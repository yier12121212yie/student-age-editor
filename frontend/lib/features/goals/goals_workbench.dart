import 'package:flutter/material.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../../core/api_client.dart';
import '../../core/app_dialogs.dart';
import '../../core/app_feedback.dart';
import '../../core/app_theme.dart';
import '../../core/debouncer.dart';
import '../../core/empty_state.dart';
import '../../core/error_text.dart';
import '../../core/models.dart';
import '../../core/motion.dart';
import '../../core/workbench_controller.dart';
import '../../core/workbench_guard.dart';
import '../../core/workbench_scaffold.dart';
import '../../core/save_bar.dart';
import '../editor/section_card.dart';
import '../editor/synced_fields.dart';
import '../nocode/entity_picker.dart' show RoleEntry, loadRoles;
import '../resources/role_visuals.dart';

/// 目标工作台 —— 导演布局下「目标 / 意愿」的专属界面。
///
/// 三栏：目标列表｜游戏内目标预览｜目标设置（标签）。数据来自 `IntentCfg`，
/// 整表读写（带 `expect_mtime_ns` 乐观锁，409 弹冲突选择）。
class GoalsWorkbench extends StatefulWidget {
  const GoalsWorkbench({
    super.key,
    required this.state,
    this.onOpenSearch,
  });

  final AppState state;
  final VoidCallback? onOpenSearch;

  @override
  State<GoalsWorkbench> createState() => _GoalsWorkbenchState();
}

/// 设置标签页。
const _goalTabs = <List<String>>[
  ['basic', '基本设置'],
  ['demand', '完成要求'],
  ['reward', '奖励与失败'],
  ['advanced', '扩展设置'],
];

const _finishTypes = <List<String>>[
  ['0', '领取奖励后移除'],
  ['1', '完成时自动移除'],
  ['2', '仅通过效果移除'],
];

const _goalTags = <List<String>>[
  ['0', '支线'],
  ['1', '主线'],
  ['2', '计划'],
];

