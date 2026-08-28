# -*- mode: python ; coding: utf-8 -*-
"""「学生时代模组编辑器」后端 PyInstaller 打包脚本。

- pathex 必须指向本项目 backend/ 目录（含 editor 包），
  绝不能指向友商产品源码目录，否则会打包进旧版 editor 包（缺 AI 功能）。
- 用 SPECPATH（PyInstaller 注入）定位项目根目录，避免硬编码绝对路径，
  因此本 spec 可以从任意位置执行：
      pyinstaller packaging/pyinstaller/backend.spec
- 打包形态为 onedir：backend.exe 与 editor_cmd.exe 两个 EXE 共用一个
  COLLECT（name='backend_dist'），依赖统一落在与 exe 同目录的 _internal/
  （PyInstaller 6 约定，bootloader 运行时相对 exe 查找 _internal），
  两个 exe 共享同一份载荷，不再像 onefile 那样各内嵌一份。
  distpath 须指向 build/release（COLLECT 会写到 <distpath>/<name>/），
  产物即 build/release/backend_dist/{backend.exe, editor_cmd.exe, _internal/}。
"""
import os

from PyInstaller.utils.hooks import collect_data_files
from PyInstaller.utils.hooks import collect_submodules

# PyInstaller 注入的 SPECPATH 即 spec 所在目录（绝对路径），直接用。
ROOT = os.path.normpath(os.path.join(os.path.abspath(SPECPATH), "..", ".."))
ENTRY = os.path.join(ROOT, "packaging", "backend_entry.py")
BACKEND = os.path.join(ROOT, "backend")

datas = []
hiddenimports = []
datas += collect_data_files('UnityPy')
hiddenimports += collect_submodules('UnityPy')
# CLI/TUI 依赖：rich / textual / prompt_toolkit 及其子模块，以及本项目 editor.cli / editor.tui
for _pkg in ('rich', 'textual', 'prompt_toolkit', 'editor.cli', 'editor.tui', 'editor.agent'):
    try:
        hiddenimports += collect_submodules(_pkg)
    except Exception:
        pass
    try:
        datas += collect_data_files(_pkg)
    except Exception:
        pass
# 额外：内置资源与数据（若存在则随包分发，便于 Android/Linux 无游戏启动）
import pathlib as _pl
for _extra in [
    (os.path.join(ROOT, "backend", "editor", "data"), "editor/data"),
    (os.path.join(ROOT, "_cache", "resource_packs"), "_cache/resource_packs"),
    (os.path.join(ROOT, "backend", "_cache", "resource_packs"), "_cache/resource_packs"),
]:
    _src, _dst = _extra
    if os.path.isdir(_src):
        datas.append((_src, _dst))


a = Analysis(
    [ENTRY],
    pathex=[BACKEND],
    binaries=[],
    datas=datas,
    hiddenimports=hiddenimports,
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=[
        'PyQt6',
        # fsspec 远程/重依赖实现：hook-fsspec 会用 collect_submodules 把它们
        # 全部带进包，但运行时只有 fsspec + fsspec.implementations.local
        # （UnityPy.environment 硬导入，本地路径）真正用到，其余按 URL scheme
        # 懒加载，本编辑器永远触达不到。每条注释标出连带砍掉的整树。
        'fsspec.implementations.reference',  # pandas/lxml/sqlalchemy/openpyxl/bs4/jinja2
        'fsspec.implementations.http',       # aiohttp/yarl/multidict/pydantic
        'fsspec.implementations.http_sync',  # requests
        'fsspec.implementations.github',     # requests
        'fsspec.implementations.gist',       # requests
        'fsspec.implementations.dbfs',       # requests
        'fsspec.implementations.jupyter',    # requests
        'fsspec.implementations.webhdfs',    # requests/urllib3/cryptography
        'fsspec.implementations.sftp',       # paramiko
        'fsspec.implementations.smb',
        'fsspec.implementations.dask',
        'fsspec.implementations.arrow',
        'fsspec.implementations.libarchive',
        'fsspec.implementations.data',
        'fsspec.implementations.git',
        # textual 演示程序（连带 httpx/httpcore/anyio/h11/h2 整树，生产不需要）
        'textual.demo',
        # pydantic v1 的 hypothesis 插件（纯测试库，随 yarl/aiohttp 链入库）
        'pydantic.v1._hypothesis_plugin',
        # 测试框架（editor/tui/test_agent_stream_flush.py 的 import pytest 不再进包）
        'pytest',
        # tqdm/std.py 的 pandas 集成区（tqdm.std 约 787-827 行）把 pandas/lxml
        # 整树拖进包。fsspec 只在其 TqdmCallback.__init__ 内惰性 import tqdm
        # （fsspec/callbacks.py:297），运行时永不触达；UnityPy 与 editor 零引用。
        'tqdm',
    ],
    noarchive=False,
    optimize=0,
)
pyz = PYZ(a.pure)

# onedir 的 EXE 不内嵌 binaries/datas（exclude_binaries=True），载荷交给
# 下方 COLLECT 统一收集到 _internal/。
exe = EXE(
    pyz,
    a.scripts,
    [],
    exclude_binaries=True,
    name='backend',
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=True,
    upx_exclude=[],
    console=False,
    disable_windowed_traceback=False,
    argv_emulation=False,
    target_arch=None,
    codesign_identity=None,
    entitlements_file=None,
)

# editor_cmd.exe：console 版复制（与 backend.exe 同一入口/依赖，仅子系统不同）。
# windowed 的 backend.exe 从终端启动时输出不可见（rich/textual 需要真实控制台），
# 安装包的 editor-tui / editor-cli 命令由本 exe 提供；复用同一次 Analysis，
# 构建成本近似为零。同样以 onedir 形式进入同一个 COLLECT。
cmd_exe = EXE(
    pyz,
    a.scripts,
    [],
    exclude_binaries=True,
    name='editor_cmd',
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=True,
    upx_exclude=[],
    console=True,
    disable_windowed_traceback=False,
    argv_emulation=False,
    target_arch=None,
    codesign_identity=None,
    entitlements_file=None,
)

# 两个 exe 共用一份 _internal/：COLLECT 把 exe 与 a.binaries/a.datas 一起
# 写到 <distpath>/backend_dist/，name 须与 build_release.py 的
# BACKEND_DIST 目录名保持一致。
coll = COLLECT(
    exe,
    cmd_exe,
    a.binaries,
    a.datas,
    strip=False,
    upx=True,
    upx_exclude=[],
    name='backend_dist',
)
