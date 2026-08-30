# -*- coding: utf-8 -*-
"""Claude Code 风格交互式 CLI – REPL + slash commands + @提及 + rich。

用法:
  python run_cli.py              # 无参自动进入 REPL
  python run_cli.py --interactive
  python -m editor.cli --interactive
  在 REPL 中输入 /help 查看命令
"""

import json
import os
import re
import shlex
import sys
import time
import subprocess
import shutil
from pathlib import Path

_WS_TOKEN_RE = re.compile(r"(^|\s)--workspace(\s|$)")  # 防止重复注入全局参数

# Ensure stdout/stderr handle UTF-8 (avoid GBK bullet encode errors)
try:
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    if hasattr(sys.stderr, "reconfigure"):
        sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

from rich.console import Console
from rich.panel import Panel
from rich.table import Table
from rich.syntax import Syntax
from rich.markup import escape

from .utils import (
    editor_root, user_mods_dir, resolve_workspace, list_mods, find_mod,
    cfg_name_normalize, cfg_path, load_cfg, save_cfg, load_schema,
    validate_cfg, search_in_mod, CfgParseError, fuzzy_suggest,
)

console = Console(legacy_windows=False)
err_console = Console(stderr=True, legacy_windows=False)

# ---------------------------------------------------------------------------
# Prompt toolkit completer (slash + @ + mods/cfgs)
# ---------------------------------------------------------------------------
try:
    from prompt_toolkit import PromptSession
    from prompt_toolkit.completion import Completer, Completion
    from prompt_toolkit.history import FileHistory
    from prompt_toolkit.auto_suggest import AutoSuggestFromHistory
    from prompt_toolkit.styles import Style
    HAS_PT = True
except Exception:
    HAS_PT = False
    PromptSession = None

SLASH_CMDS = [
    "/help", "/mods", "/cfg", "/schema", "/search", "/workspace", "/doctor", "/update",
    "/clear", "/exit", "/quit", "/tui", "/history", "/shell", "/shell!", "/status",
    "/use", "/edit", "/validate", "/export", "/import", "/theme",
    "/agent", "/cloud", "/plugins",
]

# for direct (no slash) also
DIRECT_CMDS = ["mods", "mod", "cfg", "schema", "search", "workspace", "doctor", "update", "tui",
               "help", "exit", "quit", "clear", "edit", "validate", "use", "status",
               "history", "list", "agent", "cloud", "plugins"]

_KNOWN_CMDS = {c[1:].lower() for c in SLASH_CMDS} | set(DIRECT_CMDS) | {"mod"}

_CMD_META = {
    "/help": "查看帮助", "/mods": "Mods 管理", "/cfg": "Cfg 读写", "/schema": "GAME_SCHEMA",
    "/search": "全文搜索", "/workspace": "工作区", "/doctor": "环境自检", "/update": "检查 GitHub 更新", "/clear": "清屏",
    "/exit": "退出", "/quit": "退出", "/tui": "启动 TUI", "/history": "历史记录",
    "/shell": "执行 shell", "/shell!": "执行 shell", "/status": "当前上下文",
    "/use": "切换当前 Mod", "/edit": "编辑 Cfg", "/validate": "校验当前 Mod",
    "/export": "batch 导出", "/import": "batch 导入", "/theme": "主题",
    "/agent": "AI 助手（/agent 直接对话，/agent setting 配置）", "/cloud": "云同步 (providers/add/sync…)",
    "/plugins": "插件管理 (list/info/install/enable/disable/uninstall/reload)",
}

_SUB_META = {
    "mods": [("list", "列出 Mods"), ("show", "<name> 详情"), ("create", "<Title> 新建"),
             ("delete", "<name> 删除"), ("use", "<name> 切换当前")],
    "cfg": [("list", "当前 Mod 的 Cfgs"), ("get", "<Cfg> 读记录"), ("set", "<Cfg> 写记录"),
            ("edit", "<Cfg> $EDITOR 打开"), ("delete", "<Cfg> 删记录"),
            ("validate", "校验当前 Mod"), ("export", "batch 导出"), ("import", "batch 导入")],
    "workspace": [("show", "显示工作区"), ("set", "<path> 设置工作区")],
    "agent": [("setting", "查看/修改 AI 配置"), ("chat", "[任务] 对话式改模（直接 /agent 亦可）"),
              ("history", "AI 会话历史 (list/show/resume/delete/clear)")],
    "cloud": [("providers", "列出网盘"), ("add", "新增网盘配置"), ("test", "<id> 测试连接"),
              ("show", "<id> 详情"), ("remove", "<id> 删除"), ("sync", "<id> 同步 Mod")],
    "plugins": [("list", "列出插件"), ("info", "<id> 详情"), ("install", "<zip路径> 安装"),
                ("enable", "<id> 启用 (高危确认)"), ("disable", "<id> 停用"),
                ("uninstall", "<id> 卸载 (二次确认)"), ("reload", "重载全部插件")],
}

_FLAG_META = {
    "--id": "<记录 ID>", "--key": "<字段名 schema>", "--mod": "<Mod 名>",
    "--cfg": "<Cfg 名>", "--value": "'<JSON>'", "--file": "<json 路径>",
    "--force": "强制写入 (忽略 error)", "--all": "显示全部记录", "--json": "原始 JSON 输出",
    "--verbose": "详细输出", "--desc": "<描述>",
    # agent
    "-m": "<Mod 名>", "--provider": "<协议 openai_compatible/…>",
    "--base-url": "<API 地址>", "--api-key": "<密钥>", "--model": "<模型名>",
    "--temperature": "<0.0-2.0>",
    "--resume": "<会话 id 或 last>", "--no-history": "本次会话不记录 AI 历史",
    # cloud
    "--type": "<驱动 local/webdav/…>", "--remote-root": "<远端根 mods/cfgs/save>",
    "--reveal": "敏感字段明文", "--direction": "<upload/download/sync>",
    "--dry-run": "只预览不写盘", "--delete-extra": "删除远端多余文件",
    "--files": "<相对路径,逗号分隔>",
    # plugins
    "--yes": "跳过高危/二次确认", "-y": "同 --yes",
}
_VALUE_FLAGS = {"--id", "--key", "--mod", "--cfg", "--value", "--file", "--desc",
                "-m", "--provider", "--base-url", "--api-key", "--model", "--temperature",
                "--resume",
                "--type", "--remote-root", "--direction", "--files"}
_BOOL_FLAGS = {"--force", "--all", "--json", "--verbose",
               "--dry-run", "--delete-extra", "--reveal", "--yes", "-y", "--no-history"}

_SUB_WORDS = {"get", "set", "list", "edit", "delete", "validate", "export", "import",
              "show", "use", "create", "add", "remove", "workshop",
              "config", "setting", "chat", "providers", "sync"}

