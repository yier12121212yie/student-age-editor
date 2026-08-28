# -*- coding: utf-8 -*-
"""ai_image_service 单测：mock urllib 请求，验证 OpenAI Images API 标准请求构造与响应解析。

运行方式（在 源码/src/src 目录下）：
    python -m unittest editor.server.test_ai_image_service -v
"""
import base64
import json
import unittest
import urllib.error
from unittest import mock

from editor.server import ai_image_service as s


class _FakeResp(object):
    def __init__(self, payload, status=200, headers=None):
        if isinstance(payload, (dict, list)):
            self._raw = json.dumps(payload).encode("utf-8")
        else:
            self._raw = payload
        self._status = status
        self.headers = headers or {"Content-Type": "application/json"}

    def read(self):
        return self._raw

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False

    def close(self):
        pass

    @property
    def code(self):
        return self._status


class GenerateImagesTest(unittest.TestCase):
    def _run(self, api_response, **kwargs):
        """patch urlopen 后调用 generate_images，返回 (result, captured_request)。"""
        captured = {}

        def fake_urlopen(req, timeout=None):
            captured["url"] = req.full_url
            captured["method"] = req.get_method()
            captured["headers"] = dict(req.header_items())
            captured["body"] = req.data
            if isinstance(api_response, Exception):
                raise api_response
            return api_response if isinstance(api_response, _FakeResp) else _FakeResp(api_response)

        with mock.patch("urllib.request.urlopen", side_effect=fake_urlopen):
            result = s.generate_images(api_key="sk-test", **kwargs)
        return result, captured

    def test_generations_b64(self):
        b64 = base64.b64encode(b"\x89PNG-fake").decode("ascii")
        result, req = self._run(
            {"created": 123, "data": [{"b64_json": b64}], "model": "gpt-image-1"},
            prompt="一个校园场景", n=2, size="1024x1024", quality="high",
            style="vivid", background="opaque",
        )
        self.assertEqual(result["images"][0]["b64"], b64)
        self.assertEqual(result["images"][0]["mime"], "image/png")
        self.assertEqual(result["model"], "gpt-image-1")
        # 请求路径 /images/generations + 标准请求体
        self.assertTrue(req["url"].endswith("/images/generations"))
        self.assertEqual(req["method"], "POST")
        self.assertEqual(req["headers"].get("Authorization"), "Bearer sk-test")
        body = json.loads(req["body"])
        self.assertEqual(body["model"], "gpt-image-2")
        self.assertEqual(body["prompt"], "一个校园场景")
        self.assertEqual(body["n"], 2)
        self.assertEqual(body["response_format"], "b64_json")
        self.assertEqual(body["size"], "1024x1024")
        self.assertEqual(body["quality"], "high")
        self.assertEqual(body["style"], "vivid")
        self.assertEqual(body["background"], "opaque")

    def test_generations_url_fallback(self):
        """网关只返回 url 时自动下载转 b64。"""
        url_b64 = base64.b64encode(b"URLIMG").decode("ascii")
        calls = []

        def fake_urlopen(req, timeout=None):
            calls.append(req.full_url)
            if req.full_url.endswith("/images/generations"):
                return _FakeResp({"data": [{"url": "https://cdn/x.png"}]})
            # url 下载
            resp = _FakeResp(b"URLIMG", headers={"Content-Type": "image/png"})
            return resp

        with mock.patch("urllib.request.urlopen", side_effect=fake_urlopen):
            result = s.generate_images(api_key="sk-test", prompt="x")
        self.assertEqual(result["images"][0]["b64"], url_b64)
        self.assertEqual(result["images"][0]["mime"], "image/png")
        self.assertEqual(calls[-1], "https://cdn/x.png")

    def test_upstream_error_message(self):
        err = urllib.error.HTTPError(
            "https://x", 429, "x", {}, _FakeResp(
                {"error": {"message": "Rate limit reached", "type": "rate_limit"}}))
        with self.assertRaises(s.ImageGenError) as ctx:
            self._run(err, prompt="x")
        self.assertIn("429", str(ctx.exception))
        self.assertIn("Rate limit reached", str(ctx.exception))

    def test_gpt_image_2_large_size_allowed(self):
        """gpt-image-2 支持 64 整数倍的任意尺寸（如 2048x2048）。"""
        result, req = self._run(
            {"data": [{"b64_json": "eA=="}]},
            model="gpt-image-2", prompt="x", size="2048x2048",
        )
        body = json.loads(req["body"])
        self.assertEqual(body["model"], "gpt-image-2")
        self.assertEqual(body["size"], "2048x2048")
        self.assertTrue(result["images"])

    def test_dalle_rejects_gpt_size(self):
        """dall-e 系列仍按官方枚举校验，拒绝 2048x2048。"""
        with self.assertRaises(s.ImageGenError) as ctx:
            self._run({"data": []}, model="dall-e-3", prompt="x", size="2048x2048")
        self.assertIn("size", str(ctx.exception))

    def test_gpt_image_rejects_non_multiple_of_64(self):
        """gpt-image 系列尺寸必须是 64 的整数倍。"""
        with self.assertRaises(s.ImageGenError) as ctx:
            self._run({"data": []}, model="gpt-image-2", prompt="x", size="1024x1000")
        self.assertIn("size", str(ctx.exception))


