# -*- coding: utf-8 -*-
"""波次 1 差分：同一夹具下，Python 后端与 C++ 后端的 wave-1 端点响应比对
（复用 native/tests/contract/normalize.py 的树等值规则 + 字节级序列化抽查）。

一次性核对脚本（非 golden 库成员）。用法（仓库根）：
    python native/tests/contract/run_cpp_diff.py
"""
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(REPO, "backend"))
import normalize  # noqa: E402

CASES = [
    ("GET", "/api/ping", None),
    ("GET", "/api/state", None),
    ("GET", "/api/mods", None),
    ("GET", "/api/cfg", None),
    ("GET", "/api/cfg/EvtCfg", None),
    ("GET", "/api/cfg/EvtCfg?keys=1", None),
    ("GET", "/api/cfg/EvtCfg?meta=1", None),
    ("GET", "/api/cfg/EvtCfg?prefix=10,20&suffix=3", None),
    ("GET", "/api/cfg/Nope", None),
    ("GET", "/api/history?cfg=EvtCfg", None),
    ("GET", "/api/history", None),
    ("GET", "/api/nope", None),
]

MOD_JSON = {
    "1001": {"id": 1001, "title": "开场", "type": 1},
    "1002": {"id": 1002, "title": "重逢", "type": 2},
    "10": {"id": 10, "title": "旧事件", "type": 1},
    "abc123": {"id": 0, "title": "非数字键", "type": 3},
}

ENTRY_FILE_RE = re.compile(r"^/entries/\d+/file: ")


def make_workspace(tag):
    ws = tempfile.mkdtemp(prefix="cpp_diff_%s_" % tag)
    cfgs = os.path.join(ws, "mod", "Cfgs", "zh-cn")
    os.makedirs(cfgs)
    with open(os.path.join(cfgs, "EvtCfg.json"), "w", encoding="utf-8", newline="") as f:
        json.dump(MOD_JSON, f, ensure_ascii=False, indent=2)
    with open(os.path.join(cfgs, "CustomKeyMap.json"), "w", encoding="utf-8", newline="") as f:
        json.dump({"should": "be excluded"}, f, ensure_ascii=False, indent=2)
    return ws


