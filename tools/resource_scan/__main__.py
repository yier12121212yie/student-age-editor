# -*- coding: utf-8 -*-
"""resource_scan CLI。

用法（在 editor/tools 目录下）：
  py -m resource_scan index --aa <aa目录>... --out <目录> [--jobs N] [--limit n]
  py -m resource_scan base-tables --aa <aa目录|Cfgs目录>... --out <目录>
        [--jobs N] [--limit n] [--bundle-name-filter s] [--from-index aa_index.json]
  py -m resource_scan decoded-pack [-- 参数...]       # 进程内调用 decoded_export.py

依赖：index / base-tables / decoded-pack（bundle 模式）需要 UnityPy：
  py -m pip install --user unitypy
产物格式契约：见本目录 ARTIFACT_FORMAT.md（C++ 后端消费方对接文档）。
"""
import argparse
import json
import os
import subprocess
import sys
import time

try:
    from .util import (walk_bundles, write_json_atomic, stat_parts,
                       fingerprint_from_parts, collapse_path)
    from .aa_index import (scan_bundles, build_v3_payload, default_order,
                           CACHE_VERSION, now_iso)
    from .base_tables import (read_cfg_dir, merge_contributions, write_artifacts,
                              is_lang_bad, _match_prefix)
    from . import TOOL_VERSION
except ImportError:  # python resource_scan/__main__.py 直跑回退
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    from util import (walk_bundles, write_json_atomic, stat_parts,
                      fingerprint_from_parts, collapse_path)
    from aa_index import (scan_bundles, build_v3_payload, default_order,
                          CACHE_VERSION, now_iso)
    from base_tables import (read_cfg_dir, merge_contributions, write_artifacts,
                             is_lang_bad, _match_prefix)
    from __init__ import TOOL_VERSION

_HAS_UNITYPY = True
try:
    import UnityPy  # noqa: F401
except ImportError:
    _HAS_UNITYPY = False


def _need_unitypy(cmd):
    if not _HAS_UNITYPY:
        sys.stderr.write(
            "错误：子命令 %s（bundle 模式）需要 UnityPy。安装：py -m pip install --user unitypy\n"
            % cmd)
        return 2
    return 0


def _has_bundles(d):
    """目录（递归）内是否存在 *.bundle。"""
    for _root, dirs, files in os.walk(d):
        dirs[:] = [x for x in dirs if not x.endswith("_unpacked")]
        if any(f.lower().endswith(".bundle") for f in files):
            return True
    return False


def _rel(p, root):
    try:
        return os.path.relpath(p, root).replace("\\", "/")
    except ValueError:
        return p


def _ordered_bundle_paths(dirs, skip_role=False):
    """按 (源目录序, 折叠路径, 原路径) 生成确定性 bundle 次序与 order_key 闭包。"""
    src_of = {}
    for i, d in enumerate(dirs):
        for p in walk_bundles([d], skip_role=skip_role):
            src_of[p] = i

    def order_key(p):
        return (src_of.get(p, len(dirs)),) + default_order(p)
    return sorted(src_of, key=order_key), order_key


def _source_stats(d):
    """base_meta.sources[].files：顶层文件指纹素材（不递归，对齐 base_service._stat_parts）。"""
    files = []
    if os.path.isdir(d):
        for f in sorted(os.listdir(d)):
            fp = os.path.join(d, f)
            if not os.path.isfile(fp):
                continue
            st = os.stat(fp)
            files.append({"name": f, "mtime_ns": st.st_mtime_ns, "size": st.st_size})
    elif os.path.isfile(d):
        st = os.stat(d)
        files.append({"name": os.path.basename(d), "mtime_ns": st.st_mtime_ns,
                      "size": st.st_size})
    return files


# ---------------------------------------------------------------- index ----


