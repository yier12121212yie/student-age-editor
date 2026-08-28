import 'package:flutter/material.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../../core/models.dart';
import '../../core/ui_mode.dart';
import '../ai/ai_panel.dart';
import '../base/base_search_page.dart';
import '../bugfix/bugfix_panel.dart';
import '../cloud/cloud_page.dart';
import '../resources/pack_manager_page.dart';
import '../resources/resources_page.dart';
import '../settings/settings_page.dart';
import 'editor_area.dart';
import '../../core/motion.dart';
import 'mobile_subpage.dart';
import 'shell_state.dart';
import 'shell_widgets.dart';

/// 移动端外壳：底部导航 + 抽屉 + 全屏内容 + 可滑出 AI。
/// 在宽度 < 720 时由 app.dart 自动启用，替代 CreationShell / ClassicShell。
class MobileShell extends StatefulWidget {
  const MobileShell({
    super.key,
    required this.state,
    required this.shell,
    required this.uiMode,
    required this.onUiModeChanged,
  });

  final AppState state;
  final ShellState shell;
  final UiMode uiMode;
  final ValueChanged<UiMode> onUiModeChanged;

  @override
  State<MobileShell> createState() => _MobileShellState();
}

class _MobileShellState extends State<MobileShell> {
  int _tab = 0; // 0 模组 1 页面 2 文件 3 编辑 4 更多
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  ShellState get shell => widget.shell;
  AppState get state => widget.state;

  void _switchTab(int i) {
    setState(() => _tab = i);
  }

  // 打开编辑页并切到底部“编辑”tab（供列表页点击条目后调用，预留）
  // ignore: unused_element
  void _openEditorTab() => setState(() => _tab = 3);

