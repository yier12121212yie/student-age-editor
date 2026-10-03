# -*- coding: utf-8 -*-
"""导出「人物图片资源扩展包」(Windows 有游戏时执行) —— 薄壳入口。

只导出人物立绘（bundle 名含 role 的纹理），供：
  * Windows 安装包的可选组件「人物图片资源扩展包」（setup.iss）；以及
  * 自托管服务器端的「本地安装 / 对象存储」两种分发方式（见
    `packaging/gateway/gateway.json.example` 的 portraits 段）。

实现与参数见 `tools/resource_scan/decoded_export.py`（tier=portraits）。
默认在参数后补 `--tier portraits` 与 `--out dist/portrait_pack.zip`，也可显式覆盖。

用法:
  python packaging/export_portrait_pack.py [--out dist/portrait_pack.zip]
          [--max-side 1600] [--quality 80] [--limit N]
          [--index aa_index.json] [--aa-dir <游戏 aa 根>] [--cache-dir <目录>]

等价入口（推荐）:
  py -m resource_scan decoded-pack -- --tier portraits --out dist/portrait_pack.zip

注意：本工具需要装有游戏的 Windows 机器 + UnityPy/Pillow（与
`export_decoded_pack.py` 相同前置）；仅靠 `_cache` 索引（无 bundle）时纹理解码
会全部失败，属预期——人物图片包必须在有游戏资源的机器上生成。
"""
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_TOOLS_DIR = os.path.join(ROOT, "tools")
if _TOOLS_DIR not in sys.path:
    sys.path.insert(0, _TOOLS_DIR)

from resource_scan.decoded_export import main  # noqa: E402


def _has_flag(argv, flag):
    return any(a == flag or a.startswith(flag + "=") for a in argv)


def cli(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    if not _has_flag(argv, "--tier"):
        argv += ["--tier", "portraits"]
    if not _has_flag(argv, "--out"):
        argv += ["--out", os.path.join(ROOT, "dist", "portrait_pack.zip")]
    return main(argv)


if __name__ == "__main__":
    sys.exit(cli())
