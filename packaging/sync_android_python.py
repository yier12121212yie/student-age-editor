# -*- coding: utf-8 -*-
"""把 Python 后端同步进 Android 工程（Chaquopy src/main/python）。

用法：python packaging/sync_android_python.py

内容：
1. backend/editor 包        -> frontend/android/app/src/main/python/editor
2. site-packages 的 UnityPy -> .../python/UnityPy（排除 __pycache__/.pyd；
   UnityPyBoost 等编译模块在源码中均有 ImportError 兜底）
3. 生成 4 个占位模块：texture2ddecoder / astc_encoder / etcpak / fmod_toolkit，
   它们没有 Android 原生轮子；仅当真正解码对应纹理/音频格式时才会报错。
4. 检查内置资源包 assets/bundled/resource_pack.zip 是否存在（可选，存在与否都
   不报错；不存在时 APK 将无内置资源，可后续从 GitHub Release 注入或打包后导入）。
"""
import os
import shutil
import sysconfig

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PY_ROOT = os.path.join(ROOT, "frontend", "android", "app", "src", "main", "python")
BUNDLED_ZIP = os.path.join(ROOT, "frontend", "android", "app",
                           "src", "main", "assets", "bundled", "resource_pack.zip")

EDITOR_SRC = os.path.join(ROOT, "backend", "editor")


def _unitypy_src():
    import UnityPy  # noqa: PLC0415

    return os.path.dirname(os.path.abspath(UnityPy.__file__))

IGNORE = shutil.ignore_patterns("__pycache__", "*.pyc", "*.pyd")

STUBS = {
    "texture2ddecoder.py": '"""Android 发行版占位：无原生库，解码对应压缩纹理时抛错。"""\n\n'
                           'def __getattr__(name):\n'
                           '    raise RuntimeError("texture2ddecoder 在本平台不可用（缺少原生解码库）")\n',
    "astc_encoder.py": '"""Android 发行版占位：无原生库，编解码 ASTC 纹理时抛错。"""\n\n'
                       'def __getattr__(name):\n'
                       '    raise RuntimeError("astc_encoder 在本平台不可用（缺少原生编解码库）")\n',
    "etcpak.py": '"""Android 发行版占位：无原生库，压缩 ETC/BC 纹理时抛错。"""\n\n'
                 'def __getattr__(name):\n'
                 '    raise RuntimeError("etcpak 在本平台不可用（缺少原生压缩库）")\n',
    "fmod_toolkit.py": '"""Android 发行版占位：无 FMOD 原生库，读取 FSB 音频时抛错。"""\n\n'
                       'def __getattr__(name):\n'
                       '    raise RuntimeError("fmod_toolkit 在本平台不可用（缺少 FMOD 库）")\n',
}


def _sync_dir(src, dst):
    if os.path.isdir(dst):
        shutil.rmtree(dst)
    shutil.copytree(src, dst, ignore=IGNORE)


def main():
    os.makedirs(PY_ROOT, exist_ok=True)
    print("[1/4] editor 包 ...")
    _sync_dir(EDITOR_SRC, os.path.join(PY_ROOT, "editor"))
    print("[2/4] UnityPy (%s) ..." % _unitypy_src())
    _sync_dir(_unitypy_src(), os.path.join(PY_ROOT, "UnityPy"))
    print("[3/4] 占位模块 ...")
    for name, content in STUBS.items():
        with open(os.path.join(PY_ROOT, name), "w", encoding="utf-8") as f:
            f.write(content)
    total = sum(len(fs) for _, _, fs in os.walk(PY_ROOT))
    print("完成：%d 个文件 -> %s" % (total, PY_ROOT))
    print("[4/4] 内置资源包检查 ...")
    if os.path.isfile(BUNDLED_ZIP):
        print("已内置资源包：%s (%.1f MB)"
              % (BUNDLED_ZIP, os.path.getsize(BUNDLED_ZIP) / 1048576))
    else:
        print("警告：未找到 %s" % BUNDLED_ZIP)
        print("      APK 将无内置资源（构建机无游戏时属正常，可打包后导入）。")
        print("      有游戏的机器可运行 packaging/export_decoded_pack.py 导出；")
        print("      CI 环境可用 packaging/fetch_bundled.py 从 GitHub Release 注入。")


if __name__ == "__main__":
    main()
