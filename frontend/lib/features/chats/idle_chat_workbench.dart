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
import '../resources/role_visuals.dart';

/// 闲聊工作台 —— 导演布局下「闲聊」的专属界面。
///
/// 三栏：闲聊列表｜闲聊设置 + 线性对白链｜对话预览与概览。
///
/// 同时编辑两张表：
///   * `InteractCfg`（闲聊定义：人物 / 进度文字 / 地点 / 条件 / 效果 / 入口对白）；
///   * `TalkCfg`（入口对白起的**线性对白链**：内容 / 说话人 / 增删句）。
/// 两张表各自整表读写（`expect_mtime_ns` 乐观锁）；条件 / 效果复用「积木库」。
class IdleChatWorkbench extends StatefulWidget {
  const IdleChatWorkbench({
    super.key,
    required this.state,
    this.onOpenSearch,
  });

  final AppState state;
  final VoidCallback? onOpenSearch;

  @override
  State<IdleChatWorkbench> createState() => _IdleChatWorkbenchState();
}

class _IdleChatWorkbenchState extends State<IdleChatWorkbench>
    with WorkbenchLeaveGuard<IdleChatWorkbench> {
  static const _cfg = 'InteractCfg';
  static const _talkCfg = 'TalkCfg';

  Map<String, dynamic> _rows = {};
  Map<String, dynamic> _talks = {};
  String _snap = '';
  String _talkSnap = '';
  int? _mtime;
  int? _talkMtime;

  bool _loading = true;
  bool _saving = false;
  String? _error;

  String? _selected;
  int? _line;
  String _search = '';

  List<RoleEntry> _roles = const [];
  Map<String, dynamic> _maps = const {};

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
  String get guardSubject => '闲聊与对白';

  Future<void> _loadAll() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await Future.wait([
        ApiClient.instance.get('/api/cfg/$_cfg'),
        ApiClient.instance.get('/api/cfg/$_talkCfg'),
      ]);
      if (!mounted) return;
      _rows = _dataOf(res[0]);
      _talks = _dataOf(res[1]);
      _mtime = _mtimeOf(res[0]);
      _talkMtime = _mtimeOf(res[1]);
      _snap = jsonEncode(_rows);
      _talkSnap = jsonEncode(_talks);
      final ids = _sortedIds;
      if (_selected == null || !_rows.containsKey(_selected)) {
        _selected = ids.isNotEmpty ? ids.first : null;
      }
      _line = _chain().isNotEmpty ? _chain().first : null;
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

  bool get _dirty =>
      _snap != jsonEncode(_rows) || _talkSnap != jsonEncode(_talks);

  Future<void> _saveAll() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final ok1 = await _saveTable(_cfg, _rows, _snap, _mtime, (m, s) {
        _mtime = m;
        _snap = s;
      });
      if (!ok1) return;
      final ok2 = await _saveTable(_talkCfg, _talks, _talkSnap, _talkMtime,
          (m, s) {
        _talkMtime = m;
        _talkSnap = s;
      });
      if (!ok2) return;
      if (mounted) _info('闲聊与对白已保存', fluent.InfoBarSeverity.success);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// 整表写回；返回是否写入成功（409 由用户选择）。回调更新 mtime 与快照。
  Future<bool> _saveTable(
    String name,
    Map<String, dynamic> data,
    String snap,
    int? mtime,
    void Function(int?, String) onSaved,
  ) async {
    if (jsonEncode(data) == snap) return true;
    var force = false;
    for (;;) {
      try {
        final body = <String, dynamic>{
          'data': data,
          if (!force) 'expect_mtime_ns': mtime,
          if (force) 'force': true,
        };
        final r = await ApiClient.instance.put('/api/cfg/$name', body: body);
        if (!mounted) return false;
        onSaved(_mtimeOf(r), jsonEncode(data));
        return true;
      } on ApiException catch (e) {
        if (!mounted) return false;
        if (e.statusCode == 409 && !force) {
          final act = await _conflictDialog(name);
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
      _rows = (jsonDecode(_snap) as Map).cast<String, dynamic>();
      _talks = (jsonDecode(_talkSnap) as Map).cast<String, dynamic>();
      final ids = _sortedIds;
      if (_selected == null || !_rows.containsKey(_selected)) {
        _selected = ids.isNotEmpty ? ids.first : null;
      }
      _line = _chain().isNotEmpty ? _chain().first : null;
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
  // 行访问
  // ------------------------------------------------------------------

  Map<String, dynamic>? _rowOf(String id) {
    final v = _rows[id];
    return v is Map ? v.cast<String, dynamic>() : null;
  }

  Map<String, dynamic>? get _row =>
      _selected == null ? null : _rowOf(_selected!);

  Map<String, dynamic>? _talkOf(int id) {
    final v = _talks[id.toString()];
    return v is Map ? v.cast<String, dynamic>() : null;
  }

  List<String> get _sortedIds {
    final ids = _rows.keys.toList();
    ids.sort((a, b) =>
        (int.tryParse(a) ?? 0).compareTo(int.tryParse(b) ?? 0));
    return ids;
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

  String _roleName(int id) {
    for (final r in _roles) {
      if (r.id == id.toString()) return r.name.isEmpty ? '角色 $id' : r.name;
    }
    return id == 0 ? '白雨' : '角色 $id';
  }

  String _placeName(int id) {
    final v = _maps[id.toString()];
    if (v != null) return v.toString();
    return id == 0 ? '不限地点' : '地点 $id';
  }

  /// 入口对白起的线性对白链（沿 `nextTalk[0]`）。
  List<int> _chain() {
    final row = _row;
    if (row == null) return const [];
    final out = <int>[];
    final seen = <int>{};
    var id = _intOf(row, 'talkId');
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
    for (final k in _talks.keys) {
      final v = int.tryParse(k);
      if (v != null && v > max) max = v;
    }
    return max == 0 ? 1 : max + 1;
  }

  int _newChatId() {
    var max = 0;
    for (final k in _rows.keys) {
      final v = int.tryParse(k);
      if (v != null && v > max) max = v;
    }
    return max == 0 ? 1 : max + 1;
  }

  // ------------------------------------------------------------------
  // 编辑操作
  // ------------------------------------------------------------------

  void _addChat() {
    final id = _newChatId().toString();
    setState(() {
      _rows[id] = <String, dynamic>{
        'id': int.tryParse(id),
        'npc': 0,
        'name': '',
        'text': '',
        'map': <dynamic>[],
        'talkId': 0,
        'cond': <dynamic>[],
        'effect': <dynamic>[],
      };
      _selected = id;
      _line = null;
    });
  }

  void _deleteChat() {
    final id = _selected;
    if (id == null) return;
    setState(() {
      _rows.remove(id);
      final ids = _sortedIds;
      _selected = ids.isNotEmpty ? ids.first : null;
      _line = _chain().isNotEmpty ? _chain().first : null;
    });
  }

  Future<void> _deleteLine(int id) async {
    final ok = await fluent.showDialog<bool>(
      context: context,
      builder: (ctx) => AppContentDialog(
        title: const Text('删除这句对白？'),
        content: Text(
          '将从闲聊对白链中移除该句（TalkCfg 记录一并删除）。\n'
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
    final chain = _chain();
    final idx = chain.indexOf(id);
    final prev = idx > 0 ? chain[idx - 1] : null;
    final next = idx >= 0 && idx < chain.length - 1 ? chain[idx + 1] : null;
    setState(() {
      final row = _row;
      if (row == null) return;
      if (prev != null) {
        final p = _talkOf(prev);
        if (p != null) p['nextTalk'] = next != null ? [next] : <dynamic>[];
      } else {
        row['talkId'] = next ?? 0;
      }
      _talks.remove(id.toString());
      final c = _chain();
      _line = c.isNotEmpty ? c.first : null;
    });
  }

  void _addLine(int speaker) {
    final row = _row;
    if (row == null) return;
    final chain = _chain();
    final id = _newTalkId();
    setState(() {
      _talks[id.toString()] = <String, dynamic>{
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
        row['talkId'] = id;
      } else {
        final last = _talkOf(chain.last);
        if (last != null) last['nextTalk'] = [id];
      }
      _line = id;
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

  Future<int?> _pickPlace() async {
    var query = '';
    final entries = _maps.entries.toList()
      ..sort((a, b) =>
          (int.tryParse(a.key) ?? 0).compareTo(int.tryParse(b.key) ?? 0));
    return fluent.showDialog<int>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) {
          final list = entries.where((e) =>
              query.isEmpty ||
              e.key.contains(query) ||
              e.value.toString().toLowerCase().contains(query)).toList();
          return AppContentDialog(
            title: const Text('选择闲聊地点'),
            content: SizedBox(
              width: 440,
              height: 440,
              child: Column(
                children: [
                  fluent.TextBox(
                    placeholder: '搜索地点名称或编号',
                    onChanged: (v) =>
                        setLocal(() => query = v.trim().toLowerCase()),
                  ),
                  const SizedBox(height: 10),
                  Expanded(
                    child: ListView(
                      children: [
                        _pickerRow(ctx, 0, '不限地点'),
                        for (final e in list)
                          _pickerRow(ctx, int.tryParse(e.key) ?? 0,
                              e.value.toString(),
                              sub: e.key),
                      ],
                    ),
                  ),
                ],
              ),
            ),
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

  Future<void> _editBlocks(String field, String mode) async {
    final row = _row;
    if (row == null) return;
    final out = await showBlockLibrary(
      context,
      initialText: ValueCodec.encode(row[field] ?? const <dynamic>[]),
      initialMode: mode,
      gameDicts: widget.state.gameDicts,
      title: mode == 'condition' ? '积木库 · 条件' : '积木库 · 效果',
    );
    if (out == null || !mounted) return;
    setState(() => row[field] = ValueCodec.decode(out, '2D Array'));
  }

  Future<void> _setSpeaker(int talkId) async {
    final id = await _pickRole();
    if (id == null || !mounted) return;
    setState(() {
      final talk = _talkOf(talkId);
      if (talk != null) talk['roleIds'] = [id];
    });
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
              Text('闲聊数据加载失败',
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
    final q = _search.trim().toLowerCase();
    final ids = _sortedIds.where((id) {
      if (q.isEmpty) return true;
      final row = _rowOf(id);
      return id.contains(q) ||
          (row?['text']?.toString().toLowerCase() ?? '').contains(q) ||
          _roleName(_intOf(row, 'npc')).toLowerCase().contains(q);
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
                  placeholder: '搜索闲聊或人物',
                  onChanged: (v) => setState(() => _search = v),
                ),
                const SizedBox(height: 10),
                fluent.FilledButton(
                  onPressed: _addChat,
                  child: const Text('＋ 添加闲聊',
                      style: TextStyle(fontSize: 12.5)),
                ),
                const SizedBox(height: 6),
                _MiniBtn(
                  label: '删除此闲聊',
                  danger: true,
                  enabled: _selected != null,
                  onTap: _deleteChat,
                ),
              ],
            ),
          ),
          Divider(height: 1, color: palette.border),
          Expanded(
            child: ids.isEmpty
                ? Center(
                    child: Text(
                      _rows.isEmpty ? '还没有闲聊，点「添加闲聊」。' : '没有匹配的闲聊。',
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
                      return _ChatListItem(
                        id: id,
                        npcName: _roleName(npc),
                        npcId: npc,
                        text: row?['text']?.toString() ?? '',
                        lineCount: id == _selected ? _chain().length : 0,
                        selected: id == _selected,
                        onTap: () => setState(() {
                          _selected = id;
                          _line = _chain().isNotEmpty ? _chain().first : null;
                        }),
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
                    '添加或选择左侧闲聊，编辑人物、地点与线性对白。',
                    style: TextStyle(fontSize: 13, color: palette.textHint),
                  ),
                )
              : SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(22, 20, 22, 24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _settingsCard(row),
                      _chainCard(row),
                    ],
                  ),
                ),
        ),
        _saveBar(),
      ],
    );
  }

  Widget _settingsCard(Map<String, dynamic> row) {
    final npc = _intOf(row, 'npc');
    final place = _intList(row, 'map');
    return _SectionCard(
      title: '闲聊设置',
      icon: FluentIcons.settings_24_regular,
      children: [
        _labeled('进度文字', _SyncedText(
          value: row['text']?.toString() ?? '',
          hint: '正在和谁……',
          onChanged: (v) => setState(() => row['text'] = v),
        )),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: _labeled(
                '闲聊人物',
                MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    onTap: () async {
                      final id = await _pickRole();
                      if (id == null || !mounted) return;
                      setState(() {
                        row['npc'] = id;
                        row['name'] = _roleName(id);
                      });
                    },
                    child: _valueBox(
                        npc == 0 ? '未选择人物' : _roleName(npc)),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _labeled(
                '闲聊地点',
                MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    onTap: () async {
                      final id = await _pickPlace();
                      if (id == null || !mounted) return;
                      setState(() =>
                          row['map'] = id == 0 ? <dynamic>[] : [id]);
                    },
                    child: _valueBox(place.isEmpty
                        ? '不限地点'
                        : place.map(_placeName).join('、')),
                  ),
                ),
              ),
            ),
          ],
        ),
        _listLine('触发条件', '${_lenOf(row, 'cond')} 条',
            palette.statusInfo, () => _editBlocks('cond', 'condition')),
        const SizedBox(height: 8),
        _listLine('闲聊效果', '${_lenOf(row, 'effect')} 条',
            palette.statusOk, () => _editBlocks('effect', 'effect')),
      ],
    );
  }

  Widget _chainCard(Map<String, dynamic> row) {
    final chain = _chain();
    final npc = _intOf(row, 'npc');
    return _SectionCard(
      title: '对白链',
      icon: FluentIcons.chat_24_regular,
      subtitle: chain.isEmpty
          ? '还没有对白，点下方按钮添加第一句。'
          : '共 ${chain.length} 句；在下方直接修改内容与说话人。',
      children: [
        for (var i = 0; i < chain.length; i++)
          _lineCard(chain[i], i, chain.length, npc),
        const SizedBox(height: 4),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _MiniBtn(label: '＋ 白雨对白', onTap: () => _addLine(0)),
            _MiniBtn(
              label: '＋ ${npc == 0 ? '人物' : _roleName(npc)}对白',
              onTap: () => _addLine(npc),
            ),
          ],
        ),
      ],
    );
  }

  Widget _lineCard(int talkId, int index, int total, int npc) {
    final talk = _talkOf(talkId);
    if (talk == null) return const SizedBox.shrink();
    final roles = _intList(talk, 'roleIds');
    final speaker = roles.isNotEmpty ? roles.first : npc;
    final selected = talkId == _line;
    final isLast = index == total - 1;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => setState(() => _line = talkId),
          child: Container(
            padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
            decoration: BoxDecoration(
              color: selected ? palette.card : palette.bgAlt,
              borderRadius: BorderRadius.circular(9),
              border: Border.all(
                color: selected
                    ? accentColor.withValues(alpha: 0.5)
                    : palette.border,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text('${index + 1}.',
                        style: TextStyle(
                            fontSize: 11, color: palette.textHint)),
                    const SizedBox(width: 6),
                    MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: GestureDetector(
                        onTap: () => _setSpeaker(talkId),
                        child: _SpeakerChip(
                          name: _roleName(speaker),
                          isPlayer: speaker == 0,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text('对白 $talkId',
                        style: TextStyle(
                            fontSize: 10, color: palette.textHint)),
                    const Spacer(),
                    if (isLast)
                      Text('末句',
                          style: TextStyle(
                              fontSize: 10, color: palette.textMuted)),
                    const SizedBox(width: 6),
                    fluent.IconButton(
                      icon: Icon(FluentIcons.delete_24_regular,
                          size: 13, color: palette.statusDanger),
                      onPressed: () => _deleteLine(talkId),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                _SyncedText(
                  value: talk['content']?.toString() ?? '',
                  hint: '输入对白内容',
                  maxLines: 2,
                  onChanged: (v) => setState(() => talk['content'] = v),
                ),
              ],
            ),
          ),
        ),
      ),
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
    return Container(
      width: w,
      color: palette.panel,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        child: row == null
            ? Text('选择左侧闲聊查看预览。',
                style: TextStyle(fontSize: 12, color: palette.textHint))
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    (row['text']?.toString().trim().isNotEmpty ?? false)
                        ? row['text'].toString()
                        : '未填写进度文字',
                    style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: palette.textHigh),
                  ),
                  const SizedBox(height: 4),
                  Text('ID ${row['id']}',
                      style:
                          TextStyle(fontSize: 11, color: palette.textHint)),
                  const SizedBox(height: 14),
                  _railCard('概览', [
                    '人物：${_intOf(row, 'npc') == 0 ? '未选择' : _roleName(_intOf(row, 'npc'))}',
                    '地点：${_intList(row, 'map').isEmpty ? '不限' : _intList(row, 'map').map(_placeName).join('、')}',
                    '对白：${_chain().length} 句',
                    '触发条件：${_lenOf(row, 'cond')} 条',
                    '闲聊效果：${_lenOf(row, 'effect')} 条',
                  ]),
                  const SizedBox(height: 12),
                  _previewCard(row),
                ],
              ),
      ),
    );
  }

  Widget _previewCard(Map<String, dynamic> row) {
    final chain = _chain();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(13, 11, 13, 14),
      decoration: BoxDecoration(
        color: palette.bgAlt,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: palette.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('对话预览',
              style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: palette.goldText)),
          const SizedBox(height: 10),
          if (chain.isEmpty)
            Text('（还没有对白）',
                style: TextStyle(fontSize: 11.5, color: palette.textHint))
          else
            for (final id in chain) _bubble(id),
        ],
      ),
    );
  }

  Widget _bubble(int talkId) {
    final talk = _talkOf(talkId);
    if (talk == null) return const SizedBox.shrink();
    final roles = _intList(talk, 'roleIds');
    final speaker = roles.isNotEmpty ? roles.first : 0;
    final outgoing = speaker == 0;
    final selected = talkId == _line;
    final content = talk['content']?.toString().trim() ?? '';
    return Padding(
      padding: EdgeInsets.only(
        left: outgoing ? 28 : 0,
        right: outgoing ? 0 : 28,
        bottom: 7,
      ),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => setState(() => _line = talkId),
          child: Column(
            crossAxisAlignment:
                outgoing ? CrossAxisAlignment.end : CrossAxisAlignment.start,
            children: [
              Text(_roleName(speaker),
                  style: TextStyle(fontSize: 10, color: palette.textHint)),
              const SizedBox(height: 2),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
                decoration: BoxDecoration(
                  color: outgoing
                      ? accentColor.withValues(alpha: 0.85)
                      : palette.card,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: selected
                        ? palette.goldText
                        : (outgoing ? accentColor : palette.border),
                    width: selected ? 1.6 : 1,
                  ),
                ),
                child: Text(
                  content.isEmpty ? '（空白对白）' : content,
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.5,
                    color:
                        outgoing ? palette.onAccent : palette.textPrimary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
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

  // ---------- 通用 ----------

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
      child: Row(
        children: [
          Expanded(
            child: Text(text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style:
                    TextStyle(fontSize: 12.5, color: palette.textPrimary)),
          ),
          Text('选择',
              style: TextStyle(fontSize: 11, color: accentColor)),
        ],
      ),
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
                  style: TextStyle(fontSize: 12, color: palette.textPrimary)),
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

class _SpeakerChip extends StatelessWidget {
  const _SpeakerChip({required this.name, required this.isPlayer});
  final String name;
  final bool isPlayer;

  @override
  Widget build(BuildContext context) {
    final color = isPlayer ? accentColor : palette.goldText;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.45)),
      ),
      child: Text('$name ▾',
          style: TextStyle(fontSize: 11, color: color)),
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

class _ChatListItem extends StatefulWidget {
  const _ChatListItem({
    required this.id,
    required this.npcName,
    required this.npcId,
    required this.text,
    required this.lineCount,
    required this.selected,
    required this.onTap,
  });

  final String id;
  final String npcName;
  final int npcId;
  final String text;
  final int lineCount;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_ChatListItem> createState() => _ChatListItemState();
}

class _ChatListItemState extends State<_ChatListItem> {
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
              RoleAvatar(seed: widget.npcId, name: widget.npcName),
              const SizedBox(width: 9),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.text.trim().isEmpty ? '未填写进度文字' : widget.text,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 12.5,
                          fontWeight:
                              selected ? FontWeight.w600 : FontWeight.normal,
                          color: selected
                              ? palette.textHigh
                              : palette.textPrimary),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      widget.selected && widget.lineCount > 0
                          ? '${widget.npcName} · ${widget.lineCount} 句对白'
                          : widget.npcName,
                      style: TextStyle(
                          fontSize: 10.5, color: palette.textMuted),
                    ),
                  ],
                ),
              ),
              Text(widget.id,
                  style:
                      TextStyle(fontSize: 10, color: palette.textHint)),
            ],
          ),
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
