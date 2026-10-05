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
import '../resources/image_asset_picker.dart'
    show TexThumb, showImageAssetPicker;

/// 物品仓库工作台 —— 导演布局下「物品仓库」的专属界面。
///
/// 三栏：仓库列表（物品 / 商店两种模式，筛选 / 搜索 / 新建 / 删除）｜
/// 条目详情（基本信息 / 效果指令 / 标签）｜游戏内预览与统计。
///
/// 物品模式编辑 `ItemCfg` + `BookCfg`（书籍），商店模式编辑 `ShopCfg`；
/// 均为整表读写（`expect_mtime_ns` 乐观锁）。`ItemTypeCfg` / `ItemTagCfg` /
/// `BookThemeCfg` 作为只读字典。效果 / 使用效果 / 使用条件直接复用「积木库」。
class WarehouseWorkbench extends StatefulWidget {
  const WarehouseWorkbench({
    super.key,
    required this.state,
    this.onOpenSearch,
  });

  final AppState state;
  final VoidCallback? onOpenSearch;

  @override
  State<WarehouseWorkbench> createState() => _WarehouseWorkbenchState();
}

const _itemCfg = 'ItemCfg';
const _bookCfg = 'BookCfg';
const _shopCfg = 'ShopCfg';

/// 一张正在编辑的配置表（整表数据 + 本次加载快照 + mtime）。
class _TableBuf {
  _TableBuf(this.name, this.data, this.snap, this.mtime);

  final String name;
  Map<String, dynamic> data;
  String snap;
  int? mtime;

  bool get dirty => jsonEncode(data) != snap;
}

/// 仓库列表里的一行（table 可能是 ItemCfg / BookCfg / ShopCfg）。
class _WhEntry {
  const _WhEntry(this.table, this.id, this.row, this.visual);

  final String table;
  final String id;
  final Map<String, dynamic> row;

  /// 用于展示的行：商店条目指向售卖的商品行，其余指向自身。
  final Map<String, dynamic> visual;
}

