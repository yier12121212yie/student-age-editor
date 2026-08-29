import 'package:flutter/material.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../../core/api_client.dart';
import '../../core/models.dart';
import '../../core/plugin_state.dart';
import '../../core/responsive.dart';
import '../../core/ui_mode.dart';
import '../../core/motion.dart';
import '../ai/ai_panel.dart';
import '../base/base_search_page.dart';
import '../bugfix/bugfix_panel.dart';
import '../editor/editor_controller.dart';
import '../mods/mods_page.dart';
import '../pages/classic_page_layouts.dart';
import '../pages/pages_catalog.dart';
import '../plugins/plugins_page.dart';
import '../resources/resources_page.dart';
import '../settings/settings_page.dart';
import 'shell_state.dart';
import 'shell_widgets.dart';
import 'status_bar.dart';
import '../../core/app_theme.dart';

/// 经典布局（类友商风格 + 暗黑主题）：
/// 顶部大标题 + 横向工具栏 | 左侧三大类宽分组导航 | 中央类友商卡片工作流 | 底部状态栏。
class ClassicShell extends StatefulWidget {
  const ClassicShell({
    super.key,
    required this.state,
    required this.shell,
    required this.pluginState,
    required this.uiMode,
    required this.onUiModeChanged,
  });

  final AppState state;
  final ShellState shell;
  final PluginState pluginState;
  final UiMode uiMode;
  final ValueChanged<UiMode> onUiModeChanged;

  @override
  State<ClassicShell> createState() => _ClassicShellState();
}

class _ClassicShellState extends State<ClassicShell> {
  String _activePageId = 'person';
  String _activeCfgName = 'PersonCfg';

  @override
  void initState() {
    super.initState();
    _syncFromController();
  }

  void _syncFromController() {
    final current = widget.shell.controller.current;
    if (current != null && current.pageId.isNotEmpty) {
      _activePageId = current.pageId;
      final pageDef = pageById(_activePageId);
      if (pageDef != null) {
        _activeCfgName = pageDef.defaultCfg;
      }
    } else {
      _selectPage('person');
    }
  }

  void _selectPage(String pageId) {
    setState(() {
      _activePageId = pageId;
      final def = pageById(pageId);
      if (def != null) {
        _activeCfgName = def.defaultCfg;
      }
    });
    final def = pageById(pageId);
    if (def != null) {
      widget.shell.controller.open(OpenDoc.page(pageId: pageId, title: def.title));
    }
  }

