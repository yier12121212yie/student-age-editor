# -*- coding: utf-8 -*-
"""LLM 流式客户端（传输层）—— frontend/lib/features/ai/ai_client.dart 的 Python 移植。

仅负责「一次协议往返」：发请求 → 读 SSE → 聚合文本与 tool_call 增量片段 →
返回 (工具调用列表, 本轮文本)。多轮「生成 → 工具 → 回填」循环在 engine.py，
系统提示词在 prompt.py，本模块不掺和。

支持三协议（与 GUI 设置页下拉一致，字段来自三端共享的 .editor_ai.json）：
  - openai_compatible  POST {base}/chat/completions
  - openai_responses   POST {base}/responses
  - anthropic          POST {base}/messages

纯标准库 urllib（与 server/cloud_sync.py 同策略），无第三方依赖；
SSE 逐行读取 ``data:`` 负载，行为对齐 dart 端（含 [DONE]、tool_calls
分片聚合、finish_reason 短路）。base64 图片块转换一并保留，历史格式
与 dart 端完全同构（OpenAI 风格消息），会话可在三端间无缝互换。
"""

import io
import json
import socket
import time
import urllib.error
import urllib.request
from dataclasses import dataclass, field

from ..core.env_store import normalize_ai_settings

_MAX_TOOL_ROUNDS = 20  # 与 GUI（ai_client.dart _maxToolRounds）一致

_DEFAULT_BASE = {
    "anthropic": "https://api.anthropic.com/v1",
    "openai_responses": "https://api.openai.com/v1",
}
_FALLBACK_BASE = "https://api.openai.com/v1"

_MAX_TOKENS_ANTHROPIC = 8192
_HTTP_TIMEOUT = 30


class LlmError(Exception):
    """请求失败（HTTP ≥400、网络中断、响应不可解析）。

    retryable 标注该失败是否值得自动重连（连接失败/流式中断/HTTP 429、5xx 为
    True）；retry_after 为 429 场景服务端要求的等待秒数（无则为 None）。
    """

    def __init__(self, message, retryable=False, retry_after=None):
        super().__init__(message)
        self.retryable = retryable
        self.retry_after = retry_after



class LlmCancelled(Exception):
    """调用方通过 cancel() 主动中断，非错误。"""


@dataclass
class ToolCall:
    """一次工具调用（由模型发起）。arguments 为已解析的 dict（解析失败为 {}）。"""
    id: str
    name: str
    arguments: dict = field(default_factory=dict)


def _as_dict(value):
    """None 安全取 dict；非 dict 返回 {}（对齐 dart _asStrMap 的容错语义）。"""
    return value if isinstance(value, dict) else {}


def _try_parse_json(raw: str) -> dict:
    text = (raw or "").strip()
    if not text:
        return {}
    try:
        parsed = json.loads(text)
    except (ValueError, TypeError):
        return {}
    return parsed if isinstance(parsed, dict) else {}


