# -*- coding: utf-8 -*-
"""AI 会话历史持久化单测：落盘/列表/恢复归一化/文稿渲染/淘汰上限/CLI 命令族。

运行方式（在 backend 目录下）：
    python -m unittest editor.agent.test_history_store -v
"""
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from editor.agent import history_store as hs


class _TmpRoot(unittest.TestCase):
    """每个用例一个独立临时目录，直接以 root= 注入，不碰真实 editor 根。"""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.root = Path(self._tmp.name)


class SaveLoadTest(_TmpRoot):
    def test_roundtrip_and_meta(self):
        s = hs.new_session(provider="anthropic", model="m1", mod="TestMod", source="cli")
        s["history"] = [
            {"role": "user", "content": "把标题改一下\n第二行"},
            {"role": "assistant", "content": "好的"},
        ]
        saved = hs.save_session(s, root=self.root)
        self.assertTrue(saved["id"])
        self.assertEqual(saved["title"], "把标题改一下")  # 首行截取
        self.assertEqual(saved["message_count"], 2)
        self.assertEqual(saved["provider"], "anthropic")
        self.assertEqual(saved["mod"], "TestMod")

        # 列表只含元数据，不含 history
        metas = hs.list_sessions(root=self.root)
        self.assertEqual(len(metas), 1)
        self.assertNotIn("history", metas[0])
        self.assertEqual(metas[0]["message_count"], 2)

        # 载入得到完整 history
        loaded = hs.load_session(saved["id"], root=self.root)
        self.assertEqual(loaded["id"], saved["id"])
        self.assertEqual(len(loaded["history"]), 2)

    def test_new_session_id_unique(self):
        a = hs.new_session()
        b = hs.new_session()
        self.assertNotEqual(a["id"], b["id"])
        self.assertEqual(a["history"], [])

    def test_update_keeps_title_and_bumps_time(self):
        s = hs.new_session(source="tui")
        s["history"] = [{"role": "user", "content": "第一轮"}]
        first = hs.save_session(s, root=self.root)
        first["history"].append({"role": "assistant", "content": "回复"})
        second = hs.save_session(first, root=self.root)
        self.assertEqual(second["id"], first["id"])
        self.assertEqual(second["title"], "第一轮")
        self.assertEqual(second["message_count"], 2)
        self.assertGreaterEqual(second["updated_at"], first["updated_at"])

    def test_corrupt_file_skipped(self):
        (hs.sessions_dir(self.root)).mkdir(parents=True, exist_ok=True)
        (hs.sessions_dir(self.root) / "broken.json").write_text("{oops", encoding="utf-8")
        self.assertEqual(hs.list_sessions(root=self.root), [])
        self.assertIsNone(hs.load_session("broken", root=self.root))


class NormalizeTest(_TmpRoot):
    def test_anthropic_blocks_to_openai(self):
        history = [
            {"role": "user", "content": "任务"},
            {"role": "assistant", "content": [
                {"type": "text", "text": "先查一下。"},
                {"type": "tool_use", "id": "tu_1", "name": "list_mods", "input": {"k": "v"}},
            ]},
            {"role": "user", "content": [
                {"type": "tool_result", "tool_use_id": "tu_1", "content": "结果文本"},
            ]},
            {"role": "assistant", "content": "结论"},
        ]
        out = hs.to_openai_history(history)
        self.assertEqual(out[0], {"role": "user", "content": "任务"})
        self.assertEqual(out[1]["role"], "assistant")
        self.assertEqual(out[1]["content"], "先查一下。")
        tc = out[1]["tool_calls"][0]
        self.assertEqual(tc["id"], "tu_1")
        self.assertEqual(tc["type"], "function")
        self.assertEqual(tc["function"]["name"], "list_mods")
        self.assertEqual(json.loads(tc["function"]["arguments"]), {"k": "v"})
        self.assertEqual(out[2], {"role": "tool", "tool_call_id": "tu_1", "content": "结果文本"})
        self.assertEqual(out[3], {"role": "assistant", "content": "结论"})

    def test_openai_style_passthrough_lossless(self):
        history = [
            {"role": "user", "content": "任务"},
            {"role": "assistant", "content": None,
             "tool_calls": [{"id": "c1", "type": "function",
                             "function": {"name": "n", "arguments": "{\"a\":1}"}}]},
            {"role": "tool", "tool_call_id": "c1", "content": "ok"},
        ]
        self.assertEqual(hs.to_openai_history(history), history)

    def test_ignores_unknown_shapes(self):
        out = hs.to_openai_history([None, {"role": "system", "content": "x"}, 42])
        self.assertEqual(out, [])


