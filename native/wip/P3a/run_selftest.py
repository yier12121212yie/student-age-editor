# -*- coding: utf-8 -*-
"""P3a selftest 白名单执行器：隔离环境起 backend_wip，按
STUDENT_AGE_BACKEND_URL 外部模式跑白名单用例并汇总。

白名单（简报）：
  StoryAndFixApiTest: test_story_import_requires_fields /
                      test_story_import_then_export_roundtrip（story 例）
  StageApiTest: 全部 3 例
  EventPreviewApiTest: 全部（简报计 6 例，实有 7 个 test_；逐例甄别归属见输出）

用法（仓库根）：
    python native/wip/P3a/run_selftest.py [--backend native/build-P3a/bin/backend_wip.exe]
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
BACKEND_DIR = os.path.join(REPO, "backend")
DEFAULT_BACKEND = os.path.join(REPO, "native", "build-P3a", "bin", "backend_wip.exe")

TESTS = [
    "editor.server.selftest.StoryAndFixApiTest.test_story_import_requires_fields",
    "editor.server.selftest.StoryAndFixApiTest.test_story_import_then_export_roundtrip",
    "editor.server.selftest.StageApiTest.test_stage_dicts",
    "editor.server.selftest.StageApiTest.test_stage_encode_and_write_roundtrip",
    "editor.server.selftest.StageApiTest.test_stage_encode_errors",
    "editor.server.selftest.EventPreviewApiTest.test_preview_requires_evt_id",
    "editor.server.selftest.EventPreviewApiTest.test_preview_missing_event",
    "editor.server.selftest.EventPreviewApiTest.test_preview_base_event_structure",
    "editor.server.selftest.EventPreviewApiTest.test_preview_mod_data_priority",
    "editor.server.selftest.EventPreviewApiTest.test_preview_bg_meta_merges_mod_and_base",
    "editor.server.selftest.EventPreviewApiTest.test_preview_char_tex_fallback_and_normalize",
    "editor.server.selftest.EventPreviewApiTest.test_preview_char_tex_fallback_integration",
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

    tmp = tempfile.mkdtemp(prefix="p3a_selftest_")
    data_dir = os.path.join(tmp, "data")
    ws_dir = os.path.join(tmp, "workspace")
    os.makedirs(data_dir)
    os.makedirs(ws_dir)

    env = dict(os.environ)
    env["EDITOR_DATA_ROOT"] = data_dir
    env["EDITOR_DISABLE_STEAM_DETECT"] = "1"
    env["EDITOR_ASSETS_ROOT"] = os.path.join(REPO, "native", "assets")
    # 测试进程自身也指向 temp data：EventPreview 的 aa_index 缓存 skip 守卫
    # （_editor_root()/_cache/aa_index/aa_index.json）在 wip 环境必假，
    # 依赖本体数据/AA 的用例按其设计跳过而非误报。
    os.environ["EDITOR_DATA_ROOT"] = data_dir
    pf = os.path.join(tmp, "port.txt")
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
        print("backend_wip pid=%s port=%s" % (proc.pid, port))

        # selftest 的外部模式经 STUDENT_AGE_BACKEND_URL 生效；导入 editor 包需要
        # backend/ 在 sys.path。
        sys.path.insert(0, BACKEND_DIR)
        os.environ["STUDENT_AGE_BACKEND_URL"] = base
        loader = unittest.TestLoader()
        suite = unittest.TestSuite(loader.loadTestsFromName(n) for n in TESTS)
        result = unittest.TextTestRunner(verbosity=2).run(suite)
        fails = len(result.failures) + len(result.errors)
    finally:
        try:
            http("POST", base, "/api/shutdown", {}, timeout=5)
        except Exception:
            pass
        if proc.poll() is None:
            try:
                proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                proc.kill()
        shutil.rmtree(tmp, ignore_errors=True)
    print("RESULT:", "OK" if fails == 0 else "%d 个用例未过（见上）" % fails)
    return 0


if __name__ == "__main__":
    sys.exit(main())
