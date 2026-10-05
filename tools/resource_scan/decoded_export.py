# -*- coding: utf-8 -*-
"""导出「内置解码资源包」(Windows 有游戏时执行)。

**独立工具版本**：逻辑整体从 packaging/export_decoded_pack.py 迁入（W5-3，
波次 4 删除 backend/editor 后本文件为唯一实现）。相对旧版的三处剥离：
- `UnityFsIndex`/`_norm_key`/`detect_game_aa_dir` 改从同目录 `unityfs_res`
  导入，不再把 backend 挂上 sys.path 去依赖 editor 包。
- 清洗 helper 改从同目录 `base_tables` 导入（`_clean_cfg_json`/`_match_prefix`/
  `_CFG_LANG_BAD_TOKENS`），不再依赖 editor.server.base_service。
- 索引缓存路径不再写 backend/_cache；默认落在 <repo>/dist/aa_index_cache，
  可用 --index/--cache-dir 覆盖（索引由 `resource_scan index` 产出）。

packaging/export_decoded_pack.py 仍保留为薄壳入口（历史文档/脚本引用它）；
`py -m resource_scan decoded-pack` 直接进程内调用本模块。

在装有游戏（含 Addressables bundle）的 Windows 机器上运行，把资源预解码成
WebP/OGG/WAV/M4A/JSON，打成 zip 内置进 APK assets。Android 运行时由 Python
后端解压到 filesDir 使用（无游戏目录、无 UnityPy 原生解码器）。

用法:
  py -m resource_scan decoded-pack -- [--out dist/bundled_preview.zip]
          [--tier preview|full|portraits|backgrounds] [--max-side 1600] [--quality 80]
          [--limit N] [--no-audios] [--no-zip]
          [--from-dir <已解码图片目录>]
          [--index aa_index.json] [--aa-dir <游戏 aa 根>] [--cache-dir <目录>]

`--from-dir` 直接吃一个已解码的图片目录（如 参考资料/背景、参考资料/人物立绘），
把其中 PNG/JPG/... 统一转 WebP 打成与 decoded_export 同布局的图片扩展包
（tex/<key>.webp + aa_index.json + manifest.json），不依赖游戏 bundle / 索引。

产物 zip 布局:
  manifest.json          # name='StudentAge Bundled Resources', 含 tier/stats
  aa_index.json          # v3 解码包索引 {"v":3,"decoded":true,"tex":[...],"aud":[...],"txt":[...]}
  base_data.json         # {标准表名: {id: record}} 汇总（预览/剧情库回退）
  Cfgs/zh-cn/<表名>.json
  tex/<key>.webp         # 关键帧/立绘等纹理
  aud/<key>.ogg|wav|m4a  # 音频（FSB 经 fmod_toolkit 转 wav）

任一资源解码失败只打警告继续，不中断整个导出。
"""
import argparse
import io
import json
import os
import re
import shutil
import sys
import time
import zipfile

try:
    from .unityfs_res import UnityFsIndex, _norm_key, detect_game_aa_dir
    from .base_tables import (_CFG_LANG_BAD_TOKENS, _clean_cfg_json, _match_prefix)
except ImportError:  # 以脚本方式直跑时的回退（正常入口为 python -m resource_scan）
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    from unityfs_res import UnityFsIndex, _norm_key, detect_game_aa_dir
    from base_tables import (_CFG_LANG_BAD_TOKENS, _clean_cfg_json, _match_prefix)

# tools/resource_scan/decoded_export.py -> tools/resource_scan -> tools -> <repo>
_TOOL_DIR = os.path.dirname(os.path.abspath(__file__))
_TOOLS_DIR = os.path.dirname(_TOOL_DIR)
ROOT = os.path.dirname(_TOOLS_DIR)

# 索引缓存默认目录（dist/ 是 gitignore 的本地产物目录）：由 `resource_scan index`
# 或本脚本扫描后落盘；换机/游戏更新时以 --index 指向新产物即可。
_DEFAULT_CACHE_DIR = os.path.join(ROOT, "dist", "aa_index_cache")

