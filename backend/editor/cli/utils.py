# -*- coding: utf-8 -*-
"""Shared helpers for CLI and TUI – filesystem-centric, no HTTP required."""

import json
import os
import re
import sys
from pathlib import Path

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

GAME_WORKSHOP_APPID = "1991040"

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


def editor_root() -> Path:
    """应用数据根目录（跨平台，见 core/paths.py；开发模式为 backend/）。"""
    from editor.core.paths import app_data_dir
    return Path(app_data_dir())


def user_mods_dir() -> Path:
    from editor.core.steam_paths import user_mods_dir as _impl
    return Path(_impl())


def steam_library_paths() -> list[Path]:
    from editor.core.steam_paths import steam_library_paths as _impl
    return [Path(p) for p in _impl()]


def workshop_mods_roots() -> list[Path]:
    from editor.core.steam_paths import workshop_mods_roots as _impl
    return [Path(p) for p in _impl()]


def resolve_workspace(cli_root: str | None) -> Path:
    if cli_root:
        p = Path(cli_root).expanduser().resolve()
        if not p.is_dir():
            raise SystemExit(f"workspace not found: {p}")
        return p
    # try env file
    er = editor_root()
    env_path = er / "editor_env.json"
    if env_path.exists():
        try:
            data = json.loads(env_path.read_text(encoding="utf-8-sig"))
            ws = data.get("workspace_root") or data.get("workspace") or ""
            if ws and Path(ws).is_dir():
                return Path(ws)
        except Exception:
            pass
    # fallback
    fallback = user_mods_dir()
    if fallback.is_dir():
        return fallback
    return er


# ---------------------------------------------------------------------------
# Mod helpers
# ---------------------------------------------------------------------------

def mod_info(name: str, mod_dir: Path):
    cfg_dir = mod_dir / "Cfgs" / "zh-cn"
    cfg_files = []
    if cfg_dir.is_dir():
        for f in sorted(cfg_dir.iterdir()):
            if f.suffix == ".json" and f.name != "CustomKeyMap.json":
                cfg_files.append(f.stem)
    manifest = {}
    mpath = mod_dir / "manifest.json"
    if mpath.is_file():
        try:
            manifest = json.loads(mpath.read_text(encoding="utf-8-sig"))
        except Exception:
            manifest = {}
    return {
        "name": name,
        "root": str(mod_dir),
        "cfg_files": cfg_files,
        "has_manifest": bool(manifest),
        "manifest_title": manifest.get("title", "") if isinstance(manifest, dict) else "",
        "manifest": manifest if isinstance(manifest, dict) else {},
    }


def list_mods(workspace: Path | str | None = None):
    ws = Path(workspace) if workspace else resolve_workspace(None)
    roots: list[Path] = []
    if ws and Path(ws).is_dir():
        roots.append(Path(ws))
    er = editor_root()
    if (er / "Cfgs" / "zh-cn").is_dir():
        roots.append(er)
    for r in workshop_mods_roots():
        roots.append(Path(r))
    seen, mods = set(), []
    for base in roots:
        if not base.is_dir():
            continue
        nb = os.path.normpath(str(base))
        if nb in seen:
            continue
        seen.add(nb)
        try:
            names = sorted(os.listdir(base))
        except OSError:
            continue
        for name in names:
            mod_dir = base / name
            if not mod_dir.is_dir():
                continue
            cfg_dir = mod_dir / "Cfgs" / "zh-cn"
            manifest = mod_dir / "manifest.json"
            if not (cfg_dir.is_dir() or manifest.is_file()):
                continue
            mods.append(mod_info(name, mod_dir))
    return mods


def find_mod(name: str, workspace: Path | None = None):
    for m in list_mods(workspace):
        if m["name"] == name:
            return m
    return None


def cfg_name_normalize(raw: str) -> str:
    raw = raw.strip()
    if not raw:
        return raw
    # exact
    if raw in _CFG_KEY_MAP.values():
        return raw
    low = raw.lower()
    if low in _CFG_KEY_MAP:
        return _CFG_KEY_MAP[low]
    # prefix match
    best = ""
    for pfx in _CFG_PREFIXES:
        if low.startswith(pfx) and len(pfx) > len(best):
            best = pfx
    if best:
        return _CFG_KEY_MAP[best]
    # try removing .json
    if low.endswith(".json"):
        return cfg_name_normalize(low[:-5])
    return raw


class CfgParseError(Exception):
    """Raised when cfg JSON is invalid even after lenient fixes."""
    pass


