# -*- coding: utf-8 -*-
"""AA bundle 扫描引擎与 v3 索引产出。

改造自 backend/editor/services/unityfs_res.py（UnityFsIndex._collect_env /
_collect_cabs / _tex_size / _index_bundle_batch / _run_pool），差异：
- 零 editor 包依赖；UnityPy 仅扫描时需要（读产物不需要）。
- 合并次序确定化：first-wins 去重按 (源目录序, 折叠路径, 原路径) 升序
  （util.collapse_path 剔除标点，使本体包 cfgs_assets 排在 cfgs-zh-hant 前；
  backend 原实现按进程桶合并，跨桶重复键的胜者随 --jobs 变化，本工具修正为
  确定序且优先命中语言中性包，单键值语义不变）。
- --limit 采样：只处理排序后前 n 个 bundle，产物顶层标 "partial": true。
- bundles 语义与 backend 一致 = 已尝试（含解析失败）的 bundle 集合。
"""
import datetime
import os
import sys
from concurrent.futures import ProcessPoolExecutor

try:
    from .util import norm_key, collapse_path
except ImportError:  # 以脚本方式直跑时的回退（正常入口为 python -m resource_scan）
    from util import norm_key, collapse_path

# 与 unityfs_res.CACHE_VERSION 一致：v3 = tex/aud/txt 值 [bundle, path_id] + cabs + texmeta
CACHE_VERSION = 3
_SLOW_TAG = "_role_"


def now_iso():
    return datetime.datetime.now().strftime("%Y-%m-%dT%H:%M:%S")


# ------------------------------------------------------------------ 采集 ----
# _collect_cabs / _tex_size / _collect_env 与 unityfs_res.py 逐句对齐


def _collect_cabs(env, bundle_path, out):
    """bundle 内所有 SerializedFile 的 CAB 名 -> bundle 路径 映射（跨包解码依赖用）。"""
    for f in env.files.values():
        for sf in (f.get_assets() if hasattr(f, "get_assets") else []):
            name = (getattr(sf, "name", "") or "").lower()
            if name:
                out.setdefault(name, bundle_path)


def _tex_size(obj):
    """读 Texture2D/Sprite 头部取宽高（不解码像素）；失败返回 None。"""
    try:
        o = obj.read()
        w = int(getattr(o, "m_Width", 0) or 0)
        h = int(getattr(o, "m_Height", 0) or 0)
        if w > 0 and h > 0:
            return [w, h]
    except Exception:
        pass
    return None


def _collect_env(env, bundle_path, tex, aud, txt, texmeta=None):
    """从 env 收集纹理/音频/文本键；texmeta 记录新 tex 键的 [w, h]（CG 判定信号）。"""
    for obj in env.objects:
        obj_type = obj.type.name
        if obj_type not in ("Texture2D", "Sprite", "AudioClip", "TextAsset"):
            continue
        try:
            name = obj.peek_name() or ""
        except Exception:
            try:
                name = obj.read().m_Name or ""
            except Exception:
                continue
        if not name:
            continue
        key = norm_key(name)
        if not key:
            continue
        if obj_type == "AudioClip":
            if key not in aud:
                aud[key] = [bundle_path, obj.path_id]
        elif obj_type == "TextAsset":
            if key not in txt:
                txt[key] = [bundle_path, obj.path_id]
        elif key not in tex:
            tex[key] = [bundle_path, obj.path_id]
            if texmeta is not None:
                size = _tex_size(obj)
                if size:
                    texmeta[key] = size


# ---------------------------------------------------------------- worker ----


def _scan_bundle_batch(args):
    """进程池 worker。args=(paths, mode)；返回 [(bundle, payload, err), ...]。

    mode='full'   payload={'tex','aud','txt','cabs','texmeta'}，值 [bundle, path_id]
    mode='texts'  payload={'texts'}，cfg_key -> TextAsset 原始 utf-8 字节
    """
    paths, mode = args
    import UnityPy
    results = []
    for bundle_path in paths:
        try:
            env = UnityPy.load(bundle_path)
        except Exception as e:
            results.append((bundle_path, None, "load failed: %s" % e))
            continue
        try:
            if mode == "texts":
                if __package__:
                    from .base_tables import extract_cfg_texts
                else:
                    from base_tables import extract_cfg_texts
                payload = {"texts": extract_cfg_texts(env, bundle_path)}
            else:
                tex, aud, txt, cabs, texmeta = {}, {}, {}, {}, {}
                _collect_env(env, bundle_path, tex, aud, txt, texmeta)
                _collect_cabs(env, bundle_path, cabs)
                payload = {"tex": tex, "aud": aud, "txt": txt,
                           "cabs": cabs, "texmeta": texmeta}
            results.append((bundle_path, payload, ""))
        except Exception as e:
            results.append((bundle_path, None, "collect failed: %s" % e))
    return results


# ---------------------------------------------------------------- 驱动 ----


