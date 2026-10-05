/// 目录卡片的公共视觉件：**只呈现「人话标题 + 分类」**，不显示占位符
/// （`@ATTR@`）与原始代码（`[1, 1, @ATTR@, V]`）。
///
/// 供积木库左栏 [BlockCatalogList] 与无代码字段目录（`_CatalogBrowserDialog`）
/// 共用，保证「选效果」的两种入口观感一致（对标成熟方案的目录卡片）。
library;

import 'package:flutter/material.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../../core/app_theme.dart';
import '../../core/motion.dart';

/// 目录卡片：主行=人话标题，副行=分类；右侧一个「＋」。
class BlockCatalogTile extends StatefulWidget {
  const BlockCatalogTile({
    super.key,
    required this.title,
    required this.category,
    required this.onTap,
    this.addIcon = true,
  });

  /// 已人话化的标题（见 `humanizeBlockDesc`）。
  final String title;

  /// 分类名（白话，如「改变属性」）。
  final String category;
  final VoidCallback onTap;
  final bool addIcon;

  @override
  State<BlockCatalogTile> createState() => _BlockCatalogTileState();
}

class _BlockCatalogTileState extends State<BlockCatalogTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: AppMotion.fast,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: _hover ? palette.card : palette.bgAlt,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: _hover ? palette.borderHover : palette.border,
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      widget.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        color: palette.textHigh,
                        fontWeight: FontWeight.w600,
                        height: 1.3,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      widget.category,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 10.5, color: palette.textMuted),
                    ),
                  ],
                ),
              ),
              if (widget.addIcon) ...[
                const SizedBox(width: 6),
                Icon(
                  FluentIcons.add_24_regular,
                  size: 14,
                  color: _hover ? accentColor : palette.iconDisabled,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 目录分类胶囊。
class BlockCategoryChip extends StatelessWidget {
  const BlockCategoryChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
          decoration: BoxDecoration(
            color: selected ? accentColor.withValues(alpha: 0.14) : null,
            borderRadius: BorderRadius.circular(7),
            border: Border.all(
              color: selected
                  ? accentColor.withValues(alpha: 0.4)
                  : palette.border,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 11.5,
              color: selected ? palette.textHigh : palette.textMuted,
            ),
          ),
        ),
      ),
    );
  }
}
