import 'package:flutter/material.dart';
import '../../core/motion.dart';
import '../../core/app_theme.dart';

class SectionCard extends StatefulWidget {
  const SectionCard({
    super.key,
    required this.title,
    this.desc,
    this.child,
    this.padding = const EdgeInsets.all(12),
  });

  final String title;
  final String? desc;
  final Widget? child;
  final EdgeInsetsGeometry padding;

  @override
  State<SectionCard> createState() => _SectionCardState();
}

class _SectionCardState extends State<SectionCard> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedContainer(
        duration: AppMotion.fast,
        curve: AppMotion.easeOut,
        decoration: BoxDecoration(
          color: palette.panel,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: _hover ? palette.borderHover : palette.surface),
          boxShadow: _hover ? [BoxShadow(color: palette.scrimWeak, blurRadius: 12, offset: const Offset(0, 4))] : [],
        ),
        transform: Matrix4.identity()..translateByDouble(0.0, _hover ? -1.0 : 0.0, 0.0, 1.0),
        padding: widget.padding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.title.isNotEmpty) ...[
              Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: palette.textHigh, fontWeight: FontWeight.w600)),
              if (widget.desc != null) ...[
                const SizedBox(height: 4),
                Text(widget.desc!, style: TextStyle(fontSize: 11, color: palette.textMuted)),
              ],
              const SizedBox(height: 8),
            ],
            if (widget.child != null) Expanded(child: widget.child!),
          ],
        ),
      ),
    );
  }
}

/// 工作台「分区卡片」的既有三种形态。12 个工作台此前各自内联了一份私有
/// `_SectionCard`（其中 8 份逐字节相同、2 份相同、1 份独有），此处按 [tone]
/// 收敛为一份实现：边距 / 圆角 / 底色 / 字号 / 行距逐一保持原值，属纯去重，
/// 不改外观。
enum SectionCardTone {
  /// 平铺型：`palette.bgAlt` + 圆角 10、标题 12.5/w600/goldText、子项间 8px。
  /// 目标 / 外部对话 / 仓库 / 消息 / 小游戏 / JSON / 社交 / 空间 的原形态。
  flat,

  /// 卡片型：`palette.card` + 圆角 11、可带前置图标、标题 13/w600/textHigh、
  /// 子项之间不留自动间隔（留白由调用方自己控制）。事件 / 闲聊 的原形态。
  card,

  /// 面板型：`palette.panel` + 圆角 12、标题 14/w600/goldText、子项间 14px。
  /// 人物工作台的原形态。
  panel,
}

/// 工作台通用分区卡片。[children] 按 [tone] 的既有间隔逐个排布；单件场景也可
/// 用 [child]（等价于只有一个元素的 [children]）。
class WorkbenchSectionCard extends StatelessWidget {
  const WorkbenchSectionCard({
    super.key,
    required this.title,
    this.icon,
    this.subtitle,
    this.child,
    this.children = const <Widget>[],
    this.tone = SectionCardTone.flat,
  });

  final String title;
  final IconData? icon;
  final String? subtitle;
  final Widget? child;
  final List<Widget> children;
  final SectionCardTone tone;

  @override
  Widget build(BuildContext context) {
    final bool flat = tone == SectionCardTone.flat;
    final bool panelTone = tone == SectionCardTone.panel;

    final double titleSize = flat ? 12.5 : (panelTone ? 14 : 13);
    final double descSize = panelTone ? 11.5 : 11;
    final double gap = flat ? 8 : (panelTone ? 14 : 0);
    final double headGap = flat ? 10 : (panelTone ? 14 : 12);

    Widget titleWidget;
    if (tone == SectionCardTone.card) {
      titleWidget = Row(
        children: [
          if (icon != null) ...[
            Icon(icon, size: 14, color: palette.goldText),
            const SizedBox(width: 6),
          ],
          Text(title,
              style: TextStyle(
                  fontSize: titleSize,
                  fontWeight: FontWeight.w600,
                  color: palette.textHigh)),
        ],
      );
    } else {
      titleWidget = Text(title,
          style: TextStyle(
              fontSize: titleSize,
              fontWeight: FontWeight.w600,
              color: palette.goldText));
    }

    return Container(
      margin: EdgeInsets.only(bottom: panelTone ? 16 : 14),
      padding: flat
          ? const EdgeInsets.fromLTRB(14, 12, 14, 14)
          : (panelTone
              ? const EdgeInsets.fromLTRB(18, 16, 18, 18)
              : const EdgeInsets.fromLTRB(16, 14, 16, 16)),
      decoration: BoxDecoration(
        color: flat
            ? palette.bgAlt
            : (panelTone ? palette.panel : palette.card),
        borderRadius: BorderRadius.circular(flat ? 10 : (panelTone ? 12 : 11)),
        border: Border.all(color: palette.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          titleWidget,
          if (subtitle != null) ...[
            const SizedBox(height: 4),
            Text(subtitle!,
                style: TextStyle(
                    fontSize: descSize, height: 1.6, color: palette.textMuted)),
          ],
          SizedBox(height: headGap),
          if (child != null) ...[
            child!,
            if (gap > 0) SizedBox(height: gap),
          ],
          for (final c in children) ...[
            c,
            if (gap > 0) SizedBox(height: gap),
          ],
        ],
      ),
    );
  }
}