# preview 档只导出「背景/立绘」：bundle 文件名含 bg 或 role
_PREVIEW_BUNDLE_TOKENS = ("bg", "role")
# portraits 档只导出「人物立绘」：bundle 文件名含 role（供「人物图片资源扩展」）
_PORTRAIT_BUNDLE_TOKENS = ("role",)
# backgrounds 档只导出「背景」：bundle 文件名含 bg（供「背景图片资源扩展」）
_BACKGROUND_BUNDLE_TOKENS = ("bg",)

# --from-dir 直接成包时可识别的图片扩展名（解码后素材，如 参考资料/背景）。
_IMAGE_EXTS = (".png", ".jpg", ".jpeg", ".webp", ".bmp", ".tga", ".gif",
               ".tif", ".tiff")


def _safe_name(key):
    """文件名安全化：键统一小写规范键，仅保留文件系统安全字符。"""
    s = re.sub(r"[^a-z0-9._-]", "_", _norm_key(key))
    return s or "asset"


def _warn(msg):
    print("[warn] %s" % msg, file=sys.stdout)


# ------------------------------------------------------------------ 索引 --

def load_index(args):
    """加载 AA 索引。优先读 --index/缓存目录产物；缺失/损坏时全量扫描游戏 bundle。

    缓存版本接受 v2（旧：无 cabs/texmeta）与 v3（含 cabs/texmeta）。
    旧实现只认 v2，而后端实际已升 v3，导致缓存恒不命中而每次全量重扫——
    此处按 ARTIFACT_FORMAT.md 的 v3 契约一并接受，属于 bug 修复。
    """
    cache_dir = args.cache_dir or _DEFAULT_CACHE_DIR
    index_path = args.index or os.environ.get("SA_AA_INDEX", "")
    if not index_path:
        cand = os.path.join(cache_dir, "aa_index.json")
        if os.path.isfile(cand):
            index_path = cand

    idx = None
    if index_path and os.path.isfile(index_path):
        try:
            with open(index_path, "r", encoding="utf-8") as f:
                data = json.load(f)
            if isinstance(data, dict) and data.get("v") in (2, 3) and \
                    isinstance(data.get("tex"), dict) and data["tex"]:
                idx = UnityFsIndex(bundle_dirs=[],
                                   cache_root=os.path.dirname(index_path))
                idx._tex = dict(data.get("tex") or {})
                idx._aud = dict(data.get("aud") or {})
                idx._txt = dict(data.get("txt") or {})
                idx._cabs = dict(data.get("cabs") or {})
                idx._texmeta = dict(data.get("texmeta") or {})
                idx._bundle_set = set(data.get("bundles") or [])
                print("索引缓存: %s（%d tex 键）"
                      % (index_path, len(idx._tex)))
            else:
                print("缓存索引版本/结构不符，改为全量扫描 ...")
        except Exception as e:
            _warn("读取索引缓存失败: %s，改为全量扫描 ..." % e)
    elif index_path:
        print("未找到索引 %s，改为全量扫描 ..." % index_path)

    if idx is None or len(idx.tex_keys()) == 0:
        aa_dir = _detect_aa_dir(args)
        if not aa_dir:
            raise SystemExit(
                "错误：未找到游戏 Addressables 目录，且没有可用索引缓存。\n"
                "请先用 `py -m resource_scan index --aa <游戏aa根> --out <目录>` 产出索引，\n"
                "或设置 SA_GAME_AA_DIR 环境变量 / 用 --aa-dir 指向游戏的 aa 根目录。")
        print("扫描游戏 bundle 目录 %s ..." % aa_dir)
        idx = UnityFsIndex([aa_dir], cache_root=cache_dir)
        idx.scan(include_slow=True)  # 含 _role_ 大包（立绘/音频）
        if len(idx.tex_keys()) == 0:
            raise SystemExit("错误：扫描后未获得任何 tex 键。")
    _remap_bundles(idx, _detect_aa_dir(args))
    return idx


def _detect_aa_dir(args):
    """游戏 aa 根目录：--aa-dir 优先，其次 SA_GAME_AA_DIR（detect 内处理），再枚举 Steam。"""
    return getattr(args, "aa_dir", "") or detect_game_aa_dir()


