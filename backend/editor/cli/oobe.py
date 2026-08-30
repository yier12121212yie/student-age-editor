# -*- coding: utf-8 -*-
"""OOBE（Out-Of-Box Experience）首次运行向导 — CLI / TUI / GUI 三端共享状态层。

「第一次访问」判定：编辑器根目录下 editor_env.json 是否含
"oobe_completed": true 标记。三端共用同一标记，任一端完成引导后其余端不再自动弹出。

开启方式：
  自动   首次访问时各端开启一次（CLI 仅在交互终端触发，管道/CI 静默跳过）
  强制   CLI/TUI: 命令行加 --oobe
         GUI:     StudentAgeEditor.exe --oobe（Windows runner 会注入 EDITOR_OOBE=1）
                  或直接设置环境变量 EDITOR_OOBE=1
  禁用   环境变量 EDITOR_NO_OOBE=1（--oobe 显式指定时仍会开启）
"""

import datetime
import json
import os
import re
import sys
from pathlib import Path

ENV_KEY = "oobe_completed"
FORCE_ENV = "EDITOR_OOBE"
DISABLE_ENV = "EDITOR_NO_OOBE"

_TITLE_RE = re.compile(r'[\\/:*?"<>|\x00-\x1f]')


# ---------------------------------------------------------------------------
# 状态存取（editor_env.json）
# ---------------------------------------------------------------------------

def env_path() -> Path:
    from .utils import editor_root
    return editor_root() / "editor_env.json"


def read_env() -> dict:
    p = env_path()
    if not p.is_file():
        return {}
    try:
        data = json.loads(p.read_text(encoding="utf-8-sig"))
        return data if isinstance(data, dict) else {}
    except Exception:
        return {}


def is_done() -> bool:
    return bool(read_env().get(ENV_KEY))


def forced_by_env() -> bool:
    raw = os.environ.get(FORCE_ENV, "")
    if os.environ.get(DISABLE_ENV, "") and raw == "":
        return False
    return raw.strip().lower() in ("1", "true", "yes", "on")


def should_run(force: bool = False) -> bool:
    """是否应显示 OOBE。force（--oobe）为最高优先级。"""
    if force:
        return True
    if os.environ.get(DISABLE_ENV, "").strip().lower() in ("1", "true", "yes", "on"):
        return False
    return not is_done()


def mark_done(extra: dict | None = None):
    """写入完成标记（合并进 editor_env.json，保留其它键）。"""
    data = read_env()
    data[ENV_KEY] = True
    data["oobe_completed_at"] = datetime.datetime.now().isoformat(timespec="seconds")
    for k, v in (extra or {}).items():
        data[k] = v
    p = env_path()
    p.parent.mkdir(parents=True, exist_ok=True)
    tmp = p.with_suffix(".json.tmp_%d" % os.getpid())
    tmp.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
    tmp.replace(p)


def suggested_workspace() -> Path:
    from .utils import user_mods_dir
    return user_mods_dir()


def current_workspace() -> Path | None:
    """editor_env.json 中已持久化的 workspace；未设置返回 None。"""
    ws = str(read_env().get("workspace_root") or "").strip()
    return Path(ws) if ws else None


def snapshot() -> dict:
    """给 GUI/诊断用的状态快照。"""
    done = is_done()
    return {
        "done": done,
        "first_run": not done,
        "forced": forced_by_env(),
        "disabled": bool(os.environ.get(DISABLE_ENV)),
        "workspace_root": str(current_workspace() or ""),
        "suggested_workspace": str(suggested_workspace()),
        "mods_count": len(_list_mods_safe()),
        "editor_root": str(Path(__file__).resolve().parents[3]),
    }


def _list_mods_safe():
    try:
        from .utils import list_mods
        return list_mods(None)
    except Exception:
        return []


# ---------------------------------------------------------------------------
# 工作区 / 首个 Mod 设置（CLI 向导与 GUI API 共用）
# ---------------------------------------------------------------------------

