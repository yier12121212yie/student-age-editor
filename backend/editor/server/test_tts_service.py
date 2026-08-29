# -*- coding: utf-8 -*-
"""tts_service 单测：mock urllib 请求，验证两家配音供应商的请求构造、响应
解析、音色列表兜底、错误映射与 ogg 编码器探测。

运行方式（在 backend 目录下）：
    python -m unittest editor.server.test_tts_service -v
"""
import base64
import json
import unittest
import urllib.error
from unittest import mock

from editor.server import tts_service as s


class _FakeResp(object):
    """可迭代的流式响应（模拟 SSE），同时具备 read()/close()。"""

    def __init__(self, payload, status=200):
        if isinstance(payload, bytes):
            self._raw = payload
        elif isinstance(payload, str):
            self._raw = payload.encode("utf-8")
        else:
            self._raw = json.dumps(payload).encode("utf-8")
        self._status = status
        self._lines = None

    def read(self):
        return self._raw

    def __iter__(self):
        if self._lines is None:
            text = self._raw.decode("utf-8", "replace")
            self._lines = [ln.encode("utf-8") for ln in text.splitlines()]
        return iter(self._lines)

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False

    def close(self):
        pass

    @property
    def code(self):
        return self._status


def _cfg(**over):
    base = {
        "ttsProvider": "minimax",
        "ttsApiKey": "tk_test",
        "ttsGroupId": "grp1",
        "ttsModel": "",
        "ttsVoice": "",
        "ttsBaseUrl": "",
        "ttsSpeed": 1.0,
        "ttsVolume": 1.0,
        "ttsPitch": 0,
    }
    base.update(over)
    return base


class SynthesizeCommonTest(unittest.TestCase):
    def test_empty_text_rejected(self):
        with self.assertRaises(s.TtsError) as cm:
            s.synthesize("minimax", "   ", None, _cfg())
        self.assertIn("不能为空", str(cm.exception))

    def test_bad_provider_rejected(self):
        with self.assertRaises(s.TtsError):
            s.synthesize("openai", "hello", None, _cfg())

    def test_missing_key_rejected(self):
        with self.assertRaises(s.TtsError) as cm:
            s.synthesize("minimax", "hello", None, _cfg(ttsApiKey=""))
        self.assertIn("API Key", str(cm.exception))


class MiniMaxSynthesizeTest(unittest.TestCase):
    def _run(self, api_payload, settings=None, text="你好", voice="f1", params=None):
        captured = {}

        def fake_urlopen(req, timeout=None):
            captured["url"] = req.full_url
            captured["headers"] = dict(req.header_items())
            captured["body"] = json.loads(req.data.decode("utf-8"))
            return _FakeResp(api_payload)

        with mock.patch("urllib.request.urlopen", side_effect=fake_urlopen):
            result = s.synthesize("minimax", text, voice, settings or _cfg(),
                                  params or {})
        return result, captured

    def test_happy_path(self):
        raw = b"RIFF....WAVEfmt"
        payload = {"base_resp": {"status_code": 0},
                   "data": {"audio": base64.b64encode(raw).decode("ascii")}}
        (audio, ext), captured = self._run(payload)
        self.assertEqual(audio, raw)
        self.assertEqual(ext, "wav")
        self.assertTrue(captured["url"].startswith(
            "https://api.minimax.chat/v1/t2a_v2?GroupId=grp1"))
        self.assertEqual(captured["headers"]["Authorization"], "Bearer tk_test")
        body = captured["body"]
        self.assertEqual(body["model"], "speech-02-hd")
        self.assertEqual(body["voice_setting"]["voice_id"], "f1")
        self.assertEqual(body["audio_setting"]["format"], "wav")

    def test_custom_model_and_params(self):
        raw = b"x"
        payload = {"base_resp": {"status_code": 0},
                   "data": {"audio": base64.b64encode(raw).decode("ascii")}}
        settings = _cfg(ttsModel="speech-02-turbo", ttsBaseUrl="https://gw.example.com/v1")
        (_, _), captured = self._run(payload, settings=settings, params={"speed": 1.5})
        # base 末尾的 /v1 应被去掉后再拼接口路径，精确断言防 /v1/v1 复发
        self.assertEqual(captured["url"],
                         "https://gw.example.com/v1/t2a_v2?GroupId=grp1")
        self.assertEqual(captured["body"]["model"], "speech-02-turbo")
        self.assertEqual(captured["body"]["voice_setting"]["speed"], 1.5)

    def test_base_url_ending_with_v1_not_duplicated(self):
        # MiniMax 文档常见写法 base=.../v1：不得拼出 /v1/v1/t2a_v2（上游 404）
        raw = b"x"
        payload = {"base_resp": {"status_code": 0},
                   "data": {"audio": base64.b64encode(raw).decode("ascii")}}
        settings = _cfg(ttsBaseUrl="https://api.minimax.chat/v1")
        (_, _), captured = self._run(payload, settings=settings)
        self.assertEqual(captured["url"],
                         "https://api.minimax.chat/v1/t2a_v2?GroupId=grp1")

    def test_non_dict_params_treated_as_empty(self):
        # 非 dict 的 params 应被当成空参数处理，而不是 .get() 抛 AttributeError
        raw = b"x"
        payload = {"base_resp": {"status_code": 0},
                   "data": {"audio": base64.b64encode(raw).decode("ascii")}}
        (audio, ext), captured = self._run(payload, params="oops")
        self.assertEqual(audio, raw)
        self.assertEqual(ext, "wav")
        self.assertEqual(captured["body"]["voice_setting"]["speed"], 1.0)

    def test_non_dict_settings_treated_as_empty(self):
        # 非 dict 的 settings 同样防御：等价于未配置，应报缺失 API Key
        with self.assertRaises(s.TtsError) as cm:
            s.synthesize("minimax", "hi", None, "not-a-dict")
        self.assertIn("API Key", str(cm.exception))

    def test_upstream_error_mapped(self):
        payload = {"base_resp": {"status_code": 1004, "status_msg": "auth failed"}}
        with self.assertRaises(s.TtsError) as cm:
            self._run(payload)
        self.assertIn("auth failed", str(cm.exception))

    def test_http_error_mapped(self):
        def fake_urlopen(req, timeout=None):
            err = urllib.error.HTTPError(req.full_url, 401, "Unauthorized", {},
                                         _FakeResp({"error": {"message": "bad key"}}))
            raise err

        with mock.patch("urllib.request.urlopen", side_effect=fake_urlopen):
            with self.assertRaises(s.TtsError) as cm:
                s.synthesize("minimax", "hi", None, _cfg())
        self.assertIn("401", str(cm.exception))
        self.assertIn("bad key", str(cm.exception))

    def test_missing_group_id(self):
        with self.assertRaises(s.TtsError) as cm:
            s.synthesize("minimax", "hi", None, _cfg(ttsGroupId=""))
        self.assertIn("GroupId", str(cm.exception))


