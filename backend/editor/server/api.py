# -*- coding: utf-8 -*-
"""API 路由：模组管理、cfg 数据 CRUD、schema/字典、Unity 资源、AI 工具沙箱。

（源码重建版：恢复被误删的初始功能，并包含已验证的加固——
  USERPROFILE 回退、创意工坊订阅目录支持、BOM 兼容、删除保护。）
"""
import json
import os
import re
import sys
import threading

from editor.server import ai_files
from editor.server import fs_tools
from editor.server.fs_tools import SandboxError
from editor.server import cfg_store
from editor.server.httpd import ApiRouter
from editor.server import ai_domain_service
from editor.server import ai_image_service
from editor.server import tts_service
from editor.server import tts_store
from editor.server import flow_assets
from editor.server import resource_pack
from editor.server import cloud_sync
from editor.server import realtime_sync
from editor.core import plugin_system

try:
    from editor.core.game_schema import GAME_SCHEMA
except Exception:
    GAME_SCHEMA = {}

try:
    from editor.core.data_dicts import (
        DEFAULT_EVT_KEY_MAP, DEFAULT_TALK_KEY_MAP, DEFAULT_OPT_KEY_MAP,
        DEFAULT_PERSON_KEY_MAP, DEFAULT_GROW_KEY_MAP, DEFAULT_KZONE_KEY_MAP,
        DEFAULT_PHONE_KEY_MAP, DEFAULT_GIFT_KEY_MAP, DEFAULT_INTERACT_KEY_MAP,
    )
    from editor.core.data_dicts import ITEM_DICT, ROLE_DICT, JOB_DICT, MAP_DICT, ATTR_DICT
    from editor.core.data_dicts import RELATION_DICT, BG_DICT, TURN_DICT
    from editor.core.data_dicts import EVT_TYPE_DICT, BADMINTON_MODELS
except Exception:
    DEFAULT_EVT_KEY_MAP = DEFAULT_TALK_KEY_MAP = DEFAULT_OPT_KEY_MAP = {}
    DEFAULT_PERSON_KEY_MAP = DEFAULT_GROW_KEY_MAP = DEFAULT_KZONE_KEY_MAP = {}
    DEFAULT_PHONE_KEY_MAP = DEFAULT_GIFT_KEY_MAP = DEFAULT_INTERACT_KEY_MAP = {}
    ITEM_DICT = ROLE_DICT = JOB_DICT = MAP_DICT = ATTR_DICT = {}
    RELATION_DICT = BG_DICT = TURN_DICT = {}
    EVT_TYPE_DICT = {}
    BADMINTON_MODELS = {}

try:
    from editor.services.unityfs_res import (
        UnityFsIndex, detect_game_aa_dir, TEX_PREFIX, AUD_PREFIX,
    )
except Exception:
    UnityFsIndex = None
    detect_game_aa_dir = lambda: ""

try:
    from editor.services import decoded_pack
except Exception:
    decoded_pack = None

from editor.server.base_service import BaseDataService
from editor.server import bugfix_service
from editor.server import story_service
from editor.server import stage_service
from editor.server import preview_service

GAME_WORKSHOP_APPID = "1991040"


def _user_mods_dir():
    """游戏 Mods 工作区根目录（跨平台探测，见 core/steam_paths.py）。"""
    from editor.core.steam_paths import user_mods_dir
    return user_mods_dir()


def _steam_library_paths():
    """发现本机全部 Steam 库根目录（跨平台，见 core/steam_paths.py）。"""
    from editor.core.steam_paths import steam_library_paths
    return steam_library_paths()


def _workshop_mods_roots():
    """创意工坊 mods 根目录列表（含 editor_env.json 覆盖，见 core/steam_paths.py）。"""
    from editor.core.steam_paths import workshop_mods_roots
    return workshop_mods_roots()


def _editor_root():
    """数据/缓存根目录。

    EDITOR_DATA_ROOT：Android（Chaquopy）等无写权限环境的覆盖入口，
    由 start_server(data_root) 写入并指向 filesDir；否则按 core/paths.py
    的跨平台规则解析（Windows 与便携目录为 exe 同目录，系统安装回退
    平台用户数据目录）。
    """
    env = os.environ.get("EDITOR_DATA_ROOT")
    if env:
        return env
    from editor.core.paths import app_data_dir
    return app_data_dir()


# 内置预解码资源包存储（Android 无游戏目录时的回落数据源）
_PACK_STORE = decoded_pack.DecodedPackStore() if decoded_pack else None
_PACK_LAST_DIR = ""


def _active_pack_dir():
    try:
        return resource_pack.get_active_dir()
    except Exception:
        return ""


def _ensure_pack_store():
    """返回解码资源包存储；活动包目录变化时自动重建。不可用返回 None。"""
    global _PACK_LAST_DIR
    if _PACK_STORE is None:
        return None
    d = _active_pack_dir()
    if d != _PACK_LAST_DIR:
        _PACK_LAST_DIR = d
        _PACK_STORE.refresh(d)
    return _PACK_STORE


def _pack_active_info():
    """(active_id, active_name)：供 /api/aa/status 内置包信息展示。"""
    try:
        meta = resource_pack.list_packs()
    except Exception:
        meta = {}
    if not isinstance(meta, dict):
        return "", ""
    active = meta.get("active") or ""
    name = active
    for p in meta.get("packs") or []:
        if isinstance(p, dict) and p.get("id") == active:
            name = p.get("name") or active
            break
    return active, name


class EditorState(object):
    def __init__(self):
        self.workspace_root = ""
        self.mod_root = ""          # 当前模组根目录（绝对路径）
        self.mod_name = ""
        self.aa_index = None
        self.aa_dirs = []
        self.aa_status = "idle"
        self.aa_error = ""
        self.base = None            # BaseDataService 实例（_init_state 中创建）
        self.base_dirs = []
        self.base_loaded = []
        self._lock = threading.Lock()

    def _cfg_dir(self):
        if not self.mod_root:
            return ""
        return os.path.join(self.mod_root, "Cfgs", "zh-cn")

    def list_mods(self):
        """扫描工作区根：子目录（含 Cfgs/zh-cn 或 manifest.json）为模组。

        扫描范围：本地工作区（LocalLow/.../Mods）+ 编辑器根 + Steam 创意工坊
        订阅目录（<库>/steamapps/workshop/content/<appid>/）。
        """
        roots = [self.workspace_root] if self.workspace_root else []
        editor_root = _editor_root()
        if editor_root and os.path.isdir(os.path.join(editor_root, "Cfgs", "zh-cn")):
            roots.append(editor_root)
        roots.extend(_workshop_mods_roots())
        seen, mods = set(), []
        for base in roots:
            if not base or not os.path.isdir(base):
                continue
            nb = os.path.normpath(base)
            if nb in seen:
                continue
            seen.add(nb)
            try:
                names = sorted(os.listdir(base))
            except OSError:
                # 目录存在但不可读（权限/占用）：跳过该根，不让整个列表失败
                continue
            for name in names:
                mod_dir = os.path.join(base, name)
                if not os.path.isdir(mod_dir):
                    continue
                cfg_dir = os.path.join(mod_dir, "Cfgs", "zh-cn")
                manifest = os.path.join(mod_dir, "manifest.json")
                if not (os.path.isdir(cfg_dir) or os.path.isfile(manifest)):
                    continue
                info = self._mod_info(name, mod_dir)
                mods.append(info)
        return mods

    def _mod_info(self, name, mod_dir):
        cfg_dir = os.path.join(mod_dir, "Cfgs", "zh-cn")
        cfg_files = []
        if os.path.isdir(cfg_dir):
            try:
                names = sorted(os.listdir(cfg_dir))
            except OSError:
                names = []
            for f in names:
                if f.endswith(".json") and f != "CustomKeyMap.json":
                    cfg_files.append(f[:-5])
        manifest = {}
        mpath = os.path.join(mod_dir, "manifest.json")
        if os.path.isfile(mpath):
            try:
                # utf-8-sig：兼容外部工具写出的带 BOM 文件
                with open(mpath, "r", encoding="utf-8-sig") as f:
                    manifest = json.load(f)
            except Exception:
                pass
        return {
            "name": name,
            "root": mod_dir,
            "cfg_files": cfg_files,
            "has_manifest": bool(manifest),
            "manifest_title": (manifest or {}).get("title", ""),
        }

    def select_mod(self, name, root):
        with self._lock:
            self.mod_name = name
            self.mod_root = root
            self.aa_index = None
            self.aa_status = "idle"
        try:
            _invalidate_mod_cfgs_cache()
        except NameError:
            pass
        try:
            from editor.server import preview_service as _ps
            _ps.invalidate_cache()
        except Exception:
            pass
        return self._mod_info(name, root)

    def sandbox_root(self, scope):
        if scope == "workspace":
            return self.workspace_root or _editor_root()
        return self.mod_root or self.workspace_root or _editor_root()


STATE = EditorState()


def _env_workspace_root():
    """editor_env.json 中持久化的 workspace（与 CLI/TUI 共用），无效/缺失返回 ''。"""
    env_path = os.path.join(_editor_root(), "editor_env.json")
    if not os.path.isfile(env_path):
        return ""
    try:
        with open(env_path, "r", encoding="utf-8-sig") as f:
            data = json.load(f)
        ws = str((data or {}).get("workspace_root") or "")
        return ws if ws and os.path.isdir(ws) else ""
    except Exception:
        return ""


def _init_state():
    if not STATE.workspace_root:
        # 与 CLI/TUI 一致：优先 editor_env.json 持久化值，否则游戏 Mods 目录
        STATE.workspace_root = _env_workspace_root() or _user_mods_dir()
        # 工作区根不存在时自动创建，否则 mods 列表/新建全部不可用
        try:
            os.makedirs(STATE.workspace_root, exist_ok=True)
        except OSError:
            pass
    if not STATE.mod_root:
        mods = STATE.list_mods()
        if mods:
            STATE.mod_root = mods[0]["root"]
            STATE.mod_name = mods[0]["name"]
    if STATE.base is None:
        STATE.base = BaseDataService(
            _editor_root(),
            os.path.join(_editor_root(), "_cache"),
        )


def _cfg_name(rel):
    rel = rel.replace("\\", "/").rstrip("/")
    if rel.endswith(".json"):
        rel = rel[:-5]


    return rel


def _cfg_path(cfg_name):
    cfg_dir = STATE._cfg_dir()
    if not cfg_dir:
        raise SandboxError("no mod selected")
    rel = fs_tools._norm(cfg_name + ".json")
    return os.path.join(cfg_dir, rel)


_MOD_CFGS_LOCK = threading.RLock()
_MOD_CFGS_CACHE = {}          # {cfg_name: data}
_MOD_CFGS_FP = None           # 指纹：[(fname, mtime_ns, size), ...] 或 None
_MOD_CFGS_DIR = ""            # 对应 cfg_dir


def _mod_cfgs_fingerprint(cfg_dir):
    """cfg 目录指纹：文件名+mtime+size，任意一项变化即失效。"""
    if not cfg_dir or not os.path.isdir(cfg_dir):
        return None
    try:
        out = []
        for f in sorted(os.listdir(cfg_dir)):
            if not f.endswith(".json") or f == "CustomKeyMap.json":
                continue
            p = os.path.join(cfg_dir, f)
            try:
                st = os.stat(p)
                out.append((f, st.st_mtime_ns, st.st_size))
            except OSError:
                out.append((f, 0, 0))
        return tuple(out)
    except OSError:
        return None


def _load_mod_cfgs():
    """加载当前 Mod 的全部配置表（磁盘 → {表名: {id: record}}），带指纹缓存。

    缓存命中时零读盘；指纹失配或换 Mod 时全量重扫并刷新缓存。
    """
    cfg_dir = STATE._cfg_dir()
    if not cfg_dir or not os.path.isdir(cfg_dir):
        with _MOD_CFGS_LOCK:
            _MOD_CFGS_CACHE.clear()
        return {}
    fp = _mod_cfgs_fingerprint(cfg_dir)
    with _MOD_CFGS_LOCK:
        global _MOD_CFGS_FP, _MOD_CFGS_DIR
        if fp is not None and fp == _MOD_CFGS_FP and _MOD_CFGS_DIR == cfg_dir and _MOD_CFGS_CACHE:
            # 浅拷贝返回，避免调用方篡改缓存对象
            return dict(_MOD_CFGS_CACHE)
    out = {}
    for f in sorted(os.listdir(cfg_dir)):
        if not f.endswith(".json") or f == "CustomKeyMap.json":
            continue
        name = f[:-5]
        try:
            with open(os.path.join(cfg_dir, f), "r", encoding="utf-8-sig") as fp2:
                data = json.load(fp2)
            out[name] = data if isinstance(data, dict) else {}
        except Exception:
            out[name] = {}
    with _MOD_CFGS_LOCK:
        _MOD_CFGS_CACHE.clear()
        _MOD_CFGS_CACHE.update(out)
        _MOD_CFGS_FP = fp
        _MOD_CFGS_DIR = cfg_dir
    return dict(out)


def _invalidate_mod_cfgs_cache():
    """使模组配置缓存失效（cfg 写入/切换模组后调用）。"""
    with _MOD_CFGS_LOCK:
        global _MOD_CFGS_FP
        _MOD_CFGS_FP = None


def _save_mod_cfg(cfg_name, data):
    """原子写回单个配置表（统一走 cfg_store，覆盖前留 .editor_history 快照），并刷新缓存。"""
    path = _cfg_path(cfg_name)
    result = cfg_store.write_cfg(path, data, snapshot=True)
    if not result.get("ok"):
        raise OSError(result.get("error") or "配置表写入失败")
    # 写回后刷新单表缓存并失效指纹，下次读取会重新比对
    with _MOD_CFGS_LOCK:
        _MOD_CFGS_CACHE[cfg_name] = data if isinstance(data, dict) else {}
        global _MOD_CFGS_FP
        _MOD_CFGS_FP = None


