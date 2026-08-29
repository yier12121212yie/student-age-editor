import 'package:flutter/material.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import '../../core/models.dart';
import '../../core/motion.dart';
import '../editor/editor_controller.dart';
import '../editor/schema_editor_view.dart';
import '../editor/section_card.dart';
import '../files/file_viewer.dart';
import '../pages/page_view.dart';
import '../pages/pages_catalog.dart';
import '../preview/event_preview_view.dart';
import '../../core/app_theme.dart';

class EditorArea extends StatefulWidget {
  const EditorArea({
    super.key,
    required this.state,
    required this.controller,
    this.classic = false,
    this.showTabs = true,
    this.onOpenSearch,
  });
  final AppState state;
  final EditorController controller;
  final bool classic;
  final bool showTabs;
  final VoidCallback? onOpenSearch;
  @override
  State<EditorArea> createState() => _EditorAreaState();
}

class _EditorAreaState extends State<EditorArea> {
  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        if (widget.showTabs) ...[
          _TabBar(controller: widget.controller),
          Divider(height: 1, color: palette.border),
        ],
        Expanded(
          child: ListenableBuilder(
            listenable: widget.controller,
            builder: (context, _) {
              final doc = widget.controller.current;
              Widget content;
              if (doc == null) {
                content = const _WelcomeView(key: ValueKey('welcome'));
              } else if (doc.kind == 'cfg') {
                content = SchemaEditorView(
                  key: ValueKey(doc),
                  state: widget.state,
                  cfgName: doc.cfgName,
                  classic: widget.classic,
                  onPreview: (evtId) =>
                      widget.controller.open(OpenDoc.preview(eventId: evtId)),
                  onOpenSearch: widget.onOpenSearch,
                );
              } else if (doc.kind == 'page') {
                final page = pageById(doc.pageId);
                if (page != null) {
                  content = EditorPageView(
                    key: ValueKey(doc),
                    state: widget.state,
                    page: page,
                    classic: widget.classic,
                    onPreview: (evtId) =>
                        widget.controller.open(OpenDoc.preview(eventId: evtId)),
                    onOpenSearch: widget.onOpenSearch,
                  );
                } else {
                  content = const _WelcomeView(key: ValueKey('welcome'));
                }
              } else if (doc.kind == 'preview') {
                final view = EventPreviewView(
                  key: ValueKey(doc),
                  state: widget.state,
                  controller: widget.controller,
                  eventId: doc.eventId,
                );
                content = !widget.classic
                    ? view
                    : Padding(
                        padding: const EdgeInsets.all(10),
                        child: SectionCard(title: '事件预览', child: view),
                      );
              } else {
                final view = FileViewer(
                  key: ValueKey(doc),
                  state: widget.state,
                  path: doc.path,
                  title: doc.title,
                );
                content = !widget.classic
                    ? view
                    : Padding(
                        padding: const EdgeInsets.all(10),
                        child: SectionCard(title: '文件 ', child: view),
                      );
              }
              return AnimatedSwitcher(
                duration: AppMotion.normal,
                switchInCurve: AppMotion.easeOut,
                switchOutCurve: AppMotion.easeOut,
                transitionBuilder: (child, anim) {
                  final slide = Tween<Offset>(begin: const Offset(0, 0.02), end: Offset.zero).animate(anim);
                  return FadeTransition(opacity: anim, child: SlideTransition(position: slide, child: child));
                },
                child: content,
              );
            },
          ),
        ),
      ],
    );
  }
}

class _TabBar extends StatelessWidget {
  const _TabBar({required this.controller});
  final EditorController controller;
  static IconData _tabIcon(OpenDoc doc) {
    if (doc.kind == 'cfg') return FluentIcons.table_24_regular;
    final i = doc.path.lastIndexOf('.');
    final ext = i < 0 ? '' : doc.path.substring(i + 1).toLowerCase();
    if (const {'png', 'jpg', 'jpeg', 'webp', 'bmp', 'gif'}.contains(ext)) {
      return FluentIcons.image_24_regular;
    }
    if (const {'wav', 'ogg', 'mp3', 'flac', 'm4a'}.contains(ext)) {
      return FluentIcons.music_note_2_24_regular;
    }
    return FluentIcons.document_24_regular;
  }

  @override
  Widget build(BuildContext context) {
    final isMob = MediaQuery.sizeOf(context).width < 720;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        return Container(
          height: isMob ? 44 : 36,
          color: palette.bg,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
            itemCount: controller.docs.length,
            separatorBuilder: (_, _) => const SizedBox(width: 2),
            itemBuilder: (context, i) {
              final doc = controller.docs[i];
              final selected = i == controller.currentIndex;
              return _TabItem(
                doc: doc,
                selected: selected,
                onTap: () => controller.open(doc),
                onClose: () => controller.close(i),
                icon: _tabIcon(doc),
              );
            },
          ),
        );
      },
    );
  }
}

