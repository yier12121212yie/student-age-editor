# -*- coding: utf-8 -*-
"""原版配置表导出：base_data/<Table>.json + base_meta.json（替代 pickle base_data.pkl）。

常量与清洗逻辑复制自 backend/editor/server/base_service.py（波次 4 删原件后此处
为唯一出处）：_CFG_PREFIXES / _CFG_KEY_MAP / _CFG_LANG_BAD_TOKENS / _TC_CHARS /
_clean_cfg_json / _match_prefix；脏数据读取语义与其 _load_from_dirs /
_load_from_aa 一致（utf-8-sig + errors=ignore、繁体检出即弃、脏 JSON 强洗）。

合并语义（写入 base_meta.json.merge_semantics 供 C++ 校验）：
  表 = dict-of-rows；多来源命中同一表名时按「CLI 源顺序 → bundle/文件名排序」
  逐行 dict.update（后来源的同 id 行覆盖前行）。与 studio 模式
  Cfgs/zh-cn + Cfgs/DLC_zh-cn 的合并方式一致。
"""
import hashlib
import json
import os
import re

try:
    from .util import norm_key, write_json_atomic
    from .aa_index import now_iso
except ImportError:  # 脚本直跑回退
    from util import norm_key, write_json_atomic
    from aa_index import now_iso

# ---------------- 配置表识别常量（复制自 base_service.py，勿改） ----------------

_CFG_PREFIXES = [
    "personcfg", "bgcfg", "evtcfg", "talkcfg", "optioncfg", "cgcfg",
    "relationcfg", "itemcfg", "bookcfg", "personattrcfg", "mapcfg",
    "actioncfg", "actionevtcfg", "personstatecfg", "tvcfg", "moviecfg",
    "shopcfg", "endingdatingcfg", "endingoptioncfg", "papercfg", "textcfg", "togglecfg", "minigamecfg", "minigameactioncfg", "jobcfg",
    "kzoneprofilecfg", "kzoneavatarcfg", "kzonecolorcfg", "kzonefontcfg", "negotiationteammatecfg", "audiocfg",
    "intentcfg", "negotiationplayercfg", "interactcfg", "friendrequestcfg",
    "lovevindicateratecfg", "lovebadmintoncfg", "badmintonmodelcfg", "loveribboncfg", "lovedrawcfg", "lovebreakfastcfg", "evttypecfg",
    "endingpartcfg", "kzonecontentcfg", "kzonecommentcfg", "phonemsgcfg", "explorecfg",
]

_CFG_KEY_MAP = {
    "personcfg": "PersonCfg", "bgcfg": "BgCfg", "evtcfg": "EvtCfg", "talkcfg": "TalkCfg",
    "optioncfg": "OptionCfg", "cgcfg": "CGCfg", "relationcfg": "RelationCfg",
    "itemcfg": "ItemCfg", "bookcfg": "BookCfg", "personattrcfg": "PersonAttrCfg", "mapcfg": "MapCfg",
    "actioncfg": "ActionCfg", "actionevtcfg": "ActionEvtCfg", "personstatecfg": "PersonStateCfg",
    "tvcfg": "TvCfg", "moviecfg": "MovieCfg", "shopcfg": "ShopCfg",
    "endingdatingcfg": "EndingDatingCfg", "endingoptioncfg": "EndingOptionCfg", "papercfg": "PaperCfg", "textcfg": "TextCfg",
    "togglecfg": "ToggleCfg", "minigamecfg": "MinigameCfg", "minigameactioncfg": "MinigameActionCfg", "jobcfg": "JobCfg",
    "kzoneprofilecfg": "KZoneProfileCfg", "kzoneavatarcfg": "KZoneAvatarCfg",
    "kzonecolorcfg": "KZoneColorCfg", "kzonefontcfg": "KZoneFontCfg", "negotiationteammatecfg": "NegotiationTeammateCfg", "audiocfg": "AudioCfg",
    "intentcfg": "IntentCfg", "negotiationplayercfg": "NegotiationPlayerCfg", "interactcfg": "InteractCfg", "friendrequestcfg": "FriendRequestCfg",
    "lovevindicateratecfg": "LoveVindicateRateCfg", "lovebadmintoncfg": "LoveBadmintonCfg", "badmintonmodelcfg": "BadmintonModelCfg",
    "loveribboncfg": "LoveRibbonCfg", "lovedrawcfg": "LoveDrawCfg", "lovebreakfastcfg": "LoveBreakfastCfg", "evttypecfg": "EvtTypeCfg",
    "endingpartcfg": "EndingPartCfg", "kzonecontentcfg": "KZoneContentCfg", "kzonecommentcfg": "KZoneCommentCfg", "phonemsgcfg": "PhoneMsgCfg", "explorecfg": "ExploreCfg",
}

