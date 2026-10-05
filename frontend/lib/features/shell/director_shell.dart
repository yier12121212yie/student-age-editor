import 'package:flutter/material.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/api_client.dart';
import '../../core/app_dialogs.dart';
import '../../core/app_theme.dart';
import '../../core/models.dart';
import '../../core/motion.dart';
import '../../core/plugin_state.dart';
import '../../core/responsive.dart';
import '../../core/ui_mode.dart';
import '../base/base_search_page.dart';
import '../blocks/blocks_workbench.dart';
import '../bugfix/bugfix_panel.dart';
import '../cloud/cloud_page.dart';
import '../chats/idle_chat_workbench.dart';
import '../editor/cfg_display_names.dart';
import '../editor/editor_controller.dart';
import '../editor/schema_editor_view.dart';
import '../events/event_workbench.dart';
import '../files/file_tree_page.dart';
import '../goals/goals_workbench.dart';
import '../messages/messages_workbench.dart';
import '../minigames/minigames_workbench.dart';
import '../json/json_workbench.dart';
import '../external/external_dialogues_workbench.dart';
import '../mods/mods_page.dart';
import '../pages/pages_catalog.dart';
import '../pages/workshop_features.dart';
import '../person/person_workbench.dart';
import '../plugins/plugins_page.dart';
import '../social/social_workbench.dart';
import '../space/space_workbench.dart';
import '../warehouse/warehouse_workbench.dart';
import '../resources/resources_page.dart';
import '../settings/settings_page.dart';
import '../story/story_studio_editor.dart';
import 'ai_dock.dart';
import 'shell_state.dart';
import 'status_bar.dart';

/// 导演工作台的顶层功能模块。
enum _DirectorFeature {
  home('主页', FluentIcons.home_24_regular, '功能总览与快捷入口'),
  studio('剧情舞台', FluentIcons.production_24_regular, '对话线 / 舞台编辑 / 人物与表情'),
  person('人物工作台', FluentIcons.person_24_regular, '角色资料 / 成长喜好 / 表情服装 / 立绘大小'),
  social('社交动态', FluentIcons.chat_24_regular, '企鹅空间动态 / 评论回复 / 点赞人物'),
  space('空间', FluentIcons.globe_24_regular, '企鹅空间主页 / 个性签名 / 留言板'),
  warehouse('物品仓库', FluentIcons.box_multiple_24_regular, '物品 / 书籍 / 商店与效果指令'),
  minigames('小游戏库', FluentIcons.games_24_regular, '人物社交小游戏 / 关卡与效果'),
  json('JSON 侧栏', FluentIcons.code_24_regular, '原始配置 JSON 查看与编辑'),
  external('外部对话', FluentIcons.comment_multiple_24_regular, '送礼 / 小游戏 / 闲聊的对白入口'),
  messages('手机消息', FluentIcons.chat_multiple_24_regular, '短信对话与回复分支'),
  goals('目标工作台', FluentIcons.target_24_regular, '目标列表 / 游戏内预览 / 要求与奖励'),
  blocks('积木库', FluentIcons.apps_list_24_regular, '条件 / 效果 / 指令的目录与搭建'),
  events('事件工作台', FluentIcons.calendar_ltr_24_regular, '事件触发 / 对白入口 / 选项'),
  chats('闲聊', FluentIcons.person_chat_24_regular, '人物闲聊 / 进度文字 / 线性对白'),
  pages('配置表', FluentIcons.table_24_regular, 'Schema 驱动的全部编辑页面'),
  resources('素材库', FluentIcons.box_24_regular, '贴图 / 音频 / 立绘等资产'),
  files('文件', FluentIcons.folder_24_regular, '模组文件树与文本编辑'),
  plugins('插件', FluentIcons.puzzle_piece_24_regular, '声明型插件与动态面板'),
  cloud('云同步', FluentIcons.cloud_24_regular, 'WebDAV / OpenList 等驱动'),
  mods('模组管理', FluentIcons.apps_24_regular, '新建 / 切换 / 导入导出模组'),
  search('剧情库检索', FluentIcons.search_24_regular, '原版事件与台词全文检索'),
  bugfix('扫描修复', FluentIcons.wrench_24_regular, '配置体检与自动修复');

  const _DirectorFeature(this.label, this.icon, this.description);

  final String label;
  final IconData icon;
  final String description;
}

/// 主页卡片的归类。
enum _HomeCategory { builtin, extension, resource }

