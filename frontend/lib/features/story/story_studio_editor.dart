/// 剧情舞台：类友商产品#2「拾光工坊」的剧情编辑页。
///
/// 三栏信息架构：左栏对话夹树（沿跳转链递归展开，选项/条件分支在触发句下
/// 长夹）｜中栏可编辑的游戏画面 + 本句分区（选项/接续/音频/效果/原文兜底）｜
/// 右栏人物与表情。数据流与经典剧情处理器同口径：整表加载、stageOf 舞台副本、
/// mergeStageBack 并回、PUT 带 expect_mtime_ns 乐观锁，纯函数全部走 story_logic。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../../core/api_client.dart';
import '../../core/models.dart';
import '../ai/tts_panel.dart';
import '../editor/field_utils.dart';
import '../editor/id_ref_picker.dart' show showIdBrowseDialog;
import '../nocode/no_code_exit.dart';
import '../nocode/no_code_ref_field.dart';
import '../nocode/nocode_effect_field.dart';
import '../nocode/role_picker.dart';
import '../resources/image_asset_picker.dart' show BgIdThumb, TexThumb;
import '../resources/local_import.dart'
    show importLocalAssets, texKeyOfImportedPath;
import 'story_logic.dart';
import '../../core/app_theme.dart';

// ---------------------------------------------------------------------------
// 对话线树（纯函数，可单测）
// ---------------------------------------------------------------------------

/// 左栏对话线的一个条目。
enum StudioItemKind { talk, folder, tail, ref, note, header }

class StudioTreeItem {
  const StudioTreeItem({
    required this.kind,
    required this.depth,
    this.id = '',
    this.label = '',
    this.ownerId = '',
    this.field = '',
  });

  /// talk=对白卡；folder=对话夹标题；tail=夹底部去向；ref=跳转引用；
  /// note=提示（目标缺失等）；header=游离段标题。
  final StudioItemKind kind;

  /// 缩进层级（0=主线）。折叠时按「depth 大于夹层级」隐藏子项。
  final int depth;

  /// talk=对白 id；folder/tail=夹键（'opt:..'/'cond:..'）；ref=目标对白 id；
  /// note=缺失目标 id；header=''。
  final String id;

  /// folder 的显示标题 / note、header 的文案。
  final String label;

  /// 夹的归属对象 id（选项夹=选项 id，条件夹=对白 id），tail 写回时用。
  final String ownerId;

  /// tail 写回的字段（'talkId'/'talkId2'/'nextTalk2'）。
  final String field;
}

/// 对话链最大嵌套层数：超过后以引用呈现，防御脏数据造成的深递归/环。
const int _kStudioMaxDepth = 12;

/// 从事件首句出发沿 nextTalk/option/check 链构建对话线条目序列（深度优先、
/// 扁平带 depth）。同一节点第二次被触达时输出 [StudioItemKind.ref]（友商#2
/// 的「↗ 跳转到该句」），无法从任何首句到达的对白收进「游离对白」段。
List<StudioTreeItem> buildStudioTree({
  required String evtId,
  required Map<String, dynamic> evtCfg,
  required Map<String, dynamic> talks,
  required Map<String, dynamic> options,
}) {
  final items = <StudioTreeItem>[];
  final visited = <String>{};

  void walk(String? startId, int depth) {
    var cursor = startId == null ? '' : cln(startId);
    // 链的迭代推进；visited 保证每条对白至多展开一次（环在此收敛为引用）。
    while (cursor.isNotEmpty) {
      if (visited.contains(cursor)) {
        items.add(
          StudioTreeItem(kind: StudioItemKind.ref, depth: depth, id: cursor),
        );
        return;
      }
      final raw = talks[cursor];
      if (raw is! Map) {
        items.add(
          StudioTreeItem(
            kind: StudioItemKind.note,
            depth: depth,
            id: cursor,
            label: '跳转目标 [$cursor] 不存在',
          ),
        );
        return;
      }
      visited.add(cursor);
      items.add(
        StudioTreeItem(kind: StudioItemKind.talk, depth: depth, id: cursor),
      );
      final talk = raw.cast<String, dynamic>();

      if (depth + 1 <= _kStudioMaxDepth) {
        final seenOptIds = <String>{};
        for (final optId
            in normalizeStoryIdList(talk['option']).map(cln)) {
          if (optId.isEmpty || seenOptIds.contains(optId)) continue;
          seenOptIds.add(optId);
          final opt = options[optId];
          final key = 'opt:$optId';
          if (opt is! Map) {
            items.add(
              StudioTreeItem(
                kind: StudioItemKind.note,
                depth: depth + 1,
                id: optId,
                label: '选项 [$optId] 不在 OptionCfg',
              ),
            );
            continue;
          }
          final title = cln(opt['content']);
          items.add(
            StudioTreeItem(
              kind: StudioItemKind.folder,
              depth: depth + 1,
              id: key,
              label: title.isEmpty ? '选项 $optId' : title,
              ownerId: optId,
            ),
          );
          final t1 = _firstTarget(opt['talkId']);
          if (t1.isEmpty) {
            items.add(
              StudioTreeItem(
                kind: StudioItemKind.note,
                depth: depth + 2,
                label: '未设置跳转：本夹没有起点',
              ),
            );
          } else {
            walk(t1, depth + 2);
          }
          items.add(
            StudioTreeItem(
              kind: StudioItemKind.tail,
              depth: depth + 2,
              id: key,
              ownerId: optId,
              field: 'talkId',
            ),
          );
          final t2 = _firstTarget(opt['talkId2']);
          if (t2.isNotEmpty) {
            final fkey = '$key:fail';
            items.add(
              StudioTreeItem(
                kind: StudioItemKind.folder,
                depth: depth + 2,
                id: fkey,
                label: '判定失败后',
                ownerId: optId,
              ),
            );
            walk(t2, depth + 3);
            items.add(
              StudioTreeItem(
                kind: StudioItemKind.tail,
                depth: depth + 3,
                id: fkey,
                ownerId: optId,
                field: 'talkId2',
              ),
            );
          }
        }

        // 条件分支：check 有值且配置了失败跳转时长出一个紫色夹（友商#2 的
        // conditional-folder），失败去向即夹底部接续下拉。
        final hasCheck = normalizeStoryIdList(talk['check']).isNotEmpty;
        final fail = _firstTarget(talk['nextTalk2']);
        if (fail.isNotEmpty) {
          if (hasCheck) {
            final key = 'cond:$cursor';
            items.add(
              StudioTreeItem(
                kind: StudioItemKind.folder,
                depth: depth + 1,
                id: key,
                label: '条件判定 · 失败进入',
                ownerId: cursor,
              ),
            );
            walk(fail, depth + 2);
            items.add(
              StudioTreeItem(
                kind: StudioItemKind.tail,
                depth: depth + 2,
                id: key,
                ownerId: cursor,
                field: 'nextTalk2',
              ),
            );
          } else {
            items.add(
              StudioTreeItem(
                kind: StudioItemKind.ref,
                depth: depth + 1,
                id: fail,
                label: '失败跳转 →',
              ),
            );
          }
        }
        // 多值 nextTalk 的其余目标：不展开成链，以引用呈现。
        final nexts =
            normalizeStoryIdList(talk['nextTalk']).map(cln).where((s) => s.isNotEmpty).toList();
        for (final extra in nexts.skip(1)) {
          items.add(
            StudioTreeItem(
              kind: StudioItemKind.ref,
              depth: depth + 1,
              id: extra,
              label: '也接续 →',
            ),
          );
        }
        cursor = nexts.isEmpty ? '' : nexts.first;
      } else {
        // 超出层级上限：剩余链条折叠为引用。
        final nexts =
            normalizeStoryIdList(talk['nextTalk']).map(cln).where((s) => s.isNotEmpty).toList();
        if (nexts.isNotEmpty) {
          items.add(
            StudioTreeItem(
              kind: StudioItemKind.ref,
              depth: depth,
              id: nexts.first,
              label: '（层级过深，折叠）→',
            ),
          );
        }
        return;
      }
    }
  }

  for (final s in storyStartIds(evtId, evtCfg, talks)) {
    walk(s, 0);
  }
  final orphans = talks.keys.map(cln).where((k) => !visited.contains(k)).toList()
    ..sort(compareIds);
  if (orphans.isNotEmpty) {
    items.add(
      StudioTreeItem(
        kind: StudioItemKind.header,
        depth: 0,
        label: '游离对白（未接入任何起始点）',
      ),
    );
    for (final o in orphans) {
      walk(o, 0);
    }
  }
  return items;
}

String _firstTarget(dynamic raw) {
  for (final t in normalizeStoryIdList(raw)) {
    final s = cln(t);
    if (s.isNotEmpty) return s;
  }
  return '';
}

/// 折叠呈现：夹被折叠时跳过其全部子项（depth 更大者），直到同级或更浅项。
List<StudioTreeItem> applyStudioCollapse(
  List<StudioTreeItem> items,
  Set<String> collapsed,
) {
  if (collapsed.isEmpty) return items;
  final out = <StudioTreeItem>[];
  var hideBelow = -1;
  for (final it in items) {
    if (hideBelow >= 0) {
      if (it.depth > hideBelow) continue;
      hideBelow = -1;
    }
    out.add(it);
    if (it.kind == StudioItemKind.folder && collapsed.contains(it.id)) {
      hideBelow = it.depth;
    }
  }
  return out;
}

// ---------------------------------------------------------------------------
// 剧情舞台编辑器
// ---------------------------------------------------------------------------

class StoryStudioEditor extends StatefulWidget {
  const StoryStudioEditor({
    super.key,
    required this.state,
    this.onPreview,
  });

  final AppState state;

  /// 事件场景预览回调：携带事件 ID，由宿主打开预览文档。
  final ValueChanged<String>? onPreview;

  @override
  State<StoryStudioEditor> createState() => _StoryStudioEditorState();
}

/// 舞台站位信息（roles 字符串 '槽位,人物,动作' 的解析结果）。
class _StudioRolePlacement {
  const _StudioRolePlacement({
    required this.slot,
    required this.roleId,
    required this.action,
  });
  final int slot;
  final String roleId;
  final String action;
}

class _StoryStudioEditorState extends State<StoryStudioEditor> {
  bool _loaded = false;
  String? _error;

  Map<String, dynamic> _evtCfg = {};
  Map<String, dynamic> _talkCfg = {};
  Map<String, dynamic> _optCfg = {};
  Map<String, dynamic> _personCfg = {};
  Map<String, dynamic> _bgCfg = {};
  Map<String, dynamic> _audioCfg = {};
  Map<String, RoleEntry> _roleCatalog = {};

  int? _evtMtimeNs;
  int? _talkMtimeNs;
  int? _optMtimeNs;
  // BgCfg / PersonCfg 也要能被「从电脑选择」就地补一条并乐观锁写回。
  int? _bgMtimeNs;
  int? _personMtimeNs;

  String? _evtId;
  List<String> _prefixes = const [];
  Map<String, dynamic> _stageTalks = {};
  Map<String, dynamic> _stageOpts = {};
  Map<String, dynamic> _talkBaseline = {};
  Map<String, dynamic> _optBaseline = {};

  String? _talkId;
  final Set<String> _selectedTalkIds = {};
  final Set<String> _collapsedFolders = {};
  bool _dirty = false;
  bool _switching = false;

  // 页面级偏好（对应友商#2 工具栏上的全局开关）
  bool _showIds = true;
  int _stageIndex = 0;
  static const _stages = ['小学立绘', '中学立绘'];
  String _search = '';
  final TextEditingController _searchCtrl = TextEditingController();

  /// 右栏正在检视的在场人物（不在本场时自动回落到首位）。
  String? _inspectRoleId;

