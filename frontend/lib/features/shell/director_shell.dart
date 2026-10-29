import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/api_client.dart';
import '../../core/app_command.dart';
import '../../core/app_dialogs.dart';
import '../../core/app_theme.dart';
import '../../core/mode_picker.dart';
import '../../core/models.dart';
import '../../core/motion.dart';
import '../../core/plugin_state.dart';
import '../../core/responsive.dart';
import '../../core/section_header.dart';
import '../../core/ui_mode.dart';
import '../../core/editor_leave_guard.dart';
import '../base/base_search_page.dart';
import '../blocks/blocks_workbench.dart';
import '../bugfix/bugfix_panel.dart';
import '../cloud/cloud_page.dart';
import '../chats/idle_chat_workbench.dart';
import '../editor/cfg_display_names.dart';
import '../editor/editor_controller.dart';
import '../editor/schema_editor_view.dart';
import '../files/file_tree_page.dart';
import '../goals/goals_workbench.dart';
import '../nocode/effect_health_panel.dart';
import '../external/external_dialogues_workbench.dart';
import '../mods/mods_page.dart';
import '../pages/pages_catalog.dart';
import '../pages/workbench_registry.dart';
import '../pages/workshop_features.dart';
import '../plugins/plugins_page.dart';
import '../space/space_workbench.dart';
import '../warehouse/warehouse_workbench.dart';
import '../resources/resources_page.dart';
import '../resources/image_asset_picker.dart' show refreshBgIdKeyMap;
import '../settings/settings_page.dart';
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
  json('高级编辑器', FluentIcons.code_24_regular, '直接查看与编辑原始配置数据'),
  external('外部对话', FluentIcons.comment_multiple_24_regular, '送礼 / 小游戏 / 闲聊的对白入口'),
  messages('手机消息', FluentIcons.chat_multiple_24_regular, '短信对话与回复分支'),
  goals('目标工作台', FluentIcons.target_24_regular, '目标列表 / 游戏内预览 / 要求与奖励'),
  blocks('积木库', FluentIcons.apps_list_24_regular, '条件 / 效果 / 指令的目录与搭建'),
  events('事件工作台', FluentIcons.calendar_ltr_24_regular, '事件触发 / 对白入口 / 选项'),
  chats('闲聊', FluentIcons.person_chat_24_regular, '人物闲聊 / 进度文字 / 线性对白'),
  featureTable('功能配置', FluentIcons.table_24_regular, '功能驱动的配置表工作台'),
  resources('素材库', FluentIcons.box_24_regular, '贴图 / 音频 / 立绘等资产'),
  files('文件', FluentIcons.folder_24_regular, '模组文件树与文本编辑'),
  plugins('插件', FluentIcons.puzzle_piece_24_regular, '声明型插件与动态面板'),
  cloud('云同步', FluentIcons.cloud_24_regular, 'WebDAV / OpenList 等驱动'),
  mods('模组管理', FluentIcons.apps_24_regular, '新建 / 切换 / 导入导出模组'),
  search('剧情库检索', FluentIcons.search_24_regular, '原版事件与台词全文检索'),
  effectHealth('拆解体检', FluentIcons.stethoscope_24_regular, '批量检查效果 / 条件代码的拆解情况'),
  bugfix('扫描修复', FluentIcons.wrench_24_regular, '配置体检与自动修复');

  const _DirectorFeature(this.label, this.icon, this.description);

  final String label;
  final IconData icon;
  final String description;
}

/// 主页功能卡片的归类。
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

/// 顶部「功能」下拉里的一项（分组标题项不可跳转，仅作分隔）。
class _FeatureMenuItem {
  const _FeatureMenuItem(this.value, this.label, {this.section = false});

  final String value;
  final String label;
  final bool section;
}

