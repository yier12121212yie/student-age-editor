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
import '../pages/pages_catalog.dart';

/// JSON 侧栏工作台 —— 导演布局下「JSON 侧栏」的专属界面。
///
/// 三栏：配置表列表（搜索）｜记录列表 + 原始 JSON 编辑器｜表信息与解析状态。
///
/// 直接读写任意配置表的原始 JSON：选中一张表，逐条记录查看 / 编辑其 JSON，
/// 校验通过后按整表写回（`expect_mtime_ns` 乐观锁）。适合高级用户核对或批量改动
/// 常规工作台未覆盖的字段。
class JsonWorkbench extends StatefulWidget {
  const JsonWorkbench({
    super.key,
    required this.state,
    this.onOpenSearch,
  });

  final AppState state;
  final VoidCallback? onOpenSearch;

  @override
  State<JsonWorkbench> createState() => _JsonWorkbenchState();
}

/// 常规工作台未覆盖、也值得在 JSON 侧栏直接编辑的表。
const _extraTables = <String>[
  'MinigameCfg',
  'MinigameActionCfg',
  'KZoneProfileCfg',
  'KZoneMessageBoardCfg',
  'KZoneContentCfg',
  'KZoneCommentCfg',
  'KZoneAvatarCfg',
  'KZoneColorCfg',
  'KZoneFontCfg',
  'InteractCfg',
];

