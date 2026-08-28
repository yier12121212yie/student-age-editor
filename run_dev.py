# -*- coding: utf-8 -*-
"""开发启动器：先启动 Python 后端（127.0.0.1:8765），再启动 Flutter 前端。

用法：python run_dev.py [--backend-only] [--oobe]
"""
import os
import shutil
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(ROOT, "backend")           # 我方 Python 后端（editor 包所在目录）
FRONTEND = os.path.join(ROOT, "frontend")

PORT = 8765


def _port_in_use(port):
    """探测端口是否已被占用（不设置 SO_REUSEADDR，避免误判双绑定场景）。"""
    import socket
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 0)
        try:
            s.bind(("127.0.0.1", port))
            return False
        except OSError:
            return True


def _kill_port_owner(port):
    """结束占用指定端口的进程，返回被成功结束的 PID 列表；无法定位时返回空列表。

    Windows 用 netstat -ano 查 PID 后 taskkill /F；其他平台用 lsof -ti 查 PID 后 kill -9。
    """
    import re

    pids = []
    if sys.platform == "win32":
        proc = subprocess.run(
            ["netstat", "-ano", "-p", "tcp"],
            capture_output=True, text=True,
        )
        pattern = re.compile(r"\S+:%d\s+\S+\s+LISTENING\s+(\d+)" % port)
        for line in proc.stdout.splitlines():
            m = pattern.search(line)
            if m and m.group(1) != "0":
                pids.append(m.group(1))
    else:
        proc = subprocess.run(
            ["lsof", "-ti", "tcp:%d" % port],
            capture_output=True, text=True,
        )
        if proc.returncode == 0:
            pids = [pid for pid in proc.stdout.split() if pid != "0"]

    killed = []
    for pid in sorted(set(pids)):
        if sys.platform == "win32":
            r = subprocess.run(["taskkill", "/F", "/PID", pid],
                               capture_output=True, text=True)
        else:
            r = subprocess.run(["kill", "-9", pid], capture_output=True, text=True)
        if r.returncode == 0:
            killed.append(pid)
        else:
            print("警告：无法结束进程 %s（%s）" % (pid, (r.stderr or "").strip()))
    return killed


def _flutter_cmd():
    """返回可被 subprocess 直接执行的 flutter 命令列表。

    Windows 上 flutter 是 flutter.bat，CreateProcess 无法直接执行，
    需要经 cmd.exe /c 包装；同时优先解析完整路径避免 PATH 差异。
    """
    exe = shutil.which("flutter")
    if not exe:
        return None
    if sys.platform == "win32":
        return ["cmd", "/c", exe]
    return [exe]


def main():
    if not os.path.isdir(SRC):
        print("错误：找不到后端源码目录：%s" % SRC)
        return 1

    backend_only = "--backend-only" in sys.argv
    oobe_mode = "--oobe" in sys.argv
    env = dict(os.environ)
    env["PYTHONPATH"] = SRC + os.pathsep + env.get("PYTHONPATH", "")
    if oobe_mode:
        # 与打包模式下 runner/main.cpp 注入行为一致：后端与前端均可见，
        # 强制弹出 OOBE 引导页（不影响 editor_env.json 的持久化状态）。
        env["EDITOR_OOBE"] = "1"
        print("已启用 --oobe：EDITOR_OOBE=1，本次启动将强制弹出首次使用引导页")

    if _port_in_use(PORT):
        print("警告：端口 %d 已被占用，正在结束占用该端口的进程..." % PORT)
        killed = _kill_port_owner(PORT)
        if not killed:
            print("错误：无法定位并结束占用端口 %d 的进程，请手动关闭后重试。" % PORT)
            return 1
        print("已结束占用端口的进程：%s" % ", ".join(killed))
        # 等待端口释放
        for _ in range(40):
            if not _port_in_use(PORT):
                break
            time.sleep(0.25)
        else:
            print("错误：端口 %d 仍被占用，请手动关闭占用进程后重试。" % PORT)
            return 1
        print("端口 %d 已释放，继续启动。" % PORT)

    if not backend_only:
        flutter_cmd = _flutter_cmd()
        if flutter_cmd is None:
            print("错误：未找到 flutter 命令。请安装 Flutter SDK 并将其加入 PATH。")
            return 1

    backend = subprocess.Popen(
        [sys.executable, "-m", "editor.server", "--port", str(PORT)],
        cwd=SRC, env=env,
    )
    print("后端启动中 (127.0.0.1:%d)..." % PORT)
    # 等待后端就绪
    import urllib.request
    for _ in range(60):
        try:
            with urllib.request.urlopen("http://127.0.0.1:%d/api/ping" % PORT, timeout=1) as r:
                if r.status == 200:
                    print("后端已就绪")
                    break
        except Exception:
            time.sleep(0.5)
    else:
        print("后端启动失败")
        backend.kill()
        return 1

    if backend_only:
        print("按 Ctrl+C 停止")
        try:
            while True:
                time.sleep(3600)
        except KeyboardInterrupt:
            pass
        backend.terminate()
        return 0

    frontend = subprocess.Popen(
        flutter_cmd + ["run", "-d", "windows"],
        cwd=FRONTEND, env=env,
    )
    print("Flutter 前端启动中（flutter run -d windows）...")
    try:
        frontend.wait()
    except KeyboardInterrupt:
        pass
    finally:
        frontend.terminate()
        backend.terminate()
    return 0


if __name__ == "__main__":
    sys.exit(main())
