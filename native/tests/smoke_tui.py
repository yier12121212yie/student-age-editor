# -*- coding: utf-8 -*-
"""P8 smoke test (headless, Windows).

Boots the *official* C++ backend (native/build/bin/backend.exe — read-only use)
against a temp data root + a temp workspace containing one synthesized mod, then:

  1. polls /api/ping for readiness,
  2. runs backend_tui.exe --connect to prove the TUI's real client stack
     (ping -> mods -> select -> cfg list -> cfg load) works against the live
     server end to end,
  3. runs backend_tui.exe --render-check all to prove every panel renders and
     assert the key text lines are present.

Isolation recipe mirrors tools/golden_env.py: temp EDITOR_DATA_ROOT / PLUGINS /
PACKS roots, workspace via --workspace-root, EDITOR_DISABLE_STEAM_DETECT=1. Only
ports 8770-8779 are used; only the child PIDs are terminated. Never writes to any
user data root or the game tree.

Exit 0 + "RESULT: PASS" on success.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))           # native/tests
NATIVE = os.path.abspath(os.path.join(HERE, ".."))    # native
BACKEND = os.path.join(NATIVE, "build", "bin", "backend.exe")
TUI = os.path.join(NATIVE, "build", "bin", "backend_tui.exe")
PORTS = [8772, 8773, 8774, 8775]

checks = []


def check(name, cond, detail=""):
    checks.append((name, bool(cond)))
    print(("  PASS  " if cond else "  FAIL  ") + name + (("  | " + detail) if detail else ""))
    return cond


def make_temp_env(root):
    data = os.path.join(root, "data")
    ws = os.path.join(root, "workspace")
    os.makedirs(data)
    mod = os.path.join(ws, "SmokeMod", "Cfgs", "zh-cn")
    os.makedirs(mod)
    with open(os.path.join(ws, "SmokeMod", "manifest.json"), "w", encoding="utf-8") as f:
        json.dump({"title": "SmokeMod", "description": "p8 smoke", "version": "1.0.0"}, f,
                  ensure_ascii=False)
    with open(os.path.join(mod, "TestCfg.json"), "w", encoding="utf-8") as f:
        json.dump({"1": {"text": "你好"}, "2": {"text": "世界"}}, f, ensure_ascii=False)
    env = dict(os.environ)
    env["EDITOR_DATA_ROOT"] = data
    env["EDITOR_PLUGINS_ROOT"] = os.path.join(data, "plugins")
    env["EDITOR_PACKS_ROOT"] = os.path.join(data, "resource_packs")
    env["EDITOR_DISABLE_STEAM_DETECT"] = "1"
    for k in ("EDITOR_OOBE", "EDITOR_NO_OOBE"):
        env.pop(k, None)
    return env, ws


def http_get(url, timeout=2):
    req = urllib.request.Request(url, headers={"Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.status, r.read().decode("utf-8", "replace")


def run(cmd, env=None):
    p = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8",
                       errors="replace", env=env, timeout=60)
    return p.returncode, (p.stdout or "") + (p.stderr or "")


def main():
    if not os.path.exists(BACKEND):
        print("missing backend.exe:", BACKEND)
        return 2
    if not os.path.exists(TUI):
        print("missing backend_tui.exe:", TUI)
        return 2

    root = tempfile.mkdtemp(prefix="p8_smoke_")
    env, ws = make_temp_env(root)
    proc = None
    port = None
    try:
        for candidate in PORTS:
            proc = subprocess.Popen(
                [BACKEND, "--port", str(candidate), "--workspace-root", ws],
                env=env, cwd=NATIVE,
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            deadline = time.time() + 12
            ok = False
            while time.time() < deadline:
                if proc.poll() is not None:
                    break
                try:
                    status, body = http_get("http://127.0.0.1:%d/api/ping" % candidate)
                    if status == 200 and '"ok": true' in body:
                        ok = True
                        break
                except Exception:
                    time.sleep(0.3)
            if ok:
                port = candidate
                break
            if proc.poll() is None:
                proc.terminate()
                proc.wait(timeout=5)
            proc = None
        check("backend.exe ping ready", port is not None, "port=%s" % port)
        if port is None:
            return finish()

        url = "http://127.0.0.1:%d" % port
        rc, out = run([TUI, "--connect", "--url", url], env=env)
        check("tui --connect exit 0", rc == 0, "rc=%d" % rc)
        check("connect reports CONNECT_OK", "CONNECT_OK" in out, out.strip()[:160])
        check("connect sees the smoke mod's table", "first=TestCfg" in out, out.strip()[:160])
        check("connect loaded 2 rows", "rows=2" in out, out.strip()[:160])

        rc2, out2 = run([TUI, "--render-check", "all", "--width", "92", "--height", "22"], env=env)
        check("render-check exit 0", rc2 == 0, "rc=%d" % rc2)
        for token in ("编辑器 TUI", "模组", "表列表", "表格", "Bug 扫描", "AI 助手",
                      "DemoMod", "TalkCfg", "今天下雨了", "引用了不存在的角色"):
            check("render contains %r" % token, token in out2)
        return finish()
    finally:
        if proc is not None and proc.poll() is None:
            try:
                urllib.request.urlopen(
                    urllib.request.Request("http://127.0.0.1:%d/api/shutdown" % port,
                                           data=b"{}", method="POST"), timeout=3).read()
            except Exception:
                pass
            try:
                proc.wait(timeout=5)
            except Exception:
                proc.terminate()
        shutil.rmtree(root, ignore_errors=True)


def finish():
    total = len(checks)
    passed = sum(1 for _, c in checks if c)
    if passed == total:
        print("RESULT: PASS (%d/%d)" % (passed, total))
        return 0
    print("RESULT: FAIL (%d/%d)" % (passed, total))
    return 1


if __name__ == "__main__":
    sys.exit(main())
