// 统一弹窗尺寸与包装（单一来源）。
//
// 背景：FluentUI 的 [fluent.ContentDialog] 默认约束是
// `BoxConstraints(maxWidth: 368, maxHeight: 756)`（见 fluent_ui
// content_dialog.dart 的 kDefaultContentDialogConstraints）。于是任何
// 「窄而高」的弹窗——长表单、长列表、长文本——都会被压成 368 宽的竖长条。
//
// 这里给出一个统一入口：
// - [appDialogSize] / [appDialogConstraints]：按屏幕自适应，并尽量把弹窗
//   收敛到 16:9，空间不足时退化为 4:3，避免「长条」；
// - [AppContentDialog]：可直接替换 `fluent.ContentDialog(...)` 的包装，
//   默认把宽度上限放宽到桌面可用宽度（而非 368），从根上消除竖长条。
//
// 对「长表单/长列表」这类内容较高的弹窗，调用方应显式传 [aspectRatio]
// （或自行用 [appDialogSize] 约束正文），并保证正文可滚动/可伸缩。
library;

import 'package:flutter/widgets.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;

import 'responsive.dart';

double _clampD(double v, double lo, double hi) {
  if (hi < lo) return hi;
  if (v < lo) return lo;
  if (v > hi) return hi;
  return v;
}

/// 弹窗目标尺寸：优先 [preferredAspect]（默认 16:9），屏幕放不下时退化为
/// [fallbackAspect]（默认 4:3）；仍然放不下则保持宽度优先，用最接近的宽比例
/// 填满可用高度。不会返回「竖长条」尺寸。
Size appDialogSize(
  BuildContext context, {
  double preferredWidth = 880,
  double preferredAspect = 16 / 9,
  double fallbackAspect = 4 / 3,
  double maxWidthFraction = 0.92,
  double maxHeightFraction = 0.88,
  double minWidth = 340,
}) {
  final screen = MediaQuery.sizeOf(context);
  // 移动端保持「近全屏」：竖屏下 16:9 会矮得放不下内容。
  if (isMobileWidth(context)) {
    return Size(screen.width - 24, screen.height * 0.92);
  }
  final maxW = _clampD(screen.width * maxWidthFraction, 0, screen.width - 24);
  final maxH = screen.height * maxHeightFraction;
  final lower = minWidth > maxW ? maxW : minWidth;

  var w = _clampD(preferredWidth, lower, maxW);
  var h = w / preferredAspect;
  if (h > maxH) {
    // 16:9 放不下 → 退 4:3。
    h = w / fallbackAspect;
    if (h > maxH) {
      // 仍然放不下 → 以可用高度为准，取最宽的 16:9 比例。
      h = maxH;
      w = _clampD(h * preferredAspect, lower, maxW);
      h = w / preferredAspect;
    }
  }
  return Size(w, h);
}

/// [fluent.ContentDialog] 的默认约束：宽度上限放宽到 [preferredWidth]，默认取
/// Windows 内容对话框指引的 548（Fluent 自带默认仅 368，长表单会被压成竖长条）。
/// 用于 [AppContentDialog] 未显式给定 `constraints` 时。
BoxConstraints appDialogConstraints(
  BuildContext context, {
  double preferredWidth = 548,
  double maxWidthFraction = 0.92,
  double maxHeightFraction = 0.88,
  double minWidth = 340,
}) {
  final screen = MediaQuery.sizeOf(context);
  if (isMobileWidth(context)) {
    return BoxConstraints(
      maxWidth: screen.width - 24,
      maxHeight: screen.height * maxHeightFraction,
    );
  }
  final maxW = _clampD(screen.width * maxWidthFraction, 0, screen.width - 24);
  final lower = minWidth > maxW ? maxW : minWidth;
  return BoxConstraints(
    maxWidth: _clampD(preferredWidth, lower, maxW),
    maxHeight: screen.height * maxHeightFraction,
  );
}

/// [fluent.ContentDialog] 正文专用尺寸：在桌面端给出 [aspectRatio] 的正文区域，
/// 同时把高度压到屏幕的 [maxHeightFraction]，给标题/按钮留出空间；移动端按屏宽
/// 收窄。适合 `content: SizedBox(width: ..., height: ...)`。
Size appDialogContentSize(
  BuildContext context, {
  double preferredWidth = 720,
  double aspectRatio = 16 / 9,
  double maxHeightFraction = 0.6,
}) {
  final screen = MediaQuery.sizeOf(context);
  final w = _clampD(preferredWidth, 260, screen.width - 48);
  final h = w / aspectRatio;
  final maxH = screen.height * maxHeightFraction;
  return Size(w, h > maxH ? maxH : h);
}

/// 可直接替换 `fluent.ContentDialog(...)` 的包装：
///
/// - 未传 [constraints] 时使用 [appDialogConstraints]，把宽度上限从 Fluent
///   默认的 368 放宽到 [preferredWidth]（默认 548 指引值），避免竖长条；
///   内容较宽的弹窗（长表单/流程页）应显式传更大的 [preferredWidth]。
/// - 传了 [aspectRatio] 时，把正文锁定为该宽高比（如 `16 / 9` 或 `4 / 3`），
///   正文需自行滚动/伸缩以防溢出。
///
/// 其余参数与 `fluent.ContentDialog` 语义一致。
class AppContentDialog extends StatelessWidget {
  const AppContentDialog({
    super.key,
    this.title,
    this.content,
    this.actions,
    this.style,
    this.constraints,
    this.preferredWidth = 548,
    this.aspectRatio,
  });

  final Widget? title;
  final Widget? content;
  final List<Widget>? actions;
  final fluent.ContentDialogThemeData? style;
  final BoxConstraints? constraints;

  /// 未显式给定 [constraints] 时的宽度上限（会按屏幕收窄）。
  final double preferredWidth;

  /// 非空时把正文锁定为该宽高比（如 16/9、4/3）。
  final double? aspectRatio;

  @override
  Widget build(BuildContext context) {
    final box =
        constraints ??
        appDialogConstraints(context, preferredWidth: preferredWidth);
    var body = content;
    final ratio = aspectRatio;
    if (body != null && ratio != null && ratio > 0) {
      final size = appDialogSize(context, preferredWidth: preferredWidth);
      body = SizedBox(width: size.width, height: size.height, child: body);
    }
    return fluent.ContentDialog(
      title: title,
      content: body,
      actions: actions,
      style: style,
      constraints: box,
    );
  }
}

/// 统一的破坏性删除确认。返回 true 表示用户确认删除。
///
/// 各工作台的删除此前有的弹确认、有的直接删；此入口收敛文案与按钮语义。
/// [message] 应说明删的是什么，并提示「保存前可放弃修改回退」。
Future<bool> confirmDelete(BuildContext context, String message) async {
  final ok = await fluent.showDialog<bool>(
    context: context,
    builder: (ctx) => AppContentDialog(
      title: const Text('确认删除'),
      content: Text(
        message,
        style: const TextStyle(fontSize: 12.5, height: 1.5),
      ),
      actions: [
        fluent.Button(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('取消'),
        ),
        fluent.FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('删除'),
        ),
      ],
    ),
  );
  return ok == true;
}
