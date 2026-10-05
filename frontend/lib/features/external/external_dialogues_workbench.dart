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

/// 外部对话工作台 —— 导演布局下「外部对话」的专属界面。
///
/// 把游戏里**主线剧情之外**的对白入口汇总到一处，按用途分类浏览与编辑：
/// - 送礼对话（`GiftEvtCfg`：人物 × 礼物 → 对白）；
/// - 小游戏开场 / 胜利 / 失败（`MinigameActionCfg.startTalk/winTalk/loseTalk`）；
/// - 闲聊（`InteractCfg.talkId`）。
///
/// 三栏：入口列表（用途筛选 / 搜索）｜用途参数 + 对白链编辑｜对话预览与统计。
/// 对白内容统一落在 `TalkCfg`，沿 `nextTalk[0]` 串成线性对白链就地编辑。
///
/// 对标把「对话夹」作为编辑器私有元数据保存；本工作台不新增元数据文件，
/// 按**用途（kind）**对入口分组，聚焦游戏内真实数据。
class ExternalDialoguesWorkbench extends StatefulWidget {
  const ExternalDialoguesWorkbench({
    super.key,
    required this.state,
    this.onOpenSearch,
  });

  final AppState state;
  final VoidCallback? onOpenSearch;

  @override
  State<ExternalDialoguesWorkbench> createState() =>
      _ExternalDialoguesWorkbenchState();
}

const _giftCfg = 'GiftEvtCfg';
const _miniCfg = 'MinigameActionCfg';
const _interactCfg = 'InteractCfg';
const _talkCfg = 'TalkCfg';

/// 用途分类（kind → 展示名）。
const _extKinds = <List<String>>[
  ['all', '全部'],
  ['gift', '送礼对话'],
  ['mini-start', '小游戏开场'],
  ['mini-win', '小游戏胜利'],
  ['mini-lose', '小游戏失败'],
  ['interact', '闲聊'],
];

String _kindLabel(String kind) {
  for (final k in _extKinds) {
    if (k[0] == kind) return k[1];
  }
  return kind;
}

class _TableBuf {
  _TableBuf(this.name, this.data, this.snap, this.mtime);

  final String name;
  Map<String, dynamic> data;
  String snap;
  int? mtime;

  bool get dirty => jsonEncode(data) != snap;
}

/// 一个外部对白入口。
class _ExtEntry {
  const _ExtEntry({
    required this.kind,
    required this.table,
    required this.id,
    this.index = -1,
    this.field,
    this.personId = 0,
  });

  final String kind;
  final String table;
  final String id;
  final int index;
  final String? field;
  final int personId;

  String get key => '$kind|$table|$id|$index|${field ?? ''}';
}

