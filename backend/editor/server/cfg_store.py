# -*- coding: utf-8 -*-
"""配置表统一写入口：冲突检测 + 历史快照 + 原子写 + 撤销/重做。

背景：此前 api._save_mod_cfg / api.cfg_write / ai_domain_service.save_cfg /
tts_store.register_audio_cfg / cli.utils.save_cfg 各自内联实现「tmp + os.replace」
原子写，误覆盖外部改动（游戏 / 其他设备 / 云同步回写）时无从察觉，也没有
误操作兜底。本模块把写入链路收敛为一个入口：

    write_cfg(abs_path, data, expect_mtime_ns=..., force=False, snapshot=True)
      1) 冲突检测：expect_mtime_ns 与磁盘 st_mtime_ns 不一致时拒绝写入，
         返回磁盘当前内容（供前端弹「文件已被外部修改」对话框）；
      2) 历史快照：覆盖已有文件前，把旧内容原文存入 <mod根>/.editor_history/；
      3) 原子写：临时文件 + os.replace（复用 fs_tools._tmp_path_for）；
      4) 维护内存 undo/redo 栈（Lock 保护，undo 上限 50）。

    undo(abs_path) / redo(abs_path)：撤销 / 重做最近一次写入。
    list_history(abs_path)：列出该表的磁盘历史快照（新 → 旧）。

零第三方依赖；只依赖标准库与 editor.server.fs_tools。
"""
import json
import os
import threading
import time

from editor.server import fs_tools

# 历史快照目录名（相对 Mod 根；云同步 / 实时同步按名字排除）
HISTORY_DIR = ".editor_history"
# undo 栈上限：超出丢最旧
HISTORY_LIMIT = 50

_STACK_LOCK = threading.RLock()
# {abs_path: {"undo": [(快照文件名或 None, 旧内容文本)], "redo": [...]}}
# undo 栈顶 = 最近一次写入的「写入前内容」；redo 栈顶 = 最近一次撤销的「被撤销内容」。
_STACKS = {}


def _read_text(path):
    """utf-8-sig 容错读取文本（兼容外部工具写出的 BOM 文件）；失败返回 None。"""
    try:
        with open(path, "r", encoding="utf-8-sig") as f:
            return f.read()
    except OSError:
        return None


def _read_json_lenient(path):
    """读取磁盘当前 JSON 内容（容错 BOM/空白）；文件缺失或解析失败返回 None。"""
    text = _read_text(path)
    if text is None:
        return None
    try:
        return json.loads(text.strip() or "{}")
    except (ValueError, TypeError):
        return None


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


def _write_snapshot(abs_path):
    """把旧文件原文（原始字节，保留 BOM）写入 .editor_history/<stem>_<ms>_<seq>.json。

    目录不存在则创建。返回快照文件名；读取/写入失败返回 None（不阻塞写入）。
    """
    try:
        with open(abs_path, "rb") as src:
            raw = src.read()
    except OSError:
        return None
    hdir = _history_dir(abs_path)
    try:
        os.makedirs(hdir, exist_ok=True)
    except OSError:
        return None
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
        tmp = fs_tools._tmp_path_for(snap_path)
        with open(tmp, "wb") as dst:
            dst.write(raw)
        os.replace(tmp, snap_path)
    except OSError:
        return None
    return name


def _atomic_write(abs_path, content):
    """文本内容原子写（临时文件 + os.replace），自动创建父目录。"""
    parent = os.path.dirname(abs_path)
    if parent:
        os.makedirs(parent, exist_ok=True)
    tmp = fs_tools._tmp_path_for(abs_path)
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(content)
    os.replace(tmp, abs_path)


def _stat_mtime_ns(abs_path):
    try:
        return os.stat(abs_path).st_mtime_ns
    except OSError:
        return None


