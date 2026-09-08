# -*- coding: utf-8 -*-
"""波次 2 P1 黑盒差分：golden 6 例 + 可选 --equiv Python/C++ 语义等价对比。

模式 1（默认，golden 差分）：复刻 golden/README.md §1 的隔离环境（temp data +
temp 空 workspace + EDITOR_DISABLE_STEAM_DETECT=1 + EDITOR_ASSETS_ROOT），用
backend_wip 起服务，逐端点与 native/tests/contract/golden/*.json 过
normalize.normalize + compare。

模式 2（--equiv）：在两份**逐字节相同**的 temp fixture mod 工作区上，分别用
Python 后端（子进程 editor.server.main）与 backend_wip 跑
  POST /api/validate ×3 → POST /api/bugfix/scan → POST /api/bugfix/fix → 磁盘回读，
逐响应对比（remaining 按内容排序后比——Python 的 touched 集合插入序受
PYTHONHASHSEED 影响，非契约部分），并对比修复后 Cfgs/zh-cn 落盘 JSON 树。

用法（仓库根）：
    python native/wip/P1/smoke.py [--backend native/build-P1/bin/backend_wip.exe]
    python native/wip/P1/smoke.py --equiv
退出码 0 = 全部 PASS。
"""
import argparse
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
NATIVE = os.path.abspath(os.path.join(HERE, "..", ".."))
REPO = os.path.abspath(os.path.join(NATIVE, ".."))
GOLDEN_DIR = os.path.join(NATIVE, "tests", "contract", "golden")
sys.path.insert(0, os.path.join(NATIVE, "tests", "contract"))
import normalize  # noqa: E402

BACKEND_DIR = os.path.join(REPO, "backend")
DEFAULT_BACKEND = os.path.join(NATIVE, "build-P1", "bin", "backend_wip.exe")

# (golden 文件名, method, path) —— 简报钉死的 6 份
CASES = [
    ("api_schema", "GET", "/api/schema"),
    ("api_dicts", "GET", "/api/dicts"),
    ("api_cfg_ids_name_EvtCfg", "GET", "/api/cfg_ids?name=EvtCfg"),
    ("api_base_ids_cfg_EvtCfg", "GET", "/api/base_ids?cfg=EvtCfg"),
    ("api_effect_suggest_mode_effect_q_", "GET", "/api/effect_suggest?mode=effect&q="),
    ("api_effect_suggest_mode_condition_q_", "GET", "/api/effect_suggest?mode=condition&q="),
]


def http(method, base, path, body=None, timeout=20):
    data = json.dumps(body, ensure_ascii=False).encode("utf-8") if body is not None else None
    req = urllib.request.Request(base + path, data=data, method=method,
                                 headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read().decode("utf-8"))


def wait_ready(base_tmp_files, proc=None, timeout=25):
    pf, base = base_tmp_files
    t0 = time.time()
    while time.time() - t0 < timeout:
        if proc is not None and proc.poll() is not None:
            raise RuntimeError("backend 进程提前退出 rc=%s" % proc.returncode)
        try:
            if os.path.exists(pf):
                port = open(pf).read().strip()
                if port:
                    b = "http://127.0.0.1:%s" % port
                    http("GET", b, "/api/ping", timeout=2)
                    return b
        except Exception:
            pass
        time.sleep(0.15)
    raise RuntimeError("backend 未在 %ss 内就绪" % timeout)


def shutdown(base):
    try:
        http("POST", base, "/api/shutdown", {}, timeout=5)
    except Exception:
        pass


# ---------------------------------------------------------------------------
# fixture：一份带各类 bug 的 temp mod 工作区
# ---------------------------------------------------------------------------

