# -*- coding: utf-8 -*-
"""波次 2 P3a 黑盒 golden 差分：/api/search/talk、/api/ai/stage/dicts、
/api/ai/stage/roles?talk_id=0。

隔离环境复刻 golden/README.md §1（与 P2 smoke.py 同思路，用 P2 落地的
EDITOR_DISABLE_STEAM_DETECT 总开关等价录制的 steam_paths 进程内补丁）：

  1. temp <tmp>/data 作 EDITOR_DATA_ROOT、<tmp>/workspace 作工作区（空 ->
     无 mod，对齐 golden 录制环境「base 未加载、空 mod」）；
  2. 预写 <tmp>/data/editor_env.json（workspace_root），清 EDITOR_OOBE/EDITOR_NO_OOBE；
  3. EDITOR_ASSETS_ROOT 指 native/assets（dicts.json 的 game_dicts.roles
     与 api_ai_stage_dicts golden 已验证逐键序全等）。

用法（仓库根）：
    python native/wip/P3a/smoke.py [--backend native/build/bin/backend.exe]
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

# (golden slug, method, path)
CASES = [
    ("api_search_talk_q_limit_5", "GET", "/api/search/talk?q=&limit=5"),
    ("api_ai_stage_dicts", "GET", "/api/ai/stage/dicts"),
    ("api_ai_stage_roles_talk_id_0", "GET", "/api/ai/stage/roles?talk_id=0"),
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

    tmp = tempfile.mkdtemp(prefix="p3a_smoke_")
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

    print("=== P3a 黑盒 golden 差分（隔离环境：空工作区 + 本体未加载）===")
    proc = subprocess.Popen([backend, "--port", "0", "--write-port", pf,
                             "--workspace-root", ws_dir],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                            env=env, cwd=os.path.dirname(backend))
    fails = 0
    base = None  # finally 里防御未就绪
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
            if base:
                http("POST", base, "/api/shutdown", {}, timeout=5)
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
