/// 区块标题行：图标 + 标题（可选行内说明 / 行尾动作）。
///
/// 迁移前导演壳的功能页头、移动详情页的「对白/选项」两处标题行
/// 各写一套（图标 15/16、标题 13/14、颜色与间距互不相同），
/// 这里统一为一种结构；[compact] 供壳内工具条（13pt）使用。
library;

import 'package:flutter/material.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import 'app_theme.dart';
import 'design_tokens.dart';

class SectionHeader extends StatelessWidget {
  const SectionHeader({
    super.key,
    required this.icon,
    required this.title,
    this.leading,
    this.description,
    this.trailing,
    this.iconColor,
    this.compact = false,
  });

  final IconData icon;
  final String title;

  /// 行首插槽（如导演壳的「返回全部功能」链接）。
  final Widget? leading;

  /// 行内说明（标题右侧，单行省略）。
  final String? description;

  /// 行尾动作（与 [description] 互斥取用；一般传 [SectionActionButton]）。
  final Widget? trailing;

  /// 图标色，缺省 [AppPalette.textSecondary]。
  final Color? iconColor;

  /// 紧凑档（图标 15 / 标题 13），缺省标准档（16 / 14）。
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        if (leading != null) ...[
          leading!,
          const SizedBox(width: AppSpace.m),
        ],
        Icon(icon,
            size: compact ? 15 : 16,
            color: iconColor ?? palette.textSecondary),
        const SizedBox(width: AppSpace.s6),
        Text(
          title,
          style: TextStyle(
            fontSize: compact ? AppText.emphasis : AppText.title,
            fontWeight: FontWeight.w600,
            color: palette.textHigh,
          ),
        ),
        if (description != null) ...[
          SizedBox(width: compact ? AppSpace.s10 : AppSpace.s),
          Expanded(
            child: Text(
              description!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style:
                  TextStyle(fontSize: AppText.caption, color: palette.textMuted),
            ),
          ),
        ] else if (trailing != null) ...[
          const Spacer(),
          trailing!,
        ],
      ],
    );
  }
}

/// 区块标题行尾的「添加」胶囊按钮（图标 + 文案，tint 底 + 半透明描边）。
///
/// 移动详情页两处标题行原先逐字重复了该形状，仅主色不同。
class SectionActionButton extends StatelessWidget {
  const SectionActionButton({
    super.key,
    required this.label,
    required this.onTap,
    required this.color,
  });

  final String label;
  final VoidCallback onTap;

  /// 主色（图标/文字/描边同源，底为其 15% 透明度）。
  final Color color;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpace.s, vertical: AppSpace.xs),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(AppRadius.m),
          border: Border.all(color: color.withValues(alpha: 0.3)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(FluentIcons.add_24_regular, size: 12, color: color),
            const SizedBox(width: AppSpace.xs),
            Text(label, style: TextStyle(fontSize: AppText.micro, color: color)),
          ],
        ),
      ),
    );
  }
}
