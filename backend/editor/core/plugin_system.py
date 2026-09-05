# -*- coding: utf-8 -*-
"""插件系统：第三方 Python 插件运行时。

Zip 安装（条目安全校验同资源扩展包）→ 目录持久化（plugins.json 原子写）
→ 惰性加载（importlib + setup(ctx)）→ 路由/工具/命令/面板四类贡献，
并提供与 Agent 侧、HTTP 侧的桥接 API。

安全语义：
- 插件 id 必须匹配 ^[a-z][a-z0-9_-]{0,63}$，且不在保留集合内。
- 启用 = 加载第三方 Python 代码并与编辑器同权限运行，必须先 risk_ack=True。
- 一把模块级 RLock 串行化 安装/卸载/启停/加载/重载，避免并发解压与注册表写。
"""

import importlib.util
import io
import json
import os
import re
import shutil
import sys
import threading
import time
import zipfile

# plugin id 合法性：^[a-z][a-z0-9_-]{0,63}$
_PLUGIN_ID_RE = re.compile(r"^[a-z][a-z0-9_-]{0,63}$")
# 保留 id：禁止作为插件安装
RESERVED_IDS = frozenset({"agent", "ui", "reload", "install", "install_path"})
# Agent 工具详情地址（tools.py 查询 readonly/confirm 用）
_PLUGIN_MOD_PREFIX = "student_age_plugin_"

_lock = threading.RLock()
_router = None        # 已挂载的 ApiRouter（load_all / reload_plugins 注入）
_loaded = {}          # pid -> PluginContext（含四类贡献）
_errors = {}          # pid -> 最近一次加载错误串


def _editor_root():
    from editor.core.paths import app_data_dir
    return app_data_dir()


# ------------------------------------------------------------------ 目录与持久化

def plugins_root():
    """插件根目录：EDITOR_PLUGINS_ROOT 优先，否则 <app_data_dir>/plugins/。"""
    root = os.environ.get("EDITOR_PLUGINS_ROOT") \
        or os.path.join(_editor_root(), "plugins")
    try:
        os.makedirs(root, exist_ok=True)
    except Exception:
        pass
    return root


def _meta_path():
    return os.path.join(plugins_root(), "plugins.json")


def _load_meta():
    """读 plugins.json，格式损坏/缺失时回退空注册表（读容错）。"""
    try:
        with open(_meta_path(), "r", encoding="utf-8") as f:
            data = json.load(f)
        if isinstance(data, dict) and "plugins" in data:
            return data
    except Exception:
        pass
    return {"plugins": {}}


def _save_meta(meta):
    """原子写 plugins.json（唯一临时文件名 + os.replace）。

    固定 .tmp 名会在 GUI 后端与 CLI 同时安装/启停插件时互踩——两进程写同
    一个临时文件再 os.replace，可能落一份混合/截断的注册表。
    """
    from editor.core.atomic_io import _unique_tmp_path
    target = _meta_path()
    tmp = _unique_tmp_path(target)
    try:
        os.makedirs(plugins_root(), exist_ok=True)
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(meta, f, ensure_ascii=False, indent=2)
        os.replace(tmp, target)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass


def _safe_pid(pid):
    """pid 不得携带路径穿越 / 绝对路径成分。"""
    return bool(pid) and not any(ch in str(pid) for ch in ("/", "\\", ":")) \
        and ".." not in str(pid)


def _reconcile():
    """目录与 plugins.json 对账：清掉目录已消失的条目、补上目录的默认条目。"""
    root = plugins_root()
    meta = _load_meta()
    registry = meta.setdefault("plugins", {})
    existing = set()
    try:
        for d in os.listdir(root):
            if os.path.isdir(os.path.join(root, d)) and d != "__pycache__":
                existing.add(d)
    except Exception:
        pass
    changed = False
    for pid in list(registry):
        if pid not in existing:
            del registry[pid]
            changed = True
    for pid in existing:
        if pid not in registry:
            registry[pid] = {"enabled": False, "risk_ack_at": ""}
            changed = True
    if changed:
        _save_meta(meta)
    return meta


# ------------------------------------------------------------------ manifest

