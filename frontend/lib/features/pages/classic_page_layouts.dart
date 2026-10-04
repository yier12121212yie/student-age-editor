import 'package:flutter/material.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../../core/api_client.dart';
import '../../core/models.dart';
import '../base/base_search_page.dart';
import '../editor/cfg_display_names.dart';
import '../editor/page_card.dart';
import '../editor/schema_editor_view.dart';
import '../nocode/entity_picker.dart' show RoleEntry, loadRoles;
import '../resources/image_asset_picker.dart' show TexBytesCache, TexThumb;
import '../resources/pack_manager_page.dart';
import '../story/story_director_view.dart';
import '../story/story_studio_editor.dart';
import '../story/story_transfer_dialogs.dart';
import 'pages_catalog.dart';
import '../../core/app_theme.dart';
import '../../core/app_dialogs.dart';

/// 经典布局页面体系（类友商心知版三栏/双栏工作流 + 暗黑主题）。
class ClassicPageLayouts extends StatefulWidget {
  const ClassicPageLayouts({
    super.key,
    required this.state,
    required this.page,
    required this.cfgName,
    this.onPreview,
    this.onOpenSearch,
    this.onOpenPage,
  });

  final AppState state;
  final EditorPageDef page;
  final String cfgName;
  final ValueChanged<String>? onPreview;
  final VoidCallback? onOpenSearch;

  /// 页面内跳转：从当前经典页切到另一个编辑页（如「故事」→「剧情编辑（友商风格）」）。
  /// 为空时各页面退回自身的内嵌视图。
  final ValueChanged<String>? onOpenPage;

  @override
  State<ClassicPageLayouts> createState() => _ClassicPageLayoutsState();
}

class _ClassicPageLayoutsState extends State<ClassicPageLayouts> {
  @override
  Widget build(BuildContext context) {
    switch (widget.page.id) {
      case 'person':
        return _PersonLayout(
          state: widget.state,
          onPreview: widget.onPreview,
          onOpenSearch: widget.onOpenSearch,
        );
      case 'resource':
        return _ResourceLayout(
          state: widget.state,
          onOpenSearch: widget.onOpenSearch,
        );
      case 'function':
        return _FunctionLayout(
          state: widget.state,
          onOpenSearch: widget.onOpenSearch,
        );
      case 'story':
        return _StoryLayout(
          state: widget.state,
          onPreview: widget.onPreview,
          onOpenSearch: widget.onOpenSearch,
          onOpenPage: widget.onOpenPage,
        );
      case 'story_competitor':
        return _StoryCompetitorLayout(
          state: widget.state,
          onPreview: widget.onPreview,
          onOpenSearch: widget.onOpenSearch,
          onOpenPage: widget.onOpenPage,
        );
      case 'social':
        return _SpaceEndingLayout(
          state: widget.state,
          onOpenSearch: widget.onOpenSearch,
        );
      case 'love':
        return _LoveLayout(
          state: widget.state,
          onOpenSearch: widget.onOpenSearch,
        );
      case 'official':
        return _OfficialLayout(
          state: widget.state,
          onOpenSearch: widget.onOpenSearch,
        );
      default:
        return Padding(
          padding: const EdgeInsets.all(8),
          child: SchemaEditorView(
            state: widget.state,
            cfgName: widget.cfgName,
            classic: true,
            onPreview: widget.onPreview,
            onOpenSearch: widget.onOpenSearch,
          ),
        );
    }
  }
}

// ---------------------------------------------------------------------------
// 1. 人物综合配置
// ---------------------------------------------------------------------------
class _PersonLayout extends StatefulWidget {
  const _PersonLayout({
    required this.state,
    this.onPreview,
    this.onOpenSearch,
  });
  final AppState state;
  final ValueChanged<String>? onPreview;
  final VoidCallback? onOpenSearch;

  @override
  State<_PersonLayout> createState() => _PersonLayoutState();
}

class _PersonLayoutState extends State<_PersonLayout> {
  String _currentMode = 'PersonCfg';
  String? _selectedPersonId;
  int _stageIndex = 0;
  int _refreshCounter = 0;

  /// 当前选中人物的立绘数据（来自 /api/roles 的 portrait1/portrait2）。
  RoleEntry? _role;
  bool _roleLoading = false;
  int _roleLoadToken = 0;

  /// PersonCfg 只有两套立绘字段：url = 小学、url2 = 中学（见 dicts.json）。
  static const _stages = ['小学立绘', '中学立绘'];

  final _modeOptions = const [
    'PersonCfg',
    'PersonGrowCfg',
    'PersonAttrCfg',
    'PersonStateCfg',
    'TraitsCfg',
  ];

  /// 选中人物：拉取其立绘 key（/api/roles 的 portrait1/portrait2）。
  void _select(String? id) {
    if (id == _selectedPersonId) return;
    setState(() {
      _selectedPersonId = id;
      _stageIndex = 0;
    });
    if (id == null || id.isEmpty) {
      setState(() {
        _role = null;
        _roleLoading = false;
      });
      return;
    }
    _loadRole(id);
  }

  Future<void> _loadRole(String id) async {
    final token = ++_roleLoadToken;
    setState(() => _roleLoading = true);
    final roles = await loadRoles(id);
    if (!mounted || token != _roleLoadToken) return;
    RoleEntry? hit;
    for (final r in roles) {
      if (r.id == id) {
        hit = r;
        break;
      }
    }
    setState(() {
      _role = hit;
      _roleLoading = false;
    });
  }

  /// 当前阶段对应的立绘 key（空串 = 该阶段无立绘）。
  String get _stagePortraitKey {
    final r = _role;
    if (r == null) return '';
    return _stageIndex == 0 ? r.portrait1 : r.portrait2;
  }

