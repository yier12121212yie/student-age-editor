# -*- coding: utf-8 -*-
"""插件系统 HTTP API 单测：直接构造 build_router() 并调用 router.dispatch，
不起端口。

运行方式（在 backend 目录下）：
    python -m unittest editor.server.test_plugin_api -v
"""
import base64
import io
import json
import os
import sys
import tempfile
import unittest
import zipfile

from editor.server.api import build_router
from editor.core import plugin_system

API_PLUGIN_SRC = '''\
# -*- coding: utf-8 -*-
def setup(ctx):
    def greet(query, body):
        return 200, {"msg": "hi", "q": query}
    ctx.register_route("GET", "greet", greet)

    def submit(query, body):
        return 200, {"received": body}
    ctx.register_route("POST", "submit", submit)

    def dice(args, confirm):
        return "rolled %s" % (int(args.get("n") or 0) + 1)
    ctx.register_tool("dice", "roll dice",
                      {"type": "object",
                       "properties": {"n": {"type": "integer"}}},
                      dice, readonly=True)

    def beep(args, confirm):
        if confirm is not None and not confirm("beep", "beep details"):
            return "rejected"
        return "beeped"
    ctx.register_tool("beep", "needs confirm",
                      {"type": "object", "properties": {}},
                      beep, confirm=True)

    def cmd_run(args):
        pass
    ctx.register_command("run", "run it", cmd_run)

    ctx.register_panel("mp", "My Panel", "icon", "a panel")
'''


def make_zip(pid="p1"):
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("manifest.json", json.dumps({
            "id": pid, "name": pid, "version": "1.0.0",
            "author": "tester", "description": "demo", "entry": "plugin.py",
        }, ensure_ascii=False))
        z.writestr("plugin.py", API_PLUGIN_SRC)
    return buf.getvalue()


class PluginApiTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self._old_root = os.environ.get("EDITOR_PLUGINS_ROOT")
        os.environ["EDITOR_PLUGINS_ROOT"] = self._tmp.name
        self.addCleanup(self._restore_state)
        self.router = build_router()

    def _restore_state(self):
        if self._old_root is None:
            os.environ.pop("EDITOR_PLUGINS_ROOT", None)
        else:
            os.environ["EDITOR_PLUGINS_ROOT"] = self._old_root
        with plugin_system._lock:
            plugin_system._loaded.clear()
            plugin_system._errors.clear()
            plugin_system._router = None
        for m in [m for m in list(sys.modules)
                  if m.startswith("student_age_plugin_")]:
            sys.modules.pop(m, None)

    def _install(self, pid="p1", filename=None):
        b64 = base64.b64encode(make_zip(pid)).decode("ascii")
        return self.router.dispatch(
            "POST", "/api/plugins/install", {},
            {"data": b64, "filename": filename or (pid + ".zip")})

    def _enable(self, pid="p1"):
        return self.router.dispatch(
            "POST", "/api/plugins/%s/enable" % pid, {}, {"risk_ack": True})

    def _disable(self, pid="p1"):
        return self.router.dispatch(
            "POST", "/api/plugins/%s/disable" % pid, {}, None)


class PluginApiListTest(PluginApiTest):
    def test_list_empty_and_install(self):
        status, payload = self.router.dispatch("GET", "/api/plugins", {}, None)
        self.assertEqual(status, 200)
        self.assertEqual(payload, {"plugins": []})

        status, payload = self._install("p1")
        self.assertEqual(status, 200)
        self.assertTrue(payload["ok"])
        self.assertEqual(payload["id"], "p1")
        self.assertFalse(payload["plugin"]["enabled"])

        status, payload = self.router.dispatch("GET", "/api/plugins", {}, None)
        self.assertEqual(status, 200)
        self.assertEqual([e["id"] for e in payload["plugins"]], ["p1"])

    def test_invalid_base64(self):
        status, payload = self.router.dispatch(
            "POST", "/api/plugins/install", {}, {"data": "!!!"})
        self.assertEqual(status, 400)
        self.assertEqual(payload["error"], "invalid base64")

    def test_install_path(self):
        with tempfile.NamedTemporaryFile(suffix=".zip", delete=False) as f:
            f.write(make_zip("pp"))
            path = f.name
        try:
            status, payload = self.router.dispatch(
                "POST", "/api/plugins/install_path", {},
                {"path": path, "filename": "pp.zip"})
            self.assertEqual(status, 200)
            self.assertEqual(payload["id"], "pp")
        finally:
            os.unlink(path)
        status, payload = self.router.dispatch(
            "POST", "/api/plugins/install_path", {}, {"path": "N:/no/such"})
        self.assertEqual(status, 400)


class PluginApiDetailTest(PluginApiTest):
    def test_detail_and_404(self):
        self._install("p1")
        status, payload = self.router.dispatch("GET", "/api/plugins/p1", {}, None)
        self.assertEqual(status, 200)
        self.assertEqual(payload["id"], "p1")
        self.assertEqual(payload["contributions"],
                         {"routes": [], "tools": [], "commands": [], "panels": [],
                          "flow_cards": []})
        status, payload = self.router.dispatch("GET", "/api/plugins/nope", {}, None)
        self.assertEqual(status, 404)

    def test_detail_after_enable_has_contributions(self):
        self._install("p1")
        self._enable("p1")
        status, payload = self.router.dispatch("GET", "/api/plugins/p1", {}, None)
        self.assertEqual(status, 200)
        self.assertEqual(payload["loaded"], True)
        self.assertEqual(payload["contributions"]["routes"],
                         ["GET greet", "POST submit"])
        self.assertIn("p1__dice", payload["contributions"]["tools"])
        self.assertIn("p1.run", payload["contributions"]["commands"])
        self.assertEqual(payload["contributions"]["panels"],
                         [{"panel_id": "mp", "title": "My Panel",
                           "icon": "icon", "description": "a panel"}])