_TC_CHARS = ["們", "這", "個", "說", "選項", "繼續", "遊戲", "嗎", "過", "點", "樣", "為", "與", "對", "從", "來", "將", "還", "實", "認", "滿", "沒", "現", "經", "開", "發", "間", "時", "體", "裡", "後", "會", "話", "請", "錯", "關", "閉", "儲", "載", "测试", "設置", "檔案", "離開", "讀取", "階", "臺", "學", "牆", "奧", "場", "館", "紅", "綠", "藍", "漸", "變", "圖", "單", "擊", "雙", "髮", "褲", "襪", "鞋", "飾", "裝", "愛", "戀", "歡", "氣", "結"]
_CFG_LANG_BAD_TOKENS = ["-en", "_en", "-hant", "hant", "hk", "_tw", "-tw", "traditional", "en_", "en-"]


def _clean_cfg_json(content):
    """清洗配置表内容（复制自 base_service._clean_cfg_json，逐行一致）：
    繁体/多语言内容返回 None；脏 JSON 强洗后返回 dict。"""
    sample = content[:200000]
    tc_count = 0
    for c in _TC_CHARS:
        tc_count += sample.count(c)
        if tc_count > 2:
            break
    if tc_count > 2:
        return None
    try:
        data = json.loads(content, strict=False)
        return data if isinstance(data, dict) else None
    except json.JSONDecodeError:
        c_text = re.sub(r"//.*", "", content)
        c_text = re.sub(r"/\*.*?\*/", "", c_text, flags=re.DOTALL)
        c_text = re.sub(r",\s*([\]}])", r"\1", c_text)
        c_text = c_text.strip()
        if c_text.endswith(",}"):
            c_text = c_text[:-2] + "}"
        if c_text.endswith(",]"):
            c_text = c_text[:-2] + "]"
        try:
            data = json.loads(c_text, strict=False)
            return data if isinstance(data, dict) else None
        except Exception:
            return None


def _match_prefix(name):
    """从文件名或 key 中匹配最长的配置表前缀，返回标准表名；未匹配返回 None。"""
    low = (name or "").lower()
    best = ""
    for pfx in _CFG_PREFIXES:
        if low.startswith(pfx) and len(pfx) > len(best):
            best = pfx
    return _CFG_KEY_MAP.get(best) if best else None


def is_lang_bad(key):
    return any(x in (key or "").lower() for x in _CFG_LANG_BAD_TOKENS)


# ---------------- 来源抽取 ----------------


def extract_cfg_texts(env, bundle_path):
    """从已加载 Environment 抽取配置表候选：{norm_key: utf-8 字节}。

    bundle 文件名本身含多语言坏 token（cfgs-zh-hant、english、dlc_cfgs-zh-hant）
    时整包跳过：backend 靠索引跨包 first-wins 遮蔽繁体键，本工具 texts 模式
    保留所有贡献，若无此过滤繁体行会覆盖本体行（实测 NegotiationPlayerCfg）。
    仅收 TextAsset 且对象名命中 _CFG_PREFIXES、未含多语言坏 token 的键；
    同包重名 first-wins（与 _collect_env 的包内去重一致）。
    内容取 m_Script（UnityPy：str 则 encode utf-8，bytes/其他按字节转）。
    """
    if is_lang_bad(os.path.basename(bundle_path or "")):
        return {}
    out = {}
    for obj in env.objects:
        if obj.type.name != "TextAsset":
            continue
        try:
            name = obj.peek_name() or ""
        except Exception:
            try:
                name = obj.read().m_Name or ""
            except Exception:
                continue
        key = norm_key(name)
        if not key or key in out or is_lang_bad(key) or not _match_prefix(key):
            continue
        try:
            script = obj.read().m_Script
        except Exception:
            continue
        if isinstance(script, str):
            blob = script.encode("utf-8")
        elif isinstance(script, bytes):
            blob = script
        else:
            try:
                blob = bytes(script)
            except Exception:
                continue
        out[key] = blob
    return out


