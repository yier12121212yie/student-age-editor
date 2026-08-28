# -*- coding: utf-8 -*-
"""本体（原版游戏）配置数据服务：原版配置表加载、事件检索、事件提取、台词全文搜索。

纯逻辑实现，逻辑剥离自友商 Qt 客户端（app.py 的 load_base_game_env / ui/pages/evt.py
的 BaseStoryImporterDialog 与 FullTextSearchDialog），无任何 GUI 依赖，供 HTTP API 层复用。
"""
import copy
import hashlib
import json
import os
import pickle
import re
import threading
try:
    from editor.server import resource_pack
except Exception:
    resource_pack = None

# ---------------- 配置表识别常量（复制自 app.py） ----------------

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
    """清洗配置表内容：繁体/多语言内容返回 None；脏 JSON 强洗后返回 dict。"""
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


def _nat_key(value):
    """自然排序键：数字部分按数值比较（等价于友商 robust_sort）。"""
    parts = re.split(r"(\d+)", str(value))
    out = []
    for p in parts:
        if p.isdigit():
            out.append((1, int(p)))
        else:
            out.append((0, p))
    return out


def _stat_parts(paths):
    parts = []
    for p in paths or []:
        if not p or not os.path.exists(p):
            continue
        if os.path.isdir(p):
            try:
                for f in sorted(os.listdir(p)):
                    fp = os.path.join(p, f)
                    if not os.path.isfile(fp):
                        continue
                    st = os.stat(fp)
                    parts.append((p, f, st.st_mtime_ns, st.st_size))
            except Exception:
                pass
        else:
            try:
                st = os.stat(p)
                parts.append((p, st.st_mtime_ns, st.st_size))
            except Exception:
                pass
    return parts


