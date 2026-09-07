# -*- coding: utf-8 -*-
"""契约比对归一化器（Python 后端 → C++ 后端 波次0，门禁雏形）。

用途：
  - golden 录制前对响应体做「归一化」，抹掉环境相关/每次运行必变的字段；
  - 比对 golden 与实测响应：JSON 树语义等值（对象 key 序无关、数组有序），
    float 带容差；失败时输出最小差异路径列表（JSON-Pointer 风格）。

规则表为文件顶部显式常量（VOLATILE_KEYS / PATH_KEYS / 路径正则 / float 容差），
来源：对同一份 golden 用独立进程、独立 temp 工作区复跑后，实际会变的位置。

CLI（仅标准库）：
  python normalize.py <golden.json> <actual.json>          # 比对：PASS 退 0，FAIL 退 1
  python normalize.py --normalize <in.json> <out.json>     # 输出归一化后的 JSON
"""

import argparse
import json
import re
import sys

# ---------------------------------------------------------------------------
# 显式规则表（波次0 实测归纳；后续波次新增易变字段时在此登记）
# ---------------------------------------------------------------------------

# float 比较容差：绝对 + 相对（JSON 往返/不同序列化器对 0.7 之类的十进制
# 字面量可能出现 1e-16 级尾差）
FLOAT_ABS_TOL = 1e-6
FLOAT_REL_TOL = 1e-9

# 这些 key 的值每次运行/每台机器必变（时间戳、进程号、端口、缓存代次等），
# 无论类型，归一化为 VOLATILE 哨兵。
#   mtime_ns / mtime    ：/api/cfg/<name> 的文件修改时间纳秒（表存在时）
#   ts / timestamp /    ：通用时间戳键（realtime/cloud 状态等）
#     unix_ms / epoch
#   pid / port          ：进程号 / 动态端口（当前 golden 端点未出现，防御性登记）
#   updated_at / created_at / last_sync / last_check / generated_at：
#     人读时间串（manifest created_at 在响应中为落盘值，录制态固定；登记以防漂移）
VOLATILE_KEYS = frozenset({
    "mtime_ns", "mtime",
    "ts", "timestamp", "unix_ms", "epoch",
    "pid", "port",
    "updated_at", "created_at", "created",
    "last_sync", "last_check", "generated_at", "next_remote_poll",
    "duration_ms", "elapsed_ms", "uptime", "uptime_ms",
})

# 这些 key 的「字符串值 / 列表元素」若形似文件系统绝对路径，替换为 PATH 哨兵。
# 录制使用 tempfile 独立工作区（见 tools/golden_env.py），路径每次必变；
# 真实运行环境路径同理与机器绑定，不属于 API 契约。
#   workspace_root / mod_root / server_workspace / root / dirs / detected：
#     EditorState 与 /api/state /api/mods /api/ping /api/aa/status
#   suggested_workspace / editor_root：/api/oobe/status（含源码 checkout 位置）
#   env_path：/api/base/status 指向 editor_env.json 的绝对路径
#   path：/api/tools/list 回显的相对路径（绝对形态时哨兵化；相对形态保留）
PATH_KEYS = frozenset({
    "workspace_root", "mod_root", "server_workspace", "suggested_workspace",
    "editor_root", "env_path", "detected", "dirs", "aa_dirs", "root", "path",
    "dir", "file", "zip_path", "source_file",
})

# 未列入 PATH_KEYS、但值必然机器相关的绝对路径形态：任意 key 下出现即哨兵化
#（Windows 盘符路径 / UNC；POSIX 绝对路径歧义大——"/api/foo" 之类 URL 路径
#  是真契约内容——故只按 key 名单处理 POSIX）。
ANY_KEY_PATH_PATTERNS = (
    re.compile(r"^[A-Za-z]:[\\/]"),          # C:\ / c:/  盘符绝对路径
    re.compile(r"^\\\\[^\\]+\\?"),           # \\UNC\share
)

# PATH_KEYS 名单内判定「形似绝对路径」：含 Windows 盘符/UNC/POSIX 根，
# 且不是空串、不是纯 URL 端点路径（/api/...）。
ABS_PATH_RE = re.compile(r"^(?:[A-Za-z]:[\\/]|\\\\|/(?!api/)[^/\\\s]+[/\\])")

VOLATILE_SENTINEL = "<VOLATILE>"
PATH_SENTINEL = "<PATH>"

# ---------------------------------------------------------------------------


def _looks_like_abs_path(value):
    return bool(isinstance(value, str) and value and ABS_PATH_RE.match(value))


def _matches_any_key_path(value):
    return bool(isinstance(value, str) and
                any(rx.match(value) for rx in ANY_KEY_PATH_PATTERNS))


