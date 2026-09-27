#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""从源码启动编辑器(开发模式一键入口)。

流程:
  1. 若 native 后端可执行文件缺失(或传 --build),增量构建 backend 目标
     (调 native/build.cmd / build.sh --no-tests --target backend);
  2. 探测 127.0.0.1:8765,未就绪则拉起后端子进程;
  3. 在 frontend/ 下执行 flutter run(其余参数原样透传,如 -d windows);
  4. flutter 退出后回收本脚本拉起的后端(先 /api/shutdown 优雅退出,兜底 kill)。

用法:
  python run_dev.py                     # 缺则构建,起后端,flutter run(设备自选)
  python run_dev.py --build             # 强制增量重编 backend 目标
  python run_dev.py --no-build          # 跳过构建(产物缺失则直接报错退出)
  python run_dev.py --no-backend        # 不代起后端(由 debug 前端自动拉起源码构建产物)
  python run_dev.py -d windows          # 其余参数透传给 flutter run

仅依赖标准库,Windows / Linux / macOS 通用。
"""

import argparse
import os
import subprocess
import sys
import time
import urllib.request

REPO_ROOT = os.path.dirname(os.path.abspath(__file__))
NATIVE_DIR = os.path.join(REPO_ROOT, "native")
FRONTEND_DIR = os.path.join(REPO_ROOT, "frontend")
PORT = 8765
IS_WIN = os.name == "nt"


def log(msg):
    print(f"[run_dev] {msg}", flush=True)


def backend_bin(build_dir):
    name = "backend.exe" if IS_WIN else "backend"
    return os.path.join(NATIVE_DIR, build_dir, "bin", name)


def pick_build_dir():
    """与 build.sh 的选择规则对齐:WSL 下默认 build-linux,避免共享盘上的
    Windows build/ 缓存互踩;Windows 恒为 build。已存在的产物优先。"""
    if IS_WIN:
        return "build"
    if os.path.exists(backend_bin("build-linux")):
        return "build-linux"
    if os.path.exists(backend_bin("build")):
        return "build"
    return "build-linux" if os.environ.get("WSL_DISTRO_NAME") else "build"


def build_backend(build_dir):
    script = "build.cmd" if IS_WIN else "build.sh"
    cmd = (["cmd", "/c", script] if IS_WIN else ["bash", script]) + [
        "--no-tests",
        "--target",
        "backend",
    ]
    log(f"构建后端: {' '.join(cmd)} (native/{build_dir}, 首次可能需几分钟)")
    rc = subprocess.run(cmd, cwd=NATIVE_DIR).returncode
    if rc != 0:
        sys.exit(f"[run_dev] 后端构建失败(exitCode={rc}):请检查 VS/CMake 环境,或手动运行 native/{script}")


def probe(timeout=1.0):
    try:
        with urllib.request.urlopen(
            f"http://127.0.0.1:{PORT}/api/ping", timeout=timeout
        ) as resp:
            return resp.status == 200
    except Exception:
        return False


def wait_ready(deadline_s=60):
    deadline = time.monotonic() + deadline_s
    while time.monotonic() < deadline:
        if probe():
            return True
        time.sleep(0.5)
    return False


def start_backend(exe, build_dir):
    log(f"拉起后端: {exe} --port {PORT}")
    return subprocess.Popen(
        [exe, "--port", str(PORT)],
        cwd=os.path.join(NATIVE_DIR, build_dir, "bin"),
    )


def shutdown_backend(proc):
    """优雅退出优先:POST /api/shutdown(3s),失败/超时兜底 terminate+kill。"""
    try:
        req = urllib.request.Request(f"http://127.0.0.1:{PORT}/api/shutdown", data=b"")
        urllib.request.urlopen(req, timeout=3).read()
    except Exception:
        pass
    try:
        proc.wait(timeout=5)
        return
    except Exception:
        pass
    proc.terminate()
    try:
        proc.wait(timeout=3)
    except Exception:
        proc.kill()


def flutter_cmd():
    # Windows 下 flutter 是 .bat,CreateProcess 不会按 PATHEXT 解析,须显式指名。
    return "flutter.bat" if IS_WIN else "flutter"


def main():
    parser = argparse.ArgumentParser(
        description="从源码启动编辑器:构建/拉起后端并 flutter run",
        epilog="其余参数透传给 flutter run,例如: python run_dev.py -d windows",
    )
    parser.add_argument("--build", action="store_true", help="强制增量重编后端")
    parser.add_argument("--no-build", action="store_true", help="跳过构建(产物缺失则报错)")
    parser.add_argument("--no-backend", action="store_true",
                        help="不由本脚本拉起后端(debug 前端会自动找源码构建产物)")
    args, flutter_extra = parser.parse_known_args()

    build_dir = pick_build_dir()
    exe = backend_bin(build_dir)

    if not os.path.exists(exe):
        if args.no_build:
            sys.exit(f"[run_dev] 后端产物不存在:{exe}(去掉 --no-build 自动构建)")
        build_backend(build_dir)
    elif args.build:
        build_backend(build_dir)

    if args.no_backend:
        log("--no-backend:跳过拉起后端")
    elif probe():
        log(f"端口 {PORT} 已有在线后端,直接复用")
    else:
        proc = start_backend(exe, build_dir)
        try:
            if not wait_ready():
                proc.terminate()
                sys.exit(f"[run_dev] 后端启动超时(60s 未就绪),请手动运行 {exe} 查看报错")
        except Exception:
            shutdown_backend(proc)
            raise

    log(f"flutter run {' '.join(flutter_extra)}(Ctrl+C 退出)")
    try:
        rc = subprocess.run([flutter_cmd(), "run", *flutter_extra], cwd=FRONTEND_DIR).returncode
    except FileNotFoundError:
        sys.exit("[run_dev] 未找到 flutter 命令,请确认 Flutter SDK 已加入 PATH")
    finally:
        # 本脚本自己拉起的后端才回收;复用/前端拉起的各归各管
        if not args.no_backend and "proc" in locals() and proc.poll() is None:
            log("回收后端进程")
            shutdown_backend(proc)
    sys.exit(rc)


if __name__ == "__main__":
    main()
