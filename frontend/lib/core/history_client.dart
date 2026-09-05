/// 撤销/重做的共用侧：`/api/history/undo|redo` 调用 + 「快捷键该不该让位给输入框」判定。
///
/// 这两个判断此前在文档标签页与剧情图画布各写了一份，行为迟早分叉
/// （例如一处漏了 `!shift`，Ctrl+Shift+Z 就会在两处表现不一致）。
library;

import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'api_client.dart';

/// historyOp 的四种结果。
///
/// D4：此前只回 bool，`_busy` 命中（连发快捷键/双表连探）也返回 false，
/// 调用方把它当成「没有可撤销」误报。busy 是瞬态让路，语义必须分开。
enum HistoryOpResult {
  /// 已应用（后端确认成功）。
  applied,

  /// 后端栈为空（nothing to undo/redo）。
  empty,

  /// 在途请求占用（Ctrl 连发 KeyDown 门闩）：本次静默放弃，不是空栈。
  busy,

  /// 真实失败（网络/5xx），info bar 已弹出。
  failed,
}

/// 在途请求门闩：Ctrl 按住不放会连发 KeyDown，两次 undo 会把快照栈倒空。
bool _busy = false;

/// 后端历史栈只对**已保存**内容有效：写入由 `cfg_store` 在存表时打快照，
/// 粒度是单张 cfg 表。未保存的画布改动不在这里，见 FlowEditHistory。
/// [quietEmpty] 用于「一次探多张表」的调用方（剧情图同时探 TalkCfg 与
/// OptionCfg）：空栈属正常结果，不弹提示；真正的失败仍然弹。
Future<HistoryOpResult> historyOp(
  String op, {
  required String cfg,
  required BuildContext context,
  bool quietEmpty = false,
}) async {
  if (_busy) return HistoryOpResult.busy;
  _busy = true;
  try {
    await ApiClient.instance.post('/api/history/$op', body: {'cfg': cfg});
    return HistoryOpResult.applied;
  } on ApiException catch (e) {
    final nothing =
        e.message.contains('nothing to undo') ||
        e.message.contains('nothing to redo');
    if (nothing) {
      // 空栈是正常结果：仅 quietEmpty=false 时提示，语义仍是 empty
      if (quietEmpty) return HistoryOpResult.empty;
      if (!context.mounted) return HistoryOpResult.failed;
      fluent.displayInfoBar(
        context,
        builder: (ctx, close) => fluent.InfoBar(
          title: Text('没有可${op == 'undo' ? '撤销' : '重做'}的操作'),
          severity: fluent.InfoBarSeverity.warning,
        ),
      );
      return HistoryOpResult.empty;
    }
    // 真实失败必须返回 failed：调用方靠它区分「空栈」与「失败」，
    // 返回 empty 会再叠加一条误导性的「没有可撤销的已保存改动」
    if (!context.mounted) return HistoryOpResult.failed;
    fluent.displayInfoBar(
      context,
      builder: (ctx, close) => fluent.InfoBar(
        title: Text('${op == 'undo' ? '撤销' : '重做'}失败'),
        content: Text(e.toString(), style: const TextStyle(fontSize: 12)),
        severity: fluent.InfoBarSeverity.error,
      ),
    );
    return HistoryOpResult.failed;
  } catch (e) {
    if (!context.mounted) return HistoryOpResult.failed;
    fluent.displayInfoBar(
      context,
      builder: (ctx, close) => fluent.InfoBar(
        title: Text('${op == 'undo' ? '撤销' : '重做'}失败'),
        content: Text(e.toString(), style: const TextStyle(fontSize: 12)),
        severity: fluent.InfoBarSeverity.error,
      ),
    );
    return HistoryOpResult.failed;
  } finally {
    _busy = false;
  }
}

/// Ctrl+Z / Ctrl+Shift+Z / Ctrl+Y 归一成 `'undo'` / `'redo'`，其余按键返回 null。
String? historyKeyOp(KeyEvent event) {
  if (event is! KeyDownEvent) return null;
  if (!HardwareKeyboard.instance.isControlPressed) return null;
  final key = event.logicalKey;
  final shift = HardwareKeyboard.instance.isShiftPressed;
  if (key == LogicalKeyboardKey.keyZ && !shift) return 'undo';
  if (key == LogicalKeyboardKey.keyY || (key == LogicalKeyboardKey.keyZ && shift)) {
    return 'redo';
  }
  return null;
}

/// 主焦点是否位于文本输入控件内：是则撤销/删除类快捷键让位给输入框自身。
bool focusInEditableText() {
  final ctx = FocusManager.instance.primaryFocus?.context;
  if (ctx == null) return false;
  final self = ctx.widget;
  if (self is EditableText || self is TextField) return true;
  var found = false;
  ctx.visitAncestorElements((e) {
    final w = e.widget;
    if (w is EditableText || w is TextField) {
      found = true;
      return false;
    }
    return true;
  });
  return found;
}