def http(base, method, path, body=None):
    data = json.dumps(body).encode("utf-8") if body is not None else None
    req = urllib.request.Request(base + path, data=data, method=method,
                                 headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status, json.loads(r.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read().decode("utf-8"))


def start_python(ws):
    os.environ.pop("STUDENT_AGE_BACKEND_URL", None)
    os.environ["EDITOR_DATA_ROOT"] = ws
    from editor.server import httpd, api
    from editor.core import steam_paths
    steam_paths.steam_library_paths = lambda: []
    steam_paths.user_mods_dir = lambda: os.path.join(ws, "_none")
    steam_paths.workshop_mods_roots = lambda: []
    api.STATE.workspace_root = ws
    api._init_state()
    router = api.build_router()
    _t, port = httpd.run_server(router, port=0)
    return port


def start_cpp(ws):
    pf = os.path.join(tempfile.gettempdir(), "cpp_diff_port.txt")
    if os.path.exists(pf):
        os.unlink(pf)
    proc = subprocess.Popen([os.path.join(REPO, "native", "build", "bin", "backend.exe"),
                             "--port", "0", "--write-port", pf, "--workspace-root", ws],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    t0 = time.time()
    while time.time() - t0 < 15:
        if os.path.exists(pf) and open(pf).read().strip():
            break
        time.sleep(0.1)
    port = int(open(pf).read().strip())
    base = "http://127.0.0.1:%d" % port
    for _ in range(100):
        try:
            urllib.request.urlopen(base + "/api/ping", timeout=2)
            break
        except Exception:
            time.sleep(0.1)
    return proc, base


def main():
    ws_py = make_workspace("py")
    base_py = "http://127.0.0.1:%d" % start_python(ws_py)
    ws_cpp = make_workspace("cpp")
    proc, base_cpp = start_cpp(ws_cpp)
    fails = 0
    try:
        # 两侧做同一次全量 PUT：/api/history 在两边同为非空，且验证 PUT 响应契约
        for name, base in (("py", base_py), ("cpp", base_cpp)):
            c, r = http(base, "PUT", "/api/cfg/EvtCfg", {"data": dict(
                MOD_JSON, **{"1003": {"id": 1003, "title": "新事件", "type": 1}})})
            print("%s PUT ->" % name, c, "snapshot=", bool(r.get("snapshot")))
            assert c == 200 and r.get("ok") is True

        # 两侧再做同一次 patch（响应形状 + if_match 冲突路径）
        for name, base in (("py", base_py), ("cpp", base_cpp)):
            c, r = http(base, "PUT", "/api/cfg/EvtCfg",
                        {"patch": {"set": {"2001": {"id": 2001}}, "remove": ["abc123"],
                                   "if_match": {"1001": {"id": 1001, "title": "开场",
                                                         "type": 1}}}})
            print("%s patch ->" % name, c, r.get("applied_set"), r.get("applied_remove"))
            assert c == 200 and r.get("applied_set") == 1 and r.get("applied_remove") == 1
            c, r = http(base, "PUT", "/api/cfg/EvtCfg",
                        {"patch": {"set": {"2001": {"id": 999999}},
                                   "if_match": {"2001": {"id": 999999}}}})
            print("%s conflict ->" % name, c, r.get("reason"), r.get("conflicting_keys"))
            assert c == 200 or (c == 409 and r.get("reason") == "rows")

        for method, path, body in CASES:
            code_py, resp_py = http(base_py, method, path, body)
            code_cpp, resp_cpp = http(base_cpp, method, path, body)
            same, diffs = normalize.compare(normalize.normalize(resp_py),
                                            normalize.normalize(resp_cpp))
            # 快照文件名内嵌落盘毫秒：跨进程必然不同，属预期差异
            if (path.startswith("/api/history?") and diffs
                    and all(ENTRY_FILE_RE.match(d) for d in diffs)):
                same, diffs = True, []
            ok = code_py == code_cpp and same
            fails += 0 if ok else 1
            print("%s %s %s  (py=%d cpp=%d)" % ("OK " if ok else "DIFF", method, path,
                                                code_py, code_cpp))
            for d in diffs[:6]:
                print("      ", d)

        # 撤销/重做契约（两侧行为等价性由 selftest + C++ 测试覆盖，这里比响应形状）
        for name, base in (("py", base_py), ("cpp", base_cpp)):
            c, r = http(base, "POST", "/api/history/undo", {"cfg": "EvtCfg"})
            print("%s undo ->" % name, c, "ok=", r.get("ok"))
            assert c == 200 and r.get("ok") is True
            c, r = http(base, "POST", "/api/history/redo", {"cfg": "EvtCfg"})
            print("%s redo ->" % name, c, "ok=", r.get("ok"))
            assert c == 200 and r.get("ok") is True

        # 字节级序列化比对：全表 GET，掩掉 mtime_ns 后逐字节相等
        raw_py = urllib.request.urlopen(base_py + "/api/cfg/EvtCfg", timeout=10).read()
        raw_cpp = urllib.request.urlopen(base_cpp + "/api/cfg/EvtCfg", timeout=10).read()
        strip = lambda b: re.sub(rb'"mtime_ns": \d+', b'"mtime_ns": <MS>', b)
        if strip(raw_py) == strip(raw_cpp):
            print("OK  byte-level serialization parity (mtime_ns masked)")
        else:
            fails += 1
            print("DIFF byte-level serialization parity")
            print("   py :", strip(raw_py)[:220])
            print("   cpp:", strip(raw_cpp)[:220])
    finally:
        http(base_cpp, "POST", "/api/shutdown", {})
        try:
            proc.wait(timeout=10)
        except Exception:
            proc.kill()
        shutil.rmtree(ws_py, ignore_errors=True)
        shutil.rmtree(ws_cpp, ignore_errors=True)
    print("RESULT:", "PASS" if fails == 0 else "FAIL (%d diffs)" % fails)
    return 0 if fails == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
