// server/services/mcp_bridge.h — Web 端 stdio MCP 桥接（C2）。
//
// 浏览器没有子进程能力，桌面端由 Flutter 直接 `Process.start` 拉起 MCP
// 服务器；网页版把这一步交给后端：后端持有子进程，浏览器只通过
// /api/mcp/stdio/* 收发 JSON-RPC 行。
//
// 信任边界：
//   * 本机浏览器版：与桌面同权限（后端就是本机进程），不设命令白名单；
//   * 自托管（网关 fork 的实例，EDITOR_HOSTED=1）：默认关闭；管理员在
//     gateway.json 的 `mcp_stdio` 显式开启并提供命令白名单，实例通过
//     EDITOR_MCP_STDIO_ALLOW 读取。未开启 / 命令不在白名单一律 403。
//
// 协议：
//   POST /api/mcp/stdio/start  {command,args[]} -> {session_id}
//   POST /api/mcp/stdio/send   {session_id,message} -> {ok}
//   GET  /api/mcp/stdio/stream?session_id=... -> text/event-stream（data: <json>）
//   POST /api/mcp/stdio/stop   {session_id} -> {ok}
//   GET  /api/mcp/stdio/policy -> {available,hosted,allow[]}
#pragma once

#include "server/httpd.h"

namespace sa {
namespace mcp_bridge {

void register_mcp_bridge_routes(Router& r);

// 测试钩子：关闭全部会话（进程组清理）。
void shutdown_all_for_test();

}  // namespace mcp_bridge
}  // namespace sa
