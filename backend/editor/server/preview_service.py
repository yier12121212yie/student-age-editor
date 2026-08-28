# -*- coding: utf-8 -*-
"""事件场景预览服务：把事件（EvtCfg）+ 对白链（TalkCfg）+ 选项（OptionCfg）
组装成可在编辑器内渲染的「游戏场景」数据（背景 / 立绘 / 角色名 / 资源 key 映射）。

数据源优先级：当前 Mod 配置表 → 游戏本体 AA（TextAsset）→ data_dicts 内置字典。
本模块不依赖 HTTP，可被 selftest / API 路由直接调用。
"""
import json
import os
import threading

try:
    from editor.core.data_dicts import (
        ROLE_DICT as _ROLE_DICT, BG_DICT as _BG_DICT,
        EVT_TYPE_DICT as _EVT_TYPE_DICT,
    )
except Exception:
    _ROLE_DICT = {}
    _BG_DICT = {}
    _EVT_TYPE_DICT = {}

# 对白链展开上限（防环 / 防超大事件拖垮预览）
_MAX_TALKS = 800
# 舞台动作类型（与 stage_service.STAGE_ACTIONS 保持一致）
_ACT_ENTER = {1001, 1002, 1003}   # 入场（滑动/直接/底部），参数 [1, 站位]
_ACT_LEAVE = {2001, 2002}         # 退场（滑动/直接）
_ACT_EXPR = {3000}                # 表情，参数 [表情ID]
_ACT_CLOTH = {3006}               # 换装，参数 [服装ID]
_ACT_FLIP = {3007}                # 镜像
_POS_MAP = {1: "left", 2: "right", 3: "center"}


def _clean_id(v):
    """id 规范化：213.0 → 213（JSON 中数字可能为 float 形式）。"""
    try:
        f = float(v)
        if f.is_integer():
            return str(int(f))
    except (TypeError, ValueError):
        pass
    return str(v)

_lock = threading.RLock()  # RLock：load_table 持锁时 _load_aa_index 可重入
_table_cache = {}   # 表名 -> {id: record}（仅缓存 mod 未覆盖且非 None 的结果）
_aa_cache = None    # UnityFsIndex 实例（懒加载）
# 指纹/缓存：PersonCfg/BGCfg 合并后的 meta 与单表读盘
_mod_fp_cache = {}      # cfg名 -> (fp_key, data)  fp_key=(mtime_ns,size) 或 None
_meta_cache = None      # 已构建的 meta
_meta_fp = None         # meta 指纹：(person_fp, bg_fp)


def _norm_tex_key(k):
    """把配置表里的资源名规范成 AA 索引 key 的格式（与 unityfs_res._norm_key 一致）。

    AA 索引的 tex/aud/txt key 统一为：去扩展名、去 " #" 后缀、小写、去首尾空白。
    配置表（PersonCfg/BGCfg）里的 url 大小写可能与资源名不一致（如
    role_student_zhongxueF_12 → role_student_zhongxuef_12），预览返回给前端的
    key 统一用规范形式，保证 /api/aa/preview 可直接命中。
    """
    if not k:
        return k
    return os.path.splitext(str(k))[0].split(" #")[0].strip().lower()


# ---------------------------------------------------------------------------
# 配置表加载：mod 优先，回退本体 AA
# ---------------------------------------------------------------------------

