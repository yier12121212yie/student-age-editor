/// 无代码模式的通用实体浏览面板：人物 / 道具 / 背景 / 地图 / 属性 / 职业 /
/// 关系 / 学期 / 事件类型，统一个「ID · 名称」（人物、背景带缩略图）的选择器。
///
/// 数据来源（全部复用既有链路，**零新增请求、零新增路由**）：
/// - 人物：GET /api/roles（game_dicts.roles 合并工作区 PersonCfg，含立绘 key）；
/// - 背景：BgCfg 缩略图走 GET /api/preview/meta 的 bgKeys（[loadBgIdKeyMap]）；
/// - 其余：AppState.gameDicts 里的原版字典，外加宿主可选传入的 MOD 表覆盖。
///
/// 使用度上报只对人物做（/api/usage 的白名单里有 kind=role，其余种类的
/// 白名单在 native/server/services/usage_store.cpp:47-51 里没有对应项）。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;

import '../../core/api_client.dart';
import '../../core/app_theme.dart';
import '../editor/field_meta.dart' show FieldRule;
import '../resources/image_asset_picker.dart';
import 'effect_slot_form.dart' show reportUsage;

/// 可选择引用的实体种类。字典名与 `game_dicts` 的键一一对应。
enum EntityKind { roles, items, bgs, maps, attrs, jobs, relations, turns, evtTypes }

extension EntityKindMeta on EntityKind {
  /// `game_dicts` / `AppState.gameDicts` 里的键。
  String get dictName => switch (this) {
        EntityKind.roles => 'roles',
        EntityKind.items => 'items',
        EntityKind.bgs => 'bgs',
        EntityKind.maps => 'maps',
        EntityKind.attrs => 'attrs',
        EntityKind.jobs => 'jobs',
        EntityKind.relations => 'relations',
        EntityKind.turns => 'turns',
        EntityKind.evtTypes => 'evt_types',
      };

  /// 「选择 X」标题与空态文案用的中文名。
  String get label => switch (this) {
        EntityKind.roles => '人物',
        EntityKind.items => '道具',
        EntityKind.bgs => '背景',
        EntityKind.maps => '地图',
        EntityKind.attrs => '属性',
        EntityKind.jobs => '职业',
        EntityKind.relations => '关系',
        EntityKind.turns => '学期',
        EntityKind.evtTypes => '事件类型',
      };

  /// 是否需要缩略图（只有人物立绘与背景有现成的取图链路）。
  bool get hasThumb => this == EntityKind.roles || this == EntityKind.bgs;

  /// 使用度上报的 kind；null = 该种类不在后端白名单里，不上报。
  String? get usageKind => this == EntityKind.roles ? 'role' : null;
}

/// 字段规则 → 实体种类：无代码模式给引用字段挂「选 X」浏览面板用。
///
/// 只映射确有候选池的种类；返回 null 的字段（如 EvtCfg 跳转目标、actions
/// 行动表）沿用既有的 ID 浏览对话框，不在这里造第二套入口。
EntityKind? entityKindForRule(FieldRule? rule) {
  if (rule == null) return null;
  switch (rule.dictName) {
    case 'roles':
      return EntityKind.roles;
    case 'items':
      return EntityKind.items;
    case 'bgs':
      return EntityKind.bgs;
    case 'maps':
      return EntityKind.maps;
    case 'attrs':
      return EntityKind.attrs;
    case 'jobs':
      return EntityKind.jobs;
    case 'relations':
      return EntityKind.relations;
    case 'turns':
      return EntityKind.turns;
    case 'evt_types':
      return EntityKind.evtTypes;
  }
  switch (rule.idRefCfg) {
    case 'PersonCfg':
      return EntityKind.roles;
    case 'ItemCfg':
      return EntityKind.items;
    case 'BgCfg':
      return EntityKind.bgs;
    case 'MapCfg':
      return EntityKind.maps;
    case 'AttrCfg':
      return EntityKind.attrs;
    case 'JobCfg':
      return EntityKind.jobs;
    case 'RelationCfg':
      return EntityKind.relations;
    case 'EvtTypeCfg':
      return EntityKind.evtTypes;
  }
  return null;
}