class _WarehouseWorkbenchState extends State<WarehouseWorkbench>
    with WorkbenchLeaveGuard<WarehouseWorkbench> {
  final Map<String, _TableBuf> _tables = {};

  Map<String, dynamic> _types = {};
  Map<String, dynamic> _tags = {};
  Map<String, dynamic> _bookThemes = {};

  bool _loading = true;
  bool _saving = false;
  String? _error;

  /// 'item' | 'shop'
  String _mode = 'item';
  String? _selTable;
  String? _selId;
  String _search = '';
  String _typeFilter = '';
  String _tab = 'basic';

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
  String get guardSubject => '物品与商店数据';

  Future<void> _loadAll() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await Future.wait([
        ApiClient.instance.get('/api/cfg/$_itemCfg'),
        ApiClient.instance.get('/api/cfg/$_bookCfg'),
        ApiClient.instance.get('/api/cfg/$_shopCfg'),
        ApiClient.instance.get('/api/cfg/ItemTypeCfg'),
        ApiClient.instance.get('/api/cfg/ItemTagCfg'),
        ApiClient.instance.get('/api/cfg/BookThemeCfg'),
      ]);
      if (!mounted) return;
      final item = _dataOf(res[0]);
      final book = _dataOf(res[1]);
      final shop = _dataOf(res[2]);
      _types = _dataOf(res[3]);
      _tags = _dataOf(res[4]);
      _bookThemes = _dataOf(res[5]);
      _tables
        ..clear()
        ..[_itemCfg] = _TableBuf(_itemCfg, item, jsonEncode(item), _mtimeOf(res[0]))
        ..[_bookCfg] = _TableBuf(_bookCfg, book, jsonEncode(book), _mtimeOf(res[1]))
        ..[_shopCfg] = _TableBuf(_shopCfg, shop, jsonEncode(shop), _mtimeOf(res[2]));
      _ensureSelection();
      setState(() => _loading = false);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  void _ensureSelection() {
    final entries = _entries;
    if (_selTable != null &&
        _selId != null &&
        _entryExists(_selTable!, _selId!)) {
      return;
    }
    if (entries.isNotEmpty) {
      _selTable = entries.first.table;
      _selId = entries.first.id;
    } else {
      _selTable = null;
      _selId = null;
    }
  }

  bool _entryExists(String table, String id) {
    if (table == _shopCfg) return _mode == 'shop' && _tableData(table).containsKey(id);
    if (_mode != 'item') return false;
    return _tableData(table).containsKey(id);
  }

  Map<String, dynamic> _tableData(String t) =>
      _tables[t]?.data ?? <String, dynamic>{};

  bool _tableDirty(String t) => _tables[t]?.dirty ?? false;

  bool get _dirty =>
      _tableDirty(_itemCfg) ||
      _tableDirty(_bookCfg) ||
      _tableDirty(_shopCfg);

  Future<void> _saveAll() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      for (final name in const [_itemCfg, _bookCfg, _shopCfg]) {
        final buf = _tables[name]!;
        if (!buf.dirty) continue;
        final ok = await _saveTable(buf);
        if (!ok || !mounted) return;
      }
      if (mounted) {
        _info('物品仓库已保存', fluent.InfoBarSeverity.success);
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
  // 行访问
  // ------------------------------------------------------------------

  Map<String, dynamic>? _rowIn(String table, String id) {
    final v = _tableData(table)[id];
    return v is Map ? v.cast<String, dynamic>() : null;
  }

  Map<String, dynamic>? _lookupAny(String id) =>
      _rowIn(_itemCfg, id) ?? _rowIn(_bookCfg, id);

  Map<String, dynamic>? get _row =>
      (_selTable == null || _selId == null) ? null : _rowIn(_selTable!, _selId!);

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

  num _numOf(Map<String, dynamic>? row, String field, [num fallback = 0]) {
    final v = row?[field];
    if (v is num) return v;
    return num.tryParse(v?.toString() ?? '') ?? fallback;
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

  int _nextId(String table) {
    var max = 0;
    for (final k in _tableData(table).keys) {
      final v = int.tryParse(k);
      if (v != null && v > max) max = v;
    }
    return max + 1;
  }

  String _typeName(int id) {
    if (id == 3) return '书籍';
    final v = _types[id.toString()];
    if (v is Map) {
      final n = v['name']?.toString().trim() ?? '';
      if (n.isNotEmpty) return n;
    }
    if (id == 3001) return '故事书';
    if (id == 3002) return '知识书';
    return id == 0 ? '未分类' : '类型 $id';
  }

  String _tagName(int id) {
    final v = _tags[id.toString()];
    if (v is Map) {
      final n = v['name']?.toString().trim() ?? '';
      if (n.isNotEmpty) return n;
    }
    return '标签 $id';
  }

  String _themeName(int id) {
    final v = _bookThemes[id.toString()];
    if (v is Map) {
      final n = v['name']?.toString().trim() ?? '';
      if (n.isNotEmpty) return n;
    }
    return '主题 $id';
  }

  String _entryName(_WhEntry e) {
    final n = e.visual['name']?.toString().trim() ?? '';
    return n.isEmpty ? '未命名物品' : n;
  }

  int _effectiveType(_WhEntry e) {
    if (e.table == _bookCfg) return 3;
    if (e.table == _shopCfg) {
      final t = _intOf(e.row, 'type');
      if (t != 0) return t == 3 ? 3 : t;
      final p = _lookupAny(e.id);
      return p == null ? 0 : (_rowIn(_bookCfg, e.id) != null ? 3 : _intOf(p, 'type'));
    }
    return _intOf(e.row, 'type');
  }

  // ------------------------------------------------------------------
  // 列表
  // ------------------------------------------------------------------

  List<_WhEntry> get _allEntries {
    final out = <_WhEntry>[];
    if (_mode == 'shop') {
      for (final id in _sortedIds(_shopCfg)) {
        final row = _rowIn(_shopCfg, id)!;
        out.add(_WhEntry(_shopCfg, id, row, _lookupAny(id) ?? row));
      }
    } else {
      for (final t in const [_itemCfg, _bookCfg]) {
        for (final id in _sortedIds(t)) {
          final row = _rowIn(t, id)!;
          out.add(_WhEntry(t, id, row, row));
        }
      }
    }
    out.sort((a, b) {
      final c = (int.tryParse(a.id) ?? 0).compareTo(int.tryParse(b.id) ?? 0);
      return c != 0 ? c : a.table.compareTo(b.table);
    });
    return out;
  }

  List<_WhEntry> get _entries {
    final q = _search.trim().toLowerCase();
    return _allEntries.where((e) {
      if (_typeFilter.isNotEmpty &&
          _effectiveType(e).toString() != _typeFilter) {
        return false;
      }
      if (q.isEmpty) return true;
      final name = _entryName(e).toLowerCase();
      final desc = e.visual['desc']?.toString().toLowerCase() ?? '';
      return e.id.contains(q) || name.contains(q) || desc.contains(q);
    }).toList();
  }

  List<String> _typeFilterOptions() {
    final ids = <int>{3};
    for (final k in _types.keys) {
      final v = int.tryParse(k);
      if (v != null && v > 0) ids.add(v);
    }
    final list = ids.toList()..sort();
    return list.map((e) => e.toString()).toList();
  }

  // ------------------------------------------------------------------
  // 编辑操作
  // ------------------------------------------------------------------

  void _select(_WhEntry e) {
    setState(() {
      _selTable = e.table;
      _selId = e.id;
      _tab = 'basic';
    });
  }

  void _setMode(String mode) {
    setState(() {
      _mode = mode;
      _typeFilter = '';
      _tab = 'basic';
      _ensureSelection();
    });
  }

  Future<void> _addNew() async {
    if (_mode == 'shop') {
      await _addShop();
    } else {
      await _addItem();
    }
  }

  Future<void> _addItem() async {
    final book = await fluent.showDialog<bool>(
      context: context,
      builder: (ctx) => AppContentDialog(
        title: const Text('新建物品'),
        content: Text('选择要创建的物品类别。书籍使用 BookCfg，普通物品使用 ItemCfg。',
            style: TextStyle(
                fontSize: 12.5, color: palette.textPrimary, height: 1.5)),
        actions: [
          fluent.Button(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('普通物品'),
          ),
          fluent.FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('书籍'),
          ),
        ],
      ),
    );
    if (book == null || !mounted) return;
    setState(() {
      if (book) {
        final id = _nextId(_bookCfg);
        _tableData(_bookCfg)[id.toString()] = <String, dynamic>{
          'id': id,
          'name': '',
          'type': 3001,
          'icon': '',
          'itemTag': <dynamic>[],
          'capacity': 0,
          'effect': <dynamic>[],
          'value': -1,
          'sell': -1,
          'desc': '',
          'themes': <dynamic>[],
          'need': <dynamic>[],
          'precondition': <dynamic>[],
          'talk': '',
          'usingEffect': <dynamic>[],
        };
        _selTable = _bookCfg;
        _selId = id.toString();
      } else {
        final id = _nextId(_itemCfg);
        _tableData(_itemCfg)[id.toString()] = <String, dynamic>{
          'id': id,
          'name': '',
          'icon': '',
          'type': _firstItemType(),
          'itemTag': <dynamic>[],
          'effect': <dynamic>[],
          'usingEffect': <dynamic>[],
          'value': -1,
          'sell': -1,
          'desc': '',
          'talkId': 0,
          'maxcount': 1,
          'btn': '',
          'clothType': 0,
          'needDLC': 0,
          'precondition': <dynamic>[],
          'rarity': 0,
          'sex': 0,
          'subType': 0,
        };
        _selTable = _itemCfg;
        _selId = id.toString();
      }
      _tab = 'basic';
    });
  }

  int _firstItemType() {
    final ids = _types.keys
        .map(int.tryParse)
        .whereType<int>()
        .where((e) => e > 0 && e < 3000)
        .toList()
      ..sort();
    return ids.isNotEmpty ? ids.first : 1;
  }

  Future<void> _addShop() async {
    final taken = _tableData(_shopCfg).keys.toSet();
    final candidates = <_WhEntry>[
      for (final e in _allEntries)
        if (e.table != _shopCfg && !taken.contains(e.id)) e,
    ];
    final picked = await _pickProduct('选择要上架的商品', candidates);
    if (picked == null || !mounted) return;
    final product = picked.visual;
    final isBook = picked.table == _bookCfg;
    setState(() {
      final id = int.tryParse(picked.id) ?? 0;
      _tableData(_shopCfg)[picked.id] = <String, dynamic>{
        'id': id,
        'group': 0,
        'price': isBook ? 0 : (_intOf(product, 'sell') < 0 ? 0 : _intOf(product, 'sell')),
        'next': 0,
        'time': 0,
        'discountRound': 0,
        'type': isBook ? 3 : _intOf(product, 'type'),
        'maxcount': 0,
        'precondition': <dynamic>[],
        'probability': 1,
        'buyTalk': '',
        'disappearTime': 0,
        'limcount': 0,
      };
      _selTable = _shopCfg;
      _selId = picked.id;
      _tab = 'basic';
    });
  }

  Future<_WhEntry?> _pickProduct(String title, List<_WhEntry> candidates) {
    var query = '';
    return fluent.showDialog<_WhEntry>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) {
          final list = candidates.where((e) {
            if (query.isEmpty) return true;
            return e.id.contains(query) ||
                _entryName(e).toLowerCase().contains(query);
          }).toList();
          return AppContentDialog(
            title: Text(title),
            content: SizedBox(
              width: 520,
              height: 460,
              child: Column(
                children: [
                  fluent.TextBox(
                    placeholder: '搜索物品名称或编号',
                    onChanged: (v) =>
                        setLocal(() => query = v.trim().toLowerCase()),
                  ),
                  const SizedBox(height: 10),
                  Expanded(
                    child: ListView.builder(
                      itemCount: list.length,
                      itemBuilder: (context, i) {
                        final e = list[i];
                        return MouseRegion(
                          cursor: SystemMouseCursors.click,
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () => Navigator.pop(ctx, e),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 7),
                              child: Row(
                                children: [
                                  _IconBox(icon: e.visual['icon']?.toString() ?? '', size: 34),
                                  const SizedBox(width: 10),
                                  SizedBox(
                                    width: 56,
                                    child: Text(e.id,
                                        style: TextStyle(
                                            fontSize: 10.5,
                                            color: palette.textHint)),
                                  ),
                                  Expanded(
                                    child: Text(_entryName(e),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                            fontSize: 12.5,
                                            color: palette.textPrimary)),
                                  ),
                                  Text(
                                    e.table == _bookCfg
                                        ? '书籍'
                                        : _typeName(_intOf(e.visual, 'type')),
                                    style: TextStyle(
                                        fontSize: 10.5, color: palette.textMuted),
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

  Future<void> _deleteSelected() async {
    final table = _selTable;
    final id = _selId;
    if (table == null || id == null) return;
    final row = _rowIn(table, id);
    final name = row?['name']?.toString().trim() ?? '';
    final shown =
        name.isNotEmpty ? name : (_lookupAny(id)?['name']?.toString() ?? id);
    final yes = await fluent.showDialog<bool>(
      context: context,
      builder: (ctx) => AppContentDialog(
        title: const Text('删除确认'),
        content: Text('确定删除「$shown」吗？保存前可以在「放弃修改」回滚。',
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
      _tableData(table).remove(id);
      _ensureSelection();
    });
  }

  Future<void> _changeId() async {
    final table = _selTable;
    final id = _selId;
    if (table == null || id == null) return;
    final row = _rowIn(table, id);
    if (row == null) return;
    final ctrl = TextEditingController(text: id);
    final next = await fluent.showDialog<int>(
      context: context,
      builder: (ctx) => AppContentDialog(
        title: const Text('修改编号'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('修改后不会自动更新其它表中对该编号的引用（如商店、事件等），请自行核对。',
                style: TextStyle(
                    fontSize: 11.5, color: palette.textMuted, height: 1.5)),
            const SizedBox(height: 10),
            fluent.TextBox(
              controller: ctrl,
              placeholder: '新编号（正整数）',
              onSubmitted: (v) {
                final n = int.tryParse(v.trim());
                if (n != null && n > 0) Navigator.pop(ctx, n);
              },
            ),
          ],
        ),
        actions: [
          fluent.Button(
            onPressed: () => Navigator.pop(ctx, null),
            child: const Text('取消'),
          ),
          fluent.FilledButton(
            onPressed: () {
              final n = int.tryParse(ctrl.text.trim());
              if (n == null || n <= 0) return;
              Navigator.pop(ctx, n);
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (next == null || !mounted) return;
    if (next.toString() == id) return;
    if (_tableData(table).containsKey(next.toString())) {
      _info('编号 $next 已被占用', fluent.InfoBarSeverity.warning);
      return;
    }
    setState(() {
      final data = _tableData(table);
      data.remove(id);
      row['id'] = next;
      data[next.toString()] = row;
      _selId = next.toString();
    });
  }

  // ------------------------------------------------------------------
  // 积木库 / 图片
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

  Future<void> _pickIcon(Map<String, dynamic> row) async {
    final cur = row['icon']?.toString() ?? '';
    final picked = await showImageAssetPicker(
      context,
      title: '选择物品图片',
      initialSelected: cur.isEmpty ? const [] : <String>[cur],
    );
    if (picked == null || picked.isEmpty || !mounted) return;
    setState(() => row['icon'] = picked.first);
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
              Text('物品仓库加载失败',
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
                Row(
                  children: [
                    _SegButton(
                      label: '物品',
                      selected: _mode == 'item',
                      onTap: () => _setMode('item'),
                    ),
                    const SizedBox(width: 6),
                    _SegButton(
                      label: '商店',
                      selected: _mode == 'shop',
                      onTap: () => _setMode('shop'),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                fluent.TextBox(
                  controller: _searchCtrl,
                  placeholder: _mode == 'shop' ? '搜索商品名称或编号' : '搜索物品名称、编号或说明',
                  onChanged: (v) => setState(() => _search = v),
                ),
                const SizedBox(height: 8),
                _DropdownStr(
                  value: _typeFilter,
                  hint: '全部类型',
                  options: {
                    '': '全部类型',
                    for (final id in _typeFilterOptions())
                      id: _typeName(int.tryParse(id) ?? 0),
                  },
                  onChanged: (v) => setState(() => _typeFilter = v),
                ),
                const SizedBox(height: 10),
                fluent.FilledButton(
                  onPressed: _addNew,
                  child: Text(
                    _mode == 'shop' ? '＋ 上架商品' : '＋ 新建物品',
                    style: const TextStyle(fontSize: 12.5),
                  ),
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Expanded(
                      child: _MiniBtn(
                        label: '删除',
                        danger: true,
                        enabled: _selId != null,
                        onTap: _deleteSelected,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: _MiniBtn(
                        label: '改编号',
                        enabled: _selId != null,
                        onTap: _changeId,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          Divider(height: 1, color: palette.border),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 6),
            child: Text(
              '共 ${entries.length} 项',
              style: TextStyle(fontSize: 11, color: palette.textMuted),
            ),
          ),
          Expanded(
            child: entries.isEmpty
                ? Center(
                    child: Text(
                      _allEntries.isEmpty ? '还没有条目，点上方按钮新建。' : '没有匹配的条目。',
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

  Widget _entryTile(_WhEntry e) {
    final selected = e.table == _selTable && e.id == _selId;
    final subtitle = e.table == _shopCfg
        ? '¥ ${_intOf(e.row, 'price')}'
        : (e.table == _bookCfg ? '书籍 · ${_typeName(_intOf(e.row, 'type'))}' : _typeName(_intOf(e.row, 'type')));
    return _HoverTile(
      selected: selected,
      onTap: () => _select(e),
      child: Row(
        children: [
          _IconBox(icon: e.visual['icon']?.toString() ?? '', size: 38),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_entryName(e),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 12.5,
                        fontWeight:
                            selected ? FontWeight.w600 : FontWeight.normal,
                        color: selected
                            ? palette.textHigh
                            : palette.textPrimary)),
                const SizedBox(height: 3),
                Text(subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, color: palette.textMuted)),
              ],
            ),
          ),
          Text(e.id,
              style: TextStyle(fontSize: 10, color: palette.textHint)),
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
                  child: Text('选择或新建一个条目，中间编辑、右侧预览。',
                      style: TextStyle(fontSize: 13, color: palette.textHint)),
                )
              : SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(18, 16, 18, 24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _headerBar(),
                      const SizedBox(height: 14),
                      if (_tab == 'basic') ...[
                        _basicEditor(row),
                        const SizedBox(height: 14),
                        _advancedEditor(row),
                      ] else if (_tab == 'effect') ...[
                        _commandEditor(row),
                      ] else ...[
                        _tagsEditor(row),
                      ],
                    ],
                  ),
                ),
        ),
        _saveBar(),
      ],
    );
  }

  Widget _headerBar() {
    final tabs = _mode == 'shop'
        ? const [['basic', '商品信息'], ['effect', '条件']]
        : const [['basic', '物品信息'], ['effect', '效果指令'], ['tags', '标签']];
    final row = _row!;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
      decoration: BoxDecoration(
        color: palette.panel,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: palette.border),
      ),
      child: Row(
        children: [
          _IconBox(icon: row['icon']?.toString() ?? '', size: 34, onTap: () => _pickIcon(row)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _selTable == _shopCfg
                      ? (_lookupAny(_selId!) ?? row)['name']?.toString() ?? '未命名商品'
                      : (row['name']?.toString().trim().isNotEmpty == true
                          ? row['name'].toString()
                          : '未命名物品'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: palette.textHigh),
                ),
                const SizedBox(height: 2),
                Text(
                  '${_selTable == _bookCfg ? 'BookCfg' : _selTable} · #$_selId',
                  style: TextStyle(fontSize: 10.5, color: palette.textMuted),
                ),
              ],
            ),
          ),
          for (final t in tabs) ...[
            const SizedBox(width: 6),
            _SegButton(
              label: t[1],
              selected: _tab == t[0],
              onTap: () => setState(() => _tab = t[0]),
            ),
          ],
        ],
      ),
    );
  }

  // ---------- 基本信息 ----------

  Widget _basicEditor(Map<String, dynamic> row) {
    if (_selTable == _shopCfg) {
      final product = _lookupAny(_selId!) ?? row;
      return _SectionCard(
        title: '商品信息',
        children: [
          _labeled(
            '售卖物品',
            Row(
              children: [
                _IconBox(icon: product['icon']?.toString() ?? '', size: 32),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${product['name']?.toString() ?? '未命名物品'}（#${_selId ?? ''}）',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 12.5, color: palette.textPrimary),
                  ),
                ),
              ],
            ),
          ),
          _labeled('商品类型', _readOnly(_selTypeName(row))),
          _labeled('购买价格', _NumBox(
            value: _numOf(row, 'price'),
            hint: '0 表示免费',
            onChanged: (v) => setState(() => row['price'] = (v ?? 0).toInt()),
          )),
          _labeled('数量上限', _NumBox(
            value: _numOf(row, 'maxcount'),
            hint: '0 表示不限',
            onChanged: (v) => setState(() => row['maxcount'] = (v ?? 0).toInt()),
          )),
          _labeled('上架概率', _NumBox(
            value: _numOf(row, 'probability'),
            hint: '0 ~ 1',
            onChanged: (v) => setState(
                () => row['probability'] = (v ?? 0).toDouble().clamp(0, 1)),
          )),
          Row(
            children: [
              Expanded(
                child: _labeled('开始出售年份', _NumBox(
                  value: _numOf(row, 'time'),
                  onChanged: (v) => setState(() => row['time'] = (v ?? 0).toInt()),
                )),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _labeled('打折回合', _NumBox(
                  value: _numOf(row, 'discountRound'),
                  onChanged: (v) =>
                      setState(() => row['discountRound'] = (v ?? 0).toInt()),
                )),
              ),
            ],
          ),
          Row(
            children: [
              Expanded(
                child: _labeled('停止出售时间', _NumBox(
                  value: _numOf(row, 'disappearTime'),
                  onChanged: (v) =>
                      setState(() => row['disappearTime'] = (v ?? 0).toInt()),
                )),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _labeled('购买数量限制', _NumBox(
                  value: _numOf(row, 'limcount'),
                  onChanged: (v) =>
                      setState(() => row['limcount'] = (v ?? 0).toInt()),
                )),
              ),
            ],
          ),
          Row(
            children: [
              Expanded(
                child: _labeled('互斥商品组', _NumBox(
                  value: _numOf(row, 'group'),
                  hint: '0 不分组',
                  onChanged: (v) => setState(() => row['group'] = (v ?? 0).toInt()),
                )),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _labeled('售完替换商品', _NumBox(
                  value: _numOf(row, 'next'),
                  hint: '商品编号',
                  onChanged: (v) => setState(() => row['next'] = (v ?? 0).toInt()),
                )),
              ),
            ],
          ),
          _labeled('店员台词', _SyncedText(
            value: row['buyTalk']?.toString() ?? '',
            hint: '购买时的店员台词',
            maxLines: 3,
            onChanged: (v) => setState(() => row['buyTalk'] = v),
          )),
        ],
      );
    }

    if (_selTable == _bookCfg) {
      return _SectionCard(
        title: '书籍信息',
        children: [
          _labeled('名称', _SyncedText(
            value: row['name']?.toString() ?? '',
            hint: '书籍名称',
            onChanged: (v) => setState(() => row['name'] = v),
          )),
          _labeled('书籍类别', _DropdownInt(
            value: _intOf(row, 'type', 3001),
            options: {
              for (final e in _bookTypeOptions().entries) e.key: e.value,
            },
            onChanged: (v) => setState(() => row['type'] = v),
          )),
          _labeled('总页数', _NumBox(
            value: _numOf(row, 'capacity'),
            onChanged: (v) => setState(() => row['capacity'] = (v ?? 0).toInt()),
          )),
          Row(
            children: [
              Expanded(
                child: _labeled('赠送价值', _NumBox(
                  value: _numOf(row, 'value', -1),
                  hint: '−1 不可赠送',
                  onChanged: (v) => setState(() => row['value'] = (v ?? -1).toInt()),
                )),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _labeled('出售价格', _NumBox(
                  value: _numOf(row, 'sell', -1),
                  hint: '−1 不可出售',
                  onChanged: (v) => setState(() => row['sell'] = (v ?? -1).toInt()),
                )),
              ),
            ],
          ),
          _labeled('阅读提示文字', _SyncedText(
            value: row['talk']?.toString() ?? '',
            hint: '阅读提示文字',
            onChanged: (v) => setState(() => row['talk'] = v),
          )),
          _labeled('物品说明', _SyncedText(
            value: row['desc']?.toString() ?? '',
            hint: '物品说明',
            maxLines: 3,
            onChanged: (v) => setState(() => row['desc'] = v),
          )),
        ],
      );
    }

    return _SectionCard(
      title: '物品信息',
      children: [
        _labeled('名称', _SyncedText(
          value: row['name']?.toString() ?? '',
          hint: '物品名称',
          onChanged: (v) => setState(() => row['name'] = v),
        )),
        _labeled('类型', _DropdownInt(
          value: _intOf(row, 'type', _firstItemType()),
          options: _itemTypeOptions(),
          onChanged: (v) => setState(() => row['type'] = v),
        )),
        Row(
          children: [
            Expanded(
              child: _labeled('赠送价值', _NumBox(
                value: _numOf(row, 'value', -1),
                hint: '−1 不可赠送',
                onChanged: (v) => setState(() => row['value'] = (v ?? -1).toInt()),
              )),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _labeled('出售价格', _NumBox(
                value: _numOf(row, 'sell', -1),
                hint: '−1 不可出售',
                onChanged: (v) => setState(() => row['sell'] = (v ?? -1).toInt()),
              )),
            ),
          ],
        ),
        Row(
          children: [
            Expanded(
              child: _labeled('数量上限', _NumBox(
                value: _numOf(row, 'maxcount', 1),
                onChanged: (v) => setState(() => row['maxcount'] = (v ?? 0).toInt()),
              )),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _labeled('使用后对话', _NumBox(
                value: _numOf(row, 'talkId'),
                hint: 'TalkCfg 编号',
                onChanged: (v) => setState(() => row['talkId'] = (v ?? 0).toInt()),
              )),
            ),
          ],
        ),
        _labeled('物品说明', _SyncedText(
          value: row['desc']?.toString() ?? '',
          hint: '物品说明',
          maxLines: 3,
          onChanged: (v) => setState(() => row['desc'] = v),
        )),
      ],
    );
  }

  String _selTypeName(Map<String, dynamic> row) {
    final t = _intOf(row, 'type');
    if (t == 3 || _rowIn(_bookCfg, _selId ?? '') != null) return '书籍';
    return _typeName(t);
  }

  Map<int, String> _itemTypeOptions() {
    final ids = _types.keys
        .map(int.tryParse)
        .whereType<int>()
        .where((e) => e > 0 && e < 3000)
        .toList()
      ..sort();
    return {for (final id in ids) id: _typeName(id)};
  }

  Map<int, String> _bookTypeOptions() {
    final ids = _types.keys
        .map(int.tryParse)
        .whereType<int>()
        .where((e) => e >= 3000)
        .toList()
      ..sort();
    final map = {for (final id in ids) id: _typeName(id)};
    map.putIfAbsent(3001, () => _typeName(3001));
    map.putIfAbsent(3002, () => _typeName(3002));
    return map;
  }

  // ---------- 高级选项 ----------

  Widget _advancedEditor(Map<String, dynamic> row) {
    if (_selTable == _shopCfg) return const SizedBox.shrink();
    final isBook = _selTable == _bookCfg;
    return _Collapsible(
      title: '高级扩展选项',
      children: isBook
          ? [
              _labeled('阅读要求参数（逗号分隔）', _ListNumField(
                value: _intList(row, 'need'),
                hint: '例如 1,2,3',
                onChanged: (v) => setState(() => row['need'] = v),
              )),
              _labeled(
                '书籍主题',
                _ChipMultiSelect(
                  options: {
                    for (final k in _bookThemes.keys)
                      if (int.tryParse(k) != null)
                        int.parse(k): _themeName(int.parse(k)),
                  },
                  selected: _intList(row, 'themes').toSet(),
                  onToggle: (id) => setState(() {
                    final set = _intList(row, 'themes').toSet();
                    if (!set.remove(id)) set.add(id);
                    row['themes'] = set.toList()..sort();
                  }),
                ),
              ),
            ]
          : [
              _labeled(
                '稀有度',
                _NumBox(
                  value: _numOf(row, 'rarity'),
                  onChanged: (v) =>
                      setState(() => row['rarity'] = (v ?? 0).toInt()),
                ),
              ),
              _labeled(
                '适用性别',
                Row(
                  children: [
                    _SegButton(
                      label: '不限',
                      selected: _intOf(row, 'sex') == 0,
                      onTap: () => setState(() => row['sex'] = 0),
                    ),
                    const SizedBox(width: 6),
                    _SegButton(
                      label: '男',
                      selected: _intOf(row, 'sex') == 1,
                      onTap: () => setState(() => row['sex'] = 1),
                    ),
                    const SizedBox(width: 6),
                    _SegButton(
                      label: '女',
                      selected: _intOf(row, 'sex') == 2,
                      onTap: () => setState(() => row['sex'] = 2),
                    ),
                  ],
                ),
              ),
              Row(
                children: [
                  Expanded(
                    child: _labeled('细分类别', _NumBox(
                      value: _numOf(row, 'subType'),
                      onChanged: (v) =>
                          setState(() => row['subType'] = (v ?? 0).toInt()),
                    )),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _labeled('服装类别', _NumBox(
                      value: _numOf(row, 'clothType'),
                      onChanged: (v) =>
                          setState(() => row['clothType'] = (v ?? 0).toInt()),
                    )),
                  ),
                ],
              ),
              Row(
                children: [
                  Expanded(
                    child: _labeled('所需扩展内容编号', _NumBox(
                      value: _numOf(row, 'needDLC'),
                      onChanged: (v) =>
                          setState(() => row['needDLC'] = (v ?? 0).toInt()),
                    )),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _labeled('使用按钮文字', _SyncedText(
                      value: row['btn']?.toString() ?? '',
                      hint: '例如 使用',
                      onChanged: (v) => setState(() => row['btn'] = v),
                    )),
                  ),
                ],
              ),
            ],
    );
  }

  // ---------- 效果指令 ----------

  Widget _commandEditor(Map<String, dynamic> row) {
    final isShop = _selTable == _shopCfg;
    return _SectionCard(
      title: isShop ? '上架条件' : '效果指令',
      subtitle: '点击「打开积木库」用可视化积木搭建，和字段内编辑结果一致。',
      children: [
        if (!isShop) ...[
          _blockField(row, 'effect', 'effect', '积木库 · 获得 / 阅读效果'),
          _blockField(row, 'usingEffect', 'effect', '积木库 · 使用效果'),
        ],
        _blockField(row, 'precondition', 'condition', '积木库 · 使用条件'),
      ],
    );
  }

  Widget _blockField(
      Map<String, dynamic> row, String field, String mode, String title) {
    final count = (row[field] is List) ? (row[field] as List).length : 0;
    final label = field == 'effect'
        ? '获得 / 阅读效果'
        : field == 'usingEffect'
            ? '使用效果'
            : '使用条件';
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

  // ---------- 标签 ----------

  Widget _tagsEditor(Map<String, dynamic> row) {
    final selected = _intList(row, 'itemTag').toSet();
    final options = <int, String>{
      for (final k in _tags.keys)
        if (int.tryParse(k) != null && int.parse(k) >= 0 && int.parse(k) < 100)
          int.parse(k): _tagName(int.parse(k)),
    };
    return _SectionCard(
      title: '物品标签',
      subtitle: '标签用于任务目标、礼物喜好等条件；编号小于 100 的才算物品标签。',
      children: [
        _ChipMultiSelect(
          options: options,
          selected: selected,
          allowFreeInput: true,
          freeHint: '输入标签编号后回车添加',
          onToggle: (id) => setState(() {
            final set = _intList(row, 'itemTag').toSet();
            if (!set.remove(id)) set.add(id);
            row['itemTag'] = set.toList()..sort();
          }),
          onAddFree: (id) => setState(() {
            final set = _intList(row, 'itemTag').toSet()..add(id);
            row['itemTag'] = set.toList()..sort();
          }),
        ),
      ],
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
    final row = _row;
    return Container(
      width: w,
      color: palette.panel,
      child: row == null
          ? Center(
              child: Text('选择条目查看预览。',
                  style: TextStyle(fontSize: 12, color: palette.textHint)),
            )
          : SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _SectionCard(
                    title: '游戏内预览',
                    children: [_previewCard(row)],
                  ),
                  _statsCard(row),
                ],
              ),
            ),
    );
  }

  Widget _previewCard(Map<String, dynamic> row) {
    final isShop = _selTable == _shopCfg;
    final visual = isShop ? (_lookupAny(_selId!) ?? row) : row;
    final name = visual['name']?.toString().trim() ?? '';
    final icon = visual['icon']?.toString() ?? '';
    final tags = _intList(visual, 'itemTag');
    final isBook = _selTable == _bookCfg || _rowIn(_bookCfg, _selId ?? '') != null;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: palette.bgAlt,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: palette.border),
      ),
      child: Column(
        children: [
          _IconBox(icon: icon, size: 84),
          const SizedBox(height: 10),
          Text(name.isEmpty ? '未命名物品' : name,
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                  color: palette.textHigh)),
          const SizedBox(height: 4),
          Text(
            isBook
                ? '书籍 · ${_typeName(isShop ? 3 : _intOf(row, 'type'))}'
                : _typeName(isShop ? _effectiveType(_WhEntry(_selTable!, _selId!, row, visual)) : _intOf(row, 'type')),
            style: TextStyle(fontSize: 11, color: palette.textMuted),
          ),
          const SizedBox(height: 8),
          if (tags.isNotEmpty)
            Wrap(
              spacing: 6,
              runSpacing: 6,
              alignment: WrapAlignment.center,
              children: [
                for (final id in tags)
                  _Tag(text: _tagName(id), color: palette.statusInfo),
              ],
            ),
        ],
      ),
    );
  }

  Widget _statsCard(Map<String, dynamic> row) {
    final isShop = _selTable == _shopCfg;
    final visual = isShop ? (_lookupAny(_selId!) ?? row) : row;
    return _SectionCard(
      title: '统计与引用',
      children: [
        if (isShop) ...[
          _kv('购买价格', '¥ ${_intOf(row, 'price')}'),
          _kv('上架概率', '${_numOf(row, 'probability')}'),
          _kv('数量上限', '${_intOf(row, 'maxcount') == 0 ? '不限' : _intOf(row, 'maxcount')}'),
          _kv('上架条件', '${(row['precondition'] is List) ? (row['precondition'] as List).length : 0} 条'),
        ] else ...[
          _kv('赠送价值', '${_intOf(visual, 'value', -1) < 0 ? '不可赠送' : _intOf(visual, 'value')}'),
          _kv('出售价格', '${_intOf(visual, 'sell', -1) < 0 ? '不可出售' : _intOf(visual, 'sell')}'),
          if (_selTable == _bookCfg)
            _kv('总页数', '${_intOf(row, 'capacity')}')
          else
            _kv('数量上限', '${_intOf(row, 'maxcount')}'),
          _kv('获得效果', '${(row['effect'] is List) ? (row['effect'] as List).length : 0} 条'),
          _kv('使用效果', '${(row['usingEffect'] is List) ? (row['usingEffect'] as List).length : 0} 条'),
          _kv('使用条件', '${(row['precondition'] is List) ? (row['precondition'] as List).length : 0} 条'),
        ],
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
          Text(value,
              style: TextStyle(fontSize: 12, color: palette.textPrimary)),
        ],
      ),
    );
  }

  Widget _readOnly(String text) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: palette.bgAlt,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: palette.border),
      ),
      child: Text(text,
          style: TextStyle(fontSize: 12.5, color: palette.textSecondary)),
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

class _Collapsible extends StatefulWidget {
  const _Collapsible({required this.title, required this.children});
  final String title;
  final List<Widget> children;

  @override
  State<_Collapsible> createState() => _CollapsibleState();
}

class _CollapsibleState extends State<_Collapsible> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      decoration: BoxDecoration(
        color: palette.bgAlt,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: palette.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => setState(() => _open = !_open),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                child: Row(
                  children: [
                    Icon(
                      _open
                          ? FluentIcons.chevron_down_24_regular
                          : FluentIcons.chevron_right_24_regular,
                      size: 14,
                      color: palette.textMuted,
                    ),
                    const SizedBox(width: 6),
                    Text(widget.title,
                        style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                            color: palette.textSecondary)),
                  ],
                ),
              ),
            ),
          ),
          if (_open)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: widget.children,
              ),
            ),
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

