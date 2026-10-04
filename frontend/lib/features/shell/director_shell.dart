import 'package:flutter/material.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../../core/api_client.dart';
import '../../core/app_dialogs.dart';
import '../../core/app_theme.dart';
import '../../core/models.dart';
import '../../core/motion.dart';
import '../../core/plugin_state.dart';
import '../../core/responsive.dart';
import '../../core/ui_mode.dart';
import '../base/base_search_page.dart';
import '../bugfix/bugfix_panel.dart';
import '../cloud/cloud_page.dart';
import '../editor/editor_controller.dart';
import '../files/file_tree_page.dart';
import '../mods/mods_page.dart';
import '../pages/page_view.dart';
import '../pages/pages_catalog.dart';
import '../plugins/plugins_page.dart';
import '../resources/resources_page.dart';
import '../settings/settings_page.dart';
import '../story/story_studio_editor.dart';
import 'ai_dock.dart';
import 'shell_state.dart';
import 'status_bar.dart';

/// 导演工作台的功能模块（顶部「功能」选择器与左侧导航切换的目标）。
enum _DirectorFeature {
  home('主页', FluentIcons.home_24_regular, '功能总览与快捷入口'),
  studio('剧情舞台', FluentIcons.production_24_regular, '对话线 / 舞台编辑 / 人物与表情'),
  pages('配置表', FluentIcons.table_24_regular, 'Schema 驱动的全部编辑页面'),
  resources('资源', FluentIcons.box_24_regular, '贴图 / 音频 / 立绘等资产'),
  files('文件', FluentIcons.folder_24_regular, '模组文件树与文本编辑'),
  plugins('插件', FluentIcons.puzzle_piece_24_regular, '声明型插件与动态面板'),
  cloud('云同步', FluentIcons.cloud_24_regular, 'WebDAV / OpenList 等驱动'),
  mods('模组', FluentIcons.apps_24_regular, '新建 / 切换 / 导入导出模组'),
  search('全局功能搜索', FluentIcons.search_24_regular, '跨配置表检索字段与条目'),
  bugfix('扫描修复', FluentIcons.wrench_24_regular, '配置体检与自动修复');

  const _DirectorFeature(this.label, this.icon, this.description);

  final String label;
  final IconData icon;
  final String description;
}