/// 一条可选项。
class EntityEntry {
  const EntityEntry({required this.id, required this.name, this.thumbKey = ''});
  final String id;
  final String name;

  /// 贴图 key：人物 = 立绘 key；背景 = BgCfg id 反查出来的 tex key（见 [BgIdThumb]）。
  final String thumbKey;
}

class RoleEntry {
  const RoleEntry({
    required this.id,
    required this.name,
    this.gender,
    this.portrait = '',
  });
  final String id;
  final String name;
  final int? gender;
  final String portrait;

  factory RoleEntry.fromJson(Map j) => RoleEntry(
        id: j['id']?.toString() ?? '',
        name: j['name']?.toString() ?? '',
        gender: (j['gender'] as num?)?.toInt(),
        portrait: j['portrait']?.toString() ?? '',
      );
}

/// 拉取人物目录（q 为空返回全量）。后端不可达时返回空表。
Future<List<RoleEntry>> loadRoles(String q) async {
  try {
    final resp = await ApiClient.instance.get('/api/roles',
        query: q.trim().isEmpty ? null : {'q': q.trim()});
    final list = (resp['roles'] as List? ?? const []).cast<Map>();
    return list.map(RoleEntry.fromJson).toList();
  } catch (_) {
    return const [];
  }
}

/// 字典值 → 展示名：字典值可能是 List（首元素才是中文名）。
String _dictLabel(dynamic v) {
  if (v is List && v.isNotEmpty) return v.first.toString();
  return v?.toString() ?? '';
}

/// 本地字典候选（零请求）：原版字典打底，MOD 记录覆盖同 id 的名字。
List<EntityEntry> _localEntries(
  EntityKind kind, {
  required Map<String, dynamic> gameDicts,
  Map<String, dynamic>? modRecords,
}) {
  final out = <String, String>{};
  final base = gameDicts[kind.dictName];
  if (base is Map) {
    for (final e in base.entries) {
      final id = e.key.toString().trim();
      if (id.isEmpty) continue;
      out[id] = _dictLabel(e.value);
    }
  }
  if (modRecords != null) {
    for (final e in modRecords.entries) {
      final id = e.key.toString().trim();
      if (id.isEmpty) continue;
      final rec = e.value;
      final name = rec is Map ? (rec['name']?.toString() ?? '') : rec.toString();
      if (name.trim().isNotEmpty) out[id] = name.trim();
    }
  }
  final entries = [
    for (final e in out.entries) EntityEntry(id: e.key, name: e.value),
  ];
  // 数字 id 按数值序，其余按字典序（与 schema 编辑器的候选排序一致）。
  entries.sort((a, b) {
    final an = int.tryParse(a.id);
    final bn = int.tryParse(b.id);
    if (an != null && bn != null) return an.compareTo(bn);
    return a.id.compareTo(b.id);
  });
  return entries;
}

List<EntityEntry> _filter(List<EntityEntry> items, String q) {
  final t = q.trim().toLowerCase();
  if (t.isEmpty) return items;
  return [
    for (final e in items)
      if (e.id.toLowerCase().contains(t) || e.name.toLowerCase().contains(t)) e,
  ];
}

/// 加载候选（按种类分流）。后端不可达时退回字典，字典也没有就返回空表。
Future<List<EntityEntry>> loadEntities(
  EntityKind kind, {
  String q = '',
  Map<String, dynamic> gameDicts = const {},
  Map<String, dynamic>? modRecords,
}) async {
  if (kind == EntityKind.roles) {
    final roles = await loadRoles(q);
    if (roles.isNotEmpty) {
      return [
        for (final r in roles)
          EntityEntry(id: r.id, name: r.name, thumbKey: r.portrait),
      ];
    }
    // 后端不可达 / 搜索无结果：退回原版字典（搜索在客户端做）。
  }
  final local = _localEntries(kind, gameDicts: gameDicts, modRecords: modRecords);
  return q.trim().isEmpty ? local : _filter(local, q);
}

