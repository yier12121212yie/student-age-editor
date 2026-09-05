import 'package:flutter/material.dart';

import '../../core/app_theme.dart';
import '../../core/motion.dart';
import '../editor/editor_controller.dart';

/// 剧情图模式的顶栏视图（浏览器式标签）。
///
/// graph 为画布首页；mods/bugfix 不设固定标签（收进条尾 ⋯ 溢出菜单），
/// 选中后以临时标签形式出现在条上；doc 表示当前展示动态文档标签
/// （EditorController 的 cfg/file/page/preview）。
enum StoryFlowView {
  graph, // 剧情图（首页）
  pages, // 编辑页面
  files,
  resources,
  base,
  cloud,
  plugins,
  settings,
  mods,
  bugfix,
  doc,
}

extension StoryFlowViewMeta on StoryFlowView {
  String get label {
    switch (this) {
      case StoryFlowView.graph:
        return '剧情图';
      case StoryFlowView.pages:
        return '编辑页面';
      case StoryFlowView.files:
        return '文件';
      case StoryFlowView.resources:
        return '资源';
      case StoryFlowView.base:
        return '基础库';
      case StoryFlowView.cloud:
        return '云同步';
      case StoryFlowView.plugins:
        return '插件';
      case StoryFlowView.settings:
        return '设置';
      case StoryFlowView.mods:
        return '模组';
      case StoryFlowView.bugfix:
        return '错误修复';
      case StoryFlowView.doc:
        return '文档';
    }
  }

  IconData get icon {
    switch (this) {
      case StoryFlowView.graph:
        return Icons.account_tree_outlined;
      case StoryFlowView.pages:
        return Icons.edit_note;
      case StoryFlowView.files:
        return Icons.folder_outlined;
      case StoryFlowView.resources:
        return Icons.image_outlined;
      case StoryFlowView.base:
        return Icons.menu_book_outlined;
      case StoryFlowView.cloud:
        return Icons.cloud_outlined;
      case StoryFlowView.plugins:
        return Icons.extension_outlined;
      case StoryFlowView.settings:
        return Icons.settings_outlined;
      case StoryFlowView.mods:
        return Icons.inventory_2_outlined;
      case StoryFlowView.bugfix:
        return Icons.build_outlined;
      case StoryFlowView.doc:
        return Icons.description_outlined;
    }
  }
}

/// 顶部常驻标签条：始终显示，内容区（含画布）让出其高度。
/// 设置/插件入口不在此列（已移入画布左侧浮动工具栏）。
class StoryFlowTopTabs extends StatefulWidget {
  const StoryFlowTopTabs({
    super.key,
    required this.view,
    required this.controller,
    required this.onView,
    required this.onSelectDoc,
    required this.onCloseDoc,
  });

  final StoryFlowView view;
  final EditorController controller;
  final ValueChanged<StoryFlowView> onView;
  final ValueChanged<int> onSelectDoc;
  final ValueChanged<int> onCloseDoc;

  @override
  State<StoryFlowTopTabs> createState() => _StoryFlowTopTabsState();
}

