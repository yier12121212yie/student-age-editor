# -*- coding: utf-8 -*-
"""AI 助手会话历史持久化（CLI / TUI 共用，GUI 不使用）。

AgentEngine.history 是内存态（与 GUI dart 端同构，引擎本身不落盘）；本模块
在 TUI / CLI 的 UI 层把 engine.history 按会话写入 <editor 根>/.editor_ai_history/
（一会话一 JSON 文件），供跨进程回看往轮对话与恢复上下文继续聊。

会话文件 = 元数据（provider/model/mod/source/标题/时间）+ 全量 history
（engine 原样消息，OpenAI 风格或 anthropic 块风格，取决于当时的 provider）。
恢复时用 to_openai_history() 归一化为 OpenAI 风格——client 的三协议转换器
（_to_anthropic_messages / _to_responses_input）都以该风格为入参，任何
provider 下都能续聊。

上限 _MAX_SESSIONS=50，超出按 updated_at 淘汰最旧；工具结果可能含模组文件
片段，属本地数据，勿入库。
"""

import json
import secrets
import time
from datetime import datetime
from pathlib import Path

from editor.core import atomic_io

from ..core.paths import app_data_dir

_MAX_SESSIONS = 50
_TITLE_MAX = 60
_TRANSCRIPT_TOOL_HEAD = 120  # 工具行摘要截断宽度


def sessions_dir(root=None) -> Path:
    """会话存储目录（root 参数供测试注入临时目录）。"""
    base = Path(root) if root is not None else Path(app_data_dir())
    return base / ".editor_ai_history"


def new_session(provider="", model="", mod="", source="") -> dict:
    """新建会话元数据（history 为空，首次 save_session 时才落盘）。"""
    now = datetime.now().isoformat(timespec="seconds")
    return {
        "id": "%s-%s" % (time.strftime("%Y%m%d-%H%M%S"), secrets.token_hex(2)),
        "title": "",
        "created_at": now,
        "updated_at": now,
        "provider": provider or "",
        "model": model or "",
        "mod": mod or "",
        "source": source or "",
        "message_count": 0,
        "history": [],
    }


def _write_atomic(path: Path, data: dict):
    atomic_io.write_text_atomic(
        str(path), json.dumps(data, ensure_ascii=False))


def _derive_title(history: list) -> str:
    """标题 = 首条用户消息的首行（截断 _TITLE_MAX）。"""
    for m in history:
        if not isinstance(m, dict) or m.get("role") != "user":
            continue
        content = m.get("content")
        text = content if isinstance(content, str) else ""
        if not text and isinstance(content, list):
            text = " ".join(b.get("text") or "" for b in content
                            if isinstance(b, dict) and b.get("type") == "text")
        text = text.strip().splitlines()
        if text and text[0].strip():
            title = text[0].strip()
            return title[:_TITLE_MAX] + ("…" if len(title) > _TITLE_MAX else "")
    return ""


def _prune(root: Path, keep_id: str = ""):
    """超过 _MAX_SESSIONS 时按 updated_at 淘汰最旧会话文件。"""
    try:
        # 次级键用文件名（id 含创建时刻，字典序=时间序）：同一时间片内
        # 批量落盘时 st_mtime 相同，只按 mtime 排序在 Windows 上不稳定，
        # 会随机淘汰错文件（时间戳粒度问题）。
        entries = sorted(root.glob("*.json"),
                         key=lambda p: (p.stat().st_mtime, p.name))
    except OSError:
        return
    overflow = len(entries) - _MAX_SESSIONS
    if overflow <= 0:
        return
    for p in entries:
        if overflow <= 0:
            break
        if p.stem == keep_id:
            continue
        try:
            p.unlink()
            overflow -= 1
        except OSError:
            pass