def read_cfg_dir(cfg_dir):
    """读取解包 Cfgs 目录（游戏/UnityRipper 的 zh-cn 目录）：{norm_key: 文本}。
    文件读取语义复制自 base_service._load_from_dirs：顶层 .json/.txt、
    utf-8-sig + errors=ignore、坏 token 跳过、前缀匹配。"""
    out = {}
    for f in sorted(os.listdir(cfg_dir)):
        if not f.lower().endswith((".json", ".txt")):
            continue
        if is_lang_bad(f) or not _match_prefix(f):
            continue
        try:
            with open(os.path.join(cfg_dir, f), "r", encoding="utf-8-sig",
                      errors="ignore") as fp:
                content = fp.read()
        except Exception:
            continue
        out[norm_key(f)] = content
    return out


# ---------------- 合并与落盘 ----------------


def merge_contributions(contribs, errors):
    """contribs = [(source_label, {key: str|bytes}), ...]（有序）。

    返回 tables: 表名 -> {id: record}（逐行 dict.update，后来源覆盖同行 id）。
    与 base_service._load_from_aa / _load_from_dirs 的单文件清洗一致：
    bytes 先 decode('utf-8', errors='ignore')，再过 _clean_cfg_json。
    """
    tables = {}
    origins = {}
    for label, items in contribs:
        for key in sorted(items):
            content = items[key]
            if isinstance(content, (bytes, bytearray)):
                content = bytes(content).decode("utf-8", errors="ignore")
            cfg_name = _match_prefix(key)
            if not cfg_name:
                continue
            try:
                data = _clean_cfg_json(content)
            except Exception as e:
                errors.append("[%s/%s] 清洗异常: %s" % (label, key, e))
                continue
            if data is None:
                continue
            bucket = tables.setdefault(cfg_name, {})
            bucket.update(data)
            srcs = origins.setdefault(cfg_name, [])
            if label not in srcs:
                srcs.append(label)
    return tables, origins


def table_sha256(table_map):
    """规范化序列化（与 base_data/<Table>.json 落盘字节完全一致）后取 sha256。"""
    blob = json.dumps(table_map, ensure_ascii=False).encode("utf-8")
    return hashlib.sha256(blob).hexdigest()


def write_artifacts(out_dir, tables, origins, meta_extra):
    base_dir = os.path.join(out_dir, "base_data")
    os.makedirs(base_dir, exist_ok=True)
    manifest = {}
    for name in sorted(tables):
        path = os.path.join(base_dir, name + ".json")
        write_json_atomic(tables[name], path)
        size = os.path.getsize(path)
        manifest[name] = {
            "file": "base_data/%s.json" % name,
            "rows": len(tables[name]),
            "bytes": size,
            "sha256": table_sha256(tables[name]),
            "sources": origins.get(name, []),
        }
    meta = {
        "v": 1,
        "tool": "resource_scan",
        "tables": manifest,
        "table_count": len(manifest),
        "total_bytes": sum(m["bytes"] for m in manifest.values()),
        "missing_expected": sorted(set(_CFG_KEY_MAP.values()) - set(manifest)),
        "merge_semantics": "dict-of-rows; per-row update in source order (later source overwrites same row id)",
        "encoding": "UTF-8 no BOM; JSON compact (ensure_ascii=false)",
        "generated_at": now_iso(),
    }
    meta.update(meta_extra)
    write_json_atomic(meta, os.path.join(out_dir, "base_meta.json"))
    return meta