/// 主页的一张功能卡片。
class _HomeEntry {
  const _HomeEntry({
    required this.id,
    required this.title,
    required this.description,
    required this.hint,
    required this.icon,
    required this.category,
    required this.onOpen,
  });

  final String id;
  final String title;
  final String description;
  final String hint;
  final IconData icon;
  final _HomeCategory category;
  final VoidCallback onOpen;
}

/// 导演布局：功能总览为首页的整壳工作台。
///
/// 顶部工程栏（品牌 + 前进后退 + 模组 + 功能选择 + 操作）｜中部功能视图
/// （主页 / 剧情舞台 / 配置表 / 素材库 / 文件 / 插件 / 云同步 / 模组 / 搜索 /
/// 修复，懒加载保活）｜右下角快捷工具托盘｜底部状态栏。配色取自 [palette]。
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
  static const _favoritesKey = 'director_home_favorites_v1';

  /// 进入导演布局先在主页，而不是直接落到某个编辑器。
  _DirectorFeature _feature = _DirectorFeature.home;

  /// 访问过的功能（懒加载保活：切走再切回不丢页面状态）。
  final Set<_DirectorFeature> _visited = {_DirectorFeature.home};

  /// 壳内视图历史（顶部前进/后退）。
  final List<_DirectorFeature> _history = [_DirectorFeature.home];
  int _historyCursor = 0;

  /// 每个功能的刷新计数，用于单独重挂当前视图。
  final Map<_DirectorFeature, int> _refreshTokens = {};

  /// 主页点某个页面卡片时，指定配置表页要打开的页面。
  String? _pendingPageId;

  /// 主页点某张配置表卡片时，直接定位到这张表（可跨页面）。
  String? _pendingCfg;

  final Set<String> _favorites = {};

  bool _cornersCollapsed = false;
  bool _helpOpen = false;

  @override
  void initState() {
    super.initState();
    _loadFavorites();
  }

  Future<void> _loadFavorites() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getStringList(_favoritesKey);
      if (!mounted) return;
      setState(() {
        _favorites
          ..clear()
          ..addAll(saved ?? _defaultFavorites());
      });
    } catch (_) {}
  }

  /// 首次使用时按功能目录的 `defaultFavorite` 预置收藏（与参考产品一致）。
  List<String> _defaultFavorites() {
    final list = kWorkshopFeatures.where((f) => f.defaultFavorite).toList()
      ..sort((a, b) => a.favoriteOrder.compareTo(b.favoriteOrder));
    return [for (final f in list) f.id];
  }

  Future<void> _toggleFavorite(String id) async {
    setState(() {
      if (!_favorites.remove(id)) _favorites.add(id);
    });
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_favoritesKey, _favorites.toList());
    } catch (_) {}
  }

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

  /// 打开「配置表」功能并直接定位到某一张表（自动找到它所归属的页面；该表不在
  /// 任何预设页面时只显示这张表的编辑视图）。
  void _openTable(String cfg) {
    String? pageId;
    for (final p in editorPages) {
      if (p.cfgNames.contains(cfg)) {
        pageId = p.id;
        break;
      }
    }
    setState(() {
      _pendingPageId = pageId;
      _pendingCfg = cfg;
      _refreshTokens[_DirectorFeature.pages] =
          (_refreshTokens[_DirectorFeature.pages] ?? 0) + 1;
    });
    _go(_DirectorFeature.pages);
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
    // 刷新会重挂当前视图、销毁其 State：任何未保存修改都要先确认。
    if (!await widget.state.runLeaveGuards()) return;
    if (!mounted) return;
    setState(() {
      _refreshTokens[_feature] = (_refreshTokens[_feature] ?? 0) + 1;
    });
  }

  Future<void> _selectMod(String name) async {
    if (name.trim().isEmpty || name == widget.state.modName) return;
    // 切模组会重载所有工作台数据：脏工作台先确认（保存/放弃/取消）。
    if (!await widget.state.runLeaveGuards()) return;
    if (!mounted) return;
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
            width: 156,
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
            width: 132,
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
                        Expanded(
                          child: Text(
                            f.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
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
        return _DirectorHome(
          modName: state.modName.isEmpty ? '(未加载/空白)' : state.modName,
          entries: _homeEntries(),
          favorites: _favorites,
          onToggleFavorite: _toggleFavorite,
          onOpenMods: _openMods,
        );
      case _DirectorFeature.studio:
        return StoryStudioEditor(
          state: state,
          onPreview: (evtId) =>
              controller.open(OpenDoc.preview(eventId: evtId)),
        );
      case _DirectorFeature.person:
        return PersonWorkbench(
          state: state,
          onPreview: (evtId) =>
              controller.open(OpenDoc.preview(eventId: evtId)),
          onOpenSearch: () => _go(_DirectorFeature.search),
        );
      case _DirectorFeature.social:
        return SocialWorkbench(
          state: state,
          onOpenSearch: () => _go(_DirectorFeature.search),
        );
      case _DirectorFeature.space:
        return SpaceWorkbench(
          state: state,
          onOpenSearch: () => _go(_DirectorFeature.search),
        );
      case _DirectorFeature.warehouse:
        return WarehouseWorkbench(
          state: state,
          onOpenSearch: () => _go(_DirectorFeature.search),
        );
      case _DirectorFeature.minigames:
        return MinigamesWorkbench(
          state: state,
          onOpenSearch: () => _go(_DirectorFeature.search),
        );
      case _DirectorFeature.json:
        return JsonWorkbench(
          state: state,
          onOpenSearch: () => _go(_DirectorFeature.search),
        );
      case _DirectorFeature.external:
        return ExternalDialoguesWorkbench(
          state: state,
          onOpenSearch: () => _go(_DirectorFeature.search),
        );
      case _DirectorFeature.messages:
        return MessagesWorkbench(
          state: state,
          onOpenSearch: () => _go(_DirectorFeature.search),
        );
      case _DirectorFeature.goals:
        return GoalsWorkbench(
          state: state,
          onOpenSearch: () => _go(_DirectorFeature.search),
        );
      case _DirectorFeature.blocks:
        return BlocksWorkbench(state: state);
      case _DirectorFeature.events:
        return EventWorkbench(
          state: state,
          onOpenSearch: () => _go(_DirectorFeature.search),
          onOpenStudio: () => _go(_DirectorFeature.studio),
        );
      case _DirectorFeature.chats:
        return IdleChatWorkbench(
          state: state,
          onOpenSearch: () => _go(_DirectorFeature.search),
        );
      case _DirectorFeature.pages:
        return _DirectorPagesView(
          state: state,
          initialPageId: _pendingPageId ??
              (_pendingCfg == null ? 'story' : null),
          initialCfg: _pendingCfg,
          onHome: () => _go(_DirectorFeature.home),
          onPreview: (evtId) =>
              controller.open(OpenDoc.preview(eventId: evtId)),
          onOpenSearch: () => _go(_DirectorFeature.search),
        );
      case _DirectorFeature.resources:
        return _DirectorFrame(
          feature: f,
          onHome: () => _go(_DirectorFeature.home),
          child: ResourcesPage(state: state),
        );
      case _DirectorFeature.files:
        return _DirectorFrame(
          feature: f,
          onHome: () => _go(_DirectorFeature.home),
          child: FileTreePage(state: state, controller: controller),
        );
      case _DirectorFeature.plugins:
        return _DirectorFrame(
          feature: f,
          onHome: () => _go(_DirectorFeature.home),
          child: PluginsPage(pluginState: widget.pluginState),
        );
      case _DirectorFeature.cloud:
        return _DirectorFrame(
          feature: f,
          onHome: () => _go(_DirectorFeature.home),
          child: CloudPage(state: state),
        );
      case _DirectorFeature.mods:
        return _DirectorFrame(
          feature: f,
          onHome: () => _go(_DirectorFeature.home),
          child: ModsPage(state: state, controller: controller),
        );
      case _DirectorFeature.search:
        return _DirectorFrame(
          feature: f,
          onHome: () => _go(_DirectorFeature.home),
          child: BaseSearchPage(state: state),
        );
      case _DirectorFeature.bugfix:
        return _DirectorFrame(
          feature: f,
          onHome: () => _go(_DirectorFeature.home),
          child: BugfixPanel(state: state),
        );
    }
  }

  List<_HomeEntry> _homeEntries() {
    return <_HomeEntry>[
      // 参考产品「工坊主页」的功能目录：每张卡片是一组配置表 / 一个编辑器入口，
      // 用户看到的是「功能」而不是原始表名。
      for (final f in kWorkshopFeatures)
        _HomeEntry(
          id: f.id,
          title: f.label,
          description: f.description,
          hint: _featureHint(f),
          icon: _featureIcon(f),
          category: _featureCategory(f),
          onOpen: () => _openFeature(f),
        ),
      // 本编辑器独有、参考产品主页没有的扩展工具。
      _HomeEntry(
        id: 'feat:blocks',
        title: '积木库',
        description: '条件 / 效果 / 指令的目录浏览与可视化搭建',
        hint: '无代码',
        icon: FluentIcons.apps_list_24_regular,
        category: _HomeCategory.extension,
        onOpen: () => _go(_DirectorFeature.blocks),
      ),
      _HomeEntry(
        id: 'feat:events',
        title: '事件',
        description: '事件定义与触发条件 / 人物闲聊',
        hint: '玩法',
        icon: FluentIcons.calendar_24_regular,
        category: _HomeCategory.extension,
        onOpen: () => _go(_DirectorFeature.events),
      ),
      _HomeEntry(
        id: 'feat:json',
        title: 'JSON 侧栏',
        description: '原始配置 JSON 查看与编辑',
        hint: '高级',
        icon: FluentIcons.code_24_regular,
        category: _HomeCategory.extension,
        onOpen: () => _go(_DirectorFeature.json),
      ),
      _HomeEntry(
        id: 'feat:plugins',
        title: '插件',
        description: '声明型插件与动态面板',
        hint: '扩展',
        icon: FluentIcons.puzzle_piece_24_regular,
        category: _HomeCategory.extension,
        onOpen: () => _go(_DirectorFeature.plugins),
      ),
      _HomeEntry(
        id: 'feat:files',
        title: '文件',
        description: '模组文件树与文本编辑',
        hint: '文件树',
        icon: FluentIcons.folder_24_regular,
        category: _HomeCategory.extension,
        onOpen: () => _go(_DirectorFeature.files),
      ),
      _HomeEntry(
        id: 'feat:cloud',
        title: '云同步',
        description: 'WebDAV / OpenList 等驱动',
        hint: '同步',
        icon: FluentIcons.cloud_24_regular,
        category: _HomeCategory.extension,
        onOpen: () => _go(_DirectorFeature.cloud),
      ),
      _HomeEntry(
        id: 'feat:search',
        title: '剧情库检索',
        description: '原版事件与台词全文检索',
        hint: '检索',
        icon: FluentIcons.search_24_regular,
        category: _HomeCategory.extension,
        onOpen: () => _go(_DirectorFeature.search),
      ),
      _HomeEntry(
        id: 'feat:bugfix',
        title: '扫描修复',
        description: '配置体检与自动修复',
        hint: '体检',
        icon: FluentIcons.wrench_24_regular,
        category: _HomeCategory.extension,
        onOpen: () => _go(_DirectorFeature.bugfix),
      ),
    ];
  }

  /// 功能卡片右下角的计数：素材类显示「素材」，其余显示覆盖的配置表数量。
  String _featureHint(WorkshopFeature f) {
    if (f.resourceOnly) return '素材';
    if (f.tables.isEmpty) return '入口';
    return '${f.tables.length} 张表';
  }

  _HomeCategory _featureCategory(WorkshopFeature f) {
    if (f.resourceOnly) return _HomeCategory.resource;
    return f.homeCategory == 'extension'
        ? _HomeCategory.extension
        : _HomeCategory.builtin;
  }

  IconData _featureIcon(WorkshopFeature f) {
    const tableIcons = <String, IconData>{
      'PersonCfg': FluentIcons.person_24_regular,
      'PersonGrowCfg': FluentIcons.person_24_regular,
      'ModFaceCfg': FluentIcons.emoji_24_regular,
      'ItemCfg': FluentIcons.box_24_regular,
      'BookCfg': FluentIcons.book_24_regular,
      'ShopCfg': FluentIcons.cart_24_regular,
      'KZoneContentCfg': FluentIcons.chat_24_regular,
      'KZoneCommentCfg': FluentIcons.comment_multiple_24_regular,
      'KZoneAvatarCfg': FluentIcons.person_24_regular,
      'KZoneProfileCfg': FluentIcons.globe_24_regular,
      'PhoneMsgCfg': FluentIcons.chat_multiple_24_regular,
      'IntentCfg': FluentIcons.target_24_regular,
      'ActionCfg': FluentIcons.wrench_24_regular,
      'MinigameCfg': FluentIcons.games_24_regular,
      'ToggleCfg': FluentIcons.toggle_right_24_regular,
      'TraitsCfg': FluentIcons.star_24_regular,
      'EndingPartCfg': FluentIcons.book_24_regular,
      'EndingOptionCfg': FluentIcons.branch_24_regular,
      'BgCfg': FluentIcons.image_24_regular,
      'CGCfg': FluentIcons.image_24_regular,
      'AudioCfg': FluentIcons.music_note_2_24_regular,
      'MovieCfg': FluentIcons.movies_and_tv_24_regular,
      'NewsCfg': FluentIcons.news_24_regular,
      'FishCfg': FluentIcons.food_fish_24_regular,
      'TripSpotCfg': FluentIcons.globe_24_regular,
      'AnimationCfg': FluentIcons.video_24_regular,
      'ExpoSiteCfg': FluentIcons.building_24_regular,
      'ClubActivityCfg': FluentIcons.search_24_regular,
      'DIYCfg': FluentIcons.puzzle_piece_24_regular,
      'BirthdayPaintCfg': FluentIcons.food_cake_24_regular,
      'NegotiationPlayerCfg': FluentIcons.scales_24_regular,
      'TextCfg': FluentIcons.document_24_regular,
      'RenshengguanMemoryCfg': FluentIcons.book_24_regular,
    };
    final table = f.primaryTable ?? (f.tables.isNotEmpty ? f.tables.first : null);
    if (table != null && tableIcons[table] != null) return tableIcons[table]!;
    return FluentIcons.apps_list_24_regular;
  }

  /// 打开一条主页功能：有专属工作台的走工作台，其余定位到通用配置表编辑器。
  void _openFeature(WorkshopFeature f) {
    switch (f.entryKind) {
      case 'story':
        _go(_DirectorFeature.studio);
        return;
      case 'idle-chats':
        _go(_DirectorFeature.chats);
        return;
      case 'external-dialogues':
        _go(_DirectorFeature.external);
        return;
      case 'manifest':
        _go(_DirectorFeature.mods);
        return;
      case 'resources':
        _go(_DirectorFeature.resources);
        return;
      case 'plugins':
        _go(_DirectorFeature.plugins);
        return;
    }
    final table = f.primaryTable ?? (f.tables.isNotEmpty ? f.tables.first : null);
    if (table == null) return;
    switch (table) {
      case 'PersonCfg':
        _go(_DirectorFeature.person);
        return;
      case 'KZoneContentCfg':
      case 'KZoneCommentCfg':
        _go(_DirectorFeature.social);
        return;
      case 'PhoneMsgCfg':
        _go(_DirectorFeature.messages);
        return;
      case 'IntentCfg':
        _go(_DirectorFeature.goals);
        return;
      case 'ItemCfg':
      case 'BookCfg':
      case 'ShopCfg':
        _go(_DirectorFeature.warehouse);
        return;
      case 'MinigameCfg':
      case 'MinigameActionCfg':
        _go(_DirectorFeature.minigames);
        return;
      case 'KZoneProfileCfg':
        _go(_DirectorFeature.space);
        return;
    }
    _openTable(table);
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
    ];
    return Positioned(
      // AI 入口只保留右下角的悬浮按钮（[AiOverlayDock]，带待审批 / 正在回复
      // 角标）；快捷托盘不再放 AI，避免侧栏出现两个机器人图标。AI 收起态时
      // 悬浮按钮停在右下角，托盘上移让位。
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

/// 非主页功能的外框：面包屑返回 + 功能标题，正文置于工作台卡片内。
class _DirectorFrame extends StatelessWidget {
  const _DirectorFrame({
    required this.feature,
    required this.onHome,
    required this.child,
  });

  final _DirectorFeature feature;
  final VoidCallback onHome;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: palette.bgDeep2,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: 46,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: palette.panel,
              border: Border(bottom: BorderSide(color: palette.border)),
            ),
            child: Row(
              children: [
                _HomeBackLink(onTap: onHome),
                const SizedBox(width: 12),
                Icon(feature.icon, size: 15, color: accentColor),
                const SizedBox(width: 7),
                Text(
                  feature.label,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: palette.textHigh,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    feature.description,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11.5, color: palette.textMuted),
                  ),
                ),
              ],
            ),
          ),
          Expanded(child: child),
        ],
      ),
    );
  }
}

