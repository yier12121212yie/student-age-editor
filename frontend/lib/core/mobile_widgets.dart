import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_theme.dart';
import 'design_tokens.dart';

/// 统一移动端小工具库：提供触摸友好的 UI 组件和便捷操作。

/// 移动端触摸反馈助手。
class MobileHaptic {
  /// 轻量震动（列表点击、切换等）。
  static Future<void> lightImpact() async {
    await HapticFeedback.lightImpact();
  }

  /// 中等震动（确认操作、表单提交等）。
  static Future<void> mediumImpact() async {
    await HapticFeedback.mediumImpact();
  }

  /// 粗犷震动（删除、重要操作）。
  static Future<void> heavyImpact() async {
    await HapticFeedback.heavyImpact();
  }

  /// 文本输入震动模拟（使用 lightImpact 替代）。
  static Future<void> selectionChange() async {
    await lightImpact(); // Flutter 不支持 selectionChange，用轻量震动替代
  }

  /// 成功提示震动。
  static Future<void> success() async {
    await HapticFeedback.lightImpact();
  }

  /// 错误提示震动。
  static Future<void> error() async {
    await HapticFeedback.vibrate();
  }
}

/// 移动端图标按钮 - 保证最小 44x44px 触控区域。
class MobileIconButton extends StatelessWidget {
  const MobileIconButton({
    super.key,
    required this.icon,
    required this.onPressed,
    this.size = 44.0,
    this.color,
    this.backgroundColor,
    this.tooltip,
  });

  final IconData icon;
  final VoidCallback onPressed;
  final double size;
  final Color? color;
  final Color? backgroundColor;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip ?? '',
      child: Material(
        color: backgroundColor ?? Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.l),
        ),
        child: InkWell(
          onTap: () {
            MobileHaptic.lightImpact().then((_) => onPressed());
          },
          borderRadius: BorderRadius.circular(AppRadius.l),
          child: SizedBox(
            width: size,
            height: size,
            child: Center(
              child: Icon(icon, color: color, size: 20),
            ),
          ),
        ),
      ),
    );
  }
}

/// 移动端大按钮 - 全宽或大半宽按钮。
class MobileButton extends StatelessWidget {
  const MobileButton.full({
    super.key,
    required this.text,
    required this.onPressed,
    this.loading = false,
    this.color,
    this.textColor,
    this.height = 44,
    this.width, // 全宽按钮也支持指定宽度
  });

  const MobileButton({
    super.key,
    required this.text,
    required this.onPressed,
    this.width,
    this.loading = false,
    this.color,
    this.textColor,
    this.height = 44,
  });

  final String text;
  final VoidCallback onPressed;
  final double? width;
  final bool loading;
  final Color? color;
  final Color? textColor;
  final double height;

  @override
  Widget build(BuildContext context) {
    final btn = SizedBox(
      width: width,
      height: height,
      child: Stack(
        alignment: Alignment.center,
        children: [
          if (loading)
            const CircularProgressIndicator(strokeWidth: 2),
          if (!loading)
            Text(text),
        ],
      ),
    );

    return Material(
      color: color ?? palette.primaryColor,
      borderRadius: BorderRadius.circular(AppRadius.l),
      child: InkWell(
        onTap: loading ? null : () {
          MobileHaptic.mediumImpact().then((_) => onPressed());
        },
        borderRadius: BorderRadius.circular(AppRadius.l),
        child: btn,
      ),
    );
  }
}

/// 移动端输入框 - 高度自适应键盘。
class MobileTextField extends StatefulWidget {
  const MobileTextField({
    super.key,
    this.controller,
    this.decoration,
    this.keyboardType = TextInputType.text,
    this.onChanged,
    this.onSubmitted,
    this.maxLength,
    this.maxLines = 1,
    this.readOnly = false,
    this.hintText,
    this.autoFocus = false,
  });

  final TextEditingController? controller;
  final InputDecoration? decoration;
  final TextInputType keyboardType;
  final Function(String)? onChanged;
  final Function(String)? onSubmitted;
  final int? maxLength;
  final int maxLines;
  final bool readOnly;
  final String? hintText;
  final bool autoFocus;

  @override
  State<MobileTextField> createState() => _MobileTextFieldState();
}

