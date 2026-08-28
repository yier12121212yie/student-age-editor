# -*- coding: utf-8 -*-
"""CLI 启动器 — 等价于: python -m editor.cli

用法:
  python run_cli.py mods list
  python run_cli.py cfg get EvtCfg --mod test --id 320101
  python run_cli.py --help
"""
import os
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(ROOT, "backend")
if SRC not in sys.path:
    sys.path.insert(0, SRC)
os.environ["PYTHONPATH"] = SRC + os.pathsep + os.environ.get("PYTHONPATH", "")

from editor.cli.app import main

if __name__ == "__main__":
    # 无参 → Claude Code 风格 REPL
    if len(sys.argv) == 1:
        from editor.cli.interactive import run_interactive
        run_interactive()
    else:
        sys.exit(main())
