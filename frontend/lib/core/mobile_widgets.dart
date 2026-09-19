import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
          borderRadius: BorderRadius.circular(8),
        ),
        child: InkWell(
          onTap: () {
            MobileHaptic.lightImpact().then((_) => onPressed());
          },
          borderRadius: BorderRadius.circular(8),
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
      color: color ?? Theme.of(context).primaryColor,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: loading ? null : () {
          MobileHaptic.mediumImpact().then((_) => onPressed());
        },
        borderRadius: BorderRadius.circular(8),
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
            fillColor: Colors.white.withOpacity(0.1),
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
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
      style: const TextStyle(fontSize: 16),
    );
  }
}

/// 移动端卡片容器。
class MobileCard extends StatelessWidget {
  const MobileCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.margin = const EdgeInsets.only(bottom: 12),
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
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: Colors.white70,
              ),
            ),
            const SizedBox(height: 12),
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
        borderRadius: BorderRadius.circular(12),
        child: Container(
          margin: margin,
          padding: EdgeInsets.zero,
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.05),
            borderRadius: BorderRadius.circular(12),
          ),
          child: content,
        ),
      );
    }

    return Container(
      margin: margin,
      padding: EdgeInsets.zero,
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.05),
        borderRadius: BorderRadius.circular(12),
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