def set_workspace(path: str | Path) -> Path:
    """校验并创建目录，把 workspace_root 写入 editor_env.json。"""
    p = Path(str(path)).expanduser()
    if not p.is_absolute():
        p = Path.cwd() / p
    p = Path(os.path.normpath(p))
    try:
        p.mkdir(parents=True, exist_ok=True)
    except OSError as e:
        raise ValueError(f"cannot create workspace {p}: {e}") from e
    data = read_env()
    data["workspace_root"] = str(p)
    env_p = env_path()
    env_p.parent.mkdir(parents=True, exist_ok=True)
    tmp = env_p.with_suffix(".json.tmp_%d" % os.getpid())
    tmp.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
    tmp.replace(env_p)
    return p


def create_mod(title: str, workspace: Path, desc: str = "") -> Path:
    """在 workspace 下新建模组骨架（与 CLI mods create 行为一致）。"""
    title = (title or "").strip()
    if not title:
        raise ValueError("模组名不能为空")
    if _TITLE_RE.search(title) or title in (".", ".."):
        raise ValueError(f"模组名含非法字符: {title!r}")
    mod_dir = Path(workspace) / title
    if mod_dir.exists():
        raise ValueError(f"模组已存在: {mod_dir}")
    (mod_dir / "Cfgs" / "zh-cn").mkdir(parents=True, exist_ok=True)
    manifest = {
        "title": title,
        "description": desc or "",
        "version": "1.0.0",
        "created_at": datetime.datetime.now().isoformat(timespec="seconds"),
    }
    (mod_dir / "manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")
    return mod_dir


def _apply_extras(ai_settings: dict | None = None,
                  cloud_provider: dict | None = None,
                  workspace: str | Path | None = None) -> dict:
    """OOBE 可选配置落盘：AI 助手（.editor_ai.json）+ 云存储（.editor_cloud.json）。

    供 apply_setup 与 CLI 向导共用；任一项失败静默降级，不阻塞完成标记。
    返回实际写入项摘要 {"ai_settings": True, "cloud_provider": True, ...}。
    """
    result: dict = {}
    if ai_settings:
        try:
            from editor.core.env_store import write_ai_settings
            patch_ai = {k: v for k, v in ai_settings.items() if v not in (None, "")}
            if patch_ai:
                write_ai_settings(patch_ai)
                result["ai_settings"] = True
        except Exception:
            pass
    if cloud_provider:
        try:
            if workspace:
                try:
                    # 让云存储配置落在 <workspace>/.editor_cloud.json 而不是 cache 兜底
                    from editor.server.api import STATE
                    STATE.workspace_root = str(Path(workspace))
                except Exception:
                    pass
            from editor.server.cloud_sync import add_provider
            add_provider(cloud_provider)
            result["cloud_provider"] = True
        except Exception:
            pass
    return result


def apply_setup(workspace: str | None = None,
                mod_title: str | None = None,
                mod_desc: str = "",
                ai_settings: dict | None = None,
                cloud_provider: dict | None = None) -> dict:
    """OOBE 完成时的一次性落盘：设置工作区（可选）+ 建首个 Mod（可选）
    + AI 助手/云存储（可选）+ 标记完成。

    返回结果摘要（供 API 与向导复用）。
    """
    result: dict = {}
    ws_path = None
    if workspace:
        ws_path = set_workspace(workspace)
        result["workspace"] = str(ws_path)
    elif current_workspace():
        result["workspace"] = str(current_workspace())
    if mod_title:
        target_ws = ws_path or current_workspace() or suggested_workspace()
        mod_dir = create_mod(mod_title, target_ws, mod_desc)
        result["mod"] = mod_dir.name
        result["mod_root"] = str(mod_dir)
    result.update(_apply_extras(ai_settings, cloud_provider,
                                ws_path or current_workspace()))
    patch = {}
    if "workspace" in result:
        patch["workspace_root"] = result["workspace"]
    mark_done(patch)
    result["done"] = True
    return result