  @override
  Widget build(BuildContext context) {
    return fluent.FluentTheme(
      data: fluent.FluentTheme.of(context).copyWith(
        typography: const fluent.Typography.raw(
          body: TextStyle(fontSize: 13, fontFamily: 'Microsoft YaHei'),
          caption: TextStyle(fontSize: 12, fontFamily: 'Microsoft YaHei'),
        ),
      ),
      child: Theme(
        data: ThemeData.dark().copyWith(
          scaffoldBackgroundColor: const Color(0xFF131316),
          navigationBarTheme: const NavigationBarThemeData(backgroundColor: Color(0xFF1B1B1F)),
        ),
        child: Scaffold(
          key: _scaffoldKey,
          backgroundColor: const Color(0xFF131316),
          appBar: _MobileAppBar(
            state: state,
            onMenu: () => _scaffoldKey.currentState?.openDrawer(),
            onSearch: () => _showSheet(BaseSearchPage(state: state)),
            onAi: () => _showAiSheet(),
          ),
          drawer: _MobileDrawer(
            state: state,
            currentTab: _tab,
            onSelectTab: _switchTab,
            onSelectPane: _openToolPane,
            onOpenAi: () {
              Navigator.of(context).pop();
              _showAiSheet();
            },
            uiMode: widget.uiMode,
            onUiModeChanged: widget.onUiModeChanged,
          ),
          body: SafeArea(
            child: _buildBody(),
          ),
          bottomNavigationBar: SafeArea(
            child: _MobileBottomBar(
              current: _tab,
              editorBadge: shell.controller.docs.isNotEmpty,
              onTap: _switchTab,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    return AnimatedSwitcher(
      duration: AppMotion.normal,
      switchInCurve: AppMotion.easeOut,
      switchOutCurve: AppMotion.easeOut,
      transitionBuilder: (child, anim) {
        final slide = Tween<Offset>(begin: const Offset(0.02, 0), end: Offset.zero).animate(anim);
        return FadeTransition(opacity: anim, child: SlideTransition(position: slide, child: child));
      },
      child: ListenableBuilder(
        key: ValueKey(_tab),
        listenable: Listenable.merge([shell, state, shell.controller]),
        builder: (context, _) {
          switch (_tab) {
            case 0:
              return SidePaneView(
                pane: SidePane.mods,
                state: state,
                controller: shell.controller,
                aiSettings: shell.aiSettings,
                onAiChanged: shell.setAiSettings,
                width: double.infinity,
                uiMode: widget.uiMode,
                onUiModeChanged: widget.onUiModeChanged,
              );
            case 1:
              return SidePaneView(
                pane: SidePane.pages,
                state: state,
                controller: shell.controller,
                aiSettings: shell.aiSettings,
                onAiChanged: shell.setAiSettings,
                width: double.infinity,
                uiMode: widget.uiMode,
                onUiModeChanged: widget.onUiModeChanged,
              );
            case 2:
              return SidePaneView(
                pane: SidePane.files,
                state: state,
                controller: shell.controller,
                aiSettings: shell.aiSettings,
                onAiChanged: shell.setAiSettings,
                width: double.infinity,
                uiMode: widget.uiMode,
                onUiModeChanged: widget.onUiModeChanged,
              );
            case 3:
              return _MobileEditorWrapper(
                state: state,
                controller: shell.controller,
                onEmptyPages: () => _switchTab(1),
                onEmptyFiles: () => _switchTab(2),
              );
            case 4:
              return _MobileMorePage(
                state: state,
                shell: shell,
                uiMode: widget.uiMode,
                onUiModeChanged: widget.onUiModeChanged,
                onOpenAi: () => _showAiSheet(),
              );
            default:
              return const SizedBox.shrink();
          }
        },
      ),
    );
  }

  /// 抽屉「工具」入口：关闭抽屉后以全屏子页打开对应面板。
  void _openToolPane(SidePane p) {
    Navigator.of(context).pop();
    switch (p) {
      case SidePane.resources:
        _pushMobilePage('资源', ResourcesPage(state: state));
      case SidePane.base:
        _pushMobilePage('剧情库', BaseSearchPage(state: state));
      case SidePane.cloud:
        _pushMobilePage('云同步', CloudPage(state: state));
      case SidePane.bugfix:
        _pushMobilePage('诊断修复', BugfixPanel(state: state));
      default:
        break;
    }
  }

  void _pushMobilePage(String title, Widget body) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => MobileSubPage(title: title, body: body)),
    );
  }

  /// 通用底部滑出层：可拖拽，头部带手柄与可选操作按钮。
  void _showSheet(Widget child, {List<Widget>? headerActions}) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1E1E23),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
      ),
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.92,
        maxChildSize: 0.96,
        minChildSize: 0.5,
        expand: false,
        builder: (ctx, ctrl) => Column(
          children: [
            const SizedBox(height: 8),
            Row(
              children: [
                const SizedBox(width: 14),
                Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: const Color(0xFF3A3A42),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const Spacer(),
                ...?headerActions,
                const SizedBox(width: 4),
              ],
            ),
            const SizedBox(height: 8),
            Expanded(child: child),
          ],
        ),
      ),
    );
  }

  void _showAiSheet() {
    _showSheet(
      AiPanel(
        state: state,
        settings: shell.settingsLoaded ? shell.aiSettings : AiSettings(),
        onChanged: shell.setAiSettings,
        onOpenSettings: () {
          Navigator.of(context).pop();
          setState(() => _tab = 4);
        },
      ),
      headerActions: [
        IconButton(
          icon: const Icon(
            FluentIcons.full_screen_maximize_24_regular,
            size: 18,
            color: Color(0xFF9B9BA3),
          ),
          onPressed: () {
            Navigator.of(context).pop();
            _openAiFullscreen();
          },
        ),
      ],
    );
  }

  /// AI 全屏模式：关闭底部滑出后进入独立页面。
  void _openAiFullscreen() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => MobileSubPage(
          title: 'AI 助手',
          body: AiPanel(
            state: state,
            settings: shell.settingsLoaded ? shell.aiSettings : AiSettings(),
            onChanged: shell.setAiSettings,
            onOpenSettings: () {
              Navigator.of(context).pop();
              setState(() => _tab = 4);
            },
          ),
        ),
      ),
    );
  }
}

