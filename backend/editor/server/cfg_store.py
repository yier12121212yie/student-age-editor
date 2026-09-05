# -*- coding: utf-8 -*-
"""配置表统一写入口：冲突检测 + 历史快照 + 原子写 + 撤销/重做 + 增量补丁。

背景：此前 api._save_mod_cfg / api.cfg_write / ai_domain_service.save_cfg /
tts_store.register_audio_cfg / cli.utils.save_cfg 各自内联实现「tmp + os.replace」
原子写，误覆盖外部改动（游戏 / 其他设备 / 云同步回写）时无从察觉，也没有
误操作兜底。本模块把写入链路收敛为一个入口：

    write_cfg(abs_path, data, expect_mtime_ns=..., expect_digest=..., ...)
      1) 冲突检测：优先 sha1 摘要（expect_digest，Windows mtime 粒度 ~15.6ms
         同刻度外部改动会被 mtime 比较漏过），缺失才退回 expect_mtime_ns；
         不一致时拒绝写入，返回磁盘当前内容（供前端弹「文件已被外部修改」）；
      2) 内容未变：序列化结果与磁盘字节全等时不快照、不写盘、不动 undo 栈；
      3) 历史快照：覆盖已有文件前，把旧内容**原始字节**存入
         <mod根>/.editor_history/，每表滚动保留最近 HISTORY_KEEP 份；
      4) 原子写：editor.core.atomic_io（临时文件 + fsync + os.replace +
         WinError 5/32 瞬时占用重试），源文件带 BOM 则原样保留；
      5) undo/redo 栈：有磁盘快照的条目只存快照名（不存整表文本），
         快照失败/被调用方关闭时才退回内存文本。

    apply_patch(abs_path, set=..., remove=..., if_match=...)：增量补丁写入，
    逐行 if_match 深比对，冲突返回 {conflicting_keys} 不回全表。

    undo(abs_path) / redo(abs_path)：撤销 / 重做最近一次写入。
    list_history(abs_path)：列出该表的磁盘历史快照（新 → 旧）。

并发模型：磁盘 IO 在**按路径** RLock 下进行（不同表互不阻塞），
全局 _STACK_LOCK 只保护内存栈登记本身。

零第三方依赖；只依赖标准库与 editor.core.atomic_io / editor.server.perf。
"""
import copy
import hashlib
import json
import os
import threading
import time

from editor.core import atomic_io
from editor.core.atomic_io import BOM
from editor.server import perf

# 历史快照目录名（相对 Mod 根；云同步 / 实时同步按名字排除）
HISTORY_DIR = ".editor_history"
# undo/redo 内存栈上限：超出丢最旧
HISTORY_LIMIT = 50
# 磁盘快照每表滚动保留上限（50 份 × 40MB ≈ 2GB 磁盘，故独立于 HISTORY_LIMIT）。
# 被修剪掉的快照对应的 undo 条目会安全失败（见 undo 内「history snapshot missing」），
# 可撤销深度在磁盘层面缩短为 HISTORY_KEEP——设计取舍，不是缺陷。
HISTORY_KEEP = 10

_STACK_LOCK = threading.RLock()   # 只护 _STACKS / _PATH_LOCKS 注册表
# {normcase(abspath): {"undo": [entry], "redo": [entry]}}
# entry = {"snap": 快照文件名或 None, "text": 退回文本或 None, "existed": 写入前文件是否存在}
# undo 栈顶 = 最近一次写入的「写入前状态」；redo 栈顶 = 最近一次撤销的「被撤销状态」。
_STACKS = {}
_PATH_LOCKS = {}                  # {normcase(abspath): threading.RLock}

# S1 解析缓存钩子：api 层注册 fn(abs_path) -> (data, lossy, mtime_ns) | None，
# apply_patch 命中时零读盘零解析。cfg_store 不 import api（避免循环依赖）。
_PARSE_PROVIDER = None


