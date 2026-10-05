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
import '../resources/image_asset_picker.dart'
    show TexThumb, showImageAssetPicker;

/// 人物工作台 —— 导演布局下人物的专属界面（区别于通用 Schema 页）。
///
/// 三栏：人物列表（搜索 / 新建 / 复制 / 删除）｜标签表单
/// （人物资料 / 成长与喜好 / 表情与服装 / 图片与大小）｜立绘预览。
///
/// 数据来自 `PersonCfg` / `PersonGrowCfg` / `ModFaceCfg` 三张表，整表读取、
/// 整表写回（带 `expect_mtime_ns` 乐观锁，409 弹冲突选择）。
class PersonWorkbench extends StatefulWidget {
  const PersonWorkbench({
    super.key,
    required this.state,
    this.onPreview,
    this.onOpenSearch,
  });

  final AppState state;
  final ValueChanged<String>? onPreview;
  final VoidCallback? onOpenSearch;

  @override
  State<PersonWorkbench> createState() => _PersonWorkbenchState();
}

/// 工作台标签页。
enum _PersonTab {
  profile('人物资料', FluentIcons.contact_card_24_regular),
  growth('成长与喜好', FluentIcons.data_trending_24_regular),
  faces('表情与服装', FluentIcons.emoji_24_regular),
  model('图片与大小', FluentIcons.resize_24_regular);

  const _PersonTab(this.label, this.icon);
  final String label;
  final IconData icon;
}

/// MBTI 四个维度（与原生 personalitys 的 8 个数值一一对应）。
const _mbtiPairs = <List<String>>[
  ['E', 'I', '外向', '内向'],
  ['N', 'S', '开放', '务实'],
  ['F', 'T', '感性', '理性'],
  ['P', 'J', '随性', '上进'],
];