class _IconBox extends StatelessWidget {
  const _IconBox({required this.icon, this.size = 40, this.onTap});

  final String icon;
  final double size;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final box = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: palette.bgDeep2,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: palette.border),
      ),
      clipBehavior: Clip.antiAlias,
      alignment: Alignment.center,
      child: icon.isEmpty
          ? Icon(FluentIcons.image_24_regular,
              size: size * 0.42, color: palette.iconDisabled)
          : TexThumb(
              keyName: icon,
              fit: BoxFit.contain,
              width: size,
              height: size,
            ),
    );
    if (onTap == null) return box;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(onTap: onTap, child: box),
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

class _ChipMultiSelect extends StatelessWidget {
  const _ChipMultiSelect({
    required this.options,
    required this.selected,
    required this.onToggle,
    this.allowFreeInput = false,
    this.freeHint,
    this.onAddFree,
  });

  final Map<int, String> options;
  final Set<int> selected;
  final ValueChanged<int> onToggle;
  final bool allowFreeInput;
  final String? freeHint;
  final ValueChanged<int>? onAddFree;

  @override
  Widget build(BuildContext context) {
    final entries = options.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final e in entries)
              _chip(e.value, selected.contains(e.key), () => onToggle(e.key)),
          ],
        ),
        if (allowFreeInput) ...[
          const SizedBox(height: 10),
          _FreeIdField(hint: freeHint, onAdd: onAddFree),
        ],
      ],
    );
  }

  Widget _chip(String label, bool on, VoidCallback onTap) {
    final color = on ? accentColor : palette.border;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
          decoration: BoxDecoration(
            color: on ? accentColor.withValues(alpha: 0.16) : palette.card,
            borderRadius: BorderRadius.circular(7),
            border: Border.all(color: color),
          ),
          child: Text(label,
              style: TextStyle(
                fontSize: 11.5,
                color: on ? palette.textHigh : palette.textSecondary,
              )),
        ),
      ),
    );
  }
}

