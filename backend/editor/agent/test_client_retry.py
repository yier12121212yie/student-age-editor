# -*- coding: utf-8 -*-
"""LlmClient.round() 自动重连单测：连接失败 / 流中断 / 429、5xx 重试、
不可重试错误直抛、LlmCancelled 永不重试、退避可中断。

运行方式（在 backend 目录下）：
    python -m unittest editor.agent.test_client_retry -v
"""
import io
import urllib.error
import urllib.request
import unittest
from http.client import HTTPMessage
from unittest import mock

from editor.agent import LlmClient, LlmError, LlmCancelled

_EVENT_STOP = '{"choices": [{"delta": {"content": "回复"}, "finish_reason": "stop"}]}'


def _settings(**overrides):
    base = {
        "provider": "openai_compatible",
        "baseUrl": "http://fake",
        "apiKey": "test-key",
        "model": "test-model",
        "temperature": 0.7,
        "maxRetries": 3,
        "retryDelayMs": 1,
    }
    base.update(overrides)
    return base


class _BrokenLineStream:
    """先产出一行 data，再抛 OSError 模拟流中断；close 幂等。"""

    def __init__(self):
        self._sent = False
        self.closed = False

    def __iter__(self):
        return self

    def __next__(self):
        if self._sent:
            raise OSError("connection reset")
        self._sent = True
        return "data: {\"x\": 1}\n"

    def close(self):
        self.closed = True


class RetryRoundTest(unittest.TestCase):
    def test_connect_failure_then_success_retries(self):
        client = LlmClient(_settings(maxRetries=3, retryDelayMs=1))
        retries = []
        with mock.patch.object(
            LlmClient, "_post_stream",
            side_effect=[
                LlmError("连接失败: boom", retryable=True),
                [_EVENT_STOP],
            ],
        ):
            calls, text = client.round(
                [{"role": "user", "content": "x"}], [], "sys",
                on_retry=lambda a, t, r: retries.append((a, t, r)))
        self.assertEqual((calls, text), ([], "回复"))
        self.assertEqual(retries, [(1, 3, "连接失败: boom")])

    def test_mid_stream_break_retries_and_reexports_partial(self):
        client = LlmClient(_settings(maxRetries=3, retryDelayMs=1))
        deltas = []

        def _burst():
            yield '{"choices": [{"delta": {"content": "（前"}, "finish_reason": null}]}'
            raise LlmError("流式连接中断: reset", retryable=True)

        with mock.patch.object(LlmClient, "_post_stream",
                               side_effect=[_burst(), [_EVENT_STOP]]):
            calls, text = client.round(
                [{"role": "user", "content": "x"}], [], "sys", on_text=deltas.append)
        self.assertEqual(text, "回复")
        # 第二尝试重新生成：第一尝试的半截 delta 也经过了 on_text（UI 据此显示重连提示）
        self.assertEqual(deltas, ["（前", "回复"])

    def test_exhausted_retries_raises(self):
        client = LlmClient(_settings(maxRetries=2, retryDelayMs=1))
        retries = []
        with mock.patch.object(
            LlmClient, "_post_stream",
            side_effect=LlmError("连接失败: boom", retryable=True),
        ):
            with self.assertRaises(LlmError) as ctx:
                client.round([{"role": "user", "content": "x"}], [], "sys",
                             on_retry=lambda a, t, r: retries.append((a, t, r)))
        self.assertIn("连接失败", str(ctx.exception))
        self.assertEqual(retries, [(1, 2, "连接失败: boom"), (2, 2, "连接失败: boom")])

    def test_zero_max_retries_no_retry(self):
        client = LlmClient(_settings(maxRetries=0, retryDelayMs=1))
        retries = []
        with mock.patch.object(
            LlmClient, "_post_stream",
            side_effect=LlmError("连接失败: boom", retryable=True),
        ):
            with self.assertRaises(LlmError):
                client.round([{"role": "user", "content": "x"}], [], "sys",
                             on_retry=lambda a, t, r: retries.append(a))
        self.assertEqual(retries, [])

    def test_non_retryable_error_raises_immediately(self):
        # HTTP 401 等 4xx 由 _post_stream 标注 retryable=False，不得重试
        client = LlmClient(_settings(maxRetries=3, retryDelayMs=1))
        retries = []
        with mock.patch.object(
            LlmClient, "_post_stream",
            side_effect=LlmError("HTTP 401: unauthorized", retryable=False),
        ):
            with self.assertRaises(LlmError):
                client.round([{"role": "user", "content": "x"}], [], "sys",
                             on_retry=lambda a, t, r: retries.append(a))
        self.assertEqual(retries, [])

    def test_anthropic_round_also_retried(self):
        count = {"n": 0}

        def _flaky(*_args, **_kwargs):
            count["n"] += 1
            if count["n"] == 1:
                raise LlmError("流式连接中断: reset", retryable=True)
            return ['{"type": "content_block_delta", "delta": {"text": "hi"}}']

        client = LlmClient(_settings(provider="anthropic", maxRetries=2, retryDelayMs=1))
        retries = []
        with mock.patch.object(LlmClient, "_post_stream", side_effect=_flaky):
            calls, text = client.round(
                [{"role": "user", "content": "x"}], [], "sys",
                on_retry=lambda a, t, r: retries.append((a, t)))
        self.assertEqual((calls, text), ([], "hi"))
        self.assertEqual(retries, [(1, 2)])

    def test_cancel_during_backoff_aborts(self):
        # maxRetries/退避区间很大，但 on_retry 里 cancel 后应立刻抛 LlmCancelled，
        # 而不是把长退避睡完；测试本身快速结束即验证了可中断性。
        client = LlmClient(_settings(maxRetries=3, retryDelayMs=10000))
        retries = []

        def on_retry(attempt, total, reason):
            retries.append((attempt, total))
            client.cancel()

        with mock.patch.object(
            LlmClient, "_post_stream",
            side_effect=LlmError("连接失败: boom", retryable=True),
        ):
            with self.assertRaises(LlmCancelled):
                client.round([{"role": "user", "content": "x"}], [], "sys",
                             on_retry=on_retry)
        self.assertEqual(retries, [(1, 3)])

    def test_cancelled_never_retried(self):
        client = LlmClient(_settings(maxRetries=3, retryDelayMs=1))
        retries = []
        with mock.patch.object(
            LlmClient, "_post_stream",
            side_effect=LlmCancelled("已取消"),
        ):
            with self.assertRaises(LlmCancelled):
                client.round([{"role": "user", "content": "x"}], [], "sys",
                             on_retry=lambda a, t, r: retries.append(a))
        self.assertEqual(retries, [])

    def test_backoff_delay_computation(self):
        client = LlmClient(_settings())
        self.assertEqual(client._retry_delay_ms(1, 1000, None), 1000)
        self.assertEqual(client._retry_delay_ms(2, 1000, None), 2000)
        self.assertEqual(client._retry_delay_ms(3, 1000, None), 4000)
        # 指数退避封顶 10s（attempt 5 应为 16000 → 10000）
        self.assertEqual(client._retry_delay_ms(5, 1000, None), 10000)
        # 429 的 Retry-After 优先于退避计算
        self.assertEqual(client._retry_delay_ms(1, 1000, 5.0), 5000)
        # 退避本身比 Retry-After 更长时取退避
        self.assertEqual(client._retry_delay_ms(5, 1000, 2.0), 10000)
        # retryDelayMs=0 不额外等待
        self.assertEqual(client._retry_delay_ms(1, 0, None), 0)