class _PersonWorkbenchState extends State<PersonWorkbench>
    with WorkbenchLeaveGuard<PersonWorkbench> {
  static const _personCfg = 'PersonCfg';
  static const _growCfg = 'PersonGrowCfg';
  static const _faceCfg = 'ModFaceCfg';
  static const _pageSize = 50;

  // 三张表的当前数据（id → row）与加载时的快照 / mtime。
  Map<String, dynamic> _person = {};
  Map<String, dynamic> _grow = {};
  Map<String, dynamic> _face = {};
  String _personSnap = '';
  String _growSnap = '';
  String _faceSnap = '';
  int? _personM;
  int? _growM;
  int? _faceM;

  // 引用表（id → 显示名）与人物立绘目录（/api/roles）。
  Map<String, String> _attrNames = {};
  Map<String, String> _traitNames = {};
  Map<String, String> _stateNames = {};
  Map<String, String> _itemNames = {};
  Map<String, String> _tagNames = {};
  List<RoleEntry> _roles = const [];

  bool _loading = true;
  bool _saving = false;
  String? _error;

  String? _selectedId;
  _PersonTab _tab = _PersonTab.profile;
  String _search = '';
  int _page = 0;

  // 预览状态。
  int _grade = 0; // 0 小学 / 1 中学
  int _cloth = 0;
  int _previewFace = 0;

  // 成长页：选中年级（可多选）。
  Set<int> _growYears = {0};
  bool _growMulti = false;

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
  // 数据装载 / 保存
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
  String get guardSubject => '人物资料';

  Future<void> _loadAll() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await Future.wait([
        ApiClient.instance.get('/api/cfg/$_personCfg'),
        ApiClient.instance.get('/api/cfg/$_growCfg'),
        ApiClient.instance.get('/api/cfg/$_faceCfg'),
      ]);
      if (!mounted) return;
      _person = _dataOf(res[0]);
      _grow = _dataOf(res[1]);
      _face = _dataOf(res[2]);
      _personM = _mtimeOf(res[0]);
      _growM = _mtimeOf(res[1]);
      _faceM = _mtimeOf(res[2]);
      _personSnap = jsonEncode(_person);
      _growSnap = jsonEncode(_grow);
      _faceSnap = jsonEncode(_face);
      _selectedId ??= _sortedIds.isNotEmpty ? _sortedIds.first : null;
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
    if (_selectedId == null) return;
    final list = await loadRoles('');
    if (!mounted) return;
    setState(() => _roles = list);
  }

  Future<void> _loadRefs() async {
    try {
      final res = await Future.wait([
        ApiClient.instance.get('/api/cfg/PersonAttrCfg'),
        ApiClient.instance.get('/api/cfg/TraitsCfg'),
        ApiClient.instance.get('/api/cfg/PersonStateCfg'),
        ApiClient.instance.get('/api/cfg/ItemTagCfg'),
      ]);
      if (!mounted) return;
      setState(() {
        _attrNames = _nameMap(_dataOf(res[0]));
        _traitNames = _nameMap(_dataOf(res[1]));
        _stateNames = _nameMap(_dataOf(res[2]));
        _tagNames = _nameMap(_dataOf(res[3]));
      });
    } catch (_) {}
  }

  /// id → 显示名；`name` 可能是字符串，也可能是 1D 数组（首元素为名）。
  Map<String, String> _nameMap(Map<String, dynamic> data) {
    final out = <String, String>{};
    for (final e in data.entries) {
      final v = e.value;
      if (v is Map) {
        final raw = v['name'] ?? v['title'];
        String name = '';
        if (raw is List && raw.isNotEmpty) {
          name = raw.first.toString();
        } else if (raw != null) {
          name = raw.toString();
        }
        out[e.key] = name.isEmpty ? '条目 ${e.key}' : name;
      }
    }
    return out;
  }

  bool get _dirty =>
      _personSnap != jsonEncode(_person) ||
      _growSnap != jsonEncode(_grow) ||
      _faceSnap != jsonEncode(_face);

  Future<void> _saveAll() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await _saveOne(_personCfg, _person, _personSnap);
      await _saveOne(_growCfg, _grow, _growSnap);
      await _saveOne(_faceCfg, _face, _faceSnap);
      if (mounted) {
        _info('人物资料、成长、表情服装已一起保存', fluent.InfoBarSeverity.success);
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _saveOne(
    String name,
    Map<String, dynamic> data,
    String snap,
  ) async {
    if (jsonEncode(data) == snap) return;
    var force = false;
    for (;;) {
      try {
        final body = <String, dynamic>{
          'data': data,
          if (force) 'force': true,
        };
        if (!force) {
          if (name == _personCfg) body['expect_mtime_ns'] = _personM;
          if (name == _growCfg) body['expect_mtime_ns'] = _growM;
          if (name == _faceCfg) body['expect_mtime_ns'] = _faceM;
        }
        final r = await ApiClient.instance.put('/api/cfg/$name', body: body);
        final freshSnap = jsonEncode(data);
        if (!mounted) return;
        setState(() {
          if (name == _personCfg) {
            _personM = _mtimeOf(r);
            _personSnap = freshSnap;
          } else if (name == _growCfg) {
            _growM = _mtimeOf(r);
            _growSnap = freshSnap;
          } else {
            _faceM = _mtimeOf(r);
            _faceSnap = freshSnap;
          }
        });
        return;
      } on ApiException catch (e) {
        if (!mounted) return;
        if (e.statusCode == 409 && !force) {
          final act = await _conflictDialog(name);
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
  }

  void _discard() {
    setState(() {
      _person = (jsonDecode(_personSnap) as Map).cast<String, dynamic>();
      _grow = (jsonDecode(_growSnap) as Map).cast<String, dynamic>();
      _face = (jsonDecode(_faceSnap) as Map).cast<String, dynamic>();
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
  // 行访问与修改
  // ------------------------------------------------------------------

  Map<String, dynamic> _ensureRow(Map<String, dynamic> tbl, String id) {
    final v = tbl[id];
    if (v is Map) return v.cast<String, dynamic>();
    final m = <String, dynamic>{'id': int.tryParse(id) ?? id};
    tbl[id] = m;
    return m;
  }

  Map<String, dynamic>? _row(Map<String, dynamic> tbl, String id) {
    final v = tbl[id];
    return v is Map ? v.cast<String, dynamic>() : null;
  }

  int _pid(String id) => int.tryParse(id) ?? -1;

  List<String> get _sortedIds {
    final ids = _person.keys.toList();
    ids.sort((a, b) {
      final an = int.tryParse(a);
      final bn = int.tryParse(b);
      if (an != null && bn != null) return an.compareTo(bn);
      return a.compareTo(b);
    });
    return ids;
  }

  String _nameOf(String id) {
    final m = _row(_person, id);
    final n = m?['name']?.toString() ?? '';
    return n.isEmpty ? '未命名人物' : n;
  }

  int _allocId() {
    var max = 0;
    for (final id in _person.keys) {
      final v = int.tryParse(id);
      if (v != null && v > max) max = v;
    }
    return max == 0 ? 1 : max + 1;
  }

  void _newPerson({bool duplicate = false}) {
    final id = _allocId().toString();
    final base = duplicate ? _row(_person, _selectedId ?? '') : null;
    setState(() {
      final row = <String, dynamic>{
        'id': int.tryParse(id),
        'name': duplicate ? '${base?['name'] ?? '人物'} · 副本' : '未命名人物',
        'gender': 1,
      };
      if (base != null) {
        for (final e in base.entries) {
          row[e.key] = e.value;
        }
        row['id'] = int.tryParse(id);
        row['name'] = '${base['name'] ?? '人物'} · 副本';
      }
      _person[id] = row;
      _grow[id] = <String, dynamic>{
        'id': int.tryParse(id),
        'ItemPref': [
          for (var i = 1; i <= 11; i++) [i, 0],
        ],
      };
      if (duplicate && _selectedId != null) {
        final srcGrow = _row(_grow, _selectedId!);
        if (srcGrow != null) {
          _grow[id] = {...srcGrow, 'id': int.tryParse(id)};
        }
      }
      _selectedId = id;
      _previewFace = 0;
      _cloth = 0;
    });
  }

  Future<void> _removePerson() async {
    final id = _selectedId;
    if (id == null) return;
    final name = _nameOf(id);
    final ok = await confirmDelete(
      context,
      '确定删除人物「${name.isEmpty ? id : name}」吗？保存前可「放弃修改」回退。',
    );
    if (!ok || !mounted) return;
    setState(() {
      _person.remove(id);
      _grow.remove(id);
      final pid = _pid(id);
      _face.removeWhere((_, v) {
        final fid = (v is Map)
            ? ((v['id'] as num?)?.toInt() ?? -1)
            : (int.tryParse(_key(v)) ?? -1);
        return fid ~/ 1000 == pid;
      });
      _selectedId = _sortedIds.isNotEmpty ? _sortedIds.first : null;
      _previewFace = 0;
      _cloth = 0;
    });
  }

  String _key(dynamic v) => v is Map ? (v['id']?.toString() ?? '') : '';

  // ------------------------------------------------------------------
  // 预览 / 表情 / 服装
  // ------------------------------------------------------------------

  List<Map<String, dynamic>> _facesFor(int pid, int cloth) {
    final out = <Map<String, dynamic>>[];
    for (final e in _face.entries) {
      final v = e.value;
      if (v is! Map) continue;
      final m = v.cast<String, dynamic>();
      final fid = (m['id'] as num?)?.toInt() ?? int.tryParse(e.key) ?? -1;
      if (fid ~/ 1000 == pid && (fid % 1000) ~/ 100 == cloth) {
        out.add(m);
      }
    }
    out.sort((a, b) {
      final af = ((a['id'] as num?)?.toInt() ?? 0) % 100;
      final bf = ((b['id'] as num?)?.toInt() ?? 0) % 100;
      return af.compareTo(bf);
    });
    return out;
  }

  List<int> _clothSlots(int pid) {
    final slots = <int>{0};
    for (final e in _face.entries) {
      final v = e.value;
      if (v is! Map) continue;
      final fid = (v['id'] as num?)?.toInt() ?? int.tryParse(e.key) ?? -1;
      if (fid ~/ 1000 == pid) slots.add((fid % 1000) ~/ 100);
    }
    final list = slots.toList()..sort();
    return list;
  }

  String _previewKey() {
    final id = _selectedId;
    if (id == null) return '';
    final pid = _pid(id);
    final faces = _facesFor(pid, _cloth);
    if (faces.isNotEmpty) {
      Map<String, dynamic>? face;
      for (final f in faces) {
        if (((f['id'] as num?)?.toInt() ?? 0) % 100 == _previewFace) {
          face = f;
          break;
        }
      }
      face ??= faces.first;
      final primary = _grade == 1 ? 'icon' : 'icon_xx';
      final alt = _grade == 1 ? 'icon_xx' : 'icon';
      final k = face[primary] ?? face[alt];
      if (k is String && k.isNotEmpty) return k;
    }
    final row = _row(_person, id) ?? const <String, dynamic>{};
    final list = _grade == 1 ? row['url2'] : row['url'];
    if (list is List && list.isNotEmpty) {
      final s = list.first?.toString() ?? '';
      if (s.isNotEmpty) return s;
    }
    for (final r in _roles) {
      if (r.id == id) {
        final k = _grade == 1 ? r.portrait2 : r.portrait1;
        if (k.isNotEmpty) return k;
      }
    }
    return '';
  }

  Future<void> _pickPortrait(int grade) async {
    final id = _selectedId;
    if (id == null) return;
    final row = _ensureRow(_person, id);
    final cur = (grade == 1 ? row['url2'] : row['url']) as List?;
    final initial = (cur != null && cur.isNotEmpty)
        ? <String>[cur.first.toString()]
        : <String>[];
    final picked = await showImageAssetPicker(
      context,
      title: grade == 1 ? '选择中学立绘' : '选择小学立绘',
      initialSelected: initial,
    );
    if (picked == null || picked.isEmpty) return;
    setState(() {
      final arr = List<dynamic>.from(
          (grade == 1 ? row['url2'] : row['url']) as List? ?? []);
      if (arr.isEmpty) arr.add('');
      arr[0] = picked.first;
      row[grade == 1 ? 'url2' : 'url'] = arr;
    });
  }

  Future<void> _addFace() async {
    final id = _selectedId;
    if (id == null) return;
    final picked = await showImageAssetPicker(
      context,
      title: '选择立绘图片',
      initialSelected: const [],
    );
    if (picked == null || picked.isEmpty) return;
    final pid = _pid(id);
    final taken = _facesFor(pid, _cloth)
        .map((f) => ((f['id'] as num?)?.toInt() ?? 0) % 100)
        .toSet();
    var face = taken.contains(0)
        ? (List.generate(99, (i) => i + 1).firstWhere(
            (n) => !taken.contains(n),
            orElse: () => -1,
          ))
        : 0;
    if (face < 0) {
      _info('这套服装最多支持 100 张表情立绘', fluent.InfoBarSeverity.warning);
      return;
    }
    final fid = pid * 1000 + _cloth * 100 + face;
    setState(() {
      _face[fid.toString()] = <String, dynamic>{
        'id': fid,
        'name': face == 0 ? '默认' : '表情 $face',
        'icon': picked.first,
        'icon_xx': picked.first,
        'photobooth': '',
      };
      _previewFace = face;
    });
  }

  Future<void> _addOutfit() async {
    final id = _selectedId;
    if (id == null) return;
    final pid = _pid(id);
    final slots = _clothSlots(pid);
    final slot = List.generate(9, (i) => i + 1).firstWhere(
      (s) => !slots.contains(s),
      orElse: () => -1,
    );
    if (slot < 0) {
      _info('该角色已拥有九套附加服装', fluent.InfoBarSeverity.warning);
      return;
    }
    final picked = await showImageAssetPicker(
      context,
      title: '选择服装立绘',
      initialSelected: const [],
    );
    if (picked == null || picked.isEmpty) return;
    final fid = pid * 1000 + slot * 100;
    setState(() {
      _face[fid.toString()] = <String, dynamic>{
        'id': fid,
        'name': '默认',
        'icon': picked.first,
        'icon_xx': picked.first,
        'photobooth': '',
      };
      _cloth = slot;
      _previewFace = 0;
    });
  }

  void _deleteFace(int face) {
    final id = _selectedId;
    if (id == null || face == 0) return;
    final pid = _pid(id);
    final fid = pid * 1000 + _cloth * 100 + face;
    setState(() {
      _face.remove(fid.toString());
      _previewFace = 0;
    });
  }

  void _deleteOutfit() {
    final id = _selectedId;
    if (id == null || _cloth == 0) return;
    final pid = _pid(id);
    setState(() {
      _face.removeWhere((_, v) {
        final fid = (v is Map)
            ? ((v['id'] as num?)?.toInt() ?? -1)
            : (int.tryParse(_key(v)) ?? -1);
        return fid ~/ 1000 == pid && (fid % 1000) ~/ 100 == _cloth;
      });
      _cloth = 0;
      _previewFace = 0;
    });
  }

  // ------------------------------------------------------------------
  // 成长页数值辅助
  // ------------------------------------------------------------------

  List<int> _personalitys() {
    final id = _selectedId;
    if (id == null) return List.filled(8, 0);
    final g = _ensureRow(_grow, id);
    final v = g['personalitys'];
    final out = <int>[];
    if (v is List) {
      for (final e in v) {
        if (e is List) {
          for (final x in e) {
            out.add((x as num?)?.toInt() ?? 0);
          }
        } else {
          out.add((e as num?)?.toInt() ?? 0);
        }
      }
    }
    while (out.length < 8) {
      out.add(0);
    }
    return out;
  }

  void _setPersonalityPair(int pair, int which) {
    final id = _selectedId;
    if (id == null) return;
    final out = _personalitys();
    out[pair * 2] = which == 0 ? 10 : 0;
    out[pair * 2 + 1] = which == 1 ? 10 : 0;
    setState(() => _ensureRow(_grow, id)['personalitys'] = out);
  }

  List<int> _intList(Map<String, dynamic>? row, String field, int len) {
    final v = row?[field];
    final out = <int>[];
    if (v is List) {
      for (final e in v) {
        out.add((e as num?)?.toInt() ?? 0);
      }
    }
    while (out.length < len) {
      out.add(0);
    }
    return out;
  }

  void _setGrowValue(int col, num value) {
    final id = _selectedId;
    if (id == null) return;
    final g = _ensureRow(_grow, id);
    final rows = List<dynamic>.from((g['grow'] as List?) ?? []);
    final years = _growYears.isEmpty ? {0} : _growYears;
    for (final y in years) {
      while (rows.length <= y) {
        rows.add([0, 0, 0]);
      }
      final r = List<dynamic>.from((rows[y] as List?) ?? [0, 0, 0]);
      while (r.length < 3) {
        r.add(0);
      }
      r[col] = value;
      rows[y] = r;
    }
    setState(() => g['grow'] = rows);
  }

  List<int> _growRow() {
    final id = _selectedId;
    if (id == null) return [0, 0, 0];
    final g = _ensureRow(_grow, id);
    final rows = (g['grow'] as List?) ?? const [];
    final y = _growYears.isEmpty ? 0 : _growYears.reduce((a, b) => a < b ? a : b);
    if (y < rows.length && rows[y] is List) {
      final r = (rows[y] as List).map((e) => (e as num?)?.toInt() ?? 0).toList();
      while (r.length < 3) {
        r.add(0);
      }
      return r;
    }
    return [0, 0, 0];
  }

  void _setItemPref(int tag, int value) {
    final id = _selectedId;
    if (id == null) return;
    final g = _ensureRow(_grow, id);
    final rows = List<dynamic>.from((g['ItemPref'] as List?) ?? []);
    final out = <dynamic>[];
    var found = false;
    for (final row in rows) {
      if (row is List && row.isNotEmpty && (row[0] as num?)?.toInt() == tag) {
        out.add([tag, value]);
        found = true;
      } else {
        out.add(row);
      }
    }
    if (!found) out.add([tag, value]);
    out.sort((a, b) => (((a as List)[0] as num).toInt())
        .compareTo(((b as List)[0] as num).toInt()));
    setState(() => g['ItemPref'] = out);
  }

  int _itemPref(int tag) {
    final id = _selectedId;
    if (id == null) return 0;
    final rows = (_ensureRow(_grow, id)['ItemPref'] as List?) ?? const [];
    for (final row in rows) {
      if (row is List && row.isNotEmpty && (row[0] as num?)?.toInt() == tag) {
        return (row.length > 1 ? (row[1] as num?)?.toInt() : 0) ?? 0;
      }
    }
    return 0;
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
              Text('人物数据加载失败',
                  style: TextStyle(fontSize: 13, color: palette.textPrimary)),
              const SizedBox(height: 6),
              Text('$_error',
                  style: TextStyle(fontSize: 11, color: palette.textMuted)),
              const SizedBox(height: 12),
              fluent.Button(
                onPressed: _loadAll,
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }

    return WorkbenchScaffold(
      leftBuilder: (w) => _leftPanel(w),
      center: _center(),
      rightBuilder: (w) => _previewPanel(w),
      rightLabel: '立绘预览',
      rightIcon: FluentIcons.image_24_regular,
    );
  }

  // ---------- 左栏 ----------

  Widget _leftPanel(double w) {
    final ids = _sortedIds.where((id) {
      final q = _search.trim().toLowerCase();
      if (q.isEmpty) return true;
      return id.toLowerCase().contains(q) ||
          _nameOf(id).toLowerCase().contains(q);
    }).toList();
    final pages = (ids.length / _pageSize).ceil();
    final page = pages == 0
        ? 0
        : (_page >= pages ? pages - 1 : _page);
    final start = (page * _pageSize).clamp(0, ids.length);
    final end = (start + _pageSize).clamp(0, ids.length);
    final slice = ids.sublist(start, end);

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
                  placeholder: '搜索人物名称或编号',
                  onChanged: (v) => setState(() {
                    _search = v;
                    _page = 0;
                  }),
                ),
                const SizedBox(height: 10),
                fluent.FilledButton(
                  onPressed: () => _newPerson(),
                  child: const Text('＋ 添加角色',
                      style: TextStyle(fontSize: 12.5)),
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Expanded(
                      child: _MiniBtn(
                        label: '创建副本',
                        enabled: _selectedId != null,
                        onTap: () => _newPerson(duplicate: true),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: _MiniBtn(
                        label: '删除角色',
                        danger: true,
                        enabled: _selectedId != null,
                        onTap: _removePerson,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          Divider(height: 1, color: palette.border),
          Expanded(
            child: slice.isEmpty
                ? Center(
                    child: Text(
                      ids.isEmpty ? '尚未添加人物。' : '没有匹配的人物。',
                      style:
                          TextStyle(fontSize: 12, color: palette.textHint),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 8),
                    itemCount: slice.length,
                    itemBuilder: (context, i) => _PersonListItem(
                      id: slice[i],
                      name: _nameOf(slice[i]),
                      selected: slice[i] == _selectedId,
                      onTap: () => setState(() {
                        _selectedId = slice[i];
                        _previewFace = 0;
                        _cloth = 0;
                      }),
                    ),
                  ),
          ),
          if (pages > 1)
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: palette.border)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _MiniBtn(
                    label: '←',
                    enabled: page > 0,
                    onTap: () => setState(() => _page = page - 1),
                  ),
                  Text('${page + 1} / $pages',
                      style: TextStyle(
                          fontSize: 11.5, color: palette.textSecondary)),
                  _MiniBtn(
                    label: '→',
                    enabled: page < pages - 1,
                    onTap: () => setState(() => _page = page + 1),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  // ---------- 中栏 ----------

  Widget _center() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _tabBar(),
        Expanded(
          child: _selectedId == null
              ? Center(
                  child: Text(
                    '在左侧添加或选择角色。',
                    style: TextStyle(fontSize: 13, color: palette.textHint),
                  ),
                )
              : SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(22, 20, 22, 28),
                  child: _tabBody(),
                ),
        ),
        _saveBar(),
      ],
    );
  }

  Widget _tabBar() {
    return Container(
      decoration: BoxDecoration(
        color: palette.panel,
        border: Border(bottom: BorderSide(color: palette.border)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (final t in _PersonTab.values)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: _SegButton(
                  label: t.label,
                  icon: t.icon,
                  selected: _tab == t,
                  onTap: () => setState(() => _tab = t),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _tabBody() {
    switch (_tab) {
      case _PersonTab.profile:
        return _profileTab();
      case _PersonTab.growth:
        return _growthTab();
      case _PersonTab.faces:
        return _facesTab();
      case _PersonTab.model:
        return _modelTab();
    }
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
          Text(
            dirty ? '有未保存的修改' : '已与磁盘同步',
            style: TextStyle(fontSize: 11.5, color: palette.textSecondary),
          ),
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

  // ---------- 资料页 ----------

  Widget _profileTab() {
    final id = _selectedId!;
    final row = _ensureRow(_person, id);
    final gender = (row['gender'] as num?)?.toInt() ?? 1;
    final birthday = _intList(row, 'birthday', 3);
    final init = _intList(row, 'init', 1);
    final socialOn = [2, 3, 4].contains(init.isNotEmpty ? init[0] : 0);
    final nicknames = (row['nicknames'] as List?) ?? const [];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _recordTitle(id),
        _SectionCard(
          title: '基础资料',
          children: [
            _Labeled('姓名', _SyncedText(
              value: row['name']?.toString() ?? '',
              hint: '人物姓名',
              onChanged: (v) => setState(() => row['name'] = v),
            )),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: _Labeled(
                    '性别',
                    Row(
                      children: [
                        _SegButton(
                          label: '男',
                          selected: gender == 1,
                          onTap: () => setState(() => row['gender'] = 1),
                        ),
                        const SizedBox(width: 8),
                        _SegButton(
                          label: '女',
                          selected: gender == 2,
                          onTap: () => setState(() => row['gender'] = 2),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  flex: 2,
                  child: _Labeled(
                    '出生日期',
                    Row(
                      children: [
                        Expanded(
                          child: _NumBox(
                            value: birthday[0],
                            hint: '年',
                            onChanged: (v) => setState(() {
                              final l = _intList(row, 'birthday', 3);
                              l[0] = (v ?? 0).toInt();
                              row['birthday'] = l;
                            }),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: _NumBox(
                            value: birthday[1],
                            hint: '月',
                            onChanged: (v) => setState(() {
                              final l = _intList(row, 'birthday', 3);
                              l[1] = (v ?? 1).toInt();
                              row['birthday'] = l;
                            }),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: _NumBox(
                            value: birthday[2],
                            hint: '日',
                            onChanged: (v) => setState(() {
                              final l = _intList(row, 'birthday', 3);
                              l[2] = (v ?? 1).toInt();
                              row['birthday'] = l;
                            }),
                          ),
                        ),
                        const SizedBox(width: 6),
                        fluent.IconButton(
                          icon: const Icon(FluentIcons.calendar_24_regular,
                              size: 14),
                          onPressed: () async {
                            final picked = await showBirthdayPicker(
                              context,
                              year: birthday[0],
                              month: birthday[1],
                              day: birthday[2],
                            );
                            if (picked != null && mounted) {
                              setState(() => row['birthday'] = picked);
                            }
                          },
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            _Labeled('人物介绍', _SyncedText(
              value: row['introduction']?.toString() ?? '',
              hint: '人物介绍',
              maxLines: 4,
              onChanged: (v) => setState(() => row['introduction'] = v),
            )),
          ],
        ),
        _SectionCard(
          title: '立绘',
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: _portraitField(0)),
                const SizedBox(width: 14),
                Expanded(child: _portraitField(1)),
              ],
            ),
          ],
        ),
        _SectionCard(
          title: '联系方式与备注',
          children: [
            Row(
              children: [
                Expanded(
                  child: _Labeled('电话号码', _SyncedText(
                    value: row['telephone']?.toString() ?? '',
                    hint: '电话号码',
                    onChanged: (v) => setState(() => row['telephone'] = v),
                  )),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: _Labeled('普通昵称', _SyncedText(
                    value: nicknames.isNotEmpty
                        ? nicknames[0].toString()
                        : '',
                    hint: '普通昵称',
                    onChanged: (v) => setState(() {
                      final l = List<dynamic>.from(nicknames);
                      while (l.isEmpty) {
                        l.add('');
                      }
                      l[0] = v;
                      row['nicknames'] = l;
                    }),
                  )),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: _Labeled('恋爱昵称', _SyncedText(
                    value: nicknames.length > 1 ? nicknames[1].toString() : '',
                    hint: '恋爱昵称',
                    onChanged: (v) => setState(() {
                      final l = List<dynamic>.from(nicknames);
                      while (l.length < 2) {
                        l.add('');
                      }
                      l[1] = v;
                      row['nicknames'] = l;
                    }),
                  )),
                ),
              ],
            ),
            _Labeled('备注', _SyncedText(
              value: row['note']?.toString() ?? '',
              hint: '只给自己看，不影响游戏',
              maxLines: 3,
              onChanged: (v) => setState(() => row['note'] = v),
            )),
          ],
        ),
        _SectionCard(
          title: '社交与头像',
          children: [
            Row(
              children: [
                _SegButton(
                  label: '可社交',
                  selected: socialOn,
                  onTap: () => setState(() {
                    final l = _intList(row, 'init', 3);
                    l[0] = socialOn ? 1 : 2;
                    row['init'] = l;
                  }),
                ),
                const SizedBox(width: 12),
                Text(
                  socialOn ? '该角色可在游戏中出现并社交' : '初始不登场（需要事件/剧情安排登场）',
                  style:
                      TextStyle(fontSize: 11.5, color: palette.textMuted),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: _Labeled('企鹅头像编号', _NumBox(
                    value: (row['kzoneHeadId'] as num?)?.toInt() ?? 0,
                    hint: '引用 KZoneAvatarCfg',
                    onChanged: (v) => setState(
                        () => row['kzoneHeadId'] = (v ?? 0).toInt()),
                  )),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: _Labeled('点击音效编号', _NumBox(
                    value: (row['clickAudio'] as num?)?.toInt() ?? 0,
                    hint: '引用 AudioCfg',
                    onChanged: (v) => setState(
                        () => row['clickAudio'] = (v ?? 0).toInt()),
                  )),
                ),
              ],
            ),
          ],
        ),
      ],
    );
  }

  Widget _recordTitle(String id) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        children: [
          Icon(FluentIcons.person_24_regular, size: 18, color: accentColor),
          const SizedBox(width: 8),
          Text(
            _nameOf(id),
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w700,
              color: palette.textHigh,
            ),
          ),
          const SizedBox(width: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: palette.card,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: palette.border),
            ),
            child: Text('ID $id',
                style: TextStyle(fontSize: 11, color: palette.textHint)),
          ),
        ],
      ),
    );
  }

  Widget _portraitField(int grade) {
    final id = _selectedId!;
    final row = _ensureRow(_person, id);
    final list = (grade == 1 ? row['url2'] : row['url']) as List?;
    final key = (list != null && list.isNotEmpty)
        ? list.first?.toString() ?? ''
        : '';
    return _Labeled(
      grade == 1 ? '中学立绘' : '小学立绘',
      MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: () => _pickPortrait(grade),
          child: Container(
            height: 170,
            decoration: BoxDecoration(
              color: palette.bgAlt,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: palette.border),
            ),
            clipBehavior: Clip.antiAlias,
            child: key.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(FluentIcons.image_24_regular,
                            size: 22, color: palette.iconDisabled),
                        const SizedBox(height: 6),
                        Text('点击选择图片',
                            style: TextStyle(
                                fontSize: 11.5, color: palette.textHint)),
                      ],
                    ),
                  )
                : TexThumb(
                    keyName: key,
                    fit: BoxFit.contain,
                    width: double.infinity,
                    height: double.infinity,
                  ),
          ),
        ),
      ),
    );
  }

  // ---------- 成长页 ----------

  Widget _growthTab() {
    final id = _selectedId!;
    final g = _ensureRow(_grow, id);
    final attr = _intList(g, 'attr', 3);
    final growRow = _growRow();
    final pers = _personalitys();
    final code = [
      for (var i = 0; i < 4; i++) pers[i * 2] >= pers[i * 2 + 1]
          ? _mbtiPairs[i][0]
          : _mbtiPairs[i][1],
    ].join();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionCard(
          title: '初始属性',
          subtitle: '人物创建时的智力、情商、体魄。',
          children: [
            for (var i = 0; i < 3; i++)
              _SliderField(
                label: const ['智力', '情商', '体魄'][i],
                value: attr[i].toDouble(),
                max: 100,
                onChanged: (v) => setState(() {
                  final l = _intList(g, 'attr', 3);
                  l[i] = v;
                  g['attr'] = l;
                }),
              ),
          ],
        ),
        _SectionCard(
          title: '属性成长',
          subtitle: '可多选年级，调整只应用到选中的年级；不同年级的原有值分别保留。',
          children: [
            Row(
              children: [
                _SegButton(
                  label: '同时配置多个年级',
                  selected: _growMulti,
                  onTap: () => setState(() {
                    _growMulti = !_growMulti;
                    if (!_growMulti) {
                      _growYears = {_growYears.isEmpty ? 0 : _growYears.first};
                    }
                  }),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (var y = 0; y < 12; y++)
                  _SegButton(
                    label: '第 ${y + 1} 学年',
                    selected: _growYears.contains(y),
                    onTap: () => setState(() {
                      if (!_growMulti) {
                        _growYears = {y};
                      } else if (_growYears.contains(y)) {
                        if (_growYears.length > 1) {
                          _growYears = {..._growYears}..remove(y);
                        }
                      } else {
                        _growYears = {..._growYears, y};
                      }
                    }),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            for (var i = 0; i < 3; i++)
              _SliderField(
                label: const ['智力增长', '情商增长', '体魄增长'][i],
                value: growRow[i].toDouble(),
                max: 20,
                onChanged: (v) => _setGrowValue(i, v),
              ),
          ],
        ),
        _SectionCard(
          title: '性格（MBTI）',
          children: [
            Row(
              children: [
                Expanded(
                  child: _SyncedText(
                    value: code,
                    hint: '如 ENFJ',
                    onChanged: (v) {
                      final up = v.toUpperCase();
                      if (!RegExp(r'^[EI][NS][FT][PJ]$').hasMatch(up)) return;
                      for (var i = 0; i < 4; i++) {
                        final first = up[i] == _mbtiPairs[i][0];
                        _setPersonalityPair(i, first ? 0 : 1);
                      }
                    },
                  ),
                ),
                const SizedBox(width: 14),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: palette.card,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: palette.border),
                  ),
                  child: Text(
                    '$code  ${_mbtiName(code)}',
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: palette.goldText),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            for (var i = 0; i < 4; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    SizedBox(
                      width: 54,
                      child: Text('维度 ${i + 1}',
                          style: TextStyle(
                              fontSize: 11.5, color: palette.textMuted)),
                    ),
                    Expanded(
                      child: _SegButton(
                        label: '${_mbtiPairs[i][0]} · ${_mbtiPairs[i][2]}',
                        selected: pers[i * 2] >= pers[i * 2 + 1],
                        onTap: () => _setPersonalityPair(i, 0),
                        wide: true,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _SegButton(
                        label: '${_mbtiPairs[i][1]} · ${_mbtiPairs[i][3]}',
                        selected: pers[i * 2] < pers[i * 2 + 1],
                        onTap: () => _setPersonalityPair(i, 1),
                        wide: true,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
        _SectionCard(
          title: '礼物喜好',
          subtitle: '按物品类型设置喜好数值，数值越大越喜欢。',
          children: [
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (var tag = 1; tag <= 11; tag++)
                  SizedBox(
                    width: 210,
                    child: _GiftRow(
                      label: _tagNames[tag.toString()] ?? '物品类型 $tag',
                      value: _itemPref(tag),
                      onChanged: (v) => _setItemPref(tag, v),
                    ),
                  ),
              ],
            ),
          ],
        ),
        _SectionCard(
          title: '特质与状态',
          children: [
            Row(
              children: [
                Expanded(
                  child: _Labeled(
                    '重点属性',
                    _RefDropdown(
                      value: (g['focusAttrId'] as num?)?.toInt() ?? 0,
                      options: _attrNames,
                      onChanged: (v) =>
                          setState(() => g['focusAttrId'] = v),
                    ),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: _Labeled(
                    '人物特质',
                    _RefDropdown(
                      value: (g['trait'] as num?)?.toInt() ?? 0,
                      options: _traitNames,
                      onChanged: (v) => setState(() => g['trait'] = v),
                    ),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: _Labeled(
                    '人物特长',
                    _RefDropdown(
                      value: (g['speciality'] as num?)?.toInt() ?? 0,
                      options: _traitNames,
                      onChanged: (v) =>
                          setState(() => g['speciality'] = v),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            _ChipLine(
              title: '携带物品',
              empty: '未添加物品',
              ids: _intList(g, 'items', 0),
              names: _itemNames,
              onPick: _pickItems,
              onRemove: (i) => setState(() {
                final l = _intList(g, 'items', 0)..removeAt(i);
                g['items'] = l;
              }),
            ),
            const SizedBox(height: 8),
            _ChipLine(
              title: '初始状态',
              empty: '未添加状态',
              ids: _intList(g, 'state', 0),
              names: _stateNames,
              onPick: _pickStates,
              onRemove: (i) => setState(() {
                final l = _intList(g, 'state', 0)..removeAt(i);
                g['state'] = l;
              }),
            ),
          ],
        ),
        _SectionCard(
          title: '班级与排名',
          subtitle: '资料页展示的班级编号与学习水平，不是班级中的第几名。',
          children: [
            _Labeled(
              '所在班级',
              _intRowEditor(
                g,
                'className',
                4,
                const ['小学', '初中', '高中未分班', '高中分班后'],
              ),
            ),
            _Labeled(
              '考试排名',
              _intRowEditor(
                g,
                'examRank',
                4,
                const ['小学／高中未分班', '初中', '高中文科', '高中理科'],
              ),
            ),
            _Labeled(
              '学习排名',
              _intRowEditor(
                g,
                'studyRank',
                3,
                const ['小学', '初中', '高中'],
              ),
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                Expanded(
                  child: _Labeled('关联小游戏编号', _NumBox(
                    value: (g['minigame'] as num?)?.toInt() ?? 0,
                    hint: '引用 MinigameCfg，0 表示未关联',
                    onChanged: (v) =>
                        setState(() => g['minigame'] = (v ?? 0).toInt()),
                  )),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: _Labeled('排序', _NumBox(
                    value: (g['order'] as num?)?.toInt() ?? 0,
                    onChanged: (v) =>
                        setState(() => g['order'] = (v ?? 0).toInt()),
                  )),
                ),
              ],
            ),
          ],
        ),
      ],
    );
  }

  Widget _intRowEditor(
    Map<String, dynamic> row,
    String field,
    int len,
    List<String> labels,
  ) {
    final values = _intList(row, field, len);
    return Row(
      children: [
        for (var i = 0; i < len; i++) ...[
          Expanded(
            child: _NumBox(
              value: values[i],
              hint: labels[i],
              onChanged: (v) => setState(() {
                final l = _intList(row, field, len);
                l[i] = (v ?? 0).toInt();
                row[field] = l;
              }),
            ),
          ),
          if (i != len - 1) const SizedBox(width: 8),
        ],
      ],
    );
  }

  String _mbtiName(String code) {
    const map = {
      'ENFP': '竞选者', 'ENFJ': '主人公', 'ENTP': '辩论家', 'ENTJ': '指挥官',
      'ESFP': '表演者', 'ESFJ': '执政官', 'ESTP': '企业家', 'ESTJ': '总经理',
      'INFP': '调停者', 'INFJ': '提倡者', 'INTP': '逻辑学家', 'INTJ': '建筑师',
      'ISFP': '探险家', 'ISFJ': '守卫者', 'ISTP': '鉴赏家', 'ISTJ': '物流师',
    };
    return map[code] ?? '';
  }

  Future<void> _pickItems() async {
    if (_itemNames.isEmpty) {
      try {
        final r = await ApiClient.instance.get('/api/cfg/ItemCfg');
        _itemNames = _nameMap(_dataOf(r));
      } catch (_) {}
    }
    final id = _selectedId;
    if (id == null || !mounted) return;
    final cur = _intList(_ensureRow(_grow, id), 'items', 0);
    final result = await _pickMulti('从物品仓库选择', _itemNames, cur);
    if (result == null || !mounted) return;
    setState(() => _ensureRow(_grow, id)['items'] = result);
  }

  Future<void> _pickStates() async {
    final id = _selectedId;
    if (id == null) return;
    final cur = _intList(_ensureRow(_grow, id), 'state', 0);
    final result = await _pickMulti('选择初始状态', _stateNames, cur);
    if (result == null || !mounted) return;
    setState(() => _ensureRow(_grow, id)['state'] = result);
  }

  Future<List<int>?> _pickMulti(
    String title,
    Map<String, String> options,
    List<int> current,
  ) {
    final selected = current.toSet();
    var query = '';
    return fluent.showDialog<List<int>>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) {
          final entries = options.entries.where((e) {
            final q = query.trim().toLowerCase();
            if (q.isEmpty) return true;
            return e.key.contains(q) ||
                e.value.toLowerCase().contains(q);
          }).toList();
          return AppContentDialog(
            title: Text(title),
            content: SizedBox(
              width: 480,
              height: 420,
              child: Column(
                children: [
                  fluent.TextBox(
                    placeholder: '搜索名称或编号',
                    onChanged: (v) => setLocal(() => query = v),
                  ),
                  const SizedBox(height: 10),
                  Expanded(
                    child: entries.isEmpty
                        ? Center(
                            child: Text('没有可选项',
                                style: TextStyle(
                                    fontSize: 12, color: palette.textHint)),
                          )
                        : ListView.builder(
                            itemCount: entries.length,
                            itemBuilder: (context, i) {
                              final e = entries[i];
                              final d = int.tryParse(e.key);
                              final on = d != null && selected.contains(d);
                              return MouseRegion(
                                cursor: SystemMouseCursors.click,
                                child: GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onTap: () => setLocal(() {
                                    if (d == null) return;
                                    if (on) {
                                      selected.remove(d);
                                    } else {
                                      selected.add(d);
                                    }
                                  }),
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 8, vertical: 7),
                                    child: Row(
                                      children: [
                                        fluent.Checkbox(
                                          checked: on,
                                          onChanged: (_) => setLocal(() {
                                            if (d == null) return;
                                            if (on) {
                                              selected.remove(d);
                                            } else {
                                              selected.add(d);
                                            }
                                          }),
                                        ),
                                        const SizedBox(width: 8),
                                        Expanded(
                                          child: Text(
                                            e.value,
                                            style: TextStyle(
                                                fontSize: 12.5,
                                                color: palette.textPrimary),
                                          ),
                                        ),
                                        Text(e.key,
                                            style: TextStyle(
                                                fontSize: 10.5,
                                                color: palette.textHint)),
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
              fluent.FilledButton(
                onPressed: () => Navigator.pop(ctx, selected.toList()..sort()),
                child: const Text('确定'),
              ),
            ],
          );
        },
      ),
    );
  }

  // ---------- 表情与服装页 ----------

  Widget _facesTab() {
    final id = _selectedId!;
    final pid = _pid(id);
    final slots = _clothSlots(pid);
    final faces = _facesFor(pid, _cloth);
    final face = faces.cast<Map<String, dynamic>?>().firstWhere(
          (f) => (((f?['id'] as num?)?.toInt() ?? 0) % 100) == _previewFace,
          orElse: () => faces.isNotEmpty ? faces.first : null,
        );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionCard(
          title: '服装',
          subtitle: '游戏里在教学楼/操场互动穿「服装 2」，其他地点穿默认服装；这是原版规则，模组不能按人物单独指定。',
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final s in slots)
                  _SegButton(
                    label: s == 0 ? '默认服装' : '服装 $s',
                    selected: _cloth == s,
                    onTap: () => setState(() {
                      _cloth = s;
                      _previewFace = 0;
                    }),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                _MiniBtn(label: '＋ 加入该角色服装', onTap: _addOutfit),
                const SizedBox(width: 8),
                if (_cloth != 0)
                  _MiniBtn(
                    label: '删除这套服装',
                    danger: true,
                    onTap: _deleteOutfit,
                  ),
              ],
            ),
          ],
        ),
        _SectionCard(
          title: '这套服装的立绘图片',
          children: [
            faces.isEmpty
                ? Text(
                    '这套服装还没有立绘，先「添加立绘图片」。',
                    style: TextStyle(fontSize: 12, color: palette.textMuted),
                  )
                : Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      for (final f in faces)
                        _FaceCard(
                          face: f,
                          grade: _grade,
                          selected: (((f['id'] as num?)?.toInt() ?? 0) % 100) ==
                              _previewFace,
                          onTap: () => setState(() => _previewFace =
                              ((f['id'] as num?)?.toInt() ?? 0) % 100),
                          onDelete: (((f['id'] as num?)?.toInt() ?? 0) % 100) ==
                                  0
                              ? null
                              : () => _deleteFace(
                                  ((f['id'] as num?)?.toInt() ?? 0) % 100),
                        ),
                    ],
                  ),
            const SizedBox(height: 12),
            fluent.Button(
              onPressed: _addFace,
              child: const Text('＋ 添加立绘图片',
                  style: TextStyle(fontSize: 12.5)),
            ),
            if (face != null) ...[
              const SizedBox(height: 14),
              _Labeled(
                '这张立绘的表情名称',
                _SyncedText(
                  value: face['name']?.toString() ?? '',
                  hint: '默认 / 笑 / 生气…',
                  onChanged: (v) => setState(() => face['name'] = v),                ),
              ),
            ],
          ],
        ),
      ],
    );
  }

  // ---------- 图片与大小页 ----------

  Widget _modelTab() {
    final id = _selectedId!;
    final row = _ensureRow(_person, id);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionCard(
          title: '立绘排版参数',
          subtitle: '按 [偏移X, 偏移Y, 缩放] 调整静态立绘在对话框中的位置与大小。',
          children: [
            _labeledTriple('小学立绘 urlParm', row, 'urlParm'),
            _labeledTriple('中学立绘 urlParm2', row, 'urlParm2'),
          ],
        ),
        _SectionCard(
          title: '气泡高度',
          subtitle: '立绘上方名字气泡的垂直偏移（像素）。',
          children: [
            Row(
              children: [
                Expanded(
                  child: _Labeled('小学 bubbleParm', _NumBox(
                    value: _firstNum(row['bubbleParm']),
                    onChanged: (v) => setState(
                        () => row['bubbleParm'] = _asList(v, row['bubbleParm'])),
                  )),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: _Labeled('中学 bubbleParm2', _NumBox(
                    value: _firstNum(row['bubbleParm2']),
                    onChanged: (v) => setState(
                        () => row['bubbleParm2'] = _asList(v, row['bubbleParm2'])),
                  )),
                ),
              ],
            ),
          ],
        ),
        _SectionCard(
          title: 'Live2D 参数',
          subtitle: '每行 [X, Y, 缩放, 镜像(0/1)]，与 l2d / l2d2 模型一一对应。',
          children: [
            _Labeled('小学 l2d 模型名', _SyncedText(
              value: _joinList(row['l2d']),
              hint: '逗号分隔，留空则用静态立绘',
              onChanged: (v) => setState(() => row['l2d'] = _splitList(v)),
            )),
            _Labeled('中学 l2d2 模型名', _SyncedText(
              value: _joinList(row['l2d2']),
              hint: '逗号分隔',
              onChanged: (v) => setState(() => row['l2d2'] = _splitList(v)),
            )),
          ],
        ),
      ],
    );
  }

  Widget _labeledTriple(String label, Map<String, dynamic> row, String field) {
    final v = _intList(row, field, 3);
    return _Labeled(
      label,
      Row(
        children: [
          Expanded(
            child: _NumBox(
              value: v[0],
              hint: 'X',
              onChanged: (val) => setState(() {
                final l = _intList(row, field, 3);
                l[0] = (val ?? 0).toInt();
                row[field] = l;
              }),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _NumBox(
              value: v[1],
              hint: 'Y',
              onChanged: (val) => setState(() {
                final l = _intList(row, field, 3);
                l[1] = (val ?? 0).toInt();
                row[field] = l;
              }),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _NumBox(
              value: v[2],
              hint: '缩放',
              onChanged: (val) => setState(() {
                final l = _intList(row, field, 3);
                l[2] = (val ?? 1).toInt();
                row[field] = l;
              }),
            ),
          ),
        ],
      ),
    );
  }

  num _firstNum(dynamic v) {
    if (v is List && v.isNotEmpty && v.first is num) return v.first as num;
    if (v is num) return v;
    return 0;
  }

  dynamic _asList(num? v, dynamic old) {
    final base = (old is List) ? List<dynamic>.from(old) : <dynamic>[];
    if (base.isEmpty) base.add(0);
    base[0] = (v ?? 0).toInt();
    return base;
  }

  String _joinList(dynamic v) {
    if (v is List) return v.map((e) => e.toString()).join(', ');
    return v?.toString() ?? '';
  }

  List<String> _splitList(String s) {
    return s
        .split(RegExp(r'[,，]'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
  }

  // ---------- 右栏 ----------

  Widget _previewPanel(double w) {
    final id = _selectedId;
    if (id == null) return const SizedBox.shrink();
    final pid = _pid(id);
    final faces = _facesFor(pid, _cloth);
    final key = _previewKey();
    final slots = _clothSlots(pid);

    return Container(
      width: w,
      color: palette.panel,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Text('立绘预览',
                    style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: palette.textHigh)),
                const Spacer(),
                _SegButton(
                  label: '小学',
                  selected: _grade == 0,
                  onTap: () => setState(() => _grade = 0),
                ),
                const SizedBox(width: 6),
                _SegButton(
                  label: '中学',
                  selected: _grade == 1,
                  onTap: () => setState(() => _grade = 1),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Container(
              height: 340,
              decoration: BoxDecoration(
                color: palette.bgAlt,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: palette.border),
              ),
              clipBehavior: Clip.antiAlias,
              child: key.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(FluentIcons.person_24_regular,
                              size: 34, color: palette.iconDisabled),
                          const SizedBox(height: 8),
                          Text('暂无立绘',
                              style: TextStyle(
                                  fontSize: 12, color: palette.textHint)),
                        ],
                      ),
                    )
                  : TexThumb(
                      keyName: key,
                      fit: BoxFit.contain,
                      width: double.infinity,
                      height: double.infinity,
                    ),
            ),
            const SizedBox(height: 10),
            Text(
              _nameOf(id),
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: palette.textHigh),
            ),
            const SizedBox(height: 12),
            _Labeled(
              '表情',
              fluent.ComboBox<int>(
                value: _previewFace,
                isExpanded: true,
                items: [
                  const fluent.ComboBoxItem<int>(
                    value: 0,
                    child: Text('默认', style: TextStyle(fontSize: 12)),
                  ),
                  for (final f in faces)
                    if (((f['id'] as num?)?.toInt() ?? 0) % 100 != 0)
                      fluent.ComboBoxItem<int>(
                        value: ((f['id'] as num?)?.toInt() ?? 0) % 100,
                        child: Text(
                          f['name']?.toString() ?? '表情',
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                ],
                onChanged: (v) {
                  if (v != null) setState(() => _previewFace = v);
                },
              ),
            ),
            _Labeled(
              '服装',
              fluent.ComboBox<int>(
                value: _cloth,
                isExpanded: true,
                items: [
                  for (final s in slots)
                    fluent.ComboBoxItem<int>(
                      value: s,
                      child: Text(
                        s == 0 ? '默认服装' : '服装 $s',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                ],
                onChanged: (v) {
                  if (v != null) {
                    setState(() {
                      _cloth = v;
                      _previewFace = 0;
                    });
                  }
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ----------------------------------------------------------------------
// 通用小部件
// ----------------------------------------------------------------------

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
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
      decoration: BoxDecoration(
        color: palette.panel,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: palette.border),
      ),
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
          if (subtitle != null) ...[
            const SizedBox(height: 4),
            Text(
              subtitle!,
              style: TextStyle(
                  fontSize: 11.5, height: 1.6, color: palette.textMuted),
            ),
          ],
          const SizedBox(height: 14),
          for (final c in children) ...[
            c,
            const SizedBox(height: 14),
          ],
        ],
      ),
    );
  }
}

/// 「选择生日」日历弹窗（对标成熟方案的生日选择）：年份步进 + 月份下拉 +
/// 日网格 + 「不设置生日」。返回 `[年, 月, 日]`；取消返回 null；
/// 「不设置生日」返回 `[0, 0, 0]`。
Future<List<int>?> showBirthdayPicker(
  BuildContext context, {
  int year = 1995,
  int month = 1,
  int day = 1,
}) async {
  var y = year <= 0 ? 1995 : year;
  var m = (month >= 1 && month <= 12) ? month : 1;
  var d = day >= 1 ? day : 1;
  final yearCtrl = TextEditingController(text: '$y');
  final result = await showDialog<List<int>>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setLocal) {
        final daysInMonth = DateTime(y, m + 1, 0).day;
        if (d > daysInMonth) d = daysInMonth;
        final firstWeekday = DateTime(y, m, 1).weekday % 7; // 周日 = 0
        final cells = <int?>[
          for (var i = 0; i < firstWeekday; i++) null,
          for (var i = 1; i <= daysInMonth; i++) i,
        ];
        return AppContentDialog(
          title: const Text('选择生日'),
          content: SizedBox(
            width: 340,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    fluent.IconButton(
                      icon: const Icon(FluentIcons.chevron_left_24_regular,
                          size: 14),
                      onPressed: () => setLocal(() {
                        y -= 1;
                        yearCtrl.text = '$y';
                      }),
                    ),
                    SizedBox(
                      width: 76,
                      child: fluent.TextBox(
                        controller: yearCtrl,
                        textAlign: TextAlign.center,
                        onChanged: (v) {
                          final n = int.tryParse(v.trim());
                          if (n != null && n > 0) y = n;
                        },
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: fluent.ComboBox<int>(
                        isExpanded: true,
                        value: m,
                        items: [
                          for (var i = 1; i <= 12; i++)
                            fluent.ComboBoxItem(
                                value: i, child: Text('$i 月')),
                        ],
                        onChanged: (v) {
                          if (v != null) setLocal(() => m = v);
                        },
                      ),
                    ),
                    fluent.IconButton(
                      icon: const Icon(FluentIcons.chevron_right_24_regular,
                          size: 14),
                      onPressed: () => setLocal(() {
                        y += 1;
                        yearCtrl.text = '$y';
                      }),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    for (final w in const ['日', '一', '二', '三', '四', '五', '六'])
                      Expanded(
                        child: Center(
                          child: Text(w,
                              style: TextStyle(
                                  fontSize: 11, color: palette.textMuted)),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 4),
                GridView.count(
                  crossAxisCount: 7,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  mainAxisSpacing: 4,
                  crossAxisSpacing: 4,
                  childAspectRatio: 1.5,
                  children: [
                    for (final c in cells)
                      c == null
                          ? const SizedBox.shrink()
                          : MouseRegion(
                              cursor: SystemMouseCursors.click,
                              child: GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTap: () => setLocal(() => d = c),
                                child: Container(
                                  alignment: Alignment.center,
                                  decoration: BoxDecoration(
                                    color: c == d
                                        ? accentColor.withValues(alpha: 0.16)
                                        : null,
                                    borderRadius: BorderRadius.circular(6),
                                    border: Border.all(
                                      color: c == d
                                          ? accentColor.withValues(alpha: 0.5)
                                          : palette.border,
                                    ),
                                  ),
                                  child: Text('$c',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: palette.textPrimary,
                                      )),
                                ),
                              ),
                            ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            fluent.Button(
              onPressed: () => Navigator.pop(ctx, const <int>[0, 0, 0]),
              child: const Text('不设置生日'),
            ),
            fluent.Button(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            fluent.FilledButton(
              onPressed: () => Navigator.pop(ctx, <int>[y, m, d]),
              child: const Text('确定'),
            ),
          ],
        );
      },
    ),
  );
  yearCtrl.dispose();
  return result;
}

class _Labeled extends StatelessWidget {
  const _Labeled(this.label, this.child);
  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: palette.textSecondary),
        ),
        const SizedBox(height: 7),
        child,
      ],
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
  const _NumBox({
    required this.value,
    required this.onChanged,
    this.hint,
  });

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

  void _emit(String v) {
    if (v.trim().isEmpty) {
      widget.onChanged(null);
      return;
    }
    widget.onChanged(int.tryParse(v));
  }

  @override
  Widget build(BuildContext context) {
    return fluent.TextBox(
      controller: _c,
      focusNode: _focus,
      placeholder: widget.hint,
      onChanged: _emit,
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

class _SegButton extends StatefulWidget {
  const _SegButton({
    required this.label,
    required this.onTap,
    this.icon,
    this.selected = false,
    this.wide = false,
  });

  final String label;
  final VoidCallback onTap;
  final IconData? icon;
  final bool selected;
  final bool wide;

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
          width: widget.wide ? double.infinity : null,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
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
          child: Row(
            mainAxisSize: widget.wide ? MainAxisSize.max : MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (widget.icon != null) ...[
                Icon(widget.icon,
                    size: 13,
                    color: selected ? accentColor : palette.textSecondary),
                const SizedBox(width: 6),
              ],
              Flexible(
                child: Text(
                  widget.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 12,
                    color: selected ? palette.textHigh : palette.textSecondary,
                    fontWeight:
                        selected ? FontWeight.w600 : FontWeight.normal,
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

class _PersonListItem extends StatefulWidget {
  const _PersonListItem({
    required this.id,
    required this.name,
    required this.selected,
    required this.onTap,
  });

  final String id;
  final String name;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_PersonListItem> createState() => _PersonListItemState();
}

class _PersonListItemState extends State<_PersonListItem> {
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
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
          decoration: BoxDecoration(
            color: selected
                ? accentColor.withValues(alpha: 0.14)
                : _hover
                    ? palette.card
                    : palette.bgAlt,
            borderRadius: BorderRadius.circular(7),
            border: Border.all(
              color: selected
                  ? accentColor.withValues(alpha: 0.45)
                  : palette.border,
            ),
          ),
          child: Row(
            children: [
              Icon(
                FluentIcons.person_24_regular,
                size: 13,
                color: selected ? accentColor : palette.textHint,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  widget.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    color:
                        selected ? palette.textHigh : palette.textPrimary,
                    fontWeight:
                        selected ? FontWeight.w600 : FontWeight.normal,
                  ),
                ),
              ),
              Text(widget.id,
                  style: TextStyle(fontSize: 10, color: palette.textHint)),
            ],
          ),
        ),
      ),
    );
  }
}

class _FaceCard extends StatefulWidget {
  const _FaceCard({
    required this.face,
    required this.grade,
    required this.selected,
    required this.onTap,
    this.onDelete,
  });

  final Map<String, dynamic> face;
  final int grade;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onDelete;

  @override
  State<_FaceCard> createState() => _FaceCardState();
}

class _FaceCardState extends State<_FaceCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final primary = widget.grade == 1 ? 'icon' : 'icon_xx';
    final alt = widget.grade == 1 ? 'icon_xx' : 'icon';
    final key = (widget.face[primary] ?? widget.face[alt])?.toString() ?? '';
    final faceNo = ((widget.face['id'] as num?)?.toInt() ?? 0) % 100;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Container(
          width: 132,
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: widget.selected ? palette.card : palette.bgAlt,
            borderRadius: BorderRadius.circular(9),
            border: Border.all(
              color: widget.selected
                  ? accentColor.withValues(alpha: 0.5)
                  : palette.border,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Stack(
                children: [
                  Container(
                    height: 150,
                    decoration: BoxDecoration(
                      color: palette.bgDeep2,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: key.isEmpty
                        ? Center(
                            child: Icon(FluentIcons.image_24_regular,
                                size: 18, color: palette.iconDisabled))
                        : TexThumb(
                            keyName: key,
                            fit: BoxFit.contain,
                            width: double.infinity,
                            height: double.infinity,
                          ),
                  ),
                  if (widget.onDelete != null && _hover)
                    Positioned(
                      top: 4,
                      right: 4,
                      child: GestureDetector(
                        onTap: widget.onDelete,
                        child: Container(
                          padding: const EdgeInsets.all(3),
                          decoration: BoxDecoration(
                            color: palette.scrim,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Icon(FluentIcons.dismiss_24_regular,
                              size: 12, color: palette.statusDanger),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 7),
              Text(
                widget.face['name']?.toString() ?? '表情 $faceNo',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11.5,
                  color: palette.textPrimary,
                  fontWeight:
                      widget.selected ? FontWeight.w600 : FontWeight.normal,
                ),
              ),
              if (faceNo == 0)
                Text('默认立绘',
                    style:
                        TextStyle(fontSize: 10, color: palette.textHint)),
            ],
          ),
        ),
      ),
    );
  }
}

class _GiftRow extends StatelessWidget {
  const _GiftRow({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final int value;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: palette.bgAlt,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: palette.border),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11.5, color: palette.textSecondary),
            ),
          ),
          SizedBox(
            width: 30,
            height: 28,
            child: _StepBtn(
              icon: FluentIcons.subtract_24_regular,
              onTap: () => onChanged(value - 1),
            ),
          ),
          const SizedBox(width: 5),
          SizedBox(
            width: 58,
            child: _GiftValue(
              value: value,
              onChanged: onChanged,
            ),
          ),
          const SizedBox(width: 5),
          SizedBox(
            width: 30,
            height: 28,
            child: _StepBtn(
              icon: FluentIcons.add_24_regular,
              onTap: () => onChanged(value + 1),
            ),
          ),
        ],
      ),
    );
  }
}

class _GiftValue extends StatefulWidget {
  const _GiftValue({required this.value, required this.onChanged});
  final int value;
  final ValueChanged<int> onChanged;

  @override
  State<_GiftValue> createState() => _GiftValueState();
}

class _GiftValueState extends State<_GiftValue> {
  late final TextEditingController _c =
      TextEditingController(text: widget.value.toString());
  final FocusNode _focus = FocusNode();

  @override
  void didUpdateWidget(covariant _GiftValue old) {
    super.didUpdateWidget(old);
    if (!_focus.hasFocus && widget.value.toString() != _c.text) {
      _c.text = widget.value.toString();
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
      textAlign: TextAlign.center,
      onChanged: (v) {
        final n = int.tryParse(v.trim());
        if (n != null) widget.onChanged(n);
      },
    );
  }
}

class _StepBtn extends StatelessWidget {
  const _StepBtn({required this.icon, required this.onTap});
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            color: palette.card,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: palette.border),
          ),
          child: Icon(icon, size: 13, color: palette.textSecondary),
        ),
      ),
    );
  }
}

class _SliderField extends StatelessWidget {
  const _SliderField({
    required this.label,
    required this.value,
    required this.onChanged,
    this.max = 100,
  });

  final String label;
  final double value;
  final ValueChanged<int> onChanged;
  final double max;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 76,
          child: Text(label,
              style: TextStyle(fontSize: 12, color: palette.textSecondary)),
        ),
        Expanded(
          child: fluent.Slider(
            min: 0,
            max: max,
            value: value.clamp(0, max),
            onChanged: (v) => onChanged(v.round()),
          ),
        ),
        SizedBox(
          width: 56,
          child: Text(
            value.round().toString(),
            textAlign: TextAlign.center,
            style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: palette.goldText),
          ),
        ),
      ],
    );
  }
}