class _GoalsWorkbenchState extends State<GoalsWorkbench>
    with WorkbenchLeaveGuard<GoalsWorkbench> {
  static const _cfg = 'IntentCfg';

  /// A3 试点：整表 load/save/dirty/乐观锁 409 交给公共控制器，
  /// 工作台只保留 UI 状态。`_rows` 作为控制器数据的转发 getter，
  /// 现有调用点无需改动。
  late final WorkbenchController _ctl = WorkbenchController(
    cfgs: const [_cfg],
    onConflict: _onConflict,
    onError: (e) {
      if (mounted) {
        AppFeedback.error(context, '保存失败：${humanizeErrorMessage(e)}',
            detail: e.toString());
      }
    },
    onSaved: (_) {
      if (mounted) AppFeedback.success(context, '目标已保存');
    },
  );

  Map<String, dynamic> get _rows => _ctl.table(_cfg).data;

  bool _loading = true;
  bool _saving = false;
  String? _error;

  String? _selected;
  String _tab = 'basic';
  String _search = '';
  String _previewState = 'progress';

  List<RoleEntry> _roles = const [];
  Map<String, String> _talkNames = {};
  bool _talksLoaded = false;
  Map<String, String> _renshengguanNames = {};

  final TextEditingController _searchCtrl = TextEditingController();
  final Debouncer _searchDebounce = Debouncer();

  @override
  void initState() {
    super.initState();
    _ctl.addListener(_onCtl);
    _loadAll();
  }

  void _onCtl() {
    if (!mounted) return;
    setState(() {
      _loading = _ctl.loading;
      _saving = _ctl.saving;
      _error = _ctl.error?.toString();
    });
  }

  @override
  void dispose() {
    _ctl.removeListener(_onCtl);
    _ctl.dispose();
    _searchCtrl.dispose();
    _searchDebounce.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------------
  // 数据
  // ------------------------------------------------------------------

  // ---- 离开守卫（切模式/切模组/刷新）：见 core/workbench_guard.dart ----
  @override
  AppState get guardAppState => widget.state;
  @override
  bool get guardDirty => _dirty;
  @override
  Future<void> guardSave() => _saveAll();
  @override
  void guardDiscard() => _discard();
  @override
  Future<void> guardReload() => _loadAll();
  @override
  String get guardSubject => '目标设置';

  Future<void> _loadAll() async {
    try {
      await _ctl.load();
      if (!mounted) return;
      if (_selected == null || !_rows.containsKey(_selected)) {
        final ids = _sortedIds;
        _selected = ids.isNotEmpty ? ids.first : null;
      }
      _loadRoles();
      _loadRenshengguan();
    } catch (_) {
      // 错误已由控制器记录并经监听器反映到 _error / WorkbenchStatus.error。
    }
  }

  Future<void> _loadRoles() async {
    final list = await loadRoles('');
    if (!mounted) return;
    setState(() => _roles = list);
  }

  Future<void> _loadRenshengguan() async {
    try {
      final r = await ApiClient.instance.get('/api/cfg/RenshengguanTypeCfg');
      if (!mounted) return;
      setState(() => _renshengguanNames = _nameMap(WorkbenchController.extractData(r)));
    } catch (_) {}
  }

  Map<String, String> _nameMap(Map<String, dynamic> data) {
    final out = <String, String>{};
    for (final e in data.entries) {
      final v = e.value;
      if (v is Map) {
        final raw = v['name'] ?? v['title'];
        out[e.key] = raw?.toString() ?? '条目 ${e.key}';
      }
    }
    return out;
  }

  Future<void> _ensureTalks() async {
    if (_talksLoaded) return;
    _talksLoaded = true;
    try {
      final r = await ApiClient.instance.get('/api/cfg/TalkCfg');
      if (!mounted) return;
      final data = WorkbenchController.extractData(r);
      setState(() {
        _talkNames = {
          for (final e in data.entries)
            e.key: (e.value is Map
                    ? ((e.value as Map)['content']?.toString() ?? '')
                    : '')
                .replaceAll(_tagRe, '')
                .trim(),
        };
      });
    } catch (_) {}
  }

  bool get _dirty => _ctl.dirtyDeep;

  Future<void> _saveAll() async {
    final ok = await _ctl.save();
    // 409 选「重新加载」时控制器已重载该表；这里只同步选中项。
    if (!mounted) return;
    if (ok && (_selected == null || !_rows.containsKey(_selected))) {
      final ids = _sortedIds;
      _selected = ids.isNotEmpty ? ids.first : null;
    }
  }

  void _discard() {
    _ctl.discard();
    if (_selected == null || !_rows.containsKey(_selected)) {
      final ids = _sortedIds;
      _selected = ids.isNotEmpty ? ids.first : null;
    }
  }

  /// 409 冲突弹窗 → 控制器的 [WorkbenchConflictChoice]。
  Future<WorkbenchConflictChoice?> _onConflict(WorkbenchTable table) =>
      showWorkbenchConflictDialog(context, table);

  // ------------------------------------------------------------------
  // 行访问
  // ------------------------------------------------------------------

  Map<String, dynamic>? get _row =>
      _selected == null ? null : _rowOf(_selected!);

  Map<String, dynamic>? _rowOf(String id) {
    final v = _rows[id];
    return v is Map ? v.cast<String, dynamic>() : null;
  }

  List<String> get _sortedIds {
    // 排序结果按源表版本号缓存：源表一变才重算，避免每次 build 全表 O(n log n)。
    final rev = _ctl.table(_cfg).revision;
    if (rev == _sortRev) return _sortedIdsCache;
    final ids = _rows.keys.toList();
    ids.sort((a, b) {
      final an = int.tryParse(a);
      final bn = int.tryParse(b);
      if (an != null && bn != null) return an.compareTo(bn);
      return a.compareTo(b);
    });
    _sortRev = rev;
    _sortedIdsCache = ids;
    return ids;
  }

  int _sortRev = -1;
  List<String> _sortedIdsCache = const [];

  String _nameOf(String id) {
    final n = _rowOf(id)?['name']?.toString() ?? '';
    return n.isEmpty ? '未命名目标' : n;
  }

  int _intOf(Map<String, dynamic>? row, String field) {
    final v = row?[field];
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? '') ?? 0;
  }

  List<int> _listInt(Map<String, dynamic>? row, String field) {
    final v = row?[field];
    if (v is! List) return <int>[];
    return [
      for (final e in v)
        if (e is num)
          e.toInt()
        else if (int.tryParse(e.toString()) != null)
          int.parse(e.toString()),
    ];
  }

  /// 2D 命令数组（demand / condition / reward / fail）的条数。
  int _lenOf(Map<String, dynamic>? row, String field) {
    final v = row?[field];
    return v is List ? v.length : 0;
  }

  String _roleName(int id) {
    // 角色名索引：原实现对每行线性扫 _roles（O(可见行 × 角色数)）。
    if (!identical(_roleIndexSrc, _roles)) {
      final m = <String, String>{};
      for (final r in _roles) {
        m[r.id] = r.name.isEmpty ? '角色 ${r.id}' : r.name;
      }
      _roleIndexSrc = _roles;
      _roleNameIndex = m;
    }
    final n = _roleNameIndex[id.toString()];
    if (n != null) return n;
    return id == 0 ? '白雨' : '角色 $id';
  }

  List<RoleEntry>? _roleIndexSrc;
  Map<String, String> _roleNameIndex = const {};

  /// 富文本标记剥离用正则（逐行调用，提到 static 只编译一次）。
  static final RegExp _tagRe = RegExp(r'<[^>]*>');

  int _newId() {
    var max = 0;
    for (final k in _rows.keys) {
      final v = int.tryParse(k);
      if (v != null && v > max) max = v;
    }
    return max == 0 ? 1 : max + 1;
  }

  void _addGoal() {
    final id = _newId().toString();
    setState(() {
      _rows[id] = <String, dynamic>{
        'id': int.tryParse(id),
        'name': '未命名目标',
        'group': 999,
        'desc': '',
        'npc': 0,
        'finishType': 0,
        'round': 0,
        'before': 0,
        'next': 0,
        'targetRound': 0,
        'weight': 1,
        'tag': 0,
        'renshengguan': 0,
        'demand': <dynamic>[],
        'condition': <dynamic>[],
        'reward': <dynamic>[],
        'fail': <dynamic>[],
        'finishTalk': <dynamic>[],
        'failTalk': <dynamic>[],
      };
      _selected = id;
      _tab = 'basic';
    });
  }

  void _duplicateGoal() {
    final src = _row;
    if (src == null) return;
    final id = _newId().toString();
    setState(() {
      _rows[id] = {
        ...src,
        'id': int.tryParse(id),
        'name': '${src['name'] ?? '目标'} · 副本',
      };
      _selected = id;
      _tab = 'basic';
    });
  }

  void _deleteGoal() {
    final id = _selected;
    if (id == null) return;
    setState(() {
      _rows.remove(id);
      final ids = _sortedIds;
      _selected = ids.isNotEmpty ? ids.first : null;
    });
  }

  Future<int?> _pickRole() async {
    var query = '';
    return fluent.showDialog<int>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) {
          final rows = _roles
              .where((r) =>
                  r.id.toLowerCase().contains(query) ||
                  r.name.toLowerCase().contains(query))
              .toList();
          return AppContentDialog(
            title: const Text('选择目标图像（人物）'),
            content: SizedBox(
              width: 440,
              height: 400,
              child: Column(
                children: [
                  fluent.TextBox(
                    placeholder: '搜索人物名称或编号',
                    onChanged: (v) =>
                        setLocal(() => query = v.trim().toLowerCase()),
                  ),
                  const SizedBox(height: 10),
                  Expanded(
                    child: ListView(
                      children: [
                        for (final r in rows)
                          MouseRegion(
                            cursor: SystemMouseCursors.click,
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: () =>
                                  Navigator.pop(ctx, int.tryParse(r.id) ?? 0),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 10, vertical: 9),
                                child: Row(
                                  children: [
                                    RoleAvatar(
                                        seed: int.tryParse(r.id) ?? 0,
                                        name: r.name),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Text(r.name,
                                          style: TextStyle(
                                              fontSize: 12.5,
                                              color: palette.textPrimary)),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              fluent.Button(
                onPressed: () => Navigator.pop(ctx, null),
                child: const Text('取消'),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<int?> _pickTalk() async {
    await _ensureTalks();
    if (!mounted) return null;
    var query = '';
    final entries = _talkNames.entries
        .where((e) => e.value.isNotEmpty)
        .toList()
      ..sort((a, b) {
        final an = int.tryParse(a.key);
        final bn = int.tryParse(b.key);
        if (an != null && bn != null) return an.compareTo(bn);
        return a.key.compareTo(b.key);
      });
    return fluent.showDialog<int>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) {
          final list = entries
              .where((e) =>
                  e.key.contains(query) ||
                  e.value.toLowerCase().contains(query))
              .toList();
          return AppContentDialog(
            title: const Text('选择对话'),
            content: SizedBox(
              width: 480,
              height: 420,
              child: Column(
                children: [
                  fluent.TextBox(
                    placeholder: '搜索对话内容或编号',
                    onChanged: (v) =>
                        setLocal(() => query = v.trim().toLowerCase()),
                  ),
                  const SizedBox(height: 10),
                  Expanded(
                    child: list.isEmpty
                        ? const EmptyState('没有匹配的对话')
                        : ListView.builder(
                            itemCount: list.length,
                            itemBuilder: (context, i) {
                              final e = list[i];
                              return MouseRegion(
                                cursor: SystemMouseCursors.click,
                                child: GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onTap: () => Navigator.pop(
                                      ctx, int.tryParse(e.key) ?? 0),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 10, vertical: 9),
                                    child: Row(
                                      children: [
                                        Text(e.key,
                                            style: TextStyle(
                                                fontSize: 10.5,
                                                color: palette.textHint)),
                                        const SizedBox(width: 10),
                                        Expanded(
                                          child: Text(e.value,
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                  fontSize: 12,
                                                  color:
                                                      palette.textPrimary)),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
            actions: [
              fluent.Button(
                onPressed: () => Navigator.pop(ctx, null),
                child: const Text('取消'),
              ),
            ],
          );
        },
      ),
    );
  }

  // ------------------------------------------------------------------
  // 构建
  // ------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return WorkbenchScaffold(
      errorTitle: '目标数据加载失败',
      status: _loading
          ? WorkbenchStatus.loading
          : _error != null
              ? WorkbenchStatus.error
              : WorkbenchStatus.ready,
      error: _error,
      onRetry: _loadAll,
      leftBuilder: (w) => _leftPanel(w),
      center: _center(),
      rightBuilder: (w) => _rightPanel(w),
      rightLabel: '目标设置',
    );
  }

  // ---------- 左栏 ----------

  Widget _leftPanel(double w) {
    final q = _search.trim().toLowerCase();
    final ids = _sortedIds.where((id) {
      if (q.isEmpty) return true;
      final row = _rowOf(id);
      return id.contains(q) ||
          _nameOf(id).toLowerCase().contains(q) ||
          (row?['desc']?.toString().toLowerCase() ?? '').contains(q);
    }).toList();

    return Container(
      width: w,
      color: palette.panel,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                fluent.TextBox(
                  controller: _searchCtrl,
                  placeholder: '搜索目标名称或编号',
                  onChanged: (v) => _searchDebounce.run(
                      () => setState(() => _search = v)),
                ),
                const SizedBox(height: 10),
                fluent.FilledButton(
                  onPressed: _addGoal,
                  child: const Text('＋ 添加目标',
                      style: TextStyle(fontSize: 12.5)),
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Expanded(
                      child: WorkbenchMiniButton(
                        label: '创建副本',
                        enabled: _selected != null,
                        onTap: _duplicateGoal,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: WorkbenchMiniButton(
                        label: '删除目标',
                        danger: true,
                        enabled: _selected != null,
                        onTap: _deleteGoal,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          Divider(height: 1, color: palette.border),
          Expanded(
            child: ids.isEmpty
                ? Center(
                    child: Text(
                      _rows.isEmpty ? '还没有目标，点「添加目标」新建。' : '没有匹配的目标。',
                      style:
                          TextStyle(fontSize: 12, color: palette.textHint),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 8),
                    itemCount: ids.length,
                    itemBuilder: (context, i) {
                      final id = ids[i];
                      final row = _rowOf(id);
                      final npc = _intOf(row, 'npc');
                      final desc = (row?['desc']?.toString() ?? '')
                          .replaceAll(_tagRe, '');
                      return _GoalListItem(
                        id: id,
                        name: _nameOf(id),
                        npcId: npc,
                        npcName: _roleName(npc),
                        desc: desc,
                        tag: _intOf(row, 'tag'),
                        selected: id == _selected,
                        onTap: () => setState(() => _selected = id),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  // ---------- 中栏：预览 ----------

  Widget _center() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: _selected == null
              ? Center(
                  child: Text(
                    '添加或选择左侧目标，右侧编辑，中间预览。',
                    style: TextStyle(fontSize: 13, color: palette.textHint),
                  ),
                )
              : SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(22, 18, 22, 20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // 窄屏（手机编辑页）下标题与三个分段按钮同排会溢出，
                      // 故窄屏改为可换行的 Wrap，宽屏维持原「标题 + 右对齐按钮」。
                      LayoutBuilder(builder: (ctx, c) {
                        final left = <Widget>[
                          Icon(FluentIcons.target_24_regular,
                              size: 15, color: palette.goldText),
                          const SizedBox(width: 6),
                          Text('游戏内目标预览',
                              style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                  color: palette.textHigh)),
                        ];
                        final right = <Widget>[
                          for (final s in const [
                            ['progress', '进行中'],
                            ['complete', '已完成'],
                            ['failed', '已失败'],
                          ])
                            Padding(
                              padding: const EdgeInsets.only(left: 6),
                              child: _SegButton(
                                label: s[1],
                                selected: _previewState == s[0],
                                onTap: () => setState(() {
                                  _previewState = s[0];
                                }),
                              ),
                            ),
                        ];
                        if (c.maxWidth < 380) {
                          return Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [...left, ...right],
                          );
                        }
                        return Row(
                            children: [...left, const Spacer(), ...right]);
                      }),
                      const SizedBox(height: 14),
                      _previewCard(),
                    ],
                  ),
                ),
        ),
        _saveBar(),
      ],
    );
  }

  Widget _previewCard() {
    final row = _row!;
    final npc = _intOf(row, 'npc');
    final demand = _lenOf(row, 'demand');
    final reward = _lenOf(row, 'reward');
    final round = _intOf(row, 'round');
    final targetRound = _intOf(row, 'targetRound');
    final finish = _intOf(row, 'finishType');
    final done = _previewState == 'complete';
    final failed = _previewState == 'failed';
    return Container(
      constraints: const BoxConstraints(maxWidth: 560),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [palette.card, palette.panel],
        ),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: done
              ? palette.statusOk.withValues(alpha: 0.6)
              : failed
                  ? palette.statusDanger.withValues(alpha: 0.6)
                  : palette.borderHover,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              RoleAvatar(seed: npc, name: _roleName(npc), size: 44),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            row['name']?.toString() ?? '未命名目标',
                            style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                                color: palette.textHigh),
                          ),
                        ),
                        if (done)
                          _Tag(text: '已完成', color: palette.statusOk)
                        else if (failed)
                          _Tag(text: '已失败', color: palette.statusDanger)
                        else
                          _Tag(
                              text: _tagLabel(_intOf(row, 'tag')),
                              color: palette.goldText),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text('目标组 ${_intOf(row, 'group')} · ID ${row['id']}',
                        style: TextStyle(
                            fontSize: 11, color: palette.textHint)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            (row['desc']?.toString().trim().isNotEmpty ?? false)
                ? row['desc'].toString()
                : (demand > 0 ? '完成以下要求。' : '（没有描述）'),
            style: TextStyle(
                fontSize: 12.5, height: 1.7, color: palette.textPrimary),
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _Tag(text: '完成要求 $demand 条', color: palette.statusInfo),
              if (reward > 0)
                _Tag(text: '完成奖励 $reward 条', color: palette.statusOk),
              if (_lenOf(row, 'fail') > 0)
                _Tag(
                    text: '失败效果 ${_lenOf(row, 'fail')} 条',
                    color: palette.statusDanger),
              _Tag(
                  text: round > 0 ? '持续 $round 回合' : '持续存在',
                  color: palette.textMuted),
              if (targetRound > 0)
                _Tag(text: '截止第 $targetRound 回合', color: palette.statusWarn),
            ],
          ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: palette.bgDeep2.withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: palette.border),
            ),
            child: Row(
              children: [
                Icon(FluentIcons.info_24_regular,
                    size: 12, color: palette.textHint),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '移除规则：${_finishLabel(finish)}　'
                    '前置目标：${_intOf(row, 'before') == 0 ? "无" : _nameOf(_intOf(row, 'before').toString())}　'
                    '后续目标组：${_intOf(row, 'next') == 0 ? "无" : _intOf(row, 'next')}',
                    style: TextStyle(
                        fontSize: 11, color: palette.textSecondary),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _finishLabel(int v) {
    for (final t in _finishTypes) {
      if (t[0] == v.toString()) return t[1];
    }
    return '原有规则 $v';
  }

  String _tagLabel(int v) {
    for (final t in _goalTags) {
      if (t[0] == v.toString()) return t[1];
    }
    return '目标';
  }

  Widget _saveBar() {
    return SaveBar(
      dirty: _dirty,
      saving: _saving,
      onSave: _saveAll,
      onDiscard: _discard,
      onOpenSearch: widget.onOpenSearch,
      history: _ctl,
    );
  }

  // ---------- 右栏：设置 ----------

  Widget _rightPanel(double w) {
    final row = _row;
    return Container(
      width: w,
      color: palette.panel,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        child: row == null
            ? Text('选择左侧目标查看设置。',
                style: TextStyle(fontSize: 12, color: palette.textHint))
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_nameOf(_selected!),
                      style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: palette.textHigh)),
                  const SizedBox(height: 12),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        for (final t in _goalTabs)
                          Padding(
                            padding: const EdgeInsets.only(right: 6),
                            child: _SegButton(
                              label: t[1],
                              selected: _tab == t[0],
                              onTap: () => setState(() => _tab = t[0]),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  _tabBody(row),
                ],
              ),
      ),
    );
  }

  Widget _tabBody(Map<String, dynamic> row) {
    switch (_tab) {
      case 'demand':
        return WorkbenchSectionCard(
          title: '完成要求',
          subtitle: '所有要求达成后，目标完成。',
          children: [
            Text('已设置 ${_lenOf(row, 'demand')} 条要求',
                style: TextStyle(fontSize: 12, color: palette.textMuted)),
            const SizedBox(height: 6),
            Text(
              '完成要求（达成条件）请在通用配置表的条件编辑器中维护；'
              '这里负责目标的名称、图像、回合与前后置关系。',
              style: TextStyle(
                  fontSize: 11, height: 1.6, color: palette.textHint),
            ),
          ],
        );
      case 'reward':
        final finishTalk = _listInt(row, 'finishTalk');
        final failTalk = _listInt(row, 'failTalk');
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            WorkbenchSectionCard(
              title: '奖励与失败',
              children: [
                Text(
                  '完成奖励：${_lenOf(row, 'reward')} 条　'
                  '失败效果：${_lenOf(row, 'fail')} 条',
                  style: TextStyle(fontSize: 12, color: palette.textMuted),
                ),
                const SizedBox(height: 6),
                Text(
                  '奖励与失败效果请在通用配置表的效果编辑器中维护。',
                  style: TextStyle(
                      fontSize: 11, height: 1.6, color: palette.textHint),
                ),
              ],
            ),
            WorkbenchSectionCard(
              title: '完成 / 失败对话',
              children: [
                _talkLine(
                  '完成后对话',
                  finishTalk,
                  (i) => setState(() {
                    final l = _listInt(row, 'finishTalk')..removeAt(i);
                    row['finishTalk'] = l;
                  }),
                  () async {
                    final id = await _pickTalk();
                    if (id == null || !mounted) return;
                    setState(() {
                      final l = _listInt(row, 'finishTalk')..add(id);
                      row['finishTalk'] = l;
                    });
                  },
                ),
                const SizedBox(height: 10),
                _talkLine(
                  '失败后对话',
                  failTalk,
                  (i) => setState(() {
                    final l = _listInt(row, 'failTalk')..removeAt(i);
                    row['failTalk'] = l;
                  }),
                  () async {
                    final id = await _pickTalk();
                    if (id == null || !mounted) return;
                    setState(() {
                      final l = _listInt(row, 'failTalk')..add(id);
                      row['failTalk'] = l;
                    });
                  },
                ),
              ],
            ),
          ],
        );
      case 'advanced':
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            WorkbenchSectionCard(
              title: '出现条件',
              children: [
                Text('已设置 ${_lenOf(row, 'condition')} 条出现条件',
                    style:
                        TextStyle(fontSize: 12, color: palette.textMuted)),
                const SizedBox(height: 6),
                Text(
                  '控制目标何时可以出现，请在通用配置表的条件编辑器中维护。',
                  style: TextStyle(
                      fontSize: 11, height: 1.6, color: palette.textHint),
                ),
              ],
            ),
            WorkbenchSectionCard(
              title: '前后置与分类',
              children: [
                _labeled(
                  '前置目标',
                  _RefDropdown(
                    value: _intOf(row, 'before'),
                    zeroLabel: '不需要前置目标',
                    options: {
                      for (final e in _rows.entries)
                        if (e.key != _selected) e.key: _nameOf(e.key),
                    },
                    onChanged: (v) => setState(() => row['before'] = v),
                  ),
                ),
                Row(
                  children: [
                    Expanded(
                      child: _labeled('后续目标组', NumBox(
                        intOnly: true, value: _intOf(row, 'next'),
                        hint: '移除后随机选择',
                        onChanged: (v) =>
                            setState(() => row['next'] = (v ?? 0).toInt()),
                      )),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _labeled('目标组', NumBox(
                        intOnly: true, value: _intOf(row, 'group'),
                        hint: '999 为普通自定义组',
                        onChanged: (v) =>
                            setState(() => row['group'] = (v ?? 0).toInt()),
                      )),
                    ),
                  ],
                ),
                Row(
                  children: [
                    Expanded(
                      child: _labeled('截止回合', NumBox(
                        intOnly: true, value: _intOf(row, 'targetRound'),
                        hint: '0 表示不设置',
                        onChanged: (v) => setState(
                            () => row['targetRound'] = (v ?? 0).toInt()),
                      )),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _labeled('随机权重', NumBox(
                        intOnly: true, value: _intOf(row, 'weight'),
                        hint: '同组随机抽取使用',
                        onChanged: (v) =>
                            setState(() => row['weight'] = (v ?? 0).toInt()),
                      )),
                    ),
                  ],
                ),
                _labeled(
                  '目标分类',
                  Row(
                    children: [
                      for (final t in _goalTags)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: _SegButton(
                            label: t[1],
                            selected: _intOf(row, 'tag') == int.parse(t[0]),
                            onTap: () =>
                                setState(() => row['tag'] = int.parse(t[0])),
                          ),
                        ),
                    ],
                  ),
                ),
                _labeled(
                  '优先匹配的人生观',
                  _RefDropdown(
                    value: _intOf(row, 'renshengguan'),
                    zeroLabel: '不限',
                    options: _renshengguanNames,
                    onChanged: (v) =>
                        setState(() => row['renshengguan'] = v),
                  ),
                ),
              ],
            ),
          ],
        );
      default:
        return WorkbenchSectionCard(
          title: '基本设置',
          children: [
            _labeled('目标标题', SyncedTextField(
              value: row['name']?.toString() ?? '',
              hint: '目标标题',
              onChanged: (v) => setState(() => row['name'] = v),
            )),
            Row(
              children: [
                Expanded(
                  child: _labeled(
                    '目标图像',
                    MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: GestureDetector(
                        onTap: () async {
                          final id = await _pickRole();
                          if (id == null || !mounted) return;
                          setState(() => row['npc'] = id);
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 8),
                          decoration: BoxDecoration(
                            color: palette.bgAlt,
                            borderRadius: BorderRadius.circular(7),
                            border: Border.all(color: palette.border),
                          ),
                          child: Row(
                            children: [
                              RoleAvatar(
                                  seed: _intOf(row, 'npc'),
                                  name: _roleName(_intOf(row, 'npc')),
                                  size: 24),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(_roleName(_intOf(row, 'npc')),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                        fontSize: 12,
                                        color: palette.textPrimary)),
                              ),
                              Text('选择',
                                  style: TextStyle(
                                      fontSize: 11, color: accentColor)),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _labeled('持续回合', NumBox(
                    intOnly: true, value: _intOf(row, 'round'),
                    hint: '0 表示持续存在',
                    onChanged: (v) =>
                        setState(() => row['round'] = (v ?? 0).toInt()),
                  )),
                ),
              ],
            ),
            _labeled(
              '移除规则',
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final t in _finishTypes)
                    _SegButton(
                      label: t[1],
                      selected: _intOf(row, 'finishType') == int.parse(t[0]),
                      onTap: () => setState(
                          () => row['finishType'] = int.parse(t[0])),
                    ),
                ],
              ),
            ),
            _labeled('目标描述', SyncedTextField(
              value: row['desc']?.toString() ?? '',
              hint: '目标描述',
              maxLines: 3,
              onChanged: (v) => setState(() => row['desc'] = v),
            )),
          ],
        );
    }
  }

  Widget _talkLine(
    String title,
    List<int> ids,
    ValueChanged<int> onRemove,
    VoidCallback onAdd,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title,
            style: TextStyle(fontSize: 12, color: palette.textSecondary)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (var i = 0; i < ids.length; i++)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: palette.bgAlt,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: palette.border),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _talkNames[ids[i].toString()]?.isNotEmpty == true
                          ? _talkNames[ids[i].toString()]!
                          : '对话 ${ids[i]}',
                      style: TextStyle(
                          fontSize: 11.5, color: palette.textPrimary),
                    ),
                    const SizedBox(width: 6),
                    MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: GestureDetector(
                        onTap: () => onRemove(i),
                        child: Icon(FluentIcons.dismiss_24_regular,
                            size: 11, color: palette.textMuted),
                      ),
                    ),
                  ],
                ),
              ),
            MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                onTap: onAdd,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: palette.card,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: palette.borderHover),
                  ),
                  child: Text('＋ 选择对话',
                      style: TextStyle(fontSize: 11.5, color: accentColor)),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _labeled(String label, Widget child) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: palette.textSecondary)),
          const SizedBox(height: 7),
          child,
        ],
      ),
    );
  }
}

