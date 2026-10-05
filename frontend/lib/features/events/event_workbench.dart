import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../../core/api_client.dart';
import '../../core/app_dialogs.dart';
import '../../core/app_theme.dart';
import '../../core/models.dart';
import '../../core/motion.dart';
import '../../core/workbench_guard.dart';
import '../../core/workbench_scaffold.dart';
import '../blocks/block_library.dart';
import '../editor/field_utils.dart';
import '../nocode/entity_picker.dart' show RoleEntry, loadRoles;

/// 事件工作台 —— 导演布局下「事件」的专属界面。
///
/// 三栏：事件列表（筛选 / 搜索 / 新建 / 删除）｜事件详情（基本信息 / 触发与效果 /
/// 对白入口 / 选项 / 内容）｜概览与引用。
///
/// 只编辑 `EvtCfg`（整表读写 + `expect_mtime_ns` 乐观锁）；`TalkCfg` / `OptionCfg`
/// 只读用于对白与选项预览，实际内容去剧情处理 / 剧情舞台编辑。
/// 条件 / 效果两栏直接复用「积木库」，把代码行做成可视化积木。
class EventWorkbench extends StatefulWidget {
  const EventWorkbench({
    super.key,
    required this.state,
    this.onOpenSearch,
    this.onOpenStudio,
  });

  final AppState state;
  final VoidCallback? onOpenSearch;

  /// 打开剧情舞台（可选）。
  final VoidCallback? onOpenStudio;

  @override
  State<EventWorkbench> createState() => _EventWorkbenchState();
}

/// 事件筛选组（含事件类型 id 集合；null = 不按类型过滤）。
const _eventFilters = <List<Object?>>[
  ['all', '全部', null],
  ['start', '回合开始', [0]],
  ['end', '结束回合', [3]],
  ['action', '行动', [4]],
  ['social', '社交', [2, 11, 21, 22, 110, 520, 521, 522, 523]],
  ['relation', '关系', [20]],
  ['button', '按钮', [101, 102, 10]],
  ['other', '其他', null],
];

