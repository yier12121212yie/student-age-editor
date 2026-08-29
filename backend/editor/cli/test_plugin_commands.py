# -*- coding: utf-8 -*-
"""CLI plugin 子命令单测：list / info / install / enable(高危确认) /
disable / dispatch 末端插件命令 <id>.<name> 命中与未命中。

fixture 插件用测试内临时目录 + EDITOR_PLUGINS_ROOT 环境变量隔离
（对齐 core/test_plugin_system.py 的做法），并恢复模块级插件状态。

运行方式（在 backend 目录下）：
    python -m unittest editor.cli.test_plugin_commands -v
"""
import io
import json
import os
import sys
import tempfile
import unittest
import zipfile
from types import SimpleNamespace
from unittest import mock

from rich.console import Console

from editor.core import plugin_system
from editor.cli import app as cli_app

# 插件命令把执行痕迹写入插件 data/ 目录，避免依赖 stdout 捕获第三方代码输出
PLUGIN_SRC = '''\
# -*- coding: utf-8 -*-
import os

def setup(ctx):
    def cmd_hello(args):
        with open(os.path.join(ctx.data_dir, "cmd_out.txt"), "w", encoding="utf-8") as f:
            f.write(args or "")
    ctx.register_command("hello", "say hello", cmd_hello)
'''


def make_zip(pid="demo1", name="Demo Plugin"):
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("manifest.json", json.dumps({
            "id": pid, "name": name, "version": "1.0.0",
            "author": "tester", "description": "a demo plugin",
            "entry": "plugin.py",
        }, ensure_ascii=False))
        z.writestr("plugin.py", PLUGIN_SRC)
    return buf.getvalue()


class _CLIBase(unittest.TestCase):
    """隔离到临时目录：EDITOR_PLUGINS_ROOT + 捕获 cli.app 的 console/err_console。"""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self._zips = tempfile.TemporaryDirectory()
        self.addCleanup(self._zips.cleanup)
        self._old_root = os.environ.get("EDITOR_PLUGINS_ROOT")
        os.environ["EDITOR_PLUGINS_ROOT"] = self._tmp.name
        self.addCleanup(self._restore_state)
        self._console = Console(record=True, legacy_windows=False,
                                force_terminal=False, width=120)
        self._err = Console(record=True, legacy_windows=False,
                            force_terminal=False, width=120)
        self._patches = [
            mock.patch.object(cli_app, "console", self._console),
            mock.patch.object(cli_app, "err_console", self._err),
        ]
        for p in self._patches:
            p.start()
        self.addCleanup(self._stop_patches)

    def _stop_patches(self):
        for p in self._patches:
            p.stop()

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

    def _write_zip(self, pid="demo1", name="Demo Plugin"):
        p = os.path.join(self._zips.name, pid + ".zip")
        with open(p, "wb") as f:
            f.write(make_zip(pid, name))
        return p

    def _install(self, pid="demo1"):
        path = self._write_zip(pid)
        cli_app.cmd_plugin_install(SimpleNamespace(path=path))
        return path

    def _enable(self, pid="demo1"):
        cli_app.cmd_plugin_enable(SimpleNamespace(id=pid, yes=True))

    def _run_main(self, argv):
        """走 cli_app.main 完整 dispatch；返回退出码并把 stderr 存到 self._last_stderr。"""
        import contextlib
        err_buf = io.StringIO()
        with contextlib.redirect_stderr(err_buf):
            try:
                rc = cli_app.main(argv)
            except SystemExit as e:
                rc = e.code if e.code is not None else 0
        if rc is None:  # main() 内置子命令成功路径无显式 return
            rc = 0
        self._last_stderr = err_buf.getvalue()
        return rc

    @property
    def out(self):
        # rich 15 的 export_text(clear=True) 是默认值——读取后会清空录制缓冲，
        # 属性必须用 clear=False 以便多次断言可取到同一份输出
        return self._console.export_text(clear=False)

    @property
    def err(self):
        return self._err.export_text(clear=False)


class PluginListInfoTest(_CLIBase):
    def test_list_output_fields(self):
        self._install("demo1")
        cli_app.cmd_plugin_list(SimpleNamespace())
        self.assertIn("demo1", self.out)
        self.assertIn("Demo Plugin", self.out)
        self.assertIn("1.0.0", self.out)
        self.assertIn("tester", self.out)
        self.assertIn("停用", self.out)

    def test_info_output_full_fields(self):
        self._install("demo1")
        cli_app.cmd_plugin_info(SimpleNamespace(id="demo1"))
        self.assertIn("Demo Plugin", self.out)
        self.assertIn("a demo plugin", self.out)
        self.assertIn("risk_ack_at", self.out)
        self.assertIn("停用", self.out)

    def test_info_unknown_id_reports_not_found(self):
        self._install("demo1")
        with self.assertRaises(SystemExit) as cm:
            cli_app.cmd_plugin_info(SimpleNamespace(id="nope"))
        self.assertNotEqual(cm.exception.code, 0)
        self.assertIn("plugin not found: nope", self.err)


