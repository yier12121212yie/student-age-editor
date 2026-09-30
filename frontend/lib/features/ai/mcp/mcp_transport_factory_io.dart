/// MCP 传输工厂（有 dart:io 的平台）：http 配置走 streamable HTTP，
/// 其余（stdio）拉起本地子进程。
library;

import 'mcp_client.dart';
import 'mcp_stdio_transport.dart';
import 'mcp_types.dart';

McpTransport defaultMcpTransport(McpServerConfig cfg) =>
    cfg.transport == 'http' ? HttpTransport(cfg) : StdioTransport(cfg);