class _ExternalDialoguesWorkbenchState
    extends State<ExternalDialoguesWorkbench>
    with WorkbenchLeaveGuard<ExternalDialoguesWorkbench> {
  final Map<String, _TableBuf> _tables = {};

  Map<String, dynamic> _grow = {};
  Map<String, dynamic> _items = {};
  Map<String, dynamic> _books = {};
  Map<String, dynamic> _minigames = {};
  Map<String, dynamic> _relations = {};
  Map<String, dynamic> _maps = const {};

  List<RoleEntry> _roles = const [];

  bool _loading = true;
  bool _saving = false;
  String? _error;

  String _kindFilter = 'all';
  String _search = '';
  String? _selKey;

  final TextEditingController _searchCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _maps = (widget.state.gameDicts['maps'] as Map?)?.cast<String, dynamic>() ??
        const {};
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
  String get guardSubject => '外部对话';

  Future<void> _loadAll() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await Future.wait([
        ApiClient.instance.get('/api/cfg/$_giftCfg'),
        ApiClient.instance.get('/api/cfg/$_miniCfg'),
        ApiClient.instance.get('/api/cfg/$_interactCfg'),
        ApiClient.instance.get('/api/cfg/$_talkCfg'),
        ApiClient.instance.get('/api/cfg/PersonGrowCfg'),
        ApiClient.instance.get('/api/cfg/ItemCfg'),
        ApiClient.instance.get('/api/cfg/BookCfg'),
        ApiClient.instance.get('/api/cfg/MinigameCfg'),
        ApiClient.instance.get('/api/cfg/RelationCfg'),
      ]);
      if (!mounted) return;
      _grow = _dataOf(res[4]);
      _items = _dataOf(res[5]);
      _books = _dataOf(res[6]);
      _minigames = _dataOf(res[7]);
      _relations = _dataOf(res[8]);
      _tables.clear();
      for (var i = 0; i < 4; i++) {
        final name = [_giftCfg, _miniCfg, _interactCfg, _talkCfg][i];
        final data = _dataOf(res[i]);
        _tables[name] = _TableBuf(name, data, jsonEncode(data), _mtimeOf(res[i]));
      }
      _ensureSelection();
      setState(() => _loading = false);
      _loadRoles();
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

  Map<String, dynamic> _tableData(String t) =>
      _tables[t]?.data ?? <String, dynamic>{};

  bool _tableDirty(String t) => _tables[t]?.dirty ?? false;

  bool get _dirty =>
      _tableDirty(_giftCfg) ||
      _tableDirty(_miniCfg) ||
      _tableDirty(_interactCfg) ||
      _tableDirty(_talkCfg);

  Future<void> _saveAll() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      for (final name in const [_giftCfg, _miniCfg, _interactCfg, _talkCfg]) {
        final buf = _tables[name]!;
        if (!buf.dirty) continue;
        final ok = await _saveTable(buf);
        if (!ok || !mounted) return;
      }
      if (mounted) {
        _info('外部对话已保存', fluent.InfoBarSeverity.success);
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<bool> _saveTable(_TableBuf buf) async {
    var force = false;
    for (;;) {
      try {
        final body = <String, dynamic>{
          'data': buf.data,
          if (!force) 'expect_mtime_ns': buf.mtime,
          if (force) 'force': true,
        };
        final r = await ApiClient.instance.put('/api/cfg/${buf.name}', body: body);
        if (!mounted) return false;
        buf.mtime = _mtimeOf(r);
        buf.snap = jsonEncode(buf.data);
        return true;
      } on ApiException catch (e) {
        if (!mounted) return false;
        if (e.statusCode == 409 && !force) {
          final act = await _conflictDialog(buf.name);
          if (!mounted) return false;
          if (act == 'reload') {
            await _loadAll();
            return false;
          }
          if (act == 'force') {
            force = true;
            continue;
          }
          return false;
        }
        _info('保存失败：$e', fluent.InfoBarSeverity.error);
        return false;
      } catch (e) {
        if (!mounted) return false;
        _info('保存失败：$e', fluent.InfoBarSeverity.error);
        return false;
      }
    }
  }

  void _discard() {
    setState(() {
      for (final buf in _tables.values) {
        buf.data = (jsonDecode(buf.snap) as Map).cast<String, dynamic>();
      }
      _ensureSelection();
    });
  }

  Future<String?> _conflictDialog(String name) {
    return fluent.showDialog<String>(
      context: context,
      builder: (ctx) => AppContentDialog(
        title: const Text('文件冲突'),
        content: Text(
          '$name 已被外部修改（可能被游戏或其他端改写）。\n'
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
  // 行 / 名称
  // ------------------------------------------------------------------

  Map<String, dynamic>? _rowIn(String table, String id) {
    final v = _tableData(table)[id];
    return v is Map ? v.cast<String, dynamic>() : null;
  }

  List<String> _sortedIds(String table) {
    final ids = _tableData(table).keys.toList();
    ids.sort((a, b) =>
        (int.tryParse(a) ?? 0).compareTo(int.tryParse(b) ?? 0));
    return ids;
  }

  int _intOf(Map<String, dynamic>? row, String field, [int fallback = 0]) {
    final v = row?[field];
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? '') ?? fallback;
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

  String _personName(int id) {
    for (final r in _roles) {
      if (r.id == id.toString()) return r.name.isEmpty ? '角色 $id' : r.name;
    }
    return id == 0 ? '白雨' : '角色 $id';
  }

  String _itemName(int id) {
    for (final map in [_items, _books]) {
      final v = map[id.toString()];
      if (v is Map) {
        final n = v['name']?.toString().trim() ?? '';
        if (n.isNotEmpty) return n;
      }
    }
    return '物品 $id';
  }

  String _gameName(int gameId) {
    final v = _minigames[gameId.toString()];
    if (v is Map) {
      final n = v['name']?.toString().trim() ?? '';
      if (n.isNotEmpty) return n;
    }
    return '小游戏 $gameId';
  }

  String _relationName(int id) {
    if (id == 0) return '无';
    final v = _relations[id.toString()];
    if (v is Map) {
      final n = v['name']?.toString().trim() ?? '';
      if (n.isNotEmpty) return n;
    }
    return '关系 $id';
  }

  String _placeName(int id) {
    final v = _maps[id.toString()];
    if (v != null) return v.toString();
    return id == 0 ? '不限地点' : '地点 $id';
  }

  int? _personOfGame(int gameId) {
    for (final e in _grow.entries) {
      final v = e.value;
      if (v is Map && _intOf(v.cast<String, dynamic>(), 'minigame') == gameId) {
        return int.tryParse(e.key) ?? 0;
      }
    }
    return null;
  }

  // ------------------------------------------------------------------
  // 入口
  // ------------------------------------------------------------------

  List<_ExtEntry> get _allEntries {
    final out = <_ExtEntry>[];
    for (final id in _sortedIds(_giftCfg)) {
      final row = _rowIn(_giftCfg, id);
      final npcs = _intList(row, 'npc');
      if (npcs.isEmpty) {
        out.add(_ExtEntry(
            kind: 'gift', table: _giftCfg, id: id, index: -1, field: null));
      } else {
        for (var i = 0; i < npcs.length; i++) {
          out.add(_ExtEntry(
            kind: 'gift',
            table: _giftCfg,
            id: id,
            index: i,
            personId: npcs[i],
          ));
        }
      }
    }
    for (final id in _sortedIds(_miniCfg)) {
      final gameId = (int.tryParse(id) ?? 0) ~/ 100;
      final person = _personOfGame(gameId) ?? 0;
      final row = _rowIn(_miniCfg, id);
      for (final f in const [
        ['startTalk', 'mini-start'],
        ['winTalk', 'mini-win'],
        ['loseTalk', 'mini-lose'],
      ]) {
        if (_intOf(row, f[0]) == 0) continue;
        out.add(_ExtEntry(
          kind: f[1],
          table: _miniCfg,
          id: id,
          field: f[0],
          personId: person,
        ));
      }
    }
    for (final id in _sortedIds(_interactCfg)) {
      final row = _rowIn(_interactCfg, id);
      out.add(_ExtEntry(
        kind: 'interact',
        table: _interactCfg,
        id: id,
        personId: _intOf(row, 'npc'),
      ));
    }
    return out;
  }

  List<_ExtEntry> get _entries {
    final q = _search.trim().toLowerCase();
    return _allEntries.where((e) {
      if (_kindFilter != 'all' && e.kind != _kindFilter) return false;
      if (q.isEmpty) return true;
      return _entryLabel(e).toLowerCase().contains(q) ||
          e.id.contains(q) ||
          _entryTalk(e).toString().contains(q);
    }).toList();
  }

  _ExtEntry? _entryByKey(String? key) {
    if (key == null) return null;
    for (final e in _allEntries) {
      if (e.key == key) return e;
    }
    return null;
  }

  _ExtEntry? get _sel => _entryByKey(_selKey);

  void _ensureSelection() {
    final list = _entries;
    if (list.any((e) => e.key == _selKey)) return;
    _selKey = list.isNotEmpty ? list.first.key : null;
  }

  String _entryLabel(_ExtEntry e) {
    switch (e.kind) {
      case 'gift':
        return '送礼 · ${_personName(e.personId)} ← ${_itemName(_intOf(_rowIn(e.table, e.id), 'item'))}';
      case 'interact':
        final row = _rowIn(e.table, e.id);
        final name = row?['name']?.toString().trim() ?? '';
        return '闲聊 · ${_personName(e.personId)}${name.isNotEmpty ? ' · $name' : ''}';
      default:
        final gameId = (int.tryParse(e.id) ?? 0) ~/ 100;
        final level = (int.tryParse(e.id) ?? 0) % 100;
        return '${_gameName(gameId)} 第$level关 · ${_kindLabel(e.kind).replaceFirst('小游戏', '')}';
    }
  }

  int _entryTalk(_ExtEntry e) {
    final row = _rowIn(e.table, e.id);
    if (row == null) return 0;
    switch (e.kind) {
      case 'gift':
        final tl = row['talkId'];
        if (tl is List && e.index >= 0 && e.index < tl.length) {
          final v = tl[e.index];
          if (v is List) return v.isNotEmpty ? _asInt(v.first) : 0;
          return _asInt(v);
        }
        return 0;
      case 'interact':
        return _intOf(row, 'talkId');
      default:
        return _intOf(row, e.field ?? '');
    }
  }

  void _setEntryTalk(_ExtEntry e, int talkId) {
    final row = _rowIn(e.table, e.id);
    if (row == null) return;
    switch (e.kind) {
      case 'gift':
        final tl = row['talkId'];
        final list = tl is List ? List<dynamic>.from(tl) : <dynamic>[];
        while (list.length <= e.index) {
          list.add(0);
        }
        if (e.index >= 0) list[e.index] = talkId;
        row['talkId'] = list;
        break;
      case 'interact':
        row['talkId'] = talkId;
        break;
      default:
        row[e.field!] = talkId;
    }
  }

  int _asInt(Object? v) {
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? '') ?? 0;
  }

  // ------------------------------------------------------------------
  // 对白链
  // ------------------------------------------------------------------

  Map<String, dynamic>? _talkOf(int id) {
    final v = _tableData(_talkCfg)[id.toString()];
    return v is Map ? v.cast<String, dynamic>() : null;
  }

  List<int> _chainOf(int talkId) {
    final out = <int>[];
    final seen = <int>{};
    var id = talkId;
    while (id != 0 && !seen.contains(id)) {
      final talk = _talkOf(id);
      if (talk == null) break;
      seen.add(id);
      out.add(id);
      final next = _intList(talk, 'nextTalk');
      id = next.isNotEmpty ? next.first : 0;
    }
    return out;
  }

  int _newTalkId() {
    var max = 0;
    for (final k in _tableData(_talkCfg).keys) {
      final v = int.tryParse(k);
      if (v != null && v > max) max = v;
    }
    return max == 0 ? 1 : max + 1;
  }

  void _addLine(_ExtEntry e, int speaker) {
    final chain = _chainOf(_entryTalk(e));
    final id = _newTalkId();
    setState(() {
      _tableData(_talkCfg)[id.toString()] = <String, dynamic>{
        'id': id,
        'content': '',
        'roleIds': [speaker],
        'nextTalk': <dynamic>[],
        'nextTalk2': <dynamic>[],
        'option': <dynamic>[],
        'check': <dynamic>[],
        'effect': <dynamic>[],
        'effect2': <dynamic>[],
        'screenEffect': <dynamic>[],
        'highlights': <dynamic>[],
        'replace': <dynamic>[],
        'roles': <dynamic>[],
        'maxoptions': 0,
      };
      if (chain.isEmpty) {
        _setEntryTalk(e, id);
      } else {
        final last = _talkOf(chain.last);
        if (last != null) last['nextTalk'] = [id];
      }
    });
  }

  Future<void> _deleteLine(_ExtEntry e, int talkId) async {
    final ok = await fluent.showDialog<bool>(
      context: context,
      builder: (ctx) => AppContentDialog(
        title: const Text('删除这句对白？'),
        content: Text(
          '将从这条外部对白链中移除该句（TalkCfg 记录一并删除）。\n'
          '若其它剧情也跳转到这句，删除后需要另行调整。',
          style: TextStyle(
              fontSize: 12.5, color: palette.textPrimary, height: 1.6),
        ),
        actions: [
          fluent.Button(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          fluent.FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final chain = _chainOf(_entryTalk(e));
    final idx = chain.indexOf(talkId);
    final prev = idx > 0 ? chain[idx - 1] : null;
    final next = idx >= 0 && idx < chain.length - 1 ? chain[idx + 1] : null;
    setState(() {
      if (prev != null) {
        final p = _talkOf(prev);
        if (p != null) p['nextTalk'] = next != null ? [next] : <dynamic>[];
      } else {
        _setEntryTalk(e, next ?? 0);
      }
      _tableData(_talkCfg).remove(talkId.toString());
    });
  }

  Future<void> _setSpeaker(int talkId, int roleId) async {
    setState(() {
      final t = _talkOf(talkId);
      if (t != null) t['roleIds'] = [roleId];
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
            title: const Text('选择说话人'),
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
                        _pickerRow(ctx, 0, '白雨（主角）'),
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

  Future<int?> _pickPerson() async {
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
            title: const Text('选择人物'),
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

  Future<int?> _pickItem() async {
    var query = '';
    final entries = <MapEntry<String, dynamic>>[
      ..._items.entries,
      ..._books.entries,
    ];
    return fluent.showDialog<int>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) {
          final list = entries.where((e) {
            if (query.isEmpty) return true;
            final name = (e.value is Map ? (e.value as Map)['name'] : '')
                    ?.toString()
                    .toLowerCase() ??
                '';
            return e.key.contains(query) || name.contains(query);
          }).toList();
          return AppContentDialog(
            title: const Text('选择礼物'),
            content: SizedBox(
              width: 480,
              height: 440,
              child: Column(
                children: [
                  fluent.TextBox(
                    placeholder: '搜索物品名称或编号',
                    onChanged: (v) =>
                        setLocal(() => query = v.trim().toLowerCase()),
                  ),
                  const SizedBox(height: 10),
                  Expanded(
                    child: ListView(
                      children: [
                        for (final e in list)
                          _pickerRow(
                            ctx,
                            int.tryParse(e.key) ?? 0,
                            (e.value is Map ? (e.value as Map)['name'] : '')
                                    ?.toString() ??
                                '物品 ${e.key}',
                            sub: e.key,
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
                    maxLines: 1,
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

  // ------------------------------------------------------------------
  // 积木库
  // ------------------------------------------------------------------

  Future<void> _editBlocks(
      Map<String, dynamic> row, String field, String mode, String title) async {
    final current = row[field];
    final out = await showBlockLibrary(
      context,
      initialText: ValueCodec.encode(current ?? const <dynamic>[]),
      initialMode: mode,
      gameDicts: widget.state.gameDicts,
      title: title,
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
              Text('外部对话加载失败',
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
      rightLabel: '对话预览',
      rightIcon: FluentIcons.chat_24_regular,
    );
  }

  // ---------- 左栏 ----------

  Widget _leftPanel(double w) {
    final entries = _entries;
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
                  placeholder: '搜索入口、人物或对白编号',
                  onChanged: (v) => setState(() {
                    _search = v;
                    _ensureSelection();
                  }),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 5,
                  runSpacing: 5,
                  children: [
                    for (final k in _extKinds)
                      _SegButton(
                        label: k[1],
                        selected: _kindFilter == k[0],
                        compact: true,
                        onTap: () => setState(() {
                          _kindFilter = k[0];
                          _ensureSelection();
                        }),
                      ),
                  ],
                ),
              ],
            ),
          ),
          Divider(height: 1, color: palette.border),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 6),
            child: Text('共 ${entries.length} 个入口',
                style: TextStyle(fontSize: 11, color: palette.textMuted)),
          ),
          Expanded(
            child: entries.isEmpty
                ? Center(
                    child: Text(
                      _allEntries.isEmpty ? '还没有外部对白入口。' : '没有匹配的入口。',
                      style: TextStyle(fontSize: 12, color: palette.textHint),
                    ),
                  )
                : ListView.builder(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    itemCount: entries.length,
                    itemBuilder: (context, i) => _entryTile(entries[i]),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _entryTile(_ExtEntry e) {
    final selected = e.key == _selKey;
    final talk = _entryTalk(e);
    final missing = talk != 0 && _talkOf(talk) == null;
    return _HoverTile(
      selected: selected,
      onTap: () => setState(() => _selKey = e.key),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: palette.bgDeep2,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: palette.border),
            ),
            alignment: Alignment.center,
            child: Icon(_kindIcon(e.kind), size: 16, color: palette.textMuted),
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_entryLabel(e),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight:
                            selected ? FontWeight.w600 : FontWeight.normal,
                        color: selected
                            ? palette.textHigh
                            : palette.textPrimary)),
                const SizedBox(height: 3),
                Row(
                  children: [
                    Text(_kindLabel(e.kind),
                        style: TextStyle(
                            fontSize: 10, color: palette.textMuted)),
                    const SizedBox(width: 6),
                    Text(
                      talk == 0
                          ? '未绑定对白'
                          : (missing ? '对白 $talk（缺失）' : '对白 $talk'),
                      style: TextStyle(
                          fontSize: 10,
                          color: missing
                              ? palette.statusDanger
                              : palette.textHint),
                    ),
                  ],
                ),
              ],
            ),
          ),
          Text(e.id,
              style: TextStyle(fontSize: 10, color: palette.textHint)),
        ],
      ),
    );
  }

  IconData _kindIcon(String kind) {
    switch (kind) {
      case 'gift':
        return FluentIcons.gift_24_regular;
      case 'interact':
        return FluentIcons.person_chat_24_regular;
      default:
        return FluentIcons.games_24_regular;
    }
  }

  // ---------- 中栏 ----------

  Widget _center() {
    final e = _sel;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: e == null
              ? Center(
                  child: Text('选择左侧一个外部对白入口。',
                      style: TextStyle(fontSize: 13, color: palette.textHint)),
                )
              : SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(18, 16, 18, 24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _headerBar(e),
                      const SizedBox(height: 14),
                      _bindingCard(e),
                      const SizedBox(height: 14),
                      _chainCard(e),
                    ],
                  ),
                ),
        ),
        _saveBar(),
      ],
    );
  }

  Widget _headerBar(_ExtEntry e) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: palette.panel,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: palette.border),
      ),
      child: Row(
        children: [
          Icon(_kindIcon(e.kind), size: 18, color: accentColor),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_entryLabel(e),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: palette.textHigh)),
                const SizedBox(height: 2),
                Text('${_kindLabel(e.kind)} · ${e.table} #${e.id}',
                    style:
                        TextStyle(fontSize: 10.5, color: palette.textMuted)),
              ],
            ),
          ),
          _Tag(
            text: '${_chainOf(_entryTalk(e)).length} 句',
            color: palette.statusInfo,
          ),
        ],
      ),
    );
  }

  Widget _bindingCard(_ExtEntry e) {
    final row = _rowIn(e.table, e.id);
    if (row == null) {
      return _SectionCard(title: '用途参数', children: const [
        Text('找不到对应的记录。'),
      ]);
    }
    switch (e.kind) {
      case 'gift':
        return _giftBinding(e, row);
      case 'interact':
        return _interactBinding(e, row);
      default:
        return _miniBinding(e, row);
    }
  }

  Widget _giftBinding(_ExtEntry e, Map<String, dynamic> row) {
    final types = _intList(row, 'type');
    final mode = e.index >= 0 && e.index < types.length ? types[e.index] : 0;
    final itemId = _intOf(row, 'item');
    return _SectionCard(
      title: '送礼用途',
      subtitle: '人物 × 礼物 → 对白。同一个礼物规则可对多个人物各绑一条对白。',
      children: [
        _labeled(
          '收礼人',
          Row(
            children: [
              Expanded(child: _valueBox(_personName(e.personId))),
              const SizedBox(width: 8),
              _MiniBtn(
                label: '更换',
                enabled: e.index >= 0,
                onTap: () async {
                  final picked = await _pickPerson();
                  if (picked == null || !mounted || e.index < 0) return;
                  setState(() {
                    final list = _intList(row, 'npc');
                    while (list.length <= e.index) {
                      list.add(0);
                    }
                    list[e.index] = picked;
                    row['npc'] = list;
                  });
                },
              ),
            ],
          ),
        ),
        _labeled(
          '具体礼物',
          Row(
            children: [
              Expanded(child: _valueBox(_itemName(itemId))),
              const SizedBox(width: 8),
              _MiniBtn(
                label: '更换',
                onTap: () async {
                  final picked = await _pickItem();
                  if (picked == null || !mounted) return;
                  setState(() => row['item'] = picked);
                },
              ),
            ],
          ),
        ),
        _labeled(
          '赠送方式',
          Row(
            children: [
              _SegButton(
                label: '交付礼物并播放对话',
                selected: mode == 0,
                onTap: () => _setGiftMode(row, e.index, 0),
              ),
              const SizedBox(width: 6),
              _SegButton(
                label: '仅播放对话',
                selected: mode == 1,
                onTap: () => _setGiftMode(row, e.index, 1),
              ),
            ],
          ),
        ),
        _blockRow(row, 'cond', 'condition', '积木库 · 送礼条件', '触发条件'),
      ],
    );
  }

  void _setGiftMode(Map<String, dynamic> row, int index, int mode) {
    if (index < 0) return;
    setState(() {
      final list = _intList(row, 'type');
      while (list.length <= index) {
        list.add(0);
      }
      list[index] = mode;
      row['type'] = list;
    });
  }

  Widget _miniBinding(_ExtEntry e, Map<String, dynamic> row) {
    final gameId = (int.tryParse(e.id) ?? 0) ~/ 100;
    final level = (int.tryParse(e.id) ?? 0) % 100;
    return _SectionCard(
      title: '小游戏用途',
      subtitle: '人物在「人物工作台」绑定小游戏后，其关卡的开场 / 胜利 / 失败对白在此编辑。',
      children: [
        _labeled('人物', _valueBox(
            e.personId != 0 ? _personName(e.personId) : '未绑定人物')),
        _labeled('小游戏 / 关卡',
            _valueBox('${_gameName(gameId)} · 第$level关')),
        Row(
          children: [
            Expanded(
              child: _labeled('精力消耗', _NumBox(
                value: row['cost'],
                onChanged: (v) => setState(() => row['cost'] = (v ?? 0).toInt()),
              )),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _labeled('关系要求', _valueBox(
                  _relationName(_intOf(row, 'needRelation')))),
            ),
          ],
        ),
        _blockRow(row, 'effect', 'effect', '积木库 · 关卡效果', '关卡效果'),
      ],
    );
  }

  Widget _interactBinding(_ExtEntry e, Map<String, dynamic> row) {
    final maps = _intList(row, 'map');
    return _SectionCard(
      title: '闲聊用途',
      subtitle: '人物在地点触发的闲聊（与「闲聊」工作台共用 InteractCfg）。',
      children: [
        _labeled(
          '闲聊人物',
          Row(
            children: [
              Expanded(child: _valueBox(_personName(_intOf(row, 'npc')))),
              const SizedBox(width: 8),
              _MiniBtn(
                label: '更换',
                onTap: () async {
                  final picked = await _pickPerson();
                  if (picked == null || !mounted) return;
                  setState(() => row['npc'] = picked);
                },
              ),
            ],
          ),
        ),
        _labeled('进度文字', _SyncedText(
          value: row['text']?.toString() ?? '',
          hint: '正在和谁…… 的进度文字',
          onChanged: (v) => setState(() => row['text'] = v),
        )),
        _labeled('地点',
            _valueBox(maps.isEmpty ? '不限地点' : maps.map(_placeName).join('、'))),
        _blockRow(row, 'cond', 'condition', '积木库 · 触发条件', '触发条件'),
        _blockRow(row, 'effect', 'effect', '积木库 · 闲聊效果', '闲聊效果'),
      ],
    );
  }

  Widget _blockRow(
      Map<String, dynamic> row, String field, String mode, String title, String label) {
    final count = (row[field] is List) ? (row[field] as List).length : 0;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: palette.textSecondary)),
                const SizedBox(height: 3),
                Text(count == 0 ? '未设置（$field）' : '已设置 $count 条（$field）',
                    style: TextStyle(fontSize: 11, color: palette.textMuted)),
              ],
            ),
          ),
          _MiniBtn(
            label: '打开积木库',
            onTap: () => _editBlocks(row, field, mode, title),
          ),
        ],
      ),
    );
  }

  // ---------- 对白链 ----------

  Widget _chainCard(_ExtEntry e) {
    final talkId = _entryTalk(e);
    final chain = _chainOf(talkId);
    return _SectionCard(
      title: '对白链（TalkCfg）',
      subtitle: '从入口对白起沿 nextTalk 主线串联，逐句就地编辑；分支与选项去「剧情舞台」。',
      children: [
        if (talkId != 0 && chain.isEmpty)
          Text('入口绑定的对白 $talkId 不存在。',
              style: TextStyle(fontSize: 12, color: palette.statusDanger)),
        if (chain.isEmpty)
          Text('还没有对白，点下方按钮添加第一句。',
              style: TextStyle(fontSize: 12, color: palette.textHint))
        else
          for (var i = 0; i < chain.length; i++)
            _lineCard(talkId, chain[i], i, chain.length),
        const SizedBox(height: 4),
        Row(
          children: [
            _MiniBtn(
              label: '＋ 白雨对白',
              onTap: () => _addLine(e, 0),
            ),
            const SizedBox(width: 8),
            _MiniBtn(
              label: '＋ ${_personName(e.personId)}对白',
              onTap: () => _addLine(e, e.personId),
            ),
          ],
        ),
      ],
    );
  }

  Widget _lineCard(int entryTalk, int talkId, int index, int total) {
    final talk = _talkOf(talkId);
    if (talk == null) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text('对白 $talkId 缺失',
            style: TextStyle(fontSize: 12, color: palette.statusDanger)),
      );
    }
    final speaker = _intList(talk, 'roleIds').isNotEmpty
        ? _intList(talk, 'roleIds').first
        : -1;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(10, 9, 8, 10),
      decoration: BoxDecoration(
        color: palette.card,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: palette.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('${index + 1}/$total',
                  style: TextStyle(fontSize: 10.5, color: palette.textHint)),
              const SizedBox(width: 8),
              MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  onTap: () async {
                    final picked = await _pickRole();
                    if (picked == null || !mounted) return;
                    await _setSpeaker(talkId, picked);
                  },
                  child: _Tag(
                    text: speaker >= 0 ? _personName(speaker) : '旁白',
                    color: speaker >= 0 ? accentColor : palette.textMuted,
                  ),
                ),
              ),
              const Spacer(),
              fluent.IconButton(
                icon: Icon(FluentIcons.delete_24_regular,
                    size: 13, color: palette.statusDanger),
                onPressed: () => _deleteLine(_sel!, talkId),
              ),
            ],
          ),
          const SizedBox(height: 6),
          _SyncedText(
            value: talk['content']?.toString() ?? '',
            hint: '对白内容',
            maxLines: 2,
            onChanged: (v) => setState(() => talk['content'] = v),
          ),
        ],
      ),
    );
  }

  // ---------- 底部保存条 ----------

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
    final e = _sel;
    return Container(
      width: w,
      color: palette.panel,
      child: e == null
          ? Center(
              child: Text('选择入口查看预览。',
                  style: TextStyle(fontSize: 12, color: palette.textHint)),
            )
          : SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _SectionCard(
                    title: '对话预览',
                    children: [_preview(e)],
                  ),
                  _statsCard(e),
                ],
              ),
            ),
    );
  }

  Widget _preview(_ExtEntry e) {
    final chain = _chainOf(_entryTalk(e));
    if (chain.isEmpty) {
      return Text('还没有对白。',
          style: TextStyle(fontSize: 12, color: palette.textHint));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [for (final id in chain) _bubble(e, id)],
    );
  }

  Widget _bubble(_ExtEntry e, int talkId) {
    final talk = _talkOf(talkId);
    if (talk == null) return const SizedBox.shrink();
    final roleIds = _intList(talk, 'roleIds');
    final speaker = roleIds.isNotEmpty ? roleIds.first : -1;
    final isPlayer = speaker == 0;
    final isNarrator = speaker < 0;
    final name = isNarrator ? '旁白' : _personName(speaker);
    final content = talk['content']?.toString() ?? '';
    final align = isPlayer ? CrossAxisAlignment.end : CrossAxisAlignment.start;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: align,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _Avatar(seed: speaker, name: name, size: 20),
              const SizedBox(width: 6),
              Text(name,
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: palette.textSecondary)),
            ],
          ),
          const SizedBox(height: 3),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            decoration: BoxDecoration(
              color: isNarrator
                  ? palette.bgAlt
                  : isPlayer
                      ? accentColor.withValues(alpha: 0.16)
                      : palette.card,
              borderRadius: BorderRadius.circular(9),
              border: Border.all(color: palette.border),
            ),
            child: Text(
              content.isEmpty ? '（空白对白）' : content,
              style: TextStyle(
                  fontSize: 12,
                  height: 1.5,
                  fontStyle: isNarrator ? FontStyle.italic : FontStyle.normal,
                  color: palette.textPrimary),
            ),
          ),
        ],
      ),
    );
  }

  Widget _statsCard(_ExtEntry e) {
    final chain = _chainOf(_entryTalk(e));
    final row = _rowIn(e.table, e.id);
    return _SectionCard(
      title: '统计与引用',
      children: [
        _kv('用途', _kindLabel(e.kind)),
        _kv('数据表', '${e.table} #${e.id}'),
        _kv('入口对白', _entryTalk(e) == 0 ? '未绑定' : '${_entryTalk(e)}'),
        _kv('对白链长度', '${chain.length} 句'),
        if (e.kind == 'gift') ...[
          _kv('收礼人', _personName(e.personId)),
          _kv('礼物', _itemName(_intOf(row, 'item'))),
        ],
        if (e.kind == 'interact')
          _kv('触发条件',
              '${(row?['cond'] is List) ? (row!['cond'] as List).length : 0} 条'),
      ],
    );
  }

  Widget _kv(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: Row(
        children: [
          Expanded(
            child: Text(label,
                style: TextStyle(fontSize: 11.5, color: palette.textMuted)),
          ),
          Flexible(
            child: Text(value,
                textAlign: TextAlign.right,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: palette.textPrimary)),
          ),
        ],
      ),
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

  Widget _valueBox(String text) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: palette.bgAlt,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: palette.border),
      ),
      child: Text(text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 12.5, color: palette.textSecondary)),
    );
  }
}