class PluginInstallUninstallTest(_CLIBase):
    def test_install_from_path(self):
        cli_app.cmd_plugin_install(SimpleNamespace(path=self._write_zip("demo1")))
        entry = plugin_system.get_plugin_info("demo1")
        self.assertEqual(entry["id"], "demo1")
        self.assertFalse(entry["enabled"])
        self.assertFalse(entry["loaded"])
        self.assertIn("installed", self.out)

    def test_install_bad_path_reports_error(self):
        with self.assertRaises(SystemExit):
            cli_app.cmd_plugin_install(SimpleNamespace(path="N:/no/such/plugin.zip"))
        self.assertIn("install failed", self.err)

    def test_uninstall_requires_disable_first(self):
        self._install("demo1")
        self._enable("demo1")
        with self.assertRaises(SystemExit):
            cli_app.cmd_plugin_uninstall(SimpleNamespace(id="demo1", yes=True))
        self.assertIn("请先停用", self.err)

    def test_uninstall_yes_deletes(self):
        self._install("demo1")
        cli_app.cmd_plugin_uninstall(SimpleNamespace(id="demo1", yes=True))
        self.assertIsNone(plugin_system.get_plugin_info("demo1"))
        self.assertFalse(os.path.isdir(os.path.join(plugin_system.plugins_root(), "demo1")))
        self.assertIn("已卸载", self.out)


class PluginEnableDisableTest(_CLIBase):
    def setUp(self):
        super().setUp()
        self._install("demo1")

    def test_enable_unconfirmed_leaves_disabled(self):
        with mock.patch.object(self._console, "input", return_value="n"):
            cli_app.cmd_plugin_enable(SimpleNamespace(id="demo1", yes=False))
        # 高危警示块与插件元信息已展示
        self.assertIn("高危警示", self.out)
        self.assertIn("Demo Plugin", self.out)
        entry = plugin_system.get_plugin_info("demo1")
        self.assertFalse(entry["enabled"])
        self.assertFalse(entry["loaded"])
        self.assertEqual(entry["risk_ack_at"], "")

    def test_enable_yes_enables_and_writes_risk_ack_at(self):
        cli_app.cmd_plugin_enable(SimpleNamespace(id="demo1", yes=True))
        entry = plugin_system.get_plugin_info("demo1")
        self.assertTrue(entry["enabled"])
        self.assertTrue(entry["loaded"])
        self.assertRegex(entry["risk_ack_at"],
                         r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}$")
        self.assertIn("已启用", self.out)

    def test_enable_confirm_text_path_uses_input(self):
        # y 走 console.input 确认（非 --yes 路径）
        with mock.patch.object(self._console, "input", return_value="y"):
            cli_app.cmd_plugin_enable(SimpleNamespace(id="demo1", yes=False))
        entry = plugin_system.get_plugin_info("demo1")
        self.assertTrue(entry["enabled"])
        self.assertTrue(entry["risk_ack_at"])

    def test_disable(self):
        plugin_system.set_enabled("demo1", True, risk_ack=True)
        cli_app.cmd_plugin_disable(SimpleNamespace(id="demo1"))
        entry = plugin_system.get_plugin_info("demo1")
        self.assertFalse(entry["enabled"])
        self.assertFalse(entry["loaded"])
        self.assertIn("已停用", self.out)


class PluginDispatchTest(_CLIBase):
    def test_plugin_command_hit(self):
        self._install("demo1")
        self._enable("demo1")
        rc = self._run_main(["demo1.hello", "hello world"])
        self.assertEqual(rc, 0)
        out_file = os.path.join(plugin_system.plugins_root(),
                                "demo1", "data", "cmd_out.txt")
        self.assertTrue(os.path.exists(out_file), "插件命令未被分发执行")
        with open(out_file, "r", encoding="utf-8") as f:
            self.assertEqual(f.read(), "hello world")

    def test_plugin_command_miss_goes_to_argparse(self):
        self._install("demo1")
        self._enable("demo1")
        rc = self._run_main(["demo1.nope", "x"])
        self.assertEqual(rc, 2)  # argparse invalid choice
        self.assertIn("invalid choice", self._last_stderr)

    def test_builtin_subcommand_wins(self):
        self._install("demo1")
        self._enable("demo1")
        rc = self._run_main(["plugin", "list"])
        self.assertEqual(rc, 0)
        self.assertIn("demo1", self.out)
        self.assertIn("停用", self.out)


if __name__ == "__main__":
    unittest.main()