class _EventWorkbenchState extends State<EventWorkbench>
    with WorkbenchLeaveGuard<EventWorkbench> {
  static const _cfg = 'EvtCfg';

  Map<String, dynamic> _rows = {};
  String _snap = '';
  int? _mtime;

  Map<String, dynamic> _types = {};
  Map<String, dynamic> _talks = {};
  Map<String, dynamic> _options = {};

  bool _loading = true;
  bool _saving = false;
  bool _refsLoading = false;
  String? _error;

  String? _selected;
  String _filter = 'all';
  String _search = '';
  String _sort = 'id';

  List<RoleEntry> _roles = const [];

  final TextEditingController _searchCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadAll();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------------
  // 数据
  // ------------------------------------------------------------------

  Map<String, dynamic> _dataOf(dynamic r) {
    if (r is Map && r['data'] is Map) {
      return (r['data'] as Map).cast<String, dynamic>();
    }
    return <String, dynamic>{};
  }

  int? _mtimeOf(dynamic r) =>
      (r is Map && r['mtime_ns'] is int) ? r['mtime_ns'] as int : null;

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
  String get guardSubject => '事件';

  Future<void> _loadAll() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await Future.wait([
        ApiClient.instance.get('/api/cfg/$_cfg'),
        ApiClient.instance.get('/api/cfg/EvtTypeCfg'),
      ]);
      if (!mounted) return;
      _rows = _dataOf(res[0]);
      _types = _dataOf(res[1]);
      _mtime = _mtimeOf(res[0]);
      _snap = jsonEncode(_rows);
      final ids = _sortedIds;
      if (_selected == null || !_rows.containsKey(_selected)) {
        _selected = ids.isNotEmpty ? ids.first : null;
      }
      setState(() => _loading = false);
      _loadRoles();
      _loadRefs();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _loadRoles() async {
    final list = await loadRoles('');
    if (!mounted) return;
    setState(() => _roles = list);
  }

  /// 懒加载对白与选项（仅用于预览；失败静默）。
  Future<void> _loadRefs() async {
    if (_refsLoading) return;
    _refsLoading = true;
    try {
      final res = await Future.wait([
        ApiClient.instance.get('/api/cfg/TalkCfg'),
        ApiClient.instance.get('/api/cfg/OptionCfg'),
      ]);
      if (!mounted) return;
      setState(() {
        _talks = _dataOf(res[0]);
        _options = _dataOf(res[1]);
      });
    } catch (_) {
      // 引用表读不到：预览退化为「对话 <id>」。
    } finally {
      _refsLoading = false;
    }
  }

  bool get _dirty => _snap != jsonEncode(_rows);

  Future<void> _saveAll() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      var force = false;
      for (;;) {
        if (jsonEncode(_rows) == _snap) break;
        try {
          final body = <String, dynamic>{
            'data': _rows,
            if (!force) 'expect_mtime_ns': _mtime,
            if (force) 'force': true,
          };
          final r = await ApiClient.instance.put('/api/cfg/$_cfg', body: body);
          if (!mounted) return;
          setState(() {
            _mtime = _mtimeOf(r);
            _snap = jsonEncode(_rows);
          });
          break;
        } on ApiException catch (e) {
          if (!mounted) return;
          if (e.statusCode == 409 && !force) {
            final act = await _conflictDialog();
            if (!mounted) return;
            if (act == 'reload') {
              await _loadAll();
              return;
            }
            if (act == 'force') {
              force = true;
              continue;
            }
            return;
          }
          _info('保存失败：$e', fluent.InfoBarSeverity.error);
          return;
        } catch (e) {
          if (!mounted) return;
          _info('保存失败：$e', fluent.InfoBarSeverity.error);
          return;
        }
      }
      if (mounted) {
        _info('事件已保存', fluent.InfoBarSeverity.success);
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _discard() {
    setState(() {
      _rows = (jsonDecode(_snap) as Map).cast<String, dynamic>();
      final ids = _sortedIds;
      if (_selected == null || !_rows.containsKey(_selected)) {
        _selected = ids.isNotEmpty ? ids.first : null;
      }
    });
  }

  Future<String?> _conflictDialog() {
    return fluent.showDialog<String>(
      context: context,
      builder: (ctx) => AppContentDialog(
        title: const Text('文件冲突'),
        content: Text(
          '$_cfg 已被外部修改（可能被游戏或其他端改写）。\n'
          '重新加载将放弃本地未保存的修改；强制覆盖将用当前编辑内容覆盖磁盘文件。',
          style: TextStyle(
              fontSize: 12.5, color: palette.textPrimary, height: 1.5),
        ),
        actions: [
          fluent.Button(
            onPressed: () => Navigator.pop(ctx, 'reload'),
            child: const Text('重新加载'),
          ),
          fluent.FilledButton(
            onPressed: () => Navigator.pop(ctx, 'force'),
            child: const Text('强制覆盖'),
          ),
        ],
      ),
    );
  }

  void _info(String msg, fluent.InfoBarSeverity severity) {
    if (!mounted) return;
    fluent.displayInfoBar(
      context,
      builder: (ctx, close) => fluent.InfoBar(
        title: Text(msg),
        severity: severity,
      ),
    );
  }

  // ------------------------------------------------------------------
  // 行访问
  // ------------------------------------------------------------------

  Map<String, dynamic>? _rowOf(String id) {
    final v = _rows[id];
    return v is Map ? v.cast<String, dynamic>() : null;
  }

  Map<String, dynamic>? get _row =>
      _selected == null ? null : _rowOf(_selected!);

  List<String> get _sortedIds {
    final ids = _rows.keys.toList();
    if (_sort == 'name') {
      ids.sort((a, b) {
        final c = _title(a).compareTo(_title(b));
        return c != 0 ? c : (int.tryParse(a) ?? 0).compareTo(int.tryParse(b) ?? 0);
      });
    } else {
      ids.sort((a, b) =>
          (int.tryParse(a) ?? 0).compareTo(int.tryParse(b) ?? 0));
    }
    return ids;
  }

  String _title(String id) {
    final t = _rowOf(id)?['title']?.toString().trim() ?? '';
    return t.isEmpty ? '未命名事件' : t;
  }

  int _intOf(Map<String, dynamic>? row, String field) {
    final v = row?[field];
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? '') ?? 0;
  }

  List<int> _intList(Map<String, dynamic>? row, String field) {
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

  int _lenOf(Map<String, dynamic>? row, String field) {
    final v = row?[field];
    return v is List ? v.length : 0;
  }

  String _typeName(Object? t) {
    final id = t is num ? t.toInt() : int.tryParse(t?.toString() ?? '');
    if (id == null) return '未设置类型';
    final row = _types[id.toString()];
    if (row is Map) {
      final n = row['name']?.toString().trim() ?? '';
      if (n.isNotEmpty) return n;
    }
    return '事件类型 $id';
  }

  String _roleName(int id) {
    for (final r in _roles) {
      if (r.id == id.toString()) return r.name.isEmpty ? '角色 $id' : r.name;
    }
    return id == 0 ? '无' : '角色 $id';
  }

  String _talkSummary(int id) {
    final row = _talks[id.toString()];
    if (row is! Map) return '对话 $id（未载入）';
    final content = _plain(row['content']?.toString() ?? '');
    final speaker = _roleName(_intList(
                row.cast<String, dynamic>(), 'roleIds')
            .isNotEmpty
        ? _intList(row.cast<String, dynamic>(), 'roleIds').first
        : 0);
    final prefix = speaker == '无' ? '' : '$speaker：';
    return '$prefix${content.isEmpty ? '（空白对白）' : content}';
  }

  String _optionSummary(int id) {
    final row = _options[id.toString()];
    if (row is! Map) return '选项 $id（未载入）';
    final content = _plain(row['content']?.toString() ?? '');
    return content.isEmpty ? '（空白选项）' : content;
  }

  String _plain(String s) {
    final t = s.replaceAll(RegExp(r'<[^>]*>'), '').trim();
    return t.length > 48 ? '${t.substring(0, 48)}…' : t;
  }

  int _newId() {
    var max = 0;
    for (final k in _rows.keys) {
      final v = int.tryParse(k);
      if (v != null && v > max) max = v;
    }
    return max == 0 ? 1 : max + 1;
  }

  bool _matchesFilter(Map<String, dynamic>? row) {
    if (_filter == 'all') return true;
    final type = _intOf(row, 'type');
    if (_filter == 'other') {
      for (final f in _eventFilters) {
        final ids = f[2] as List<int>?;
        if (ids != null && ids.contains(type)) return false;
      }
      return true;
    }
    final spec = _eventFilters.firstWhere(
      (f) => f[0] == _filter,
      orElse: () => const ['all', '全部', null],
    );
    final ids = spec[2] as List<int>?;
    return ids == null || ids.contains(type);
  }

  /// 从对白入口出发可达的对白集合（含选项跳转）。
  Set<int> _reachableTalks(List<int> starts) {
    final visited = <int>{};
    final stack = [...starts.reversed];
    while (stack.isNotEmpty) {
      final id = stack.removeLast();
      if (!visited.add(id)) continue;
      final t = _talks[id.toString()];
      if (t is! Map) continue;
      final tr = t.cast<String, dynamic>();
      for (final n in _intList(tr, 'nextTalk')) {
        stack.add(n);
      }
      for (final n in _intList(tr, 'nextTalk2')) {
        stack.add(n);
      }
      for (final o in _intList(tr, 'option')) {
        final opt = _options[o.toString()];
        if (opt is! Map) continue;
        final or = opt.cast<String, dynamic>();
        for (final n in _intList(or, 'talkId')) {
          stack.add(n);
        }
        for (final n in _intList(or, 'talkId2')) {
          stack.add(n);
        }
      }
    }
    return visited;
  }

  String _firstLine(Map<String, dynamic>? row) {
    for (final id in _intList(row, 'talkId')) {
      if (_talks.containsKey(id.toString())) return _talkSummary(id);
    }
    return '';
  }

  List<String> _referencedBy(int id) {
    final out = <String>[];
    for (final e in _rows.entries) {
      if (e.key == _selected) continue;
      final r = e.value is Map ? (e.value as Map).cast<String, dynamic>() : null;
      if (_intList(r, 'replace').contains(id)) {
        out.add('事件 ${e.key} 覆盖');
      }
    }
    for (final o in _options.entries) {
      final r = o.value is Map ? (o.value as Map).cast<String, dynamic>() : null;
      if (_intOf(r, 'nextEvtId') == id) {
        out.add('选项 ${o.key} 跳转');
      }
    }
    return out;
  }

  // ------------------------------------------------------------------
  // 编辑操作
  // ------------------------------------------------------------------

  void _addEvent() {
    final id = _newId().toString();
    setState(() {
      _rows[id] = <String, dynamic>{
        'id': int.tryParse(id),
        'title': '未命名事件',
        'type': 1,
        'talkId': <dynamic>[],
        'rate': 1,
        'npc': 0,
        'maxcount': 0,
        'mapId': 0,
        'effect': <dynamic>[],
        'condition': <dynamic>[],
        'displayType': 0,
        'content': '',
        'desc': '',
        'maxoptions': 0,
        'miniGame': <dynamic>[],
        'options': <dynamic>[],
        'probability': <dynamic>[],
        'replace': <dynamic>[],
        'weight': 1,
      };
      _selected = id;
      _filter = 'all';
    });
  }

  void _deleteEvent() {
    final id = _selected;
    if (id == null) return;
    setState(() {
      _rows.remove(id);
      final ids = _sortedIds;
      _selected = ids.isNotEmpty ? ids.first : null;
    });
  }

  void _addToIntList(Map<String, dynamic> row, String field, int value) {
    final list = _intList(row, field);
    if (!list.contains(value)) {
      row[field] = [...list, value];
    }
  }

  void _removeFromIntList(Map<String, dynamic> row, String field, int i) {
    final list = _intList(row, field);
    if (i < 0 || i >= list.length) return;
    list.removeAt(i);
    row[field] = list;
  }

  void _moveInIntList(Map<String, dynamic> row, String field, int i, int d) {
    final list = _intList(row, field);
    final j = i + d;
    if (i < 0 || j < 0 || i >= list.length || j >= list.length) return;
    final v = list.removeAt(i);
    list.insert(j, v);
    row[field] = list;
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
            title: const Text('选择关联人物'),
            content: SizedBox(
              width: 440,
              height: 420,
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
                        _pickerRow(ctx, 0, '无'),
                        for (final r in rows)
                          _pickerRow(ctx, int.tryParse(r.id) ?? 0, r.name,
                              sub: r.id),
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

  /// 对白 / 选项的通用选择器。
  Future<int?> _pickFromTable(String table) async {
    await _loadRefs();
    if (!mounted) return null;
    final data = table == 'TalkCfg' ? _talks : _options;
    var query = '';
    final entries = data.entries.toList()
      ..sort((a, b) =>
          (int.tryParse(a.key) ?? 0).compareTo(int.tryParse(b.key) ?? 0));
    return fluent.showDialog<int>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) {
          final list = entries.where((e) {
            if (query.isEmpty) return true;
            final content =
                _plain((e.value is Map ? (e.value as Map)['content'] : '')
                        ?.toString() ??
                    '');
            return e.key.contains(query) ||
                content.toLowerCase().contains(query);
          }).toList();
          return AppContentDialog(
            title: Text(table == 'TalkCfg' ? '选择对白' : '选择选项'),
            content: SizedBox(
              width: 500,
              height: 460,
              child: Column(
                children: [
                  fluent.TextBox(
                    placeholder: '搜索内容或编号',
                    onChanged: (v) =>
                        setLocal(() => query = v.trim().toLowerCase()),
                  ),
                  const SizedBox(height: 10),
                  Expanded(
                    child: list.isEmpty
                        ? Center(
                            child: Text('没有匹配的条目',
                                style: TextStyle(
                                    fontSize: 12, color: palette.textHint)))
                        : ListView.builder(
                            itemCount: list.length,
                            itemBuilder: (c, i) {
                              final e = list[i];
                              final summary = table == 'TalkCfg'
                                  ? _talkSummary(int.tryParse(e.key) ?? 0)
                                  : _optionSummary(int.tryParse(e.key) ?? 0);
                              return _pickerRow(ctx,
                                  int.tryParse(e.key) ?? 0, summary,
                                  sub: e.key);
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

  Widget _pickerRow(BuildContext ctx, int id, String name, {String? sub}) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => Navigator.pop(ctx, id),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
          child: Row(
            children: [
              if (sub != null)
                SizedBox(
                  width: 64,
                  child: Text(sub,
                      style:
                          TextStyle(fontSize: 10.5, color: palette.textHint)),
                ),
              Expanded(
                child: Text(name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 12.5, color: palette.textPrimary)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 用积木库编辑条件 / 效果数组。
  Future<void> _editBlocks(Map<String, dynamic> row, String field,
      String mode) async {
    final current = row[field];
    final out = await showBlockLibrary(
      context,
      initialText: ValueCodec.encode(current ?? const <dynamic>[]),
      initialMode: mode,
      gameDicts: widget.state.gameDicts,
      title: mode == 'condition' ? '积木库 · 条件' : '积木库 · 效果',
    );
    if (out == null || !mounted) return;
    setState(() => row[field] = ValueCodec.decode(out, '2D Array'));
  }

  // ------------------------------------------------------------------
  // 构建
  // ------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Container(
        color: palette.bgDeep2,
        child: const Center(child: fluent.ProgressRing()),
      );
    }
    if (_error != null) {
      return Container(
        color: palette.bgDeep2,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(FluentIcons.error_circle_24_regular,
                  size: 34, color: palette.statusDanger),
              const SizedBox(height: 10),
              Text('事件数据加载失败',
                  style: TextStyle(fontSize: 13, color: palette.textPrimary)),
              const SizedBox(height: 6),
              Text('$_error',
                  style: TextStyle(fontSize: 11, color: palette.textMuted)),
              const SizedBox(height: 12),
              fluent.Button(onPressed: _loadAll, child: const Text('重试')),
            ],
          ),
        ),
      );
    }

    return WorkbenchScaffold(
      leftBuilder: (w) => _leftPanel(w),
      center: _center(),
      rightBuilder: (w) => _rightPanel(w),
      rightLabel: '概览与引用',
      rightIcon: FluentIcons.info_24_regular,
    );
  }

  // ---------- 左栏 ----------

  Widget _leftPanel(double w) {
    final q = _search.trim().toLowerCase();
    final ids = _sortedIds.where((id) {
      final row = _rowOf(id);
      if (!_matchesFilter(row)) return false;
      if (q.isEmpty) return true;
      return id.contains(q) ||
          _title(id).toLowerCase().contains(q) ||
          (row?['content']?.toString().toLowerCase() ?? '').contains(q) ||
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
                  placeholder: '搜索事件名称 / 内容',
                  onChanged: (v) => setState(() => _search = v),
                ),
                const SizedBox(height: 10),
                fluent.FilledButton(
                  onPressed: _addEvent,
                  child: const Text('＋ 新建事件',
                      style: TextStyle(fontSize: 12.5)),
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Expanded(
                      child: _MiniBtn(
                        label: _sort == 'id' ? '按 ID 排序' : '按名称排序',
                        onTap: () => setState(
                            () => _sort = _sort == 'id' ? 'name' : 'id'),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: _MiniBtn(
                        label: '删除事件',
                        danger: true,
                        enabled: _selected != null,
                        onTap: _deleteEvent,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          SizedBox(
            height: 34,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              children: [
                for (final f in _eventFilters)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: _FilterChip(
                      label: f[1] as String,
                      selected: _filter == f[0],
                      onTap: () => setState(() => _filter = f[0] as String),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Divider(height: 1, color: palette.border),
          Expanded(
            child: ids.isEmpty
                ? Center(
                    child: Text(
                      _rows.isEmpty ? '还没有事件，点「新建事件」。' : '没有匹配的事件。',
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
                      final talks = _intList(row, 'talkId');
                      final count =
                          _talks.isEmpty ? talks.length : _reachableTalks(talks).length;
                      return _EventListItem(
                        id: id,
                        title: _title(id),
                        typeName: _typeName(row?['type']),
                        dialogueCount: count,
                        conditionSummary: _lenOf(row, 'condition') == 0
                            ? '未设置额外触发条件'
                            : '${_lenOf(row, 'condition')} 项触发条件',
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

  // ---------- 中栏 ----------

  Widget _center() {
    final row = _row;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: row == null
              ? Center(
                  child: Text(
                    '新建或选择左侧事件，编辑触发条件、对白入口与选项。',
                    style: TextStyle(fontSize: 13, color: palette.textHint),
                  ),
                )
              : SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(22, 20, 22, 24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _basicSection(row),
                      _triggerSection(row),
                      _talkSection(row),
                      _optionSection(row),
                      _extraSection(row),
                      _contentSection(row),
                    ],
                  ),
                ),
        ),
        _saveBar(),
      ],
    );
  }

  Widget _basicSection(Map<String, dynamic> row) {
    return _SectionCard(
      title: '基本信息',
      icon: FluentIcons.info_24_regular,
      children: [
        _labeled('事件标题', _SyncedText(
          value: row['title']?.toString() ?? '',
          hint: '事件标题',
          onChanged: (v) => setState(() => row['title'] = v),
        )),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: _labeled(
                '事件类型',
                _types.isEmpty
                    ? _NumBox(
                        value: _intOf(row, 'type'),
                        hint: '事件类型编号',
                        onChanged: (v) =>
                            setState(() => row['type'] = (v ?? 0).toInt()),
                      )
                    : _TypeDropdown(
                        value: _intOf(row, 'type'),
                        types: _types,
                        onChanged: (v) => setState(() => row['type'] = v),
                      ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _labeled('显示方式', _NumBox(
                value: _intOf(row, 'displayType'),
                hint: 'displayType',
                onChanged: (v) =>
                    setState(() => row['displayType'] = (v ?? 0).toInt()),
              )),
            ),
          ],
        ),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: _labeled('触发概率', _NumBox(
                value: _rateOf(row),
                hint: '0~1，1 为 100%',
                onChanged: (v) => setState(() => row['rate'] = v ?? 0),
              )),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _labeled('次数上限', _NumBox(
                value: _intOf(row, 'maxcount'),
                hint: '0 表示不限',
                onChanged: (v) =>
                    setState(() => row['maxcount'] = (v ?? 0).toInt()),
              )),
            ),
          ],
        ),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: _labeled(
                '关联人物',
                MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    onTap: () async {
                      final pid = await _pickRole();
                      if (pid == null || !mounted) return;
                      setState(() => row['npc'] = pid);
                    },
                    child: _valueBox(
                      _intOf(row, 'npc') == 0
                          ? '无'
                          : _roleName(_intOf(row, 'npc')),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _labeled('权重', _NumBox(
                value: _intOf(row, 'weight'),
                hint: '同组抽取使用',
                onChanged: (v) =>
                    setState(() => row['weight'] = (v ?? 0).toInt()),
              )),
            ),
          ],
        ),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: _labeled('地图编号', _NumBox(
                value: _intOf(row, 'mapId'),
                hint: 'mapId',
                onChanged: (v) =>
                    setState(() => row['mapId'] = (v ?? 0).toInt()),
              )),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _labeled('最大选项数', _NumBox(
                value: _intOf(row, 'maxoptions'),
                hint: 'maxoptions',
                onChanged: (v) =>
                    setState(() => row['maxoptions'] = (v ?? 0).toInt()),
              )),
            ),
          ],
        ),
      ],
    );
  }

  num _rateOf(Map<String, dynamic> row) {
    final v = row['rate'];
    if (v is num) return v;
    return num.tryParse(v?.toString() ?? '') ?? 0;
  }

  Widget _triggerSection(Map<String, dynamic> row) {
    return _SectionCard(
      title: '触发与效果',
      icon: FluentIcons.flash_24_regular,
      subtitle: '用积木库可视化编辑，可随时在通用配置表核对。',
      children: [
        _listLine(
          '出现条件',
          '${_lenOf(row, 'condition')} 条',
          palette.statusInfo,
          () => _editBlocks(row, 'condition', 'condition'),
        ),
        const SizedBox(height: 8),
        _listLine(
          '事件效果',
          '${_lenOf(row, 'effect')} 条',
          palette.statusOk,
          () => _editBlocks(row, 'effect', 'effect'),
        ),
      ],
    );
  }

  Widget _talkSection(Map<String, dynamic> row) {
    final talks = _intList(row, 'talkId');
    final reachable = _talks.isEmpty ? talks.length : _reachableTalks(talks).length;
    return _SectionCard(
      title: '对白入口',
      icon: FluentIcons.chat_24_regular,
      subtitle: _refsLoading
          ? '正在载入对白…'
          : '事件从这里的第一句对白开始播放；共 $reachable 句可达对白。',
      children: [
        for (var i = 0; i < talks.length; i++)
          _refRow(
            index: i,
            label: _talkSummary(talks[i]),
            sub: '对白 ${talks[i]}',
            onUp: i == 0
                ? null
                : () => setState(() => _moveInIntList(row, 'talkId', i, -1)),
            onDown: i == talks.length - 1
                ? null
                : () => setState(() => _moveInIntList(row, 'talkId', i, 1)),
            onRemove: () => setState(() => _removeFromIntList(row, 'talkId', i)),
          ),
        const SizedBox(height: 6),
        _MiniBtn(
          label: '＋ 添加对白入口',
          onTap: () async {
            final id = await _pickFromTable('TalkCfg');
            if (id == null || !mounted) return;
            setState(() => _addToIntList(row, 'talkId', id));
          },
        ),
      ],
    );
  }

  Widget _optionSection(Map<String, dynamic> row) {
    final options = _intList(row, 'options');
    return _SectionCard(
      title: '选项',
      icon: FluentIcons.list_24_regular,
      subtitle: _refsLoading ? '正在载入选项…' : '事件弹出的可选项（内容在 OptionCfg 编辑）。',
      children: [
        for (var i = 0; i < options.length; i++)
          _refRow(
            index: i,
            label: _optionSummary(options[i]),
            sub: '选项 ${options[i]}',
            onUp: i == 0
                ? null
                : () => setState(() => _moveInIntList(row, 'options', i, -1)),
            onDown: i == options.length - 1
                ? null
                : () => setState(() => _moveInIntList(row, 'options', i, 1)),
            onRemove: () =>
                setState(() => _removeFromIntList(row, 'options', i)),
          ),
        const SizedBox(height: 6),
        _MiniBtn(
          label: '＋ 添加选项',
          onTap: () async {
            final id = await _pickFromTable('OptionCfg');
            if (id == null || !mounted) return;
            setState(() => _addToIntList(row, 'options', id));
          },
        ),
      ],
    );
  }

  Widget _extraSection(Map<String, dynamic> row) {
    return _SectionCard(
      title: '其他数组',
      icon: FluentIcons.number_symbol_24_regular,
      children: [
        _numListEditor(row, 'miniGame', '小游戏'),
        const SizedBox(height: 8),
        _numListEditor(row, 'probability', '概率权重'),
        const SizedBox(height: 8),
        _numListEditor(row, 'replace', '覆盖事件'),
      ],
    );
  }

  Widget _numListEditor(Map<String, dynamic> row, String field, String label) {
    final list = _intList(row, field);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('$label（${list.length}）',
            style: TextStyle(fontSize: 12, color: palette.textSecondary)),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (var i = 0; i < list.length; i++)
              _Chip(
                text: list[i].toString(),
                onRemove: () => setState(() => _removeFromIntList(row, field, i)),
              ),
            _MiniChip(
              label: '＋',
              onTap: () => setState(() => _addToIntList(row, field, 0)),
            ),
          ],
        ),
      ],
    );
  }

  Widget _contentSection(Map<String, dynamic> row) {
    return _SectionCard(
      title: '内容与说明',
      icon: FluentIcons.text_description_24_regular,
      children: [
        _labeled('事件内容', _SyncedText(
          value: row['content']?.toString() ?? '',
          hint: '无对白事件的正文 / 通知文本',
          maxLines: 4,
          onChanged: (v) => setState(() => row['content'] = v),
        )),
        _labeled('内部说明', _SyncedText(
          value: row['desc']?.toString() ?? '',
          hint: '给自己看的说明，不影响游戏',
          maxLines: 3,
          onChanged: (v) => setState(() => row['desc'] = v),
        )),
      ],
    );
  }

  Widget _saveBar() {
    final dirty = _dirty;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: palette.panel,
        border: Border(top: BorderSide(color: palette.border)),
      ),
      child: Row(
        children: [
          Icon(
            dirty
                ? FluentIcons.circle_24_filled
                : FluentIcons.checkmark_circle_24_regular,
            size: 12,
            color: dirty ? palette.statusWarn : palette.statusOk,
          ),
          const SizedBox(width: 6),
          Text(dirty ? '有未保存的修改' : '已与磁盘同步',
              style: TextStyle(fontSize: 11.5, color: palette.textSecondary)),
          const Spacer(),
          if (widget.onOpenSearch != null)
            _MiniBtn(label: '检索剧情库', onTap: widget.onOpenSearch!),
          const SizedBox(width: 8),
          _MiniBtn(
            label: '放弃修改',
            enabled: dirty && !_saving,
            onTap: _discard,
          ),
          const SizedBox(width: 8),
          fluent.FilledButton(
            onPressed: (!dirty || _saving) ? null : _saveAll,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_saving)
                  const SizedBox(
                    width: 12,
                    height: 12,
                    child: fluent.ProgressRing(strokeWidth: 2),
                  )
                else
                  const Icon(FluentIcons.save_24_regular, size: 13),
                const SizedBox(width: 6),
                const Text('保存修改', style: TextStyle(fontSize: 12.5)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ---------- 右栏 ----------

  Widget _rightPanel(double w) {
    final row = _row;
    final id = _selected;
    return Container(
      width: w,
      color: palette.panel,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        child: row == null || id == null
            ? Text('选择左侧事件查看概览。',
                style: TextStyle(fontSize: 12, color: palette.textHint))
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_title(id),
                      style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: palette.textHigh)),
                  const SizedBox(height: 4),
                  Text('事件 ID $id',
                      style:
                          TextStyle(fontSize: 11, color: palette.textHint)),
                  const SizedBox(height: 14),
                  _railCard('概览', [
                    '类型：${_typeName(row['type'])}',
                    '对白入口：${_intList(row, 'talkId').length} 个',
                    '可达对白：${_talks.isEmpty ? _intList(row, 'talkId').length : _reachableTalks(_intList(row, 'talkId')).length} 句',
                    '选项：${_intList(row, 'options').length} 个',
                    '触发概率：${_formatRate(_rateOf(row))}',
                  ]),
                  const SizedBox(height: 12),
                  _railCard('首句预览', [
                    _firstLine(row).isEmpty ? '（无对白，走事件效果）' : _firstLine(row),
                  ]),
                  const SizedBox(height: 12),
                  _railCard('触发条件', [
                    _lenOf(row, 'condition') == 0
                        ? '未设置额外触发条件（由事件类型与入口决定）。'
                        : '${_lenOf(row, 'condition')} 条，在「触发与效果」用积木库编辑。',
                  ]),
                  const SizedBox(height: 12),
                  _railCard('被引用', _referencedBy(int.tryParse(id) ?? -1)
                      .let((refs) => refs.isEmpty
                          ? ['没有被其他事件或选项引用。']
                          : refs)),
                ],
              ),
      ),
    );
  }

  String _formatRate(num rate) {
    final v = rate.toDouble();
    if (v >= 0 && v <= 1) return '${(v * 100).toStringAsFixed(0)}%';
    return v.toString();
  }

  Widget _railCard(String title, List<String> lines) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(13, 11, 13, 12),
      decoration: BoxDecoration(
        color: palette.bgAlt,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: palette.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: palette.goldText)),
          const SizedBox(height: 8),
          for (final l in lines)
            Padding(
              padding: const EdgeInsets.only(bottom: 5),
              child: Text(l,
                  style: TextStyle(
                      fontSize: 11.5, height: 1.6, color: palette.textMuted)),
            ),
        ],
      ),
    );
  }

  // ---------- 通用小组件 ----------

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

  Widget _valueBox(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: palette.bgAlt,
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: palette.border),
      ),
      child: Text(text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 12.5, color: palette.textPrimary)),
    );
  }

  Widget _listLine(
      String label, String value, Color color, VoidCallback onTap) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
          decoration: BoxDecoration(
            color: palette.bgAlt,
            borderRadius: BorderRadius.circular(7),
            border: Border.all(color: palette.border),
          ),
          child: Row(
            children: [
              Text(label,
                  style:
                      TextStyle(fontSize: 12, color: palette.textPrimary)),
              const SizedBox(width: 8),
              _Tag(text: value, color: color),
              const Spacer(),
              Text('积木编辑',
                  style: TextStyle(fontSize: 11, color: accentColor)),
              const SizedBox(width: 4),
              Icon(FluentIcons.chevron_right_24_regular,
                  size: 12, color: accentColor),
            ],
          ),
        ),
      ),
    );
  }

  Widget _refRow({
    required int index,
    required String label,
    required String sub,
    VoidCallback? onUp,
    VoidCallback? onDown,
    required VoidCallback onRemove,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 7, 6, 7),
        decoration: BoxDecoration(
          color: palette.bgAlt,
          borderRadius: BorderRadius.circular(7),
          border: Border.all(color: palette.border),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 12, color: palette.textPrimary)),
                  Text(sub,
                      style:
                          TextStyle(fontSize: 10, color: palette.textHint)),
                ],
              ),
            ),
            _iconAct('up', FluentIcons.arrow_up_24_regular, onUp),
            _iconAct('down', FluentIcons.arrow_down_24_regular, onDown),
            _iconAct('del', FluentIcons.delete_24_regular, onRemove,
                color: palette.statusDanger),
          ],
        ),
      ),
    );
  }

  Widget _iconAct(String key, IconData icon, VoidCallback? onTap,
      {Color? color}) {
    return fluent.IconButton(
      icon: Icon(icon, size: 13, color: color ?? palette.textMuted),
      onPressed: onTap,
    );
  }
}

