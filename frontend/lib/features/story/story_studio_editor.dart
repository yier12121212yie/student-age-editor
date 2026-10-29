/// 剧情舞台：对话夹树 + 游戏画面即写台词 + 人物与表情的剧情编辑页。
///
/// 三栏信息架构：左栏对话夹树（沿跳转链递归展开，选项/条件分支在触发句下
/// 长夹）｜中栏可编辑的游戏画面 + 本句分区（选项/接续/音频/效果/原文兜底）｜
/// 右栏人物与表情。数据流与经典剧情处理器同口径：整表加载、stageOf 舞台副本、
/// mergeStageBack 并回、PUT 带 expect_mtime_ns 乐观锁，纯函数全部走 story_logic。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/services.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../../core/api_client.dart';
import '../../core/models.dart';
import '../editor/field_utils.dart';
import '../editor/id_ref_picker.dart' show showIdBrowseDialog;
import '../nocode/no_code_exit.dart';
import '../nocode/no_code_ref_field.dart';
import '../nocode/nocode_effect_field.dart';
import '../nocode/role_picker.dart';
import '../resources/image_asset_picker.dart'
    show
        BgIdThumb,
        TexThumb,
        refreshBgIdKeyMap,
        bgIdKeyMapOrNull,
        ensureMergedMeta,
        mergedMetaUsable,
        charKeysMapOrNull,
        MergedMetaAutoRetry,
        mergedMetaRevision;
import '../resources/local_import.dart'
    show importLocalAssets, texKeyOfImportedPath;
import 'portrait_keys.dart';
import 'story_logic.dart';
import '../../core/app_theme.dart';
import '../../core/app_dialogs.dart';

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

/// 台词卡左侧「说话人圆点头像」的直径（逻辑像素）。
const double _kSpeakerDotSize = 22;

/// 圆点头像的纵向取景点（`Alignment.y`，-1 贴顶 / 0 居中 / 1 贴底）。
///
/// ⚠ 方向（曾调反过）：`Alignment.y` 是**取景框在源图上的锚点**——
/// 负值 = 框向上移 = 取到画面偏上部分（头、肩），这正是立绘头像想要的；
/// 正值 = 框向下移 = 会取到人物下半身（腿、裙），是反的。
///
/// 立绘是全身竖图，整幅 cover 进 22px 小圆只会得到一团缩到极小的全身像；
/// 向上取景让人物头肩填满圆框，观感才与「头像」一致。
const double _kSpeakerDotCropY = -0.95;

/// 从事件首句出发沿 nextTalk/option/check 链构建对话线条目序列（深度优先、
/// 扁平带 depth）。同一节点第二次被触达时输出 [StudioItemKind.ref]
/// （「↗ 跳转到该句」），无法从任何首句到达的对白收进「游离对白」段。
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

        // 条件分支：check 有值且配置了失败跳转时长出一个紫色夹，
        // 失败去向即夹底部接续下拉。
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

/// 舞台站位信息（由 roles 指令解析：slot 为 0..4 的可视列，映射到站位 pos）。
class _StudioRolePlacement {
  const _StudioRolePlacement({
    required this.slot,
    required this.roleId,
    required this.expr,
    this.flip = false,
  });

  /// 可视列 0..4（0/1=左 2=中 3/4=右）。
  final int slot;

  final String roleId;

  /// 表情编号 0..26。
  final int expr;

  /// 是否水平镜像翻转。
  final bool flip;
}

class _StoryStudioEditorState extends State<StoryStudioEditor> {
  bool _loaded = false;
  String? _error;

  Map<String, dynamic> _evtCfg = {};
  Map<String, dynamic> _talkCfg = {};
  Map<String, dynamic> _optCfg = {};
  Map<String, dynamic> _personCfg = {};
  Map<String, dynamic> _faceCfg = {};
  Map<String, dynamic> _bgCfg = {};
  Map<String, dynamic> _audioCfg = {};
  Map<String, RoleEntry> _roleCatalog = {};
  Map<String, EffectiveBgState> _effectiveBgs = const {};
  /// 与 [_effectiveBgs] 同步缓存的有效舞台（同一次 `_updateEffectiveBgs` 里算出）：
  /// 单次 `build()` 会对每条旁白行 / 舞台预览 / 演员面板调用 [_stageChars]，
  /// 每次现算 effectiveStages 都要跑一遍全图 BFS（每帧 3～20+ 次）。
  Map<String, List<StageCharState>> _effectiveStages = const {};

  /// 派生缓存是否落后于舞台数据。任何 `setState` 都可能改过 [_stageTalks] /
  /// [_stageOpts]，标记为陈旧后由下一次读取惰性重算（**每帧至多一次** BFS，
  /// 而不是每次 build 的十几次），既能批量合并、又不会读到过期舞台。
  bool _derivedStale = true;

  @override
  void setState(VoidCallback fn) {
    _derivedStale = true;
    super.setState(fn);
    // fn 内部若已显式调用 _updateEffectiveBgs()，会把标记复位（见其实现）。
  }

  /// 惰性重算派生缓存（幂等：同一帧内只算一次）。
  void _ensureDerived() {
    if (_derivedStale) _updateEffectiveBgs();
  }

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

  // 页面级偏好（对应工具栏上的全局开关）
  bool _showIds = true;
  int _stageIndex = 0;
  static const _stages = ['小学立绘', '中学立绘'];
  String _search = '';
  final TextEditingController _searchCtrl = TextEditingController();
  Timer? _searchDebounce;
  Timer? _dirtyRefresh;

  // P3：EvtCfg 顶层条形下拉的排序与 3k+ ComboBoxItem 只在表对象变化时重建。
  // 此前每次 build（每敲一个字）都重排全部事件并重新分配所有下拉项。
  Map<String, dynamic>? _evtListCacheFor;
  int _evtListCacheLen = -1;
  List<String> _evtKeysCache = const [];
  List<fluent.ComboBoxItem<String>> _evtItemsCache = const [];

  /// 右栏正在检视的在场人物（不在本场时自动回落到首位）。
  String? _inspectRoleId;

  @override
  void initState() {
    super.initState();
    // 注册切模式守卫：导演壳可经顶栏切走，未保存的舞台修改必须拦住确认。
    widget.state.leaveGuard = _confirmLeaveGuard;
    _load();
    _loadRoleCatalog();
  }

