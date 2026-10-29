/// 诊断信息的拼装与复制（设置页「诊断」区块 / 错误兜底页共用）。
///
/// Flutter Web 没有可读的界面树，用户报「白屏 / 卡住 / 按钮错位」时，最缺的
/// 是三样东西：走到哪一步、什么浏览器什么屏、报了什么错。这里把
/// `__editorDiag`（`core/web_diag.dart`）、JS 错误（`core/web_errors.dart`）
/// 与运行环境压成一段纯文本，一键复制即可粘贴到反馈里。
///
/// 报告只含启动阶段、界面模式、错误摘要与浏览器环境——**不含模组内容、文件
/// 路径与账号信息**，因此可以放心公开粘贴。
library;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';

import 'platform_env.dart';
import 'update_check.dart';
import 'web_diag.dart';
import 'web_errors.dart';

/// 已知诊断字段的展示顺序：先回答「卡在哪」，再放其余。
const List<String> _diagOrder = <String>[
  'boot',
  'init',
  'uiMode',
  'auth',
  'render',
  'intake',
  'err',
  'jsErr',
];

/// 本地时间 `2026-10-28 22:45:03`（不带时区：用户和开发者通常同一时区）。
String formatDiagnosticTime(DateTime t) {
  String two(int v) => v < 10 ? '0$v' : '$v';
  return '${t.year}-${two(t.month)}-${two(t.day)} '
      '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
}

/// 纯函数：把各项状态拼成可直接粘贴的一段文本。
String buildDiagnosticsReport({
  required DateTime now,
  required String appVersion,
  required String environment,
  required Map<String, String> diag,
  List<String> jsErrors = const <String>[],
}) {
  final b = StringBuffer()
    ..writeln('=== 学生时代模组编辑器 · 诊断信息 ===')
    ..writeln('时间：${formatDiagnosticTime(now)}')
    ..writeln('版本：${appVersion.trim().isEmpty ? '未知' : appVersion.trim()}')
    ..writeln('环境：${environment.trim().isEmpty ? '未知' : environment.trim()}');

  final known = <String>{
    for (final k in _diagOrder)
      if (diag.containsKey(k)) k,
  };
  final others = diag.keys.where((k) => !known.contains(k)).toList()..sort();

  b.writeln();
  b.writeln('[启动与渲染]');
  for (final key in <String>[..._diagOrder, ...others]) {
    final value = diag[key];
    if (value == null) continue;
    b.writeln('  $key: $value');
  }
  if (diag.isEmpty) b.writeln('  （无）');

  if (jsErrors.isNotEmpty) {
    b.writeln();
    b.writeln('[最近 JS 错误]（旧 → 新，最多 5 条）');
    for (var i = 0; i < jsErrors.length; i++) {
      b.writeln('  ${i + 1}. ${jsErrors[i]}');
    }
  }

  b
    ..writeln()
    ..write('（本段不含模组内容与账号信息，可直接粘贴到问题反馈中）');
  return b.toString();
}

/// 读取当前运行状态并写入系统剪贴板；返回是否成功。
Future<bool> copyDiagnosticsReport({DateTime? now}) async {
  final report = buildDiagnosticsReport(
    now: now ?? DateTime.now(),
    appVersion: UpdateState.instance.version,
    environment:
        kIsWeb ? webEnvironmentSummary() : desktopEnvironmentSummary(),
    diag: webDiagEntries(),
    jsErrors: webCapturedErrors(),
  );
  try {
    await Clipboard.setData(ClipboardData(text: report));
    return true;
  } catch (_) {
    // 浏览器拒绝剪贴板权限（非安全上下文/用户拒绝）时由调用方提示手动复制。
    return false;
  }
}