class _TabItem extends StatefulWidget {
  const _TabItem({required this.doc, required this.selected, required this.onTap, required this.onClose, required this.icon});
  final OpenDoc doc;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onClose;
  final IconData icon;
  @override
  State<_TabItem> createState() => _TabItemState();
}

class _TabItemState extends State<_TabItem> {
  bool _hover = false;
  bool _closeHover = false;
  @override
  Widget build(BuildContext context) {
    final isMob = MediaQuery.sizeOf(context).width < 720;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: AppMotion.fast,
          curve: AppMotion.easeOut,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: widget.selected
                ? palette.card
                : _hover
                    ? palette.panel
                    : palette.bg,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: widget.selected ? palette.borderHover : Colors.transparent,
              width: 1,
            ),
          ),
          child: Row(
            children: [
              TweenAnimationBuilder<double>(
                tween: Tween(begin: 0, end: widget.selected ? 1 : 0),
                duration: AppMotion.fast,
                builder: (context, v, child) => Icon(widget.icon, size: 13, color: Color.lerp(palette.textMuted, const Color(0xFF6C5CE7), v)),
                child: Icon(widget.icon),
              ),
              const SizedBox(width: 6),
              AnimatedDefaultTextStyle(
                duration: AppMotion.fast,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: widget.selected ? FontWeight.w600 : FontWeight.normal,
                  color: widget.selected ? palette.textHigh : _hover ? palette.textPrimary : palette.textSecondary,
                ),
                child: Text(widget.doc.title),
              ),
              const SizedBox(width: 8),
              MouseRegion(
                onEnter: (_) => setState(() => _closeHover = true),
                onExit: (_) => setState(() => _closeHover = false),
                child: GestureDetector(
                  onTap: widget.onClose,
                  behavior: HitTestBehavior.opaque,
                  // 移动端扩大关闭按钮热区，便于手指点击
                  child: Padding(
                    padding: EdgeInsets.all(isMob ? 8 : 0),
                    child: AnimatedContainer(
                      duration: AppMotion.fast,
                      padding: const EdgeInsets.all(2),
                      decoration: BoxDecoration(
                        color: _closeHover ? palette.borderHover : Colors.transparent,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: AnimatedRotation(
                        duration: AppMotion.fast,
                        turns: _closeHover ? 0.25 : 0,
                        child: Icon(
                          FluentIcons.dismiss_24_regular,
                          size: 12,
                          color: _closeHover ? palette.textHigh : palette.textHint,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _WelcomeView extends StatefulWidget {
  const _WelcomeView({super.key});
  @override
  State<_WelcomeView> createState() => _WelcomeViewState();
}

class _WelcomeViewState extends State<_WelcomeView> with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  late final Animation<double> _float;
  @override
  void initState() {
    super.initState();
    _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 2200))..repeat(reverse: true);
    _float = Tween<double>(begin: -6, end: 6).animate(CurvedAnimation(parent: _c, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ScaleFade(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedBuilder(
              animation: _float,
              builder: (context, child) => Transform.translate(
                offset: Offset(0, _float.value),
                child: child,
              ),
              child: Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  color: palette.panel,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: palette.surface),
                  boxShadow: [
                    BoxShadow(color: const Color(0xFF6C5CE7).withValues(alpha: 0.12), blurRadius: 24, offset: const Offset(0, 8)),
                  ],
                ),
                child: const Icon(FluentIcons.box_24_regular, size: 36, color: Color(0xFF6C5CE7)),
              ),
            ),
            const SizedBox(height: 20),
            FadeSlide(
              delay: Duration(milliseconds: 120),
              child: Text('学生时代模组编辑器', style: TextStyle(fontSize: 20, color: palette.textHigh, fontWeight: FontWeight.w600)),
            ),
            const SizedBox(height: 8),
            FadeSlide(
              delay: Duration(milliseconds: 220),
              offset: Offset(0, 8),
              child: Text('从左侧选择一个模组，然后从配置表开始编辑', style: TextStyle(fontSize: 13, color: palette.textMuted)),
            ),
            const SizedBox(height: 20),
            // 提示按平台区分：移动端没有键盘快捷键，引导用顶部搜索入口
            FadeSlide(
              delay: const Duration(milliseconds: 360),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(color: palette.card, borderRadius: BorderRadius.circular(20), border: Border.all(color: palette.surface)),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(FluentIcons.lightbulb_24_regular, size: 12, color: Color(0xFF6C5CE7)),
                    const SizedBox(width: 6),
                    Text(
                      MediaQuery.sizeOf(context).width < 720
                          ? '提示：点击右上角搜索图标全局搜索配置'
                          : '提示：按 Ctrl+F 全局搜索配置',
                      style: TextStyle(fontSize: 11, color: palette.textSecondary),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