def _read_manifest(d):
    manifest = {}
    try:
        with open(os.path.join(d, "manifest.json"), "r", encoding="utf-8-sig") as f:
            manifest = json.load(f)
    except Exception:
        manifest = {}
    if not isinstance(manifest, dict):
        manifest = {}
    return manifest


def _manifest_id(manifest):
    mid = manifest.get("id")
    if not isinstance(mid, str):
        return ""
    return mid.strip()


def _id_from_filename(filename):
    """zip 缺 id 时从文件名生成：小写、非法字符转下划线、首字符非字母加 p_、截 64。"""
    base = os.path.splitext(os.path.basename(filename or ""))[0].strip().lower()
    safe = re.sub(r"[^a-z0-9_-]", "_", base)
    if not safe:
        safe = "plugin"
    if not safe[0].isalpha():
        safe = "p_" + safe
    return safe[:64]


def _validate_pid(pid):
    """校验插件 id：不合法或保留 → ValueError。"""
    if not _PLUGIN_ID_RE.match(pid or ""):
        raise ValueError("invalid plugin id: %r" % pid)
    if pid in RESERVED_IDS:
        raise ValueError("reserved plugin id: %s" % pid)


# ------------------------------------------------------------------ 条目合成

def _entry_for(pid, d, manifest, reg):
    """合成 list/install/enable 返回值中的插件条目。"""
    return {
        "id": pid,
        "name": manifest.get("name") or pid,
        "version": manifest.get("version") or "",
        "author": manifest.get("author") or "",
        "description": manifest.get("description") or "",
        "entry": manifest.get("entry") or "plugin.py",
        "enabled": bool(reg.get("enabled")),
        "loaded": pid in _loaded,
        "error": _errors.get(pid) or "",
        "risk_ack_at": reg.get("risk_ack_at") or "",
    }


def _entry_list(reg):
    out = []
    for pid in sorted(reg):
        d = os.path.join(plugins_root(), pid)
        if not os.path.isdir(d):
            continue
        out.append(_entry_for(pid, d, _read_manifest(d), reg[pid]))
    return out


# ------------------------------------------------------------------ 安装 / 卸载

def _install_zip(z, filename=""):
    """通用 zip 安装：校验条目安全 → 解压 → 补 manifest → 注册元数据（默认停用）。"""
    names = z.namelist()
    if not names:
        raise ValueError("empty zip")
    for n in names:
        if n.startswith("/") or ".." in n or ":" in n:
            raise ValueError("illegal entry: %r" % n)
    if "manifest.json" not in names:
        raise ValueError("zip missing manifest.json")
    # 优先读 zip 内 manifest 的 id（utf-8-sig），缺 id 走文件名生成
    try:
        man_buf = z.read("manifest.json")
    except Exception:
        man_buf = b"{}"
    manifest = {}
    try:
        manifest = json.loads(man_buf.decode("utf-8-sig"))
    except Exception:
        pass
    if not isinstance(manifest, dict):
        manifest = {}
    pid = _manifest_id(manifest) or _id_from_filename(filename)
    _validate_pid(pid)
    dest = os.path.join(plugins_root(), pid)
    if os.path.exists(dest):
        raise ValueError("plugin already exists: %s" % pid)
    try:
        os.makedirs(dest, exist_ok=True)
        z.extractall(dest)
    except Exception as e:
        shutil.rmtree(dest, ignore_errors=True)
        raise ValueError("extract failed: %s" % e)
    entry = str(manifest.get("entry") or "plugin.py") or "plugin.py"
    if not os.path.isfile(os.path.join(dest, entry)):
        shutil.rmtree(dest, ignore_errors=True)
        raise ValueError("plugin entry file missing: %s" % entry)
    manifest.setdefault("name", pid)
    manifest.setdefault("version", "1.0.0")
    manifest.setdefault("author", "")
    manifest.setdefault("description", "")
    manifest["id"] = pid
    try:
        with open(os.path.join(dest, "manifest.json"), "w", encoding="utf-8") as f:
            json.dump(manifest, f, ensure_ascii=False, indent=2)
    except Exception:
        pass
    meta = _load_meta()
    registry = meta.setdefault("plugins", {})
    registry[pid] = {"enabled": False, "risk_ack_at": ""}
    _save_meta(meta)
    return {"id": pid, "plugin": _entry_for(pid, dest, manifest, registry[pid])}