_SUB_SPECS = {
    "cfg": {
        "get": {"pos": ["cfg"], "flags": ["--id", "--key", "--mod", "--all", "--json"]},
        "set": {"pos": ["cfg"], "flags": ["--id", "--key", "--mod", "--value", "--file", "--force"]},
        "edit": {"pos": ["cfg"], "flags": ["--mod"]},
        "delete": {"pos": ["cfg"], "flags": ["--id", "--mod"]},
        "list": {"pos": [], "flags": ["--mod"]},
        "validate": {"pos": [], "flags": ["--mod", "--verbose"]},
        "export": {"pos": [], "flags": []},
        "import": {"pos": [], "flags": []},
    },
    "mods": {
        "list": {"pos": [], "flags": []},
        "show": {"pos": ["mod"], "flags": []},
        "use": {"pos": ["mod"], "flags": []},
        "delete": {"pos": ["mod"], "flags": []},
        "create": {"pos": ["title"], "flags": ["--desc"]},
    },
    "workspace": {"show": {"pos": [], "flags": []}, "set": {"pos": ["dir"], "flags": []}},
    "agent": {
        "config": {"pos": [], "flags": ["--json"]},
        "setting": {"pos": [], "flags": ["--json"]},
        "chat": {"pos": ["task"], "flags": ["-m", "--mod", "--provider", "--base-url",
                                            "--api-key", "--model", "--temperature",
                                            "--resume", "--no-history"]},
        "history": {
            "list": {"pos": [], "flags": []},
            "show": {"pos": ["session_id"], "flags": []},
            "resume": {"pos": ["session_id"], "flags": []},
            "delete": {"pos": ["session_id"], "flags": []},
            "clear": {"pos": [], "flags": ["-y", "--yes"]},
        },
    },
    "cloud": {
        "providers": {"pos": [], "flags": ["--json"]},
        "add": {"pos": [], "flags": ["--type", "--name", "--remote-root", "--cfg"]},
        "test": {"pos": ["id"], "flags": []},
        "show": {"pos": ["id"], "flags": ["--reveal", "--json"]},
        "remove": {"pos": ["id"], "flags": ["--force"]},
        "sync": {"pos": ["id"], "flags": ["--mod", "--direction", "--dry-run",
                                          "--delete-extra", "--files"]},
    },
    "search": {"*": {"pos": ["kw"], "flags": ["--cfg"]}},
    "schema": {"*": {"pos": ["cfg"], "flags": ["--json"]}},
    "tui": {"*": {"pos": [], "flags": ["--mod"]}},
    "use": {"*": {"pos": ["mod"], "flags": []}},
    "edit": {"*": {"pos": ["cfg"], "flags": []}},
    "validate": {"*": {"pos": [], "flags": ["--mod", "--verbose"]}},
}
_SUB_SPECS["mod"] = _SUB_SPECS["mods"]

# _SUB_SPECS 续：plugins（插件管理，走 _dispatch_via_app 同路径）
_SUB_SPECS["plugins"] = {
    "list": {"pos": [], "flags": ["--json"]},
    "info": {"pos": ["id"], "flags": ["--json"]},
    "install": {"pos": ["path"], "flags": []},
    "enable": {"pos": ["id"], "flags": ["-y", "--yes"]},
    "disable": {"pos": ["id"], "flags": []},
    "uninstall": {"pos": ["id"], "flags": ["-y", "--yes"]},
    "reload": {"pos": [], "flags": ["--json"]},
}

# cloud add 的 --type / --remote-root 候选（与 server.cloud_sync.DRIVERS 对齐）
_CLOUD_TYPE_CANDS = [
    ("local", "本地目录"), ("webdav", "WebDAV"), ("openlist", "OpenList/Alist"),
    ("baidu", "百度网盘"), ("123", "123 云盘"),
    ("google_drive", "Google Drive"), ("onedrive", "OneDrive"),
]
_CLOUD_REMOTE_ROOTS = [("mods", "Mods 根目录"), ("cfgs", "Mod 的 Cfgs"), ("save", "存档目录")]


