# -*- coding: utf-8 -*-
"""导出「内置解码资源包」(Windows 有游戏时执行) —— 薄壳入口。

实现已整体迁至 `tools/resource_scan/decoded_export.py`（W5-3 从 backend/editor
剥离，零 editor 包依赖）。本文件保留是因为历史文档/脚本按此路径引用；它只
把仓库 `tools/` 挂上 sys.path 后转调同一 main()。

用法（与迁移前逐参一致）:
  python packaging/export_decoded_pack.py [--out dist/bundled_preview.zip]
          [--tier preview|full] [--max-side 1600] [--quality 80]
          [--limit N] [--no-audios] [--no-zip]

等价入口（推荐）:
  py -m resource_scan decoded-pack -- <上述参数...>

产物 zip 布局与语义见 decoded_export.py 模块 docstring 与
tools/resource_scan/ARTIFACT_FORMAT.md §6。
"""
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_TOOLS_DIR = os.path.join(ROOT, "tools")
if _TOOLS_DIR not in sys.path:
    sys.path.insert(0, _TOOLS_DIR)

from resource_scan.decoded_export import main  # noqa: E402


if __name__ == "__main__":
    sys.exit(main())
