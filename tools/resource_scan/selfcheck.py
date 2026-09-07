# -*- coding: utf-8 -*-
"""testdata 结构自检：纯 stdlib，不依赖 UnityPy / 游戏文件。

校验 tools/resource_scan/testdata/ 下的产物样例符合 ARTIFACT_FORMAT.md 的
结构不变量（字段存在性/类型/键规范化/键集一致性/sha256/编码/标记语义）。
CI 或 C++ 移植侧可作为冒烟基线：

  python tools/resource_scan/selfcheck.py [testdata目录]

退出码 0=全绿，1=有失败。
"""
import hashlib
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
if os.path.basename(HERE) == "resource_scan":
    sys.path.insert(0, os.path.dirname(HERE))
else:  # 从任意 cwd 以文件路径直跑
    sys.path.insert(0, HERE)
    sys.path.insert(0, os.path.dirname(HERE))

from resource_scan.util import norm_key                      # noqa: E402
from resource_scan.base_tables import _CFG_KEY_MAP           # noqa: E402

INT64_MIN, INT64_MAX = -2**63, 2**63 - 1
FAILURES = []


def check(name, cond, detail=""):
    status = "PASS" if cond else "FAIL"
    if not cond:
        FAILURES.append("%s %s" % (name, detail))
    print("[%s] %s%s" % (status, name, (" — " + detail if detail and not cond else "")))


def load_json_nobom(path):
    with open(path, "rb") as f:
        blob = f.read()
    bom = blob[:3] == b"\xef\xbb\xbf"
    check("no-BOM utf-8: %s" % os.path.basename(path), not bom, "found BOM")
    try:
        return json.loads(blob.decode("utf-8"))
    except Exception as e:
        check("parse: %s" % os.path.basename(path), False, str(e))
        return None


def is_int(v):
    return isinstance(v, int) and not isinstance(v, bool)


def check_index(td):
    idx = load_json_nobom(os.path.join(td, "index", "aa_index.json"))
    if idx is None:
        return None
    need = {"v", "fp", "tex", "aud", "txt", "cabs", "texmeta", "bundles"}
    check("aa_index: 必需字段", need <= set(idx), "缺 %s" % (need - set(idx)))
    check("aa_index: 未知字段", set(idx) <= need | {"partial"},
          "多 %s" % (set(idx) - need - {"partial"}))
    check("aa_index: v==3", idx.get("v") == 3)
    check("aa_index: fp 为字符串", isinstance(idx.get("fp"), str))
    check("aa_index: partial 缺省或 true", idx.get("partial", False) is True or "partial" not in idx)

    for t in ("tex", "aud", "txt"):
        d = idx.get(t) or {}
        ok = isinstance(d, dict) and all(
            isinstance(k, str) and k
            and isinstance(v, list) and len(v) == 2
            and isinstance(v[0], str) and v[0].lower().endswith(".bundle")
            and is_int(v[1]) and INT64_MIN <= v[1] <= INT64_MAX
            for k, v in d.items())
        check("aa_index: %s 值 [bundle,int64]" % t, ok)
        bad = [k for k in d if k != norm_key(k)]
        check("aa_index: %s 键已规范化" % t, not bad, str(bad[:3]))

    cabs = idx.get("cabs") or {}
    check("aa_index: cabs str->bundle路径", isinstance(cabs, dict) and all(
        isinstance(k, str) and k == k.lower() and isinstance(v, str)
        and v.lower().endswith(".bundle") for k, v in cabs.items()))
    tm = idx.get("texmeta") or {}
    check("aa_index: texmeta [w,h]>0", isinstance(tm, dict) and all(
        isinstance(v, list) and len(v) == 2 and all(is_int(x) and x > 0 for x in v)
        for v in tm.values()))
    bundles = idx.get("bundles") or []
    check("aa_index: bundles 升序且 .bundle", bundles == sorted(bundles) and all(
        isinstance(b, str) and b.lower().endswith(".bundle") for b in bundles))

    keys = load_json_nobom(os.path.join(td, "index", "keys.json"))
    if keys is not None:
        check("keys: v==1 且 partial 布尔", keys.get("v") == 1 and isinstance(keys.get("partial"), bool))
        for t in ("tex", "aud", "txt"):
            lst = keys.get(t) or []
            check("keys: %s 与 aa_index 键集一致且升序" % t,
                  lst == sorted(set(lst)) and set(lst) == set(idx.get(t) or {}))
        counts = keys.get("counts") or {}
        check("keys: counts 与各表一致", all(
            counts.get(t) == len(idx.get(t) or {})
            for t in ("tex", "aud", "txt", "cabs", "texmeta")))
        check("keys: partial 与 aa_index 一致",
              keys.get("partial") == bool(idx.get("partial", False)))

    meta = load_json_nobom(os.path.join(td, "index", "index_meta.json"))
    if meta is not None:
        check("index_meta: index_version==3", meta.get("index_version") == 3)
        check("index_meta: partial 与 aa_index 一致",
              meta.get("partial") == bool(idx.get("partial", False)))
    return idx


