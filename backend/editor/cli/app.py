# -*- coding: utf-8 -*-
"""CLI entry – argparse + rich.  Usage: python -m editor.cli <cmd>"""

import argparse
import json
import os
import re
import sys
import subprocess
import shutil
from pathlib import Path

from rich.console import Console
from rich.table import Table
from rich.panel import Panel
from rich.syntax import Syntax
from rich.markup import escape

from .utils import (
    editor_root, user_mods_dir, resolve_workspace, list_mods, find_mod,
    cfg_name_normalize, cfg_path, load_cfg, save_cfg, load_schema,
    validate_cfg, search_in_mod, CfgParseError, fuzzy_suggest, default_record,
    suggest_next_id,
)

# Force UTF-8 stdout/stderr early to avoid GBK encode errors on Windows
# consoles printing CJK / box-drawing characters.
try:
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    if hasattr(sys.stderr, "reconfigure"):
        sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

console = Console(legacy_windows=False)
err_console = Console(stderr=True, legacy_windows=False)

# ---------------------------------------------------------------------------
# helpers for output
# ---------------------------------------------------------------------------

def _json_out(obj, pretty=True):
    if pretty:
        console.print_json(json.dumps(obj, ensure_ascii=False, indent=2))
    else:
        console.print(json.dumps(obj, ensure_ascii=False))

def _want_json(args) -> bool:
    return bool(getattr(args, "json", False) or getattr(args, "global_json", False))

def _print_kv(d: dict):
    for k, v in d.items():
        console.print(f"[bold cyan]{k}[/]: {escape(str(v))}")

def _require_mod(args) -> Path:
    # --mod / --workspace / current selection via editor_env.json
    mod_name = getattr(args, "mod", None) or getattr(args, "mod_name", None)
    workspace = getattr(args, "workspace", None)
    ws_path = resolve_workspace(workspace) if workspace else resolve_workspace(None)
    # if mod_name provided, lookup
    if mod_name:
        info = find_mod(mod_name, ws_path)
        if not info:
            err_console.print(f"[red]mod not found: {mod_name}[/]  workspace={ws_path}")
            # list available
            mods = list_mods(ws_path)
            if mods:
                err_console.print("available: " + ", ".join(m["name"] for m in mods[:20]))
            raise SystemExit(1)
        return Path(info["root"])
    # else try editor_env.json selected mod or editor_root
    # fallback: if only one mod, use it; else ask
    # Check editor_env.json for selected mod? For now use heuristic: if workspace contains Cfgs, treat as mod itself
    if (ws_path / "Cfgs").is_dir():
        # workspace itself is a mod (e.g. editor_root)
        return ws_path
    # try to find selected in state file (editor/server/api STATE)
    # for CLI convenience, if exactly one mod, use it
    mods = list_mods(ws_path)
    if len(mods) == 1:
        return Path(mods[0]["root"])
    # otherwise require explicit --mod
    err_console.print("[red]--mod is required[/] (multiple mods found, cannot infer)")
    if mods:
        err_console.print("available mods:")
        for m in mods[:20]:
            err_console.print(f"  - {m['name']}  ({m['root']})")
    raise SystemExit(1)


# ---------------------------------------------------------------------------
# typo hints ("did you mean ...")
# ---------------------------------------------------------------------------

class _Parser(argparse.ArgumentParser):
    """argparse with fuzzy suggestions on 'invalid choice' errors."""

    def error(self, message):
        m = re.search(r"invalid choice:\s*'([^']+)'", str(message))
        if m:
            choices: list[str] = []
            for act in self._actions:
                ch = getattr(act, "choices", None)
                if ch:
                    choices.extend(c for c in ch if isinstance(c, str))
            sug = fuzzy_suggest(m.group(1), choices)
            if sug:
                err_console.print(f"[yellow]did you mean:[/] [bold]{', '.join(sug)}[/]")
        super().error(message)


def _schema_names():
    return sorted(load_schema().keys())


def _print_cfg_hint(cname: str):
    """Print close schema matches for an unknown cfg name."""
    sug = fuzzy_suggest(cname, _schema_names())
    if sug:
        err_console.print(f"[yellow]did you mean:[/] [bold]{', '.join(sug)}[/]")


def _print_id_hint(rid: str, data: dict):
    """Print close record-id matches when a lookup misses."""
    sug = fuzzy_suggest(str(rid), list(data.keys())[:5000])
    if sug:
        err_console.print(f"[yellow]closest ids:[/] [bold]{', '.join(sug)}[/]")


# ---------------------------------------------------------------------------
# cfg rendering helpers (table view / record view)
# ---------------------------------------------------------------------------

_PREFERRED_FIELDS = ("title", "Title", "name", "Name", "desc", "description",
                     "text", "Text", "content")

_TABLE_PREVIEW_ROWS = 30


def _cell(v, width: int = 28) -> str:
    """Compact human-readable cell text."""
    if isinstance(v, (dict, list)):
        s = json.dumps(v, ensure_ascii=False, separators=(",", ":"))
        typ = "…" if isinstance(v, dict) else "[…]"
        if len(s) > width - len(typ):
            s = f"{s[:width - 3]}{typ}"
        return s
    s = "null" if v is None else str(v)
    return s if len(s) <= width else f"{s[:width-1]}…"


def _sort_keys(data: dict):
    return sorted(data.keys(), key=lambda x: int(x) if str(x).lstrip("-").isdigit() else x)


def _pick_columns(data: dict, explicit=None) -> list[str]:
    """Choose display columns: --fields wins, then common names, then first keys."""
    if explicit:
        return [c.strip() for c in explicit.split(",") if c.strip()]
    sample = next((r for r in data.values() if isinstance(r, dict)), None)
    if not sample:
        return []
    cols = [f for f in _PREFERRED_FIELDS if any(
        isinstance(r, dict) and f in r for r in list(data.values())[:200])]
    if not cols:
        cols = [k for k in sample.keys() if k != "id"]
    return cols[:3]


def _render_table_view(cfg_name: str, data: dict, path, args):
    cols = _pick_columns(data, getattr(args, "fields", None))
    keys = _sort_keys(data)
    shown = keys if getattr(args, "all", False) else keys[:_TABLE_PREVIEW_ROWS]
    t = Table(title=f"{cfg_name}  {len(data)} records  @ {path}")
    t.add_column("ID", style="bold green")
    for c in cols:
        t.add_column(c, style="cyan", overflow="fold")
    unknown_cols = [c for c in cols if not any(isinstance(r, dict) and c in r for r in data.values())]
    for k in shown:
        rec = data[k]
        row = [str(k)]
        for c in cols:
            row.append(_cell(rec.get(c)) if isinstance(rec, dict) else escape(str(rec))[:40])
        t.add_row(*row)
    console.print(t)
    notes = []
    if unknown_cols and getattr(args, "fields", None):
        notes.append(f"columns with no values: {', '.join(unknown_cols)}")
    if len(shown) < len(data):
        notes.append(f"showing {_TABLE_PREVIEW_ROWS}/{len(data)} rows – use --all for the rest, --json to pipe")
    elif not cols:
        notes.append("no usable field columns found; try --fields a,b,c or --json")
    for n in notes:
        console.print(f"[dim]{n}[/]")


def _render_record_view(cfg_name: str, rid: str, rec, schema_fields: dict, path):
    console.print(f"[bold]{cfg_name}[{rid}][/]  @ {path}")
    if not isinstance(rec, dict):
        console.print_json(json.dumps(rec, ensure_ascii=False, indent=2))
        return
    t = Table(title=None, show_header=True)
    t.add_column("Field", style="cyan")
    t.add_column("Type", style="dim")
    t.add_column("Value", overflow="fold")
    missing = []
    listed = set()
    ordered = [f for f in schema_fields if f in rec] + [k for k in rec if k not in schema_fields]
    for f in ordered:
        typ = schema_fields.get(f)
        mark = "" if typ is not None else "*"
        val = escape(_cell(rec[f], width=10**6))
        t.add_row(f + mark, str(typ or "unknown"), val)
        listed.add(f)
    console.print(t)
    for f in schema_fields:
        if f not in listed:
            missing.append(f)
    if missing:
        console.print(f"[dim]missing schema fields ({len(missing)}): {', '.join(missing[:12])}{' …' if len(missing) > 12 else ''}[/]")
    console.print("[dim]--json 可输出原始 JSON；带 * 为 schema 外字段[/]")

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

def cmd_mods_list(args):
    ws = resolve_workspace(getattr(args, "workspace", None))
    mods = list_mods(ws)
    if _want_json(args):
        _json_out({"workspace": str(ws), "mods": mods})
        return
    t = Table(title=f"Mods @ {ws}  ({len(mods)} found)", show_lines=False)
    t.add_column("Name", style="bold green")
    t.add_column("Title", style="cyan")
    t.add_column("Cfgs", style="dim")
    t.add_column("Root", style="dim", overflow="fold")
    t.add_column("Manifest", style="yellow")
    for m in mods:
        cfgs = ", ".join(m["cfg_files"][:6])
        if len(m["cfg_files"]) > 6:
            cfgs += f" +{len(m['cfg_files'])-6}"
        t.add_row(m["name"], m["manifest_title"] or "-", cfgs or "-", m["root"], "yes" if m["has_manifest"] else "no")
    console.print(t)
    if not mods:
        console.print("[dim]no mods found. Create one with:  python -m editor.cli mods create <Title>[/]")