  /// 打开资源包管理页安装「人物图片资源扩展」；返回后清缓存强制重取，
  /// 让刚装好的立绘立即可见（TexBytesCache 会把失败结果缓存为 null）。
  Future<void> _openPackManager() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PackManagerPage(state: widget.state),
      ),
    );
    if (!mounted) return;
    TexBytesCache.clear();
    setState(() => _refreshCounter++);
  }

  /// 人物资源库主区：选中人物的当前阶段立绘；无图给空态与安装入口。
  Widget _portraitPreview() {
    if (_selectedPersonId == null) {
      return _portraitEmpty(
        icon: FluentIcons.person_24_regular,
        title: '暂无立绘预览',
        subtitle: '从下方角色列表选择人物',
      );
    }
    if (_roleLoading) {
      return const Center(
        child: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    final key = _stagePortraitKey;
    if (key.isEmpty) {
      return _portraitEmpty(
        icon: FluentIcons.image_24_regular,
        title: '角色 [$_selectedPersonId] 暂无${_stages[_stageIndex]}',
        subtitle: '可安装「人物图片资源扩展」后查看',
        action: true,
      );
    }
    final name = _role?.name ?? '';
    return Column(
      children: [
        if (name.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 12,
                  color: palette.textHigh,
                  fontWeight: FontWeight.w600),
            ),
          ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(6),
            child: TexThumb(
              key: ValueKey('portrait_${key}_$_refreshCounter'),
              keyName: key,
              width: double.infinity,
              height: double.infinity,
              fit: BoxFit.contain,
            ),
          ),
        ),
      ],
    );
  }

  Widget _portraitEmpty({
    required IconData icon,
    required String title,
    String subtitle = '',
    bool action = false,
  }) {
    // 窄面板下文字会换行撑高：用纵向滚动兜底，避免 RenderFlex 溢出。
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 36, color: palette.iconDisabled),
          const SizedBox(height: 8),
          Text(title,
              textAlign: TextAlign.center,
              style: TextStyle(color: palette.textHint, fontSize: 12)),
          if (subtitle.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(subtitle,
                textAlign: TextAlign.center,
                style: TextStyle(color: palette.textMuted, fontSize: 11)),
          ],
          if (action) ...[
            const SizedBox(height: 10),
            _ActionPill(
              label: '安装人物图片扩展',
              primary: true,
              onPressed: _openPackManager,
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _createPerson() async {
    await _promptCreateEntry(
      context: context,
      cfgName: 'PersonCfg',
      defaultIdPrefix: '10',
      onCreated: (newId) {
        _select(newId);
        setState(() => _refreshCounter++);
      },
    );
  }

  Future<void> _deletePerson() async {
    await _promptDeleteEntry(
      context: context,
      cfgName: 'PersonCfg',
      selectedId: _selectedPersonId,
      onDeleted: () {
        _select(null);
        setState(() => _refreshCounter++);
      },
    );
  }

  void _showExtractModal() {
    showDialog(
      context: context,
      builder: (ctx) {
        final size = appDialogSize(ctx, preferredWidth: 1000);
        return Dialog(
          backgroundColor: palette.panel,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: BorderSide(color: palette.surface),
          ),
          child: Container(
            width: size.width,
            height: size.height,
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Text(
                      '📖 提取原版配置 / 检索剧情库',
                      style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: palette.textHigh),
                    ),
                    const Spacer(),
                    IconButton(
                      icon: Icon(FluentIcons.dismiss_24_regular, size: 16, color: palette.textSecondary),
                      onPressed: () {
                        Navigator.of(ctx).pop();
                        setState(() => _refreshCounter++);
                      },
                    ),
                  ],
                ),
                Divider(color: palette.surface, height: 18),
                Expanded(child: BaseSearchPage(state: widget.state)),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // 顶部角色操作条
        Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: palette.panel,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: palette.surface),
          ),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                Text('🎛️ 角色操作', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: palette.textHigh)),
                const SizedBox(width: 16),
                Text('当前模式:', style: TextStyle(fontSize: 12, color: palette.textSecondary)),
                const SizedBox(width: 8),
                SizedBox(
                  width: 210,
                  height: 34,
                  child: fluent.ComboBox<String>(
                    value: _currentMode,
                    isExpanded: true,
                    items: _modeOptions.map((e) {
                      return fluent.ComboBoxItem(
                        value: e,
                        child: Text(cfgDisplayName(e), style: const TextStyle(fontSize: 12)),
                      );
                    }).toList(),
                    onChanged: (val) {
                      if (val != null) setState(() => _currentMode = val);
                    },
                  ),
                ),
                const SizedBox(width: 16),
                _ActionPill(
                  label: '恢复默认属性名',
                  onPressed: () {
                    fluent.displayInfoBar(
                      context,
                      builder: (ctx, close) => const fluent.InfoBar(
                        title: Text('已恢复默认属性名映射'),
                        severity: fluent.InfoBarSeverity.success,
                      ),
                    );
                  },
                ),
                const SizedBox(width: 6),
                _ActionPill(
                  label: '导入原版角色',
                  primary: true,
                  onPressed: _showExtractModal,
                ),
                const SizedBox(width: 6),
                _ActionPill(
                  label: '删除角色',
                  danger: true,
                  onPressed: _deletePerson,
                ),
                const SizedBox(width: 6),
                _ActionPill(
                  label: '➕ 新建人物',
                  primary: true,
                  onPressed: _createPerson,
                ),
              ],
            ),
          ),
        ),
        // 下方两栏：人物资源库 + 属性编辑
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                flex: 4,
                child: PageCard(
                  title: '📁 人物资源库',
                  child: Column(
                    children: [
                      MouseRegion(
                        cursor: SystemMouseCursors.click,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () {
                            setState(() {
                              _stageIndex = (_stageIndex + 1) % _stages.length;
                            });
                          },
                          child: Container(
                            width: double.infinity,
                            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
                            decoration: BoxDecoration(
                              color: palette.card,
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(color: palette.borderHover),
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(FluentIcons.arrow_sync_24_regular, size: 14, color: accentColor),
                                const SizedBox(width: 6),
                                Flexible(
                                  child: Text(
                                    '当前: ${_stages[_stageIndex]} (点击切换)',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(fontSize: 12, color: palette.textMid, fontWeight: FontWeight.w500),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Expanded(
                        child: Container(
                          decoration: BoxDecoration(
                            color: palette.bgAlt,
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: palette.border),
                          ),
                          child: _portraitPreview(),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text('👥 角色列表:', style: TextStyle(fontSize: 11.5, color: palette.textSecondary, fontWeight: FontWeight.w600)),
                      ),
                      const SizedBox(height: 4),
                      Expanded(
                        child: _ConfigEntryList(
                          key: ValueKey('PersonCfg_$_refreshCounter'),
                          cfgName: 'PersonCfg',
                          selectedId: _selectedPersonId,
                          onSelect: (id) => _select(id),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 7,
                child: PageCard(
                  title: '✏️ 属性编辑',
                  child: SchemaEditorView(
                    key: ValueKey('${_currentMode}_${_selectedPersonId}_$_refreshCounter'),
                    state: widget.state,
                    cfgName: _currentMode,
                    classic: true,
                    embedInCard: true,
                    selectedId: _selectedPersonId,
                    onSelectedIdChanged: (id) => _select(id),
                    onPreview: widget.onPreview,
                    onOpenSearch: widget.onOpenSearch,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 2. 资源综合配置
// ---------------------------------------------------------------------------
class _ResourceLayout extends StatefulWidget {
  const _ResourceLayout({
    required this.state,
    this.onOpenSearch,
  });
  final AppState state;
  final VoidCallback? onOpenSearch;

  @override
  State<_ResourceLayout> createState() => _ResourceLayoutState();
}

class _ResourceLayoutState extends State<_ResourceLayout> {
  String _selectedCfg = 'ItemCfg';
  String? _selectedId;
  int _refreshCounter = 0;

  final _resourceCfgs = const [
    'ItemCfg',
    'AudioCfg',
    'CGCfg',
    'ShopCfg',
    'BookCfg',
    'MovieCfg',
    'TVCfg',
  ];

  Future<void> _createItem() async {
    await _promptCreateEntry(
      context: context,
      cfgName: _selectedCfg,
      defaultIdPrefix: '100',
      onCreated: (newId) {
        setState(() {
          _selectedId = newId;
          _refreshCounter++;
        });
      },
    );
  }

  Future<void> _deleteItem() async {
    await _promptDeleteEntry(
      context: context,
      cfgName: _selectedCfg,
      selectedId: _selectedId,
      onDeleted: () {
        setState(() {
          _selectedId = null;
          _refreshCounter++;
        });
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          flex: 4,
          child: PageCard(
            title: '📦 资源分类',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  height: 34,
                  child: fluent.ComboBox<String>(
                    value: _selectedCfg,
                    isExpanded: true,
                    items: _resourceCfgs.map((e) {
                      return fluent.ComboBoxItem(
                        value: e,
                        child: Text(cfgDisplayName(e), style: const TextStyle(fontSize: 12)),
                      );
                    }).toList(),
                    onChanged: (val) {
                      if (val != null) {
                        setState(() {
                          _selectedCfg = val;
                          _selectedId = null;
                        });
                      }
                    },
                  ),
                ),
                const SizedBox(height: 8),
                Text('📝 资源列表:', style: TextStyle(fontSize: 12, color: palette.textSecondary, fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                Expanded(
                  child: _ConfigEntryList(
                    key: ValueKey('${_selectedCfg}_$_refreshCounter'),
                    cfgName: _selectedCfg,
                    selectedId: _selectedId,
                    onSelect: (id) => setState(() => _selectedId = id),
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: _ActionPill(
                        label: '➕ 新建项',
                        primary: true,
                        onPressed: _createItem,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: _ActionPill(
                        label: '🗑️ 删除项',
                        danger: true,
                        onPressed: _deleteItem,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          flex: 8,
          child: PageCard(
            title: '✨ 资源详细属性配置',
            actions: [
              _ActionPill(
                label: '恢复默认属性名',
                onPressed: () {
                  fluent.displayInfoBar(
                    context,
                    builder: (ctx, close) => const fluent.InfoBar(
                      title: Text('已恢复默认属性名映射'),
                      severity: fluent.InfoBarSeverity.success,
                    ),
                  );
                },
              ),
            ],
            child: SchemaEditorView(
              key: ValueKey('${_selectedCfg}_${_selectedId}_$_refreshCounter'),
              state: widget.state,
              cfgName: _selectedCfg,
              classic: true,
              embedInCard: true,
              selectedId: _selectedId,
              onSelectedIdChanged: (id) {
                if (_selectedId != id) {
                  setState(() => _selectedId = id);
                }
              },
              onOpenSearch: widget.onOpenSearch,
            ),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 3. 功能配置相关
// ---------------------------------------------------------------------------
class _FunctionLayout extends StatefulWidget {
  const _FunctionLayout({
    required this.state,
    this.onOpenSearch,
  });
  final AppState state;
  final VoidCallback? onOpenSearch;

  @override
  State<_FunctionLayout> createState() => _FunctionLayoutState();
}

class _FunctionLayoutState extends State<_FunctionLayout> {
  String _selectedCfg = 'ActionCfg';
  String? _selectedId;
  bool _showOriginal = false;
  bool _enableRandomAction = false;
  int _refreshCounter = 0;

  final _functionCfgs = const [
    'ActionCfg',
    'ActionTypeCfg',
    'ActionEvtCfg',
    'MinigameCfg',
    'MinigameActionCfg',
    'JobCfg',
  ];

  Future<void> _createFunctionItem() async {
    await _promptCreateEntry(
      context: context,
      cfgName: _selectedCfg,
      defaultIdPrefix: '1',
      onCreated: (newId) {
        setState(() {
          _selectedId = newId;
          _refreshCounter++;
        });
      },
    );
  }

  Future<void> _deleteFunctionItem() async {
    await _promptDeleteEntry(
      context: context,
      cfgName: _selectedCfg,
      selectedId: _selectedId,
      onDeleted: () {
        setState(() {
          _selectedId = null;
          _refreshCounter++;
        });
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          flex: 4,
          child: PageCard(
            title: '⚙️ 功能配置库',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  height: 34,
                  child: fluent.ComboBox<String>(
                    value: _selectedCfg,
                    isExpanded: true,
                    items: _functionCfgs.map((e) {
                      return fluent.ComboBoxItem(
                        value: e,
                        child: Text(cfgDisplayName(e), style: const TextStyle(fontSize: 12)),
                      );
                    }).toList(),
                    onChanged: (val) {
                      if (val != null) {
                        setState(() {
                          _selectedCfg = val;
                          _selectedId = null;
                        });
                      }
                    },
                  ),
                ),
                const SizedBox(height: 6),
                fluent.Checkbox(
                  checked: _showOriginal,
                  onChanged: (v) => setState(() => _showOriginal = v ?? false),
                  content: Flexible(
                    child: Text(
                      '显示原版资源 (修改后将覆盖至Mod)',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11.5, color: palette.textMid),
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Expanded(
                  child: _ConfigEntryList(
                    key: ValueKey('${_selectedCfg}_$_refreshCounter'),
                    cfgName: _selectedCfg,
                    selectedId: _selectedId,
                    onSelect: (id) => setState(() => _selectedId = id),
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: _ActionPill(
                        label: '➕ 新建',
                        primary: true,
                        onPressed: _createFunctionItem,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: _ActionPill(
                        label: '🗑️ 删除',
                        danger: true,
                        onPressed: _deleteFunctionItem,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          flex: 8,
          child: PageCard(
            title: '详细属性配置',
            actions: [
              _ActionPill(
                label: '恢复默认属性名',
                onPressed: () {
                  fluent.displayInfoBar(
                    context,
                    builder: (ctx, close) => const fluent.InfoBar(
                      title: Text('已恢复默认属性名映射'),
                      severity: fluent.InfoBarSeverity.success,
                    ),
                  );
                },
              ),
            ],
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: palette.tintWarn,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: palette.tintWarn),
                  ),
                  child: Text(
                    '这里是行动配置模块，你可以在这里添加新的行动或对原有行动进行修改，行动类型1是官方的场景行动(如买东西)，行动类型2是功能行动(如空间)，修改原版这两类行动需要双击解锁。',
                    style: TextStyle(fontSize: 12, color: palette.statusTan, height: 1.4),
                  ),
                ),
                fluent.Checkbox(
                  checked: _enableRandomAction,
                  onChanged: (v) => setState(() => _enableRandomAction = v ?? false),
                  content: Flexible(
                    child: Text(
                      '启用随机行动触发事件 (关联 ActionEvtCfg)',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: palette.textMid),
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Expanded(
                  child: SchemaEditorView(
                    key: ValueKey('${_selectedCfg}_${_selectedId}_$_refreshCounter'),
                    state: widget.state,
                    cfgName: _selectedCfg,
                    classic: true,
                    embedInCard: true,
                    selectedId: _selectedId,
                    onSelectedIdChanged: (id) {
                      if (_selectedId != id) {
                        setState(() => _selectedId = id);
                      }
                    },
                    onOpenSearch: widget.onOpenSearch,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 4. 剧情编辑器
// ---------------------------------------------------------------------------
class _StoryLayout extends StatefulWidget {
  const _StoryLayout({
    required this.state,
    this.onPreview,
    this.onOpenSearch,
    this.onOpenPage,
  });
  final AppState state;
  final ValueChanged<String>? onPreview;
  final VoidCallback? onOpenSearch;

  /// 跳转到独立的「剧情编辑（友商风格）」页；为空时退回页内 tab 视图。
  final ValueChanged<String>? onOpenPage;

  @override
  State<_StoryLayout> createState() => _StoryLayoutState();
}

class _StoryLayoutState extends State<_StoryLayout> {
  int _tabIndex = 0; // 0 = EvtCfg事件列表与详细配置, 1 = 剧情处理器 (TalkCfg/OptionCfg)
  String? _selectedEventId;
  int _refreshCounter = 0;

  Future<void> _createEvent() async {
    await _promptCreateEntry(
      context: context,
      cfgName: 'EvtCfg',
      defaultIdPrefix: '8000',
      onCreated: (newId) {
        setState(() {
          _selectedEventId = newId;
          _refreshCounter++;
        });
      },
    );
  }

  Future<void> _deleteEvent() async {
    await _promptDeleteEntry(
      context: context,
      cfgName: 'EvtCfg',
      selectedId: _selectedEventId,
      onDeleted: () {
        setState(() {
          _selectedEventId = null;
          _refreshCounter++;
        });
      },
    );
  }

  void _showExtractModal() {
    showDialog(
      context: context,
      builder: (ctx) {
        final size = appDialogSize(ctx, preferredWidth: 1000);
        return Dialog(
          backgroundColor: palette.panel,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: BorderSide(color: palette.surface),
          ),
          child: Container(
            width: size.width,
            height: size.height,
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Text(
                      '📖 提取原版剧情 / 检索剧情库',
                      style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: palette.textHigh),
                    ),
                    const Spacer(),
                    IconButton(
                      icon: Icon(FluentIcons.dismiss_24_regular, size: 16, color: palette.textSecondary),
                      onPressed: () {
                        Navigator.of(ctx).pop();
                        setState(() => _refreshCounter++);
                      },
                    ),
                  ],
                ),
                Divider(color: palette.surface, height: 18),
                Expanded(child: BaseSearchPage(state: widget.state)),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_tabIndex == 1) {
      return Column(
        children: [
          Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: palette.panel,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: palette.surface),
            ),
            child: Row(
              children: [
                _ActionPill(
                  label: '⬅️ 返回 EvtCfg 事件列表',
                  onPressed: () => setState(() => _tabIndex = 0),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text('🎬 剧情处理器 (TalkCfg / OptionCfg)',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: palette.textHigh)),
                ),
              ],
            ),
          ),
          Expanded(
            child: StoryDirectorView(
              state: widget.state,
              onPreview: widget.onPreview,
              classic: true,
            ),
          ),
        ],
      );
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 左栏：EvtCfg 事件列表
        Expanded(
          flex: 4,
          child: PageCard(
            title: '📝 EvtCfg 事件列表',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: _ActionPill(
                        label: '➕ 新建事件',
                        primary: true,
                        onPressed: _createEvent,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: _ActionPill(
                        label: '🗑️ 删除事件',
                        danger: true,
                        onPressed: _deleteEvent,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: _ConfigEntryList(
                    key: ValueKey('EvtCfg_$_refreshCounter'),
                    cfgName: 'EvtCfg',
                    selectedId: _selectedEventId,
                    onSelect: (id) => setState(() => _selectedEventId = id),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 8),
        // 中栏：事件详细配置
        Expanded(
          flex: 8,
          child: PageCard(
            title: '✨ 事件详细配置',
            actions: [
              _ActionPill(
                label: '恢复默认属性名',
                onPressed: () {
                  fluent.displayInfoBar(
                    context,
                    builder: (ctx, close) => const fluent.InfoBar(
                      title: Text('已恢复默认属性名映射'),
                      severity: fluent.InfoBarSeverity.success,
                    ),
                  );
                },
              ),
            ],
            child: SchemaEditorView(
              key: ValueKey('EvtCfg_${_selectedEventId}_$_refreshCounter'),
              state: widget.state,
              cfgName: 'EvtCfg',
              classic: true,
              embedInCard: true,
              selectedId: _selectedEventId,
              onSelectedIdChanged: (id) {
                if (_selectedEventId != id) {
                  setState(() => _selectedEventId = id);
                }
              },
              onPreview: widget.onPreview,
              onOpenSearch: widget.onOpenSearch,
            ),
          ),
        ),
        const SizedBox(width: 8),
        // 右栏：工作流工具
        Expanded(
          flex: 3,
          child: PageCard(
            title: '🧰 工作流工具',
            child: ListView(
              children: [
                _ToolActionButton(
                  emoji: '📥',
                  label: '导入文本剧本 (TXT)',
                  onPressed: () => showStoryImportDialog(context, widget.state),
                ),
                const SizedBox(height: 6),
                _ToolActionButton(
                  emoji: '📤',
                  label: '导出选中剧情 (TXT)',
                  onPressed: () => showStoryExportDialog(context, widget.state),
                ),
                const SizedBox(height: 6),
                _ToolActionButton(
                  emoji: '🪄',
                  label: '开始处理剧情 (TalkCfg_Option)',
                  primary: true,
                  // 接入独立的「剧情编辑（友商风格）」页；无跳转回调时退回内嵌 tab。
                  onPressed: () {
                    final openPage = widget.onOpenPage;
                    if (openPage != null) {
                      openPage('story_competitor');
                    } else {
                      setState(() => _tabIndex = 1);
                    }
                  },
                ),
                const SizedBox(height: 6),
                _ToolActionButton(
                  emoji: '▶️',
                  label: '剧情运行预览',
                  onPressed: () {
                    if (widget.onPreview != null) {
                      widget.onPreview!(_selectedEventId ?? '8000');
                    }
                  },
                ),
                const SizedBox(height: 6),
                _ToolActionButton(
                  emoji: '📖',
                  label: '提取原版剧情',
                  onPressed: _showExtractModal,
                ),
                const SizedBox(height: 6),
                _ToolActionButton(
                  emoji: '🔍',
                  label: '全文检索',
                  onPressed: widget.onOpenSearch,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 5. 空间手机结局编辑
// ---------------------------------------------------------------------------
class _SpaceEndingLayout extends StatefulWidget {
  const _SpaceEndingLayout({
    required this.state,
    this.onOpenSearch,
  });
  final AppState state;
  final VoidCallback? onOpenSearch;

  @override
  State<_SpaceEndingLayout> createState() => _SpaceEndingLayoutState();
}

class _SpaceEndingLayoutState extends State<_SpaceEndingLayout> {
  String _selectedModule = 'KZoneContentCfg';
  String? _selectedId;
  int _refreshCounter = 0;

  final _modules = const [
    'KZoneContentCfg',
    'PhoneMsgCfg',
    'EndingPartCfg',
    'EndingOptionCfg',
    'KZoneAvatarCfg',
  ];

  Future<void> _createSpaceItem() async {
    await _promptCreateEntry(
      context: context,
      cfgName: _selectedModule,
      defaultIdPrefix: '1',
      onCreated: (newId) {
        setState(() {
          _selectedId = newId;
          _refreshCounter++;
        });
      },
    );
  }

  Future<void> _deleteSpaceItem() async {
    await _promptDeleteEntry(
      context: context,
      cfgName: _selectedModule,
      selectedId: _selectedId,
      onDeleted: () {
        setState(() {
          _selectedId = null;
          _refreshCounter++;
        });
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // 顶部模块选择
        Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: palette.panel,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: palette.surface),
          ),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                Text('🏷️ 选择模块:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: palette.textHigh)),
                const SizedBox(width: 12),
                SizedBox(
                  width: 260,
                  height: 34,
                  child: fluent.ComboBox<String>(
                    value: _selectedModule,
                    isExpanded: true,
                    items: _modules.map((e) {
                      return fluent.ComboBoxItem(
                        value: e,
                        child: Text(cfgDisplayName(e), style: const TextStyle(fontSize: 12)),
                      );
                    }).toList(),
                    onChanged: (val) {
                      if (val != null) {
                        setState(() {
                          _selectedModule = val;
                          _selectedId = null;
                        });
                      }
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
        // 下方内容
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                flex: 4,
                child: PageCard(
                  title: '📱 条目列表',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: _ActionPill(
                              label: '⚡ 极速导入',
                              primary: true,
                              onPressed: () {
                                fluent.displayInfoBar(
                                  context,
                                  builder: (ctx, close) => const fluent.InfoBar(
                                    title: Text('极速导入功能已就绪'),
                                    severity: fluent.InfoBarSeverity.info,
                                  ),
                                );
                              },
                            ),
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: _ActionPill(
                              label: '➕ 新增',
                              onPressed: _createSpaceItem,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: _ActionPill(
                              label: '🗑️ 批量删除',
                              danger: true,
                              onPressed: _deleteSpaceItem,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Expanded(
                        child: _ConfigEntryList(
                          key: ValueKey('${_selectedModule}_$_refreshCounter'),
                          cfgName: _selectedModule,
                          selectedId: _selectedId,
                          onSelect: (id) => setState(() => _selectedId = id),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 8,
                child: PageCard(
                  title: '主体属性与配置',
                  actions: [
                    _ActionPill(
                      label: '恢复默认属性名',
                      onPressed: () {
                        fluent.displayInfoBar(
                          context,
                          builder: (ctx, close) => const fluent.InfoBar(
                            title: Text('已恢复默认属性名映射'),
                            severity: fluent.InfoBarSeverity.success,
                          ),
                        );
                      },
                    ),
                  ],
                  child: SchemaEditorView(
                    key: ValueKey('${_selectedModule}_${_selectedId}_$_refreshCounter'),
                    state: widget.state,
                    cfgName: _selectedModule,
                    classic: true,
                    embedInCard: true,
                    selectedId: _selectedId,
                    onSelectedIdChanged: (id) {
                      if (_selectedId != id) {
                        setState(() => _selectedId = id);
                      }
                    },
                    onOpenSearch: widget.onOpenSearch,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 6. 恋爱相关
// ---------------------------------------------------------------------------
class _LoveLayout extends StatefulWidget {
  const _LoveLayout({
    required this.state,
    this.onOpenSearch,
  });
  final AppState state;
  final VoidCallback? onOpenSearch;

  @override
  State<_LoveLayout> createState() => _LoveLayoutState();
}

class _LoveLayoutState extends State<_LoveLayout> {
  String _selectedCfg = 'BadmintonModelCfg';
  String? _selectedId;
  int _refreshCounter = 0;

  final _loveCfgs = const [
    'BadmintonModelCfg',
    'LoveVindicateRateCfg',
    'LoveBadmintonCfg',
    'LoveRibbonCfg',
    'LoveDrawCfg',
    'LoveBreakfastCfg',
  ];

  Future<void> _createLoveItem() async {
    await _promptCreateEntry(
      context: context,
      cfgName: _selectedCfg,
      defaultIdPrefix: '1',
      onCreated: (newId) {
        setState(() {
          _selectedId = newId;
          _refreshCounter++;
        });
      },
    );
  }

  Future<void> _deleteLoveItem() async {
    await _promptDeleteEntry(
      context: context,
      cfgName: _selectedCfg,
      selectedId: _selectedId,
      onDeleted: () {
        setState(() {
          _selectedId = null;
          _refreshCounter++;
        });
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          flex: 4,
          child: PageCard(
            title: '💞 恋爱事件库',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  height: 34,
                  child: fluent.ComboBox<String>(
                    value: _selectedCfg,
                    isExpanded: true,
                    items: _loveCfgs.map((e) {
                      return fluent.ComboBoxItem(
                        value: e,
                        child: Text(cfgDisplayName(e), style: const TextStyle(fontSize: 12)),
                      );
                    }).toList(),
                    onChanged: (val) {
                      if (val != null) {
                        setState(() {
                          _selectedCfg = val;
                          _selectedId = null;
                        });
                      }
                    },
                  ),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: _ConfigEntryList(
                    key: ValueKey('${_selectedCfg}_$_refreshCounter'),
                    cfgName: _selectedCfg,
                    selectedId: _selectedId,
                    onSelect: (id) => setState(() => _selectedId = id),
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: _ActionPill(
                        label: '➕ 新建项',
                        primary: true,
                        onPressed: _createLoveItem,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: _ActionPill(
                        label: '🗑️ 删除',
                        danger: true,
                        onPressed: _deleteLoveItem,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          flex: 8,
          child: PageCard(
            title: '📝 详细属性配置',
            child: SchemaEditorView(
              key: ValueKey('${_selectedCfg}_${_selectedId}_$_refreshCounter'),
              state: widget.state,
              cfgName: _selectedCfg,
              classic: true,
              embedInCard: true,
              selectedId: _selectedId,
              onSelectedIdChanged: (id) {
                if (_selectedId != id) {
                  setState(() => _selectedId = id);
                }
              },
              onOpenSearch: widget.onOpenSearch,
            ),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 7. 官方生态与工具
// ---------------------------------------------------------------------------
class _OfficialLayout extends StatelessWidget {
  const _OfficialLayout({
    required this.state,
    this.onOpenSearch,
  });
  final AppState state;
  final VoidCallback? onOpenSearch;

  @override
  Widget build(BuildContext context) {
    return PageCard(
      title: '🛡️ 官方生态与兼容工具',
      child: SchemaEditorView(
        state: state,
        cfgName: 'ManifestCfg',
        classic: true,
        embedInCard: true,
        onOpenSearch: onOpenSearch,
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 8. 剧情编辑（友商风格）— 类友商产品#2 的三栏剧情编辑页
// ---------------------------------------------------------------------------
class _StoryCompetitorLayout extends StatefulWidget {
  const _StoryCompetitorLayout({
    required this.state,
    this.onPreview,
    this.onOpenSearch,
    this.onOpenPage,
  });
  final AppState state;
  final ValueChanged<String>? onPreview;
  final VoidCallback? onOpenSearch;

  /// 返回「故事」事件列表页。
  final ValueChanged<String>? onOpenPage;

  @override
  State<_StoryCompetitorLayout> createState() => _StoryCompetitorLayoutState();
}

class _StoryCompetitorLayoutState extends State<_StoryCompetitorLayout> {
  /// 三栏编辑器的最小可用宽度：低于此宽度改为横向滚动，
  /// 避免「对话线树 + 舞台 + 人物与表情」固定宽度栏互相挤压导致溢出。
  static const double _minEditorWidth = 1060;

  /// 页面形态：true = 类友商#2「拾光舞台」；false = 经典三栏处理器（友商#1）。
  bool _studioStyle = true;

  /// 打开「提取原版剧情 / 检索剧情库」弹窗（从经典故事页迁移至此）。
  void _showExtractModal() {
    showDialog<void>(
      context: context,
      builder: (ctx) {
        final size = appDialogSize(ctx, preferredWidth: 1000);
        return Dialog(
          backgroundColor: palette.panel,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: BorderSide(color: palette.surface),
          ),
          child: Container(
            width: size.width,
            height: size.height,
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Text(
                      '📖 提取原版剧情 / 检索剧情库',
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
                Expanded(child: BaseSearchPage(state: widget.state)),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 顶部：页面标题 / 说明 + 快捷工具（窄屏整体横向滚动，避免溢出）
        Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: palette.panel,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: palette.surface),
          ),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                if (widget.onOpenPage != null) ...[
                  _ActionPill(
                    label: '⬅️ 返回事件列表',
                    onPressed: () => widget.onOpenPage!('story'),
                  ),
                  const SizedBox(width: 8),
                ],
                Icon(FluentIcons.script_24_regular, size: 18, color: accentColor),
                const SizedBox(width: 10),
                Text(
                  '🎬 剧情编辑（友商风格）',
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.bold,
                    color: palette.textHigh,
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  _studioStyle
                      ? '对话夹树 · 游戏画面即写台词 · 人物与表情（类友商#2 拾光舞台）'
                      : '事件 / 对白列表 · 行编辑 + 舞台 · 场景与选项（类友商#1 三栏处理器）',
                  style: TextStyle(fontSize: 11.5, color: palette.textMid),
                ),
                const SizedBox(width: 16),
                _ActionPill(
                  label: '🎭 拾光舞台',
                  primary: _studioStyle,
                  onPressed: () => setState(() => _studioStyle = true),
                ),
                const SizedBox(width: 4),
                _ActionPill(
                  label: '🎬 三栏处理器',
                  primary: !_studioStyle,
                  onPressed: () => setState(() => _studioStyle = false),
                ),
                const SizedBox(width: 16),
                _ActionPill(
                  label: '📥 导入文本剧本',
                  onPressed: () => showStoryImportDialog(context, widget.state),
                ),
                const SizedBox(width: 6),
                _ActionPill(
                  label: '📤 导出选中剧情',
                  onPressed: () => showStoryExportDialog(context, widget.state),
                ),
                const SizedBox(width: 6),
                _ActionPill(
                  label: '📖 提取原版剧情 / 检索',
                  onPressed: widget.onOpenSearch ?? _showExtractModal,
                ),
              ],
            ),
          ),
        ),
        // 主体：默认类友商#2「拾光舞台」剧情编辑器（对话夹树 + 游戏画面
        // WYSIWYG + 人物表情速涂）；可切回类友商#1 的三栏剧情处理器。
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final editor = SizedBox(
                width: constraints.maxWidth < _minEditorWidth
                    ? _minEditorWidth
                    : constraints.maxWidth,
                child: _studioStyle
                    ? StoryStudioEditor(
                        key: const ValueKey('story-studio'),
                        state: widget.state,
                        onPreview: widget.onPreview,
                      )
                    : StoryDirectorView(
                        key: const ValueKey('story-director'),
                        state: widget.state,
                        onPreview: widget.onPreview,
                        classic: true,
                      ),
              );
              if (constraints.maxWidth >= _minEditorWidth) return editor;
              return SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: editor,
              );
            },
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 通用弹窗操作辅助
// ---------------------------------------------------------------------------
Future<void> _promptCreateEntry({
  required BuildContext context,
  required String cfgName,
  String defaultIdPrefix = '1',
  required ValueChanged<String> onCreated,
}) async {
  final idController = TextEditingController();
  final nameController = TextEditingController();

  await showDialog<void>(
    context: context,
    builder: (ctx) => AppContentDialog(
      title: Text('➕ 新建 ${cfgDisplayName(cfgName)} 条目'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('条目 ID (建议纯数字或英文标识)：', style: TextStyle(fontSize: 12)),
          const SizedBox(height: 6),
          fluent.TextBox(
            controller: idController,
            placeholder: '如: ${defaultIdPrefix}01',
          ),
          const SizedBox(height: 12),
          const Text('名称 / 标题 (可选)：', style: TextStyle(fontSize: 12)),
          const SizedBox(height: 6),
          fluent.TextBox(
            controller: nameController,
            placeholder: '如: 新配置项',
          ),
        ],
      ),
      actions: [
        fluent.Button(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('取消'),
        ),
          fluent.FilledButton(
            onPressed: () async {
              final id = idController.text.trim();
              if (id.isEmpty) return;
              try {
                final r = await ApiClient.instance.get('/api/cfg/$cfgName');
                final data = (r['data'] as Map? ?? {}).cast<String, dynamic>();
                final name = nameController.text.trim();
                data[id] = {'id': id, if (name.isNotEmpty) 'name': name};
                // expect_mtime_ns：刚 GET 到的磁盘 mtime，被外部改写时后端返回 409
                await ApiClient.instance.put('/api/cfg/$cfgName', body: {
                  'data': data,
                  'expect_mtime_ns': r['mtime_ns'],
                });
                if (ctx.mounted) Navigator.of(ctx).pop();
                onCreated(id);
              } on ApiException catch (e) {
                if (ctx.mounted) {
                  fluent.displayInfoBar(
                    ctx,
                    builder: (bctx, close) => fluent.InfoBar(
                      title: const Text('新建失败'),
                      content: Text(
                        e.statusCode == 409
                            ? '$cfgName 文件已被外部修改（可能被游戏或其他端改写），请重试'
                            : e.toString(),
                      ),
                      severity: fluent.InfoBarSeverity.error,
                    ),
                  );
                }
              } catch (e) {
                if (ctx.mounted) {
                  fluent.displayInfoBar(
                    ctx,
                    builder: (bctx, close) => fluent.InfoBar(
                      title: const Text('新建失败'),
                      content: Text(e.toString()),
                      severity: fluent.InfoBarSeverity.error,
                    ),
                  );
                }
              }
            },
            child: const Text('确定创建'),
          ),
      ],
    ),
  );
}

Future<void> _promptDeleteEntry({
  required BuildContext context,
  required String cfgName,
  required String? selectedId,
  required VoidCallback onDeleted,
}) async {
  if (selectedId == null || selectedId.isEmpty) {
    fluent.displayInfoBar(
      context,
      builder: (ctx, close) => const fluent.InfoBar(
        title: Text('请先在左侧选择要删除的条目'),
        severity: fluent.InfoBarSeverity.warning,
      ),
    );
    return;
  }
  await showDialog<void>(
    context: context,
    builder: (ctx) => AppContentDialog(
      title: const Text('确认删除'),
      content: Text('确定要删除 ${cfgDisplayName(cfgName)} 中的条目 [$selectedId] 吗？此操作不可逆。'),
      actions: [
        fluent.Button(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('取消'),
        ),
        fluent.FilledButton(
          style: fluent.ButtonStyle(
            backgroundColor: WidgetStatePropertyAll(palette.danger),
          ),
          onPressed: () async {
            try {
              final r = await ApiClient.instance.get('/api/cfg/$cfgName');
              final data = (r['data'] as Map? ?? {}).cast<String, dynamic>();
              data.remove(selectedId);
              // expect_mtime_ns：刚 GET 到的磁盘 mtime，被外部改写时后端返回 409
              await ApiClient.instance.put('/api/cfg/$cfgName', body: {
                'data': data,
                'expect_mtime_ns': r['mtime_ns'],
              });
              if (ctx.mounted) Navigator.of(ctx).pop();
              onDeleted();
            } on ApiException catch (e) {
              if (ctx.mounted) {
                fluent.displayInfoBar(
                  ctx,
                  builder: (bctx, close) => fluent.InfoBar(
                    title: const Text('删除失败'),
                    content: Text(
                      e.statusCode == 409
                          ? '$cfgName 文件已被外部修改（可能被游戏或其他端改写），请重试'
                          : e.toString(),
                    ),
                    severity: fluent.InfoBarSeverity.error,
                  ),
                );
              }
            } catch (e) {
              if (ctx.mounted) {
                fluent.displayInfoBar(
                  ctx,
                  builder: (bctx, close) => fluent.InfoBar(
                    title: const Text('删除失败'),
                    content: Text(e.toString()),
                    severity: fluent.InfoBarSeverity.error,
                  ),
                );
              }
            }
          },
          child: const Text('确定删除'),
        ),
      ],
    ),
  );
}

// ---------------------------------------------------------------------------
// 通用组件与辅助部件
// ---------------------------------------------------------------------------
class _ActionPill extends StatelessWidget {
  const _ActionPill({
    required this.label,
    required this.onPressed,
    this.primary = false,
    this.danger = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool primary;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    Color bg = palette.card;
    Color fg = palette.textPrimary;
    Color? borderColor = palette.borderHover;

    if (primary) {
      bg = accentColor;
      fg = palette.onAccent;
      borderColor = null;
    } else if (danger) {
      bg = palette.tintDanger;
      fg = palette.statusDanger;
      borderColor = palette.tintDanger;
    }

    return MouseRegion(
      cursor: onPressed != null ? SystemMouseCursors.click : SystemMouseCursors.basic,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onPressed,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(5),
            border: borderColor != null ? Border.all(color: borderColor) : null,
          ),
          child: Text(
            label,
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11.5,
              color: fg,
              fontWeight: primary ? FontWeight.bold : FontWeight.normal,
            ),
          ),
        ),
      ),
    );
  }
}

class _ToolActionButton extends StatelessWidget {
  const _ToolActionButton({
    required this.emoji,
    required this.label,
    required this.onPressed,
    this.primary = false,
  });

  final String emoji;
  final String label;
  final VoidCallback? onPressed;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final bg = primary ? accentColor : palette.card;
    final fg = primary ? palette.onAccent : palette.textPrimary;

    return MouseRegion(
      cursor: onPressed != null ? SystemMouseCursors.click : SystemMouseCursors.basic,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onPressed,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(6),
            border: primary ? null : Border.all(color: palette.borderHover),
          ),
          child: Row(
            children: [
              Text(emoji, style: const TextStyle(fontSize: 13)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: fg,
                    fontWeight: primary ? FontWeight.bold : FontWeight.normal,
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

class _ConfigEntryList extends StatefulWidget {
  const _ConfigEntryList({
    super.key,
    required this.cfgName,
    this.selectedId,
    this.onSelect,
  });
  final String cfgName;
  final String? selectedId;
  final ValueChanged<String>? onSelect;

  @override
  State<_ConfigEntryList> createState() => _ConfigEntryListState();
}

class _ConfigEntryListState extends State<_ConfigEntryList> {
  List<(String, String)> _items = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant _ConfigEntryList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.cfgName != widget.cfgName) _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await ApiClient.instance.get('/api/cfg/${widget.cfgName}');
      final data = result is Map && result['data'] is Map
          ? (result['data'] as Map).cast<String, dynamic>()
          : <String, dynamic>{};
      final values = <(String, String)>[];
      for (final entry in data.entries) {
        final value = entry.value is Map
            ? (entry.value as Map)['name'] ??
                  (entry.value as Map)['title'] ??
                  (entry.value as Map)['desc']
            : null;
        values.add((entry.key, value?.toString() ?? '条目 ${entry.key}'));
      }
      if (!mounted) return;
      setState(() {
        _items = values;
        _loading = false;
      });
      if (values.isNotEmpty && widget.selectedId == null && widget.onSelect != null) {
        widget.onSelect!(values.first.$1);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: fluent.ProgressRing());
    }
    if (_error != null) {
      return Center(
        child: Text(
          '资源列表加载失败',
          style: TextStyle(fontSize: 12, color: palette.textMuted),
        ),
      );
    }
    if (_items.isEmpty) {
      return Center(
        child: Text(
          '暂无配置条目',
          style: TextStyle(fontSize: 12, color: palette.textHint),
        ),
      );
    }
    return ListView.separated(
      itemCount: _items.length,
      separatorBuilder: (_, _) => const SizedBox(height: 3),
      itemBuilder: (context, index) {
        final (id, name) = _items[index];
        final isSelected = widget.selectedId == id;

        return MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              if (widget.onSelect != null) widget.onSelect!(id);
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              decoration: BoxDecoration(
                color: isSelected ? palette.tintAccent : palette.card,
                borderRadius: BorderRadius.circular(4),
                border: isSelected ? Border.all(color: accentColor, width: 1) : null,
              ),
              child: Row(
                children: [
                  Icon(
                    FluentIcons.document_24_regular,
                    size: 13,
                    color: isSelected ? accentColor : palette.accentLight,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: isSelected ? palette.textHigh : palette.textPrimary,
                        fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                      ),
                    ),
                  ),
                  Text(
                    id,
                    style: TextStyle(
                      fontSize: 10,
                      color: isSelected ? palette.accentLighter : palette.textHint,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
