import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import '../../core/api_client.dart';
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
  /// 撤销/重做成功后的刷新信号：传给 SchemaEditorView 触发重新加载磁盘内容。
  int _cfgReloadToken = 0;
  bool _historyBusy = false;

  /// 撤销/重做当前 cfg 文档（POST /api/history/undo|redo）。
  Future<void> _historyOp(String op) async {
    final doc = widget.controller.current;
    if (doc == null || doc.kind != 'cfg' || _historyBusy) return;
    _historyBusy = true;
    try {
      await ApiClient.instance.post(
        '/api/history/$op',
        body: {'cfg': doc.cfgName},
      );
      if (!mounted) return;
      setState(() => _cfgReloadToken++);
    } on ApiException catch (e) {
      if (!mounted) return;
      final nothing = e.message.contains('nothing to undo') ||
          e.message.contains('nothing to redo');
      fluent.displayInfoBar(
        context,
        builder: (ctx, close) => fluent.InfoBar(
          title: Text(op == 'undo'
              ? (nothing ? '没有可撤销的操作' : '撤销失败')
              : (nothing ? '没有可重做的操作' : '重做失败')),
          content: nothing
              ? null
              : Text(e.toString(), style: const TextStyle(fontSize: 12)),
          severity: fluent.InfoBarSeverity.warning,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      fluent.displayInfoBar(
        context,
        builder: (ctx, close) => fluent.InfoBar(
          title: Text(op == 'undo' ? '撤销失败' : '重做失败'),
          content: Text(e.toString(), style: const TextStyle(fontSize: 12)),
          severity: fluent.InfoBarSeverity.error,
        ),
      );
    } finally {
      _historyBusy = false;
    }
  }

  /// 主焦点是否位于文本输入控件内：是则让位给输入框自身的 Ctrl+Z / Ctrl+Y。
  bool _focusInEditableText() {
    final ctx = FocusManager.instance.primaryFocus?.context;
    if (ctx == null) return false;
    final self = ctx.widget;
    if (self is EditableText || self is TextField) return true;
    bool found = false;
    ctx.visitAncestorElements((e) {
      final w = e.widget;
      if (w is EditableText || w is TextField) {
        found = true;
        return false;
      }
      return true;
    });
    return found;
  }

  /// Ctrl+Z / Ctrl+Y（及 Ctrl+Shift+Z）→ 撤销 / 重做。
  /// 仅在 cfg 文档激活且焦点不在文本输入内时响应，其余按键事件放行。
  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final ctrl = HardwareKeyboard.instance.isControlPressed;
    if (!ctrl) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final isUndo = key == LogicalKeyboardKey.keyZ &&
        !HardwareKeyboard.instance.isShiftPressed;
    final isRedo = key == LogicalKeyboardKey.keyY ||
        (key == LogicalKeyboardKey.keyZ &&
            HardwareKeyboard.instance.isShiftPressed);
    if (!isUndo && !isRedo) return KeyEventResult.ignored;
    final doc = widget.controller.current;
    if (doc == null || doc.kind != 'cfg') return KeyEventResult.ignored;
    if (_focusInEditableText()) return KeyEventResult.ignored;
    _historyOp(isUndo ? 'undo' : 'redo');
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      // 挂在内容区上层拦截 Ctrl+Z / Ctrl+Y：焦点在文本输入内时放行给输入框
      onKeyEvent: _handleKeyEvent,
      canRequestFocus: false,
      skipTraversal: true,
      child: Column(
        children: [
          if (widget.showTabs) ...[
            _TabBar(
              controller: widget.controller,
              onUndo: () => _historyOp('undo'),
              onRedo: () => _historyOp('redo'),
            ),
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
                  reloadToken: _cfgReloadToken,
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
      ),
    );
  }
}

class _TabBar extends StatelessWidget {
  const _TabBar({required this.controller, this.onUndo, this.onRedo});
  final EditorController controller;
  final VoidCallback? onUndo;
  final VoidCallback? onRedo;
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
        final doc = controller.current;
        final canHistory = doc != null && doc.kind == 'cfg';
        return Container(
          height: isMob ? 44 : 36,
          color: palette.bg,
          child: Row(
            children: [
              Expanded(
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
              ),
              // 撤销/重做仅对 cfg 文档生效（历史按表维度记录在 .editor_history）
              if (!isMob) ...[
                _HistoryButton(
                  icon: FluentIcons.arrow_undo_24_regular,
                  label: '撤销 (Ctrl+Z)',
                  onTap: canHistory ? onUndo : null,
                ),
                _HistoryButton(
                  icon: FluentIcons.arrow_redo_24_regular,
                  label: '重做 (Ctrl+Y)',
                  onTap: canHistory ? onRedo : null,
                ),
                const SizedBox(width: 4),
              ],
            ],
          ),
        );
      },
    );
  }
}

/// 标签栏右侧的撤销/重做小按钮（仅 cfg 文档激活时可用）。
class _HistoryButton extends StatefulWidget {
  const _HistoryButton({required this.icon, required this.label, this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  @override
  State<_HistoryButton> createState() => _HistoryButtonState();
}

class _HistoryButtonState extends State<_HistoryButton> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    return Tooltip(
      message: widget.label,
      waitDuration: const Duration(milliseconds: 500),
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
            padding: const EdgeInsets.all(5),
            decoration: BoxDecoration(
              color: enabled && _hover ? palette.panel : Colors.transparent,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Icon(
              widget.icon,
              size: 14,
              color: enabled
                  ? (_hover ? palette.textHigh : palette.textSecondary)
                  : palette.textHint,
            ),
          ),
        ),
      ),
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
