# -*- coding: utf-8 -*-
"""轻量本地 HTTP 服务：线程池 + 正则路由 + JSON 编解码，零第三方依赖。"""
import inspect
import json
import re
import threading
import traceback
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, unquote, urlparse

_JSON_HEADERS = {"Content-Type": "application/json; charset=utf-8"}

# 本机来源校验：仅接受无 Origin（同进程/CLI）或本机地址来源的请求，
# 防止恶意网页通过浏览器跨站调用本地 API。
_ALLOWED_ORIGIN_HOSTS = ("127.0.0.1", "localhost", "::1")
_ALLOWED_HOST_SUFFIXES = ("127.0.0.1", "localhost", "::1")


class ApiRouter(object):
    """(method, path_regex) -> handler。handler 返回 (status_code, payload_dict)。"""

    def __init__(self):
        self._routes = []           # (method, rx, fn, sig) 保留注册顺序
        self._by_method = {}        # method -> [(rx, fn, sig), ...] 避免每请求扫全量
        self._owner_fns = {}        # owner -> set(fn)，插件路由按 owner 注销用

    def route(self, method, pattern, owner=None):
        rx = re.compile(pattern)

        def deco(fn):
            sig = inspect.signature(fn)
            self._routes.append((method, rx, fn, sig))
            self._by_method.setdefault(method, []).append((rx, fn, sig))
            if owner:
                self._owner_fns.setdefault(owner, set()).add(fn)
            return fn

        return deco

    def unregister_owner(self, owner):
        """注销带 owner 标记的全部路由（插件停用/卸载时调用）。返回注销条数。

        注意按 fn 身份过滤：同一函数注册到多个 pattern 会一并注销，
        插件应避免复用同一 handler 注册多条路由。
        """
        fns = self._owner_fns.pop(owner, None)
        if not fns:
            return 0
        before = len(self._routes)
        self._routes = [e for e in self._routes if e[2] not in fns]
        for method in list(self._by_method):
            # _by_method 元组为 (rx, fn, sig)，按 fn(e[1]) 身份过滤
            self._by_method[method] = [e for e in self._by_method[method] if e[1] not in fns]
        return before - len(self._routes)

    def dispatch(self, method, path, query, body):
        bucket = self._by_method.get(method)
        if not bucket:
            return 404, {"error": "no route: %s %s" % (method, path)}
        for rx, fn, sig in bucket:
            mt = rx.fullmatch(path)
            if mt:
                try:
                    kwargs = dict(mt.groupdict())
                    if "_query" in sig.parameters:
                        kwargs["_query"] = query
                    if "_body" in sig.parameters:
                        kwargs["_body"] = body
                    return fn(**kwargs)
                except Exception as e:
                    traceback.print_exc()
                    return 500, {"error": "%s: %s" % (type(e).__name__, e)}
        return 404, {"error": "no route: %s %s" % (method, path)}


def _host_without_port(value):
    """Host 头去端口：先剥 IPv6 方括号，再按最后一个冒号分离端口。

    直接 split(":")[0] 会把 "[::1]:8765" 解析成 "["，误拒合法的
    http://[::1]:port 本机访问。
    """
    v = (value or "").strip().lower()
    if v.startswith("["):
        end = v.find("]")
        return v[1:end] if end > 0 else v
    return v.rsplit(":", 1)[0] if ":" in v else v