def _remap_bundles(idx, aa_dir):
    """缓存路径过期（游戏目录变更/换机器）时按 bundle 名在当前游戏目录重定位。"""
    if not aa_dir or not os.path.isdir(aa_dir):
        return
    changed = False
    for table in (idx._tex, idx._aud, idx._txt):
        for k, item in list(table.items()):
            if len(item) >= 2 and not os.path.isfile(item[0]):
                hit = _locate_bundle(aa_dir, os.path.basename(item[0]))
                if hit:
                    table[k] = [hit, item[1]]
                    changed = True
    if changed:
        idx._cabs = {}  # cab 映射同理可能过期，失效以便保守回退


def _locate_bundle(aa_dir, bundle_name):
    for root, dirs, files in os.walk(aa_dir):
        dirs[:] = [d for d in dirs if not d.endswith("_unpacked")]
        if bundle_name in files:
            return os.path.join(root, bundle_name)
    return None


# ------------------------------------------------------------- 选择 tex ----

def select_tex_keys(idx, tier, limit):
    """按 tier 选择 tex 键：preview 只看 bundle basename 含 bg/role 的键；
    portraits 只看含 role 的键（人物立绘）；backgrounds 只看含 bg 的键
    （背景）；full 全部。"""
    keys = sorted(idx.tex_keys())
    if tier == "full":
        out = keys
    else:
        if tier == "portraits":
            tokens = _PORTRAIT_BUNDLE_TOKENS
        elif tier == "backgrounds":
            tokens = _BACKGROUND_BUNDLE_TOKENS
        else:
            tokens = _PREVIEW_BUNDLE_TOKENS
        out = []
        for k in keys:
            item = idx._tex.get(k)
            if not item or len(item) < 1:
                continue
            base = os.path.basename(item[0]).lower()
            if any(tok in base for tok in tokens):
                out.append(k)
    if limit and limit > 0:
        out = out[:limit]
    return out


# ------------------------------------------------------------ tex 解码 ----

def _tex_image(idx, key):
    try:
        item = idx._tex.get(_norm_key(key))
        if not item:
            return None
        env = idx._get_env(item[0])
        obj = idx._find_object(env, item[0], item[1])
        if obj is None:
            return None
        return obj.read().image
    except Exception:
        return None


def _to_webp_bytes(img, max_side, quality):
    from PIL import Image
    try:
        if img.mode in ("1", "P"):
            img = img.convert("RGBA")
        elif img.mode not in ("RGB", "RGBA", "LA", "L"):
            img = img.convert("RGB")
        if img.mode == "RGBA":
            try:
                if img.getchannel("A").getextrema() == (255, 255):
                    img = img.convert("RGB")  # 不透明 RGBA → RGB，体积更小
            except Exception:
                pass
        if max_side and max_side > 0 and max(img.size) > max_side:
            img.thumbnail((max_side, max_side), Image.LANCZOS)
        buf = io.BytesIO()
        img.save(buf, "WEBP", quality=quality)
        return buf.getvalue()
    except Exception:
        return None


def export_tex(idx, key, out_dir, max_side, quality):
    try:
        item = idx._tex.get(_norm_key(key))
        if not item:
            _warn("tex %s 不在索引中" % key)
            return None
        env = idx._get_env(item[0])
        obj = idx._find_object(env, item[0], item[1])
        if obj is None:
            _warn("tex %s 对象未找到" % key)
            return None
        data = _to_webp_bytes(obj.read().image, max_side, quality)
        if not data:
            _warn("tex %s WebP 编码失败" % key)
            return None
        path = os.path.join(out_dir, _safe_name(key) + ".webp")
        with open(path, "wb") as f:
            f.write(data)
        return path
    except Exception as e:
        _warn("tex %s 解码失败: %s" % (key, e))
        return None


# ------------------------------------------------------------ aud 解码 ----

def _read_audio(idx, key):
    """读取音频原始字节。返回 (blob, channels, freq)；失败 None。"""
    try:
        item = idx._aud.get(_norm_key(key))
        if not item:
            return None
        env = idx._get_env(item[0])
        obj = idx._find_object(env, item[0], item[1])
        if obj is None:
            return None
        audio = obj.read()
        from UnityPy.helpers.ResourceReader import get_resource_data
        if getattr(audio, "m_AudioData", None):
            blob = bytes(audio.m_AudioData)
        elif getattr(audio, "m_Resource", None):
            res = audio.m_Resource
            blob = get_resource_data(res.m_Source, obj.assets_file,
                                     res.m_Offset, res.m_Size)
        else:
            return None
        return (blob, int(getattr(audio, "m_Channels", 0) or 2),
                int(getattr(audio, "m_Frequency", 0) or 44100))
    except Exception:
        return None


