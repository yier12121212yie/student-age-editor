#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""mcp_bridge.py 的单元测试：内置 http.server 模拟模组后端，进程内直接
调用桥的 handle_message，另加一个 stdio 端到端子进程冒烟测试。

运行：python tools/mcp_bridge/test_mcp_bridge.py
"""

import json
import os
import subprocess
import sys
import threading
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, urlparse

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import mcp_bridge  # noqa: E402

BRIDGE_PY = os.path.join(HERE, "mcp_bridge.py")

# 模拟后端收到的请求（method/path/query/body），每个测试前清空
CALLS = []


class MockBackendHandler(BaseHTTPRequestHandler):
    """按真实后端的路由返回固定 JSON，并记录收到的请求。"""

    protocol_version = "HTTP/1.1"

    def log_message(self, *args):  # 静音，避免污染测试输出
        pass

    def _respond(self, code, payload):
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _handle(self, method):
        parsed = urlparse(self.path)
        query = {k: v[0] for k, v in parse_qs(parsed.query, keep_blank_values=True).items()}
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b""
        body = json.loads(raw.decode("utf-8")) if raw else None
        CALLS.append({"method": method, "path": parsed.path,
                      "query": query, "body": body})
        path = parsed.path

        if method == "GET" and path == "/api/ai/domains":
            return self._respond(200, {"domains": [
                {"id": "story", "name": "剧情", "desc": "事件与对话",
                 "tables": {"EvtCfg": "事件", "TalkCfg": "对话"}}]})
        if method == "GET" and path == "/api/ai/dicts":
            if "name" in query:
                return self._respond(200, {"cn": "角色", "total": 1, "items": [
                    {"id": "102", "name": query.get("q", "薛诗蕾")}]})
            return self._respond(200, {"dicts": [{"id": "roles", "name": "角色", "count": 30}]})
        if method == "GET" and path == "/api/ai/domain/items":
            if not query.get("domain"):
                return self._respond(400, {"error": "missing domain"})
            return self._respond(200, {"items": [
                {"cfg": "EvtCfg", "id": 1, "name": "开场", "summary": "…"}]})
        if method == "GET" and path == "/api/ai/domain/item":
            return self._respond(200, {"cfg_cn": "事件", "data": {
                "id": query.get("id"), "title": "开场"}})
        if method == "PUT" and path == "/api/ai/domain/item":
            return self._respond(200, {"changed": True,
                                       "patched_fields": list(body["patch"].keys()),
                                       "data": dict(body["patch"], id=body["id"])})
        if method == "POST" and path == "/api/ai/domain/item":
            return self._respond(200, {"id": body["data"]["id"], "data": body["data"]})
        if method == "DELETE" and path == "/api/ai/domain/item":
            return self._respond(200, {"ok": True, "deleted": query.get("id")})
        if method == "GET" and path == "/api/tools/list":
            return self._respond(200, {"entries": [
                {"name": "Config", "type": "dir"}, {"name": "Config/a.json", "type": "file"}]})
        if method == "GET" and path == "/api/tools/read":
            if query.get("path") == "fail.txt":
                return self._respond(500, {"error": "boom"})
            return self._respond(200, {"text": "hello 模组"})
        if method == "GET" and path == "/api/mods":
            return self._respond(200, {"mods": [{"name": "demo"}, {"name": "base"}]})
        if method == "GET" and path == "/api/ai/stage/dicts":
            return self._respond(200, {"expressions": [{"id": 0, "name": "普通"}],
                                       "actions": [], "positions": [], "roles": []})
        if method == "GET" and path == "/api/ai/stage/roles":
            return self._respond(200, {"desc": "薛诗蕾 居中"})
        if method == "POST" and path == "/api/ai/stage/encode":
            return self._respond(200, {"new_roles": [{"pos": 1, "expr": 0}],
                                       "new_desc": "薛诗蕾 入场到中", "old_desc": ""})
        return self._respond(404, {"error": "no route %s %s" % (method, path)})

    def do_GET(self):
        self._handle("GET")

    def do_POST(self):
        self._handle("POST")

    def do_PUT(self):
        self._handle("PUT")

    def do_DELETE(self):
        self._handle("DELETE")


class BridgeTestCase(unittest.TestCase):
    """进程内测试：直接调用 EditorBridge.handle_message。"""

    @classmethod
    def setUpClass(cls):
        cls.server = HTTPServer(("127.0.0.1", 0), MockBackendHandler)
        cls.backend = "http://127.0.0.1:%d" % cls.server.server_address[1]
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join(timeout=5)

    def setUp(self):
        del CALLS[:]
        self.bridge = mcp_bridge.EditorBridge(backend=self.backend)
        self.write_bridge = mcp_bridge.EditorBridge(backend=self.backend, allow_write=True)

    # ---- 辅助 ----

    def request(self, bridge, method, params=None, rid=1):
        msg = {"jsonrpc": "2.0", "id": rid, "method": method}
        if params is not None:
            msg["params"] = params
        resp = bridge.handle_message(msg)
        self.assertIsNotNone(resp, "带 id 请求必须有响应")
        return resp

    def call_tool(self, bridge, name, arguments=None, rid=1):
        return self.request(bridge, "tools/call",
                            {"name": name, "arguments": arguments or {}}, rid)

    @staticmethod
    def tool_text(resp):
        return resp["result"]["content"][0]["text"]

    # ---- 协议层 ----

    def test_initialize(self):
        resp = self.request(self.bridge, "initialize", {
            "protocolVersion": "2025-03-26", "capabilities": {},
            "clientInfo": {"name": "pytest", "version": "0"},
        })
        result = resp["result"]
        self.assertEqual(resp["id"], 1)
        self.assertEqual(result["protocolVersion"], "2025-03-26")
        self.assertEqual(result["capabilities"], {"tools": {}})
        self.assertEqual(result["serverInfo"]["name"], "student-age-editor-bridge")
        self.assertIn("version", result["serverInfo"])

    def test_initialized_notification_ignored(self):
        self.assertIsNone(self.bridge.handle_message(
            {"jsonrpc": "2.0", "method": "notifications/initialized"}))

    def test_ping(self):
        resp = self.request(self.bridge, "ping")
        self.assertEqual(resp["result"], {})

    def test_unknown_method_returns_32601(self):
        resp = self.request(self.bridge, "resources/list", {}, rid=7)
        self.assertEqual(resp["error"]["code"], -32601)
        self.assertEqual(resp["id"], 7)

    def test_unknown_notification_ignored(self):
        self.assertIsNone(self.bridge.handle_message(
            {"jsonrpc": "2.0", "method": "notifications/cancelled"}))

    def test_parse_error_via_stdio(self):
        # 非法 JSON 行走主循环的解析分支：这里直接验证错误码常量约定
        resp = self.bridge.handle_message("not a dict")
        self.assertEqual(resp["error"]["code"], -32600)

    # ---- tools/list 与 --allow-write 门控 ----

    def test_tools_list_readonly(self):
        resp = self.request(self.bridge, "tools/list")
        names = [t["name"] for t in resp["result"]["tools"]]
        self.assertEqual(names, [
            "list_domains", "get_game_dicts", "list_domain_items", "get_domain_item",
            "list_files", "read_file", "list_mods", "get_stage_dicts", "get_talk_stage",
        ])
        for tool in resp["result"]["tools"]:
            self.assertTrue(tool["description"])
            self.assertEqual(tool["inputSchema"]["type"], "object")

    def test_tools_list_with_write(self):
        resp = self.request(self.write_bridge, "tools/list")
        names = [t["name"] for t in resp["result"]["tools"]]
        self.assertEqual(len(names), 13)
        self.assertIn("update_domain_item", names)
        self.assertIn("create_domain_item", names)
        self.assertIn("delete_domain_item", names)
        self.assertIn("set_talk_stage", names)
        # 生图/改图需 GUI 审批，桥接里一律省略
        self.assertNotIn("generate_image", names)
        self.assertNotIn("edit_image", names)

    def test_required_schemas_match_dart(self):
        by_name = {t["name"]: t for t in
                   self.request(self.write_bridge, "tools/list")["result"]["tools"]}
        self.assertEqual(by_name["list_domain_items"]["inputSchema"]["required"], ["domain"])
        self.assertEqual(by_name["get_domain_item"]["inputSchema"]["required"],
                         ["domain", "cfg", "id"])
        self.assertEqual(by_name["update_domain_item"]["inputSchema"]["required"],
                         ["domain", "cfg", "id", "patch"])
        self.assertEqual(by_name["set_talk_stage"]["inputSchema"]["required"],
                         ["talk_id", "commands"])
        self.assertEqual(by_name["list_files"]["inputSchema"]["properties"]["scope"]["enum"],
                         ["mod", "workspace"])

    def test_write_tool_gated_without_flag(self):
        resp = self.call_tool(self.bridge, "update_domain_item", {
            "domain": "story", "cfg": "EvtCfg", "id": "1", "patch": {"title": "x"}})
        self.assertIn("error", resp)
        self.assertEqual(resp["error"]["code"], -32602)
        self.assertIn("--allow-write", resp["error"]["message"])
        # 门控拦截后绝不应把请求打到后端
        self.assertEqual(CALLS, [])

    def test_unknown_tool_error(self):
        resp = self.call_tool(self.bridge, "no_such_tool")
        self.assertEqual(resp["error"]["code"], -32602)

    # ---- tools/call：只读 ----

    def test_call_list_mods(self):
        resp = self.call_tool(self.bridge, "list_mods")
        self.assertFalse(resp["result"]["isError"])
        self.assertEqual(json.loads(self.tool_text(resp)),
                         {"mods": [{"name": "demo"}, {"name": "base"}]})
        self.assertEqual(CALLS, [{"method": "GET", "path": "/api/mods",
                                  "query": {}, "body": None}])

    def test_call_get_game_dicts_query_passthrough(self):
        resp = self.call_tool(self.bridge, "get_game_dicts",
                              {"name": "roles", "q": "薛", "limit": 5})
        self.assertFalse(resp["result"]["isError"])
        call = CALLS[-1]
        self.assertEqual(call["method"], "GET")
        self.assertEqual(call["path"], "/api/ai/dicts")
        self.assertEqual(call["query"], {"name": "roles", "q": "薛", "limit": "5"})
        self.assertEqual(json.loads(self.tool_text(resp))["items"][0]["name"], "薛")

    def test_call_get_game_dicts_no_params(self):
        resp = self.call_tool(self.bridge, "get_game_dicts")
        self.assertFalse(resp["result"]["isError"])
        self.assertEqual(CALLS[-1]["query"], {})

    def test_call_read_file(self):
        resp = self.call_tool(self.bridge, "read_file", {"path": "Config/a.json"})
        self.assertFalse(resp["result"]["isError"])
        self.assertEqual(CALLS[-1]["query"], {"scope": "mod", "path": "Config/a.json"})

    def test_call_list_files_defaults(self):
        resp = self.call_tool(self.bridge, "list_files")
        self.assertEqual(CALLS[-1]["query"], {"scope": "mod", "path": "", "deep": "1"})
        self.assertIn("entries", json.loads(self.tool_text(resp)))

    def test_http_error_becomes_is_error_result(self):
        resp = self.call_tool(self.bridge, "read_file", {"path": "fail.txt"})
        self.assertTrue(resp["result"]["isError"])
        text = self.tool_text(resp)
        self.assertIn("500", text)
        self.assertIn("boom", text)

    def test_missing_required_argument(self):
        resp = self.call_tool(self.bridge, "get_domain_item", {"domain": "story", "id": "1"})
        self.assertTrue(resp["result"]["isError"])
        self.assertIn("cfg", self.tool_text(resp))
        self.assertEqual(CALLS, [])

    def test_backend_unreachable_is_error(self):
        dead = mcp_bridge.EditorBridge(backend="http://127.0.0.1:1", timeout=3)
        resp = self.call_tool(dead, "list_mods")
        self.assertTrue(resp["result"]["isError"])
        self.assertIn("无法连接后端", self.tool_text(resp))

    # ---- tools/call：写工具（--allow-write） ----

    def test_update_domain_item_put(self):
        resp = self.call_tool(self.write_bridge, "update_domain_item", {
            "domain": "story", "cfg": "EvtCfg", "id": "7", "patch": {"title": "新标题"}})
        self.assertFalse(resp["result"]["isError"])
        call = CALLS[-1]
        self.assertEqual((call["method"], call["path"]), ("PUT", "/api/ai/domain/item"))
        self.assertEqual(call["body"], {"domain": "story", "cfg": "EvtCfg", "id": "7",
                                        "patch": {"title": "新标题"}})
        self.assertEqual(json.loads(self.tool_text(resp))["patched_fields"], ["title"])

    def test_create_domain_item_post(self):
        resp = self.call_tool(self.write_bridge, "create_domain_item", {
            "domain": "role", "cfg": "PersonCfg", "data": {"id": 101, "name": "新角色"}})
        self.assertFalse(resp["result"]["isError"])
        call = CALLS[-1]
        self.assertEqual(call["method"], "POST")
        self.assertEqual(json.loads(self.tool_text(resp))["id"], 101)

    def test_delete_domain_item_uses_query(self):
        resp = self.call_tool(self.write_bridge, "delete_domain_item", {
            "domain": "story", "cfg": "EvtCfg", "id": "3"})
        self.assertFalse(resp["result"]["isError"])
        call = CALLS[-1]
        self.assertEqual(call["method"], "DELETE")
        self.assertEqual(call["query"], {"domain": "story", "cfg": "EvtCfg", "id": "3"})

    def test_empty_patch_rejected(self):
        resp = self.call_tool(self.write_bridge, "update_domain_item", {
            "domain": "story", "cfg": "EvtCfg", "id": "7", "patch": {}})
        self.assertTrue(resp["result"]["isError"])
        self.assertEqual(CALLS, [])

    def test_set_talk_stage_encodes_then_puts(self):
        resp = self.call_tool(self.write_bridge, "set_talk_stage", {
            "talk_id": "55", "commands": [{"action": "入场", "role": "薛诗蕾",
                                           "mode": "滑动", "pos": "左"}],
            "clear": True})
        self.assertFalse(resp["result"]["isError"])
        self.assertEqual([c["method"] + " " + c["path"] for c in CALLS],
                         ["POST /api/ai/stage/encode", "PUT /api/ai/domain/item"])
        encode, put = CALLS
        self.assertEqual(encode["body"]["talk_id"], "55")
        self.assertIs(encode["body"]["clear"], True)
        self.assertEqual(put["body"], {"domain": "story", "cfg": "TalkCfg", "id": "55",
                                       "patch": {"roles": [{"pos": 1, "expr": 0}]}})
        out = json.loads(self.tool_text(resp))
        self.assertEqual(out["talk_id"], "55")
        self.assertEqual(out["new_desc"], "薛诗蕾 入场到中")

    def test_get_talk_stage_readonly(self):
        resp = self.call_tool(self.bridge, "get_talk_stage", {"talk_id": "55"})
        self.assertFalse(resp["result"]["isError"])
        self.assertEqual(CALLS[-1]["query"], {"talk_id": "55"})


class StdioEndToEndTest(unittest.TestCase):
    """以子进程走真正的 stdio 传输：逐行喂 JSON-RPC，收逐行响应。"""

    @classmethod
    def setUpClass(cls):
        cls.server = HTTPServer(("127.0.0.1", 0), MockBackendHandler)
        cls.backend = "http://127.0.0.1:%d" % cls.server.server_address[1]
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join(timeout=5)

    def run_stdio(self, extra_args, methods):
        lines = []
        for rid, msg in enumerate(methods, start=1):
            payload = dict(msg)
            payload.setdefault("jsonrpc", "2.0")
            if not payload["method"].startswith("notifications/"):
                payload.setdefault("id", rid)
            lines.append(json.dumps(payload, ensure_ascii=False))
        proc = subprocess.run(
            [sys.executable, BRIDGE_PY, "--backend", self.backend] + extra_args,
            input="\n".join(lines) + "\n",
            capture_output=True, text=True, encoding="utf-8", timeout=60)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        responses = [json.loads(l) for l in proc.stdout.splitlines() if l.strip()]
        return responses, proc.stderr

    def test_stdio_readonly_session(self):
        responses, _ = self.run_stdio([], [
            {"method": "initialize", "params": {}},
            {"method": "notifications/initialized"},  # 通知，不应有响应
            {"method": "tools/list"},
            {"method": "tools/call", "params": {"name": "list_mods", "arguments": {}}},
        ])
        self.assertEqual([r["id"] for r in responses], [1, 3, 4])  # 通知（rid=2）被跳过
        self.assertEqual(responses[0]["result"]["protocolVersion"], "2025-03-26")
        self.assertEqual(len(responses[1]["result"]["tools"]), 9)
        self.assertFalse(responses[2]["result"]["isError"])
        self.assertIn("demo", responses[2]["result"]["content"][0]["text"])

    def test_stdio_allow_write_and_utf8(self):
        responses, _ = self.run_stdio(["--allow-write"], [
            {"method": "tools/list"},
            {"method": "tools/call", "params": {"name": "read_file",
                                                "arguments": {"path": "Config/a.json"}}},
        ])
        self.assertEqual(len(responses[0]["result"]["tools"]), 13)
        text = responses[1]["result"]["content"][0]["text"]
        self.assertIn("hello 模组", text)  # 中文经 stdout UTF-8 无损往返

    def test_stdio_backend_env_override(self):
        env = dict(os.environ, EDITOR_BACKEND=self.backend)
        proc = subprocess.run(
            [sys.executable, BRIDGE_PY], input=json.dumps(
                {"jsonrpc": "2.0", "id": 1, "method": "tools/call",
                 "params": {"name": "list_mods", "arguments": {}}}) + "\n",
            capture_output=True, text=True, encoding="utf-8", timeout=60, env=env)
        resp = json.loads(proc.stdout.strip())
        self.assertFalse(resp["result"]["isError"])
        self.assertIn("demo", resp["result"]["content"][0]["text"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