/// 便于右栏「被引用」内联表达。
extension _Let<T> on T {
  R let<R>(R Function(T) f) => f(this);
}

// ---------------------------------------------------------------------------
// 通用小部件
// ---------------------------------------------------------------------------

class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.title,
    required this.children,
    this.icon,
    this.subtitle,
  });

  final String title;
  final IconData? icon;
  final String? subtitle;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      decoration: BoxDecoration(
        color: palette.card,
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: palette.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (icon != null) ...[
                Icon(icon, size: 14, color: palette.goldText),
                const SizedBox(width: 6),
              ],
              Text(title,
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: palette.textHigh)),
            ],
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 4),
            Text(subtitle!,
                style: TextStyle(
                    fontSize: 11, height: 1.6, color: palette.textMuted)),
          ],
          const SizedBox(height: 12),
          for (final c in children) c,
        ],
      ),
    );
  }
}

class _SyncedText extends StatefulWidget {
  const _SyncedText({
    required this.value,
    required this.onChanged,
    this.hint,
    this.maxLines = 1,
  });

  final String value;
  final ValueChanged<String> onChanged;
  final String? hint;
  final int maxLines;

  @override
  State<_SyncedText> createState() => _SyncedTextState();
}

class _SyncedTextState extends State<_SyncedText> {
  late final TextEditingController _c =
      TextEditingController(text: widget.value);
  final FocusNode _focus = FocusNode();

