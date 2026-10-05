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
import '../nocode/entity_picker.dart' show RoleEntry, loadRoles;

/// 手机消息工作台 —— 导演布局下短信对话树的专属界面。
///
/// 三栏：短信列表｜手机对话视图｜短信设置。数据来自 `PhoneMsgCfg`，整表读写。
/// 消息以 `next` 串成对话树：`role == 0` 表示白雨的回复选项；id 约定同组消息
/// 共用 `floor(id / 100)`。整表写回带 `expect_mtime_ns` 乐观锁，409 弹冲突选择。
class MessagesWorkbench extends StatefulWidget {
  const MessagesWorkbench({
    super.key,
    required this.state,
    this.onOpenSearch,
  });

  final AppState state;
  final VoidCallback? onOpenSearch;

  @override
  State<MessagesWorkbench> createState() => _MessagesWorkbenchState();
}

class _MessagesWorkbenchState extends State<MessagesWorkbench>
    with WorkbenchLeaveGuard<MessagesWorkbench> {
  static const _cfg = 'PhoneMsgCfg';

  Map<String, dynamic> _rows = {};
  String _snap = '';
  int? _mtime;

  bool _loading = true;
  bool _saving = false;
  String? _error;

  int? _root;
  int? _selected;
  final Map<int, int> _choices = {};
  String _search = '';

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
  String get guardSubject => '短信与回复分支';

  Future<void> _loadAll() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await ApiClient.instance.get('/api/cfg/$_cfg');
      if (!mounted) return;
      _rows = _dataOf(r);
      _mtime = _mtimeOf(r);
      _snap = jsonEncode(_rows);
      final roots = _roots();
      if (_root == null || !_roots().contains(_root)) {
        _root = roots.isNotEmpty ? roots.first : null;
      }
      _selected = _root;
      _choices.clear();
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
        _info('短信与回复分支已保存', fluent.InfoBarSeverity.success);
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _discard() {
    setState(() {
      _rows = (jsonDecode(_snap) as Map).cast<String, dynamic>();
      final roots = _roots();
      if (_root == null || !roots.contains(_root)) {
        _root = roots.isNotEmpty ? roots.first : null;
      }
      _selected = _root;
      _choices.clear();
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
  // 对话树
  // ------------------------------------------------------------------

  Map<String, dynamic>? _row(int id) {
    final v = _rows[id.toString()];
    return v is Map ? v.cast<String, dynamic>() : null;
  }

  List<int> _listInt(Map<String, dynamic>? row, String field) {
    final v = row?[field];
    if (v is! List) return <int>[];
    return [
      for (final e in v)
        if (e is num) e.toInt() else if (int.tryParse(e.toString()) != null) int.parse(e.toString()),
    ];
  }

  int _roleOf(Map<String, dynamic>? row) {
    final v = row?['role'];
    return v is num ? v.toInt() : (int.tryParse(v?.toString() ?? '') ?? 0);
  }

  /// 根消息：没有被任何消息的 next 引用。
  List<int> _roots() {
    final referenced = <int>{};
    for (final v in _rows.values) {
      if (v is! Map) continue;
      for (final n in _listInt(v.cast<String, dynamic>(), 'next')) {
        referenced.add(n);
      }
    }
    final ids = <int>[];
    for (final k in _rows.keys) {
      final id = int.tryParse(k);
      if (id != null && !referenced.contains(id)) ids.add(id);
    }
    ids.sort();
    return ids;
  }

  int? _parentOf(int id) {
    for (final e in _rows.entries) {
      final v = e.value;
      if (v is! Map) continue;
      final row = v.cast<String, dynamic>();
      if (_listInt(row, 'next').contains(id)) {
        return int.tryParse(e.key);
      }
    }
    return null;
  }

  Set<int> _reachable(int root) {
    final out = <int>{};
    void visit(int id) {
      if (!out.add(id)) return;
      for (final n in _listInt(_row(id), 'next')) {
        visit(n);
      }
    }

    visit(root);
    return out;
  }

  /// 从根沿选择（缺省取第一条 next）串成的对话链；遇到白雨选项则停在该节点。
  List<int> _chain() {
    final root = _root;
    if (root == null) return const [];
    final out = <int>[];
    final seen = <int>{};
    int? id = root;
    while (id != null && _row(id) != null && seen.add(id)) {
      out.add(id);
      final next = _listInt(_row(id), 'next');
      if (next.isEmpty) break;
      final choice = _choices[id];
      if (choice != null && next.contains(choice)) {
        id = choice;
        continue;
      }
      final player =
          next.where((n) => _roleOf(_row(n)) == 0).toList();
      if (player.isNotEmpty) break;
      id = next.first;
    }
    return out;
  }

  /// 链尾节点上的白雨选项（若有）。
  List<int> _pendingOptions() {
    final chain = _chain();
    if (chain.isEmpty) return const [];
    final last = chain.last;
    return _listInt(_row(last), 'next')
        .where((n) => _roleOf(_row(n)) == 0)
        .toList();
  }

  int _nextId(int root) {
    final start = (root ~/ 100) * 100;
    for (var id = start + 1; id <= start + 99; id++) {
      if (id != root && !_rows.containsKey(id.toString())) return id;
    }
    // 组内用尽：顺延到下一组。
    var id = start + 100;
    while (_rows.containsKey(id.toString())) {
      id++;
    }
    return id;
  }

  int _newRootId() {
    var max = 0;
    for (final k in _rows.keys) {
      final v = int.tryParse(k);
      if (v != null && v > max) max = v;
    }
    return max == 0 ? 1 : max + 1;
  }

  String _roleName(int id) {
    for (final r in _roles) {
      if (r.id == id.toString()) {
        return r.name.isEmpty ? '角色 $id' : r.name;
      }
    }
    return id == 0 ? '白雨' : '角色 $id';
  }

  String _snippet(int id) {
    final row = _row(id);
    final content = row?['content']?.toString() ?? '';
    final text = content.replaceAll(RegExp(r'<[^>]*>'), '').trim();
    if (text.isEmpty) return '（空白短信）';
    return text.length > 40 ? '${text.substring(0, 40)}…' : text;
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
            title: const Text('选择联系人'),
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
                          MouseRegion(
                            cursor: SystemMouseCursors.click,
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: () => Navigator.pop(
                                  ctx, int.tryParse(r.id) ?? 0),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 10, vertical: 9),
                                child: Row(
                                  children: [
                                    _Avatar(
                                        seed: int.tryParse(r.id) ?? 0,
                                        name: r.name),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Text(r.name,
                                          style: TextStyle(
                                              fontSize: 12.5,
                                              color: palette.textPrimary)),
                                    ),
                                    Text(r.id,
                                        style: TextStyle(
                                            fontSize: 10.5,
                                            color: palette.textHint)),
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

  Future<String?> _textDialog(String heading) async {
    final ctrl = TextEditingController();
    final result = await fluent.showDialog<String>(
      context: context,
      builder: (ctx) => AppContentDialog(
        title: Text(heading),
        content: SizedBox(
          width: 440,
          child: fluent.TextBox(
            controller: ctrl,
            maxLines: 4,
            placeholder: '输入短信内容',
          ),
        ),
        actions: [
          fluent.Button(
            onPressed: () => Navigator.pop(ctx, null),
            child: const Text('取消'),
          ),
          fluent.FilledButton(
            onPressed: () {
              final text = ctrl.text.trim();
              if (text.isNotEmpty) Navigator.pop(ctx, text);
            },
            child: const Text('添加'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    return result;
  }

  Future<void> _newConversation() async {
    final role = await _pickRole();
    if (role == null || !mounted) return;
    final id = _newRootId();
    setState(() {
      _rows[id.toString()] = <String, dynamic>{
        'id': id,
        'role': role,
        'content': '',
        'next': <dynamic>[],
        'option': '',
        'cond': <dynamic>[],
        'effect': <dynamic>[],
      };
      _root = id;
      _selected = id;
      _choices.clear();
    });
  }

  Future<void> _appendContact() async {
    final root = _root;
    if (root == null) return;
    final chain = _chain();
    final ownerId = chain.isNotEmpty ? chain.last : root;
    final owner = _row(ownerId);
    if (owner == null) return;
    if (_listInt(owner, 'next').isNotEmpty) {
      _info('这条消息后已有分支，请先在手机视图里选择要继续的分支。',
          fluent.InfoBarSeverity.warning);
      return;
    }
    final text = await _textDialog('添加${_roleName(_roleOf(_row(root)))}信息');
    if (text == null || !mounted) return;
    setState(() {
      if (ownerId == root && (owner['content']?.toString() ?? '').isEmpty) {
        owner['content'] = text;
        _selected = root;
        return;
      }
      final id = _nextId(root);
      _rows[id.toString()] = <String, dynamic>{
        'id': id,
        'role': _roleOf(_row(root)),
        'content': text,
        'next': <dynamic>[],
        'option': '',
        'cond': <dynamic>[],
        'effect': <dynamic>[],
      };
      owner['next'] = [..._listInt(owner, 'next'), id];
      _selected = id;
    });
  }

  Future<void> _appendPlayer({bool alternative = false}) async {
    final root = _root;
    if (root == null) return;
    var ownerId = alternative
        ? (_selected ?? (_chain().isNotEmpty ? _chain().last : root))
        : (_chain().isNotEmpty ? _chain().last : root);
    var owner = _row(ownerId);
    if (owner == null) return;
    if (alternative && _roleOf(owner) == 0) {
      final parent = _parentOf(ownerId);
      if (parent != null) {
        ownerId = parent;
        owner = _row(ownerId);
      }
    }
    if (owner == null) return;
    final existingPlayer = _listInt(owner, 'next')
        .where((n) => _roleOf(_row(n)) == 0)
        .toList();
    if (alternative && existingPlayer.length >= 2) {
      _info('同一条消息最多两个白雨回复。', fluent.InfoBarSeverity.warning);
      return;
    }
    if (!alternative && _listInt(owner, 'next').isNotEmpty) {
      _info('这条消息后已有分支，请先选择要继续编辑的分支。',
          fluent.InfoBarSeverity.warning);
      return;
    }
    final text = await _textDialog('添加白雨信息');
    if (text == null || !mounted) return;
    setState(() {
      final id = _nextId(root);
      _rows[id.toString()] = <String, dynamic>{
        'id': id,
        'role': 0,
        'content': text,
        'option': text,
        'next': <dynamic>[],
        'cond': <dynamic>[],
        'effect': <dynamic>[],
      };
      owner!['next'] = [..._listInt(owner, 'next'), id];
      _choices[ownerId] = id;
      _selected = id;
    });
  }

  void _deleteSelected() {
    final id = _selected;
    if (id == null) return;
    final root = _root;
    setState(() {
      if (id == root) {
        final doomed = _reachable(id);
        for (final d in doomed) {
          _rows.remove(d.toString());
        }
        final roots = _roots();
        _root = roots.isNotEmpty ? roots.first : null;
        _selected = _root;
      } else {
        final doomed = _reachable(id);
        final parent = _parentOf(id);
        if (parent != null) {
          final p = _row(parent);
          if (p != null) {
            p['next'] =
                _listInt(p, 'next').where((n) => n != id).toList();
          }
        }
        for (final d in doomed) {
          _rows.remove(d.toString());
        }
        _selected = root;
      }
      _choices.clear();
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
              Text('短信数据加载失败',
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
      rightLabel: '短信设置',
    );
  }

  // ---------- 左栏 ----------

  Widget _leftPanel(double w) {
    final q = _search.trim().toLowerCase();
    final roots = _roots().where((id) {
      if (q.isEmpty) return true;
      final name = _roleName(_roleOf(_row(id))).toLowerCase();
      return id.toString().contains(q) ||
          name.contains(q) ||
          _snippet(id).toLowerCase().contains(q);
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
                  placeholder: '搜索联系人或短信',
                  onChanged: (v) => setState(() => _search = v),
                ),
                const SizedBox(height: 10),
                fluent.FilledButton(
                  onPressed: _newConversation,
                  child: const Text('＋ 创建短信',
                      style: TextStyle(fontSize: 12.5)),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: palette.border),
          Expanded(
            child: roots.isEmpty
                ? Center(
                    child: Text(
                      _rows.isEmpty ? '还没有短信，点「创建短信」新建。' : '没有匹配的短信。',
                      style:
                          TextStyle(fontSize: 12, color: palette.textHint),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 8),
                    itemCount: roots.length,
                    itemBuilder: (context, i) {
                      final id = roots[i];
                      final role = _roleOf(_row(id));
                      return _ConversationItem(
                        id: id,
                        name: _roleName(role),
                        roleId: role,
                        title: _snippet(id),
                        count: _reachable(id).length,
                        selected: id == _root,
                        onTap: () => setState(() {
                          _root = id;
                          _selected = id;
                          _choices.clear();
                        }),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  // ---------- 中栏：手机视图 ----------

  Widget _center() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: _root == null
              ? Center(
                  child: Text(
                    '创建一段短信：先选择联系人，再添加消息与回复。',
                    style: TextStyle(fontSize: 13, color: palette.textHint),
                  ),
                )
              : Padding(
                  padding: const EdgeInsets.fromLTRB(22, 18, 22, 8),
                  child: _phone(),
                ),
        ),
        _composeBar(),
        _saveBar(),
      ],
    );
  }

  Widget _phone() {
    final root = _root!;
    final role = _roleOf(_row(root));
    final chain = _chain();
    final options = _pendingOptions();
    return Center(
      child: Container(
        constraints: const BoxConstraints(maxWidth: 400),
        decoration: BoxDecoration(
          color: palette.card,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: palette.border),
          boxShadow: [
            BoxShadow(
              color: palette.scrimWeak,
              blurRadius: 18,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Column(
          children: [
            // 状态栏
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
              child: Row(
                children: [
                  Text('12:00',
                      style: TextStyle(
                          fontSize: 11, color: palette.textSecondary)),
                  const Spacer(),
                  Icon(FluentIcons.battery_10_24_regular,
                      size: 13, color: palette.textSecondary),
                  const SizedBox(width: 4),
                  Icon(FluentIcons.wifi_1_24_regular,
                      size: 13, color: palette.textSecondary),
                ],
              ),
            ),
            Divider(height: 1, color: palette.border),
            // 联系人标题
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  Icon(FluentIcons.chevron_left_24_regular,
                      size: 15, color: palette.textHint),
                  const SizedBox(width: 8),
                  _Avatar(seed: role, name: _roleName(role), size: 28),
                  const SizedBox(width: 8),
                  Text(_roleName(role),
                      style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                          color: palette.textHigh)),
                  const Spacer(),
                  Text('ID $root',
                      style:
                          TextStyle(fontSize: 10.5, color: palette.textHint)),
                ],
              ),
            ),
            Divider(height: 1, color: palette.border),
            // 消息
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(
                    horizontal: 14, vertical: 12),
                children: [
                  for (final id in chain) _bubble(id),
                  if (options.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    for (final o in options)
                      _OptionBubble(
                        text: (_row(o)?['option']?.toString() ??
                                    _row(o)?['content']?.toString() ??
                                    '回复')
                                .toString(),
                        selected: _choices[chain.last] == o,
                        onTap: () => setState(() {
                          _choices[chain.last] = o;
                          _selected = o;
                        }),
                      ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _bubble(int id) {
    final row = _row(id);
    if (row == null) return const SizedBox.shrink();
    final outgoing = _roleOf(row) == 0;
    final selected = id == _selected;
    final content = (_row(id)?['content']?.toString() ?? '').trim();
    return Padding(
      padding: EdgeInsets.only(
        left: outgoing ? 40 : 0,
        right: outgoing ? 0 : 40,
        bottom: 8,
      ),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => setState(() => _selected = id),
          child: Row(
            mainAxisAlignment:
                outgoing ? MainAxisAlignment.end : MainAxisAlignment.start,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (!outgoing) ...[
                _Avatar(
                    seed: _roleOf(row), name: _roleName(_roleOf(row)), size: 26),
                const SizedBox(width: 6),
              ],
              Flexible(
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                  decoration: BoxDecoration(
                    color: outgoing
                        ? accentColor.withValues(alpha: 0.9)
                        : palette.bgAlt,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: selected
                          ? palette.goldText
                          : (outgoing
                              ? accentColor
                              : palette.border),
                      width: selected ? 1.6 : 1,
                    ),
                  ),
                  child: Text(
                    content.isEmpty ? '点击填写短信' : content,
                    style: TextStyle(
                      fontSize: 12.5,
                      height: 1.5,
                      color: outgoing ? palette.onAccent : palette.textPrimary,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _composeBar() {
    final root = _root;
    final hasNext =
        root != null && _listInt(_row(_selected ?? root), 'next').isNotEmpty;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        alignment: WrapAlignment.center,
        children: [
          _MiniBtn(
            label: root == null
                ? '＋ 添加信息'
                : '＋ 添加${_roleName(_roleOf(_row(root)))}信息',
            enabled: root != null && !hasNext,
            onTap: _appendContact,
          ),
          _MiniBtn(
            label: '＋ 添加白雨信息',
            enabled: root != null && !hasNext,
            onTap: () => _appendPlayer(),
          ),
          _MiniBtn(
            label: '＋ 添加第二种回复',
            enabled: root != null && _selected != null,
            onTap: () => _appendPlayer(alternative: true),
          ),
        ],
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
    final id = _selected;
    final row = id == null ? null : _row(id);
    return Container(
      width: w,
      color: palette.panel,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        child: row == null
            ? Text('选择一条消息查看设置。',
                style: TextStyle(fontSize: 12, color: palette.textHint))
            : _settings(id!, row),
      ),
    );
  }

  Widget _settings(int id, Map<String, dynamic> row) {
    final outgoing = _roleOf(row) == 0;
    final cond = _listInt(row, 'cond');
    final effect = _listInt(row, 'effect');
    final isRoot = id == _root;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(isRoot ? '短信设置' : (outgoing ? '白雨回复' : '联系消息'),
                style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: palette.textHigh)),
            const SizedBox(width: 8),
            Text('ID $id',
                style: TextStyle(fontSize: 11, color: palette.textHint)),
          ],
        ),
        const SizedBox(height: 14),
        if (isRoot)
          _SectionCard(
            title: '发送人',
            children: [
              MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  onTap: () async {
                    final picked = await _pickRole();
                    if (picked == null || !mounted) return;
                    setState(() {
                      for (final n in _reachable(id)) {
                        final r = _row(n);
                        if (r != null && _roleOf(r) == _roleOf(row)) {
                          r['role'] = picked;
                        }
                      }
                    });
                  },
                  child: Row(
                    children: [
                      _Avatar(
                          seed: _roleOf(row),
                          name: _roleName(_roleOf(row))),
                      const SizedBox(width: 8),
                      Text(_roleName(_roleOf(row)),
                          style: TextStyle(
                              fontSize: 12.5, color: palette.textPrimary)),
                      const Spacer(),
                      Text('更换',
                          style: TextStyle(
                              fontSize: 11, color: accentColor)),
                    ],
                  ),
                ),
              ),
            ],
          ),
        _SectionCard(
          title: '短信内容',
          children: [
            _SyncedText(
              value: row['content']?.toString() ?? '',
              hint: '输入短信内容',
              maxLines: 4,
              onChanged: (v) => setState(() => row['content'] = v),
            ),
          ],
        ),
        if (outgoing)
          _SectionCard(
            title: '回复选项文字',
            subtitle: '显示在选项按钮上的文字，默认与短信内容相同。',
            children: [
              _SyncedText(
                value: row['option']?.toString() ?? '',
                hint: '默认与短信内容相同',
                onChanged: (v) => setState(() => row['option'] = v),
              ),
            ],
          ),
        _SectionCard(
          title: '条件与效果',
          children: [
            Text(
              isRoot
                  ? '触发条件：${cond.length} 条　阅读效果：${effect.length} 条'
                  : '出现条件：${cond.length} 条　阅读效果：${effect.length} 条',
              style: TextStyle(fontSize: 12, color: palette.textMuted),
            ),
            const SizedBox(height: 6),
            Text(
              '条件与效果（金钱、好感、状态变化等）请在通用配置表的条件 / 效果'
              '编辑器中维护；这里负责短信内容与回复分支的编排。',
              style: TextStyle(
                  fontSize: 11, height: 1.6, color: palette.textHint),
            ),
          ],
        ),
        const SizedBox(height: 6),
        _MiniBtn(
          label: isRoot ? '删除这段短信' : '删除此消息及后续分支',
          danger: true,
          onTap: _deleteSelected,
        ),
      ],
    );
  }
}

// ----------------------------------------------------------------------
// 通用小部件
// ----------------------------------------------------------------------

class _Avatar extends StatelessWidget {
  const _Avatar({required this.seed, required this.name, this.size = 32});

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
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.22),
        borderRadius: BorderRadius.circular(size * 0.28),
        border: Border.all(color: c.withValues(alpha: 0.5)),
      ),
      child: Text(
        ch,
        style: TextStyle(
          fontSize: size * 0.42,
          fontWeight: FontWeight.w600,
          color: c,
        ),
      ),
    );
  }
}

class _OptionBubble extends StatefulWidget {
  const _OptionBubble({
    required this.text,
    required this.selected,
    required this.onTap,
  });
  final String text;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_OptionBubble> createState() => _OptionBubbleState();
}

class _OptionBubbleState extends State<_OptionBubble> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerRight,
      child: Padding(
        padding: const EdgeInsets.only(left: 40, bottom: 8),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          child: GestureDetector(
            onTap: widget.onTap,
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              decoration: BoxDecoration(
                color: widget.selected || _hover
                    ? accentColor.withValues(alpha: 0.16)
                    : palette.bgAlt,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: widget.selected
                      ? accentColor.withValues(alpha: 0.6)
                      : palette.borderHover,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(FluentIcons.arrow_reply_24_regular,
                      size: 12, color: accentColor),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(widget.text,
                        style: TextStyle(
                            fontSize: 12.5, color: palette.textPrimary)),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ConversationItem extends StatefulWidget {
  const _ConversationItem({
    required this.id,
    required this.name,
    required this.roleId,
    required this.title,
    required this.count,
    required this.selected,
    required this.onTap,
  });

  final int id;
  final String name;
  final int roleId;
  final String title;
  final int count;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_ConversationItem> createState() => _ConversationItemState();
}

class _ConversationItemState extends State<_ConversationItem> {
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
              _Avatar(seed: widget.roleId, name: widget.name, size: 36),
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
                        Text('${widget.id}',
                            style: TextStyle(
                                fontSize: 10, color: palette.textHint)),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(widget.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 11.5,
                            height: 1.5,
                            color: palette.textMuted)),
                    const SizedBox(height: 4),
                    Text('${widget.count} 条消息',
                        style: TextStyle(
                            fontSize: 10.5, color: palette.textHint)),
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
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
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