class _JsonWorkbenchState extends State<JsonWorkbench>
    with WorkbenchLeaveGuard<JsonWorkbench> {
  List<String> _tables = const [];

  String? _table;
  Map<String, dynamic> _data = {};
  String _snap = '';
  int? _mtime;

  bool _loading = false;
  bool _saving = false;
  String? _error;
  String? _parseError;

  String? _selId;

  String _tableSearch = '';
  String _recordSearch = '';

  final TextEditingController _tableCtrl = TextEditingController();
  final TextEditingController _recordCtrl = TextEditingController();
  final TextEditingController _jsonCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    final set = <String>{
      for (final p in editorPages) ...p.cfgNames,
      ..._extraTables,
    };
    _tables = set.toList()..sort();
  }

  @override
  void dispose() {
    _tableCtrl.dispose();
    _recordCtrl.dispose();
    _jsonCtrl.dispose();
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
  Future<void> guardSave() => _save();
  @override
  void guardDiscard() => _discard();
  @override
  Future<void> guardReload() async {
    final t = _table;
    if (t != null) await _loadTable(t);
  }
  @override
  String get guardSubject => 'JSON 修改';

  Future<void> _loadTable(String name) async {
    setState(() {
      _loading = true;
      _error = null;
      _table = name;
      _parseError = null;
      _selId = null;
      _recordSearch = '';
      _recordCtrl.clear();
    });
    try {
      final r = await ApiClient.instance.get('/api/cfg/$name');
      if (!mounted) return;
      final data = _dataOf(r);
      final ids = _sortedIdsOf(data);
      setState(() {
        _data = data;
        _snap = jsonEncode(data);
        _mtime = _mtimeOf(r);
        _selId = ids.isNotEmpty ? ids.first : null;
        _loading = false;
      });
      _syncEditor();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _reload() async {
    final name = _table;
    if (name == null) return;
    await _loadTable(name);
  }

  bool get _dirty => _table != null && jsonEncode(_data) != _snap;

  Future<void> _save() async {
    final name = _table;
    if (name == null || _saving) return;
    if (_parseError != null) {
      _info('当前记录 JSON 有误，请先修正再保存', fluent.InfoBarSeverity.error);
      return;
    }
    setState(() => _saving = true);
    var force = false;
    try {
      for (;;) {
        try {
          final body = <String, dynamic>{
            'data': _data,
            if (!force) 'expect_mtime_ns': _mtime,
            if (force) 'force': true,
          };
          final r = await ApiClient.instance.put('/api/cfg/$name', body: body);
          if (!mounted) return;
          setState(() {
            _mtime = _mtimeOf(r);
            _snap = jsonEncode(_data);
            _saving = false;
          });
          _info('$name 已保存', fluent.InfoBarSeverity.success);
          return;
        } on ApiException catch (e) {
          if (!mounted) return;
          if (e.statusCode == 409 && !force) {
            final act = await _conflictDialog(name);
            if (!mounted) return;
            if (act == 'reload') {
              setState(() => _saving = false);
              await _reload();
              return;
            }
            if (act == 'force') {
              force = true;
              continue;
            }
            setState(() => _saving = false);
            return;
          }
          _info('保存失败：$e', fluent.InfoBarSeverity.error);
          setState(() => _saving = false);
          return;
        } catch (e) {
          if (!mounted) return;
          _info('保存失败：$e', fluent.InfoBarSeverity.error);
          setState(() => _saving = false);
          return;
        }
      }
    } finally {
      if (mounted && _saving) setState(() => _saving = false);
    }
  }

  void _discard() {
    setState(() {
      _data = (jsonDecode(_snap) as Map).cast<String, dynamic>();
      _parseError = null;
      if (_selId == null || !_data.containsKey(_selId)) {
        final ids = _sortedIds;
        _selId = ids.isNotEmpty ? ids.first : null;
      }
    });
    _syncEditor();
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
  // 记录
  // ------------------------------------------------------------------

  List<String> _sortedIdsOf(Map<String, dynamic> data) {
    final ids = data.keys.toList();
    ids.sort((a, b) {
      final na = int.tryParse(a);
      final nb = int.tryParse(b);
      if (na != null && nb != null) return na.compareTo(nb);
      if (na != null) return -1;
      if (nb != null) return 1;
      return a.compareTo(b);
    });
    return ids;
  }

  List<String> get _sortedIds => _sortedIdsOf(_data);

  Map<String, dynamic>? get _record {
    if (_selId == null) return null;
    final v = _data[_selId];
    return v is Map ? v.cast<String, dynamic>() : null;
  }

  String _label(String id) {
    final row = _data[id];
    if (row is Map) {
      for (final k in const ['name', 'title', 'text', 'content', 'desc']) {
        final s = row[k]?.toString().trim() ?? '';
        if (s.isNotEmpty) return s;
      }
    }
    return '记录 $id';
  }

  void _selectRecord(String id) {
    setState(() {
      _selId = id;
      _parseError = null;
    });
    _syncEditor();
  }

  void _syncEditor() {
    final row = _record;
    _jsonCtrl.text =
        row == null ? '' : const JsonEncoder.withIndent('  ').convert(row);
  }

  void _onJsonChanged(String text) {
    if (_selId == null) return;
    if (text.trim().isEmpty) {
      setState(() => _parseError = '记录不能为空');
      return;
    }
    try {
      final v = jsonDecode(text);
      if (v is! Map) {
        setState(() => _parseError = '记录必须是一个 JSON 对象（{…}）');
        return;
      }
      setState(() {
        _data[_selId!] = v.cast<String, dynamic>();
        _parseError = null;
      });
    } catch (e) {
      setState(() => _parseError = _shortError(e));
    }
  }

  String _shortError(Object e) {
    final s = e.toString();
    return s.length > 160 ? '${s.substring(0, 160)}…' : s;
  }

  void _format() {
    final row = _record;
    if (row == null) return;
    setState(() => _parseError = null);
    _jsonCtrl.text = const JsonEncoder.withIndent('  ').convert(row);
  }

  Future<void> _addRecord() async {
    final ctrl = TextEditingController();
    final id = await fluent.showDialog<String>(
      context: context,
      builder: (ctx) => AppContentDialog(
        title: const Text('新建记录'),
        content: fluent.TextBox(
          controller: ctrl,
          placeholder: '记录编号（非空且不重复）',
          onSubmitted: (v) {
            if (v.trim().isNotEmpty) Navigator.pop(ctx, v.trim());
          },
        ),
        actions: [
          fluent.Button(
            onPressed: () => Navigator.pop(ctx, null),
            child: const Text('取消'),
          ),
          fluent.FilledButton(
            onPressed: () {
              final v = ctrl.text.trim();
              if (v.isNotEmpty) Navigator.pop(ctx, v);
            },
            child: const Text('创建'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (id == null || !mounted) return;
    if (_data.containsKey(id)) {
      _info('记录 $id 已存在', fluent.InfoBarSeverity.warning);
      return;
    }
    setState(() {
      _data[id] = <String, dynamic>{};
      _selId = id;
      _parseError = null;
    });
    _syncEditor();
  }

  Future<void> _deleteRecord() async {
    final id = _selId;
    if (id == null) return;
    final yes = await fluent.showDialog<bool>(
      context: context,
      builder: (ctx) => AppContentDialog(
        title: const Text('删除记录'),
        content: Text('确定删除「${_label(id)}」吗？保存前可以「放弃修改」回滚。',
            style: TextStyle(
                fontSize: 12.5, color: palette.textPrimary, height: 1.5)),
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
    if (yes != true || !mounted) return;
    setState(() {
      _data.remove(id);
      final ids = _sortedIds;
      _selId = ids.isNotEmpty ? ids.first : null;
      _parseError = null;
    });
    _syncEditor();
  }

  // ------------------------------------------------------------------
  // 构建
  // ------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return WorkbenchScaffold(
      leftBuilder: (w) => _tablesPanel(w),
      center: _center(),
      rightBuilder: (w) => _infoPanel(w),
      rightLabel: '表信息',
      rightIcon: FluentIcons.info_24_regular,
    );
  }

  // ---------- 左栏：配置表 ----------

  Widget _tablesPanel(double w) {
    final q = _tableSearch.trim().toLowerCase();
    final list = _tables.where((t) => q.isEmpty || t.toLowerCase().contains(q)).toList();
    return Container(
      width: w,
      color: palette.panel,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
            child: fluent.TextBox(
              controller: _tableCtrl,
              placeholder: '搜索配置表名（如 EvtCfg）',
              onChanged: (v) => setState(() => _tableSearch = v),
            ),
          ),
          Divider(height: 1, color: palette.border),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              itemCount: list.length,
              itemBuilder: (context, i) => _tableTile(list[i]),
            ),
          ),
        ],
      ),
    );
  }

  Widget _tableTile(String name) {
    final selected = name == _table;
    return _HoverTile(
      selected: selected,
      onTap: () => _loadTable(name),
      child: Row(
        children: [
          Icon(FluentIcons.code_24_regular,
              size: 15, color: selected ? accentColor : palette.textMuted),
          const SizedBox(width: 8),
          Expanded(
            child: Text(name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                    color:
                        selected ? palette.textHigh : palette.textPrimary)),
          ),
        ],
      ),
    );
  }

  // ---------- 中栏 ----------

  Widget _center() {
    if (_table == null) {
      return Center(
        child: Text('选择左侧一张配置表，查看与编辑其原始 JSON。',
            style: TextStyle(fontSize: 13, color: palette.textHint)),
      );
    }
    if (_loading) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const fluent.ProgressRing(),
            const SizedBox(height: 10),
            Text('正在读取 $_table…',
                style: TextStyle(fontSize: 12, color: palette.textMuted)),
          ],
        ),
      );
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(FluentIcons.error_circle_24_regular,
                size: 30, color: palette.statusDanger),
            const SizedBox(height: 8),
            Text('读取失败',
                style: TextStyle(fontSize: 13, color: palette.textPrimary)),
            const SizedBox(height: 4),
            Text('$_error',
                style: TextStyle(fontSize: 11, color: palette.textMuted)),
            const SizedBox(height: 10),
            fluent.Button(onPressed: _reload, child: const Text('重试')),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _headerBar(),
        Expanded(child: _editorArea()),
        _saveBar(),
      ],
    );
  }

  Widget _headerBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 12, 10),
      decoration: BoxDecoration(
        color: palette.panel,
        border: Border(bottom: BorderSide(color: palette.border)),
      ),
      child: Row(
        children: [
          Icon(FluentIcons.code_24_regular, size: 18, color: accentColor),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_table ?? '',
                    style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                        color: palette.textHigh)),
                const SizedBox(height: 2),
                Text('${_data.length} 条记录 · JSON 原始编辑',
                    style:
                        TextStyle(fontSize: 10.5, color: palette.textMuted)),
              ],
            ),
          ),
          _MiniBtn(label: '重新加载', onTap: _reload),
          const SizedBox(width: 6),
          _MiniBtn(label: '＋ 记录', onTap: _addRecord),
          const SizedBox(width: 6),
          _MiniBtn(
            label: '删除记录',
            danger: true,
            enabled: _selId != null,
            onTap: _deleteRecord,
          ),
        ],
      ),
    );
  }

  Widget _editorArea() {
    if (_data.isEmpty) {
      return Center(
        child: Text('这张表还没有记录，点「＋ 记录」新建。',
            style: TextStyle(fontSize: 12, color: palette.textHint)),
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(width: 210, child: _recordList()),
        VerticalDivider(width: 1, color: palette.border),
        Expanded(child: _recordEditor()),
      ],
    );
  }

  Widget _recordList() {
    final q = _recordSearch.trim().toLowerCase();
    final ids = _sortedIds.where((id) {
      if (q.isEmpty) return true;
      return id.toLowerCase().contains(q) ||
          _label(id).toLowerCase().contains(q);
    }).toList();
    return Container(
      color: palette.panel,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 10, 10, 6),
            child: fluent.TextBox(
              controller: _recordCtrl,
              placeholder: '搜索记录',
              onChanged: (v) => setState(() => _recordSearch = v),
            ),
          ),
          Divider(height: 1, color: palette.border),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              itemCount: ids.length,
              itemBuilder: (context, i) {
                final id = ids[i];
                final selected = id == _selId;
                return _HoverTile(
                  selected: selected,
                  onTap: () => _selectRecord(id),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 44,
                        child: Text(id,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 10.5, color: palette.textHint)),
                      ),
                      Expanded(
                        child: Text(_label(id),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 12,
                                color: selected
                                    ? palette.textHigh
                                    : palette.textPrimary)),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _recordEditor() {
    final row = _record;
    return Container(
      color: palette.bgDeep2,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
            child: Row(
              children: [
                Text(
                  _selId == null ? '未选择记录' : '记录 #$_selId',
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: palette.textSecondary),
                ),
                const SizedBox(width: 8),
                if (_parseError != null)
                  _Tag(text: 'JSON 有误', color: palette.statusDanger)
                else
                  _Tag(text: 'JSON 有效', color: palette.statusOk),
                const Spacer(),
                _MiniBtn(
                  label: '格式化',
                  enabled: row != null,
                  onTap: _format,
                ),
              ],
            ),
          ),
          if (_parseError != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 6),
              child: Text(_parseError!,
                  style: TextStyle(
                      fontSize: 11, height: 1.5, color: palette.statusDanger)),
            ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
              child: Container(
                decoration: BoxDecoration(
                  color: palette.card,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: palette.border),
                ),
                padding: const EdgeInsets.all(8),
                child: row == null
                    ? Center(
                        child: Text('选择或新建一条记录。',
                            style: TextStyle(
                                fontSize: 12, color: palette.textHint)),
                      )
                    : fluent.TextBox(
                        controller: _jsonCtrl,
                        expands: true,
                        maxLines: null,
                        textAlignVertical: TextAlignVertical.top,
                        placeholder: '{ }',
                        onChanged: _onJsonChanged,
                      ),
              ),
            ),
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
            onPressed: (!dirty || _saving || _parseError != null) ? null : _save,
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

  Widget _infoPanel(double w) {
    final bytes = _table == null ? 0 : utf8.encode(jsonEncode(_data)).length;
    return Container(
      width: w,
      color: palette.panel,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _SectionCard(
              title: '表信息',
              children: [
                _kv('配置表', _table ?? '未选择'),
                _kv('记录数', '${_data.length}'),
                _kv('序列化大小', '${(bytes / 1024).toStringAsFixed(1)} KB'),
                _kv('mtime', _mtime == null ? '—' : '$_mtime'),
              ],
            ),
            _SectionCard(
              title: '当前记录',
              children: [
                _kv('编号', _selId ?? '未选择'),
                _kv('解析状态', _parseError == null ? '有效' : '有误'),
                if (_parseError != null)
                  Text(_parseError!,
                      style: TextStyle(
                          fontSize: 11,
                          height: 1.5,
                          color: palette.statusDanger)),
              ],
            ),
            _SectionCard(
              title: '说明',
              subtitle: 'JSON 侧栏用于核对与高级改动；常规编辑请优先使用专属工作台，'
                  '避免破坏字段类型。保存按整表写回。',
              children: const [],
            ),
          ],
        ),
      ),
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
          margin: const EdgeInsets.only(bottom: 4),
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 8),
          decoration: BoxDecoration(
            color: selected
                ? accentColor.withValues(alpha: 0.12)
                : _hover
                    ? palette.card
                    : Colors.transparent,
            borderRadius: BorderRadius.circular(7),
            border: Border.all(
              color: selected
                  ? accentColor.withValues(alpha: 0.45)
                  : Colors.transparent,
            ),
          ),
          child: widget.child,
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
