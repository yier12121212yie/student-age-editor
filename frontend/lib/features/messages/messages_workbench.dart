import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../../core/api_client.dart';
import '../../core/app_dialogs.dart';
import '../../core/app_feedback.dart';
import '../../core/app_theme.dart';
import '../../core/error_text.dart';
import '../../core/models.dart';
import '../../core/workbench_controller.dart';
import '../../core/workbench_guard.dart';
import '../../core/workbench_scaffold.dart';
import '../../core/save_bar.dart';
import '../editor/section_card.dart';
import '../editor/synced_fields.dart';
import '../nocode/entity_picker.dart' show RoleEntry, loadRoles;
import '../resources/role_visuals.dart';

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

  /// A3：[A3]整表 load/save/dirty/乐观锁 409 交给公共控制器。
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
      if (mounted) AppFeedback.success(context, '短信与回复分支已保存');
    },
  );

  Map<String, dynamic> get _rows => _ctl.table(_cfg).data;

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
  String get guardSubject => '短信与回复分支';

  Future<void> _loadAll() async {
    try {
      await _ctl.load();
      if (!mounted) return;
      final roots = _roots();
      if (_root == null || !_roots().contains(_root)) {
        _root = roots.isNotEmpty ? roots.first : null;
      }
      _selected = _root;
      _choices.clear();
      _loadRoles();
    } catch (_) {
      // 错误已由控制器记录并经监听器反映到 _error。
    }
  }

  Future<void> _loadRoles() async {
    final list = await loadRoles('');
    if (!mounted) return;
    setState(() => _roles = list);
  }

  bool get _dirty => _ctl.dirtyDeep;

  Future<void> _saveAll() => _ctl.save();

  void _discard() {
    _ctl.discard();
    final roots = _roots();
    if (_root == null || !roots.contains(_root)) {
      _root = roots.isNotEmpty ? roots.first : null;
    }
    _selected = _root;
    _choices.clear();
  }

  /// 409 冲突弹窗 → 控制器的 [WorkbenchConflictChoice]。
  Future<WorkbenchConflictChoice?> _onConflict(WorkbenchTable table) =>
      showWorkbenchConflictDialog(context, table);



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
      AppFeedback.warning(
          context, '这条消息后已有分支，请先在手机视图里选择要继续的分支。');
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
      AppFeedback.warning(context, '同一条消息最多两个白雨回复。');
      return;
    }
    if (!alternative && _listInt(owner, 'next').isNotEmpty) {
      AppFeedback.warning(
          context, '这条消息后已有分支，请先选择要继续编辑的分支。');
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
    return WorkbenchScaffold(
      errorTitle: '消息数据加载失败',
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
                  RoleAvatar(seed: role, name: _roleName(role), size: 28),
                  const SizedBox(width: 8),
                  Text(_roleName(role),
                      style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                          color: palette.textHigh)),
                  const Spacer(),
                  Text('编号 $root',
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
                RoleAvatar(
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
          WorkbenchMiniButton(
            label: root == null
                ? '＋ 添加信息'
                : '＋ 添加${_roleName(_roleOf(_row(root)))}信息',
            enabled: root != null && !hasNext,
            onTap: _appendContact,
          ),
          WorkbenchMiniButton(
            label: '＋ 添加白雨信息',
            enabled: root != null && !hasNext,
            onTap: () => _appendPlayer(),
          ),
          WorkbenchMiniButton(
            label: '＋ 添加第二种回复',
            enabled: root != null && _selected != null,
            onTap: () => _appendPlayer(alternative: true),
          ),
        ],
      ),
    );
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
            Text('编号 $id',
                style: TextStyle(fontSize: 11, color: palette.textHint)),
          ],
        ),
        const SizedBox(height: 14),
        if (isRoot)
          WorkbenchSectionCard(
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
                      RoleAvatar(
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
        WorkbenchSectionCard(
          title: '短信内容',
          children: [
            SyncedTextField(
              value: row['content']?.toString() ?? '',
              hint: '输入短信内容',
              maxLines: 4,
              onChanged: (v) => setState(() => row['content'] = v),
            ),
          ],
        ),
        if (outgoing)
          WorkbenchSectionCard(
            title: '回复选项文字',
            subtitle: '显示在选项按钮上的文字，默认与短信内容相同。',
            children: [
              SyncedTextField(
                value: row['option']?.toString() ?? '',
                hint: '默认与短信内容相同',
                onChanged: (v) => setState(() => row['option'] = v),
              ),
            ],
          ),
        WorkbenchSectionCard(
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
        WorkbenchMiniButton(
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
              RoleAvatar(seed: widget.roleId, name: widget.name, size: 36),
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