def _base_table_ids(cfg_name):
    """原版表 ID 集合（int 化）；原版数据（STATE.base）不可用时返回空集合。"""
    base = STATE.base
    if base is None or not cfg_name:
        return set()
    try:
        data = base.data
    except Exception:
        return set()
    if not isinstance(data, dict):
        return set()
    tbl = data.get(cfg_name)
    ids = set()
    if isinstance(tbl, dict):
        for k in tbl.keys():
            try:
                ids.add(int(k))
            except (TypeError, ValueError):
                continue
    return ids


def _read_mod_table(cfg_name):
    """读取当前 Mod 的单个配置表；文件缺失/解析失败返回 None（调用方跳过该表）。"""
    try:
        path = _cfg_path(cfg_name)
    except Exception:
        return None
    if not path or not os.path.isfile(path):
        return None
    try:
        with open(path, "r", encoding="utf-8-sig") as f:
            content = f.read().strip()
    except OSError:
        return None
    if not content:
        return {}
    try:
        data = json.loads(content)
    except (ValueError, TypeError):
        return None
    return data if isinstance(data, dict) else None


def _tts_register_audio_cfg(key, body):
    """登记 AudioCfg 行（文件 IO 在 tts_store，三端共享）并刷新 mod 配置缓存。"""
    new_id = tts_store.register_audio_cfg(
        STATE._cfg_dir(), key, str(body.get("title") or ""))
    _invalidate_mod_cfgs_cache()
    try:
        from editor.server import preview_service as _ps
        _ps.invalidate_cache()
    except Exception:
        pass
    return new_id


# 跨表 issue 消息前缀 -> 表名（用于 /api/validate 的 cfg 字段标注）
_CROSS_MSG_CFG_PREFIX = (("事件", "EvtCfg"), ("对话", "TalkCfg"), ("选项", "OptionCfg"))


def _norm_effect_rows(arr):
    """把 json.loads(f"[{t}]") 的结果归一为「行列表」（screen/action 校验用）。

    - 首元素非 list（用户漏了外层括号，如 4001,0.5 / 0,3000,1）→ 整体包装成单行；
    - 首元素是 list 且其首元素也是 list（用户写了 [[row],[row]]，外层被 f"[{t}]" 又包了一层）
      → 取 arr[0] 作为行列表；
    - 其余（[[row], ...] 单层行列表）→ arr 本身。
    """
    if not isinstance(arr, list) or not arr:
        return []
    if not isinstance(arr[0], list):
        return [arr]
    if arr[0] and isinstance(arr[0][0], list):
        return arr[0]
    return arr


# 角色立绘/音频 bundle 文件名标记：体量大，默认扫描（include_slow=False）跳过
_ROLE_BUNDLE_TAG = "_role_"


def _ensure_role_bundles(idx, dirs):
    """角色立绘/音频 bundle（文件名含 _role_）默认扫描会跳过，导致缓存索引
    缺立绘 key、预览中立绘空白。检测到缺失时后台补扫（scan_extra 只补未
    索引的 bundle，幂等）。供 _ensure_aa_index 与 preview_service 复用。"""
    if not dirs or STATE.aa_status == "scanning":
        return
    if any(_ROLE_BUNDLE_TAG in os.path.basename(p) for p in idx._bundle_set):
        return
    missing = []
    try:
        for d in dirs:
            for root, sub, files in os.walk(d):
                sub[:] = [x for x in sub if not x.endswith("_unpacked")]
                for f in files:
                    if _ROLE_BUNDLE_TAG not in f or not f.lower().endswith(".bundle"):
                        continue
                    p = os.path.join(root, f)
                    if p in idx._bundle_set:
                        continue
                    missing.append(p)
    except Exception:
        return
    if not missing:
        return
    STATE.aa_status = "scanning"

    def work():
        try:
            idx.scan_extra([_ROLE_BUNDLE_TAG])
            STATE.aa_status = "ready"
        except Exception as e:
            STATE.aa_status = "error"
            STATE.aa_error = "%s: %s" % (type(e).__name__, e)

    threading.Thread(target=work, daemon=True).start()