def cmd_mods_create(args):
    ws = resolve_workspace(getattr(args, "workspace", None))
    title = args.title.strip()
    if not title:
        err_console.print("[red]title required[/]")
        raise SystemExit(1)
    import re
    if re.search(r'[\\/:*?"<>|\x00-\x1f]', title) or title in (".", ".."):
        err_console.print(f"[red]invalid title (contains illegal chars): {title!r}[/]")
        raise SystemExit(1)
    mod_dir = Path(ws) / title
    if mod_dir.exists():
        err_console.print(f"[red]already exists: {mod_dir}[/]")
        raise SystemExit(1)
    mod_dir.mkdir(parents=True, exist_ok=False)
    (mod_dir / "Cfgs" / "zh-cn").mkdir(parents=True, exist_ok=True)
    import datetime
    manifest = {
        "title": title,
        "description": getattr(args, "desc", "") or "",
        "version": "1.0.0",
        "created_at": datetime.datetime.now().isoformat(timespec="seconds"),
    }
    (mod_dir / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")
    console.print(f"[green]created[/] {mod_dir}")
    console.print_json(json.dumps(manifest, ensure_ascii=False, indent=2))

def cmd_mods_delete(args):
    ws = resolve_workspace(getattr(args, "workspace", None))
    name = args.name
    info = find_mod(name, ws)
    if not info:
        err_console.print(f"[red]mod not found: {name}[/]")
        raise SystemExit(1)
    # safety: workshop mods not deletable via CLI
    from .utils import workshop_mods_roots
    abs_root = os.path.abspath(info["root"])
    if any(abs_root.startswith(os.path.abspath(r) + os.sep) for r in workshop_mods_roots()):
        err_console.print("[red]workshop mods cannot be deleted via CLI (use Steam client)[/]")
        raise SystemExit(1)
    if not args.force:
        console.print(f"[yellow]will delete:[/] {info['root']}")
        ans = console.input("[bold red]type DELETE to confirm: [/]")
        if ans.strip() != "DELETE":
            console.print("[dim]cancelled[/]")
            return
    import shutil
    shutil.rmtree(info["root"], ignore_errors=True)
    console.print(f"[green]deleted[/] {name}")

def cmd_mods_show(args):
    ws = resolve_workspace(getattr(args, "workspace", None))
    name = args.name
    info = find_mod(name, ws)
    if not info:
        err_console.print(f"[red]mod not found: {name}[/]")
        raise SystemExit(1)
    if _want_json(args):
        _json_out(info)
        return
    console.print(Panel.fit(f"[bold]{escape(info['name'])}[/]\n{escape(info['root'])}", title="Mod"))
    _print_kv({k: v for k, v in info.items() if k not in ("manifest",)})
    if info.get("manifest"):
        console.print("\n[bold]manifest.json[/]")
        console.print_json(json.dumps(info["manifest"], ensure_ascii=False, indent=2))
    # cfg files detail
    cfg_dir = Path(info["root"]) / "Cfgs" / "zh-cn"
    if cfg_dir.is_dir():
        files = sorted(cfg_dir.glob("*.json"))
        t = Table(title="Cfgs")
        t.add_column("Cfg", style="cyan")
        t.add_column("Keys", justify="right")
        t.add_column("Size", justify="right")
        t.add_column("Path", style="dim", overflow="fold")
        for f in files:
            try:
                data = json.loads(f.read_text(encoding="utf-8-sig") or "{}")
                keys = len(data) if isinstance(data, dict) else 0
            except Exception:
                keys = "ERR"
            t.add_row(f.stem, str(keys), f"{f.stat().st_size} B", str(f))
        console.print(t)

def cmd_cfg_list(args):
    mod_root = _require_mod(args)
    cfg_dir = mod_root / "Cfgs" / "zh-cn"
    if not cfg_dir.is_dir():
        console.print(f"[yellow]no Cfgs dir at {cfg_dir}[/]")
        return
    files = sorted(cfg_dir.glob("*.json"))
    if _want_json(args):
        out = []
        for f in files:
            try:
                data = json.loads(f.read_text(encoding="utf-8-sig") or "{}")
                n = len(data) if isinstance(data, dict) else 0
            except Exception as e:
                n = f"error: {e}"
            out.append({"cfg": f.stem, "path": str(f), "keys": n, "size": f.stat().st_size})
        _json_out(out)
        return
    t = Table(title=f"Cfgs @ {mod_root.name}  ({mod_root})")
    t.add_column("Cfg", style="bold cyan")
    t.add_column("Records", justify="right")
    t.add_column("Size", justify="right")
    t.add_column("Schema?", style="dim")
    schema = load_schema()
    for f in files:
        try:
            data = json.loads(f.read_text(encoding="utf-8-sig") or "{}")
            n = str(len(data)) if isinstance(data, dict) else "?"
        except Exception as e:
            n = f"[red]ERR[/]"
        has_schema = "yes" if f.stem in schema else "no"
        t.add_row(f.stem, n, f"{f.stat().st_size} B", has_schema)
    console.print(t)

def cmd_cfg_get(args):
    mod_root = _require_mod(args)
    cfg_name = cfg_name_normalize(args.cfg)
    data, path, exists = load_cfg(mod_root, cfg_name)
    if not exists:
        err_console.print(f"[yellow]cfg not found (no file): {path}[/]")
        if not _want_json(args) and not args.id and not args.key:
            console.print("[dim]returning empty dict[/]")
            _json_out({})
        elif _want_json(args):
            _json_out({})
        return
    if args.id:
        rid = str(args.id)
        rec = data.get(rid) if isinstance(data, dict) else None
        if rec is None:
            err_console.print(f"[red]id not found: {rid} in {cfg_name} ({len(data)} records)[/]")
            _print_id_hint(rid, data)
            raise SystemExit(1)
        if args.key:
            if args.key not in rec:
                err_console.print(f"[red]key {args.key!r} not in record {rid}[/]  available: {list(rec.keys())}")
                raise SystemExit(1)
            val = rec[args.key]
            if _want_json(args):
                _json_out(val)
            else:
                console.print_json(json.dumps(val, ensure_ascii=False, indent=2))
            return
        if _want_json(args):
            _json_out(rec)
        else:
            fields = load_schema().get(cfg_name, {})
            _render_record_view(cfg_name, rid, rec, fields, path)
        return
    if args.key:
        # filter all records by key presence? Show all values for that key
        out = {rid: rec.get(args.key) for rid, rec in data.items() if isinstance(rec, dict) and args.key in rec}
        if _want_json(args):
            _json_out(out)
        else:
            console.print(f"[bold]{cfg_name}.*.{args.key}[/]  ({len(out)} hits)")
            console.print_json(json.dumps(out, ensure_ascii=False, indent=2))
        return
    # whole cfg
    if _want_json(args):
        _json_out(data)
    else:
        _render_table_view(cfg_name, data, path, args)

def _pick_editor() -> str:
    editor = os.environ.get("EDITOR") or os.environ.get("VISUAL")
    if not editor:
        if sys.platform == "win32":
            # try notepad or code
            for cand in ["code", "notepad"]:
                if shutil.which(cand):
                    editor = cand
                    break
            else:
                editor = "notepad"
        else:
            for cand in ["nano", "vim", "vi"]:
                if shutil.which(cand):
                    editor = cand
                    break
            else:
                editor = "vi"
    return editor


def _edit_json_via_editor(initial: dict | None) -> dict:
    """Open $EDITOR with prefilled JSON; parse back on close.

    Raises SystemExit on launch/parse failure; returns dict when valid.
    """
    import tempfile
    editor = _pick_editor()
    fd, tmp_name = tempfile.mkstemp(suffix=".json")
    os.close(fd)
    tmp = Path(tmp_name)
    try:
        tmp.write_text(json.dumps(initial or {}, ensure_ascii=False, indent=2), encoding="utf-8")
        console.print(f"[dim]opening {tmp.name} with {editor} ... (保存并关闭编辑器以继续)[/]")
        rc = subprocess.run([editor, str(tmp)]).returncode
        text = tmp.read_text(encoding="utf-8-sig").strip()
    finally:
        try:
            tmp.unlink(missing_ok=True)
        except Exception:
            pass
    if rc != 0:
        err_console.print(f"[red]editor exited with code {rc}, aborted[/]")
        raise SystemExit(1)
    if not text:
        err_console.print("[red]empty edit result, aborted[/]")
        raise SystemExit(1)
    try:
        parsed = json.loads(text)
    except Exception as e:
        err_console.print(f"[red]edited content is not valid JSON: {e}[/]")
        raise SystemExit(1)
    if not isinstance(parsed, dict):
        err_console.print("[red]record must be a JSON object[/]")
        raise SystemExit(1)
    return parsed


def _coerce_typed(raw: str, typ):
    """按 schema 类型把输入转换为值; 失败抛 ValueError。"""
    s = raw.strip()
    if typ == "Number":
        try:
            return int(s)
        except ValueError:
            return float(s)  # may raise ValueError -> caller warns
    if typ == "1D Array":
        try:
            v = json.loads(s)
            if isinstance(v, list):
                return v
        except Exception:
            pass
        parts = [p.strip() for p in re.split(r"[,，]", s) if p.strip()]
        conv = []
        for p in parts:
            if re.fullmatch(r"-?\d+", p):
                conv.append(int(p))
            elif re.fullmatch(r"-?\d+\.\d+", p):
                conv.append(float(p))
            else:
                conv.append(p)
        return conv
    if typ == "2D Array":
        try:
            v = json.loads(s)
            if isinstance(v, list):
                return v
        except Exception:
            pass
        rows = []
        for part in re.split(r"[;；]", s):
            cells = [c.strip() for c in part.split("|") if c.strip()]
            if not cells:
                continue
            row = []
            for c in cells:
                if re.fullmatch(r"-?\d+", c):
                    row.append(int(c))
                elif re.fullmatch(r"-?\d+\.\d+", c):
                    row.append(float(c))
                else:
                    row.append(c)
            rows.append(row)
        return rows
    # String / 未知类型: JSON 字面量优先, 否则原样字符串 ("" 表示空串)
    if s.startswith(('"', "{", "[")):
        try:
            return json.loads(s)
        except Exception:
            pass
    return s


def _edit_record_interactive(cfg_name: str, rid: str, rec: dict):
    """CLI 内置逐字段编辑器。

    回车=保留当前值; !q=中止; String 输入 "" 设为空串;
    数组可用 [1,2] / 1,2 简写; 结束后汇总变更并确认。
    返回编辑后的 dict, 中止/未修改返回 None (调用方不落盘)。
    """
    fields = load_schema().get(cfg_name, {})
    ordered = list(fields.keys()) + [k for k in rec if k not in fields]
    result = dict(rec)
    changes = []
    total = len(ordered)
    console.print(
        f"[bold]{cfg_name}[{rid}][/][dim] 内置编辑器[/] — "
        "[dim]回车保留 | 输入新值替换 | \"\"清空字符串 | !q 放弃[/]"
    )
    idx = 0
    for f in ordered:
        idx += 1
        typ = fields.get(f)
        cur = result.get(f)
        if f == "id":
            console.print(f"[cyan][{idx}/{total}][/][bold] id[/] = {escape(str(cur))}  [dim](锁定不可改)[/]")
            continue
        while True:
            preview = escape(_cell(cur, width=56))
            tag = f"[dim]({typ})[/]" if typ else "[yellow](schema 外)[/]"
            try:
                ans = console.input(f"[cyan][{idx}/{total}][/][bold] {f}[/] {tag} = {preview} > ")
            except EOFError:
                console.print("\n[dim]中止[/]")
                return None
            except KeyboardInterrupt:
                console.print("\n[dim]中止 (丢弃全部修改)[/]")
                return None
            raw = ans.rstrip()
            if raw.strip() == "!q":
                console.print("[dim]已放弃全部修改[/]")
                return None
            if raw.strip() == "":
                break  # keep current
            try:
                val = _coerce_typed(raw, typ)
            except ValueError as e:
                err_console.print(f"[red]{f}: {e}[/]  (回车保留原值或重新输入)")
                continue
            changes.append((f, cur, val))
            result[f] = val
            cur = val
            break
    if not changes:
        console.print("[dim]无修改[/]")
        return None
    t = Table(title=f"变更 ({len(changes)} 项)")
    t.add_column("字段", style="cyan")
    t.add_column("旧值", overflow="fold")
    t.add_column("→ 新值", style="green", overflow="fold")
    for f, old, new in changes:
        t.add_row(f, escape(_cell(old)), escape(_cell(new)))
    console.print(t)
    try:
        ok = console.input("[bold green]保存到磁盘? [y/N]: [/]").strip().lower()
    except Exception:
        ok = ""
    if ok != "y":
        console.print("[dim]已放弃 (未写入)[/]")
        return None
    return result


def cmd_cfg_set(args):
    mod_root = _require_mod(args)
    cfg_name = cfg_name_normalize(args.cfg)
    data, path, exists = load_cfg(mod_root, cfg_name)
    if data is None:
        data = {}
    # input sources: --value (json), --file, --stdin, or --id + --key + --value
    new_data = None
    if args.file:
        p = Path(args.file)
        if not p.is_file():
            err_console.print(f"[red]file not found: {p}[/]")
            raise SystemExit(1)
        try:
            new_data = json.loads(p.read_text(encoding="utf-8-sig"))
        except Exception as e:
            err_console.print(f"[red]json parse failed for {p}: {e}[/]")
            raise SystemExit(1)
        if args.id:
            # file contains single record value
            rid = str(args.id)
            if not isinstance(data, dict):
                data = {}
            data[rid] = new_data
        else:
            if not isinstance(new_data, dict):
                err_console.print("[red]cfg file must be a dict/object at top level[/]")
                raise SystemExit(1)
            data = new_data
        path = save_cfg(mod_root, cfg_name, data)
        console.print(f"[green]saved[/] {cfg_name} -> {path}  ({len(data)} records)")
        return

    parsed = None
    if args.value is not None:
        raw = args.value
        # PowerShell / cmd escaping fix: '{\"a\":1}' -> '{"a":1}'
        def _try_parse(s):
            try:
                return json.loads(s), True
            except Exception:
                return s, False
        parsed, ok = _try_parse(raw)
        if not ok and '\\"' in raw:
            # try unescaping \" -> "
            alt = raw.replace('\\"', '"').replace("\\'", "'")
            # also handle double-escaped?
            alt2, ok2 = _try_parse(alt)
            if ok2:
                parsed, ok = alt2, True
            else:
                # try single quotes to double quotes fallback
                alt3 = raw.replace("'", '"')
                alt3p, ok3 = _try_parse(alt3)
                if ok3:
                    parsed = alt3p
                else:
                    parsed = raw
        elif not ok:
            # last fallback: raw string value for --key case will be kept as string
            # but for record-level we need dict; keep raw so later error is clear
            parsed = raw
    elif args.id and not args.key:
        # no --value/--file: edit the single record inside the CLI (per-field)
        rid = str(args.id)
        is_new = not (isinstance(data, dict) and isinstance(data.get(rid), dict))
        base = data.get(rid) if not is_new else default_record(cfg_name, rid)
        console.print(f"[dim]新建记录, 已按 schema 填默认值[/]" if is_new else f"[dim]编辑已有记录 {cfg_name}[{rid}][/]")
        if getattr(args, "editor", False):
            parsed = _edit_json_via_editor(base)
        else:
            parsed = _edit_record_interactive(cfg_name, rid, base)
            if parsed is None:
                return

    if args.value is None and parsed is None and not (args.id and args.key):
        err_console.print("[red]need --value or --file[/]")
        raise SystemExit(1)
    if args.id and args.key and args.value is None:
        err_console.print("[red]--key set requires --value or --file[/]")
        raise SystemExit(1)

    if args.id and args.key:
        rid = str(args.id)
        if rid not in data or not isinstance(data[rid], dict):
            data[rid] = {}
        data[rid][args.key] = parsed
    elif args.id:
        rid = str(args.id)
        if not isinstance(parsed, dict):
            err_console.print("[red]when setting whole record, value must be JSON object[/]")
            raise SystemExit(1)
        data[rid] = parsed
    elif args.key:
        err_console.print("[red]--key requires --id[/]")
        raise SystemExit(1)
    else:
        if not isinstance(parsed, dict):
            err_console.print("[red]value must be JSON object when setting whole cfg[/]")
            raise SystemExit(1)
        data = parsed

    # optional validation
    issues = validate_cfg(cfg_name, data)
    has_error = any(lv == "error" for lv, _ in issues)
    if issues:
        for lv, msg in issues:
            col = "red" if lv == "error" else "yellow"
            err_console.print(f"[{col}]{lv}:[/] {escape(msg)}")
        if has_error and not args.force:
            err_console.print("[red]validation has errors, aborting (use --force to save anyway)[/]")
            raise SystemExit(1)

    path = save_cfg(mod_root, cfg_name, data)
    bak = Path(str(path) + ".bak")
    note = f"  [dim](backup: {bak.name})[/]" if bak.is_file() else ""
    console.print(f"[green]saved[/] {cfg_name} -> {path}  ({len(data)} records){note}")

def cmd_cfg_add(args):
    """Create a new record: schema defaults + optional overrides, id = max+1."""
    mod_root = _require_mod(args)
    cfg_name = cfg_name_normalize(args.cfg)
    data, path, exists = load_cfg(mod_root, cfg_name)
    if data is None or not isinstance(data, dict):
        data = {}
    # pick id: explicit --id wins; else max numeric id + 1
    if args.id is not None:
        rid = str(args.id)
        if rid in data:
            err_console.print(f"[red]id already exists: {rid}[/]  (use 'cfg set' to overwrite)")
            raise SystemExit(1)
    else:
        # 默认 ID：优先用官方指南语义建议（Evt 随机 1XXXXXX / Talk 10位 / Option 9位）
        suggested = suggest_next_id(cfg_name, data)
        if suggested is not None:
            rid = str(suggested)
        else:
            nums = [int(k) for k in data.keys() if str(k).lstrip("-").isdigit()]
            rid = str((max(nums) + 1) if nums else 1)
            while rid in data:  # paranoia for mixed keys
                rid = str(int(rid) + 1)
    # base record from schema defaults
    rec = default_record(cfg_name, rid)
    # apply --value / --file overrides on top of defaults
    override = None
    if args.file:
        p = Path(args.file)
        if not p.is_file():
            err_console.print(f"[red]file not found: {p}[/]")
            raise SystemExit(1)
        try:
            override = json.loads(p.read_text(encoding="utf-8-sig"))
        except Exception as e:
            err_console.print(f"[red]json parse failed for {p}: {e}[/]")
            raise SystemExit(1)
    elif args.value is not None:
        try:
            override = json.loads(args.value)
        except Exception:
            try:
                override = json.loads(args.value.replace('\\"', '"'))
            except Exception as e:
                err_console.print(f"[red]--value is not valid JSON: {e}[/]")
                raise SystemExit(1)
    if override is not None:
        if not isinstance(override, dict):
            err_console.print("[red]override must be a JSON object[/]")
            raise SystemExit(1)
        rec.update(override)

    issues = validate_cfg(cfg_name, {rid: rec})
    has_error = any(lv == "error" for lv, _ in issues)
    if issues:
        for lv, msg in issues:
            col = "red" if lv == "error" else "yellow"
            err_console.print(f"[{col}]{lv}:[/] {escape(msg)}")
        if has_error and not args.force:
            err_console.print("[red]validation has errors, aborting (use --force to save anyway)[/]")
            raise SystemExit(1)

    data[rid] = rec
    save_cfg(mod_root, cfg_name, data)
    console.print(f"[green]added[/] {cfg_name}[{rid}] -> {path}")
    fields_view = load_schema().get(cfg_name, {})
    _render_record_view(cfg_name, rid, rec, fields_view, path)


def cmd_cfg_edit(args):
    mod_root = _require_mod(args)
    cfg_name = cfg_name_normalize(args.cfg)
    # --id variant: edit a single record via $EDITOR instead of the whole file
    rid = getattr(args, "id", None)
    if rid:
        data, path, exists = load_cfg(mod_root, cfg_name)
        if not exists or not isinstance(data, dict):
            data = {}
        is_new = not isinstance(data.get(str(rid)), dict)
        base = data.get(str(rid)) if not is_new else default_record(cfg_name, str(rid))
        console.print("[dim]新建记录, 已按 schema 填默认值[/]" if is_new else f"[dim]编辑已有记录 {cfg_name}[{rid}][/]")
        if getattr(args, "editor", False):
            parsed = _edit_json_via_editor(base)
        else:
            parsed = _edit_record_interactive(cfg_name, str(rid), base)
            if parsed is None:
                return
        issues = validate_cfg(cfg_name, {str(rid): parsed})
        has_error = any(lv == "error" for lv, _ in issues)
        if issues:
            for lv, msg in issues:
                col = "red" if lv == "error" else "yellow"
                err_console.print(f"[{col}]{lv}:[/] {escape(msg)}")
            if has_error and not args.force:
                err_console.print("[red]validation has errors, aborting (use --force to save anyway)[/]")
                raise SystemExit(1)
        data[str(rid)] = parsed
        save_cfg(mod_root, cfg_name, data)
        console.print(f"[green]saved[/] {cfg_name}[{rid}] -> {path}")
        return
    _, path, exists = load_cfg(mod_root, cfg_name)
    if not exists:
        # create empty
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("{}", encoding="utf-8")
    editor = _pick_editor()
    console.print(f"[dim]opening {path} with {editor} ...[/]")
    try:
        subprocess.run([editor, str(path)], check=False)
    except Exception as e:
        err_console.print(f"[red]failed to launch editor: {e}[/]")
        raise SystemExit(1)
    # validate after edit
    try:
        text = path.read_text(encoding="utf-8-sig").strip()
        if text:
            data = json.loads(text)
            issues = validate_cfg(cfg_name, data)
            if issues:
                console.print("[yellow]post-edit validation:[/]")
                for lv, msg in issues:
                    console.print(f"  [{lv}] {escape(msg)}")
    except Exception as e:
        err_console.print(f"[red]edited file is not valid JSON: {e}[/]")

def cmd_cfg_delete(args):
    mod_root = _require_mod(args)
    cfg_name = cfg_name_normalize(args.cfg)
    data, path, exists = load_cfg(mod_root, cfg_name)
    if not exists or not isinstance(data, dict):
        err_console.print(f"[red]cfg not found or empty: {cfg_name}[/]")
        raise SystemExit(1)
    rid = str(args.id)
    if rid not in data:
        err_console.print(f"[red]id not found: {rid}[/]")
        raise SystemExit(1)
    if not args.force:
        console.print(f"[yellow]will delete[/] {cfg_name}[{rid}]")
        console.print_json(json.dumps(data[rid], ensure_ascii=False, indent=2))
        ans = console.input("[bold red]type DELETE to confirm: [/]")
        if ans.strip() != "DELETE":
            console.print("[dim]cancelled[/]")
            return
    del data[rid]
    save_cfg(mod_root, cfg_name, data)
    console.print(f"[green]deleted[/] {cfg_name}[{rid}]  -> {path}")

def cmd_cfg_validate(args):
    mod_root = None
    try:
        mod_root = _require_mod(args)
    except SystemExit:
        # if no mod specified and args wants all, validate all mods? fallback to workspace
        ws = resolve_workspace(getattr(args, "workspace", None))
        mods = list_mods(ws)
        if not mods:
            err_console.print("[red]no mods found to validate[/]")
            raise SystemExit(1)
        # validate each
        overall_ok = True
        for m in mods:
            console.rule(f"Mod: {m['name']}")
            ok = _validate_one_mod(Path(m["root"]), args)
            overall_ok = overall_ok and ok
        if not overall_ok:
            raise SystemExit(2)
        return
    ok = _validate_one_mod(mod_root, args)
    if not ok:
        raise SystemExit(2)

def _validate_one_mod(mod_root: Path, args):
    cfg_dir = mod_root / "Cfgs" / "zh-cn"
    if not cfg_dir.is_dir():
        console.print(f"[yellow]no Cfgs at {cfg_dir}[/]")
        return True
    total_issues = 0
    t = Table(title=f"Validate {mod_root.name}")
    t.add_column("Cfg", style="cyan")
    t.add_column("Records", justify="right")
    t.add_column("Issues", justify="right")
    t.add_column("Status", style="bold")
    ok_all = True
    # 收集事件三表用于跨表引用校验（与循环内一致的加载方式）
    tables = {"EvtCfg": {}, "TalkCfg": {}, "OptionCfg": {}}
    for jf in sorted(cfg_dir.glob("*.json")):
        if jf.name == "CustomKeyMap.json":
            continue
        cname = jf.stem
        try:
            data = json.loads(jf.read_text(encoding="utf-8-sig") or "{}")
        except Exception as e:
            t.add_row(cname, "-", "1", "[red]JSON ERR[/]")
            err_console.print(f"[red]{cname}: json error: {e}[/]")
            ok_all = False
            total_issues += 1
            continue
        norm = cfg_name_normalize(cname)
        if norm in tables and isinstance(data, dict):
            tables[norm] = data
        issues = validate_cfg(cname, data) if isinstance(data, dict) else [("error", "root not dict")]
        errs = [m for lv, m in issues if lv == "error"]
        warns = [m for lv, m in issues if lv == "warn"]
        n = len(data) if isinstance(data, dict) else 0
        status = "[green]OK[/]" if not issues else f"[yellow]{len(warns)} warn[/]" if not errs else f"[red]{len(errs)} err[/]"
        if errs:
            ok_all = False
        t.add_row(cname, str(n), str(len(issues)), status)
        if args.verbose and issues:
            for lv, msg in issues[:20]:
                col = "red" if lv == "error" else "yellow"
                console.print(f"  [{col}]{cname}[/] {escape(msg)}")
        total_issues += len(issues)
    console.print(t)
    # 跨表引用校验（指南语义层：Evt/Talk/Option 之间的 ID 引用；CLI 无原版数据，base_ids=None）
    if any(tables.values()):
        cross_issues = []
        try:
            from editor.core.guide_rules import validate_cross as _validate_cross
            cross_issues = _validate_cross(tables)
        except Exception:
            cross_issues = []
        if cross_issues:
            ct = Table(title="跨表引用校验")
            ct.add_column("级别", style="bold", width=6)
            ct.add_column("问题", overflow="fold")
            for lv, msg in cross_issues:
                col = "red" if lv == "error" else ("yellow" if lv == "warn" else "dim")
                ct.add_row(f"[{col}]{lv}[/]", escape(msg))
            console.print(ct)
            total_issues += len(cross_issues)
            if any(lv == "error" for lv, _ in cross_issues):
                ok_all = False
        else:
            console.print("[green]跨表引用校验: OK (0 issues)[/]")
    if ok_all:
        console.print(f"[green]OK {mod_root.name}: {total_issues} issues (all warnings or clean)[/]")
    else:
        console.print(f"[red]FAIL {mod_root.name}: validation failed[/]")
    return ok_all

def cmd_schema(args):
    schema = load_schema()
    if args.cfg:
        cname = cfg_name_normalize(args.cfg)
        if cname not in schema:
            err_console.print(f"[red]unknown cfg: {cname}[/]  known: {', '.join(sorted(schema.keys())[:20])} ... ({len(schema)} total)")
            _print_cfg_hint(cname)
            raise SystemExit(1)
        fields = schema[cname]
        if _want_json(args):
            _json_out({cname: fields})
            return
        t = Table(title=f"Schema: {cname}")
        t.add_column("Field", style="cyan")
        t.add_column("Type", style="magenta")
        for k, typ in sorted(fields.items()):
            t.add_row(k, typ)
        console.print(t)
        return
    if _want_json(args):
        _json_out(schema)
        return
    t = Table(title=f"GAME_SCHEMA ({len(schema)} cfgs)")
    t.add_column("Cfg", style="bold cyan")
    t.add_column("Fields", style="dim")
    t.add_column("Field Types Preview", overflow="fold")
    for cname in sorted(schema.keys()):
        fields = schema[cname]
        preview = ", ".join(f"{k}:{v}" for k, v in list(fields.items())[:4])
        if len(fields) > 4:
            preview += f" +{len(fields)-4}"
        t.add_row(cname, str(len(fields)), preview)
    console.print(t)

def cmd_search(args):
    mod_root = None
    ws = resolve_workspace(getattr(args, "workspace", None))
    # if --mod given, search only that mod, else search all mods in workspace
    if getattr(args, "mod", None):
        mod_root = _require_mod(args)
        mods = [{"name": mod_root.name, "root": str(mod_root)}]
    else:
        mods = list_mods(ws)
        if not mods:
            err_console.print("[red]no mods found[/]")
            raise SystemExit(1)
    kw = args.keyword
    cfg_filter = getattr(args, "cfg", None)
    hits = []
    for m in mods:
        res = search_in_mod(m["root"], kw, cfg_filter)
        for r in res:
            r["mod"] = m["name"]
            hits.append(r)
    if _want_json(args):
        _json_out(hits)
        return
    if not hits:
        console.print(f"[yellow]no hits for {kw!r}[/]")
        return
    t = Table(title=f"Search: {kw!r}  ({len(hits)} hits)")
    t.add_column("Mod", style="dim")
    t.add_column("Cfg", style="cyan")
    t.add_column("ID", style="bold green")
    t.add_column("Snippet", overflow="fold", max_width=80)
    for h in hits[:200]:
        snip = escape(h["snippet"][:180])
        t.add_row(h["mod"], h["cfg"], h["id"], snip)
    console.print(t)
    if len(hits) > 200:
        console.print(f"[dim]showing 200 of {len(hits)} hits (use --json to get all)[/]")

def cmd_workspace(args):
    if args.sub == "show":
        ws = resolve_workspace(getattr(args, "workspace", None))
        console.print(f"[bold]workspace:[/] {ws}")
        console.print(f"editor_root: {editor_root()}")
        console.print(f"user_mods: {user_mods_dir()}")
        # show env file
        env_path = editor_root() / "editor_env.json"
        if env_path.exists():
            console.print(f"\n[bold]editor_env.json[/] @ {env_path}")
            console.print_json(env_path.read_text(encoding="utf-8-sig"))
        mods = list_mods(ws)
        console.print(f"\n[dim]{len(mods)} mods discovered[/]")
        return
    if args.sub == "set":
        new_ws = Path(args.path).expanduser().resolve()
        if not new_ws.is_dir():
            # try to create
            try:
                new_ws.mkdir(parents=True, exist_ok=True)
            except Exception as e:
                err_console.print(f"[red]cannot create workspace: {e}[/]")
                raise SystemExit(1)
        env_path = editor_root() / "editor_env.json"
        data = {}
        if env_path.exists():
            try:
                data = json.loads(env_path.read_text(encoding="utf-8-sig"))
            except Exception:
                data = {}
        data["workspace_root"] = str(new_ws)
        env_path.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
        console.print(f"[green]workspace set to[/] {new_ws}  -> {env_path}")
        return

def cmd_server(args):
    # launch backend server
    port = getattr(args, "port", 8765)
    console.print(f"[bold]starting server[/] @ 127.0.0.1:{port}  (Ctrl+C to stop)")
    # use same env as run_dev.py
    src = Path(__file__).resolve().parents[2]  # backend
    env = dict(os.environ)
    env["PYTHONPATH"] = str(src) + os.pathsep + env.get("PYTHONPATH", "")
    cmd = [sys.executable, "-m", "editor.server", "--port", str(port)]
    try:
        subprocess.run(cmd, cwd=str(src), env=env)
    except KeyboardInterrupt:
        console.print("\n[dim]server stopped[/]")

def cmd_doctor(args):
    console.rule("Doctor")
    checks = []
    def ok(msg): checks.append(("ok", msg))
    def warn(msg): checks.append(("warn", msg))
    def err(msg): checks.append(("err", msg))
    # python
    ok(f"python {sys.version.split()[0]} @ {sys.executable}")
    # rich/textual
    try:
        import rich
        ver = getattr(rich, "__version__", None) or getattr(rich, "VERSION", None) or "installed"
        try:
            import importlib.metadata as im
            ver = im.version("rich")
        except Exception:
            pass
        ok(f"rich {ver}")
    except Exception as e:
        err(f"rich missing: {e}")
    try:
        import textual
        ok(f"textual {textual.__version__}")
    except Exception:
        warn("textual not installed – TUI will use fallback (pip install textual)")
    # schema
    schema = load_schema()
    if schema:
        ok(f"GAME_SCHEMA {len(schema)} cfgs loaded")
    else:
        warn("GAME_SCHEMA empty or failed to load")
    # workspace
    ws = resolve_workspace(None)
    if ws.is_dir():
        ok(f"workspace {ws} exists")
    else:
        warn(f"workspace {ws} not found")
    # mods
    mods = list_mods(ws) if ws.is_dir() else []
    ok(f"mods discovered: {len(mods)}")
    # AI 助手配置（.editor_ai.json 三端共享）
    try:
        from editor.core.env_store import read_ai_settings, is_ai_settings_meaningful, ai_settings_path
        ai = read_ai_settings()
        if is_ai_settings_meaningful(ai):
            ok(f"AI 配置 {ai['provider']}/{ai['model'] or '-'} @ {ai_settings_path().name}")
        else:
            warn(f"AI 助手未配置 ({ai_settings_path().name} 缺失或无 apiKey) – 运行 python run_cli.py agent config")
    except Exception as e:
        warn(f"AI 配置读取失败: {e}")
    # 云同步 providers（.editor_cloud.json 三端共享）
    try:
        from editor.server import cloud_sync as _cs
        _prime_cloud_state()  # 配置路径依赖 STATE.workspace_root，先注入再读
        provs = _cs.list_providers()
        if provs:
            ok(f"云同步 providers: {len(provs)} ({', '.join(p['id'] for p in provs[:5])})")
        else:
            warn("云同步未配置网盘 – 运行 python run_cli.py cloud add")
    except Exception as e:
        warn(f"云同步模块加载失败: {e}")
    # config dir writable
    try:
        test = ws / ".doctor_write_test"
        test.write_text("ok", encoding="utf-8")
        test.unlink(missing_ok=True)
        ok("workspace writable")
    except Exception as e:
        err(f"workspace not writable: {e}")
    # print – use ASCII icons to avoid GBK encode errors on Windows
    for level, msg in checks:
        icon = {"ok": "[green][OK]", "warn": "[yellow][WARN]", "err": "[red][ERR]"}[level]
        console.print(f"{icon} {escape(msg)}[/]")
    has_err = any(lv == "err" for lv, _ in checks)
    if has_err:
        console.print("\n[red]doctor found errors - fix above before using CLI/TUI[/]")
        if not _want_json(args):
            raise SystemExit(1)
    else:
        console.print("\n[green]all checks passed[/]")

def cmd_update(args):
    """检查 GitHub 最新发行版（手动单次查询，不做后台轮询）。"""
    from editor.core.update_check import check_update

    result = check_update(timeout=6)
    if _want_json(args):
        _json_out(result)
        return
    if not result.get("ok"):
        err_console.print(f"[red]检查更新失败：{escape(str(result.get('error') or '未知错误'))}[/]")
        return

    current = str(result.get("current") or "-")
    latest = str(result.get("latest_tag") or "")
    console.rule("检查更新")
    console.print(f"当前版本：[bold]{escape(current)}[/]")
    if not latest:
        console.print("最新版本：[dim](仓库尚无发行版)[/]")
        return
    name = str(result.get("latest_name") or "")
    console.print(f"最新版本：[bold]{escape(latest)}[/]" + (f"  [dim]{escape(name)}[/]" if name else ""))
    if result.get("update_available"):
        console.print("[yellow]发现新版本，建议更新[/]")
    else:
        console.print("[green]已是最新[/]")
    if result.get("prerelease"):
        console.print("[dim]类型：预发行版 (prerelease)[/]")
    if result.get("published_at"):
        console.print(f"发布时间：{escape(str(result['published_at']))}")
    if result.get("html_url"):
        url = str(result["html_url"])
        console.print(f"发行页：[link={url}]{escape(url)}[/]")

    notes = str(result.get("notes") or "").strip()
    if notes:
        note_lines = notes.splitlines()
        body = "\n".join(note_lines[:15])
        if len(note_lines) > 15:
            body += "\n…（完整说明见发行页）"
        console.print(Panel(escape(body), title="更新说明", border_style="cyan"))

    assets = result.get("assets") or []
    if assets:
        t = Table(title=f"附件 ({len(assets)})", show_lines=False)
        t.add_column("名称", style="cyan", overflow="fold")
        t.add_column("大小", justify="right")
        t.add_column("下载地址", style="dim", overflow="fold")
        for it in assets:
            size = it.get("size") or 0
            t.add_row(str(it.get("name") or "-"), f"{size / (1024 * 1024):.1f} MB",
                      str(it.get("url") or "-"))
        console.print(t)

def cmd_tui(args):
    # lazy import
    try:
        from editor.tui.app import run as tui_run
    except Exception as e:
        err_console.print(f"[red]failed to load TUI: {e}[/]")
        # fallback hint
        err_console.print("try: pip install textual")
        raise SystemExit(1)
    kwargs = {}
    if getattr(args, "mod", None):
        kwargs["initial_mod"] = args.mod
    if getattr(args, "workspace", None):
        kwargs["workspace"] = args.workspace
    tui_run(**kwargs)

# ---------------------------------------------------------------------------
# AI Agent（agent config / agent chat）— 三端共享配置 .editor_ai.json
# ---------------------------------------------------------------------------

_SENSITIVE_KEY_RE = re.compile(r"password|token|secret|cookie|key", re.I)


def _mask_cfg_value(k: str, v) -> str:
    """云盘/网盘配置里的敏感字段打码（show/providers 列表用）。"""
    if v and _SENSITIVE_KEY_RE.search(k or ""):
        return "***"
    return "" if v is None else str(v)


def _mask_ai_settings(settings: dict) -> dict:
    out = dict(settings)
    if out.get("apiKey"):
        out["apiKey"] = "***"
    if out.get("imageApiKey"):
        out["imageApiKey"] = "***"
    if out.get("ttsApiKey"):
        out["ttsApiKey"] = "***"
    return out


def _print_ai_settings(settings: dict):
    t = Table(title=".editor_ai.json（GUI / CLI / TUI 三端共享）", show_header=False)
    t.add_column("字段", style="bold cyan")
    t.add_column("值")
    for k, v in _mask_ai_settings(settings).items():
        shown = str(v) if str(v) != "" else "[dim](空)[/]"
        t.add_row(k, escape(shown))
    console.print(t)


def _apply_agent_overrides(args, settings: dict) -> dict:
    """命令行覆盖项优先于共享配置文件（不改文件）。"""
    out = dict(settings)
    for flag, key in (("provider", "provider"), ("base_url", "baseUrl"),
                      ("api_key", "apiKey"), ("model", "model")):
        val = getattr(args, flag, None)
        if val:
            out[key] = val
    temp = getattr(args, "temperature", None)
    if temp is not None:
        out["temperature"] = temp
    return out


def _agent_ping(settings: dict) -> str:
    """连通性测试：发一条最小对话，返回模型回复文本。"""
    from editor.agent import LlmClient

    client = LlmClient(settings)
    chunks = []
    calls, text = client.round(
        [{"role": "user", "content": "连通性测试，请只回复：OK"}],
        [],
        "你是连通性测试探针，只回复 OK。",
        on_text=chunks.append,
    )
    return text or "".join(chunks)


def cmd_agent_config(args):
    from editor.core.env_store import (
        read_ai_settings, write_ai_settings, ai_settings_path, AI_PROVIDERS,
    )

    settings = read_ai_settings()
    if _want_json(args):
        _json_out(_mask_ai_settings(settings))
        return
    _print_ai_settings(settings)
    if not (sys.stdin.isatty() and sys.stdout.isatty()):
        console.print("[dim]非交互终端：仅显示配置。修改请在终端运行 python run_cli.py agent config[/]")
        return

    console.print("\n[bold]修改配置[/] [dim]（直接回车保留当前值）[/]")
    provider_labels = {
        "openai_compatible": "OpenAI Compatible（/chat/completions）",
        "openai_responses": "OpenAI Responses（/responses）",
        "anthropic": "Anthropic Compatible（/messages）",
    }
    cur = settings["provider"]
    console.print("  协议 provider：")
    for i, p in enumerate(AI_PROVIDERS, 1):
        mark = " [green](当前)[/]" if p == cur else ""
        console.print(f"    {i}. {p} — {provider_labels.get(p, p)}{mark}")
    raw = console.input(f"[cyan]选择 1-{len(AI_PROVIDERS)}[/] [dim]回车={cur}[/]: ").strip()
    patch = {}
    if raw:
        if raw in ("1", "2", "3"):
            patch["provider"] = AI_PROVIDERS[int(raw) - 1]
        elif raw in AI_PROVIDERS:
            patch["provider"] = raw
        else:
            err_console.print("[yellow]输入无效，保留原协议[/]")
    else:
        patch["provider"] = cur

    raw = console.input(f"baseUrl [dim]回车={settings['baseUrl'] or '空'}[/]: ").strip()
    if raw:
        patch["baseUrl"] = raw
    shown_key = "***" if settings["apiKey"] else "空"
    import getpass
    raw = getpass.getpass(f"apiKey [dim]回车={shown_key} 保留[/]: ").strip()
    if raw:
        patch["apiKey"] = raw
    raw = console.input(f"model [dim]回车={settings['model'] or '空'}[/]: ").strip()
    if raw:
        patch["model"] = raw
    raw = console.input(f"temperature [dim]回车={settings['temperature']}[/]: ").strip()
    if raw:
        try:
            patch["temperature"] = float(raw)
        except ValueError:
            err_console.print("[yellow]temperature 需为数字，保留原值[/]")
    raw = console.input(
        f"maxRetries [dim]回车={settings['maxRetries']}（自动重连次数，0=关闭）[/]: ").strip()
    if raw:
        try:
            patch["maxRetries"] = int(raw)
        except ValueError:
            err_console.print("[yellow]maxRetries 需为整数，保留原值[/]")
    raw = console.input(
        f"retryDelayMs [dim]回车={settings['retryDelayMs']}（重连首个退避间隔毫秒）[/]: ").strip()
    if raw:
        try:
            patch["retryDelayMs"] = int(raw)
        except ValueError:
            err_console.print("[yellow]retryDelayMs 需为整数，保留原值[/]")

    pm_cur = settings.get("permissionMode") or "confirm"
    raw = console.input(
        f"permissionMode [dim]回车={pm_cur}（1=confirm 变更前确认 / 2=full 完全访问，AI 直接修改不弹确认）[/]: ").strip().lower()
    if raw:
        if raw in ("1", "confirm"):
            patch["permissionMode"] = "confirm"
        elif raw in ("2", "full"):
            patch["permissionMode"] = "full"
        else:
            err_console.print("[yellow]permissionMode 需为 confirm 或 full，保留原值[/]")

    # 配音（TTS）可选配置：aliyun（DashScope 百炼）/ minimax（T2A V2）
    if console.input("\n配置配音(TTS)服务? [y/N]: ").strip().lower() in ("y", "yes"):
        tts_cur = settings.get("ttsProvider") or "空"
        raw = console.input(
            f"  ttsProvider [dim]回车={tts_cur}（aliyun / minimax）[/]: ").strip()
        if raw in ("aliyun", "minimax"):
            patch["ttsProvider"] = raw
        shown_tts = "***" if settings.get("ttsApiKey") else "空"
        raw = getpass.getpass(f"  ttsApiKey [dim]回车={shown_tts} 保留[/]: ").strip()
        if raw:
            patch["ttsApiKey"] = raw
        if (patch.get("ttsProvider") or settings.get("ttsProvider")) == "minimax":
            raw = console.input(
                f"  ttsGroupId [dim]回车={settings.get('ttsGroupId') or '空'}[/]: ").strip()
            if raw:
                patch["ttsGroupId"] = raw
        raw = console.input(
            f"  ttsBaseUrl [dim]回车={settings.get('ttsBaseUrl') or '空'}（留空官方默认）[/]: ").strip()
        if raw:
            patch["ttsBaseUrl"] = raw
        raw = console.input(
            f"  ttsModel [dim]回车={settings.get('ttsModel') or '空'}[/]: ").strip()
        if raw:
            patch["ttsModel"] = raw
        raw = console.input(
            f"  ttsVoice [dim]回车={settings.get('ttsVoice') or '空'}[/]: ").strip()
        if raw:
            patch["ttsVoice"] = raw
        raw = console.input(
            f"  ttsSpeed [dim]回车={settings.get('ttsSpeed') or 1.0}[/]: ").strip()
        if raw:
            try:
                patch["ttsSpeed"] = float(raw)
            except ValueError:
                err_console.print("[yellow]ttsSpeed 需为数字，保留原值[/]")

    if not patch or (set(patch) == {"provider"} and patch["provider"] == cur):
        console.print("[dim]未做修改[/]")
        return
    merged = write_ai_settings(patch)
    console.print(f"[green]已保存[/] -> {ai_settings_path()}")

    if merged.get("apiKey") and console.input("\n测试连通性? [y/N]: ").strip().lower() in ("y", "yes"):
        with console.status("连接中…"):
            try:
                reply = _agent_ping(merged)
                console.print(f"[green]连接成功[/]，模型回复：{escape((reply or '').strip()[:80] or '(空)')}")
            except Exception as e:
                err_console.print(f"[red]连接失败：{escape(str(e))}[/]")


def _cli_confirm_change(title: str, detail: str) -> bool:
    """写操作审批：展示 diff/内容面板 + y/N（与 GUI 审批框同一语义）。"""
    console.rule(f"[bold yellow]{escape(title)}")
    stripped = detail.strip()
    if stripped.startswith("{") or stripped.startswith("[") or '"+' in detail or '"-' in detail:
        from rich.syntax import Syntax
        body = Syntax(detail, "json", theme="ansi_dark", word_wrap=True)
    else:
        body = escape(detail)
    console.print(Panel(body, border_style="yellow"))
    ans = console.input("[bold green]允许本次修改? [y/N]: [/]").strip().lower()
    return ans in ("y", "yes")


def _cli_ask(question: str, options=None) -> str:
    """ask_user 回调：AI 主动向用户提问（面板 + 编号选项），阻塞等答案。

    与写操作审批（_cli_confirm_change）并列的交互，返回文本直接回填给模型；
    完全访问模式不跳过——提问永远要问。输入序号选选项，或直接输入自定义
    回答；空输入 / EOF（非交互管道）视为「用户未回答」。Ctrl+C 向上抛出，
    与聊天循环里既有的「已取消本轮请求」路径一致。
    """
    console.print(Panel(escape(question), title="AI 向你提问", border_style="cyan"))
    opts = [str(o).strip() for o in (options or []) if isinstance(o, str) and o.strip()][:6]
    if opts:
        for i, o in enumerate(opts, 1):
            console.print(f"  [bold cyan]{i}.[/] {escape(o)}")
        prompt = "[bold green]输入序号选择，或直接输入你的回答（回车=未回答）: [/]"
    else:
        prompt = "[bold green]输入你的回答（回车=未回答）: [/]"
    try:
        ans = console.input(prompt).strip()
    except EOFError:  # 非交互管道：无人应答
        return "用户未回答"
    if ans.isdigit() and 1 <= int(ans) <= len(opts):
        return opts[int(ans) - 1]
    return ans if ans else "用户未回答"


def _make_agent_hooks(mod_name: str):
    """agent chat 的流式打印 / 工具记录 / 审批回调。"""
    state = {"round_text": False}

    def on_text(delta):
        console.print(escape(delta), end="", markup=False, highlight=False)

    def on_tool_round_text(text):
        # 过渡文本已随流式打印；这里只负责换行进入工具区（空文本也要换行标记边界）
        if state["round_text"]:
            console.print()
        state["round_text"] = True

    def on_tool_result(name, result):
        first = (result or "").strip().splitlines()
        head = first[0] if first else ""
        style = "yellow" if name == "_loop_limit" else "dim"
        console.print(f"[{style}]  ⚙ {escape(name)} → {escape(head[:160])}[/]")

    def on_retry(attempt, total, reason):
        # 断流前已输出的半截文本会随重连重新生成，这里换行给出明确提示
        console.print(f"\n[yellow]⚠ 连接中断，正在自动重连 ({attempt}/{total})…[/]")

    def confirm(title, detail):
        return _cli_confirm_change(title, detail)

    return on_text, on_tool_round_text, on_tool_result, confirm, on_retry


def _print_history_transcript(title: str, history: list, max_lines: int, border: str = "cyan"):
    """恢复/查看会话时的文稿回显（超出 max_lines 只保留最近若干行）。"""
    from editor.agent import history_store

    transcript = history_store.render_transcript(history)
    lines = transcript.splitlines() if transcript else []
    if len(lines) > max_lines:
        lines = ["（较早 %d 行已省略，完整内容见会话文件）" % (len(lines) - max_lines)] + lines[-max_lines:]
    console.print(Panel("\n".join(lines) or "（空会话）", title=title, border_style=border))


def cmd_agent_chat(args):
    from editor.core.env_store import read_ai_settings, is_ai_settings_meaningful
    from editor.agent import LlmClient, LlmError, LlmCancelled, AgentTools, AgentEngine
    from editor.agent import history_store

    settings = _apply_agent_overrides(args, read_ai_settings())
    if not is_ai_settings_meaningful(settings):
        err_console.print("[red]AI 助手尚未配置 apiKey。[/]")
        err_console.print("先运行 [bold]python run_cli.py agent config[/]（或 REPL 内 [bold]/agent setting[/]）完成配置（GUI 设置页亦可，三端共享）。")
        raise SystemExit(1)
    if not settings.get("model"):
        err_console.print("[red]model 未配置，请在 agent config 或 --model 中提供。[/]")
        raise SystemExit(1)

    ws = resolve_workspace(getattr(args, "workspace", None))
    mod_root, mod_name = None, ""
    mod_flag = getattr(args, "mod", None)
    if mod_flag:
        info = find_mod(mod_flag, ws)
        if not info:
            err_console.print(f"[red]mod not found: {mod_flag}[/]  workspace={ws}")
            raise SystemExit(1)
        mod_root, mod_name = Path(info["root"]), info["name"]
    else:
        mods = list_mods(ws)
        if len(mods) == 1:  # 与 _require_mod 同一启发式：唯一模组自动选定
            mod_root, mod_name = Path(mods[0]["root"]), mods[0]["name"]
            console.print(f"[dim]自动选定唯一模组：{mod_name}（-m 可指定其他）[/]")

    tools = AgentTools()
    tools.use_mod(mod_root, ws)
    on_text, on_round, on_result, confirm, on_retry = _make_agent_hooks(mod_name)
    if settings.get("permissionMode") == "full":
        # 完全访问：写操作不再逐项审批（与 GUI 完全访问模式同一语义）
        console.print("[yellow]⚠ 完全访问模式：AI 的写操作将直接执行，不再逐项确认（/agent setting 可切回）。[/]")
        confirm = lambda title, detail: True  # noqa: E731
    engine = AgentEngine(
        tools,
        confirm=confirm,
        ask=_cli_ask,  # ask_user 提问：与写审批并列，完全访问模式也不跳过
        on_text=on_text,
        on_tool_round_text=on_round,
        on_tool_result=on_result,
        on_retry=on_retry,
        mod_context=(f"当前模组：{mod_name}。默认只修改这个模组，不要读取或修改其他模组的内容。"
                     if mod_name else ""),
    )
    client = LlmClient(settings)

    # ── 会话历史：默认记录到 .editor_ai_history（--no-history 关闭；--resume 续聊）──
    no_hist = getattr(args, "no_history", False)
    resume_ref = (getattr(args, "resume", None) or "").strip()
    if resume_ref and no_hist:
        console.print("[dim]已忽略 --resume（--no-history 生效）[/]")
    session = None
    if not no_hist:
        if resume_ref:
            session, err = history_store.resolve_session_ref(resume_ref)
            if err or session is None:
                err_console.print(f"[red]{escape(err or '会话不存在')}[/]")
                raise SystemExit(1)
            engine.history = history_store.to_openai_history(session.get("history") or [])
            session["source"] = session.get("source") or "cli"
        else:
            session = history_store.new_session(
                provider=settings["provider"], model=settings["model"] or "",
                mod=mod_name, source="cli")

    def _persist():
        if session is not None:
            try:
                session["history"] = list(engine.history)
                history_store.save_session(session)
            except Exception as e:
                err_console.print(f"[yellow]会话历史保存失败: {escape(str(e))}[/]")

    task = " ".join(getattr(args, "task", None) or []).strip()
    if task:
        try:
            engine.run(task, client)
            _persist()
        except (LlmError, LlmCancelled) as e:
            console.print()
            err_console.print(f"[red]{escape(str(e))}[/]")
            raise SystemExit(1)
        console.print("\n")
        # 交互终端：执行完首条任务后继续落入下方聊天循环（可接着对话）；
        # 非交互终端（管道/脚本）：保持旧版一次性执行后退出，便于脚本兼容。
        if not (sys.stdin.isatty() and sys.stdout.isatty()):
            return

    # 交互聊天子会话：多轮上下文保存在 engine.history（内存态），
    # 每轮结束后同步落盘到 .editor_ai_history（agent history 查看/恢复）
    if resume_ref:
        _print_history_transcript(
            f"已恢复会话 {session['id']} · {escape(session.get('title') or '(无标题)')}",
            engine.history, max_lines=60, border="dim")
    console.print(Panel(
        f"AI 助手聊天  [dim]（{escape(settings['provider'])} · {escape(settings['model'])}）[/]\n"
        + (f"当前模组：[bold green]{escape(mod_name)}[/]\n" if mod_name else "[yellow]未选定模组（只读查询仍可用 list_mods）[/]\n")
        + "[dim]写操作会先展示改动并等待 y/N 确认；输入 exit 或 Ctrl+D 退出[/]",
        border_style="cyan",
    ))
    while True:
        try:
            line = console.input("[bold cyan]❯ [/]").strip()
        except (EOFError, KeyboardInterrupt):
            console.print("\n[dim]再见[/]")
            return
        if not line:
            continue
        if line.lower() in ("exit", "quit", "/exit", "/quit", ":q"):
            console.print("[dim]再见[/]")
            return
        try:
            engine.run(line, client)
            _persist()
            console.print("\n")
        except KeyboardInterrupt:
            client.cancel()
            console.print("\n[yellow]已取消本轮请求[/]")
        except LlmCancelled:
            console.print("\n[yellow]已取消[/]")
        except LlmError as e:
            console.print()
            err_console.print(f"[red]{escape(str(e))}[/]")


def cmd_agent_history(args):
    """agent history list|show|resume|delete|clear — AI 会话历史管理。"""
    from editor.agent import history_store

    action = (getattr(args, "action", None) or "list").lower()
    if action == "list":
        sessions = history_store.list_sessions()
        if not sessions:
            console.print("[dim]暂无 AI 会话历史（agent chat / TUI 聊天面板自动记录）[/]")
            return
        t = Table(title=f"AI 会话历史（{len(sessions)}）· {history_store.sessions_dir()}")
        t.add_column("时间", style="cyan")
        t.add_column("来源", style="magenta", justify="center")
        t.add_column("模组", style="green", overflow="fold")
        t.add_column("消息", justify="right")
        t.add_column("标题", overflow="fold")
        t.add_column("id", style="dim")
        for s in sessions:
            t.add_row(
                str(s.get("updated_at") or "-"),
                str(s.get("source") or "-"),
                str(s.get("mod") or "-"),
                str(s.get("message_count") or 0),
                escape(str(s.get("title") or "(无标题)")),
                str(s.get("id")),
            )
        console.print(t)
        console.print("[dim]show / resume / delete 的会话 id 可用 last 代指最新一条；"
                      "resume 恢复后可接着对话[/]")
        return
    if action == "show":
        session, err = history_store.resolve_session_ref(getattr(args, "session_id", ""))
        if err or session is None:
            err_console.print(f"[red]{escape(err or '会话不存在')}[/]")
            return
        meta = "%s · %s · 模组 %s · %s 条消息" % (
            session.get("id"), session.get("provider") or "-",
            session.get("mod") or "-", session.get("message_count") or 0)
        _print_history_transcript(
            f"{escape(session.get('title') or '(无标题)')}  [dim]{escape(meta)}[/]",
            session.get("history") or [], max_lines=200)
        return
    if action == "resume":
        ns = argparse.Namespace(
            task=[], mod=None, provider=None, base_url=None, api_key=None,
            model=None, temperature=None, workspace=getattr(args, "workspace", None),
            resume=getattr(args, "session_id", ""), no_history=False)
        cmd_agent_chat(ns)
        return
    if action == "delete":
        session, err = history_store.resolve_session_ref(getattr(args, "session_id", ""))
        if err or session is None:
            err_console.print(f"[red]{escape(err or '会话不存在')}[/]")
            return
        if history_store.delete_session(session["id"]):
            console.print(f"[green]已删除[/] {session['id']} · {escape(session.get('title') or '(无标题)')}")
        else:
            err_console.print("[red]删除失败[/]")
        return
    if action == "clear":
        if not getattr(args, "yes", False):
            if not (sys.stdin.isatty() and sys.stdout.isatty()):
                err_console.print("[red]非交互终端请显式加 --yes[/]")
                raise SystemExit(1)
            if console.input("[yellow]确认清空全部 AI 会话历史? [y/N]: [/]").strip().lower() not in ("y", "yes"):
                console.print("[dim]已取消[/]")
                return
        n = history_store.clear_sessions()
        console.print(f"[green]已清空 {n} 个会话[/]")
        return
    console.print("[dim]history: list | show <id|last> | resume <id|last> | delete <id|last> | clear[/]")


# ---------------------------------------------------------------------------
# 云同步（cloud providers/add/test/remove/show/sync）— 复用 server.cloud_sync
# ---------------------------------------------------------------------------

_SYNC_ACTION_CN = {
    "upload_new": "上传(新增)", "upload_update": "上传(更新)",
    "download_new": "下载(新增)", "download_update": "下载(更新)",
    "sync_upload": "双向→上传", "sync_download": "双向→下载",
    "sync_upload_update": "双向→上传(新)", "sync_download_update": "双向→下载(新)",
    "delete_remote": "删除远端多余", "delete_local": "删除本地多余",
    "skip": "跳过(一致)", "skip_unchanged": "跳过(一致)",
    "skip_extra_remote": "跳过(远端多余)", "skip_local_extra": "跳过(本地多余)",
}


def _cloud(workspace=None):
    """取 cloud_sync 模块。注意：_cloud_config_path() 依赖 STATE.workspace_root
    （有值 → <workspace>/.editor_cloud.json，与 GUI 同一份；无值 → _cache 回退），
    因此任何读写前必须先注入工作区，否则会出现「写入 _cache、GUI 看不到」的分裂。
    """
    _prime_cloud_state(workspace)
    from editor.server import cloud_sync

    return cloud_sync


def _prime_cloud_state(workspace=None):
    """离线复用云同步引擎前，把 CLI 的工作区（editor_env.json 同源）注入 STATE，
    使 _get_mod_dir/_list_local_files 与 GUI/CLI 看到同一批模组。"""
    try:
        from editor.server.api import STATE

        if not STATE.workspace_root:
            STATE.workspace_root = str(resolve_workspace(workspace))
    except Exception:
        pass


def _provider_table(providers):
    t = Table(title="云同步 providers（.editor_cloud.json，三端共享）")
    t.add_column("id", style="cyan")
    t.add_column("name")
    t.add_column("type", style="green")
    t.add_column("remote_root")
    t.add_column("created_at", style="dim")
    for p in providers:
        t.add_row(str(p.get("id")), escape(str(p.get("name") or "")),
                  escape(str(p.get("type") or "")), escape(str(p.get("remote_root") or "")),
                  escape(str(p.get("created_at") or "")))
    console.print(t)


def cmd_cloud_providers(args):
    providers = _cloud(getattr(args, "workspace", None)).list_providers()
    if _want_json(args):
        masked = [{**p, "config": {k: _mask_cfg_value(k, v) for k, v in (p.get("config") or {}).items()}}
                  for p in providers]
        _json_out(masked)
        return
    if not providers:
        console.print("[yellow]尚未配置网盘。运行 [bold]python run_cli.py cloud add[/] 新增（GUI 云页亦可见同一份配置）。[/]")
        return
    _provider_table(providers)


def cmd_cloud_add(args):
    cs = _cloud(getattr(args, "workspace", None))
    driver_types = sorted({cls.type_name for cls in set(cs.DRIVERS.values())})
    info = {}
    itype = (args.type or "").strip().lower()
    if not itype:
        if not sys.stdin.isatty():
            err_console.print("非交互终端：请用 --type/--name/--remote-root/--cfg k=v 提供全部字段")
            raise SystemExit(1)
        console.print("可选驱动：")
        for i, dt in enumerate(driver_types, 1):
            console.print(f"  {i}. {dt}")
        raw = console.input(f"[cyan]选择 1-{len(driver_types)}[/]: ").strip()
        try:
            itype = driver_types[int(raw) - 1]
        except (ValueError, IndexError):
            err_console.print("[red]无效选择[/]")
            raise SystemExit(1)
    if itype not in cs.DRIVERS:
        sug = fuzzy_suggest(itype, driver_types)
        if sug:
            err_console.print(f"[yellow]did you mean:[/] [bold]{', '.join(sug)}[/]")
        err_console.print(f"[red]unknown driver type: {itype}[/]  可选: {', '.join(driver_types)}")
        raise SystemExit(1)
    info["type"] = itype

    schema = cs.get_driver(itype, {}).config_schema()
    cfg = {}
    for kv in args.cfg or []:
        if "=" not in kv:
            err_console.print(f"[red]--cfg 需为 k=v 形式: {kv}[/]")
            raise SystemExit(1)
        k, _, v = kv.partition("=")
        cfg[k.strip()] = v
    import getpass
    name = (args.name or "").strip()
    remote_root = (args.remote_root or "").strip()
    interactive = bool(schema) and sys.stdin.isatty()
    try:
        for field, desc in schema.items():
            if field in cfg:
                continue
            if not interactive:
                continue  # 非交互模式：缺失字段由下方统一校验报错
            secret = bool(_SENSITIVE_KEY_RE.search(field))
            if secret:
                val = getpass.getpass(f"{field} [dim]{desc}[/]: ")
            else:
                val = console.input(f"{field} [dim]{desc}[/]: ")
            if val:
                cfg[field] = val
        if interactive:
            name = name or console.input("显示名称 [dim]回车=默认[/]: ").strip()
            remote_root = remote_root or console.input("远端根目录 [dim]回车=mods[/]: ").strip() or "mods"
    except (EOFError, KeyboardInterrupt, OSError):
        err_console.print("\n[yellow]检测到非交互终端，无法问询。请用 --type/--name/--remote-root/--cfg k=v 提供全部字段[/]")
        raise SystemExit(1)
    missing = [f for f in schema if f not in cfg]
    if missing:
        err_console.print(f"[red]缺少配置字段: {', '.join(missing)}[/]  （用 --cfg k=v 提供）")
        raise SystemExit(1)
    info["config"] = cfg
    info["name"] = name or itype
    info["remote_root"] = remote_root or "mods"

    entry = cs.add_provider(info)
    console.print(f"[green]已保存[/] {entry['id']} ({entry['type']}) -> .editor_cloud.json")
    try:
        if console.input("立即测试连接? [Y/n]: ").strip().lower() not in ("n", "no"):
            _cloud_test_driver(entry)
    except (EOFError, KeyboardInterrupt, OSError):
        pass  # 非交互环境（管道/无 TTY）跳过问询


def _cloud_test_driver(entry) -> bool:
    with console.status(f"测试 {entry['id']} ({entry['type']}) …"):
        try:
            driver = _cloud().get_driver(entry["type"], entry.get("config") or {})
            driver.test()
        except Exception as e:
            err_console.print(f"[red]连接失败：{type(e).__name__}: {escape(str(e))}[/]")
            return False
    console.print(f"[green]连接成功[/] {entry['id']} -> {entry.get('remote_root')}")
    return True


def _resolve_cloud_provider(pid: str, workspace=None):
    entry = _cloud(workspace).get_provider(pid)
    if not entry:
        providers = _cloud(workspace).list_providers()
        err_console.print(f"[red]provider not found: {pid}[/]")
        if providers:
            sug = fuzzy_suggest(pid, [p["id"] for p in providers])
            if sug:
                err_console.print(f"[yellow]did you mean:[/] [bold]{', '.join(sug)}[/]")
            err_console.print("available: " + ", ".join(p["id"] for p in providers))
        raise SystemExit(1)
    return entry


def cmd_cloud_test(args):
    _cloud_test_driver(_resolve_cloud_provider(args.id, getattr(args, "workspace", None)))


def cmd_cloud_show(args):
    entry = _resolve_cloud_provider(args.id, getattr(args, "workspace", None))
    shown = dict(entry)
    if not args.reveal:
        shown["config"] = {k: _mask_cfg_value(k, v) for k, v in (entry.get("config") or {}).items()}
    if _want_json(args):
        _json_out(shown)
        return
    t = Table(show_header=False, title=f"provider {entry['id']}")
    t.add_column("字段", style="bold cyan")
    t.add_column("值")
    for k, v in shown.items():
        if k == "config":
            for ck, cv in v.items():
                t.add_row(f"config.{ck}", escape(str(cv)))
        else:
            t.add_row(k, escape(str(v)))
    console.print(t)


def cmd_cloud_remove(args):
    entry = _resolve_cloud_provider(args.id, getattr(args, "workspace", None))
    if not args.force:
        ans = console.input(
            f"[bold red]删除网盘配置 {entry['id']} ({entry.get('type')})? [y/N]: [/]").strip().lower()
        if ans not in ("y", "yes"):
            console.print("[dim]已取消[/]")
            return
    _cloud().remove_provider(entry["id"])
    console.print(f"[green]已删除[/] {entry['id']}（远端文件不受影响）")


def _render_sync_result(result):
    results = result.get("results") or []
    counts = {}
    errors = []
    for row in results:
        if row.get("ok"):
            counts[row.get("action", "?")] = counts.get(row.get("action", "?"), 0) + 1
        else:
            errors.append(row)
    dry = result.get("dry_run")
    head = "[yellow]DRY-RUN 预览（未写盘）[/] " if dry else ""
    console.print(f"\n{head}同步完成：{result.get('total', len(results))} 个文件")
    if counts:
        t = Table(show_header=False)
        t.add_column("动作", style="cyan")
        t.add_column("数量", justify="right")
        for action, n in sorted(counts.items(), key=lambda kv: -kv[1]):
            t.add_row(f"{_SYNC_ACTION_CN.get(action, action)} [dim]({action})[/]", str(n))
        console.print(t)
    if errors:
        t = Table(title=f"失败 {len(errors)} 项")
        t.add_column("文件", style="cyan")
        t.add_column("错误", style="red")
        for row in errors[:20]:
            t.add_row(escape(str(row.get("rel"))), escape(str(row.get("error"))))
        if len(errors) > 20:
            console.print(f"[dim]… 其余 {len(errors) - 20} 项失败已省略[/]")
        console.print(t)


def cmd_cloud_sync(args):
    from rich.progress import Progress, SpinnerColumn, BarColumn, TextColumn, TimeElapsedColumn
    import threading
    import time as _time

    cs = _cloud(getattr(args, "workspace", None))
    _resolve_cloud_provider(args.id, getattr(args, "workspace", None))  # 提前报错（含 did-you-mean）
    ws = resolve_workspace(getattr(args, "workspace", None))
    info = find_mod(args.mod, ws)
    if not info:
        err_console.print(f"[red]mod not found: {args.mod}[/]  workspace={ws}")
        mods = list_mods(ws)
        if mods:
            err_console.print("available: " + ", ".join(m["name"] for m in mods[:20]))
        raise SystemExit(1)

    kwargs = dict(provider_id=args.id, direction=args.direction, mod_name=args.mod,
                  dry_run=bool(args.dry_run), delete_extra=bool(args.delete_extra))
    runner = cs.sync_mod_folder
    files = (args.files or "").strip()
    if files:
        if args.direction == "sync":
            err_console.print("[red]--files 模式不支持 --direction sync（仅 upload/download）[/]")
            raise SystemExit(1)
        rels = [f.strip() for f in files.split(",") if f.strip()]
        if not rels:
            err_console.print("[red]--files 为空[/]")
            raise SystemExit(1)
        runner = cs.sync_mod_files
        kwargs = dict(provider_id=args.id, direction=args.direction, mod_name=args.mod,
                      rel_paths=rels, dry_run=bool(args.dry_run))

    box = {}
    def worker():
        try:
            box["result"] = runner(**kwargs)
        except BaseException as e:  # 线程内异常带回主线程展示
            box["error"] = e

    th = threading.Thread(target=worker, daemon=True)
    th.start()
    with Progress(SpinnerColumn(), TextColumn("[progress.description]{task.description}"),
                  BarColumn(), TextColumn("{task.fields[prog]}"), TimeElapsedColumn(),
                  console=console) as progress:
        task_id = progress.add_task(
            f"同步 {args.mod} [{'dry-run ' if args.dry_run else ''}{args.direction}] -> {args.id}",
            prog="0/0", total=None)
        while th.is_alive():
            st = cs.sync_status()
            total = st.get("total") or 0
            done = st.get("progress") or 0
            progress.update(task_id, total=total or None, completed=done,
                            prog=f"{done}/{total}", description=(
                                f"同步 {args.mod} [{'dry-run ' if args.dry_run else ''}{args.direction}]"
                                f" · {st.get('action') or ''} {st.get('last') or ''}".rstrip()))
            th.join(timeout=0.25)
    if "error" in box:
        if os.environ.get("EDITOR_CLI_DEBUG"):
            import traceback
            traceback.print_exception(type(box["error"]), box["error"], box["error"].__traceback__)
        err_console.print(f"[red]同步失败：{escape(str(box['error']))}[/]")
        raise SystemExit(1)
    _render_sync_result(box["result"])


# ---------------------------------------------------------------------------
# 配音（tts config/voices/test/synthesize/list/delete）— 复用 server.tts_service
# 与 server.tts_store；配置存 .editor_ai.json 的 tts* 字段（三端共享）。
# ---------------------------------------------------------------------------

_TTS_PROVIDERS = ("aliyun", "minimax")


def _tts_provider_and_settings(args) -> tuple[str, dict]:
    """解析 provider（命令行 > 设置 ttsProvider > aliyun）并应用 --model/--voice/--speed 覆盖（仅内存）。"""
    from editor.core.env_store import read_ai_settings

    settings = dict(read_ai_settings())
    provider = (getattr(args, "provider", None)
                or settings.get("ttsProvider") or "aliyun").strip().lower()
    if getattr(args, "model", None):
        settings["ttsModel"] = args.model
    if getattr(args, "voice", None):
        settings["ttsVoice"] = args.voice
    if getattr(args, "speed", None) is not None:
        settings["ttsSpeed"] = args.speed
    return provider, settings


def _print_tts_settings(settings: dict):
    t = Table(title="配音（TTS）配置（.editor_ai.json，GUI / CLI / TUI 三端共享）", show_header=False)
    t.add_column("字段", style="bold cyan")
    t.add_column("值")
    for k in sorted(k for k in settings if k.startswith("tts")):
        v = settings.get(k)
        if k == "ttsApiKey" and v:
            v = "***"
        shown = str(v) if str(v) != "" else "[dim](空)[/]"
        t.add_row(k, escape(shown))
    console.print(t)


def cmd_tts_config(args):
    from editor.core.env_store import read_ai_settings, write_ai_settings, ai_settings_path

    settings = read_ai_settings()
    if _want_json(args):
        _json_out(_mask_ai_settings(settings))
        return
    _print_tts_settings(settings)
    if not (sys.stdin.isatty() and sys.stdout.isatty()):
        console.print("[dim]非交互终端：仅显示配置。修改请在终端运行 python run_cli.py tts config[/]")
        return

    import getpass
    console.print("\n[bold]修改配音配置[/] [dim]（直接回车保留当前值）[/]")
    cur = settings.get("ttsProvider") or ""
    raw = console.input(
        f"ttsProvider [dim]回车={cur or '空'}（{' / '.join(_TTS_PROVIDERS)}）[/]: ").strip().lower()
    patch = {}
    if raw in _TTS_PROVIDERS:
        patch["ttsProvider"] = raw
    shown_key = "***" if settings.get("ttsApiKey") else "空"
    raw = getpass.getpass(f"ttsApiKey [dim]回车={shown_key} 保留[/]: ").strip()
    if raw:
        patch["ttsApiKey"] = raw
    if (patch.get("ttsProvider") or cur) == "minimax":
        raw = console.input(
            f"ttsGroupId [dim]回车={settings.get('ttsGroupId') or '空'}[/]: ").strip()
        if raw:
            patch["ttsGroupId"] = raw
    raw = console.input(
        f"ttsBaseUrl [dim]回车={settings.get('ttsBaseUrl') or '空'}（留空官方默认）[/]: ").strip()
    if raw:
        patch["ttsBaseUrl"] = raw
    raw = console.input(f"ttsModel [dim]回车={settings.get('ttsModel') or '空'}[/]: ").strip()
    if raw:
        patch["ttsModel"] = raw
    raw = console.input(f"ttsVoice [dim]回车={settings.get('ttsVoice') or '空'}[/]: ").strip()
    if raw:
        patch["ttsVoice"] = raw
    raw = console.input(f"ttsSpeed [dim]回车={settings.get('ttsSpeed') or 1.0}[/]: ").strip()
    if raw:
        try:
            patch["ttsSpeed"] = float(raw)
        except ValueError:
            err_console.print("[yellow]ttsSpeed 需为数字，保留原值[/]")

    if not patch:
        console.print("[dim]未做修改[/]")
        return
    write_ai_settings(patch)
    console.print(f"[green]已保存[/] -> {ai_settings_path()}")


def cmd_tts_voices(args):
    from editor.server.tts_service import list_voices, TtsError

    provider, settings = _tts_provider_and_settings(args)
    try:
        voices, source = list_voices(provider, settings)
    except TtsError as e:
        err_console.print(f"[red]{escape(str(e))}[/]")
        raise SystemExit(1)
    if _want_json(args):
        _json_out({"provider": provider, "source": source,
                   "count": len(voices), "voices": voices})
        return
    src_label = "在线拉取" if source == "live" else "内置音色表"
    t = Table(title=f"TTS 音色 — {provider}  ({len(voices)} 个, 来源: {src_label})")
    t.add_column("id", style="bold green")
    t.add_column("name", style="cyan", overflow="fold")
    t.add_column("gender", style="magenta", justify="center")
    t.add_column("desc", style="dim", overflow="fold")
    for v in voices:
        t.add_row(escape(str(v.get("id") or "")), escape(str(v.get("name") or "")),
                  escape(str(v.get("gender") or "")), escape(str(v.get("desc") or "")))
    console.print(t)
    if source == "preset":
        console.print("[dim]来源为内置音色表（兜底数据）。minimax 配置 apiKey+groupId 后可在线拉取完整音色。[/]")


def cmd_tts_test(args):
    from editor.server.tts_service import test_connection

    provider, settings = _tts_provider_and_settings(args)
    result = test_connection(provider, settings)
    if _want_json(args):
        _json_out({"provider": provider, **result})
        return
    if result.get("ok"):
        console.print(f"[green]连接成功[/] {provider} — {escape(str(result.get('detail') or ''))}")
    else:
        err_console.print(f"[red]连接失败[/] {provider} — {escape(str(result.get('error') or '未知错误'))}")
        raise SystemExit(1)


def _read_tts_text(args) -> str:
    """文本来源：位置参数 > --text/-t；'-' 从 stdin 读；皆空报错。"""
    pos = " ".join(getattr(args, "text", None) or []).strip()
    flag = (getattr(args, "text_flag", None) or "").strip()
    raw = pos or flag
    if not raw:
        err_console.print("[red]缺少配音文本[/]  用位置参数或 --text/-t 提供，传 '-' 从 stdin 读取")
        raise SystemExit(1)
    if raw == "-":
        raw = sys.stdin.read().strip()
        if not raw:
            err_console.print("[red]stdin 未提供文本[/]")
            raise SystemExit(1)
    return raw


def cmd_tts_synthesize(args):
    import time as _time
    from editor.server.tts_service import synthesize, TtsError
    from editor.server.tts_store import save_audio, register_audio_cfg, TtsStoreError

    text = _read_tts_text(args)
    provider, settings = _tts_provider_and_settings(args)
    voice = (getattr(args, "voice", None) or "").strip() or None
    params = {}
    if getattr(args, "speed", None) is not None:
        params["speed"] = args.speed
    mod_root = _require_mod(args)
    key = (getattr(args, "key", None) or "").strip() or ("tts_%d" % int(_time.time() * 1000))
    try:
        audio, ext = synthesize(provider, text, voice=voice, settings=settings, params=params)
        info = save_audio(mod_root, audio, ext, key=key, ogg=not args.raw_wav)
    except (TtsError, TtsStoreError) as e:
        err_console.print(f"[red]{escape(str(e))}[/]")
        raise SystemExit(1)
    # 登记 AudioCfg 失败不当作整体失败：文件已落盘，降级为警告
    # （与 /api/tts/save 的 200 + warning 行为一致，避免误报 + 孤儿素材）
    cfg_id = None
    if not args.no_cfg:
        try:
            cfg_id = register_audio_cfg(Path(mod_root) / "Cfgs" / "zh-cn",
                                        info["key"], title=text[:24])
        except TtsStoreError as e:
            err_console.print(f"[yellow]文件已保存，登记 AudioCfg 失败: {escape(str(e))}[/]")
    # 配音打通：--bind-talk <对白id> 时把 TalkCfg.audio 指向新登记的 AudioCfg id
    bind_talk = (getattr(args, "bind_talk", None) or "").strip()
    bound_talk = None
    if bind_talk:
        if cfg_id is None:
            err_console.print("[yellow]未登记 AudioCfg，跳过绑定（--no-cfg 时无法绑定）[/]")
        else:
            try:
                from editor.server.tts_store import bind_talk_audio
                bind_talk_audio(mod_root, bind_talk, cfg_id)
                bound_talk = bind_talk
            except TtsStoreError as e:
                err_console.print(f"[yellow]绑定失败: {escape(str(e))}[/]")
    result = {"provider": provider, "mod": Path(mod_root).name, "key": info["key"],
              "path": info["path"], "ext": info["ext"], "bytes": info["bytes"],
              "convertedOgg": info["convertedOgg"], "audioCfgId": cfg_id,
              "boundTalkId": bound_talk}
    if _want_json(args):
        _json_out(result)
        return
    status = "已转 Ogg" if info["convertedOgg"] else "wav 原样"
    console.print(f"[green]已保存[/] {escape(result['path'])}  ({info['bytes']} B, {status})")
    if cfg_id is not None:
        console.print(f"[green]已登记[/] AudioCfg id={cfg_id}")
    else:
        console.print("[dim]未登记 AudioCfg (--no-cfg)[/]")
    if bound_talk:
        console.print(f"[green]已绑定对白[/] {bound_talk} → AudioCfg #{cfg_id} (TalkCfg.audio)")
    if not info["convertedOgg"] and not args.raw_wav:
        console.print("[dim]未检测到 ffmpeg/oggenc，保持 wav 格式（游戏原生为 Ogg，安装后可重试）[/]")


def cmd_tts_list(args):
    from editor.server.tts_store import list_materials, TtsStoreError

    mod_root = _require_mod(args)
    try:
        items = list_materials(mod_root)
    except TtsStoreError as e:
        err_console.print(f"[red]{escape(str(e))}[/]")
        raise SystemExit(1)
    if _want_json(args):
        _json_out({"mod": Path(mod_root).name, "materials": items})
        return
    if not items:
        console.print(f"[yellow]无配音素材[/]  ({mod_root / 'audio' / 'tts'} 为空)")
        console.print("[dim]运行 python run_cli.py tts synthesize \"文本\" 合成第一条配音[/]")
        return
    t = Table(title=f"配音素材 @ {Path(mod_root).name}  ({len(items)} 个)")
    t.add_column("path", style="bold green", overflow="fold")
    t.add_column("size", justify="right")
    t.add_column("ext", style="cyan")
    for it in items:
        t.add_row(escape(str(it.get("path") or "")),
                  f"{it.get('size') or 0} B", escape(str(it.get("ext") or "")))
    console.print(t)


def cmd_tts_delete(args):
    from editor.server.tts_store import delete_material, TtsStoreError

    mod_root = _require_mod(args)
    rel = (args.path or "").strip().replace("\\", "/")
    if not rel:
        err_console.print("[red]缺少素材路径[/]  例: tts_1730000000.ogg 或 audio/tts/talk_intro.ogg")
        raise SystemExit(1)
    if not rel.startswith("audio/tts/"):
        rel = "audio/tts/" + rel.lstrip("/")
    if not args.force:
        console.print(f"[yellow]will delete:[/] {rel}")
        try:
            ans = console.input("[bold red]确认删除? [y/N]: [/]").strip().lower()
        except (EOFError, KeyboardInterrupt, OSError):
            ans = ""
        if ans not in ("y", "yes"):
            console.print("[dim]cancelled[/]")
            return
    try:
        deleted = delete_material(mod_root, rel)
    except TtsStoreError as e:
        err_console.print(f"[red]{escape(str(e))}[/]")
        raise SystemExit(1)
    if _want_json(args):
        _json_out({"deleted": deleted})
        return
    console.print(f"[green]deleted[/] {deleted}")


# ---------------------------------------------------------------------------
# 插件管理（plugin）— 复用 editor.core.plugin_system（离线模式）
# ---------------------------------------------------------------------------

def _plugin_system():
    from editor.core import plugin_system
    return plugin_system


def _ensure_plugins_loaded():
    """离线收集：加载全部已启用插件（不挂路由），供 list/info/命令注册表查询。"""
    ps = _plugin_system()
    try:
        ps.load_all(None)
    except Exception:
        pass
    return ps


def _plugin_by_id(ps, pid):
    """按 id 取详情；不存在打印可用列表并 SystemExit(1)。"""
    info = ps.get_plugin_info(pid)
    if info is None:
        err_console.print(f"[red]plugin not found: {pid}[/]")
        avail = [e["id"] for e in ps.list_plugins()]
        if avail:
            err_console.print("available: " + ", ".join(avail))
        raise SystemExit(1)
    return info


def cmd_plugin_list(args):
    ps = _ensure_plugins_loaded()
    entries = ps.list_plugins()
    if _want_json(args):
        _json_out({"plugins": entries})
        return
    if not entries:
        console.print("[yellow]no plugins installed[/]")
        console.print("[dim]install one with:  python run_cli.py plugin install <xxx.zip>[/]")
        return
    t = Table(title=f"Plugins ({len(entries)})")
    t.add_column("id", style="bold green")
    t.add_column("name", style="cyan")
    t.add_column("version", style="dim")
    t.add_column("author", style="dim")
    t.add_column("status", style="yellow")
    t.add_column("error", style="red", overflow="fold")
    for e in entries:
        status = "启用" if e["enabled"] else "停用"
        if e["enabled"]:
            status += " · " + ("已加载" if e["loaded"] else "加载失败")
        cell_err = escape(str(e["error"] or ""))[:80]
        t.add_row(escape(e["id"]), escape(e["name"] or "-"),
                  escape(e["version"] or "-"), escape(e["author"] or "-"),
                  status, cell_err)
    console.print(t)


def cmd_plugin_info(args):
    ps = _ensure_plugins_loaded()
    info = _plugin_by_id(ps, args.id)
    if _want_json(args):
        _json_out(info)
        return
    t = Table(show_header=False, title=f"plugin {info['id']}")
    t.add_column("字段", style="bold cyan")
    t.add_column("值", overflow="fold")
    for k in ("id", "name", "version", "author", "description", "entry"):
        t.add_row(k, escape(str(info.get(k) or "")))
    status = "启用" if info["enabled"] else "停用"
    status += " · " + ("已加载" if info["loaded"] else "未加载")
    t.add_row("status", status)
    t.add_row("risk_ack_at", escape(str(info.get("risk_ack_at") or "")))
    if info.get("error"):
        t.add_row("error", escape(str(info["error"])))
    console.print(t)
    contrib = info.get("contributions") or {}
    console.print("\n[bold]contributions[/]")
    for kind in ("routes", "tools", "commands", "panels"):
        items = contrib.get(kind) or []
        if items:
            for it in items:
                console.print(f"  [green]{kind}[/]  {escape(str(it))}")
        else:
            console.print(f"  [dim]{kind}: (none)[/]")


def cmd_plugin_install(args):
    _ensure_plugins_loaded()
    try:
        result = _plugin_system().install_plugin_from_path(args.path)
    except ValueError as e:
        err_console.print(f"[red]install failed:[/] {escape(str(e))}")
        raise SystemExit(1)
    pid = result["id"]
    console.print(f"[green]installed[/] {pid}  (默认停用，启用请运行 [bold]python run_cli.py plugin enable {pid}[/])")


def cmd_plugin_enable(args):
    ps = _ensure_plugins_loaded()
    info = _plugin_by_id(ps, args.id)
    if info["enabled"]:
        console.print(f"[dim]{args.id} 已是启用状态[/]")
        return
    # 插件元信息 + 红色高危警示块
    console.print(Panel.fit(
        f"[bold]{escape(info['name'])}[/]  [dim]{escape(info['id'])}[/]\n"
        f"version: {escape(info['version'] or '-')}   author: {escape(info['author'] or '-')}\n"
        f"{escape(info['description'] or '')}",
        title="插件信息", border_style="cyan"))
    console.print(Panel.fit(
        "[bold red]高危警示[/]\n"
        "该插件为第三方 Python 代码，启用后将以与编辑器相同的用户权限在本机运行，"
        "可读写文件、访问网络。请仅启用来自可信来源的插件。",
        border_style="red"))
    if not args.yes:
        try:
            ans = console.input("[bold green]确定启用该插件? [y/N]: [/]").strip().lower()
        except (EOFError, KeyboardInterrupt, OSError):
            ans = ""
        if ans not in ("y", "yes"):
            console.print(f"[dim]已取消 (未启用 {args.id})[/]")
            return
    try:
        entry = ps.set_enabled(args.id, True, risk_ack=True)
    except ValueError as e:
        err_console.print(f"[red]{escape(str(e))}[/]")
        raise SystemExit(1)
    detail = "已加载" if entry["loaded"] else f"加载失败: {entry['error']}"
    console.print(f"[green]已启用[/] {args.id}  ({detail})")


def cmd_plugin_disable(args):
    ps = _ensure_plugins_loaded()
    _plugin_by_id(ps, args.id)
    entry = ps.set_enabled(args.id, False)
    console.print(f"[green]已停用[/] {args.id}")


def cmd_plugin_uninstall(args):
    ps = _ensure_plugins_loaded()
    info = _plugin_by_id(ps, args.id)
    if info["enabled"]:
        err_console.print(f"[red]{args.id} 已启用，请先停用 (python run_cli.py plugin disable {args.id}) 再卸载[/]")
        raise SystemExit(1)
    if not args.yes:
        console.print(f"[yellow]将卸载插件:[/] [bold]{args.id}[/] ({escape(info['name'])} {escape(info['version'] or '')})")
        console.print("[yellow]将删除插件目录与数据，不可恢复[/]")
        try:
            ans = console.input("[bold red]确认卸载? [y/N]: [/]").strip().lower()
        except (EOFError, KeyboardInterrupt, OSError):
            ans = ""
        if ans not in ("y", "yes"):
            console.print("[dim]已取消[/]")
            return
    try:
        ps.uninstall_plugin(args.id)
    except ValueError as e:
        err_console.print(f"[red]{escape(str(e))}[/]")
        raise SystemExit(1)
    console.print(f"[green]已卸载[/] {args.id}")


def cmd_plugin_reload(args):
    ps = _ensure_plugins_loaded()
    entries = ps.reload_plugins(None)
    if _want_json(args):
        _json_out({"plugins": entries})
        return
    ok = [e for e in entries if e["enabled"] and e["loaded"]]
    failed = [e for e in entries if e["enabled"] and not e["loaded"] and e["error"]]
    console.print(f"[green]已重载[/] 启用 {len(ok)} · 失败 {len(failed)}")
    for e in failed:
        err_console.print(f"[red]  {e['id']}: {escape(e['error'][:80])}[/]")


def _plugin_command_fallback(parser, argv):
    """dispatch 末端：内置子命令未命中时查插件命令注册表（全名 <id>.<name>）。

    命名空间冲突顺序：现有子命令优先，插件命令兜底。命中返回 (fn, args_str)。
    """
    if not argv or argv[0].startswith("-"):
        return None
    first = argv[0]
    subs = None
    for act in parser._actions:
        if getattr(act, "dest", None) == "cmd" and getattr(act, "choices", None):
            subs = act
            break
    if subs is not None and first in subs.choices:
        return None  # 现有子命令优先
    try:
        from editor.core import plugin_system
        plugin_system.load_all(None)
        fn = plugin_system.plugin_command(first)
    except Exception:
        fn = None
    if fn is None:
        return None
    return fn, " ".join(argv[1:])


# ---------------------------------------------------------------------------
# Parser assembly
# ---------------------------------------------------------------------------

def build_parser() -> argparse.ArgumentParser:
    p = _Parser(
        prog="run_cli.py",
        description="学生时代 模组编辑器 – CLI (离线文件模式, 无需启动 server)",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "示例:\n"
            "  python run_cli.py mods list\n"
            "  python run_cli.py cfg list --mod MyMod\n"
            "  python run_cli.py cfg get EvtCfg --mod MyMod --id 1001\n"
            "  python run_cli.py cfg set EvtCfg --mod MyMod --id 999 --value '{\"title\":\"新事件\"}'\n"
            "  python run_cli.py search 关键词 --mod MyMod\n"
            "  python run_cli.py tui\n\n"
            "提示:\n"
            "  不带参数直接运行 → 进入交互式 REPL (Tab 补全 / @提及 / !shell)\n"
            "  --oobe           强制开启首次使用引导 (首次访问时自动弹出)\n"
        ),
    )
    p.add_argument("--workspace", default=None, help="workspace 根目录 (默认自动探测: editor_env.json / USERPROFILE/Mods)")
    p.add_argument("--json", dest="global_json", action="store_true", help="以 JSON 输出 (便于管道/脚本, 全局)")
    # p.add_argument("--no-color", action="store_true", help="禁用颜色")
    sub = p.add_subparsers(dest="cmd", required=True)

    # mods
    m = sub.add_parser("mods", help="模组管理")
    ms = m.add_subparsers(dest="sub", required=True)
    a = ms.add_parser("list", help="列出全部模组")
    a.add_argument("--json", action="store_true", help="JSON 输出")
    a.set_defaults(func=cmd_mods_list)
    a = ms.add_parser("create", help="创建新模组")
    a.add_argument("title", help="模组目录名/标题 (不能含 \\/:*?\"<>| )")
    a.add_argument("--desc", default="", help="描述")
    a.set_defaults(func=cmd_mods_create)
    a = ms.add_parser("delete", help="删除模组 (需二次确认)")
    a.add_argument("name", help="模组名")
    a.add_argument("--force", action="store_true", help="跳过确认直接删除")
    a.set_defaults(func=cmd_mods_delete)
    a = ms.add_parser("show", help="查看模组详情")
    a.add_argument("name", help="模组名")
    a.add_argument("--json", action="store_true", help="JSON 输出")
    a.set_defaults(func=cmd_mods_show)

    # cfg
    c = sub.add_parser("cfg", help="配置表 (Cfgs/zh-cn/*.json) CRUD")
    cs = c.add_subparsers(dest="sub", required=True)
    a = cs.add_parser("list", help="列出 cfg 文件")
    a.add_argument("--mod", default=None, help="模组名 (多模组时必填)")
    a.add_argument("--json", action="store_true", help="JSON 输出")
    a.set_defaults(func=cmd_cfg_list)
    a = cs.add_parser("get", help="读取 cfg / 记录 / 字段")
    a.add_argument("cfg", help="Cfg 名 (如 EvtCfg, PersonCfg; 大小写不敏感)")
    a.add_argument("--mod", default=None, help="模组名")
    a.add_argument("--id", default=None, help="记录 ID")
    a.add_argument("--key", default=None, help="字段名 (需配合 --id 或单独显示该字段列)")
    a.add_argument("--fields", default=None, help="表格视图显示的列 (逗号分隔, 如 title,type)")
    a.add_argument("--all", action="store_true", help="显示全部 (否则大表仅显示前若干行)")
    a.add_argument("--json", action="store_true", help="JSON 输出")
    a.set_defaults(func=cmd_cfg_get)
    a = cs.add_parser("set", help="写入 cfg / 记录 / 字段 (JSON)")
    a.add_argument("cfg", help="Cfg 名")
    a.add_argument("--mod", default=None, help="模组名")
    a.add_argument("--id", default=None, help="记录 ID")
    a.add_argument("--key", default=None, help="字段名 (需配合 --id)")
    a.add_argument("--value", default=None, help="JSON 值 (字符串请用 '\"text\"' 包裹)")
    a.add_argument("--file", default=None, help="从文件读取 JSON (优先级高于 --value)")
    a.add_argument("--editor", action="store_true", help="无值时改用外部 $EDITOR 编辑单条记录 (默认内置逐字段编辑器)")
    a.add_argument("--force", action="store_true", help="跳过校验强制写入")
    a.set_defaults(func=cmd_cfg_set)
    a = cs.add_parser("edit", help="编辑 cfg 文件或单条记录 (默认 CLI 内置编辑器)")
    a.add_argument("cfg", help="Cfg 名")
    a.add_argument("--mod", default=None, help="模组名")
    a.add_argument("--id", default=None, help="记录 ID (仅编辑该条, 新 id 会按 schema 建模板)")
    a.add_argument("--editor", action="store_true", help="用外部 $EDITOR 代替内置编辑器")
    a.add_argument("--force", action="store_true", help="跳过校验强制写入")
    a.set_defaults(func=cmd_cfg_edit)
    a = cs.add_parser("add", help="新建记录 (schema 默认值, ID 按指南建议)")
    a.add_argument("cfg", help="Cfg 名")
    a.add_argument("--mod", default=None, help="模组名")
    a.add_argument("--id", default=None, help="记录 ID (缺省为指南建议的下一个合规 ID)")
    a.add_argument("--value", default=None, help="JSON 覆盖默认值")
    a.add_argument("--file", default=None, help="从文件读取 JSON 覆盖默认值")
    a.add_argument("--force", action="store_true", help="跳过校验强制写入")
    a.set_defaults(func=cmd_cfg_add)
    a = cs.add_parser("delete", help="删除一条记录")
    a.add_argument("cfg", help="Cfg 名")
    a.add_argument("--mod", default=None, help="模组名")
    a.add_argument("--id", required=True, help="记录 ID")
    a.add_argument("--force", action="store_true", help="跳过确认")
    a.set_defaults(func=cmd_cfg_delete)
    a = cs.add_parser("validate", help="校验 cfg (schema + JSON)")
    a.add_argument("--mod", default=None, help="模组名 (不填则校验 workspace 下全部)")
    a.add_argument("--verbose", action="store_true", help="打印每条 warn/error")
    a.set_defaults(func=cmd_cfg_validate)
    # alias: cfg validate can be called as `cfg validate` or via top-level
    # also export/import as thin wrappers around get/set --file
    a = cs.add_parser("export", help="导出 cfg 到文件")
    a.add_argument("cfg", help="Cfg 名")
    a.add_argument("--mod", default=None)
    a.add_argument("--out", required=True, help="输出路径")
    a.set_defaults(func=lambda args: _cfg_export(args))
    a = cs.add_parser("import", help="从文件导入 cfg (覆盖)")
    a.add_argument("cfg", help="Cfg 名")
    a.add_argument("--mod", default=None)
    a.add_argument("--in", dest="in_path", required=True, help="输入路径")
    a.add_argument("--force", action="store_true")
    a.set_defaults(func=lambda args: _cfg_import(args))

    # schema
    s = sub.add_parser("schema", help="查看 GAME_SCHEMA")
    s.add_argument("cfg", nargs="?", default=None, help="Cfg 名 (不填列出全部)")
    s.add_argument("--json", action="store_true", help="JSON 输出")
    s.set_defaults(func=cmd_schema)
    # search
    sr = sub.add_parser("search", help="跨 cfg 全文搜索")
    sr.add_argument("keyword", help="关键词 (大小写不敏感)")
    sr.add_argument("--mod", default=None, help="限定模组")
    sr.add_argument("--cfg", default=None, help="限定 cfg")
    sr.add_argument("--json", action="store_true", help="JSON 输出")
    sr.set_defaults(func=cmd_search)

    # workspace
    w = sub.add_parser("workspace", help="工作区管理")
    ws = w.add_subparsers(dest="sub", required=True)
    a = ws.add_parser("show", help="显示当前 workspace")
    a.set_defaults(func=cmd_workspace)
    a = ws.add_parser("set", help="设置 workspace (写入 editor_env.json)")
    a.add_argument("path", help="新 workspace 路径")
    a.set_defaults(func=cmd_workspace)

    # server
    sv = sub.add_parser("server", help="启动 HTTP 后端 (供 Flutter/GUI 使用)")
    svs = sv.add_subparsers(dest="sub", required=True)
    a = svs.add_parser("start", help="启动 server")
    a.add_argument("--port", type=int, default=8765)
    a.set_defaults(func=cmd_server)

    # doctor
    d = sub.add_parser("doctor", help="环境自检")
    d.set_defaults(func=cmd_doctor)

    # update
    u = sub.add_parser("update", help="检查 GitHub 最新发行版")
    u.add_argument("--json", action="store_true", help="JSON 输出")
    u.set_defaults(func=cmd_update)

    # tui
    t = sub.add_parser("tui", help="启动 TUI 交互编辑器 (textual)")
    t.add_argument("--mod", default=None, help="初始模组")
    t.set_defaults(func=cmd_tui)

    # agent
    ag = sub.add_parser("agent", help="AI 助手 (.editor_ai.json 三端共享)")
    ags = ag.add_subparsers(dest="sub", required=True)
    a = ags.add_parser("config", help="查看/交互式修改 AI 服务配置")
    a.add_argument("--json", action="store_true", help="JSON 输出 (掩码)")
    a.set_defaults(func=cmd_agent_config)
    a = ags.add_parser("setting", help="查看/交互式修改 AI 服务配置（config 的别名）")
    a.add_argument("--json", action="store_true", help="JSON 输出 (掩码)")
    a.set_defaults(func=cmd_agent_config)
    a = ags.add_parser("chat", help="AI 助手：带任务参数=先执行任务再进入聊天（非交互终端执行完退出），省略=进入聊天")
    a.add_argument("task", nargs="*", help="任务描述（交互终端：先执行再继续对话；非交互：执行完退出）")
    a.add_argument("-m", "--mod", default=None, help="限定模组 (唯一模组时自动选定)")
    a.add_argument("--provider", default=None,
                   choices=["openai_compatible", "openai_responses", "anthropic"])
    a.add_argument("--base-url", dest="base_url", default=None, help="覆盖 baseUrl")
    a.add_argument("--api-key", dest="api_key", default=None, help="覆盖 apiKey")
    a.add_argument("--model", default=None, help="覆盖 model")
    a.add_argument("--temperature", type=float, default=None, help="覆盖 temperature")
    a.add_argument("--resume", default=None, metavar="ID|last",
                   help="恢复历史会话继续对话（id 或 last，agent history list 查看）")
    a.add_argument("--no-history", dest="no_history", action="store_true",
                   help="本次会话不写入 AI 历史（默认自动记录）")
    a.set_defaults(func=cmd_agent_chat)
    a = ags.add_parser("history", help="AI 会话历史：list / show / resume / delete / clear")
    hs = a.add_subparsers(dest="action")
    h = hs.add_parser("list", help="列出会话（省略子命令时同效）")
    h.set_defaults(action="list")
    h = hs.add_parser("show", help="查看某次会话内容")
    h.add_argument("session_id", metavar="ID|last", help="会话 id 或 last")
    h = hs.add_parser("resume", help="恢复会话并继续对话（等价 agent chat --resume）")
    h.add_argument("session_id", metavar="ID|last", help="会话 id 或 last")
    h = hs.add_parser("delete", help="删除一个会话")
    h.add_argument("session_id", metavar="ID|last", help="会话 id 或 last")
    h = hs.add_parser("clear", help="清空全部会话（交互确认，-y 跳过）")
    h.add_argument("-y", "--yes", action="store_true", help="跳过确认")
    a.set_defaults(func=cmd_agent_history)

    # cloud
    cl = sub.add_parser("cloud", help="云同步 (.editor_cloud.json 三端共享)")
    cls_ = cl.add_subparsers(dest="sub", required=True)
    a = cls_.add_parser("providers", help="列出已配置网盘")
    a.add_argument("--json", action="store_true", help="JSON 输出 (掩码)")
    a.set_defaults(func=cmd_cloud_providers)
    a = cls_.add_parser("add", help="新增网盘配置 (交互问询或 --cfg k=v)")
    a.add_argument("--type", default=None, help="驱动类型 (省略则交互选择)")
    a.add_argument("--name", default=None, help="显示名称")
    a.add_argument("--remote-root", dest="remote_root", default=None, help="远端根目录 (默认 mods)")
    a.add_argument("--cfg", action="append", default=[], metavar="K=V",
                   help="驱动配置字段，可重复 (如 --cfg url=https://… --cfg password=…)")
    a.set_defaults(func=cmd_cloud_add)
    a = cls_.add_parser("test", help="测试网盘连接")
    a.add_argument("id", help="provider id (cloud providers 查看)")
    a.set_defaults(func=cmd_cloud_test)
    a = cls_.add_parser("show", help="查看网盘配置详情")
    a.add_argument("id", help="provider id")
    a.add_argument("--reveal", action="store_true", help="显示敏感字段明文")
    a.add_argument("--json", action="store_true", help="JSON 输出")
    a.set_defaults(func=cmd_cloud_show)
    a = cls_.add_parser("remove", help="删除网盘配置 (远端文件不受影响)")
    a.add_argument("id", help="provider id")
    a.add_argument("--force", action="store_true", help="跳过确认")
    a.set_defaults(func=cmd_cloud_remove)
    a = cls_.add_parser("sync", help="同步 Mod 文件夹到网盘")
    a.add_argument("id", help="provider id")
    a.add_argument("--mod", required=True, help="模组名")
    a.add_argument("--direction", default="upload", choices=["upload", "download", "sync"],
                   help="upload=本地→远端, download=远端→本地, sync=双向 (默认 upload)")
    a.add_argument("--dry-run", dest="dry_run", action="store_true", help="只预览不写盘")
    a.add_argument("--delete-extra", dest="delete_extra", action="store_true",
                   help="删除远端多余文件 (upload/download 时有效)")
    a.add_argument("--files", default=None, help="仅同步指定相对路径 (逗号分隔)")
    a.set_defaults(func=cmd_cloud_sync)

    # tts（配音）
    tt = sub.add_parser("tts", help="配音 TTS（配置/音色/合成/素材管理，配置三端共享）")
    tts = tt.add_subparsers(dest="sub", required=True)
    a = tts.add_parser("config", help="查看/交互式配置配音服务 (provider/apiKey/groupId/model/voice/speed)")
    a.add_argument("--json", action="store_true", help="JSON 输出 (打码 ttsApiKey)")
    a.set_defaults(func=cmd_tts_config)
    a = tts.add_parser("voices", help="列出音色 (缺省取设置 ttsProvider, 再缺省 aliyun)")
    a.add_argument("provider", nargs="?", default=None, choices=list(_TTS_PROVIDERS),
                   help="配音服务商")
    a.add_argument("--model", default=None, help="aliyun 时按模型切换内置音色表 (qwen-tts/cosyvoice)")
    a.add_argument("--json", action="store_true", help="JSON 输出")
    a.set_defaults(func=cmd_tts_voices)
    a = tts.add_parser("test", help="配音服务连通性测试 (aliyun 会真实合成一句短文本)")
    a.add_argument("provider", nargs="?", default=None, choices=list(_TTS_PROVIDERS),
                   help="配音服务商 (缺省取设置 ttsProvider, 再缺省 aliyun)")
    a.add_argument("--model", default=None, help="覆盖合成模型")
    a.add_argument("--voice", default=None, help="覆盖音色")
    a.add_argument("--speed", type=float, default=None, help="覆盖语速 0.5–2.0")
    a.add_argument("--json", action="store_true", help="JSON 输出")
    a.set_defaults(func=cmd_tts_test)
    a = tts.add_parser("synthesize", help="合成语音并保存到模组 audio/tts/ (默认登记 AudioCfg + 转 Ogg)")
    a.add_argument("text", nargs="*", help="配音文本 ('-' 从 stdin 读取)")
    a.add_argument("-t", "--text", dest="text_flag", default=None,
                   help="配音文本 (长文本/含特殊字符时用)")
    a.add_argument("--mod", default=None, help="模组名 (多模组时必填)")
    a.add_argument("--provider", default=None, choices=list(_TTS_PROVIDERS),
                   help="配音服务商 (覆盖设置)")
    a.add_argument("--voice", default=None, help="音色 id (tts voices 查看)")
    a.add_argument("--model", default=None, help="覆盖合成模型")
    a.add_argument("--speed", type=float, default=None, help="语速 0.5–2.0")
    a.add_argument("--key", default=None,
                   help="素材键名 (缺省 tts_<时间戳>; 建议自行命名如 talk_xxx)")
    a.add_argument("--no-cfg", dest="no_cfg", action="store_true", help="不登记 AudioCfg")
    a.add_argument("--bind-talk", dest="bind_talk", default=None,
                   help="绑定对白 id（配音打通：写回 TalkCfg.audio 指向该 AudioCfg）")
    a.add_argument("--raw-wav", dest="raw_wav", action="store_true",
                   help="跳过 Ogg 自动转码 (保留 wav)")
    a.add_argument("--json", action="store_true", help="JSON 输出")
    a.set_defaults(func=cmd_tts_synthesize)
    a = tts.add_parser("list", help="列出模组 audio/tts/ 配音素材")
    a.add_argument("--mod", default=None, help="模组名 (多模组时必填)")
    a.add_argument("--json", action="store_true", help="JSON 输出")
    a.set_defaults(func=cmd_tts_list)
    a = tts.add_parser("delete", help="删除配音素材 (audio/tts/ 内, 需 y/N 确认)")
    a.add_argument("path", help="素材文件名或相对路径 (如 tts_1730000000.ogg)")
    a.add_argument("--mod", default=None, help="模组名 (多模组时必填)")
    a.add_argument("--force", action="store_true", help="跳过确认")
    a.add_argument("--json", action="store_true", help="JSON 输出")
    a.set_defaults(func=cmd_tts_delete)

    # plugin（第三方插件管理）
    pl = sub.add_parser("plugin", help="插件管理 (第三方 Python 插件，高危确认后启用)")
    pls = pl.add_subparsers(dest="sub", required=True)
    a = pls.add_parser("list", help="列出全部插件")
    a.add_argument("--json", action="store_true", help="JSON 输出")
    a.set_defaults(func=cmd_plugin_list)
    a = pls.add_parser("info", help="查看插件详情 (manifest 全字段 + contributions)")
    a.add_argument("id", help="插件 id")
    a.add_argument("--json", action="store_true", help="JSON 输出")
    a.set_defaults(func=cmd_plugin_info)
    a = pls.add_parser("install", help="从本地 zip 安装插件 (默认停用)")
    a.add_argument("path", help="插件 zip 路径")
    a.set_defaults(func=cmd_plugin_install)
    a = pls.add_parser("enable", help="启用插件 (先展示高危警示, y/N 确认)")
    a.add_argument("id", help="插件 id")
    a.add_argument("-y", "--yes", action="store_true", help="跳过高危确认 (脚本场景)")
    a.set_defaults(func=cmd_plugin_enable)
    a = pls.add_parser("disable", help="停用插件")
    a.add_argument("id", help="插件 id")
    a.set_defaults(func=cmd_plugin_disable)
    a = pls.add_parser("uninstall", help="卸载插件 (需先停用 + 二次确认)")
    a.add_argument("id", help="插件 id")
    a.add_argument("-y", "--yes", action="store_true", help="跳过确认直接卸载")
    a.set_defaults(func=cmd_plugin_uninstall)
    a = pls.add_parser("reload", help="重新加载全部已启用插件")
    a.add_argument("--json", action="store_true", help="JSON 输出")
    a.set_defaults(func=cmd_plugin_reload)

    # also allow `cfg validate` without sub nesting as top-level alias for convenience
    # (handled via cfg subparser already)

    return p

