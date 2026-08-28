# -*- coding: utf-8 -*-
"""python -m editor.tui"""

from .app import run

if __name__ == "__main__":
    import argparse
    ap = argparse.ArgumentParser(description="学生时代 模组编辑器 — TUI")
    ap.add_argument("--mod", default=None, help="初始模组名")
    ap.add_argument("--workspace", default=None, help="workspace 路径")
    ap.add_argument("--oobe", action="store_true", help="强制开启首次使用引导（OOBE）")
    args = ap.parse_args()
    run(workspace=args.workspace, initial_mod=args.mod, force_oobe=args.oobe)
