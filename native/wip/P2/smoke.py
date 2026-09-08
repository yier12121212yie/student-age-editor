# -*- coding: utf-8 -*-
"""波次 2 P2 黑盒 golden 差分：/api/state /api/mods /api/oobe/status。

复刻 golden/README.md §1「录制状态固定方式」的隔离环境（Python 侧靠进程内
补丁，C++ 侧靠 P2 落地的 EDITOR_DISABLE_STEAM_DETECT 总开关 —— 屏蔽注册表/
libraryfolders.vdf/创意工坊扫描，效果与 steam_library_paths→[] 的 mock 等价）：

  1. temp <tmp>/data 作 EDITOR_DATA_ROOT、<tmp>/workspace 作工作区（--workspace-root）；
  2. 预写 <tmp>/data/editor_env.json（workspace_root + oobe_completed=true），
     使 EditorState 只见空工作区、OOBE 视为已完成；
  3. 清 EDITOR_OOBE / EDITOR_NO_OOBE 宿主环境变量；
  4. EDITOR_ASSETS_ROOT 指 native/assets（schema_count=406 契约）。

随后逐端点 normalize.normalize + normalize.compare 与 golden/*.json 比对。
用法（仓库根）：
    python native/wip/P2/smoke.py [--backend native/build/bin/backend.exe]
退出码 0 = 全部 PASS。
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
GOLDEN_DIR = os.path.join(REPO, "native", "tests", "contract", "golden")
NORMALIZE_DIR = os.path.join(REPO, "native", "tests", "contract")
sys.path.insert(0, NORMALIZE_DIR)
import normalize  # noqa: E402

DEFAULT_BACKEND = os.path.join(REPO, "native", "build", "bin", "backend.exe")

# (golden 文件名, method, path)
CASES = [
    ("api_state", "GET", "/api/state"),
    ("api_mods", "GET", "/api/mods"),
    ("api_oobe_status", "GET", "/api/oobe/status"),
]


def http(method, base, path, body=None, timeout=15):
    data = json.dumps(body).encode("utf-8") if body is not None else None
    req = urllib.request.Request(base + path, data=data, method=method,
                                 headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read().decode("utf-8"))


def main():
    backend = DEFAULT_BACKEND
    if "--backend" in sys.argv:
        backend = sys.argv[sys.argv.index("--backend") + 1]

    tmp = tempfile.mkdtemp(prefix="p2_smoke_")
    data_dir = os.path.join(tmp, "data")
    ws_dir = os.path.join(tmp, "workspace")
    os.makedirs(data_dir)
    os.makedirs(ws_dir)
    with open(os.path.join(data_dir, "editor_env.json"), "w", encoding="utf-8") as f:
        json.dump({"workspace_root": ws_dir, "oobe_completed": True}, f,
                  ensure_ascii=False, indent=2)

    env = dict(os.environ)
    env["EDITOR_DATA_ROOT"] = data_dir
    env["EDITOR_DISABLE_STEAM_DETECT"] = "1"
    env["EDITOR_ASSETS_ROOT"] = os.path.join(REPO, "native", "assets")
    env.pop("EDITOR_OOBE", None)
    env.pop("EDITOR_NO_OOBE", None)
    pf = os.path.join(tmp, "port.txt")

    print("=== P2 黑盒 golden 差分（隔离环境：disable-steam + temp data/workspace）===")
    proc = subprocess.Popen([backend, "--port", "0", "--write-port", pf,
                             "--workspace-root", ws_dir],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                            env=env, cwd=os.path.dirname(backend))
    fails = 0
    try:
        t0 = time.time()
        port = ""
        while time.time() - t0 < 20:
            if os.path.exists(pf):
                try:
                    port = open(pf).read().strip()
                    if port:
                        break
                except OSError:
                    pass
            time.sleep(0.1)
        assert port, "backend 未写出端口"
        base = "http://127.0.0.1:%s" % port
        for _ in range(100):
            try:
                http("GET", base, "/api/ping", timeout=2)
                break
            except Exception:
                time.sleep(0.1)
        print("backend pid=%s port=%s" % (proc.pid, port))

        for slug, method, path in CASES:
            golden_path = os.path.join(GOLDEN_DIR, slug + ".json")
            with open(golden_path, "r", encoding="utf-8") as f:
                golden_env = json.load(f)
            code, body = http(method, base, path)
            actual_env = {"endpoint": golden_env["endpoint"],
                          "method": golden_env["method"],
                          "status": code, "response": body}
            ok, diffs = normalize.compare(normalize.normalize(golden_env),
                                          normalize.normalize(actual_env))
            if ok and code == golden_env["status"]:
                print("PASS %s %s (golden=%d actual=%d)"
                      % (method, path, golden_env["status"], code))
            else:
                fails += 1
                print("FAIL %s %s (golden=%d actual=%d)"
                      % (method, path, golden_env["status"], code))
                for d in diffs[:10]:
                    print("      ", d)
    finally:
        try:
            http("POST", "http://127.0.0.1:%s" % port if port else base,
                 "/api/shutdown", {}, timeout=5)
        except Exception:
            pass
        if proc.poll() is None:
            try:
                proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                proc.kill()
        shutil.rmtree(tmp, ignore_errors=True)
        if os.path.exists(pf):
            os.unlink(pf)
    print("RESULT:", "PASS" if fails == 0 else "FAIL (%d diffs)" % fails)
    return 0 if fails == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