def cmd_index(args):
    rc = _need_unitypy("index")
    if rc:
        return rc
    dirs = [d for d in args.aa if os.path.isdir(d)]
    if not dirs:
        sys.stderr.write("错误：--aa 需指向存在的 Addressables 根目录（将递归找 *.bundle）。\n")
        return 2
    paths, order_key = _ordered_bundle_paths(dirs, skip_role=args.skip_slow)
    total_found = len(paths)
    partial = bool(args.limit) and args.limit < total_found
    if args.limit:
        paths = paths[:args.limit]
    print("== resource_scan index v%d ==" % CACHE_VERSION)
    print("bundle 数: %d%s（--jobs=%d）"
          % (len(paths), "，采样自 %d（partial）" % total_found if partial else "", args.jobs))
    t0 = time.time()

    def progress(done, total):
        sys.stdout.write("\r  扫描 %d/%d" % (done, total))
        sys.stdout.flush()

    scan = scan_bundles(paths, jobs=args.jobs, mode="full", progress=progress,
                        order_key=order_key)
    print("\r  扫描完成 %d/%d（%.1fs）      " % (scan.done, scan.total, time.time() - t0))
    for bundle, err in scan.errors:
        sys.stderr.write("[warn] %s: %s\n" % (bundle, err))

    payload = build_v3_payload(scan, partial)
    counts = {"tex": len(payload["tex"]), "aud": len(payload["aud"]),
              "txt": len(payload["txt"]), "cabs": len(payload["cabs"]),
              "texmeta": len(payload["texmeta"])}
    out_dir = args.out
    index_path = os.path.join(out_dir, "aa_index.json")
    write_json_atomic(payload, index_path)

    write_json_atomic({
        "v": 1,
        "partial": bool(partial),
        "generated_at": now_iso(),
        "tool": "resource_scan/%s" % TOOL_VERSION,
        "sources": list(dirs),
        "bundles_scanned": scan.done,
        "bundles_failed": [{"bundle": b, "error": e} for b, e in scan.errors],
        "counts": counts,
        "tex": sorted(payload["tex"]),
        "aud": sorted(payload["aud"]),
        "txt": sorted(payload["txt"]),
    }, os.path.join(out_dir, "keys.json"))

    write_json_atomic({
        "v": 1,
        "index_version": CACHE_VERSION,
        "partial": bool(partial),
        "generated_at": now_iso(),
        "tool": "resource_scan/%s" % TOOL_VERSION,
        "aa_dirs": dirs,
        "skip_slow": bool(args.skip_slow),
        "limit": args.limit or 0,
        "jobs": args.jobs,
        "bundles_total_found": total_found,
        "bundles_scanned": scan.done,
        "elapsed_sec": round(time.time() - t0, 1),
        "counts": counts,
        "errors": [{"bundle": b, "error": e} for b, e in scan.errors],
    }, os.path.join(out_dir, "index_meta.json"))
    print("产物: %s (%.1f MB), keys.json, index_meta.json"
          % (index_path, os.path.getsize(index_path) / 1048576.0))
    print("键数: tex=%d aud=%d txt=%d cabs=%d texmeta=%d bundles=%d"
          % (counts["tex"], counts["aud"], counts["txt"],
             counts["cabs"], counts["texmeta"], len(payload["bundles"])))
    return 0


# ---------------------------------------------------------- base-tables ----


_bund_cache = {}


def _locate_bundle(aa_dirs, bundle_name):
    """按文件名在 aa 目录中重定位 bundle（索引内路径过期场景，
    对齐 decoded_export._remap_bundles）。"""
    key = bundle_name.lower()
    if key in _bund_cache:
        return _bund_cache[key]
    hit = None
    for d in aa_dirs:
        for root, dirs, files in os.walk(d):
            dirs[:] = [x for x in dirs if not x.endswith("_unpacked")]
            if bundle_name in files:
                hit = os.path.join(root, bundle_name)
                break
        if hit:
            break
    _bund_cache[key] = hit
    return hit