def _load_aa_index():
    """懒加载 AA 索引（本体资源）。优先复用 STATE.aa_index，否则用磁盘缓存。"""
    global _aa_cache
    if _aa_cache is not None:
        return _aa_cache
    with _lock:
        if _aa_cache is not None:
            return _aa_cache
        idx = None
        try:
            from editor.server.api import STATE
            idx = STATE.aa_index
        except Exception:
            pass
        if idx is None:
            try:
                from editor.services.unityfs_res import UnityFsIndex, detect_game_aa_dir
                editor_root = None
                try:
                    from editor.server.api import _editor_root
                    editor_root = _editor_root()
                except Exception:
                    pass
                cache_root = os.path.join(editor_root or "", "_cache", "aa_index")
                dirs = []
                detected = detect_game_aa_dir()
                if detected:
                    dirs.append(detected)
                idx = UnityFsIndex(dirs, cache_root=cache_root)
                idx.try_load_cached()
                # 缓存可能缺角色立绘 bundle（默认扫描跳过），触发后台补扫
                try:
                    from editor.server.api import _ensure_role_bundles
                    _ensure_role_bundles(idx, dirs)
                except Exception:
                    pass
            except Exception:
                idx = None
        # Fallback: try resource pack aa_index.json when no game bundles
        if (idx is None or (hasattr(idx, 'tex_keys') and len(idx.tex_keys())==0)):
            try:
                from editor.server import resource_pack as _rp2
                d2 = _rp2.get_active_dir()
                if d2:
                    import os as _os2, json as _json2
                    aj = _os2.path.join(d2, "aa_index.json")
                    if _os2.path.isfile(aj):
                        with open(aj, "r", encoding="utf-8") as f2:
                            j2 = _json2.load(f2)
                        # 构造轻量索引对象，仅用于 txt 查询
                        class _PackIdx:
                            def __init__(self, data):
                                self._txt = {k.lower(): v for k,v in (data.get("txt") or {}).items()}
                                self._tex = {k.lower(): v for k,v in (data.get("tex") or {}).items()}
                                self._aud = {k.lower(): v for k,v in (data.get("aud") or {}).items()}
                            def has_txt(self, k): return k.lower() in self._txt
                            def has_tex(self, k): return k.lower() in self._tex
                            def has_aud(self, k): return k.lower() in self._aud
                            def tex_keys(self): return list(self._tex.keys())
                            def aud_keys(self): return list(self._aud.keys())
                            def txt_keys(self): return list(self._txt.keys())
                            def export_text(self, k):
                                import os as _os3
                                d3 = _rp2.get_active_dir()
                                # 尝试 base_data.json 或分散文件
                                for sub in ("Cfgs/zh-cn", "Cfgs"):
                                    fp = _os3.path.join(d3, sub, k + ".json")
                                    if _os3.path.isfile(fp):
                                        with open(fp, "rb") as ff:
                                            return ff.read()
                                bd = _os3.path.join(d3, "base_data.json")
                                if _os3.path.isfile(bd):
                                    import json as _j3
                                    with open(bd, "r", encoding="utf-8") as ff:
                                        bj = _j3.load(ff)
                                    if k in bj:
                                        return _j3.dumps(bj[k], ensure_ascii=False).encode()
                                    lk = k.lower()
                                    for kk, vv in bj.items():
                                        if kk.lower()==lk:
                                            return _j3.dumps(vv, ensure_ascii=False).encode()
                                return None
                            def preview_tex_png(self, k): return None
                            def preview_audio(self, k): return None
                            def export_tex_png(self, k, out): return False
                            def export_audio(self, k, out): return None
                        idx = _PackIdx(j2)
            except Exception:
                pass
        _aa_cache = idx
        return _aa_cache


def invalidate_cache():
    """外部失效：切换模组或写入 cfg 后调用，清空本文缓存。"""
    global _meta_cache, _meta_fp
    with _lock:
        _table_cache.clear()
        _mod_fp_cache.clear()
        _meta_cache = None
        _meta_fp = None


def _mod_file_fp(path):
    try:
        st = os.stat(path)
        return (st.st_mtime_ns, st.st_size)
    except OSError:
        return None


def _load_mod_cfg(name):
    """读取当前 mod 的配置表；未选模组/文件不存在返回 None（带 mtime 指纹缓存）。"""
    try:
        from editor.server.api import STATE
        if not STATE.mod_root:
            return None
        cfg_dir = STATE._cfg_dir()
        path = os.path.join(cfg_dir, name + ".json")
        if not os.path.isfile(path):
            with _lock:
                _mod_fp_cache.pop(name, None)
            return None
        fp = _mod_file_fp(path)
        with _lock:
            cached = _mod_fp_cache.get(name)
            if cached is not None and cached[0] == fp:
                return cached[1]
        with open(path, "r", encoding="utf-8-sig") as fp2:
            data = json.load(fp2)
        data = data if isinstance(data, dict) else None
        with _lock:
            _mod_fp_cache[name] = (fp, data)
        return data
    except Exception:
        return None