  @override
  void didUpdateWidget(covariant _SyncedText old) {
    super.didUpdateWidget(old);
    if (!_focus.hasFocus && widget.value != _c.text) {
      _c.text = widget.value;
    }
  }

  @override
  void dispose() {
    _c.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return fluent.TextBox(
      controller: _c,
      focusNode: _focus,
      maxLines: widget.maxLines,
      placeholder: widget.hint,
      onChanged: widget.onChanged,
    );
  }
}

class _NumBox extends StatefulWidget {
  const _NumBox({required this.value, required this.onChanged, this.hint});
  final num? value;
  final ValueChanged<num?> onChanged;
  final String? hint;

  @override
  State<_NumBox> createState() => _NumBoxState();
}

class _NumBoxState extends State<_NumBox> {
  late final TextEditingController _c =
      TextEditingController(text: widget.value?.toString() ?? '');
  final FocusNode _focus = FocusNode();

  @override
  void didUpdateWidget(covariant _NumBox old) {
    super.didUpdateWidget(old);
    final cur = widget.value?.toString() ?? '';
    if (!_focus.hasFocus && cur != _c.text) _c.text = cur;
  }

  @override
  void dispose() {
    _c.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return fluent.TextBox(
      controller: _c,
      focusNode: _focus,
      placeholder: widget.hint,
      onChanged: (v) {
        final t = v.trim();
        widget.onChanged(t.isEmpty ? null : num.tryParse(t));
      },
    );
  }
}