class _MobileTextFieldState extends State<MobileTextField> {
  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: widget.controller,
      decoration: widget.decoration ??
          InputDecoration(
            hintText: widget.hintText,
            filled: true,
            fillColor: palette.overlayMedium,
            contentPadding: const EdgeInsets.symmetric(
                horizontal: AppSpace.l, vertical: 14),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(AppRadius.l),
              borderSide: BorderSide.none,
            ),
          ),
      keyboardType: widget.keyboardType,
      onChanged: widget.onChanged,
      onSubmitted: widget.onSubmitted,
      maxLength: widget.maxLength,
      maxLines: widget.maxLines,
      readOnly: widget.readOnly,
      autofocus: widget.autoFocus,
      style: const TextStyle(fontSize: AppText.display),
    );
  }
}

/// 移动端卡片容器。
class MobileCard extends StatelessWidget {
  const MobileCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(AppSpace.l),
    this.margin = const EdgeInsets.only(bottom: AppSpace.m),
    this.title,
    this.onTap,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry margin;
  final String? title;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final content = Padding(
      padding: padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title != null) ...[
            Text(
              title!,
              style: TextStyle(
                fontSize: AppText.title,
                fontWeight: FontWeight.w600,
                color: palette.textPrimary,
              ),
            ),
            const SizedBox(height: AppSpace.m),
          ],
          child,
        ],
      ),
    );

    if (onTap != null) {
      return InkWell(
        onTap: () {
          MobileHaptic.lightImpact().then((_) => onTap!());
        },
        borderRadius: BorderRadius.circular(AppRadius.xxl),
        child: Container(
          margin: margin,
          padding: EdgeInsets.zero,
          decoration: BoxDecoration(
            color: palette.overlayWeak,
            borderRadius: BorderRadius.circular(AppRadius.xxl),
          ),
          child: content,
        ),
      );
    }

    return Container(
      margin: margin,
      padding: EdgeInsets.zero,
      decoration: BoxDecoration(
        color: palette.overlayWeak,
        borderRadius: BorderRadius.circular(AppRadius.xxl),
      ),
      child: content,
    );
  }
}

/// 移动端列表项 - 带触觉反馈的点击项。
class MobileListItem extends StatelessWidget {
  const MobileListItem({
    super.key,
    required this.leading,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.onLongPress,
  });

  final Widget leading;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      minLeadingWidth: 24,
      minVerticalPadding: 8,
      minTileHeight: 44,
      visualDensity: VisualDensity.compact,
      leading: leading,
      title: Text(title),
      subtitle: subtitle != null ? Text(subtitle!) : null,
      trailing: trailing,
      onTap: () {
        MobileHaptic.lightImpact().then((_) => onTap?.call());
      },
      onLongPress: onLongPress,
    );
  }
}

/// 通用底部滑出层：可拖动（手柄/标题区），头部可带标题、操作按钮与关闭键；
/// 底部随软键盘抬升（viewInsets），避免输入法遮挡内容。
/// 从 MobileShell._showSheet 抽出，供 AI 面板、预览呼出等复用。
///
/// [initialSize] 默认 0.92；短内容（搜索、选择器）可传 0.6~0.8，避免
/// 半屏内容也铺满整屏。[showClose] 默认 true——92% 高度时顶部遮罩只剩
/// 一条窄缝，没有关闭键用户只能靠系统返回。
Future<void> showMobileSheet(
  BuildContext context,
  Widget child, {
  List<Widget>? headerActions,
  String? title,
  double initialSize = 0.92,
  double minSize = 0.5,
  double maxSize = 0.96,
  bool showClose = true,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    // 下滑收起由 [_MobileSheetFrame] 的头部手势处理；关掉 modal 自带拖拽，
    // 否则外层手势会抢走垂直拖动，手柄拖不动。
    enableDrag: false,
    backgroundColor: palette.panel,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.xxl)),
    ),
    builder: (ctx) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
      child: _MobileSheetFrame(
        initialSize: initialSize,
        minSize: minSize,
        maxSize: maxSize,
        title: title,
        headerActions: headerActions,
        showClose: showClose,
        child: child,
      ),
    ),
  );
}