def set_parse_provider(fn):
    """注册解析缓存提供者（api._load_table_cached 的缓存视图）。幂等。"""
    global _PARSE_PROVIDER
    if fn is None or _PARSE_PROVIDER is not fn:
        _PARSE_PROVIDER = fn


def _path_key(abs_path):
    """Windows 盘符大小写不敏感：栈与按路径锁统一按 normcase 归一。"""
    return os.path.normcase(os.path.abspath(abs_path))


def _path_lock(key):
    with _STACK_LOCK:
        lock = _PATH_LOCKS.get(key)
        if lock is None:
            lock = _PATH_LOCKS[key] = threading.RLock()
        return lock


def _stacks_entry(key):
    with _STACK_LOCK:
        return _STACKS.setdefault(key, {"undo": [], "redo": []})


def _read_text_from(raw):
    """raw bytes → lenient 文本（utf-8-sig，解码失败按 replace 容错）；raw 为 None 返回 None。"""
    if raw is None:
        return None
    try:
        return raw.decode("utf-8-sig")
    except UnicodeDecodeError:
        return raw.decode("utf-8-sig", errors="replace")


def read_raw(abs_path):
    """唯一读盘口：返回文件原始字节；缺失/IO 失败返回 None。"""
    try:
        with open(abs_path, "rb") as f:
            return f.read()
    except OSError:
        return None


def read_lossy(abs_path):
    """一次读盘拿到 (raw, text, lossy)。

    lossy=True 表示字节不是合法 UTF-8（外部 GBK/ANSI 工具或半截写入），
    text 中的非 ASCII 已是 U+FFFD 占位——调用方写回前必须检查（B2）。
    文件缺失返回 (None, None, False)。
    """
    raw = read_raw(abs_path)
    if raw is None:
        return None, None, False
    try:
        return raw, raw.decode("utf-8-sig"), False
    except UnicodeDecodeError:
        return raw, raw.decode("utf-8-sig", errors="replace"), True


def _read_text(path):
    """utf-8-sig 容错读取文本（兼容外部工具写出的 BOM 文件）；读取失败返回 None。

    绝不返回 None 表示「解码失败」——undo 栈用 None 表示「文件原本不存在」，
    解码失败走 replace 容错，不能让 undo 把文件当不存在删掉。
    """
    return _read_text_from(read_raw(path))


def _parse_json_text(text):
    """lenient 文本 → JSON dict；空内容返回 {}，解析失败返回 None。"""
    if text is None:
        return None
    try:
        data = json.loads(text.strip() or "{}")
    except (ValueError, TypeError):
        return None
    return data if isinstance(data, dict) else None


def _mod_root_of(abs_path):
    """从配置表绝对路径推导 Mod 根目录。

    适配两种布局：<mod>/Cfgs/zh-cn/<name>.json（逐级三层）与
    <mod>/Cfgs/<name>.json（逐级两层）；其余按两层兜底。
    """
    d = os.path.dirname(os.path.abspath(abs_path))
    if os.path.basename(d).lower() == "zh-cn":
        d = os.path.dirname(d)
    return os.path.dirname(d)


def _cfg_stem(abs_path):
    """EvtCfg.json -> EvtCfg（快照文件名前缀 / list_history 过滤用）。"""
    base = os.path.basename(abs_path)
    if base.endswith(".json"):
        base = base[:-5]
    return base


def _history_dir(abs_path):
    return os.path.join(_mod_root_of(abs_path), HISTORY_DIR)


def _history_entries(hdir, stem):
    """该表名下全部快照文件名（按 ts 升序）；目录不可读返回 []。"""
    prefix = stem + "_"
    try:
        names = os.listdir(hdir)
    except OSError:
        return []
    out = []
    for name in names:
        if not name.startswith(prefix) or not name.endswith(".json"):
            continue
        tail = name[len(prefix):-5]
        try:
            ts = int(tail.split("_")[0])
        except (IndexError, ValueError):
            ts = 0
        out.append((ts, name))
    out.sort()
    return out


