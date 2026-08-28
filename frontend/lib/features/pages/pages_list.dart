import 'package:flutter/material.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../../core/models.dart';
import '../../core/responsive.dart';
import '../editor/editor_controller.dart';
import 'pages_catalog.dart';

/// 编辑页面侧边栏：9 个页面入口。
class PagesList extends StatelessWidget {
  const PagesList({super.key, required this.state, required this.controller});
  final AppState state;
  final EditorController controller;

  static const _icons = <String, IconData>{
    'story': FluentIcons.chat_24_regular,
    'person': FluentIcons.person_24_regular,
    'evt': FluentIcons.calendar_24_regular,
    'social': FluentIcons.people_community_24_regular,
    'gift': FluentIcons.gift_24_regular,
    'love': FluentIcons.heart_24_regular,
    'function': FluentIcons.games_24_regular,
    'resource': FluentIcons.image_24_regular,
    'official': FluentIcons.grid_24_regular,
  };

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          height: 38,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: const Row(
            children: [
              Text('编辑页面',
                  style: TextStyle(
                      fontSize: 12, color: Color(0xFF9B9BA3), fontWeight: FontWeight.w600)),
            ],
          ),
        ),
        const Divider(height: 1, color: Color(0xFF2A2A2E)),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(vertical: 4),
            itemCount: editorPages.length,
            itemBuilder: (context, i) {
              final page = editorPages[i];
              return MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  onTap: () => controller.open(OpenDoc.page(pageId: page.id, title: page.title)),
                  child: Padding(
                    // 移动端：卡片化 + 更大热区（≥48px）
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    child: Container(
                      decoration: isMobileWidth(context)
                          ? BoxDecoration(
                              color: const Color(0xFF1E1E23),
                              borderRadius: BorderRadius.circular(8),
                            )
                          : null,
                      padding: isMobileWidth(context)
                          ? const EdgeInsets.symmetric(horizontal: 12, vertical: 14)
                          : EdgeInsets.zero,
                      child: Row(
                        children: [
                          Icon(_icons[page.id] ?? FluentIcons.table_24_regular,
                              size: 16, color: const Color(0xFF6C5CE7)),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(page.title,
                                    style: TextStyle(
                                        fontSize: isMobileWidth(context) ? 14 : 13,
                                        color: const Color(0xFFD4D4D8),
                                        fontWeight: FontWeight.w600)),
                                const SizedBox(height: 2),
                                Text(page.description,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                        fontSize: 11, color: Color(0xFF6E6E76))),
                              ],
                            ),
                          ),
                          const Icon(FluentIcons.chevron_right_24_regular,
                              size: 13, color: Color(0xFF5E5E66)),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