def save_session(session: dict, root=None) -> dict:
    """落盘一个会话（补齐 id/时间/标题/消息数，原子写）。返回更新后的 session。"""
    hist = session.get("history") or []
    if not isinstance(hist, list):
        hist = []
    if not session.get("id"):
        session.update(new_session())
        session["history"] = hist
    if not _safe_session_id(session.get("id")):
        raise ValueError("非法会话 id: %r" % (session.get("id"),))
    if not session.get("title"):
        session["title"] = _derive_title(hist)
    session["updated_at"] = datetime.now().isoformat(timespec="seconds")
    session["message_count"] = len(hist)
    d = sessions_dir(root)
    _write_atomic(d / ("%s.json" % session["id"]), session)
    _prune(d, keep_id=session["id"])
    return session


def list_sessions(root=None, limit=None) -> list:
    """会话元数据列表（不含 history），按 updated_at 降序。"""
    d = sessions_dir(root)
    out = []
    try:
        files = list(d.glob("*.json"))
    except OSError:
        return []
    for p in files:
        try:
            data = json.loads(p.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        if not isinstance(data, dict) or not data.get("id"):
            continue
        meta = {k: v for k, v in data.items() if k != "history"}
        if "message_count" not in meta:
            meta["message_count"] = len(data.get("history") or [])
        out.append(meta)
    out.sort(key=lambda m: str(m.get("updated_at") or ""), reverse=True)
    return out[:limit] if limit else out


def _safe_session_id(session_id) -> bool:
    """会话 id 仅允许字母数字与 . _ -：id 直接拼进文件路径，
    未净化的 `../x` 之类可越出会话目录读/删任意 json。"""
    import re
    return bool(session_id) and re.fullmatch(r"[A-Za-z0-9._-]+", str(session_id)) is not None


def load_session(session_id: str, root=None):
    """按 id 读取完整会话；不存在或损坏返回 None。"""
    if not _safe_session_id(session_id):
        return None
    p = sessions_dir(root) / ("%s.json" % session_id)
    try:
        data = json.loads(p.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    return data if isinstance(data, dict) else None


def resolve_session_ref(ref: str, root=None):
    """'last' → 最新会话；其余按 id 查找。返回 (session|None, 错误信息|None)。"""
    ref = (ref or "").strip()
    if not ref:
        return None, "缺少会话 id（agent history list 查看）"
    if ref.lower() == "last":
        sessions = list_sessions(root=root, limit=1)
        if not sessions:
            return None, "还没有任何 AI 会话历史"
        return load_session(sessions[0]["id"], root=root), None
    data = load_session(ref, root=root)
    if data is None:
        return None, "会话不存在: %s" % ref
    return data, None


def delete_session(session_id: str, root=None) -> bool:
    if not _safe_session_id(session_id):
        return False
    try:
        (sessions_dir(root) / ("%s.json" % session_id)).unlink()
        return True
    except OSError:
        return False


def clear_sessions(root=None) -> int:
    """清空全部会话，返回删除的文件数。"""
    d = sessions_dir(root)
    n = 0
    try:
        files = list(d.glob("*.json"))
    except OSError:
        return 0
    for p in files:
        try:
            p.unlink()
            n += 1
        except OSError:
            pass
    return n


# ---------------------------------------------------------------------------
# 恢复：历史消息归一化 / 转可读文稿
# ---------------------------------------------------------------------------

def to_openai_history(history: list) -> list:
    """把 engine.history 归一化为 OpenAI 风格消息（续聊入参）。

    openai_compatible / openai_responses 会话本就是该风格，原样通过；
    anthropic 会话的块结构（tool_use / tool_result / text）转成
    tool_calls + role:"tool" 消息，文本块折叠为字符串。
    """
    out = []
    for m in history or []:
        if not isinstance(m, dict):
            continue
        role = m.get("role")
        if role not in ("user", "assistant", "tool"):
            continue
        content = m.get("content")
        if not isinstance(content, list):
            msg = {"role": role}
            if content is not None:
                msg["content"] = content
            elif "content" in m:  # 助手 tool_calls 轮的 content=None 原样保留
                msg["content"] = None
            if role == "assistant" and isinstance(m.get("tool_calls"), list):
                msg["tool_calls"] = m["tool_calls"]
            if role == "tool" and m.get("tool_call_id") is not None:
                msg["tool_call_id"] = m["tool_call_id"]
            out.append(msg)
            continue
        texts, tool_calls, tool_results, images = [], [], [], []
        for b in content:
            if not isinstance(b, dict):
                continue
            btype = b.get("type")
            if btype == "text":
                texts.append(b.get("text") or "")
            elif btype == "tool_use":
                tool_calls.append(b)
            elif btype == "tool_result":
                tool_results.append(b)
            elif btype == "image_url":
                images.append(b)
        if role == "assistant" and tool_calls:
            msg = {"role": "assistant",
                   "content": "".join(texts) if texts else None,
                   "tool_calls": [
                       {
                           "id": c.get("id") or "toolu_0",
                           "type": "function",
                           "function": {
                               "name": c.get("name") or "",
                               "arguments": json.dumps(
                                   c.get("input") if isinstance(c.get("input"), dict) else {},
                                   ensure_ascii=False),
                           },
                       }
                       for c in tool_calls
                   ]}
            out.append(msg)
        elif role == "user" and tool_results:
            for r in tool_results:
                rc = r.get("content")
                out.append({
                    "role": "tool",
                    "tool_call_id": r.get("tool_use_id") or "",
                    "content": rc if isinstance(rc, str) else json.dumps(
                        rc, ensure_ascii=False),
                })
            if texts:  # 引擎不会产生该形态（文本+结果同块），容错保序在后
                out.append({"role": "user", "content": "".join(texts)})
        elif images:
            blocks = [{"type": "text", "text": t} for t in texts if t]
            blocks.extend(images)
            out.append({"role": role, "content": blocks})
        else:
            out.append({"role": role, "content": "".join(texts)})
    return out


def _tool_head(content, width=_TRANSCRIPT_TOOL_HEAD) -> str:
    text = content if isinstance(content, str) else json.dumps(content, ensure_ascii=False)
    lines = (text or "").strip().splitlines()
    head = lines[0] if lines else ""
    return head[:width]


def render_transcript(history: list) -> str:
    """history → 可读文稿（你：/ AI：/ ⚙ 工具行），供恢复会话时回显。"""
    lines = []
    for m in history or []:
        if not isinstance(m, dict):
            continue
        role = m.get("role")
        content = m.get("content")
        if role == "user":
            if isinstance(content, list):
                texts = [b.get("text") or "" for b in content
                         if isinstance(b, dict) and b.get("type") == "text"]
                texts = [t for t in texts if t.strip()]
                if texts:
                    lines.append("你：" + "\n".join(texts))
                n_results = sum(1 for b in content
                                if isinstance(b, dict) and b.get("type") == "tool_result")
                if n_results:
                    lines.append("  ⚙ （工具结果 ×%d）" % n_results)
            elif isinstance(content, str) and content.strip():
                lines.append("你：" + content)
        elif role == "assistant":
            if isinstance(content, list):
                texts = [b.get("text") or "" for b in content
                         if isinstance(b, dict) and b.get("type") == "text"]
                texts = [t for t in texts if t.strip()]
                if texts:
                    lines.append("AI：" + "\n".join(texts))
                for b in content:
                    if isinstance(b, dict) and b.get("type") == "tool_use":
                        args = json.dumps(b.get("input") or {}, ensure_ascii=False)
                        lines.append("  ⚙ %s %s" % (b.get("name") or "", args[:_TRANSCRIPT_TOOL_HEAD]))
            else:
                if isinstance(content, str) and content.strip():
                    lines.append("AI：" + content)
                for tc in m.get("tool_calls") or []:
                    if isinstance(tc, dict):
                        fn = tc.get("function") or {}
                        lines.append("  ⚙ %s %s" % (
                            fn.get("name") or "", (fn.get("arguments") or "")[:_TRANSCRIPT_TOOL_HEAD]))
        elif role == "tool":
            lines.append("    → " + _tool_head(content))
    return "\n".join(lines)
