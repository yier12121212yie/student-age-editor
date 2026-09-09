# -*- coding: utf-8 -*-
"""aa_scan.exe 冻结入口：把 tools/resource_scan 打包为独立发行工具。

- 运行时把仓库 tools/ 加入 sys.path 后走 resource_scan.__main__.main()，
  不触碰 backend/（该工具波次 2 起零 editor 包依赖）。
- ProcessPoolExecutor（aa_index/base-tables 的 --jobs）在 Windows 走 spawn，
  子进程会重拉本 exe，必须 freeze_support() 兜住，否则无限弹窗。
- decoded-pack 子命令透传 sys.executable → 冻结形态下不可用（会拉起自身），
  发行包内本工具只用于 index / base-tables。
"""
import multiprocessing
import os
import sys


def _main():
    # 冻结时 resource_scan 已随包收集（aa_scan.spec 的 pathex）；源码直跑时
    # 兜底把仓库 tools/ 挂上 sys.path。
    root = os.path.normpath(os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "..", ".."))
    tools_dir = os.path.join(root, "tools")
    if os.path.isdir(tools_dir) and tools_dir not in sys.path:
        sys.path.insert(0, tools_dir)
    from resource_scan.__main__ import main
    sys.exit(main())


if __name__ == "__main__":
    multiprocessing.freeze_support()
    _main()
