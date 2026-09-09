# -*- mode: python ; coding: utf-8 -*-
"""aa_scan.exe —— tools/resource_scan 的 PyInstaller onefile 冻结。

发行通道（W4-1）：Windows 后端切 native C++ 后，AA 资源扫描不再嵌在后端里，
以独立工具 aa_scan.exe 随包（index / base-tables 两个子命令，产物契约见
tools/resource_scan/ARTIFACT_FORMAT.md，供 C++ 后端消费方对接）。

- onefile：单 exe 携带全部依赖（含 UnityPy，扫描 bundle 时需要），随包/
  调用都简单；启动有解包开销，扫描属低频重活，可接受。
- pathex 指向仓库 tools/，入口 aa_scan_entry.py 走 resource_scan.__main__。
- distpath 下产物即 <distpath>/aa_scan.exe。
- 构建失败（缺 PyInstaller/UnityPy 等）由 build_release.py 捕获降级为
  「本次发行不随 aa_scan.exe」，不阻塞主链路；故本 spec 不做图标等
  非功能硬校验，图标存在才设置。
"""
import os
import sys

from PyInstaller.utils.hooks import collect_data_files
from PyInstaller.utils.hooks import collect_submodules

ROOT = os.path.normpath(os.path.join(os.path.abspath(SPECPATH), "..", ".."))
ENTRY = os.path.join(ROOT, "packaging", "pyinstaller", "aa_scan_entry.py")
TOOLS = os.path.join(ROOT, "tools")
if TOOLS not in sys.path:
    sys.path.insert(0, TOOLS)

datas = []
hiddenimports = ["resource_scan", "resource_scan.__main__", "resource_scan.aa_index",
                 "resource_scan.base_tables", "resource_scan.util"]
try:
    hiddenimports += collect_submodules("UnityPy")
    datas += collect_data_files("UnityPy")
except Exception:
    pass  # 缺 UnityPy：exe 能出，但 bundle 模式运行时自会报错提示

APP_ICON = os.path.join(ROOT, "frontend", "windows", "runner", "resources", "app_icon.ico")
if sys.platform == "win32" and not os.path.isfile(APP_ICON):
    APP_ICON = None

a = Analysis(
    [ENTRY],
    pathex=[TOOLS],
    binaries=[],
    datas=datas,
    hiddenimports=hiddenimports,
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=[
        'PyQt6', 'PySide6', 'tkinter',
        'fsspec.implementations.reference',
        'fsspec.implementations.http',
        'fsspec.implementations.http_sync',
        'fsspec.implementations.github',
        'fsspec.implementations.gist',
        'fsspec.implementations.dbfs',
        'fsspec.implementations.jupyter',
        'fsspec.implementations.webhdfs',
        'fsspec.implementations.sftp',
        'fsspec.implementations.smb',
        'fsspec.implementations.dask',
        'fsspec.implementations.arrow',
        'fsspec.implementations.libarchive',
        'fsspec.implementations.data',
        'fsspec.implementations.git',
    ],
    noarchive=False,
    optimize=0,
)
pyz = PYZ(a.pure)

exe = EXE(
    pyz,
    a.scripts,
    a.binaries,
    a.datas,
    [],
    name='aa_scan',
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=False,
    console=True,
    disable_windowed_traceback=False,
    argv_emulation=False,
    target_arch=None,
    codesign_identity=None,
    entitlements_file=None,
    icon=APP_ICON,
)