class PluginApiEnableDisableTest(PluginApiTest):
    def test_enable_requires_risk_ack(self):
        self._install("p1")
        status, payload = self.router.dispatch(
            "POST", "/api/plugins/p1/enable", {}, {})
        self.assertEqual(status, 400)
        self.assertEqual(
            payload["error"],
            "需要高危确认：该插件为第三方 Python 代码，启用后将与本编辑器同权限运行")
        status, payload = self.router.dispatch(
            "POST", "/api/plugins/p1/enable", {}, {"risk_ack": "true"})
        self.assertEqual(status, 400)
        # 仍未启用
        status, payload = self.router.dispatch("GET", "/api/plugins/p1", {}, None)
        self.assertFalse(payload["enabled"])
        self.assertFalse(payload["loaded"])

    def test_enable_success_and_loaded(self):
        self._install("p1")
        status, payload = self._enable("p1")
        self.assertEqual(status, 200)
        self.assertTrue(payload["ok"])
        self.assertTrue(payload["plugin"]["enabled"])
        self.assertTrue(payload["plugin"]["loaded"])
        self.assertTrue(payload["plugin"]["risk_ack_at"])

    def test_disable_then_route_404(self):
        self._install("p1")
        self._enable("p1")
        status, payload = self.router.dispatch(
            "GET", "/api/plugins/p1/greet", {"x": "1"}, None)
        self.assertEqual(status, 200)
        self.assertEqual(payload, {"msg": "hi", "q": {"x": "1"}})
        status, payload = self._disable("p1")
        self.assertEqual(status, 200)
        self.assertFalse(payload["plugin"]["enabled"])
        self.assertFalse(payload["plugin"]["loaded"])
        status, payload = self.router.dispatch(
            "GET", "/api/plugins/p1/greet", {}, None)
        self.assertEqual(status, 404)
        self.assertEqual(payload["error"], "no route")
        # 停用仍是停用，重复停用幂等
        status, payload = self._disable("p1")
        self.assertEqual(status, 200)

    def test_fallback_post_and_miss(self):
        self._install("p1")
        self._enable("p1")
        status, payload = self.router.dispatch(
            "POST", "/api/plugins/p1/submit", {}, {"a": 1, "b": [1, 2]})
        self.assertEqual(status, 200)
        self.assertEqual(payload["received"], {"a": 1, "b": [1, 2]})
        status, payload = self.router.dispatch(
            "GET", "/api/plugins/p1/nope", {}, None)
        self.assertEqual(status, 404)

    def test_delete_requires_disable(self):
        self._install("p1")
        self._enable("p1")
        status, payload = self.router.dispatch("DELETE", "/api/plugins/p1", {}, None)
        self.assertEqual(status, 400)
        self._disable("p1")
        status, payload = self.router.dispatch("DELETE", "/api/plugins/p1", {}, None)
        self.assertEqual(status, 200)
        self.assertTrue(payload["ok"])
        status, payload = self.router.dispatch("GET", "/api/plugins", {}, None)
        self.assertEqual(payload["plugins"], [])


class PluginApiAgentTest(PluginApiTest):
    def setUp(self):
        super().setUp()
        self._install("p1")
        self._enable("p1")

    def test_ui_panels(self):
        status, payload = self.router.dispatch("GET", "/api/plugins/ui", {}, None)
        self.assertEqual(status, 200)
        self.assertEqual(payload["panels"],
                         [{"panel_id": "mp", "title": "My Panel",
                           "icon": "icon", "description": "a panel"}])

    def test_agent_tools(self):
        status, payload = self.router.dispatch(
            "GET", "/api/plugins/agent/tools", {}, None)
        self.assertEqual(status, 200)
        by_name = {t["name"]: t for t in payload["tools"]}
        self.assertIn("p1__dice", by_name)
        self.assertTrue(by_name["p1__dice"]["readonly"])
        self.assertTrue(by_name["p1__beep"]["confirm"])
        self.assertEqual(by_name["p1__dice"]["plugin_id"], "p1")

    def test_agent_exec(self):
        status, payload = self.router.dispatch(
            "POST", "/api/plugins/agent/exec", {},
            {"name": "p1__dice", "args": {"n": 5}})
        self.assertEqual(status, 200)
        self.assertTrue(payload["ok"])
        self.assertEqual(payload["result"], "rolled 6")
        # confirm=True 工具：API 无条件放行（confirm=all True）
        status, payload = self.router.dispatch(
            "POST", "/api/plugins/agent/exec", {},
            {"name": "p1__beep", "args": {}})
        self.assertEqual(status, 200)
        self.assertEqual(payload["result"], "beeped")
        # 未知工具 → 400
        status, payload = self.router.dispatch(
            "POST", "/api/plugins/agent/exec", {},
            {"name": "p1__nope", "args": {}})
        self.assertEqual(status, 400)


class PluginApiReloadTest(PluginApiTest):
    def test_reload(self):
        self._install("p1")
        self._enable("p1")
        status, payload = self.router.dispatch(
            "POST", "/api/plugins/reload", {}, None)
        self.assertEqual(status, 200)
        self.assertTrue(payload["ok"])
        self.assertEqual([e["id"] for e in payload["plugins"]], ["p1"])
        self.assertTrue(payload["plugins"][0]["loaded"])
        # 重载后兜底路由仍可用
        status, payload = self.router.dispatch(
            "GET", "/api/plugins/p1/greet", {}, None)
        self.assertEqual(status, 200)


if __name__ == "__main__":
    unittest.main()