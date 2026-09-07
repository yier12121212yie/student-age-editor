# -*- coding: utf-8 -*-
"""resource_scan 共用工具函数。

复制来源（保持行为逐字节一致，backend 原件波次 4 删除后本文件为唯一出处）：
- _norm_key            <- backend/editor/services/unityfs_res.py
- _stat_parts          <- backend/editor/server/base_service.py
- 原子写语义 (tmp + os.replace) <- unityfs_res.UnityFsIndex._save_index /
                                   editor/core/atomic_io.py
"""
import hashlib
import json
import os
import re


def norm_key(name):
    """资源对象名 -> 索引键：去扩展名、去 " #" 后缀、转小写。"""
    return os.path.splitext(name or "")[0].split(" #")[0].strip().lower()


_NON_ALNUM_RE = re.compile(r"[^0-9a-z]+")


def collapse_path(path):
    """路径比较用折叠键：小写后剔除非 [0-9a-z] 字符。

    Addressable bundle 命名里 `-`/`_` 只是分组标点（如 cfgs-zh-hant 对比
    cfgs_assets__），纯字典序会让 `-`(0x2D) < `_`(0x5F) 而把繁体/locale 变体
    排到本体包之前；折叠标点后 "cfgsassets" < "cfgszhhant"，本体胜出。
    索引 first-wins 与 base-tables 贡献序均按 (源目录序, 折叠路径, 原路径)。
    """
    return _NON_ALNUM_RE.sub("", (path or "").lower())


def stat_parts(paths):
    """指纹素材：目录取其顶层文件的 (dir, name, mtime_ns, size)（不递归，
    与 base_service._stat_parts 一致），单文件取 (path, mtime_ns, size)。"""
    parts = []
    for p in paths or []:
        if not p or not os.path.exists(p):
            continue
        if os.path.isdir(p):
            try:
                for f in sorted(os.listdir(p)):
                    fp = os.path.join(p, f)
                    if not os.path.isfile(fp):
                        continue
                    st = os.stat(fp)
                    parts.append((p, f, st.st_mtime_ns, st.st_size))
            except Exception:
                pass
        else:
            try:
                st = os.stat(p)
                parts.append((p, st.st_mtime_ns, st.st_size))
            except Exception:
                pass
    return parts


def fingerprint_from_parts(parts, mode):
    """base_service.BaseDataService._fingerprint 的哈希本体：
    sha1( 每个 stat 元组的 str() utf-8(ignore) 依次 update + mode 字符串 )。
    工具版不含 editor_env.json 项（CLI 无该文件），其余算法逐字一致。"""
    digest = hashlib.sha1()
    for x in parts:
        digest.update(str(x).encode("utf-8", "ignore"))
    digest.update(str(mode).encode("utf-8", "ignore"))
    return digest.hexdigest()


def walk_bundles(dirs, skip_dirs_suffix="_unpacked", skip_role=False):
    """递归收集 *.bundle 绝对路径（跳过 *<skip_dirs_suffix> 目录与 0 字节文件）。
    目录内按文件名排序，多目录按给定顺序拼接——决定索引 first-wins 去重次序。"""
    paths = []
    for d in dirs:
        for root, dirnames, files in os.walk(d):
            dirnames[:] = [x for x in dirnames if not x.endswith(skip_dirs_suffix)]
            for f in sorted(files):
                if not f.lower().endswith(".bundle"):
                    continue
                if skip_role and "_role_" in f:
                    continue
                p = os.path.join(root, f)
                try:
                    if os.path.getsize(p) == 0:
                        continue
                except OSError:
                    continue
                paths.append(p)
    return paths


def write_json_atomic(obj, path):
    """UTF-8 无 BOM、ensure_ascii=False、LF 换行、先 .tmp 后 replace（原子落盘）。"""
    parent = os.path.dirname(os.path.abspath(path))
    os.makedirs(parent, exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8", newline="\n") as f:
        json.dump(obj, f, ensure_ascii=False)
    os.replace(tmp, path)
