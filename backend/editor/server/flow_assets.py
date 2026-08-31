# -*- coding: utf-8 -*-
"""剧情图媒体资产判定：从全量 AA key 中筛出「CG 图片」与「音乐（BGM）」。

纯函数、不依赖 api.STATE，可脱离 HTTP 服务单测。信号来源：
- 纹理尺寸（aa_index v3 texmeta / 资源包图像头部），CG 为全屏演出图，
  分辨率不低于游戏内 1280x720 是硬底线；
- Addressable 分组编码在 bundle 文件名里（textures_assets_cg / bg / role /
  icon…），作为直通/否决的辅助信号；
- 音频按 audios_assets_bgm bundle 与 AudioCfg(type=1) 的 url 判定 BGM，
  TTS 配音（audio/tts/）与角色语音包（audios_assets_role）排除。
"""
import os
import re

# CG 分辨率硬底线（游戏原生 1280x720）
CG_MIN_W = 1280
CG_MIN_H = 720
# 宽高比合理区间：排除竖幅立绘大图与长条拼接图
CG_RATIO_MIN = 1.15
CG_RATIO_MAX = 2.4

# 确定性剧情演出组（textures_assets_<group>）：分辨率达标即 CG
_CG_GROUPS = frozenset(("cg", "cg2", "big", "comic"))
# 混合内容组（主包/背景/DLC v1xx）：分辨率 + 宽高比启发
_MIXED_GROUPS_PREFIX = ("v",)
_MIXED_GROUPS = frozenset(("", "bg"))
# SpriteAtlas 自动拼页纹理名前缀（icon/role/语音等图集页，非 CG）
_ATLAS_KEY_PREFIX = "sactx-"
_TEXTURES_BUNDLE = "textures_assets_"
_HASH_RE = re.compile(r"[0-9a-f]{16,}$")


def _tex_group(bundle_path):
    """`textures_assets_<group>_<hash>.bundle` → group；非贴图 bundle 返回 None。

    实测 Addressable 打包按组分 bundle（cg/cg2/big/comic/paint/icon/role/
    kzone-head/v177…），组名是最可靠的来源信号；localization、prefabs、
    kzone_min、common 等非 `textures_assets_` 前缀的 bundle 一律 None。
    """
    name = _bundle_name(bundle_path)
    if not name.startswith(_TEXTURES_BUNDLE):
        return None
    rest = name[len(_TEXTURES_BUNDLE):]
    if rest.endswith(".bundle"):
        rest = rest[:-len(".bundle")]
    parts = rest.split("_")
    # 末段是打包 hash（长十六进制）；组名本身可含 '-'（kzone-head）
    if len(parts) > 1 and _HASH_RE.search(parts[-1]):
        parts = parts[:-1]
    return parts[0] if parts else None

# 确定性非音乐：角色语音、配音落盘目录
_MUSIC_REJECT = ("audios_assets_role", "audios_assets_ogg", "audio/tts",
                 "audio\\tts")


def _bundle_name(bundle_path):
    """bundle 路径 → 小写文件名（资源包的解码文件路径同样适用其目录段）。"""
    s = (bundle_path or "").replace("\\", "/").lower()
    return os.path.basename(s) if "/" in s or s else s


def is_cg_image(key, bundle_path, width, height):
    """CG 图片判定：分辨率硬底线 + Addressable 组白名单 + 混合组宽高比启发。

    规则（依次短路）：
    1. w>=1280 且 h>=720（低于底线一律不是 CG）；
    2. `sactx-*`（SpriteAtlas 拼页）否决；
    3. 非 `textures_assets_` 前缀的 bundle（kzone_min/localization/main/
       common/prefabs…）否决；
    4. 确定性演出组 cg/cg2/big/comic 直通；
    5. 混合内容组（主包、bg、DLC v1xx）与资源包平铺文件：宽高比
       1.15~2.4 + 键名启发否决（icon/head/ui/atlas…）。

    width/height 任一缺失（旧索引无 texmeta）返回 False，由调用方决定回退。
    """
    try:
        w = int(width or 0)
        h = int(height or 0)
    except (TypeError, ValueError):
        return False
    if w < CG_MIN_W or h < CG_MIN_H:
        return False
    if (key or "").strip().lower().startswith(_ATLAS_KEY_PREFIX):
        return False
    name = _bundle_name(bundle_path)
    group = _tex_group(name)
    if group is None:
        # 内置资源包平铺文件（pack/tex/*.webp）没有分组信息：走启发式；
        # 其余非贴图 bundle 整包否决
        if name.endswith(".bundle"):
            return False
    elif group in _CG_GROUPS:
        return True
    elif not (group in _MIXED_GROUPS or group.startswith(_MIXED_GROUPS_PREFIX)):
        # paint/icon/role/kzone-head/guide/puzzle/track… 明确非 CG 组
        return False
    ratio = w / float(h)
    if not (CG_RATIO_MIN <= ratio <= CG_RATIO_MAX):
        return False
    kl = (key or "").lower()
    if re.search(r"(icon|head|avatar|cloth|\bui[_-]|atlas|spine)", kl):
        return False
    return True


def music_url_basenames(audio_rows):
    """从 AudioCfg 行（dict-of-dict 或行迭代器）提取 type==1（BGM）的 url basename 集合。"""
    out = set()
    rows = audio_rows.values() if isinstance(audio_rows, dict) else audio_rows
    for row in rows:
        if not isinstance(row, dict):
            continue
        try:
            if int(row.get("type") or 0) != 1:
                continue
        except (TypeError, ValueError):
            continue
        url = str(row.get("url") or "").strip()
        if not url:
            continue
        base = os.path.basename(url.replace("\\", "/")).lower()
        base = os.path.splitext(base)[0]
        if base:
            out.add(base)
    return out


def is_music(key, bundle_path, music_urls):
    """音乐（BGM）判定：bgm bundle 直通 / AudioCfg type=1 url 命中；语音与配音排除。"""
    kl = (key or "").strip().lower()
    name = _bundle_name(bundle_path)
    full = (bundle_path or "").replace("\\", "/").lower()
    for tag in _MUSIC_REJECT:
        if tag in name or tag in full or kl.startswith("audio/tts"):
            return False
    if "audios_assets_bgm" in name or "bgm" in name:
        return True
    return kl in music_urls