class _HomeBackLink extends StatelessWidget {
  const _HomeBackLink({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(7),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                FluentIcons.chevron_left_24_regular,
                size: 12,
                color: accentColor,
              ),
              const SizedBox(width: 3),
              Text(
                '全部功能',
                style: TextStyle(fontSize: 12, color: accentColor),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 主页：功能总览（标题 + 搜索 + 分组卡片 + 模组管理工具）。
class _DirectorHome extends StatefulWidget {
  const _DirectorHome({
    required this.modName,
    required this.entries,
    required this.favorites,
    required this.onToggleFavorite,
    required this.onOpenMods,
  });

  final String modName;
  final List<_HomeEntry> entries;
  final Set<String> favorites;
  final ValueChanged<String> onToggleFavorite;
  final VoidCallback onOpenMods;

  @override
  State<_DirectorHome> createState() => _DirectorHomeState();
}

class _DirectorHomeState extends State<_DirectorHome> {
  final TextEditingController _searchCtrl = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  List<_HomeEntry> get _filtered {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return widget.entries;
    return widget.entries
        .where(
          (e) =>
              e.title.toLowerCase().contains(q) ||
              e.description.toLowerCase().contains(q) ||
              e.hint.toLowerCase().contains(q),
        )
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final all = _filtered;
    final favorites = all
        .where((e) => widget.favorites.contains(e.id))
        .toList();
    final builtin = all
        .where(
          (e) =>
              e.category == _HomeCategory.builtin &&
              !widget.favorites.contains(e.id),
        )
        .toList();
    final extension = all
        .where(
          (e) =>
              e.category == _HomeCategory.extension &&
              !widget.favorites.contains(e.id),
        )
        .toList();
    final resource = all
        .where(
          (e) =>
              e.category == _HomeCategory.resource &&
              !widget.favorites.contains(e.id),
        )
        .toList();

    return Container(
      color: palette.bgDeep2,
      child: Scrollbar(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(28, 26, 28, 48),
          child: Align(
            alignment: Alignment.topLeft,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1360),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _heading(),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: 560,
                    child: fluent.TextBox(
                      controller: _searchCtrl,
                      placeholder: '搜索功能，如人物、剧情、物品…',
                      onChanged: (v) => setState(() => _query = v),
                    ),
                  ),
                  const SizedBox(height: 8),
                  _section(
                    '收藏区',
                    favorites,
                    empty: '点击功能卡片右上角的星星，把常用功能放到这里。',
                  ),
                  _section('游戏内置编辑器可编辑项', builtin),
                  _section('编辑器拓展', extension),
                  _tools(),
                  _section('素材库', resource),
                  if (all.isEmpty && _query.trim().isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 20),
                      child: Text(
                        '没有匹配的功能。',
                        style: TextStyle(fontSize: 12.5, color: palette.textMuted),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _heading() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '模组编辑功能',
                style: TextStyle(
                  fontSize: 27,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.5,
                  color: palette.textHigh,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '选择要编辑的内容。各功能默认只显示这个模组的记录。',
                style: TextStyle(fontSize: 13, color: palette.textMuted),
              ),
            ],
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: palette.panel,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: palette.border),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                FluentIcons.apps_24_regular,
                size: 13,
                color: palette.textHint,
              ),
              const SizedBox(width: 6),
              Text(
                '当前模组：${widget.modName}',
                style: TextStyle(fontSize: 12, color: palette.textSecondary),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _section(String title, List<_HomeEntry> items, {String empty = ''}) {
    if (items.isEmpty && empty.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: palette.goldText,
            ),
          ),
          const SizedBox(height: 12),
          if (items.isEmpty)
            Text(
              empty,
              style: TextStyle(fontSize: 12, color: palette.textMuted),
            )
          else
            LayoutBuilder(
              builder: (context, box) {
                final w = box.maxWidth;
                final columns = (w / 300).floor().clamp(1, 4);
                const gap = 14.0;
                final cardW = (w - gap * (columns - 1)) / columns;
                return Wrap(
                  spacing: gap,
                  runSpacing: gap,
                  children: [
                    for (final e in items)
                      SizedBox(
                        width: cardW,
                        height: 172,
                        child: _HomeCard(
                          entry: e,
                          favorite: widget.favorites.contains(e.id),
                          onToggleFavorite: widget.onToggleFavorite,
                        ),
                      ),
                  ],
                );
              },
            ),
        ],
      ),
    );
  }