def install_plugin(zip_bytes, filename=""):
    """从内存 zip 字节安装插件；目标目录已存在 → ValueError；默认停用。"""
    if not zip_bytes or len(zip_bytes) < 4:
        raise ValueError("empty zip")
    if len(zip_bytes) > 500 * 1024 * 1024:
        raise ValueError("zip too large (>500MB)")
    with _lock:
        try:
            z = zipfile.ZipFile(io.BytesIO(zip_bytes))
        except Exception as e:
            raise ValueError("invalid zip: %s" % e)
        return _install_zip(z, filename)


def install_plugin_from_path(path, filename=""):
    """按本地路径安装插件 zip。文件保留在原地，本函数不负责清理。"""
    if not path or not os.path.isfile(path):
        raise ValueError("file not found: %s" % path)
    try:
        size = os.path.getsize(path)
    except Exception:
        size = 0
    if size <= 0:
        raise ValueError("empty file")
    if size > 4 * 1024 * 1024 * 1024:
        raise ValueError("zip too large (>4GB)")
    with _lock:
        try:
            z = zipfile.ZipFile(path)
        except Exception as e:
            raise ValueError("invalid zip: %s" % e)
        return _install_zip(z, filename or os.path.basename(path))


def uninstall_plugin(pid):
    """卸载插件：必须已停用（先停用再卸载）；删目录 + 清注册表条目。"""
    with _lock:
        if not _safe_pid(pid):
            raise ValueError("invalid plugin id")
        d = os.path.join(plugins_root(), pid)
        if not os.path.isdir(d):
            raise ValueError("plugin not found: %s" % pid)
        meta = _load_meta()
        registry = meta.get("plugins", {})
        if bool(registry.get(pid, {}).get("enabled")):
            raise ValueError("请先停用该插件再卸载：%s" % pid)
        _unload_plugin(pid)
        shutil.rmtree(d, ignore_errors=True)
        if pid in registry:
            del registry[pid]
            _save_meta(meta)
        return {"ok": True}


# ------------------------------------------------------------------ 加载 / 卸载

def _load_plugin(pid):
    """加载单个插件：spec_from_file_location + setup(ctx)，失败回滚全部贡献。"""
    d = os.path.join(plugins_root(), pid)
    manifest = _read_manifest(d)
    entry = str(manifest.get("entry") or "plugin.py") or "plugin.py"
    entry_path = os.path.join(d, entry)
    if not os.path.isfile(entry_path):
        raise ValueError("entry file not found: %s" % entry)
    modname = _PLUGIN_MOD_PREFIX + pid
    sys.modules.pop(modname, None)  # 重新加载前先移除同名模块
    ctx = PluginContext(pid, d, manifest)
    _loaded[pid] = ctx
    try:
        spec = importlib.util.spec_from_file_location(modname, entry_path)
        if spec is None or spec.loader is None:
            raise ValueError("cannot create module spec")
        module = importlib.util.module_from_spec(spec)
        sys.modules[modname] = module
        spec.loader.exec_module(module)
        setup = getattr(module, "setup", None)
        if not callable(setup):
            raise ValueError("plugin entry has no callable setup(ctx)")
        ctx._active = True
        try:
            setup(ctx)
        finally:
            ctx._active = False
    except Exception:
        _loaded.pop(pid, None)
        if _router is not None:
            try:
                _router.unregister_owner("plugin:%s" % pid)
            except Exception:
                pass
        sys.modules.pop(modname, None)
        for m in [m for m in list(sys.modules) if m.startswith(modname + ".")]:
            sys.modules.pop(m, None)
        raise
    return ctx


def _unload_plugin(pid):
    """卸载单个插件：注销路由（owner=plugin:<id>）+ 清贡献 + 尽力移除模块。"""
    _loaded.pop(pid, None)
    _errors.pop(pid, None)
    if _router is not None:
        try:
            _router.unregister_owner("plugin:%s" % pid)
        except Exception:
            pass
    modname = _PLUGIN_MOD_PREFIX + pid
    sys.modules.pop(modname, None)
    for m in [m for m in list(sys.modules) if m.startswith(modname + ".")]:
        sys.modules.pop(m, None)