class AliyunSynthesizeTest(unittest.TestCase):
    SSE_HAPPY = (
        'data: {"output": {"audio": "%s"}}\n\n'
        'data: {"output": {"audio": "%s"}}\n\n'
        'data: {"output": {"text": ""}, "usage": {"total_tokens": 3}}\n\n'
    )

    def _run(self, sse_text, settings=None, text="你好", voice="Cherry"):
        captured = {}

        def fake_urlopen(req, timeout=None):
            captured["url"] = req.full_url
            captured["headers"] = dict(req.header_items())
            captured["body"] = json.loads(req.data.decode("utf-8"))
            return _FakeResp(sse_text)

        with mock.patch("urllib.request.urlopen", side_effect=fake_urlopen):
            result = s.synthesize("aliyun", text, voice, settings or _cfg(ttsProvider="aliyun"))
        return result, captured

    def test_happy_path_aggregates_chunks(self):
        chunk1 = b"\x00\x01"
        chunk2 = b"\x02\x03"
        sse = self.SSE_HAPPY % (base64.b64encode(chunk1).decode(),
                                base64.b64encode(chunk2).decode())
        (audio, ext), captured = self._run(sse)
        self.assertEqual(audio, chunk1 + chunk2)
        self.assertEqual(ext, "wav")
        self.assertTrue(captured["url"].startswith("https://dashscope.aliyuncs.com"))
        self.assertEqual(captured["headers"]["Authorization"], "Bearer tk_test")
        self.assertEqual(captured["body"]["model"], "qwen-tts")
        self.assertEqual(captured["body"]["input"]["voice"], "Cherry")

    def test_error_event_raises(self):
        sse = 'data: {"result": "failed", "message": "invalid voice"}\n\n'
        with self.assertRaises(s.TtsError) as cm:
            self._run(sse)
        self.assertIn("invalid voice", str(cm.exception))

    def test_no_audio_chunks(self):
        sse = 'data: {"output": {"text": "x"}}\n\n'
        with self.assertRaises(s.TtsError) as cm:
            self._run(sse)
        self.assertIn("未返回音频", str(cm.exception))

    def test_http_error_mapped(self):
        def fake_urlopen(req, timeout=None):
            err = urllib.error.HTTPError(req.full_url, 400, "Bad Request", {},
                                         _FakeResp({"error": {"message": "bad text"}}))
            raise err

        with mock.patch("urllib.request.urlopen", side_effect=fake_urlopen):
            with self.assertRaises(s.TtsError) as cm:
                s.synthesize("aliyun", "hi", None, _cfg(ttsProvider="aliyun"))
        self.assertIn("400", str(cm.exception))


