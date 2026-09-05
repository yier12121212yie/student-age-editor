# -*- coding: utf-8 -*-
"""AI 文件工具沙箱：所有路径解析都相对沙箱根，禁止逃逸（.. 越界）。"""
import base64
import json
import os

from editor.core import atomic_io

TEXT_EXTS = {
    ".json", ".txt", ".md", ".csv", ".xml", ".html", ".css", ".js", ".ts",
    ".lua", ".py", ".cfg", ".ini", ".yaml", ".yml", ".log", ".manifest",
    ".template", ".bat", ".sh",
}

BINARY_EXTS = {".png", ".jpg", ".jpeg", ".webp", ".bmp", ".gif", ".wav",
               ".ogg", ".mp3", ".bundle", ".assets", ".bytes", ".dll", ".exe"}

MAX_LIST_ENTRIES = 2000
MAX_FILE_BYTES = 8 * 1024 * 1024  # 8MB 文本上限


class SandboxError(Exception):
    pass


def _norm(rel_path):
    if rel_path is None:
        raise SandboxError("empty path")
    if not isinstance(rel_path, str):
        rel_path = str(rel_path)
    p = rel_path.replace("\\", "/").lstrip("/").strip()
    if not p or p == ".":
        return ""
    norm = os.path.normpath(p)
    if norm in (".",):
        return ""
    head = norm.split(os.sep)[0]
    if head == ".." or ":" in norm or os.path.isabs(norm):
        raise SandboxError("path escapes sandbox: %r" % rel_path)
    return norm


def resolve(root, rel_path):
    """返回绝对路径；root 不存在或 rel 越界时抛 SandboxError。"""
    if not root or not os.path.isdir(root):
        raise SandboxError("sandbox root missing: %r" % root)
    rel = _norm(rel_path)
    abs_path = os.path.abspath(os.path.join(root, rel))
    root_abs = os.path.abspath(root)
    if abs_path != root_abs and not abs_path.startswith(root_abs + os.sep):
        raise SandboxError("path escapes sandbox: %r" % rel_path)
    return abs_path


def list_dir(root, rel_path, deep=False):
    """列出目录；deep=True 时递归（限制深度 4）。返回条目列表。"""
    abs_path = resolve(root, rel_path)
    if not os.path.isdir(abs_path):
        raise SandboxError("not a directory: %r" % rel_path)
    entries = []

    def walk(base, rel, depth):
        try:
            names = sorted(os.listdir(base))
        except OSError:
            return
        for name in names:
            if len(entries) >= MAX_LIST_ENTRIES:
                return
            full = os.path.join(base, name)
            # 统一用 / 拼接相对路径（跨平台一致，前端/AI 均按 / 解析）
            child_rel = rel + "/" + name if rel else name
            if os.path.isdir(full):
                entries.append({"name": child_rel, "type": "dir", "size": 0})
                if deep and depth < 4:
                    walk(full, child_rel, depth + 1)
            else:
                try:
                    size = os.path.getsize(full)
                except OSError:
                    size = 0
                entries.append({"name": child_rel, "type": "file", "size": size})

    walk(abs_path, "", 0)
    return entries


def read_file(root, rel_path, as_binary=False):
    """读取文件。文本返回 {"text": ...}；二进制（或 as_binary）返回 {"base64": ...}。"""
    abs_path = resolve(root, rel_path)
    if not os.path.isfile(abs_path):
        raise SandboxError("not a file: %r" % rel_path)
    size = os.path.getsize(abs_path)
    if size > MAX_FILE_BYTES and not as_binary:
        raise SandboxError("file too large (%d bytes): %r" % (size, rel_path))
    ext = os.path.splitext(abs_path)[1].lower()
    binary = as_binary or ext in BINARY_EXTS
    with open(abs_path, "rb") as f:
        raw = f.read()
    if binary:
        return {"path": rel_path, "size": len(raw), "base64": base64.b64encode(raw).decode("ascii")}
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError:
        text = raw.decode("gbk", errors="replace")
    return {"path": rel_path, "size": len(raw), "text": text}


def _tmp_path_for(abs_path):
    """为写入生成唯一临时文件路径，避免并发写竞争。

    .. deprecated:: 实际落盘请用 editor.core.atomic_io（带瞬时占用重试）。
    """
    import threading
    import time
    return "%s.tmp_%d_%d" % (abs_path, int(time.time() * 1000) % 1000000,
                             threading.get_ident())


def write_file(root, rel_path, content, base64_mode=False):
    """写入文件。content 为文本字符串或 base64。自动创建父目录。"""
    abs_path = resolve(root, rel_path)
    if base64_mode:
        raw = base64.b64decode(content)
    else:
        raw = str(content).encode("utf-8")
    atomic_io.write_bytes_atomic(abs_path, raw)
    return {"path": rel_path, "size": len(raw)}


def read_json_file(root, rel_path):
    abs_path = resolve(root, rel_path)
    with open(abs_path, "r", encoding="utf-8") as f:
        return json.load(f)


def write_json_file(root, rel_path, data):
    abs_path = resolve(root, rel_path)
    atomic_io.write_text_atomic(abs_path, json.dumps(data, ensure_ascii=False, indent=2))
    return {"path": rel_path}


def stat_path(root, rel_path):
    abs_path = resolve(root, rel_path)
    if not os.path.exists(abs_path):
        return {"path": rel_path, "exists": False}
    info = {"path": rel_path, "exists": True, "type": "dir" if os.path.isdir(abs_path) else "file"}
    if os.path.isfile(abs_path):
        info["size"] = os.path.getsize(abs_path)
        info["ext"] = os.path.splitext(abs_path)[1].lower()
    return info