/// 打开通用实体浏览面板；确认返回所选 id（按点选顺序），取消返回 null。
/// [multi]=true 多选（累加高亮 + 确定按钮），false 单击即选中并返回。
Future<List<String>?> showEntityPicker(
  BuildContext context, {
  required EntityKind kind,
  bool multi = true,
  String? title,
  Set<String> exclude = const {},
  Map<String, dynamic> gameDicts = const {},
  Map<String, dynamic>? modRecords,
}) {
  return showDialog<List<String>>(
    context: context,
    barrierColor: palette.scrim,
    builder: (ctx) => _EntityPickerDialog(
      kind: kind,
      multi: multi,
      title: title ?? ('选择' + kind.label),
      exclude: exclude,
      gameDicts: gameDicts,
      modRecords: modRecords,
    ),
  );
}

class _EntityPickerDialog extends StatefulWidget {
  const _EntityPickerDialog({
    required this.kind,
    required this.multi,
    required this.title,
    required this.exclude,
    required this.gameDicts,
    this.modRecords,
  });

  final EntityKind kind;
  final bool multi;
  final String title;
  final Set<String> exclude;
  final Map<String, dynamic> gameDicts;
  final Map<String, dynamic>? modRecords;

  @override
  State<_EntityPickerDialog> createState() => _EntityPickerDialogState();
}

class _EntityPickerDialogState extends State<_EntityPickerDialog> {
  final TextEditingController _q = TextEditingController();
  Timer? _debounce;
  List<EntityEntry> _items = const [];
  bool _loading = true;
  final List<String> _picked = [];

  @override
  void initState() {
    super.initState();
    // 背景缩略图需要 id→key 映射；这是用户点击路径，允许发请求。
    if (widget.kind == EntityKind.bgs) {
      loadBgIdKeyMap().then((_) {
        if (mounted) setState(() {});
      });
    }
    _fetch('');
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _q.dispose();
    super.dispose();
  }

  Future<void> _fetch(String q) async {
    final items = await loadEntities(
      widget.kind,
      q: q,
      gameDicts: widget.gameDicts,
      modRecords: widget.modRecords,
    );
    if (!mounted) return;
    setState(() {
      _items = items;
      _loading = false;
    });
  }

  void _onQuery(String v) {
    _debounce?.cancel();
    // 人物走服务端搜索（可搜名字），其余种类本地过滤；统一防抖 250ms。
    _debounce = Timer(const Duration(milliseconds: 250), () => _fetch(v));
  }

  void _tap(EntityEntry e) {
    if (widget.multi) {
      setState(() {
        if (_picked.contains(e.id)) {
          _picked.remove(e.id);
        } else {
          _picked.add(e.id);
        }
      });
    } else {
      _report([e.id]);
      Navigator.pop(context, [e.id]);
    }
  }

  void _report(List<String> ids) {
    final kind = widget.kind.usageKind;
    if (kind == null) return;
    for (final id in ids) {
      reportUsage(kind, id);
    }
  }