def load_all(router=None):
    """加载全部已启用插件；router 非 None 时挂载路由并存入模块级变量。

    单插件失败隔离：error 记入该条目，其他插件不受影响。
    """
    global _router
    with _lock:
        if router is not None:
            if _router is not router:
                for pid in list(_loaded):
                    _unload_plugin(pid)
                _router = router
        meta = _reconcile()
        registry = meta.get("plugins", {})
        for pid in sorted(registry):
            if pid in _loaded:
                continue
            if not registry[pid].get("enabled"):
                continue
            d = os.path.join(plugins_root(), pid)
            if not os.path.isdir(d):
                continue
            try:
                _load_plugin(pid)
            except Exception as e:
                _errors[pid] = "%s: %s" % (type(e).__name__, e)
        return _entry_list(registry)


def reload_plugins(router=None):
    """卸载全部已加载插件后重新 load_all（fresh 挂载到给定 router）。"""
    global _router
    with _lock:
        if router is not None:
            _router = router
        for pid in list(_loaded):
            _unload_plugin(pid)
        return load_all(None)


# ------------------------------------------------------------------ 公开查询

def list_plugins():
    """扫目录与 plugins.json 对账，返回全部插件条目列表。"""
    with _lock:
        meta = _reconcile()
        return _entry_list(meta.get("plugins", {}))


def get_plugin_info(pid):
    """插件详情：条目 + 已加载插件的 contributions；不存在返回 None。"""
    with _lock:
        if not _safe_pid(pid):
            return None
        meta = _reconcile()
        registry = meta.get("plugins", {})
        if pid not in registry:
            return None
        d = os.path.join(plugins_root(), pid)
        if not os.path.isdir(d):
            return None
        entry = _entry_for(pid, d, _read_manifest(d), registry[pid])
        ctx = _loaded.get(pid)
        entry["contributions"] = ctx.contributions() if ctx is not None else {
            "routes": [], "tools": [], "commands": [], "panels": [],
            "flow_cards": [],
        }
        return entry


def set_enabled(pid, enabled, risk_ack=False):
    """启用/停用插件并持久化。启用即加载（router 存在时挂路由）；
    enabled=True 且 risk_ack 非 True → ValueError；
    停用 = 卸载贡献 + 注销路由。
    """
    with _lock:
        if not _safe_pid(pid):
            raise ValueError("invalid plugin id")
        d = os.path.join(plugins_root(), pid)
        if not os.path.isdir(d):
            raise ValueError("plugin not found: %s" % pid)
        meta = _load_meta()
        registry = meta.setdefault("plugins", {})
        reg = registry.setdefault(pid, {"enabled": False, "risk_ack_at": ""})
        if enabled:
            if not risk_ack:
                raise ValueError("需要高危确认：该插件为第三方 Python 代码，启用后将与本编辑器同权限运行")
            reg["enabled"] = True
            reg["risk_ack_at"] = time.strftime("%Y-%m-%dT%H:%M:%S")
            _save_meta(meta)
            if pid not in _loaded:
                try:
                    _load_plugin(pid)
                except Exception as e:
                    _errors[pid] = "%s: %s" % (type(e).__name__, e)
        else:
            reg["enabled"] = False
            _save_meta(meta)
            _unload_plugin(pid)
        return _entry_for(pid, d, _read_manifest(d), reg)


# ------------------------------------------------------------------ 插件上下文

