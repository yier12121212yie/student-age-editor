/// 浏览器 fetch SSE 条件导出：Web 用 ReadableStream，其余平台抛
/// [SseUnavailable]（桌面继续走 `package:http` 流式实现）。
library;

export 'sse_client_stub.dart'
    if (dart.library.js_interop) 'sse_client_web.dart';

export 'sse_client_types.dart';