def _write_snapshot(abs_path, raw):
    """把旧文件原始字节（保留 BOM）写入 .editor_history/<stem>_<ms>_<seq>.json。

    raw 由调用方在唯一一次读盘时取得（A7：一次保存只读一遍文件）。
    目录不存在则创建。返回快照文件名；写入失败返回 None（不阻塞写入）。
    """
    hdir = _history_dir(abs_path)
    stem = _cfg_stem(abs_path)
    ms = int(time.time() * 1000)
    seq = 0
    while True:  # 同一毫秒内多次写入时以序号避让重名
        name = "%s_%d_%d.json" % (stem, ms, seq)
        snap_path = os.path.join(hdir, name)
        if not os.path.exists(snap_path):
            break
        seq += 1
    try:
        atomic_io.write_bytes_atomic(snap_path, raw)
    except OSError:
        return None
    perf.bump("cfg.snapshots_written")
    perf.bump("cfg.snapshot_bytes", len(raw))
    return name


def _prune_history(abs_path):
    """A9：每表滚动只保留最近 HISTORY_KEEP 份快照，删除更旧的。"""
    hdir = _history_dir(abs_path)
    entries = _history_entries(hdir, _cfg_stem(abs_path))
    for _ts, name in entries[:-HISTORY_KEEP] if len(entries) > HISTORY_KEEP else []:
        try:
            os.unlink(os.path.join(hdir, name))
        except OSError:
            pass


def _stat_mtime_ns(abs_path):
    try:
        return os.stat(abs_path).st_mtime_ns
    except OSError:
        return None


def _serialize(data):
    """统一序列化（与 api 响应同参数：ensure_ascii=False + indent=2）。"""
    return json.dumps(data, ensure_ascii=False, indent=2)


def _encode_with_bom(text, had_bom):
    """B5：源文件带 BOM 则写回时原样保留（快照路径已保 BOM，写路径不再丢）。"""
    raw = text.encode("utf-8")
    if had_bom:
        raw = BOM + raw
    return raw


def _commit(abs_path, data, *, raw, lossy, expect_mtime_ns=None,
            expect_digest=None, force=False, snapshot=True):
    """写入管线（调用方已持有按路径锁）：

    冲突检测 → 序列化 → 内容未变短路 → 快照 → 原子写 → undo 登记 → 快照修剪。
    raw/lossy 为调用方在唯一一次读盘中取得的旧文件状态（raw=None 表示文件不存在）。
    """
    exists = raw is not None
    cur_mtime = _stat_mtime_ns(abs_path) if exists else None
    # ① 冲突检测：优先 sha1 摘要（B6：mtime 同刻度漏检），缺失才退回 mtime
    if not force and exists:
        if expect_digest is not None:
            if hashlib.sha1(raw).hexdigest() != expect_digest:
                return {"ok": False, "conflict": True, "reason": "digest",
                        "mtime_ns": cur_mtime, "lossy": lossy,
                        "data": _parse_json_text(_read_text_from(raw))}
        elif (expect_mtime_ns is not None and cur_mtime is not None
                and cur_mtime != expect_mtime_ns):
            return {"ok": False, "conflict": True, "reason": "mtime",
                    "mtime_ns": cur_mtime, "lossy": lossy,
                    "data": _parse_json_text(_read_text_from(raw))}
    # ② 序列化 + BOM 保留
    had_bom = raw[:3] == BOM if exists else False
    new_bytes = _encode_with_bom(_serialize(data), had_bom)
    # ③ 内容未变：不快照、不写盘、不动 undo 栈
    if exists and new_bytes == raw:
        return {"ok": True, "mtime_ns": cur_mtime, "snapshot": None,
                "unchanged": True, "lossy": lossy}
    # ④ 历史快照：仅对「覆盖已有文件」记录旧内容原始字节
    snap_name = None
    if exists and snapshot:
        snap_name = _write_snapshot(abs_path, raw)
    # ⑤ 原子写（瞬时占用重试在 atomic_io 内）
    try:
        atomic_io.write_bytes_atomic(abs_path, new_bytes)
    except OSError as e:
        return {"ok": False, "error": "写入失败: %s" % e, "lossy": lossy}
    perf.bump("cfg.writes")
    perf.bump("cfg.write_bytes", len(new_bytes))
    new_mtime = _stat_mtime_ns(abs_path)
    # ⑥ undo 栈：有磁盘快照的条目不存整表文本（A8，50 项 × 40MB ≈ 2GB 常驻）；
    #    快照缺失/被关闭时退回内存文本兜底，否则 undo 无从恢复
    entry = _stacks_entry(_path_key(abs_path))
    with _STACK_LOCK:
        entry["undo"].append({"snap": snap_name,
                              "text": None if snap_name else _read_text_from(raw),
                              "existed": exists,
                              # 文本兜底恢复所需：BOM 补回 + lossy 源拒绝恢复
                              "had_bom": had_bom,
                              "lossy": lossy})
        del entry["undo"][:-HISTORY_LIMIT]
        entry["redo"].clear()
    # ⑦ 磁盘快照滚动修剪（A9）
    if snap_name:
        _prune_history(abs_path)
    return {"ok": True, "mtime_ns": new_mtime, "snapshot": snap_name,
            "unchanged": False, "lossy": lossy}


