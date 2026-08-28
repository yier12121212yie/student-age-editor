# -*- coding: utf-8 -*-
"""Agent 循环引擎——ai_client.dart send() 的「生成 → 工具调用 → 审批 → 回填」移植。

与 GUI 完全一致的循环语义：
  - 上限 20 轮工具调用（超限上报 _loop_limit 并终止）；
  - 无工具调用的轮次即最终回复，写入 history 后结束；
  - 每个写操作工具必经 confirm(title, detail) 审批（由 UI 层注入，None 拒绝）；
  - 工具轮次消息按 provider 追加对应结构（anthropic 块 / OpenAI tool_calls），
    client 层负责跨协议转换，history 始终是调用方持有引用的同一列表。

会话历史为内存态（engine.history 跨 run() 保留，实现多轮对话），不落盘。
"""

from typing import Callable, Optional

from .client import LlmClient
from . import prompt
from .tools import AgentTools

_MAX_TOOL_ROUNDS = 20  # 与 GUI（ai_client.dart _maxToolRounds）一致

# 超限提示（回填给模型与 UI 的文案与 dart 相同）
_LOOP_LIMIT_MSG = "工具调用轮次超过上限（%d），已终止" % _MAX_TOOL_ROUNDS


class AgentEngine:
    """一次会话一个实例；run() 逐条处理用户消息。"""

    def __init__(
        self,
        tools: AgentTools,
        confirm: Optional[Callable[[str, str], bool]] = None,
        on_text: Optional[Callable[[str], None]] = None,
        on_tool_round_text: Optional[Callable[[str], None]] = None,
        on_tool_result: Optional[Callable[[str, str], None]] = None,
        on_done: Optional[Callable[[], None]] = None,
        mod_context: str = "",
    ):
        self.tools = tools
        self.confirm = confirm
        self.on_text = on_text
        self.on_tool_round_text = on_tool_round_text
        self.on_tool_result = on_tool_result
        self.on_done = on_done
        # 非空时追加到系统提示，约束模型只操作该模组（与 GUI modContext 同构）
        self.mod_context = mod_context
        # 结构化会话历史（OpenAI 风格），跨 run() 保留实现多轮上下文
        self.history: list = []

    def run(self, user_message: str, client: LlmClient) -> str:
        """处理一条用户消息，返回最终回复文本。

        LlmError / LlmCancelled 直接向上抛（UI 层决定如何展示/中断）；
        history 已包含该条用户消息，异常后重试不会丢失上下文。
        """
        self.history.append({"role": "user", "content": user_message})
        system = prompt.system_prompt(self.tools.tool_defs(), self.mod_context)
        tools = self.tools.tool_defs()

        round_no = 0
        while True:
            round_no += 1
            if round_no > _MAX_TOOL_ROUNDS:
                if self.on_tool_result:
                    self.on_tool_result("_loop_limit", _LOOP_LIMIT_MSG)
                if self.on_done:
                    self.on_done()
                return ""
            calls, text = client.round(self.history, tools, system, on_text=self.on_text)

            if not calls:
                # 最终回复：写入 history 保证后续轮次对话连贯
                if text:
                    self.history.append({"role": "assistant", "content": text})
                if self.on_done:
                    self.on_done()
                return text

            # 本轮以工具调用结束：先上报过渡文本（空也上报，标记轮次边界）
            if self.on_tool_round_text:
                self.on_tool_round_text(text)
            results = []
            for call in calls:
                result = self.tools.execute(call, confirm=self.confirm)
                results.append(result)
                if self.on_tool_result:
                    self.on_tool_result(call.name, result)

            # 本轮工具调用与结果追加为结构化消息（provider 相应格式）
            if client.settings["provider"] == "anthropic":
                content = []
                if text:
                    content.append({"type": "text", "text": text})
                for i, call in enumerate(calls):
                    content.append({
                        "type": "tool_use",
                        "id": call.id,
                        "name": call.name,
                        "input": call.arguments,
                    })
                self.history.append({"role": "assistant", "content": content})
                self.history.append({
                    "role": "user",
                    "content": [
                        {
                            "type": "tool_result",
                            "tool_use_id": call.id,
                            "content": results[i],
                        }
                        for i, call in enumerate(calls)
                    ],
                })
            else:
                self.history.append({
                    "role": "assistant",
                    "content": text if text else None,
                    "tool_calls": [
                        {
                            "id": call.id,
                            "type": "function",
                            "function": {
                                "name": call.name,
                                "arguments": _dumps(call.arguments),
                            },
                        }
                        for call in calls
                    ],
                })
                for call, result in zip(calls, results):
                    self.history.append({
                        "role": "tool",
                        "tool_call_id": call.id,
                        "content": result,
                    })


def _dumps(data) -> str:
    import json

    return json.dumps(data if isinstance(data, dict) else {}, ensure_ascii=False)
