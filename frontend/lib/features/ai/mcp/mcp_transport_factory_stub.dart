/// MCP 传输工厂（Web）：http 用浏览器 fetch；stdio 交给后端桥接（C2）。
///
/// 浏览器不能 `Process.start`，所以 stdio 服务器由后端代持子进程
/// （`/api/mcp/stdio/*`）。自托管默认关闭，管理员显式开启并配置命令白名单
/// 后才可用；本机浏览器版与桌面同权限，直接可用。
library;

import 'mcp_backend_bridge.dart';
import 'mcp_client.dart';
import 'mcp_types.dart';

McpTransport defaultMcpTransport(McpServerConfig cfg) {
  if (cfg.transport == 'http') return HttpTransport(cfg);
  return BackendStdioTransport(cfg);
}