def write_cfg(abs_path, data, *, expect_mtime_ns=None, expect_digest=None,
              force=False, snapshot=True):
    """统一写入口。返回 dict：

    - 冲突：{"ok": False, "conflict": True, "reason": "digest"|"mtime",
             "mtime_ns": 磁盘当前, "data": 磁盘当前内容, "lossy": bool}
    - 成功：{"ok": True, "mtime_ns": 新 stat, "snapshot": 快照文件名或 None,
             "unchanged": 内容未变未写盘, "lossy": bool}
    - 失败：{"ok": False, "error": ...}
    """
    abs_path = os.path.abspath(abs_path)
    key = _path_key(abs_path)
    with _path_lock(key):
        raw, old_text, lossy = read_lossy(abs_path)  # 唯一一次读盘（A7）
        return _commit(abs_path, data, raw=raw, lossy=lossy,
                       expect_mtime_ns=expect_mtime_ns,
                       expect_digest=expect_digest, force=force,
                       snapshot=snapshot)


def apply_patch(abs_path, *, set=None, remove=None, if_match=None,
                expect_mtime_ns=None, expect_digest=None, force=False):
    """增量补丁写入（S2/S3 契约：PUT body 以 patch 字段判别后路由到这里）。

    - set: {key: value} 逐行写入（值深拷贝，避免污染 S1 解析缓存对象）
    - remove: [key, ...] 逐行删除
    - if_match: {key: 期望值} 逐行深比对（乐观锁的行级部分）；
      不一致的 key 收进 conflicting_keys，冲突返回**不回全表 data**
    - expect_mtime_ns / expect_digest: 表级乐观锁，语义同 write_cfg
      （表级冲突返回磁盘当前 data，供 409 三选 UI 展示）

    返回 dict 同 write_cfg，成功多带 applied 计数与 data（合并后全表，
    仅供 api 层刷新内存缓存，不进 HTTP 响应）。
    """
    abs_path = os.path.abspath(abs_path)
    key = _path_key(abs_path)
    with _path_lock(key):
        data = None
        # ① 取当前数据：优先 S1 解析缓存（省 40MB 级 JSON 解析），退回本地 lenient 读
        provider = _PARSE_PROVIDER
        if provider is not None:
            try:
                cached = provider(abs_path)
            except Exception:
                cached = None
            if cached is not None:
                data, _cache_lossy, _mtime = cached
        # raw 一律读盘取得：_commit 以 raw=None 判定「文件不存在」，且依赖
        # raw 做表级冲突检测、BOM 保留、历史快照与 undo 登记——这些语义
        # 只认磁盘字节，缓存命中仅免除解析，不免除这次读取
        raw, old_text, lossy = read_lossy(abs_path)
        if data is None:
            data = _parse_json_text(old_text)
            if data is None:
                data = {}
        data = dict(data)  # 浅拷贝顶层：只替换/删除顶层键，内层值从不原地改
        # ② 行级乐观锁：if_match 深比对（Python == 即 JSON 值深比较）
        conflicts = []
        if if_match:
            for k, expected in if_match.items():
                if k not in data or data[k] != expected:
                    conflicts.append(k)
        cur_mtime = _stat_mtime_ns(abs_path)
        if conflicts and not force:
            return {"ok": False, "conflict": True, "reason": "rows",
                    "conflicting_keys": conflicts, "mtime_ns": cur_mtime,
                    "lossy": lossy}
        # ③ 应用补丁
        n_set = n_remove = 0
        for k in (remove or []):
            if k in data:
                del data[k]
                n_remove += 1
        for k, v in (set or {}).items():
            data[k] = copy.deepcopy(v) if isinstance(v, (dict, list)) else v
            n_set += 1
        # ④ 复用写入管线（快照 / 原子写 / undo 登记 / 修剪全同路径）
        result = _commit(abs_path, data, raw=raw, lossy=lossy,
                         expect_mtime_ns=expect_mtime_ns,
                         expect_digest=expect_digest, force=force)
        if result.get("ok"):
            result["applied"] = {"set": n_set, "remove": n_remove}
            result["data"] = data  # 合并后全表，仅供 api 层刷新内存缓存
        return result