  void _confirm() {
    _report(_picked);
    Navigator.pop(context, List.of(_picked));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title + (widget.multi ? '（多选）' : ''),
          style: const TextStyle(fontSize: 14)),
      content: SizedBox(
        width: 560,
        height: 460,
        child: Column(
          children: [
            fluent.TextBox(
              controller: _q,
              placeholder: '搜索' + widget.kind.label + '（中文名或 ID）…',
              style: const TextStyle(fontSize: 12),
              onChanged: _onQuery,
            ),
            const SizedBox(height: 8),
            Expanded(
              child: _loading
                  ? const Center(child: fluent.ProgressRing())
                  : _items.isEmpty
                      ? Center(
                          child: Text('没有匹配的' + widget.kind.label,
                              style: TextStyle(
                                  fontSize: 12, color: palette.textMuted)))
                      : widget.kind.hasThumb
                          ? _thumbGrid()
                          : _plainList(),
            ),
          ],
        ),
      ),
      actions: [
        Text(_picked.isEmpty ? '' : '已选 ' + _picked.length.toString() + ' 项',
            style: TextStyle(fontSize: 11, color: palette.textMuted)),
        fluent.Button(
            onPressed: () => Navigator.pop(context), child: const Text('取消')),
        if (widget.multi)
          fluent.FilledButton(
            onPressed: _picked.isEmpty ? null : _confirm,
            child: const Text('确定'),
          ),
      ],
    );
  }

  /// 人物 / 背景：缩略图网格。
  Widget _thumbGrid() {
    return GridView.builder(
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 110,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        childAspectRatio: 0.72,
      ),
      itemCount: _items.length,
      itemBuilder: (c, i) {
        final e = _items[i];
        final selected = _picked.contains(e.id);
        final disabled = widget.exclude.contains(e.id);
        return _tileShell(
          selected: selected,
          disabled: disabled,
          onTap: disabled ? null : () => _tap(e),
          child: Column(
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: widget.kind == EntityKind.bgs
                      ? BgIdThumb(id: e.id, width: double.infinity, height: 60)
                      : (e.thumbKey.isEmpty
                          ? Center(
                              child: Icon(Icons.person_outline,
                                  size: 28, color: palette.textHint))
                          : TexThumb(keyName: e.thumbKey, fit: BoxFit.contain)),
                ),
              ),
              const SizedBox(height: 2),
              Text(
                e.name.isEmpty ? e.id : e.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11),
              ),
              Text(
                'ID ' + e.id,
                maxLines: 1,
                style: TextStyle(fontSize: 9.5, color: palette.textSecondary),
              ),
            ],
          ),
        );
      },
    );
  }

  /// 其余种类：无图，用一行一项的紧凑列表（ID 左、名称右）。
  Widget _plainList() {
    return ListView.builder(
      itemCount: _items.length,
      itemBuilder: (c, i) {
        final e = _items[i];
        final selected = _picked.contains(e.id);
        final disabled = widget.exclude.contains(e.id);
        return Opacity(
          opacity: disabled ? 0.35 : 1,
          child: MouseRegion(
            cursor: disabled
                ? SystemMouseCursors.forbidden
                : SystemMouseCursors.click,
            child: GestureDetector(
              onTap: disabled ? null : () => _tap(e),
              child: Container(
                margin: const EdgeInsets.only(bottom: 4),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                decoration: BoxDecoration(
                  color: selected ? palette.tintAccent : palette.card,
                  borderRadius: BorderRadius.circular(AppRadius.xs),
                  border: Border.all(
                    color: selected ? accentColor : palette.border,
                    width: selected ? 2 : 1,
                  ),
                ),
                child: Row(
                  children: [
                    SizedBox(
                      width: 64,
                      child: Text('ID ' + e.id,
                          style: TextStyle(
                              fontSize: 11, color: palette.textSecondary)),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        e.name.isEmpty ? '(未命名)' : e.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                    if (selected) Icon(Icons.check, size: 14, color: accentColor),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _tileShell({
    required bool selected,
    required bool disabled,
    required VoidCallback? onTap,
    required Widget child,
  }) {
    return Opacity(
      opacity: disabled ? 0.35 : 1,
      child: MouseRegion(
        cursor:
            disabled ? SystemMouseCursors.forbidden : SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            decoration: BoxDecoration(
              color: palette.card,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: selected ? accentColor : palette.border,
                width: selected ? 2 : 1,
              ),
            ),
            padding: const EdgeInsets.all(4),
            child: child,
          ),
        ),
      ),
    );
  }
}