def _load_aa_cfg(name):
    """从本体 AA 读取配置表；不可用/不存在返回 None。"""
    try:
        idx = _load_aa_index()
        if idx is None:
            # Fallback to resource pack AA/BASE
            pack_data = _load_pack_cfg(name)
            if pack_data is not None:
                return pack_data
            return None
        key = str(name).lower()  # AA 索引的 txt key 为小写
        if not idx.has_txt(key):
            return None
        raw = idx.export_text(key)
        if not raw:
            return None
        data = json.loads(raw.decode("utf-8", errors="ignore"))
        return data if isinstance(data, dict) else None
    except Exception:
        return None



def _load_pack_cfg(name):
    """从资源扩展包读取配置（兼容无游戏）"""
    try:
        from editor.server import resource_pack as _rp
        d = _rp.get_active_dir()
        if not d:
            return None
        import os, json
        # 1) base_data.json
        bd = os.path.join(d, "base_data.json")
        if os.path.isfile(bd):
            try:
                with open(bd, "r", encoding="utf-8-sig") as f:
                    data = json.load(f)
                if isinstance(data, dict) and name in data:
                    v = data[name]
                    if isinstance(v, dict):
                        return v
            except Exception:
                pass
        # 2) Cfgs 分散
        for sub in ("Cfgs/zh-cn", "Cfgs", "cfgs"):
            fp = os.path.join(d, sub, name + ".json")
            if os.path.isfile(fp):
                try:
                    with open(fp, "r", encoding="utf-8-sig") as f:
                        data = json.load(f)
                    if isinstance(data, dict):
                        return data
                except Exception:
                    continue
        # 3) dicts.json 覆盖
        dj = os.path.join(d, "dicts.json")
        if os.path.isfile(dj):
            try:
                with open(dj, "r", encoding="utf-8") as f:
                    jd = json.load(f)
                if isinstance(jd, dict) and name in jd:
                    v = jd[name]
                    if isinstance(v, dict):
                        return v
            except Exception:
                pass
    except Exception:
        return None
    return None


def load_table(name):
    """配置表统一入口：mod → AA → {}（结果缓存，mod 优先保证实时性）。"""
    mod = _load_mod_cfg(name)
    if mod is not None:
        return mod
    with _lock:
        if name in _table_cache:
            return _table_cache[name]
        data = _load_aa_cfg(name) or {}
        if not data:
            data = _load_pack_cfg(name) or {}
        _table_cache[name] = data
        return data


def load_table_merged(name):
    """合并 mod + 本体配置表（mod 覆盖同名 id，本体兜底缺失 id）。

    用于角色名/背景等**元数据映射**：mod 常只覆盖少量自定义条目
    （如 BgCfg 只定义几个新背景），若只用 mod 数据，对白引用的本体
    背景/角色 id 会因查不到映射而丢失资源 key。合并后两类 id 都能解析。
    """
    mod = _load_mod_cfg(name)
    if mod is None:
        with _lock:
            if name in _table_cache:
                return _table_cache[name]
            data = _load_aa_cfg(name) or {}
            _table_cache[name] = data
            return data
    base = _load_aa_cfg(name) or {}
    if not base:
        base = _load_pack_cfg(name) or {}
    out = dict(base)
    out.update(mod)
    return out


def _record(table, rid):
    """取表中记录（id 支持 str/int）。"""
    v = table.get(str(rid))
    if v is None:
        v = table.get(rid)
    return v if isinstance(v, dict) else None


# ---------------------------------------------------------------------------
# 字典组装：角色名 / 背景 / 立绘 / 事件类型
# ---------------------------------------------------------------------------

