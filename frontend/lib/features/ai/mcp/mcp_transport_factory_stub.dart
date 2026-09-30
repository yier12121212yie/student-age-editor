/// MCP 传输工厂（Web）：浏览器里没有子进程，stdio 服务器一律不可用。
/// 连接失败在 `_startMcpClient` 被静默摘除，不阻塞聊天——与桌面坏配置同路径。
///
/// http 配置仍返回真实的 [HttpTransport]：浏览器 fetch 到本机 service 插件
/// 会被 CORS 拦下并如实报错（v1 明确砍掉服务插件代理，不做假成功）。
library;

import 'mcp_client.dart';
import 'mcp_types.dart';

McpTransport defaultMcpTransport(McpServerConfig cfg) {
  if (cfg.transport == 'http') return HttpTransport(cfg);
  return _UnsupportedStdioTransport(cfg);
}

class _UnsupportedStdioTransport implements McpTransport {
  _UnsupportedStdioTransport(this.cfg);

  final McpServerConfig cfg;

  @override
  Future<void> start() async {
    throw McpException('网页版不支持本地进程 MCP 服务器（${cfg.id}）');
  }

  @override
  void send(Map<String, dynamic> msg) {
    throw McpException('网页版不支持本地进程 MCP 服务器（${cfg.id}）');
  }

  @override
  Stream<Map<String, dynamic>> get incoming => const Stream.empty();

  @override
  Future<void> close() async {}
}