class _FreeIdField extends StatefulWidget {
  const _FreeIdField({required this.onAdd, this.hint});
  final ValueChanged<int>? onAdd;
  final String? hint;

  @override
  State<_FreeIdField> createState() => _FreeIdFieldState();
}

class _FreeIdFieldState extends State<_FreeIdField> {
  final TextEditingController _c = TextEditingController();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _submit() {
    final v = int.tryParse(_c.text.trim());
    if (v != null && v >= 0) {
      widget.onAdd?.call(v);
      _c.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: fluent.TextBox(
            controller: _c,
            placeholder: widget.hint,
            onSubmitted: (_) => _submit(),
          ),
        ),
        const SizedBox(width: 8),
        fluent.Button(onPressed: _submit, child: const Text('添加')),
      ],
    );
  }
}

class _DropdownInt extends StatelessWidget {
  const _DropdownInt({
    required this.value,
    required this.options,
    required this.onChanged,
  });

  final int value;
  final Map<int, String> options;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final entries = options.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    final has = options.containsKey(value);
    return fluent.ComboBox<int>(
      value: has
          ? value
          : (entries.isNotEmpty ? entries.first.key : 0),
      isExpanded: true,
      items: [
        for (final e in entries)
          fluent.ComboBoxItem<int>(
            value: e.key,
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

class _DropdownStr extends StatelessWidget {
  const _DropdownStr({
    required this.value,
    required this.options,
    required this.onChanged,
    this.hint,
  });

  final String value;
  final Map<String, String> options;
  final ValueChanged<String> onChanged;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final entries = options.entries.toList();
    return fluent.ComboBox<String>(
      value: options.containsKey(value)
          ? value
          : (entries.isNotEmpty ? entries.first.key : ''),
      isExpanded: true,
      items: [
        for (final e in entries)
          fluent.ComboBoxItem<String>(
            value: e.key,
            child: Text(e.value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12)),
          ),
      ],
      onChanged: (v) {
        if (v != null) onChanged(v);
      },
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
      placeholder: widget.hint,
      onChanged: (v) =>
          widget.onChanged(v.trim().isEmpty ? null : num.tryParse(v.trim())),
    );
  }
}

class _ListNumField extends StatefulWidget {
  const _ListNumField({
    required this.value,
    required this.onChanged,
    this.hint,
  });

  final List<int> value;
  final ValueChanged<List<int>> onChanged;
  final String? hint;

  @override
  State<_ListNumField> createState() => _ListNumFieldState();
}

class _ListNumFieldState extends State<_ListNumField> {
  late final TextEditingController _c =
      TextEditingController(text: widget.value.join(', '));
  final FocusNode _focus = FocusNode();

  @override
  void didUpdateWidget(covariant _ListNumField old) {
    super.didUpdateWidget(old);
    if (!_focus.hasFocus && widget.value.join(', ') != _c.text) {
      _c.text = widget.value.join(', ');
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
      placeholder: widget.hint,
      onChanged: (v) {
        final text = v.replaceAll('，', ',');
        final parts = text
            .split(',')
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .toList();
        final nums = <int>[];
        for (final p in parts) {
          final n = int.tryParse(p);
          if (n == null) return; // 有非法项时暂不写回
          nums.add(n);
        }
        widget.onChanged(nums);
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