def build_router():
    r = ApiRouter()
    _init_state()

    # ---------- 系统 ----------
    @r.route("GET", r"/api/ping")
    def ping(_query=None, _body=None):
        return 200, {"ok": True, "app": "student-age-editor", "state": {
            "workspace_root": STATE.workspace_root,
            "mod_root": STATE.mod_root,
            "mod_name": STATE.mod_name,
            "aa_status": STATE.aa_status,
            "base_loaded_count": len(STATE.base_loaded),
        }}

    @r.route("GET", r"/api/state")
    def state(_query=None, _body=None):
        return 200, {
            "workspace_root": STATE.workspace_root,
            "mod_root": STATE.mod_root,
            "mod_name": STATE.mod_name,
            "mods": STATE.list_mods(),
            "aa_status": STATE.aa_status,
            "aa_dirs": STATE.aa_dirs,
            "aa_error": STATE.aa_error,
            "base_loaded": STATE.base_loaded[:200],
            "schema_count": len(GAME_SCHEMA),
        }

    @r.route("POST", r"/api/workspace")
    def set_workspace(_query=None, _body=None):
        root = (_body or {}).get("root") or ""
        if root and not os.path.isdir(root):
            return 400, {"error": "directory not found: %s" % root}
        STATE.workspace_root = root or _user_mods_dir()
        return 200, {"workspace_root": STATE.workspace_root, "mods": STATE.list_mods()}

    @r.route("POST", r"/api/shutdown")
    def shutdown(_query=None, _body=None):
        def bye():
            os._exit(0)
        threading.Thread(target=bye, daemon=True).start()
        return 200, {"ok": True}

    # ---------- OOBE（首次运行向导，三端共用标记） ----------
    @r.route("GET", r"/api/oobe/status")
    def oobe_status(_query=None, _body=None):
        try:
            from editor.cli.oobe import snapshot as _snap
            snap = _snap()
        except Exception as e:
            # oobe 模块异常时不阻塞 GUI：按已完成处理
            snap = {"done": True, "first_run": False, "forced": False,
                    "workspace_root": STATE.workspace_root, "error": str(e)}
        snap.setdefault("suggested_workspace", _user_mods_dir())
        snap.setdefault("workspace_root", STATE.workspace_root)
        snap["server_workspace"] = STATE.workspace_root
        return 200, snap

    @r.route("POST", r"/api/oobe/setup")
    def oobe_setup(_query=None, _body=None):
        """OOBE 完成落盘：设置工作区（可选）+ 建首个 Mod（可选）+ 标记完成。"""
        body = _body or {}
        ws = (body.get("workspace") or "").strip()
        title = (body.get("mod_title") or "").strip()
        desc = (body.get("mod_desc") or "").strip()
        try:
            from editor.cli.oobe import set_workspace as _set_ws
            from editor.cli.oobe import create_mod as _create_mod
            from editor.cli.oobe import mark_done as _mark_done
            if ws:
                p = os.path.abspath(os.path.expanduser(ws))
                saved = _set_ws(p)
                STATE.workspace_root = str(saved)
                _invalidate_mod_cfgs_cache()
            mod_name = ""
            if title:
                target_ws = STATE.workspace_root or _user_mods_dir()
                mod_dir = _create_mod(title, target_ws, desc)
                mod_name = os.path.basename(str(mod_dir))
                STATE.select_mod(mod_name, str(mod_dir))
            elif not ws:
                mods = STATE.list_mods()
                if mods and not STATE.mod_name:
                    STATE.mod_name = mods[0]["name"]
                    STATE.mod_root = mods[0]["root"]
            # OOBE 可选配置：AI 助手 / 云存储（复用 oobe._apply_extras，失败降级不阻塞）
            if body.get("ai_settings") or body.get("cloud_provider"):
                from editor.cli.oobe import _apply_extras as _extras
                _extras(body.get("ai_settings"), body.get("cloud_provider"),
                        STATE.workspace_root or None)
            if body.get("mark_done", True):
                patch = {"workspace_root": STATE.workspace_root} if ws else None
                _mark_done(patch)
        except ValueError as e:
            return 400, {"error": str(e)}
        except Exception as e:
            return 500, {"error": "%s: %s" % (type(e).__name__, e)}
        return 200, {"ok": True, "workspace_root": STATE.workspace_root,
                     "mods": STATE.list_mods(), "mod_name": STATE.mod_name}

    @r.route("POST", r"/api/oobe/complete")
    def oobe_complete(_query=None, _body=None):
        try:
            from editor.cli.oobe import mark_done as _mark_done
            _mark_done(None)
        except Exception as e:
            return 500, {"error": str(e)}
        return 200, {"ok": True}

    # ---------- AI 助手共享配置（GUI/CLI/TUI 三端唯一数据源 .editor_ai.json） ----------
    @r.route("GET", r"/api/ai/settings")
    def ai_settings_get(_query=None, _body=None):
        try:
            from editor.core.env_store import read_ai_settings
            return 200, {"settings": read_ai_settings()}
        except Exception as e:
            return 500, {"error": "%s: %s" % (type(e).__name__, e)}

    @r.route("PUT", r"/api/ai/settings")
    def ai_settings_put(_query=None, _body=None):
        body = _body or {}
        if not isinstance(body.get("settings", body), dict):
            return 400, {"error": "body must be a settings object"}
        patch = body["settings"] if isinstance(body.get("settings"), dict) else body
        try:
            from editor.core.env_store import write_ai_settings
            return 200, {"ok": True, "settings": write_ai_settings(patch)}
        except Exception as e:
            return 500, {"error": "%s: %s" % (type(e).__name__, e)}

    # ---------- 模组 ----------
    @r.route("GET", r"/api/mods")
    def mods(_query=None, _body=None):
        return 200, {"mods": STATE.list_mods(), "selected": STATE.mod_name}

    @r.route("POST", r"/api/mods/select")
    def mod_select(_query=None, _body=None):
        name = (_body or {}).get("name") or ""
        root = (_body or {}).get("root") or ""
        if root:
            # root 必须位于工作区或创意工坊订阅目录内（防止把任意目录当沙箱根）
            allowed_bases = [os.path.abspath(STATE.workspace_root or _user_mods_dir())]
            allowed_bases.extend(os.path.abspath(r) for r in _workshop_mods_roots())
            abs_root = os.path.abspath(root)
            if not any(abs_root == b or abs_root.startswith(b + os.sep)
                       for b in allowed_bases):
                return 400, {"error": "mod root must be inside workspace or workshop dir"}
            if os.path.isdir(abs_root):
                return 200, {"mod": STATE.select_mod(name or os.path.basename(abs_root), abs_root)}
            return 404, {"error": "mod dir not found: %s" % root}
        mods = STATE.list_mods()
        for m in mods:
            if m["name"] == name:
                return 200, {"mod": STATE.select_mod(name, m["root"])}
        return 404, {"error": "mod not found: %s" % name}

    @r.route("POST", r"/api/mods/create")
    def mod_create(_query=None, _body=None):
        body = _body or {}
        title = str(body.get("title") or "").strip()
        desc = str(body.get("desc") or "").strip()
        if not title:
            return 400, {"error": "title required"}
        # 目录名净化：禁止路径分隔符/穿越/绝对路径/非法字符
        if re.search(r'[\\/:*?"<>|\x00-\x1f]', title) or title in (".", ".."):
            return 400, {"error": "标题含非法字符，不能用作目录名: %r" % title}
        base = STATE.workspace_root or _user_mods_dir()
        mod_dir = os.path.join(base, title)
        if not os.path.abspath(mod_dir).startswith(os.path.abspath(base) + os.sep):
            return 400, {"error": "title escapes workspace"}
        if os.path.exists(mod_dir):
            return 400, {"error": "mod already exists: %s" % title}
        os.makedirs(os.path.join(mod_dir, "Cfgs", "zh-cn"), exist_ok=True)
        manifest = {
            "title": title,
            "description": desc,
            "version": "1.0.0",
            "created_at": __import__("datetime").datetime.now().isoformat(timespec="seconds"),
        }
        with open(os.path.join(mod_dir, "manifest.json"), "w", encoding="utf-8") as f:
            json.dump(manifest, f, ensure_ascii=False, indent=2)
        return 200, {"mod": STATE.select_mod(title, mod_dir)}

    @r.route("POST", r"/api/mods/delete")
    def mod_delete(_query=None, _body=None):
        body = _body or {}
        name = str(body.get("name") or "")
        mods = STATE.list_mods()
        for m in mods:
            if m["name"] == name:
                abs_root = os.path.abspath(m["root"])
                if any(abs_root.startswith(os.path.abspath(r) + os.sep)
                       for r in _workshop_mods_roots()):
                    # 创意工坊订阅内容由 Steam 客户端管理，直接删除会被 Steam 重新下载
                    return 400, {"error": "创意工坊订阅内容请在 Steam 客户端取消订阅，不能直接删除"}
                import shutil
                shutil.rmtree(m["root"], ignore_errors=True)
                if STATE.mod_name == name:
                    STATE.mod_root = ""
                    STATE.mod_name = ""
                return 200, {"ok": True}
        return 404, {"error": "mod not found"}

    # ---------- cfg 数据（无状态文件 CRUD） ----------
    @r.route("GET", r"/api/cfg")
    def cfg_list(_query=None, _body=None):
        mods = STATE.list_mods()
        info = next((m for m in mods if m["name"] == STATE.mod_name), None)
        if info is None:
            info = STATE._mod_info(STATE.mod_name, STATE.mod_root) if STATE.mod_root else None
        return 200, {"mod": STATE.mod_name, "cfg_files": (info or {}).get("cfg_files", [])}

    @r.route("GET", r"/api/cfg/(?P<name>[^/]+)")
    def cfg_read(name, _query=None, _body=None):
        cfg_name = _cfg_name(name)
        path = _cfg_path(cfg_name)
        # mtime_ns：前端保存时回传做乐观锁（冲突检测用）；文件缺失为 None
        mtime_ns = None
        if os.path.isfile(path):
            try:
                mtime_ns = os.stat(path).st_mtime_ns
            except OSError:
                mtime_ns = None
        if not os.path.isfile(path):
            # 配置表尚不存在：返回空表（exists=false），前端可新建，保存时自动创建
            return 200, {"cfg": cfg_name, "data": {}, "keys": [], "exists": False,
                         "mtime_ns": None}
        try:
            # utf-8-sig：兼容外部工具写出的带 BOM 文件
            with open(path, "r", encoding="utf-8-sig") as f:
                content = f.read().strip()
        except OSError as e:
            return 500, {"error": "读取配置表失败: %s" % e, "cfg": cfg_name}
        if not content:
            return 200, {"cfg": cfg_name, "data": {}, "keys": [], "exists": True,
                         "mtime_ns": mtime_ns}
        try:
            data = json.loads(content)
        except (ValueError, TypeError) as e:
            # 非法 JSON 明确报错，避免 500 崩溃/前端空白
            return 400, {"error": "配置表 JSON 解析失败: %s" % e, "cfg": cfg_name}
        return 200, {"cfg": cfg_name, "data": data if isinstance(data, dict) else {},
                     "keys": sorted(data.keys()) if isinstance(data, dict) else [],
                     "exists": True, "mtime_ns": mtime_ns}

    @r.route("PUT", r"/api/cfg/(?P<name>[^/]+)")
    def cfg_write(name, _query=None, _body=None):
        body = _body or {}
        data = body.get("data")
        if not isinstance(data, dict):
            return 400, {"error": "data must be a dict"}
        cfg_name = _cfg_name(name)
        path = _cfg_path(cfg_name)
        # 可选乐观锁：expect_mtime_ns 与磁盘不一致且未 force 时拒绝写入（409）
        expect = body.get("expect_mtime_ns")
        try:
            expect = int(expect) if expect is not None else None
        except (TypeError, ValueError):
            expect = None
        result = cfg_store.write_cfg(
            path, data, expect_mtime_ns=expect, force=bool(body.get("force")),
            snapshot=True)
        if not result.get("ok"):
            if result.get("conflict"):
                return 409, {"error": "conflict", "cfg": cfg_name,
                             "mtime_ns": result.get("mtime_ns"),
                             "data": result.get("data")}
            return 500, {"error": result.get("error") or "写入失败", "cfg": cfg_name}
        with _MOD_CFGS_LOCK:
            _MOD_CFGS_CACHE[cfg_name] = data if isinstance(data, dict) else {}
            global _MOD_CFGS_FP
            _MOD_CFGS_FP = None
        try:
            from editor.server import preview_service as _ps
            _ps.invalidate_cache()
        except Exception:
            pass
        return 200, {"ok": True, "cfg": cfg_name, "keys": sorted(data.keys()),
                     "mtime_ns": result.get("mtime_ns"),
                     "snapshot": result.get("snapshot")}

    # ---------- 误操作保护：历史快照 / 撤销 / 重做 ----------
    @r.route("GET", r"/api/history")
    def history_list(_query=None, _body=None):
        cfg_name = _cfg_name(str((_query or {}).get("cfg") or ""))
        if not cfg_name:
            return 400, {"error": "cfg required"}
        try:
            path = _cfg_path(cfg_name)
        except SandboxError as e:
            return 400, {"error": str(e)}
        return 200, {"cfg": cfg_name, "entries": cfg_store.list_history(path)}

    def _history_op(cfg_name, op):
        """撤销/重做公共流程：成功后失效 mod 配置缓存与预览缓存。

        返回 (ok, result)；ok=False 时 result 即失败响应体（如 nothing to undo）。
        """
        path = _cfg_path(cfg_name)
        result = cfg_store.undo(path) if op == "undo" else cfg_store.redo(path)
        if not result.get("ok"):
            return False, result
        _invalidate_mod_cfgs_cache()
        try:
            from editor.server import preview_service as _ps
            _ps.invalidate_cache()
        except Exception:
            pass
        return True, result

    @r.route("POST", r"/api/history/undo")
    def history_undo(_query=None, _body=None):
        body = _body or {}
        cfg_name = _cfg_name(str(body.get("cfg") or ""))
        if not cfg_name:
            return 400, {"error": "cfg required"}
        try:
            ok, result = _history_op(cfg_name, "undo")
        except SandboxError as e:
            return 400, {"error": str(e)}
        if not ok:
            return 400, result
        return 200, result

    @r.route("POST", r"/api/history/redo")
    def history_redo(_query=None, _body=None):
        body = _body or {}
        cfg_name = _cfg_name(str(body.get("cfg") or ""))
        if not cfg_name:
            return 400, {"error": "cfg required"}
        try:
            ok, result = _history_op(cfg_name, "redo")
        except SandboxError as e:
            return 400, {"error": str(e)}
        if not ok:
            return 400, result
        return 200, result

    # ---------- 指南校验 / 引用数据源 ----------
    @r.route("POST", r"/api/validate")
    def validate_save(_query=None, _body=None):
        """保存前校验：单表指南规则（guide_rules.validate_record）+ 跨表引用（validate_cross）。

        body: {"cfg": "EvtCfg", "data": {rid: record, ...}}
        响应: {"cfg": ..., "issues": [{level,msg,rid,cfg}], "counts": {error,warn,info}}
        """
        body = _body or {}
        cfg = str(body.get("cfg") or "")
        data = body.get("data")
        try:
            from editor.core import guide_rules as _gr
        except Exception as e:
            return 200, {"cfg": cfg, "issues": [], "error": "guide_rules not ready: %s" % e}
        if cfg and not isinstance(data, dict):
            data = {}
        issues = []
        # 1) 单表：逐条记录跑指南规则（validate_record 的 msg 以 rid 开头）
        if isinstance(data, dict):
            for rid, rec in data.items():
                try:
                    rec_issues = _gr.validate_record(cfg, rid, rec)
                except Exception as e:
                    # 单条记录校验崩溃不应静默吞掉（也不阻塞其余记录）
                    issues.append({"level": "info",
                                   "msg": "记录 %s 单表校验失败（已跳过该记录）: %s" % (rid, e),
                                   "rid": str(rid), "cfg": cfg})
                    continue
                for level, msg in rec_issues:
                    issues.append({"level": str(level), "msg": str(msg),
                                   "rid": str(rid), "cfg": cfg})
        # 2) 跨表：读当前 mod 的 EvtCfg/TalkCfg/OptionCfg，请求中的 data 覆盖同名表
        tables = {}
        for tname in ("EvtCfg", "TalkCfg", "OptionCfg"):
            if cfg == tname and isinstance(data, dict):
                tables[tname] = data
                continue
            tdata = _read_mod_table(tname)
            if isinstance(tdata, dict):
                tables[tname] = tdata
        base_ids = {t: _base_table_ids(t) for t in ("EvtCfg", "TalkCfg", "OptionCfg")}
        try:
            cross_issues = _gr.validate_cross(tables, base_ids)
        except Exception as e:
            cross_issues = []
            issues.append({"level": "info", "msg": "跨表校验失败（已跳过）: %s" % e,
                           "rid": "", "cfg": ""})
        for level, msg in cross_issues:
            xcfg = ""
            for prefix, name in _CROSS_MSG_CFG_PREFIX:
                if str(msg).startswith(prefix):
                    xcfg = name
                    break
            issues.append({"level": str(level), "msg": str(msg), "rid": "", "cfg": xcfg})
        counts = {"error": 0, "warn": 0, "info": 0}
        for it in issues:
            lv = it.get("level")
            counts[lv if lv in counts else "info"] += 1
        return 200, {"cfg": cfg, "issues": issues, "counts": counts}

    @r.route("GET", r"/api/cfg_ids")
    def cfg_ids(_query=None, _body=None):
        """引用字段下拉数据源：当前 mod 指定表的 [{id, preview}] 列表（按 id 数值排序，最多 500 条）。"""
        q = _query or {}
        cfg_name = _cfg_name(str(q.get("name") or ""))
        items = []
        data = _read_mod_table(cfg_name) if cfg_name else None
        if isinstance(data, dict):

            def _id_sort_key(k):
                try:
                    return (0, int(k), "")
                except (TypeError, ValueError):
                    return (1, 0, str(k))

            for k in sorted(data.keys(), key=_id_sort_key)[:500]:
                rec = data[k]
                preview = ""
                if isinstance(rec, dict):
                    for fld in ("title", "content", "showTxt", "desc"):
                        v = rec.get(fld)
                        if v is None:
                            continue
                        sv = str(v).replace("\r", "").replace("\n", "")
                        if sv.strip():
                            preview = sv[:20]
                            break
                items.append({"id": str(k), "preview": preview})
        return 200, {"cfg": cfg_name, "items": items}

    @r.route("GET", r"/api/base_ids")
    def base_ids(_query=None, _body=None):
        """原版表 ID 列表（引用校验/下拉提示用）：从 STATE.base.data 取键集合（int 化、排序）。"""
        q = _query or {}
        cfg = str(q.get("cfg") or "")
        ids = sorted(_base_table_ids(cfg))
        loaded = False
        base = STATE.base
        if base is not None:
            try:
                bdata = base.data
            except Exception:
                bdata = None
            loaded = isinstance(bdata, dict) and bool(bdata)
        return 200, {"cfg": cfg, "ids": ids, "loaded": loaded}

    # ---------- schema / 字典 ----------

    def _build_evt_types():
        """事件类型字典：硬编码兜底 + 原版/模组 EvtTypeCfg 覆盖（对齐友商逻辑）。"""
        out = {str(k): v for k, v in EVT_TYPE_DICT.items()}
        base = STATE.base
        if base is not None:
            try:
                evt_types = (base.data or {}).get("EvtTypeCfg") or {}
            except Exception:
                evt_types = {}
            for k, v in evt_types.items():
                if str(k).isdigit() and isinstance(v, dict):
                    out[str(k)] = str(v.get("name") or "未知")
        return out

    def _build_audios():
        """音乐音效字典（MinigameCfg.bgm 等）：优先原版 AudioCfg 名称，缺省按 ID 显示。"""
        out = {}
        base = STATE.base
        if base is not None:
            try:
                audios = (base.data or {}).get("AudioCfg") or {}
            except Exception:
                audios = {}
            for k, v in audios.items():
                if isinstance(v, dict):
                    out[str(k)] = str(v.get("name") or "音频 %s" % k)
                else:
                    out[str(k)] = str(v)
        return out

    @r.route("GET", r"/api/schema")
    def schema(_query=None, _body=None):
        field_types = {}
        for cfg_name, fields in GAME_SCHEMA.items():
            for k, v in fields.items():
                field_types[k] = v
        return 200, {"game_schema": GAME_SCHEMA, "field_types": field_types,
                     "cfg_names": sorted(GAME_SCHEMA.keys())}

    @r.route("GET", r"/api/effect_suggest")
    def effect_suggest(_query=None, _body=None):
        q = (_query or {}).get("q", "") if _query else ""
        mode = (_query or {}).get("mode", "effect") if _query else "effect"
        try:
            from editor.core.data_dicts import (
                CONDITION_DB as _CND_DB,
                EFFECT_DB as _EFF_DB,
                EFFECT_EDITOR_DB as _EFFE_DB,
                STATE_DICT as _ST_DICT,
                TEXT_DICT as _TXT_DICT,
                NEGOTIATION_SKILL_DICT as _NSK_DICT,
                NEGOTIATION_BUFF_DICT as _NBF_DICT,
                GAME_DICT as _GM_DICT,
                KZONE_POST_DICT as _KZ_DICT,
                KZONE_MESSAGE_DICT as _KZM_DICT,
                PHONE_MSG_DICT as _PH_DICT,
                COST_DB as _COST_DB,
                CONDITION_SECONDARY_TEMPLATE_INDEX as _CND_IDX,
                EFFECT_SECONDARY_TEMPLATE_INDEX as _EFF_IDX,
                EFFECT_EDITOR_SECONDARY_TEMPLATE_INDEX as _EFFE_IDX,
                SECONDARY_PLACEHOLDER_MAP as _PLACE_MAP,
                validate_secondary_item as _validate_item,
                render_secondary_template as _render_tpl,
                match_secondary_template as _match_tpl,
                _is_numeric_token as _is_num,
            )
        except Exception as _e:
            return 200, {"items": [], "error": "effect dict not ready: %s" % _e}
        # 动作指令/屏幕效果字典（可能尚未写入 data_dicts）：单独 import，缺失时不影响 effect/condition/cost
        try:
            from editor.core.data_dicts import (
                ACTION_CMD_DB as _ACT_DB,
                SCREEN_EFFECT_DB as _SCR_DB,
            )
        except Exception:
            _ACT_DB = _SCR_DB = None
        _mode = (mode or "effect").strip().lower()
        if _mode not in ("effect", "condition", "cost", "action", "screen"):
            _mode = "effect"
        if _mode == "condition":
            _db = list(_CND_DB)
            _idx = _CND_IDX
        elif _mode == "cost":
            _db = list(_COST_DB)
            _idx = None
        elif _mode == "action":
            if not _ACT_DB:
                return 200, {"items": [], "mode": _mode, "q": (q or "").strip(),
                             "error": "动作指令字典（ACTION_CMD_DB）尚未就绪"}
            _db = list(_ACT_DB)
            _idx = None
        elif _mode == "screen":
            if not _SCR_DB:
                return 200, {"items": [], "mode": _mode, "q": (q or "").strip(),
                             "error": "屏幕效果字典（SCREEN_EFFECT_DB）尚未就绪"}
            _db = list(_SCR_DB)
            _idx = None
        else:
            _db = list(_EFFE_DB) if _mode == "effect" else list(_EFF_DB)
            _idx = _EFFE_IDX
        # 允许的二级码占位符一次查全，后端不再做拼音/角色名替换，前端负责展示
        _limit = 40
        qn = (q or "").strip()
        q_upper = qn.upper().replace("≥", ">=").replace("≤", "<=")
        q_upper = q_upper.replace("大于等于", ">=").replace("小于等于", "<=")
        q_upper = q_upper.replace("大于", ">").replace("小于", "<").replace("等于", "=")
        chunks = [s for s in __import__("re").split(r"[,，;；\s]+", q_upper) if s]
        nums = __import__("re").findall(r"-?\d+(?:\.\d+)?", q_upper)
        out = []
        for _item in _db:
            _desc = _item.get("desc", "")
            _code = _item.get("code", "")
            _target = (_desc + _code).upper().replace(" ", "")
            _target = _target.replace("≥", ">=").replace("≤", "<=").replace("＞", ">").replace("＜", "<")
            ok = True
            has_text = False
            for ch in chunks:
                chars = "".join(c for c in ch if not c.isdigit() and c not in "-+.")
                if chars:
                    has_text = True
                    if not all(c in _target for c in chars):
                        ok = False; break
            if not ok:
                continue
            if not has_text and chunks == [] and not qn:
                pass
            elif not has_text and nums:
                if not any(n in _target for n in nums) and not __import__("re").search(r"[A-Z]", _code):
                    continue
            out.append(_item)
            if len(out) >= _limit:
                break
        # 若关键词为空，返回前 _limit 条
        # 若按关键词未命中且关键词长度>=1，回退返回前 15 条避免空列表
        if not out and qn:
            out = list(_db[:15])
        # 高亮：数字直映到占位符（与友商一致，末尾数字优先）
        # action/screen 无二级模板占位符，跳过数字替换，原样返回
        _skip_render = _mode in ("action", "screen")
        rendered = []
        for _mi in out:
            _tc = _mi["code"]; _td = _mi["desc"]
            _ph = len(__import__("re").findall(r"[A-Z]", _mi["code"]))
            if _ph and nums and not _skip_render:
                _use = nums[-_ph:]
                for _n in _use:
                    _tc = __import__("re").sub(r"[A-Z]", str(_n), _tc, count=1)
                    _td = __import__("re").sub(r"[A-Z]", str(_n), _td, count=1)
            rendered.append({"desc": _td, "code": _tc, "raw_code": _mi["code"], "raw_desc": _mi["desc"]})
        return 200, {"items": rendered, "mode": _mode, "q": qn}

    @r.route("POST", r"/api/effect_validate")
    def effect_validate(_query=None, _body=None):
        body = _body or {}
        text = str(body.get("text") or "")
        mode = str(body.get("mode") or "effect").lower().strip()
        if mode not in ("effect", "condition", "cost", "action", "screen"):
            mode = "effect"
        t = text.strip().rstrip(",; \n\t")
        if not t:
            return 200, {"valid": True, "translations": [], "errors": [], "status": "empty"}
        try:
            arr = json.loads(f"[{t}]")
        except Exception as e:
            return 200, {"valid": False, "status": "json_error", "message": "括号或逗号不匹配", "detail": str(e)}
        # screen/action 允许省略外层括号（4001,0.5 / 0,3000,1），由下方分支包装成单行
        if (mode not in ("screen", "action") and arr
                and not isinstance(arr[0], list) and str(arr[0]).lstrip("-").isdigit()):
            return 200, {"valid": False, "status": "missing_outer_bracket", "message": f"缺少外层方括号，请改为: [ [{t}] ]"}
        try:
            from editor.core.data_dicts import (
                CONDITION_SECONDARY_TEMPLATE_INDEX as _CND_IDX,
                EFFECT_EDITOR_SECONDARY_TEMPLATE_INDEX as _EFFE_IDX,
                SECONDARY_PLACEHOLDER_MAP as _PLACE_MAP,
                validate_secondary_item as _validate_item,
                STATE_DICT as _ST_DICT,
                TEXT_DICT as _TXT_DICT,
                ROLE_DICT as _RL_DICT,
                ATTR_DICT as _AT_DICT,
                ITEM_DICT as _IT_DICT,
                RELATION_DICT as _REL_DICT,
                MAP_DICT as _MP_DICT,
                JOB_DICT as _JB_DICT,
                NEGOTIATION_SKILL_DICT as _NSK_DICT,
                NEGOTIATION_BUFF_DICT as _NBF_DICT,
                GAME_DICT as _GM_DICT,
                KZONE_POST_DICT as _KZ_DICT,
                KZONE_MESSAGE_DICT as _KZM_DICT,
                PHONE_MSG_DICT as _PH_DICT,
                COST_DB as _COST_DB,
            )
        except Exception as e:
            return 200, {"valid": False, "status": "dict_unavailable", "message": str(e)}
        # cost 模式：沿用旧 translate_array_to_text 逻辑，不走二次模板
        if mode == "cost":
            translations = []
            for r in arr:
                if not isinstance(r, list):
                    continue
                translations.append(", ".join(str(x) for x in r))
            return 200, {"valid": True, "translations": translations, "errors": []}
        # screen / action 模式：指南语义校验（guide_rules），不走二次模板
        if mode in ("screen", "action"):
            try:
                if mode == "screen":
                    from editor.core.guide_rules import describe_screen_row as _describe_row
                else:
                    from editor.core.guide_rules import describe_action_row as _describe_row
            except Exception as e:
                return 200, {"valid": False, "status": "dict_unavailable", "message": str(e)}
            # screen: 4001,0.5 或 [[4001,0.5]]；action: [[0,3000,1],[102,1001,0,2]] 或漏外层括号的 0,3000,1
            rows = _norm_effect_rows(arr)
            translations = []
            errors = []
            if mode == "screen" and len(rows) > 1:
                errors.append("第 1 行 👉 一句话只能填写一个屏幕效果")
            for i, row in enumerate(rows):
                if not isinstance(row, list):
                    continue
                desc, errs = _describe_row(row)
                translations.append(desc or ", ".join(str(x) for x in row))
                for er in errs:
                    errors.append(f"第 {i+1} 行 👉 {er}")
            return 200, {"valid": len(errors) == 0, "translations": translations,
                         "errors": errors, "status": "ok" if not errors else "logic_error"}
        idx = _EFFE_IDX if mode == "effect" else _CND_IDX
        available = {
            "ROLE": dict(_RL_DICT or {}),
            "ATTR": dict(_AT_DICT or {}),
            "ITEM": dict(_IT_DICT or {}),
            "RELATION": dict(_REL_DICT or {}),
            "MAP": dict(_MP_DICT or {}),
            "JOB": dict(_JB_DICT or {}),
            "STATE": dict(_ST_DICT or {}),
            "TEXT": dict(_TXT_DICT or {}),
            "NEGOTIATION_SKILL": dict(_NSK_DICT or {}),
            "NEGOTIATION_BUFF": dict(_NBF_DICT or {}),
            "GAME": dict(_GM_DICT or {}),
            "KZONE_POST": dict(_KZ_DICT or {}),
            "KZONE_MESSAGE": dict(_KZM_DICT or {}),
            "PHONE_MSG": dict(_PH_DICT or {}),
        }
        translations = []
        errors = []
        for i, item in enumerate(arr):
            if not isinstance(item, list):
                continue
            res = _validate_item(item, idx, available)
            translations.append(res.get("translation", str(item)))
            for er in res.get("errors", []):
                errors.append(f"第 {i+1} 行 👉 {er}")
        return 200, {"valid": len(errors) == 0, "translations": translations, "errors": errors, "status": "ok" if not errors else "logic_error"}

    @r.route("GET", r"/api/dicts")
    def dicts(_query=None, _body=None):
        return 200, {
            "key_maps": {
                "EvtCfg": DEFAULT_EVT_KEY_MAP,
                "TalkCfg": DEFAULT_TALK_KEY_MAP,
                "OptionCfg": DEFAULT_OPT_KEY_MAP,
                "PersonCfg": DEFAULT_PERSON_KEY_MAP,
                "PersonGrowCfg": DEFAULT_GROW_KEY_MAP,
                "KZoneContentCfg": DEFAULT_KZONE_KEY_MAP,
                "PhoneMsgCfg": DEFAULT_PHONE_KEY_MAP,
                "GiftEvtCfg": DEFAULT_GIFT_KEY_MAP,
                "InteractCfg": DEFAULT_INTERACT_KEY_MAP,
            },
            "game_dicts": {
                "items": ITEM_DICT,
                "roles": ROLE_DICT,
                "jobs": JOB_DICT,
                "bgm": {},
                "sound": {},
                "icons": {},
                "maps": MAP_DICT,
                "attrs": ATTR_DICT,
                "relations": RELATION_DICT,
                "bgs": BG_DICT,
                "turns": TURN_DICT,
                "audios": _build_audios(),
                "evt_types": _build_evt_types(),
                "badminton_models": BADMINTON_MODELS,
            },
            "story_dicts": {},
        }

    # ---------- AI 工具沙箱 ----------
    @r.route("GET", r"/api/tools/list")
    def tools_list(_query=None, _body=None):
        scope = (_query or {}).get("scope", "mod")
        path = (_query or {}).get("path", "")
        deep = (_query or {}).get("deep") in ("1", "true", "yes")
        root = STATE.sandbox_root(scope)
        if not os.path.isdir(root):
            return 200, {"root": root, "path": path, "entries": []}
        try:
            entries = fs_tools.list_dir(root, path, deep=deep)
        except SandboxError as e:
            return 400, {"error": str(e)}
        return 200, {"root": root, "path": path, "entries": entries}

    @r.route("GET", r"/api/tools/read")
    def tools_read(_query=None, _body=None):
        scope = (_query or {}).get("scope", "mod")
        path = (_query or {}).get("path", "")
        root = STATE.sandbox_root(scope)
        try:
            payload = fs_tools.read_file(root, path)
        except SandboxError as e:
            return 400, {"error": str(e)}
        return 200, payload

    @r.route("PUT", r"/api/tools/write")
    def tools_write(_query=None, _body=None):
        body = _body or {}
        scope = body.get("scope", "mod")
        path = str(body.get("path") or "")
        content = body.get("content", "")
        root = STATE.sandbox_root(scope)
        try:
            result = fs_tools.write_file(root, path, content,
                                         base64_mode=bool(body.get("base64")))
        except SandboxError as e:
            return 400, {"error": str(e)}
        return 200, result

    @r.route("GET", r"/api/tools/stat")
    def tools_stat(_query=None, _body=None):
        scope = (_query or {}).get("scope", "mod")
        path = (_query or {}).get("path", "")
        root = STATE.sandbox_root(scope)
        try:
            info = fs_tools.stat_path(root, path)
        except SandboxError as e:
            return 400, {"error": str(e)}
        return 200, info

    # ---------- AI 细分领域（剧情 / 背景 / 人物…） ----------
    # 让 AI 以「领域 + 条目」粒度修改模组内容，而不是直接读写整份文件。
    @r.route("GET", r"/api/ai/domains")
    def ai_domains(_query=None, _body=None):
        return 200, {"domains": ai_domain_service.get_domains()}

    @r.route("GET", r"/api/ai/dicts")
    def ai_dicts(_query=None, _body=None):
        name = (_query or {}).get("name", "")
        q = (_query or {}).get("q", "")
        limit = (_query or {}).get("limit")
        try:
            if not name:
                return 200, {"dicts": ai_domain_service.list_dicts()}
            return 200, ai_domain_service.get_dict(name, q=q, limit=limit)
        except SandboxError as e:
            return 400, {"error": str(e)}

    @r.route("GET", r"/api/ai/domain/items")
    def ai_domain_items(_query=None, _body=None):
        query = _query or {}
        try:
            result = ai_domain_service.list_domain_items(
                str(query.get("domain") or ""),
                q=query.get("q"),
                limit=query.get("limit"),
                table=query.get("table"),
            )
        except SandboxError as e:
            return 400, {"error": str(e)}
        return 200, result

    @r.route("GET", r"/api/ai/domain/item")
    def ai_domain_item(_query=None, _body=None):
        query = _query or {}
        try:
            result = ai_domain_service.get_domain_item(
                str(query.get("domain") or ""),
                str(query.get("cfg") or ""),
                str(query.get("id") or ""),
            )
        except SandboxError as e:
            return 400, {"error": str(e)}
        return 200, result

    @r.route("PUT", r"/api/ai/domain/item")
    def ai_domain_item_update(_query=None, _body=None):
        body = _body or {}
        try:
            result = ai_domain_service.update_domain_item(
                str(body.get("domain") or ""),
                str(body.get("cfg") or ""),
                str(body.get("id") or ""),
                body.get("patch"),
            )
        except SandboxError as e:
            return 400, {"error": str(e)}
        return 200, result

    @r.route("POST", r"/api/ai/domain/item")
    def ai_domain_item_create(_query=None, _body=None):
        body = _body or {}
        try:
            result = ai_domain_service.create_domain_item(
                str(body.get("domain") or ""),
                str(body.get("cfg") or ""),
                body.get("id"),
                body.get("data"),
            )
        except SandboxError as e:
            return 400, {"error": str(e)}
        return 200, result

    @r.route("DELETE", r"/api/ai/domain/item")
    def ai_domain_item_delete(_query=None, _body=None):
        query = _query or {}
        try:
            result = ai_domain_service.delete_domain_item(
                str(query.get("domain") or ""),
                str(query.get("cfg") or ""),
                str(query.get("id") or ""),
            )
        except SandboxError as e:
            return 400, {"error": str(e)}
        return 200, result

    # ---------- AI 图片生成（openai-image-api：images/generations / images/edits） ----------
    # 生成与修改图片走 OpenAI Images API 标准；key/base_url 由前端设置传入，
    # 图片不在此处保存——前端审批后把返回的 b64 写入模组（/api/tools/write）。
    @r.route("POST", r"/api/ai/image/generate")
    def ai_image_generate(_query=None, _body=None):
        body = _body or {}
        try:
            return 200, ai_image_service.generate_images(
                api_key=str(body.get("api_key") or ""),
                base_url=str(body.get("base_url") or ""),
                model=str(body.get("model") or "") or None,
                prompt=str(body.get("prompt") or ""),
                n=body.get("n", 1),
                size=str(body.get("size") or "") or None,
                quality=str(body.get("quality") or "") or None,
                style=str(body.get("style") or "") or None,
                background=str(body.get("background") or "") or None,
            )
        except ai_image_service.ImageGenError as e:
            return 400, {"error": str(e)}

    @r.route("POST", r"/api/ai/image/edit")
    def ai_image_edit(_query=None, _body=None):
        body = _body or {}
        try:
            return 200, ai_image_service.edit_image(
                api_key=str(body.get("api_key") or ""),
                base_url=str(body.get("base_url") or ""),
                model=str(body.get("model") or "") or None,
                prompt=str(body.get("prompt") or ""),
                image_b64=body.get("image_base64") or None,
                image_mime=str(body.get("image_mime") or "image/png"),
                mask_b64=body.get("mask_base64") or None,
                n=body.get("n", 1),
                size=str(body.get("size") or "") or None,
            )
        except ai_image_service.ImageGenError as e:
            return 400, {"error": str(e)}

    # ---------- 配音（TTS：阿里云 DashScope 百炼 / MiniMax T2A V2） ----------
    # 配置存 .editor_ai.json（env_store，字段前缀 tts*，GUI/CLI/TUI 三端共享）；
    # 合成不落盘（职责单一），保存由 /api/tts/save 写入 mod（fs_tools 沙箱）并登记 AudioCfg。
    @r.route("GET", r"/api/tts/settings")
    def tts_settings_get(_query=None, _body=None):
        try:
            from editor.core.env_store import read_ai_settings
            return 200, {"settings": read_ai_settings()}
        except Exception as e:
            return 500, {"error": "%s: %s" % (type(e).__name__, e)}

    @r.route("PUT", r"/api/tts/settings")
    def tts_settings_put(_query=None, _body=None):
        body = _body or {}
        patch = body.get("settings", body)
        if not isinstance(patch, dict):
            return 400, {"error": "body must be a settings object"}
        # 只接收 tts* 字段，避免误改对话/生图配置
        tts_patch = {k: v for k, v in patch.items() if k.startswith("tts")}
        try:
            from editor.core.env_store import write_ai_settings
            return 200, {"ok": True, "settings": write_ai_settings(tts_patch)}
        except Exception as e:
            return 500, {"error": "%s: %s" % (type(e).__name__, e)}

    @r.route("POST", r"/api/tts/test")
    def tts_test(_query=None, _body=None):
        body = _body or {}
        try:
            return 200, tts_service.test_connection(
                provider=str(body.get("provider") or ""),
                settings=body.get("settings") or {},
                params=body.get("params") or {},
            )
        except Exception as e:
            return 500, {"error": "%s: %s" % (type(e).__name__, e)}

    @r.route("GET", r"/api/tts/voices")
    def tts_voices(_query=None, _body=None):
        q = _query or {}
        try:
            from editor.core.env_store import read_ai_settings
            settings = read_ai_settings()
            provider = str(q.get("provider") or settings.get("ttsProvider") or "")
            voices, source = tts_service.list_voices(provider, settings)
            return 200, {"voices": voices, "source": source, "provider": provider}
        except tts_service.TtsError as e:
            return 400, {"error": str(e)}
        except Exception as e:
            return 500, {"error": "%s: %s" % (type(e).__name__, e)}

    @r.route("POST", r"/api/tts/synthesize")
    def tts_synthesize(_query=None, _body=None):
        body = _body or {}
        try:
            from editor.core.env_store import read_ai_settings
            settings = read_ai_settings()
            provider = str(body.get("provider") or settings.get("ttsProvider") or "")
            audio, ext = tts_service.synthesize(
                provider=provider,
                text=str(body.get("text") or ""),
                voice=str(body.get("voice") or "") or None,
                settings=settings,
                params=body.get("params") or {},
            )
            import base64 as _b64
            return 200, {
                "audio": _b64.b64encode(audio).decode("ascii"),
                "ext": ext,
                "bytes": len(audio),
            }
        except tts_service.TtsError as e:
            return 400, {"error": str(e)}
        except Exception as e:
            return 500, {"error": "%s: %s" % (type(e).__name__, e)}

    @r.route("POST", r"/api/tts/save")
    def tts_save(_query=None, _body=None):
        """把合成音频写入当前 mod（audio/tts/），并按需登记 AudioCfg 行。"""
        body = _body or {}
        import base64 as _b64
        try:
            audio = _b64.b64decode(str(body.get("audio") or ""), validate=False)
        except Exception:
            return 400, {"error": "audio base64 decode failed"}
        if not STATE.mod_root:
            return 400, {"error": "未选择模组"}
        # 只认真布尔（或字符串 "true"），避免 "false"/"0" 被当成 True 触发无谓转码
        ogg_flag = body.get("ogg")
        ogg = ogg_flag is True or str(ogg_flag).strip().lower() == "true"
        try:
            saved = tts_store.save_audio(
                STATE.mod_root, audio, str(body.get("ext") or "wav"),
                key=str(body.get("key") or "") or None,
                ogg=ogg)
        except tts_store.TtsStoreError as e:
            return 400, {"error": str(e)}
        audio_cfg_id = None
        if body.get("writeCfg"):
            try:
                audio_cfg_id = _tts_register_audio_cfg(saved["key"], body)
            except Exception as e:
                return 200, {"ok": True, **saved, "audioCfgId": None,
                             "warning": "文件已保存，登记 AudioCfg 失败: %s" % e}
        # 配音打通：bindTalkId 非空时把 TalkCfg.audio 指向新登记的 AudioCfg id
        # （引擎的逐句配音通道为 TalkCfg.audio，vocals 不被引擎消费）；
        # 走 tts_store.bind_talk_audio 统一写入口并失效配置/预览缓存。
        bind_talk = str(body.get("bindTalkId") or "").strip()
        if audio_cfg_id is not None and bind_talk:
            try:
                tts_store.bind_talk_audio(STATE.mod_root, bind_talk, audio_cfg_id)
                _invalidate_mod_cfgs_cache()
                try:
                    from editor.server import preview_service as _ps
                    _ps.invalidate_cache()
                except Exception:
                    pass
            except tts_store.TtsStoreError as e:
                return 200, {"ok": True, **saved, "audioCfgId": audio_cfg_id,
                             "warning": "音频已保存并登记，绑定对白失败: %s" % e}
        return 200, {"ok": True, **saved, "audioCfgId": audio_cfg_id,
                     "boundTalkId": bind_talk or None}

    @r.route("GET", r"/api/tts/audio")
    def tts_audio(_query=None, _body=None):
        """读回 mod 内已保存的配音音频（base64 + ext），供面板重开后再试听。"""
        q = _query or {}
        rel = str(q.get("path") or "")
        if not rel:
            return 400, {"error": "path required"}
        try:
            blob = tts_store.read_audio(STATE.mod_root, rel)
        except tts_store.TtsStoreError as e:
            msg = str(e)
            # 仅「文件本身不存在」是 404；未选模组等前置条件问题统一 400
            return (404, {"error": msg}) if msg.startswith("文件不存在") \
                else (400, {"error": msg})
        import base64 as _b64
        ext = os.path.splitext(rel)[1].lstrip(".").lower() or "wav"
        return 200, {"path": rel, "ext": ext,
                     "audio": _b64.b64encode(blob).decode("ascii")}

    @r.route("GET", r"/api/tts/list")
    def tts_list(_query=None, _body=None):
        """列出当前 mod 的 audio/tts/ 下已保存的配音素材。"""
        try:
            items = tts_store.list_materials(STATE.mod_root)
        except tts_store.TtsStoreError as e:
            return 400, {"error": str(e)}
        return 200, {"items": items}

    @r.route("POST", r"/api/tts/delete")
    def tts_delete(_query=None, _body=None):
        """删除 mod 内一条已保存的配音素材（仅限 audio/tts/ 目录内）。"""
        body = _body or {}
        rel = str(body.get("path") or "")
        if not rel:
            return 400, {"error": "path required"}
        try:
            tts_store.delete_material(STATE.mod_root, rel)
        except tts_store.TtsStoreError as e:
            msg = str(e)
            # 仅「文件本身不存在」是 404；未选模组等前置条件问题统一 400
            return (404, {"error": msg}) if msg.startswith("文件不存在") \
                else (400, {"error": msg})
        return 200, {"ok": True, "path": rel}

    # ---------- AI 舞台调度（人物站位/移动/入场退场/表情/动作） ----------
    # 语义化指令 <-> TalkCfg.roles 编码，写回复用 /api/ai/domain/item（含备份与 schema 校验）。
    @r.route("GET", r"/api/ai/stage/dicts")
    def ai_stage_dicts(_query=None, _body=None):
        return 200, stage_service.get_stage_dicts()

    @r.route("GET", r"/api/ai/stage/roles")
    def ai_stage_roles(_query=None, _body=None):
        query = _query or {}
        try:
            return 200, stage_service.get_talk_stage(str(query.get("talk_id") or ""))
        except SandboxError as e:
            return 400, {"error": str(e)}

    @r.route("POST", r"/api/ai/stage/encode")
    def ai_stage_encode(_query=None, _body=None):
        body = _body or {}
        try:
            return 200, stage_service.encode_talk_stage(
                str(body.get("talk_id") or ""),
                body.get("commands"),
                clear=bool(body.get("clear")),
            )
        except SandboxError as e:
            return 400, {"error": str(e)}

    # ---------- AI 侧栏附件上传 ----------
    @r.route("POST", r"/api/ai/upload")
    def ai_upload(_query=None, _body=None):
        body = _body or {}
        name = str(body.get("name") or "").strip()
        data = str(body.get("data") or "")
        if not name:
            return 400, {"error": "缺少文件名 name"}
        if not data:
            return 400, {"error": "缺少文件内容 data（base64）"}
        try:
            import base64
            raw = base64.b64decode(data, validate=True)
        except Exception:
            return 400, {"error": "data 不是合法的 base64 编码"}
        if not raw:
            return 400, {"error": "文件内容为空"}
        if len(raw) > ai_files.MAX_FILE_BYTES:
            return 400, {"error": "文件过大：最大 %dMB"
                         % (ai_files.MAX_FILE_BYTES // 1048576)}
        try:
            result = ai_files.parse_file(name, raw)
        except ai_files.UploadError as e:
            return 400, {"error": str(e)}
        return 200, {"ok": True, **result}

    # ---------- 官方模组工具 ----------
    @r.route("GET", r"/api/manifest/status")
    def manifest_status(_query=None, _body=None):
        if not STATE.mod_root:
            return 200, {"selected": False, "checks": []}
        mpath = os.path.join(STATE.mod_root, "manifest.json")
        if not os.path.isfile(mpath):
            return 200, {"selected": True, "has_manifest": False,
                         "checks": [{"key": "manifest.json", "ok": False,
                                     "detail": "缺少 manifest.json"}]}
        try:
            with open(mpath, "r", encoding="utf-8-sig") as f:
                manifest = json.load(f)
        except Exception as e:
            return 200, {"selected": True, "has_manifest": True, "parse_error": str(e),
                         "checks": [{"key": "manifest.json", "ok": False,
                                     "detail": "解析失败: %s" % e}]}
        checks = []
        for key, label in (("title", "标题"), ("description", "简介"), ("version", "版本")):
            v = manifest.get(key)
            checks.append({"key": key, "label": label, "ok": bool(v),
                           "detail": str(v or "（缺失）")[:120]})
        cfg_dir = STATE._cfg_dir()
        cfg_count = 0
        if cfg_dir and os.path.isdir(cfg_dir):
            cfg_count = len([f for f in os.listdir(cfg_dir) if f.endswith(".json")])
        checks.append({"key": "cfgs", "label": "配置表", "ok": cfg_count > 0,
                       "detail": "%d 个 JSON 配置表" % cfg_count})
        return 200, {"selected": True, "has_manifest": True, "manifest": manifest,
                     "checks": checks}

    # ---------- Unity 资源 ----------
    def _ensure_aa_index():
        """确保 STATE.aa_index 可用：未扫描/未初始化时懒加载磁盘缓存索引。

        编辑器打包后 AA 索引由首次扫描写入 <editor根>/_cache/aa_index/aa_index.json，
        重新启动后端时 STATE.aa_index 为 None，预览/资源页需要图片时直接读缓存，
        避免「一直加载中」。返回索引实例；不可用时返回 None。
        """
        if STATE.aa_index is not None:
            return STATE.aa_index
        if UnityFsIndex is None:
            return None
        try:
            cache_root = os.path.join(_editor_root(), "_cache", "aa_index")
            detected = detect_game_aa_dir()
            dirs = [detected] if detected else []
            idx = UnityFsIndex(dirs, cache_root=cache_root)
            idx.try_load_cached()
            if len(idx.tex_keys()) == 0:
                return None
            STATE.aa_index = idx
            if STATE.aa_status in ("idle", "error"):
                STATE.aa_status = "ready"  # 缓存模式视为可用
            _ensure_role_bundles(idx, dirs)
            return idx
        except Exception:
            return None

    @r.route("GET", r"/api/aa/status")
    def aa_status(_query=None, _body=None):
        store = _ensure_pack_store()
        bundled = None
        if store is not None and store.active:
            pid, pname = _pack_active_info()
            bundled = {"active": pid, "name": pname,
                       "tex": store.tex_count(), "aud": store.aud_count()}
        return 200, {"status": STATE.aa_status, "dirs": STATE.aa_dirs,
                     "error": STATE.aa_error,
                     "detected": detect_game_aa_dir(),
                     "bundled": bundled}

    @r.route("POST", r"/api/aa/scan")
    def aa_scan(_query=None, _body=None):
        if UnityFsIndex is None:
            return 500, {"error": "unityfs unavailable"}
        if STATE.aa_status in ("scanning", "ready"):
            return 200, {"status": STATE.aa_status}
        body = _body or {}
        dirs = [d for d in (body.get("dirs") or []) if d]
        if not dirs:
            detected = detect_game_aa_dir()
            dirs = [detected] if detected else []
        STATE.aa_dirs = dirs
        STATE.aa_status = "scanning"
        STATE.aa_error = ""

        def work():
            try:
                cache_root = os.path.join(_editor_root(), "_cache", "aa_index")
                idx = UnityFsIndex(dirs, cache_root=cache_root)
                # include_slow=True：角色立绘/音频 bundle（文件名含 _role_）
                # 体量大但包含大量立绘，手动全量扫描必须纳入，否则预览立绘空白
                idx.scan(include_slow=True)
                STATE.aa_index = idx
                STATE.aa_status = "ready"
            except Exception as e:
                STATE.aa_status = "error"
                STATE.aa_error = "%s: %s" % (type(e).__name__, e)

        threading.Thread(target=work, daemon=True).start()
        return 200, {"status": "scanning"}

    @r.route("GET", r"/api/aa/keys")
    def aa_keys(_query=None, _body=None):
        idx = _ensure_aa_index()
        store = _ensure_pack_store()
        query = _query or {}
        q = (query.get("q") or "").strip().lower()
        limit = int(query.get("limit") or 500)
        scope = (query.get("scope") or "").strip().lower()

        # 游戏索引与内置包键集合取并集（去重），统一按数量截断
        def pick(*groups):
            out = []
            seen = set()
            for keys in groups:
                for k in keys:
                    if k in seen:
                        continue
                    seen.add(k)
                    if q and q not in k.lower():
                        continue
                    out.append(k)
                    if len(out) >= limit:
                        break
                if len(out) >= limit:
                    break
            return out

        # ---------- scope=flow：剧情图媒体资产（仅 CG 图片 + 音乐） ----------
        if scope == "flow":
            # BGM 判定信号：base + mod 的 AudioCfg（type==1 的 url basename）
            audio_rows = {}
            base = STATE.base
            if base is not None:
                try:
                    audio_rows.update((base.data or {}).get("AudioCfg") or {})
                except Exception:
                    pass
            try:
                audio_rows.update(_load_mod_cfgs().get("AudioCfg") or {})
            except Exception:
                pass
            music_urls = flow_assets.music_url_basenames(audio_rows)
            # 纹理过滤可行性：游戏索引已按 v3 重扫（带 texmeta），或内置包可读图头
            tex_filterable = bool(idx is not None and idx.has_texmeta()) \
                or bool(store is not None and store.active)

            def flow_pick(groups, keep):
                """groups=[(keys, bundle_fn, size_fn), ...]，keep(k, bundle, size)。"""
                out = []
                seen = set()
                for keys, bundle_fn, size_fn in groups:
                    for k in keys or []:
                        if k in seen:
                            continue
                        seen.add(k)
                        if q and q not in k.lower():
                            continue
                        size = size_fn(k) if size_fn else None
                        if keep(k, bundle_fn(k) if bundle_fn else "", size):
                            out.append(k)
                        if len(out) >= limit:
                            return out
                return out

            tex_groups = []
            if idx is not None:
                tex_groups.append((idx.tex_keys(), idx.tex_bundle, idx.tex_meta))
            if store is not None and store.active:
                tex_groups.append((store.tex_keys(), store.tex_path, store.tex_meta))
            aud_groups = []
            if idx is not None:
                aud_groups.append((idx.aud_keys(), idx.aud_bundle, None))
            if store is not None and store.active:
                aud_groups.append((store.aud_keys(), None, None))

            tex = flow_pick(
                tex_groups,
                lambda k, b, s: (not tex_filterable)
                or flow_assets.is_cg_image(k, b, (s or [0, 0])[0], (s or [0, 0])[1]))
            # 过滤后全空但源不缺 key：判据不可用（如旧索引/无 PIL），回退全量
            tex_had_source = any(keys for keys, _, _ in tex_groups)
            if not tex and tex_had_source and not q:
                tex_filterable = False
                tex = flow_pick(tex_groups, lambda k, b, s: True)
            # 音乐：bundle 分组/表信号恒可用；两者皆缺时回退全量并标记未过滤
            music_filterable = bool(idx is not None) or bool(music_urls)
            aud = flow_pick(
                aud_groups,
                lambda k, b, s: (not music_filterable) or flow_assets.is_music(k, b, music_urls))
            meta = {}
            if tex_filterable:
                for k in tex:
                    for keys, _, size_fn in tex_groups:
                        if k in (keys or []) and size_fn:
                            s = size_fn(k)
                            if s:
                                meta[k] = s
                            break
            status = "ready" if (idx is not None or (store is not None and store.active)) else STATE.aa_status
            return 200, {"status": status, "tex": tex, "aud": aud,
                         "txt": pick(idx.txt_keys() if idx else [],
                                     store.txt_keys() if store else []),
                         "meta": meta, "flow_filtered": bool(tex_filterable)}

        tex = pick(idx.tex_keys() if idx else [], store.tex_keys() if store else [])
        aud = pick(idx.aud_keys() if idx else [], store.aud_keys() if store else [])
        txt = pick(idx.txt_keys() if idx else [], store.txt_keys() if store else [])
        status = "ready" if (idx is not None or (store is not None and store.active)) else STATE.aa_status
        return 200, {"status": status, "tex": tex, "aud": aud, "txt": txt}

    @r.route("POST", r"/api/aa/export")
    def aa_export(_query=None, _body=None):
        idx = _ensure_aa_index()
        store = _ensure_pack_store()
        if idx is None and (store is None or not store.active):
            return 400, {"error": "index not ready"}
        body = _body or {}
        kind = body.get("kind")  # tex | aud | txt
        key = str(body.get("key") or "")
        out_rel = str(body.get("out") or "")
        if not kind or not key:
            return 400, {"error": "kind/key required"}
        if not STATE.mod_root:
            return 400, {"error": "no mod selected"}
        try:
            out_abs = fs_tools.resolve(STATE.mod_root, out_rel)
        except SandboxError as e:
            # 输出路径越界：与 tools_* 系列保持一致返回 400
            return 400, {"error": str(e)}
        try:
            os.makedirs(os.path.dirname(out_abs), exist_ok=True)
            if kind == "tex":
                exported = False
                if idx is not None and idx.has_tex(key):
                    exported = idx.export_tex_png(key, out_abs)
                if not exported:
                    # 内置包回落：直接拷贝解码文件
                    r = store.read_file(store.tex_path(key)) if store is not None else None
                    if r is None:
                        if idx is not None and idx.has_tex(key):
                            return 422, {"error": "texture decode failed: %s" % key}
                        return 404, {"error": "texture key not found: %s" % key}
                    with open(out_abs, "wb") as f:
                        f.write(r[0])
            elif kind == "aud":
                exported = False
                if idx is not None and idx.has_aud(key):
                    exported = idx.export_audio(key, out_abs)
                if not exported:
                    r = store.read_file(store.aud_path(key)) if store is not None else None
                    if r is None:
                        if idx is not None and idx.has_aud(key):
                            return 422, {"error": "audio decode failed: %s" % key}
                        return 404, {"error": "audio key not found: %s" % key}
                    with open(out_abs, "wb") as f:
                        f.write(r[0])
            elif kind == "txt":
                if idx is not None and idx.has_txt(key):
                    # export_text 返回原始字节（utf-8 编码的配置表内容），必须用二进制模式写入
                    data = idx.export_text(key)
                    if data is None:
                        return 422, {"error": "text decode failed: %s" % key}
                    with open(out_abs, "wb") as f:
                        f.write(data)
                else:
                    return 404, {"error": "text key not found: %s" % key}
            else:
                return 400, {"error": "bad kind"}
        except Exception as e:
            return 500, {"error": "%s: %s" % (type(e).__name__, e)}
        return 200, {"ok": True, "out": out_rel}

    @r.route("POST", r"/api/aa/preview")
    def aa_preview(_query=None, _body=None):
        """预览 AA 资源内容：tex → PNG base64，aud → 音频 base64+ext，txt → 文本（截断）。"""
        idx = _ensure_aa_index()
        store = _ensure_pack_store()
        if idx is None and (store is None or not store.active):
            return 400, {"error": "index not ready"}
        body = _body or {}
        kind = body.get("kind")  # tex | aud | txt
        key = str(body.get("key") or "")
        if not kind or not key:
            return 400, {"error": "kind/key required"}
        import base64 as _b64
        try:
            if kind == "tex":
                data = None
                found = False
                if idx is not None and idx.has_tex(key):
                    found = True
                    data = idx.preview_tex_png(key)
                if data is None:
                    # 内置包回落（Android 无游戏目录时）
                    if store is not None:
                        r = store.read_file(store.tex_path(key))
                        if r is not None:
                            blob, ext = r
                            return 200, {"kind": "tex",
                                         "mime": decoded_pack._TEX_MIME.get(ext, "application/octet-stream"),
                                         "data": _b64.b64encode(blob).decode("ascii")}
                    if found:
                        return 422, {"error": "texture decode failed: %s" % key}
                    return 404, {"error": "texture key not found: %s" % key}
                return 200, {"kind": "tex", "mime": "image/png",
                             "data": _b64.b64encode(data).decode("ascii")}
            if kind == "aud":
                blob = None
                ext = ""
                found = False
                if idx is not None and idx.has_aud(key):
                    found = True
                    result = idx.preview_audio(key)
                    if result is not None:
                        blob, ext = result
                if blob is None:
                    # 内置包回落
                    if store is not None:
                        r = store.read_file(store.aud_path(key))
                        if r is not None:
                            blob, ext = r
                            return 200, {"kind": "aud",
                                         "mime": decoded_pack._AUD_MIME.get(ext, "application/octet-stream"),
                                         "ext": ext,
                                         "data": _b64.b64encode(blob).decode("ascii")}
                    if found:
                        return 422, {"error": "audio decode failed: %s" % key}
                    return 404, {"error": "audio key not found: %s" % key}
                mime = {".ogg": "audio/ogg", ".wav": "audio/wav",
                        ".m4a": "audio/mp4"}.get(ext, "application/octet-stream")
                return 200, {"kind": "aud", "mime": mime, "ext": ext,
                             "data": _b64.b64encode(blob).decode("ascii")}
            if kind == "txt":
                if not idx.has_txt(key):
                    return 404, {"error": "text key not found: %s" % key}
                data = idx.export_text(key)
                if data is None:
                    return 422, {"error": "text decode failed: %s" % key}
                text = data.decode("utf-8", errors="replace")
                truncated = False
                # 配置表可能极大，预览只返回前 200K 字符
                if len(text) > 200000:
                    text = text[:200000]
                    truncated = True
                return 200, {"kind": "txt", "text": text, "truncated": truncated}
            return 400, {"error": "bad kind"}
        except Exception as e:
            return 500, {"error": "%s: %s" % (type(e).__name__, e)}

    # ---------- 本体（原版）配置数据：检索 / 提取 / 台词搜索 ----------
    @r.route("GET", r"/api/base/status")
    def base_status(_query=None, _body=None):
        return 200, STATE.base.status_dict()

    @r.route("POST", r"/api/base/load")
    def base_load(_query=None, _body=None):
        body = _body or {}
        force = bool(body.get("force"))
        started = STATE.base.load_async(force=force)
        return 200, {"started": started, **STATE.base.status_dict()}

    @r.route("GET", r"/api/base/events")
    def base_events(_query=None, _body=None):
        if STATE.base.status != "ready":
            return 409, {"error": "base data not ready", **STATE.base.status_dict()}
        q = (_query or {}).get("q", "")
        npc = (_query or {}).get("npc", "")
        evt_type = (_query or {}).get("type", "")
        page = (_query or {}).get("page", "1")
        per_page = (_query or {}).get("per_page", "50")
        return 200, STATE.base.search_events(
            keyword=q, npc_id=npc, evt_type=evt_type,
            page=page, per_page=per_page,
        )

    @r.route("POST", r"/api/base/extract")
    def base_extract(_query=None, _body=None):
        body = _body or {}
        evt_id = str(body.get("evt_id") or "")
        if not evt_id:
            return 400, {"error": "evt_id required"}
        if STATE.base.status != "ready":
            return 409, {"error": "base data not ready"}
        if not STATE.mod_root:
            return 400, {"error": "no mod selected"}
        delta = STATE.base.extract_event(evt_id)
        if not delta:
            return 404, {"error": "event not found in base data: %s" % evt_id}
        mod_cfgs = _load_mod_cfgs()
        counts = {}
        for cfg_name, records in delta.items():
            bucket = mod_cfgs.setdefault(cfg_name, {})
            for rid, record in records.items():
                bucket[rid] = record  # 覆盖式合并：原版事件整体复制进 Mod
            counts[cfg_name] = len(records)
            _save_mod_cfg(cfg_name, bucket)
        return 200, {"ok": True, "evt_id": evt_id, "imported": counts}

    @r.route("GET", r"/api/search/talk")
    def search_talk(_query=None, _body=None):
        q = (_query or {}).get("q", "")
        limit = int((_query or {}).get("limit") or 150)
        mod_cfgs = _load_mod_cfgs() if STATE.mod_root else {}
        return 200, {
            "results": STATE.base.search_talks(
                q,
                mod_talk=mod_cfgs.get("TalkCfg", {}),
                mod_evt=mod_cfgs.get("EvtCfg", {}),
                limit=limit,
            ),
        }

    # ---------- 故事剧本文本：导出 / 导入 ----------
    @r.route("POST", r"/api/story/export")
    def story_export(_query=None, _body=None):
        body = _body or {}
        evt_ids = [str(x) for x in (body.get("evt_ids") or []) if x]
        if not evt_ids:
            return 400, {"error": "evt_ids required"}
        if not STATE.mod_root:
            return 400, {"error": "no mod selected"}
        mod_cfgs = _load_mod_cfgs()
        role_dict = dict(ROLE_DICT)
        for k, v in (mod_cfgs.get("PersonCfg", {}) or {}).items():
            if isinstance(v, dict) and v.get("name"):
                role_dict[str(k)] = v["name"]
        opts = body.get("opts") or {}
        dual = body.get("dual_choice") or "both"
        try:
            text = story_service.export_story(
                mod_cfgs.get("EvtCfg", {}), mod_cfgs.get("TalkCfg", {}),
                mod_cfgs.get("OptionCfg", {}), role_dict,
                evt_ids, opts=opts, dual_choice=dual,
            )
        except Exception as e:
            return 500, {"error": "%s: %s" % (type(e).__name__, e)}
        return 200, {"text": text, "evt_ids": evt_ids}

    @r.route("POST", r"/api/story/import")
    def story_import(_query=None, _body=None):
        body = _body or {}
        start_id = str(body.get("start_id") or "")
        text = str(body.get("text") or "")
        write = bool(body.get("write"))
        append = bool(body.get("append"))
        if not start_id or not text.strip():
            return 400, {"error": "start_id and text required"}
        if write and not STATE.mod_root:
            return 400, {"error": "no mod selected"}
        mod_cfgs = _load_mod_cfgs() if write or STATE.mod_root else {}
        role_dict = dict(ROLE_DICT)
        for k, v in (mod_cfgs.get("PersonCfg", {}) or {}).items():
            if isinstance(v, dict) and v.get("name"):
                role_dict[str(k)] = v["name"]
        # ScriptParser 需要 {名字: id} 映射（与友商 StoryImporterDialog 一致）
        name_to_id = {}
        for rid, rname in role_dict.items():
            if not rname or rname in name_to_id:
                continue
            try:
                name_to_id[str(rname)] = int(rid)
            except (ValueError, TypeError):
                name_to_id[str(rname)] = rid
        try:
            parsed = story_service.parse_script(start_id, text, name_to_id)
        except Exception as e:
            return 500, {"error": "%s: %s" % (type(e).__name__, e)}
        if write:
            bucket = mod_cfgs.setdefault("TalkCfg", {})
            if not append:
                # 清空导入：删除该事件原有的全部对白（与友商行为一致）
                target = start_id
                for tid in [str(k) for k in list(bucket.keys())]:
                    ts = str(tid)
                    if (len(ts) > 3 and ts[:-3] == target) or \
                       (len(ts) > 2 and ts[:-2] == target) or ts == target:
                        bucket.pop(tid, None)
            for tid, record in parsed.items():
                bucket[tid] = record
            _save_mod_cfg("TalkCfg", bucket)
            # 绑定事件起始对白（与友商一致：非追加或 talkId 为空时设置）
            evt_bucket = mod_cfgs.get("EvtCfg", {})
            evt = evt_bucket.get(start_id)
            if isinstance(evt, dict) and (not append or not evt.get("talkId")):
                evt["talkId"] = [int(start_id) * 1000 + 1]
                _save_mod_cfg("EvtCfg", evt_bucket)
        preview = sorted(parsed.items(), key=lambda kv: int(kv[0]))[:200]
        return 200, {
            "ok": True, "write": write, "count": len(parsed),
            "preview": preview,
        }

    # ---------- 事件场景预览 ----------
    @r.route("POST", r"/api/preview/event")
    def preview_event(_query=None, _body=None):
        """组装事件场景预览数据（对白链 + 舞台状态 + 资源 key 映射）。"""
        body = _body or {}
        evt_id = str(body.get("evt_id") or "").strip()
        if not evt_id:
            return 400, {"error": "evt_id required"}
        try:
            data = preview_service.preview_event(evt_id)
        except SandboxError as e:
            return 400, {"error": str(e)}
        except Exception as e:
            return 500, {"error": "%s: %s" % (type(e).__name__, e)}
        return 200, data

    # ---------- 数据诊断与一键修复 ----------
    @r.route("POST", r"/api/bugfix/scan")
    def bugfix_scan(_query=None, _body=None):
        if not STATE.mod_root:
            return 400, {"error": "no mod selected"}
        mod_cfgs = _load_mod_cfgs()
        base_data = STATE.base.data if STATE.base.status == "ready" else {}
        bugs = bugfix_service.scan_bugs(mod_cfgs, base_data)
        return 200, {"bugs": bugs, "count": len(bugs)}

    @r.route("POST", r"/api/bugfix/fix")
    def bugfix_fix(_query=None, _body=None):
        body = _body or {}
        if not STATE.mod_root:
            return 400, {"error": "no mod selected"}
        mod_cfgs = _load_mod_cfgs()
        base_data = STATE.base.data if STATE.base.status == "ready" else {}
        bugs = bugfix_service.scan_bugs(mod_cfgs, base_data)

        targets = body.get("bugs")
        if targets is None:
            targets = bugs
        fixed = 0
        touched = set()
        for bug in targets:
            if not isinstance(bug, dict):
                continue
            # 重新定位：按 (cfg, id, key) 匹配当前扫描结果，防止使用过期数据
            matched = next((b for b in bugs if b.get("cfg") == bug.get("cfg")
                            and str(b.get("id")) == str(bug.get("id"))
                            and b.get("key") == bug.get("key")), None)
            if matched is None:
                continue
            if bugfix_service.apply_fix(mod_cfgs, matched):
                fixed += 1
                touched.add(matched["cfg"])
                if matched["flag"] in ("FIX_OPTION_1", "FIX_TALK_1"):
                    touched.update(("TalkCfg", "OptionCfg"))

        for cfg_name in touched:
            _save_mod_cfg(cfg_name, mod_cfgs.get(cfg_name, {}))

        remaining = bugfix_service.scan_bugs(mod_cfgs, base_data)
        return 200, {"fixed": fixed, "remaining": remaining,
                     "remaining_count": len(remaining)}




    # ---------- 资源扩展包 (Zip) ----------
    @r.route("GET", r"/api/resource_packs")
    def rp_list(_query=None, _body=None):
        try:
            meta = resource_pack.list_packs()
        except Exception as e:
            return 500, {"error": "%s: %s" % (type(e).__name__, e)}
        return 200, meta

    @r.route("POST", r"/api/resource_packs/install")
    def rp_install(_query=None, _body=None):
        body = _body or {}
        b64 = body.get("data") or body.get("zip_base64") or ""
        filename = body.get("filename") or body.get("name") or "pack.zip"
        if not b64:
            return 400, {"error": "zip_base64 required"}
        try:
            import base64
            raw = base64.b64decode(b64, validate=True)
        except Exception:
            return 400, {"error": "invalid base64"}
        if len(raw) > 500 * 1024 * 1024:
            return 400, {"error": "zip too large"}
        try:
            result = resource_pack.install_pack(raw, filename)
        except ValueError as e:
            return 400, {"error": str(e)}
        except Exception as e:
            return 500, {"error": "%s: %s" % (type(e).__name__, e)}
        return 200, result

    @r.route("POST", r"/api/resource_packs/active")
    def rp_active(_query=None, _body=None):
        body = _body or {}
        pid = body.get("id") or body.get("pack_id") or ""
        try:
            meta = resource_pack.set_active(pid)
        except ValueError as e:
            return 400, {"error": str(e)}
        except Exception as e:
            return 500, {"error": "%s: %s" % (type(e).__name__, e)}
        return 200, meta

    @r.route("DELETE", r"/api/resource_packs/(?P<pid>[^/]+)")
    def rp_delete(pid, _query=None, _body=None):
        try:
            meta = resource_pack.uninstall_pack(pid)
        except ValueError as e:
            return 400, {"error": str(e)}
        except Exception as e:
            return 500, {"error": "%s: %s" % (type(e).__name__, e)}
        return 200, meta

    @r.route("GET", r"/api/resource_packs/(?P<pid>[^/]+)")
    def rp_info(pid, _query=None, _body=None):
        info = resource_pack.get_pack_info(pid)
        if not info:
            return 404, {"error": "pack not found"}
        return 200, info

    @r.route("POST", r"/api/resource_packs/import_path")
    def rp_import_path(_query=None, _body=None):
        """按本地路径导入资源包 zip（移动端文件选择器导入：绕 base64 与 500MB）。

        前端先拷贝到其可写临时目录再提交路径；文件保留在原地不清理。
        """
        body = _body or {}
        path = str(body.get("path") or "")
        if not path:
            return 400, {"error": "path required"}
        filename = body.get("filename") or os.path.basename(path) or "pack.zip"
        try:
            result = resource_pack.install_pack_from_path(path, filename)
        except ValueError as e:
            return 400, {"error": str(e)}
        except Exception as e:
            return 500, {"error": "%s: %s" % (type(e).__name__, e)}
        return 200, result

    # ---------- 云端同步 (类 OpenList，单文件) ----------
    @r.route("GET", r"/api/cloud/providers")
    def cloud_list(_query=None, _body=None):
        try:
            providers = cloud_sync.list_providers()
            # 脱敏：不返回完整 token
            safe = []
            for p in providers:
                cfg = dict(p.get("config") or {})
                for k in list(cfg.keys()):
                    if "token" in k.lower() or "password" in k.lower() or "pass" in k.lower():
                        cfg[k] = "***" if cfg[k] else ""
                safe.append({**p, "config": cfg})
            return 200, {"providers": safe, "drivers": list(cloud_sync.DRIVERS.keys())}
        except Exception as e:
            return 500, {"error": "%s: %s" % (type(e).__name__, e)}

    @r.route("POST", r"/api/cloud/providers")
    def cloud_add(_query=None, _body=None):
        body = _body or {}
        try:
            entry = cloud_sync.add_provider(body)
        except ValueError as e:
            return 400, {"error": str(e)}
        except Exception as e:
            return 500, {"error": "%s: %s" % (type(e).__name__, e)}
        return 200, {"provider": entry}

    @r.route("PUT", r"/api/cloud/providers/(?P<pid>[^/]+)")
    def cloud_update(pid, _query=None, _body=None):
        body = _body or {}
        # 修复脱敏回写 bug：若前端误将 "***" 作为密码 token 回写，需还原为原值
        try:
            if "config" in body and isinstance(body["config"], dict):
                orig = cloud_sync.get_provider(pid)
                if orig and isinstance(orig.get("config"), dict):
                    orig_cfg = orig.get("config") or {}
                    for k, v in list(body["config"].items()):
                        if v == "***" and k in orig_cfg:
                            body["config"][k] = orig_cfg[k]
        except Exception:
            pass
        try:
            entry = cloud_sync.update_provider(pid, body)
        except ValueError as e:
            return 400, {"error": str(e)}
        except Exception as e:
            return 500, {"error": "%s: %s" % (type(e).__name__, e)}
        return 200, {"provider": entry}

    @r.route("DELETE", r"/api/cloud/providers/(?P<pid>[^/]+)")
    def cloud_delete(pid, _query=None, _body=None):
        try:
            cloud_sync.remove_provider(pid)
        except ValueError as e:
            return 400, {"error": str(e)}
        except Exception as e:
            return 500, {"error": "%s: %s" % (type(e).__name__, e)}
        return 200, {"ok": True}

    @r.route("POST", r"/api/cloud/test")
    def cloud_test(_query=None, _body=None):
        body = _body or {}
        ptype = body.get("type") or body.get("driver") or ""
        cfg = body.get("config") or {}
        provider_id = body.get("provider_id") or body.get("id") or ""
        try:
            if provider_id:
                prov = cloud_sync.get_provider(provider_id)
                if not prov:
                    return 404, {"error": "provider not found"}
                drv = cloud_sync.get_driver(prov.get("type"), prov.get("config"))
            else:
                if not ptype:
                    return 400, {"error": "type or provider_id required"}
                drv = cloud_sync.get_driver(ptype, cfg)
            drv.test()
        except ValueError as e:
            return 400, {"error": str(e)}
        except Exception as e:
            return 500, {"error": "%s: %s" % (type(e).__name__, e)}
        return 200, {"ok": True}

    @r.route("GET", r"/api/cloud/status")
    def cloud_status(_query=None, _body=None):
        return 200, cloud_sync.sync_status()

    @r.route("POST", r"/api/cloud/sync")
    def cloud_sync_api(_query=None, _body=None):
        body = _body or {}
        provider_id = body.get("provider_id") or body.get("id") or ""
        direction = (body.get("direction") or "upload").lower()
        mod_name = body.get("mod_name") or body.get("mod") or STATE.mod_name
        rel_paths = body.get("files") or body.get("rel_paths") or body.get("paths") or []
        dry_run = bool(body.get("dry_run") or body.get("dryRun"))
        delete_extra = bool(body.get("delete_extra") or body.get("deleteExtra"))
        if not provider_id:
            return 400, {"error": "provider_id required"}
        if direction not in ("upload", "download", "delete_remote", "delete_local", "sync"):
            return 400, {"error": "invalid direction"}
        if not mod_name:
            return 400, {"error": "mod_name required (select mod first)"}
        # 兼容部分前端传 file 单个
        if isinstance(rel_paths, str):
            rel_paths = [rel_paths]
        if body.get("file"):
            rel_paths = [body.get("file")]
        if body.get("rel_path"):
            rel_paths = [body.get("rel_path")]
        # 若未指定 files，则视为整 Mod 文件夹同步（满足用户需求：云同步整个mod文件夹）
        is_folder = bool(body.get("folder") or body.get("full") or body.get("all"))
        if not rel_paths or is_folder:
            folder_dir = direction if direction in ("upload","download","sync") else "upload"
            try:
                res = cloud_sync.sync_mod_folder(provider_id, folder_dir, mod_name, dry_run=dry_run, delete_extra=delete_extra)
                return 200, res
            except ValueError as e:
                return 400, {"error": str(e)}
            except Exception as e:
                import traceback; traceback.print_exc()
                return 500, {"error": "%s: %s" % (type(e).__name__, e)}
        if not rel_paths:
            return 400, {"error": "files required (单文件或整文件夹需指定)"}
        try:
            res = cloud_sync.sync_mod_files(provider_id, direction, mod_name, rel_paths, dry_run=dry_run)
        except ValueError as e:
            return 400, {"error": str(e)}
        except Exception as e:
            import traceback; traceback.print_exc()
            return 500, {"error": "%s: %s" % (type(e).__name__, e)}
        return 200, res

    @r.route("POST", r"/api/cloud/file")
    def cloud_single(_query=None, _body=None):
        body = _body or {}
        provider_id = body.get("provider_id") or ""
        direction = (body.get("direction") or "upload").lower()
        mod_name = body.get("mod_name") or STATE.mod_name
        rel_path = body.get("rel_path") or body.get("file") or ""
        dry_run = bool(body.get("dry_run"))
        if not provider_id or not rel_path:
            return 400, {"error": "provider_id and rel_path required"}
        try:
            result = cloud_sync.sync_single_file(provider_id, direction, mod_name, rel_path, dry_run=dry_run)
        except ValueError as e:
            return 400, {"error": str(e)}
        except FileNotFoundError as e:
            return 404, {"error": str(e)}
        except Exception as e:
            return 500, {"error": "%s: %s" % (type(e).__name__, e)}
        return 200, result

    @r.route("GET", r"/api/cloud/list")
    def cloud_remote_list(_query=None, _body=None):
        q = _query or {}
        provider_id = q.get("provider_id") or q.get("id") or ""
        mod_name = q.get("mod_name") or q.get("mod") or ""
        sub = q.get("path") or q.get("dir") or ""
        if not provider_id:
            return 400, {"error": "provider_id required"}
        prov = cloud_sync.get_provider(provider_id)
        if not prov:
            return 404, {"error": "provider not found"}
        try:
            drv = cloud_sync.get_driver(prov.get("type"), prov.get("config"))
            # 远端路径 = remote_root/mod_name/sub
            from editor.server.cloud_sync import _remote_path_for
            remote = _remote_path_for(prov, mod_name, sub)
            objs = drv.list(remote)
            return 200, {"remote": remote, "objects": [o.to_dict() for o in objs]}
        except Exception as e:
            return 500, {"error": "%s: %s" % (type(e).__name__, e)}

    @r.route("GET", r"/api/cloud/local_files")
    def cloud_local_files(_query=None, _body=None):
        """修复原前端 _loadFiles 误用全局 mod：按 mod_name 精准列出本地 Mod 文件"""
        q = _query or {}
        mod_name = q.get("mod_name") or q.get("mod") or STATE.mod_name
        if not mod_name:
            return 400, {"error": "mod_name required"}
        try:
            # 优先使用 cloud_sync._list_local_files 保证与同步引擎一致的过滤逻辑
            from editor.server.cloud_sync import _list_local_files, _get_mod_dir
            mod_dir = _get_mod_dir(mod_name)
            if not mod_dir or not os.path.isdir(mod_dir):
                return 404, {"error": f"mod not found: {mod_name}", "mod_dir": mod_dir}
            raw = _list_local_files(mod_name, compute_sha=False)
            # 转为前端期望的 entries 格式
            entries = []
            for rel, (sz, mt, _) in sorted(raw.items()):
                entries.append({"name": rel, "type": "file", "size": sz, "mtime": mt})
            return 200, {"mod": mod_name, "root": mod_dir, "entries": entries, "count": len(entries)}
        except Exception as e:
            import traceback; traceback.print_exc()
            return 500, {"error": "%s: %s" % (type(e).__name__, e)}

    @r.route("GET", r"/api/cloud/drivers")
    def cloud_drivers(_query=None, _body=None):
        """返回所有驱动的配置 Schema，供前端动态生成表单并展示帮助"""
        try:
            out = {}
            for key, cls in cloud_sync.DRIVERS.items():
                try:
                    inst = cls({})
                    schema = inst.config_schema() if hasattr(inst, "config_schema") else {}
                except Exception:
                    schema = {}
                out[key] = schema
            return 200, {"drivers": out}
        except Exception as e:
            return 500, {"error": "%s: %s" % (type(e).__name__, e)}



    # ---------- realtime cloud sync ----------
    @r.route("GET", r"/api/cloud/realtime/config")
    def realtime_get_config(_query=None, _body=None):
        try:
            cfg = realtime_sync.rt_get_config()
            return 200, {"config": cfg}
        except Exception as e:
            return 500, {"error": "%s: %s" % (type(e).__name__, e)}

    @r.route("POST", r"/api/cloud/realtime/config")
    def realtime_set_config(_query=None, _body=None):
        try:
            body = _body or {}
            patch = body.get("config") if isinstance(body.get("config"), dict) else body
            cfg = realtime_sync.rt_update_config(patch or {})
            return 200, {"config": cfg}
        except Exception as e:
            return 400, {"error": "%s: %s" % (type(e).__name__, e)}

    @r.route("PUT", r"/api/cloud/realtime/config")
    def realtime_put_config(_query=None, _body=None):
        try:
            body = _body or {}
            patch = body.get("config") if isinstance(body.get("config"), dict) else body
            cfg = realtime_sync.rt_update_config(patch or {})
            return 200, {"config": cfg}
        except Exception as e:
            return 400, {"error": "%s: %s" % (type(e).__name__, e)}

    @r.route("GET", r"/api/cloud/realtime/status")
    def realtime_status(_query=None, _body=None):
        try:
            st = realtime_sync.rt_get_status()
            return 200, st
        except Exception as e:
            import traceback; traceback.print_exc()
            return 500, {"error": "%s: %s" % (type(e).__name__, e)}

    @r.route("POST", r"/api/cloud/realtime/start")
    def realtime_start(_query=None, _body=None):
        try:
            body = _body or {}
            if body:
                patch = body.get("config") if isinstance(body.get("config"), dict) else body
                known = {"provider_id","mod_name","mods","direction","debounce_ms","poll_interval_ms","remote_poll_interval_ms","delete_extra","auto_start","watch_all_mods","enabled"}
                filtered = {k:v for k,v in patch.items() if k in known} if isinstance(patch, dict) else {}
                if filtered:
                    realtime_sync.rt_update_config(filtered)
            st = realtime_sync.rt_start()
            return 200, st
        except ValueError as e:
            return 400, {"error": str(e)}
        except Exception as e:
            import traceback; traceback.print_exc()
            return 500, {"error": "%s: %s" % (type(e).__name__, e)}

    @r.route("POST", r"/api/cloud/realtime/stop")
    def realtime_stop(_query=None, _body=None):
        try:
            st = realtime_sync.rt_stop()
            return 200, st
        except Exception as e:
            return 500, {"error": "%s: %s" % (type(e).__name__, e)}

    @r.route("GET", r"/api/cloud/realtime/events")
    def realtime_events(_query=None, _body=None):
        try:
            q = _query or {}
            limit = int(q.get("limit") or 50)
            limit = max(1, min(200, limit))
            st = realtime_sync.rt_get_status()
            ev = st.get("events", [])[:limit]
            return 200, {"events": ev, "stats": st.get("stats", {}), "running": st.get("running"), "enabled": st.get("enabled")}
        except Exception as e:
            return 500, {"error": str(e)}


    # ---------- 插件系统 ----------
    @r.route("GET", r"/api/plugins")
    def plugins_list(_query=None, _body=None):
        try:
            plugins = plugin_system.list_plugins()
        except Exception as e:
            return 500, {"error": "%s: %s" % (type(e).__name__, e)}
        return 200, {"plugins": plugins}

    @r.route("POST", r"/api/plugins/install")
    def plugins_install(_query=None, _body=None):
        body = _body or {}
        b64 = body.get("data") or ""
        filename = body.get("filename") or "plugin.zip"
        if not b64:
            return 400, {"error": "zip data required"}
        try:
            import base64
            raw = base64.b64decode(b64, validate=True)
        except Exception:
            return 400, {"error": "invalid base64"}
        if len(raw) > 100 * 1024 * 1024:
            return 400, {"error": "zip too large (>100MB)"}
        try:
            result = plugin_system.install_plugin(raw, filename)
        except ValueError as e:
            return 400, {"error": str(e)}
        except Exception as e:
            return 500, {"error": "%s: %s" % (type(e).__name__, e)}
        return 200, {"ok": True, "id": result["id"], "plugin": result["plugin"]}

    @r.route("POST", r"/api/plugins/install_path")
    def plugins_install_path(_query=None, _body=None):
        body = _body or {}
        path = str(body.get("path") or "")
        if not path:
            return 400, {"error": "path required"}
        filename = body.get("filename") or os.path.basename(path) or "plugin.zip"
        try:
            result = plugin_system.install_plugin_from_path(path, filename)
        except ValueError as e:
            return 400, {"error": str(e)}
        except Exception as e:
            return 500, {"error": "%s: %s" % (type(e).__name__, e)}
        return 200, {"ok": True, "id": result["id"], "plugin": result["plugin"]}

    @r.route("POST", r"/api/plugins/reload")
    def plugins_reload(_query=None, _body=None):
        try:
            plugin_system.reload_plugins(r)
        except Exception as e:
            return 500, {"error": "%s: %s" % (type(e).__name__, e)}
        return 200, {"ok": True, "plugins": plugin_system.list_plugins()}

    @r.route("GET", r"/api/plugins/ui")
    def plugins_ui(_query=None, _body=None):
        return 200, {"panels": plugin_system.ui_panels()}

    @r.route("GET", r"/api/plugins/ui/flow_cards")
    def plugins_flow_cards(_query=None, _body=None):
        return 200, {"flow_cards": plugin_system.flow_cards()}

    @r.route("GET", r"/api/plugins/agent/tools")
    def plugins_agent_tools(_query=None, _body=None):
        return 200, {"tools": plugin_system.agent_tool_defs()}

    @r.route("POST", r"/api/plugins/agent/exec")
    def plugins_agent_exec(_query=None, _body=None):
        body = _body or {}
        name = body.get("name") or ""
        args = body.get("args") or {}
        if not name:
            return 400, {"error": "name required"}
        try:
            # GUI 已本地确认：此端点无条件放行写工具
            result = plugin_system.agent_exec(name, args,
                                              confirm=lambda t, d: True)
        except Exception as e:
            return 400, {"error": "%s: %s" % (type(e).__name__, e)}
        return 200, {"ok": True, "result": result}

    @r.route("GET", r"/api/plugins/(?P<pid>[^/]+)")
    def plugins_info(pid, _query=None, _body=None):
        try:
            info = plugin_system.get_plugin_info(pid)
        except Exception as e:
            return 500, {"error": "%s: %s" % (type(e).__name__, e)}
        if not info:
            return 404, {"error": "plugin not found"}
        return 200, info

    @r.route("POST", r"/api/plugins/(?P<pid>[^/]+)/enable")
    def plugins_enable(pid, _query=None, _body=None):
        body = _body or {}
        if body.get("risk_ack") is not True:
            return 400, {"error": "需要高危确认：该插件为第三方 Python 代码，启用后将与本编辑器同权限运行"}
        try:
            entry = plugin_system.set_enabled(pid, True, risk_ack=True)
        except ValueError as e:
            return 400, {"error": str(e)}
        except Exception as e:
            return 500, {"error": "%s: %s" % (type(e).__name__, e)}
        return 200, {"ok": True, "plugin": entry}

    @r.route("POST", r"/api/plugins/(?P<pid>[^/]+)/disable")
    def plugins_disable(pid, _query=None, _body=None):
        try:
            entry = plugin_system.set_enabled(pid, False)
        except ValueError as e:
            return 400, {"error": str(e)}
        except Exception as e:
            return 500, {"error": "%s: %s" % (type(e).__name__, e)}
        return 200, {"ok": True, "plugin": entry}

    @r.route("DELETE", r"/api/plugins/(?P<pid>[^/]+)")
    def plugins_delete(pid, _query=None, _body=None):
        try:
            plugin_system.uninstall_plugin(pid)
        except ValueError as e:
            return 400, {"error": str(e)}
        except Exception as e:
            return 500, {"error": "%s: %s" % (type(e).__name__, e)}
        return 200, {"ok": True}

    def _plugin_fallback(method_str):
        """插件路由兜底：rest 精确 fullmatch 已加载插件的注册路由。"""
        def handler(pid, rest, _query=None, _body=None):
            try:
                hit = plugin_system.dispatch_plugin_route(
                    pid, method_str, rest, _query or {}, _body or {})
            except Exception as e:
                return 500, {"error": "%s: %s" % (type(e).__name__, e)}
            if hit is None:
                return 404, {"error": "no route"}
            return int(hit[0]), hit[1]
        return handler

    for _plugin_method in ("GET", "POST", "PUT", "DELETE"):
        r.route(_plugin_method,
                r"/api/plugins/(?P<pid>[a-z0-9_\-]+)/(?P<rest>.+)")(
            _plugin_fallback(_plugin_method))

    # auto start realtime sync if configured
    try:
        realtime_sync.rt_auto_start()
    except Exception:
        pass

    # 加载已启用插件（挂载插件路由，供启动后立即可用的首轮调度）
    plugin_system.load_all(r)

    return r
