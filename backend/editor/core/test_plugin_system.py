# -*- coding: utf-8 -*-
"""plugin_system 单测：manifest/id 校验、zip 安装校验、启停持久化与
risk_ack_at、启用确认拦截、加载失败隔离、Context 注册与命名空间、
Agent 工具过滤/confirm/exec 与 dispatch_plugin_route。

运行方式（在 backend 目录下）：
    python -m unittest editor.core.test_plugin_system -v
"""
import io
import json
import os
import sys
import tempfile
import unittest
import zipfile

from editor.core import plugin_system as s

# 一个完整的示例插件源码：注册路由/工具/命令/面板
PLUGIN_SRC = '''\
# -*- coding: utf-8 -*-
def setup(ctx):
    ctx.log("hello from test plugin")

    def greet(query, body):
        return 200, {"msg": "hi", "q": query}

    ctx.register_route("GET", "greet", greet)

    def roll(args, confirm):
        return "rolled %s" % (int(args.get("n") or 0) + 1)

    ctx.register_tool("dice", "roll a dice",
                      {"type": "object",
                       "properties": {"n": {"type": "integer"}}},
                      roll, readonly=True)

    def hello(args, confirm):
        return "hello %s" % (args.get("who") or "world")

    ctx.register_tool("hello", "say hello",
                      {"type": "object",
                       "properties": {"who": {"type": "string"}}},
                      hello)

    def wipe(args, confirm):
        if confirm is not None and not confirm("wipe", "erase everything"):
            return "rejected"
        return "wiped"

    ctx.register_tool("wipe", "dangerous write",
                      {"type": "object", "properties": {}},
                      wipe, confirm=True)

    def cmd_greet(args):
        pass

    ctx.register_command("greet", "say hi", cmd_greet)

    ctx.register_panel("p1", "Dice Panel", "dice", "roll dice")
'''


def make_zip(files):
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
        for name, content in files.items():
            z.writestr(name, content if isinstance(content, bytes)
                       else content.encode("utf-8"))
    return buf.getvalue()


def plugin_zip(pid="test1", name="test plugin", src=None, entry="plugin.py"):
    manifest = {"name": name, "version": "1.0.0", "author": "tester",
                "description": "desc", "entry": entry}
    if pid is not None:
        manifest["id"] = pid
    return make_zip({
        "manifest.json": json.dumps(manifest, ensure_ascii=False),
        entry: PLUGIN_SRC if src is None else src,
        "data/readme.txt": "hi",
    })