def _bucket_paths(paths, jobs):
    """按体积降序贪心均衡分桶（同 backend._run_pool 思路），桶内小包在前先出。"""
    jobs = max(1, min(jobs, len(paths))) if paths else 1
    try:
        big_first = sorted(paths, key=os.path.getsize, reverse=True)
    except OSError:
        big_first = list(paths)
    buckets = [[] for _ in range(jobs)]
    sums = [0] * jobs
    for p in big_first:
        try:
            size = os.path.getsize(p)
        except OSError:
            size = 0
        i = sums.index(min(sums))
        buckets[i].append(p)
        sums[i] += size
    out = []
    for b in buckets:
        if b:
            b.reverse()  # 小包先完成，进度更早可见
            out.append(b)
    return out


def _iter_pool(batches, jobs, mode):
    """并行执行批次；进程池不可用时回退串行。产出按提交序，合并前再全局排序。"""
    payloads = [(b, mode) for b in batches]
    if jobs <= 1 or len(payloads) <= 1:
        for p in payloads:
            yield _scan_bundle_batch(p)
        return
    try:
        with ProcessPoolExecutor(max_workers=min(jobs, len(payloads))) as pool:
            for r in pool.map(_scan_bundle_batch, payloads):
                yield r
    except Exception as e:
        sys.stderr.write("[warn] process pool unavailable (%s)，回退串行\n" % e)
        for p in payloads:
            yield _scan_bundle_batch(p)


def default_order(path):
    """无源信息时的合并次序键：(折叠路径, 原路径)。"""
    return (collapse_path(path), path)


class ScanResult(object):
    """确定性合并结果：各表 first-wins，次序 = 调用方给定的 order_key 升序。"""

    def __init__(self, mode="full"):
        self.mode = mode
        self.tex = {}
        self.aud = {}
        self.txt = {}
        self.cabs = {}
        self.texmeta = {}
        self.texts = {}      # mode='texts': bundle_path -> {cfg_key: bytes}
        self.bundles = set()  # 已尝试（含失败）bundle，backend 同语义
        self.errors = []      # [(bundle, error)]，失败不计入 bundles
        self.done = 0
        self.total = 0

    def merge(self, bundle_path, payload, err):
        if err:
            self.errors.append((bundle_path, err))
            return
        self.bundles.add(bundle_path)
        if self.mode == "texts":
            # 按 bundle 分桶保留全部来源；跨包同名键**不去重**——
            # base-tables 逐表按贡献序 dict.update 合并（含 DLC 行），
            # 若在这里按键 setdefault，会被排序靠前的繁体/副本包遮蔽本体内容。
            dst = self.texts.setdefault(bundle_path, {})
            for k, v in (payload.get("texts") or {}).items():
                dst.setdefault(k, v)  # 仅同包内重名 first-wins（对齐 _collect_env）
        else:
            for k, v in (payload.get("tex") or {}).items():
                self.tex.setdefault(k, v)
            for k, v in (payload.get("aud") or {}).items():
                self.aud.setdefault(k, v)
            for k, v in (payload.get("txt") or {}).items():
                self.txt.setdefault(k, v)
            for k, v in (payload.get("cabs") or {}).items():
                self.cabs.setdefault(k, v)
            for k, v in (payload.get("texmeta") or {}).items():
                self.texmeta.setdefault(k, v)
        self.done += 1


def scan_bundles(paths, jobs=2, mode="full", progress=None, order_key=None):
    """扫描 bundle 列表并确定性合并。

    完成序不定（并行）-> 先收齐各 bundle 结果，再按 order_key（默认
    (折叠路径, 原路径)）排序合并，因此产物与 --jobs、磁盘速度无关。
    paths 传 (path, src_idx) 元组列表时可由调用方自定义 order_key 闭包。
    全失败/部分失败见 ScanResult.errors。
    """
    order_key = order_key or default_order
    paths = sorted(set(paths), key=order_key)
    scan = ScanResult(mode)
    scan.total = len(paths)
    if not paths:
        return scan
    batches = _bucket_paths(paths, jobs)
    per_bundle = {}
    finished = 0
    for results in _iter_pool(batches, jobs, mode):
        for tup in results:
            per_bundle[tup[0]] = tup
        finished += len(results)
        if progress:
            progress(min(finished, len(paths)), len(paths))
    for p in sorted(per_bundle, key=order_key):
        bundle_path, payload, err = per_bundle[p]
        scan.merge(bundle_path, payload, err)
    return scan


def build_v3_payload(scan, partial):
    """v3 aa_index.json 字典（逐字段兼容 backend _cache/aa_index/aa_index.json）。"""
    payload = {
        "v": CACHE_VERSION,
        "fp": "",                # backend 在 aa 模式下恒为空串（不传 fingerprint）
        "tex": {k: scan.tex[k] for k in sorted(scan.tex)},
        "aud": {k: scan.aud[k] for k in sorted(scan.aud)},
        "txt": {k: scan.txt[k] for k in sorted(scan.txt)},
        "cabs": {k: scan.cabs[k] for k in sorted(scan.cabs)},
        "texmeta": {k: scan.texmeta[k] for k in sorted(scan.texmeta)},
        "bundles": sorted(scan.bundles),
    }
    if partial:
        payload["partial"] = True  # 采样产物额外键；backend v3 读取端忽略未知键
    return payload