class _TypeDropdown extends StatelessWidget {
  const _TypeDropdown({
    required this.value,
    required this.types,
    required this.onChanged,
  });

  final int value;
  final Map<String, dynamic> types;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final entries = types.entries.toList()
      ..sort((a, b) =>
          (int.tryParse(a.key) ?? 0).compareTo(int.tryParse(b.key) ?? 0));
    final has = types.containsKey(value.toString());
    return fluent.ComboBox<int>(
      value: has ? value : (int.tryParse(entries.first.key) ?? 0),
      isExpanded: true,
      items: [
        for (final e in entries)
          fluent.ComboBoxItem<int>(
            value: int.tryParse(e.key) ?? 0,
            child: Text(
              '${e.value is Map ? (e.value as Map)['name'] ?? '' : ''}（${e.key}）',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12),
            ),
          ),
        if (!has && entries.isEmpty)
          fluent.ComboBoxItem<int>(
            value: value,
            child: Text('事件类型 $value',
                style: const TextStyle(fontSize: 12)),
          ),
      ],
      onChanged: (v) {
        if (v != null) onChanged(v);
      },
    );
  }
}

class _EventListItem extends StatefulWidget {
  const _EventListItem({
    required this.id,
    required this.title,
    required this.typeName,
    required this.dialogueCount,
    required this.conditionSummary,
    required this.selected,
    required this.onTap,
  });