FIX_FILES = {
    "EvtCfg.json": {
        "1314170": {"id": 1314170, "title": "测试事件", "npc": 8888888,
                    "talkId": [1314170001], "rate": 0.5, "type": 4},
    },
    "TalkCfg.json": {
        "1314170001": {"id": 1314170001, "content": "你好", "option": [1],
                       "nextTalk": [1314170002]},
        "1314170002": {"id": 1314170002, "content": "第二句",
                       "cond": [[1, 1, 999999, 3]], "effect": [2, 2, 1, 50]},
    },
    "OptionCfg.json": {
        "1": {"id": 1, "content": "坏选项"},
        "131417001": {"id": 131417001, "talkId": 5},
    },
    "GiftEvtCfg.json": {
        "1": {"id": 1, "npcId": [3], "condition": [[1, 1, 1, 5]]},
    },
    # 坏表（B16）：扫描跳过 + 如实上报
    "PersonStateCfg.json": "{ broken json",
}

VALIDATE_CALLS = [
    {"cfg": "EvtCfg", "data": {"1314170": {"id": 1314170, "talkId": [1314170001]}}},
    {"cfg": "EvtCfg", "data": {"1314170": {"id": 1314170, "talkId": [9999999999],
                                           "rate": 5, "type": 2, "npc": 0}}},
    {"cfg": "OptionCfg", "data": {"1": {"id": 1, "content": "坏选项"}}},
]


def make_fixture_workspace(ws_dir, mod_name="p1mod"):
    cfg_dir = os.path.join(ws_dir, mod_name, "Cfgs", "zh-cn")
    os.makedirs(cfg_dir)
    for name, content in FIX_FILES.items():
        with open(os.path.join(cfg_dir, name), "w", encoding="utf-8") as f:
            if isinstance(content, str):
                f.write(content)
            else:
                json.dump(content, f, ensure_ascii=False, indent=2)
    return mod_name


def run_semantic_suite(base, mod_name):
    """在已就绪后端上跑 validate/scan/fix 序列，返回可对比的记录。"""
    rec = {"select": http("POST", base, "/api/mods/select", {"name": mod_name})}
    rec["validate"] = [http("POST", base, "/api/validate", b) for b in VALIDATE_CALLS]
    rec["scan"] = http("POST", base, "/api/bugfix/scan", {})
    rec["fix"] = http("POST", base, "/api/bugfix/fix", {})
    return rec


# B16 desc 尾部的解析器错误文本：Python 是 CPython json 的报错
# （"JSONDecodeError: Expecting property name enclosed in double quotes:
# line 1 column 3 (char 2)"），C++ 是 nlohmann 的（"file is not valid JSON"）——
# 该串在波次 1 官方 cfg_cache.cpp 里生成，P1 无权改；比对前把「（非无问题）: 」
# 之后的部分替换成哨兵，desc 前缀契约仍然对比。
PARSER_ERR_RE = __import__("re").compile(r"（非无问题）: .*")


def _canon_desc(d):
    return PARSER_ERR_RE.sub("（非无问题）: <PARSER-ERROR>", d)


def canon_reply(reply):
    """响应归一：status + body；remaining/bugs 列表按内容排序后比。

    Python bugfix/fix 的 touched 是 set（rescan 顺序受 PYTHONHASHSEED 影响），
    「哪些 remaining bug」才是契约，顺序不是——两侧都排序后比。
    """
    status, body = reply
    body = json.loads(json.dumps(body))  # deep copy

    for lst_key in ("remaining", "bugs"):
        if isinstance(body, dict) and isinstance(body.get(lst_key), list):
            for b in body[lst_key]:
                if isinstance(b, dict) and isinstance(b.get("desc"), str):
                    b["desc"] = _canon_desc(b["desc"])

    def sort_bugs(lst):
        return sorted(lst, key=lambda b: json.dumps(b, sort_keys=True, ensure_ascii=False))
    if isinstance(body, dict):
        for k in ("remaining", "bugs", "issues"):
            if isinstance(body.get(k), list):
                body[k] = sort_bugs(body[k])
    return status, body