  @override
  void initState() {
    super.initState();
    _load();
    _loadRoleCatalog();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loaded = false;
      _error = null;
    });
    try {
      final names = [
        'EvtCfg',
        'TalkCfg',
        'OptionCfg',
        'PersonCfg',
        'BgCfg',
        'AudioCfg',
      ];
      final results = await Future.wait(
        names.map((n) => ApiClient.instance.get('/api/cfg/$n')),
      );
      if (!mounted) return;
      setState(() {
        _evtCfg = _asMap(results[0]['data']);
        _talkCfg = _asMap(results[1]['data']);
        _optCfg = _asMap(results[2]['data']);
        _personCfg = _asMap(results[3]['data']);
        _bgCfg = _asMap(results[4]['data']);
        _audioCfg = _asMap(results[5]['data']);
        _evtMtimeNs = _asInt(results[0]['mtime_ns']);
        _talkMtimeNs = _asInt(results[1]['mtime_ns']);
        _optMtimeNs = _asInt(results[2]['mtime_ns']);
        _personMtimeNs = _asInt(results[3]['mtime_ns']);
        _bgMtimeNs = _asInt(results[4]['mtime_ns']);
        _loaded = true;
      });
      if (_evtId == null && _evtCfg.isNotEmpty) {
        final keys = _evtCfg.keys.toList()..sort(compareEventIds);
        _selectEvent(keys.first);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loaded = true;
      });
    }
  }

  Future<void> _loadRoleCatalog() async {
    final roles = await loadRoles('');
    if (!mounted || roles.isEmpty) return;
    setState(() {
      _roleCatalog = {for (final r in roles) r.id: r};
    });
  }

  Map<String, dynamic> _asMap(dynamic v) =>
      v is Map ? v.cast<String, dynamic>() : <String, dynamic>{};

  int? _asInt(dynamic v) => v is int ? v : null;

  // ---------- 事件 / 对白切换 ----------

  Future<void> _selectEvent(String evtId, {bool skipDirtyCheck = false}) async {
    if (_switching) return;
    if (evtId == _evtId) return;
    _switching = true;
    try {
      if (!skipDirtyCheck && _dirty && _evtId != null && _evtId != evtId) {
        final choice = await _confirmSaveDiscard();
        if (!mounted || choice == null || choice == 'cancel') return;
        if (choice == 'save') {
          final saved = await _save();
          if (!mounted || !saved) return;
        }
      }
      if (!mounted) return;
      setState(() {
        _evtId = evtId;
        _talkId = null;
        _selectedTalkIds.clear();
        _collapsedFolders.clear();
        _inspectRoleId = null;
        _search = '';
        _searchCtrl.clear();
        _prefixes = storyRelatedPrefixes(evtId, _evtCfg);
        _stageTalks = stageOf(_talkCfg, _prefixes);
        _stageOpts = stageOf(_optCfg, _prefixes, isOption: true);
        _talkBaseline = stageOf(_talkCfg, _prefixes);
        _optBaseline = stageOf(_optCfg, _prefixes, isOption: true);
        _dirty = false;
        if (_stageTalks.isNotEmpty) {
          final keys = _stageTalks.keys.toList()..sort(compareIds);
          _talkId = keys.first;
          _selectedTalkIds.add(keys.first);
        }
      });
    } finally {
      _switching = false;
    }
  }

  void _selectTalk(String id) {
    setState(() {
      _talkId = id;
      // Shift 点选累加多选（与经典处理器同交互）
      if (HardwareKeyboard.instance.isShiftPressed) {
        if (!_selectedTalkIds.remove(id)) _selectedTalkIds.add(id);
      } else if (!_selectedTalkIds.contains(id)) {
        _selectedTalkIds.clear();
        _selectedTalkIds.add(id);
      }
    });
  }

  Map<String, dynamic>? get _curTalk {
    final id = _talkId;
    if (id == null) return null;
    final t = _stageTalks[id];
    return t is Map ? t.cast<String, dynamic>() : null;
  }

  // ---------- 舞台操作（与经典处理器同口径的 story_logic 调用） ----------

  void _insertTalk() {
    final cur = _talkId;
    if (cur == null) return;
    final newId = insertTalkId(cur, _stageTalks);
    if (newId.isEmpty) return;
    final curTalk = _stageTalks[cur];
    final next =
        normalizeStoryIdList(curTalk is Map ? curTalk['nextTalk'] : null);
    setState(() {
      _stageTalks[newId] = buildInsertedTalkRecord(
        curTalk is Map ? curTalk.cast<String, dynamic>() : null,
        newId,
        next,
      );
      if (curTalk is Map) curTalk['nextTalk'] = <dynamic>[int.parse(newId)];
      _talkId = newId;
      _selectedTalkIds
        ..clear()
        ..add(newId);
      _dirty = true;
    });
  }

  void _appendTalk() {
    final newId = appendTalkId(_talkId, _evtId ?? '', _stageTalks);
    if (newId.isEmpty) return;
    final cur = _talkId;
    final curTalk = cur != null ? _stageTalks[cur] : null;
    setState(() {
      _stageTalks[newId] = {
        'id': int.parse(newId),
        'roleIds': <dynamic>[],
        'content': '【新建对话】',
        'nextTalk': <dynamic>[],
        'nextTalk2': <dynamic>[],
        'option': <dynamic>[],
      };
      if (cur != null && curTalk is Map) {
        final oldNext = normalizeStoryIdList(curTalk['nextTalk']);
        if (oldNext.isEmpty) curTalk['nextTalk'] = <dynamic>[int.parse(newId)];
      } else {
        final evt = _evtCfg[cln(_evtId)];
        if (evt is Map && normalizeStoryIdList(evt['talkId']).isEmpty) {
          evt['talkId'] = <dynamic>[int.parse(newId)];
        }
      }
      _talkId = newId;
      _selectedTalkIds
        ..clear()
        ..add(newId);
      _dirty = true;
    });
  }

  /// 复制选中：紧随原句插入一条内容相同的副本；选项不随副本迁移
  /// （选项 ID 空间按对白前缀分配，复制会让两句共享同一选项记录）。
  void _duplicateSelected() {
    if (_selectedTalkIds.isEmpty) return;
    final ids = _selectedTalkIds.toList()
      ..sort(
        (a, b) => (int.tryParse(a) ?? 0).compareTo(int.tryParse(b) ?? 0),
      );
    setState(() {
      String? last;
      for (final id in ids) {
        final src = _stageTalks[id];
        if (src is! Map) continue;
        final newId = insertTalkId(id, _stageTalks);
        if (newId.isEmpty) continue;
        final copy = (copyRecordValue(src) as Map).cast<String, dynamic>();
        copy['id'] = int.parse(newId);
        copy['option'] = <dynamic>[];
        final oldNext = normalizeStoryIdList(copy['nextTalk']);
        copy['nextTalk'] = oldNext;
        _stageTalks[newId] = copy;
        src['nextTalk'] = <dynamic>[int.parse(newId)];
        last = newId;
      }
      if (last != null) {
        _talkId = last;
        _selectedTalkIds
          ..clear()
          ..add(last);
      }
      _dirty = true;
    });
  }

  Future<void> _deleteSelectedTalks() async {
    if (_selectedTalkIds.isEmpty) return;
    final count = _selectedTalkIds.length;
    final confirmed = await _confirm(
      '删除对话',
      '确认删除选中的 $count 句对话吗？\n（删除后会将指向这些对话的跳转自动重定向）',
    );
    if (!confirmed || !mounted) return;
    setState(() {
      final ids = _selectedTalkIds.toList()
        ..sort(
          (a, b) => (int.tryParse(b) ?? 0).compareTo(int.tryParse(a) ?? 0),
        );
      for (final delId in ids) {
        final deleted = _stageTalks[delId];
        var replacements = normalizeStoryIdList(
          deleted is Map ? deleted['nextTalk'] : null,
        );
        if (replacements.isEmpty) {
          final later = _stageTalks.keys
              .map(int.tryParse)
              .whereType<int>()
              .where((n) => n > (int.tryParse(delId) ?? 0))
              .toList()
            ..sort();
          if (later.isNotEmpty) replacements = [later.first];
        }
        _stageTalks.remove(delId);
        remapDeletedTarget(
          _stageTalks,
          _stageOpts,
          _prefixes,
          delId,
          replacements,
        );
      }
      _talkId = null;
      _selectedTalkIds.clear();
      if (_stageTalks.isNotEmpty) {
        final keys = _stageTalks.keys.toList()..sort(compareIds);
        _talkId = keys.first;
        _selectedTalkIds.add(keys.first);
      }
      _dirty = true;
    });
  }

  void _addOption() {
    final cur = _talkId;
    if (cur == null) return;
    final talk = _stageTalks[cur];
    if (talk is! Map) return;
    final pfx = getTalkPrefix(cur);
    final used = <String>{
      for (final k in _stageOpts.keys) cln(k),
      for (final t in _stageTalks.values)
        if (t is Map) ...ensureList(t['option']),
    };
    var candidate = allocOptionId(pfx, used);
    if (candidate == null) {
      _showInfo('提示', '按钮数量已超 99，请直接在选项表修改 ID。');
      return;
    }
    final existingIds =
        normalizeStoryIdList(talk['option']).map(cln).toSet();
    if (existingIds.contains(candidate)) {
      candidate = allocOptionId(pfx, {...used, candidate}) ?? candidate;
    }
    final newOptId = candidate;
    final existing = normalizeStoryIdList(talk['option']);
    setState(() {
      _stageOpts[newOptId] = {
        'id': int.parse(newOptId),
        'content': '新创建的按钮',
        'precondition': <dynamic>[],
        'check': <dynamic>[],
        'talkId': <dynamic>[],
        'talkId2': <dynamic>[],
        'effect': <dynamic>[],
        'effect2': <dynamic>[],
      };
      talk['option'] = [...existing, int.parse(newOptId)];
      _dirty = true;
    });
  }

  void _removeOption(String optId) {
    final cur = _talkId;
    if (cur == null) return;
    final talk = _stageTalks[cur];
    if (talk is! Map) return;
    setState(() {
      talk['option'] = normalizeStoryIdList(talk['option'])
          .where((o) => cln(o) != cln(optId))
          .toList();
      _stageOpts.remove(optId);
      _dirty = true;
    });
  }

  /// 对话夹底部「结束后去向」：tail 条目按 field 写回归属记录的跳转目标。
  Future<void> _pickFolderTail(StudioTreeItem item) async {
    final ids = await _pickTalkTarget(
      title: '选择接续目标',
      initial: const [],
    );
    if (ids == null || ids.isEmpty || !mounted) return;
    final target = cln(ids.first);
    if (target.isEmpty) return;
    setState(() {
      if (item.field == 'nextTalk2') {
        final talk = _stageTalks[item.ownerId];
        if (talk is Map) talk['nextTalk2'] = <dynamic>[int.parse(target)];
      } else {
        final opt = _stageOpts[item.ownerId];
        if (opt is Map) opt[item.field] = <dynamic>[int.parse(target)];
      }
      _dirty = true;
    });
  }

  // ---------- 保存 ----------

  Future<bool> _save() async {
    try {
      mergeStageBack(_talkCfg, _talkBaseline, _stageTalks, _prefixes);
      mergeStageBack(
        _optCfg,
        _optBaseline,
        _stageOpts,
        _prefixes,
        isOption: true,
      );
      if (!await _putTableWithConflictCheck(
        'TalkCfg',
        _talkCfg,
        expect: () => _talkMtimeNs,
        onMtime: (v) => _talkMtimeNs = v,
      )) {
        return false;
      }
      if (!await _putTableWithConflictCheck(
        'OptionCfg',
        _optCfg,
        expect: () => _optMtimeNs,
        onMtime: (v) => _optMtimeNs = v,
      )) {
        return false;
      }
      if (!await _putTableWithConflictCheck(
        'EvtCfg',
        _evtCfg,
        expect: () => _evtMtimeNs,
        onMtime: (v) => _evtMtimeNs = v,
      )) {
        return false;
      }
      if (!mounted) return false;
      setState(() {
        _dirty = false;
        _talkBaseline = stageOf(_talkCfg, _prefixes);
        _optBaseline = stageOf(_optCfg, _prefixes, isOption: true);
      });
      fluent.displayInfoBar(
        context,
        builder: (ctx, close) => fluent.InfoBar(
          title: Text('已保存事件 ${_evtId ?? ''} 的剧情线'),
          severity: fluent.InfoBarSeverity.success,
        ),
      );
      return true;
    } catch (e) {
      if (mounted) {
        fluent.displayInfoBar(
          context,
          builder: (ctx, close) => fluent.InfoBar(
            title: const Text('保存失败'),
            content: Text(e.toString()),
            severity: fluent.InfoBarSeverity.error,
          ),
        );
      }
      return false;
    }
  }

  Future<bool> _putTableWithConflictCheck(
    String cfg,
    Map<String, dynamic> data, {
    required int? Function() expect,
    required ValueChanged<int?> onMtime,
  }) async {
    Future<bool> put({bool force = false}) async {
      final r = await ApiClient.instance.put(
        '/api/cfg/$cfg',
        body: {
          'data': data,
          if (!force) 'expect_mtime_ns': expect(),
          if (force) 'force': true,
        },
      );
      onMtime(_asInt(r is Map ? r['mtime_ns'] : null));
      return true;
    }

    try {
      return await put();
    } on ApiException catch (e) {
      if (e.statusCode != 409) rethrow;
      if (!mounted) return false;
      final action = await fluent.showDialog<String>(
        context: context,
        builder: (ctx) => fluent.ContentDialog(
          title: const Text('文件冲突'),
          content: Text(
            '$cfg 文件已被外部修改。\n重新加载将放弃该表本地未保存的改动；'
            '强制覆盖将用当前内容覆盖磁盘文件。',
            style: TextStyle(fontSize: 12.5, color: palette.textPrimary),
          ),
          actions: [
            fluent.Button(
              onPressed: () => Navigator.pop(ctx, 'reload'),
              child: const Text('重新加载(放弃该表修改)'),
            ),
            fluent.Button(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            fluent.FilledButton(
              onPressed: () => Navigator.pop(ctx, 'force'),
              child: const Text('强制覆盖'),
            ),
          ],
        ),
      );
      if (!mounted) return false;
      if (action == 'force') return put(force: true);
      if (action == 'reload') {
        final r = await ApiClient.instance.get('/api/cfg/$cfg');
        if (!mounted) return false;
        final disk = _asMap(r['data']);
        final mtime = _asInt(r['mtime_ns']);
        setState(() {
          switch (cfg) {
            case 'TalkCfg':
              _talkCfg = disk;
              _talkMtimeNs = mtime;
              _stageTalks = stageOf(_talkCfg, _prefixes);
              _talkBaseline = stageOf(_talkCfg, _prefixes);
              break;
            case 'OptionCfg':
              _optCfg = disk;
              _optMtimeNs = mtime;
              _stageOpts = stageOf(_optCfg, _prefixes, isOption: true);
              _optBaseline = stageOf(_optCfg, _prefixes, isOption: true);
              break;
            case 'BgCfg':
              _bgCfg = disk;
              _bgMtimeNs = mtime;
              break;
            case 'PersonCfg':
              _personCfg = disk;
              _personMtimeNs = mtime;
              break;
            default:
              _evtCfg = disk;
              _evtMtimeNs = mtime;
          }
        });
        _showInfo('提示', '$cfg 已从磁盘重新加载，该表未保存的改动已放弃。');
      }
      return false;
    }
  }

  // ---------- 小工具 ----------

  Future<bool> _confirm(String title, String message) async {
    final r = await fluent.showDialog<bool>(
      context: context,
      builder: (ctx) => fluent.ContentDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          fluent.Button(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          fluent.FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确认'),
          ),
        ],
      ),
    );
    return r ?? false;
  }

  Future<String?> _confirmSaveDiscard() {
    return fluent.showDialog<String>(
      context: context,
      builder: (ctx) => fluent.ContentDialog(
        title: const Text('有未保存的修改'),
        content: const Text('当前事件的对白/选项修改尚未保存，离开当前事件后将丢失。'),
        actions: [
          fluent.Button(
            onPressed: () => Navigator.pop(ctx, 'discard'),
            child: const Text('放弃修改'),
          ),
          fluent.Button(
            onPressed: () => Navigator.pop(ctx, 'cancel'),
            child: const Text('取消'),
          ),
          fluent.FilledButton(
            onPressed: () => Navigator.pop(ctx, 'save'),
            child: const Text('保存并切换'),
          ),
        ],
      ),
    );
  }

  void _showInfo(String title, String message) {
    fluent.displayInfoBar(
      context,
      builder: (ctx, close) => fluent.InfoBar(
        title: Text(title),
        content: Text(message),
        severity: fluent.InfoBarSeverity.info,
      ),
    );
  }

  bool get _noCode => widget.state.noCodeMode;

  String _evtTitle(String id) {
    final info = _evtCfg[id];
    if (info is Map) {
      final t = info['title'];
      if (t is String) return t;
    }
    return '';
  }

  String _talkDisplayName(String talkId) {
    final t = _stageTalks[talkId];
    if (t is! Map) return '旁白';
    final roleName = cln(t['roleName']);
    if (roleName.isNotEmpty) return roleName;
    final roleIds = ensureList(t['roleIds']);
    if (roleIds.isEmpty) return '旁白';
    final names =
        roleIds.map((id) => _roleName(id)).where((n) => n.isNotEmpty).toList();
    return names.isEmpty ? 'NPC' : names.join('、');
  }

  String _roleName(String id) {
    final catalog = _roleCatalog[id];
    if (catalog != null && catalog.name.isNotEmpty) return catalog.name;
    final p = _personCfg[id];
    if (p is Map) {
      final n = p['name'];
      if (n is String && n.isNotEmpty) return n;
    }
    final gameRoles = widget.state.gameDicts['roles'];
    if (gameRoles is Map && gameRoles.containsKey(id)) {
      final n = gameRoles[id];
      if (n != null && n.toString().isNotEmpty) return n.toString();
    }
    return '';
  }

  /// 人物 ID → 当前阶段立绘 key（与经典处理器同规则：url=小学、url2=中学）。
  String _portraitKeyFor(String roleId) {
    final id = cln(roleId);
    if (id.isEmpty) return '';
    final r = _roleCatalog[id];
    if (r != null) {
      final p1 = r.portrait1.trim();
      final p2 = r.portrait2.trim();
      if (_stageIndex == 0) return p1.isNotEmpty ? p1 : p2;
      return p2.isNotEmpty ? p2 : p1;
    }
    final p = _personCfg[id];
    if (p is Map) {
      String firstOf(dynamic v) {
        if (v is List && v.isNotEmpty) return cln(v.first);
        return cln(v);
      }

      final p1 = firstOf(p['url']);
      final p2 = firstOf(p['url2']);
      if (_stageIndex == 0) return p1.isNotEmpty ? p1 : p2;
      return p2.isNotEmpty ? p2 : p1;
    }
    return '';
  }

  Map<String, String> _allBgs() {
    final map = <String, String>{};
    final gameBgs = widget.state.gameDicts['bgs'];
    if (gameBgs is Map) {
      for (final e in gameBgs.entries) {
        map[e.key.toString()] = e.value.toString();
      }
    }
    for (final e in _bgCfg.entries) {
      final name = e.value is Map ? (e.value as Map)['name'] : e.value;
      if (name != null && name.toString().isNotEmpty) {
        map[e.key.toString()] = name.toString();
      }
    }
    return map;
  }

  Map<String, String> _allAudios() {
    final map = <String, String>{};
    final gameAudios = widget.state.gameDicts['audios'];
    if (gameAudios is Map) {
      for (final e in gameAudios.entries) {
        map[e.key.toString()] = e.value.toString();
      }
    }
    for (final e in _audioCfg.entries) {
      final name = e.value is Map ? (e.value as Map)['name'] : e.value;
      if (name != null && name.toString().isNotEmpty) {
        map[e.key.toString()] = name.toString();
      }
    }
    return map;
  }

  Map<String, String> _allRoles() {
    final map = <String, String>{};
    final gameRoles = widget.state.gameDicts['roles'];
    if (gameRoles is Map) {
      for (final e in gameRoles.entries) {
        final k = e.key.toString().trim();
        if (k.isNotEmpty && k != '-1') map[k] = e.value.toString();
      }
    }
    for (final e in _personCfg.entries) {
      final k = e.key.toString().trim();
      if (k.isEmpty || k == '-1') continue;
      final p = e.value;
      if (p is Map && p['name'] != null && p['name'].toString().isNotEmpty) {
        map[k] = p['name'].toString();
      } else if (!map.containsKey(k)) {
        map[k] = '角色 $k';
      }
    }
    return map;
  }

  /// 当前事件对白候选（id · 内容预览），跳转目标选择用。
  List<(String, String)> _talkOptions() {
    final out = <(String, String)>[];
    for (final e in _stageTalks.entries) {
      final rec = e.value;
      final content = rec is Map ? cln(rec['content']) : '';
      final preview =
          content.length > 16 ? '${content.substring(0, 16)}…' : content;
      out.add((e.key, preview));
    }
    return out;
  }

  Future<List<String>?> _pickTalkTarget({
    String title = '选择跳转目标',
    bool multi = false,
    List<String> initial = const [],
  }) {
    return showIdBrowseDialog(
      context,
      title: title,
      options: _talkOptions(),
      multi: multi,
      initialSelected: initial,
    );
  }

  /// 说话人轮换：旁白 ↔ 本句候选角色（拾光「点名字换人」）。
  void _cycleSpeaker(Map<String, dynamic> talk) {
    final candidates = <String>{
      ...ensureList(talk['roleIds']),
      ..._parseSlots(talk).map((s) => s.roleId),
    }.where((s) => s.isNotEmpty && s != '-1').toList()
      ..sort(compareIds);
    final current = ensureList(talk['roleIds']);
    String? pick;
    if (current.isNotEmpty) {
      final idx = candidates.indexOf(cln(current.first));
      if (idx >= 0 && idx + 1 < candidates.length) pick = candidates[idx + 1];
    } else if (candidates.isNotEmpty) {
      pick = candidates.first;
    }
    setState(() {
      talk['roleIds'] =
          pick == null ? <dynamic>[] : <dynamic>[int.tryParse(pick) ?? pick];
      _dirty = true;
    });
  }

  // ---------- 站位/表情（roles '槽,人物,动作'） ----------

  List<_StudioRolePlacement> _parseSlots(Map<String, dynamic> talk) {
    final out = <_StudioRolePlacement>[];
    final raw = ensureList(talk['roles']);
    for (final r in raw) {
      final parts = r.split(',');
      if (parts.length < 2) continue;
      final slot = int.tryParse(parts[0].trim()) ?? 2;
      out.add(
        _StudioRolePlacement(
          slot: slot.clamp(0, 4),
          roleId: parts[1].trim(),
          action: parts.length > 2 && parts[2].trim().isNotEmpty
              ? parts[2].trim()
              : '3000',
        ),
      );
    }
    if (out.isEmpty) {
      // roles 为空时按 roleIds 默认摆放（与经典处理器同式：槽 1、3…）。
      var fallbackSlot = 1;
      for (final rid in ensureList(talk['roleIds'])) {
        if (rid.isEmpty || rid == '-1') continue;
        out.add(
          _StudioRolePlacement(
            slot: fallbackSlot % 5,
            roleId: rid,
            action: '3000',
          ),
        );
        fallbackSlot += 2;
      }
    }
    return out;
  }

  _StudioRolePlacement? _placementOf(
    List<_StudioRolePlacement> slots,
    String roleId,
  ) {
    for (final p in slots) {
      if (p.roleId == roleId) return p;
    }
    return null;
  }

  void _writeSlot(Map<String, dynamic> talk, _StudioRolePlacement p) {
    // 目标站位旧人物与本角色旧站位都清掉：一条对白里一个人只占一个站位。
    final roles = ensureList(talk['roles'])
        .where((r) => !r.startsWith('${p.slot},'))
        .toList();
    roles.removeWhere((r) {
      final parts = r.split(',');
      return parts.length >= 2 && parts[1].trim() == p.roleId;
    });
    roles.add('${p.slot},${p.roleId},${p.action}');
    talk['roles'] = roles;
    _dirty = true;
  }

  void _setEmotion(Map<String, dynamic> talk, String roleId, String code) {
    final slots = _parseSlots(talk);
    final cur = slots.where((s) => s.roleId == roleId).toList();
    final slot = cur.isEmpty ? 2 : cur.first.slot;
    _writeSlot(
      talk,
      _StudioRolePlacement(slot: slot, roleId: roleId, action: code),
    );
    setState(() {});
  }

  void _shiftPlacement(Map<String, dynamic> talk, _StudioRolePlacement p, int dir) {
    final next = p.slot + dir;
    if (next < 0 || next > 4) return;
    _writeSlot(
      talk,
      _StudioRolePlacement(slot: next, roleId: p.roleId, action: p.action),
    );
    setState(() {});
  }

  void _removePlacement(Map<String, dynamic> talk, String roleId) {
    final roles = ensureList(talk['roles']).where((r) {
      final parts = r.split(',');
      return !(parts.length >= 2 && parts[1].trim() == roleId);
    }).toList();
    talk['roles'] = roles;
    setState(() => _dirty = true);
  }

  static const _emotions = <(String, String)>[
    ('3000', '普通'),
    ('3001', '开心'),
    ('3002', '生气'),
    ('3003', '悲伤'),
    ('3004', '害羞'),
    ('3005', '惊讶'),
    ('3006', '得意'),
    ('3007', '叹气'),
  ];

  String _emotionName(String code) {
    for (final e in _emotions) {
      if (e.$1 == code) return e.$2;
    }
    return code.startsWith('30') ? '动作 $code' : code;
  }

  Future<void> _openTtsPanel(Map<String, dynamic> talk) async {
    final content = ((talk['content'] ?? talk['showTxt'])?.toString() ?? '')
        .trim();
    final role = cln(talk['roleName']).trim();
    final title = content.isNotEmpty
        ? (role.isNotEmpty ? '$role：$content' : content)
        : '';
    await showDialog(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => Center(
        child: TtsPanel(
          initText: content,
          initTitle: title,
          initTalkId: talk['id'] != null ? 'talk_${talk['id']}' : '',
        ),
      ),
    );
  }

  // ---------- 放置角色弹窗（拾光「点选后立即登场」） ----------

  Future<void> _showPlaceRoleDialog(
    int? slotIdx,
    Map<String, dynamic> talk,
  ) async {
    final allRoles = _allRoles();
    final personKeys = allRoles.keys.toList()
      ..sort(
        (a, b) => (int.tryParse(a) ?? 999999).compareTo(
          int.tryParse(b) ?? 999999,
        ),
      );
    String? placed;
    if (slotIdx != null) {
      for (final s in _parseSlots(talk)) {
        if (s.slot == slotIdx) {
          placed = s.roleId;
          break;
        }
      }
    }
    var selected = placed ?? (personKeys.isNotEmpty ? personKeys.first : '10');
    var actionCode = '3000';
    var slot = slotIdx ?? 2;

    await fluent.showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => fluent.ContentDialog(
          title: Text(slotIdx == null ? '人物登场' : '放置角色到 站位 $slotIdx'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('选择角色:', style: TextStyle(fontSize: 12)),
                const SizedBox(height: 6),
                fluent.ComboBox<String>(
                  value: personKeys.contains(selected) ? selected : null,
                  placeholder: const Text('请选择角色', style: TextStyle(fontSize: 12)),
                  isExpanded: true,
                  items: personKeys
                      .map(
                        (k) => fluent.ComboBoxItem(
                          value: k,
                          child: Text('[$k] ${allRoles[k] ?? '角色'}',
                              style: const TextStyle(fontSize: 12)),
                        ),
                      )
                      .toList(),
                  onChanged: (v) {
                    if (v != null) setDialogState(() => selected = v);
                  },
                ),
                if (slotIdx == null) ...[
                  const SizedBox(height: 10),
                  const Text('站位:', style: TextStyle(fontSize: 12)),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 6,
                    children: [0, 1, 2, 3, 4]
                        .map(
                          (s) => _StudioPill(
                            label: const ['左', '中左', '居中', '中右', '右'][s],
                            selected: slot == s,
                            onTap: () => setDialogState(() => slot = s),
                          ),
                        )
                        .toList(),
                  ),
                ],
                const SizedBox(height: 10),
                const Text('表情与动作 (30xx):', style: TextStyle(fontSize: 12)),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: _emotions
                      .map(
                        (e) => _StudioPill(
                          label: '${e.$2} (${e.$1})',
                          selected: actionCode == e.$1,
                          onTap: () => setDialogState(() => actionCode = e.$1),
                        ),
                      )
                      .toList(),
                ),
              ],
            ),
          ),
          actions: [
            // 直接从电脑选图导入并写进该角色立绘，省掉先导入再配人设。
            fluent.Button(
              onPressed: () async {
                await _importLocalPortrait(selected);
                if (ctx.mounted) setDialogState(() {});
              },
              child: const Text('从电脑选择立绘…'),
            ),
            fluent.Button(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('取消'),
            ),
            fluent.FilledButton(
              onPressed: () {
                setState(() {
                  _writeSlot(
                    talk,
                    _StudioRolePlacement(
                      slot: slot,
                      roleId: selected,
                      action: actionCode,
                    ),
                  );
                  // 登场即入说话人候选（友商「点选后立即登场」的顺手路径）。
                  final ids = ensureList(talk['roleIds']).map(cln).toList();
                  if (!ids.contains(selected) && selected != '-1') {
                    talk['roleIds'] = [
                      ...normalizeStoryIdList(talk['roleIds']),
                      int.tryParse(selected) ?? selected,
                    ];
                  }
                  _dirty = true;
                });
                Navigator.of(ctx).pop();
              },
              child: const Text('登场'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showSceneBgDialog(Map<String, dynamic> talk) async {
    final bgs = _allBgs();
    var current = cln(talk['bg']);
    await fluent.showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => fluent.ContentDialog(
          title: const Text('选择场景背景'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                fluent.ComboBox<String>(
                  value: bgs.containsKey(current) ? current : null,
                  placeholder: const Text('延续上文 / 默认背景',
                      style: TextStyle(fontSize: 12)),
                  isExpanded: true,
                  items: [
                    const fluent.ComboBoxItem(
                      value: '',
                      child: Text('延续上文 / 默认背景',
                          style: TextStyle(fontSize: 12)),
                    ),
                    ...bgs.entries.map(
                      (e) => fluent.ComboBoxItem(
                        value: e.key,
                        child: Text('${e.value} (${e.key})',
                            style: const TextStyle(fontSize: 12)),
                      ),
                    ),
                  ],
                  onChanged: (v) {
                    if (v != null) setDialogState(() => current = v);
                  },
                ),
                const SizedBox(height: 10),
                if (current.isNotEmpty && current != '0')
                  SizedBox(
                    height: 150,
                    child: BgIdThumb(
                      id: current,
                      width: double.infinity,
                      height: 150,
                    ),
                  )
                else
                  Text('空 = 延续前文背景，不切换',
                      style: TextStyle(fontSize: 11, color: palette.textHint)),
              ],
            ),
          ),
          actions: [
            // 直接从电脑选图并登记为背景：无需先到人物/背景页导入。
            fluent.Button(
              onPressed: () async {
                final id = await _importLocalBg();
                if (id != null && ctx.mounted) {
                  setDialogState(() {
                    current = '$id';
                    // 下拉项在打开对话框时已快照，这里补进新背景名，免得选不中。
                    final rec = _bgCfg['$id'];
                    final name =
                        (rec is Map ? rec['name'] : null)?.toString() ?? '';
                    bgs['$id'] = name.isEmpty ? '新背景 $id' : name;
                  });
                }
              },
              child: const Text('从电脑选择图片…'),
            ),
            fluent.Button(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('取消'),
            ),
            fluent.FilledButton(
              onPressed: () {
                setState(() {
                  talk['bg'] = current.isEmpty ? null : (int.tryParse(current) ?? current);
                  _dirty = true;
                });
                Navigator.of(ctx).pop();
              },
              child: const Text('应用'),
            ),
          ],
        ),
      ),
    );
  }

  /// 从电脑选一张图片导入当前 Mod，并登记为一条新的 BgCfg；返回新背景 id。
  ///
  /// 不需要预先导入：选中文件即自动落盘到 `Textures/` 并写 BgCfg，随后场景
  /// 对话框可直接应用该背景。取消 / 登记失败返回 null。
  Future<int?> _importLocalBg() async {
    final saved = await importLocalAssets(context, kind: 'image');
    if (!mounted || saved.isEmpty) return null;
    final key = texKeyOfImportedPath((saved.first['path'] ?? '').toString());
    if (key.isEmpty) return null;

    var maxId = 0;
    for (final k in _bgCfg.keys) {
      final n = int.tryParse(k);
      if (n != null && n > maxId) maxId = n;
    }
    final id = maxId + 1;
    final name = key.split('/').last;
    final updated = <String, dynamic>{
      ..._bgCfg,
      '$id': <String, dynamic>{'id': id, 'name': name, 'url': key},
    };
    final ok = await _putTableWithConflictCheck(
      'BgCfg',
      updated,
      expect: () => _bgMtimeNs,
      onMtime: (v) => _bgMtimeNs = v,
    );
    if (!ok || !mounted) return null;
    setState(() => _bgCfg = updated);
    return id;
  }

  /// 从电脑选一张图片导入并写进该角色的立绘（url=小学 / url2=中学）。
  ///
  /// 只写已有 PersonCfg 记录的角色；没有记录时不擅自新建（缺 name 等字段会
  /// 破坏游戏数据），改为提示先在人物表建角色。返回是否写入成功。
  Future<bool> _importLocalPortrait(String roleId) async {
    final id = cln(roleId);
    if (id.isEmpty) return false;
    final existing = _personCfg[id];
    if (existing is! Map) {
      _showInfo('无法设置立绘', '角色 $id 还没有 PersonCfg 记录，请先在人物表中创建该角色。');
      return false;
    }
    final saved = await importLocalAssets(context, kind: 'image');
    if (!mounted || saved.isEmpty) return false;
    final key = texKeyOfImportedPath((saved.first['path'] ?? '').toString());
    if (key.isEmpty) return false;

    final record = Map<String, dynamic>.from(existing);
    final field = _stageIndex == 0 ? 'url' : 'url2';
    final list =
        ensureList(record[field]).map(cln).where((e) => e.isNotEmpty).toList();
    if (!list.contains(key)) list.add(key);
    record[field] = list;
    final updated = <String, dynamic>{..._personCfg, id: record};
    final ok = await _putTableWithConflictCheck(
      'PersonCfg',
      updated,
      expect: () => _personMtimeNs,
      onMtime: (v) => _personMtimeNs = v,
    );
    if (!ok || !mounted) return false;
    setState(() => _personCfg = updated);
    return true;
  }

  // ---------- UI ----------

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return const Center(
        child: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (_error != null) {
      return Center(
        child: Text(
          '加载失败: $_error',
          style: TextStyle(color: palette.textSecondary, fontSize: 13),
        ),
      );
    }
    final talk = _curTalk;
    return Column(
      children: [
        _buildTopBar(),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(width: 272, child: _buildDialogueSidebar()),
              VerticalDivider(width: 1, color: palette.border),
              Expanded(
                child: KeyedSubtree(
                  key: ValueKey('studio-pane-$_evtId-$_talkId'),
                  child: talk == null ? _buildNoSelection() : _buildEditorColumn(talk),
                ),
              ),
              VerticalDivider(width: 1, color: palette.border),
              SizedBox(width: 292, child: _buildCastPanel(talk)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildTopBar() {
    final evtKeys = _evtCfg.keys.toList()..sort(compareEventIds);
    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: palette.bg,
        border: Border(bottom: BorderSide(color: palette.border)),
      ),
      child: Row(
        children: [
          const Text('🎬', style: TextStyle(fontSize: 15)),
          const SizedBox(width: 8),
          Text(
            '剧情舞台',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.bold,
              color: palette.textHigh,
            ),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: 170,
            height: 36,
            child: fluent.ComboBox<String>(
              value: evtKeys.contains(_evtId) ? _evtId : null,
              isExpanded: true,
              items: evtKeys.map((k) {
                final t = _evtTitle(k);
                return fluent.ComboBoxItem(
                  value: k,
                  child: Text('[$k] ${t.isEmpty ? '事件' : t}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11.5)),
                );
              }).toList(),
              onChanged: (v) {
                if (v != null) _selectEvent(v);
              },
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              _dirty ? '● 本事件有未保存的修改' : '已保存',
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11.5,
                color: _dirty ? palette.warning : palette.textMuted,
              ),
            ),
          ),
          _StudioPill(
            label: '显示 ID',
            selected: _showIds,
            onTap: () => setState(() => _showIds = !_showIds),
          ),
          const SizedBox(width: 6),
          _StudioPill(
            label: '▶ 运行预览',
            onTap: () {
              final evtId = _evtId;
              if (evtId != null) widget.onPreview?.call(evtId);
            },
          ),
          const SizedBox(width: 6),
          _StudioPill(
            label: '💾 保存',
            selected: _dirty,
            onTap: _save,
          ),
        ],
      ),
    );
  }

  // ---------- 左栏：对话线（对话夹树） ----------

  Widget _buildDialogueSidebar() {
    final allIds = _stageTalks.keys.toList()..sort(compareIds);
    final query = _search.trim().toLowerCase();
    final List<StudioTreeItem> shown;
    if (query.isEmpty) {
      shown = applyStudioCollapse(
        buildStudioTree(
          evtId: _evtId ?? '',
          evtCfg: _evtCfg,
          talks: _stageTalks,
          options: _stageOpts,
        ),
        _collapsedFolders,
      );
    } else {
      shown = [
        for (final id in allIds)
          if (_talkMatchesQuery(id, query))
            StudioTreeItem(kind: StudioItemKind.talk, depth: 0, id: id),
      ];
    }

    return Column(
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 6),
          decoration: BoxDecoration(
            color: palette.panel,
            border: Border(bottom: BorderSide(color: palette.surface)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '对话线（${allIds.length} 句）',
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.bold,
                        color: palette.textHigh,
                      ),
                    ),
                  ),
                  if (_selectedTalkIds.length > 1)
                    Text(
                      '选中 ${_selectedTalkIds.length}',
                      style: TextStyle(fontSize: 10.5, color: palette.accentLight),
                    ),
                ],
              ),
              const SizedBox(height: 6),
              SizedBox(
                height: 30,
                child: fluent.TextBox(
                  placeholder: '🔍 搜索 ID / 台词 / 说话人',
                  style: const TextStyle(fontSize: 11.5),
                  controller: _searchCtrl,
                  onChanged: (v) => setState(() => _search = v),
                ),
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(
                    child: _StudioPill(
                      label: '＋ 添加对话',
                      selected: true,
                      onTap: _appendTalk,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: _StudioPill(
                      label: '⬇ 插入选中后',
                      onTap: _talkId == null ? null : _insertTalk,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        Expanded(
          child: shown.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        FluentIcons.chat_empty_24_regular,
                        size: 30,
                        color: palette.iconDisabled,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        query.isEmpty ? '该事件暂无对话' : '没有匹配的对话',
                        style: TextStyle(fontSize: 12, color: palette.textHint),
                      ),
                      if (query.isEmpty && _evtId != null) ...[
                        const SizedBox(height: 10),
                        fluent.FilledButton(
                          onPressed: _appendTalk,
                          child: const Text('➕ 新建第一句'),
                        ),
                      ],
                    ],
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  itemCount: shown.length,
                  itemBuilder: (context, i) => _buildTreeItem(shown, i),
                ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          color: palette.bgAlt,
          child: Row(
            children: [
              Expanded(
                child: _StudioPill(
                  label: '⧉ 复制',
                  onTap: _selectedTalkIds.isEmpty ? null : _duplicateSelected,
                ),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: _StudioPill(
                  label: '🗑 删除',
                  danger: true,
                  onTap: _selectedTalkIds.isEmpty ? null : _deleteSelectedTalks,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  bool _talkMatchesQuery(String id, String query) {
    if (id.toLowerCase().contains(query)) return true;
    final t = _stageTalks[id];
    if (t is Map && cln(t['content']).toLowerCase().contains(query)) return true;
    return _talkDisplayName(id).toLowerCase().contains(query);
  }

  Widget _buildTreeItem(List<StudioTreeItem> all, int i) {
    final it = all[i];
    switch (it.kind) {
      case StudioItemKind.talk:
        return _buildTalkCard(it);
      case StudioItemKind.folder:
        return _buildFolderHeader(all, i, it);
      case StudioItemKind.tail:
        return _buildFolderTail(it);
      case StudioItemKind.ref:
        return _buildRefRow(it);
      case StudioItemKind.note:
        return Padding(
          padding: EdgeInsets.only(left: 14.0 + it.depth * 12, right: 8, top: 2, bottom: 2),
          child: Text(
            it.label,
            style: TextStyle(fontSize: 10.5, color: palette.textHint, fontStyle: FontStyle.italic),
          ),
        );
      case StudioItemKind.header:
        return Padding(
          padding: const EdgeInsets.fromLTRB(10, 10, 8, 4),
          child: Row(
            children: [
              Icon(FluentIcons.puzzle_piece_24_regular, size: 12, color: palette.textMuted),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  it.label,
                  style: TextStyle(fontSize: 10.5, color: palette.textMuted),
                ),
              ),
            ],
          ),
        );
    }
  }

  Widget _buildTalkCard(StudioTreeItem it) {
    final id = it.id;
    final talk = _stageTalks[id];
    final isCurrent = id == _talkId;
    final selected = _selectedTalkIds.contains(id);
    final opts = talk is Map ? normalizeStoryIdList(talk['option']) : const [];
    final hasCond = talk is Map &&
        normalizeStoryIdList(talk['check']).isNotEmpty &&
        normalizeStoryIdList(talk['nextTalk2']).isNotEmpty;
    final dotKey = _firstPortraitKey(talk);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _selectTalk(id),
        child: Container(
          margin: EdgeInsets.only(
            left: 6 + it.depth * 12,
            right: 6,
            top: 2,
            bottom: 2,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: selected ? palette.tintAccent : palette.panel,
            borderRadius: BorderRadius.circular(5),
            border: Border.all(
              color: isCurrent ? accentColor : palette.surface,
              width: isCurrent ? 1.5 : 1,
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 说话人圆点头像（拾光 speaker-dot）
              Container(
                width: 22,
                height: 22,
                margin: const EdgeInsets.only(right: 6, top: 1),
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: palette.card,
                ),
                child: dotKey.isEmpty
                    ? Icon(FluentIcons.person_24_regular,
                        size: 12, color: palette.textHint)
                    : TexThumb(keyName: dotKey, width: 22, height: 22, fit: BoxFit.cover),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        if (_showIds) ...[
                          Flexible(
                            child: Text(
                              id,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 9.5,
                                color: isCurrent
                                    ? palette.accentLight
                                    : palette.textMuted,
                              ),
                            ),
                          ),
                          const SizedBox(width: 4),
                        ],
                        Expanded(
                          child: Text(
                            _talkDisplayName(id),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.bold,
                              color: isCurrent
                                  ? palette.textHigh
                                  : palette.textPrimary,
                            ),
                          ),
                        ),
                        if (opts.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(left: 4),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 4, vertical: 1),
                              decoration: BoxDecoration(
                                color: palette.tintWarn,
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                '${opts.length}选',
                                style: TextStyle(
                                    fontSize: 9, color: palette.statusTan),
                              ),
                            ),
                          ),
                        if (hasCond)
                          Padding(
                            padding: const EdgeInsets.only(left: 4),
                            child: Icon(FluentIcons.branch_fork_24_regular,
                                size: 11, color: palette.warning),
                          ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      talk is Map ? cln(talk['content']) : '',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 10.5, color: palette.textMuted),
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

  String _firstPortraitKey(dynamic talk) {
    if (talk is! Map) return '';
    for (final id in ensureList(talk['roleIds'])) {
      final k = _portraitKeyFor(id);
      if (k.isNotEmpty) return k;
    }
    for (final s in _parseSlots(talk.cast<String, dynamic>())) {
      final k = _portraitKeyFor(s.roleId);
      if (k.isNotEmpty) return k;
    }
    return '';
  }

  Widget _buildFolderHeader(
    List<StudioTreeItem> all,
    int i,
    StudioTreeItem it,
  ) {
    final collapsed = _collapsedFolders.contains(it.id);
    // 子树句数：向下扫描到下一个不更深的条目为止。
    var count = 0;
    for (var j = i + 1; j < all.length && all[j].depth > it.depth; j++) {
      if (all[j].kind == StudioItemKind.talk) count++;
    }
    final conditional = it.id.startsWith('cond:') || it.id.endsWith(':fail');
    final accent = conditional ? palette.warning : const Color(0xFF527C63);
    return Padding(
      padding: EdgeInsets.only(left: 6 + it.depth * 12, right: 6, top: 3),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            setState(() {
              if (collapsed) {
                _collapsedFolders.remove(it.id);
              } else {
                _collapsedFolders.add(it.id);
              }
            });
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
            decoration: BoxDecoration(
              border: Border(
                left: BorderSide(color: accent, width: 2),
              ),
              color: palette.card,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Row(
              children: [
                Icon(
                  collapsed
                      ? FluentIcons.chevron_right_24_regular
                      : FluentIcons.chevron_down_24_regular,
                  size: 11,
                  color: palette.textMuted,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    it.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: conditional ? palette.warning : palette.textSecondary,
                    ),
                  ),
                ),
                Text(
                  '$count 句',
                  style: TextStyle(fontSize: 9.5, color: palette.textHint),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFolderTail(StudioTreeItem it) {
    final Map<String, dynamic>? record = it.field == 'nextTalk2'
        ? (_stageTalks[it.ownerId] is Map
            ? (_stageTalks[it.ownerId] as Map).cast<String, dynamic>()
            : null)
        : (_stageOpts[it.ownerId] is Map
            ? (_stageOpts[it.ownerId] as Map).cast<String, dynamic>()
            : null);
    final target =
        record == null ? '' : _firstTarget(record[it.field]);
    final preview =
        target.isEmpty || _stageTalks[target] is! Map
            ? '未设置'
            : cln((_stageTalks[target] as Map)['content']);
    final prefix = it.field == 'talkId2'
        ? '判定失败后进入'
        : (it.field == 'nextTalk2' ? '失败后进入' : '对话夹结束后');
    return Padding(
      padding: EdgeInsets.only(left: 14 + it.depth * 12, right: 8, top: 1, bottom: 3),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _pickFolderTail(it),
          child: Row(
            children: [
              Icon(FluentIcons.arrow_step_in_24_regular,
                  size: 10, color: palette.iconDisabled),
              const SizedBox(width: 5),
              Text(
                '$prefix：',
                style: TextStyle(fontSize: 9.5, color: palette.textHint),
              ),
              Flexible(
                child: Text(
                  target.isEmpty ? '未设置' : '[$target] ${preview.isEmpty ? '…' : preview}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 9.5,
                    color: target.isEmpty ? palette.iconDisabled : palette.accentLighter,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRefRow(StudioTreeItem it) {
    final exists = _stageTalks.containsKey(it.id);
    final label = it.label.isEmpty ? '↗ 接续' : it.label;
    return Padding(
      padding: EdgeInsets.only(left: 14 + it.depth * 12, right: 8, top: 1, bottom: 1),
      child: MouseRegion(
        cursor: exists ? SystemMouseCursors.click : SystemMouseCursors.basic,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: exists ? () => _selectTalk(it.id) : null,
          child: Row(
            children: [
              Text(label,
                  style: TextStyle(fontSize: 9.5, color: palette.textHint)),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  exists
                      ? '[${it.id}] ${_talkDisplayName(it.id)}'
                      : '[${it.id}]（不在本场）',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 9.5,
                    color: exists ? palette.accentLighter : palette.danger,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---------- 中栏：舞台 + 本句分区 ----------

  Widget _buildNoSelection() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(FluentIcons.video_24_regular, size: 34, color: palette.iconDisabled),
          const SizedBox(height: 10),
          Text(
            _stageTalks.isEmpty
                ? '点左侧「＋ 添加对话」写第一句台词'
                : '在左侧对话线中选择一句开始编辑',
            style: TextStyle(fontSize: 12.5, color: palette.textHint),
          ),
        ],
      ),
    );
  }

  Widget _buildEditorColumn(Map<String, dynamic> talk) {
    return ListView(
      padding: const EdgeInsets.all(10),
      children: [
        _buildSceneStage(talk),
        const SizedBox(height: 10),
        _buildOptionsSection(talk),
        const SizedBox(height: 10),
        _buildFlowSection(talk),
        const SizedBox(height: 10),
        _buildAudioSection(talk),
        const SizedBox(height: 10),
        _buildEffectSection(talk),
        const SizedBox(height: 10),
        _buildRawSection(talk),
        const SizedBox(height: 10),
      ],
    );
  }

  /// 可编辑游戏画面：背景 + 5 站位立绘 + 对话框内直接写台词。
  Widget _buildSceneStage(Map<String, dynamic> talk) {
    final bgVal = cln(talk['bg']);
    final bgName = _allBgs()[bgVal] ?? '';
    final slots = _parseSlots(talk);
    final slotMap = <int, _StudioRolePlacement>{
      for (final p in slots) p.slot: p,
    };
    final highlights = ensureList(talk['highlights']).map(cln).toSet();
    final speakerIds = ensureList(talk['roleIds']).map(cln).toList();

    return Container(
      decoration: BoxDecoration(
        color: palette.panel,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: palette.surface),
      ),
      padding: const EdgeInsets.all(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 舞台上方工具行：学段 + 说话人 chips + 素材按钮（人物登场/场景）
          Row(
            children: [
              for (var s = 0; s < _stages.length; s++) ...[
                _StudioPill(
                  label: _stages[s],
                  selected: _stageIndex == s,
                  onTap: () => setState(() => _stageIndex = s),
                ),
                const SizedBox(width: 4),
              ],
              const SizedBox(width: 6),
              _StudioPill(
                label: '👤 人物登场',
                onTap: () => _showPlaceRoleDialog(null, talk),
              ),
              const SizedBox(width: 4),
              _StudioPill(
                label: '🖼 场景',
                onTap: () => _showSceneBgDialog(talk),
              ),
              const Spacer(),
              Text(
                bgVal.isEmpty
                    ? '延续上文背景'
                    : '背景 ${bgName.isEmpty ? bgVal : bgName}',
                style: TextStyle(fontSize: 10.5, color: palette.textHint),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // 说话人 chips
          Wrap(
            spacing: 5,
            runSpacing: 4,
            children: [
              ...speakerIds.map(
                (rid) => Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                  decoration: BoxDecoration(
                    color: palette.tintAccent,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: palette.accentDeep),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _roleName(rid).isEmpty ? '[$rid]' : _roleName(rid),
                        style: TextStyle(
                            fontSize: 10.5, color: palette.accentPale),
                      ),
                      const SizedBox(width: 4),
                      MouseRegion(
                        cursor: SystemMouseCursors.click,
                        child: GestureDetector(
                          onTap: () {
                            setState(() {
                              talk['roleIds'] = normalizeStoryIdList(
                                      talk['roleIds'])
                                  .where((e) => cln(e) != rid)
                                  .toList();
                              _dirty = true;
                            });
                          },
                          child: Icon(FluentIcons.dismiss_16_regular,
                              size: 10, color: palette.accentPale),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              _StudioPill(
                label: '＋说话人',
                onTap: () async {
                  final ids = await showRolePickerDialog(context, multi: true);
                  if (ids == null || ids.isEmpty) return;
                  setState(() {
                    talk['roleIds'] = <dynamic>[
                      ...normalizeStoryIdList(talk['roleIds']),
                      ...ids.map((e) => int.tryParse(e) ?? e),
                    ];
                    _dirty = true;
                  });
                },
              ),
              if (speakerIds.isEmpty)
                Text(
                  '旁白（无名说话）',
                  style: TextStyle(fontSize: 10.5, color: palette.textHint),
                ),
            ],
          ),
          const SizedBox(height: 8),
          // 模拟游戏画面
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Container(
              height: 300,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [palette.bgDeep, palette.bgDeep2],
                ),
              ),
              child: Stack(
                children: [
                  if (bgVal.isNotEmpty && bgVal != '0')
                    Positioned.fill(
                      child: BgIdThumb(
                        id: bgVal,
                        width: double.infinity,
                        height: 300,
                      ),
                    ),
                  // 站位立绘
                  Positioned.fill(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: List.generate(5, (slotIdx) {
                          final p = slotMap[slotIdx];
                          if (p == null) return const Spacer();
                          final key = _portraitKeyFor(p.roleId);
                          final hl = highlights.contains(p.roleId);
                          return Expanded(
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 2),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (key.isNotEmpty)
                                    TexThumb(
                                      key: ValueKey('studio-pp-${p.roleId}-$key'),
                                      keyName: key,
                                      height: 190,
                                      fit: BoxFit.contain,
                                    )
                                  else
                                    SizedBox(
                                      height: 60,
                                      child: Center(
                                        child: Icon(FluentIcons.person_24_filled,
                                            size: 32,
                                            color: hl
                                                ? palette.accentLight
                                                : palette.textHint),
                                      ),
                                    ),
                                  MouseRegion(
                                    cursor: SystemMouseCursors.click,
                                    child: GestureDetector(
                                      onTap: () =>
                                          _showSlotActionDialog(talk, p),
                                      child: Container(
                                        margin: const EdgeInsets.only(top: 2, bottom: 4),
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 6, vertical: 2),
                                        decoration: BoxDecoration(
                                          color: hl
                                              ? palette.tintAccent
                                              : palette.card
                                                  .withValues(alpha: 0.85),
                                          borderRadius:
                                              BorderRadius.circular(8),
                                          border: hl
                                              ? Border.all(color: accentColor)
                                              : null,
                                        ),
                                        child: Text(
                                          '${_roleName(p.roleId).isEmpty ? p.roleId : _roleName(p.roleId)} · ${_emotionName(p.action)}',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                              fontSize: 9.5,
                                              color: palette.textHigh),
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        }),
                      ),
                    ),
                  ),
                  // 对话框：台词打在游戏画面里（WYSIWYG）
                  Positioned(
                    left: 14,
                    right: 14,
                    bottom: 10,
                    child: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.55),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                            color: Colors.white.withValues(alpha: 0.18)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          MouseRegion(
                            cursor: SystemMouseCursors.click,
                            child: GestureDetector(
                              onTap: () => _cycleSpeaker(talk),
                              child: Text(
                                '${_talkDisplayName(_talkId ?? '')} ▸',
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                  color: Color(0xFFFFD27D),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 4),
                          _StudioTextField(
                            value: talk['content']?.toString() ?? '',
                            maxLines: 3,
                            placeholder: '把台词直接打在这里…',
                            style: const TextStyle(
                                fontSize: 12.5, color: Colors.white),
                            onChanged: (v) {
                              talk['content'] = v;
                              _markDirty();
                            },
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Text(
                '显示名称：',
                style: TextStyle(fontSize: 11, color: palette.textSecondary),
              ),
              Expanded(
                child: _StudioTextField(
                  value: talk['roleName']?.toString() ?? '',
                  placeholder: '如「？？？」（空 = 用人物本名）',
                  style: const TextStyle(fontSize: 11.5),
                  onChanged: (v) {
                    talk['roleName'] = v;
                    _markDirty();
                  },
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ---------- 对话选项 ----------

  Widget _buildOptionsSection(Map<String, dynamic> talk) {
    final optIds = <String>{};
    for (final o in normalizeStoryIdList(talk['option'])) {
      final s = cln(o);
      if (s.isNotEmpty) optIds.add(s);
    }
    return _StudioSection(
      icon: FluentIcons.select_all_on_24_regular,
      title: '对话选项',
      subtitle: '${optIds.length} 个选项',
      actions: [
        _StudioPill(label: '＋ 添加选项', selected: true, onTap: _addOption),
      ],
      child: optIds.isEmpty
          ? Text(
              '本句没有选项：玩家点击画面顺序接续。',
              style: TextStyle(fontSize: 11, color: palette.textHint),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final optId in optIds)
                  _StudioOptionCard(
                    key: ValueKey('studio-opt-$optId'),
                    optId: optId,
                    opt: _stageOpts[optId],
                    talkOptions: _talkOptions(),
                    noCode: _noCode,
                    gameDicts: widget.state.gameDicts,
                    onChanged: _markDirty,
                    onRemove: () => _removeOption(optId),
                    onPickTarget: ({List<String> initial = const []}) =>
                        _pickTalkTarget(title: '选择跳转目标', initial: initial),
                  ),
              ],
            ),
    );
  }

  // ---------- 接续与条件分支 ----------

  Widget _buildFlowSection(Map<String, dynamic> talk) {
    final nexts =
        normalizeStoryIdList(talk['nextTalk']).map(cln).where((s) => s.isNotEmpty).toList();
    final nextLabel = nexts.isEmpty
        ? '顺序顺延（下一编号）'
        : nexts.map((s) {
            final t = _stageTalks[s];
            final c = t is Map ? cln(t['content']) : '';
            return '[$s]${c.isEmpty ? '' : ' ${c.length > 10 ? '${c.substring(0, 10)}…' : c}'}';
          }).join('，');
    final hasCheck = normalizeStoryIdList(talk['check']).isNotEmpty;

    return _StudioSection(
      icon: FluentIcons.branch_fork_24_regular,
      title: '接续与条件分支',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '主线接续：$nextLabel',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11.5, color: palette.textSecondary),
                ),
              ),
              _StudioPill(
                label: '设为主接续',
                onTap: () async {
                  final ids = await _pickTalkTarget(
                    title: '选择下一句',
                    initial: nexts,
                  );
                  if (ids == null || !mounted) return;
                  setState(() {
                    talk['nextTalk'] =
                        ids.map((e) => int.tryParse(e) ?? e).toList();
                    _dirty = true;
                  });
                },
              ),
              const SizedBox(width: 4),
              _StudioPill(
                label: '清空',
                onTap: nexts.isEmpty
                    ? null
                    : () => setState(() {
                          talk['nextTalk'] = <dynamic>[];
                          _dirty = true;
                        }),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              fluent.Checkbox(
                checked: hasCheck,
                onChanged: (v) {
                  setState(() {
                    talk['check'] =
                        (v ?? false) ? <dynamic>['has_score>=60'] : <dynamic>[];
                    _dirty = true;
                  });
                },
                content: Text('开启前提判定',
                    style: TextStyle(fontSize: 11.5, color: palette.textMid)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Row(
                  children: [
                    Text('判定失败后 → ',
                        style:
                            TextStyle(fontSize: 11.5, color: palette.textSecondary)),
                    Expanded(
                      child: _targetField(
                        talk,
                        'nextTalk2',
                        empty: '（不跳转）',
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// talk 上的单个跳转目标字段（无代码=浏览按钮，普通=ID 文本）。
  Widget _targetField(
    Map<String, dynamic> talk,
    String field, {
    String empty = '（空 = 顺延）',
  }) {
    final value = normalizeStoryIdList(talk[field]).map(cln).join(',');
    if (_noCode) {
      return NoCodeRefField(
        value: value.isEmpty ? '' : value,
        pickLabel: '选…',
        emptyText: empty,
        compact: true,
        nameOf: (id) {
          for (final e in _talkOptions()) {
            if (e.$1 == id) return e.$2.isEmpty ? null : e.$2;
          }
          return null;
        },
        onPick: () async {
          final ids = await _pickTalkTarget(
            title: '选择跳转目标',
            initial: normalizeStoryIdList(talk[field]).map(cln).toList(),
          );
          if (ids == null || !mounted) return;
          setState(() {
            talk[field] = ids.map((e) => int.tryParse(e) ?? e).toList();
            _dirty = true;
          });
        },
        onDisableNoCode: () => exitNoCodeMode(context),
      );
    }
    return _StudioTextField(
      value: value,
      placeholder: '对话 ID，逗号分隔；$empty',
      style: const TextStyle(fontSize: 11.5),
      onChanged: (v) {
        talk[field] = v
            .split(',')
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty)
            .map((s) => int.tryParse(s) ?? s)
            .toList();
        _markDirty();
      },
    );
  }

  // ---------- 音频与 BGM ----------

  Widget _buildAudioSection(Map<String, dynamic> talk) {
    final bgVal = cln(talk['bg']);
    final audioVal = cln(talk['audio']);
    final bgs = _allBgs();
    final audios = _allAudios();
    return _StudioSection(
      icon: FluentIcons.speaker_2_24_regular,
      title: '音频与 BGM',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              SizedBox(
                width: 56,
                child: Text('背景 bg',
                    style: TextStyle(fontSize: 11.5, color: palette.textSecondary)),
              ),
              Expanded(
                child: SizedBox(
                  height: 36,
                  child: fluent.ComboBox<String>(
                    value: bgs.containsKey(bgVal) ? bgVal : null,
                    placeholder: const Text('延续上文 / 默认背景',
                        style: TextStyle(fontSize: 11.5)),
                    isExpanded: true,
                    items: [
                      const fluent.ComboBoxItem(
                        value: '',
                        child: Text('延续上文 / 默认背景',
                            style: TextStyle(fontSize: 11.5)),
                      ),
                      ...bgs.entries.map(
                        (e) => fluent.ComboBoxItem(
                          value: e.key,
                          child: Text('${e.value} (${e.key})',
                              style: const TextStyle(fontSize: 11.5)),
                        ),
                      ),
                    ],
                    onChanged: (v) {
                      setState(() {
                        talk['bg'] =
                            (v == null || v.isEmpty) ? null : (int.tryParse(v) ?? v);
                        _dirty = true;
                      });
                    },
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              SizedBox(
                width: 56,
                child: Text('BGM',
                    style: TextStyle(fontSize: 11.5, color: palette.textSecondary)),
              ),
              Expanded(
                child: SizedBox(
                  height: 36,
                  child: fluent.ComboBox<String>(
                    value: audios.containsKey(audioVal) ? audioVal : null,
                    placeholder: const Text('[延续上文/无更改]',
                        style: TextStyle(fontSize: 11.5)),
                    isExpanded: true,
                    items: [
                      const fluent.ComboBoxItem(
                        value: '',
                        child: Text('[延续上文/无更改]',
                            style: TextStyle(fontSize: 11.5)),
                      ),
                      ...audios.entries.map(
                        (e) => fluent.ComboBoxItem(
                          value: e.key,
                          child: Text('${e.value} (${e.key})',
                              style: const TextStyle(fontSize: 11.5)),
                        ),
                      ),
                    ],
                    onChanged: (v) {
                      setState(() {
                        talk['audio'] =
                            (v == null || v.isEmpty) ? null : (int.tryParse(v) ?? v);
                        _dirty = true;
                      });
                    },
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ---------- 本句效果 ----------

  Widget _buildEffectSection(Map<String, dynamic> talk) {
    return _StudioSection(
      icon: FluentIcons.sparkle_24_regular,
      title: '本句效果',
      subtitle: '达成/失败两路',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_noCode) ...[
            NoCodeEffectField(
              value: talk['effect'],
              type: '2D Array',
              cfg: 'TalkCfg',
              fieldKey: 'effect',
              gameDicts: widget.state.gameDicts,
              onChanged: (v) {
                talk['effect'] = v;
                _markDirty();
                setState(() {});
              },
              onDisableNoCode: () => exitNoCodeMode(context),
            ),
            const SizedBox(height: 8),
            NoCodeEffectField(
              value: talk['effect2'],
              type: '2D Array',
              cfg: 'TalkCfg',
              fieldKey: 'effect2',
              gameDicts: widget.state.gameDicts,
              onChanged: (v) {
                talk['effect2'] = v;
                _markDirty();
                setState(() {});
              },
              onDisableNoCode: () => exitNoCodeMode(context),
            ),
          ] else ...[
            _codecField(talk, 'effect', '达成效果 effect（2D Array）'),
            const SizedBox(height: 6),
            _codecField(talk, 'effect2', '失败效果 effect2（2D Array）'),
          ],
        ],
      ),
    );
  }

  Widget _codecField(Map<String, dynamic> talk, String field, String hint) {
    return _StudioTextField(
      value: ValueCodec.encode(talk[field]),
      placeholder: hint,
      style: const TextStyle(fontSize: 11.5),
      onChanged: (v) {
        try {
          talk[field] = ValueCodec.decode(v, '2D Array');
        } catch (_) {
          talk[field] = v;
        }
        _markDirty();
      },
    );
  }

  // ---------- 动作指令兜底（原文） ----------

  Widget _buildRawSection(Map<String, dynamic> talk) {
    return _CollapsibleSection(
      icon: FluentIcons.code_24_regular,
      title: '动作指令与更多字段（原文兜底）',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('人物动作 roles（分号分隔：站位,人物,动作码）',
              style: TextStyle(fontSize: 11, color: palette.textSecondary)),
          const SizedBox(height: 4),
          if (_noCode)
            NoCodeEffectField(
              value: _rolesTo2d(talk['roles']),
              type: '2D Array',
              cfg: 'TalkCfg',
              fieldKey: 'roles',
              mode: 'action',
              gameDicts: widget.state.gameDicts,
              onChanged: (v) {
                talk['roles'] = _rolesFrom2d(v);
                _markDirty();
                setState(() {});
              },
              onDisableNoCode: () => exitNoCodeMode(context),
            )
          else
            _StudioTextField(
              value: ensureList(talk['roles']).join(';'),
              placeholder: '如 0,10,3001;3,12,3000',
              style: const TextStyle(fontSize: 11.5),
              onChanged: (v) {
                talk['roles'] = v
                    .split(';')
                    .map((s) => s.trim())
                    .where((s) => s.isNotEmpty)
                    .toList();
                _markDirty();
              },
            ),
          const SizedBox(height: 8),
          Text('屏幕效果 screenEffect（40xx/关键字）',
              style: TextStyle(fontSize: 11, color: palette.textSecondary)),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: _StudioTextField(
                  value: talk['screenEffect']?.toString() ?? '',
                  placeholder: '如 抖动 / 闪白 / CG名字…',
                  style: const TextStyle(fontSize: 11.5),
                  onChanged: (v) {
                    talk['screenEffect'] = v;
                    _markDirty();
                  },
                ),
              ),
              const SizedBox(width: 6),
              ...['抖动', '闪白', '黑屏', '淡入', 'CG特写'].map(
                (tag) => Padding(
                  padding: const EdgeInsets.only(left: 2),
                  child: _StudioPill(
                    label: tag,
                    onTap: () {
                      talk['screenEffect'] = tag;
                      _markDirty();
                      setState(() {});
                    },
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              SizedBox(
                width: 150,
                child: _codecField(talk, 'miniGame', '小游戏 miniGame'),
              ),
              SizedBox(
                width: 150,
                child: _codecField(talk, 'replace', '替换 replace'),
              ),
              SizedBox(
                width: 150,
                child: _codecField(talk, 'vocals', '人声 vocals'),
              ),
              SizedBox(
                width: 110,
                child: _numField(talk, 'maxoptions', '最大选项数'),
              ),
              SizedBox(
                width: 110,
                child: _numField(talk, 'time', '时间'),
              ),
              SizedBox(
                width: 220,
                child: _StudioTextField(
                  value: talk['showTxt']?.toString() ?? '',
                  placeholder: '悬浮提示 showTxt',
                  style: const TextStyle(fontSize: 11.5),
                  onChanged: (v) {
                    talk['showTxt'] = v;
                    _markDirty();
                  },
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _numField(Map<String, dynamic> talk, String field, String label) {
    return _StudioTextField(
      value: (talk[field] ?? '').toString(),
      placeholder: label,
      style: const TextStyle(fontSize: 11.5),
      onChanged: (v) {
        final n = num.tryParse(v.trim());
        talk[field] = n ?? (v.trim().isEmpty ? null : v);
        _markDirty();
      },
    );
  }

  static List<List<String>> _rolesTo2d(dynamic v) {
    final out = <List<String>>[];
    for (final item in ensureList(v)) {
      final parts = item.split(',').map((e) => e.trim()).toList();
      if (parts.length >= 3) out.add([parts[0], parts[1], parts[2]]);
    }
    return out;
  }

  static List<String> _rolesFrom2d(dynamic v) {
    final out = <String>[];
    if (v is List) {
      for (final row in v) {
        if (row is List && row.length >= 3) {
          out.add(row.take(3).map((e) => e.toString()).join(','));
        }
      }
    }
    return out;
  }

  // ---------- 站位动作弹窗 ----------

  Future<void> _showSlotActionDialog(
    Map<String, dynamic> talk,
    _StudioRolePlacement p,
  ) async {
    await fluent.showDialog<void>(
      context: context,
      builder: (ctx) => fluent.ContentDialog(
        title: Text('角色 [${p.roleId}] 的表情与站位'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: _emotions
                  .map(
                    (e) => _StudioPill(
                      label: '${e.$2} (${e.$1})',
                      selected: p.action == e.$1,
                      onTap: () {
                        _setEmotion(talk, p.roleId, e.$1);
                        Navigator.of(ctx).pop();
                      },
                    ),
                  )
                  .toList(),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                _StudioPill(
                  label: '◀ 左移',
                  onTap: p.slot > 0
                      ? () {
                          _shiftPlacement(talk, p, -1);
                          Navigator.of(ctx).pop();
                        }
                      : null,
                ),
                const SizedBox(width: 6),
                _StudioPill(
                  label: '右移 ▶',
                  onTap: p.slot < 4
                      ? () {
                          _shiftPlacement(talk, p, 1);
                          Navigator.of(ctx).pop();
                        }
                      : null,
                ),
                const SizedBox(width: 6),
                _StudioPill(
                  label: '高亮',
                  onTap: () {
                    setState(() {
                      final h = ensureList(talk['highlights'])
                          .map(cln)
                          .toList();
                      if (h.contains(p.roleId)) {
                        h.remove(p.roleId);
                      } else {
                        h.add(p.roleId);
                      }
                      talk['highlights'] =
                          h.map((e) => int.tryParse(e) ?? e).toList();
                      _dirty = true;
                    });
                    Navigator.of(ctx).pop();
                  },
                ),
                const Spacer(),
                _StudioPill(
                  label: '移除此句站位',
                  danger: true,
                  onTap: () {
                    _removePlacement(talk, p.roleId);
                    Navigator.of(ctx).pop();
                  },
                ),
              ],
            ),
          ],
        ),
        actions: [
          fluent.Button(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  // ---------- 右栏：人物与表情 ----------

  Widget _buildCastPanel(Map<String, dynamic>? talk) {
    final placements =
        talk == null ? const <_StudioRolePlacement>[] : _parseSlots(talk);
    final castIds = <String>{
      ...ensureList(talk?['roleIds'] ?? '').map(cln),
      ...placements.map((p) => p.roleId),
    }.where((s) => s.isNotEmpty && s != '-1').toList()
      ..sort(compareIds);
    final inspect = _inspectRoleId != null && castIds.contains(_inspectRoleId)
        ? _inspectRoleId!
        : (castIds.isEmpty ? '' : castIds.first);
    final placement = _placementOf(placements, inspect);
    final key = inspect.isEmpty ? '' : _portraitKeyFor(inspect);
    final highlights = talk == null
        ? <String>{}
        : ensureList(talk['highlights']).map(cln).toSet();

    return Container(
      color: palette.bg,
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '人物与表情',
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.bold,
              color: palette.textHigh,
            ),
          ),
          const SizedBox(height: 6),
          if (castIds.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 18),
              child: Text(
                '本句没有在场人物（旁白）。\n用中栏「👤 人物登场」或「＋说话人」添加。',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11, color: palette.textHint, height: 1.6),
              ),
            )
          else
            Wrap(
              spacing: 5,
              runSpacing: 5,
              children: castIds
                  .map(
                    (id) => MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: GestureDetector(
                        onTap: () => setState(() => _inspectRoleId = id),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: id == inspect
                                ? palette.tintAccent
                                : palette.card,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: id == inspect ? accentColor : palette.borderHover,
                            ),
                          ),
                          child: Text(
                            _roleName(id).isEmpty ? '[$id]' : _roleName(id),
                            style: TextStyle(
                              fontSize: 11,
                              color: id == inspect
                                  ? palette.accentPale
                                  : palette.textPrimary,
                            ),
                          ),
                        ),
                      ),
                    ),
                  )
                  .toList(),
            ),
          if (inspect.isNotEmpty) ...[
            const SizedBox(height: 10),
            Container(
              height: 220,
              width: double.infinity,
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: palette.bgAlt,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: palette.surface),
              ),
              child: key.isEmpty
                  ? Center(
                      child: Icon(FluentIcons.person_24_filled,
                          size: 42, color: palette.textHint),
                    )
                  : TexThumb(
                      key: ValueKey('studio-inspect-$inspect-$key'),
                      keyName: key,
                      width: double.infinity,
                      height: 220,
                      fit: BoxFit.contain,
                    ),
            ),
            const SizedBox(height: 4),
            Text(
              '[$inspect] ${_roleName(inspect)} · ${placement == null ? '未站在场上' : '站位 ${placement.slot}'}',
              style: TextStyle(fontSize: 10.5, color: palette.textMuted),
            ),
            const SizedBox(height: 10),
            Text('表情速涂（点一下写入本句动作）',
                style: TextStyle(
                    fontSize: 11, color: palette.textSecondary)),
            const SizedBox(height: 6),
            Wrap(
              spacing: 5,
              runSpacing: 5,
              children: _emotions
                  .map(
                    (e) => _StudioPill(
                      label: e.$2,
                      hint: e.$1,
                      selected: placement?.action == e.$1,
                      onTap: talk == null
                          ? null
                          : () => _setEmotion(talk, inspect, e.$1),
                    ),
                  )
                  .toList(),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: _StudioPill(
                    label: '◀ 左移',
                    onTap: placement == null || talk == null
                        ? null
                        : () => _shiftPlacement(talk, placement, -1),
                  ),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: _StudioPill(
                    label: '右移 ▶',
                    onTap: placement == null || talk == null
                        ? null
                        : () => _shiftPlacement(talk, placement, 1),
                  ),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: _StudioPill(
                    label: highlights.contains(inspect) ? '取消高亮' : '高亮',
                    selected: highlights.contains(inspect),
                    onTap: talk == null
                        ? null
                        : () {
                            setState(() {
                              final h =
                                  ensureList(talk['highlights']).map(cln).toList();
                              if (h.contains(inspect)) {
                                h.remove(inspect);
                              } else {
                                h.add(inspect);
                              }
                              talk['highlights'] =
                                  h.map((e) => int.tryParse(e) ?? e).toList();
                              _dirty = true;
                            });
                          },
                  ),
                ),
              ],
            ),
          ],
          const Spacer(),
          SizedBox(
            width: double.infinity,
            child: fluent.FilledButton(
              onPressed: talk == null
                  ? null
                  : () {
                      final t = talk;
                      _openTtsPanel(t);
                    },
              style: fluent.ButtonStyle(
                backgroundColor: WidgetStatePropertyAll(palette.warning),
              ),
              child: const Text('🎙️ 给本行配音'),
            ),
          ),
          const SizedBox(height: 6),
          SizedBox(
            width: double.infinity,
            child: fluent.Button(
              onPressed: talk == null
                  ? null
                  : () {
                      final t = talk;
                      _showPlaceRoleDialog(null, t);
                    },
              child: const Text('👤 人物登场'),
            ),
          ),
        ],
      ),
    );
  }

  void _markDirty() {
    if (!_dirty) {
      setState(() => _dirty = true);
    } else {
      // 内容摘要需要跟随刷新（左栏卡片预览）
      setState(() {});
    }
  }
}

// ---------------------------------------------------------------------------
// 小部件
// ---------------------------------------------------------------------------

/// 通用胶囊按钮（页内高频操作；三态：默认/选中/危险，禁用=onTap 为 null）。
class _StudioPill extends StatelessWidget {
  const _StudioPill({
    required this.label,
    this.onTap,
    this.selected = false,
    this.danger = false,
    this.hint,
  });
  final String label;
  final VoidCallback? onTap;
  final bool selected;
  final bool danger;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    Color bg = palette.card;
    Color fg = palette.textPrimary;
    if (!enabled) {
      bg = palette.panel;
      fg = palette.iconDisabled;
    } else if (selected) {
      bg = palette.tintAccent;
      fg = palette.accentPale;
    } else if (danger) {
      bg = palette.tintWarn;
      fg = palette.danger;
    }
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: selected ? palette.accentDeep : palette.borderHover,
            ),
          ),
          child: Text(
            hint == null ? label : '$label · $hint',
            style: TextStyle(fontSize: 11, color: fg, fontWeight: FontWeight.w500),
          ),
        ),
      ),
    );
  }
}

/// 分区卡片（友商#2 的 section-title + section-divider 结构）。
class _StudioSection extends StatelessWidget {
  const _StudioSection({
    required this.icon,
    required this.title,
    required this.child,
    this.subtitle,
    this.actions = const [],
  });
  final IconData icon;
  final String title;
  final String? subtitle;
  final List<Widget> actions;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: palette.panel,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: palette.surface),
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(icon, size: 13, color: accentColor),
              const SizedBox(width: 6),
              Text(
                title,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.bold,
                  color: palette.textHigh,
                ),
              ),
              if (subtitle != null) ...[
                const SizedBox(width: 8),
                Text(
                  subtitle!,
                  style: TextStyle(fontSize: 10.5, color: palette.textHint),
                ),
              ],
              const Spacer(),
              ...actions,
            ],
          ),
          const SizedBox(height: 10),
          child,
        ],
      ),
    );
  }
}

/// 默认收起的分区（原文兜底用）。
class _CollapsibleSection extends StatefulWidget {
  const _CollapsibleSection({
    required this.icon,
    required this.title,
    required this.child,
  });
  final IconData icon;
  final String title;
  final Widget child;

  @override
  State<_CollapsibleSection> createState() => _CollapsibleSectionState();
}

class _CollapsibleSectionState extends State<_CollapsibleSection> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: palette.bgAlt,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: palette.surface),
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
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                child: Row(
                  children: [
                    Icon(
                      _open
                          ? FluentIcons.chevron_down_24_regular
                          : FluentIcons.chevron_right_24_regular,
                      size: 11,
                      color: palette.textMuted,
                    ),
                    const SizedBox(width: 6),
                    Icon(widget.icon, size: 13, color: palette.textSecondary),
                    const SizedBox(width: 6),
                    Text(
                      widget.title,
                      style: TextStyle(fontSize: 12, color: palette.textSecondary),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (_open)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: widget.child,
            ),
        ],
      ),
    );
  }
}

/// 自维护 controller 的文本框：外部值与当前文本不同时才回写（防吞光标）。
class _StudioTextField extends StatefulWidget {
  const _StudioTextField({
    super.key,
    required this.value,
    required this.onChanged,
    this.placeholder = '',
    this.style,
    this.maxLines,
  });
  final String value;
  final ValueChanged<String> onChanged;
  final String placeholder;
  final TextStyle? style;
  final int? maxLines;

  @override
  State<_StudioTextField> createState() => _StudioTextFieldState();
}

class _StudioTextFieldState extends State<_StudioTextField> {
  late final TextEditingController _ctrl =
      TextEditingController(text: widget.value);

  @override
  void didUpdateWidget(covariant _StudioTextField old) {
    super.didUpdateWidget(old);
    // 语义相等（含首尾空白差异）不回写，避免打断输入。
    if (widget.value != _ctrl.text &&
        widget.value.trim() != _ctrl.text.trim()) {
      _ctrl.text = widget.value;
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: widget.maxLines == null ? 32 : 32 + (widget.maxLines! - 1) * 20.0,
      child: fluent.TextBox(
        controller: _ctrl,
        placeholder: widget.placeholder,
        style: widget.style,
        maxLines: widget.maxLines ?? 1,
        minLines: 1,
        onChanged: (v) {
          widget.onChanged(v);
        },
      ),
    );
  }
}

/// 选项卡（友商#2 branch-card：文本 + 双去向 + 高级条件/效果折叠）。
class _StudioOptionCard extends StatefulWidget {
  const _StudioOptionCard({
    super.key,
    required this.optId,
    required this.opt,
    required this.talkOptions,
    required this.noCode,
    required this.gameDicts,
    required this.onChanged,
    required this.onRemove,
    required this.onPickTarget,
  });
  final String optId;
  final dynamic opt;
  final List<(String, String)> talkOptions;
  final bool noCode;
  final Map<String, dynamic> gameDicts;
  final VoidCallback onChanged;
  final VoidCallback onRemove;
  final Future<List<String>?> Function({List<String> initial}) onPickTarget;

  @override
  State<_StudioOptionCard> createState() => _StudioOptionCardState();
}

class _StudioOptionCardState extends State<_StudioOptionCard> {
  bool _advanced = false;

  String? _talkName(String id) {
    for (final e in widget.talkOptions) {
      if (e.$1 == id) return e.$2.isEmpty ? null : e.$2;
    }
    return null;
  }

  Widget _targetEditor(String field, String label) {
    final opt = widget.opt;
    final value = opt is Map
        ? normalizeStoryIdList(opt[field]).map(cln).join(',')
        : '';
    Widget editor;
    if (widget.noCode) {
      editor = NoCodeRefField(
        value: value,
        pickLabel: '选…',
        emptyText: '（未设置）',
        compact: true,
        nameOf: _talkName,
        onPick: () async {
          final ids = await widget.onPickTarget(
            initial: opt is Map
                ? normalizeStoryIdList(opt[field]).map(cln).toList()
                : const [],
          );
          if (ids == null || opt is! Map) return;
          opt[field] = ids.map((e) => int.tryParse(e) ?? e).toList();
          widget.onChanged();
          setState(() {});
        },
        onDisableNoCode: () => exitNoCodeMode(context),
      );
    } else {
      editor = _StudioTextField(
        value: value,
        placeholder: '对话 ID',
        style: const TextStyle(fontSize: 11.5),
        onChanged: (v) {
          if (opt is! Map) return;
          opt[field] = v
              .split(',')
              .map((s) => s.trim())
              .where((s) => s.isNotEmpty)
              .map((s) => int.tryParse(s) ?? s)
              .toList();
          widget.onChanged();
        },
      );
    }
    return Row(
      children: [
        SizedBox(
          width: 84,
          child: Text(label,
              style: TextStyle(fontSize: 11, color: palette.textSecondary)),
        ),
        Expanded(child: editor),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final opt = widget.opt;
    if (opt is! Map) {
      return Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: palette.bgAlt,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: palette.border),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                '选项 [${widget.optId}] 不在 OptionCfg（可删除引用或去选项表补记录）',
                style: TextStyle(fontSize: 11, color: palette.danger),
              ),
            ),
            _StudioPill(label: '× 删除引用', danger: true, onTap: widget.onRemove),
          ],
        ),
      );
    }
    final typed = opt.cast<String, dynamic>();
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: palette.tintWarn,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: palette.borderHover),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(FluentIcons.circle_half_fill_24_regular,
                  size: 12, color: palette.warning),
              const SizedBox(width: 6),
              Text(
                '选项 ${widget.optId}',
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: palette.goldText,
                ),
              ),
              const Spacer(),
              MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  onTap: widget.onRemove,
                  child: Icon(FluentIcons.delete_24_regular,
                      size: 13, color: palette.statusDanger),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          _StudioTextField(
            key: ValueKey('optc-${widget.optId}'),
            value: opt['content']?.toString() ?? '',
            placeholder: '玩家看到的选项文字',
            style: const TextStyle(fontSize: 12),
            onChanged: (v) {
              typed['content'] = v;
              widget.onChanged();
            },
          ),
          const SizedBox(height: 6),
          _targetEditor('talkId', '选择后 →'),
          const SizedBox(height: 4),
          _targetEditor('talkId2', '判定失败后 →'),
          const SizedBox(height: 4),
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => setState(() => _advanced = !_advanced),
              child: Row(
                children: [
                  Icon(
                    _advanced
                        ? FluentIcons.chevron_down_24_regular
                        : FluentIcons.chevron_right_24_regular,
                    size: 10,
                    color: palette.textMuted,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    '高级：可用条件 / 成功判定 / 成功·失败效果',
                    style: TextStyle(fontSize: 10.5, color: palette.textMuted),
                  ),
                ],
              ),
            ),
          ),
          if (_advanced) ...[
            const SizedBox(height: 6),
            for (final f in const [
              ('precondition', '可用条件 precondition', '1D Array'),
              ('check', '成功判定 check', '1D Array'),
              ('effect', '成功效果 effect', '2D Array'),
              ('effect2', '失败效果 effect2', '2D Array'),
            ])
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: widget.noCode
                    ? NoCodeEffectField(
                        value: typed[f.$1],
                        type: f.$3,
                        cfg: 'OptionCfg',
                        fieldKey: f.$1,
                        gameDicts: widget.gameDicts,
                        onChanged: (v) {
                          typed[f.$1] = v;
                          widget.onChanged();
                        },
                        onDisableNoCode: () => exitNoCodeMode(context),
                      )
                    : _StudioTextField(
                        key: ValueKey('optadv-${widget.optId}-${f.$1}'),
                        value: ValueCodec.encode(typed[f.$1]),
                        placeholder: f.$2,
                        style: const TextStyle(fontSize: 11),
                        onChanged: (v) {
                          try {
                            typed[f.$1] = ValueCodec.decode(v, f.$3);
                          } catch (_) {
                            typed[f.$1] = v;
                          }
                          widget.onChanged();
                        },
                      ),
              ),
          ],
        ],
      ),
    );
  }
}
