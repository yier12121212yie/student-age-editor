# -*- coding: utf-8 -*-
"""波次 2 P3b 黑盒 golden 差分（简报交付项 5）。

复刻 golden_env.py 的录制隔离环境（temp data/workspace、editor_env.json 预写、
EDITOR_PACKS_ROOT/EDITOR_PLUGINS_ROOT 注入、EDITOR_DISABLE_STEAM_DETECT 屏蔽
创意工坊探测、EDITOR_ASSETS_ROOT 指 native/assets），起 backend_wip.exe（现为正树 backend.exe）后逐端点
normalize + compare 与 golden/*.json 比对，10 件：

    api_tools_list_scope_workspace_path_   api_tools_list_scope_mod_path_
    api_ai_domains                         api_ai_settings
    api_resource_packs                     api_plugins_ui_flow_cards
    api_plugins                            api_plugins_ui
    api_plugins_agent_tools                api_manifest_status

外加黑盒 URL 编码沙箱逃逸回归（selftest 同款两例的 TCP 形态）。

用法（仓库根）：
    python native/wip/P3b/smoke.py [--backend native/build/bin/backend.exe]
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
sys.path.insert(0, os.path.join(REPO, "native", "tests", "contract"))
import normalize  # noqa: E402

DEFAULT_BACKEND = os.path.join(REPO, "native", "build", "bin", "backend.exe")

# (golden 文件名, method, path)
CASES = [
    ("api_tools_list_scope_workspace_path_", "GET", "/api/tools/list?scope=workspace&path="),
    ("api_tools_list_scope_mod_path_", "GET", "/api/tools/list?scope=mod&path="),
    ("api_ai_domains", "GET", "/api/ai/domains"),
    ("api_ai_settings", "GET", "/api/ai/settings"),
    ("api_resource_packs", "GET", "/api/resource_packs"),
    ("api_plugins_ui_flow_cards", "GET", "/api/plugins/ui/flow_cards"),
    ("api_plugins", "GET", "/api/plugins"),
    ("api_plugins_ui", "GET", "/api/plugins/ui"),
    ("api_plugins_agent_tools", "GET", "/api/plugins/agent/tools"),
    ("api_manifest_status", "GET", "/api/manifest/status"),
]


def http(method, base, path, body=None, timeout=20):
    data = json.dumps(body).encode("utf-8") if body is not None else None
    req = urllib.request.Request(base + path, data=data, method=method,
                                 headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read().decode("utf-8-sig", "replace"))


def main():
    backend = DEFAULT_BACKEND
    if "--backend" in sys.argv:
        backend = sys.argv[sys.argv.index("--backend") + 1]

    tmp = tempfile.mkdtemp(prefix="p3b_smoke_")
    data_dir = os.path.join(tmp, "data")
    ws_dir = os.path.join(tmp, "workspace")
    os.makedirs(data_dir)
    os.makedirs(ws_dir)
    with open(os.path.join(data_dir, "editor_env.json"), "w", encoding="utf-8") as f:
        json.dump({"workspace_root": ws_dir, "oobe_completed": True}, f,
                  ensure_ascii=False, indent=2)

    env = dict(os.environ)
    env["EDITOR_DATA_ROOT"] = data_dir
    env["EDITOR_PACKS_ROOT"] = os.path.join(data_dir, "resource_packs")
    env["EDITOR_PLUGINS_ROOT"] = os.path.join(data_dir, "plugins")
    env["EDITOR_DISABLE_STEAM_DETECT"] = "1"
    env["EDITOR_ASSETS_ROOT"] = os.path.join(REPO, "native", "assets")
    env.pop("EDITOR_OOBE", None)
    env.pop("EDITOR_NO_OOBE", None)
    pf = os.path.join(tmp, "port.txt")

    print("=== P3b 黑盒 golden 差分（隔离环境：disable-steam + temp data/workspace）===")
    proc = subprocess.Popen([backend, "--port", "0", "--write-port", pf,
                             "--workspace-root", ws_dir],
                            env=env, cwd=REPO,
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        base = None
        deadline = time.time() + 30
        while time.time() < deadline:
            if os.path.exists(pf):
                try:
                    with open(pf) as f:
                        port = int(f.read().strip())
                    if port:
                        base = "http://127.0.0.1:%d" % port
                        break
                except ValueError:
                    pass
            if proc.poll() is not None:
                print("FAIL: backend exited early (code %s)" % proc.returncode)
                return 2
            time.sleep(0.1)
        if base is None:
            print("FAIL: backend did not report a port")
            return 2
        # 就绪轮询
        for _ in range(100):
            try:
                if http("GET", base, "/api/ping")[0] == 200:
                    break
            except Exception:
                time.sleep(0.1)
        else:
            print("FAIL: /api/ping never answered")
            return 2

        failures = []
        for slug, method, path in CASES:
            with open(os.path.join(GOLDEN_DIR, slug + ".json"), encoding="utf-8") as f:
                golden = json.load(f)
            status, body = http(method, base, path)
            actual_env = normalize.normalize({
                "endpoint": path, "method": method, "status": status, "response": body,
            })
            ok, diffs = normalize.compare(
                normalize.normalize(golden), actual_env)
            if ok:
                print("PASS %s  (%s %s)" % (slug, method, path))
            else:
                failures.append(slug)
                print("FAIL %s  (%s %s)" % (slug, method, path))
                for d in diffs[:8]:
                    print("      " + d)

        # URL 编码 / 点分逃逸黑盒回归（selftest 两例的 TCP 形态；%2F 需绕开
        # urllib 规范化，用原始 percent-encoded path 手工发请求）
        for raw_path, tag in [
            ("/api/tools/read?scope=mod&path=..%2F..%2Fetc%2Fpasswd", "url-encoded escape"),
            ("/api/tools/read?scope=mod&path=../../etc/passwd", "dotdot escape"),
        ]:
            req = urllib.request.Request(
                "http://127.0.0.1:%d%s" % (int(open(pf).read().strip()), raw_path),
                method="GET", headers={"Content-Type": "application/json"})
            try:
                with urllib.request.urlopen(req, timeout=20) as resp:
                    code, payload = resp.status, json.loads(resp.read().decode("utf-8"))
            except urllib.error.HTTPError as e:
                code, payload = e.code, json.loads(e.read().decode("utf-8"))
            ok = code == 400 and "escapes" in payload.get("error", "")
            print(("PASS " if ok else "FAIL ") + tag +
                  "  -> %d %s" % (code, payload.get("error", "")))
            if not ok:
                failures.append(tag)

        http("POST", base, "/api/shutdown")
        time.sleep(0.3)
    finally:
        try:
            proc.terminate()
            proc.wait(timeout=5)
        except Exception:
            proc.kill()
        shutil.rmtree(tmp, ignore_errors=True)

    total = len(CASES) + 2
    print("RESULT: %s (%d/%d)" % ("PASS" if not failures else "FAIL: " + ", ".join(failures),
                                  total - len(failures), total))
    return 0 if not failures else 1


if __name__ == "__main__":
    sys.exit(main())
