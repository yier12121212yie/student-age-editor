import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import '../../core/motion.dart';
import '../../core/plugin_state.dart';
import '../plugins/plugin_pane.dart';
import 'shell_state.dart';
import '../../core/app_theme.dart';

// 创作模式窄活动栏（Cursor 风格）—— 真实滑动指示条
class ActivityBar extends StatelessWidget {
  const ActivityBar({
    super.key,
    required this.current,
    required this.aiOpen,
    required this.onSelect,
    required this.onToggleAi,
    required this.shell,
    required this.pluginState,
  });

  final SidePane current;
  final bool aiOpen;
  final ValueChanged<SidePane> onSelect;
  final VoidCallback onToggleAi;
  final ShellState shell;
  final PluginState pluginState;

  int _paneIndex(SidePane p) {
    switch (p) {
      case SidePane.mods: return 0;
      case SidePane.pages: return 1;
      case SidePane.files: return 2;
      case SidePane.resources: return 3;
      case SidePane.base: return 4;
      case SidePane.cloud: return 5;
      case SidePane.bugfix: return 6;
      case SidePane.plugins: return 7;
      case SidePane.settings: return 8;
    }
  }

  /// 固定「插件」条目：切到插件列表（清空已打开的面板）。
  void _openPluginsList() {
    onSelect(SidePane.plugins);
    shell.setActivePluginPanel(null);
  }