  final String id;
  final String title;
  final String typeName;
  final int dialogueCount;
  final String conditionSummary;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_EventListItem> createState() => _EventListItemState();
}

class _EventListItemState extends State<_EventListItem> {
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
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(widget.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 12.5,
                            fontWeight:
                                selected ? FontWeight.w600 : FontWeight.normal,
                            color: selected
                                ? palette.textHigh
                                : palette.textPrimary)),
                  ),
                  Text(widget.id,
                      style:
                          TextStyle(fontSize: 10, color: palette.textHint)),
                ],
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  Flexible(
                    child: Text(widget.typeName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 10.5, color: palette.goldText)),
                  ),
                  const SizedBox(width: 6),
                  Text('${widget.dialogueCount} 句',
                      style: TextStyle(
                          fontSize: 10.5, color: palette.textMuted)),
                ],
              ),
              const SizedBox(height: 3),
              Text(widget.conditionSummary,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 10.5, color: palette.textHint)),
            ],
          ),
        ),
      ),
    );
  }
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: selected ? accentColor.withValues(alpha: 0.14) : null,
            borderRadius: BorderRadius.circular(7),
            border: Border.all(
              color: selected
                  ? accentColor.withValues(alpha: 0.4)
                  : palette.border,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 11,
              color: selected ? palette.textHigh : palette.textMuted,
            ),
          ),
        ),
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag({required this.text, required this.color});
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(text, style: TextStyle(fontSize: 10.5, color: color)),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.text, required this.onRemove});
  final String text;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: palette.bgAlt,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: palette.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(text,
              style: TextStyle(fontSize: 11, color: palette.textPrimary)),
          const SizedBox(width: 5),
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              onTap: onRemove,
              child: Icon(FluentIcons.dismiss_24_regular,
                  size: 10, color: palette.textMuted),
            ),
          ),
        ],
      ),
    );
  }
}