class PluginSystemBase(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self._old_root = os.environ.get("EDITOR_PLUGINS_ROOT")
        os.environ["EDITOR_PLUGINS_ROOT"] = self._tmp.name
        self.addCleanup(self._restore_state)

    def _restore_state(self):
        if self._old_root is None:
            os.environ.pop("EDITOR_PLUGINS_ROOT", None)
        else:
            os.environ["EDITOR_PLUGINS_ROOT"] = self._old_root
        with s._lock:
            s._loaded.clear()
            s._errors.clear()
            s._router = None
        for m in [m for m in list(sys.modules)
                  if m.startswith("student_age_plugin_")]:
            sys.modules.pop(m, None)

    def _meta(self):
        with open(os.path.join(s.plugins_root(), "plugins.json"),
                  "r", encoding="utf-8") as f:
            return json.load(f)


class InstallAndValidateTest(PluginSystemBase):
    def test_manifest_id_validation(self):
        for bad in ("Hello World!", "1abc", "UPPER", "a.b", "a/b", "a b"):
            with self.assertRaisesRegex(ValueError, "invalid plugin id"):
                s.install_plugin(plugin_zip(pid=bad), "x.zip")
        for reserved in ("agent", "ui", "reload", "install", "install_path"):
            with self.assertRaisesRegex(ValueError, "reserved plugin id"):
                s.install_plugin(plugin_zip(pid=reserved), "x.zip")
        # 合法 id 正常安装
        result = s.install_plugin(plugin_zip(pid="ok_plugin-1"), "x.zip")
        self.assertEqual(result["id"], "ok_plugin-1")

    def test_id_generated_from_filename(self):
        result = s.install_plugin(plugin_zip(pid=None), "hello world.zip")
        self.assertEqual(result["id"], "hello_world")
        result = s.install_plugin(plugin_zip(pid=None), "1abc.zip")
        self.assertEqual(result["id"], "p_1abc")
        # 保留 id 由文件名生成时同样禁止
        with self.assertRaisesRegex(ValueError, "reserved plugin id"):
            s.install_plugin(plugin_zip(pid=None), "agent.zip")

    def test_install_defaults_disabled(self):
        result = s.install_plugin(plugin_zip(), "test1.zip")
        self.assertEqual(result["id"], "test1")
        entry = result["plugin"]
        self.assertEqual(entry["name"], "test plugin")
        self.assertEqual(entry["author"], "tester")
        self.assertEqual(entry["entry"], "plugin.py")
        self.assertFalse(entry["enabled"])
        self.assertFalse(entry["loaded"])
        self.assertEqual(entry["risk_ack_at"], "")
        lst = s.list_plugins()
        self.assertEqual([e["id"] for e in lst], ["test1"])
        self.assertFalse(lst[0]["enabled"])
        # 注册表落盘
        self.assertFalse(self._meta()["plugins"]["test1"]["enabled"])

    def test_install_rejects_existing_directory(self):
        s.install_plugin(plugin_zip(), "test1.zip")
        with self.assertRaisesRegex(ValueError, "already exists"):
            s.install_plugin(plugin_zip(name="other"), "test1.zip")

    def test_install_illegal_entries(self):
        bad = make_zip({"manifest.json": '{"id":"x1"}', "../evil": "x"})
        with self.assertRaisesRegex(ValueError, "illegal entry"):
            s.install_plugin(bad)
        with self.assertRaisesRegex(ValueError, "illegal entry"):
            s.install_plugin(make_zip({"/abs": "x", "manifest.json": '{"id":"x1"}'}))
        with self.assertRaisesRegex(ValueError, "illegal entry"):
            s.install_plugin(make_zip({"a:b": "x", "manifest.json": '{"id":"x1"}'}))

    def test_install_missing_manifest_or_entry(self):
        with self.assertRaisesRegex(ValueError, "manifest"):
            s.install_plugin(make_zip({"plugin.py": PLUGIN_SRC}))
        bad = make_zip({"manifest.json": json.dumps({"id": "x2", "entry": "nope.py"}),
                        "plugin.py": PLUGIN_SRC})
        with self.assertRaisesRegex(ValueError, "entry file missing"):
            s.install_plugin(bad)
        with self.assertRaisesRegex(ValueError, "empty"):
            s.install_plugin(b"")

    def test_install_from_path(self):
        with tempfile.NamedTemporaryFile(suffix=".zip", delete=False) as f:
            f.write(plugin_zip(pid="tp1"))
            path = f.name
        try:
            result = s.install_plugin_from_path(path, "tp1.zip")
            self.assertEqual(result["id"], "tp1")
        finally:
            os.unlink(path)
        with self.assertRaisesRegex(ValueError, "not found"):
            s.install_plugin_from_path("N:/no/such/plugin.zip")


class EnableDisableTest(PluginSystemBase):
    def setUp(self):
        super().setUp()
        s.install_plugin(plugin_zip(), "test1.zip")

    def test_enable_requires_risk_ack(self):
        with self.assertRaisesRegex(ValueError, "需要高危确认"):
            s.set_enabled("test1", True)
        with self.assertRaisesRegex(ValueError, "需要高危确认"):
            s.set_enabled("test1", True, risk_ack=False)
        # 未被启用（注册表保持停用）
        self.assertFalse(self._meta()["plugins"]["test1"]["enabled"])

    def test_enable_disable_persistence(self):
        entry = s.set_enabled("test1", True, risk_ack=True)
        self.assertTrue(entry["enabled"])
        self.assertTrue(entry["loaded"])
        self.assertRegex(entry["risk_ack_at"],
                         r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}$")
        reg = self._meta()["plugins"]["test1"]
        self.assertTrue(reg["enabled"])
        self.assertTrue(reg["risk_ack_at"])

        entry = s.set_enabled("test1", False)
        self.assertFalse(entry["enabled"])
        self.assertFalse(entry["loaded"])
        self.assertFalse(self._meta()["plugins"]["test1"]["enabled"])

        # 重新启用：risk_ack_at 刷新且仍在
        entry = s.set_enabled("test1", True, risk_ack=True)
        self.assertTrue(entry["enabled"])
        self.assertTrue(entry["loaded"])
        self.assertTrue(entry["risk_ack_at"])
        self.assertTrue(self._meta()["plugins"]["test1"]["risk_ack_at"])

    def test_uninstall_requires_disable_first(self):
        s.set_enabled("test1", True, risk_ack=True)
        with self.assertRaisesRegex(ValueError, "先停用"):
            s.uninstall_plugin("test1")
        s.set_enabled("test1", False)
        s.uninstall_plugin("test1")
        self.assertFalse(os.path.isdir(os.path.join(s.plugins_root(), "test1")))
        self.assertEqual([e["id"] for e in s.list_plugins()], [])
        with self.assertRaisesRegex(ValueError, "not found"):
            s.uninstall_plugin("test1")


class LoadFailureIsolationTest(PluginSystemBase):
    def setUp(self):
        super().setUp()
        bad_src = "def setup(ctx):\n    raise RuntimeError('boom')\n"
        s.install_plugin(plugin_zip(pid="bad", src=bad_src), "bad.zip")
        s.install_plugin(plugin_zip(pid="good"), "good.zip")

    def test_failure_isolation_on_enable(self):
        entry = s.set_enabled("bad", True, risk_ack=True)
        self.assertTrue(entry["enabled"])
        self.assertFalse(entry["loaded"])
        self.assertIn("boom", entry["error"])
        entry = s.set_enabled("good", True, risk_ack=True)
        self.assertTrue(entry["loaded"])
        self.assertEqual(entry["error"], "")

    def test_reload_isolation(self):
        s.set_enabled("bad", True, risk_ack=True)
        s.set_enabled("good", True, risk_ack=True)
        s.reload_plugins()
        lst = {e["id"]: e for e in s.list_plugins()}
        self.assertIn("boom", lst["bad"]["error"])
        self.assertFalse(lst["bad"]["loaded"])
        self.assertTrue(lst["good"]["loaded"])
        self.assertEqual(lst["good"]["error"], "")


class ContextRegistrationTest(PluginSystemBase):
    def _install_and_enable(self, pid):
        s.install_plugin(plugin_zip(pid=pid), pid + ".zip")
        return s.set_enabled(pid, True, risk_ack=True)

    def test_registration_namespaces(self):
        self._install_and_enable("test1")
        defs = s.agent_tool_defs()
        by_name = {d["name"]: d for d in defs}
        for name in ("test1__dice", "test1__hello", "test1__wipe"):
            self.assertIn(name, by_name)
        self.assertTrue(by_name["test1__dice"]["readonly"])
        self.assertTrue(by_name["test1__wipe"]["confirm"])
        self.assertFalse(by_name["test1__hello"]["confirm"])
        self.assertEqual(by_name["test1__hello"]["plugin_id"], "test1")
        self.assertIn("parameters", by_name["test1__dice"])

        self.assertTrue(s.has_plugin_tool("test1__dice"))
        self.assertFalse(s.has_plugin_tool("nope"))

        self.assertEqual(s.ui_panels(), [{"panel_id": "p1",
                                          "title": "Dice Panel",
                                          "icon": "dice",
                                          "description": "roll dice"}])

        self.assertTrue(callable(s.plugin_command("test1.greet")))
        self.assertIsNone(s.plugin_command("test1.nope"))
        self.assertIsNone(s.plugin_command("nope.greet"))

        info = s.get_plugin_info("test1")
        self.assertEqual(info["contributions"]["routes"], ["GET greet"])
        self.assertIn("test1__dice", info["contributions"]["tools"])
        self.assertIn("test1.greet", info["contributions"]["commands"])
        self.assertEqual(info["contributions"]["panels"][0]["panel_id"], "p1")
        self.assertIsNone(s.get_plugin_info("nope"))

    def test_agent_exec_confirm_and_unknown(self):
        self._install_and_enable("test1")
        self.assertEqual(s.agent_exec("test1__dice", {"n": 5}, None), "rolled 6")
        self.assertEqual(s.agent_exec("test1__hello", {"who": "x"}, None), "hello x")
        # confirm=True 工具无回调 → 「该工具需要用户确认」
        self.assertEqual(s.agent_exec("test1__wipe", {}, None), "该工具需要用户确认")
        # 有回调 → 执行
        self.assertEqual(s.agent_exec("test1__wipe", {},
                                      confirm=lambda t, d: True), "wiped")
        # 未知工具 → ValueError
        with self.assertRaises(ValueError):
            s.agent_exec("nope", {})
        # 未加载插件的工具 → ValueError
        s.install_plugin(plugin_zip(pid="idle"), "idle.zip")
        with self.assertRaises(ValueError):
            s.agent_exec("idle__dice", {})

    def test_dispatch_plugin_route(self):
        self._install_and_enable("test1")
        result = s.dispatch_plugin_route("test1", "GET", "greet",
                                         {"a": "1"}, None)
        self.assertEqual(result, (200, {"msg": "hi", "q": {"a": "1"}}))
        self.assertIsNone(s.dispatch_plugin_route("test1", "POST", "greet", {}, {}))
        self.assertIsNone(s.dispatch_plugin_route("test1", "GET", "other", {}, {}))
        self.assertIsNone(s.dispatch_plugin_route("nope", "GET", "greet", {}, {}))
        # 停用后不可达
        s.set_enabled("test1", False)
        self.assertIsNone(s.dispatch_plugin_route("test1", "GET", "greet", {}, {}))

    def test_router_mount_and_unregister(self):
        from editor.server.httpd import ApiRouter

        router = ApiRouter()
        s.load_all(router)
        self._install_and_enable("test1")
        status, payload = router.dispatch("GET", "/api/plugins/test1/greet",
                                          {"x": "9"}, None)
        self.assertEqual(status, 200)
        self.assertEqual(payload["msg"], "hi")
        self.assertEqual(payload["q"], {"x": "9"})
        # 停用注销 owner 路由
        s.set_enabled("test1", False)
        status, payload = router.dispatch("GET", "/api/plugins/test1/greet", {}, None)
        self.assertEqual(status, 404)

    def test_data_dir_lazy_created(self):
        self._install_and_enable("test1")
        data_dir = os.path.join(s.plugins_root(), "test1", "data")
        self.assertTrue(os.path.isdir(data_dir))
        info = s.get_plugin_info("test1")
        self.assertEqual(info["id"], "test1")


if __name__ == "__main__":
    unittest.main()