def _build_meta():
    """返回预览所需的 id→名称 / id→资源 key 映射（mod + 本体合并，mod 覆盖同名），带指纹缓存。"""
    global _meta_cache, _meta_fp
    # 指纹：两张 mod 文件的 mtime/size
    try:
        from editor.server.api import STATE as _ST
        if _ST.mod_root:
            p1 = _mod_file_fp(os.path.join(_ST._cfg_dir(), "PersonCfg.json"))
            p2 = _mod_file_fp(os.path.join(_ST._cfg_dir(), "BgCfg.json"))
            fp = (p1, p2)
            with _lock:
                if _meta_cache is not None and _meta_fp == fp:
                    return _meta_cache
        else:
            fp = None
    except Exception:
        fp = None
    person = load_table_merged("PersonCfg")
    bg = load_table_merged("BgCfg")

    roles = dict(_ROLE_DICT)
    for rid, rec in person.items():
        if isinstance(rec, dict) and rec.get("name"):
            roles[str(rid)] = rec["name"]

    bgs = dict(_BG_DICT)
    bg_keys = {}
    for rid, rec in bg.items():
        url = rec.get("url") if isinstance(rec, dict) else None
        if not url:
            continue
        key = str(url)
        if key.startswith("bg/"):
            key = key[3:]
        # 保留原值（mod 自定义背景可能为文件路径）；查询时由索引侧规范化
        bg_keys[str(rid)] = key
        if isinstance(rec, dict) and rec.get("id") is not None and str(rec.get("id")) not in bgs:
            bgs[str(rec.get("id"))] = key  # 名称缺失时用 key 兜底展示

    # 立绘映射：base = 默认立绘，base2 = 表情变体前缀（表情 key = f"{base2}_{expr}"）
    char_keys = {}
    for rid, rec in person.items():
        if not isinstance(rec, dict):
            continue
        url = rec.get("url")
        url2 = rec.get("url2")
        base = url[0] if isinstance(url, list) and url and isinstance(url[0], str) else None
        base2 = url2[0] if isinstance(url2, list) and url2 and isinstance(url2[0], str) else None
        if not base and not base2:
            continue
        char_keys[str(rid)] = {
            "base": base or "",
            "base2": base2 or "",
            "l2d": rec.get("l2d") if isinstance(rec.get("l2d"), list) else [],
        }
    out = {
        "roles": roles,
        "bgs": bgs,
        "bgKeys": bg_keys,
        "charKeys": char_keys,
        "evtTypes": {str(k): v for k, v in _EVT_TYPE_DICT.items()},
    }
    # 缓存 meta（含指纹）
    try:
        with _lock:
            _meta_cache = out
            _meta_fp = fp
    except Exception:
        pass
    return out


# ---------------------------------------------------------------------------
# 舞台状态：跨对白维护立绘在场 / 站位 / 表情
# ---------------------------------------------------------------------------

def _pick_char_tex(ck, expr, idx):
    """选择立绘 tex key，按资源存在性回退：表情变体 → 基础立绘 → 变体前缀。

    - expr>0 且存在 base2：候选 `base2_expr`（表情变体）；
    - 变体缺失（如表达式编号超范围 / 该角色无变体）时回退 base；
    - base 为空或缺失（部分角色仅配置 url2）时用 base2 本身。
    AA 索引不可用（idx 为 None）时按原规则返回首个候选，
    由前端在加载失败时留空。返回值统一为索引规范 key（小写/去扩展名）。
    """
    base = ck.get("base") or ""
    base2 = ck.get("base2") or ""
    cands = []
    if expr and base2:
        cands.append("%s_%s" % (base2, expr))
    if base:
        cands.append(base)
    if base2 and not base:
        cands.append(base2)
    if not cands:
        return ""
    if idx is None:
        return _norm_tex_key(cands[0])
    for t in cands:
        try:
            if idx.has_tex(t):
                return _norm_tex_key(t)
        except Exception:
            return _norm_tex_key(cands[0])
    return _norm_tex_key(cands[0])


def _build_stage(talk, char_keys, prev_state, idx=None):
    """按该条对白的 roles 指令推导舞台快照（在 prev_state 基础上演进而非重建）。

    返回 (stage_dict, new_state)。stage_dict:
        {"bg": {"id":..., "key":...} | None, "chars": [{roleId,name,tex,pos,expr,flip}]}
    """
    state = dict(prev_state or {})
    roles = talk.get("roles") or []
    bg_id = talk.get("bg")

    for item in roles:
        if not isinstance(item, list) or len(item) < 2:
            continue
        try:
            tid = int(item[1])
        except (TypeError, ValueError):
            continue
        if tid in _ACT_ENTER:
            rid = _clean_id(item[0])
            pos = _POS_MAP.get(int(item[3]) if len(item) > 3 else 3, "center")
            st = state.setdefault(rid, {"pos": "center", "expr": 0, "flip": False})
            st["pos"] = pos
            st["present"] = True
        elif tid in _ACT_LEAVE:
            rid = _clean_id(item[0])
            st = state.get(rid)
            if st is not None:
                st["present"] = False
        elif tid in _ACT_EXPR:
            rid = _clean_id(item[0])
            try:
                expr = int(item[2]) if len(item) > 2 else 0
            except (TypeError, ValueError):
                expr = 0
            state.setdefault(rid, {"pos": "center", "expr": 0, "flip": False})["expr"] = expr
        elif tid in _ACT_CLOTH:
            # 换装：仅记录标记（立绘资源切换由前端按 cloth 处理，默认仍用 base）
            rid = _clean_id(item[0])
            state.setdefault(rid, {"pos": "center", "expr": 0, "flip": False})["cloth"] = True
        elif tid in _ACT_FLIP:
            rid = _clean_id(item[0])
            st = state.setdefault(rid, {"pos": "center", "expr": 0, "flip": False})
            st["flip"] = not st.get("flip", False)

    # 立绘 key 选择：表情变体优先，缺失时回退 base / base2（按索引存在性）
    chars = []
    for rid, st in state.items():
        if not st.get("present"):
            continue
        ck = char_keys.get(str(rid)) or {}
        expr = st.get("expr", 0)
        tex = _pick_char_tex(ck, expr, idx)
        chars.append({
            "roleId": _clean_id(rid),
            "tex": tex,
            "pos": st.get("pos", "center"),
            "expr": expr,
            "flip": bool(st.get("flip", False)),
        })
    return chars, state