@dataclass
class LlmClient:
    """三协议 AI 客户端。settings 为 .editor_ai.json 同构 dict。"""

    settings: dict
    _cancelled: bool = False
    _resp: "io.TextIOWrapper | None" = None

    def __post_init__(self):
        self.settings = normalize_ai_settings(self.settings)

    # ------------------------------------------------------------------ 公共
    def cancel(self):
        """线程安全的中断请求：置位标志并关闭底层连接，令阻塞中的读立即失败。"""
        self._cancelled = True
        resp = self._resp
        self._resp = None
        if resp is not None:
            try:
                resp.close()
            except Exception:
                pass

    @property
    def cancelled(self) -> bool:
        return self._cancelled

    def round(self, history: list, tools: list, system_prompt: str, on_text=None, on_retry=None):
        """执行一轮「模型生成」。

        history : OpenAI 风格结构化消息（与 dart 端 send() 的入参同构；
                  assistant 可带 tool_calls，tool 角色携带结果），原地复用。
        tools   : [{name, description, parameters(JSON schema)}] 开放格式，
                  按协议自动转为 function / input_schema 规格。
        on_text : 文本增量回调（含以工具调用结束的轮次），用于流式打印。
        on_retry: 自动重连回调 on_retry(attempt, total_retries, reason)，在每次
                  网络失败重试前调用；total_retries 为 settings["maxRetries"]。

        返回 (list[ToolCall], str)。工具调用非空表示本轮以工具调用结束，
        引擎需执行工具并把结果回填 history 后再次 round()。

        自动重连：连接失败 / 流式中断 / HTTP 429、5xx 按指数退避自动重发本
        轮（请求无状态、携带全量 history，重发即恢复）；不可重试的错误
        （其它 4xx、未配置 Key）与用户取消（LlmCancelled）保持原样直抛。
        断流前已输出的部分文本会随重试重新生成，UI 层用 on_retry 提示用户。
        """
        if self._cancelled:
            raise LlmCancelled("已取消")
        if not (self.settings.get("apiKey") or "").strip():
            raise LlmError("未配置 API Key，请先运行 `agent config` 或在 GUI 设置中配置")
        provider = self.settings["provider"]
        max_retries = int(self.settings.get("maxRetries") or 0)
        delay_ms = int(self.settings.get("retryDelayMs") or 1000)

        attempt = 0
        while True:
            try:
                if provider == "anthropic":
                    return self._anthropic_round(history, tools, system_prompt, on_text)
                if provider == "openai_responses":
                    return self._responses_round(history, tools, system_prompt, on_text)
                return self._openai_round(history, tools, system_prompt, on_text)
            except LlmCancelled:
                raise
            except LlmError as exc:
                if not exc.retryable or attempt >= max_retries:
                    raise
                attempt += 1
                if on_retry:
                    on_retry(attempt, max_retries, str(exc))
                self._sleep_cancellable(
                    self._retry_delay_ms(attempt, delay_ms, exc.retry_after))

    @staticmethod
    def _retry_delay_ms(attempt: int, base_ms: int, retry_after) -> int:
        """指数退避：base_ms * 2^(attempt-1)，上限 10s；429 场景取 Retry-After（上限 60s）。"""
        ms = base_ms * (2 ** (attempt - 1)) if base_ms > 0 else 0
        ms = min(ms, 10_000)
        if retry_after:
            ms = max(ms, int(min(retry_after * 1000, 60_000)))
        return ms

    def _sleep_cancellable(self, ms: int):
        """可中断的退避睡眠：0.2s 切片检查取消标志，避免长退避卡住 cancel()。"""
        end = time.monotonic() + ms / 1000
        while True:
            if self._cancelled:
                raise LlmCancelled("已取消")
            remain = end - time.monotonic()
            if remain <= 0:
                return
            time.sleep(min(remain, 0.2))

    # ------------------------------------------------------------------ URI / 头
    def _uri(self, path: str) -> str:
        base = (self.settings.get("baseUrl") or "").strip()
        if not base:
            base = _DEFAULT_BASE.get(self.settings["provider"], _FALLBACK_BASE)
        return base.rstrip("/") + path

    def _headers(self) -> dict:
        headers = {
            "Content-Type": "application/json",
            "Accept": "text/event-stream",
        }
        if self.settings["provider"] == "anthropic":
            headers["x-api-key"] = self.settings["apiKey"]
            headers["anthropic-version"] = "2023-06-01"
        else:
            headers["Authorization"] = f"Bearer {self.settings['apiKey']}"
        return headers

    # ------------------------------------------------------------------ SSE
    def _post_stream(self, uri: str, body: dict):
        """POST 并返回 SSE ``data:`` 负载的迭代器（逐行，已去除前缀与空白）。"""
        req = urllib.request.Request(
            uri,
            data=json.dumps(body, ensure_ascii=False).encode("utf-8"),
            headers=self._headers(),
            method="POST",
        )
        try:
            resp = urllib.request.urlopen(req, timeout=_HTTP_TIMEOUT)
        except LlmCancelled:
            raise
        except urllib.error.HTTPError as exc:
            code = exc.code
            retryable = code in (429,) or code >= 500
            retry_after = None
            try:
                header = exc.headers.get("Retry-After") if exc.headers else None
                if header:
                    try:
                        retry_after = max(float(header), 0.0)
                    except (TypeError, ValueError):
                        pass
            except Exception:
                pass
            raw = b""
            try:
                raw = exc.read(64 * 1024) or b""
            except Exception:
                pass
            finally:
                exc.close()
            raise LlmError(
                f"HTTP {code}: {self._trim_err(raw.decode('utf-8', 'replace'))}",
                retryable=retryable,
                retry_after=retry_after,
            ) from exc
        except (urllib.error.URLError, socket.timeout, OSError) as exc:
            if self._cancelled:
                raise LlmCancelled("已取消") from exc
            raise LlmError(f"连接失败: {exc}", retryable=True) from exc
        if self._cancelled:
            resp.close()
            raise LlmCancelled("已取消")
        stream = io.TextIOWrapper(resp, encoding="utf-8", errors="replace")
        self._resp = stream
        return self._iter_sse(stream)

    def _iter_sse(self, stream):
        """逐行产出 data 负载；取消或连接中断时按语义收尾。

        stream 显式传参而非读 self._resp：cancel() 会把后者置空，
        若在首次迭代前取消，生成器延迟体执行时会拿到 None。
        """
        try:
            for line in stream:
                if self._cancelled:
                    raise LlmCancelled("已取消")
                line = line.strip()
                if not line.startswith("data:"):
                    continue
                yield line[5:].strip()
        except LlmCancelled:
            raise
        except (socket.timeout, OSError, ValueError) as exc:
            # 取消导致的流中断：静默结束（对齐 dart 的 handleError 分支）
            if self._cancelled:
                raise LlmCancelled("已取消") from exc
            raise LlmError(f"流式连接中断: {exc}", retryable=True) from exc
        finally:
            self._resp = None
            try:
                stream.close()
            except Exception:
                pass

    @staticmethod
    def _trim_err(raw: str) -> str:
        text = (raw or "").strip()
        if not text:
            return "empty response"
        try:
            parsed = json.loads(text)
        except (ValueError, TypeError):
            return text[:400]
        if isinstance(parsed, dict):
            err = parsed.get("error")
            if isinstance(err, dict):
                return str(err.get("message") or err)
            if err is not None:
                return str(err)
        return text[:400]

    # ------------------------------------------------------------------ 三协议
    def _openai_round(self, history, tools, system_prompt, on_text):
        body = {
            "model": self.settings["model"],
            "temperature": self.settings["temperature"],
            "stream": True,
            "messages": [{"role": "system", "content": system_prompt}, *history],
            "tools": [
                {
                    "type": "function",
                    "function": {
                        "name": t["name"],
                        "description": t["description"],
                        "parameters": t["parameters"],
                    },
                }
                for t in tools
            ],
        }
        calls: dict = {}
        text_parts: list = []
        for event in self._post_stream(self._uri("/chat/completions"), body):
            if not event or event == "[DONE]":
                continue
            try:
                chunk = json.loads(event)
            except ValueError:
                continue  # 个别网关会夹带非 JSON 心跳行，跳过
            if not isinstance(chunk, dict):
                continue
            choices = chunk.get("choices")
            if not choices:
                continue
            first = choices[0] if isinstance(choices[0], dict) else {}
            delta = _as_dict(first.get("delta"))
            content = delta.get("content")
            if isinstance(content, str) and content:
                text_parts.append(content)
                if on_text:
                    on_text(content)
            for raw in delta.get("tool_calls") or []:
                item = _as_dict(raw)
                fn = _as_dict(item.get("function"))
                idx = item.get("index")
                idx = idx if isinstance(idx, int) else 0
                slot = calls.setdefault(
                    idx, {"id": item.get("id") or f"call_{idx}", "name": "", "arguments": ""}
                )
                if fn.get("name"):
                    slot["name"] = fn["name"]
                if fn.get("arguments") is not None:
                    slot["arguments"] += fn["arguments"]
            finish = first.get("finish_reason")
            if finish in ("tool_calls", "stop"):
                break
        return self._parse_calls(calls), "".join(text_parts)

    def _responses_round(self, history, tools, system_prompt, on_text):
        body = {
            "model": self.settings["model"],
            "temperature": self.settings["temperature"],
            "stream": True,
            "input": [{"role": "system", "content": system_prompt},
                      *self._to_responses_input(history)],
            "tools": [
                {
                    "type": "function",
                    "name": t["name"],
                    "description": t["description"],
                    "parameters": t["parameters"],
                }
                for t in tools
            ],
        }
        calls: dict = {}  # id -> slot
        order: list = []  # 保持 output_item.added 的出现顺序
        text_parts: list = []
        next_idx = [0]

        def _slot_for(item_id: str):
            for call_id in order:
                if call_id == item_id:
                    return calls[call_id]
            return None

        for event in self._post_stream(self._uri("/responses"), body):
            if not event or event == "[DONE]":
                continue
            try:
                chunk = json.loads(event)
            except ValueError:
                continue
            if not isinstance(chunk, dict):
                continue
            etype = chunk.get("type") or ""
            if etype == "response.output_text.delta":
                delta = chunk.get("delta") or ""
                if delta:
                    text_parts.append(delta)
                    if on_text:
                        on_text(delta)
            elif etype == "response.output_item.added":
                item = _as_dict(chunk.get("item"))
                if item.get("type") == "function_call":
                    call_id = item.get("id") or f"fc_{next_idx[0]}"
                    calls[call_id] = {
                        "id": call_id,
                        "name": item.get("name") or "",
                        "arguments": item.get("arguments") or "",
                    }
                    order.append(call_id)
                    next_idx[0] += 1
            elif etype == "response.output_item.done":
                # 部分网关在 done 事件携带完整 item
                item = _as_dict(chunk.get("item"))
                if item.get("type") == "function_call" and isinstance(item.get("arguments"), str):
                    args = item["arguments"]
                    if args:
                        slot = _slot_for(item.get("id") or "")
                        if slot is None and order:
                            slot = calls[order[-1]]
                        if slot is not None:
                            slot["arguments"] = args
            elif etype == "response.function_call_arguments.delta":
                slot = _slot_for(chunk.get("item_id") or "")
                delta = chunk.get("delta") or ""
                if slot is not None and delta:
                    slot["arguments"] += delta
        parsed = [calls[cid] for cid in order]
        return (
            [
                ToolCall(id=s["id"], name=s["name"], arguments=_try_parse_json(s["arguments"]))
                for s in parsed
            ],
            "".join(text_parts),
        )

    def _anthropic_round(self, history, tools, system_prompt, on_text):
        body = {
            "model": self.settings["model"],
            "temperature": self.settings["temperature"],
            "max_tokens": _MAX_TOKENS_ANTHROPIC,
            "stream": True,
            "system": system_prompt,
            "messages": self._to_anthropic_messages(history),
            "tools": [
                {
                    "name": t["name"],
                    "description": t["description"],
                    "input_schema": t["parameters"],
                }
                for t in tools
            ],
        }
        calls: dict = {}  # id -> slot
        text_parts: list = []
        current_id = None
        for event in self._post_stream(self._uri("/messages"), body):
            if not event:
                continue
            try:
                chunk = json.loads(event)
            except ValueError:
                continue
            if not isinstance(chunk, dict):
                continue
            etype = chunk.get("type") or ""
            if etype == "content_block_start":
                block = _as_dict(chunk.get("content_block"))
                if block.get("type") == "tool_use" and block.get("id") and block.get("name"):
                    current_id = block["id"]
                    calls[current_id] = {
                        "id": current_id,
                        "name": block["name"],
                        "arguments": "",
                    }
            elif etype == "content_block_delta":
                delta = _as_dict(chunk.get("delta"))
                text = delta.get("text")
                if isinstance(text, str) and text:
                    text_parts.append(text)
                    if on_text:
                        on_text(text)
                partial = delta.get("partial_json")
                if isinstance(partial, str) and current_id in calls and partial:
                    calls[current_id]["arguments"] += partial
        parsed = [
            ToolCall(id=s["id"], name=s["name"], arguments=_try_parse_json(s["arguments"]))
            for s in calls.values()
        ]
        return parsed, "".join(text_parts)

    # ------------------------------------------------------------------ 历史格式转换
    @staticmethod
    def _split_data_url(url: str):
        """data URL → (media_type, base64 数据)；非 data URL 原样返回。"""
        if url.startswith("data:"):
            comma = url.find(",")
            if comma > 5:
                meta = url[5:comma]
                semi = meta.find(";")
                media = (meta[:semi] if semi > 0 else meta).strip()
                return (media or "image/png"), url[comma + 1:]
        return "image/png", url

    def _to_anthropic_messages(self, messages: list) -> list:
        """OpenAI 风格消息 → Anthropic messages（content 为 blocks 或字符串）。"""
        out = []
        for m in messages:
            role = m.get("role")
            if role not in ("user", "assistant"):
                continue
            content = m.get("content")
            if isinstance(content, list):
                blocks = []
                for b in content:
                    blk = _as_dict(b)
                    if not blk:
                        continue
                    if blk.get("type") == "image_url":
                        url = (_as_dict(blk.get("image_url")).get("url")) or ""
                        media_type, data = self._split_data_url(url)
                        if not data:
                            continue
                        blocks.append({
                            "type": "image",
                            "source": {"type": "base64", "media_type": media_type, "data": data},
                        })
                    else:
                        blocks.append(blk)
                out.append({"role": role, "content": blocks})
                continue
            if role == "assistant" and isinstance(m.get("tool_calls"), list):
                blocks = []
                if isinstance(content, str) and content:
                    blocks.append({"type": "text", "text": content})
                for tc in m["tool_calls"]:
                    tc_map = _as_dict(tc)
                    if not tc_map:
                        continue
                    fn = _as_dict(tc_map.get("function"))
                    blocks.append({
                        "type": "tool_use",
                        "id": tc_map.get("id") or "toolu_0",
                        "name": fn.get("name") or "",
                        "input": _try_parse_json(fn.get("arguments") or ""),
                    })
                out.append({"role": role, "content": blocks})
                continue
            out.append({"role": role, "content": content if content is not None else ""})
        return out

    def _to_responses_input(self, messages: list) -> list:
        """OpenAI 风格消息 → Responses API input 序列。"""
        out = []
        for m in messages:
            role = m.get("role")
            if role in ("user", "assistant"):
                content = m.get("content")
                if isinstance(content, list):
                    blocks = []
                    for b in content:
                        block = _as_dict(b)
                        if not block:
                            continue
                        btype = block.get("type")
                        if btype == "tool_result":
                            blocks.append({
                                "type": "function_call_output",
                                "call_id": block.get("tool_use_id"),
                                "output": block.get("content"),
                            })
                        elif btype == "text":
                            blocks.append({"type": "input_text", "text": block.get("text") or ""})
                        elif btype == "image_url":
                            url = (_as_dict(block.get("image_url")).get("url")) or ""
                            blocks.append({"type": "input_image", "image_url": url})
                    if blocks:
                        out.extend(blocks)
                    continue
                if role == "assistant" and isinstance(m.get("tool_calls"), list):
                    for tc in m["tool_calls"]:
                        tc_map = _as_dict(tc)
                        if not tc_map:
                            continue
                        fn = _as_dict(tc_map.get("function"))
                        out.append({
                            "type": "function_call",
                            "call_id": tc_map.get("id") or "fc_0",
                            "name": fn.get("name"),
                            "arguments": fn.get("arguments"),
                        })
                    continue
                out.append({"role": role, "content": content if content is not None else ""})
            elif role == "tool":
                out.append({
                    "type": "function_call_output",
                    "call_id": m.get("tool_call_id"),
                    "output": m.get("content"),
                })
        return out

    # ------------------------------------------------------------------ 聚合
    @staticmethod
    def _parse_calls(slots: dict) -> list:
        out = []
        for idx in sorted(slots):
            slot = slots[idx]
            out.append(ToolCall(
                id=slot["id"],
                name=slot["name"],
                arguments=_try_parse_json(slot["arguments"]),
            ))
        return out