def cmd_base_tables(args):
    srcs = [d for d in args.aa if os.path.isdir(d)]
    if not srcs:
        sys.stderr.write("错误：--aa 需指向存在的目录（aa 根 / bundle 目录 / 解包 Cfgs 目录）。")
        return 2
    bundle_srcs, dir_srcs = [], []
    for d in srcs:
        (bundle_srcs if _has_bundles(d) else dir_srcs).append(d)
    if bundle_srcs:
        rc = _need_unitypy("base-tables")
        if rc:
            return rc

    contributions = []  # [(label, {key: content}), ...] 顺序即合并覆盖顺序
    errors = []
    t0 = time.time()
    partial = False
    scanned = failed = 0

    if bundle_srcs:
        all_paths, order_key = _ordered_bundle_paths(bundle_srcs)
        if args.from_index:
            with open(args.from_index, "r", encoding="utf-8-sig") as f:
                idx = json.load(f)
            want = {k: v for k, v in (idx.get("txt") or {}).items()
                    if not is_lang_bad(k) and _match_prefix(k)}
            picked = set()
            for k in sorted(want):
                p = want[k][0]
                if not os.path.isfile(p):
                    p = _locate_bundle(bundle_srcs, os.path.basename(want[k][0]))
                if p:
                    picked.add(p)
                else:
                    errors.append("[from-index] 定位失败: %s" % want[k][0])
            paths = [p for p in all_paths if p in picked]
            print("== resource_scan base-tables（--from-index：%d 候选键 → %d bundle）=="
                  % (len(want), len(paths)))
        else:
            paths = all_paths
            if args.bundle_name_filter:
                toks = [t.lower() for t in args.bundle_name_filter]
                paths = [p for p in paths
                         if any(t in os.path.basename(p).lower() for t in toks)]
        total_found = len(paths)
        partial = bool(args.limit) and args.limit < total_found
        if args.limit:
            paths = paths[:args.limit]
        print("== 待扫 bundle %d/%d%s（--jobs=%d）=="
              % (len(paths), total_found,
                 "，采样 partial" if partial else "", args.jobs))
        scan = scan_bundles(paths, jobs=args.jobs, mode="texts",
                            progress=lambda d, t: (
                                sys.stdout.write("\r  bundle %d/%d" % (d, t)),
                                sys.stdout.flush()),
                            order_key=order_key)
        print("\r  bundle 完成 %-6d（%.1fs）        " % (scan.done, time.time() - t0))
        scanned, failed = scan.done, len(scan.errors)
        for bundle, err in scan.errors:
            errors.append("[%s] %s" % (bundle, err))
        # scan.texts: bundle_path -> {key: bytes}，插入序即合并次序（确定性）
        for bundle_path, keymap in scan.texts.items():
            if not keymap:
                continue
            label = _rel(bundle_path, bundle_srcs[0]) \
                if len(bundle_srcs) == 1 else bundle_path
            contributions.append((label, keymap))

    for d in dir_srcs:
        got = False
        for cand in [d] + [os.path.join(d, *sub.split("/")) for sub in
                           ("TextAsset", "Cfgs/zh-cn", "Cfgs/DLC_zh-cn",
                            "Cfgs", "zh-cn", "DLC_zh-cn")]:
            if not os.path.isdir(cand):
                continue
            contents = read_cfg_dir(cand)
            if contents:
                print("== Cfgs 目录 %s：%d 个表文件 ==" % (cand, len(contents)))
                contributions.append((cand, contents))
                got = True
        if not got:
            errors.append("[dir] %s 无可读表文件（既无 bundle 也无 *.json/*.txt）" % d)

    tables, origins = merge_contributions(contributions, errors)
    if not tables:
        sys.stderr.write("错误：未导出任何配置表。\n")
        for e in errors:
            sys.stderr.write("  %s\n" % e)
        return 1
    parts = []
    for d in srcs:
        parts.extend(stat_parts([d]))
    meta = write_artifacts(args.out, tables, origins, {
        "partial": bool(partial),
        "sources": [{"path": d,
                     "mode": "aa" if _has_bundles(d) else "cfgs",
                     "files": _source_stats(d)} for d in srcs],
        # 指纹 = sha1(各源目录顶层 stat 元组 str() + mode 标签)，
        # 算法与 base_service.BaseDataService._fingerprint 的哈希本体一致
        # （工具无 editor_env.json，不含 backend studio 模式里的该项）。
        "fingerprint": fingerprint_from_parts(
            parts, "aa" if bundle_srcs else "studio"),
        "bundles_scanned": scanned,
        "bundles_failed": failed,
        "contributions": [label for label, _ in contributions],
        "limit": args.limit or 0,
        "bundle_name_filter": list(args.bundle_name_filter or []),
        "jobs": args.jobs,
        "elapsed_sec": round(time.time() - t0, 1),
        "errors": errors,
    })
    print("产物: %s（%d 表，%.2f MB）+ base_meta.json"
          % (os.path.join(args.out, "base_data"),
             meta["table_count"], meta["total_bytes"] / 1048576.0))
    if meta["missing_expected"]:
        print("缺失预期表: %s" % ", ".join(meta["missing_expected"]))
    for e in errors[:10]:
        sys.stderr.write("[warn] %s\n" % e)
    return 0


# -------------------------------------------------------- decoded-pack ----


