/// Web：等「提示已经上屏」再开始同步解析。
///
/// 为什么要两帧：第 1 个 `requestAnimationFrame` 回调在**本帧绘制之前**，
/// 第 2 个回调时上一帧已经绘制完成。调用方先写提示状态、再 `await
/// nextWebPaint()`，用户就能在几秒的同步 `jsonDecode` 冻结前看到
/// 「正在解析 N MB…」，而不是界面毫无反应。
///
/// 标签页被隐藏时浏览器不派发 rAF，这里用 150ms 超时兜底，绝不让请求挂住。
library;

import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

Future<void> nextWebPaint() {
  final done = Completer<void>();
  void finish() {
    if (!done.isCompleted) done.complete();
  }

  void second(JSAny? _) => finish();
  void first(JSAny? _) => web.window.requestAnimationFrame(second.toJS);

  try {
    web.window.requestAnimationFrame(first.toJS);
  } catch (_) {
    finish();
  }
  return done.future
      .timeout(const Duration(milliseconds: 150), onTimeout: finish);
}