// ----------------------------------------------------------------------
// 通用小部件
// ----------------------------------------------------------------------

class _Tag extends StatelessWidget {
  const _Tag({required this.text, required this.color});
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(text, style: TextStyle(fontSize: 11, color: color)),
    );
  }
}

class _GoalListItem extends StatefulWidget {
  const _GoalListItem({
    required this.id,
    required this.name,
    required this.npcId,
    required this.npcName,
    required this.desc,
    required this.tag,
    required this.selected,
    required this.onTap,
  });

  final String id;
  final String name;
  final int npcId;
  final String npcName;
  final String desc;
  final int tag;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_GoalListItem> createState() => _GoalListItemState();
}

class _GoalListItemState extends State<_GoalListItem> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final selected = widget.selected;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Container(
          margin: const EdgeInsets.only(bottom: 7),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: selected
                ? accentColor.withValues(alpha: 0.12)
                : _hover
                    ? palette.card
                    : palette.bgAlt,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: selected
                  ? accentColor.withValues(alpha: 0.45)
                  : palette.border,
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              RoleAvatar(seed: widget.npcId, name: widget.npcName, size: 38),
              const SizedBox(width: 9),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(widget.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 12.5,
                                  fontWeight: selected
                                      ? FontWeight.w600
                                      : FontWeight.normal,
                                  color: selected
                                      ? palette.textHigh
                                      : palette.textPrimary)),
                        ),
                        Text(widget.id,
                            style: TextStyle(
                                fontSize: 10, color: palette.textHint)),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      widget.desc.trim().isEmpty ? '（没有描述）' : widget.desc,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 11.5,
                          height: 1.5,
                          color: palette.textMuted),
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