// ---------------------------------------------------------------------------
// 通用小部件
// ---------------------------------------------------------------------------

class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.title,
    required this.children,
    this.subtitle,
  });

  final String title;
  final String? subtitle;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
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
          if (subtitle != null) ...[
            const SizedBox(height: 4),
            Text(subtitle!,
                style: TextStyle(
                    fontSize: 11, height: 1.6, color: palette.textMuted)),
          ],
          const SizedBox(height: 10),
          for (final c in children) ...[
            c,
            const SizedBox(height: 8),
          ],
        ],
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

class _Avatar extends StatelessWidget {
  const _Avatar({required this.seed, required this.name, this.size = 24});
  final int seed;
  final String name;
  final double size;

  List<Color> get _swatches => [
        accentColor,
        palette.catTexture,
        palette.catAudio,
        palette.catSprite,
        palette.statusOk,
        palette.statusWarn,
      ];

  @override
  Widget build(BuildContext context) {
    final c = _swatches[seed.abs() % _swatches.length];
    final ch = name.trim().isEmpty ? '?' : name.trim().substring(0, 1);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.22),
        shape: BoxShape.circle,
        border: Border.all(color: c.withValues(alpha: 0.5)),
      ),
      alignment: Alignment.center,
      child: Text(ch,
          style: TextStyle(
              fontSize: size * 0.5,
              fontWeight: FontWeight.w600,
              color: c)),
    );
  }
}