class EditorCompleter(Completer if HAS_PT else object):
    """多级自动补全：命令 → 子命令 → Cfg/Mod/ID/字段 → Flag/路径 → @提及。

    complete_pairs(text) 返回 [(替换串, 提示文案), ...]，替换串用于替换光标前
    的当前词；兼容 prompt_toolkit 与 readline 两种后端。
    """

    MAX_RESULTS = 300

    def __init__(self, get_ctx):
        self.get_ctx = get_ctx
        self._cache = {}
        self._cache_ts = {}

    # ------------------------------------------------------------- infrastructure
    def _cached(self, key, fn, ttl=1.0):
        now = time.time()
        if key in self._cache and now - self._cache_ts.get(key, 0) < ttl:
            return self._cache[key]
        try:
            val = fn()
        except Exception:
            val = []
        self._cache[key] = val
        self._cache_ts[key] = now
        return val

    @staticmethod
    def _split(text):
        """返回 (已完成 tokens, 正在输入的词片段)。"""
        i = len(text)
        while i > 0 and not text[i - 1].isspace():
            i -= 1
        return text[:i].split(), text[i:]

    @classmethod
    def _rank(cls, cands, frag):
        f = (frag or "").lower()
        starts, contains = [], []
        for ins, meta in cands:
            if not ins:
                continue
            s = ins.lower()
            if not f or s.startswith(f):
                starts.append((ins, meta))
            elif f in s:
                contains.append((ins, meta))
        return (starts + contains)[: cls.MAX_RESULTS]

    def _ctx(self):
        try:
            return self.get_ctx() or {}
        except Exception:
            return {}

    def _mods_info(self):
        ws = self._ctx().get("workspace")
        return self._cached(("mods", str(ws)), lambda: list_mods(ws))

    def _mod_cands(self):
        cur = self._ctx().get("mod")
        out = []
        for m in self._mods_info():
            tag = "★ 当前 Mod" if m["name"] == cur else "Mod"
            out.append((m["name"], tag))
        return out

    def _target_mod(self, tokens):
        if "--mod" in tokens:
            idx = tokens.index("--mod")
            if idx + 1 < len(tokens):
                want = tokens[idx + 1]
                for m in self._mods_info():
                    if m["name"] == want:
                        return m
                return None
        ctx_mod = self._ctx().get("mod")
        if ctx_mod:
            for m in self._mods_info():
                if m["name"] == ctx_mod:
                    return m
            return None
        mods = self._mods_info()
        if len(mods) == 1:
            return mods[0]
        return None

    def _schema(self):
        return self._cached(("schema",), load_schema, ttl=10.0)

    def _cfg_cands(self, tokens=None):
        tgt = self._target_mod(tokens) if tokens else None
        local = set(tgt["cfg_files"]) if tgt else set()
        schema_keys = set(self._schema().keys())
        out = [(n, "本 Mod") for n in sorted(local)]
        out += [(n, "schema") for n in sorted(schema_keys - local)]
        return out

    def _guess_cfg(self, tokens):
        pend = None
        for tok in tokens[1:]:
            if pend is not None:
                pend = None
                continue
            if tok in _VALUE_FLAGS:
                pend = tok
                continue
            if tok.startswith("-") or tok.lower() in _SUB_WORDS or tok.isdigit():
                continue
            norm = cfg_name_normalize(tok)
            if norm and (norm in self._schema() or norm.lower().endswith("cfg")):
                return norm
        return None

    def _ids_for(self, root, cfg_name):
        def _load():
            try:
                data, _, exists = load_cfg(Path(root), cfg_name)
                if not exists or not isinstance(data, dict):
                    return []
                items = sorted(data.items(), key=lambda kv: (len(str(kv[0])), str(kv[0])))
                out = []
                for k, v in items[:800]:
                    if isinstance(v, dict):
                        prev = v.get("id") or v.get("Name") or v.get("name") or v.get("title") or ""
                        meta = f"{prev}" if prev else json.dumps(v, ensure_ascii=False)[:48]
                    else:
                        meta = str(v)[:48]
                    out.append((str(k), meta))
                return out
            except Exception:
                return []
        return self._cached(("ids", str(root), cfg_name), _load, ttl=2.0)

    def _id_cands(self, tokens):
        tgt = self._target_mod(tokens)
        if not tgt:
            return []
        cfg = self._guess_cfg(tokens)
        if not cfg:
            return []
        return self._ids_for(tgt["root"], cfg)

    def _key_cands(self, tokens):
        cfg = self._guess_cfg(tokens)
        if not cfg:
            return []
        fields = self._schema().get(cfg)
        if not fields:
            return []
        return sorted((k, typ) for k, typ in fields.items())

    def _path_cands(self, frag, dirs_only=False, want_json=False):
        raw = frag.strip('"').strip("'")
        try:
            exp = os.path.expandvars(os.path.expanduser(raw)) if raw else "."
            ends_sep = raw.endswith("\\") or raw.endswith("/") or raw.endswith(":")
            p = Path(exp) if exp else Path(".")
        except Exception:
            return []
        if ends_sep or p.is_dir():
            base, prefix, typed = p, "", raw
        else:
            base, prefix = p.parent, p.name
            typed = raw[: len(raw) - len(prefix)] if len(prefix) <= len(raw) else ""
        try:
            entries = sorted(base.iterdir(), key=lambda e: e.name.lower())
        except Exception:
            return []
        low = prefix.lower()
        out = []
        for e in entries:
            name = e.name
            if name.startswith(".") and not low.startswith("."):
                continue
            is_dir = e.is_dir()
            if is_dir:
                ins = name + "\\"
            else:
                if dirs_only:
                    continue
                if want_json and e.suffix.lower() != ".json":
                    continue
                ins = name
            if low and not name.lower().startswith(low) and low not in name.lower():
                continue
            try:
                meta = "目录" if is_dir else f"{e.stat().st_size} B"
            except OSError:
                meta = "目录" if is_dir else ""
            out.append((typed + ins, meta))
            if len(out) >= 120:
                break
        return out

    def _cloud_provider_cands(self):
        """已配置网盘的 (id, name [type]) 候选，来自 .editor_cloud.json（三端共享）。"""
        def _load():
            try:
                from editor.server import cloud_sync as cs
            except Exception:
                return []
            try:
                from editor.server.api import STATE
                ws = self._ctx().get("workspace")
                if not ws:
                    from .utils import resolve_workspace
                    ws = str(resolve_workspace(None))
                if ws and not STATE.workspace_root:
                    STATE.workspace_root = str(ws)
            except Exception:
                pass
            try:
                return [(p.get("id") or "", f"{p.get('name') or ''} [{p.get('type')}]")
                        for p in cs.list_providers()]
            except Exception:
                return []
        return self._cached(("cloudp", str(self._ctx().get("workspace"))), _load, ttl=2.0)

    def _session_cands(self):
        """AI 会话历史 (id, 标题·条数) 候选（agent history / chat --resume）。"""
        def _load():
            try:
                from editor.agent import history_store
                return [(s.get("id") or "",
                         f"{s.get('title') or '（无标题）'} · {s.get('message_count') or 0}条")
                        for s in history_store.list_sessions(limit=30)]
            except Exception:
                return []
        return self._cached(("aisess",), _load, ttl=2.0)

    def _session_ref_cands(self):
        return [("last", "最新一条")] + self._session_cands()

    # ------------------------------------------------------------- mention (@)
    def _mention_cands(self):
        seen, out = set(), []
        for n, meta in self._cfg_cands():
            if n not in seen:
                seen.add(n)
                out.append((n, meta))
        for n, meta in self._mod_cands():
            if n not in seen:
                seen.add(n)
                out.append((n, meta))
        return out

    def _complete_at(self, frag):
        pref = frag[1:]
        if ":" in pref:
            cfg_part, qid = pref.rsplit(":", 1)
            norm = cfg_name_normalize(cfg_part)
            tgt = self._target_mod([])
            ids = self._ids_for(tgt["root"], norm) if tgt else []
            return [(f"@{cfg_part}:{iid}", meta) for iid, meta in self._rank(ids, qid)]
        return [("@" + n, meta) for n, meta in self._rank(self._mention_cands(), pref)]

    # ------------------------------------------------------------- core engine
    def _spec_state(self, cmd, tokens, frag):
        """根据 tokens/frag 推断当前待补全位置。

        约定：tokens 只含"完整的词"，正在输入的词整体在 frag 中。
        """
        table = _SUB_SPECS.get(cmd, {})
        has_subs = cmd in _SUB_META

        # 正在输入子命令这一级
        if has_subs:
            if len(tokens) == 1:
                return self._rank([(s, m) for s, m in _SUB_META[cmd]], frag), None
            sub = tokens[1].lower()
            spec = table.get(sub) or table.get("*") or {"pos": [], "flags": []}
            walk = tokens[2:]
        else:
            spec = table.get("*") or {"pos": [], "flags": []}
            walk = tokens[1:]

        pend_flag = None
        consumed = 0
        used_flags = set()
        for t in walk:
            if pend_flag is not None:
                pend_flag = None
                continue
            if t in _VALUE_FLAGS:
                pend_flag = t
                used_flags.add(t)
                continue
            if t.startswith("-"):
                used_flags.add(t)
                continue
            consumed += 1

        # 补全 flag 的值 (--mod/--id/--key/--file/--cfg ...)
        if pend_flag is not None:
            if pend_flag in ("--mod", "-m"):
                pairs = self._mod_cands()
            elif pend_flag == "--cfg":
                # cloud add 的 --cfg 是 k=v 键值对（驱动配置字段），不是 Cfg 表名
                if cmd == "cloud":
                    return [], None
                pairs = self._cfg_cands(tokens)
            elif pend_flag == "--id":
                pairs = self._id_cands(tokens)
            elif pend_flag == "--key":
                pairs = self._key_cands(tokens)
            elif pend_flag == "--file":
                pairs = self._path_cands(frag, want_json=True)
            elif pend_flag == "--type":
                pairs = _CLOUD_TYPE_CANDS
            elif pend_flag == "--direction":
                pairs = [("upload", "本地→远端"), ("download", "远端→本地"), ("sync", "双向新者为准")]
            elif pend_flag == "--remote-root":
                pairs = _CLOUD_REMOTE_ROOTS
            elif pend_flag == "--provider":
                try:
                    from editor.core.env_store import AI_PROVIDERS
                    pairs = [(p, "") for p in AI_PROVIDERS]
                except Exception:
                    pairs = []
            elif pend_flag == "--resume":
                pairs = self._session_ref_cands()
            elif pend_flag in ("--api-key", "--base-url", "--model", "--temperature"):
                return [], None
            else:
                return [], None
            return self._rank(pairs, frag), None

        pos_types = spec.get("pos", [])
        next_type = pos_types[consumed] if consumed < len(pos_types) else None

        def flag_pairs():
            valid = [f for f in spec.get("flags", []) if f not in used_flags]
            out = []
            for f in valid:
                if f == "--cfg" and cmd == "cloud":
                    out.append((f, "<驱动字段 k=v>"))
                else:
                    out.append((f, _FLAG_META.get(f, "")))
            return out

        # 正在输入以 - 开头的 flag 名
        if frag.startswith("-"):
            return self._rank(flag_pairs(), frag), None
        if next_type in ("mod", "cfg"):
            pairs = self._mod_cands() if next_type == "mod" else self._cfg_cands(tokens)
            ranked = self._rank(pairs, frag)
            if not frag:
                ranked += self._rank(flag_pairs(), "")
            return ranked, None
        if next_type == "id":
            # cloud test/show/remove/sync 的网盘 id
            return self._rank(self._cloud_provider_cands(), frag), None
        if next_type == "session_id":
            # agent history show|resume|delete 的会话 id
            return self._rank(self._session_ref_cands(), frag), None
        if next_type == "dir":
            return self._path_cands(frag, dirs_only=True), None
        if frag:
            return [], None
        return self._rank(flag_pairs(), ""), None

    def complete_pairs(self, text):
        """返回 [(候选, 提示), ...]，候选替换光标前的整个当前词片段。"""
        try:
            return self._complete_pairs_impl(text)
        except Exception:
            if os.environ.get("EDITOR_CLI_DEBUG"):
                import traceback
                traceback.print_exc()
            return []

    def _rank_cmd_cands(self, frag):
        cands = [(c, _CMD_META.get(c, "")) for c in SLASH_CMDS]
        cands += [(d, _CMD_META.get("/" + d, "")) for d in DIRECT_CMDS if "/" + d in _CMD_META]
        return self._rank(cands, frag)

    def _complete_pairs_impl(self, text):
        tokens, frag = self._split(text)
        if frag.startswith("@"):
            return self._complete_at(frag)
        if not tokens:
            return self._rank_cmd_cands(frag)
        name = tokens[0].lstrip("/").lower()
        if name not in _KNOWN_CMDS:
            if len(tokens) == 1 and not frag:
                return self._rank_cmd_cands(tokens[0])
            return []
        if name == "shell":
            return []
        pairs, _extra = self._spec_state(name, tokens, frag)
        return pairs

    # ------------------------------------------------------------- prompt_toolkit
    def get_completions(self, document, complete_event):
        if not HAS_PT:
            return
        text = document.text_before_cursor
        back = len(self._split(text)[1])
        for ins, meta in self.complete_pairs(text):
            yield Completion(ins, start_position=-back, display_meta=meta or None)