  @override
  void dispose() {
    if (widget.state.leaveGuard == _confirmLeaveGuard) {
      widget.state.leaveGuard = null;
    }
    _searchDebounce?.cancel();
    _dirtyRefresh?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  /// 切界面模式的守卫：脏数据先弹「保存 / 放弃 / 取消」，
  /// 返回 false 表示放弃切换（壳不重建）。
  Future<bool> _confirmLeaveGuard() async {
    if (!_dirty) return true;
    final choice = await _confirmSaveDiscard(
      content: '当前事件的对白/选项修改尚未保存，切换界面模式后将丢失。',
    );
    if (!mounted || choice == null || choice == 'cancel') return false;
    if (choice == 'save') return await _save();
    return true; // 放弃修改
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
      Map<String, dynamic> faceData = {};
      try {
        final faceRes = await ApiClient.instance.get('/api/cfg/ModFaceCfg');
        faceData = _asMap(faceRes['data']);
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _evtCfg = _asMap(results[0]['data']);
        _talkCfg = _asMap(results[1]['data']);
        _optCfg = _asMap(results[2]['data']);
        _personCfg = _asMap(results[3]['data']);
        _bgCfg = _asMap(results[4]['data']);
        _audioCfg = _asMap(results[5]['data']);
        _faceCfg = faceData;
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
      } else {
        _updateEffectiveBgs();
      }
      _loadStageMeta();
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

  /// 拉取合并元数据（`/api/preview/meta` 的 bgKeys + charKeys）：舞台背景缩略图
  /// 依赖全局 [bgIdKeyMapOrNull]，此前剧情舞台从不触发刷新，导致切换模组或读取模组时
  /// 模组背景/角色元数据未更新，依然显示占位图；这里在进入或重新加载时强制刷新。
  Future<void> _loadStageMeta() async {
    await refreshBgIdKeyMap();
    if (!mounted) return;
    setState(() {});
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
        // 基线 = 当前舞台的深拷贝：省去再来一遍 9.8 万行全表 stageOf 扫描。
        _talkBaseline = copyRecords(_stageTalks);
        _optBaseline = copyRecords(_stageOpts);
        _dirty = false;
        _updateEffectiveBgs();
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
        _talkBaseline = copyRecords(_stageTalks);
        _optBaseline = copyRecords(_stageOpts);
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
      // putRaw：超过 2000 行时把整表 jsonEncode 挪到后台 isolate，避免大表保存
      // 期间主线程冻结（小表/测试桩走同步编码，行为不变）。
      final r = await ApiClient.instance.putRaw(
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
        builder: (ctx) => AppContentDialog(
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
              _talkBaseline = copyRecords(_stageTalks);
              break;
            case 'OptionCfg':
              _optCfg = disk;
              _optMtimeNs = mtime;
              _stageOpts = stageOf(_optCfg, _prefixes, isOption: true);
              _optBaseline = copyRecords(_stageOpts);
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
      builder: (ctx) => AppContentDialog(
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

  Future<String?> _confirmSaveDiscard({
    String content = '当前事件的对白/选项修改尚未保存，离开当前事件后将丢失。',
  }) {
    return fluent.showDialog<String>(
      context: context,
      builder: (ctx) => AppContentDialog(
        title: const Text('有未保存的修改'),
        content: Text(content),
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

  /// P3：缓存事件下拉的排序键与 ComboBoxItem；表对象或行数变化才重建。
  void _ensureEvtListCache() {
    final cfg = _evtCfg;
    if (identical(cfg, _evtListCacheFor) && cfg.length == _evtListCacheLen) {
      return;
    }
    _evtListCacheFor = cfg;
    _evtListCacheLen = cfg.length;
    _evtKeysCache = cfg.keys.toList()..sort(compareEventIds);
    _evtItemsCache = [
      for (final k in _evtKeysCache)
        fluent.ComboBoxItem(
          value: k,
          child: Text(
            '[$k] ${_evtTitle(k).isEmpty ? '事件' : _evtTitle(k)}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11.5),
          ),
        ),
    ];
  }

  void _onSearchChanged(String v) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 200), () {
      if (mounted) setState(() => _search = v);
    });
  }

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

  void _updateEffectiveBgs() {
    if (_evtId == null) {
      _effectiveBgs = const {};
      _effectiveStages = const {};
      _derivedStale = false;
      return;
    }
    // 舞台与背景沿同一条对白链推导，一次算清、两处缓存，build 期间零 BFS。
    _effectiveStages = effectiveStages(
      evtId: _evtId!,
      evtCfg: _evtCfg,
      talks: _stageTalks,
      options: _stageOpts,
    );
    _effectiveBgs = effectiveBackgrounds(
      evtId: _evtId!,
      evtCfg: _evtCfg,
      talks: _stageTalks,
      options: _stageOpts,
    );
    _derivedStale = false;
  }

  EffectiveBgState _effectiveBgFor(Map<String, dynamic>? talk) {
    if (talk == null) return const EffectiveBgState(bgId: '');
    _ensureDerived();
    final tid = cln(talk['id']);
    final fromMap = _effectiveBgs[tid];
    if (fromMap != null) return fromMap;
    final rawBg = cln(talk['bg']);
    if (rawBg.isNotEmpty && rawBg != '0') {
      return EffectiveBgState(bgId: rawBg, isInherited: false, sourceTalkId: tid);
    }
    return const EffectiveBgState(bgId: '');
  }

  /// 人物 ID + 表情编号 → 候选立绘 key 列表（变体优先，优雅回退到基础立绘）。
  ///
  /// 解析口径统一收敛到 [portraitKeyCandidates]（与经典导演视图同源），这里只
  /// 负责把工作台已加载的四类素材来源摊平成入参：
  ///   1. ModFaceCfg（`_faceCfg`）：用户按表情逐个指定的自定义表情图；
  ///   2. RoleCatalog（`/api/roles`）：随包官方 → 工作区 PersonCfg 逐层覆盖；
  ///   3. 工作区 PersonCfg（`_personCfg`）原始记录：目录未就绪时的自定义兜底；
  ///   4. charKeys（`/api/preview/meta` 合并元数据）：官方差分/基础立绘兜底。
  List<String> _portraitKeyCandidates(String roleId, {int expr = 0}) {
    final id = cln(roleId);
    if (id.isEmpty) return const [];
    final r = _roleCatalog[id];
    final p = _personCfg[id];
    Map<String, dynamic>? ck;
    final rawCk = charKeysMapOrNull?[id];
    if (rawCk is Map) ck = rawCk.cast<String, dynamic>();
    return portraitKeyCandidates(
      roleId: id,
      expr: expr,
      stageIndex: _stageIndex,
      faceCfg: _faceCfg,
      catalogPortrait1: r?.portrait1.trim() ?? '',
      catalogPortrait2: r?.portrait2.trim() ?? '',
      personUrl1: p is Map ? portraitFirstStr(p['url']) : '',
      personUrl2: p is Map ? portraitFirstStr(p['url2']) : '',
      charKeys: ck,
    );
  }

  /// 人物 ID → 当前阶段立绘 key（与经典处理器同规则：url=小学、url2=中学）。
  String _portraitKeyFor(String roleId, {int expr = 0}) {
    final cands = _portraitKeyCandidates(roleId, expr: expr);
    return cands.isNotEmpty ? cands.first : '';
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
      } else if (!map.containsKey(e.key.toString())) {
        map[e.key.toString()] = '背景 ${e.key}';
      }
    }
    // 合并元数据中已有但在 gameDicts/_bgCfg 中未命名的背景补充兜底名称
    final metaBgs = bgIdKeyMapOrNull;
    if (metaBgs != null) {
      for (final k in metaBgs.keys) {
        if (!map.containsKey(k) && k.isNotEmpty && k != '0') {
          map[k] = '背景 $k';
        }
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

  /// 点击说话人名称：弹出「更改说话人」对话框。
  ///
  /// 可多选任意人物（不再局限于本句已在场的候选）、一键清空为旁白，并就地编辑
  /// 显示名称（`roleName`）。相比原先的「点名字轮换」，这里不会在候选末尾把
  /// 说话人打回旁白；换人后若显示名仍是旧说话人的默认名（未被显式自定义），
  /// 会自动清空让显示名跟随新说话人，修复「换了人还显示旧名字」的问题。
  Future<void> _showSpeakerDialog(Map<String, dynamic> talk) async {
    var ids = normalizeStoryIdList(talk['roleIds'])
        .map(cln)
        .where((s) => s.isNotEmpty && s != '-1')
        .toList();
    // 旧说话人的默认显示名：用于判断 roleName 是「自定义」还是「跟随说话人」。
    final oldDefault = ids.map(_roleName).where((n) => n.isNotEmpty).join('、');
    final nameCtrl = TextEditingController(text: cln(talk['roleName']));

    await fluent.showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AppContentDialog(
          title: const Text('更改说话人'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '说话人（留空 = 旁白，可多选）',
                  style: TextStyle(fontSize: 12, color: palette.textSecondary),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 5,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    for (final rid in ids)
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 4),
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
                                  fontSize: 11, color: palette.accentPale),
                            ),
                            const SizedBox(width: 4),
                            MouseRegion(
                              cursor: SystemMouseCursors.click,
                              child: GestureDetector(
                                onTap: () => setDialogState(() {
                                  ids = ids.where((e) => e != rid).toList();
                                }),
                                child: Icon(FluentIcons.dismiss_16_regular,
                                    size: 10, color: palette.accentPale),
                              ),
                            ),
                          ],
                        ),
                      ),
                    _StudioPill(
                      label: '＋ 选择人物',
                      onTap: () async {
                        final picked =
                            await showRolePickerDialog(ctx, multi: true);
                        if (picked == null || !ctx.mounted) return;
                        setDialogState(() {
                          for (final p in picked) {
                            final pid = cln(p);
                            if (pid.isNotEmpty &&
                                pid != '-1' &&
                                !ids.contains(pid)) {
                              ids = [...ids, pid];
                            }
                          }
                        });
                      },
                    ),
                    _StudioPill(
                      label: '旁白（清空）',
                      onTap: ids.isEmpty
                          ? null
                          : () => setDialogState(() => ids = []),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  '显示名称（留空 = 用人物本名）',
                  style: TextStyle(fontSize: 12, color: palette.textSecondary),
                ),
                const SizedBox(height: 6),
                fluent.TextBox(
                  controller: nameCtrl,
                  placeholder: '如「？？？」',
                  style: const TextStyle(fontSize: 12),
                ),
              ],
            ),
          ),
          actions: [
            fluent.Button(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('取消'),
            ),
            fluent.FilledButton(
              onPressed: () {
                final name = nameCtrl.text.trim();
                // 只保留用户显式输入的自定义名；空或等于旧说话人默认名时清空，
                // 让显示名跟随新说话人自动更新。
                final custom = name.isNotEmpty && name != oldDefault;
                setState(() {
                  talk['roleIds'] =
                      ids.map((e) => int.tryParse(e) ?? e).toList();
                  if (custom) {
                    talk['roleName'] = name;
                  } else {
                    talk.remove('roleName');
                  }
                  _dirty = true;
                });
                Navigator.of(ctx).pop();
              },
              child: const Text('确定'),
            ),
          ],
        ),
      ),
    );
  }

  // ---------- 站位/表情（roles 指令 [[roleId, 指令码, ...], ...]） ----------

  /// 可视列 0..4 → 站位 pos（0/1=左 1，2=中 3，3/4=右 2）。
  static const _slotPos = [1, 1, 3, 2, 2];

  static int _posToSlot(int pos) => pos == 1 ? 1 : (pos == 2 ? 3 : 2);

  /// 有效舞台（含跨对白继承，与后端 preview_event 同口径）；解析失败回退单句。
  /// 查 [_effectiveStages] 缓存（O(1)），不再每帧重跑全图 BFS。
  List<StageCharState> _stageChars(String talkId, Map<String, dynamic> talk) {
    _ensureDerived();
    if (talkId.isNotEmpty && _evtId != null) {
      final eff = _effectiveStages[talkId];
      if (eff != null) return eff;
    }
    return parseStageChars(talk['roles']);
  }

  List<_StudioRolePlacement> _parseSlots(Map<String, dynamic> talk) {
    final chars = _stageChars(cln(talk['id']), talk);
    return [
      for (final c in chars)
        _StudioRolePlacement(
          slot: _posToSlot(c.pos),
          roleId: c.roleId,
          expr: c.expr,
          flip: c.flip,
        ),
    ];
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

  /// 写回舞台操作：只改站位或表情，均以 roles 指令行形式落盘。
  void _applyStage(
    Map<String, dynamic> talk, {
    String? roleId,
    int? pos,
    int? expr,
  }) {
    if (roleId == null) return;
    var roles = talk['roles'];
    if (pos != null) roles = setStagePos(roles, roleId, pos);
    if (expr != null) roles = setStageExpr(roles, roleId, expr);
    talk['roles'] = roles;
    _dirty = true;
    setState(() {});
  }

  void _setEmotion(Map<String, dynamic> talk, String roleId, int expr) {
    _applyStage(talk, roleId: roleId, expr: expr);
  }

  void _shiftPlacement(
    Map<String, dynamic> talk,
    _StudioRolePlacement p,
    int dir,
  ) {
    final next = p.slot + dir;
    if (next < 0 || next > 4) return;
    _applyStage(talk, roleId: p.roleId, pos: _slotPos[next]);
  }

  void _toggleFlip(Map<String, dynamic> talk, String roleId) {
    talk['roles'] = toggleStageFlip(talk['roles'], roleId);
    _dirty = true;
    _markDirty();
    setState(() {});
  }

  void _removePlacement(Map<String, dynamic> talk, String roleId) {
    talk['roles'] = removeStageRole(talk['roles'], roleId);
    setState(() => _dirty = true);
  }

  /// 游戏表情编号 → 名称（0..26）。权威表在 `story_logic.dart:kEmotionNames`
  /// （与后端 stage_service kExpressionNames 同序），此处仅引用，避免双份维护。
  static const _emotions = kEmotionNames;

  String _emotionName(int expr) => emotionNameOf(expr);

  /// 角色是否「已知支持」该表情 —— **只用于高亮提示，不再用于禁用表情按钮**。
  ///
  /// 历史坑（本次修复的根因）：本函数原为 `_isEmotionAvailable`，返回值被当作
  /// `onTap` 的开关，false 即把表情胶囊置灰。但链路上没有任何一环能给出可靠反证：
  ///   * 后端 `charKeys[id].expressions` 通过「`base_N` 贴图是否存在」探测得到，
  ///     与游戏真实表情集系统性不符（实测角色 101 真实含 8=惊讶，探测只给到
  ///     [0,1,2,3,4,5,6]；角色 3 真实含 [1,6,8,11]，探测只给到 [0,2]）；
  ///   * 旧代码 `if (exprs is List) return exprs.contains(expr)` 会把后面的
  ///     PersonCfg 兜底整体短路 —— 一旦后端漏检，表情永久置灰；
  ///   * `/api/cfg/PersonCfg` 只返回 **mod 自己**的表（用户模组仅 31 条），
  ///     核心角色 101/102/3 不在其中 → 第 3 步兜底拿不到数据；
  ///   * 基础 PersonCfg 的 380 条里 **没有任何** `l2d`/`l2d2`，
  ///     「Live2D 角色恒可用」分支在基础数据上从不生效。
  ///
  /// 参考实现（友商产品#1 `story.py` / `person.py`）同样从不禁用表情：它只把
  /// 「已知支持」的表情**标色**（`color = "#DB0000"`），其余照常可选。此处对齐
  /// 该语义 —— 判定退化为「正向证据并集」，无证据即中性（仍可选）。
  bool _isEmotionSupported(String roleId, int expr) {
    if (expr == 0) return true; // 默认表情
    final id = cln(roleId);
    if (id.isEmpty) return true;

    // 1. ModFaceCfg 自定义表情差分（id = pid*1000 + expr）
    final pid = int.tryParse(id);
    if (pid != null && _faceCfg.isNotEmpty) {
      for (final e in _faceCfg.values) {
        if (e is! Map) continue;
        final fid = (e['id'] as num?)?.toInt() ?? -1;
        if (fid ~/ 1000 != pid || fid % 100 != expr) continue;
        final icon = (e['icon'] ?? '').toString().trim();
        final iconXx = (e['icon_xx'] ?? '').toString().trim();
        if (icon.isNotEmpty || iconXx.isNotEmpty) return true;
      }
    }

    // 2. 合并元数据 charKeys：任一正向证据即可
    final ck = charKeysMapOrNull?[id];
    if (ck is Map) {
      final l2d = ck['l2d'];
      if (l2d is List && l2d.isNotEmpty) return true;
      final faces = ck['faces'];
      if (faces is Map && faces.containsKey(expr.toString())) return true;
      final exprs = ck['expressions'];
      if (exprs is List && exprs.contains(expr)) return true;
      // ⚠ 此处不得 `return exprs.contains(expr)`：exprs 漏检只说明「没探测到」，
      // 不等于「不支持」。一票否决会把下面所有兜底短路（历史 bug）。
    }

    // 3. PersonCfg 中配置了 Live2D
    final p = _personCfg[id];
    if (p is Map) {
      final l1 = p['l2d'];
      if (l1 is List && l1.isNotEmpty) return true;
      final l2 = p['l2d2'];
      if (l2 is List && l2.isNotEmpty) return true;
    }

    return false;
  }

  // ---------- 放置角色弹窗（点选后立即登场） ----------

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
    int? placedExpr;
    if (slotIdx != null) {
      for (final s in _parseSlots(talk)) {
        if (s.slot == slotIdx) {
          placed = s.roleId;
          placedExpr = s.expr;
          break;
        }
      }
    }
    final selected = placed ?? (personKeys.isNotEmpty ? personKeys.first : '10');
    final exprCode = placedExpr ?? 0;
    final slot = slotIdx ?? 2;

    await fluent.showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => _StudioPlaceRoleDialog(
        slotIdx: slotIdx,
        initialSelected: selected,
        initialExpr: exprCode,
        initialSlot: slot,
        allRoles: allRoles,
        roleCatalog: _roleCatalog,
        onCatalogLoaded: (m) {
          if (mounted) setState(() => _roleCatalog = m);
        },
        portraitKeyCandidates: _portraitKeyCandidates,
        roleName: _roleName,
        emotionName: _emotionName,
        isEmotionSupported: _isEmotionSupported,
        onImportLocalPortrait: (rid) async {
          await _importLocalPortrait(rid);
          if (mounted) setState(() {});
        },
        onConfirm: (sel, expr, s) {
          setState(() {
            talk['roles'] = setStageExpr(
              setStagePos(talk['roles'], sel, _slotPos[s]),
              sel,
              expr,
            );
            // 登场即入说话人候选（点选后立即登场的顺手路径）。
            final ids = ensureList(talk['roleIds']).map(cln).toList();
            if (!ids.contains(sel) && sel != '-1') {
              talk['roleIds'] = [
                ...normalizeStoryIdList(talk['roleIds']),
                int.tryParse(sel) ?? sel,
              ];
            }
            _dirty = true;
          });
        },
      ),
    );
  }

  /// 「点击人物更换角色」：复用 [_StudioPlaceRoleDialog]，确认时经
  /// [replaceStageRole] 原子替换舞台指令，并联动说话人（roleIds）与高亮（highlights）。
  Future<void> _showReplaceRoleDialog(
    Map<String, dynamic> talk,
    _StudioRolePlacement p,
  ) async {
    final allRoles = _allRoles();
    final oldId = p.roleId;
    final oldName = _roleName(oldId);
    final oldLabel = oldName.isEmpty ? oldId : oldName;

    await fluent.showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => _StudioPlaceRoleDialog(
        // 传 null 让弹窗展示站位微调（站位槽已由 [p] 预置）。
        slotIdx: null,
        initialSelected: oldId,
        initialExpr: p.expr,
        initialSlot: p.slot,
        allRoles: allRoles,
        roleCatalog: _roleCatalog,
        onCatalogLoaded: (m) {
          if (mounted) setState(() => _roleCatalog = m);
        },
        portraitKeyCandidates: _portraitKeyCandidates,
        roleName: _roleName,
        emotionName: _emotionName,
        isEmotionSupported: _isEmotionSupported,
        titleText: '更换人物：[$oldId] $oldLabel',
        confirmButtonText: '确定更换',
        onImportLocalPortrait: (rid) async {
          await _importLocalPortrait(rid);
          if (mounted) setState(() {});
        },
        onConfirm: (sel, expr, s) {
          final newId = cln(sel);
          if (newId.isEmpty || newId == cln(oldId)) return;
          setState(() {
            talk['roles'] = replaceStageRole(
              talk['roles'],
              oldId,
              newId,
              pos: _slotPos[s],
              expr: expr,
              flip: p.flip,
            );
            // 说话人 / 高亮联动：原角色在列则替换为新角色。
            if (ensureList(talk['roleIds']).map(cln).contains(oldId)) {
              talk['roleIds'] = replaceRoleRef(talk['roleIds'], oldId, newId);
            }
            if (ensureList(talk['highlights']).map(cln).contains(oldId)) {
              talk['highlights'] =
                  replaceRoleRef(talk['highlights'], oldId, newId);
            }
            if (cln(_inspectRoleId ?? '') == cln(oldId)) {
              _inspectRoleId = newId;
            }
            _dirty = true;
          });
        },
      ),
    );
  }

  Future<void> _showSceneBgDialog(Map<String, dynamic> talk) async {
    final bgs = _allBgs();
    var current = cln(talk['bg']);
    final inheritedState = _effectiveBgFor(talk);
    final inheritedId = inheritedState.bgId;
    final inheritedName = bgs[inheritedId] ?? '';

    await fluent.showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AppContentDialog(
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
                      key: ValueKey('bg-dialog-$current'),
                      id: current,
                      width: double.infinity,
                      height: 150,
                    ),
                  )
                else ...[
                  Text(
                    inheritedId.isNotEmpty
                        ? '延续上文背景 (当前生效: ${inheritedName.isEmpty ? inheritedId : inheritedName} [$inheritedId])'
                        : '空 = 延续前文背景（当前链路上文未指定背景）',
                    style: TextStyle(fontSize: 11, color: palette.textHint),
                  ),
                  if (inheritedId.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    SizedBox(
                      height: 140,
                      child: Stack(
                        children: [
                          Positioned.fill(
                            child: BgIdThumb(
                              key: ValueKey('bg-dialog-inherited-$inheritedId'),
                              id: inheritedId,
                              width: double.infinity,
                              height: 140,
                            ),
                          ),
                          Positioned(
                            right: 6,
                            bottom: 6,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.65),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: const Text('延续背景预览',
                                  style: TextStyle(
                                      fontSize: 10, color: Colors.white70)),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
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
                  if (current.isEmpty || current == '0') {
                    talk.remove('bg');
                  } else {
                    talk['bg'] = int.tryParse(current) ?? current;
                  }
                  _dirty = true;
                  _updateEffectiveBgs();
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
    // BgCfg 落盘后刷新 id→key 合并元数据，否则新背景在舞台 / 场景预览里仍是占位图。
    await refreshBgIdKeyMap();
    if (!mounted) return null;
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
    // 监听合并元数据（bgKeys/charKeys）修订号：舞台立绘与「人物与表情」面板在
    // build 期被动读取该缓存，元数据异步到达后必须自动重建，否则会停留在占位图上，
    // 直到用户切换对白（旧 bug：进入剧情舞台要换几次页才显示人物和背景）。
    //
    // 外层 [MergedMetaAutoRetry] 负责「后端冷启动 / 返回空表」时的自动重拉：
    // 渲染期只读缓存、不发请求，旧实现里这一次失败无人补救，背景便一直是占位图。
    // 定时器归该组件 State 所有，随页面销毁一并取消（否则测试结束会留下未消费的
    // 定时器）。连续未就绪达上限后不再自动重发，需显式 refresh 或切模组。
    return MergedMetaAutoRetry(
      child: ValueListenableBuilder<int>(
        valueListenable: mergedMetaRevision,
        builder: (context, _, _) => _buildBody(context),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
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
    _ensureEvtListCache();
    final evtKeys = _evtKeysCache;
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
              items: _evtItemsCache,
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
                  onChanged: _onSearchChanged,
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
              // 说话人圆点头像（speaker-dot）
              // 立绘是全身竖图，直接 cover 进 22px 小圆里人只占一小块、五官不可辨；
              // 向上取景（Alignment.y < 0）让人物头肩填满圆框，见 _kSpeakerDotCropY。
              Container(
                width: _kSpeakerDotSize,
                height: _kSpeakerDotSize,
                margin: const EdgeInsets.only(right: 6, top: 1),
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: palette.card,
                ),
                child: dotKey.isEmpty
                    ? Icon(FluentIcons.person_24_regular,
                        size: 12, color: palette.textHint)
                    : TexThumb(
                        keyName: dotKey,
                        width: _kSpeakerDotSize,
                        height: _kSpeakerDotSize,
                        fit: BoxFit.cover,
                        alignment: const Alignment(0, _kSpeakerDotCropY),
                      ),
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
    final effBg = _effectiveBgFor(talk);
    final bgVal = effBg.bgId;
    final bgName = _allBgs()[bgVal] ?? '';
    final isExplicit = !effBg.isInherited && effBg.bgId.isNotEmpty;
    final isInherited = effBg.isInherited && effBg.bgId.isNotEmpty;
    // 背景 id 是否已解析出贴图 key。元数据（后端合并 bgKeys）还没就绪时解析不出
    // 来，缩略图只能显示占位图 —— 明确标出「资源未就绪」（而不是让用户以为是
    // 这句没背景）；同时 MergedMetaAutoRetry 会持续自动重拉，就绪后自动换图。
    final bgKey = (bgVal.isEmpty || bgVal == '0') ? null : bgIdKeyMapOrNull?[bgVal];
    final bgUnresolved =
        bgVal.isNotEmpty && bgVal != '0' && (bgKey == null || bgKey.isEmpty);
    final String bgLabel;
    if (isExplicit) {
      bgLabel =
          '背景: ${bgName.isEmpty ? bgVal : bgName} ($bgVal) · ${bgUnresolved ? '资源未就绪' : '本句切换'}';
    } else if (isInherited) {
      final src = effBg.sourceTalkId != null ? ' · 延续自 [${effBg.sourceTalkId}]' : ' · 延续前文';
      bgLabel = '背景: ${bgName.isEmpty ? bgVal : bgName} ($bgVal)$src';
    } else {
      bgLabel = '背景: 未设置 (默认黑幕)';
    }

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
              // 当前背景状态指示与缩略
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                decoration: BoxDecoration(
                  color: isExplicit
                      ? palette.tintAccent
                      : (isInherited ? palette.surface : Colors.transparent),
                  borderRadius: BorderRadius.circular(6),
                  border: isExplicit
                      ? Border.all(color: accentColor.withValues(alpha: 0.5))
                      : null,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (bgVal.isNotEmpty && bgVal != '0') ...[
                      ClipRRect(
                        borderRadius: BorderRadius.circular(3),
                        child: SizedBox(
                          width: 22,
                          height: 16,
                          child: BgIdThumb(id: bgVal, width: 22, height: 16),
                        ),
                      ),
                      const SizedBox(width: 6),
                    ],
                    Text(
                      bgLabel,
                      style: TextStyle(
                        fontSize: 10.5,
                        color: isExplicit
                            ? palette.accentPale
                            : (isInherited ? palette.textBody : palette.textHint),
                        fontWeight: isExplicit ? FontWeight.w600 : FontWeight.normal,
                      ),
                    ),
                    if (isExplicit) ...[
                      const SizedBox(width: 4),
                      MouseRegion(
                        cursor: SystemMouseCursors.click,
                        child: GestureDetector(
                          onTap: () {
                            setState(() {
                              talk.remove('bg');
                              _dirty = true;
                              _updateEffectiveBgs();
                            });
                          },
                          child: Tooltip(
                            message: '清除本句背景切换（改为延续前文）',
                            child: Icon(
                              FluentIcons.dismiss_12_regular,
                              size: 11,
                              color: palette.accentPale,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
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
                  if (!mounted) return;
                  if (ids == null || ids.isEmpty) return;
                  setState(() {
                    final merged = normalizeStoryIdList(talk['roleIds']);
                    final existing =
                        merged.map(cln).where((s) => s.isNotEmpty).toSet();
                    for (final e in ids) {
                      final id = cln(e);
                      if (id.isEmpty || !existing.add(id)) continue;
                      merged.add(int.tryParse(id) ?? id);
                    }
                    talk['roleIds'] = merged;
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
                  // 站位立绘（高度 220 沉底，顶部浮动显示角色信息与表情）
                  Positioned.fill(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: List.generate(5, (slotIdx) {
                          final p = slotMap[slotIdx];
                          if (p == null) {
                            return Expanded(
                              child: MouseRegion(
                                cursor: SystemMouseCursors.click,
                                child: GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onTap: () => _showPlaceRoleDialog(slotIdx, talk),
                                  child: Container(
                                    height: 220,
                                    margin: const EdgeInsets.symmetric(horizontal: 2),
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(6),
                                      border: Border.all(
                                        color: Colors.white.withValues(alpha: 0.08),
                                      ),
                                    ),
                                    child: Center(
                                      child: Opacity(
                                        opacity: 0.25,
                                        child: Icon(
                                          FluentIcons.add_circle_24_regular,
                                          size: 20,
                                          color: palette.textHint,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            );
                          }

                          final cands = _portraitKeyCandidates(p.roleId, expr: p.expr);
                          final primaryKey = cands.isNotEmpty ? cands.first : '';
                          final hl = highlights.contains(p.roleId);
                          final hasHlFocus = highlights.isNotEmpty;
                          final roleDimmed = hasHlFocus && !hl;

                          return Expanded(
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 2),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  // 角色名称与表情浮标（位于立绘顶部，不被底部台词框遮挡）
                                  MouseRegion(
                                    cursor: SystemMouseCursors.click,
                                    child: GestureDetector(
                                      onTap: () => _showSlotActionDialog(talk, p),
                                      child: Container(
                                        margin: const EdgeInsets.only(bottom: 4),
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 6, vertical: 2),
                                        decoration: BoxDecoration(
                                          color: hl
                                              ? palette.tintAccent
                                              : palette.card.withValues(alpha: 0.88),
                                          borderRadius: BorderRadius.circular(8),
                                          border: hl
                                              ? Border.all(color: accentColor, width: 1.2)
                                              : Border.all(
                                                  color: Colors.white.withValues(alpha: 0.15)),
                                          boxShadow: hl
                                              ? [
                                                  BoxShadow(
                                                    color: accentColor.withValues(alpha: 0.35),
                                                    blurRadius: 4,
                                                  ),
                                                ]
                                              : null,
                                        ),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            if (p.flip) ...[
                                              Icon(FluentIcons.arrow_swap_16_regular,
                                                  size: 8.5, color: palette.accentPale),
                                              const SizedBox(width: 2),
                                            ],
                                            Flexible(
                                              child: Text(
                                                '${_roleName(p.roleId).isEmpty ? p.roleId : _roleName(p.roleId)} · ${_emotionName(p.expr)}',
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: TextStyle(
                                                  fontSize: 9.5,
                                                  fontWeight: hl ? FontWeight.w600 : FontWeight.normal,
                                                  color: hl ? palette.accentPale : palette.textHigh,
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                  // 立绘（含镜像翻转与发言高亮/弱化）：点击直接呼出更换人物
                                  Tooltip(
                                    message:
                                        '点击更换人物 ([${p.roleId}] ${_roleName(p.roleId)})',
                                    child: MouseRegion(
                                      cursor: SystemMouseCursors.click,
                                      child: GestureDetector(
                                        behavior: HitTestBehavior.opaque,
                                        onTap: () =>
                                            _showReplaceRoleDialog(talk, p),
                                        child: AnimatedOpacity(
                                          duration: const Duration(
                                              milliseconds: 180),
                                          opacity: roleDimmed ? 0.60 : 1.0,
                                          child: Transform.flip(
                                            flipX: p.flip,
                                            child: cands.isNotEmpty
                                                ? TexThumb(
                                                    key: ValueKey(
                                                        'studio-pp-${p.roleId}-${p.expr}-${p.flip}-$primaryKey'),
                                                    keyName: primaryKey,
                                                    keyCandidates: cands,
                                                    height: 220,
                                                    fit: BoxFit.contain,
                                                  )
                                                : SizedBox(
                                                    height: 80,
                                                    child: Center(
                                                      child: Icon(
                                                        FluentIcons
                                                            .person_24_filled,
                                                        size: 36,
                                                        color: hl
                                                            ? palette
                                                                .accentLight
                                                            : palette.textHint,
                                                      ),
                                                    ),
                                                  ),
                                          ),
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
                              onTap: () => _showSpeakerDialog(talk),
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

  /// talk 上的单个跳转目标字段（简易=浏览按钮，普通=ID 文本）。
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
          Text('人物动作 roles（指令行：[[角色, 指令码, 参数…], …]）',
              style: TextStyle(fontSize: 11, color: palette.textSecondary)),
          const SizedBox(height: 4),
          if (_noCode)
            NoCodeEffectField(
              value: talk['roles'] is List ? talk['roles'] : <dynamic>[],
              type: '2D Array',
              cfg: 'TalkCfg',
              fieldKey: 'roles',
              mode: 'action',
              gameDicts: widget.state.gameDicts,
              onChanged: (v) {
                talk['roles'] = v;
                _markDirty();
                setState(() {});
              },
              onDisableNoCode: () => exitNoCodeMode(context),
            )
          else
            _StudioTextField(
              value: const JsonEncoder.withIndent('  ')
                  .convert(talk['roles'] is List ? talk['roles'] : <dynamic>[]),
              placeholder: '如 [[0,1001,1,1],[0,3000,2]]',
              style: const TextStyle(fontSize: 11.5),
              maxLines: 4,
              onChanged: (v) {
                try {
                  final parsed = jsonDecode(v);
                  talk['roles'] = parsed is List ? parsed : <dynamic>[];
                } catch (_) {
                  // JSON 未写完时保持原值，不打断输入。
                }
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

  // ---------- 站位动作弹窗 ----------

  Future<void> _showSlotActionDialog(
    Map<String, dynamic> talk,
    _StudioRolePlacement p,
  ) async {
    await fluent.showDialog<void>(
      context: context,
      builder: (ctx) => AppContentDialog(
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
                      label: e.$2,
                      selected: p.expr == e.$1,
                      // 表情一律可选：是否存在差分由游戏侧回退处理，编辑器只按
                      // 「已知支持」做高亮（禁用会把可用的表情藏起来，见 _isEmotionSupported）。
                      hinted: _isEmotionSupported(p.roleId, e.$1),
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
                  label: p.flip ? '已镜像' : '🔄 翻转',
                  selected: p.flip,
                  onTap: () {
                    _toggleFlip(talk, p.roleId);
                    Navigator.of(ctx).pop();
                  },
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
                const SizedBox(width: 6),
                _StudioPill(
                  label: '🔄 更换人物',
                  onTap: () {
                    Navigator.of(ctx).pop();
                    _showReplaceRoleDialog(talk, p);
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
    final candidates = inspect.isEmpty
        ? const <String>[]
        : _portraitKeyCandidates(inspect, expr: placement?.expr ?? 0);
    final key = candidates.isNotEmpty ? candidates.first : '';
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
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
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
                    Tooltip(
                      message: placement != null ? '点击更换人物' : '',
                      child: MouseRegion(
                        cursor: placement != null
                            ? SystemMouseCursors.click
                            : SystemMouseCursors.basic,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: (talk != null && placement != null)
                              ? () => _showReplaceRoleDialog(talk, placement)
                              : null,
                          child: Container(
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
                                : Transform.flip(
                                    flipX: placement?.flip ?? false,
                                    child: TexThumb(
                                      key: ValueKey(
                                          'studio-inspect-$inspect-${placement?.expr ?? 0}-${placement?.flip ?? false}-$key'),
                                      keyName: key,
                                      keyCandidates: candidates,
                                      width: double.infinity,
                                      height: 220,
                                      fit: BoxFit.contain,
                                    ),
                                  ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            '[$inspect] ${_roleName(inspect)} · ${placement == null ? '未站在场上' : '站位 ${placement.slot}'}',
                            style: TextStyle(fontSize: 10.5, color: palette.textMuted),
                          ),
                        ),
                        if (placement != null)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                            decoration: BoxDecoration(
                              color: palette.tintAccent,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              _emotionName(placement.expr),
                              style: TextStyle(fontSize: 9.5, color: palette.accentPale),
                            ),
                          ),
                        if (talk != null && placement != null) ...[
                          const SizedBox(width: 6),
                          _StudioPill(
                            label: '🔄 更换',
                            onTap: () => _showReplaceRoleDialog(talk, placement),
                          ),
                        ],
                      ],
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
                              hint: '${e.$1}',
                              selected: placement?.expr == e.$1,
                              hinted: _isEmotionSupported(inspect, e.$1),
                              // 仅在「本句未选中」时禁用（那才是真的无处可写），
                              // 不再按角色差分可用性禁用。
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
                            label: placement?.flip == true ? '已镜像' : '🔄 翻转',
                            selected: placement?.flip == true,
                            onTap: talk == null || inspect.isEmpty
                                ? null
                                : () => _toggleFlip(talk, inspect),
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
                  const SizedBox(height: 12),
                ],
              ),
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
      return;
    }
    // P3：已脏后的逐字输入不再整页重建（3k 事件下拉 + 侧栏树 + 两遍链路
    // 遍历）。侧栏摘要延迟 250ms 刷新一次，连续输入只重建一次。
    _dirtyRefresh?.cancel();
    _dirtyRefresh = Timer(const Duration(milliseconds: 250), () {
      if (mounted) setState(() {});
    });
  }
}

// ---------------------------------------------------------------------------
// 小部件
// ---------------------------------------------------------------------------

/// 通用胶囊按钮（页内高频操作；三态：默认/选中/危险，禁用=onTap 为 null）。
/// [hinted] 为「已知支持」的轻提示：只改文字色，不影响可点性（对齐参考实现
/// 把可用表情标色、但仍全部可选的做法）。
class _StudioPill extends StatelessWidget {
  const _StudioPill({
    required this.label,
    this.onTap,
    this.selected = false,
    this.danger = false,
    this.hinted = false,
    this.hint,
  });
  final String label;
  final VoidCallback? onTap;
  final bool selected;
  final bool danger;
  final bool hinted;
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
    } else if (hinted) {
      fg = palette.accentPale;
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

/// 分区卡片（section-title + section-divider 结构）。
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

/// 选项卡（branch-card：文本 + 双去向 + 高级条件/效果折叠）。
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
          if (!mounted) return;
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

// ---------------------------------------------------------------------------
// 放置角色弹窗（人物选择卡片网格 + 表情选择 + 快捷站位）
// ---------------------------------------------------------------------------

class _StudioPlaceRoleDialog extends StatefulWidget {
  const _StudioPlaceRoleDialog({
    required this.slotIdx,
    required this.initialSelected,
    required this.initialExpr,
    required this.initialSlot,
    required this.allRoles,
    required this.roleCatalog,
    required this.portraitKeyCandidates,
    required this.roleName,
    required this.emotionName,
    required this.isEmotionSupported,
    required this.onImportLocalPortrait,
    required this.onConfirm,
    this.onCatalogLoaded,
    this.titleText,
    this.confirmButtonText,
  });

  final int? slotIdx;
  final String initialSelected;
  final int initialExpr;
  final int initialSlot;
  final Map<String, String> allRoles;
  final Map<String, RoleEntry> roleCatalog;
  final List<String> Function(String roleId, {int expr}) portraitKeyCandidates;
  final String Function(String id) roleName;
  final String Function(int expr) emotionName;
  /// 「已知支持」提示（只用于高亮，不再用于禁用表情按钮）。
  final bool Function(String roleId, int expr) isEmotionSupported;
  final Future<void> Function(String roleId) onImportLocalPortrait;
  final void Function(String selected, int exprCode, int slot) onConfirm;

  /// 弹窗自行拉取到角色目录后回调宿主，同步回 [_StoryStudioEditorState._roleCatalog]，
  /// 避免下次打开重复请求（宿主目录在弹窗打开瞬间可能尚未就绪）。
  final void Function(Map<String, RoleEntry> catalog)? onCatalogLoaded;

  /// 自定义标题：用于「更换人物」等复用场景（为空时按 [slotIdx] 取默认文案）。
  final String? titleText;

  /// 自定义确认按钮文案（为空时默认「登场」）。
  final String? confirmButtonText;

  @override
  State<_StudioPlaceRoleDialog> createState() => _StudioPlaceRoleDialogState();
}

class _StudioPlaceRoleDialogState extends State<_StudioPlaceRoleDialog> {
  final TextEditingController _searchController = TextEditingController();
  final ScrollController _gridScroll = ScrollController();
  late String _selected;
  late int _exprCode;
  late int _slot;
  late Map<String, RoleEntry> _catalog;
  String _query = '';
  bool _autoScrolled = false;

  @override
  void initState() {
    super.initState();
    _selected = widget.initialSelected;
    _exprCode = widget.initialExpr;
    // 注意：这里**不再**把「检测不到的表情」重置为 0。检测只用于高亮，
    // 静默改写用户已选的表情会丢数据（历史 bug 的另一面）。
    _slot = widget.initialSlot;
    _catalog = Map.of(widget.roleCatalog);
    // 立绘 key 依赖两个异步源：/api/roles（角色目录）与 /api/preview/meta
    // （charKeys 合并元数据）。弹窗是独立路由，不随宿主 setState 重建，所以
    // 必须自己触发元数据拉取并监听其到达——否则首屏卡片会定格在占位图标，
    // 直到用户滚动网格、itemBuilder 重新执行才出图（历史 bug）。
    ensureMergedMeta();
    mergedMetaRevision.addListener(_onMetaChanged);
    if (_catalog.isEmpty) {
      loadRoles('').then((roles) {
        if (!mounted || roles.isEmpty) return;
        final map = {for (final r in roles) r.id: r};
        setState(() => _catalog = map);
        widget.onCatalogLoaded?.call(map); // 回填宿主，避免下次打开重复拉取
      });
    }
  }

  /// 合并元数据到达/刷新：重建首屏卡片，让新到的立绘 key 立刻命中。
  void _onMetaChanged() {
    if (mounted) setState(() {});
  }

  /// 弹窗内立绘候选：宿主解析结果 + 弹窗自持目录 + 合并元数据，去重合并。
  ///
  /// 关键修复点：宿主 [_StoryStudioEditorState._portraitKeyCandidates] 只读宿主
  /// 自己的 `_roleCatalog`，弹窗打开瞬间它可能尚未就绪而返回空列表。这里用弹窗
  /// 自己拉到的 `_catalog` 与 `charKeys` 补齐候选链，保证首屏无需滚动即可出图。
  List<String> _candidatesFor(String id, {required int expr}) {
    final key = cln(id);
    if (key.isEmpty) return const [];
    final out = <String>[];
    void push(String v) {
      final s = v.trim();
      if (s.isEmpty || out.contains(s)) return;
      out.add(s);
    }

    for (final c in widget.portraitKeyCandidates(key, expr: expr)) {
      push(c);
    }
    final r = _catalog[key];
    if (r != null) {
      push(r.portrait);
      push(r.portrait2);
      push(r.portrait1);
    }
    final ck = charKeysMapOrNull?[key];
    if (ck is Map) {
      push(portraitFirstStr(ck['base2']));
      push(portraitFirstStr(ck['base']));
    }
    // 主角别名 00 / 000 无独立立绘：复用主角 0 的候选。
    if (key == '00' || key == '000') {
      for (final c in _candidatesFor('0', expr: expr)) {
        push(c);
      }
    }
    return out;
  }

  /// 轻量判断某角色是否有立绘候选（供排序用，避免逐项跑完整解析）。
  bool _hasPortrait(String id) {
    final key = cln(id);
    if (key.isEmpty) return false;
    final r = _catalog[key];
    if (r != null &&
        (r.portrait.isNotEmpty ||
            r.portrait1.isNotEmpty ||
            r.portrait2.isNotEmpty)) {
      return true;
    }
    final ck = charKeysMapOrNull?[key];
    if (ck is Map &&
        (portraitFirstStr(ck['base']).isNotEmpty ||
            portraitFirstStr(ck['base2']).isNotEmpty)) {
      return true;
    }
    if (key == '00' || key == '000') return _hasPortrait('0');
    return false;
  }

  /// 首帧后把初始选中角色滚入视野（仅一次）。选中项若在网格下方，用户会误以为
  /// 「未选中/无立绘」，自动滚一次可避免。
  void _scheduleAutoScroll(List<String> keys, double viewportWidth) {
    if (_autoScrolled) return;
    final idx = keys.indexOf(_selected);
    if (idx < 0) return;
    _autoScrolled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_gridScroll.hasClients) return;
      const maxExt = 110.0, spacing = 8.0, aspect = 0.72;
      // 与 SliverGridDelegateWithMaxCrossAxisExtent 的列数口径一致。
      final cols = (viewportWidth / (maxExt + spacing)).ceil().clamp(1, 999);
      final tileW = viewportWidth / cols;
      final rowPitch = tileW / aspect + spacing;
      final offset = (idx ~/ cols) * rowPitch;
      final max = _gridScroll.position.maxScrollExtent;
      if (offset > _gridScroll.offset) {
        _gridScroll.jumpTo(offset.clamp(0.0, max));
      }
    });
  }

  void _selectRole(String id) {
    setState(() {
      _selected = id;
    });
  }

  @override
  void dispose() {
    mergedMetaRevision.removeListener(_onMetaChanged);
    _gridScroll.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _confirm() {
    widget.onConfirm(_selected, _exprCode, _slot);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.sizeOf(context);
    final dialogWidth = (screen.width - 48).clamp(320.0, 680.0);
    final dialogHeight = (screen.height * 0.90).clamp(420.0, 720.0);

    // 汇总所有角色（字典与目录合并）。排序分两段：有立绘的在前，让首屏第一行
    // 即出现有效人物卡片；段内再按数值 ID / 字典序（原口径）。
    final allKeys = <String>{...widget.allRoles.keys, ..._catalog.keys}.toList();

    int byId(String a, String b) {
      final na = int.tryParse(a);
      final nb = int.tryParse(b);
      if (na != null && nb != null) return na.compareTo(nb);
      if (na != null) return -1;
      if (nb != null) return 1;
      return a.compareTo(b);
    }

    final withPortrait = <String>[];
    final withoutPortrait = <String>[];
    for (final k in allKeys) {
      (_hasPortrait(k) ? withPortrait : withoutPortrait).add(k);
    }
    withPortrait.sort(byId);
    withoutPortrait.sort(byId);
    final sortedKeys = [...withPortrait, ...withoutPortrait];

    final q = _query.toLowerCase();
    final filteredKeys = sortedKeys.where((k) {
      if (q.isEmpty) return true;
      final name = _catalog[k]?.name ?? widget.allRoles[k] ?? widget.roleName(k);
      return k.toLowerCase().contains(q) || name.toLowerCase().contains(q);
    }).toList();

    final currentRoleName = _catalog[_selected]?.name ??
        widget.allRoles[_selected] ??
        widget.roleName(_selected);

    return AppContentDialog(
      constraints: BoxConstraints(
        maxWidth: dialogWidth,
        maxHeight: dialogHeight,
      ),
      title: Text(widget.titleText ??
          (widget.slotIdx == null
              ? '人物登场'
              : '放置角色到 站位 ${widget.slotIdx}')),
      content: SizedBox(
        width: dialogWidth,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 1. 搜索框
              fluent.TextBox(
                controller: _searchController,
                placeholder: '搜索人物（中文名或 ID）…',
                prefix: const Padding(
                  padding: EdgeInsets.only(left: 8),
                  child: Icon(FluentIcons.search_16_regular, size: 14),
                ),
                style: const TextStyle(fontSize: 12),
                onChanged: (v) => setState(() => _query = v.trim()),
              ),
              const SizedBox(height: 8),

              // 2. 人物网格（类似简易模式人物选择器）
              SizedBox(
                height: 210,
                child: filteredKeys.isEmpty
                    ? Center(
                        child: Text(
                          '没有匹配的人物',
                          style:
                              TextStyle(fontSize: 12, color: palette.textMuted),
                        ),
                      )
                    : LayoutBuilder(
                        builder: (ctx, box) {
                          _scheduleAutoScroll(filteredKeys, box.maxWidth);
                          return GridView.builder(
                            controller: _gridScroll,
                            // 独立滚动控制器 + primary:false：本网格嵌在纵向
                            // SingleChildScrollView 内，不能与祖先抢主滚动。
                            primary: false,
                            addAutomaticKeepAlives: false,
                            scrollCacheExtent:
                                const ScrollCacheExtent.pixels(210),
                            gridDelegate:
                                const SliverGridDelegateWithMaxCrossAxisExtent(
                              maxCrossAxisExtent: 110,
                              mainAxisSpacing: 8,
                              crossAxisSpacing: 8,
                              childAspectRatio: 0.72,
                            ),
                            itemCount: filteredKeys.length,
                            itemBuilder: (ctx, i) {
                              final id = filteredKeys[i];
                              final isSelected = id == _selected;
                              final name = _catalog[id]?.name ??
                                  widget.allRoles[id] ??
                                  widget.roleName(id);
                              // 用弹窗自持的候选解析（含 _catalog / charKeys 兜底），
                              // 不依赖宿主目录是否已就绪。
                              final cands = _candidatesFor(
                                id,
                                expr: isSelected ? _exprCode : 0,
                              );
                              final thumbKey = cands.isNotEmpty
                                  ? cands.first
                                  : (_catalog[id]?.portrait ?? '');

                              return _roleCard(
                                id: id,
                                name: name,
                                isSelected: isSelected,
                                cands: cands,
                                thumbKey: thumbKey,
                                onTap: () => _selectRole(id),
                                onDoubleTap: () {
                                  _selectRole(id);
                                  _confirm();
                                },
                              );
                            },
                          );
                        },
                      ),
              ),
              const SizedBox(height: 8),

              // 3. 当前已选角色与表情摘要
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                decoration: BoxDecoration(
                  color: palette.panel,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: palette.border),
                ),
                child: Row(
                  children: [
                    Text(
                      '已选角色：',
                      style:
                          TextStyle(fontSize: 11, color: palette.textSecondary),
                    ),
                    Expanded(
                      child: Text(
                        '[$_selected] ${currentRoleName.isEmpty ? '角色' : currentRoleName}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    Text(
                      '表情：',
                      style:
                          TextStyle(fontSize: 11, color: palette.textSecondary),
                    ),
                    Text(
                      widget.emotionName(_exprCode),
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                        color: palette.accentPale,
                      ),
                    ),
                  ],
                ),
              ),

              // 4. 站位（仅当没有指定站位时展示）
              if (widget.slotIdx == null) ...[
                const SizedBox(height: 10),
                const Text('站位:', style: TextStyle(fontSize: 12)),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 6,
                  children: [0, 1, 2, 3, 4]
                      .map(
                        (s) => _StudioPill(
                          label: const ['左', '中左', '居中', '中右', '右'][s],
                          selected: _slot == s,
                          onTap: () => setState(() => _slot = s),
                        ),
                      )
                      .toList(),
                ),
              ],

              // 5. 表情选择
              const SizedBox(height: 10),
              const Text('表情:', style: TextStyle(fontSize: 12)),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: _StoryStudioEditorState._emotions
                    .map(
                      (e) => _StudioPill(
                        label: e.$2,
                        selected: _exprCode == e.$1,
                        hinted: widget.isEmotionSupported(_selected, e.$1),
                        onTap: () => setState(() => _exprCode = e.$1),
                      ),
                    )
                    .toList(),
              ),
            ],
          ),
        ),
      ),
      actions: [
        fluent.Button(
          onPressed: () async {
            await widget.onImportLocalPortrait(_selected);
            if (mounted) setState(() {});
          },
          child: const Text('从电脑选择立绘…'),
        ),
        fluent.Button(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        fluent.FilledButton(
          onPressed: _selected.isEmpty ? null : _confirm,
          child: Text(widget.confirmButtonText ?? '登场'),
        ),
      ],
    );
  }

  Widget _roleCard({
    required String id,
    required String name,
    required bool isSelected,
    required List<String> cands,
    required String thumbKey,
    required VoidCallback onTap,
    required VoidCallback onDoubleTap,
  }) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        onDoubleTap: onDoubleTap,
        child: Container(
          decoration: BoxDecoration(
            color: isSelected ? palette.tintAccent : palette.card,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: isSelected ? accentColor : palette.border,
              width: isSelected ? 2 : 1,
            ),
          ),
          padding: const EdgeInsets.all(4),
          child: Column(
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      // 旁白只有 -1。此前误把主角 0（白雨）也当旁白显示喇叭，
                      // 导致 0 的立绘永远不加载。
                      if (id == '-1')
                        Center(
                          child: Icon(
                            FluentIcons.speaker_2_24_regular,
                            size: 28,
                            color: isSelected
                                ? palette.accentPale
                                : palette.textHint,
                          ),
                        )
                      else if (cands.isNotEmpty || thumbKey.isNotEmpty)
                        TexThumb(
                          key: ValueKey(
                              'place-card-$id-${cands.isNotEmpty ? cands.first : thumbKey}'),
                          keyName: cands.isNotEmpty ? cands.first : thumbKey,
                          keyCandidates: cands,
                          fit: BoxFit.contain,
                        )
                      else
                        Center(
                          child: Icon(
                            FluentIcons.person_24_regular,
                            size: 28,
                            color: isSelected
                                ? palette.accentPale
                                : palette.textHint,
                          ),
                        ),
                      if (isSelected)
                        Positioned(
                          top: 2,
                          right: 2,
                          child: Container(
                            decoration: BoxDecoration(
                              color: accentColor,
                              shape: BoxShape.circle,
                            ),
                            padding: const EdgeInsets.all(2),
                            child: const Icon(
                              Icons.check,
                              size: 10,
                              color: Colors.white,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 2),
              Text(
                name.isEmpty ? id : name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                  color: isSelected ? palette.accentPale : palette.textHigh,
                ),
              ),
              Text(
                'ID $id',
                maxLines: 1,
                style: TextStyle(
                  fontSize: 9.5,
                  color:
                      isSelected ? palette.accentLight : palette.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
