# -*- coding: utf-8 -*-
"""ask_user 提问工具单测：工具定义 schema、ask 回调注入、只读克隆隔离。

运行方式（在 backend 目录下）：
    python -m unittest editor.agent.test_ask_user -v
    或 python -m pytest editor/agent -q

ask(question, options) -> str 与 confirm(title, detail) -> bool 并列：
ask_user 不走审批、不受完全访问模式短路，且不进 READ_ONLY_TOOLS
（只读子代理永远拿不到 ask 回调，也无法调用 ask_user）。
"""
import unittest

from editor.agent.client import ToolCall
from editor.agent.engine import AgentEngine
from editor.agent.tools import AgentTools, READ_ONLY_TOOLS

_ASK_UNSUPPORTED = "当前环境不支持向用户提问"


def _call(name: str, args: dict) -> ToolCall:
    return ToolCall(id="t1", name=name, arguments=args)


class AskUserToolDefTest(unittest.TestCase):
    """工具定义：TOOL_DEFS 注册 + schema 与 GUI 侧逐字段一致。"""

    def test_static_defs_contains_ask_user(self):
        self.assertIn("ask_user", [t["name"] for t in AgentTools.TOOL_DEFS])

    def test_tool_def_schema(self):
        d = {t["name"]: t for t in AgentTools().tool_defs()}["ask_user"]
        # 描述要说清用途与禁用场景（防闲聊），GUI ai_panel.dart 与此逐字段一致
        self.assertIn("向用户提问并等待回答", d["description"])
        schema = d["parameters"]
        self.assertEqual(schema.get("type"), "object")
        self.assertEqual(schema.get("required"), ["question"])
        props = schema["properties"]
        self.assertEqual(props["question"]["type"], "string")
        self.assertEqual(props["options"]["type"], "array")
        self.assertEqual(props["options"]["items"]["type"], "string")

    def test_not_in_readonly_whitelist(self):
        # 提问需要人在场，子代理（并行线程）没有交互对象，绝不放行
        self.assertNotIn("ask_user", READ_ONLY_TOOLS)

    def test_prompt_discipline(self):
        from editor.agent import prompt

        s = prompt.system_prompt(AgentTools().tool_defs())
        self.assertIn("ask_user", s)
        self.assertIn("一次只问一个最关键的问题", s)


class AskUserExecuteTest(unittest.TestCase):
    """执行语义：ask 注入返回答案；未注入返回提示；参数清洗。"""

    def test_ask_callback_returns_answer(self):
        tools = AgentTools()
        seen = {}

        def ask(question, options):
            seen["q"], seen["o"] = question, options
            return "选 A"

        out = tools.execute(
            _call("ask_user", {"question": "A 还是 B？", "options": ["A", "B"]}),
            ask=ask)
        self.assertEqual(out, "选 A")
        self.assertEqual(seen["q"], "A 还是 B？")
        self.assertEqual(seen["o"], ["A", "B"])

    def test_options_filtered_and_capped(self):
        # 非字符串/空串剔除，最多保留 6 个
        tools = AgentTools()
        seen = {}
        tools.execute(
            _call("ask_user", {"question": "？",
                               "options": ["  ", "a", 1, None, "b", "c", "d",
                                           "e", "f", "g"]}),
            ask=lambda q, o: seen.update(o=list(o)) or "ok")
        self.assertEqual(seen["o"], ["a", "b", "c", "d", "e", "f"])

    def test_missing_options_defaults_to_empty_list(self):
        tools = AgentTools()
        seen = {}
        tools.execute(_call("ask_user", {"question": "？"}),
                      ask=lambda q, o: seen.update(o=list(o)) or "ok")
        self.assertEqual(seen["o"], [])

    def test_without_ask_returns_hint(self):
        tools = AgentTools()
        out = tools.execute(_call("ask_user", {"question": "？"}))
        self.assertIn(_ASK_UNSUPPORTED, out)

    def test_ask_reset_between_calls(self):
        # execute 每次调用都重写 _ask_user_cb：上一次注入不能泄漏到下一次
        tools = AgentTools()
        tools.execute(_call("ask_user", {"question": "？"}), ask=lambda q, o: "答案")
        out = tools.execute(_call("ask_user", {"question": "？"}))
        self.assertIn(_ASK_UNSUPPORTED, out)

    def test_ask_independent_of_confirm(self):
        # confirm 缺省（未接审批）不影响 ask_user；二者互不干扰
        tools = AgentTools()
        out = tools.execute(_call("ask_user", {"question": "？"}),
                            confirm=None, ask=lambda q, o: "好")
        self.assertEqual(out, "好")

    def test_ask_stash_does_not_shadow_approval_helper(self):
        # 关键回归：ask 暂存属性绝不能遮蔽写审批助手 AgentTools._ask
        tools = AgentTools()
        tools.execute(_call("ask_user", {"question": "？"}), ask=lambda q, o: "答案")
        self.assertEqual(tools._ask_user_cb("？", []), "答案")
        self.assertNotIn("_ask", vars(tools))  # 实例字典没有遮蔽类级 _ask
        self.assertFalse(tools._ask(None, "t", "d"))  # confirm=None → 仍拒绝写操作


class AskUserSubagentIsolationTest(unittest.TestCase):
    """只读克隆隔离：子代理工具集不暴露、也拒绝执行 ask_user。"""

    def test_readonly_clone_hides_ask_user(self):
        names = [t["name"] for t in AgentTools().clone_readonly().tool_defs()]
        self.assertNotIn("ask_user", names)

    def test_readonly_clone_rejects_call(self):
        clone = AgentTools().clone_readonly()
        out = clone.execute(_call("ask_user", {"question": "？"}),
                            ask=lambda q, o: "不应被调用")
        self.assertIn("已被拒绝", out)
        self.assertIn("ask_user", out)

    def test_engine_accepts_ask_kwarg(self):
        # 引擎构造：ask 与 confirm 并列注入；缺省 None（子代理路径即此形态）
        self.assertIsNone(AgentEngine(AgentTools()).ask)
        eng = AgentEngine(AgentTools(), ask=lambda q, o: "好")
        self.assertIsNotNone(eng.ask)


if __name__ == "__main__":
    unittest.main()
