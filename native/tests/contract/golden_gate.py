# -*- coding: utf-8 -*-
"""golden 门禁（W4-5 后落位正树）：复刻 tools/golden_env.make_env() 的隔离环境，
用任一本机 C++ backend.exe 打 record_golden.py --check 全 38 端点。
（原为 wave-3 P5 的 native/wip/P5/golden_gate.py；迁移期归档退役后移入
native/tests/contract/，与 normalize.py / run_cpp_*.py 同桌，成为长期门禁入口。）

make_env() 的进程内补丁在独立进程里等价实现：
  * steam_library_paths -> []   => EDITOR_DISABLE_STEAM_DETECT=1 + editor_env.json
                                   里 steam_library_paths=[]（防御性冗余）
  * user_mods_dir 哨兵          => editor_env.json user_mods_dir=<tmp>/user_mods
                                   + --workspace-root 兜底（永不回退 LocalLow）
  * _APP_DATA_DIR_CACHE=<data>  => EDITOR_DATA_ROOT=<tmp>/data（C++ editor_root()
                                   的第一优先级）
绝不写真实游戏 Mods / backend 目录。只用 8790-8799 端口；只杀自己启动的 PID。

用法：python native/tests/contract/golden_gate.py [path\\to\\backend.exe]
退出码 0 == 38/38 PASS（输出为 record_golden.py 原文）。
"""
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
NATIVE = os.path.abspath(os.path.join(HERE, "..", ".."))
REPO_ROOT = os.path.abspath(os.path.join(NATIVE, ".."))


def find_backend():
    if len(sys.argv) > 1:
        return sys.argv[1]
    cand = os.path.join(NATIVE, "build", "bin", "backend.exe")
    if os.path.isfile(cand):
        return cand
    return None


def pick_port():
    for port in range(8790, 8800):
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        try:
            s.bind(("127.0.0.1", port))
            return port
        except OSError:
            continue
        finally:
            s.close()
    raise RuntimeError("no free port in 8790-8799")


def http_get(port, path, timeout=8):
    url = "http://127.0.0.1:%d%s" % (port, path)
    req = urllib.request.Request(url, method="GET",
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.status, resp.read()


def main():
    backend = find_backend()
    if not backend or not os.path.isfile(backend):
        print("ERROR: backend_wip.exe not found (%s)" % backend)
        return 2

    tmp = tempfile.mkdtemp(prefix="p5_golden_env_")
    port = pick_port()
    proc = None
    try:
        data_root = os.path.join(tmp, "data")
        workspace = os.path.join(tmp, "workspace")
        os.makedirs(data_root)
        os.makedirs(workspace)
        with open(os.path.join(data_root, "editor_env.json"), "w", encoding="utf-8") as f:
            json.dump({"workspace_root": os.path.abspath(workspace),
                       "oobe_completed": True,
                       "steam_library_paths": [],
                       "user_mods_dir": os.path.join(tmp, "user_mods")},
                      f, ensure_ascii=False, indent=2)

        env = dict(os.environ)
        env["EDITOR_DATA_ROOT"] = data_root
        env["EDITOR_PLUGINS_ROOT"] = os.path.join(data_root, "plugins")
        env["EDITOR_PACKS_ROOT"] = os.path.join(data_root, "resource_packs")
        env["EDITOR_DISABLE_STEAM_DETECT"] = "1"
        # backend starts with cwd=<tmp> for isolation; /api/state's schema_count
        # (golden 406) reads native/assets/schema.json — point the loader at it
        # explicitly (assets are read-only shared inputs).
        env["EDITOR_ASSETS_ROOT"] = os.path.join(NATIVE, "assets")
        for key in ("EDITOR_OOBE", "EDITOR_NO_OOBE", "EDITOR_BASE_ARTIFACT_DIR",
                    "EDITOR_DECODED_PACK_DIR", "EDITOR_UPDATE_URL"):
            env.pop(key, None)

        proc = subprocess.Popen(
            [backend, "--port", str(port), "--workspace-root", workspace],
            cwd=tmp, env=env,
            stdout=open(os.path.join(tmp, "backend.out"), "wb"),
            stderr=subprocess.STDOUT)

        ready = False
        end = time.time() + 20
        while time.time() < end:
            if proc.poll() is not None:
                print("ERROR: backend exited early (code %s)" % proc.returncode)
                with open(os.path.join(tmp, "backend.out"), "rb") as f:
                    print(f.read().decode("utf-8", "replace")[-2000:])
                return 2
            try:
                st, _ = http_get(port, "/api/ping")
                if st == 200:
                    ready = True
                    break
            except (urllib.error.URLError, OSError):
                time.sleep(0.1)
        if not ready:
            print("ERROR: backend never answered /api/ping on %d" % port)
            return 2

        r = subprocess.run(
            [sys.executable, os.path.join(REPO_ROOT, "tools", "record_golden.py"),
             "--check", "--url", "http://127.0.0.1:%d" % port],
            cwd=REPO_ROOT, env=env, capture_output=True, text=True,
            encoding="utf-8", errors="replace")
        print(r.stdout, end="")
        if r.stderr.strip():
            print("[stderr]", r.stderr[-1500:], file=sys.stderr)
        code = r.returncode

        try:
            req = urllib.request.Request("http://127.0.0.1:%d/api/shutdown" % port,
                                         data=b"{}", method="POST",
                                         headers={"Content-Type": "application/json"})
            urllib.request.urlopen(req, timeout=5)
        except Exception:
            pass
        return code
    finally:
        if proc is not None:
            time.sleep(0.2)
            try:
                proc.wait(timeout=5)
            except Exception:
                proc.terminate()
                try:
                    proc.wait(timeout=3)
                except Exception:
                    proc.kill()
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
