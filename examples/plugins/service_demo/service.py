# -*- coding: utf-8 -*-
"""HTTP 服务插件示例（PLUGIN_GUIDE §5）。

与 manifest.json 的 "service.url"（http://127.0.0.1:39211）配套：把本插件目录
放进编辑器的 plugins/ 根并运行 `python service.py`，再在插件页点「重载」即可。

服务只需满足三个约定，其余全部自由：
  * GET /plugin.json  → 贡献声明（flow_cards / panels / agent_tools）；
  * 代理目标           → 后端会把 /api/plugins/service/<pid>/<subpath> 原样
                         转发到 <url>/<subpath>（超时 10s，附 X-Plugin-Id 头）；
  * agent 工具         → plugin.json 里 agent_tools[].name 由 AI 面板消费，
                         POST /api/plugins/agent/exec {"name","args"} 会转发到
                         该工具声明的 path（缺省 /agent/exec），返回体原样透传，
                         前端读取 {"result": ...}。

生命周期：后端不会拉起/杀掉本进程；关掉本脚本，插件页即显示服务不可用。
"""
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = 39211

PLUGIN_JSON = {
    "flow_cards": [
        {
            "type_id": "svc_dice",
            "name": "掷骰子",
            "applies_to": "talk",
            "color": "#9B59B6",
            "description": "由 service_demo 动态提供的对白卡（与声明型卡片同线格式）",
        }
    ],
    "panels": [
        {"panel_id": "live", "title": "实时面板"}
    ],
    "agent_tools": [
        {"name": "roll_dice", "description": "掷一个 1-6 的骰子",
         "parameters": {"type": "object", "properties": {}},
         "confirm": False, "path": "/agent/exec"},
    ],
}


class Handler(BaseHTTPRequestHandler):
    def _send(self, payload, status=200, mime="application/json; charset=utf-8"):
        body = payload if isinstance(payload, bytes) else json.dumps(
            payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", mime)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/plugin.json":
            return self._send(PLUGIN_JSON)
        if self.path == "/panel/live":  # 动态面板内容（{"title","blocks"} 线格式）
            return self._send({"title": "实时面板", "blocks": [
                {"type": "markdown", "text": "由 service.py 实时生成：_reload_%d" % PORT}]})
        if self.path.startswith("/echo"):
            return self._send({"echo": self.path})
        return self._send({"error": "no route: GET %s" % self.path}, status=404)

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b""
        if self.path == "/agent/exec":
            req = json.loads(raw.decode("utf-8") or "{}")
            if req.get("name") == "roll_dice":
                import random
                return self._send({"result": "骰子点数：%d" % random.randint(1, 6)})
            return self._send({"error": "unknown tool: %s" % req.get("name")}, status=404)
        if self.path.startswith("/echo"):
            return self._send({"echo": self.path, "body_bytes": len(raw)})
        return self._send({"error": "no route: POST %s" % self.path}, status=404)

    def log_message(self, fmt, *args):  # 安静一些
        pass


if __name__ == "__main__":
    print("service_demo listening on http://127.0.0.1:%d" % PORT)
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