class EditImageTest(unittest.TestCase):
    def test_edits_multipart(self):
        image_b64 = base64.b64encode(b"\x89PNG-orig").decode("ascii")
        out_b64 = base64.b64encode(b"\x89PNG-new").decode("ascii")
        captured = {}

        def fake_urlopen(req, timeout=None):
            captured["url"] = req.full_url
            captured["headers"] = dict(req.header_items())
            captured["body"] = req.data
            return _FakeResp({"created": 9, "data": [{"b64_json": out_b64}]})

        with mock.patch("urllib.request.urlopen", side_effect=fake_urlopen):
            result = s.edit_image(
                api_key="sk-test", prompt="把天空改成夜晚",
                image_b64=image_b64, n=1, size="1024x1024",
            )
        self.assertTrue(captured["url"].endswith("/images/edits"))
        ctype = next((v for k, v in captured["headers"].items()
                      if k.lower() == "content-type"), "")
        self.assertTrue(ctype.startswith("multipart/form-data; boundary="))
        boundary = ctype.split("boundary=")[1]
        body = captured["body"].decode("utf-8", "replace")
        # 字段与文件齐全
        self.assertIn('name="prompt"', body)
        self.assertIn("把天空改成夜晚", body)
        self.assertIn('name="model"', body)
        self.assertIn('name="image"; filename="image.png"', body)
        self.assertIn("Content-Type: image/png", body)
        self.assertIn(b"\x89PNG-orig", captured["body"])
        self.assertIn("--%s--" % boundary, body)
        self.assertEqual(result["images"][0]["b64"], out_b64)

    def test_edits_with_mask(self):
        image_b64 = base64.b64encode(b"A").decode("ascii")
        mask_b64 = base64.b64encode(b"B").decode("ascii")
        captured = {}

        def fake_urlopen(req, timeout=None):
            captured["body"] = req.data
            return _FakeResp({"data": [{"b64_json": "eA=="}]})

        with mock.patch("urllib.request.urlopen", side_effect=fake_urlopen):
            s.edit_image(api_key="k", prompt="x", image_b64=image_b64, mask_b64=mask_b64)
        body = captured["body"].decode("utf-8", "replace")
        self.assertIn('name="mask"; filename="mask.png"', body)
        self.assertIn("B", body)

    def test_edits_missing_image(self):
        with self.assertRaises(s.ImageGenError):
            s.edit_image(api_key="k", prompt="x")


if __name__ == "__main__":
    unittest.main()
