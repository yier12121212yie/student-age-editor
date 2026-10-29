/// 非 Web：流式走 `package:http` 的字节流，不使用 fetch 实现。
library;

import 'sse_client_types.dart';

Stream<String> openSseStream({
  required Uri uri,
  required Map<String, String> headers,
  required String body,
  void Function(void Function() abort)? registerAbort,
}) {
  throw SseUnavailable('当前平台不使用浏览器 fetch 流式通道');
}

/// 非 Web 不使用 GET SSE（stdio 由本机 `Process.start` 直接处理）。
Stream<String> openSseGetStream({
  required Uri uri,
  required Map<String, String> headers,
  void Function(void Function() abort)? registerAbort,
}) {
  throw SseUnavailable('当前平台不使用浏览器 fetch 流式通道');
}
