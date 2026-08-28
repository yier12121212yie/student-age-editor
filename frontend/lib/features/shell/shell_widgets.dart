import 'package:flutter/material.dart';
import '../../core/models.dart';
import '../../core/ui_mode.dart';
import '../../core/motion.dart';
import '../base/base_search_page.dart';
import '../bugfix/bugfix_panel.dart';
import '../cloud/cloud_page.dart';
import '../editor/editor_controller.dart';
import '../files/file_tree_page.dart';
import '../mods/mods_page.dart';
import '../pages/pages_list.dart';
import '../resources/resources_page.dart';
import '../settings/settings_page.dart';
import 'shell_state.dart';

// 当前面板对应的侧栏视图（带 AnimatedSwitcher 切换动效）
class SidePaneView extends StatelessWidget {
  const SidePaneView({
    super.key,
    required this.pane,
    required this.state,
    required this.controller,
    required this.aiSettings,
    required this.onAiChanged,
    required this.width,
    this.uiMode,
    this.onUiModeChanged,
  });

  final SidePane pane;
  final AppState state;
  final EditorController controller;
  final AiSettings aiSettings;
  final ValueChanged<AiSettings> onAiChanged;
  final double width;
  final UiMode? uiMode;
  final ValueChanged<UiMode>? onUiModeChanged;

  @override
  Widget build(BuildContext context) {
    Widget child;
    switch (pane) {
      case SidePane.mods:
        child = ModsPage(key: const ValueKey('mods'), state: state, controller: controller);
      case SidePane.pages:
        child = PagesList(key: const ValueKey('pages'), state: state, controller: controller);
      case SidePane.files:
        child = FileTreePage(key: const ValueKey('files'), state: state, controller: controller);
      case SidePane.resources:
        child = ResourcesPage(key: const ValueKey('resources'), state: state);
      case SidePane.base:
        child = BaseSearchPage(key: const ValueKey('base'), state: state);
      case SidePane.bugfix:
        child = BugfixPanel(key: const ValueKey('bugfix'), state: state);
      case SidePane.cloud:
        child = CloudPage(key: const ValueKey('cloud'), state: state);
      case SidePane.settings:
        child = SettingsPage(
            key: const ValueKey('settings'),
            settings: aiSettings,
            onChanged: onAiChanged,
            uiMode: uiMode,
            onUiModeChanged: onUiModeChanged);
    }
    return SizedBox(
      width: width,
      child: AnimatedSwitcher(
        duration: AppMotion.normal,
        switchInCurve: AppMotion.easeOut,
        switchOutCurve: AppMotion.easeOut,
        transitionBuilder: (child, anim) => FadeTransition(opacity: anim, child: child),
        child: child,
      ),
    );
  }
}

// 可拖拽分割线，带悬停高亮与拖拽反馈
class ResizeHandle extends StatefulWidget {
  const ResizeHandle({
    super.key,
    required this.width,
    required this.min,
    required this.max,
    required this.defaultWidth,
    required this.onChanged,
    this.inverted = false,
  });

  final double width;
  final double min;
  final double max;
  final double defaultWidth;
  final ValueChanged<double> onChanged;
  final bool inverted;

  @override
  State<ResizeHandle> createState() => _ResizeHandleState();
}

class _ResizeHandleState extends State<ResizeHandle> {
  bool _hover = false;
  bool _dragging = false;
  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeLeftRight,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragStart: (_) => setState(() => _dragging = true),
        onHorizontalDragEnd: (_) => setState(() => _dragging = false),
        onHorizontalDragUpdate: (d) {
          final delta = widget.inverted ? -d.delta.dx : d.delta.dx;
          widget.onChanged((widget.width + delta).clamp(widget.min, widget.max));
        },
        onDoubleTap: () => widget.onChanged(widget.defaultWidth),
        child: AnimatedContainer(
          duration: AppMotion.fast,
          width: 5,
          color: _dragging
              ? const Color(0xFF6C5CE7).withValues(alpha: 0.18)
              : _hover
                  ? const Color(0xFF6C5CE7).withValues(alpha: 0.08)
                  : Colors.transparent,
          child: Center(
            child: AnimatedContainer(
              duration: AppMotion.fast,
              width: 1,
              height: double.infinity,
              color: _dragging
                  ? const Color(0xFF6C5CE7)
                  : _hover
                      ? const Color(0xFF3A3A42)
                      : const Color(0xFF2A2A2E),
            ),
          ),
        ),
      ),
    );
  }
}
