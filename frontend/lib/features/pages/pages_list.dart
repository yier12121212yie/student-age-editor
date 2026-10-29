import 'package:flutter/material.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../../core/models.dart';
import '../../core/responsive.dart';
import '../editor/editor_controller.dart';
import '../shell/mobile_subpage.dart';
import 'pages_catalog.dart';
import 'workbench_registry.dart';
import '../../core/app_theme.dart';
import '../../core/editor_leave_guard.dart';

/// 编辑页面侧边栏：按 [editorPages] 枚举全部页面入口。
///
/// B2：若某页面存在专属工作台（见 [workbenchEntryForPage]），移动端点击直接
/// 打开工作台（全屏子页），桌面端在行尾追加「打开工作台」按钮；无工作台的
/// 页面仍走通用 [SchemaEditorView]（controller.open）。
class PagesList extends StatelessWidget {
  const PagesList({super.key, required this.state, required this.controller});
  final AppState state;
  final EditorController controller;

  /// 打开页面专属工作台（全屏子页，自带返回）。
  void _openWorkbench(BuildContext context, EditorPageDef page) {
    final entry = workbenchEntryForPage(page.id);
    if (entry == null) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => MobileSubPage(
          title: page.title,
          body: entry.build(WorkbenchDeps(state: state)),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          height: 38,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              Text('编辑页面',
                  style: TextStyle(
                      fontSize: 12, color: palette.textSecondary, fontWeight: FontWeight.w600)),
            ],
          ),
        ),
        Divider(height: 1, color: palette.border),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(vertical: 4),
            itemCount: visibleEditorPages.length,
            itemBuilder: (context, i) {
              final page = visibleEditorPages[i];
              final mobile = isMobileWidth(context);
              final hasWorkbench = workbenchEntryForPage(page.id) != null;
              return MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  // 移动端：有专属工作台的页面直接打开工作台，否则走通用编辑页。
                  onTap: () async {
                    if (mobile && hasWorkbench) {
                      _openWorkbench(context, page);
                    } else {
                      await openDocGuarded(
                        context,
                        controller,
                        OpenDoc.page(pageId: page.id, title: page.title),
                      );
                    }
                  },
                  child: Padding(
                    // 移动端：卡片化 + 更大热区（≥48px）
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    child: Container(
                      decoration: mobile
                          ? BoxDecoration(
                              color: palette.panel,
                              borderRadius: BorderRadius.circular(8),
                            )
                          : null,
                      padding: mobile
                          ? const EdgeInsets.symmetric(horizontal: 12, vertical: 14)
                          : EdgeInsets.zero,
                      child: Row(
                        children: [
                          Icon(pageIconFor(page.id),
                              size: 16, color: accentColor),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(page.title,
                                    style: TextStyle(
                                        fontSize: mobile ? 14 : 13,
                                        color: palette.textPrimary,
                                        fontWeight: FontWeight.w600)),
                                const SizedBox(height: 2),
                                Text(page.description,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                        fontSize: 11, color: palette.textHint)),
                              ],
                            ),
                          ),
                          // 桌面：工作台页面在行尾给一个显式入口（不影响原有
                          // 通用编辑页动线，两者并存）。
                          if (!mobile && hasWorkbench)
                            Tooltip(
                              message: '打开${page.title}工作台',
                              child: IconButton(
                                icon: Icon(FluentIcons.window_24_regular,
                                    size: 15, color: accentColor),
                                onPressed: () => _openWorkbench(context, page),
                              ),
                            ),
                          Icon(FluentIcons.chevron_right_24_regular,
                              size: 13, color: palette.textFaint),
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