class TranscriptTest(_TmpRoot):
    def test_render_transcript(self):
        history = [
            {"role": "user", "content": "第一个任务"},
            {"role": "assistant", "content": None,
             "tool_calls": [{"id": "c1", "type": "function",
                             "function": {"name": "search_mod", "arguments": "{\"kw\":\"x\"}"}}]},
            {"role": "tool", "tool_call_id": "c1", "content": "命中 3 条\n详情省略"},
            {"role": "assistant", "content": "这是结论"},
        ]
        text = hs.render_transcript(history)
        self.assertIn("你：第一个任务", text)
        self.assertIn("⚙ search_mod", text)
        self.assertIn("→ 命中 3 条", text)  # 工具结果只取首行
        self.assertNotIn("详情省略", text)
        self.assertIn("AI：这是结论", text)

    def test_render_anthropic_blocks(self):
        history = [
            {"role": "assistant", "content": [
                {"type": "text", "text": "块文本"},
                {"type": "tool_use", "id": "t", "name": "get_cfg", "input": {}},
            ]},
            {"role": "user", "content": [
                {"type": "tool_result", "tool_use_id": "t", "content": "r"},
            ]},
        ]
        text = hs.render_transcript(history)
        self.assertIn("AI：块文本", text)
        self.assertIn("⚙ get_cfg", text)
        self.assertIn("⚙ （工具结果 ×1）", text)


class LifecycleTest(_TmpRoot):
    def test_resolve_last_and_missing(self):
        s = hs.new_session(source="cli")
        s["history"] = [{"role": "user", "content": "唯一会话"}]
        hs.save_session(s, root=self.root)
        got, err = hs.resolve_session_ref("last", root=self.root)
        self.assertIsNone(err)
        self.assertEqual(got["title"], "唯一会话")
        got, err = hs.resolve_session_ref("no-such-id", root=self.root)
        self.assertIsNone(got)
        self.assertIn("不存在", err)
        got, err = hs.resolve_session_ref("", root=self.root)
        self.assertIsNone(got)
        self.assertTrue(err)

    def test_delete_and_clear(self):
        for i in range(3):
            s = hs.new_session(source="cli")
            s["history"] = [{"role": "user", "content": f"t{i}"}]
            hs.save_session(s, root=self.root)
        sid = hs.list_sessions(root=self.root)[0]["id"]
        self.assertTrue(hs.delete_session(sid, root=self.root))
        self.assertFalse(hs.delete_session(sid, root=self.root))  # 幂等
        self.assertEqual(len(hs.list_sessions(root=self.root)), 2)
        self.assertEqual(hs.clear_sessions(root=self.root), 2)
        self.assertEqual(hs.list_sessions(root=self.root), [])

    def test_prune_keeps_max_sessions(self):
        for i in range(hs._MAX_SESSIONS + 3):
            s = hs.new_session(source="tui")
            s["history"] = [{"role": "user", "content": "msg %d" % i}]
            hs.save_session(s, root=self.root)
        metas = hs.list_sessions(root=self.root)
        self.assertEqual(len(metas), hs._MAX_SESSIONS)
        # 最旧的被淘汰：剩余标题里不含最早的 msg 0/1/2
        titles = {m["title"] for m in metas}
        self.assertNotIn("msg 0", titles)


class CliWiringTest(_TmpRoot):
    """agent history 子命令族与 agent chat 新 flag 的解析与执行。"""

    def test_parser_and_commands(self):
        import io

        import editor.cli.app as cliapp
        from editor.cli.app import build_parser
        from rich.console import Console

        p = build_parser()
        ns = p.parse_args(["agent", "history"])
        self.assertIs(ns.func, cliapp.cmd_agent_history)
        ns = p.parse_args(["agent", "history", "show", "last"])
        self.assertEqual((ns.action, ns.session_id), ("show", "last"))
        ns = p.parse_args(["agent", "chat", "--resume", "last", "--no-history", "任务"])
        self.assertEqual(ns.resume, "last")
        self.assertTrue(ns.no_history)
        self.assertEqual(ns.task, ["任务"])

        # 造两个会话后依次 list → show → delete → clear（输出重定向到隔离 console）
        for i in range(2):
            s = hs.new_session(provider="openai_compatible", model="m", mod="Mod", source="cli")
            s["history"] = [{"role": "user", "content": "任务 %d" % i},
                            {"role": "assistant", "content": "完成"}]
            hs.save_session(s, root=self.root)

        buf_con = Console(file=io.StringIO(), legacy_windows=False)
        with mock.patch.object(hs, "app_data_dir", return_value=str(self.root)), \
                mock.patch.object(cliapp, "console", buf_con):
            ns = p.parse_args(["agent", "history", "list"])
            ns.func(ns)
            ns = p.parse_args(["agent", "history", "show", "last"])
            ns.func(ns)
            ns = p.parse_args(["agent", "history", "delete", "last"])
            ns.func(ns)
            self.assertEqual(len(hs.list_sessions(root=self.root)), 1)
            ns = p.parse_args(["agent", "history", "clear", "-y"])
            ns.func(ns)
            self.assertEqual(hs.list_sessions(root=self.root), [])


if __name__ == "__main__":
    unittest.main()