def export_aud(idx, key, out_dir):
    """魔数嗅探直接透传 OggS/RIFF/ftyp 原始字节；FSB 需 fmod_toolkit 转换。"""
    info = _read_audio(idx, key)
    if info is None:
        _warn("aud %s 解码失败" % key)
        return None
    blob, channels, freq = info
    magic = memoryview(blob)[:8]
    if magic[:4] == b"OggS":
        ext, data = ".ogg", blob
    elif magic[:4] == b"RIFF":
        ext, data = ".wav", blob
    elif magic[4:8] == b"ftyp":
        ext, data = ".m4a", blob
    else:
        # FSB 等私有封装，桌面端用 fmod_toolkit 解
        try:
            import fmod_toolkit
        except Exception:
            _warn("aud %s 为 FSB 音频但 fmod_toolkit 不可用，跳过" % key)
            return None
        try:
            res_map = fmod_toolkit.raw_to_wav(
                blob, "clip", channels, freq)
            if not res_map:
                raise RuntimeError("raw_to_wav 无输出")
            data, ext = next(iter(res_map.values())), ".wav"
        except Exception as e:
            _warn("aud %s FSB 转换失败: %s" % (key, e))
            return None
    path = os.path.join(out_dir, _safe_name(key) + ext)
    try:
        with open(path, "wb") as f:
            f.write(data)
        return path
    except Exception as e:
        _warn("aud %s 写盘失败: %s" % (key, e))
        return None


# ------------------------------------------------------------ txt 解码 ----

def export_cfgs(idx, cfgs_out, base_data):
    """官方 Cfgs TextAsset -> utf-8 JSON；汇总进 base_data。

    核心表（_match_prefix 白名单）进 base_data 汇总并按表名落盘；其余游戏
    文本表（成就/题库等 ~300 张）也落盘（文件名 _safe_name(key)），否则
    解码包形态（C++ 后端 / Android）的 /api/aa/keys 会暴露一批 preview
    必然 422 的幽灵键（桌面 UnityPy 实时解码掩盖了该供给缺口）。

    返回已导出的 txt 键列表；失败只警告，不中断。
    """
    os.makedirs(cfgs_out, exist_ok=True)
    exported = []
    for key in sorted(idx.txt_keys()):
        low = key.lower()
        if any(bad in low for bad in _CFG_LANG_BAD_TOKENS):
            continue
        cfg_name = _match_prefix(key)
        if not cfg_name:
            # 非核心表：原样文本落 pack（不进 base_data，不清洗）
            try:
                raw = idx.export_text(key)
                if not raw:
                    continue
                with open(os.path.join(cfgs_out, _safe_name(key) + ".json"),
                          "wb") as f:
                    f.write(raw)
                exported.append(key)
            except Exception as e:
                _warn("txt %s 导出异常: %s" % (key, e))
            continue
        try:
            raw = idx.export_text(key)
            if not raw:
                continue
            content = raw.decode("utf-8", errors="ignore")
            data = _clean_cfg_json(content)
            if not isinstance(data, dict) or not data:
                continue
            base_data.setdefault(cfg_name, {}).update(data)
            exported.append(key)
        except Exception as e:
            _warn("txt %s 解析异常: %s" % (key, e))
    for cfg_name in sorted(base_data):
        with open(os.path.join(cfgs_out, cfg_name + ".json"),
                  "w", encoding="utf-8") as f:
            json.dump(base_data[cfg_name], f, ensure_ascii=False)
    return exported


# ------------------------------------------------------------- 组装 zip ----