/// 滑出层骨架：负责拖拽手势、标题/关闭键与安全区。
///
/// 不用 [DraggableScrollableSheet]：它的 controller 只有在子内容使用其
/// 提供的 ScrollController 时才 attached；本项目滑出层里常是自带滚动条的
/// 复杂面板（AI 会话、工作台设置），强行接管会和外层滚动打架。这里用
/// 自己的高度比例 + 头部垂直手势，内容区完全交给调用方。
class _MobileSheetFrame extends StatefulWidget {
  const _MobileSheetFrame({
    required this.child,
    required this.initialSize,
    required this.minSize,
    required this.maxSize,
    required this.title,
    required this.headerActions,
    required this.showClose,
  });

  final Widget child;
  final double initialSize;
  final double minSize;
  final double maxSize;
  final String? title;
  final List<Widget>? headerActions;
  final bool showClose;

  @override
  State<_MobileSheetFrame> createState() => _MobileSheetFrameState();
}

class _MobileSheetFrameState extends State<_MobileSheetFrame> {
  late double _size = widget.initialSize;
  bool _dragging = false;

  void _close() {
    if (!mounted) return;
    Navigator.of(context).maybePop();
  }

  void _onDragUpdate(DragUpdateDetails d, double available) {
    if (available <= 0) return;
    setState(() {
      _dragging = true;
      _size = (_size - d.delta.dy / available)
          .clamp(widget.minSize, widget.maxSize);
    });
  }

  void _onDragEnd(DragEndDetails d) {
    final v = d.primaryVelocity ?? 0;
    // 向下快速甩，或已经拖到接近最小高度：直接关闭。
    if (v > 700 || _size <= widget.minSize + 0.06) {
      _close();
      return;
    }
    // 向上快速甩：展开到最大；否则吸附到初始/最大中较近者。
    final target = v < -700
        ? widget.maxSize
        : ((_size - widget.initialSize).abs() <
                (_size - widget.maxSize).abs()
            ? widget.initialSize
            : widget.maxSize);
    setState(() {
      _dragging = false;
      _size = target;
    });
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final available = box.maxHeight;
        return TweenAnimationBuilder<double>(
          tween: Tween<double>(begin: _size, end: _size),
          duration: _dragging
              ? Duration.zero
              : const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          builder: (context, value, child) => SizedBox(
            height: available * value,
            child: child,
          ),
          child: Material(
            key: const ValueKey('mobile-sheet'),
            color: palette.panel,
            clipBehavior: Clip.antiAlias,
            borderRadius: const BorderRadius.vertical(
              top: Radius.circular(AppRadius.xxl),
            ),
            // SafeArea(top: false)：滑出层贴屏幕底边，AI 输入栏/发送按钮不能
            // 被手势条压住；外层 Padding 只处理软键盘 viewInsets。
            child: SafeArea(
              top: false,
              child: Column(
                children: [
                  const SizedBox(height: AppSpace.xs),
                  SizedBox(
                    height: 44,
                    child: Row(
                      children: [
                        Expanded(
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onVerticalDragUpdate: (d) =>
                                _onDragUpdate(d, available),
                            onVerticalDragEnd: _onDragEnd,
                            child: Row(
                              children: [
                                const SizedBox(width: 14),
                                Container(
                                  width: 36,
                                  height: 4,
                                  decoration: BoxDecoration(
                                    color: palette.borderHover,
                                    borderRadius:
                                        BorderRadius.circular(AppRadius.xxs),
                                  ),
                                ),
                                if (widget.title != null) ...[
                                  const SizedBox(width: AppSpace.m),
                                  Flexible(
                                    child: Text(
                                      widget.title!,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: AppText.subhead,
                                        fontWeight: FontWeight.w600,
                                        color: palette.textHigh,
                                      ),
                                    ),
                                  ),
                                ],
                                const Spacer(),
                              ],
                            ),
                          ),
                        ),
                        ...?widget.headerActions,
                        if (widget.showClose)
                          IconButton(
                            tooltip: '关闭',
                            icon: Icon(
                              Icons.close_rounded,
                              size: 18,
                              color: palette.textSecondary,
                            ),
                            onPressed: _close,
                          ),
                        const SizedBox(width: AppSpace.xs),
                      ],
                    ),
                  ),
                  const SizedBox(height: AppSpace.xs),
                  Expanded(child: widget.child),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 移动端全屏对话框包装器。
Widget mobileDialog({
  required BuildContext context,
  required String title,
  required Widget child,
  List<Widget>? actions,
}) {
  return AlertDialog(
    title: Text(title),
    content: SingleChildScrollView(child: child),
    actions: actions,
    scrollable: true,
  );
}