class PluginContext(object):
    """传给 setup(ctx) 的插件上下文；四类贡献只在 setup 期间可注册。"""

    def __init__(self, pid, plugin_dir, manifest):
        self.pid = pid
        self.plugin_dir = plugin_dir
        self.manifest = manifest
        self._data_dir = os.path.join(plugin_dir, "data")
        self._data_created = False
        self._active = False
        self.routes = []
        self.tools = []
        self.commands = []
        self.panels = []
        self.flow_cards = []

    @property
    def data_dir(self):
        """插件 data/ 目录（懒建）。"""
        if not self._data_created:
            try:
                os.makedirs(self._data_dir, exist_ok=True)
            finally:
                self._data_created = True
        return self._data_dir

    def log(self, msg):
        print("[plugin:%s] %s" % (self.pid, msg))

    def _check_active(self):
        if not self._active:
            raise ValueError("plugin API only usable during setup(ctx)")

    def register_route(self, method, pattern, fn):
        """注册相对前缀路由；全名 /api/plugins/<id>/<pattern>，owner=plugin:<id>。

        实际挂载路径以 relative pattern 拼接到 /api/plugins/<id>/ 之后，fullmatch
        匹配；fn 约定 fn(query, body) -> (status:int, payload:dict)。
        """
        self._check_active()
        method = str(method).upper()
        full = "/api/plugins/%s/%s" % (self.pid, pattern)
        rx = re.compile(full)
        self.routes.append({"method": method, "pattern": pattern,
                            "full": full, "rx": rx, "fn": fn})
        if _router is not None:
            owner = "plugin:%s" % self.pid

            def wrapper(_query=None, _body=None):
                return fn(_query or {}, _body or {})

            _router.route(method, full, owner=owner)(wrapper)

    def register_tool(self, name, description, parameters, fn,
                      readonly=False, confirm=False):
        """注册 Agent 工具；全名 <id>__<name>，fn(args: dict, confirm) -> str。"""
        self._check_active()
        self.tools.append({
            "name": "%s__%s" % (self.pid, name),
            "description": description or "",
            "parameters": parameters if isinstance(parameters, dict) else {},
            "fn": fn,
            "readonly": bool(readonly),
            "confirm": bool(confirm),
            "plugin_id": self.pid,
        })

    def register_command(self, name, help, fn):
        """注册 CLI 命令；全名 <id>.<name>，fn(args: str) -> None。"""
        self._check_active()
        self.commands.append({
            "name": "%s.%s" % (self.pid, name),
            "help": help or "",
            "fn": fn,
        })

    def register_panel(self, panel_id, title, icon, description):
        """声明 UI 面板（内容由插件自行注册路由 panel/<panel_id> 提供）。"""
        self._check_active()
        self.panels.append({
            "panel_id": panel_id,
            "title": title or "",
            "icon": icon or "",
            "description": description or "",
        })

    def register_flow_card(self, type_id, spec):
        """声明剧情流程图的自定义节点卡片类型（声明型贡献，无执行体）。

        spec 字段：
          name         必填，卡片显示名
          applies_to   必填，"talk" | "option"（作用对象节点类型）
          icon         可选，图标名（白名单映射由前端决定）
          color        可选，"#RRGGBB" 卡片主色
          match        可选，{"field": 字段名, "equals": 值} 识别规则——
                       该对白/选项记录的字段等于该值时按此卡片渲染
          body_fields  可选，卡片正文优先展示的字段名列表（content 之外）
          hidden_ports 可选，隐藏的输出端口名列表（如 ["checkFail"]）
          description  可选
        """
        self._check_active()
        if not type_id or not isinstance(spec, dict):
            raise ValueError("register_flow_card: type_id 与 spec(dict) 必填")
        applies_to = str(spec.get("applies_to") or "talk")
        if applies_to not in ("talk", "option"):
            raise ValueError("register_flow_card: applies_to 须为 talk 或 option")
        self.flow_cards.append({
            "type_id": str(type_id),
            "name": str(spec.get("name") or type_id),
            "icon": str(spec.get("icon") or ""),
            "color": str(spec.get("color") or ""),
            "applies_to": applies_to,
            "match": spec.get("match") if isinstance(spec.get("match"), dict) else None,
            "body_fields": list(spec.get("body_fields") or []),
            "hidden_ports": list(spec.get("hidden_ports") or []),
            "description": str(spec.get("description") or ""),
            "plugin_id": self.pid,
        })

    def contributions(self):
        return {
            "routes": ["%s %s" % (r["method"], r["pattern"]) for r in self.routes],
            "tools": [t["name"] for t in self.tools],
            "commands": [c["name"] for c in self.commands],
            "panels": [{"panel_id": p["panel_id"], "title": p["title"],
                        "icon": p["icon"], "description": p["description"]}
                       for p in self.panels],
            "flow_cards": [{"type_id": c["type_id"], "name": c["name"],
                            "applies_to": c["applies_to"]}
                           for c in self.flow_cards],
        }