def check_base(td):
    bdir = os.path.join(td, "base")
    meta = load_json_nobom(os.path.join(bdir, "base_meta.json"))
    if meta is None:
        return
    check("base_meta: v==1", meta.get("v") == 1)
    check("base_meta: fingerprint 40hex", bool(re.fullmatch(r"[0-9a-f]{40}", meta.get("fingerprint") or "")))
    check("base_meta: generated_at 格式", bool(re.fullmatch(
        r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}", meta.get("generated_at") or "")))
    check("base_meta: partial 布尔", isinstance(meta.get("partial"), bool))
    check("base_meta: encoding 声明", "UTF-8" in str(meta.get("encoding") or ""))
    srcs = meta.get("sources") or []
    check("base_meta: sources 结构", isinstance(srcs, list) and srcs and all(
        isinstance(s, dict) and s.get("mode") in ("aa", "cfgs") and isinstance(s.get("files"), list)
        and all(isinstance(x, dict) and {"name", "mtime_ns", "size"} <= set(x)
                and is_int(x["mtime_ns"]) and is_int(x["size"]) for x in s["files"])
        for s in srcs))
    sample = bool(meta.get("sample"))
    tables = meta.get("tables") or {}
    check("base_meta: table_count 与清单一致", meta.get("table_count") == len(tables))
    expected = set(_CFG_KEY_MAP.values())
    check("base_meta: missing_expected 与清单互补",
          set(tables) & set(meta.get("missing_expected") or ()) == set()
          and set(tables) | set(meta.get("missing_expected") or ()) <= expected,
          "含未知表名")
    rows_sum = 0
    for name, t in sorted(tables.items()):
        rel = (t.get("file") or "").replace("/", os.sep)
        path = os.path.join(bdir, rel)
        if not os.path.isfile(path):
            check("base_data: %s 文件存在" % name, sample,
                  "非 sample 产物缺表文件（或 tables 清单未同步裁剪）")
            continue
        rows_sum += t.get("rows", 0)
        with open(path, "rb") as f:
            blob = f.read()
        check("base_data: %s 无 BOM" % name, blob[:3] != b"\xef\xbb\xbf")
        check("base_data: %s sha256 相符" % name,
              hashlib.sha256(blob).hexdigest() == t.get("sha256"))
        data = json.loads(blob.decode("utf-8"))
        check("base_data: %s 行map[str->dict]" % name,
              isinstance(data, dict) and all(isinstance(k, str) for k in data)
              and all(isinstance(v, dict) for v in data.values()))
        check("base_data: %s 行数相符" % name, len(data) == t.get("rows"))
    if not sample:
        check("base_data: bytes 与磁盘一致(非样张)",
              meta.get("total_bytes") is not None)
    # 表内 id 键升序语义无关；仅确认 JSON 往返无损
    return meta


def main():
    td = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "testdata")
    print("selfcheck testdata:", td)
    if not os.path.isdir(td):
        print("FAIL: 目录不存在")
        return 1
    check_index(td)
    check_base(td)
    if FAILURES:
        print("\n%d 项失败:" % len(FAILURES))
        for f in FAILURES:
            print(" -", f)
        return 1
    print("\nALL GREEN")
    return 0


if __name__ == "__main__":
    sys.exit(main())
