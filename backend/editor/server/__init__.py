# -*- coding: utf-8 -*-
"""本地 HTTP 服务入口：editor.server.start_server() 启动。"""
import os
import sys

_SRC_DIR = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
if _SRC_DIR not in sys.path:
    sys.path.insert(0, _SRC_DIR)

from editor.server.api import build_router  # noqa: E402
from editor.server.httpd import run_server  # noqa: E402


def start_server(port=0, on_ready=None, data_root=None, packs_root=None, bundled_zip=None):
    """启动本地 API 服务（后台线程）。返回 (thread, port)。

    data_root / packs_root：Android（Chaquopy filesDir）等无写权限环境的
    覆盖入口，写入环境变量 EDITOR_DATA_ROOT / EDITOR_PACKS_ROOT 供各模块读取。
    bundled_zip：内置预解码资源包 zip 路径，首次启动时解压到
    packs_root/bundled（免重复解压由版本标记控制）。
    """
    if data_root:
        os.environ.setdefault("EDITOR_DATA_ROOT", data_root)
        os.environ.setdefault("EDITOR_PLUGINS_ROOT", os.path.join(data_root, "plugins"))
    if packs_root:
        os.environ.setdefault("EDITOR_PACKS_ROOT", packs_root)
    _extract_bundled(bundled_zip, packs_root)
    router = build_router()
    return run_server(router, host="127.0.0.1", port=port, on_ready=on_ready)


def _extract_bundled(zip_path, packs_root):
    """把内置资源包 zip 解压到 packs_root/bundled（按内容指纹跳过已解压）。"""
    if not zip_path or not packs_root or not os.path.isfile(zip_path):
        return
    dest = os.path.join(packs_root, "bundled")
    marker = os.path.join(dest, ".bundled_version")
    try:
        import hashlib
        with open(zip_path, "rb") as f:
            digest = hashlib.md5(f.read(1 << 20)).hexdigest()
    except Exception:
        digest = ""
    if os.path.isfile(marker):
        try:
            with open(marker, "r", encoding="utf-8") as f:
                if f.read().strip() == digest:
                    return
        except Exception:
            pass
    try:
        import zipfile
        os.makedirs(dest, exist_ok=True)
        with zipfile.ZipFile(zip_path) as z:
            for n in z.namelist():
                if n.startswith("/") or ".." in n or ":" in n:
                    continue
                z.extract(n, dest)
        with open(marker, "w", encoding="utf-8") as f:
            f.write(digest)
    except Exception:
        pass


def main():
    import argparse
    ap = argparse.ArgumentParser(description="学生时代模组编辑器 - 本地 API 服务")
    ap.add_argument("--port", type=int, default=0)
    ap.add_argument("--write-port", default="")
    args = ap.parse_args()

    def ready(port):
        print("API server listening on 127.0.0.1:%d" % port)
        if args.write_port:
            try:
                with open(args.write_port, "w", encoding="utf-8") as f:
                    f.write(str(port))
            except Exception as e:
                print("cannot write port file: %s" % e)

    thread, port = start_server(port=args.port, on_ready=ready)
    import time
    try:
        while True:
            time.sleep(3600)
    except KeyboardInterrupt:
        pass
    return 0