  Widget _tools() {
    return Padding(
      padding: const EdgeInsets.only(top: 26),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '模组管理',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: palette.goldText,
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              _ToolButton(
                label: '模组信息',
                icon: FluentIcons.apps_24_regular,
                onTap: widget.onOpenMods,
              ),
              _ToolButton(
                label: '游戏素材缓存',
                icon: FluentIcons.box_24_regular,
                onTap: () => widget.entries
                    .firstWhere(
                      (e) => e.id == 'feat:resources',
                      orElse: () => widget.entries.first,
                    )
                    .onOpen(),
              ),
              _ToolButton(
                label: '导出 / 导入',
                icon: FluentIcons.arrow_sync_24_regular,
                onTap: widget.onOpenMods,
              ),
              _ToolButton(
                label: '删除模组',
                icon: FluentIcons.dismiss_24_regular,
                danger: true,
                onTap: widget.onOpenMods,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _HomeCard extends StatefulWidget {
  const _HomeCard({
    required this.entry,
    required this.favorite,
    required this.onToggleFavorite,
  });

  final _HomeEntry entry;
  final bool favorite;
  final ValueChanged<String> onToggleFavorite;

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
      child: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.entry.onOpen,
              child: AnimatedContainer(
                duration: AppMotion.fast,
                curve: AppMotion.easeOut,
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: _hover ? palette.card : palette.panel,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: _hover
                        ? accentColor.withValues(alpha: 0.55)
                        : palette.border,
                  ),
                  boxShadow: _hover
                      ? [
                          BoxShadow(
                            color: palette.scrimWeak,
                            blurRadius: 14,
                            offset: const Offset(0, 4),
                          ),
                        ]
                      : [],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      // 给右上角星标留位
                      padding: const EdgeInsets.only(right: 30),
                      child: Row(
                        children: [
                          Icon(
                            widget.entry.icon,
                            size: 17,
                            color: accentColor,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              widget.entry.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                                color: palette.textHigh,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: Text(
                        widget.entry.description,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          height: 1.6,
                          color: palette.textMuted,
                        ),
                      ),
                    ),
                    Row(
                      children: [
                        Text(
                          '打开 →',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: accentColor,
                          ),
                        ),
                        const Spacer(),
                        Text(
                          widget.entry.hint,
                          style: TextStyle(
                            fontSize: 11,
                            color: palette.textHint,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
          Positioned(
            top: 10,
            right: 10,
            child: Tooltip(
              message: widget.favorite ? '取消收藏' : '收藏',
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  onTap: () => widget.onToggleFavorite(widget.entry.id),
                  child: AnimatedContainer(
                    duration: AppMotion.fast,
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(
                      color: _hover
                          ? palette.hover
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(
                      widget.favorite
                          ? FluentIcons.star_24_filled
                          : FluentIcons.star_24_regular,
                      size: 16,
                      color: widget.favorite
                          ? palette.goldText
                          : palette.textHint,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ToolButton extends StatelessWidget {
  const _ToolButton({
    required this.label,
    required this.icon,
    required this.onTap,
    this.danger = false,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final color = danger ? palette.danger : palette.textPrimary;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: palette.panel,
            borderRadius: BorderRadius.circular(9),
            border: Border.all(
              color: danger ? palette.danger.withValues(alpha: 0.5) : palette.border,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 14, color: color),
              const SizedBox(width: 7),
              Text(label, style: TextStyle(fontSize: 12.5, color: color)),
            ],
          ),
        ),
      ),
    );
  }
}

/// 配置表工作台：Schema 编辑器（条目列表 / 字段表单）+ 信息栏。
///
/// 顶部不再放整排页面标签：主页的「全部配置表」已给每张表一个入口，这里只显示
/// 当前正在编辑的页面 / 表名。
class _DirectorPagesView extends StatefulWidget {
  const _DirectorPagesView({
    required this.state,
    required this.initialPageId,
    required this.onHome,
    this.initialCfg,
    this.onPreview,
    this.onOpenSearch,
  });

  final AppState state;
  final String? initialPageId;
  final String? initialCfg;
  final VoidCallback onHome;
  final ValueChanged<String>? onPreview;
  final VoidCallback? onOpenSearch;

  @override
  State<_DirectorPagesView> createState() => _DirectorPagesViewState();
}

class _DirectorPagesViewState extends State<_DirectorPagesView> {
  late String? _pageId = widget.initialPageId;
  late String _cfgName = widget.initialCfg ??
      (pageById(widget.initialPageId ?? '')?.defaultCfg ?? '');

  @override
  void didUpdateWidget(covariant _DirectorPagesView old) {
    super.didUpdateWidget(old);
    if (old.initialPageId != widget.initialPageId ||
        old.initialCfg != widget.initialCfg) {
      final page = pageById(widget.initialPageId ?? '');
      setState(() {
        _pageId = widget.initialPageId;
        _cfgName = widget.initialCfg ?? page?.defaultCfg ?? '';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final page = pageById(_pageId ?? '');
    return Container(
      color: palette.bgDeep2,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _header(page),
          Expanded(
            child: _cfgName.isEmpty
                ? const SizedBox.shrink()
                : Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        child: SchemaEditorView(
                          // key 按 cfg 区分：切表时 State 必须重建，否则编辑区停留在旧表。
                          key: ValueKey('director-schema-$_cfgName'),
                          state: widget.state,
                          cfgName: _cfgName,
                          onPreview: widget.onPreview,
                          onOpenSearch: widget.onOpenSearch,
                        ),
                      ),
                      if (page != null) ...[
                        VerticalDivider(width: 1, color: palette.border),
                        SizedBox(
                          width: 248,
                          child: _PageInfoRail(
                            page: page,
                            cfgName: _cfgName,
                            onSelectCfg: (c) => setState(() => _cfgName = c),
                          ),
                        ),
                      ],
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _header(EditorPageDef? page) {
    final title = page?.title ?? cfgDisplayName(_cfgName);
    final desc = page?.description ?? '配置表：$_cfgName';
    return Container(
      height: 46,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: palette.panel,
        border: Border(bottom: BorderSide(color: palette.border)),
      ),
      child: Row(
        children: [
          _HomeBackLink(onTap: widget.onHome),
          const SizedBox(width: 12),
          Icon(FluentIcons.table_24_regular, size: 15, color: accentColor),
          const SizedBox(width: 7),
          Text(
            title,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: palette.textHigh,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              desc,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11.5, color: palette.textMuted),
            ),
          ),
        ],
      ),
    );
  }
}

class _PageInfoRail extends StatelessWidget {
  const _PageInfoRail({
    required this.page,
    required this.cfgName,
    required this.onSelectCfg,
  });

  final EditorPageDef page;
  final String cfgName;
  final ValueChanged<String> onSelectCfg;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: palette.panel,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              page.title,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: palette.textHigh,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              page.description,
              style: TextStyle(
                fontSize: 12,
                height: 1.7,
                color: palette.textMuted,
              ),
            ),
            const SizedBox(height: 18),
            Text(
              '可编辑配置表',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: palette.goldText,
              ),
            ),
            const SizedBox(height: 8),
            for (final cfg in page.cfgNames)
              _CfgChip(
                label: cfgDisplayName(cfg),
                selected: cfg == cfgName,
                onTap: () => onSelectCfg(cfg),
              ),
            const SizedBox(height: 16),
            Text(
              '提示：条目列表在左、字段表单在右；本栏可切换当前页面里的配置表。',
              style: TextStyle(
                fontSize: 11,
                height: 1.7,
                color: palette.textHint,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CfgChip extends StatefulWidget {
  const _CfgChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });
  final String label;
  final bool selected;
  final VoidCallback onTap;
  @override
  State<_CfgChip> createState() => _CfgChipState();
}

class _CfgChipState extends State<_CfgChip> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          width: double.infinity,
          margin: const EdgeInsets.only(bottom: 6),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: widget.selected
                ? accentColor.withValues(alpha: 0.14)
                : _hover
                ? palette.card
                : palette.bgDeep2,
            borderRadius: BorderRadius.circular(7),
            border: Border.all(
              color: widget.selected
                  ? accentColor.withValues(alpha: 0.4)
                  : palette.border,
            ),
          ),
          child: Text(
            widget.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11.5,
              color: widget.selected
                  ? palette.textHigh
                  : palette.textSecondary,
              fontWeight:
                  widget.selected ? FontWeight.w600 : FontWeight.normal,
            ),
          ),
        ),
      ),
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
                      _helpSection('主页与功能模块', const [
                        '进入导演工作台先到主页：搜索、收藏并选择要编辑的功能。',
                        '游戏内置编辑器可编辑项：剧情舞台与各配置页面。',
                        '编辑器拓展 / 素材库 / 模组管理：插件、云同步、文件、搜索、修复、素材与模组维护。',
                      ]),
                      _helpSection('配置表工作台', const [
                        '顶部标签切换页面；中间左侧条目列表、右侧字段表单；右栏可切换本页配置表。',
                      ]),
                      _helpSection('右下角快捷工具', const [
                        '常驻托盘提供 操作说明 / 模组管理 / 设置 的快捷入口，'
                            '点最下方箭头可收起或展开；AI 助手是右下角的圆形按钮。',
                      ]),
                      _helpSection('常用快捷键', const [
                        'Ctrl+Z / Ctrl+Y：撤销 / 重做（配置表文档）',
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
