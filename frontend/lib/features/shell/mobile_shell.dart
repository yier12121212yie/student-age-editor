import 'package:flutter/material.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../../core/mobile_widgets.dart';
import '../../core/models.dart';
import '../../core/plugin_state.dart';
import '../../core/ui_mode.dart';
import '../ai/ai_panel.dart';
import '../base/base_search_page.dart';
import '../bugfix/bugfix_panel.dart';
import '../cloud/cloud_page.dart';
import '../plugins/plugin_pane.dart';
import '../plugins/plugins_page.dart';
import '../resources/pack_manager_page.dart';
import '../resources/resources_page.dart';
import '../settings/settings_page.dart';
import 'editor_area.dart';
import 'mobile_subpage.dart';
import 'shell_state.dart';
import 'shell_widgets.dart';
import '../../core/app_theme.dart';

/// 移动端外壳：底部导航 + 抽屉 + 全屏内容 + 可滑出 AI。
/// 在宽度 < 720 时由 app.dart 自动启用，替代 CreationShell / ClassicShell。
class MobileShell extends StatefulWidget {
  const MobileShell({
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
  State<MobileShell> createState() => _MobileShellState();
}

class _MobileShellState extends State<MobileShell> {
  int _tab = 0; // 0 模组 1 页面 2 文件 3 编辑 4 更多
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  ShellState get shell => widget.shell;
  AppState get state => widget.state;

  /// 已消费的「打开文档」序号：非编辑 tab 下 open() 一次就自动跳到编辑 tab，
  /// 补全「列表点条目 → 直接看到表单」的移动端核心动线（此前只点亮 Badge）。
  int _openSeq = 0;

  /// 已访问过的底部 tab：IndexedStack 保活用（见 _buildBody）。
  final Set<int> _visited = {0};

  /// 访问过的 tab 历史栈（去重，最近的在上）：系统返回键逐级回退，
  /// 而不是在任何 tab 上都直接退出应用。
  final List<int> _tabHistory = [];

  @override
  void initState() {
    super.initState();
    _openSeq = shell.controller.openSeq;
    shell.controller.addListener(_onEditorChanged);
  }

  @override
  void dispose() {
    shell.controller.removeListener(_onEditorChanged);
    super.dispose();
  }

  void _onEditorChanged() {
    if (!mounted) return;
    final seq = shell.controller.openSeq;
    if (seq == _openSeq) return;
    _openSeq = seq;
    if (_tab != 3) {
      _switchTab(3);
    }
  }

  void _switchTab(int i) {
    if (i == _tab) return;
    setState(() {
      // 记录来源 tab（去重，保留最近一次），系统返回键据此回退。
      _tabHistory.remove(i);
      _tabHistory.add(_tab);
      if (_tabHistory.length > 8) _tabHistory.removeAt(0);
      _tab = i;
      _visited.add(i);
    });
  }

  /// 系统返回键：回退到上一个访问过的 tab；没有历史则回到首页 tab（0）。
  void _goBackTab() {
    setState(() {
      final prev = _tabHistory.isNotEmpty ? _tabHistory.removeLast() : 0;
      _tab = prev;
      _visited.add(prev);
    });
  }

  @override
  Widget build(BuildContext context) {
    return fluent.FluentTheme(
      data: fluent.FluentTheme.of(context).copyWith(
        typography: const fluent.Typography.raw(
          // 移动端阅读阶梯：桌面 13/12 直接搬到手机偏小，抬到 14/13
          // （OOBE/mobile_widgets 的 16 输入不在此列，走各组件自带值）。
          body: TextStyle(fontSize: 14, fontFamily: 'Microsoft YaHei'),
          caption: TextStyle(fontSize: 13, fontFamily: 'Microsoft YaHei'),
        ),
      ),
      child: Theme(
        // 移动壳内原生 Material 控件的明暗必须跟随外观，否则亮色下对话框/输入框仍是暗底。
        data: (palette.isLight ? ThemeData.light() : ThemeData.dark()).copyWith(
          scaffoldBackgroundColor: palette.bgDeep2,
          navigationBarTheme: NavigationBarThemeData(
            backgroundColor: palette.bg,
          ),
        ),
        child: PopScope(
          // 非首页 tab 时拦截系统返回：先逐级回退 tab，只有回到首页（模组）
          // 再按返回才退出应用——这是 Android 用户对底部导航的默认预期。
          canPop: _tab == 0,
          onPopInvokedWithResult: (didPop, _) {
            if (didPop) return;
            // 抽屉打开时优先关闭抽屉（部分机型返回键不会先走 LocalHistoryEntry）。
            final scaffold = _scaffoldKey.currentState;
            if (scaffold != null && scaffold.isDrawerOpen) {
              scaffold.closeDrawer();
              return;
            }
            _goBackTab();
          },
          child: Scaffold(
            key: _scaffoldKey,
            backgroundColor: palette.bgDeep2,
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
            ),
            body: SafeArea(child: _buildBody()),
            bottomNavigationBar: SafeArea(
              child: _MobileBottomBar(
                current: _tab,
                editorBadge: shell.controller.docs.isNotEmpty,
                onTap: _switchTab,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    return ListenableBuilder(
      listenable: Listenable.merge([
        shell,
        state,
        shell.controller,
        widget.pluginState,
      ]),
      builder: (context, _) {
        // 只构建访问过的 tab，但访问过的全部保活（IndexedStack）：
        // 此前 ValueKey(_tab)+AnimatedSwitcher 切走即销毁，列表滚动位置、
        // 筛选词、选中态全丢——手机上「页面↔编辑」往返高频，代价最大。
        final order = [
          for (final i in const [0, 1, 2, 3, 4])
            if (_visited.contains(i)) i,
        ];
        return IndexedStack(
          index: order.indexOf(_tab),
          // KeyedSubtree：order 列表会因新访问的 tab 插入元素，
          // 按位置匹配会让相邻 tab 复用错对象的 State，显式加 key 隔离。
          // TickerMode：IndexedStack 只绘制当前 tab，隐藏 tab 的动画却仍
          // 在跑（保活视图里的点点/呼吸类 repeat 动画会一直出帧）。
          children: [
            for (final i in order)
              KeyedSubtree(
                key: ValueKey('mtab$i'),
                child: TickerMode(enabled: i == _tab, child: _buildTab(i)),
              ),
          ],
        );
      },
    );
  }

  Widget _buildTab(int tab) {
    switch (tab) {
      case 0:
        return SidePaneView(
          pane: SidePane.mods,
          state: state,
          shell: shell,
          pluginState: widget.pluginState,
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
          shell: shell,
          pluginState: widget.pluginState,
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
          shell: shell,
          pluginState: widget.pluginState,
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
          pluginState: widget.pluginState,
          uiMode: widget.uiMode,
          onUiModeChanged: widget.onUiModeChanged,
          onOpenAi: () => _showAiSheet(),
        );
      default:
        return const SizedBox.shrink();
    }
  }

  /// 通用底部滑出层：见 [showMobileSheet]（已抽到 core 供预览等复用）。
  void _showSheet(Widget child, {List<Widget>? headerActions}) {
    showMobileSheet(context, child, headerActions: headerActions);
  }

  void _showAiSheet() {
    _showSheet(
      AiPanel(
        state: state,
        controller: shell.chatControllerFor(state),
        settings: shell.settingsLoaded ? shell.aiSettings : AiSettings(),
        onChanged: shell.setAiSettings,
        onOpenSettings: () {
          Navigator.of(context).pop();
          setState(() => _tab = 4);
        },
      ),
      headerActions: [
        IconButton(
          icon: Icon(
            FluentIcons.full_screen_maximize_24_regular,
            size: 18,
            color: palette.textSecondary,
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
            controller: shell.chatControllerFor(state),
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
      backgroundColor: palette.bg,
      elevation: 0,
      leading: IconButton(
        icon: Icon(FluentIcons.navigation_24_regular, color: palette.textHigh),
        onPressed: onMenu,
      ),
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '学生时代模组编辑器',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: palette.textHigh,
            ),
          ),
          Text(
            '工作区: $mod',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11, color: palette.textSecondary),
          ),
        ],
      ),
      actions: [
        IconButton(
          icon: Icon(
            FluentIcons.search_24_regular,
            color: palette.textSecondary,
          ),
          onPressed: onSearch,
        ),
        IconButton(
          icon: Icon(FluentIcons.bot_24_regular, color: accentColor),
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
  });

  final AppState state;
  final int currentTab;
  final ValueChanged<int> onSelectTab;

  @override
  Widget build(BuildContext context) {
    return Drawer(
      backgroundColor: palette.bgDeep2,
      width: 300,
      child: SafeArea(
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            Container(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
              color: palette.bg,
              child: Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: accentColor,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(
                      FluentIcons.box_24_regular,
                      color: palette.textHigh,
                      size: 18,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '学生时代',
                          style: TextStyle(
                            color: palette.textHigh,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          '模组编辑器',
                          style: TextStyle(
                            color: palette.textSecondary,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            // 工具入口只保留在「更多」tab（抽屉此前整段重复，两处都改一处）；
            // AI 助手在顶栏按钮；抽屉只留导航跳转与在线状态。
            _drawerSection('主要', [
              _drawerItem(
                FluentIcons.box_24_regular,
                '模组',
                currentTab == 0,
                () => onSelectTab(0),
              ),
              _drawerItem(
                FluentIcons.settings_24_regular,
                '设置',
                currentTab == 4,
                () => onSelectTab(4),
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
                    style: TextStyle(
                      fontSize: 12,
                      color: palette.textSecondary,
                    ),
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
        child: Text(
          title,
          style: TextStyle(
            fontSize: 11,
            color: palette.textHint,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      ...items,
    ],
  );

  Widget _drawerItem(
    IconData icon,
    String label,
    bool selected,
    VoidCallback onTap,
  ) => ListTile(
    leading: Icon(
      icon,
      size: 18,
      color: selected ? accentColor : palette.textSecondary,
    ),
    title: Text(
      label,
      style: TextStyle(
        fontSize: 13,
        color: selected ? palette.textHigh : palette.textPrimary,
        fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
      ),
    ),
    selected: selected,
    selectedTileColor: palette.card,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
    contentPadding: const EdgeInsets.symmetric(horizontal: 16),
    dense: true,
    onTap: onTap,
  );

  Widget _statusDot(bool ok) => Container(
    width: 8,
    height: 8,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      color: ok ? palette.statusOk : palette.danger,
    ),
  );
}

class _MobileBottomBar extends StatelessWidget {
  const _MobileBottomBar({
    required this.current,
    required this.editorBadge,
    required this.onTap,
  });

  final int current;
  final bool editorBadge;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    return NavigationBar(
      height: 64,
      backgroundColor: palette.bg,
      indicatorColor: palette.card,
      selectedIndex: current,
      onDestinationSelected: onTap,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      destinations: [
        const NavigationDestination(
          icon: Icon(FluentIcons.box_24_regular),
          selectedIcon: Icon(FluentIcons.box_24_filled),
          label: '模组',
        ),
        const NavigationDestination(
          icon: Icon(FluentIcons.apps_24_regular),
          selectedIcon: Icon(FluentIcons.apps_24_filled),
          label: '页面',
        ),
        const NavigationDestination(
          icon: Icon(FluentIcons.folder_24_regular),
          selectedIcon: Icon(FluentIcons.folder_24_filled),
          label: '文件',
        ),
        NavigationDestination(
          icon: Badge(
            isLabelVisible: editorBadge,
            smallSize: 8,
            child: const Icon(FluentIcons.document_24_regular),
          ),
          selectedIcon: Badge(
            isLabelVisible: editorBadge,
            smallSize: 8,
            child: const Icon(FluentIcons.document_24_filled),
          ),
          label: '编辑',
        ),
        const NavigationDestination(
          icon: Icon(FluentIcons.more_horizontal_24_regular),
          label: '更多',
        ),
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
                  ? _MobileEditorEmpty(
                      onPages: onEmptyPages,
                      onFiles: onEmptyFiles,
                    )
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
              color: palette.panel,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: palette.surface),
            ),
            child: Icon(
              FluentIcons.document_24_regular,
              size: 30,
              color: accentColor,
            ),
          ),
          const SizedBox(height: 14),
          Text(
            '还没有打开任何文档',
            style: TextStyle(
              fontSize: 15,
              color: palette.textHigh,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '从「页面」选择一个配置表，或从「文件」浏览模组目录',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: palette.textSecondary),
          ),
          const SizedBox(height: 18),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              fluent.FilledButton(
                onPressed: onPages,
                child: const Text('去选页面'),
              ),
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
    required this.pluginState,
    required this.uiMode,
    required this.onUiModeChanged,
    required this.onOpenAi,
  });

  final AppState state;
  final ShellState shell;
  final PluginState pluginState;
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
          icon: Icons.extension,
          title: '插件',
          subtitle: '安装与启用插件，查看扩展面板',
          onTap: () {
            shell.selectPane(SidePane.plugins);
            shell.setActivePluginPanel(null);
            _push(context, '插件', PluginsPage(pluginState: pluginState));
          },
        ),
        // 已启用插件声明的动态面板入口
        for (final panel in pluginState.uiPanels) ...[
          _moreCard(
            icon: pluginPanelIcon(panel['icon'] as String?),
            title: (panel['title'] as String? ?? '插件面板'),
            subtitle:
                '${panel['plugin_id'] ?? ''} / ${panel['panel_id'] ?? ''}',
            onTap: () => _openPluginPanel(context, panel),
          ),
        ],
        _moreCard(
          icon: FluentIcons.bot_24_regular,
          title: 'AI 助手',
          // 移动端无常驻 dock，「已开启/已关闭」是桌面语义、在此无意义；
          // 改为呈现真实会话状态（阶段 6）。
          subtitle: () {
            final chat = shell.chatOrNull;
            if (chat == null) return '对话式读取与修改模组';
            if (chat.busy) return 'AI 正在回复…';
            if (chat.hasPendingPrompt) return '有一条审批等待你确认';
            final n = chat.sessions.length;
            return n > 1 ? '$n 段历史对话 · 点击继续' : '对话式读取与修改模组';
          }(),
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
              settingsLoaded: shell.settingsLoaded,
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
      MaterialPageRoute<void>(
        builder: (_) => MobileSubPage(title: title, body: body),
      ),
    );
  }

  /// 打开插件动态面板：与桌面活动栏一致设置 pane/activePluginPanel，
  /// 以全屏子页展示（子页自带返回），返回后清除面板状态。
  void _openPluginPanel(BuildContext context, Map<String, dynamic> panel) {
    final pluginId = (panel['plugin_id'] as String? ?? '').trim();
    final panelId = (panel['panel_id'] as String? ?? '').trim();
    final title = (panel['title'] as String? ?? '插件面板').trim();
    if (pluginId.isEmpty || panelId.isEmpty) return;
    shell.selectPane(SidePane.plugins);
    shell.setActivePluginPanel('$pluginId/$panelId');
    Navigator.of(context)
        .push(
          MaterialPageRoute<void>(
            builder: (_) => MobileSubPage(
              title: title.isEmpty ? '插件面板' : title,
              body: PluginPane(
                pluginId: pluginId,
                panelId: panelId,
                showHeader: false,
                onClosed: () => shell.setActivePluginPanel(null),
              ),
            ),
          ),
        )
        .then((_) => shell.setActivePluginPanel(null));
  }

  Widget _moreCard({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) => Card(
    color: palette.panel,
    margin: const EdgeInsets.only(bottom: 8),
    child: ListTile(
      leading: Icon(icon, color: accentColor),
      title: Text(
        title,
        style: TextStyle(color: palette.textHigh, fontSize: 14),
      ),
      subtitle: Text(
        subtitle,
        style: TextStyle(color: palette.textSecondary, fontSize: 12),
      ),
      trailing: Icon(
        FluentIcons.chevron_right_24_regular,
        size: 16,
        color: palette.textHint,
      ),
      onTap: onTap,
    ),
  );
}