def _parse_cfg_text(text: str, path: Path | None = None):
    """Lenient JSON parse: handles trailing commas, // comments, /* */."""
    # fast path
    try:
        return json.loads(text)
    except Exception as e1:
        # try cleaning: strip comments and trailing commas (mirrors base_service._clean_cfg_json)
        cleaned = re.sub(r"//.*", "", text)
        cleaned = re.sub(r"/\*.*?\*/", "", cleaned, flags=re.DOTALL)
        cleaned = re.sub(r",\s*([\]}])", r"\1", cleaned)
        cleaned = cleaned.strip()
        # fix edge: ",}" at end already handled, also handle ",]" 
        if cleaned.endswith(",}"):
            cleaned = cleaned[:-2] + "}"
        if cleaned.endswith(",]"):
            cleaned = cleaned[:-2] + "]"
        try:
            return json.loads(cleaned)
        except Exception as e2:
            # give up, raise with original error for diagnostics
            raise CfgParseError(f"JSON parse failed {path}: {e1}\nHint: run 'cfg validate' to diagnose") from e2


def cfg_path(mod_root: Path | str, cfg_name: str) -> Path:
    cfg_name = cfg_name_normalize(cfg_name)
    return Path(mod_root) / "Cfgs" / "zh-cn" / f"{cfg_name}.json"


def load_cfg(mod_root: Path | str, cfg_name: str, *, strict: bool = False):
    """Load cfg file.  strict=False enables lenient trailing-comma fix.

    Returns (data, path, exists).  On parse failure raises CfgParseError
    (callers should handle and not crash the TUI).
    """
    cfg_name = cfg_name_normalize(cfg_name)
    path = cfg_path(mod_root, cfg_name)
    if not path.is_file():
        return None, path, False
    try:
        text = path.read_text(encoding="utf-8-sig").strip()
    except OSError as e:
        raise CfgParseError(f"read failed {path}: {e}") from e
    if not text:
        return {}, path, True
    data = _parse_cfg_text(text, path) if not strict else json.loads(text)
    if not isinstance(data, dict):
        return {}, path, True
    return data, path, True


def save_cfg(mod_root: Path | str, cfg_name: str, data: dict):
    cfg_name = cfg_name_normalize(cfg_name)
    path = cfg_path(mod_root, cfg_name)
    path.parent.mkdir(parents=True, exist_ok=True)
    # keep a one-generation .bak so a bad write can be undone manually
    bak = None
    try:
        if path.is_file():
            bak = path.with_suffix(path.suffix + ".bak")
            bak.write_text(path.read_text(encoding="utf-8-sig"), encoding="utf-8")
    except Exception:
        bak = None
    tmp = path.with_suffix(path.suffix + f".tmp_{os.getpid()}")
    tmp.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
    tmp.replace(path)
    return path


def default_record(cfg_name: str, rid: str | int | None = None) -> dict:
    """Build a skeleton record filled with schema defaults (mirrors TUI 'n' key)."""
    schema = load_schema()
    fields = schema.get(cfg_name_normalize(cfg_name)) or {}
    rec: dict = {}
    for f, typ in fields.items():
        if f == "id" and rid is not None:
            rec[f] = int(rid) if str(rid).isdigit() else rid
        elif typ == "Number":
            rec[f] = 0
        elif typ in ("1D Array", "2D Array"):
            rec[f] = []
        else:
            rec[f] = ""
    if rid is not None and "id" not in rec:
        try:
            rec["id"] = int(rid)
        except (TypeError, ValueError):
            rec["id"] = rid
    return rec


def load_schema():
    try:
        from editor.core.game_schema import GAME_SCHEMA as GS
        return GS
    except Exception:
        return {}


def validate_cfg(cfg_name: str, data: dict):
    """Light validation against GAME_SCHEMA. Returns list of (level, msg)."""
    schema = load_schema()
    cfg_name = cfg_name_normalize(cfg_name)
    if cfg_name not in schema:
        return [("warn", f"unknown cfg '{cfg_name}' – no schema, skip strict check")]
    fields = schema[cfg_name]
    issues = []
    if not isinstance(data, dict):
        return [("error", "cfg root must be object/dict")]
    for rid, record in data.items():
        if not isinstance(record, dict):
            issues.append(("warn", f"{rid}: record is not object, got {type(record).__name__}"))
            continue
        for k, v in record.items():
            if k not in fields:
                issues.append(("warn", f"{rid}.{k}: unknown field for {cfg_name}"))
        # check expected types loosely
        for f, typ in fields.items():
            if f not in record:
                continue
            val = record[f]
            if typ == "String" and not isinstance(val, str):
                issues.append(("warn", f"{rid}.{f}: expect String got {type(val).__name__}"))
            elif typ == "Number" and not isinstance(val, (int, float)):
                issues.append(("warn", f"{rid}.{f}: expect Number got {type(val).__name__}"))
            elif typ == "1D Array" and not isinstance(val, list):
                issues.append(("warn", f"{rid}.{f}: expect 1D Array got {type(val).__name__}"))
            elif typ == "2D Array" and not isinstance(val, list):
                issues.append(("warn", f"{rid}.{f}: expect 2D Array got {type(val).__name__}"))
    # 指南语义层校验（官方《学生时代》Mod指南：ID 格式、发生概率、屏幕效果/动作指令等）
    try:
        from editor.core.guide_rules import validate_record as _guide_validate_record
    except Exception:
        _guide_validate_record = None
    if _guide_validate_record is not None:
        for rid, record in data.items():
            if not isinstance(record, dict):
                continue
            try:
                issues.extend(_guide_validate_record(cfg_name, rid, record))
            except Exception:
                continue  # 指南规则异常时静默跳过，不影响基础类型校验
    return issues