def build_staging(idx, args):
    staging = os.path.splitext(args.out)[0] if args.out.lower().endswith(".zip") \
        else args.out
    if os.path.isdir(staging):
        shutil.rmtree(staging)
    os.makedirs(staging)
    tex_dir = os.path.join(staging, "tex")
    aud_dir = os.path.join(staging, "aud")
    cfgs_dir = os.path.join(staging, "Cfgs", "zh-cn")
    for d in (tex_dir, aud_dir, cfgs_dir):
        os.makedirs(d, exist_ok=True)

    tex_keys = select_tex_keys(idx, args.tier, args.limit)
    print("== 纹理 (tier=%s) 待导出 %d 键 ==" % (args.tier, len(tex_keys)))
    exported_tex = []
    tex_bytes = 0
    for i, key in enumerate(tex_keys, 1):
        if i % 100 == 0 or i == len(tex_keys):
            print("  ... tex %d/%d" % (i, len(tex_keys)))
        path = export_tex(idx, key, tex_dir, args.max_side, args.quality)
        if path:
            exported_tex.append(_norm_key(key))
            tex_bytes += os.path.getsize(path)

    portraits_only = args.tier == "portraits"
    backgrounds_only = args.tier == "backgrounds"
    image_only = portraits_only or backgrounds_only
    aud_keys = sorted(idx.aud_keys())
    if getattr(args, "no_audios", False) or image_only:
        # FSB 音频经 fmod_toolkit 转出的是未压缩 WAV（全量约 2.1GB），
        # 内置 APK 时应跳过；人物/背景图片包只含纹理，同样跳过音频。
        if getattr(args, "no_audios", False):
            reason = "--no-audios"
        elif backgrounds_only:
            reason = "backgrounds 只含背景"
        else:
            reason = "portraits 只含立绘"
        print("== 音频 已跳过（%s）==" % reason)
        aud_keys = []
    elif args.limit and args.limit > 0:
        aud_keys = aud_keys[:args.limit]  # 冒烟模式：音频同样限量，保持快速
    print("== 音频 待导出 %d 键 ==" % len(aud_keys))
    exported_aud = []
    aud_bytes = 0
    for key in aud_keys:
        path = export_aud(idx, key, aud_dir)
        if path:
            exported_aud.append(_norm_key(key))
            aud_bytes += os.path.getsize(path)

    base_data = {}
    exported_txt = []
    cfg_bytes = 0
    if image_only:
        # 人物/背景图片包不含配置表：纹理 key 由工作区 PersonCfg/BgCfg 提供，
        # 包只负责提供纹理字节，保持体积最小、不覆盖 active 包的 base_data。
        print("== 配置表 已跳过（%s图片包只含纹理）==" % args.tier)
    else:
        print("== 配置表 待导出 %d 键 ==" % len(idx.txt_keys()))
        exported_txt = export_cfgs(idx, cfgs_dir, base_data)
        cfg_bytes = sum(
            os.path.getsize(os.path.join(cfgs_dir, f))
            for f in os.listdir(cfgs_dir) if f.endswith(".json"))

    aa_v3 = {"v": 3, "decoded": True,
             "tex": sorted(exported_tex),
             "aud": sorted(exported_aud),
             "txt": sorted(exported_txt)}
    with open(os.path.join(staging, "aa_index.json"), "w", encoding="utf-8") as f:
        json.dump(aa_v3, f, ensure_ascii=False)
    with open(os.path.join(staging, "base_data.json"), "w", encoding="utf-8") as f:
        json.dump(base_data, f, ensure_ascii=False)

    stats = {"tex": len(exported_tex), "tex_bytes": tex_bytes,
             "aud": len(exported_aud), "aud_bytes": aud_bytes,
             "txt": len(exported_txt), "cfgs_bytes": cfg_bytes,
             "max_side": args.max_side, "quality": args.quality,
             "selected_tex": len(tex_keys),
             "keys_total": {"tex": len(idx.tex_keys()),
                            "aud": len(idx.aud_keys()),
                            "txt": len(idx.txt_keys())}}
    if image_only:
        kind, name, description = _kind_label(args.tier)
        manifest = {
            "name": name,
            "version": time.strftime("%Y.%m.%d"),
            "description": description,
            "kind": kind,
            "game_version": "",
            "created_at": time.strftime("%Y-%m-%dT%H:%M:%S"),
            "tier": args.tier,
            "stats": stats,
        }
    else:
        manifest = {
            "name": "StudentAge Bundled Resources",
            "version": time.strftime("%Y.%m.%d"),
            "description": "内置解码资源包（预解码 WebP/OGG/JSON，APK 内置）",
            "game_version": "",
            "created_at": time.strftime("%Y-%m-%dT%H:%M:%S"),
            "tier": args.tier,
            "stats": stats,
        }
    with open(os.path.join(staging, "manifest.json"), "w",
              encoding="utf-8") as f:
        json.dump(manifest, f, ensure_ascii=False, indent=2)
    return staging, stats


