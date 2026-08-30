# -*- coding: utf-8 -*-
"""终端版 Agent 助手：GUI AI 侧栏（frontend/lib/features/ai）的 Python 移植。

分层：
  client.py  LLM 流式客户端（三协议 + SSE 解析），不依赖任何服务状态
  tools.py   领域/文件/字典/舞台工具注册表，离线复用 server 数据面服务
  prompt.py  系统提示词（移植自 ai_panel.dart，剔除生图段落）
  engine.py  「生成 → 工具调用 → 审批 → 回填」循环（与 GUI 同样 20 轮上限）
  history_store.py  AI 会话历史持久化（TUI/CLI 落盘 .editor_ai_history，
             支持回看与跨进程恢复续聊；GUI 不使用）

模型服务配置来自三端共享的 .editor_ai.json（core.env_store）。
"""
from .client import LlmClient, LlmError, LlmCancelled, ToolCall
from .tools import AgentTools
from .engine import AgentEngine

__all__ = ["LlmClient", "LlmError", "LlmCancelled", "ToolCall", "AgentTools", "AgentEngine"]
