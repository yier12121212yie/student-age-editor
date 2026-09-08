# -*- coding: utf-8 -*-
"""波次 2 P3b selftest 白名单（简报交付项 6）。

起 native/build-P3b/bin/backend_wip.exe（隔离 temp data/workspace +
EDITOR_DISABLE_STEAM_DETECT），以外部模式跑 editor.server.selftest 白名单：

    AiUploadTest            （上传附件解析 9 例）
    AiDomainApiTest         （AI 领域 CRUD/校验 15 例）
    BackendApiTest.test_basic_endpoints          （含 /api/tools/list）
    BackendApiTest.test_sandbox_escape_blocked
    BackendApiTest.test_url_encoded_escape_blocked

注：test_basic_endpoints 的 /api/schema /api/dicts（P1 组）与 /api/aa/status
（未落地服务）不在 P3b build 中，落地前该整例在波次 2 的任意单组 build 里都不
可能全绿；脚本逐路径打印，P3b 负责的 /api/tools/list 段必须 200。

用法（仓库根）：
    python native/wip/P3b/run_selftest.py [--backend <exe>] [--strict]
默认：除 test_basic_endpoints 的跨组端点缺失外全部通过即 RESULT: PASS；
--strict 时 basic_endpoints 必须整例绿。
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
BACKEND_DIR = os.path.join(REPO, "backend")
DEFAULT_BACKEND = os.path.join(REPO, "native", "build-P3b", "bin", "backend_wip.exe")

CROSS_GROUP_PATHS = {"/api/schema", "/api/dicts", "/api/aa/status"}


def wait_ready(base, timeout=30):
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            with urllib.request.urlopen(base + "/api/ping", timeout=5) as r:
                if r.status == 200:
                    return True
        except Exception:
            time.sleep(0.1)
    return False


def main():
    backend = DEFAULT_BACKEND
    if "--backend" in sys.argv:
        backend = sys.argv[sys.argv.index("--backend") + 1]
    strict = "--strict" in sys.argv

    tmp = tempfile.mkdtemp(prefix="p3b_selftest_")
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
    # os.environ is what the unittest process (this one) reads via
    # _backend_base_url(); the child backend gets `env`. Forgetting os.environ
    # silently falls back to an in-process PYTHON backend.
    os.environ.pop("STUDENT_AGE_BACKEND_URL", None)
    env.pop("STUDENT_AGE_BACKEND_URL", None)
    pf = os.path.join(tmp, "port.txt")
    print("=== P3b selftest 白名单（外部模式打 build-P3b/bin/backend_wip）===")
    proc = subprocess.Popen([backend, "--port", "0", "--write-port", pf,
                             "--workspace-root", ws_dir],
                            env=env, cwd=REPO,
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    code = 2
    try:
        port = None
        deadline = time.time() + 20
        while time.time() < deadline:
            if os.path.exists(pf):
                try:
                    port = int(open(pf).read().strip())
                    if port:
                        break
                except ValueError:
                    pass
            if proc.poll() is not None:
                print("FAIL: backend exited early")
                return 2
            time.sleep(0.1)
        if not port:
            print("FAIL: no port")
            return 2
        base = "http://127.0.0.1:%d" % port
        if not wait_ready(base):
            print("FAIL: /api/ping timeout")
            return 2
        env["STUDENT_AGE_BACKEND_URL"] = base
        os.environ["STUDENT_AGE_BACKEND_URL"] = base

        sys.path.insert(0, BACKEND_DIR)
        from editor.server import selftest as st  # noqa: E402

        suite = unittest.TestSuite()
        loader = unittest.TestLoader()
        suite.addTests(loader.loadTestsFromTestCase(st.AiUploadTest))
        suite.addTests(loader.loadTestsFromTestCase(st.AiDomainApiTest))
        suite.addTests(loader.loadTestsFromNames([
            "editor.server.selftest.BackendApiTest.test_sandbox_escape_blocked",
            "editor.server.selftest.BackendApiTest.test_url_encoded_escape_blocked",
        ]))
        result = unittest.TextTestRunner(verbosity=2).run(suite)

        # test_basic_endpoints: per-path verdict (cross-group endpoints are
        # allowed missing in a single-group build unless --strict).
        print("\n--- BackendApiTest.test_basic_endpoints 逐路径 ---")
        basic_ok = True
        p3b_ok = True
        for path in ("/api/ping", "/api/state", "/api/mods", "/api/schema",
                     "/api/dicts", "/api/aa/status", "/api/cfg",
                     "/api/tools/list?scope=workspace&path="):
            try:
                with urllib.request.urlopen(base + path, timeout=10) as r:
                    status = r.status
            except Exception as e:
                status = getattr(e, "code", 0)
            cross = path.split("?")[0] in CROSS_GROUP_PATHS
            tag = "cross-group" if cross else "in-scope"
            print("  %-40s -> %s  (%s)" % (path, status, tag))
            if status != 200:
                basic_ok = False
                if not cross:
                    p3b_ok = False
        basic = loader.loadTestsFromNames(
            ["editor.server.selftest.BackendApiTest.test_basic_endpoints"])
        r2 = unittest.TextTestRunner(verbosity=1).run(basic)
        print("  whole-case:", "PASS" if r2.wasSuccessful() else
              "FAIL（跨组端点缺失所致）")

        ok = result.wasSuccessful() and (basic_ok if strict else p3b_ok)
        print("\nRESULT: %s (%d tests, failures=%d errors=%d; tools-scope basic-endpoints %s)"
              % ("PASS" if ok else "FAIL", result.testsRun,
                 len(result.failures), len(result.errors),
                 "PASS" if p3b_ok else "FAIL"))
        code = 0 if ok else 1
        try:
            urllib.request.urlopen(base + "/api/shutdown",
                                   data=b"{}", timeout=5)
        except Exception:
            pass
    finally:
        try:
            proc.terminate()
            proc.wait(timeout=5)
        except Exception:
            proc.kill()
        shutil.rmtree(tmp, ignore_errors=True)
    return code


if __name__ == "__main__":
    sys.exit(main())