# ---------------------------------------------------------------------------
# 触发条件辅助
# ---------------------------------------------------------------------------

def autostart_allowed() -> bool:
    """无 --oobe 时静默自动弹出的条件：未禁用、未完成、且处于交互 TTY。"""
    if not should_run(False):
        return False
    try:
        if not sys.stdin.isatty() or not sys.stdout.isatty():
            return False
    except Exception:
        return False
    return True


# ---------------------------------------------------------------------------
# CLI rich 向导
# ---------------------------------------------------------------------------

_WIZ_BANNER = """
[bold cyan]学生时代 · 模组编辑器[/] [dim]首次使用引导 (OOBE)[/]
"""


def run_cli_wizard(console=None) -> bool:
    """Rich 版命令行 OOBE 向导。

    返回 True 表示已完成或被用户主动跳过（写入完成标记），
    False 表示被中止（Ctrl+C / EOF），下次仍会提示。
    console 便于测试注入；默认新建。
    """
    from rich.console import Console as _Console
    from rich.panel import Panel as _Panel
    from rich.rule import Rule as _Rule
    from rich.table import Table as _Table
    from rich import box as _box
    from .utils import resolve_workspace, load_schema

    con = console or _Console(legacy_windows=False)
    con.print(_WIZ_BANNER)

    # ── 步骤 1: 欢迎 + 环境概览 ──
    schema_n = len(load_schema()) if callable(load_schema) else 0
    try:
        mods = _list_mods_safe()
    except Exception:
        mods = []
    t = _Table(box=_box.SIMPLE, show_header=False, pad_edge=False)
    t.add_column(style="cyan", no_wrap=True)
    t.add_column()
    t.add_row("是什么", "离线直读 Cfgs/zh-cn/*.json 的《学生时代》模组编辑器")
    t.add_row("能做什么", f"GAME_SCHEMA {schema_n} 张表校验 · 可视化编辑 · 全文搜索")
    t.add_row("入口形态", "CLI 单命令 / REPL / TUI 三栏 / Flutter GUI，共用同一份配置")
    t.add_row("当前发现", f"{len(mods)} 个模组（Mods 目录 + 创意工坊）")
    con.print(_Panel(t, border_style="cyan"))

    # ── 步骤 2: 工作区 ──
    default_ws = None
    try:
        default_ws = resolve_workspace(None)
    except SystemExit:
        pass
    ws: Path | None = None
    while True:
        con.print("[bold]① 选择工作区[/] — 存放你的模组（Cfgs 结构目录）")
        shown_default = str(default_ws) if default_ws else str(suggested_workspace())
        try:
            ans = con.input(
                f"[dim]回车=使用 [green]{shown_default}[/]（或输入其它路径，s=跳过）> [/]"
            ).strip()
        except (KeyboardInterrupt, EOFError):
            con.print("\n[dim]已中止引导（未标记完成，下次仍会提示）[/]")
            return False
        if ans.lower() in ("s", "skip"):
            mark_done()
            con.print("[dim]已跳过引导[/]\n")
            return True
        if ans == "":
            if default_ws is None:
                con.print("[red]默认工作区不存在，请输入路径或 s 跳过[/]")
                continue
            ws = default_ws
        else:
            try:
                ok = con.input(f"[yellow]将创建/使用 {Path(ans).expanduser()}，确认？(y/n，回车=N) > [/]").strip().lower()
            except (KeyboardInterrupt, EOFError):
                return False
            if ok != "y":
                continue
            try:
                ws = set_workspace(ans)
            except ValueError as e:
                con.print(f"[red]{e}[/] 请重试")
                continue
        break
    con.print(f"[green]工作区:[/] {ws}\n")

    # ── 步骤 3: 可选建首个 Mod ──
    con.print("[bold]② 创建第一个模组[/] [dim](可选)[/] — 在工作区生成模组目录（manifest.json + Cfgs/zh-cn 空白骨架）")
    mod_name = ""
    try:
        ans = con.input("[dim]输入模组名并回车创建（直接回车=跳过）> [/]").strip()
    except (KeyboardInterrupt, EOFError):
        return False
    if ans:
        try:
            desc = con.input("[dim]描述（可空，直接回车=跳过）> [/]").strip()
        except (KeyboardInterrupt, EOFError):
            return False
        try:
            mod_dir = create_mod(ans, ws, desc)
            mod_name = mod_dir.name
            con.print(f"[green]created[/] {mod_dir}")
        except ValueError as e:
            con.print(f"[yellow]{e} — 已跳过创建[/]")

    # ── 步骤 4: 可选 AI 助手 ──
    ai_settings: dict = {}
    con.print("[bold]③ AI 助手[/] [dim](可选)[/] — 填一次 API Key，编辑器内即可使用 AI 辅助（之后可在设置中修改）")
    try:
        ai_ans = con.input("[dim]配置 AI 助手？(y/n，回车=跳过) > [/]").strip().lower()
    except (KeyboardInterrupt, EOFError):
        return False
    if ai_ans in ("y", "yes"):
        try:
            pv = con.input(
                "[dim]协议 (回车=openai_compatible / openai_responses / anthropic) > [/]").strip()
        except (KeyboardInterrupt, EOFError):
            return False
        ai_settings["provider"] = pv or "openai_compatible"
        try:
            base = con.input("[dim]Base URL（回车=官方默认）> [/]").strip()
        except (KeyboardInterrupt, EOFError):
            return False
        if base:
            ai_settings["baseUrl"] = base
        try:
            key = con.input("[dim]API Key（必填，回车=跳过 AI 配置）> [/]").strip()
        except (KeyboardInterrupt, EOFError):
            return False
        if not key:
            con.print("[yellow]未填 API Key — 跳过 AI 配置[/]")
            ai_settings = {}
        else:
            ai_settings["apiKey"] = key
            try:
                model = con.input("[dim]模型（回车=默认）> [/]").strip()
            except (KeyboardInterrupt, EOFError):
                return False
            if model:
                ai_settings["model"] = model

    # ── 步骤 5: 可选 TTS 配音 ──
    con.print("[bold]④ 配音 TTS[/] [dim](可选)[/] — 为剧情文本配音，支持 阿里云 / MiniMax")
    try:
        tts_ans = con.input("[dim]服务商 (aliyun / minimax，回车=跳过) > [/]").strip().lower()
    except (KeyboardInterrupt, EOFError):
        return False
    if tts_ans in ("aliyun", "minimax"):
        try:
            tkey = con.input("[dim]API Key（必填，回车=跳过 TTS 配置）> [/]").strip()
        except (KeyboardInterrupt, EOFError):
            return False
        if tkey:
            ai_settings["ttsProvider"] = tts_ans
            ai_settings["ttsApiKey"] = tkey
            if tts_ans == "minimax":
                try:
                    gid = con.input("[dim]Group ID（MiniMax 控制台获取，可空）> [/]").strip()
                except (KeyboardInterrupt, EOFError):
                    return False
                if gid:
                    ai_settings["ttsGroupId"] = gid
            try:
                tmodel = con.input("[dim]模型（回车=默认）> [/]").strip()
            except (KeyboardInterrupt, EOFError):
                return False
            if tmodel:
                ai_settings["ttsModel"] = tmodel
            try:
                voice = con.input("[dim]默认音色（回车=默认）> [/]").strip()
            except (KeyboardInterrupt, EOFError):
                return False
            if voice:
                ai_settings["ttsVoice"] = voice
        else:
            con.print("[yellow]未填 API Key — 跳过 TTS 配置[/]")

    # ── 步骤 6: 可选云存储（首次配置场景，简化支持 local / webdav / openlist）──
    cloud_provider: dict | None = None
    con.print("[bold]⑤ 云存储[/] [dim](可选)[/] — 把模组同步到本地其它目录 / WebDAV / OpenList")
    try:
        cloud_ans = con.input(
            "[dim]类型 (local / webdav / openlist，回车=跳过) > [/]").strip().lower()
    except (KeyboardInterrupt, EOFError):
        return False
    if cloud_ans in ("local", "webdav", "openlist"):
        try:
            name = con.input("[dim]名称（回车=类型名）> [/]").strip()
        except (KeyboardInterrupt, EOFError):
            return False
        cfg: dict = {}
        if cloud_ans == "local":
            try:
                root = con.input("[dim]本地根目录（必填，回车=跳过云存储）> [/]").strip()
            except (KeyboardInterrupt, EOFError):
                return False
            if not root:
                con.print("[yellow]未填根目录 — 跳过云存储[/]")
                cloud_ans = ""
            else:
                cfg["root"] = root
        elif cloud_ans == "webdav":
            try:
                url = con.input("[dim]WebDAV 地址（必填，回车=跳过云存储）> [/]").strip()
            except (KeyboardInterrupt, EOFError):
                return False
            if not url:
                con.print("[yellow]未填地址 — 跳过云存储[/]")
                cloud_ans = ""
            else:
                cfg["url"] = url
                try:
                    user = con.input("[dim]用户名（可空）> [/]").strip()
                except (KeyboardInterrupt, EOFError):
                    return False
                if user:
                    cfg["username"] = user
                try:
                    pwd = con.input("[dim]密码（可空）> [/]").strip()
                except (KeyboardInterrupt, EOFError):
                    return False
                if pwd:
                    cfg["password"] = pwd
        else:  # openlist
            try:
                url = con.input("[dim]OpenList 地址（必填，回车=跳过云存储）> [/]").strip()
            except (KeyboardInterrupt, EOFError):
                return False
            if not url:
                con.print("[yellow]未填地址 — 跳过云存储[/]")
                cloud_ans = ""
            else:
                cfg["url"] = url
                try:
                    token = con.input("[dim]Token（可空）> [/]").strip()
                except (KeyboardInterrupt, EOFError):
                    return False
                if token:
                    cfg["token"] = token
        if cloud_ans:
            try:
                remote = con.input("[dim]远端根（回车=mods）> [/]").strip()
            except (KeyboardInterrupt, EOFError):
                return False
            cloud_provider = {
                "name": name or cloud_ans,
                "type": cloud_ans,
                "config": cfg,
                "remote_root": remote or "mods",
            }
            # 可选连接校验（与 /api/cloud/test 同一逻辑），失败不阻塞保存
            try:
                from editor.server.cloud_sync import get_driver
                get_driver(cloud_ans, cfg).test()
                con.print("[green]连接测试通过[/]")
            except Exception as e:
                con.print(f"[yellow]连接测试失败: {e}（配置仍会保存）[/]")

    # ── 完成 ──
    extras = _apply_extras(ai_settings, cloud_provider, ws)
    con.print(_Rule())
    summary = _Table(box=_box.SIMPLE, show_header=False)
    summary.add_column(style="cyan", no_wrap=True)
    summary.add_column()
    summary.add_row("工作区", str(ws))
    if mod_name:
        summary.add_row("当前模组", mod_name)
    if extras.get("ai_settings"):
        summary.add_row("AI 助手", "已配置 (%s)" % (ai_settings.get("provider") or ""))
    if ai_settings.get("ttsProvider"):
        summary.add_row("配音 TTS", "已配置 (%s)" % ai_settings.get("ttsProvider"))
    if extras.get("cloud_provider"):
        summary.add_row("云存储", "%s (%s)" % (cloud_provider.get("name"), cloud_provider.get("type")))
    summary.add_row("下一步", "python run_cli.py mods list   /   run_tui.py 打开三栏界面")
    con.print(_Panel(summary, title="[green]✓ 完成", border_style="green"))
    mark_done({"workspace_root": str(ws)})
    return True