class _MobileAppBar extends StatelessWidget implements PreferredSizeWidget {
  const _MobileAppBar({
    required this.state,
    required this.onMenu,
    required this.onSearch,
    required this.onAi,
  });

  final AppState state;
  final VoidCallback onMenu;
  final VoidCallback onSearch;
  final VoidCallback onAi;

  @override
  Size get preferredSize => const Size.fromHeight(52);

  @override
  Widget build(BuildContext context) {
    final mod = state.modName.isEmpty ? '未加载' : state.modName;
    return AppBar(
      backgroundColor: const Color(0xFF1B1B1F),
      elevation: 0,
      leading: IconButton(
        icon: const Icon(FluentIcons.navigation_24_regular, color: Colors.white),
        onPressed: onMenu,
      ),
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '学生时代模组编辑器',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Colors.white),
          ),
          Text(
            '工作区: $mod',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11, color: Color(0xFF9B9BA3)),
          ),
        ],
      ),
      actions: [
        IconButton(
          icon: const Icon(FluentIcons.search_24_regular, color: Color(0xFF9B9BA3)),
          onPressed: onSearch,
        ),
        IconButton(
          icon: const Icon(FluentIcons.bot_24_regular, color: Color(0xFF6C5CE7)),
          onPressed: onAi,
        ),
        const SizedBox(width: 4),
      ],
    );
  }
}

class _MobileDrawer extends StatelessWidget {
  const _MobileDrawer({
    required this.state,
    required this.currentTab,
    required this.onSelectTab,
    required this.onSelectPane,
    required this.onOpenAi,
    required this.uiMode,
    required this.onUiModeChanged,
  });

  final AppState state;
  final int currentTab;
  final ValueChanged<int> onSelectTab;
  final ValueChanged<SidePane> onSelectPane;
  final VoidCallback onOpenAi;
  final UiMode uiMode;
  final ValueChanged<UiMode> onUiModeChanged;