# ------------------------------------------------------- 目录直接成包 ----
# 背景/立绘等「已解码图片」目录（如 参考资料/背景）直接转 WebP 打图片扩展包：
# 与 decoded_export 的 tex/ 布局、aa_index.json v3、manifest 完全一致，只是
# 纹理来源从 game bundle 换成磁盘目录，供无游戏环境的机器离线成包。
def _kind_label(tier):
    if tier == "backgrounds":
        return ("backgrounds", "StudentAge Background Pack",
                "背景图片资源扩展包（场景背景，预解码 WebP）")
    if tier == "portraits":
        return ("portraits", "StudentAge Portrait Pack",
                "人物图片资源扩展包（角色立绘，预解码 WebP）")
    return ("textures", "StudentAge Image Pack", "图片资源扩展包（预解码 WebP）")


def build_staging_from_dir(args):
    """把一个已解码图片目录直接转 WebP 打成图片扩展包。

    不读游戏 bundle / 索引：遍历 `--from-dir` 顶层图片文件，按 `_norm_key`
    取键（去扩展名、小写）→ `tex/<safe_name>.webp`；写出 aa_index.json v3 与
    manifest.json，与 bundle 路径产物逐字段同构，`_kind_label` 决定 kind。
    """
    from_dir = os.path.abspath(args.from_dir)
    if not os.path.isdir(from_dir):
        raise SystemExit("错误：--from-dir 目录不存在：%s" % from_dir)
    staging = os.path.splitext(args.out)[0] if args.out.lower().endswith(".zip") \
        else args.out
    if os.path.isdir(staging):
        shutil.rmtree(staging)
    tex_dir = os.path.join(staging, "tex")
    os.makedirs(tex_dir)

    files = []
    for fn in sorted(os.listdir(from_dir)):
        fp = os.path.join(from_dir, fn)
        if os.path.isfile(fp) and os.path.splitext(fn)[1].lower() in _IMAGE_EXTS:
            files.append(fp)
    print("== 图片 (from-dir=%s) 待导出 %d 张 ==" % (from_dir, len(files)))
    exported = []
    tex_bytes = 0
    failed = 0
    for i, fp in enumerate(files, 1):
        if i % 100 == 0 or i == len(files):
            print("  ... img %d/%d" % (i, len(files)))
        key = _norm_key(os.path.basename(fp))
        if not key:
            continue
        try:
            from PIL import Image
            with Image.open(fp) as im:
                data = _to_webp_bytes(im, args.max_side, args.quality)
        except Exception as e:
            _warn("img %s 解码失败: %s" % (os.path.basename(fp), e))
            failed += 1
            continue
        if not data:
            _warn("img %s WebP 编码失败" % os.path.basename(fp))
            failed += 1
            continue
        with open(os.path.join(tex_dir, _safe_name(key) + ".webp"), "wb") as f:
            f.write(data)
        exported.append(_norm_key(key))
        tex_bytes += len(data)

    kind, name, description = _kind_label(args.tier)
    aa_v3 = {"v": 3, "decoded": True,
             "tex": sorted(set(exported)), "aud": [], "txt": []}
    with open(os.path.join(staging, "aa_index.json"), "w", encoding="utf-8") as f:
        json.dump(aa_v3, f, ensure_ascii=False)
    with open(os.path.join(staging, "base_data.json"), "w", encoding="utf-8") as f:
        json.dump({}, f, ensure_ascii=False)

    stats = {"tex": len(aa_v3["tex"]), "tex_bytes": tex_bytes,
             "aud": 0, "aud_bytes": 0, "txt": 0, "cfgs_bytes": 0,
             "max_side": args.max_side, "quality": args.quality,
             "selected_tex": len(files), "failed": failed,
             "keys_total": {"tex": len(files), "aud": 0, "txt": 0}}
    manifest = {
        "name": name,
        "version": time.strftime("%Y.%m.%d"),
        "description": description,
        "kind": kind,
        "game_version": "",
        "created_at": time.strftime("%Y-%m-%dT%H:%M:%S"),
        "tier": args.tier,
        "stats": stats,
    }
    with open(os.path.join(staging, "manifest.json"), "w",
              encoding="utf-8") as f:
        json.dump(manifest, f, ensure_ascii=False, indent=2)
    return staging, stats