class ErrorMarkingTest(unittest.TestCase):
    """_post_stream / _iter_sse 对错误的 retryable 标注与 Retry-After 解析。"""

    def test_http_429_marked_retryable_with_retry_after(self):
        client = LlmClient(_settings())
        hdrs = HTTPMessage()
        hdrs["Retry-After"] = "5"
        err = urllib.error.HTTPError(
            "http://fake/chat/completions", 429, "Too Many Requests",
            hdrs, io.BytesIO(b'{"error": {"message": "slow down"}}'))
        with mock.patch.object(urllib.request, "urlopen", side_effect=err):
            with self.assertRaises(LlmError) as ctx:
                client._post_stream("http://fake/chat/completions", {})
        self.assertTrue(ctx.exception.retryable)
        self.assertEqual(ctx.exception.retry_after, 5.0)

    def test_http_401_not_retryable(self):
        client = LlmClient(_settings())
        err = urllib.error.HTTPError(
            "http://fake/chat/completions", 401, "Unauthorized",
            HTTPMessage(), io.BytesIO(b'{"error": {"message": "bad key"}}'))
        with mock.patch.object(urllib.request, "urlopen", side_effect=err):
            with self.assertRaises(LlmError) as ctx:
                client._post_stream("http://fake/chat/completions", {})
        self.assertFalse(ctx.exception.retryable)
        self.assertIsNone(ctx.exception.retry_after)

    def test_connect_failure_marked_retryable(self):
        client = LlmClient(_settings())
        with mock.patch.object(
            urllib.request, "urlopen",
            side_effect=urllib.error.URLError("connection refused"),
        ):
            with self.assertRaises(LlmError) as ctx:
                client._post_stream("http://fake/chat/completions", {})
        self.assertTrue(ctx.exception.retryable)
        self.assertIn("连接失败", str(ctx.exception))

    def test_midstream_break_marked_retryable(self):
        client = LlmClient(_settings())
        stream = _BrokenLineStream()
        with self.assertRaises(LlmError) as ctx:
            list(client._iter_sse(stream))
        self.assertTrue(ctx.exception.retryable)
        self.assertIn("流式连接中断", str(ctx.exception))
        self.assertTrue(stream.closed)  # finally 仍收尾关闭底层流


if __name__ == "__main__":
    unittest.main()