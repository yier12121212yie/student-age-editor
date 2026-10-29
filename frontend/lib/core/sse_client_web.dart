/// Web：用 fetch + ReadableStream 读 SSE。
///
/// 为什么不用 `package:http`：浏览器端的 `BrowserClient` 走 XHR，响应体只能
/// 整体读取，`StreamedResponse.stream` 在 Web 上不可用。AI 打字机效果必须
/// 逐块消费，所以这里直接用 `fetch`，并返回与桌面 `_postStream` 相同形态的
/// `data:` 负载流。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'sse_client_types.dart';

/// 打开一个 SSE POST 请求。函数返回时响应头已到达（状态/类型已校验），
/// 因此 4xx / 非 `text/event-stream` 会在生产任何文本前抛 [SseUnavailable]。
Stream<String> openSseStream({
  required Uri uri,
  required Map<String, String> headers,
  required String body,
  void Function(void Function() abort)? registerAbort,
}) =>
    _openSse(uri: uri, headers: headers, body: body, registerAbort: registerAbort);

/// 打开一个 SSE GET 长连接（stdio MCP 桥接的 `data:` 消息流）。
Stream<String> openSseGetStream({
  required Uri uri,
  required Map<String, String> headers,
  void Function(void Function() abort)? registerAbort,
}) =>
    _openSse(uri: uri, headers: headers, body: null, registerAbort: registerAbort);

Stream<String> _openSse({
  required Uri uri,
  required Map<String, String> headers,
  required String? body,
  void Function(void Function() abort)? registerAbort,
}) {
  final controller = StreamController<String>();
  web.AbortController? abort;
  var closed = false;
  registerAbort?.call(() {
    closed = true;
    try {
      abort?.abort();
    } catch (_) {}
  });

  Future<void> run() async {
    if (closed) return;
    try {
      abort = web.AbortController();
      if (closed) {
        abort!.abort();
        return;
      }
      final h = web.Headers();
      headers.forEach((k, v) => h.set(k, v));
      if (body != null) h.set('Content-Type', 'application/json');
      h.set('Accept', 'text/event-stream');
      final init = body == null
          ? web.RequestInit(
              method: 'GET',
              headers: h,
              signal: abort!.signal,
            )
          : web.RequestInit(
              method: 'POST',
              headers: h,
              body: body.toJS,
              signal: abort!.signal,
            );
      final resp = await web.window.fetch(uri.toString().toJS, init).toDart;
      if (resp.status >= 400) {
        String detail = '';
        try {
          detail = (await resp.text().toDart).toDart;
        } catch (_) {}
        throw SseUnavailable(
          detail.isEmpty ? 'HTTP ${resp.status}' : 'HTTP ${resp.status}: $detail',
          status: resp.status,
        );
      }
      final contentType = resp.headers.get('content-type') ?? '';
      if (!contentType.toLowerCase().contains('text/event-stream')) {
        // 上游/后端返回整包 JSON（不支持流式）：交给非流式路径重新请求。
        throw SseUnavailable(
          '响应不是 text/event-stream（$contentType）',
          status: resp.status,
        );
      }
      final stream = resp.body;
      if (stream == null) {
        throw SseUnavailable('响应没有可读流', status: resp.status);
      }
      final reader =
          stream.getReader() as web.ReadableStreamDefaultReader;

      // 按字节行边界切分后再统一 UTF-8 解码，避免多字节汉字被 chunk 切断
      // 产生替换字符。
      final pending = <int>[];
      while (!closed) {
        final result = await reader.read().toDart;
        if (result.done) break;
        final value = result.value;
        if (value == null) continue;
        final bytes = (value as JSUint8Array).toDart;
        for (final b in bytes) {
          if (b == 0x0A) {
            var line = utf8.decode(pending, allowMalformed: true);
            pending.clear();
            if (line.endsWith('\r')) {
              line = line.substring(0, line.length - 1);
            }
            if (line.startsWith('data:')) {
              controller.add(line.substring(5).trimLeft());
            }
          } else {
            pending.add(b);
          }
        }
      }
      if (pending.isNotEmpty) {
        final line = utf8.decode(pending, allowMalformed: true);
        if (line.startsWith('data:')) {
          controller.add(line.substring(5).trimLeft());
        }
      }
      await reader.cancel().toDart;
      if (!closed) {
        closed = true;
        await controller.close();
      }
    } catch (e) {
      if (!closed) {
        closed = true;
        controller.addError(e);
        await controller.close();
      }
    }
  }

  controller.onListen = () {
    if (closed) return;
    unawaited(run());
  };
  controller.onCancel = () {
    closed = true;
    try {
      abort?.abort();
    } catch (_) {}
  };
  return controller.stream;
}
