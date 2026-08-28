# -*- coding: utf-8 -*-
"""跨平台「应用数据根目录」解析（缓存 / 日志 / 配置的落盘位置）。

定位规则：
- 开发模式（未冻结）：backend/ 源码根（与历史行为一致，_cache 可直接复用）。
- PyInstaller 冻结 + Windows：exe 同目录（便携 zip 语义，历史行为不变）。
- PyInstaller 冻结 + Linux/macOS：exe 同目录可写时仍用 exe 同目录
  （便携 zip、~/.local 等用户安装场景，数据随目录整体删除）；
  否则回退到平台标准用户数据目录（AppImage 只读挂载、/opt 或
  /Applications 系统安装等场景）：
  - Linux:  $XDG_DATA_HOME/student-age-editor，默认 ~/.local/share/student-age-editor
  - macOS:  ~/Library/Application Support/StudentAgeEditor

「exe 同目录可写」判定：尝试在其中创建并删除一个临时文件，结果按目录
缓存。打包安装器（packaging/linux/install.sh、macOS PKG postinstall）写
editor_env.json 时必须复用同一判定，保证配置落在后端实际使用的数据目录。
"""
import os
import sys

_APP_DATA_DIR_CACHE = None


def dev_root():
    """源码模式下的 backend/ 根目录（backend/editor/core/paths.py 上三级）。"""
    return os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def exe_dir():
    """冻结模式下 backend 可执行文件所在目录；开发模式下为 backend/。"""
    if getattr(sys, "frozen", False):
        return os.path.dirname(os.path.abspath(sys.executable))
    return dev_root()


def _dir_writable(path):
    """目录存在（或可创建）且当前用户可在其中建删文件。"""
    try:
        os.makedirs(path, exist_ok=True)
        probe = os.path.join(path, ".write_probe_%d" % os.getpid())
        with open(probe, "w", encoding="utf-8") as f:
            f.write("ok")
        os.remove(probe)
        return True
    except Exception:
        return False


def platform_data_dir():
    """平台标准用户数据目录（exe 旁不可写时的固定落点，与安装方式无关）。"""
    if sys.platform == "darwin":
        return os.path.join(os.path.expanduser("~"), "Library",
                            "Application Support", "StudentAgeEditor")
    base = os.environ.get("XDG_DATA_HOME") \
        or os.path.join(os.path.expanduser("~"), ".local", "share")
    return os.path.join(base, "student-age-editor")


def app_data_dir():
    """可写数据根目录（_cache、日志、editor_env.json 等）。"""
    global _APP_DATA_DIR_CACHE
    if _APP_DATA_DIR_CACHE is None:
        if not getattr(sys, "frozen", False) or sys.platform == "win32":
            root = exe_dir()  # 开发模式与 Windows：历史行为不变
        elif _dir_writable(exe_dir()):
            root = exe_dir()  # 便携目录可写：数据随安装目录走
        else:
            root = platform_data_dir()
        _APP_DATA_DIR_CACHE = root
    return _APP_DATA_DIR_CACHE


def logs_dir():
    """backend 无控制台运行时的日志目录。"""
    return os.path.join(app_data_dir(), "logs")