def write_cfg(abs_path, data, *, expect_mtime_ns=None, force=False, snapshot=True):
    """统一写入口。返回 dict：

    - 冲突：{"ok": False, "conflict": True, "mtime_ns": 磁盘当前, "data": 磁盘当前内容}
    - 成功：{"ok": True, "mtime_ns": 新 stat, "snapshot": 快照文件名或 None}
    - 失败：{"ok": False, "error": ...}
    """
    abs_path = os.path.abspath(abs_path)
    with _STACK_LOCK:
        exists = os.path.isfile(abs_path)
        cur_mtime = _stat_mtime_ns(abs_path) if exists else None
        # ① 冲突检测：调用方声明基于 expect_mtime_ns 的内容，磁盘已变则拒绝
        if (expect_mtime_ns is not None and exists
                and cur_mtime is not None and cur_mtime != expect_mtime_ns
                and not force):
            return {"ok": False, "conflict": True, "mtime_ns": cur_mtime,
                    "data": _read_json_lenient(abs_path)}
        # ② 历史快照：仅对「覆盖已有文件」记录旧内容原文
        snap_name = None
        old_text = None
        if exists:
            old_text = _read_text(abs_path)
            if snapshot:
                snap_name = _write_snapshot(abs_path)
        # ③ 原子写
        try:
            _atomic_write(abs_path, json.dumps(data, ensure_ascii=False, indent=2))
        except OSError as e:
            return {"ok": False, "error": "写入失败: %s" % e}
        new_mtime = _stat_mtime_ns(abs_path)
        # ④ undo 栈：记录「写入前内容」；新写入清空 redo 链
        entry = _STACKS.setdefault(abs_path, {"undo": [], "redo": []})
        entry["undo"].append((snap_name, old_text))
        del entry["undo"][:-HISTORY_LIMIT]
        entry["redo"].clear()
        return {"ok": True, "mtime_ns": new_mtime, "snapshot": snap_name}


def _restore(abs_path, content):
    """把旧内容写回（不经快照、不经冲突检测）；content 为 None 表示恢复为「文件不存在」。"""
    if content is None:
        try:
            os.unlink(abs_path)
        except OSError:
            pass
        return _stat_mtime_ns(abs_path)
    _atomic_write(abs_path, content)
    return _stat_mtime_ns(abs_path)


def _result_with_data(abs_path, mtime_ns):
    """undo/redo 成功响应：附带回填编辑器用的 JSON 数据。"""
    return {"ok": True, "mtime_ns": mtime_ns,
            "data": _read_json_lenient(abs_path)}


def undo(abs_path):
    """撤销最近一次写入：当前内容压入 redo 栈，再恢复到写入前内容。"""
    abs_path = os.path.abspath(abs_path)
    with _STACK_LOCK:
        entry = _STACKS.get(abs_path)
        if not entry or not entry["undo"]:
            return {"ok": False, "error": "nothing to undo"}
        _snap_name, old_text = entry["undo"].pop()
        cur_text = _read_text(abs_path) if os.path.isfile(abs_path) else None
        entry["redo"].append((None, cur_text))
        del entry["redo"][:-HISTORY_LIMIT]
        mtime_ns = _restore(abs_path, old_text)
        return _result_with_data(abs_path, mtime_ns)


def redo(abs_path):
    """重做最近一次被撤销的写入：当前内容压回 undo 栈，再恢复被撤销前内容。"""
    abs_path = os.path.abspath(abs_path)
    with _STACK_LOCK:
        entry = _STACKS.get(abs_path)
        if not entry or not entry["redo"]:
            return {"ok": False, "error": "nothing to redo"}
        _snap_name, redo_text = entry["redo"].pop()
        cur_text = _read_text(abs_path) if os.path.isfile(abs_path) else None
        entry["undo"].append((None, cur_text))
        del entry["undo"][:-HISTORY_LIMIT]
        mtime_ns = _restore(abs_path, redo_text)
        return _result_with_data(abs_path, mtime_ns)


def list_history(abs_path):
    """列出该 cfg 在 .editor_history 下的快照：[{file, ts, size}]（新 → 旧）。"""
    abs_path = os.path.abspath(abs_path)
    hdir = _history_dir(abs_path)
    if not os.path.isdir(hdir):
        return []
    prefix = _cfg_stem(abs_path) + "_"
    out = []
    try:
        names = os.listdir(hdir)
    except OSError:
        return []
    for name in names:
        if not name.startswith(prefix) or not name.endswith(".json"):
            continue
        # 文件名：<stem>_<毫秒时间戳>_<序号>.json；时间戳取前缀后首个下划线段
        tail = name[len(prefix):-5]
        ts = 0
        try:
            ts = int(tail.split("_")[0])
        except (IndexError, ValueError):
            pass
        try:
            size = os.path.getsize(os.path.join(hdir, name))
        except OSError:
            size = 0
        out.append({"file": name, "ts": ts, "size": size})
    out.sort(key=lambda e: (e["ts"], e["file"]), reverse=True)
    return out
