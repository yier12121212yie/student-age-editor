# -*- coding: utf-8 -*-
"""导出「内置解码资源包」(Windows 有游戏时执行)

在装有游戏（含 Addressables bundle）的 Windows 机器上运行，把资源预解码成
WebP/OGG/WAV/M4A/JSON，打成 zip 内置进 APK assets。Android 运行时由 Python
后端解压到 filesDir 使用（无游戏目录、无 UnityPy 原生解码器）。

用法:
  python packaging/export_decoded_pack.py [--out dist/bundled_preview.zip]
          [--tier preview|full] [--max-side 1600] [--quality 80]
          [--limit N] [--no-zip]

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

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BACKEND = os.path.join(ROOT, "backend")
if BACKEND not in sys.path:
    sys.path.insert(0, BACKEND)

from editor.services.unityfs_res import UnityFsIndex, _norm_key  # noqa: E402
from editor.server.base_service import (  # noqa: E402
    _CFG_LANG_BAD_TOKENS,
    _clean_cfg_json,
    _match_prefix,
)

CACHE_JSON = os.path.join(BACKEND, "_cache", "aa_index", "aa_index.json")

# preview 档只导出「背景/立绘」：bundle 文件名含 bg 或 role
_PREVIEW_BUNDLE_TOKENS = ("bg", "role")


def _safe_name(key):
    """文件名安全化：键统一小写规范键，仅保留文件系统安全字符。"""
    s = re.sub(r"[^a-z0-9._-]", "_", _norm_key(key))
    return s or "asset"


def _warn(msg):
    print("[warn] %s" % msg, file=sys.stdout)


# ------------------------------------------------------------------ 索引 --

def load_index():
    """加载 AA 索引。优先读磁盘缓存；缺失/损坏时全量扫描游戏 bundle。"""
    idx = None
    if os.path.isfile(CACHE_JSON):
        try:
            with open(CACHE_JSON, "r", encoding="utf-8") as f:
                data = json.load(f)
            if isinstance(data, dict) and data.get("v") == 2 and \
                    isinstance(data.get("tex"), dict) and data["tex"]:
                idx = UnityFsIndex(bundle_dirs=[],
                                   cache_root=os.path.dirname(CACHE_JSON))
                idx._tex = dict(data.get("tex") or {})
                idx._aud = dict(data.get("aud") or {})
                idx._txt = dict(data.get("txt") or {})
                idx._cabs = dict(data.get("cabs") or {})
                idx._bundle_set = set(data.get("bundles") or [])
            else:
                print("缓存索引版本不符，改为全量扫描 ...")
        except Exception as e:
            _warn("读取索引缓存失败: %s，改为全量扫描 ..." % e)
    else:
        print("未找到存索引 %s，改为全量扫描 ..." % CACHE_JSON)

    if idx is None or len(idx.tex_keys()) == 0:
        from editor.services.unityfs_res import detect_game_aa_dir
        aa_dir = detect_game_aa_dir()
        if not aa_dir:
            raise SystemExit(
                "错误：未找到游戏 Addressables 目录，且没有可用索引缓存。\n"
                "请先在装有游戏的本机运行过一次编辑器（生成 _cache/aa_index/aa_index.json），\n"
                "或确认 Steam 库路径可被探测到（服务端可扫描）。")
        print("扫描游戏 bundle 目录 %s ..." % aa_dir)
        idx = UnityFsIndex([aa_dir], cache_root=os.path.dirname(CACHE_JSON))
        idx.scan(include_slow=True)  # 含 _role_ 大包（立绘/音频）
        if len(idx.tex_keys()) == 0:
            raise SystemExit("错误：扫描后未获得任何 tex 键。")
    _remap_bundles(idx)
    return idx


def _remap_bundles(idx):
    """缓存路径过期（游戏目录变更/换机器）时按 bundle 名在当前游戏目录重定位。"""
    try:
        from editor.services.unityfs_res import detect_game_aa_dir
        aa_dir = detect_game_aa_dir()
    except Exception:
        aa_dir = ""
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
    """按 tier 选择 tex 键：preview 只看 bundle basename 含 bg/role 的键；full 全部。"""
    keys = sorted(idx.tex_keys())
    if tier == "full":
        out = keys
    else:
        out = []
        for k in keys:
            item = idx._tex.get(k)
            if not item or len(item) < 1:
                continue
            base = os.path.basename(item[0]).lower()
            if any(tok in base for tok in _PREVIEW_BUNDLE_TOKENS):
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

    返回已导出（写入 base_data 的）txt 键列表；失败只警告，不中断。
    """
    exported = []
    for key in sorted(idx.txt_keys()):
        low = key.lower()
        if any(bad in low for bad in _CFG_LANG_BAD_TOKENS):
            continue
        cfg_name = _match_prefix(key)
        if not cfg_name:
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
    os.makedirs(cfgs_out, exist_ok=True)
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

    aud_keys = sorted(idx.aud_keys())
    if getattr(args, "no_audios", False):
        # FSB 音频经 fmod_toolkit 转出的是未压缩 WAV（全量约 2.1GB），
        # 内置 APK 时应跳过，后续需要再单独出音频包
        print("== 音频 已跳过（--no-audios）==")
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

    print("== 配置表 待导出 %d 键 ==" % len(idx.txt_keys()))
    base_data = {}
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
             "keys_total": {"tex": len(idx.tex_keys()),
                            "aud": len(idx.aud_keys()),
                            "txt": len(idx.txt_keys())}}
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


def main():
    ap = argparse.ArgumentParser(
        description="导出内置解码资源包（Windows 有游戏时执行）")
    ap.add_argument("--out", default=os.path.join(ROOT, "dist", "bundled_preview.zip"),
                    help="输出 zip 路径（默认 dist/bundled_preview.zip）")
    ap.add_argument("--tier", choices=("preview", "full"), default="preview",
                    help="preview 只导出背景/立绘纹理；full 导出全部纹理")
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
    args = ap.parse_args()

    idx = load_index()
    staging, stats = build_staging(idx, args)

    def _dir_size(p):
        if not os.path.isdir(p):
            return 0
        return sum(os.path.getsize(os.path.join(r, f))
                   for r, _, fs in os.walk(p) for f in fs)

    print("== 导出统计 ==")
    print("  tex 导出: %d / 索引 %d 键 (%d 失败可忽略)"
          % (stats["tex"], stats["keys_total"]["tex"],
             max(0, len(select_tex_keys(idx, args.tier, args.limit)) - stats["tex"])))
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


if __name__ == "__main__":
    main()