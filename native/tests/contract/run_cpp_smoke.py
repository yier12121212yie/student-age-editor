# -*- coding: utf-8 -*-
"""波次 1 黑盒门禁：C++ backend 的 selftest 子集 + 40MB 性能证据。

一次性驱动脚本（新增文件，不属于 golden 契约库）：
  1. 在 temp 目录造 workspace + mod（绝不碰真实 Mods，思路同 golden/README.md）；
  2. 起 native/build/bin/backend.exe --port 0 --workspace-root <temp>；
  3. 以 STUDENT_AGE_BACKEND_URL 跑 editor.server.selftest 中
     cfg/history/mods/ping/state/shutdown 相关的用例白名单；
  4. 打 /api/perf 计数器，输出 40MB 冷/热/补丁/补后 四行证据；
  5. POST /api/shutdown 验证进程自退。

用法（仓库根）：
    python native/tests/contract/run_cpp_smoke.py [--backend <exe>]
退出码 0 = 子集全绿 + 性能门槛达标。
"""
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import unittest
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
# selftest.py 的官方运行目录是 backend/（`cd backend && python -m unittest ...`），
# 等价地把 backend 加入 sys.path 以便按模块名加载。
sys.path.insert(0, os.path.abspath(os.path.join(HERE, "..", "..", "..", "backend")))
REPO = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
# Portable builds drop the .exe suffix on Linux/macOS; on Windows this resolves
# to ".exe", so the default path below stays byte-identical to before.
EXE = ".exe" if sys.platform == "win32" else ""
BACKEND_EXE = os.path.join(REPO, "native", "build", "bin", "backend" + EXE)
BACKEND_DIR = os.path.join(REPO, "backend")

# CONVENTIONS 7 准出：40MB benchdata 规格（与 backend/editor/server/benchdata.py 同源）
NUM_ROWS = 98963
TARGET_SIZE = 40_258_490
ROW_TARGET_BYTES = 405

# 白名单：selftest.py 中与波次 1（cfg/history/mods/ping/state/shutdown）直接相关的用例。
# 其余 77 例在波次 2/3 落地前必然 404（原因见脚本末尾清单输出）。
SELFTEST_WHITELIST = [
    "editor.server.selftest.BackendApiTest.test_forbidden_host_rejected",
    "editor.server.selftest.BackendApiTest.test_forbidden_origin_rejected",
    "editor.server.selftest.BackendApiTest.test_local_origin_allowed",
    "editor.server.selftest.BackendApiTest.test_mod_create_title_injection_blocked",
    "editor.server.selftest.BackendApiTest.test_mod_select_root_outside_workspace_blocked",
    "editor.server.selftest.BackendApiTest.test_mod_lifecycle",
]


def _generate_bench_text():
    """benchdata.py 的 C++/Python 同构生成（此处 Python 侧，用于播种夹具）。"""
    def row(row_id):
        key = str(row_id)
        label = '"%s": ' % key
        prefix = '{"id": "%s", "content": "' % key
        suffix = ('", "person": "P%03d", "bg": "BG%02d",'
                  ' "audio": "SE_%03d", "evt_type": 1}' % (row_id % 1000, row_id % 100,
                                                           row_id % 500))
        base_content = (f"这是一个测试对白第{row_id}行的内容，用于模拟真实的"
                        "TalkCfg 数据结构。每一行都应该有足够的长度来模拟实际使用场景中的文本长度。")
        budget = (ROW_TARGET_BYTES - len(label.encode("utf-8"))
                  - len(prefix.encode("utf-8")) - len(suffix.encode("utf-8")))
        content = base_content
        deficit = budget - len(content.encode("utf-8"))
        if deficit > 0:
            content += "x" * deficit
        elif deficit < 0:
            while len(content.encode("utf-8")) > budget:
                content = content[:-1]
            content += "x" * (budget - len(content.encode("utf-8")))
        return label + prefix + content + suffix
    rows = [row(i) for i in range(NUM_ROWS)]
    return "{\n" + ",\n".join(rows) + "\n}"