class _ReadlineCompleter:
    """input() 回退模式下用 GNU readline 实现 Tab 补全。"""

    def __init__(self, pairs_source):
        self._source = pairs_source
        self._buf = []

    def __call__(self, text, state):
        try:
            import readline
            if state == 0:
                whole = readline.get_line_buffer()
                self._buf = [c for c, _ in self._source(whole)]
            return self._buf[state] if state < len(self._buf) else None
        except Exception:
            return None

# ---------------------------------------------------------------------------
# Interactive CLI
# ---------------------------------------------------------------------------

HELP_MD = """
Editor CLI — 类 Claude Code 交互式  (输入 /help 查看，Tab 补全)
"""

def _print_help():
    # Use Table instead of Markdown to avoid bullet \u2022 GBK issues
    console.print(Panel("[bold cyan]Editor CLI — 类 Claude Code 交互式[/]  输入 [bold]/help[/] 随时查看  [dim]Tab 补全 | ↑↓ 历史 | Ctrl+L 清屏 | Ctrl+D 退出[/]", border_style="cyan"))
    t = Table(title="Slash 命令", show_lines=False)
    t.add_column("命令", style="bold green")
    t.add_column("说明", style="dim")
    t.add_column("示例", style="cyan")
    rows = [
        ("/mods list", "列出 Mods", "/mods list"),
        ("/mods show <name>", "详情", "/mods show test"),
        ("/mods create <title>", "新建", "/mods create MyMod"),
        ("/mods use <name>", "切换当前 Mod (*上下文)", "/mods use test"),
        ("/cfg list", "当前 Mod 的 Cfgs", "/cfg list"),
        ("/cfg get <Cfg> [--id ID]", "读取", "/cfg get EvtCfg --id 320101"),
        ("/cfg set <Cfg> --id <id> --value", "写入", "/cfg set EvtCfg --id 999 --value '{\"title\":\"hi\"}'"),
        ("/cfg edit <Cfg>", "用 $EDITOR 打开", "/cfg edit EvtCfg"),
        ("/cfg delete <Cfg> --id <id>", "删除记录", "/cfg delete EvtCfg --id 999"),
        ("/cfg validate", "校验当前 Mod", "/cfg validate --verbose"),
        ("/edit <Cfg>", "$EDITOR 打开文件 (短写)", "/edit EvtCfg"),
        ("/use <name>", "切换当前 Mod (短写)", "/use test"),
        ("/schema [Cfg]", "查看 GAME_SCHEMA", "/schema EvtCfg"),
        ("/search <kw>", "全文搜索", "/search 320101"),
        ("/workspace show/set", "工作区", "/workspace show"),
        ("/doctor", "环境自检", "/doctor"),
        ("/agent [任务]", "AI 助手直接对话改模", "/agent 把开局事件标题改成…"),
        ("/agent setting", "AI 配置查看/修改 (config 别名)", "/agent setting"),
        ("/agent history", "AI 会话历史 (list/show/resume/delete/clear)", "/agent history resume last"),
        ("/update", "检查 GitHub 更新", "/update"),
        ("/cloud providers|add|test|sync", "云同步网盘", "/cloud sync p1 --mod test --dry-run"),
        ("/plugins list|enable <id>|disable|install|uninstall|reload", "插件管理 (第三方 Python)", "/plugins list"),
        ("/status", "当前上下文", "/status"),
        ("/tui", "启动 TUI", "/tui"),
        ("/clear", "清屏", "/clear"),
        ("/history", "历史", "/history"),
        ("/exit /quit", "退出", "/exit"),
    ]
    for a,b,c in rows:
        t.add_row(a,b,c)
    console.print(t)
    console.print(Panel(
        "[bold]@ 提及[/]\n"
        "  @EvtCfg  →  /cfg get EvtCfg\n"
        "  @EvtCfg:320101  →  /cfg get EvtCfg --id 320101\n"
        "  @test  →  /mods show test\n\n"
        "[bold]! Shell[/]\n"
        "  !dir  /  !ls -la  →  执行 shell\n\n"
        "[bold]上下文[/]\n"
        "  /mods use <name> 后，后续 /cfg 可省略 --mod（类似 Claude Code 记忆）\n\n"
        "[bold]快捷键[/]  Tab 补全 (命令/子命令/Cfg/Mod/记录ID/字段/路径/@提及) | ↑/↓ 历史 | Ctrl+R 搜索 | Ctrl+L 清屏 | Ctrl+C 取消 | Ctrl+D 退出",
        title="提示", border_style="dim"
    ))

