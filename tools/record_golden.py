# -*- coding: utf-8 -*-
"""golden 契约 --check 门禁（后端 HTTP 只读 GET 端点，对任意实现后端比对）。

用法（仓库根目录）：
    python tools/record_golden.py --check --url URL     # 对运行中的后端（C++ backend）
                                                        # 打同一套 golden，逐端点 PASS/FAIL

无 --url 的录制模式已随 Python 后端退役（W4-5），golden 为冻结契约。
现行门禁入口是 native/tests/contract/golden_gate.py：它自建隔离环境起 C++ 后端、
再调本脚本的 --check --url，退出码 0 == 38/38（隔离配方见其文件头与 golden/README.md）。

隔离要点（全程零写用户真实 Mods/配置；只比 GET，绝不碰有写盘/外联/后台线程副作用的
端点，排除清单见 golden/README.md）：tempfile 独立 data 根 + 独立 workspace +
editor_env.json 预写 + steam 探测打桩。

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


def get_json(base_url, path, timeout=30):
    """GET 一个端点，返回 (status, parsed_body_or_text)。只读，不写盘。

    W4-5 前住在 tools/golden_env.py（已随 Python 后端退役），此处内联保留，
    使 --check --url 门禁路径不再依赖已删除的 Python 后端环境。
    """
    import urllib.error
    import urllib.request
    req = urllib.request.Request(base_url + path, method="GET",
                                 headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read().decode("utf-8")
            try:
                return resp.status, json.loads(raw)
            except ValueError:
                return resp.status, {"_raw": raw}
    except urllib.error.HTTPError as e:
        raw = e.read().decode("utf-8", "replace")
        try:
            return e.code, json.loads(raw)
        except ValueError:
            return e.code, {"_raw": raw}


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

    base_url 给定：直接打外部已在跑的 HTTP 后端（现行门禁：C++ backend）。
    base_url=None：旧的「隔离环境内起进程内 Python 后端」录制模式——W4-5 删除
    Python 后端后已不可用（golden_env.py 一并退役）。保留该分支只为给出清晰报错。
    """
    if not base_url:
        raise SystemExit(
            "错误：无 --url 的录制模式已随 Python 后端退役（W4-5）。\n"
            "golden 是冻结契约，现无可作真相源的参考实现；如需比对请用：\n"
            "  python tools/record_golden.py --check --url http://127.0.0.1:<port>\n"
            "或直接跑 native/tests/contract/golden_gate.py（自建隔离环境起 C++ 后端）。"
        )
    sys.path.insert(0, os.path.join(REPO_ROOT, "native", "tests", "contract"))
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

    _fetch(base_url)
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