class ListVoicesTest(unittest.TestCase):
    def test_minimax_fallback_preset(self):
        voices, source = s.list_voices("minimax", _cfg(ttsGroupId=""))
        self.assertEqual(source, "preset")
        self.assertTrue(voices)
        self.assertTrue(all(v.get("id") for v in voices))

    def test_minimax_live_mapping(self):
        payload = {"data": {"voice_list": [
            {"voice_id": "v1", "name": "音色一", "gender": 0},
            {"voice_id": "v2", "name": "音色二", "gender": 1},
        ], "custom_voice_list": [{"voice_id": "cv1", "name": "定制"}]}}

        def fake_urlopen(req, timeout=None):
            return _FakeResp(payload)

        with mock.patch("urllib.request.urlopen", side_effect=fake_urlopen):
            voices, source = s.list_voices("minimax", _cfg())
        self.assertEqual(source, "live")
        self.assertEqual([v["id"] for v in voices], ["v1", "v2", "cv1"])
        self.assertEqual(voices[0]["gender"], "女")
        self.assertEqual(voices[1]["gender"], "男")
        self.assertIn("自定义", voices[2]["desc"])

    def test_minimax_live_failure_falls_back(self):
        def fake_urlopen(req, timeout=None):
            raise urllib.error.URLError("network down")

        with mock.patch("urllib.request.urlopen", side_effect=fake_urlopen):
            voices, source = s.list_voices("minimax", _cfg())
        self.assertEqual(source, "preset")
        self.assertTrue(voices)

    def test_minimax_live_url_no_double_v1(self):
        payload = {"data": {"voice_list": [{"voice_id": "v1"}]}}
        captured = {}

        def fake_urlopen(req, timeout=None):
            captured["url"] = req.full_url
            return _FakeResp(payload)

        with mock.patch("urllib.request.urlopen", side_effect=fake_urlopen):
            voices, source = s.list_voices(
                "minimax", _cfg(ttsBaseUrl="https://api.minimax.chat/v1"))
        self.assertEqual(source, "live")
        self.assertEqual(captured["url"],
                         "https://api.minimax.chat/v1/t2a_v2/voice_list?GroupId=grp1")

    def test_aliyun_qwen_preset(self):
        voices, source = s.list_voices("aliyun", _cfg(ttsProvider="aliyun"))
        self.assertEqual(source, "preset")
        ids = [v["id"] for v in voices]
        self.assertIn("Cherry", ids)
        self.assertNotIn("longxiaochun", ids)

    def test_aliyun_cosyvoice_preset(self):
        voices, _ = s.list_voices("aliyun", _cfg(ttsProvider="aliyun", ttsModel="cosyvoice-v2"))
        ids = [v["id"] for v in voices]
        self.assertIn("longxiaochun", ids)

    def test_unknown_provider(self):
        with self.assertRaises(s.TtsError):
            s.list_voices("foo", {})


class TestConnectionTest(unittest.TestCase):
    def test_minimax_ok(self):
        payload = {"data": {"voice_list": [{"voice_id": "v1"}]}}

        def fake_urlopen(req, timeout=None):
            return _FakeResp(payload)

        with mock.patch("urllib.request.urlopen", side_effect=fake_urlopen):
            result = s.test_connection("minimax", _cfg())
        self.assertTrue(result["ok"])

    def test_aliyun_failure_message(self):
        def fake_urlopen(req, timeout=None):
            raise urllib.error.URLError("dns error")

        with mock.patch("urllib.request.urlopen", side_effect=fake_urlopen):
            result = s.test_connection("aliyun", _cfg(ttsProvider="aliyun"))
        self.assertFalse(result["ok"])
        self.assertIn("dns error", result["error"])


class OggEncodeTest(unittest.TestCase):
    def test_detect_encoder_falls_back_gracefully(self):
        with mock.patch("editor.server.tts_service.shutil.which",
                        return_value=None):
            self.assertEqual(s.detect_encoder(), "")

    def test_detect_encoder_miss_not_cached(self):
        # 未命中不落缓存：恢复环境后仍会重新探测，不污染同进程后续调用/测试
        old = s._encoder_cache
        s._encoder_cache = None
        try:
            with mock.patch("editor.server.tts_service.shutil.which",
                            return_value=None):
                self.assertEqual(s.detect_encoder(), "")
            self.assertIsNone(s._encoder_cache)
        finally:
            s._encoder_cache = old

    def test_encode_without_encoder_returns_none(self):
        with mock.patch("editor.server.tts_service.detect_encoder",
                        return_value=""):
            self.assertIsNone(s.encode_ogg(b"RIFF...."))


if __name__ == "__main__":
    unittest.main()