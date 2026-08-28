# -*- coding: utf-8 -*-
"""「学生时代模组编辑器」后端打包入口（PyInstaller）。

打包命令由 build_release.py 生成；本文件也可直接运行用于调试：
    python packaging/backend_entry.py --port 8765
"""
import os
import sys

# 开发模式直接运行时注入源码路径；打包后由 PyInstaller 冻结模块提供。
_SRC = os.path.normpath(os.path.join(
    os.path.dirname(os.path.abspath(__file__)),
    "..", "backend"))
if os.path.isdir(_SRC) and _SRC not in sys.path:
    sys.path.insert(0, _SRC)

# UTF-8 stdout/stderr early to avoid Windows console encoding issues
try:
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    if hasattr(sys.stderr, "reconfigure"):
        sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

# 发行版（frozen + noconsole）无控制台时，重定向到 logs/backend.log。
# 但 CLI/TUI 模式或 editor_cmd.exe 需要保留控制台输出，仅在 GUI/server 模式下重定向。
_exe_name = os.path.basename(sys.executable).lower() if sys.executable else ""
_is_cmd_exe = "editor_cmd" in _exe_name or "cmd" in _exe_name
_is_cli = _is_cmd_exe or any(
    a.lstrip("-") in ("cli", "tui", "mods", "cfg", "schema", "search", "workspace", "doctor", "agent", "cloud", "help", "h")
    for a in sys.argv[1:]
)
_is_server = not _is_cli

if getattr(sys, "frozen", False) and _is_server:
    try:
        from editor.core.paths import logs_dir
        log_dir = logs_dir()
        os.makedirs(log_dir, exist_ok=True)
        _log = open(os.path.join(log_dir, "backend.log"), "a",
                    encoding="utf-8", buffering=1)
        sys.stdout = _log
        sys.stderr = _log
    except Exception:
        pass

from editor.server import main as server_main  # noqa: E402

# 扩展：发行版 backend.exe 也支持 CLI/TUI 模式
#   backend.exe --cli mods list
#   backend.exe --tui
#   backend.exe --port 8765  (默认 server 模式)
_CLI_TRIGGERS = {"cli", "--cli", "tui", "--tui", "mods", "cfg", "schema", "search", "workspace", "doctor", "agent", "cloud", "help", "-h", "--help"}
def _is_cli_mode(argv):
    if not argv:
        return False
    first = argv[0].lstrip("-")
    return first in _CLI_TRIGGERS or first in {"mods", "cfg", "schema", "search", "workspace", "server", "doctor", "tui", "agent", "cloud", "help"}

if __name__ == "__main__":
    argv = sys.argv[1:]
    if argv and argv[0] in ("--cli", "cli"):
        from editor.cli.app import main as cli_main
        sys.exit(cli_main(argv[1:]))
    if argv and argv[0] in ("--tui", "tui"):
        # 去掉触发词后透传 --mod/--workspace/--oobe 等参数
        from editor.tui.app import run as tui_run
        # 简单解析 --mod/--workspace
        import argparse
        ap = argparse.ArgumentParser(add_help=False)
        ap.add_argument("--mod", default=None)
        ap.add_argument("--workspace", default=None)
        ap.add_argument("--oobe", action="store_true")
        ns, _ = ap.parse_known_args(argv[1:])
        sys.exit(tui_run(workspace=ns.workspace, initial_mod=ns.mod, force_oobe=ns.oobe) or 0)
    # 如果首参数本身就是 CLI 子命令（如 mods / cfg），也走 CLI
    if argv and _is_cli_mode(argv):
        from editor.cli.app import main as cli_main
        sys.exit(cli_main(argv))
    # 若以 editor_cmd.exe 启动且无参数，默认进入交互式 CLI REPL（避免启动无头 Web 服务或闪退）
    if _is_cmd_exe and not argv:
        from editor.cli.app import main as cli_main
        sys.exit(cli_main([]))
    sys.exit(server_main())