def http(method, base, path, body=None, headers=None, timeout=30):
    data = None
    if body is not None:
        data = body if isinstance(body, bytes) else json.dumps(body).encode("utf-8")
    req = urllib.request.Request(base + path, data=data, method=method,
                                 headers={"Content-Type": "application/json"})
    for k, v in (headers or {}).items():
        req.add_header(k, v)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read().decode("utf-8"))


def wait_ready(base, deadline=30.0):
    t0 = time.time()
    while time.time() - t0 < deadline:
        try:
            code, _ = http("GET", base, "/api/ping", timeout=2)
            if code == 200:
                return True
        except Exception:
            time.sleep(0.2)
    return False


def main():
    backend = BACKEND_EXE
    if "--backend" in sys.argv:
        backend = sys.argv[sys.argv.index("--backend") + 1]

    ws = tempfile.mkdtemp(prefix="cpp_smoke_ws_")
    pf = os.path.join(tempfile.gettempdir(), "cpp_smoke_port_%d.txt" % os.getpid())
    if os.path.exists(pf):
        os.unlink(pf)
    mod_cfgs = os.path.join(ws, "mod", "Cfgs", "zh-cn")
    os.makedirs(mod_cfgs)

    print("=== 1) 启动 C++ backend（temp workspace，不碰真实 Mods）===")
    print("workspace:", ws)
    proc = subprocess.Popen([backend, "--port", "0", "--write-port", pf,
                             "--workspace-root", ws],
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            cwd=os.path.dirname(os.path.dirname(backend)))
    try:
        t0 = time.time()
        port = ""
        while time.time() - t0 < 15:
            if os.path.exists(pf):
                try:
                    port = open(pf).read().strip()
                    if port:
                        break
                except OSError:
                    pass
            time.sleep(0.1)
        if not port:
            out = proc.stdout.read().decode("utf-8", "replace") if proc.stdout else ""
            print("FAILED: backend 未写出端口。输出：\n" + out)
            proc.kill()
            return 1
        base = "http://127.0.0.1:%s" % port
        print("backend pid=%s port=%s" % (proc.pid, port))
        assert wait_ready(base), "/api/ping 未就绪"
        print("ping:", http("GET", base, "/api/ping")[1])

        print()
        print("=== 2) selftest 波次1 子集（%d 例）===" % len(SELFTEST_WHITELIST))
        env = dict(os.environ)
        env["STUDENT_AGE_BACKEND_URL"] = base
        os.environ["STUDENT_AGE_BACKEND_URL"] = base
        loader = unittest.TestLoader()
        suite = unittest.TestSuite(
            [loader.loadTestsFromName(n) for n in SELFTEST_WHITELIST])
        result = unittest.TextTestRunner(verbosity=2).run(suite)
        subset_ok = result.wasSuccessful()
        print("子集结果: %s (run=%d failures=%d errors=%d)" %
              ("OK" if subset_ok else "FAIL", result.testsRun,
               len(result.failures), len(result.errors)))

        print()
        print("=== 3) 40MB benchdata 性能证据（/api/perf 计数器差分）===")
        text = _generate_bench_text()
        table = os.path.join(mod_cfgs, "TalkCfg.json")
        with open(table, "w", encoding="utf-8", newline="") as f:
            f.write(text)
        size = len(text.encode("utf-8"))
        print("fixture: %s bytes (target %d, %+.2f%%)" %
              (size, TARGET_SIZE, (size - TARGET_SIZE) * 100.0 / TARGET_SIZE))
        assert abs(size - TARGET_SIZE) < TARGET_SIZE * 0.05, "40MB 夹具尺寸超差"

        def perf():
            return http("GET", base, "/api/perf")[1]

        # selftest 子集跑完后模组选中态可能已清空（mod_lifecycle 会删自己的
        # _smoke_test_mod），显式选回夹具模组；首帧 GET 即冷路径
        code_sel, sel = http("POST", base, "/api/mods/select", {"name": "mod"})
        print("select mod ->", code_sel, sel.get("mod", {}).get("name"))
        p = perf()
        cold = p["counters"]
        t0 = time.time()
        code1, body1 = http("GET", base, "/api/cfg/TalkCfg", timeout=60)
        t1 = time.time()
        p1 = perf()
        line1 = ("冷 GET: parses=%d dumps=%d read_bytes=%d | status=%d body=%dB | %.2fs" %
                 (p1["counters"].get("cfg.parses", 0) - cold.get("cfg.parses", 0),
                  p1["counters"].get("cfg.dumps", 0) - cold.get("cfg.dumps", 0),
                  p1["counters"].get("cfg.read_bytes", 0) - cold.get("cfg.read_bytes", 0),
                  code1, len(json.dumps(body1)), t1 - t0))
        print(line1)
        assert p1["counters"].get("cfg.parses", 0) - cold.get("cfg.parses", 0) == 1
        assert p1["counters"].get("cfg.dumps", 0) - cold.get("cfg.dumps", 0) == 1
        assert p1["counters"].get("cfg.read_bytes", 0) - cold.get("cfg.read_bytes", 0) == size
        cold_bytes = urllib.request.urlopen(base + "/api/cfg/TalkCfg", timeout=60).read()

        t0 = time.time()
        hot_bytes = urllib.request.urlopen(base + "/api/cfg/TalkCfg", timeout=60).read()
        t1 = time.time()
        p2 = perf()
        line2 = ("热 GET: Δparses=%d Δdumps=%d Δread_bytes=%d | 响应字节==冷:%s | %.3fs" %
                 (p2["counters"].get("cfg.parses", 0) - p1["counters"].get("cfg.parses", 0),
                  p2["counters"].get("cfg.dumps", 0) - p1["counters"].get("cfg.dumps", 0),
                  p2["counters"].get("cfg.read_bytes", 0) - p1["counters"].get("cfg.read_bytes", 0),
                  hot_bytes == cold_bytes, t1 - t0))
        print(line2)
        assert (p2["counters"].get("cfg.parses", 0) == p1["counters"].get("cfg.parses", 0)
                and p2["counters"].get("cfg.dumps", 0) == p1["counters"].get("cfg.dumps", 0)
                and p2["counters"].get("cfg.read_bytes", 0) == p1["counters"].get("cfg.read_bytes", 0))
        assert hot_bytes == cold_bytes

        w0 = perf()["counters"].get("cfg.writes", 0)
        t0 = time.time()
        code3, patch_body = http("PUT", base, "/api/cfg/TalkCfg",
                                 {"patch": {"set": {"999999": {"id": 999999, "content": "补丁行"}}}},
                                 timeout=120)
        t1 = time.time()
        p3 = perf()
        raw_len = len(json.dumps(patch_body).encode("utf-8"))
        line3 = ("单字段补丁: Δwrites=%d | status=%d 响应=%dB(<2048) applied_set=%s snapshot=%s | %.2fs" %
                 (p3["counters"].get("cfg.writes", 0) - w0, code3, raw_len,
                  patch_body.get("applied_set"), bool(patch_body.get("snapshot")), t1 - t0))
        print(line3)
        assert p3["counters"].get("cfg.writes", 0) - w0 == 1
        assert raw_len < 2048
        assert code3 == 200 and patch_body.get("applied_set") == 1

        p4 = perf()["counters"]
        code5, after = http("GET", base, "/api/cfg/TalkCfg?meta=1", timeout=30)
        p5 = perf()
        line4 = ("补丁后 GET(meta): status=%d count=%d(应=%d) Δparses=%d Δdumps=%d Δread_bytes=%d" %
                 (code5, after["count"], NUM_ROWS + 1,
                  p5["counters"].get("cfg.parses", 0) - p4.get("cfg.parses", 0),
                  p5["counters"].get("cfg.dumps", 0) - p4.get("cfg.dumps", 0),
                  p5["counters"].get("cfg.read_bytes", 0) - p4.get("cfg.read_bytes", 0)))
        print(line4)
        assert after["count"] == NUM_ROWS + 1
        stack_bytes = p5["debug"]["stack_bytes"]
        print("undo 栈驻留文本 stack_bytes = %d（应为 0，A8）" % stack_bytes)
        assert stack_bytes == 0
        perf_ok = True

        print()
        print("=== 4) shutdown 语义（响应先行，进程自退）===")
        code, body = http("POST", base, "/api/shutdown", {}, timeout=10)
        print("POST /api/shutdown ->", code, body)
        deadline = time.time() + 10
        exited = None
        while time.time() < deadline:
            exited = proc.poll()
            if exited is not None:
                break
            time.sleep(0.2)
        print("进程退出码:", exited)
        shutdown_ok = code == 200 and body.get("ok") is True and exited is not None

        print()
        print("=== 结果 ===")
        print("selftest 子集:", "OK" if subset_ok else "FAIL")
        print("40MB 性能门槛:", "OK" if perf_ok else "FAIL")
        print("shutdown 自退:", "OK" if shutdown_ok else "FAIL")
        ok = subset_ok and perf_ok and shutdown_ok
        print("RESULT:", "PASS" if ok else "FAIL")
        return 0 if ok else 1
    finally:
        if proc.poll() is None:
            proc.kill()
        shutil.rmtree(ws, ignore_errors=True)
        if os.path.exists(pf):
            os.unlink(pf)