class BaseDataService(object):
    """原版配置数据的加载与查询。线程安全（读操作在加载完成后进行）。"""

    def __init__(self, editor_root, cache_root):
        self.editor_root = editor_root
        self.cache_root = cache_root
        self._lock = threading.Lock()
        self.data = {}            # 表名 -> {id: record}
        self.status = "idle"      # idle | loading | ready | error
        self.error = ""
        self.dirs = []            # 实际使用的 cfg 目录 / bundle 目录
        self.loaded_keys = []
        self.missing_keys = []
        self._load_thread = None

    # ---------------- 环境配置 ----------------

    def env_path(self):
        return os.path.join(self.editor_root, "editor_env.json")

    def load_env(self):
        """读取编辑器环境配置（editor_env.json），失败返回空 dict。"""
        try:
            with open(self.env_path(), "r", encoding="utf-8-sig") as f:
                env = json.load(f)
            return env if isinstance(env, dict) else {}
        except Exception:
            return {}

    def cfg_dirs_from_env(self, env):
        """根据 env 解析原版配置表目录列表（studio / ripper 模式）。"""
        dirs = []
        mode = env.get("mode", "studio")
        if mode == "ripper":
            for d in (env.get("ripper_base_dir", ""), env.get("ripper_dlc_dir", "")):
                if not d or not os.path.exists(d):
                    continue
                p1 = os.path.join(d, "ExportedProject", "Assets", "Res", "Cfgs", "zh-cn")
                p2 = os.path.join(d, "ExportedProject", "Assets", "Res", "Cfgs", "DLC_zh-cn")
                if os.path.isdir(p1):
                    dirs.append(p1)
                if os.path.isdir(p2):
                    dirs.append(p2)
        else:
            b_dir = env.get("base_game_dir", "")
            if b_dir:
                # 标准布局为 <base>/Cfgs/zh-cn 与 <base>/Cfgs/DLC_zh-cn；
                # 后三个保留兼容用户把 base_game_dir 直接指到更深一层的旧配置
                for sub in ("TextAsset", "Cfgs/zh-cn", "Cfgs/DLC_zh-cn", "Cfgs", "zh-cn", "DLC_zh-cn"):
                    p = os.path.join(b_dir, *sub.split("/"))
                    if os.path.isdir(p):
                        dirs.append(p)
        seen = set()
        return [d for d in dirs if not (d in seen or seen.add(d))]

    def bundle_dirs_from_env(self, env):
        """根据 env 解析 AA bundle 目录列表（aa 模式）。"""
        dirs = []
        seen = set()
        for d in (env.get("bundle_dirs") or []):
            if not isinstance(d, str) or not d:
                continue
            p = d if os.path.isabs(d) else os.path.normpath(os.path.join(self.editor_root, d))
            if p not in seen:
                seen.add(p)
                dirs.append(p)
        return dirs

    # ---------------- 加载 ----------------

    def load(self, env=None, aa_index_factory=None, force=False):
        """加载原版配置表。

        env：editor_env.json 内容（None 则自动读取）。
        aa_index_factory：可调用，返回 UnityFsIndex 实例（aa 模式使用）；None 时自动构建。
        force：True 时忽略磁盘缓存。
        返回 (loaded_keys, missing_keys, errors)。
        """
        with self._lock:
            if self.status == "loading":
                return self.loaded_keys, self.missing_keys, []
            self.status = "loading"
            self.error = ""
            self.loaded_keys = []
            self.missing_keys = []

        env = env if env is not None else self.load_env()
        mode = env.get("mode", "studio")
        cfgs_dirs = self.cfg_dirs_from_env(env) if mode != "aa" else []
        bundle_dirs = self.bundle_dirs_from_env(env) if mode == "aa" else []

        try:
            fp = self._fingerprint(cfgs_dirs, bundle_dirs, env)
            if not force:
                cached = self._try_cache(fp)
                if cached is not None:
                    with self._lock:
                        self.data = cached
                        self.dirs = list(cfgs_dirs or bundle_dirs)
                        self.loaded_keys = sorted(cached.keys())
                        self.status = "ready"
                    return self.loaded_keys, self.missing_keys, []

            errors = []
            if mode == "aa":
                loaded, errors = self._load_from_aa(bundle_dirs, aa_index_factory)
                if not loaded:
                    # Fallback to resource pack when AA not available (Android/Linux 无游戏)
                    try:
                        pk_loaded, pk_err = self._load_from_pack()
                        if pk_loaded:
                            loaded, errors = pk_loaded, pk_err
                    except Exception:
                        pass
            else:
                loaded, errors = self._load_from_dirs(cfgs_dirs)
                if not loaded:
                    try:
                        pk_loaded, pk_err = self._load_from_pack()
                        if pk_loaded:
                            loaded, errors = pk_loaded, pk_err
                    except Exception:
                        pass
            expected = set(_CFG_KEY_MAP.values())
            missing = sorted(expected - set(loaded))
            self._save_cache(fp, {k: self.data[k] for k in loaded if k in self.data})
            with self._lock:
                self.loaded_keys = loaded
                self.missing_keys = missing
                self.dirs = list(cfgs_dirs or bundle_dirs)
                self.status = "ready"
            return loaded, missing, errors
        except Exception as e:
            with self._lock:
                self.status = "error"
                self.error = "%s: %s" % (type(e).__name__, e)
            return [], list(_CFG_KEY_MAP.values()), [str(e)]

    def load_async(self, env=None, aa_index_factory=None, force=False, done_cb=None):
        """后台线程加载，不阻塞调用方。"""
        if self.status == "loading":
            return False
        self._load_thread = threading.Thread(
            target=lambda: self._run_async(env, aa_index_factory, force, done_cb),
            daemon=True,
        )
        self._load_thread.start()
        return True

    def _run_async(self, env, aa_index_factory, force, done_cb):
        try:
            self.load(env=env, aa_index_factory=aa_index_factory, force=force)
        finally:
            if done_cb:
                done_cb()

    # ---------------- 内部实现 ----------------

    def _fingerprint(self, cfgs_dirs, bundle_dirs, env):
        parts = _stat_parts([self.env_path()])
        seen = set()
        for d in list(cfgs_dirs) + list(bundle_dirs):
            if d in seen or not os.path.isdir(d):
                continue
            seen.add(d)
            parts.extend(_stat_parts([d]))
        digest = hashlib.sha1()
        for x in parts:
            digest.update(str(x).encode("utf-8", "ignore"))
        digest.update(str(env.get("mode", "studio")).encode("utf-8", "ignore"))
        return digest.hexdigest()

    def _cache_path(self):
        try:
            os.makedirs(self.cache_root, exist_ok=True)
        except Exception:
            pass
        return os.path.join(self.cache_root, "base_data.pkl")

    def _try_cache(self, fp):
        try:
            with open(self._cache_path(), "rb") as f:
                cached = pickle.load(f)
        except Exception:
            return None
        if not isinstance(cached, dict) or cached.get("fp") != fp:
            return None
        data = cached.get("data")
        return data if isinstance(data, dict) else None

    def _save_cache(self, fp, data_map):
        try:
            tmp = self._cache_path() + ".tmp"
            with open(tmp, "wb") as f:
                pickle.dump({"fp": fp, "data": data_map}, f, protocol=pickle.HIGHEST_PROTOCOL)
            os.replace(tmp, self._cache_path())
        except Exception:
            pass


    def _load_from_pack(self):
        """从资源扩展包加载 base_data（兼容无游戏的 Android/Linux）"""
        if resource_pack is None:
            return set(), []
        d = resource_pack.get_active_dir()
        if not d or not __import__("os").path.isdir(d):
            return set(), []
        loaded = set()
        errors = []
        # 1) base_data.json 合并
        import json as _json, os as _os
        bd = _os.path.join(d, "base_data.json")
        if _os.path.isfile(bd):
            try:
                with open(bd, "r", encoding="utf-8-sig") as f:
                    data = _json.load(f)
                if isinstance(data, dict):
                    for k, v in data.items():
                        if isinstance(v, dict):
                            bucket = self.data.setdefault(k, {})
                            bucket.update(v)
                            loaded.add(k)
            except Exception as e:
                errors.append("[base_data.json] %s" % e)
        # 2) Cfgs/zh-cn 分散
        for sub in ("Cfgs/zh-cn", "Cfgs", "cfgs"):
            cd = _os.path.join(d, sub)
            if not _os.path.isdir(cd):
                continue
            try:
                for f in _os.listdir(cd):
                    if not f.lower().endswith((".json", ".txt")):
                        continue
                    if any(x in f.lower() for x in _CFG_LANG_BAD_TOKENS):
                        continue
                    cfg_name = _match_prefix(f)
                    if not cfg_name:
                        continue
                    try:
                        with open(_os.path.join(cd, f), "r", encoding="utf-8-sig", errors="ignore") as fp:
                            content = fp.read()
                        data = _clean_cfg_json(content)
                        if data is None:
                            continue
                        bucket = self.data.setdefault(cfg_name, {})
                        bucket.update(data)
                        loaded.add(cfg_name)
                    except Exception as e:
                        errors.append("[%s] %s" % (f, e))
            except Exception as e:
                errors.append("pack dir %s %s" % (cd, e))
            if loaded:
                break
        return sorted(loaded), errors

    def _load_from_dirs(self, cfgs_dirs):
        """从解包目录加载配置表（studio / ripper 模式）。返回 (loaded_keys, errors)。"""
        loaded = set()
        errors = []
        for c_dir in cfgs_dirs:
            if not os.path.exists(c_dir):
                continue
            try:
                for f in os.listdir(c_dir):
                    if not f.lower().endswith((".json", ".txt")):
                        continue
                    if any(x in f.lower() for x in _CFG_LANG_BAD_TOKENS):
                        continue
                    cfg_name = _match_prefix(f)
                    if not cfg_name:
                        continue
                    try:
                        with open(os.path.join(c_dir, f), "r", encoding="utf-8-sig", errors="ignore") as fp:
                            content = fp.read()
                        data = _clean_cfg_json(content)
                        if data is None:
                            continue
                        bucket = self.data.setdefault(cfg_name, {})
                        bucket.update(data)
                        loaded.add(cfg_name)
                    except Exception as e:
                        errors.append("[%s] 读取异常: %s" % (f, e))
            except Exception as e:
                errors.append("遍历目录 %s 失败: %s" % (c_dir, e))
        return sorted(loaded), errors

    def _load_from_aa(self, bundle_dirs, aa_index_factory):
        """从 Addressables 的 TextAsset 加载配置表（aa 模式）。"""
        loaded = set()
        errors = []
        if aa_index_factory is None:
            try:
                from editor.services.unityfs_res import UnityFsIndex, detect_game_aa_dir
            except Exception:
                return [], ["unityfs 不可用"]
            dirs = list(bundle_dirs)
            detected = detect_game_aa_dir()
            if detected and detected not in dirs:
                dirs.insert(0, detected)
            idx = UnityFsIndex(dirs, cache_root=os.path.join(self.cache_root, "aa_index"))
            idx.scan()
        else:
            idx = aa_index_factory()
        for key in idx.txt_keys():
            if any(x in key.lower() for x in _CFG_LANG_BAD_TOKENS):
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
                if data is None:
                    continue
                bucket = self.data.setdefault(cfg_name, {})
                bucket.update(data)
                loaded.add(cfg_name)
            except Exception as e:
                errors.append("[%s] 解析异常: %s" % (key, e))
        return sorted(loaded), errors

    # ---------------- 查询 ----------------

    def status_dict(self):
        with self._lock:
            return {
                "status": self.status,
                "error": self.error,
                "dirs": list(self.dirs),
                "loaded": list(self.loaded_keys),
                "missing": list(self.missing_keys),
                "env_path": self.env_path(),
                "env_exists": os.path.isfile(self.env_path()),
            }

    def search_events(self, keyword="", npc_id=None, evt_type=None, page=1, per_page=50):
        """检索原版事件列表（对应友商 BaseStoryImporterDialog 的过滤逻辑），带预计算索引与缓存。"""
        # 懒初始化索引：标题有效性、title_lower、标题长度等
        if not hasattr(self, "_evt_index"):
            self._evt_index = None
            self._evt_index_fp = None
        b_evt = self.data.get("EvtCfg", {}) or {}
        # 指纹：数量或任一被索引字段（title/npc/type）变化即重建索引
        # （旧实现只取记录数，编辑标题后索引不会刷新，搜索结果陈旧）
        h = 0
        for k, v in b_evt.items():
            if isinstance(v, dict):
                h ^= hash((str(k), str(v.get("title", "")), str(v.get("npc")), str(v.get("type"))))
            else:
                h ^= hash((str(k), "", "", ""))
        fp = (len(b_evt), h)
        if self._evt_index is None or self._evt_index_fp != fp:
            idx = []
            for e_id, obj in b_evt.items():
                if not isinstance(obj, dict):
                    continue
                title = str(obj.get("title", "") or "")
                if not title.strip() or title.strip() == "未命名":
                    continue
                sid = str(e_id)
                # 预计算：小写标题、npc 集合字符串、type 字符串、排序键
                idx.append({
                    "id": sid,
                    "title": title,
                    "title_lower": title.lower(),
                    "npc": obj.get("npc", []),
                    "npc_set": {str(x) for x in (obj.get("npc", []) if isinstance(obj.get("npc", []), list) else ([obj.get("npc")] if obj.get("npc") else []))},
                    "type": str(obj.get("type", 0)),
                    "sort_key": _nat_key(sid),
                })
            idx.sort(key=lambda x: x["sort_key"])
            self._evt_index = idx
            self._evt_index_fp = fp
        kw = (keyword or "").strip().lower()
        kw_is_digit = kw.isdigit() if kw else False
        out = []
        for rec in self._evt_index:
            if kw:
                if kw_is_digit:
                    if not rec["id"].startswith(kw):
                        continue
                elif kw not in rec["title_lower"]:
                    continue
            if npc_id not in (None, "", "0"):
                if str(npc_id) not in rec["npc_set"]:
                    continue
            if evt_type not in (None, "", "0"):
                if rec["type"] != str(evt_type):
                    continue
            out.append({
                "id": rec["id"],
                "title": rec["title"],
                "npc": rec["npc"],
                "type": rec["type"],
            })
        total = len(out)
        page = max(1, int(page or 1))
        per_page = max(1, min(200, int(per_page or 50)))
        start = (page - 1) * per_page
        return {"total": total, "page": page, "per_page": per_page,
                "events": out[start:start + per_page]}

    def infer_evt_id(self, talk_id, evt_dict):
        """由对话 ID 推断归属事件 ID（对应友商 get_evt_info）。"""
        tid = str(talk_id)
        guess = tid[:-3] if len(tid) > 3 else tid
        if guess in evt_dict:
            return guess, evt_dict[guess].get("title", "未知")
        guess2 = tid[:-2] if len(tid) > 2 else tid
        if guess2 in evt_dict:
            return guess2, evt_dict[guess2].get("title", "未知")
        return guess, "未知/通用"

    def search_talks(self, keyword, mod_talk=None, mod_evt=None, limit=150):
        """台词全文搜索（对应友商 FullTextSearchDialog）：在本体 + Mod 台词中检索。"""
        kw = (keyword or "").strip()
        if not kw:
            return []
        b_evt = self.data.get("EvtCfg", {}) or {}
        m_evt = mod_evt or {}
        results = []
        for src, evt_dict, talk_dict in (
            ("本体", b_evt, self.data.get("TalkCfg", {}) or {}),
            ("Mod", m_evt, mod_talk or {}),
        ):
            if not isinstance(talk_dict, dict):
                continue
            for tid, tdata in talk_dict.items():
                if not isinstance(tdata, dict):
                    continue
                content = str(tdata.get("content", "") or "")
                if not content or content == "None" or kw not in content:
                    continue
                eid, title = self.infer_evt_id(str(tid), evt_dict)
                results.append({
                    "src": src, "evt_id": eid, "evt_title": title,
                    "talk_id": str(tid), "content": content,
                })
        results.sort(key=lambda x: (0 if x["content"] == kw else len(x["content"])))
        return results[:limit]

    def extract_event(self, evt_id):
        """提取原版事件及其对白/选项（对应友商 copy_base_event_to_mod）。

        返回增量数据 {表名: {id: record}}；事件不存在时返回空 dict。
        """
        evt_id = str(evt_id)
        delta = {}
        b_evt = self.data.get("EvtCfg", {}) or {}
        if evt_id not in b_evt:
            return delta
        delta["EvtCfg"] = {evt_id: copy.deepcopy(b_evt[evt_id])}
        b_talk = self.data.get("TalkCfg", {}) or {}
        talks = {str(k): v for k, v in b_talk.items() if str(k).startswith(evt_id)}
        if talks:
            delta["TalkCfg"] = copy.deepcopy(talks)
        b_opt = self.data.get("OptionCfg", {}) or {}
        opts = {str(k): v for k, v in b_opt.items() if str(k).startswith(evt_id)}
        if opts:
            delta["OptionCfg"] = copy.deepcopy(opts)
        return delta
