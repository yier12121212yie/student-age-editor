/// Web：采集 `error` / `unhandledrejection`，并提供运行环境摘要与页面重载。
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

import 'web_diag.dart';

/// 只留最近几条：诊断报告要短，重复报错（如每帧一次）没有额外信息量。
const int _maxErrors = 5;
final List<String> _errors = <String>[];
int _seq = 0;

/// 浏览器/扩展注入的噪音：不是本应用的错误，留着只会淹没真正的问题。
const List<String> _noise = <String>[
  'Script error.', // 跨域脚本未开 CORS 时的占位信息
  'ResizeObserver loop', // 每帧布局抖动都会报，但 Flutter 自己会重试
  'ResizeObserver loop completed with undelivered notifications',
];

void installWebErrorCapture() {
  web.window.addEventListener('error', _onError.toJS);
  web.window.addEventListener('unhandledrejection', _onUnhandled.toJS);
}

void _onError(web.ErrorEvent e) {
  final message = e.message.trim();
  if (message.isEmpty || _isNoise(message)) return;
  final where = e.filename.isEmpty
      ? ''
      : ' @${_shortFile(e.filename)}:${e.lineno}';
  _record('JS 错误：$message$where');
}

void _onUnhandled(web.PromiseRejectionEvent e) {
  final text = _describeReason(e.reason);
  if (text.isEmpty || _isNoise(text)) return;
  _record('未处理的 Promise 拒绝：$text');
}

bool _isNoise(String message) =>
    _noise.any((n) => message.contains(n));

String _shortFile(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null) return url;
  final name = uri.pathSegments.isEmpty ? url : uri.pathSegments.last;
  return name.isEmpty ? url : name;
}

String _describeReason(JSAny? reason) {
  if (reason == null) return '';
  // 常见形态是 Error 对象：优先取 message，比 `[object Object]` 有用得多。
  try {
    final obj = reason as JSObject;
    final msg = obj.getProperty('message'.toJS);
    if (msg != null && msg.isA<JSString>()) {
      final text = (msg as JSString).toDart;
      if (text.trim().isNotEmpty) return text.trim();
    }
    final name = obj.getProperty('name'.toJS);
    if (name != null && name.isA<JSString>()) {
      final text = (name as JSString).toDart;
      if (text.trim().isNotEmpty) return text.trim();
    }
  } catch (_) {
    // 不是对象（字符串/数字/undefined）：走下面的通用转换。
  }
  try {
    return reason.dartify()?.toString().trim() ?? '';
  } catch (_) {
    return '';
  }
}

void _record(String message) {
  _seq++;
  final stamp = _hhmmss(DateTime.now());
  final line = '[$stamp #$_seq] $message';
  _errors.add(line);
  while (_errors.length > _maxErrors) {
    _errors.removeAt(0);
  }
  markWebDiag('jsErr', _errors.join(' | '));
}

String _hhmmss(DateTime t) => '${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}';
String _two(int v) => v < 10 ? '0$v' : '$v';

/// 最近采集到的 JS 错误（旧 → 新）。
List<String> webCapturedErrors() => List<String>.unmodifiable(_errors);

/// 一行环境摘要：浏览器 UA + 屏幕/视口 + 设备内存 + 已用堆（后两项仅 Chromium）。
///
/// 排查「只有某个浏览器坏」「高分屏错位」「长会话变卡」时，这几项是最常缺的
/// 上下文。
///
/// 刻意不读缩放比（DPR）：全库约定只允许 `core/texture_budget.dart` 读一次，
/// 由 texture_budget_test 静态守门；这里给屏幕与视口尺寸已足够定位错位。
String webEnvironmentSummary() {
  final parts = <String>[];
  final nav = web.window.navigator;
  final ua = nav.userAgent.trim();
  if (ua.isNotEmpty) parts.add(ua);
  final screen = web.window.screen;
  parts.add('屏幕 ${screen.width}x${screen.height}'
      ' · 视口 ${web.window.innerWidth}x${web.window.innerHeight}');
  final deviceMemory = _navigatorNumber(nav, 'deviceMemory');
  if (deviceMemory != null) {
    parts.add('设备内存 ${deviceMemory.toStringAsFixed(0)} GB');
  }
  final heap = _usedHeapMb();
  if (heap != null) parts.add('已用堆 $heap MB');
  return parts.join(' · ');
}

double? _navigatorNumber(web.Navigator nav, String key) {
  try {
    final value = (nav as JSObject).getProperty(key.toJS);
    if (value != null && value.isA<JSNumber>()) {
      return (value as JSNumber).toDartDouble;
    }
  } catch (_) {}
  return null;
}

/// `performance.memory.usedJSHeapSize`（Chrome/Edge 专有，Firefox/Safari 无）。
int? _usedHeapMb() {
  try {
    final perf = web.window.performance as JSObject;
    final memory = perf.getProperty('memory'.toJS);
    if (memory == null || !memory.isA<JSObject>()) return null;
    final used = (memory as JSObject).getProperty('usedJSHeapSize'.toJS);
    if (used == null || !used.isA<JSNumber>()) return null;
    return ((used as JSNumber).toDartDouble / (1024 * 1024)).round();
  } catch (_) {
    return null;
  }
}

/// 整页重载（错误兜底页的「重新加载」按钮）。
void reloadWebPage() {
  web.window.location.reload();
}