def disk_snapshot(ws_dir, mod_name):
    cfg_dir = os.path.join(ws_dir, mod_name, "Cfgs", "zh-cn")
    out = {}
    for f in sorted(os.listdir(cfg_dir)):
        if not f.endswith(".json") or f == "CustomKeyMap.json":
            continue
        with open(os.path.join(cfg_dir, f), "r", encoding="utf-8-sig") as fh:
            text = fh.read().strip()
        try:
            out[f] = json.loads(text) if text else {}
        except Exception:
            out[f] = "<UNPARSEABLE>"
    return out


# ---------------------------------------------------------------------------

def start_cpp(backend, tmp, env_extra):
    data_dir = os.path.join(tmp, "cpp_data")
    ws_dir = os.path.join(tmp, "cpp_ws")
    os.makedirs(data_dir)
    os.makedirs(ws_dir)
    with open(os.path.join(data_dir, "editor_env.json"), "w", encoding="utf-8") as f:
        json.dump({"workspace_root": ws_dir, "oobe_completed": True}, f, ensure_ascii=False)
    env = dict(os.environ)
    env.update(env_extra)
    env["EDITOR_DATA_ROOT"] = data_dir
    pf = os.path.join(tmp, "cpp_port.txt")
    proc = subprocess.Popen([backend, "--port", "0", "--write-port", pf,
                             "--workspace-root", ws_dir],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                            env=env, cwd=os.path.dirname(backend))
    base = wait_ready((pf, None), proc)
    return proc, base, ws_dir


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--backend", default=DEFAULT_BACKEND)
    ap.add_argument("--equiv", action="store_true", help="额外跑 Python/C++ 等价对比")
    args = ap.parse_args()

    tmp = tempfile.mkdtemp(prefix="p1_smoke_")
    env_extra = {
        "EDITOR_DISABLE_STEAM_DETECT": "1",
        "EDITOR_ASSETS_ROOT": os.path.join(NATIVE, "assets"),
    }
    fails = 0
    print("=== P1 golden 差分（temp data/workspace + disable-steam + assets 钉死）===")

    # ---------------- 模式 1：golden ----------------
    proc, base, ws_dir = start_cpp(args.backend, os.path.join(tmp, "g"), env_extra)
    try:
        for slug, method, path in CASES:
            with open(os.path.join(GOLDEN_DIR, slug + ".json"), "r", encoding="utf-8") as f:
                golden_env = json.load(f)
            code, body = http(method, base, path)
            actual_env = {"endpoint": golden_env["endpoint"],
                          "method": golden_env["method"],
                          "status": code, "response": body}
            ok, diffs = normalize.compare(normalize.normalize(golden_env),
                                          normalize.normalize(actual_env))
            if ok and code == golden_env["status"]:
                print("PASS %s %s" % (method, path))
            else:
                fails += 1
                print("FAIL %s %s (golden=%d actual=%d)" % (method, path,
                                                            golden_env["status"], code))
                for d in diffs[:8]:
                    print("      ", d)
    finally:
        shutdown(base)
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()

    # ---------------- 模式 2：--equiv ----------------
    if args.equiv:
        print("=== P1 等价对比：Python 后端 vs backend_wip（同构 fixture mod）===")
        etmp = os.path.join(tmp, "e")
        os.makedirs(etmp)
        py = None
        cpp = None
        try:
            # 先铺两份逐字节相同的 fixture 工作区，再起服务（editor_env 指过去）
            ws_a = os.path.join(etmp, "wsA")
            ws_b = os.path.join(etmp, "wsB")
            os.makedirs(ws_a)
            os.makedirs(ws_b)
            make_fixture_workspace(ws_a)
            make_fixture_workspace(ws_b)

            # Python 侧
            py_data = os.path.join(etmp, "py_data2")
            os.makedirs(py_data)
            with open(os.path.join(py_data, "editor_env.json"), "w", encoding="utf-8") as f:
                json.dump({"workspace_root": ws_a, "oobe_completed": True}, f)
            env = dict(os.environ)
            env.update(env_extra)
            env["EDITOR_DATA_ROOT"] = py_data
            env["PYTHONPATH"] = BACKEND_DIR + os.pathsep + env.get("PYTHONPATH", "")
            env["PYTHONIOENCODING"] = "utf-8"
            pf_py = os.path.join(etmp, "py2.txt")
            code = ("import sys; sys.argv = ['x', '--port', '0', '--write-port', %r];"
                    "from editor.server import main; sys.exit(main())" % pf_py)
            py_proc = subprocess.Popen([sys.executable, "-c", code],
                                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                       env=env, cwd=BACKEND_DIR)
            py = py_proc
            py_base = wait_ready((pf_py, None), py_proc)

            # C++ 侧
            cpp_data = os.path.join(etmp, "cpp_data2")
            os.makedirs(cpp_data)
            with open(os.path.join(cpp_data, "editor_env.json"), "w", encoding="utf-8") as f:
                json.dump({"workspace_root": ws_b, "oobe_completed": True}, f)
            env = dict(os.environ)
            env.update(env_extra)
            env["EDITOR_DATA_ROOT"] = cpp_data
            pf_cpp = os.path.join(etmp, "cpp2.txt")
            cpp_proc = subprocess.Popen([args.backend, "--port", "0", "--write-port", pf_cpp,
                                         "--workspace-root", ws_b],
                                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                        env=env, cwd=os.path.dirname(args.backend))
            cpp = cpp_proc
            cpp_base = wait_ready((pf_cpp, None), cpp_proc)

            r_py = run_semantic_suite(py_base, "p1mod")
            r_cpp = run_semantic_suite(cpp_base, "p1mod")
            for name in ("select", "scan", "fix"):
                a, b = r_py[name], r_cpp[name]
                if name == "select":
                    ok = a[0] == b[0] == 200
                    print(("PASS" if ok else "FAIL"), "mods/select", a[0], b[0])
                    fails += 0 if ok else 1
                    continue
                sa, sb = canon_reply(a), canon_reply(b)
                ok, diffs = normalize.compare(normalize.normalize(sa[1]),
                                              normalize.normalize(sb[1]))
                ok = ok and sa[0] == sb[0]
                print(("PASS" if ok else "FAIL"), "bugfix/" + name,
                      "py_status=%d cpp_status=%d" % (sa[0], sb[0]))
                if not ok:
                    fails += 1
                    for d in diffs[:10]:
                        print("      ", d)
            for i, (a, b) in enumerate(zip(r_py["validate"], r_cpp["validate"])):
                ok, diffs = normalize.compare(normalize.normalize(a[1]),
                                              normalize.normalize(b[1]))
                ok = ok and a[0] == b[0]
                print(("PASS" if ok else "FAIL"), "validate[%d]" % i,
                      "py_status=%d cpp_status=%d" % (a[0], b[0]))
                if not ok:
                    fails += 1
                    for d in diffs[:10]:
                        print("      ", d)
            disk_a = disk_snapshot(ws_a, "p1mod")
            disk_b = disk_snapshot(ws_b, "p1mod")
            ok, diffs = normalize.compare(normalize.normalize(disk_a),
                                          normalize.normalize(disk_b))
            print(("PASS" if ok else "FAIL"), "disk after fix")
            if not ok:
                fails += 1
                for d in diffs[:10]:
                    print("      ", d)

            shutdown(py_base)
            shutdown(cpp_base)
        finally:
            for p in (py, cpp):
                if p is not None and p.poll() is None:
                    try:
                        p.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        p.kill()

    shutil.rmtree(tmp, ignore_errors=True)
    print("RESULT:", "PASS" if fails == 0 else "FAIL (%d diffs)" % fails)
    return 0 if fails == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