/// 导演布局：面向全工作流的整壳工作台。
///
/// 顶部工程栏（品牌 + 前进后退 + 模组 + 功能选择 + 操作）｜中部功能视图
/// （剧情舞台 / 配置表 / 资源 / 文件 / 插件 / 云同步 / 模组 / 搜索 / 修复，
/// 懒加载保活）｜右下角快捷工具托盘｜底部状态栏。配色一律取自 [palette]，
/// 随亮/暗外观联动。
class DirectorShell extends StatefulWidget {
  const DirectorShell({
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
  State<DirectorShell> createState() => _DirectorShellState();
}

class _DirectorShellState extends State<DirectorShell> {
  _DirectorFeature _feature = _DirectorFeature.studio;

  /// 访问过的功能（懒加载保活：切走再切回不丢页面状态）。
  final Set<_DirectorFeature> _visited = {_DirectorFeature.studio};

  /// 壳内视图历史（顶部前进/后退）。
  final List<_DirectorFeature> _history = [_DirectorFeature.studio];
  int _historyCursor = 0;

  /// 每个功能的刷新计数，用于单独重挂当前视图。
  final Map<_DirectorFeature, int> _refreshTokens = {};

  bool _cornersCollapsed = false;
  bool _helpOpen = false;

  // ---------------- 导航 ----------------

  void _go(_DirectorFeature f) {
    if (f == _feature) {
      setState(() => _helpOpen = false);
      return;
    }
    setState(() {
      _feature = f;
      _visited.add(f);
      _history.removeRange(_historyCursor + 1, _history.length);
      _history.add(f);
      _historyCursor = _history.length - 1;
      _helpOpen = false;
    });
  }

  void _back() {
    if (_historyCursor <= 0) return;
    setState(() {
      _historyCursor--;
      _feature = _history[_historyCursor];
      _visited.add(_feature);
      _helpOpen = false;
    });
  }

  void _forward() {
    if (_historyCursor >= _history.length - 1) return;
    setState(() {
      _historyCursor++;
      _feature = _history[_historyCursor];
      _visited.add(_feature);
      _helpOpen = false;
    });
  }

  Future<void> _refresh() async {
    // 只有剧情舞台注册了切走守卫；刷新它前先处理未保存修改，其他视图直接重挂。
    if (_feature == _DirectorFeature.studio) {
      final guard = widget.state.leaveGuard;
      if (guard != null) {
        final ok = await guard();
        if (!ok || !mounted) return;
      }
    }
    setState(() {
      _refreshTokens[_feature] = (_refreshTokens[_feature] ?? 0) + 1;
    });
  }

  Future<void> _selectMod(String name) async {
    if (name.trim().isEmpty || name == widget.state.modName) return;
    final guard = widget.state.leaveGuard;
    if (guard != null) {
      final ok = await guard();
      if (!ok || !mounted) return;
    }
    try {
      final r = await ApiClient.instance.post(
        '/api/mods/select',
        body: {'name': name},
      );
      final m = (r['mod'] as Map).cast<String, dynamic>();
      widget.state.setMod(m['name'] as String, m['root'] as String);
    } catch (e) {
      if (mounted) {
        fluent.displayInfoBar(
          context,
          builder: (ctx, close) => fluent.InfoBar(
            title: const Text('切换模组失败'),
            content: Text(e.toString(), style: const TextStyle(fontSize: 12)),
            severity: fluent.InfoBarSeverity.error,
          ),
        );
      }
    }
  }

  // ---------------- 弹窗 ----------------

  void _showToolModal(String title, Widget content) {
    final isMob = isMobile(context);
    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: title,
      barrierColor: palette.scrim,
      transitionDuration: AppMotion.normal,
      pageBuilder: (ctx, a1, a2) {
        final size = appDialogSize(ctx, preferredWidth: 1000);
        return Dialog(
          backgroundColor: palette.panel,
          insetPadding: EdgeInsets.symmetric(
            horizontal: isMob ? 12 : 40,
            vertical: isMob ? 24 : 40,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: palette.surface),
          ),
          child: Container(
            width: size.width,
            height: size.height,
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
                      icon: Icon(
                        FluentIcons.dismiss_24_regular,
                        size: 16,
                        color: palette.textSecondary,
                      ),
                      onPressed: () => Navigator.of(ctx).pop(),
                    ),
                  ],
                ),
                Divider(color: palette.surface, height: 18),
                Expanded(child: content),
              ],
            ),
          ),
        );
      },
      transitionBuilder: (ctx, anim, secAnim, child) {
        final curved = CurvedAnimation(parent: anim, curve: AppMotion.easeOut);
        return FadeTransition(
          opacity: curved,
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.96, end: 1.0).animate(curved),
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, 0.02),
                end: Offset.zero,
              ).animate(curved),
              child: child,
            ),
          ),
        );
      },
    );
  }

  void _openSettings() {
    _showToolModal(
      '⚙️ 系统设置',
      SettingsPage(
        settings: widget.shell.settingsLoaded
            ? widget.shell.aiSettings
            : AiSettings(),
        settingsLoaded: widget.shell.settingsLoaded,
        onChanged: widget.shell.setAiSettings,
        uiMode: widget.uiMode,
        onUiModeChanged: widget.onUiModeChanged,
      ),
    );
  }

  void _openMods() {
    _showToolModal(
      '📂 模组管理',
      ModsPage(state: widget.state, controller: widget.shell.controller),
    );
  }

  // ---------------- 构建 ----------------

  @override
  Widget build(BuildContext context) {
    return fluent.FluentTheme(
      data: fluent.FluentTheme.of(context).copyWith(
        typography: const fluent.Typography.raw(
          body: TextStyle(fontSize: 13, fontFamily: 'Microsoft YaHei'),
          caption: TextStyle(fontSize: 12, fontFamily: 'Microsoft YaHei'),
        ),
      ),
      child: ListenableBuilder(
        listenable: Listenable.merge([
          widget.shell,
          widget.state,
          widget.shell.controller,
        ]),
        builder: (context, _) => Column(
          children: [
            _buildToolbar(),
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _buildContentStack(),
                  _buildCornerDock(),
                ],
              ),
            ),
            StatusBar(
              state: widget.state,
              onToggleAi: widget.shell.toggleAi,
              uiMode: widget.uiMode,
              onUiModeChanged: widget.onUiModeChanged,
            ),
          ],
        ),
      ),
    );
  }

  // ---------- 顶部工程栏 ----------

  Widget _buildToolbar() {
    final mods = widget.state.mods;
    final modNames = {for (final m in mods) m.name};
    final curMod = widget.state.modName;
    final canBack = _historyCursor > 0;
    final canForward = _historyCursor < _history.length - 1;

    return Container(
      height: 64,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [palette.card, palette.panel],
        ),
        border: Border(bottom: BorderSide(color: palette.border)),
        boxShadow: [
          BoxShadow(
            color: palette.scrimWeak,
            blurRadius: 12,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Row(
        children: [
          _brand(),
          const SizedBox(width: 12),
          _IconPill(
            icon: FluentIcons.chevron_left_24_regular,
            tooltip: '后退',
            enabled: canBack,
            onTap: _back,
          ),
          const SizedBox(width: 4),
          _IconPill(
            icon: FluentIcons.chevron_right_24_regular,
            tooltip: '前进',
            enabled: canForward,
            onTap: _forward,
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: 168,
            child: fluent.ComboBox<String>(
              value: curMod.isNotEmpty ? curMod : null,
              isExpanded: true,
              placeholder: const Text('选择模组', style: TextStyle(fontSize: 12)),
              items: [
                for (final m in mods)
                  fluent.ComboBoxItem(
                    value: m.name,
                    child: Text(
                      m.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                if (curMod.isNotEmpty && !modNames.contains(curMod))
                  fluent.ComboBoxItem(
                    value: curMod,
                    child: Text(
                      curMod,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
              ],
              onChanged: (v) {
                if (v != null) _selectMod(v);
              },
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 140,
            child: fluent.ComboBox<_DirectorFeature>(
              value: _feature,
              isExpanded: true,
              items: [
                for (final f in _DirectorFeature.values)
                  fluent.ComboBoxItem(
                    value: f,
                    child: Row(
                      children: [
                        Icon(f.icon, size: 13, color: palette.textSecondary),
                        const SizedBox(width: 6),
                        Text(f.label, style: const TextStyle(fontSize: 12)),
                      ],
                    ),
                  ),
              ],
              onChanged: (v) {
                if (v != null) _go(v);
              },
            ),
          ),
          const SizedBox(width: 6),
          _IconPill(
            icon: FluentIcons.arrow_sync_24_regular,
            tooltip: '刷新当前视图',
            onTap: _refresh,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Align(
              alignment: Alignment.centerRight,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                reverse: true,
                child: Row(
                  children: [
                    _HeaderAction(
                      icon: FluentIcons.home_24_regular,
                      label: '主页',
                      selected: _feature == _DirectorFeature.home,
                      onTap: () => _go(_DirectorFeature.home),
                    ),
                    _HeaderAction(
                      icon: FluentIcons.apps_24_regular,
                      label: '模组',
                      onTap: _openMods,
                    ),
                    _HeaderAction(
                      icon: FluentIcons.cloud_24_regular,
                      label: '云同步',
                      selected: _feature == _DirectorFeature.cloud,
                      onTap: () => _go(_DirectorFeature.cloud),
                    ),
                    _HeaderAction(
                      icon: FluentIcons.question_circle_24_regular,
                      label: '操作说明',
                      selected: _helpOpen,
                      onTap: () => setState(() => _helpOpen = !_helpOpen),
                    ),
                    _HeaderAction(
                      icon: FluentIcons.settings_24_regular,
                      label: '设置',
                      onTap: _openSettings,
                    ),
                    _HeaderAction(
                      icon: FluentIcons.bot_24_regular,
                      label: 'AI',
                      selected: widget.shell.aiOpen,
                      onTap: widget.shell.toggleAi,
                    ),
                    _HeaderAction(
                      icon: _nextModeIcon(widget.uiMode.nextCycle()),
                      label: '${widget.uiMode.nextCycle().label}布局',
                      onTap: () =>
                          widget.onUiModeChanged(widget.uiMode.nextCycle()),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _brand() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [accentColor, palette.accentDeep],
            ),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(
            FluentIcons.movies_and_tv_24_regular,
            size: 19,
            color: palette.onAccent,
          ),
        ),
        const SizedBox(width: 10),
        Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '学生时代模组编辑器',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: palette.textHigh,
                letterSpacing: 0.03,
              ),
            ),
            const SizedBox(height: 1),
            Text(
              '导演工作台',
              style: TextStyle(
                fontSize: 10,
                color: palette.goldText,
                letterSpacing: 0.08,
              ),
            ),
          ],
        ),
      ],
    );
  }

  /// 循环切换按钮的目标图标：创作=画笔，经典=列表，剧情图=流程图，导演=场记板。
  IconData _nextModeIcon(UiMode m) => switch (m) {
    UiMode.creation => FluentIcons.paint_brush_24_regular,
    UiMode.classic => FluentIcons.list_24_regular,
    UiMode.storyFlow => FluentIcons.flow_24_regular,
    UiMode.director => FluentIcons.movies_and_tv_24_regular,
  };

  // ---------- 内容栈 ----------

  Widget _buildContentStack() {
    final children = <Widget>[];
    for (final f in _DirectorFeature.values) {
      if (_visited.contains(f)) {
        final token = _refreshTokens[f] ?? 0;
        children.add(
          Positioned.fill(
            child: Offstage(
              offstage: f != _feature,
              child: TickerMode(
                enabled: f == _feature,
                child: KeyedSubtree(
                  key: ValueKey('director-${f.name}-$token'),
                  child: _childFor(f),
                ),
              ),
            ),
          ),
        );
      }
    }
    children.add(
      Positioned.fill(
        child: AiOverlayDock(
          state: widget.state,
          shell: widget.shell,
          panelBackground: palette.panel,
          onOpenSettings: _openSettings,
        ),
      ),
    );
    if (_helpOpen) {
      children.add(
        Positioned.fill(
          child: _DirectorHelp(
            onClose: () => setState(() => _helpOpen = false),
            onOpen: _go,
          ),
        ),
      );
    }
    return Stack(fit: StackFit.expand, children: children);
  }

  Widget _childFor(_DirectorFeature f) {
    final state = widget.state;
    final controller = widget.shell.controller;
    switch (f) {
      case _DirectorFeature.home:
        return _DirectorHome(onOpen: _go);
      case _DirectorFeature.studio:
        return StoryStudioEditor(
          state: state,
          onPreview: (evtId) =>
              controller.open(OpenDoc.preview(eventId: evtId)),
        );
      case _DirectorFeature.pages:
        return _DirectorPagesView(
          state: state,
          onPreview: (evtId) =>
              controller.open(OpenDoc.preview(eventId: evtId)),
        );
      case _DirectorFeature.resources:
        return ResourcesPage(state: state);
      case _DirectorFeature.files:
        return FileTreePage(state: state, controller: controller);
      case _DirectorFeature.plugins:
        return PluginsPage(pluginState: widget.pluginState);
      case _DirectorFeature.cloud:
        return CloudPage(state: state);
      case _DirectorFeature.mods:
        return ModsPage(state: state, controller: controller);
      case _DirectorFeature.search:
        return BaseSearchPage(state: state);
      case _DirectorFeature.bugfix:
        return BugfixPanel(state: state);
    }
  }

  // ---------- 右下角快捷工具托盘 ----------

  Widget _buildCornerDock() {
    final items = <Widget>[
      _CornerButton(
        icon: FluentIcons.question_circle_24_regular,
        tooltip: '操作说明',
        active: _helpOpen,
        onTap: () => setState(() => _helpOpen = !_helpOpen),
      ),
      _CornerButton(
        icon: FluentIcons.apps_24_regular,
        tooltip: '模组管理',
        onTap: _openMods,
      ),
      _CornerButton(
        icon: FluentIcons.settings_24_regular,
        tooltip: '系统设置',
        onTap: _openSettings,
      ),
      _CornerButton(
        icon: FluentIcons.bot_24_regular,
        tooltip: 'AI 助手',
        active: widget.shell.aiOpen,
        onTap: widget.shell.toggleAi,
      ),
    ];
    return Positioned(
      // AI 收起态的悬浮按钮停在右下角；托盘上移让位，避免两个圆形按钮重叠。
      right: 16,
      bottom: widget.shell.aiOpen ? 16 : 72,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          AnimatedSwitcher(
            duration: AppMotion.fast,
            transitionBuilder: (c, a) => FadeTransition(opacity: a, child: c),
            child: _cornersCollapsed
                ? const SizedBox(key: ValueKey('corner-collapsed'))
                : Column(
                    key: const ValueKey('corner-expanded'),
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final it in items) ...[
                        it,
                        const SizedBox(height: 8),
                      ],
                    ],
                  ),
          ),
          _CornerButton(
            icon: _cornersCollapsed
                ? FluentIcons.chevron_up_24_regular
                : FluentIcons.chevron_down_24_regular,
            tooltip: _cornersCollapsed ? '展开快捷工具' : '收起快捷工具',
            onTap: () =>
                setState(() => _cornersCollapsed = !_cornersCollapsed),
          ),
        ],
      ),
    );
  }
}

/// 主页面：功能卡片总览与快捷入口。
class _DirectorHome extends StatelessWidget {
  const _DirectorHome({required this.onOpen});
  final ValueChanged<_DirectorFeature> onOpen;

  @override
  Widget build(BuildContext context) {
    final features = _DirectorFeature.values
        .where((f) => f != _DirectorFeature.home)
        .toList();
    return Container(
      color: palette.bgDeep2,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 22, 24, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '导演工作台',
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w600,
                    color: palette.textHigh,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '选择下面的功能模块开始编辑当前模组',
                  style: TextStyle(fontSize: 12.5, color: palette.textMuted),
                ),
              ],
            ),
          ),
          Expanded(
            child: GridView.builder(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
              gridDelegate:
                  const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 300,
                    mainAxisExtent: 108,
                    crossAxisSpacing: 14,
                    mainAxisSpacing: 14,
                  ),
              itemCount: features.length,
              itemBuilder: (context, i) {
                final f = features[i];
                return _HomeCard(feature: f, onTap: () => onOpen(f));
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _HomeCard extends StatefulWidget {
  const _HomeCard({required this.feature, required this.onTap});
  final _DirectorFeature feature;
  final VoidCallback onTap;
  @override
  State<_HomeCard> createState() => _HomeCardState();
}

class _HomeCardState extends State<_HomeCard> {
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
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: _hover ? palette.card : palette.panel,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: _hover ? accentColor.withValues(alpha: 0.5) : palette.border,
            ),
            boxShadow: _hover
                ? [
                    BoxShadow(
                      color: palette.scrimWeak,
                      blurRadius: 10,
                      offset: const Offset(0, 3),
                    ),
                  ]
                : [],
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: accentColor.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Icon(widget.feature.icon, size: 17, color: accentColor),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.feature.label,
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                        color: palette.textHigh,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      widget.feature.description,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        height: 1.5,
                        color: palette.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 配置表视图：左侧页面目录 + 右侧 Schema 编辑器。
class _DirectorPagesView extends StatefulWidget {
  const _DirectorPagesView({required this.state, this.onPreview});
  final AppState state;
  final ValueChanged<String>? onPreview;
  @override
  State<_DirectorPagesView> createState() => _DirectorPagesViewState();
}

class _DirectorPagesViewState extends State<_DirectorPagesView> {
  String _pageId = 'story';

  @override
  Widget build(BuildContext context) {
    final page = pageById(_pageId);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          width: 224,
          color: palette.panel,
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: visibleEditorPages.length,
            itemBuilder: (context, i) {
              final p = visibleEditorPages[i];
              final sel = p.id == _pageId;
              return MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => setState(() => _pageId = p.id),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    margin: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: sel
                          ? accentColor.withValues(alpha: 0.14)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(7),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          FluentIcons.document_24_regular,
                          size: 14,
                          color: sel ? accentColor : palette.textHint,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            p.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12.5,
                              fontWeight:
                                  sel ? FontWeight.w600 : FontWeight.normal,
                              color:
                                  sel ? palette.textHigh : palette.textPrimary,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        VerticalDivider(width: 1, color: palette.border),
        Expanded(
          child: page == null
              ? const SizedBox.shrink()
              : EditorPageView(
                  // key 必须按页面区分：同位置同类型组件若无 key，切页时 State
                  // 被复用，_cfg 停在首个页面的 defaultCfg。
                  key: ValueKey(page.id),
                  state: widget.state,
                  page: page,
                  onPreview: widget.onPreview,
                ),
        ),
      ],
    );
  }
}

/// 操作说明覆盖层：工作台导航、功能一览与常用快捷键。
class _DirectorHelp extends StatelessWidget {
  const _DirectorHelp({required this.onClose, required this.onOpen});
  final VoidCallback onClose;
  final ValueChanged<_DirectorFeature> onOpen;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: palette.bgDeep2,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(24, 16, 16, 16),
            decoration: BoxDecoration(
              color: palette.panel,
              border: Border(bottom: BorderSide(color: palette.border)),
            ),
            child: Row(
              children: [
                Icon(
                  FluentIcons.question_circle_24_regular,
                  size: 20,
                  color: accentColor,
                ),
                const SizedBox(width: 10),
                Text(
                  '操作说明',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: palette.textHigh,
                  ),
                ),
                const Spacer(),
                _IconPill(
                  icon: FluentIcons.dismiss_24_regular,
                  tooltip: '关闭',
                  onTap: onClose,
                ),
              ],
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 40),
              child: Align(
                alignment: Alignment.topLeft,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 920),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _helpSection('顶部工程栏', const [
                        '左侧为品牌与视图历史（前进 / 后退），随后是当前模组与「功能」选择器，'
                            '点右侧「刷新」可重新载入当前视图。',
                        '右侧为常用入口：主页、模组管理、云同步、操作说明、设置、AI 与界面布局切换。',
                      ]),
                      _helpSection('功能模块', const [
                        '主页：功能卡片总览，点卡片直接进入对应模块。',
                        '剧情舞台：对话线 / 舞台画面即写台词 / 人物与表情的三栏编排。',
                        '配置表：Schema 驱动的全部编辑页面，左侧切换页面。',
                        '资源 / 文件 / 插件 / 云同步 / 模组 / 全局功能搜索 / 扫描修复：其余编辑与维护入口。',
                      ]),
                      _helpSection('右下角快捷工具', const [
                        '常驻托盘提供 操作说明 / 模组管理 / 设置 / AI 的快捷入口，'
                            '点最下方箭头可收起或展开。',
                      ]),
                      _helpSection('常用快捷键', const [
                        'Ctrl+F：全局功能搜索',
                        'Ctrl+P：模组预览',
                        'Ctrl+Z / Ctrl+Y：撤销 / 重做（配置表文档）',
                        'Ctrl+S：保存当前编辑内容',
                      ]),
                      const SizedBox(height: 8),
                      Text(
                        '功能一览',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: palette.textHigh,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 10,
                        runSpacing: 10,
                        children: [
                          for (final f in _DirectorFeature.values)
                            _HelpChip(feature: f, onTap: () => onOpen(f)),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _helpSection(String title, List<String> lines) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: palette.goldText,
            ),
          ),
          const SizedBox(height: 8),
          for (final line in lines)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                '· $line',
                style: TextStyle(
                  fontSize: 12.5,
                  height: 1.7,
                  color: palette.textBody,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _HelpChip extends StatelessWidget {
  const _HelpChip({required this.feature, required this.onTap});
  final _DirectorFeature feature;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: palette.panel,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: palette.border),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(feature.icon, size: 13, color: accentColor),
              const SizedBox(width: 6),
              Text(
                feature.label,
                style: TextStyle(fontSize: 12, color: palette.textPrimary),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 顶部操作药丸按钮。
class _HeaderAction extends StatefulWidget {
  const _HeaderAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.selected = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool selected;

  @override
  State<_HeaderAction> createState() => _HeaderActionState();
}

class _HeaderActionState extends State<_HeaderAction> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final highlight = widget.selected || _hover;
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
          margin: const EdgeInsets.only(left: 6),
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
          decoration: BoxDecoration(
            color: widget.selected
                ? accentColor.withValues(alpha: 0.16)
                : _hover
                ? palette.card
                : Colors.transparent,
            borderRadius: BorderRadius.circular(9),
            border: Border.all(
              color: widget.selected
                  ? accentColor.withValues(alpha: 0.45)
                  : _hover
                  ? palette.border
                  : Colors.transparent,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                widget.icon,
                size: 14,
                color: highlight ? accentColor : palette.textSecondary,
              ),
              const SizedBox(width: 6),
              Text(
                widget.label,
                style: TextStyle(
                  fontSize: 12,
                  color: highlight ? palette.textHigh : palette.textSecondary,
                  fontWeight: widget.selected
                      ? FontWeight.w600
                      : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 仅图标的小药丸按钮（历史前进/后退、刷新等）。
class _IconPill extends StatefulWidget {
  const _IconPill({
    required this.icon,
    required this.onTap,
    this.tooltip,
    this.enabled = true,
  });

  final IconData icon;
  final VoidCallback onTap;
  final String? tooltip;
  final bool enabled;

  @override
  State<_IconPill> createState() => _IconPillState();
}

class _IconPillState extends State<_IconPill> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.enabled;
    final button = MouseRegion(
      cursor: enabled
          ? SystemMouseCursors.click
          : SystemMouseCursors.basic,
      onEnter: (_) {
        if (enabled) setState(() => _hover = true);
      },
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: enabled ? widget.onTap : null,
        child: AnimatedContainer(
          duration: AppMotion.fast,
          curve: AppMotion.easeOut,
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: _hover && enabled ? palette.card : Colors.transparent,
            borderRadius: BorderRadius.circular(9),
            border: Border.all(
              color: _hover && enabled ? palette.border : Colors.transparent,
            ),
          ),
          child: Icon(
            widget.icon,
            size: 16,
            color: enabled ? palette.textSecondary : palette.iconDisabled,
          ),
        ),
      ),
    );
    final tip = widget.tooltip;
    return tip == null ? button : Tooltip(message: tip, child: button);
  }
}

/// 右下角快捷工具按钮（圆形）。
class _CornerButton extends StatefulWidget {
  const _CornerButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.active = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool active;

  @override
  State<_CornerButton> createState() => _CornerButtonState();
}

class _CornerButtonState extends State<_CornerButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: AppMotion.fast,
            curve: AppMotion.easeOut,
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: palette.panel,
              shape: BoxShape.circle,
              border: Border.all(
                color: widget.active
                    ? accentColor.withValues(alpha: 0.6)
                    : _hover
                    ? palette.borderHover
                    : palette.border,
              ),
              boxShadow: [
                BoxShadow(
                  color: palette.scrimWeak,
                  blurRadius: 10,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Icon(
              widget.icon,
              size: 17,
              color: widget.active
                  ? accentColor
                  : _hover
                  ? palette.textPrimary
                  : palette.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}
