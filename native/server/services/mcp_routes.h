// server/services/mcp_routes: HTTP MCP（Streamable HTTP）端点
// `POST /api/mcp` + `GET /api/mcp`（网页版计划 M2 · 外部 Agent 接入）。
//
// 与 `tools/mcp_bridge/mcp_bridge.py`（stdio 桥）同协议、同工具集：
// MCP `2025-03-26` JSON-RPC 2.0，13 个工具（9 只读 + 4 写）。差别在于传输：
// 这里是 HTTP，鉴权走请求头（`Authorization: Bearer <token>`，由传输层的
// `token_ok` 强制），并在 URL 带 `?readonly=1` 时只暴露/放行只读工具。
//
// 工具执行直接复用 C++ 领域服务（p3b/stage/state/dicts），不经过本进程的
// REST 自转发，避免二次序列化与「自己请求自己」的回路。
#pragma once

#include "server/httpd.h"

namespace sa {

void register_mcp_routes(Router& r);

}  // namespace sa
