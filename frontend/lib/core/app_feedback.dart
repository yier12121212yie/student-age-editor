// 统一反馈组件（C2）。
//
// 背景：全项目约 40 个文件各自写 `_info(msg, severity)` / 直接调
// `fluent.displayInfoBar`，时长/去重/可操作性各不相同，错误串也常原样丢给
// 用户。本文件提供单一入口 [AppFeedback]，统一：
// - 语义化四档：[success] / [info] / [warning] / [error]；
// - 时长：成功/信息 3s、警告 5s、错误近似常驻（10 分钟，或用户主动关闭）；
// - 同文案去重：1.2s 内相同 (severity, message) 只弹一次，避免连点刷屏；
// - [error] 可带 `detail`：折叠成「复制详情」按钮，技术细节不丢。
//
// [show] 按既有 [InfoBarSeverity] 分派，供工作台把自建的信息条包装
// 批量替换为一行调用，行为与旧实现保持一致（severity 决定档位）。
library;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import 'design_tokens.dart';

class AppFeedback {
  AppFeedback._();

  static const Duration successDuration = Duration(seconds: 3);
  static const Duration infoDuration = Duration(seconds: 3);
  static const Duration warningDuration = Duration(seconds: 5);

  /// 错误近似「常驻」：给足阅读时间；用户可点「复制详情」旁关闭或等其自动消失。
  static const Duration errorDuration = Duration(minutes: 10);

  static String? _lastKey;
  static DateTime? _lastAt;

  /// 测试用：清空同文案去重状态。去重基于**真实时钟**（DateTime.now），
  /// 而 widget 测试的 pump 只推进虚拟时间——同一测试进程里连跑的多个用例
  /// 会互相影响（前一个用例刚弹过的文案被误判为「连点」而静默）。
  @visibleForTesting
  static void debugResetDedupe() {
    _lastKey = null;
    _lastAt = null;
  }

  /// 成功：绿色，3s。
  static void success(BuildContext context, String message) =>
      _show(context, message, InfoBarSeverity.success, successDuration);

  /// 信息：中性，3s。
  static void info(BuildContext context, String message) =>
      _show(context, message, InfoBarSeverity.info, infoDuration);

  /// 警告：黄色，5s。
  static void warning(BuildContext context, String message) =>
      _show(context, message, InfoBarSeverity.warning, warningDuration);

  /// 错误：红色，近似常驻；[detail] 非空时提供「复制详情」。
  static void error(BuildContext context, String message, {String? detail}) =>
      _show(context, message, InfoBarSeverity.error, errorDuration,
          detail: detail);

  /// 按既有 [fluent.InfoBarSeverity] 分派（供 `_info(msg, severity)` 迁移）。
  static void show(
    BuildContext context,
    String message, {
    InfoBarSeverity severity = InfoBarSeverity.info,
    String? detail,
  }) {
    switch (severity) {
      case InfoBarSeverity.success:
        success(context, message);
      case InfoBarSeverity.warning:
        warning(context, message);
      case InfoBarSeverity.error:
        error(context, message, detail: detail);
      case InfoBarSeverity.info:
        info(context, message);
    }
  }

  static void _show(
    BuildContext context,
    String message,
    InfoBarSeverity severity,
    Duration duration, {
    String? detail,
  }) {
    // 同 (severity, message) 在 1.2s 内去重：连点按钮 / 重复失败只弹一次。
    final key = '${severity.name}\u0000$message';
    final now = DateTime.now();
    if (_lastKey == key &&
        _lastAt != null &&
        now.difference(_lastAt!) < const Duration(milliseconds: 1200)) {
      return;
    }
    _lastKey = key;
    _lastAt = now;

    final shownDetail = detail?.trim();
    displayInfoBar(
      context,
      duration: duration,
      builder: (ctx, close) => InfoBar(
        title: Text(message, style: const TextStyle(fontSize: AppText.subhead)),
        severity: severity,
        action: (shownDetail == null || shownDetail.isEmpty)
            ? null
            : Button(
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: shownDetail));
                  close();
                },
                child: const Text('复制详情', style: TextStyle(fontSize: AppText.small)),
              ),
      ),
    );
  }
}