class _HoverTile extends StatefulWidget {
  const _HoverTile({
    required this.child,
    required this.onTap,
    this.selected = false,
  });
  final Widget child;
  final VoidCallback onTap;
  final bool selected;

  @override
  State<_HoverTile> createState() => _HoverTileState();
}

class _HoverTileState extends State<_HoverTile> {
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
          margin: const EdgeInsets.only(bottom: 6),
          padding: const EdgeInsets.all(9),
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
          child: widget.child,
        ),
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
  const _NumBox({required this.value, required this.onChanged});
  final num? value;
  final ValueChanged<num?> onChanged;

  @override
  State<_NumBox> createState() => _NumBoxState();
}

class _NumBoxState extends State<_NumBox> {
  late final TextEditingController _c =
      TextEditingController(text: _fmt(widget.value));
  final FocusNode _focus = FocusNode();

  static String _fmt(num? v) {
    if (v == null) return '';
    if (v is double && v == v.roundToDouble()) return v.toInt().toString();
    return v.toString();
  }

  @override
  void didUpdateWidget(covariant _NumBox old) {
    super.didUpdateWidget(old);
    final cur = _fmt(widget.value);
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
      onChanged: (v) =>
          widget.onChanged(v.trim().isEmpty ? null : num.tryParse(v.trim())),
    );
  }
}

class _SegButton extends StatefulWidget {
  const _SegButton({
    required this.label,
    required this.onTap,
    this.selected = false,
    this.compact = false,
  });
  final String label;
  final VoidCallback onTap;
  final bool selected;
  final bool compact;

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
          padding: EdgeInsets.symmetric(
              horizontal: widget.compact ? 9 : 11,
              vertical: widget.compact ? 5 : 7),
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
              fontSize: widget.compact ? 11 : 12,
              color: selected ? palette.textHigh : palette.textSecondary,
              fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
            ),
          ),
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
  });

  final String label;
  final VoidCallback onTap;
  final bool enabled;

  @override
  State<_MiniBtn> createState() => _MiniBtnState();
}

class _MiniBtnState extends State<_MiniBtn> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final color =
        widget.enabled ? palette.textPrimary : palette.iconDisabled;
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
            border: Border.all(color: palette.border),
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
