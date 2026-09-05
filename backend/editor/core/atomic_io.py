# -*- coding: utf-8 -*-
"""原子写工具（S2 写路径）：临时文件 + flush + fsync + os.replace（带瞬时占用重试）。

此前 server.fs_tools._tmp_path_for 只保证临时名唯一，写完直接 os.replace，
Windows 上偶发 WinError 5 / 32（杀软扫描、索引服务等瞬时占用目标文件）导致
替换失败、半成品残留在临时文件里。本模块统一提供：

    write_bytes_atomic(abs_path, data, *, retries=5, delay=0.02)
        makedirs 父目录 → 同目录唯一临时文件（pid + 线程 + 随机后缀，防并发
        互踩）→ 二进制写 + flush + fsync → 循环 os.replace，对
        PermissionError / FileExistsError（瞬时占用）按 delay 退避重试；
        末次失败清理临时文件后抛 OSError。

    write_text_atomic(abs_path, text, *, encoding="utf-8", bom=False,
                      newline="\n")
        先统一 CRLF → LF 再按 newline 转换，按 bom 决定是否加 UTF-8 BOM，
        编码后走 bytes 路径。

本模块属于 core 层：只依赖标准库，禁止 import editor.server（反向依赖合法）。
"""
import os
import secrets
import threading
import time

__all__ = ["write_bytes_atomic", "write_text_atomic"]

# UTF-8 BOM：嗅探 / 拼接用（cfg_store 据此原样保留源文件 BOM）
BOM = b"\xef\xbb\xbf"


def _unique_tmp_path(abs_path):
    """同目录唯一临时文件路径：目标名 + .tmp + pid + 线程 id + 随机后缀。

    随机后缀保证两个线程/进程并发写同一目标时临时文件互不覆盖
    （fs_tools._tmp_path_for 只有 ms 时间戳 + 线程 id，同进程同毫秒可撞名）。
    """
    while True:
        tmp = "%s.tmp_%d_%d_%s" % (
            abs_path, os.getpid(), threading.get_ident(), secrets.token_hex(6))
        if not os.path.exists(tmp):
            return tmp


def write_bytes_atomic(abs_path, data, *, retries=5, delay=0.02):
    """把 bytes 原子写入 abs_path。成功返回写入字节数。

    步骤：makedirs 父目录 → 唯一临时文件（同目录，保证 os.replace 原子性）
    → 写 + flush + fsync → os.replace 替换目标。os.replace 抛
    PermissionError / FileExistsError（Windows WinError 5/32 瞬时占用，
    杀软 / 索引服务短暂锁住目标）时按 delay 退避重试 retries 次；
    末次失败清理临时文件后抛 OSError（保留原异常为 __cause__）。
    """
    abs_path = os.path.abspath(abs_path)
    parent = os.path.dirname(abs_path)
    if parent:
        os.makedirs(parent, exist_ok=True)
    tmp = _unique_tmp_path(abs_path)
    try:
        with open(tmp, "wb") as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        attempts = max(1, int(retries))
        last_err = None
        for attempt in range(attempts):
            try:
                os.replace(tmp, abs_path)
                tmp = None  # 已替换成功，finally 不再清理
                return len(data)
            except (PermissionError, FileExistsError) as e:
                last_err = e
                if attempt < attempts - 1 and delay > 0:
                    time.sleep(delay)
        raise OSError("os.replace 失败（已重试 %d 次，目标被瞬时占用）: %s"
                      % (attempts, last_err))
    finally:
        if tmp is not None:
            try:
                os.unlink(tmp)
            except OSError:
                pass


def write_text_atomic(abs_path, text, *, encoding="utf-8", bom=False,
                      newline="\n"):
    """把 str 按指定编码原子写入 abs_path。成功返回写入字节数。

    换行统一：先 CRLF → LF 归一，再整体替换为 newline（newline="\\n" 时
    等价于强制 LF，杜绝 Windows 文本模式把整表写成 CRLF）。bom=True 时
    在编码结果前加 UTF-8 BOM（用于原样保留源文件的 BOM）。
    """
    text = text.replace("\r\n", "\n").replace("\n", newline)
    raw = text.encode(encoding)
    if bom:
        raw = BOM + raw
    return write_bytes_atomic(abs_path, raw)