/// 主页功能卡片的图标：按主表映射到最贴切的 Fluent 图标。
IconData _featureIconOf(WorkshopFeature f) {
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

/// 一条壳内导航历史（N10）：功能 + 可选的「功能配置表」上下文。
///
/// `featureTable` 是功能驱动的配置表工作台——同一个功能视图承载所有功能，
/// 历史只记功能名不足以还原「当时在看哪个功能、哪张表」。
class _NavEntry {
  const _NavEntry(this.feature, {this.featureOwner, this.cfg});

  final _DirectorFeature feature;

  /// `featureTable` 当时浏览的功能（其余功能恒为 null）。
  final WorkshopFeature? featureOwner;

  /// 该功能选中的配置表。
  final String? cfg;
}

class _DirectorShellState extends State<DirectorShell> {
  static const _favoritesKey = 'director_home_favorites_v1';

  /// 进入导演布局先在主页，而不是直接落到某个编辑器。
  _DirectorFeature _feature = _DirectorFeature.home;

  /// 访问过的功能（懒加载保活：切走再切回不丢页面状态）。
  final Set<_DirectorFeature> _visited = {_DirectorFeature.home};

  /// 壳内视图历史（顶部前进/后退）。
  final List<_NavEntry> _history = [const _NavEntry(_DirectorFeature.home)];
  int _historyCursor = 0;

  /// 每个功能的刷新计数，用于单独重挂当前视图。
  final Map<_DirectorFeature, int> _refreshTokens = {};

  /// 主页点非专属工作台的功能卡片时，进入的功能驱动配置表工作台。
  WorkshopFeature? _activeFeature;

  /// 该功能当前选中的配置表。
  String? _activeFeatureCfg;

  /// 物品仓库的初始模式（'item' / 'shop'），随主页卡片切换。
  String _warehouseMode = 'item';

  /// 素材库的初始页签（tex / aud / bg …），随主页卡片切换。
  String _resourcesTab = 'tex';

  final Set<String> _favorites = {};

  bool _cornersCollapsed = false;
  bool _helpOpen = false;

  /// A2 命令面板（Ctrl+K）在本壳的落地：功能视图 / 剧情库检索 / 切模组，
  /// 外加导演壳自己的常用动作（主页 / 云同步 / 素材库 …）。壳没有左侧栏，
  /// 面板类动作由 `buildAppCommands(includePaneActions: false)` 自动跳过。
  AppCommandHost? _registeredHost;

  @override
  void initState() {
    super.initState();
    _loadFavorites();
    // 顶部工程栏的模组下拉以 state.mods 为数据源，而它只在启动引导时从
    // /api/state 取过一份快照。从源码启动时工作区/模组列表可能晚一步才
    // 就绪（或引导快照为空），下拉里就只剩当前模组一个条目、无法切换；
    // 进入导演壳时主动拉一次 /api/mods，保证下拉始终是完整列表。
    unawaited(_refreshMods());
    _registeredHost = _makeCommandHost();
    widget.shell.registerCommandHost(_registeredHost!);
  }

  @override
  void dispose() {
    final host = _registeredHost;
    if (host != null) widget.shell.unregisterCommandHost(host);
    super.dispose();
  }

  AppCommand _cmd(
    String id,
    String label,
    String description,
    IconData icon,
    VoidCallback onRun,
  ) {
    return AppCommand(
      id: 'action:director-$id',
      label: label,
      description: description,
      keywords: '导演 工作台 $label',
      category: AppCommandCategory.action,
      icon: icon,
      run: (context) async => onRun(),
    );
  }

  AppCommandHost _makeCommandHost() {
    return AppCommandHost(
      // 页面 → 对应的功能（工作台或功能配置表），与顶栏「功能」下拉同一口径。
      openPage: (pageId) {
        final page = pageById(pageId);
        if (page == null) return;
        final f = featureByTable(page.defaultCfg) ??
            (page.cfgNames.isEmpty ? null : featureByTable(page.cfgNames.first));
        if (f != null) {
          _openFeature(f);
          return;
        }
        _go(_DirectorFeature.featureTable);
      },
      openFeature: (id) {
        final f = featureById(id);
        if (f != null) _openFeature(f);
      },
      openSearch: () => _go(_DirectorFeature.search),
      selectMod: _selectMod,
      extraActions: [
        _cmd('home', '导演主页', '功能总览与快捷入口', FluentIcons.home_24_regular,
            () => _go(_DirectorFeature.home)),
        _cmd('studio', '剧情舞台', '对话线 / 舞台编辑 / 人物与表情',
            FluentIcons.production_24_regular, () => _go(_DirectorFeature.studio)),
        _cmd('events', '事件工作台', '事件触发 / 对白入口 / 选项',
            FluentIcons.calendar_ltr_24_regular, () => _go(_DirectorFeature.events)),
        _cmd('blocks', '积木库', '条件 / 效果 / 指令的目录与搭建',
            FluentIcons.apps_list_24_regular, () => _go(_DirectorFeature.blocks)),
        _cmd('resources', '素材库', '贴图 / 音频 / 立绘等资产',
            FluentIcons.box_24_regular, () => _go(_DirectorFeature.resources)),
        _cmd('files', '文件', '模组文件树与文本编辑',
            FluentIcons.folder_24_regular, () => _go(_DirectorFeature.files)),
        _cmd('plugins', '插件', '声明型插件与动态面板',
            FluentIcons.puzzle_piece_24_regular, () => _go(_DirectorFeature.plugins)),
        _cmd('cloud', '云同步', 'WebDAV / OpenList 等驱动',
            FluentIcons.cloud_24_regular, () => _go(_DirectorFeature.cloud)),
        _cmd('mods', '模组管理', '新建 / 切换 / 导入导出模组',
            FluentIcons.apps_24_regular, _openMods),
        _cmd('bugfix', '扫描修复', '配置体检与自动修复',
            FluentIcons.wrench_24_regular, () => _go(_DirectorFeature.bugfix)),
        _cmd('effectHealth', '拆解体检', '批量检查效果 / 条件代码的拆解情况',
            FluentIcons.stethoscope_24_regular,
            () => _go(_DirectorFeature.effectHealth)),
        _cmd('settings', '设置', '偏好 / 外观 / 简易模式 / 模型',
            FluentIcons.settings_24_regular, _openSettings),
      ],
    );
  }

  /// 拉取最新模组列表并广播（失败静默：旧后端无此端点或后端未就绪时
  /// 保留现有下拉内容，不打扰用户）。
  Future<void> _refreshMods() async {
    try {
      final r = await ApiClient.instance.get('/api/mods');
      if (!mounted) return;
      final list = r['mods'];
      if (list is List) {
        widget.state.setMods([
          for (final m in list)
            if (m is Map) ModInfo.fromJson(Map<String, dynamic>.from(m)),
        ]);
      }
    } catch (_) {}
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

  void _go(_DirectorFeature f, {WorkshopFeature? owner, String? cfg}) {
    // 与栈顶同一条目（同功能、同配置表上下文）：只收起帮助层，不重复入栈
    // （如反复点同一张主页卡片、同一张表）。
    final top = _history[_historyCursor];
    if (f == _feature &&
        top.feature == f &&
        top.featureOwner == owner &&
        top.cfg == cfg) {
      setState(() => _helpOpen = false);
      return;
    }
    setState(() {
      _feature = f;
      _visited.add(f);
      _history.removeRange(_historyCursor + 1, _history.length);
      _history.add(_NavEntry(f, featureOwner: owner, cfg: cfg));
      _historyCursor = _history.length - 1;
      _helpOpen = false;
    });
  }


  /// 进入某个功能的配置表工作台（顶部功能标题 + 多表分类标签）。
  void _openFeatureTable(WorkshopFeature feature, [String? cfg]) {
    final target =
        cfg ?? feature.primaryTable ?? (feature.tables.isNotEmpty ? feature.tables.first : null);
    if (target == null) return;
    setState(() {
      _activeFeature = feature;
      _activeFeatureCfg = target;
      _refreshTokens[_DirectorFeature.featureTable] =
          (_refreshTokens[_DirectorFeature.featureTable] ?? 0) + 1;
    });
    _go(_DirectorFeature.featureTable, owner: feature, cfg: target);
  }

  /// 进入物品仓库：'item' 编辑物品与书籍，'shop' 编辑商店与商品。
  void _openWarehouse(String mode) {
    setState(() => _warehouseMode = mode);
    _go(_DirectorFeature.warehouse);
  }

  /// 进入素材库并直接落到对应分类页签。
  void _openResources(String tab) {
    setState(() => _resourcesTab = tab);
    _go(_DirectorFeature.resources);
  }

  void _back() {
    if (_historyCursor <= 0) return;
    setState(() {
      _historyCursor--;
      _applyHistoryEntry(_history[_historyCursor]);
    });
  }

  void _forward() {
    if (_historyCursor >= _history.length - 1) return;
    setState(() {
      _historyCursor++;
      _applyHistoryEntry(_history[_historyCursor]);
    });
  }

  /// 应用一条历史（光标已移入）：恢复功能；功能配置表条目还要恢复当时的
  /// 工作台与配置表（N10），上下文变化时重挂视图（token 自增）回到那张表。
  void _applyHistoryEntry(_NavEntry e) {
    _feature = e.feature;
    _visited.add(e.feature);
    _helpOpen = false;
    if (e.feature != _DirectorFeature.featureTable) return;
    final changed =
        e.featureOwner != _activeFeature || e.cfg != _activeFeatureCfg;
    _activeFeature = e.featureOwner;
    _activeFeatureCfg = e.cfg;
    if (changed) {
      _refreshTokens[_DirectorFeature.featureTable] =
          (_refreshTokens[_DirectorFeature.featureTable] ?? 0) + 1;
    }
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
      // 合并元数据（bgKeys/charKeys）的合并口径随模组变化：不刷新的话舞台
      // 背景/立绘会一直用上一个模组的映射，找得到的显示错图、找不到的永远
      // 停在占位图上（旧实现只有用户手动「刷新」重挂工作台才兜回来）。
      refreshBgIdKeyMap();
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

  Future<void> _deleteCurrentMod() async {
    final cur = widget.state.modName;
    if (cur.isEmpty) {
      fluent.displayInfoBar(
        context,
        builder: (ctx, close) => const fluent.InfoBar(
          title: Text('当前未选择模组'),
          severity: fluent.InfoBarSeverity.warning,
        ),
      );
      return;
    }
    final mod = widget.state.mods.where((m) => m.name == cur).firstOrNull;
    if (mod != null) {
      final p = mod.root.replaceAll('\\', '/').toLowerCase();
      if (p.contains('/steamapps/workshop/content/3503380889')) {
        fluent.displayInfoBar(
          context,
          builder: (ctx, close) => const fluent.InfoBar(
            title: Text('无法删除'),
            content: Text('创意工坊订阅内容请在 Steam 客户端取消订阅，不能直接删除'),
            severity: fluent.InfoBarSeverity.error,
          ),
        );
        return;
      }
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AppContentDialog(
        title: const Text('删除模组'),
        content: Text('确定删除模组「${widget.state.currentModDisplayName}」吗？此操作不可恢复。'),
        actions: [
          fluent.Button(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          fluent.FilledButton(
            style: fluent.ButtonStyle(
              backgroundColor: WidgetStatePropertyAll(palette.danger),
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ApiClient.instance.post('/api/mods/delete', body: {'name': cur});
      widget.state.setMod('', '');
      await _refreshMods();
    } catch (e) {
      if (mounted) {
        fluent.displayInfoBar(
          context,
          builder: (ctx, close) => fluent.InfoBar(
            title: const Text('删除失败'),
            content: Text(e.toString()),
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
            // N11：AI 宿主与创作/经典壳一致——内容区够宽时右侧并排停靠
            // （可拖拽调宽），不足时浮层化；不再无条件悬浮在内容之上。
            Expanded(
              child: AiDockHost(
                state: widget.state,
                shell: widget.shell,
                onOpenSettings: _openSettings,
                panelBackground: palette.panel,
                content: _buildContentStack(),
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

    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 1000;
        final modW = compact ? 130.0 : 200.0;
        final featureW = compact ? 110.0 : 150.0;
        final funcW = compact ? 100.0 : 150.0;
        final gap = compact ? 4.0 : 8.0;

        return Container(
          height: 64,
          padding: EdgeInsets.symmetric(horizontal: compact ? 8 : 14),
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
              _brand(compact: compact),
              SizedBox(width: gap),
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
              SizedBox(width: gap),
              SizedBox(
                width: modW,
                child: fluent.ComboBox<String>(
                  value: curMod.isNotEmpty ? curMod : null,
                  isExpanded: true,
                  placeholder: const Text('选择模组', style: TextStyle(fontSize: 12)),
                  items: [
                    for (final m in mods)
                      fluent.ComboBoxItem(
                        value: m.name,
                        child: Text(
                          m.displayName,
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
              SizedBox(width: gap),
              SizedBox(
                width: featureW,
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
              SizedBox(width: gap),
              // 「功能」下拉：按「★ 收藏」与「全部功能」分组，快速跳转到任意功能卡片。
              SizedBox(
                width: funcW,
                child: fluent.ComboBox<String>(
                  value: _featureId,
                  isExpanded: true,
                  placeholder: const Text('功能', style: TextStyle(fontSize: 12)),
                  items: [
                    for (final g in _featureMenuGroups())
                      fluent.ComboBoxItem(
                        value: g.value,
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                g.label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight:
                                      g.section ? FontWeight.w600 : FontWeight.normal,
                                  color: g.section
                                      ? palette.goldText
                                      : palette.textPrimary,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                  onChanged: (v) {
                    if (v == null) return;
                    final f = featureById(v);
                    if (f != null) _openFeature(f);
                  },
                ),
              ),
              const SizedBox(width: 4),
              _IconPill(
                icon: FluentIcons.arrow_sync_24_regular,
                tooltip: '刷新当前视图',
                onTap: _refresh,
              ),
              const SizedBox(width: 4),
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
                    // 积木库 / 事件工作台：主页卡片网格按对标产品净化为 52 张
                    // 业务卡片（见 plan/director_mode_sync_plan.md），这两个
                    // 独立工作台改由此处（顶部工程栏）常驻入口，避免能力丢失。
                    _HeaderAction(
                      icon: FluentIcons.apps_list_24_regular,
                      label: '积木库',
                      selected: _feature == _DirectorFeature.blocks,
                      onTap: () => _go(_DirectorFeature.blocks),
                    ),
                    _HeaderAction(
                      icon: FluentIcons.calendar_ltr_24_regular,
                      label: '事件',
                      selected: _feature == _DirectorFeature.events,
                      onTap: () => _go(_DirectorFeature.events),
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
                      icon: uiModeIcon(widget.uiMode),
                      label: widget.uiMode.label,
                      onTap: () async {
                        final picked =
                            await showModePicker(context, widget.uiMode);
                        if (picked != null) widget.onUiModeChanged(picked);
                      },
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  },
);
}

  Widget _brand({bool compact = false}) {
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
        const SizedBox(width: 8),
        Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '学生时代模组编辑器',
              style: TextStyle(
                fontSize: compact ? 12 : 14,
                fontWeight: FontWeight.w600,
                color: palette.textHigh,
                letterSpacing: 0.03,
              ),
            ),
            const SizedBox(height: 1),
            Text(
              '导演工作台',
              style: TextStyle(
                fontSize: compact ? 9 : 10,
                color: palette.goldText,
                letterSpacing: 0.08,
              ),
            ),
          ],
        ),
      ],
    );
  }

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
    // 快捷托盘随内容区（在 AiDockHost 之内）：停靠态 AI 在右侧独立列，
    // 托盘不会浮到它的输入区上。
    children.add(_buildCornerDock());
    return Stack(fit: StackFit.expand, children: children);
  }

  Widget _childFor(_DirectorFeature f) {
    final state = widget.state;
    final controller = widget.shell.controller;
    // 重叠的标准工作台统一经注册表构造（workbench_registry.dart），
    // 与移动端「页面」tab 共享同一份参数装配，避免两处各写一遍。
    final deps = WorkbenchDeps(
      state: state,
      onOpenSearch: () => _go(_DirectorFeature.search),
      onPreview: (evtId) => openDocGuarded(
        context,
        controller,
        OpenDoc.preview(eventId: evtId),
        action: '打开预览',
      ),
      onOpenStudio: () => _go(_DirectorFeature.studio),
    );
    switch (f) {
      case _DirectorFeature.home:
        return _DirectorHome(
          modName: state.modName.isEmpty
              ? '(未加载/空白)'
              : state.currentModDisplayName,
          entries: _homeEntries(),
          favorites: _favorites,
          onToggleFavorite: _toggleFavorite,
          onOpenMods: _openMods,
          onOpenResources: () => _openResources('tex'),
          onOpenAdvanced: () => _go(_DirectorFeature.json),
          onDeleteMod: _deleteCurrentMod,
        );
      case _DirectorFeature.studio:
        return kWorkbenchRegistry['story']!.build(deps);
      case _DirectorFeature.person:
        return kWorkbenchRegistry['person']!.build(deps);
      case _DirectorFeature.social:
        return kWorkbenchRegistry['social']!.build(deps);
      case _DirectorFeature.minigames:
        return kWorkbenchRegistry['function']!.build(deps);
      case _DirectorFeature.json:
        return kWorkbenchRegistry['json']!.build(deps);
      case _DirectorFeature.messages:
        return kWorkbenchRegistry['messages']!.build(deps);
      case _DirectorFeature.events:
        return kWorkbenchRegistry['evt']!.build(deps);
      case _DirectorFeature.space:
        return SpaceWorkbench(
          state: state,
          onOpenSearch: () => _go(_DirectorFeature.search),
        );
      case _DirectorFeature.warehouse:
        return WarehouseWorkbench(
          state: state,
          initialMode: _warehouseMode,
          onOpenSearch: () => _go(_DirectorFeature.search),
        );
      case _DirectorFeature.external:
        return ExternalDialoguesWorkbench(
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
      case _DirectorFeature.chats:
        return IdleChatWorkbench(
          state: state,
          onOpenSearch: () => _go(_DirectorFeature.search),
        );
      case _DirectorFeature.featureTable:
        final feature = _activeFeature ??
            featureById('memories') ??
            kWorkshopFeatures.first;
        final cfgName = _activeFeatureCfg ??
            feature.primaryTable ??
            (feature.tables.isNotEmpty ? feature.tables.first : '');
        return DirectorFeatureTableView(
          key: ValueKey('director-feature-${feature.id}-$cfgName'),
          state: state,
          feature: feature,
          initialCfg: cfgName,
          onCfgChanged: (cfg) {
            setState(() {
              _activeFeatureCfg = cfg;
              final top = _history[_historyCursor];
              if (top.feature == _DirectorFeature.featureTable) {
                _history[_historyCursor] = _NavEntry(
                  top.feature,
                  featureOwner: top.featureOwner,
                  cfg: cfg,
                );
              }
            });
          },
          onHome: () {
            setState(() {
              _activeFeature = null;
              _activeFeatureCfg = null;
            });
            _go(_DirectorFeature.home);
          },
          onPreview: (evtId) => openDocGuarded(
            context,
            controller,
            OpenDoc.preview(eventId: evtId),
            action: '打开预览',
          ),
          onOpenSearch: () => _go(_DirectorFeature.search),
        );
      case _DirectorFeature.resources:
        return _DirectorFrame(
          feature: f,
          onHome: () => _go(_DirectorFeature.home),
          child: ResourcesPage(state: state, initialTab: _resourcesTab),
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
      case _DirectorFeature.effectHealth:
        return _DirectorFrame(
          feature: f,
          onHome: () => _go(_DirectorFeature.home),
          child: EffectHealthPanel(
            state: state,
            onJump: (field) => openDocGuarded(
              context,
              controller,
              OpenDoc.cfg(cfgName: field.cfg),
            ),
          ),
        );
      case _DirectorFeature.bugfix:
        return _DirectorFrame(
          feature: f,
          onHome: () => _go(_DirectorFeature.home),
          child: BugfixPanel(state: state),
        );
    }
  }

  /// 当前正在浏览的功能卡片 id（用于顶部「功能」下拉回显）。
  String? get _featureId {
    if (_feature == _DirectorFeature.featureTable) return _activeFeature?.id;
    return null;
  }

  /// 顶部「功能」下拉的条目：★ 收藏 分组 + 全部功能 分组。
  List<_FeatureMenuItem> _featureMenuGroups() {
    final out = <_FeatureMenuItem>[];
    final favs = kWorkshopFeatures.where((f) => f.native && _favorites.contains(f.id));
    final all = kWorkshopFeatures.where((f) => f.native);
    out.add(const _FeatureMenuItem('__fav', '★ 收藏', section: true));
    for (final f in favs) {
      out.add(_FeatureMenuItem(f.id, f.label));
    }
    out.add(const _FeatureMenuItem('__all', '全部功能', section: true));
    for (final f in all) {
      out.add(_FeatureMenuItem(f.id, f.label));
    }
    return out;
  }

  /// 主页卡片：严格对齐参考产品「工坊主页」的功能目录。
  ///
  /// 只渲染 `native != false` 的业务功能卡片（21 内置 + 27 拓展）与 4 张素材
  /// 卡片；「模组信息」「游戏素材」等管理项不在卡片网格里重复出现，它们归入
  /// 底部「模组管理」工具栏与顶部工程栏。
  List<_HomeEntry> _homeEntries() {
    return <_HomeEntry>[
      for (final f in kWorkshopFeatures)
        if (f.native)
          _HomeEntry(
            id: f.id,
            title: f.label,
            description: f.description,
            hint: _featureHint(f),
            icon: _featureIcon(f),
            category: _featureCategory(f),
            onOpen: () => _openFeature(f),
          ),
    ];
  }

  /// 功能卡片右下角的计数：素材卡片显示「素材目录」，其余显示覆盖的配置表数量。
  String _featureHint(WorkshopFeature f) {
    if (f.isLibrary) return '素材目录';
    if (f.tables.isEmpty) return '入口';
    return '${f.tables.length} 张表';
  }

  _HomeCategory _featureCategory(WorkshopFeature f) {
    if (f.resourceOnly || f.isLibrary) return _HomeCategory.resource;
    return f.homeCategory == 'extension'
        ? _HomeCategory.extension
        : _HomeCategory.builtin;
  }

  IconData _featureIcon(WorkshopFeature f) => _featureIconOf(f);

  /// 打开一条主页功能：有专属工作台的走工作台，素材卡片直达素材分类，
  /// 其余进入功能驱动的配置表工作台（多表功能带分类标签栏）。
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
    // 素材卡片：直达对应素材分类。
    final library = f.library;
    if (library != null) {
      _openResources(switch (library) {
        'background' => 'bg',
        'audio' => 'aud',
        _ => 'tex',
      });
      return;
    }
    // 专属工作台。
    switch (f.id) {
      case 'persons':
        _go(_DirectorFeature.person);
        return;
      case 'items':
        _openWarehouse('item');
        return;
      case 'shops':
        _openWarehouse('shop');
        return;
      case 'posts':
      case 'comments':
        _go(_DirectorFeature.social);
        return;
      case 'goals':
        _go(_DirectorFeature.goals);
        return;
      case 'profiles':
        _go(_DirectorFeature.space);
        return;
      case 'messages':
        _go(_DirectorFeature.messages);
        return;
      case 'minigames':
        _go(_DirectorFeature.minigames);
        return;
    }
    _openFeatureTable(f);
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
      // AI 收起时内容区右下角有一个 44px 悬浮按钮（AiDockHost 收起态），
      // 快捷托盘上移让位；AI 展开时按钮消失，托盘回到右下角。
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
            child: SectionHeader(
              leading: _HomeBackLink(onTap: onHome),
              icon: feature.icon,
              title: feature.label,
              description: feature.description,
              iconColor: accentColor,
              compact: true,
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
    required this.onOpenResources,
    required this.onOpenAdvanced,
    required this.onDeleteMod,
  });

  final String modName;
  final List<_HomeEntry> entries;
  final Set<String> favorites;
  final ValueChanged<String> onToggleFavorite;
  final VoidCallback onOpenMods;
  final VoidCallback onOpenResources;
  final VoidCallback onOpenAdvanced;
  final VoidCallback onDeleteMod;

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
        .where((e) => widget.favorites.contains(e.id) && e.category != _HomeCategory.resource)
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
        .where((e) => e.category == _HomeCategory.resource)
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
                onTap: widget.onOpenResources,
              ),
              _ToolButton(
                label: '高级配置',
                icon: FluentIcons.code_24_regular,
                onTap: widget.onOpenAdvanced,
              ),
              _ToolButton(
                label: '删除模组',
                icon: FluentIcons.dismiss_24_regular,
                danger: true,
                onTap: widget.onDeleteMod,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

typedef DirectorHomeCard = _HomeCard;

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
                      // 给右上角星标留位（素材卡片不可收藏，不留位）
                      padding: EdgeInsets.only(
                        right: widget.entry.category == _HomeCategory.resource
                            ? 0
                            : 30,
                      ),
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
          if (widget.entry.category != _HomeCategory.resource)
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

/// 功能驱动的配置表工作台：顶部功能标题 + 多表分类标签栏 + Schema 编辑器。
///
/// 对标参考产品的工坊工作台：点某个功能卡片（如「职业」「早报与热搜」）后，
/// 顶部显示 `← 全部功能` 面包屑、功能图标、功能标题与说明；功能包含多张表时
/// 提供横向分类切换标签栏（Module Tabs），点击无缝切换表，保留搜索、分页与
/// 表单编辑。

class DirectorFeatureTableView extends StatefulWidget {
  const DirectorFeatureTableView({
    super.key,
    required this.state,
    required this.feature,
    required this.onHome,
    this.initialCfg,
    this.onCfgChanged,
    this.onPreview,
    this.onOpenSearch,
  });

  final AppState state;
  final WorkshopFeature feature;
  final String? initialCfg;

  /// 表页签切换回调（N10）：壳用它把当前配置表同步进历史栈顶，
  /// 后退/前进才能回到用户最后查看的那张表。
  final ValueChanged<String>? onCfgChanged;
  final VoidCallback onHome;
  final ValueChanged<String>? onPreview;
  final VoidCallback? onOpenSearch;

  @override
  State<DirectorFeatureTableView> createState() => _DirectorFeatureTableViewState();
}

class _DirectorFeatureTableViewState extends State<DirectorFeatureTableView> {
  late String _cfgName = widget.initialCfg ??
      widget.feature.primaryTable ??
      (widget.feature.tables.isNotEmpty ? widget.feature.tables.first : '');

  @override
  void didUpdateWidget(covariant DirectorFeatureTableView old) {
    super.didUpdateWidget(old);
    if (old.initialCfg != widget.initialCfg ||
        old.feature.id != widget.feature.id) {
      setState(() {
        _cfgName = widget.initialCfg ??
            widget.feature.primaryTable ??
            (widget.feature.tables.isNotEmpty ? widget.feature.tables.first : '');
      });
    }
  }

  String _labelOf(String cfg) =>
      widget.feature.tableLabels[cfg] ?? cfgDisplayName(cfg);

  @override
  Widget build(BuildContext context) {
    final feature = widget.feature;
    final showTabs = feature.tables.length > 1;
    return Container(
      color: palette.bgDeep2,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _header(feature),
          if (showTabs) _moduleTabs(feature),
          Expanded(
            child: _cfgName.isEmpty
                ? const SizedBox.shrink()
                : SchemaEditorView(
                    // key 按 cfg 区分：切表时 State 必须重建，否则编辑区停留在旧表。
                    key: ValueKey('director-feature-schema-$_cfgName'),
                    state: widget.state,
                    cfgName: _cfgName,
                    onPreview: widget.onPreview,
                    onOpenSearch: widget.onOpenSearch,
                  ),
          ),
        ],
      ),
    );
  }

  Widget _header(WorkshopFeature feature) {
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
          Icon(_featureIconOf(feature), size: 15, color: accentColor),
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
    );
  }

  /// Module Tabs：功能包含多张表时的横向分类切换栏。
  Widget _moduleTabs(WorkshopFeature feature) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      decoration: BoxDecoration(
        color: palette.panel,
        border: Border(bottom: BorderSide(color: palette.border)),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (final cfg in feature.tables) ...[
              _ModuleTab(
                label: _labelOf(cfg),
                selected: cfg == _cfgName,
                onTap: () async {
                  if (cfg == _cfgName) return;
                  // U1：切表会以新 key 重建 SchemaEditorView，旧表内存改动
                  // 必须先确认（保存 / 放弃 / 取消）。
                  final ok = await confirmLeaveDirty(
                    context,
                    action: '切换配置表',
                    // 切表后旧编辑器被重建；脏信号来自编辑器句柄时「放弃」
                    // 即销毁视图，无需额外清理。
                    onDiscard: () {},
                  );
                  if (!ok || !mounted) return;
                  setState(() => _cfgName = cfg);
                  widget.onCfgChanged?.call(cfg);
                },
              ),
              const SizedBox(width: 6),
            ],
          ],
        ),
      ),
    );
  }
}

/// 多表分类标签按钮。
class _ModuleTab extends StatefulWidget {
  const _ModuleTab({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_ModuleTab> createState() => _ModuleTabState();
}

class _ModuleTabState extends State<_ModuleTab> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: AppMotion.fast,
          curve: AppMotion.easeOut,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: widget.selected
                ? accentColor.withValues(alpha: 0.14)
                : _hover
                ? palette.card
                : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: widget.selected
                  ? accentColor.withValues(alpha: 0.45)
                  : _hover
                  ? palette.border
                  : Colors.transparent,
            ),
          ),
          child: Text(
            widget.label,
            style: TextStyle(
              fontSize: 12,
              fontWeight:
                  widget.selected ? FontWeight.w600 : FontWeight.normal,
              color: widget.selected ? palette.textHigh : palette.textSecondary,
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
                        '左侧为品牌与视图历史（前进 / 后退），随后是当前模组、功能模块与「功能」下拉，'
                            '点右侧「刷新」可重新载入当前视图。',
                        '「功能」下拉按「★ 收藏」与「全部功能」分组，可快速跳转到任意功能卡片。',
                        '右侧为常用入口：主页、模组管理、云同步、操作说明、设置、AI 与界面布局切换。',
                      ]),
                      _helpSection('主页与功能模块', const [
                        '进入导演工作台先到主页：搜索、收藏并选择要编辑的功能。',
                        '游戏内置编辑器可编辑项：剧情舞台与各配置页面。',
                        '编辑器拓展 / 素材库 / 模组管理：玩法配置、素材与模组维护。',
                        '独立通用工具（文件、云同步、剧情检索、扫描修复、积木库）在顶部工程栏与右下角托盘中随时可打开。',
                      ]),
                      _helpSection('配置表工作台', const [
                        '点功能卡片进入该功能的工作台：顶部显示功能名称，多表功能提供分类标签栏，'
                            '点标签可无缝切换所属各表；左侧条目列表、右侧字段表单。',
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