def _snapshot_bytes(abs_path, snap_name):
    """读回历史快照的原始字节（保留 BOM）；无快照名或读取失败返回 None。"""
    if not snap_name:
        return None
    try:
        with open(os.path.join(_history_dir(abs_path), snap_name), "rb") as f:
            return f.read()
    except OSError:
        return None


def _restore(abs_path, content):
    """把旧内容写回（不经快照、不经冲突检测）；content 为 None 表示恢复为「文件不存在」。

    content 传 bytes 时按原始字节写回：从快照恢复走这条路径，避免
    「utf-8-sig 读取剥掉 BOM → utf-8 写回不带 BOM」造成 undo 后文件字节与原状不一致。
    """
    if content is None:
        try:
            os.unlink(abs_path)
        except OSError:
            pass
        return _stat_mtime_ns(abs_path)
    if isinstance(content, bytes):
        try:
            atomic_io.write_bytes_atomic(abs_path, content)
        except OSError:
            raise
        return _stat_mtime_ns(abs_path)
    # 文本路径：强制 LF（B4：Windows 文本模式整表 CRLF 会让每次保存字节级漂移）
    atomic_io.write_text_atomic(abs_path, content, newline="\n")
    return _stat_mtime_ns(abs_path)


def forget(abs_path):
    """丢弃某表在内存里的 undo/redo 栈。

    用于文件被编辑器之外的链路整体覆盖之后（如云同步下载 shutil.copy2 直接落盘）：
    此时栈里滞留的「写入前内容」已与磁盘现状脱节，再 undo 会把外部新数据一并回滚。
    """
    with _STACK_LOCK:
        _STACKS.pop(_path_key(abs_path), None)


def _result_with_data(abs_path, mtime_ns):
    """undo/redo 成功响应：附带回填编辑器用的 JSON 数据。"""
    _raw, text, _lossy = read_lossy(abs_path)
    return {"ok": True, "mtime_ns": mtime_ns, "data": _parse_json_text(text)}


def _current_text(abs_path):
    return _read_text(abs_path) if os.path.isfile(abs_path) else None