def cmd_decoded_pack(args):
    """预解码资源包导出：进程内调用本目录 decoded_export.py（零 editor 依赖）。

    历史写法 `decoded-pack -- <参数>` 保留：argparse REMAINDER 会把分隔符
    `--` 一并收进 passthrough，这里剥掉首个 `--`（同时兼容不写分隔符的直接
    写法，修复旧透传把裸 `--` 传给被包装脚本导致参数报错的缺陷）。
    `--script` 仍作为逃生口指向外部实现脚本（subprocess 透传）。
    """
    passthrough = list(args.passthrough or [])
    while passthrough and passthrough[0] == "--":
        passthrough.pop(0)
    if args.script:
        if not os.path.isfile(args.script):
            sys.stderr.write("错误：--script 指向的文件不存在: %s\n" % args.script)
            return 2
        cmd = [sys.executable, args.script] + passthrough
        print("$", " ".join(cmd))
        return subprocess.run(cmd, check=False).returncode
    try:
        from . import decoded_export
    except ImportError:  # python resource_scan/__main__.py 直跑
        import decoded_export
    if args.show_help:
        decoded_export.build_parser().print_help()
        print("\n[resource_scan decoded-pack] 进程内调用 tools/resource_scan/decoded_export.py"
              "（参数用 `-- ` 分隔或直接跟在子命令后）。常用：--out dist/bundled_preview.zip "
              "--tier preview|full --max-side 1600 --quality 80 --limit N "
              "--no-audios --no-zip；索引覆盖 --index/--aa-dir/--cache-dir。")
        return 0
    try:
        return decoded_export.main(passthrough)
    except SystemExit as e:  # argparse 的 --help/-h 或 SystemExit("消息")
        if e.code is None:
            return 0
        if isinstance(e.code, int):
            return e.code
        sys.stderr.write("%s\n" % e.code)
        return 2


# ------------------------------------------------------------------ CLI ----


def build_parser():
    ap = argparse.ArgumentParser(
        prog="resource_scan",
        description="StudentAge Unity 资源解析命令行工具（产物契约见 ARTIFACT_FORMAT.md）")
    ap.add_argument("--version", action="version", version="resource_scan " + TOOL_VERSION)
    sub = ap.add_subparsers(dest="command", required=True)

    p = sub.add_parser("index", help="扫描 AA bundle → aa_index.json(v3) + keys.json")
    p.add_argument("--aa", nargs="+", required=True, metavar="DIR",
                   help="Addressables 根目录（递归找 *.bundle），可多个")
    p.add_argument("--out", required=True, help="产物目录")
    p.add_argument("--jobs", type=int, default=2,
                   help="并行进程数（默认 2；4GB 大包建议 ≤4 控内存）")
    p.add_argument("--limit", type=int, default=0, metavar="N",
                   help="采样：只处理排序后前 N 个 bundle，产物标 partial=true")
    p.add_argument("--skip-slow", action="store_true",
                   help="跳过文件名含 _role_ 的大包（对齐 backend 默认 scan 行为）")
    p.set_defaults(func=cmd_index)

    p = sub.add_parser("base-tables",
                       help="原版配置表 → base_data/<Table>.json + base_meta.json")
    p.add_argument("--aa", nargs="+", required=True, metavar="SRC",
                   help="aa 根目录 / bundle 目录 / 游戏 Cfgs(zh-cn) 目录；多个按序合并（后者覆盖同行 id）")
    p.add_argument("--out", required=True, help="产物目录")
    p.add_argument("--jobs", type=int, default=2)
    p.add_argument("--limit", type=int, default=0, metavar="N",
                   help="采样：只处理前 N 个 bundle（表集可能不全，标 partial）")
    p.add_argument("--bundle-name-filter", nargs="+", metavar="SUB",
                   help="只打开文件名含任一子串的 bundle（本体表实测全在 cfgs_assets__*.bundle，"
                        "DLC 在 dlc_cfgs_assets__*.bundle）")
    p.add_argument("--from-index", metavar="AA_INDEX_JSON",
                   help="复用 index 产物 aa_index.json 的 txt 定位，只开含表候选的 bundle")
    p.set_defaults(func=cmd_base_tables)

    p = sub.add_parser(
        "decoded-pack",
        help="预解码资源包导出（参数可放在 -- 之后）",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        description="预解码资源包导出：进程内调用 tools/resource_scan/decoded_export.py，\n"
                    "零 backend/editor 依赖。写法：py -m resource_scan decoded-pack -- "
                    "<参数...>\n"
                    "看完整参数：py -m resource_scan decoded-pack --show-help")
    p.add_argument("--script", help="覆盖实现脚本路径（逃生口，subprocess 透传）")
    p.add_argument("--show-help", action="store_true",
                   help="显示 decoded-pack 的完整参数后退出")
    p.add_argument("passthrough", nargs=argparse.REMAINDER,
                   help="decoded_export 的参数（置于 -- 之后，或直接跟在子命令后）")
    p.set_defaults(func=cmd_decoded_pack)
    return ap


def main(argv=None):
    ap = build_parser()
    args = ap.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
