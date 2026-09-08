# -*- coding: utf-8 -*-
"""波次0 golden 契约录制 / --check 门禁（Python 后端 HTTP 只读 GET 端点）。

用法（仓库根目录）：
    python tools/record_golden.py                       # 录制，写 native/tests/contract/golden/*.json
    python tools/record_golden.py --check               # 用当前 Python 后端复跑比对，输出 PASS/FAIL
    python tools/record_golden.py --check --url URL     # 对任意已实现后端（如 C++ backend.exe）
                                                        # 打同一套 golden，逐端点 PASS/FAIL

录制状态固定方式见 tools/golden_env.py（tempfile 独立 data 根 + 独立 workspace +
editor_env.json 预写 + steam 探测打桩），全程零写用户真实 Mods/配置；只录 GET、
绝不录任何有写盘/外联/后台线程副作用的端点（排除清单见 golden/README.md）。

golden 保存前统一过 native/tests/contract/normalize.py 归一化（易变字段/绝对路径
哨兵化），--check 对实测同样归一化后比对。

--url 模式：不起进程、不建隔离环境，直接打给定基址。被测 C++ 后端应在自己的
temp workspace 下启动（backend --port N --workspace-root <temp>），PATH 哨兵化后
两侧路径域一致；未实现端点回 404 {"error":"no route: ..."} 会如实 FAIL——波次
推进的量化进度 = 38 项中的 PASS 数。
"""

import json
import os
import re
import sys

TOOLS_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(TOOLS_DIR)
GOLDEN_DIR = os.path.join(REPO_ROOT, "native", "tests", "contract", "golden")

# (GET 路径) —— 全部只读；带 query 的写全参数保证可复现。
ENDPOINTS = [
    "/api/ping",
    "/api/state",
    "/api/oobe/status",
    "/api/ai/settings",
    "/api/mods",
    "/api/cfg",
    "/api/cfg/EvtCfg",
    "/api/cfg/TalkCfg",
    "/api/cfg/OptionCfg",
    "/api/history?cfg=EvtCfg",
    "/api/cfg_ids?name=EvtCfg",
    "/api/base_ids?cfg=EvtCfg",
    "/api/schema",
    "/api/dicts",
    "/api/effect_suggest?mode=effect&q=",
    "/api/effect_suggest?mode=condition&q=",
    "/api/tools/list?scope=workspace&path=",
    "/api/tools/list?scope=mod&path=",
    "/api/ai/domains",
    "/api/ai/dicts",
    "/api/ai/stage/dicts",
    "/api/ai/stage/roles?talk_id=0",
    "/api/tts/settings",
    "/api/manifest/status",
    "/api/aa/status",
    "/api/aa/keys?q=&limit=20",
    "/api/base/status",
    "/api/base/events",
    "/api/search/talk?q=&limit=5",
    "/api/resource_packs",
    "/api/cloud/providers",
    "/api/cloud/status",
    "/api/cloud/realtime/config",
    "/api/cloud/realtime/status",
    "/api/plugins",
    "/api/plugins/ui",
    "/api/plugins/ui/flow_cards",
    "/api/plugins/agent/tools",
]


def golden_filename(path):
    """/api/cfg/EvtCfg -> api_cfg_EvtCfg.json；query 消毒进文件名。"""
    name = path.lstrip("/")
    name = re.sub(r"[^A-Za-z0-9_.-]+", "_", name)
    return name + ".json"


def capture_all(base_url=None):
    """录全部端点，返回 {filename: envelope}。

    base_url=None：隔离环境内起进程内 Python 后端（录制/自查模式）。
    base_url 给定：直接打外部已在跑的 HTTP 后端（波次门禁：C++ backend.exe）。
    """
    sys.path.insert(0, TOOLS_DIR)
    if os.path.join(REPO_ROOT, "native", "tests", "contract") not in sys.path:
        sys.path.insert(0, os.path.join(REPO_ROOT, "native", "tests", "contract"))
    from golden_env import start_isolated_server, get_json
    import normalize

    out = {}

    def _fetch(url_base):
        for path in ENDPOINTS:
            status, body = get_json(url_base, path)
            envelope = normalize.normalize({
                "endpoint": path,
                "method": "GET",
                "status": status,
                "response": body,
            })
            out[golden_filename(path)] = envelope

    if base_url:
        _fetch(base_url)
        return out
    cm, url_base, _info = start_isolated_server()
    try:
        _fetch(url_base)
    finally:
        cm.__exit__(None, None, None)
    return out


def cmd_record():
    os.makedirs(GOLDEN_DIR, exist_ok=True)
    data = capture_all()
    for fname, envelope in sorted(data.items()):
        with open(os.path.join(GOLDEN_DIR, fname), "w", encoding="utf-8") as f:
            json.dump(envelope, f, ensure_ascii=False, indent=2, sort_keys=True)
            f.write("\n")
    print("recorded %d golden files -> %s" % (len(data), GOLDEN_DIR))
    return 0


def cmd_check(base_url=None):
    if not os.path.isdir(GOLDEN_DIR):
        print("FAIL golden 目录不存在，先运行 python tools/record_golden.py")
        return 1
    sys.path.insert(0, os.path.join(REPO_ROOT, "native", "tests", "contract"))
    import normalize

    recorded = capture_all(base_url)
    expected_files = {golden_filename(p) for p in ENDPOINTS}
    on_disk = {f for f in os.listdir(GOLDEN_DIR) if f.endswith(".json")}

    failures = 0
    for fname in sorted(expected_files):
        gpath = os.path.join(GOLDEN_DIR, fname)
        if not os.path.isfile(gpath):
            print("FAIL %-60s missing golden file" % fname)
            failures += 1
            continue
        with open(gpath, "r", encoding="utf-8") as f:
            golden = normalize.normalize(json.load(f))
        actual = recorded.get(fname)
        ok, diffs = normalize.compare(golden, actual)
        ep = golden.get("endpoint", fname)
        if ok:
            print("PASS %s" % ep)
        else:
            failures += 1
            print("FAIL %s" % ep)
            for d in diffs[:20]:
                print("      " + d)
            if len(diffs) > 20:
                print("      ... (%d diffs total)" % len(diffs))

    extra = sorted(on_disk - expected_files)
    if extra:
        print("note: golden 目录存在录制清单之外的文件: %s" % ", ".join(extra))
    stale = sorted(expected_files - on_disk)
    if stale:
        print("note: 录制清单中的端点无 golden: %s" % ", ".join(stale))

    total = len(expected_files)
    if failures:
        print("RESULT: FAIL (%d/%d 一致, %d 不符)" % (total - failures, total, failures))
        return 1
    print("RESULT: PASS (%d/%d 端点全部一致)" % (total, total))
    return 0


def main(argv):
    url = None
    if "--url" in argv:
        i = argv.index("--url")
        if i + 1 >= len(argv):
            print("FAIL: --url 需要一个基址参数，如 http://127.0.0.1:8765")
            return 2
        url = argv[i + 1].rstrip("/")
        argv = argv[:i] + argv[i + 2:]
    if "--check" in argv:
        return cmd_check(url)
    if url:
        print("FAIL: --url 仅与 --check 组合有意义（golden 是录制真相源，不允许外部后端反写）")
        return 2
    return cmd_record()


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
