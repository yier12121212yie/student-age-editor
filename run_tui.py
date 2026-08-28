# -*- coding: utf-8 -*-
"""TUI 启动器 — 等价于: python -m editor.tui  /  python -m editor.cli tui

用法:
  python run_tui.py
  python run_tui.py --mod test
"""
import os
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(ROOT, "backend")
if SRC not in sys.path:
    sys.path.insert(0, SRC)
os.environ["PYTHONPATH"] = SRC + os.pathsep + os.environ.get("PYTHONPATH", "")

from editor.tui.app import run

if __name__ == "__main__":
    import argparse
    ap = argparse.ArgumentParser(description="学生时代 模组编辑器 — TUI")
    ap.add_argument("--mod", default=None, help="初始模组名")
    ap.add_argument("--workspace", default=None, help="workspace 路径")
    ap.add_argument("--oobe", action="store_true", help="强制开启首次使用引导（OOBE）")
    args = ap.parse_args()
    run(workspace=args.workspace, initial_mod=args.mod, force_oobe=args.oobe)