class _StoryFlowTopTabsState extends State<StoryFlowTopTabs> {
  /// 固定标签（设置/插件在画布侧栏工具栏；溢出菜单里的 mods/bugfix 除外）。
  static const _fixedTabs = [
    StoryFlowView.graph,
    StoryFlowView.pages,
    StoryFlowView.files,
    StoryFlowView.resources,
    StoryFlowView.base,
    StoryFlowView.cloud,
  ];

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: Container(
        height: 42,
        margin: const EdgeInsets.fromLTRB(12, 6, 12, 0),
        decoration: BoxDecoration(
          color: palette.card,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: palette.border),
          boxShadow: [
            BoxShadow(
              color: palette.bgDeep2.withValues(alpha: 0.5),
              blurRadius: 16,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
        child: Row(
          children: [
            for (final tab in _fixedTabs) ...[
              _TabButton(
                label: tab.label,
                icon: tab.icon,
                active: widget.view == tab,
                onTap: () => widget.onView(tab),
              ),
              const SizedBox(width: 2),
            ],
            _divider(),
            Expanded(
              child: ListenableBuilder(
                listenable: widget.controller,
                builder: (context, _) {
                  final docs = widget.controller.docs;
                  return ListView.separated(
                    scrollDirection: Axis.horizontal,
                    padding: EdgeInsets.zero,
                    itemCount: docs.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 2),
                    itemBuilder: (context, i) {
                      final doc = docs[i];
                      final active =
                          widget.view == StoryFlowView.doc &&
                          i == widget.controller.currentIndex;
                      return _TabButton(
                        label: doc.title,
                        icon: _docIcon(doc),
                        active: active,
                        onClose: () => widget.onCloseDoc(i),
                        onTap: () => widget.onSelectDoc(i),
                      );
                    },
                  );
                },
              ),
            ),
            _divider(),
            // 溢出菜单：模组 / 错误修复（无固定标签的页面）
            Material(
              type: MaterialType.transparency,
              child: PopupMenuButton<StoryFlowView>(
                tooltip: '更多页面',
                // 同「添加节点」菜单：指定不透明底板
                color: palette.card,
                onSelected: (v) => widget.onView(v),
                itemBuilder: (_) => const [
                  PopupMenuItem(
                    value: StoryFlowView.mods,
                    child: Row(
                      children: [
                        Icon(Icons.inventory_2_outlined, size: 15),
                        SizedBox(width: 8),
                        Text('模组', style: TextStyle(fontSize: 12)),
                      ],
                    ),
                  ),
                  PopupMenuItem(
                    value: StoryFlowView.bugfix,
                    child: Row(
                      children: [
                        Icon(Icons.build_outlined, size: 15),
                        SizedBox(width: 8),
                        Text('错误修复', style: TextStyle(fontSize: 12)),
                      ],
                    ),
                  ),
                ],
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8),
                  child: Icon(
                    Icons.more_horiz,
                    size: 16,
                    color: Color(0xFF9B9BA3),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static IconData _docIcon(OpenDoc doc) {
    if (doc.kind == 'cfg') return Icons.table_chart_outlined;
    if (doc.kind == 'preview') return Icons.play_circle_outline;
    if (doc.kind == 'page') return Icons.edit_note;
    return Icons.description_outlined;
  }

  Widget _divider() => Container(
    width: 1,
    height: 18,
    margin: const EdgeInsets.symmetric(horizontal: 4),
    color: palette.border,
  );
}

/// 标签条按钮：固定入口 / 动态文档标签共用。
class _TabButton extends StatefulWidget {
  const _TabButton({
    required this.label,
    required this.icon,
    required this.active,
    required this.onTap,
    this.onClose,
  });

  final String label;
  final IconData icon;
  final bool active;
  final VoidCallback onTap;
  final VoidCallback? onClose;

  @override
  State<_TabButton> createState() => _TabButtonState();
}

class _TabButtonState extends State<_TabButton> {
  bool _hover = false;
  bool _closeHover = false;

  @override
  Widget build(BuildContext context) {
    final accent = const Color(0xFF6C5CE7);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() {
        _hover = false;
        _closeHover = false;
      }),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: AppMotion.fast,
          curve: AppMotion.easeOut,
          padding: const EdgeInsets.symmetric(horizontal: 9),
          decoration: BoxDecoration(
            color: widget.active
                ? accent.withValues(alpha: 0.15)
                : _hover
                ? palette.hover
                : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: widget.active
                  ? accent.withValues(alpha: 0.45)
                  : Colors.transparent,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                widget.icon,
                size: 13,
                color: widget.active
                    ? accent
                    : (_hover ? palette.textPrimary : palette.textSecondary),
              ),
              const SizedBox(width: 5),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 130),
                child: Text(
                  widget.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: widget.active
                        ? FontWeight.w600
                        : FontWeight.normal,
                    color: widget.active
                        ? palette.textHigh
                        : _hover
                        ? palette.textPrimary
                        : palette.textSecondary,
                  ),
                ),
              ),
              if (widget.onClose != null) ...[
                const SizedBox(width: 3),
                MouseRegion(
                  onEnter: (_) => setState(() => _closeHover = true),
                  onExit: (_) => setState(() => _closeHover = false),
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: widget.onClose,
                    child: AnimatedContainer(
                      duration: AppMotion.fast,
                      padding: const EdgeInsets.all(2),
                      decoration: BoxDecoration(
                        color: _closeHover
                            ? palette.borderHover
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Icon(
                        Icons.close,
                        size: 11,
                        color: _closeHover
                            ? palette.textHigh
                            : palette.textHint,
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