class _ApiRequestHandler(BaseHTTPRequestHandler):
    router = None
    protocol_version = "HTTP/1.1"
    # keep-alive 空闲超时：Dart 客户端默认复用连接，无超时会长期占住工作线程。
    # 超时后 BaseHTTPRequestHandler 关闭本连接（socket.timeout 被其内部处理）。
    timeout = 65
    # 响应是否已开始发送（B11：兜底 500 不得在响应已部分发出后再补一份）
    _responded = False

    def log_message(self, fmt, *args):
        pass  # 静默，避免刷屏

    def _check_origin(self):
        """拒绝跨站来源：校验 Host 与 Origin。"""
        host = _host_without_port(self.headers.get("Host"))
        if host not in _ALLOWED_HOST_SUFFIXES:
            return False, "forbidden host"
        origin = self.headers.get("Origin")
        if origin:
            try:
                from urllib.parse import urlparse as _up
                ohost = _up(origin).hostname or ""
            except Exception:
                ohost = ""
            if ohost.lower() not in _ALLOWED_ORIGIN_HOSTS:
                return False, "forbidden origin"
        return True, ""

    def _handle(self):
        # 整个请求处理兜底：Content-Length 非法、负载无法序列化等异常
        # 若逃逸出去，本连接将无任何响应直接断开（keep-alive 客户端挂起），
        # 插件路由返回不受约束，更必须保证总能回一个 JSON。
        self._responded = False
        try:
            self._handle_inner()
        except Exception:
            traceback.print_exc()
            # B11：响应可能已部分发出（headers/body 已写一半），此时再补一份
            # 500 会让 keep-alive 流上多出一个越界响应；只有还没响应过才兜底
            if not self._responded:
                self._respond(500, {"error": "internal server error"})

    def _handle_inner(self):
        parsed = urlparse(self.path)
        path = unquote(parsed.path)
        query = {k: v[-1] for k, v in parse_qs(parsed.query).items()}
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            self._respond(400, {"error": "invalid Content-Length"})
            return
        length = max(0, length)
        raw = self.rfile.read(length) if length else b""
        body = None
        if raw:
            try:
                body = json.loads(raw.decode("utf-8"))
            except Exception:
                body = {"_raw": raw.decode("utf-8", "replace")}
        ok, reason = self._check_origin()
        if not ok:
            status, payload = 403, {"error": reason}
        else:
            status, payload = self.router.dispatch(self.command, path, query, body)
        self._respond(status, payload)

    def _respond(self, status, payload):
        self._responded = True
        if isinstance(payload, (bytes, bytearray)):
            # 免序列化出口：大表读路径命中缓存时 handler 直接给现成字节，
            # 跳过 json.dumps（40MB 表序列化秒级，缓存命中本就该零编码）。
            data = bytes(payload)
        else:
            try:
                data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
            except Exception:
                status, data = 500, json.dumps({"error": "non-serializable response"}).encode("utf-8")
        try:
            self.send_response(status)
            for k, v in _JSON_HEADERS.items():
                self.send_header(k, v)
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("Access-Control-Allow-Origin", "http://127.0.0.1")
            self.send_header("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS")
            self.send_header("Access-Control-Allow-Headers", "Content-Type")
            self.end_headers()
            self.wfile.write(data)
        except Exception:
            pass  # 连接已断，无法再响应

    def do_GET(self):
        self._handle()

    def do_POST(self):
        self._handle()

    def do_PUT(self):
        self._handle()

    def do_DELETE(self):
        self._handle()

    def do_OPTIONS(self):
        # B12：预检与普通请求同一套本机来源校验，不再无条件回 * 放行跨站
        self._responded = False
        ok, reason = self._check_origin()
        if not ok:
            self._respond(403, {"error": reason})
            return
        self._responded = True
        try:
            self.send_response(204)
            for k, v in _JSON_HEADERS.items():
                self.send_header(k, v)
            self.send_header("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS")
            self.send_header("Access-Control-Allow-Headers", "Content-Type")
            self.send_header("Content-Length", "0")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Access-Control-Allow-Origin", "http://127.0.0.1")
            self.end_headers()
        except Exception:
            pass


def run_server(router, host="127.0.0.1", port=0, on_ready=None, daemon=True):
    """在后台线程启动 HTTP 服务；返回 (thread, port)，port=0 时自动选择可用端口。"""
    _ApiRequestHandler.router = router

    class _Server(ThreadingHTTPServer):
        daemon_threads = True
        allow_reuse_address = False
        max_threads = 64  # B13：并发连接上限，超过直接回 503，防止线程被占满

        def process_request(self, request, client_address):
            if not self._slots.acquire(blocking=False):
                try:
                    request.sendall(
                        b"HTTP/1.1 503 Service Unavailable\r\n"
                        b"Content-Length: 0\r\nConnection: close\r\n\r\n")
                except OSError:
                    pass
                self.shutdown_request(request)
                return
            try:
                super().process_request(request, client_address)
            except Exception:
                self._slots.release()
                raise

        def process_request_thread(self, request, client_address):
            try:
                super().process_request_thread(request, client_address)
            finally:
                self._slots.release()

    _Server._slots = threading.BoundedSemaphore(_Server.max_threads)
    srv = _Server((host, port), _ApiRequestHandler)
    actual_port = srv.server_address[1]

    def serve():
        srv.serve_forever()

    t = threading.Thread(target=serve, name="api-server", daemon=daemon)
    t.start()
    if on_ready:
        on_ready(actual_port)
    return t, actual_port