  @override
  Widget build(BuildContext context) {
    return Drawer(
      backgroundColor: const Color(0xFF17171B),
      width: 300,
      child: SafeArea(
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            Container(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
              color: const Color(0xFF1B1B1F),
              child: Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: const Color(0xFF6C5CE7),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(FluentIcons.box_24_regular, color: Colors.white, size: 18),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('学生时代', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                        Text('模组编辑器', style: TextStyle(color: Color(0xFF9B9BA3), fontSize: 12)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            // 底部导航已覆盖页面/文件/编辑，抽屉只放工具与系统入口，避免重复
            _drawerSection('主要', [
              _drawerItem(FluentIcons.box_24_regular, '模组', currentTab == 0, () => onSelectTab(0)),
            ]),
            _drawerSection('工具', [
              _drawerItem(FluentIcons.image_24_regular, '资源', false, () => onSelectPane(SidePane.resources)),
              _drawerItem(FluentIcons.book_search_24_regular, '剧情库', false, () => onSelectPane(SidePane.base)),
              _drawerItem(FluentIcons.cloud_24_regular, '云同步', false, () => onSelectPane(SidePane.cloud)),
              _drawerItem(FluentIcons.wrench_24_regular, '诊断修复', false, () => onSelectPane(SidePane.bugfix)),
              _drawerItem(FluentIcons.bot_24_regular, 'AI 助手', false, onOpenAi),
            ]),
            _drawerSection('系统', [
              _drawerItem(FluentIcons.settings_24_regular, '设置', currentTab == 4, () => onSelectTab(4)),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(
                  children: [
                    const Icon(FluentIcons.paint_brush_24_regular, size: 16, color: Color(0xFF6E6E76)),
                    const SizedBox(width: 12),
                    const Expanded(child: Text('布局', style: TextStyle(color: Color(0xFF9B9BA3), fontSize: 13))),
                    fluent.ToggleSwitch(
                      checked: uiMode == UiMode.classic,
                      onChanged: (v) => onUiModeChanged(v ? UiMode.classic : UiMode.creation),
                    ),
                  ],
                ),
              ),
            ]),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  _statusDot(state.backendOnline),
                  const SizedBox(width: 8),
                  Text(
                    state.backendOnline ? '本地服务已连接' : '本地服务离线',
                    style: const TextStyle(fontSize: 12, color: Color(0xFF9B9BA3)),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  Widget _drawerSection(String title, List<Widget> items) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text(title, style: const TextStyle(fontSize: 11, color: Color(0xFF6E6E76), fontWeight: FontWeight.w600)),
          ),
          ...items,
        ],
      );

  Widget _drawerItem(IconData icon, String label, bool selected, VoidCallback onTap) => ListTile(
        leading: Icon(icon, size: 18, color: selected ? const Color(0xFF6C5CE7) : const Color(0xFF9B9BA3)),
        title: Text(label, style: TextStyle(fontSize: 13, color: selected ? Colors.white : const Color(0xFFD4D4D8), fontWeight: selected ? FontWeight.w600 : FontWeight.normal)),
        selected: selected,
        selectedTileColor: const Color(0xFF26262B),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16),
        dense: true,
        onTap: onTap,
      );

  Widget _statusDot(bool ok) => Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(shape: BoxShape.circle, color: ok ? const Color(0xFF4CAF50) : const Color(0xFFE53935)),
      );
}

class _MobileBottomBar extends StatelessWidget {
  const _MobileBottomBar({required this.current, required this.editorBadge, required this.onTap});

  final int current;
  final bool editorBadge;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    return NavigationBar(
      height: 64,
      backgroundColor: const Color(0xFF1B1B1F),
      indicatorColor: const Color(0xFF26262B),
      selectedIndex: current,
      onDestinationSelected: onTap,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      destinations: [
        const NavigationDestination(icon: Icon(FluentIcons.box_24_regular), selectedIcon: Icon(FluentIcons.box_24_filled), label: '模组'),
        const NavigationDestination(icon: Icon(FluentIcons.apps_24_regular), selectedIcon: Icon(FluentIcons.apps_24_filled), label: '页面'),
        const NavigationDestination(icon: Icon(FluentIcons.folder_24_regular), selectedIcon: Icon(FluentIcons.folder_24_filled), label: '文件'),
        NavigationDestination(
          icon: Badge(isLabelVisible: editorBadge, smallSize: 8, child: const Icon(FluentIcons.document_24_regular)),
          selectedIcon: Badge(isLabelVisible: editorBadge, smallSize: 8, child: const Icon(FluentIcons.document_24_filled)),
          label: '编辑',
        ),
        const NavigationDestination(icon: Icon(FluentIcons.more_horizontal_24_regular), label: '更多'),
      ],
    );
  }
}

class _MobileEditorWrapper extends StatelessWidget {
  const _MobileEditorWrapper({
    required this.state,
    required this.controller,
    required this.onEmptyPages,
    required this.onEmptyFiles,
  });

  final AppState state;
  final dynamic controller;
  final VoidCallback onEmptyPages;
  final VoidCallback onEmptyFiles;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        return Column(
          children: [
            Expanded(
              child: controller.current == null
                  ? _MobileEditorEmpty(onPages: onEmptyPages, onFiles: onEmptyFiles)
                  : EditorArea(state: state, controller: controller),
            ),
          ],
        );
      },
    );
  }
}

class _MobileEditorEmpty extends StatelessWidget {
  const _MobileEditorEmpty({required this.onPages, required this.onFiles});