class _RefDropdown extends StatelessWidget {
  const _RefDropdown({
    required this.value,
    required this.options,
    required this.onChanged,
  });

  final int value;
  final Map<String, String> options;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final entries = options.entries.toList()
      ..sort((a, b) {
        final an = int.tryParse(a.key);
        final bn = int.tryParse(b.key);
        if (an != null && bn != null) return an.compareTo(bn);
        return a.key.compareTo(b.key);
      });
    final hasValue = value == 0 || options.containsKey(value.toString());
    return fluent.ComboBox<int>(
      value: hasValue ? value : 0,
      isExpanded: true,
      items: [
        const fluent.ComboBoxItem<int>(
          value: 0,
          child: Text('未设置', style: TextStyle(fontSize: 12)),
        ),
        for (final e in entries)
          fluent.ComboBoxItem<int>(
            value: int.tryParse(e.key) ?? 0,
            child: Text(e.value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12)),
          ),
        if (!hasValue)
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

class _ChipLine extends StatelessWidget {
  const _ChipLine({
    required this.title,
    required this.empty,
    required this.ids,
    required this.names,
    required this.onPick,
    required this.onRemove,
  });

  final String title;
  final String empty;
  final List<int> ids;
  final Map<String, String> names;
  final Future<void> Function() onPick;
  final ValueChanged<int> onRemove;

  @override
  Widget build(BuildContext context) {
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
                      names[ids[i].toString()] ?? '编号 ${ids[i]}',
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
                onTap: onPick,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: palette.card,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: palette.borderHover),
                  ),
                  child: Text(
                    '＋ 选择',
                    style: TextStyle(fontSize: 11.5, color: accentColor),
                  ),
                ),
              ),
            ),
          ],
        ),
        if (ids.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(empty,
                style: TextStyle(fontSize: 11, color: palette.textHint)),
          ),
      ],
    );
  }
}
