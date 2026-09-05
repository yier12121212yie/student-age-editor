# -*- coding: utf-8 -*-
"""httpd 底层单测：Host 解析（含 IPv6 方括号）、整请求兜底
（畸形 Content-Length / handler 违约返回 / 不可序列化负载都必须得到
JSON 响应，而不是静默掐断连接让 keep-alive 客户端挂起）。

运行方式（在 backend 目录下）：
    python -m pytest editor/server/test_httpd.py -q
"""
import json
import socket
import unittest

from editor.server import httpd


class HostWithoutPortTest(unittest.TestCase):
    def test_ipv6_with_port(self):
        self.assertEqual(httpd._host_without_port("[::1]:8765"), "::1")

    def test_ipv6_without_port(self):
        self.assertEqual(httpd._host_without_port("[::1]"), "::1")

    def test_ipv4_with_port(self):
        self.assertEqual(httpd._host_without_port("127.0.0.1:8765"), "127.0.0.1")

    def test_bare_host(self):
        self.assertEqual(httpd._host_without_port("localhost"), "localhost")

    def test_case_normalized(self):
        self.assertEqual(httpd._host_without_port("LOCALHOST:80"), "localhost")


def _request(port, lines):
    """裸 socket 发一条 HTTP 请求，读回完整响应文本（含状态行）。"""
    s = socket.create_connection(("127.0.0.1", port), timeout=5)
    try:
        s.sendall(("\r\n".join(lines) + "\r\n\r\n").encode())
        chunks = []
        while True:
            try:
                c = s.recv(4096)
            except socket.timeout:
                break
            if not c:
                break
            chunks.append(c)
            data = b"".join(chunks)
            if b"\r\n\r\n" in data:
                head, _, body = data.partition(b"\r\n\r\n")
                cl = None
                for line in head.split(b"\r\n"):
                    if line.lower().startswith(b"content-length:"):
                        cl = int(line.split(b":", 1)[1])
                if cl is not None and len(body) >= cl:
                    break
        return b"".join(chunks).decode("latin-1")
    finally:
        s.close()


def _status_json(raw):
    head, _, body = raw.partition("\r\n\r\n")
    status = int(head.split(" ")[1])
    try:
        payload = json.loads(body)
    except ValueError:
        payload = None
    return status, payload


class ServerFallbackTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        r = httpd.ApiRouter()

        @r.route("GET", r"/ok")
        def ok():
            return 200, {"ok": True}

        @r.route("GET", r"/junk")
        def junk():
            return 200, {"bad": object()}  # 不可序列化：插件路由不受约束的真实写照

        @r.route("GET", r"/broken")
        def broken():
            return None  # 违反 (status, payload) 契约

        _t, cls.port = httpd.run_server(r)

    def _get(self, path, host=None, extra=None):
        lines = ["GET %s HTTP/1.1" % path,
                 "Host: %s" % (host or "127.0.0.1:%d" % self.port),
                 "Connection: close"]
        if extra:
            lines += extra
        return _request(self.port, lines)

    def test_normal_request(self):
        status, payload = _status_json(self._get("/ok"))
        self.assertEqual((status, payload), (200, {"ok": True}))

    def test_ipv6_host_accepted(self):
        # 曾经的误杀："[::1]:port".split(":")[0] == "[" → 403
        status, _ = _status_json(self._get("/ok", host="[::1]:%d" % self.port))
        self.assertEqual(status, 200)

    def test_bad_content_length_returns_400(self):
        raw = self._get("/ok", extra=["Content-Length: abc"])
        self.assertTrue(raw, "必须得到响应而非静默断连")
        status, payload = _status_json(raw)
        self.assertEqual(status, 400)
        self.assertIn("Content-Length", payload.get("error", ""))

    def test_non_serializable_payload_falls_back_to_500(self):
        status, payload = _status_json(self._get("/junk"))
        self.assertEqual(status, 500)
        self.assertIn("non-serializable", payload.get("error", ""))

    def test_handler_contract_violation_falls_back_to_500(self):
        status, _ = _status_json(self._get("/broken"))
        self.assertEqual(status, 500)


if __name__ == "__main__":
    unittest.main()