def undo(abs_path):
    """撤销最近一次写入：peek 栈顶 → 磁盘恢复成功 → 才动栈（B3：栈永不与文件错位）。

    恢复失败（PermissionError 等可抛 OSError）时返回 ok=False 且栈保持原状；
    条目引用的快照已被滚动修剪且无文本兜底时同样安全失败，绝不把文件误删。
    """
    abs_path = os.path.abspath(abs_path)
    key = _path_key(abs_path)
    with _path_lock(key):
        with _STACK_LOCK:
            entry = _STACKS.get(key)
            if not entry or not entry["undo"]:
                return {"ok": False, "error": "nothing to undo"}
            item = entry["undo"][-1]
        if item["existed"]:
            raw = _snapshot_bytes(abs_path, item["snap"])
            if raw is None:
                if item.get("lossy"):
                    # 兜底文本里非 ASCII 已是 U+FFFD 占位符：恢复等于把占位符
                    # 永久写盘（B2 保护未覆盖 undo 路径），宁可安全失败
                    return {"ok": False,
                            "error": "历史快照缺失且该表为有损读取，无法撤销"}
                text = item.get("text")
                if text is not None:
                    # 文本兜底：text 是 utf-8-sig 解码结果（BOM 已剥），按原样补回
                    raw = (BOM if item.get("had_bom") else b"") + text.encode("utf-8")
                else:
                    raw = None
            if raw is None:
                return {"ok": False, "error": "history snapshot missing"}
            restore = raw
        else:
            restore = None  # 创建型写入：撤销 = 恢复为文件不存在
        cur_text = _current_text(abs_path)
        try:
            mtime_ns = _restore(abs_path, restore)
        except OSError as e:
            return {"ok": False, "error": "撤销失败: %s" % e}
        with _STACK_LOCK:
            entry["undo"].pop()
            entry["redo"].append({"snap": None, "text": cur_text, "existed": True,
                                  "had_bom": bool(restore) and restore[:3] == BOM,
                                  "lossy": False})
            del entry["redo"][:-HISTORY_LIMIT]
        return _result_with_data(abs_path, mtime_ns)


def redo(abs_path):
    """重做最近一次被撤销的写入：peek → 恢复成功 → 才动栈（同 B3）。"""
    abs_path = os.path.abspath(abs_path)
    key = _path_key(abs_path)
    with _path_lock(key):
        with _STACK_LOCK:
            entry = _STACKS.get(key)
            if not entry or not entry["redo"]:
                return {"ok": False, "error": "nothing to redo"}
            item = entry["redo"][-1]
        cur_text = _current_text(abs_path)
        if item["existed"] and item.get("text") is not None:
            # 文本恢复路径按原样补回 BOM（redo 条目无磁盘快照）
            restore = (BOM if item.get("had_bom") else b"") + item["text"].encode("utf-8")
        else:
            restore = item["text"]  # None → 恢复为不存在
        try:
            mtime_ns = _restore(abs_path, restore)
        except OSError as e:
            return {"ok": False, "error": "重做失败: %s" % e}
        with _STACK_LOCK:
            entry["redo"].pop()
            entry["undo"].append({"snap": None, "text": cur_text, "existed": True,
                                  "had_bom": bool(restore) and restore[:3] == BOM,
                                  "lossy": False})
            del entry["undo"][:-HISTORY_LIMIT]
        return _result_with_data(abs_path, mtime_ns)


def list_history(abs_path):
    """列出该 cfg 在 .editor_history 下的快照：[{file, ts, size}]（新 → 旧）。"""
    abs_path = os.path.abspath(abs_path)
    hdir = _history_dir(abs_path)
    out = []
    for ts, name in _history_entries(hdir, _cfg_stem(abs_path)):
        try:
            size = os.path.getsize(os.path.join(hdir, name))
        except OSError:
            size = 0
        out.append({"file": name, "ts": ts, "size": size})
    out.sort(key=lambda e: (e["ts"], e["file"]), reverse=True)
    return out


def debug_stack_bytes():
    """诊断：undo/redo 栈中内存文本的近似字节数（快照化条目计 0）。

    S2 准出指标：带快照的大表写入后应为 0（A8 生效前 ≈120MB/3 次写入）。
    """
    total = 0
    with _STACK_LOCK:
        for entry in _STACKS.values():
            for item in entry["undo"] + entry["redo"]:
                t = item.get("text")
                if isinstance(t, str):
                    total += len(t.encode("utf-8", errors="replace"))
    return total


def debug_reset_stacks():
    """诊断：清空全部内存 undo/redo 栈（测试隔离用）。"""
    with _STACK_LOCK:
        _STACKS.clear()