class _RefDropdown extends StatelessWidget {
  const _RefDropdown({
    required this.value,
    required this.options,
    required this.onChanged,
    this.zeroLabel = '未设置',
  });

  final int value;
  final Map<String, String> options;
  final ValueChanged<int> onChanged;
  final String zeroLabel;

  @override
  Widget build(BuildContext context) {
    final entries = options.entries.toList()
      ..sort((a, b) {
        final an = int.tryParse(a.key);
        final bn = int.tryParse(b.key);
        if (an != null && bn != null) return an.compareTo(bn);
        return a.key.compareTo(b.key);
      });
    final has = value == 0 || options.containsKey(value.toString());
    return fluent.ComboBox<int>(
      value: has ? value : 0,
      isExpanded: true,
      items: [
        fluent.ComboBoxItem<int>(
          value: 0,
          child: Text(zeroLabel, style: const TextStyle(fontSize: 12)),
        ),
        for (final e in entries)
          fluent.ComboBoxItem<int>(
            value: int.tryParse(e.key) ?? 0,
            child: Text(e.value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12)),
          ),
        if (!has)
          fluent.ComboBoxItem<int>(
            value: value,
            child: Text('保留原值 $value',
                style: const TextStyle(fontSize: 12)),
          ),
      ],
      onChanged: (v) {
        if (v != null) onChanged(v);
      },
    );
  }
}
class _SegButton extends StatefulWidget {
  const _SegButton({
    required this.label,
    required this.onTap,
    this.selected = false,
  });

  final String label;
  final VoidCallback onTap;
  final bool selected;

  @override
  State<_SegButton> createState() => _SegButtonState();
}

class _SegButtonState extends State<_SegButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final selected = widget.selected;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: AppMotion.fast,
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
          decoration: BoxDecoration(
            color: selected
                ? accentColor.withValues(alpha: 0.16)
                : _hover
                    ? palette.card
                    : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: selected
                  ? accentColor.withValues(alpha: 0.45)
                  : palette.border,
            ),
          ),
          child: Text(
            widget.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              color: selected ? palette.textHigh : palette.textSecondary,
              fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
            ),
          ),
        ),
      ),
    );
  }
}
