/// MCP 传输工厂条件导出（网页版拆分 M0）：
/// - 有 dart:io 的平台：http → streamable HTTP，其余 → stdio 子进程；
/// - Web：stdio 不可用（见 stub），http 保持真实传输以便报错如实。
///
/// 把 [StdioTransport]（dart:io）隔离在 `mcp_stdio_transport.dart`，
/// 让 `mcp_client.dart` 本体不进入 web 编译依赖图。
library;

export 'mcp_transport_factory_stub.dart'
    if (dart.library.io) 'mcp_transport_factory_io.dart';
