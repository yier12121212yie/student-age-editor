# -*- coding: utf-8 -*-
"""Agent 循环引擎——ai_client.dart send() 的「生成 → 工具调用 → 审批 → 回填」移植。

与 GUI 完全一致的循环语义：
  - 上限 20 轮工具调用（超限上报 _loop_limit 并终止）；
  - 无工具调用的轮次即最终回复，写入 history 后结束；
  - 每个写操作工具必经 confirm(title, detail) 审批（由 UI 层注入，None 拒绝）；
  - 工具轮次消息按 provider 追加对应结构（anthropic 块 / OpenAI tool_calls），
    client 层负责跨协议转换，history 始终是调用方持有引用的同一列表。

会话历史为内存态（engine.history 跨 run() 保留，实现多轮对话），不落盘。

只读并行子代理：主代理可调用 spawn_subagents 把 1-4 个相互独立的调研子任务
并行分派给子代理（每个子代理 = 独立 AgentEngine + 独立 LlmClient + 只读工具集
tools.clone_readonly()，history 独立、同样只存内存不落盘），聚合结论作为一次
普通工具结果回填主对话，子代理的中间过程不进入主 history。
"""

from concurrent.futures import ThreadPoolExecutor
from typing import Callable, Optional

from .client import LlmClient
from . import prompt
from .tools import AgentTools

_MAX_TOOL_ROUNDS = 20  # 与 GUI（ai_client.dart _maxToolRounds）一致

# 超限提示模板（%d 由引擎实例的 max_rounds 填充；文案与 dart 相同）
_LOOP_LIMIT_MSG = "工具调用轮次超过上限（%d），已终止"


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
        on_retry: Optional[Callable[[int, int, str], None]] = None,
        mod_context: str = "",
        max_rounds: int = _MAX_TOOL_ROUNDS,
        system_builder: Optional[Callable[[list, str], str]] = None,
    ):
        self.tools = tools
        self.confirm = confirm
        self.on_text = on_text
        self.on_tool_round_text = on_tool_round_text
        self.on_tool_result = on_tool_result
        self.on_done = on_done
        # 自动重连回调 on_retry(attempt, total_retries, reason)，透传给 client.round
        self.on_retry = on_retry
        # 非空时追加到系统提示，约束模型只操作该模组（与 GUI modContext 同构）
        self.mod_context = mod_context
        # 工具调用轮次上限（子代理引擎可调小）；超限文案按实例上限生成
        self.max_rounds = max_rounds
        # 系统提示构建器 system_builder(tool_defs, mod_context)，可注入子代理提示
        self._system_builder = system_builder or prompt.system_prompt
        # 结构化会话历史（OpenAI 风格），跨 run() 保留实现多轮上下文
        self.history: list = []

    def run(self, user_message: str, client: LlmClient) -> str:
        """处理一条用户消息，返回最终回复文本。

        不可重试的 LlmError（4xx、未配置 Key）与 LlmCancelled 直接向上抛
        （UI 层决定如何展示/中断）；可重试的网络失败由 client 自动重连。
        history 已包含该条用户消息，异常后重试不会丢失上下文。
        """
        self.history.append({"role": "user", "content": user_message})
        # 记录客户端配置：spawn_subagents 需为每个子代理克隆独立 LlmClient
        # （线程内各自实例化，连接不共享）
        self._client_settings = client.settings
        system = self._system_builder(self.tools.tool_defs(), self.mod_context)
        tools = self.tools.tool_defs()

        round_no = 0
        while True:
            round_no += 1
            if round_no > self.max_rounds:
                if self.on_tool_result:
                    self.on_tool_result("_loop_limit", _LOOP_LIMIT_MSG % self.max_rounds)
                if self.on_done:
                    self.on_done()
                return ""
            calls, text = client.round(
                self.history, tools, system,
                on_text=self.on_text, on_retry=self.on_retry,
            )

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
                if call.name == "spawn_subagents":
                    # 并行子代理由引擎特判执行（不走 AgentTools.execute），
                    # 结果同样是普通字符串，走下方既有 provider 回填路径
                    result = self._run_parallel_subagents(call.arguments)
                else:
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

    # ------------------------------------------------------------------ 并行子代理
    def _run_parallel_subagents(self, args) -> str:
        """spawn_subagents：把只读调研子任务并行分派给子代理并聚合结论。

        每个子代理 = 独立 AgentEngine + 独立 LlmClient + 只读工具集
        （tools.clone_readonly()），history 独立、内存态不落盘；hooks 全为
        None（不流式打印，避免多线程写 rich console）、confirm=None（子代理
        无写操作）。任何子任务异常都折算成字符串，不中断主循环；聚合结果
        作为一次普通工具结果回填，走 run() 里既有的 provider 回填路径。
        """
        tasks_raw = (args or {}).get("tasks")
        if not isinstance(tasks_raw, list) or not tasks_raw:
            return "错误：tasks 需为 1-4 个含 name/task 的对象列表"
        tasks = tasks_raw[:4]  # 超过 4 个截断为前 4 个
        for t in tasks:
            if (not isinstance(t, dict)
                    or not isinstance(t.get("name"), str) or not t["name"].strip()
                    or not isinstance(t.get("task"), str) or not t["task"].strip()):
                return "错误：tasks 需为 1-4 个含 name/task 的对象列表"
        if not getattr(self, "_client_settings", None):
            return "错误：缺少客户端配置，无法派发子代理"

        def _one(t):
            sub_tools = self.tools.clone_readonly()
            sub_engine = AgentEngine(sub_tools, confirm=None, mod_context=self.mod_context,
                                     max_rounds=8, system_builder=prompt.subagent_system_prompt)
            sub_client = LlmClient(dict(self._client_settings))
            try:
                return sub_engine.run(t["task"], sub_client) or "(子任务无输出)"
            except Exception as exc:
                return "子任务失败: %s" % exc

        with ThreadPoolExecutor(max_workers=min(4, len(tasks))) as ex:
            results = list(ex.map(_one, tasks))  # ex.map 保序，与 tasks 一一对应
        return "共 %d 个子任务完成。\n\n" % len(tasks) + "\n\n".join(
            "【%s】\n%s" % (t["name"], r) for t, r in zip(tasks, results))


def _dumps(data) -> str:
    import json

    return json.dumps(data if isinstance(data, dict) else {}, ensure_ascii=False)
