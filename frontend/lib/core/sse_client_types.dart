/// 浏览器 fetch 流式不可用（CORS / 非 SSE 响应 / HTTP 错误）时抛出。
///
/// 调用方（`AiClient`）据此回退到整包非流式路径——异常保证在**首个文本
/// 增量之前**抛出，因此不会出现「半截流 + 重试」的重复内容。
class SseUnavailable implements Exception {
  SseUnavailable(this.message, {this.status = 0});

  final String message;
  final int status;

  @override
  String toString() => 'SseUnavailable($status): $message';
}
