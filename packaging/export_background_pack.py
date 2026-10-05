# -*- coding: utf-8 -*-
"""导出「背景图片资源扩展包」。

与「人物图片资源扩展包」同构（见 `export_portrait_pack.py`）：只导出背景
纹理，供：
  * Windows 安装包的可选组件「背景图片资源扩展包」（setup.iss）；以及
  * 自托管服务器端的「本地安装 / 对象存储」两种分发方式（见
    `packaging/gateway/BACKGROUNDS.md` 的 backgrounds 段）。

两种数据源：
  1. **已解码图片目录**（推荐，无游戏也能成包）：`--from-dir <目录>`，把目录内
     PNG/JPG/... 统一转 WebP。默认在未显式指定来源且 `参考资料/背景` 存在时
     自动使用该目录；
  2. **游戏 bundle 解码**（装有《学生时代》的 Windows 机器）：走
     `tools/resource_scan/decoded_export.py` 的 `--tier backgrounds`，从 bundle
     名含 bg 的纹理解码。

默认在参数后补 `--tier backgrounds` 与 `--out dist/background_pack.zip`，也可
显式覆盖。

用法:
  python packaging/export_background_pack.py [--out dist/background_pack.zip]
          [--from-dir 参考资料/背景]
          [--max-side 1920] [--quality 82] [--limit N]
          [--index aa_index.json] [--aa-dir <游戏 aa 根>] [--cache-dir <目录>]

等价入口（游戏 bundle 路径）:
  py -m resource_scan decoded-pack -- --tier backgrounds --out dist/background_pack.zip
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
        argv += ["--tier", "backgrounds"]
    if not _has_flag(argv, "--out"):
        argv += ["--out", os.path.join(ROOT, "dist", "background_pack.zip")]
    # 参考资料/背景 存在且未显式指定来源时，直接吃已解码目录：没有游戏的机器
    # 也能离线成包（背景贴图本就是解码后的 PNG 存料）。
    has_source = (_has_flag(argv, "--from-dir") or _has_flag(argv, "--aa-dir")
                  or _has_flag(argv, "--index"))
    ref_dir = os.path.join(ROOT, "参考资料", "背景")
    if not has_source and os.path.isdir(ref_dir):
        argv += ["--from-dir", ref_dir]
    return main(argv)


if __name__ == "__main__":
    sys.exit(cli())
