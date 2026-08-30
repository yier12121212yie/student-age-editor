# -*- coding: utf-8 -*-
"""系统提示词单测：关键内容、工具速查、并行调研按工具集动态拼入。

运行方式（在 backend 目录下）：
    python -m unittest editor.agent.test_prompt -v

关键句式与 frontend/test/ai_client_test.dart 的断言对齐，两边改句式要同步。
"""
import unittest

from editor.agent import prompt
from editor.agent.tools import AgentTools


def _tool(name: str) -> dict:
    return {"name": name, "parameters": {"type": "object", "properties": {}}}


class SystemPromptTest(unittest.TestCase):
    """主代理系统提示：定位句 + 分节规则 + 参数速查 + 模组范围。"""

    def setUp(self):
        self.tools = AgentTools().tool_defs()

    def test_core_positioning(self):
        s = prompt.system_prompt(self.tools)
        # 必须明确「能直接修改 mod 且必须用工具」，防止模型回答「无法修改」
        self.assertIn("修改模组必须通过工具完成", s)
        self.assertIn("list_domains", s)
        self.assertIn("update_domain_item", s)

    def test_sections(self):
        s = prompt.system_prompt(self.tools)
        for head in ("【标准操作流程】", "【内容条目规则】", "【跨类联动】", "【修改纪律】", "【回答要求】"):
            self.assertIn(head, s)

    def test_cross_domain_hints(self):
        # 跨类联动：缺角色新建而非复用、引用存 ID、删除前查引用
        s = prompt.system_prompt(self.tools)
        self.assertIn("缺角色就新建，不要复用", s)
        self.assertIn("不要把台词安到相近的已有角色头上", s)
        self.assertIn("不会出现在 get_game_dicts 里", s)  # 新角色要用新建返回的 id
        self.assertIn("跨表引用存的都是 ID 不是名字", s)
        self.assertIn("悬空 ID", s)
        # 剧情链路 / 社交挂接 / NPC 玩法等具体引用字段（与 GAME_SCHEMA 对应）
        self.assertIn("nextEvtId 跳转到下一个事件", s)
        self.assertIn("parent 指向所属动态", s)
        self.assertIn("GiftEvtCfg", s)

    def test_tool_cheatsheet(self):
        s = prompt.system_prompt(self.tools)
        self.assertIn("工具参数速查", s)
        self.assertIn("- read_file：path（string", s)
        self.assertIn("必填", s)
        self.assertIn("可空", s)

    def test_entry_role_rules(self):
        # 内容条目规则：说话人/发送者角色必填，roleName 只是可选显示名
        s = prompt.system_prompt(self.tools)
        self.assertIn("roleIds（说话人群组）", s)
        self.assertIn("PhoneMsgCfg 的 role（发送者）", s)
        self.assertIn("KZoneContentCfg 的 role（发布者）", s)
        self.assertIn("roleName（自定义名字）只是覆盖显示名的可选字段", s)

    def test_no_image_step(self):
        # 生图是 GUI 专属工具，终端版提示词不应出现
        self.assertNotIn("generate_image", prompt.system_prompt(self.tools))

    def test_operational_details(self):
        # 扩写的操作细节：与后端实际行为对应的事实性描述必须在场
        s = prompt.system_prompt(self.tools)
        self.assertIn("由 set_talk_stage 维护", s)      # TalkCfg.roles 是舞台编码
        self.assertIn("按当前最大数字 id+1 自动分配", s)  # 新建 id 可省略
        self.assertIn("允许的字段清单", s)               # 未知字段被拒时给指引
        self.assertIn("连续失败 2 次", s)                # 失败重试上限
        self.assertIn("等用户确认后再动手", s)           # 先答后改

    def test_spawn_subagents_gated(self):
        # 注册了 spawn_subagents 才出现「并行调研」段落
        self.assertIn("【并行调研】", prompt.system_prompt(self.tools))
        bare = [_tool("list_domains"), _tool("list_domain_items")]
        self.assertNotIn("【并行调研】", prompt.system_prompt(bare))
        self.assertNotIn("spawn_subagents", prompt.system_prompt(bare))

    def test_mod_context_appended(self):
        self.assertNotIn("当前模组：", prompt.system_prompt(self.tools))
        s = prompt.system_prompt(self.tools, mod_context="当前模组：TestMod。")
        self.assertTrue(s.endswith("当前模组：TestMod。"))


class SubagentPromptTest(unittest.TestCase):
    """并行只读调研子代理提示：只读约束 + 要点式结论。"""

    def test_constraints(self):
        # 引擎传给子代理的是只读克隆工具集：清单里不含 spawn_subagents 等写/派生工具
        tools = AgentTools().clone_readonly().tool_defs()
        s = prompt.subagent_system_prompt(tools)
        self.assertIn("并行只读调研子代理", s)
        self.assertIn("绝不修改任何数据", s)
        self.assertNotIn("spawn_subagents", s)
        self.assertIn("list_domain_items", s)  # 只读清单本身在列
        self.assertIn("简体中文", s)

    def test_mod_context_appended(self):
        tools = [_tool("list_domains")]
        s = prompt.subagent_system_prompt(tools, mod_context="当前模组：TestMod。")
        self.assertTrue(s.endswith("当前模组：TestMod。"))


if __name__ == "__main__":
    unittest.main()