# ------------------------------------------------------------------ Agent 桥接

def agent_tool_defs():
    """聚合已加载插件工具（openai 格式 + readonly/confirm/plugin_id 附加字段）。"""
    with _lock:
        out = []
        for pid in sorted(_loaded):
            for t in _loaded[pid].tools:
                out.append({
                    "name": t["name"],
                    "description": t["description"],
                    "parameters": t["parameters"],
                    "readonly": t["readonly"],
                    "confirm": t["confirm"],
                    "plugin_id": pid,
                })
        return out


def plugin_tool_info(name):
    """按全名查插件工具定义（含 readonly/confirm）；未加载/不存在返回 None。"""
    with _lock:
        for pid in sorted(_loaded):
            for t in _loaded[pid].tools:
                if t["name"] == name:
                    return {
                        "name": t["name"],
                        "description": t["description"],
                        "parameters": t["parameters"],
                        "readonly": t["readonly"],
                        "confirm": t["confirm"],
                        "plugin_id": pid,
                    }
        return None


def has_plugin_tool(name):
    """是否存在已加载的该全名工具。"""
    with _lock:
        return any(t["name"] == name
                   for ctx in _loaded.values() for t in ctx.tools)


def agent_exec(name, args, confirm=None):
    """按全名执行插件工具；未知/未加载 → ValueError；
    confirm=True 的工具无回调 → 返回「该工具需要用户确认」错误串。

    锁内只查找工具引用，插件代码在锁外执行：fn 可能阻塞在网络/子进程
    调用上，持全局锁会把 flow_cards/ui_panels 聚合与全部插件路由一起卡死。
    """
    with _lock:
        tool = None
        for pid in sorted(_loaded):
            for t in _loaded[pid].tools:
                if t["name"] == name:
                    tool = t
                    break
            if tool is not None:
                break
        if tool is None:
            raise ValueError("plugin tool not loaded: %s" % name)
        if tool["confirm"] and confirm is None:
            return "该工具需要用户确认"
        fn = tool["fn"]
    return fn(args if isinstance(args, dict) else {}, confirm)


def ui_panels():
    """聚合已加载插件的面板声明。"""
    with _lock:
        out = []
        for pid in sorted(_loaded):
            for p in _loaded[pid].panels:
                out.append({"panel_id": p["panel_id"], "title": p["title"],
                            "icon": p["icon"], "description": p["description"]})
        return out


def flow_cards():
    """聚合已加载插件的流程卡片声明（供剧情图工作区注册表）。"""
    with _lock:
        out = []
        for pid in sorted(_loaded):
            for c in _loaded[pid].flow_cards:
                out.append({k: c[k] for k in (
                    "type_id", "name", "icon", "color", "applies_to",
                    "match", "body_fields", "hidden_ports", "description",
                    "plugin_id")})
        return out


def plugin_command(name):
    """按全名 <id>.<name> 查命令函数（供 CLI 用）；不存在返回 None。"""
    with _lock:
        for pid in sorted(_loaded):
            for c in _loaded[pid].commands:
                if c["name"] == name:
                    return c["fn"]
        return None


def dispatch_plugin_route(pid, method, rest, query, body):
    """判断 rest 是否命中某已加载插件的注册路由（fullmatch）。

    命中返回 (status, payload)，否则 None。

    锁内只做路由匹配、取出处理函数引用，插件代码在锁外执行（与
    agent_exec 同策略）：fn 可能在网络/子进程上阻塞，持全局锁会把
    flow_cards/ui_panels 聚合与全部插件路由一起卡死。
    """
    with _lock:
        ctx = _loaded.get(pid)
        if ctx is None:
            return None
        method = str(method).upper()
        full = "/api/plugins/%s/%s" % (pid, rest)
        fn = None
        for r in ctx.routes:
            if r["method"] != method:
                continue
            if r["rx"].fullmatch(full):
                fn = r["fn"]
                break
    if fn is None:
        return None
    q = query if isinstance(query, dict) else {}
    b = body if isinstance(body, dict) else {}
    return fn(q, b)