  final VoidCallback onPages;
  final VoidCallback onFiles;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: const Color(0xFF1E1E23),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: const Color(0xFF2E2E35)),
            ),
            child: const Icon(FluentIcons.document_24_regular, size: 30, color: Color(0xFF6C5CE7)),
          ),
          const SizedBox(height: 14),
          const Text('还没有打开任何文档',
              style: TextStyle(fontSize: 15, color: Colors.white, fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          const Text('从「页面」选择一个配置表，或从「文件」浏览模组目录',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: Color(0xFF9B9BA3))),
          const SizedBox(height: 18),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              fluent.FilledButton(onPressed: onPages, child: const Text('去选页面')),
              const SizedBox(width: 10),
              fluent.Button(onPressed: onFiles, child: const Text('浏览文件')),
            ],
          ),
        ],
      ),
    );
  }
}

class _MobileMorePage extends StatelessWidget {
  const _MobileMorePage({
    required this.state,
    required this.shell,
    required this.uiMode,
    required this.onUiModeChanged,
    required this.onOpenAi,
  });

  final AppState state;
  final ShellState shell;
  final UiMode uiMode;
  final ValueChanged<UiMode> onUiModeChanged;
  final VoidCallback onOpenAi;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        _moreCard(
          icon: FluentIcons.cloud_24_regular,
          title: '云同步',
          subtitle: 'WebDAV / OpenList 等云盘双向同步',
          onTap: () => _push(context, '云同步', CloudPage(state: state)),
        ),
        _moreCard(
          icon: FluentIcons.image_24_regular,
          title: '资源',
          subtitle: '贴图 / 音频 / 文本索引',
          onTap: () => _push(context, '资源', ResourcesPage(state: state)),
        ),
        _moreCard(
          icon: FluentIcons.book_search_24_regular,
          title: '剧情库',
          subtitle: '原版检索 / 提取',
          onTap: () => _push(context, '剧情库', BaseSearchPage(state: state)),
        ),
        _moreCard(
          icon: FluentIcons.folder_zip_24_regular,
          title: '资源包管理',
          subtitle: '内置 / 导入 / 激活游戏资源包',
          onTap: () => _push(context, '资源包管理', PackManagerPage(state: state)),
        ),
        _moreCard(
          icon: FluentIcons.wrench_24_regular,
          title: '诊断修复',
          subtitle: '扫描并修复常见问题',
          onTap: () => _push(context, '诊断修复', BugfixPanel(state: state)),
        ),
        _moreCard(
          icon: FluentIcons.bot_24_regular,
          title: 'AI 助手',
          subtitle: shell.aiOpen ? '已开启，点击打开面板' : '已关闭',
          onTap: onOpenAi,
        ),
        const SizedBox(height: 12),
        _moreCard(
          icon: FluentIcons.settings_24_regular,
          title: '设置',
          subtitle: 'AI 服务 / 布局偏好',
          onTap: () => _push(
            context,
            '设置',
            SettingsPage(
              settings: shell.settingsLoaded ? shell.aiSettings : AiSettings(),
              onChanged: shell.setAiSettings,
              uiMode: uiMode,
              onUiModeChanged: onUiModeChanged,
            ),
          ),
        ),
      ],
    );
  }

  void _push(BuildContext context, String title, Widget body) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => MobileSubPage(title: title, body: body)),
    );
  }

  Widget _moreCard({required IconData icon, required String title, required String subtitle, required VoidCallback onTap}) => Card(
        color: const Color(0xFF1E1E23),
        margin: const EdgeInsets.only(bottom: 8),
        child: ListTile(
          leading: Icon(icon, color: const Color(0xFF6C5CE7)),
          title: Text(title, style: const TextStyle(color: Colors.white, fontSize: 14)),
          subtitle: Text(subtitle, style: const TextStyle(color: Color(0xFF9B9BA3), fontSize: 12)),
          trailing: const Icon(FluentIcons.chevron_right_24_regular, size: 16, color: Color(0xFF6E6E76)),
          onTap: onTap,
        ),
      );
}