# ---------------------------------------------------------------------------
# 事件预览组装
# ---------------------------------------------------------------------------

def preview_event(evt_id):
    """组装事件预览数据。找不到事件返回 None；其他异常抛 SandboxError。"""
    from editor.server.fs_tools import SandboxError
    evt_id = str(evt_id).strip()
    if not evt_id:
        raise SandboxError("evt_id 不能为空")

    evt_cfg = load_table("EvtCfg")
    talk_cfg = load_table("TalkCfg")
    opt_cfg = load_table("OptionCfg")
    event = _record(evt_cfg, evt_id)
    if event is None:
        raise SandboxError("事件 %s 不存在（当前模组与本体的 EvtCfg 中均未找到）" % evt_id)

    meta = _build_meta()
    starts = [str(x) for x in (event.get("talkId") or []) if x]

    # AA 索引（用于立绘 key 存在性回退）；不可用时不改变原有候选规则
    aa_idx = _load_aa_index()

    # BFS 展开对白链（主线 + 选项分支 + 检定分支），防环
    talks = {}
    options = {}
    stage_state = {}
    queue = list(starts)
    seen = set()
    while queue and len(talks) < _MAX_TALKS:
        tid = queue.pop(0)
        if tid in seen:
            continue
        seen.add(tid)
        rec = _record(talk_cfg, tid)
        if rec is None:
            continue
        talk = dict(rec)
        talk["id"] = tid
        if isinstance(talk.get("roleIds"), list):
            talk["roleIds"] = [_clean_id(x) for x in talk["roleIds"]]
        talk.pop("roles", None)  # 原始指令已折叠进 stage，减小载荷
        chars, stage_state = _build_stage(rec, meta["charKeys"], stage_state, aa_idx)
        talk["stage"] = {
            "bg": _bg_snapshot(talk.get("bg"), meta),
            "chars": chars,
        }
        talks[tid] = talk
        # 选项
        for oid in (rec.get("option") or []):
            oid = str(oid)
            if oid in options:
                continue
            orec = _record(opt_cfg, oid)
            if orec:
                options[oid] = dict(orec)
                options[oid]["id"] = oid
                for branch in ("talkId", "talkId2"):
                    for b in (orec.get(branch) or []):
                        if b:
                            queue.append(str(b))
        # 下一对白（nextTalk / nextTalk2）
        for n in (rec.get("nextTalk") or []) + (rec.get("nextTalk2") or []):
            if n:
                queue.append(str(n))

    return {
        "ok": True,
        "evt_id": evt_id,
        "event": dict(event),
        "event_title": str(event.get("title") or "") or ("事件 %s" % evt_id),
        "starts": starts,
        "talks": talks,
        "options": options,
        "talk_count": len(talks),
        "meta": meta,
    }


def _bg_snapshot(bg_id, meta):
    """背景快照：bg 为 0/空 时返回 None（表示沿用上一背景，由前端处理）。"""
    if not bg_id:
        return None
    rid = str(bg_id)
    return {
        "id": rid,
        "name": meta["bgs"].get(rid, ""),
        "key": meta["bgKeys"].get(rid, ""),
    }