  void _showToolModal(String title, Widget content) {
    final isMob = isMobile(context);
    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: title,
      barrierColor: Colors.black54,
      transitionDuration: AppMotion.normal,
      pageBuilder: (ctx, a1, a2) => Dialog(
        backgroundColor: palette.panel,
        insetPadding: EdgeInsets.symmetric(horizontal: isMob ? 12 : 40, vertical: isMob ? 24 : 40),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(color: palette.surface),
        ),
        child: Container(
          width: dialogWidth(context, desktopWidth: 760),
          height: dialogHeight(context, desktopHeight: 620),
          padding: EdgeInsets.all(isMob ? 12 : 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                      color: palette.textHigh,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: Icon(FluentIcons.dismiss_24_regular, size: 16, color: palette.textSecondary),
                    onPressed: () => Navigator.of(ctx).pop(),
                  ),
                ],
              ),
              Divider(color: palette.surface, height: 18),
              Expanded(child: content),
            ],
          ),
        ),
      ),
      transitionBuilder: (ctx, anim, secAnim, child) {
        final curved = CurvedAnimation(parent: anim, curve: AppMotion.easeOut);
        return FadeTransition(
          opacity: curved,
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.96, end: 1.0).animate(curved),
            child: SlideTransition(
              position: Tween<Offset>(begin: const Offset(0, 0.02), end: Offset.zero).animate(curved),
              child: child,
            ),
          ),
        );
      },
    );
  }

  Future<void> _exportMod() async {
    if (widget.state.modName.isEmpty) {
      _showMessage('未加载工作区，无法导出！');
      return;
    }
    _showMessage('正在导出当前模组…');
    try {
      await ApiClient.instance.get('/api/tools/list?scope=mod');
      _showMessage('📤 当前模组 ${widget.state.modName} 文件已就绪');
    } catch (e) {
      _showMessage('❌ 导出提示: $e');
    }
  }

  Future<void> _importMod() async {
    _showToolModal('📂 加载 / 切换模组', ModsPage(state: widget.state, controller: widget.shell.controller));
  }

  void _showMessage(String msg) {
    if (!mounted) return;
    fluent.displayInfoBar(
      context,
      builder: (ctx, close) => fluent.InfoBar(
        title: Text(msg),
        severity: fluent.InfoBarSeverity.info,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final shell = widget.shell;
    final uiMode = widget.uiMode;

    return fluent.FluentTheme(
      data: fluent.FluentTheme.of(context).copyWith(
        typography: const fluent.Typography.raw(
          body: TextStyle(fontSize: 13, fontFamily: 'Microsoft YaHei'),
          caption: TextStyle(fontSize: 12, fontFamily: 'Microsoft YaHei'),
        ),
      ),
      child: ListenableBuilder(
        listenable: Listenable.merge([shell, state, shell.controller]),
        builder: (context, _) {
          final currentPageDef = pageById(_activePageId) ?? editorPages.first;

          return Column(
            children: [
              _ClassicHeader(
                modName: state.modName.isEmpty ? '(未加载/空白)' : state.modName,
                onGlobalSearch: () => _showToolModal(
                  '🔍 全局搜索',
                  BaseSearchPage(state: state),
                ),
                onModPreview: () {
                  shell.controller.open(OpenDoc.preview(eventId: '8000'));
                },
                onSwitchMod: () => _showToolModal(
                  '📂 加载 / 切换模组',
                  ModsPage(state: state, controller: shell.controller),
                ),
                onMountRes: () => _showToolModal(
                  '⚙️ 挂载解包资源',
                  ResourcesPage(state: state),
                ),
                onDiagnose: () => _showToolModal(
                  '🛠️ 扫描修复',
                  BugfixPanel(state: state),
                ),
                onExport: _exportMod,
                onImport: _importMod,
                onPlugins: () {
                  shell.selectPane(SidePane.plugins);
                  shell.setActivePluginPanel(null);
                  _showToolModal('🧩 插件', PluginsPage(pluginState: widget.pluginState));
                },
                onToggleAi: shell.toggleAi,
                onSettings: () => _showToolModal(
                  '⚙️ 系统设置',
                  SettingsPage(
                    settings: shell.settingsLoaded ? shell.aiSettings : AiSettings(),
                    onChanged: shell.setAiSettings,
                    uiMode: uiMode,
                    onUiModeChanged: widget.onUiModeChanged,
                  ),
                ),
                onToggleUiMode: () => widget.onUiModeChanged(
                  uiMode == UiMode.creation ? UiMode.classic : UiMode.creation,
                ),
              ),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _ClassicNav(
                      activePageId: _activePageId,
                      aiOpen: shell.aiOpen,
                      onSelectPage: _selectPage,
                      onToggleAi: shell.toggleAi,
                      onOpenSettings: () => _showToolModal(
                        '⚙️ 系统设置',
                        SettingsPage(
                          settings: shell.settingsLoaded ? shell.aiSettings : AiSettings(),
                          onChanged: shell.setAiSettings,
                          uiMode: uiMode,
                          onUiModeChanged: widget.onUiModeChanged,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Container(
                        color: palette.bgDeep2,
                        padding: const EdgeInsets.all(10),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Expanded(
                              child: AnimatedSwitcher(
                                duration: AppMotion.normal,
                                switchInCurve: AppMotion.easeOut,
                                switchOutCurve: AppMotion.easeOut,
                                transitionBuilder: (child, anim) {
                                  final slide = Tween<Offset>(begin: const Offset(0.02, 0), end: Offset.zero).animate(anim);
                                  return FadeTransition(opacity: anim, child: SlideTransition(position: slide, child: child));
                                },
                                child: ClassicPageLayouts(
                                  key: ValueKey(_activePageId),
                                  state: state,
                                  page: currentPageDef,
                                  cfgName: _activeCfgName,
                                  onPreview: (evtId) {
                                    shell.controller.open(OpenDoc.preview(eventId: evtId));
                                  },
                                  onOpenSearch: () {
                                    _showToolModal('🔍 全局搜索', BaseSearchPage(state: state));
                                  },
                                ),
                              ),
                            ),
                            AnimatedContainer(
                              duration: AppMotion.normal,
                              curve: AppMotion.easeOut,
                              width: shell.aiOpen ? shell.aiWidth + 5 : 0,
                              child: ClipRect(
                                child: OverflowBox(
                                  alignment: Alignment.centerRight,
                                  maxWidth: shell.aiWidth + 5,
                                  minWidth: shell.aiWidth + 5,
                                  child: AnimatedOpacity(
                                    duration: AppMotion.normal,
                                    opacity: shell.aiOpen ? 1 : 0,
                                    child: AnimatedSlide(
                                      duration: AppMotion.normal,
                                      curve: AppMotion.easeOut,
                                      offset: shell.aiOpen ? Offset.zero : const Offset(0.06, 0),
                                      child: shell.aiOpen
                                          ? Row(
                                              children: [
                                                ResizeHandle(
                                                  width: shell.aiWidth,
                                                  min: ShellState.minAiWidth,
                                                  max: ShellState.maxAiWidth,
                                                  defaultWidth: ShellState.defaultAiWidth,
                                                  inverted: true,
                                                  onChanged: shell.setAiWidth,
                                                ),
                                                SizedBox(
                                                  width: shell.aiWidth,
                                                  child: ClipRRect(
                                                    borderRadius: BorderRadius.circular(8),
                                                    child: Container(
                                                      color: palette.panel,
                                                      child: AiPanel(
                                                        state: state,
                                                        settings: shell.settingsLoaded ? shell.aiSettings : AiSettings(),
                                                        onChanged: shell.setAiSettings,
                                                        onOpenSettings: () => _showToolModal(
                                                          '⚙️ 系统设置',
                                                          SettingsPage(
                                                            settings: shell.settingsLoaded ? shell.aiSettings : AiSettings(),
                                                            onChanged: shell.setAiSettings,
                                                            uiMode: uiMode,
                                                            onUiModeChanged: widget.onUiModeChanged,
                                                          ),
                                                        ),
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                              ],
                                            )
                                          : const SizedBox.shrink(),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              StatusBar(
                state: state,
                onToggleAi: shell.toggleAi,
                uiMode: uiMode,
                onUiModeChanged: widget.onUiModeChanged,
              ),
            ],
          );
        },
      ),
    );
  }
}

/// 顶部：标题行 + 工具栏，带入场错峰与悬停动效
class _ClassicHeader extends StatelessWidget {
  const _ClassicHeader({
    required this.modName,
    required this.onGlobalSearch,
    required this.onModPreview,
    required this.onSwitchMod,
    required this.onMountRes,
    required this.onDiagnose,
    required this.onExport,
    required this.onImport,
    required this.onPlugins,
    required this.onToggleAi,
    required this.onSettings,
    required this.onToggleUiMode,
  });

  final String modName;
  final VoidCallback onGlobalSearch;
  final VoidCallback onModPreview;
  final VoidCallback onSwitchMod;
  final VoidCallback onMountRes;
  final VoidCallback onDiagnose;
  final VoidCallback onExport;
  final VoidCallback onImport;
  final VoidCallback onPlugins;
  final VoidCallback onToggleAi;
  final VoidCallback onSettings;
  final VoidCallback onToggleUiMode;

  @override
  Widget build(BuildContext context) {
    final buttons = <Widget>[
      _ToolbarButton(emoji: '🔍', label: '全局搜索 (Ctrl+F)', onPressed: onGlobalSearch, delay: 0),
      _ToolbarButton(emoji: '📑', label: '模组预览 (Ctrl+P)', onPressed: onModPreview, delay: 1),
      _ToolbarButton(emoji: '📂', label: '加载 / 切换模组', primary: true, onPressed: onSwitchMod, delay: 2),
      _ToolbarButton(emoji: '⚙️', label: '挂载解包资源', onPressed: onMountRes, delay: 3),
      _ToolbarButton(emoji: '🛠️', label: '扫描修复', onPressed: onDiagnose, delay: 4),
      _ToolbarButton(emoji: '📤', label: '导出', onPressed: onExport, delay: 5),
      _ToolbarButton(emoji: '📥', label: '导入', onPressed: onImport, delay: 6),
      _ToolbarButton(emoji: '🧩', label: '插件', onPressed: onPlugins, delay: 7),
      _ToolbarButton(emoji: '🤖', label: 'AI 助手', onPressed: onToggleAi, delay: 8),
      _ToolbarButton(emoji: '⚙️', label: '设置', onPressed: onSettings, delay: 9),
    ];

    return Container(
      constraints: const BoxConstraints(minHeight: 92),
      decoration: BoxDecoration(
        color: palette.bg,
        border: Border(bottom: BorderSide(color: palette.border, width: 1)),
      ),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FadeSlide(
            offset: const Offset(0, -6),
            duration: AppMotion.fast,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  const Icon(FluentIcons.box_24_regular, size: 18, color: Color(0xFF6C5CE7)),
                  const SizedBox(width: 8),
                  Text('学生时代模组编辑器', style: TextStyle(fontSize: 14, color: palette.textHigh, fontWeight: FontWeight.w600)),
                  const SizedBox(width: 14),
                  Icon(FluentIcons.person_24_regular, size: 13, color: palette.textHint),
                  const SizedBox(width: 4),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 320),
                    child: Text('欢迎：神秘造物主 - 当前工作区: $modName', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: palette.textSecondary)),
                  ),
                  const SizedBox(width: 16),
                  _HoverScale(
                    child: Tooltip(
                      message: '切换到创作布局 (Cursor IDE 风格)',
                      child: MouseRegion(
                        cursor: SystemMouseCursors.click,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: onToggleUiMode,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                            decoration: BoxDecoration(color: palette.card, borderRadius: BorderRadius.circular(4), border: Border.all(color: palette.borderHover)),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(FluentIcons.paint_brush_24_regular, size: 13, color: Color(0xFF6C5CE7)),
                                SizedBox(width: 6),
                                Text('创作布局', style: TextStyle(fontSize: 11, color: palette.textMid)),
                              ],
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
          const SizedBox(height: 8),
          // 不再固定高度：常规字号下保持 36，字体放大时允许变高避免纵向溢出
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            physics: const ClampingScrollPhysics(),
            child: Container(
              alignment: Alignment.centerLeft,
              constraints: const BoxConstraints(minHeight: 36),
              child: Row(
                children: [
                  for (var i = 0; i < buttons.length; i++) ...[
                    if (i > 0) const SizedBox(width: 6),
                    buttons[i],
                  ],
                ],
              ),
            ),
          ),
        ],
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
      child: AnimatedScale(scale: _hover ? 1.04 : 1.0, duration: AppMotion.fast, curve: AppMotion.easeOut, child: widget.child),
    );
  }
}

class _ToolbarButton extends StatefulWidget {
  const _ToolbarButton({required this.emoji, required this.label, required this.onPressed, this.primary = false, this.delay = 0});
  final String emoji;
  final String label;
  final VoidCallback onPressed;
  final bool primary;
  final int delay;
  @override
  State<_ToolbarButton> createState() => _ToolbarButtonState();
}

class _ToolbarButtonState extends State<_ToolbarButton> {
  bool _hover = false;
  bool _pressed = false;
  @override
  Widget build(BuildContext context) {
    final bg = widget.primary ? const Color(0xFF6C5CE7) : palette.card;
    final hoverBg = widget.primary ? const Color(0xFF7B6EF0) : palette.surface;
    return FadeSlide(
      delay: AppMotion.stagger(widget.delay, baseMs: 30),
      offset: const Offset(0, 6),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (_) => setState(() => _pressed = true),
          onTapUp: (_) => setState(() => _pressed = false),
          onTapCancel: () => setState(() => _pressed = false),
          onTap: widget.onPressed,
          child: AnimatedContainer(
            duration: AppMotion.fast,
            curve: AppMotion.easeOut,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
            decoration: BoxDecoration(
              color: _pressed ? bg.withValues(alpha: 0.85) : _hover ? hoverBg : bg,
              borderRadius: BorderRadius.circular(5),
              border: widget.primary ? null : Border.all(color: _hover ? palette.borderHover : palette.surface),
              boxShadow: _hover ? [BoxShadow(color: Colors.black.withValues(alpha: 0.18), blurRadius: 8, offset: const Offset(0, 2))] : [],
            ),
            transform: Matrix4.identity()..scaleByDouble(_pressed ? 0.97 : _hover ? 1.02 : 1.0, _pressed ? 0.97 : _hover ? 1.02 : 1.0, _pressed ? 0.97 : _hover ? 1.02 : 1.0, 1.0),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(widget.emoji, style: const TextStyle(fontSize: 13)),
                const SizedBox(width: 6),
                Text(widget.label, style: TextStyle(fontSize: 12, color: widget.primary ? Colors.white : palette.textPrimary, fontWeight: FontWeight.w500)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ClassicNav extends StatelessWidget {
  const _ClassicNav({
    required this.activePageId,
    required this.aiOpen,
    required this.onSelectPage,
    required this.onToggleAi,
    required this.onOpenSettings,
  });

  final String activePageId;
  final bool aiOpen;
  final ValueChanged<String> onSelectPage;
  final VoidCallback onToggleAi;
  final VoidCallback onOpenSettings;

  static const _groups = <(String, List<(String, String, IconData)>)>[
    ('基础配置', [('person', '人物综合配置', FluentIcons.person_24_regular), ('resource', '资源综合配置', FluentIcons.box_24_regular), ('function', '功能配置相关', FluentIcons.wrench_24_regular)]),
    ('内容创作', [('story', '剧情编辑器', FluentIcons.book_letter_24_regular), ('social', '空间手机结局编辑', FluentIcons.chat_24_regular), ('love', '恋爱相关', FluentIcons.heart_24_regular)]),
    ('官方生态', [('official', '官方兼容工具', FluentIcons.shield_task_24_regular)]),
  ];

  // 滑动指示条所需：计算 activePageId 在分组中的视觉 top
  double _indicatorTop(String id) {
    const headerH = 30.0;
    const itemH = 44.0;
    const topBase = 6.0;
    double top = topBase;
    for (final g in _groups) {
      top += headerH;
      for (final item in g.$2) {
        if (item.$1 == id) return top + 10; // 20高条在40中居中
        top += itemH;
      }
    }
    return topBase + headerH + 10; // fallback person
  }

  @override
  Widget build(BuildContext context) {
    final indTop = _indicatorTop(activePageId);
    return Container(
      width: 190,
      color: palette.bgDeep2,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(
                  child: ListView(
                    padding: EdgeInsets.zero,
                    children: [
                      const SizedBox(height: 6),
                      for (var gi = 0; gi < _groups.length; gi++) ...[
                        FadeSlide(
                          delay: AppMotion.stagger(gi, baseMs: 60),
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                            child: Text(_groups[gi].$1, style: TextStyle(fontSize: 11, color: palette.textHint, fontWeight: FontWeight.w600)),
                          ),
                        ),
                        for (var ii = 0; ii < _groups[gi].$2.length; ii++)
                          FadeSlide(
                            delay: AppMotion.stagger(gi * 3 + ii, baseMs: 40),
                            child: _NavItem(
                              icon: _groups[gi].$2[ii].$3,
                              label: _groups[gi].$2[ii].$2,
                            selected: activePageId == _groups[gi].$2[ii].$1,
                            onTap: () => onSelectPage(_groups[gi].$2[ii].$1),
                          ),
                        ),
                    ],
                  ],
                ),
                ),
                // Positioned 必须是 Stack 直接子级：IgnorePointer 移入 AnimatedPositioned 内部
                AnimatedPositioned(
                  duration: AppMotion.normal,
                  curve: AppMotion.easeOut,
                  left: 8,
                  top: indTop,
                  child: IgnorePointer(
                    child: Container(
                      width: 2.5,
                      height: 20,
                      decoration: BoxDecoration(
                        color: const Color(0xFF6C5CE7),
                        borderRadius: BorderRadius.circular(1),
                        boxShadow: [BoxShadow(color: const Color(0xFF6C5CE7).withValues(alpha: 0.45), blurRadius: 8)],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Divider(color: palette.border, height: 1),
          // 底部 AI/设置仍保留原有选中态（AI 用淡入紫条，设置无条）
          Stack(
            children: [
              Column(
                children: [
                  FadeSlide(delay: AppMotion.stagger(9), child: _NavItem(icon: FluentIcons.bot_24_regular, label: 'AI 助手', selected: aiOpen, onTap: onToggleAi)),
                  FadeSlide(delay: AppMotion.stagger(10), child: _NavItem(icon: FluentIcons.settings_24_regular, label: '系统设置', selected: false, onTap: onOpenSettings)),
                ],
              ),
              // Positioned 必须是 Stack 直接子级：IgnorePointer 移入 AnimatedPositioned 内部
              AnimatedPositioned(
                duration: AppMotion.normal,
                curve: AppMotion.easeOut,
                left: 8,
                top: aiOpen ? 10 : -20,
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
                        boxShadow: [BoxShadow(color: const Color(0xFF6C5CE7).withValues(alpha: 0.45), blurRadius: 8)],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

class _NavItem extends StatefulWidget {
  const _NavItem({required this.icon, required this.label, required this.selected, required this.onTap});
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  @override
  State<_NavItem> createState() => _NavItemState();
}

class _NavItemState extends State<_NavItem> {
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
          curve: AppMotion.easeOut,
          height: 40,
          margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: widget.selected ? palette.card : _hover ? palette.panel : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            children: [
              Icon(widget.icon, size: 15, color: widget.selected ? const Color(0xFF6C5CE7) : _hover ? palette.textPrimary : palette.textSecondary),
              const SizedBox(width: 9),
              Expanded(
                child: AnimatedDefaultTextStyle(
                  duration: AppMotion.fast,
                  style: TextStyle(fontSize: 12.5, fontWeight: widget.selected ? FontWeight.w600 : FontWeight.normal, color: widget.selected ? palette.textHigh : _hover ? palette.textPrimary : palette.textSecondary),
                  child: Text(widget.label, maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