def make_zip(staging, out_path):
    os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)
    if os.path.isfile(out_path):
        os.remove(out_path)
    with zipfile.ZipFile(out_path, "w", zipfile.ZIP_DEFLATED,
                         compresslevel=6) as z:
        for root, dirs, files in os.walk(staging):
            for f in sorted(files):
                full = os.path.join(root, f)
                z.write(full, os.path.relpath(full, staging))
    return out_path


def build_parser():
    ap = argparse.ArgumentParser(
        prog="export_decoded_pack",
        description="导出内置解码资源包（Windows 有游戏时执行）")
    ap.add_argument("--out", default=os.path.join(ROOT, "dist", "bundled_preview.zip"),
                    help="输出 zip 路径（默认 dist/bundled_preview.zip）")
    ap.add_argument("--tier", choices=("preview", "full", "portraits", "backgrounds"),
                    default="preview",
                    help="preview 只导出背景/立绘纹理；portraits 只导出人物立绘；"
                         "backgrounds 只导出背景；full 导出全部纹理")
    ap.add_argument("--max-side", type=int, default=1600,
                    help="纹理最大边（超过则 LANCZOS 缩小）")
    ap.add_argument("--quality", type=int, default=80,
                    help="WebP 质量 (0-100)")
    ap.add_argument("--limit", type=int, default=0,
                    help="有限导出：限定处理的 tex 键数量（音频同步限量），冒烟测试用")
    ap.add_argument("--no-audios", action="store_true",
                    help="跳过音频导出（FSB→WAV 体积过大，内置 APK 建议关闭）")
    ap.add_argument("--no-zip", action="store_true",
                    help="只生成目录不打包 zip（保留在 dist/ 下）")
    ap.add_argument("--from-dir", default="",
                    help="直接吃一个已解码图片目录（如 参考资料/背景）转 WebP 成包，"
                         "不读游戏 bundle / 索引")
    ap.add_argument("--index", default="",
                    help="已产出的 aa_index.json 路径（默认 $SA_AA_INDEX / "
                         "--cache-dir/aa_index.json；都没有则扫描 --aa-dir）")
    ap.add_argument("--aa-dir", default="",
                    help="游戏 Addressables 根目录（默认 $SA_GAME_AA_DIR / Steam 库探测）")
    ap.add_argument("--cache-dir", default="",
                    help="索引缓存目录（默认 <repo>/dist/aa_index_cache）")
    return ap


def main(argv=None):
    ap = build_parser()
    args = ap.parse_args(argv)

    if args.from_dir:
        staging, stats = build_staging_from_dir(args)
    else:
        idx = load_index(args)
        staging, stats = build_staging(idx, args)

    print("== 导出统计 ==")
    total_tex = stats.get("selected_tex", stats["keys_total"]["tex"])
    failed_tex = stats.get("failed", max(0, total_tex - stats["tex"]))
    print("  tex 导出: %d / %d 键 (%d 失败可忽略)"
          % (stats["tex"], total_tex, failed_tex))
    print("  aud 导出: %d / 索引 %d 键"
          % (stats["aud"], stats["keys_total"]["aud"]))
    print("  txt 导出: %d / 索引 %d 键"
          % (stats["txt"], stats["keys_total"]["txt"]))
    print("  目录体积: tex %.1f MB, aud %.1f MB, Cfgs %.1f MB"
          % (stats["tex_bytes"] / 1048576, stats["aud_bytes"] / 1048576,
             stats["cfgs_bytes"] / 1048576))
    print("  staging: %s" % staging)

    if not args.no_zip:
        make_zip(staging, args.out)
        print("  zip: %s (%.1f MB)" % (args.out,
                                       os.path.getsize(args.out) / 1048576))
        # 默认清掉临时目录，只留 zip（--no-zip 模式则保留目录）
        shutil.rmtree(staging, ignore_errors=True)
    else:
        print("  --no-zip：目录保留在 %s" % staging)
    return 0


if __name__ == "__main__":
    sys.exit(main())