class InteractiveCLI:
    def __init__(self, workspace=None):
        self.workspace = resolve_workspace(workspace) if workspace else resolve_workspace(None)
        self.current_mod = None  # name
        self.last_input = None   # 空回车时重复上一条
        self.history_path = editor_root() / ".editor_cli_history"
        # fallback to user home if not writable
        try:
            self.history_path.parent.mkdir(parents=True, exist_ok=True)
            # test writable
            self.history_path.touch(exist_ok=True)
        except Exception:
            self.history_path = Path.home() / ".editor_cli_history"
        self.console = console
        self._init_session()

    def _init_session(self):
        self._completer = EditorCompleter(lambda: {"workspace": self.workspace, "mod": self.current_mod})
        self._use_pt = False  # PromptSession 仅在成功创建后为 True (无 TTY 时回退 input())
        if HAS_PT:
            try:
                style = Style.from_dict({
                    "prompt": "ansicyan bold",
                    "mod": "ansigreen",
                    "completion-menu": "bg:#1b2536 fg:#a8b3c4",
                    "completion-menu.completion": "bg:#1b2536 fg:#a8b3c4",
                    "completion-menu.completion.current": "bg:#1f6feb fg:#ffffff",
                    "completion-menu.meta.completion": "bg:#1b2536 fg:#5a6a80",
                    "completion-menu.meta.completion.current": "bg:#1f6feb fg:#cbd8ea",
                })
                self.session = PromptSession(
                    history=FileHistory(str(self.history_path)),
                    completer=self._completer,
                    complete_while_typing=True,
                    auto_suggest=AutoSuggestFromHistory(),
                    style=style,
                )
                self._use_pt = True
            except Exception as e:
                # NoConsoleScreenBufferError when run without tty (e.g., in test / piped)
                self.session = None
                # store error for debugging but fallback to input()
                self._pt_error = str(e)
        else:
            self.session = None
            # fallback readline history
            try:
                import readline
                if self.history_path.exists():
                    try:
                        readline.read_history_file(str(self.history_path))
                    except Exception:
                        pass
                try:
                    readline.set_completer(_ReadlineCompleter(self._completer.complete_pairs))
                    readline.set_completer_delims(" \t\n")
                    doc = getattr(readline, "__doc__", "") or ""
                    if "libedit" in doc:
                        readline.parse_and_bind("bind ^I rl_complete")
                    else:
                        readline.parse_and_bind("tab: complete")
                except Exception:
                    pass
            except Exception:
                pass

    def _prompt_text(self):
        mod_part = f"[{self.current_mod}] " if self.current_mod else ""
        ws_name = self.workspace.name if self.workspace else ""
        # Claude Code style: "editor › "  with mod
        return f" {mod_part}› "

    def header(self):
        # Claude Code style header
        mods = list_mods(self.workspace)
        schema = load_schema()
        ws = str(self.workspace)
        cur = self.current_mod or "(未选择)"
        # auto-pick first mod if single? keep cur
        table = Table.grid(padding=(0,2))
        table.add_column(style="dim")
        table.add_column()
        table.add_row("Workspace", ws)
        table.add_row("Mods", f"{len(mods)}  ({', '.join(m['name'] for m in mods[:5])}{' +'+str(len(mods)-5) if len(mods)>5 else ''})")
        table.add_row("Schema", f"{len(schema)} cfgs")
        table.add_row("当前 Mod", f"[bold green]{cur}[/]")
        panel = Panel(table, title="[bold cyan]学生时代 · Editor CLI — 类 Claude Code[/]", subtitle="输入 /help 查看命令 · Tab 补全 · @提及 · !shell · Ctrl+D 退出", border_style="cyan")
        console.print(panel)
        console.print("[dim]提示: 直接输入 /mods list 或 @EvtCfg 试试；无参直接回车可重复上一条。[/]")

    def run(self):
        self.header()
        # show quick tips
        console.print("[dim]─" * 60)
        while True:
            try:
                if self._use_pt:
                    text = self.session.prompt(self._prompt_text())
                else:
                    # fallback (无 TTY / prompt_toolkit 初始化失败)
                    try:
                        text = input(self._prompt_text())
                    except EOFError:
                        break
                text = text.strip()
                if not text:
                    # 空回车 → 重复上一条命令 (与 header 提示一致)
                    if self.last_input:
                        console.print(f"[dim]↻ {escape(self.last_input)}[/]")
                        text = self.last_input
                    else:
                        continue
                self.last_input = text
                # save history for fallback (prompt_toolkit 的 FileHistory 自动持久化)
                if not self._use_pt:
                    try:
                        import readline
                        readline.write_history_file(str(self.history_path))
                    except Exception:
                        pass
                # handle @ and ! before slash
                if text.startswith("@"):
                    self.handle_at(text)
                    continue
                if text.startswith("!"):
                    self.handle_shell(text[1:])
                    continue
                # slash or direct
                # allow direct "help" etc without slash
                if text.split()[0] in DIRECT_CMDS and not text.startswith("/"):
                    text = "/" + text
                if text.startswith("/"):
                    should_exit = self.handle_slash(text)
                    if should_exit:
                        break
                    continue
                # if not slash, treat as search or cfg get? default to search
                # For Claude Code feel, bare text is like asking: we do search
                console.print(f"[dim]未识别命令，尝试搜索: {escape(text)}[/]")
                self.cmd_search([text])
            except KeyboardInterrupt:
                console.print("\n[dim]Ctrl+C 已取消 (Ctrl+D 退出)[/]")
                continue
            except EOFError:
                break
            except SystemExit as e:
                # from utils etc - don't exit REPL, just show
                if e.code != 0:
                    console.print(f"[red]exit {e.code}[/]")
                continue
            except Exception as e:
                err_console.print(f"[red]error: {escape(str(e))}[/]")
                import traceback
                if os.environ.get("EDITOR_CLI_DEBUG"):
                    traceback.print_exc()
                continue
        console.print("\n[cyan]bye![/]")

    # ------------------------------------------------------------------ handlers
    def handle_at(self, text):
        # @EvtCfg or @EvtCfg:123 or @modName or @path
        body = text[1:].strip()
        if not body:
            return
        # @cfg:id
        if ":" in body:
            cfg, rid = body.split(":", 1)
            cfg = cfg.strip()
            rid = rid.strip()
            self.dispatch_cfg(["get", cfg, "--id", rid])
            return
        # try cfg name
        schema = load_schema()
        mods = {m["name"]: m for m in list_mods(self.workspace)}
        if body in schema:
            self.dispatch_cfg(["get", body])
            return
        if body in mods:
            self.cmd_mods_show([body])
            return
        # try path
        p = Path(body)
        if p.exists():
            try:
                # cat file with syntax
                txt = p.read_text(encoding="utf-8-sig", errors="replace")[:8000]
                lang = "json" if p.suffix==".json" else "text"
                console.print(Panel(Syntax(txt, lang, line_numbers=True, word_wrap=True), title=str(p)))
            except Exception as e:
                err_console.print(f"[red]read {p}: {e}[/]")
            return
        # fallback search
        console.print(f"[dim]@提及未命中，执行搜索 @{escape(body)}[/]")
        self.cmd_search([body])

    def handle_shell(self, cmd):
        cmd = cmd.strip()
        if not cmd:
            return
        console.print(f"[dim]$ {escape(cmd)}[/]")
        try:
            # use shell on Windows
            proc = subprocess.run(cmd, shell=True, capture_output=False)
            # we let it stream directly; if we want capture, use run with output
            # But for simplicity, subprocess.run already streams to console
            # So we just show return code
            console.print(f"[dim]exit {proc.returncode}[/]")
        except Exception as e:
            err_console.print(f"[red]shell error: {e}[/]")

    def handle_slash(self, text):
        # parse with shlex to keep JSON quoted
        raw = text[1:]  # strip /
        if not raw.strip():
            return False
        # split command and args
        try:
            parts = shlex.split(raw)
        except Exception:
            parts = raw.split()
        if not parts:
            return False
        cmd = parts[0].lower()
        args = parts[1:]

        # map aliases
        if cmd in ("exit","quit","q"):
            return True
        if cmd in ("help","h","?"):
            _print_help()
            return False
        if cmd == "clear":
            console.clear()
            self.header()
            return False
        if cmd == "history":
            self.show_history()
            return False
        if cmd == "status":
            self.show_status()
            return False
        if cmd == "tui":
            self.launch_tui(args)
            return False
        if cmd in ("mods","mod"):
            return self.dispatch_mods(args)
        if cmd == "cfg":
            return self.dispatch_cfg(args)
        if cmd == "schema":
            self.cmd_schema(args)
            return False
        if cmd == "search":
            self.cmd_search(args)
            return False
        if cmd == "workspace":
            return self.dispatch_workspace(args)
        if cmd == "doctor":
            self.cmd_doctor()
            return False
        if cmd == "update":
            self._dispatch_via_app(["update"] + args)
            return False
        if cmd == "agent":
            if not args or args[0].lower() not in ("config", "setting", "chat", "history"):
                # 裸 /agent 或 /agent <任务描述> → 直接进入 agent 对话
                argv = ["agent", "chat"] + args
            else:
                argv = ["agent"] + args
            # REPL 当前 Mod 作为 agent chat 的默认 -m
            if len(argv) > 1 and argv[1] == "chat" and "--mod" not in argv and "-m" not in argv and self.current_mod:
                argv += ["-m", self.current_mod]
            self._dispatch_via_app(argv)
            return False
        if cmd == "cloud":
            self._dispatch_via_app(["cloud"] + args)
            return False
        if cmd == "plugins":
            if not args:
                console.print("[dim]plugins: list | info <id> | install <zip> | "
                              "enable <id> [-y/--yes] | disable <id> | uninstall <id> [-y/--yes] | reload[/]")
                return False
            self._dispatch_via_app(["plugin"] + args)
            return False
        if cmd == "clear":
            console.clear()
            return False
        if cmd == "validate":
            self.dispatch_cfg(["validate"] + args)
            return False
        if cmd == "list":
            # 裸命令别名: list ≈ /mods list
            self.cmd_mods_list()
            return False
        if cmd == "history":
            self.show_history()
            return False
        if cmd == "status":
            self.show_status()
            return False
        if cmd in ("use",):
            # /use modName
            if args:
                self.cmd_mods_use(args)
            else:
                console.print("[yellow]用法: /use <mod>  或  /mods use <mod>[/]")
            return False
        if cmd in ("edit",):
            # /edit EvtCfg → 复用 cfg 编辑 (无 --id 打开整表)
            self.dispatch_cfg(["edit"] + args)
            return False
        if cmd == "shell":
            self.handle_shell(" ".join(args))
            return False
        # unknown -> try dispatch to underlying cli app for compatibility
        # e.g., /mods list etc already handled; else try generic
        console.print(f"[yellow]未知命令: /{escape(cmd)}  输入 /help 查看[/]")
        return False

    # ------------------------------------------------------------------ mod dispatch
    def dispatch_mods(self, args):
        if not args or args[0] == "list":
            self.cmd_mods_list()
            return False
        if args[0] == "show" and len(args)>=2:
            self.cmd_mods_show(args[1:])
            return False
        if args[0] == "use" and len(args)>=2:
            self.cmd_mods_use(args[1:])
            return False
        if args[0] == "create" and len(args)>=2:
            # /mods create Title --desc xxx
            title = args[1]
            desc = ""
            if "--desc" in args:
                idx = args.index("--desc")
                if idx+1 < len(args):
                    desc = args[idx+1]
            self.cmd_mods_create([title, desc])
            return False
        if args[0] == "delete" and len(args)>=2:
            self.cmd_mods_delete(args[1:])
            return False
        if len(args)==1 and args[0] not in ("list","show","create","delete","use"):
            # /mods <name>  -> show
            self.cmd_mods_show(args)
            return False
        console.print("[dim]mods: list | show <name> | use <name> | create <title> | delete <name>[/]")
        return False

    _CFG_SUBS_WITH_MOD = ("list", "get", "set", "edit", "delete", "validate",
                          "export", "import", "add")

    def dispatch_cfg(self, args):
        """cfg 子命令统一复用单命令版实现 (build_parser + 注入当前 Mod 上下文)。

        好处: 单命令/REPL 行为一致, 补全/纠错/$EDITOR/add 等新能力自动生效。
        """
        from .app import build_parser
        argv = ["cfg"] + list(args)
        if len(argv) < 2:
            argv.append("list")
        sub = argv[1].lower()
        if sub in self._CFG_SUBS_WITH_MOD and "--mod" not in argv and self.current_mod:
            argv += ["--mod", self.current_mod]
        # 关键: 单命令实现按自身规则解析 workspace, 这里显式带上 REPL 的上下文
        if self.workspace and not _WS_TOKEN_RE.search(" ".join(argv)):
            argv = ["--workspace", str(self.workspace)] + argv
        try:
            ns = build_parser().parse_args(argv)
            ns.func(ns)
        except SystemExit as e:
            # argparse 用法错误已打印 usage; 这里保证 REPL 不退出
            if e.code not in (0, None):
                console.print("[dim]命令未执行 — 检查参数 (Tab 补全可帮你填对)[/]")
        except KeyboardInterrupt:
            console.print("\n[dim]已取消[/]")
        return False

    def _dispatch_via_app(self, argv):
        """通用单命令复用入口：重组 argv 交给 app.build_parser 解析执行。

        与 dispatch_cfg 同一策略（单命令/REPL 行为一致），供 /agent、/cloud
        等新命令族使用；工作区显式带上 REPL 上下文。
        """
        from .app import build_parser
        full = list(argv)
        if self.workspace and not _WS_TOKEN_RE.search(" ".join(full)):
            full = ["--workspace", str(self.workspace)] + full
        try:
            ns = build_parser().parse_args(full)
            ns.func(ns)
        except SystemExit as e:
            if e.code not in (0, None):
                console.print("[dim]命令未执行 — 检查参数 (Tab 补全可帮你填对)[/]")
        except KeyboardInterrupt:
            console.print("\n[dim]已取消[/]")

    def dispatch_workspace(self, args):
        if not args or args[0]=="show":
            self.cmd_workspace_show()
            return False
        if args[0]=="set" and len(args)>=2:
            self.cmd_workspace_set(args[1:])
            return False
        console.print("[dim]workspace: show | set <path>[/]")
        return False

    # ------------------------------------------------------------------ actual cmd impl (rich)
    def _require_mod_for_interactive(self, explicit_mod=None):
        # use explicit > current_mod > single fallback
        if explicit_mod:
            info = find_mod(explicit_mod, self.workspace)
            if not info:
                err_console.print(f"[red]mod not found: {explicit_mod}[/]")
                return None
            return Path(info["root"]), explicit_mod
        if self.current_mod:
            info = find_mod(self.current_mod, self.workspace)
            if info:
                return Path(info["root"]), self.current_mod
        # try single mod fallback
        mods = list_mods(self.workspace)
        if len(mods)==1:
            return Path(mods[0]["root"]), mods[0]["name"]
        # need explicit
        err_console.print("[yellow]请先 /mods use <name> 选择 Mod，或加 --mod[/]")
        if mods:
            console.print("可用: " + ", ".join(m["name"] for m in mods[:10]))
        return None, None

    def cmd_mods_list(self):
        mods = list_mods(self.workspace)
        t = Table(title=f"Mods @ {self.workspace}  ({len(mods)})", show_lines=False)
        t.add_column("Name", style="bold green")
        t.add_column("Title", style="cyan")
        t.add_column("Cfgs", style="dim")
        t.add_column("Root", style="dim", overflow="fold")
        t.add_column("当前", style="yellow")
        for m in mods:
            cur = "●" if m["name"]==self.current_mod else ""
            cfgs = ", ".join(m["cfg_files"][:5])
            if len(m["cfg_files"])>5:
                cfgs+=f" +{len(m['cfg_files'])-5}"
            t.add_row(m["name"], m["manifest_title"] or "-", cfgs or "-", m["root"], cur)
        console.print(t)
        if not mods:
            console.print("[dim]无 Mods，试试 /mods create MyMod[/]")

    def cmd_mods_show(self, args):
        name = args[0] if args else self.current_mod
        if not name:
            console.print("[yellow]用法: /mods show <name>[/]")
            return
        info = find_mod(name, self.workspace)
        if not info:
            err_console.print(f"[red]mod not found: {name}[/]")
            return
        console.print(Panel(f"[bold]{escape(info['name'])}[/]\n{escape(info['root'])}", title="Mod"))
        # show manifest + cfgs
        from rich.json import JSON as RJSON
        if info.get("manifest"):
            console.print(RJSON(json.dumps(info["manifest"], ensure_ascii=False, indent=2)))
        # cfgs
        cfg_dir = Path(info["root"]) / "Cfgs" / "zh-cn"
        if cfg_dir.is_dir():
            t = Table(title="Cfgs")
            t.add_column("Cfg", style="cyan")
            t.add_column("Records", justify="right")
            t.add_column("Size", justify="right")
            for f in sorted(cfg_dir.glob("*.json")):
                try:
                    data = json.loads(f.read_text(encoding="utf-8-sig") or "{}")
                    n = str(len(data)) if isinstance(data, dict) else "?"
                except Exception:
                    n = "ERR"
                t.add_row(f.stem, n, f"{f.stat().st_size} B")
            console.print(t)

    def cmd_mods_use(self, args):
        name = args[0] if args else None
        if not name:
            console.print("[yellow]用法: /mods use <name>[/]")
            return
        info = find_mod(name, self.workspace)
        if not info:
            err_console.print(f"[red]mod not found: {name}[/]")
            return
        self.current_mod = name
        console.print(f"[green]已切换当前 Mod → [bold]{name}[/]  @ {info['root']}[/]")
        # auto show cfg list (复用单命令实现)
        self.dispatch_cfg(["list"])

    def cmd_mods_create(self, args):
        title = args[0] if args else None
        if not title:
            console.print("[yellow]用法: /mods create <Title>[/]")
            return
        desc = args[1] if len(args)>1 else ""
        import re, datetime
        if re.search(r'[\\/:*?"<>|\x00-\x1f]', title) or title in (".",".."):
            err_console.print(f"[red]非法标题: {title!r}[/]")
            return
        mod_dir = Path(self.workspace) / title
        if mod_dir.exists():
            err_console.print(f"[red]已存在: {mod_dir}[/]")
            return
        mod_dir.mkdir(parents=True, exist_ok=False)
        (mod_dir / "Cfgs" / "zh-cn").mkdir(parents=True, exist_ok=True)
        manifest = {"title": title, "description": desc, "version":"1.0.0", "created_at": datetime.datetime.now().isoformat(timespec="seconds")}
        (mod_dir / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")
        console.print(f"[green]已创建 {mod_dir}[/]")
        self.current_mod = title

    def cmd_mods_delete(self, args):
        name = args[0] if args else None
        if not name:
            console.print("[yellow]用法: /mods delete <name>[/]")
            return
        info = find_mod(name, self.workspace)
        if not info:
            err_console.print(f"[red]not found {name}[/]")
            return
        # workshop guard
        from .utils import workshop_mods_roots
        import os as _os
        abs_root = _os.path.abspath(info["root"])
        if any(abs_root.startswith(_os.path.abspath(r)+_os.path.sep) for r in workshop_mods_roots()):
            err_console.print("[red]workshop mods 不可删除[/]")
            return
        console.print(f"[yellow]将删除 {info['root']}  输入 DELETE 确认:[/]")
        try:
            ans = input("DELETE> ").strip()
        except EOFError:
            return
        if ans != "DELETE":
            console.print("[dim]已取消[/]")
            return
        import shutil
        shutil.rmtree(info["root"], ignore_errors=True)
        console.print(f"[green]已删除 {name}[/]")
        if self.current_mod==name:
            self.current_mod=None

    def cmd_schema(self, args):
        schema=load_schema()
        if args and args[0]!="--json":
            name=cfg_name_normalize(args[0])
            if name not in schema:
                err_console.print(f"[red]未知 cfg {name}[/] total {len(schema)}")
                sug=fuzzy_suggest(name, schema.keys())
                if sug:
                    err_console.print(f"[yellow]did you mean:[/] [bold]{', '.join(sug)}[/]")
                return
            fields=schema[name]
            t=Table(title=f"Schema: {name}")
            t.add_column("Field", style="cyan")
            t.add_column("Type", style="magenta")
            for k,typ in sorted(fields.items()):
                t.add_row(k, typ)
            console.print(t)
            return
        # list
        t=Table(title=f"GAME_SCHEMA ({len(schema)} cfgs)")
        t.add_column("Cfg", style="bold cyan")
        t.add_column("Fields", style="dim")
        t.add_column("Preview", overflow="fold")
        for n in sorted(schema.keys()):
            fields=schema[n]
            prev=", ".join(f"{k}:{v}" for k,v in list(fields.items())[:3])
            if len(fields)>3:
                prev+=f" +{len(fields)-3}"
            t.add_row(n, str(len(fields)), prev)
        console.print(t)

    def cmd_search(self, args):
        if not args:
            console.print("[yellow]用法: /search <kw> [--cfg Cfg][/]")
            return
        kw=args[0]
        cfg_filter=None
        if "--cfg" in args:
            idx=args.index("--cfg")
            if idx+1 < len(args):
                cfg_filter=args[idx+1]
        # search in current mod or all?
        mods=[]
        if self.current_mod:
            info=find_mod(self.current_mod, self.workspace)
            if info:
                mods=[info]
        else:
            mods=list_mods(self.workspace)
        hits=[]
        for m in mods:
            res=search_in_mod(m["root"], kw, cfg_filter)
            for r in res:
                r["mod"]=m["name"]
                hits.append(r)
        if not hits:
            console.print(f"[yellow]无结果 {kw!r}[/]")
            return
        t=Table(title=f"Search: {kw!r} ({len(hits)})")
        t.add_column("Mod", style="dim")
        t.add_column("Cfg", style="cyan")
        t.add_column("ID", style="bold green")
        t.add_column("Snippet", overflow="fold", max_width=80)
        for h in hits[:100]:
            t.add_row(h["mod"], h["cfg"], h["id"], escape(h["snippet"][:120]))
        console.print(t)
        if len(hits)>100:
            console.print(f"[dim]仅显示 100/{len(hits)}[/]")

    def cmd_workspace_show(self):
        console.print(f"[bold]workspace:[/] {self.workspace}")
        console.print(f"editor_root: {editor_root()}")
        console.print(f"user_mods: {user_mods_dir()}")
        from pathlib import Path as _P
        env=_P(editor_root()) / "editor_env.json"
        if env.exists():
            console.print(Panel(Syntax(env.read_text(encoding="utf-8-sig"), "json"), title=str(env)))
        mods=list_mods(self.workspace)
        console.print(f"[dim]{len(mods)} mods[/]")

    def cmd_workspace_set(self, args):
        path=args[0] if args else None
        if not path:
            console.print("[yellow]用法: /workspace set <path>[/]")
            return
        p=Path(path).expanduser().resolve()
        if not p.is_dir():
            try:
                p.mkdir(parents=True, exist_ok=True)
            except Exception as e:
                err_console.print(f"[red]{e}[/]")
                return
        env=editor_root() / "editor_env.json"
        data={}
        if env.exists():
            try:
                data=json.loads(env.read_text(encoding="utf-8-sig"))
            except:
                data={}
        data["workspace_root"]=str(p)
        env.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
        self.workspace=p
        console.print(f"[green]workspace → {p}[/]")

    def cmd_doctor(self):
        # reuse logic but rich
        checks=[]
        def ok(m): checks.append(("ok",m))
        def warn(m): checks.append(("warn",m))
        def err(m): checks.append(("err",m))
        import sys as _sys
        ok(f"python {_sys.version.split()[0]} @ {_sys.executable}")
        try:
            import rich
            import importlib.metadata as im
            ver=im.version("rich")
            ok(f"rich {ver}")
        except Exception as e:
            err(f"rich {e}")
        try:
            import textual
            ok(f"textual {textual.__version__}")
        except:
            warn("textual 未安装")
        try:
            import prompt_toolkit
            ok(f"prompt_toolkit {prompt_toolkit.__version__}")
        except:
            warn("prompt_toolkit 未安装 (REPL 仍可用，回退到 input)")
        schema=load_schema()
        if schema:
            ok(f"GAME_SCHEMA {len(schema)}")
        else:
            warn("GAME_SCHEMA 空")
        if self.workspace.is_dir():
            ok(f"workspace {self.workspace} 存在")
        else:
            warn(f"workspace {self.workspace} 不存在")
        mods=list_mods(self.workspace) if self.workspace.is_dir() else []
        ok(f"mods {len(mods)}")
        try:
            test=self.workspace / ".doctor_test"
            test.write_text("ok", encoding="utf-8")
            test.unlink(missing_ok=True)
            ok("workspace 可写")
        except Exception as e:
            err(f"workspace 不可写 {e}")
        for lv,msg in checks:
            icon={"ok":"[green][OK]","warn":"[yellow][WARN]","err":"[red][ERR]"}[lv]
            console.print(f"{icon} {escape(msg)}[/]")
        if any(lv=="err" for lv,_ in checks):
            console.print("\n[red]有错误[/]")
        else:
            console.print("\n[green]全部通过[/]")

    def show_history(self):
        try:
            lines=self.history_path.read_text(encoding="utf-8", errors="replace").splitlines()[-50:]
            console.print(Panel("\n".join(escape(l) for l in lines), title="History 最近 50"))
        except Exception as e:
            console.print(f"[dim]无历史: {e}[/]")

    def show_status(self):
        tbl=Table.grid(padding=(0,2))
        tbl.add_column(style="dim")
        tbl.add_column()
        tbl.add_row("Workspace", str(self.workspace))
        tbl.add_row("当前 Mod", self.current_mod or "(未选择)")
        tbl.add_row("Mods", str(len(list_mods(self.workspace))))
        tbl.add_row("Schema", str(len(load_schema())))
        console.print(Panel(tbl, title="Status"))

    def launch_tui(self, args):
        # args may contain --mod
        mod=None
        if args and "--mod" in args:
            idx=args.index("--mod")
            if idx+1<len(args):
                mod=args[idx+1]
        # use current_mod as fallback
        target=mod or self.current_mod
        console.print(f"[dim]启动 TUI {f'--mod {target}' if target else ''} ...[/]")
        try:
            from editor.tui.app import run as tui_run
            # need to suspend? prompt_toolkit and textual both claim terminal
            # For simplicity, just run
            tui_run(workspace=str(self.workspace), initial_mod=target)
        except Exception as e:
            err_console.print(f"[red]TUI 启动失败: {e}[/]")
            console.print("[dim]提示: pip install textual 后重试[/]")

def run_interactive(workspace=None):
    # 首次访问 → OOBE 引导（--oobe / 首访标记共用；管道与 EDITOR_NO_OOBE=1 跳过）
    try:
        from .oobe import autostart_allowed, run_cli_wizard
        if autostart_allowed():
            run_cli_wizard()
    except Exception:
        pass
    cli=InteractiveCLI(workspace=workspace)
    cli.run()