class _MiniChip extends StatelessWidget {
  const _MiniChip({required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: palette.card,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: palette.borderHover),
          ),
          child: Text(label,
              style: TextStyle(fontSize: 11, color: accentColor)),
        ),
      ),
    );
  }
}

class _MiniBtn extends StatefulWidget {
  const _MiniBtn({
    required this.label,
    required this.onTap,
    this.enabled = true,
    this.danger = false,
  });

  final String label;
  final VoidCallback onTap;
  final bool enabled;
  final bool danger;

  @override
  State<_MiniBtn> createState() => _MiniBtnState();
}

class _MiniBtnState extends State<_MiniBtn> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final color = !widget.enabled
        ? palette.iconDisabled
        : widget.danger
            ? palette.statusDanger
            : palette.textPrimary;
    return MouseRegion(
      cursor:
          widget.enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.enabled ? widget.onTap : null,
        child: AnimatedContainer(
          duration: AppMotion.fast,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: BoxDecoration(
            color: _hover && widget.enabled ? palette.card : palette.bgAlt,
            borderRadius: BorderRadius.circular(7),
            border: Border.all(
              color: widget.danger && widget.enabled
                  ? palette.statusDanger.withValues(alpha: 0.35)
                  : palette.border,
            ),
          ),
          child: Text(
            widget.label,
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11.5, color: color),
          ),
        ),
      ),
    );
  }
}
