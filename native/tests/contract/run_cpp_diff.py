# -*- coding: utf-8 -*-
"""波次 1 差分：同一夹具下，参考后端与本地 C++ 后端的 wave-1 端点响应比对
（复用 native/tests/contract/normalize.py 的树等值规则 + 字节级序列化抽查）。

Python 后端树已随 W4-5 删除，本脚本不再进程内起 Python 参考后端：
    --url <base>   参考后端基址（既有 URL 打点约定不变）；本地仍起 C++ 后端做对照
    无 --url       明确报错退出（提示用 --url 指向运行中的参考后端）
注意：参考后端会被本脚本按既有流程 PUT/patch 写入夹具表（与旧 Python 侧行为一致），
请指向一个一次性/可丢弃的实例，并保证其 workspace 与本地 C++ 侧同构。

一次性核对脚本（非 golden 库成员）。用法（仓库根）：
    python native/tests/contract/run_cpp_diff.py --url http://127.0.0.1:8766
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
# Portable builds drop the .exe suffix on Linux/macOS; on Windows this resolves
# to ".exe", so the default path used in start_cpp() stays byte-identical.
EXE = ".exe" if sys.platform == "win32" else ""
sys.path.insert(0, HERE)
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


def reference_base_url():
    """参考后端基址。Python 后端已移除，只能由外部提供；缺失即报错退出。

    优先级：--url 参数 > STUDENT_AGE_BACKEND_URL 环境变量（与 selftest 外部模式约定一致）。
    """
    argv = sys.argv[1:]
    url = ""
    for i, a in enumerate(argv):
        if a == "--url" and i + 1 < len(argv):
            url = argv[i + 1]
        elif a.startswith("--url="):
            url = a.split("=", 1)[1]
    url = (url or os.environ.get("STUDENT_AGE_BACKEND_URL") or "").strip().rstrip("/")
    if not url:
        print("ERROR: Python 后端已移除，已无法在本进程内启动参考后端；"
              "请用 --url <base>（或 STUDENT_AGE_BACKEND_URL）指向运行中的参考后端"
              "（例如 --url http://127.0.0.1:8766）。", file=sys.stderr)
        return None
    return url


def start_cpp(ws):
    pf = os.path.join(tempfile.gettempdir(), "cpp_diff_port.txt")
    if os.path.exists(pf):
        os.unlink(pf)
    proc = subprocess.Popen([os.path.join(REPO, "native", "build", "bin", "backend" + EXE),
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
    base_ref = reference_base_url()
    if base_ref is None:
        return 2
    ws_cpp = make_workspace("cpp")
    proc, base_cpp = start_cpp(ws_cpp)
    fails = 0
    try:
        # 两侧做同一次全量 PUT：/api/history 在两边同为非空，且验证 PUT 响应契约
        for name, base in (("ref", base_ref), ("cpp", base_cpp)):
            c, r = http(base, "PUT", "/api/cfg/EvtCfg", {"data": dict(
                MOD_JSON, **{"1003": {"id": 1003, "title": "新事件", "type": 1}})})
            print("%s PUT ->" % name, c, "snapshot=", bool(r.get("snapshot")))
            assert c == 200 and r.get("ok") is True

        # 两侧再做同一次 patch（响应形状 + if_match 冲突路径）
        for name, base in (("ref", base_ref), ("cpp", base_cpp)):
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
            code_ref, resp_ref = http(base_ref, method, path, body)
            code_cpp, resp_cpp = http(base_cpp, method, path, body)
            same, diffs = normalize.compare(normalize.normalize(resp_ref),
                                            normalize.normalize(resp_cpp))
            # 快照文件名内嵌落盘毫秒：跨进程必然不同，属预期差异
            if (path.startswith("/api/history?") and diffs
                    and all(ENTRY_FILE_RE.match(d) for d in diffs)):
                same, diffs = True, []
            ok = code_ref == code_cpp and same
            fails += 0 if ok else 1
            print("%s %s %s  (ref=%d cpp=%d)" % ("OK " if ok else "DIFF", method, path,
                                                code_ref, code_cpp))
            for d in diffs[:6]:
                print("      ", d)

        # 撤销/重做契约（两侧行为等价性由 selftest + C++ 测试覆盖，这里比响应形状）
        for name, base in (("ref", base_ref), ("cpp", base_cpp)):
            c, r = http(base, "POST", "/api/history/undo", {"cfg": "EvtCfg"})
            print("%s undo ->" % name, c, "ok=", r.get("ok"))
            assert c == 200 and r.get("ok") is True
            c, r = http(base, "POST", "/api/history/redo", {"cfg": "EvtCfg"})
            print("%s redo ->" % name, c, "ok=", r.get("ok"))
            assert c == 200 and r.get("ok") is True

        # 字节级序列化比对：全表 GET，掩掉 mtime_ns 后逐字节相等
        raw_ref = urllib.request.urlopen(base_ref + "/api/cfg/EvtCfg", timeout=10).read()
        raw_cpp = urllib.request.urlopen(base_cpp + "/api/cfg/EvtCfg", timeout=10).read()
        strip = lambda b: re.sub(rb'"mtime_ns": \d+', b'"mtime_ns": <MS>', b)
        if strip(raw_ref) == strip(raw_cpp):
            print("OK  byte-level serialization parity (mtime_ns masked)")
        else:
            fails += 1
            print("DIFF byte-level serialization parity")
            print("   ref:", strip(raw_ref)[:220])
            print("   cpp:", strip(raw_cpp)[:220])
    finally:
        http(base_cpp, "POST", "/api/shutdown", {})
        try:
            proc.wait(timeout=10)
        except Exception:
            proc.kill()
        shutil.rmtree(ws_cpp, ignore_errors=True)
    print("RESULT:", "PASS" if fails == 0 else "FAIL (%d diffs)" % fails)
    return 0 if fails == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