def _cfg_export(args):
    mod_root = _require_mod(args)
    cfg_name = cfg_name_normalize(args.cfg)
    data, _, _ = load_cfg(mod_root, cfg_name)
    if data is None:
        err_console.print(f"[red]cfg not found: {cfg_name}[/]")
        raise SystemExit(1)
    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
    console.print(f"[green]exported[/] {cfg_name} ({len(data)} records) -> {out}")

def _cfg_import(args):
    mod_root = _require_mod(args)
    cfg_name = cfg_name_normalize(args.cfg)
    inp = Path(args.in_path)
    if not inp.is_file():
        err_console.print(f"[red]input not found: {inp}[/]")
        raise SystemExit(1)
    try:
        data = json.loads(inp.read_text(encoding="utf-8-sig"))
    except Exception as e:
        err_console.print(f"[red]json error: {e}[/]")
        raise SystemExit(1)
    if not isinstance(data, dict):
        err_console.print("[red]imported file must be JSON object (dict)[/]")
        raise SystemExit(1)
    issues = validate_cfg(cfg_name, data)
    if issues and not args.force:
        for lv, msg in issues:
            col = "red" if lv == "error" else "yellow"
            err_console.print(f"[{col}]{lv}:[/] {escape(msg)}")
        if any(lv == "error" for lv, _ in issues):
            err_console.print("[red]abort (use --force to import anyway)[/]")
            raise SystemExit(1)
    save_cfg(mod_root, cfg_name, data)
    console.print(f"[green]imported[/] {cfg_name} ({len(data)} records) <- {inp}")