def suggest_next_id(cfg_name: str, data: dict, base_ids: dict | None = None):
    """为新记录建议一个符合官方指南的下一个 ID。

    转发 editor.core.guide_rules.suggest_next_id；任何异常时返回 None（调用方自行回退）。
    """
    try:
        from editor.core.guide_rules import suggest_next_id as _impl
        return _impl(cfg_name, data, base_ids)
    except Exception:
        return None


def _levenshtein(a: str, b: str, cap: int = 4) -> int:
    """Small DP edit distance, early-exit once distance exceeds cap."""
    a, b = a.lower(), b.lower()
    if a == b:
        return 0
    la, lb = len(a), len(b)
    if abs(la - lb) > cap:
        return cap + 1
    prev = list(range(lb + 1))
    for i in range(1, la + 1):
        cur = [i] + [0] * lb
        best = cur[0]
        for j in range(1, lb + 1):
            cost = 0 if a[i - 1] == b[j - 1] else 1
            cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
            if cur[j] < best:
                best = cur[j]
        if best > cap:
            return cap + 1
        prev = cur
    return prev[lb]


def fuzzy_suggest(query: str, candidates, limit: int = 3) -> list[str]:
    """Return up to `limit` candidates closest to query (case-insensitive).

    Prefix/substring matches rank first regardless of edit distance (so
    typing 'evtc' suggests EvtCfg), followed by small-edit-distance typos;
    used to build "did you mean ..." hints.
    """
    q = (query or "").strip().lower()
    if not q or not candidates:
        return []
    scored = []
    for c in candidates:
        s = str(c)
        low = s.lower()
        if low.startswith(q):
            scored.append((0, 0, s))
            continue
        if q in low:
            scored.append((1, 0, s))
            continue
        d = _levenshtein(q, low)
        if d <= (1 if len(q) < 5 else 2):
            scored.append((2, d, s))
    scored.sort(key=lambda t: (t[0], t[1], t[2]))
    out = [s for _, _, s in scored]
    # de-dup preserving order
    seen: set[str] = set()
    dedup = []
    for s in out:
        k = s.lower()
        if k not in seen:
            seen.add(k)
            dedup.append(s)
    return dedup[:limit]


def search_in_mod(mod_root: Path | str, keyword: str, cfg_filter: str | None = None):
    mod_root = Path(mod_root)
    cfg_dir = mod_root / "Cfgs" / "zh-cn"
    if not cfg_dir.is_dir():
        return []
    keyword_lower = keyword.lower()
    results = []
    for jf in sorted(cfg_dir.glob("*.json")):
        if jf.name == "CustomKeyMap.json":
            continue
        cname = jf.stem
        if cfg_filter and cfg_name_normalize(cfg_filter) != cname:
            continue
        try:
            text = jf.read_text(encoding="utf-8-sig")
            # fast pre-filter: skip parse entirely when keyword absent from file
            if keyword_lower and keyword_lower not in text.lower():
                continue
            data = json.loads(text) if text.strip() else {}
        except Exception:
            # fallback to raw search
            try:
                text = jf.read_text(encoding="utf-8-sig", errors="replace")
                if keyword_lower in text.lower():
                    results.append({"cfg": cname, "id": "-", "hit": "raw file match", "snippet": text[:200]})
            except Exception:
                pass
            continue
        for rid, rec in data.items() if isinstance(data, dict) else []:
            blob = json.dumps(rec, ensure_ascii=False).lower()
            if keyword_lower in rid.lower() or keyword_lower in blob:
                snippet = json.dumps(rec, ensure_ascii=False)[:300]
                results.append({"cfg": cname, "id": str(rid), "hit": keyword, "snippet": snippet})
            # also show field-level hits for precision
    return results