# 其余 77 例在波次 2 前必然失败/无关的清单（实测：83 例中 56 失败、27 通过）——
# 纯 Python 进程内逻辑用例（BaseServiceLogicTest 4、CloudSyncLogicTest 7、
# GuideRulesLogicTest 8 等，共 21 例）不打 HTTP，外部模式下恒通过，与后端无关；
# 波次 1 白名单 6 例覆盖 cfg/history/mods/ping/state；剩余 56 例全部依赖
# 波次 2+ 端点（当前按契约返回 404 {"error":"no route: ..."}）：
KNOWN_WAVE2_PLUS = [
    ("BackendApiTest.test_basic_endpoints",
     "断言 /api/schema /api/dicts /api/aa/status /api/tools/list 均 200（波次 2/3）"),
    ("BackendApiTest.test_schema_content", "/api/schema 属波次 2（schema 域）"),
    ("BackendApiTest.test_sandbox_escape_blocked + test_url_encoded_escape_blocked",
     "/api/tools/read 沙箱属波次 2（tools 域；错误子串 'escapes' 契约已备好）"),
    ("BackendApiTest.test_guide_validate_and_effect_modes",
     "/api/validate /api/effect_suggest 属波次 2（validate/bugfix 域）"),
    ("StoryAndFixApiTest (6 例)",
     "/api/base/status /api/base/events /api/bugfix/* /api/story/* 属波次 2"),
    ("AiUploadTest (8 例)", "/api/ai/upload* 属波次 4（AI 域）"),
    ("AiDomainApiTest (14 例)", "/api/ai/domains /api/ai/domain/items 属波次 4"),
    ("ImageApiTest (7 例)", "/api/ai/image/* 属波次 4"),
    ("StageApiTest (3 例)", "/api/ai/stage/* 属波次 4"),
    ("AaPreviewTest (4 例) + EventPreviewApiTest (6 例)",
     "/api/aa/* /api/preview/* 属波次 3（Unity 资源走 P6 产物契约）"),
    ("BaseServiceLogicTest(4) / CloudSyncLogicTest(7) / GuideRulesLogicTest(8)",
     "纯 Python 逻辑单测，不经 HTTP，外部模式下恒通过（不计入波次门禁）"),
]

if __name__ == "__main__":
    for name, reason in KNOWN_WAVE2_PLUS:
        print("[skip] %s — %s" % (name, reason))
    sys.exit(main())