def _global_only_argv(argv) -> bool:
    """True when argv contains nothing but global flags (+their values)."""
    skip = False
    for a in argv:
        if skip:
            skip = False
            continue
        if a == "--workspace":
            skip = True
            continue
        if a.startswith("--workspace=") or a in ("--json", "--interactive", "-i"):
            continue
        return False
    return True


def maybe_oobe(argv: list) -> list:
    """--oobe 处理 + 首次运行自动引导；返回剥离 --oobe 后的 argv。

    - `--oobe`（任意位置）：强制运行一次 OOBE 向导，然后继续正常流程
    - 首次访问且处于交互 TTY 时自动引导；管道 / --json / EDITOR_NO_OOBE=1 时静默跳过
    """
    from .oobe import run_cli_wizard, should_run, autostart_allowed

    force = "--oobe" in argv
    rest = [a for a in argv if a != "--oobe"]
    if not (force or autostart_allowed()):
        return rest
    try:
        completed = run_cli_wizard()
    except Exception as e:  # 向导任何异常都不阻塞后续命令
        err_console.print(f"[dim]OOBE skipped ({e})[/]")
        return rest
    if not completed and not force and not should_run(False):
        pass  # aborted; next invocation will retry
    return rest


def main(argv=None):
    # 无参 / 仅全局参数 → REPL (Claude Code 风格)
    if argv is None:
        argv = sys.argv[1:]
    else:
        argv = list(argv)
    argv = maybe_oobe(argv)
    if not argv or "--interactive" in argv or "-i" in argv or _global_only_argv(argv):
        try:
            from .interactive import run_interactive
        except Exception as e:
            err_console.print(f"[red]无法启动交互式: {e}[/]")
            raise SystemExit(1)
        # 透传 workspace
        ws = None
        if "--workspace" in argv:
            try:
                ws = argv[argv.index("--workspace")+1]
            except Exception:
                pass
        run_interactive(workspace=ws)
        return 0
    parser = build_parser()
    # allow --interactive as subcommand alias
    if "--interactive" in argv:
        argv = [a for a in argv if a != "--interactive"]
        if not argv:
            from .interactive import run_interactive
            run_interactive()
            return 0
    # 插件命令兜底：内置子命令未命中时查插件命令注册表（全名 <id>.<name>）
    fallback = _plugin_command_fallback(parser, argv)
    if fallback is not None:
        fn, rest = fallback
        try:
            fn(rest)
        except Exception as e:
            err_console.print(f"[red]error:[/] {escape(str(e))}")
            import traceback
            if os.environ.get("EDITOR_CLI_DEBUG"):
                traceback.print_exc()
            raise SystemExit(1)
        return 0
    args = parser.parse_args(argv)
    # global --json handling is per-command; ensure func exists
    func = getattr(args, "func", None)
    if func is None:
        parser.print_help()
        raise SystemExit(1)
    try:
        func(args)
    except KeyboardInterrupt:
        err_console.print("\n[dim]interrupted[/]")
        raise SystemExit(130)
    except SystemExit:
        raise
    except Exception as e:
        err_console.print(f"[red]error:[/] {escape(str(e))}")
        import traceback
        if os.environ.get("EDITOR_CLI_DEBUG"):
            traceback.print_exc()
        raise SystemExit(1)

if __name__ == "__main__":
    main()