  /// 动态插件面板条目：key = `pluginId/panelId`，title 作显示/tooltip。
  Widget _panelItem(int i) {
    final panel = pluginState.uiPanels[i];
    final pluginId = (panel['plugin_id'] as String?) ?? '';
    final panelId = (panel['panel_id'] as String?) ?? '';
    final title = (panel['title'] as String? ?? '').trim();
    final key = '$pluginId/$panelId';
    return _BarItem(
      pane: SidePane.plugins,
      icon: pluginPanelIcon(panel['icon'] as String?),
      tip: title.isEmpty ? '插件面板' : title,
      selected: current == SidePane.plugins && shell.activePluginPanel == key,
      onTap: () {
        onSelect(SidePane.plugins);
        shell.setActivePluginPanel(key);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final active = aiOpen ? const Color(0xFF6C5CE7) : palette.textPrimary;
    return Container(
      width: 48,
      color: palette.bgDeep2,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final h = constraints.maxHeight;
          // 每项视觉高度 44 (40容器+4 padding) + 2 间隙 =46；容器内 40 居中偏移 +2
          const itemPad = 2.0;
          const gap = 2.0;
          const stride = 44 + 2; // 46
          // 队列整体需要的最小高度；窗口过矮时以该高度布局并允许滚动，避免纵向溢出
          const minNeeded = 420.0;
          final layoutH = math.max(h, minNeeded);
          // 当前面板在顶部序列中的视觉索引：
          // 插件固定项=7；其后按序为各动态面板（8+i）。
          int pluginsIndex() {
            final active = shell.activePluginPanel;
            if (active == null || active.isEmpty) return 7;
            final keys = [
              for (final p in pluginState.uiPanels)
                '${p['plugin_id']}/${p['panel_id']}',
            ];
            final i = keys.indexOf(active);
            return i >= 0 ? 8 + i : 7;
          }

          double paneTop;
          if (current == SidePane.settings) {
            paneTop = layoutH - 8 - 44 + itemPad; // 底部设置项
          } else if (current == SidePane.plugins) {
            paneTop = 8 + pluginsIndex() * stride + itemPad;
          } else {
            paneTop = 8 + _paneIndex(current) * stride + itemPad;
          }

          return Stack(
            children: [
              ClipRect(
                child: SingleChildScrollView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: EdgeInsets.zero,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(minHeight: layoutH),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                    const SizedBox(height: 8),
                    FadeSlide(delay: AppMotion.stagger(0), child: _BarItem(pane: SidePane.mods, icon: FluentIcons.box_24_regular, tip: '模组', selected: current == SidePane.mods, onTap: () => onSelect(SidePane.mods))),
                    const SizedBox(height: 2),
                    FadeSlide(delay: AppMotion.stagger(1), child: _BarItem(pane: SidePane.pages, icon: FluentIcons.apps_24_regular, tip: '编辑页面', selected: current == SidePane.pages, onTap: () => onSelect(SidePane.pages))),
                    const SizedBox(height: 2),
                    FadeSlide(delay: AppMotion.stagger(2), child: _BarItem(pane: SidePane.files, icon: FluentIcons.folder_24_regular, tip: '文件', selected: current == SidePane.files, onTap: () => onSelect(SidePane.files))),
                    const SizedBox(height: 2),
                    FadeSlide(delay: AppMotion.stagger(3), child: _BarItem(pane: SidePane.resources, icon: FluentIcons.image_24_regular, tip: '资源', selected: current == SidePane.resources, onTap: () => onSelect(SidePane.resources))),
                    const SizedBox(height: 2),
                    FadeSlide(delay: AppMotion.stagger(4), child: _BarItem(pane: SidePane.base, icon: FluentIcons.book_search_24_regular, tip: '基础库（原数据/读取）', selected: current == SidePane.base, onTap: () => onSelect(SidePane.base))),
                    const SizedBox(height: 2),
                    FadeSlide(delay: AppMotion.stagger(5), child: _BarItem(pane: SidePane.cloud, icon: FluentIcons.cloud_24_regular, tip: '云同步', selected: current == SidePane.cloud, onTap: () => onSelect(SidePane.cloud))),
                    const SizedBox(height: 2),
                    FadeSlide(delay: AppMotion.stagger(6), child: _BarItem(pane: SidePane.bugfix, icon: FluentIcons.wrench_24_regular, tip: '错误修复', selected: current == SidePane.bugfix, onTap: () => onSelect(SidePane.bugfix))),
                    const SizedBox(height: 2),
                    FadeSlide(delay: AppMotion.stagger(7), child: _BarItem(pane: SidePane.plugins, icon: Icons.extension_outlined, selectedIcon: Icons.extension, tip: '插件', selected: current == SidePane.plugins && shell.activePluginPanel == null, onTap: _openPluginsList)),
                    // 已启用插件声明的动态面板入口（uiPanels 为空时不渲染）
                    for (var i = 0; i < pluginState.uiPanels.length; i++) ...[
                      const SizedBox(height: 2),
                      FadeSlide(delay: AppMotion.stagger(8 + i), child: _panelItem(i)),
                    ],
                    const Spacer(),
                    FadeSlide(
                      delay: AppMotion.stagger(8 + pluginState.uiPanels.length),
                      child: Tooltip(
                        message: 'AI 助手',
                        child: _HoverScale(
                          child: MouseRegion(
                            cursor: SystemMouseCursors.click,
                            child: GestureDetector(
                              onTap: onToggleAi,
                              child: AnimatedContainer(
                                duration: AppMotion.fast,
                                curve: AppMotion.easeOut,
                                width: 44,
                                height: 40,
                                decoration: BoxDecoration(
                                  color: aiOpen ? palette.card : Colors.transparent,
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: AnimatedSwitcher(
                                  duration: AppMotion.fast,
                                  transitionBuilder: (c, a) => ScaleTransition(scale: a, child: c),
                                  child: Icon(FluentIcons.bot_24_regular,
                                      key: ValueKey(aiOpen),
                                      size: 21,
                                      color: active),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 2),
                    FadeSlide(delay: AppMotion.stagger(9 + pluginState.uiPanels.length), child: _BarItem(pane: SidePane.settings, icon: FluentIcons.settings_24_regular, tip: '设置', selected: current == SidePane.settings, onTap: () => onSelect(SidePane.settings))),
                    const SizedBox(height: 8),
                  ],
                ),
              ),
            ),
          ),
              // 滑动紫条 - 连续位移动画（置于顶层，避免被按钮背景覆盖）
              // Positioned 必须是 Stack 直接子级：IgnorePointer 移入 AnimatedPositioned 内部
              AnimatedPositioned(
                duration: AppMotion.normal,
                curve: AppMotion.easeOut,
                left: 0,
                top: paneTop,
                child: IgnorePointer(
                  child: Container(
                    width: 2.5,
                    height: 20,
                    margin: const EdgeInsets.only(top: 10),
                    decoration: BoxDecoration(
                      color: const Color(0xFF6C5CE7),
                      borderRadius: BorderRadius.circular(1),
                      boxShadow: [BoxShadow(color: const Color(0xFF6C5CE7).withValues(alpha: 0.45), blurRadius: 8, offset: const Offset(0, 0))],
                    ),
                  ),
                ),
              ),
              // AI 独立指示（不滑动，仅显隐）
              AnimatedPositioned(
                duration: AppMotion.fast,
                curve: AppMotion.easeOut,
                left: 0,
                top: layoutH - 8 - 44 - gap - 44 + itemPad + 10,
                child: IgnorePointer(
                  child: AnimatedOpacity(
                    duration: AppMotion.fast,
                    opacity: aiOpen ? 1 : 0,
                    child: Container(
                      width: 2.5,
                      height: 20,
                      decoration: BoxDecoration(
                        color: const Color(0xFF6C5CE7),
                        borderRadius: BorderRadius.circular(1),
                        boxShadow: [BoxShadow(color: const Color(0xFF6C5CE7).withValues(alpha: aiOpen ? 0.45 : 0), blurRadius: 8)],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _BarItem extends StatefulWidget {
  const _BarItem({required this.pane, required this.icon, required this.tip, required this.selected, required this.onTap, this.selectedIcon});
  final SidePane pane;
  final IconData icon;
  final IconData? selectedIcon;
  final String tip;
  final bool selected;
  final VoidCallback onTap;
  @override
  State<_BarItem> createState() => _BarItemState();
}

class _BarItemState extends State<_BarItem> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.tip,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          child: GestureDetector(
            onTap: widget.onTap,
            child: AnimatedContainer(
              duration: AppMotion.fast,
              curve: AppMotion.easeOut,
              width: 44,
              height: 40,
              decoration: BoxDecoration(
                color: widget.selected
                    ? palette.card
                    : _hover
                        ? palette.panel
                        : Colors.transparent,
                borderRadius: BorderRadius.circular(6),
              ),
              child: AnimatedScale(
                duration: AppMotion.fast,
                curve: AppMotion.spring,
                scale: widget.selected ? 1.0 : _hover ? 1.08 : 1.0,
                child: Icon(widget.selected ? (widget.selectedIcon ?? widget.icon) : widget.icon,
                    size: 21,
                    color: widget.selected ? palette.textHigh : _hover ? palette.textPrimary : palette.textSecondary),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _HoverScale extends StatefulWidget {
  const _HoverScale({required this.child});
  final Widget child;
  @override
  State<_HoverScale> createState() => _HoverScaleState();
}

class _HoverScaleState extends State<_HoverScale> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedScale(
        scale: _hover ? 1.06 : 1.0,
        duration: AppMotion.fast,
        curve: AppMotion.easeOut,
        child: widget.child,
      ),
    );
  }
}
