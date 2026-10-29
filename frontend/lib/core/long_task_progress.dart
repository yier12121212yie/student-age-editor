/// 长任务进度对话框 + 取消（C5 · 统一 "长任务进行中" 反馈）。
///
/// 背景（见 plan/ux_roadmap_r2.md 的 C5）：项目里 4 个长任务场景的进度/取消能力
/// 参差不齐——mod 导入/导出有进度条但**没有取消按钮**；云同步只有顶栏转圈、不能
/// 中止；图片导入只有"导入中…"文案、无进度无取消。这里把进度对话框提升为公共件，
/// 自带 [ProgressBar] +「取消」，四个场景复用。
///
/// 取消语义分两层（本文件只做**前端层**）：
///   1. **前端层**（立即生效）：置 [LongTaskHandle.isCancelled]，调用方在循环里
///      检查并尽快停止后续步骤、丢弃在途结果；UI 立刻回到可交互状态。
///   2. **后端层**（真中止工作）：`runLongTask` 目前不向 `/api/jobs/{id}` 发
///      DELETE；旧后端未实现取消时降级为"前端不再等待，后台可能仍在运行"（文案
///      已说明）。真取消需后端配合，见路线图 C5"待决策"。
library;

import 'package:flutter/widgets.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;

import 'app_dialogs.dart';
import 'app_theme.dart';

/// 用户在长任务进行中点「取消」时抛出；调用方应静默吞掉（不再弹错误）。
class LongTaskCancelled implements Exception {
  const LongTaskCancelled([this.reason = '已取消']);
  final String reason;
  @override
  String toString() => 'LongTaskCancelled: $reason';
}

/// 对话框要展示的一帧：阶段文案 + 可选进度（0..1，null = 不确定）+ 是否收尾。
class LongTaskStage {
  const LongTaskStage(this.label, this.frac, {this.done = false});
  final String label;
  final double? frac;
  final bool done;
}

/// 长任务句柄：驱动进度对话框，并承载「取消」语义。
///
/// 典型用法：
/// ```dart
/// final ctl = showLongTaskProgress(context, title: '导入模组包', initialLabel: '申请直传');
/// try {
///   final r = await run(onStage: (l, f) => ctl.update(l, f),
///                       isCancelled: () => ctl.isCancelled);
///   ctl.finish('导入完成');
///   await ctl.closed;
///   if (ctl.isCancelled) return;         // 已取消：丢弃结果
///   use(r);
/// } on LongTaskCancelled {
///   await ctl.closed;                    // 静默
/// } catch (e) {
///   ctl.fail('导入失败');
///   await ctl.closed;
///   rethrow;
/// } finally {
///   ctl.dispose();
/// }
/// ```
class LongTaskHandle {
  LongTaskHandle._(this._stage);

  final ValueNotifier<LongTaskStage> _stage;

  /// 对话框关闭的 Future（任务收尾或用户取消后自动完成）。
  late final Future<void> closed;

  /// 内部取消回调（如云同步要停轮询）；由 [showLongTaskProgress] 的调用方按需设置。
  VoidCallback? onCancel;

  bool _cancelled = false;
  bool _settled = false;
  bool _disposed = false;

  /// 用户是否已点「取消」（或程序化取消）。
  bool get isCancelled => _cancelled;

  /// 是否已收尾（[finish] / [fail] / [cancel] 之一）。
  bool get isSettled => _settled;

  /// 更新阶段文案与进度（收尾后忽略）。
  void update(String label, [double? frac]) {
    if (_settled || _disposed) return;
    _stage.value = LongTaskStage(label, frac);
  }

  /// 正常收尾：进度置满并自动关窗。
  void finish([String label = '完成']) =>
      _settle(LongTaskStage(label, 1, done: true));

  /// 失败收尾：关窗但不置满（调用方随后自行展示错误）。
  void fail([String label = '失败']) =>
      _settle(LongTaskStage(label, null, done: true));

  /// 用户取消：置 [isCancelled]、关窗，并触发 [onCancel]。
  void cancel() {
    if (_settled || _disposed) return;
    _cancelled = true;
    _settle(const LongTaskStage('已取消', null, done: true));
    onCancel?.call();
  }

  void _settle(LongTaskStage s) {
    if (_settled || _disposed) return;
    _settled = true;
    _stage.value = s;
  }

  /// 释放（调用方应在 `await closed` 之后调用一次）。
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _stage.dispose();
  }
}

/// 弹出长任务进度对话框，返回可驱动/可取消的 [LongTaskHandle]。
///
/// 对话框不可点遮罩关闭（`barrierDismissible: false`）；由 [LongTaskHandle]
/// 收尾或取消时自动关窗。[cancellable] 为 false 时不显示「取消」按钮。
LongTaskHandle showLongTaskProgress(
  BuildContext context, {
  required String title,
  String initialLabel = '准备中',
  bool cancellable = true,
}) {
  final stage = ValueNotifier<LongTaskStage>(LongTaskStage(initialLabel, null));
  final handle = LongTaskHandle._(stage);
  handle.closed = fluent.showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => LongTaskProgressDialog(
      stage: stage,
      title: title,
      cancellable: cancellable,
      onCancel: handle.cancel,
    ),
  );
  return handle;
}

/// 进度对话框：监听 [stage]，`done` 置位后自动关闭（完成/失败/取消皆然）。
/// 调用方通过 [LongTaskHandle.closed] 汇合，避免竞态 pop。
class LongTaskProgressDialog extends StatefulWidget {
  const LongTaskProgressDialog({
    super.key,
    required this.stage,
    required this.title,
    this.cancellable = true,
    this.onCancel,
  });

  final ValueNotifier<LongTaskStage> stage;
  final String title;
  final bool cancellable;
  final VoidCallback? onCancel;

  @override
  State<LongTaskProgressDialog> createState() => _LongTaskProgressDialogState();
}

class _LongTaskProgressDialogState extends State<LongTaskProgressDialog> {
  @override
  void initState() {
    super.initState();
    widget.stage.addListener(_maybeClose);
    // 对话框可能在任务已结束后才真正弹出（showDialog 排队）：首帧即检查。
    if (widget.stage.value.done) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _maybeClose());
    }
  }

  @override
  void dispose() {
    widget.stage.removeListener(_maybeClose);
    super.dispose();
  }

  void _maybeClose() {
    if (widget.stage.value.done && Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<LongTaskStage>(
      valueListenable: widget.stage,
      builder: (context, stage, _) {
        final pct = stage.frac == null ? null : (stage.frac! * 100).clamp(0.0, 100.0);
        return AppContentDialog(
          title: Text(widget.title),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                pct == null
                    ? '${stage.label} …'
                    : '${stage.label} ${pct.toStringAsFixed(1)}%',
                style: const TextStyle(fontSize: 12.5),
              ),
              const SizedBox(height: 10),
              fluent.ProgressBar(value: pct),
              if (widget.cancellable && !stage.done) ...[
                const SizedBox(height: 8),
                Text('取消后界面立即恢复；后台若已开始执行可能仍会继续。',
                    style: TextStyle(fontSize: 11, color: palette.textMuted)),
              ],
            ],
          ),
          actions: [
            if (widget.cancellable && !stage.done)
              fluent.Button(
                onPressed: widget.onCancel,
                child: const Text('取消'),
              ),
          ],
        );
      },
    );
  }
}