def normalize(obj, key=None):
    """返回归一化副本：易变 key 哨兵化、绝对路径哨兵化，其余原样。"""
    if isinstance(obj, dict):
        out = {}
        for k, v in obj.items():
            if k in VOLATILE_KEYS:
                out[k] = VOLATILE_SENTINEL
            else:
                out[k] = normalize(v, k)
        return out
    if isinstance(obj, list):
        return [normalize(item, key) for item in obj]
    if isinstance(obj, str):
        if key in PATH_KEYS and _looks_like_abs_path(obj):
            return PATH_SENTINEL
        if _matches_any_key_path(obj):
            return PATH_SENTINEL
        return obj
    return obj


def _is_number(x):
    return isinstance(x, (int, float)) and not isinstance(x, bool)


def _floats_close(a, b):
    if a == b:
        return True
    tol = FLOAT_ABS_TOL + FLOAT_REL_TOL * max(abs(a), abs(b))
    return abs(a - b) <= tol


def diff_paths(expected, actual, path=""):
    """比较两棵（建议已归一化的）JSON 树，返回最小差异路径列表。

    同一节点一旦判出不匹配即记录该节点路径、不再向下展开（最小差异集）；
    对象 key 序无关；数组有序逐位；bool 与数字互不等；数字带容差。
    """
    diffs = []
    if isinstance(expected, dict) and isinstance(actual, dict):
        missing = sorted(set(expected) - set(actual))
        extra = sorted(set(actual) - set(expected))
        if missing or extra:
            detail = []
            if missing:
                detail.append("missing keys: %s" % ", ".join(missing))
            if extra:
                detail.append("extra keys: %s" % ", ".join(extra))
            diffs.append("%s: {%s}" % (path or "/", "; ".join(detail)))
            return diffs
        for k in expected:
            diffs.extend(diff_paths(expected[k], actual[k], "%s/%s" % (path, k)))
        return diffs

    if isinstance(expected, list) and isinstance(actual, list):
        if len(expected) != len(actual):
            diffs.append("%s: list length %d != %d"
                         % (path or "/", len(expected), len(actual)))
            return diffs
        for i, (e, a) in enumerate(zip(expected, actual)):
            diffs.extend(diff_paths(e, a, "%s/%d" % (path, i)))
        return diffs

    if _is_number(expected) and _is_number(actual):
        if not _floats_close(float(expected), float(actual)):
            diffs.append("%s: %r != %r" % (path or "/", expected, actual))
        return diffs

    if expected is not actual and expected != actual:
        # 类型不同或标量不等：单点报告（不展开）
        te = type(expected).__name__
        ta = type(actual).__name__
        if te != ta:
            diffs.append("%s: type %s(%r) != %s(%r)"
                         % (path or "/", te, expected, ta, actual))
        else:
            diffs.append("%s: %r != %r" % (path or "/", expected, actual))
    return diffs


def compare(golden_obj, actual_obj):
    """比对两棵已归一化的 JSON 树 -> (ok, diffs)。"""
    diffs = diff_paths(golden_obj, actual_obj)
    return (not diffs), diffs


def load_normalized(path):
    with open(path, "r", encoding="utf-8") as f:
        return normalize(json.load(f))


def main(argv=None):
    ap = argparse.ArgumentParser(description="契约 JSON 归一化 / 比对（PASS 退 0）")
    ap.add_argument("--normalize", action="store_true",
                    help="仅归一化输入并写出，不做比对")
    ap.add_argument("src", help="golden.json（比对模式）或输入 JSON（--normalize）")
    ap.add_argument("dst", nargs="?",
                    help="实测 JSON（比对模式）或输出 JSON（--normalize）")
    args = ap.parse_args(argv)

    if args.normalize:
        if not args.dst:
            ap.error("--normalize 需要输出路径")
        with open(args.src, "r", encoding="utf-8") as f:
            data = json.load(f)
        with open(args.dst, "w", encoding="utf-8") as f:
            json.dump(normalize(data), f, ensure_ascii=False, indent=2,
                      sort_keys=True)
            f.write("\n")
        print("normalized -> %s" % args.dst)
        return 0

    if not args.dst:
        ap.error("需要两个 JSON 文件：golden 与 actual")
    golden = load_normalized(args.src)
    actual = load_normalized(args.dst)
    ok, diffs = compare(golden, actual)
    if ok:
        print("PASS %s == %s" % (args.src, args.dst))
        return 0
    print("FAIL %s vs %s：%d 处差异" % (args.src, args.dst, len(diffs)))
    limit = 50
    for d in diffs[:limit]:
        print("  " + d)
    if len(diffs) > limit:
        print("  ...（另 %d 处省略）" % (len(diffs) - limit))
    return 1


if __name__ == "__main__":
    sys.exit(main())
