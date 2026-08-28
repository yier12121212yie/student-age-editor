import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../../core/api_client.dart';
import '../../core/models.dart';
import '../editor/field_utils.dart';
import 'story_logic.dart';

/// 故事页：事件 → 剧情线 → 对白节点 的三栏编排视图。
///
/// 对齐官方编辑器 story.py 的 StoryProcessorWindow 体验：
/// 以 EvtCfg 事件为入口，按 ID 前缀聚合该事件的 TalkCfg 对白与 OptionCfg 选项，
/// 提供 插入/新建/删除（自动重映射跳转）/ 选项绑定 / 分支跳转 编排能力。
class StoryDirectorView extends StatefulWidget {
  const StoryDirectorView({
    super.key,
    required this.state,
    this.onPreview,
    this.classic = false,
  });
  final AppState state;

  /// 事件场景预览回调：携带事件 ID，由宿主打开预览文档。
  final ValueChanged<String>? onPreview;

  /// 经典布局：顶部事件选择 + 左侧对白线 + 中间对白编辑 + 右侧流程工具。
  final bool classic;
  @override
  State<StoryDirectorView> createState() => _StoryDirectorViewState();
}

/// TalkCfg 特化字段的中文标签（与官方 DEFAULT_TALK_KEY_MAP 对齐）。
const _talkLabels = <String, String>{
  'id': '对话ID',
  'roleIds': '说话人',
  'roleName': '自定义名字',
  'highlights': '高亮人物',
  'bg': '切换背景',
  'audio': '背景音乐',
  'content': '对话内容',
  'check': '前提判定',
  'nextTalk': '下一句ID',
  'nextTalk2': '失败跳转ID',
  'option': '按钮列表',
  'roles': '人物控制指令',
  'screenEffect': '屏幕画面特效',
  'effect': '效果代码',
  'effect2': '效果代码(失败)',
  'maxoptions': '最大选项数',
  'miniGame': '小游戏',
  'replace': '替换',
  'showTxt': '悬浮提示文本',
  'time': '时间',
  'vocals': '语音',
};

const _evtTypeDict = <int, String>{
  0: '回合开始触发',
  1: '不弹窗，可跳过，独立按钮',
  2: '只能由社交触发',
  3: '结束回合后触发',
  4: '行动触发',
  10: '不弹出，不可跳过',
  11: '约会',
  12: '篮球主线任务，条件满足自动触发',
  13: '篮球主线任务，不自动触发',
  14: '羽毛球主线任务，条件满足自动触发',
  15: '羽毛球主线任务，不自动触发',
  16: '长跑主线人物，条件满足自动触发',
  17: '长跑主线任务，不自动触发',
  20: '关系任务',
  21: '打招呼',
  22: '话题',
  30: '点击场景物品触发',
  36: '漫展',
  37: '生日派对',
  38: '上海世博会',
  40: '考试',
  41: '考试后，放榜前，点击查看成绩按钮触发',
  42: '学习',
  50: '通知',
  51: '流程',
  60: '状态',
  61: '路人',
  62: '点击物品触发',
  63: '路人-每回合检查，条件符合才出现',
  70: '玩家打电话',
  71: '玩家接电话',
  80: '新闻',
  90: '节日',
  101: '不弹窗，不可跳过，独立按钮',
  102: '不弹出，不可跳过，精力≤20才显示',
  104: '捣蛋事件',
  110: '送礼',
  131: '社团活动事件',
  200: '人生轨迹',
  500: '高考',
  520: '表白',
  521: '由情侣看电影行动触发',
  522: '恋爱社交（社交按钮触发）',
  523: '生日礼物（送礼按钮触发）',
  750: '学习',
  801: '家',
  802: '学校教学楼',
  803: '学校操场',
  804: '欣欣小卖部',
  805: '百乐门游戏厅',
  806: '新华书店',
  807: '好宜多商场',
  808: '星河电影院',
  811: '长隆游乐园',
  817: '双子峰',
  901: '家',
  902: '学校教学楼',
  903: '学校操场',
  904: '欣欣小卖部',
  905: '百乐门游戏厅',
  906: '新华书店',
  907: '好宜多商场',
  908: '星河电影院',
  911: '长隆游乐园',
  917: '双子峰',
};

class _StoryDirectorViewState extends State<StoryDirectorView> {
  bool _loaded = false;
  String? _error;

  Map<String, dynamic> _evtCfg = {};
  Map<String, dynamic> _talkCfg = {};
  Map<String, dynamic> _optCfg = {};
  Map<String, dynamic> _personCfg = {};
  Map<String, dynamic> _bgCfg = {};
  Map<String, dynamic> _audioCfg = {};
  Map<String, dynamic> _evtTypeCfg = {};

  /// 当前事件相关数据。
  String? _evtId;
  List<String> _prefixes = const [];
  Map<String, dynamic> _stageTalks = {};
  Map<String, dynamic> _stageOpts = {};
  Map<String, dynamic> _talkBaseline = {};
  Map<String, dynamic> _optBaseline = {};

  String? _talkId;
  final Set<String> _selectedTalkIds = {};
  bool _dirty = false;
  bool _switching = false; // _selectEvent 防重入
  bool _addingEvent = false; // _addEvent 防重入（双击不建两个事件）
  bool _deletingEvent = false; // _deleteEvent 防重入（双击不叠两个确认框）
  String _evtSearch = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  KeyTranslator get translator => KeyTranslator(widget.state);

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
        'EvtTypeCfg',
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
        _evtTypeCfg = _asMap(results[6]['data']);
        _loaded = true;
      });
      // 默认选中第一个事件（首次加载无未保存修改，不会弹确认框）
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

  Map<String, dynamic> _asMap(dynamic v) =>
      v is Map ? v.cast<String, dynamic>() : <String, dynamic>{};

  // ---------- 事件维度 ----------

  /// 切换当前事件。存在未保存的对白/选项修改时先征求用户意见，
  /// 避免切换事件导致舞台数据静默丢失（保存 / 放弃 / 取消）；
  /// 保存失败时中止切换。调用方已在外部处理未保存状态时可传 [skipDirtyCheck]。
  Future<void> _selectEvent(String evtId, {bool skipDirtyCheck = false}) async {
    if (_switching) return; // 防重入：避免快速连点叠加多个确认对话框
    // 点击当前已选中事件：无需切换；直接返回可避免 setState 重载舞台，
    // 否则会把未保存修改（尚未 merge 回 _talkCfg）静默冲掉。
    if (evtId == _evtId) return;
    _switching = true;
    try {
      if (!skipDirtyCheck && _dirty && _evtId != null && _evtId != evtId) {
        final choice = await _confirmSaveDiscard();
        if (!mounted || choice == null || choice == 'cancel') return;
        if (choice == 'save') {
          final saved = await _save();
          if (!mounted || !saved) return; // 保存失败：中止切换，保留现场
        }
      }
      if (!mounted) return;
      setState(() {
        _evtId = evtId;
        _talkId = null;
        _selectedTalkIds.clear();
        _prefixes = storyRelatedPrefixes(evtId, _evtCfg);
        _stageTalks = stageOf(_talkCfg, _prefixes);
        _stageOpts = stageOf(_optCfg, _prefixes, isOption: true);
        _talkBaseline = stageOf(_talkCfg, _prefixes);
        _optBaseline = stageOf(_optCfg, _prefixes, isOption: true);
        _dirty = false;
        if (_stageTalks.isNotEmpty) {
          final keys = _stageTalks.keys.toList()..sort(compareIds);
          _talkId = keys.first;
        }
      });
    } finally {
      _switching = false;
    }
  }

  String _evtTypeName(String evtId) {
    final info = _evtCfg[evtId];
    if (info is Map) {
      final t = info['type'];
      final n = t is num ? t.toInt() : int.tryParse(cln(t));
      if (n != null) {
        final custom = _evtTypeCfg[n.toString()];
        if (custom is Map &&
            custom['name'] is String &&
            (custom['name'] as String).isNotEmpty) {
          return custom['name'] as String;
        }
        return _evtTypeDict[n] ?? '类型$n';
      }
    }
    return '';
  }

  Future<void> _addEvent() async {
    if (_addingEvent) return; // 防重入：快速双击不重复建事件/叠确认框
    _addingEvent = true;
    try {
      // 先处理当前事件的未保存修改：干净状态直接继续；
      // 有修改时弹三选确认，保存失败则中止，避免误弹框与新事件丢失标记。
      if (_dirty && _evtId != null) {
        final choice = await _confirmSaveDiscard();
        if (!mounted || choice == null || choice == 'cancel') return;
        if (choice == 'save') {
          final saved = await _save();
          if (!mounted || !saved) return;
        }
      }
      if (!mounted) return;
      // 官方规则：事件 ID 范围 8000~8999。
      // 优先取区间内最大 ID + 1；区间内全部占用时从 9000 起向上寻找
      // （保证终止，避免旧实现把 8000-8999 全占用时的 while 循环推到区间外）。
      var id = 8000;
      final nums = _evtCfg.keys.map(int.tryParse).whereType<int>().toSet();
      final inRange = nums.where((n) => n >= 8000 && n <= 8999).toList();
      if (inRange.isNotEmpty) {
        id = inRange.reduce((a, b) => a > b ? a : b) + 1;
      }
      while (id <= 8999 && nums.contains(id)) {
        id++;
      }
      if (id > 8999) {
        id = 8000;
        while (id <= 8999 && nums.contains(id)) {
          id++;
        }
        if (id > 8999) {
          // 8000-8999 全部占用：向上分配（与区间外事件 ID 共存）
          id = 9000;
          while (nums.contains(id)) {
            id++;
          }
        }
      }
      final newId = id.toString();
      setState(() {
        _evtCfg[newId] = {
          'id': id,
          'title': '新事件',
          'type': 0,
          'talkId': <dynamic>[],
        };
        _dirty = false; // 旧事件修改已处理；新事件暂无内容
      });
      _selectEvent(newId, skipDirtyCheck: true);
    } finally {
      _addingEvent = false;
    }
  }

  Future<void> _deleteEvent() async {
    if (_deletingEvent) return; // 防重入：快速双击不叠两个确认框
    _deletingEvent = true;
    try {
      final evtId = _evtId;
      if (evtId == null) return;
      final confirmed = await _confirm(
        '删除事件',
        '确认删除事件 [$evtId] 吗？\n（仅删除 EvtCfg 记录，其剧情线 TalkCfg/OptionCfg 对白不会被删除）',
      );
      if (!confirmed || !mounted) return;
      setState(() {
        _evtCfg.remove(evtId);
        _evtId = null;
        _talkId = null;
        _selectedTalkIds.clear();
        _stageTalks = {};
        _stageOpts = {};
        _dirty = true;
      });
      if (_evtCfg.isNotEmpty) {
        final keys = _evtCfg.keys.toList()..sort(compareEventIds);
        await _selectEvent(keys.first);
        // _selectEvent 会重置 _dirty；删除事件本身是未保存修改，需保留标记
        if (mounted) setState(() => _dirty = true);
      }
    } finally {
      _deletingEvent = false;
    }
  }

  // ---------- 剧情线操作 ----------

  List<String> _eventTalkIds() {
    final keys = _stageTalks.keys.toList()..sort(compareIds);
    return keys;
  }

  String _talkDisplayName(String talkId) {
    final t = _stageTalks[talkId];
    if (t is! Map) return '旁白';
    final roleName = cln(t['roleName']);
    if (roleName.isNotEmpty) return roleName;
    final roleIds = ensureList(t['roleIds']);
    if (roleIds.isEmpty) return '旁白';
    final names = roleIds
        .map((id) => _roleName(id))
        .where((n) => n.isNotEmpty)
        .toList();
    return names.isEmpty ? 'NPC' : names.join('、');
  }

  String _roleName(String id) {
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
        if (k.isNotEmpty && k != '-1' && k != '0' && k != '00' && k != '000') {
          map[k] = e.value.toString();
        }
      }
    }
    for (final e in _personCfg.entries) {
      final k = e.key.toString().trim();
      if (k.isEmpty || k == '-1' || k == '0') continue;
      final p = e.value;
      if (p is Map && p['name'] != null && p['name'].toString().isNotEmpty) {
        map[k] = p['name'].toString();
      } else if (!map.containsKey(k)) {
        map[k] = '角色 $k';
      }
    }
    return map;
  }

  void _insertTalk() {
    final cur = _talkId;
    if (cur == null) return;
    final newId = insertTalkId(cur, _stageTalks);
    if (newId.isEmpty) return;
    final curTalk = _stageTalks[cur];
    final next = normalizeStoryIdList(
      curTalk is Map ? curTalk['nextTalk'] : null,
    );
    setState(() {
      _stageTalks[newId] = buildInsertedTalkRecord(curTalk, newId, next);
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
        // 无当前对白：把新对白设为事件首句
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
          final later =
              _eventTalkIds()
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
    final newOptId = _allocOptionIdForTalk(pfx, used, talk);
    if (newOptId == null) return;
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

  /// 分配未占用的选项 ID（超出 99 个或重复时提示并返回 null）。
  String? _allocOptionIdForTalk(String pfx, Set<String> used, Map talk) {
    var id = allocOptionId(pfx, used);
    if (id == null) {
      _showInfo('提示', '按钮数量已超 99，请直接在选项表修改 ID。');
      return null;
    }
    final existingIds = normalizeStoryIdList(talk['option']).map(cln).toSet();
    if (existingIds.contains(id)) {
      final realloc = allocOptionId(pfx, {...used, id});
      if (realloc == null) return null;
      id = realloc;
    }
    return id;
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

  // ---------- 保存 ----------

  /// 保存全部修改；成功返回 true，失败返回 false（由调用方决定是否继续切换）。
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
      await ApiClient.instance.put(
        '/api/cfg/TalkCfg',
        body: {'data': _talkCfg},
      );
      await ApiClient.instance.put(
        '/api/cfg/OptionCfg',
        body: {'data': _optCfg},
      );
      await ApiClient.instance.put('/api/cfg/EvtCfg', body: {'data': _evtCfg});
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

  /// 未保存修改的三选确认：返回 'save' | 'discard' | 'cancel'（null）。
  Future<String?> _confirmSaveDiscard() async {
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
          style: const TextStyle(color: Color(0xFF9B9BA3), fontSize: 13),
        ),
      );
    }
    // 三栏固定宽度，窄窗口（AI 面板挤占）时横向滚动，避免 Row 溢出崩溃
    if (widget.classic) return _buildClassicStory();
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildEventList(),
          const VerticalDivider(width: 1, color: Color(0xFF2A2A2E)),
          _buildStoryLine(),
          const VerticalDivider(width: 1, color: Color(0xFF2A2A2E)),
          SizedBox(width: 420, child: _buildTalkEditor()),
        ],
      ),
    );
  }

  int _stageIndex = 0;
  static const _stages = ['小学立绘比例', '初中立绘比例', '高中立绘比例', '默认立绘比例'];

  /// 经典剧情处理器（三栏式类友商工作流）：
  /// 左栏事件对话线 | 中间顶部配置 + 可视化舞台站位/表情/动作交互区 + 底部对白 | 右栏流程操作 + 场景控制 + 玩家选项 + 保存。
  Widget _buildClassicStory() {
    final curTalk = _talkId != null && _stageTalks.containsKey(_talkId)
        ? (_stageTalks[_talkId] as Map?)?.cast<String, dynamic>()
        : null;

    return Column(
      children: [
        // 顶部标题与快速事件切换栏
        Container(
          height: 48,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          decoration: const BoxDecoration(
            color: Color(0xFF1B1B1F),
            border: Border(bottom: BorderSide(color: Color(0xFF2A2A2E))),
          ),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                const Text('🎬', style: TextStyle(fontSize: 16)),
                const SizedBox(width: 8),
                Text(
                  '剧情处理器 - 正在编辑事件 [${_evtId ?? '8000'}]',
                  style: const TextStyle(
                    fontSize: 13.5,
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(width: 16),
                const Text('切换事件:', style: TextStyle(fontSize: 11.5, color: Color(0xFF9B9BA3))),
                const SizedBox(width: 6),
                SizedBox(
                  width: 140,
                  height: 34,
                  child: fluent.ComboBox<String>(
                    value: _evtCfg.containsKey(_evtId) ? _evtId : (_evtCfg.keys.isNotEmpty ? _evtCfg.keys.first : null),
                    isExpanded: true,
                    items: _evtCfg.keys.map((k) {
                      final t = _evtTitle(k);
                      return fluent.ComboBoxItem(
                        value: k,
                        child: Text('[$k] ${t.isEmpty ? '事件' : t}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11.5)),
                      );
                    }).toList(),
                    onChanged: (v) {
                      if (v != null) _selectEvent(v);
                    },
                  ),
                ),
                const SizedBox(width: 16),
                _smallButton(
                  '当前阶段：${_stages[_stageIndex]}',
                  () => setState(() => _stageIndex = (_stageIndex + 1) % _stages.length),
                  icon: FluentIcons.arrow_sync_24_regular,
                ),
                const SizedBox(width: 8),
                _smallButton(
                  '▶ 运行态预览',
                  _evtId == null || widget.onPreview == null ? () {} : () => widget.onPreview!(_evtId!),
                  icon: FluentIcons.play_24_regular,
                ),
                const SizedBox(width: 8),
                _smallButton(
                  '💾 保存修改',
                  _save,
                  icon: FluentIcons.save_24_regular,
                  primary: true,
                ),
              ],
            ),
          ),
        ),
        // 下方三栏体系
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 1. 左栏：事件对话线
              SizedBox(
                width: 270,
                child: _buildClassicDialogueLine(),
              ),
              const VerticalDivider(width: 1, color: Color(0xFF2A2A2E)),
              // 2. 中栏：配置 + 可视化舞台与角色编辑 + 底部对话
              Expanded(
                flex: 7,
                child: _buildClassicCenterStage(curTalk),
              ),
              const VerticalDivider(width: 1, color: Color(0xFF2A2A2E)),
              // 3. 右栏：流程操作 + 场景人物控制 + 玩家选项配置
              SizedBox(
                width: 320,
                child: _buildClassicRightPanel(curTalk),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 左栏：事件对话线
  Widget _buildClassicDialogueLine() {
    final talkIds = _eventTalkIds();
    return Column(
      children: [
        Container(
          height: 38,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: const BoxDecoration(
            color: Color(0xFF1E1E23),
            border: Border(bottom: BorderSide(color: Color(0xFF2E2E35))),
          ),
          child: Row(
            children: [
              const Text('💭', style: TextStyle(fontSize: 14)),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '事件 ${_evtId ?? ''} 的对话线 (${talkIds.length})',
                  style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold, color: Colors.white),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: talkIds.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(FluentIcons.chat_empty_24_regular, size: 32, color: Color(0xFF4A4A52)),
                      const SizedBox(height: 8),
                      const Text('该事件暂无对话', style: TextStyle(color: Color(0xFF6E6E76), fontSize: 12)),
                      const SizedBox(height: 10),
                      fluent.FilledButton(
                        onPressed: _appendTalk,
                        child: const Text('➕ 新建对话'),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  itemCount: talkIds.length,
                  itemBuilder: (context, i) {
                    final id = talkIds[i];
                    return _buildClassicTalkNode(id);
                  },
                ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          color: const Color(0xFF18181C),
          child: Row(
            children: [
              const Text('💡', style: TextStyle(fontSize: 12)),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '按住 Shift 可多选，右侧可批量删除。\n当前阶段：${_stages[_stageIndex]}',
                  style: const TextStyle(fontSize: 10.5, color: Color(0xFF8B8B93), height: 1.3),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildClassicTalkNode(String id) {
    final talk = _stageTalks[id];
    final isCurrent = id == _talkId;
    final selected = _selectedTalkIds.contains(id);
    final opts = ensureList(talk is Map ? talk['option'] : null);
    final hasBranch = opts.isNotEmpty ||
        (talk is Map &&
            (talk['check'] != null ||
                (talk['nextTalk2'] is List && (talk['nextTalk2'] as List).isNotEmpty)));

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _selectTalk(id),
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: selected ? const Color(0xFF332F4C) : (isCurrent ? const Color(0xFF26262B) : const Color(0xFF1E1E23)),
            borderRadius: BorderRadius.circular(5),
            border: Border.all(
              color: isCurrent
                  ? const Color(0xFF6C5CE7)
                  : (selected ? const Color(0xFF4A3DB8) : const Color(0xFF2E2E35)),
              width: isCurrent ? 1.5 : 1,
            ),
          ),
          child: Row(
            children: [
              Icon(
                hasBranch ? FluentIcons.branch_fork_24_regular : FluentIcons.chat_24_regular,
                size: 14,
                color: hasBranch ? const Color(0xFFE08A3C) : (isCurrent ? const Color(0xFF6C5CE7) : const Color(0xFF6E6E76)),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '[$id] ${_talkDisplayName(id)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: isCurrent ? Colors.white : const Color(0xFFD4D4D8),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      cln(talk is Map ? talk['content'] : ''),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11, color: Color(0xFF8B8B93)),
                    ),
                  ],
                ),
              ),
              if (opts.isNotEmpty)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                  decoration: BoxDecoration(
                    color: const Color(0xFF332617),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    '${opts.length}选',
                    style: const TextStyle(fontSize: 9.5, color: Color(0xFFE0A454)),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 中栏：顶部参数配置 + 可视化舞台与角色编辑 + 底部对白
  Widget _buildClassicCenterStage(Map<String, dynamic>? talk) {
    if (talk == null) {
      return const Center(
        child: Text('请在左侧选择一句对话以开启舞台编辑', style: TextStyle(color: Color(0xFF6E6E76), fontSize: 13)),
      );
    }

    final bgVal = cln(talk['bg']);
    final audioVal = cln(talk['audio']);
    final roleIds = ensureList(talk['roleIds']);
    final highlights = ensureList(talk['highlights']);
    final roleName = cln(talk['roleName']);
    final nextTalk = ensureList(talk['nextTalk']).join(',');
    final hasCheck = talk['check'] != null && talk['check'].toString().isNotEmpty && talk['check'].toString() != '[]';

    return Container(
      color: const Color(0xFF131316),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 顶部参数卡片
          Container(
            margin: const EdgeInsets.fromLTRB(10, 10, 10, 6),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: const Color(0xFF1E1E23),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFF2E2E35)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 第一行：背景 + 背景音乐
                Row(
                  children: [
                    const Flexible(
                      child: Text('背景:',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 12, color: Color(0xFF9B9BA3))),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      flex: 5,
                      child: SizedBox(
                        height: 34,
                        child: fluent.ComboBox<String>(
                          value: _allBgs().containsKey(bgVal) ? bgVal : null,
                          placeholder: const Text('客厅 (100) / 选择背景', style: TextStyle(fontSize: 11.5)),
                          isExpanded: true,
                          items: [
                            const fluent.ComboBoxItem(value: '', child: Text('延续上文 / 默认背景', style: TextStyle(fontSize: 11.5))),
                            ..._allBgs().entries.map((e) {
                              return fluent.ComboBoxItem(
                                value: e.key,
                                child: Text('${e.value} (${e.key})', style: const TextStyle(fontSize: 11.5)),
                              );
                            }),
                          ],
                          onChanged: (v) {
                            setState(() {
                              talk['bg'] = (v == null || v.isEmpty) ? null : (int.tryParse(v) ?? v);
                              _dirty = true;
                            });
                          },
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    const Flexible(
                      child: Text('背景音乐(audio):',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 12, color: Color(0xFF9B9BA3))),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      flex: 6,
                      child: SizedBox(
                        height: 34,
                        child: fluent.ComboBox<String>(
                          value: _allAudios().containsKey(audioVal) ? audioVal : null,
                          placeholder: const Text('[延续上文/无更改]', style: TextStyle(fontSize: 11.5)),
                          isExpanded: true,
                          items: [
                            const fluent.ComboBoxItem(value: '', child: Text('[延续上文/无更改]', style: TextStyle(fontSize: 11.5))),
                            ..._allAudios().entries.map((e) {
                              return fluent.ComboBoxItem(
                                value: e.key,
                                child: Text('${e.value} (${e.key})', style: const TextStyle(fontSize: 11.5)),
                              );
                            }),
                          ],
                          onChanged: (v) {
                            setState(() {
                              talk['audio'] = (v == null || v.isEmpty) ? null : (int.tryParse(v) ?? v);
                              _dirty = true;
                            });
                          },
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    _smallButton('▶ 试听', () {
                      fluent.displayInfoBar(
                        context,
                        builder: (ctx, close) => fluent.InfoBar(
                          title: Text('试听背景音乐: ${audioVal.isEmpty ? '延续上文' : audioVal}'),
                          severity: fluent.InfoBarSeverity.info,
                        ),
                      );
                    }),
                  ],
                ),
                const SizedBox(height: 8),
                // 第二行：说话人 + 高亮人物 + 实际显示名称
                Row(
                  children: [
                    const Flexible(
                      child: Text('说话人(逗号隔开):',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 12, color: Color(0xFF9B9BA3))),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      flex: 4,
                      child: SizedBox(
                        height: 32,
                        child: fluent.TextBox(
                          placeholder: '输入名字检索...',
                          controller: TextEditingController(text: roleIds.join(',')),
                          onChanged: (v) {
                            final list = v.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).map((s) => int.tryParse(s) ?? s).toList();
                            talk['roleIds'] = list;
                            _dirty = true;
                          },
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    const Flexible(
                      child: Text('高亮人物(逗号隔开):',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 12, color: Color(0xFF9B9BA3))),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      flex: 4,
                      child: SizedBox(
                        height: 32,
                        child: fluent.TextBox(
                          placeholder: '输入名字检索...',
                          controller: TextEditingController(text: highlights.join(',')),
                          onChanged: (v) {
                            final list = v.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).map((s) => int.tryParse(s) ?? s).toList();
                            talk['highlights'] = list;
                            _dirty = true;
                          },
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    const Flexible(
                      child: Text('实际显示名称:',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 12, color: Color(0xFF9B9BA3))),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      flex: 3,
                      child: SizedBox(
                        height: 32,
                        child: fluent.TextBox(
                          controller: TextEditingController(text: roleName),
                          placeholder: '自定义名称',
                          onChanged: (v) {
                            talk['roleName'] = v.trim();
                            _dirty = true;
                          },
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                // 分支与跳转
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: const Color(0xFF26262B),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: const Color(0xFF3A3A42)),
                  ),
                  child: Row(
                    children: [
                      const Flexible(
                        child: Text('🔀 分支与跳转',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 12, color: Color(0xFFE08A3C), fontWeight: FontWeight.bold)),
                      ),
                      const SizedBox(width: 14),
                      Flexible(
                        child: fluent.Checkbox(
                          checked: hasCheck,
                          onChanged: (v) {
                            setState(() {
                              talk['check'] = (v ?? false) ? ['has_score>=60'] : null;
                              _dirty = true;
                            });
                          },
                          content: const Text('开启前提分支判定', style: TextStyle(fontSize: 11.5, color: Color(0xFFC8C8CF))),
                        ),
                      ),
                      const SizedBox(width: 16),
                      const Flexible(
                        child: Text('下一句对话ID:',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 12, color: Color(0xFF9B9BA3))),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: SizedBox(
                          height: 30,
                          child: fluent.TextBox(
                            controller: TextEditingController(text: nextTalk),
                            placeholder: '如: 8002 (空则顺延)',
                            onChanged: (v) {
                              final list = v.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).map((s) => int.tryParse(s) ?? s).toList();
                              talk['nextTalk'] = list;
                              _dirty = true;
                            },
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          // 核心：可视化舞台区（站位与表情动作直接交互）
          Expanded(
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(
                color: const Color(0xFF18181C),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFF2E2E35)),
              ),
              child: _buildVisualStage(talk),
            ),
          ),

          // 底部对白输入区
          Container(
            margin: const EdgeInsets.all(10),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: const Color(0xFF1E1E23),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFF2E2E35)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        '【${_talkDisplayName(_talkId ?? '')}】',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFFE08A3C),
                        ),
                      ),
                    ),
                    const Spacer(),
                    const Text('对话内容 (content):', style: TextStyle(fontSize: 11.5, color: Color(0xFF9B9BA3))),
                  ],
                ),
                const SizedBox(height: 6),
                SizedBox(
                  height: 90,
                  child: fluent.TextBox(
                    key: ValueKey('content_box_$_talkId'),
                    controller: TextEditingController(text: cln(talk['content'])),
                    expands: true,
                    maxLines: null,
                    textAlignVertical: TextAlignVertical.top,
                    placeholder: '请输入此句对话的台词内容…',
                    onChanged: (v) {
                      talk['content'] = v;
                      _dirty = true;
                    },
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 🎮 可视化舞台：5 个站位槽位，支持直接点击设定角色、表情代码与站位移动
  Widget _buildVisualStage(Map<String, dynamic> talk) {
    final rawRoles = ensureList(talk['roles']);
    final activeRoleIds = ensureList(talk['roleIds']);
    final highlights = ensureList(talk['highlights']).toSet();

    // 槽位映射：0=左, 1=中偏左, 2=居中, 3=中偏右, 4=右
    final slots = <int, _StageRoleInfo>{};

    // 解析当前角色与站位
    var fallbackSlot = 1;
    for (final r in rawRoles) {
      final parts = r.split(',');
      if (parts.length >= 3) {
        final slot = int.tryParse(parts[0].trim()) ?? 2;
        final code = parts[1].trim();
        final action = parts.length > 2 ? parts[2].trim() : '3000';
        slots[slot] = _StageRoleInfo(
          roleId: code,
          slot: slot,
          actionCode: action,
          isHighlight: highlights.contains(code),
        );
      }
    }

    // 若 roles 字段为空，按 roleIds 默认放置
    if (slots.isEmpty && activeRoleIds.isNotEmpty) {
      for (final rid in activeRoleIds) {
        slots[fallbackSlot % 5] = _StageRoleInfo(
          roleId: rid,
          slot: fallbackSlot % 5,
          actionCode: '3000',
          isHighlight: highlights.contains(rid) || highlights.isEmpty,
        );
        fallbackSlot += 2;
      }
    }

    return Column(
      children: [
        // 舞台顶端状态栏
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: const BoxDecoration(
            color: Color(0xFF222228),
            borderRadius: BorderRadius.only(topLeft: Radius.circular(8), topRight: Radius.circular(8)),
          ),
          child: Row(
            children: [
              const Icon(FluentIcons.video_24_regular, size: 14, color: Color(0xFF6C5CE7)),
              const SizedBox(width: 6),
              const Text('🎭 舞台站位与表情动作预览区', style: TextStyle(fontSize: 12, color: Colors.white, fontWeight: FontWeight.w600)),
              const Spacer(),
              _smallButton('➕ 放置角色', () => _showAddStageRoleDialog(talk)),
              const SizedBox(width: 6),
              _smallButton('🔄 重置站位', () {
                setState(() {
                  talk['roles'] = <dynamic>[];
                  _dirty = true;
                });
              }),
            ],
          ),
        ),
        // 5 站位主舞台
        Expanded(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  const Color(0xFF141418),
                  const Color(0xFF1E1E26),
                  const Color(0xFF101014),
                ],
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: List.generate(5, (slotIdx) {
                final role = slots[slotIdx];
                return Expanded(
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 4),
                    child: _buildStageSlot(slotIdx, role, talk),
                  ),
                );
              }),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildStageSlot(int slotIdx, _StageRoleInfo? role, Map<String, dynamic> talk) {
    const slotNames = ['站位 0 (左)', '站位 1 (中左)', '站位 2 (居中)', '站位 3 (中右)', '站位 4 (右)'];

    if (role == null) {
      return MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _showPlaceRoleToSlotDialog(slotIdx, talk),
          child: Container(
            decoration: BoxDecoration(
              color: const Color(0xFF17171C).withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: const Color(0xFF2E2E35), style: BorderStyle.solid),
            ),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(FluentIcons.add_circle_24_regular, size: 24, color: Color(0xFF4A4A52)),
                  const SizedBox(height: 6),
                  Text(
                    slotNames[slotIdx],
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 10.5, color: Color(0xFF6E6E76)),
                  ),
                  const SizedBox(height: 2),
                  const Text('点击放置', style: TextStyle(fontSize: 9.5, color: Color(0xFF4A4A52))),
                ],
              ),
            ),
          ),
        ),
      );
    }

    final roleName = _roleName(role.roleId);
    final emotionName = _getEmotionName(role.actionCode);

    return Container(
      decoration: BoxDecoration(
        color: role.isHighlight ? const Color(0xFF2D2644) : const Color(0xFF222228),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: role.isHighlight ? const Color(0xFF6C5CE7) : const Color(0xFF3A3A42),
          width: role.isHighlight ? 2 : 1,
        ),
      ),
      padding: const EdgeInsets.all(6),
      child: Column(
        children: [
          // 角色名称与操作
          Row(
            children: [
              Expanded(
                child: Text(
                  roleName.isNotEmpty ? roleName : '角色 ${role.roleId}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: role.isHighlight ? Colors.white : const Color(0xFFD4D4D8),
                  ),
                ),
              ),
              MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {
                    setState(() {
                      final roles = ensureList(talk['roles']).where((r) => !r.startsWith('$slotIdx,')).toList();
                      talk['roles'] = roles;
                      _dirty = true;
                    });
                  },
                  child: const Icon(FluentIcons.dismiss_16_regular, size: 12, color: Color(0xFF8B8B93)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          // 立绘头像框
          Expanded(
            child: Container(
              width: double.infinity,
              decoration: BoxDecoration(
                color: const Color(0xFF18181C),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      FluentIcons.person_24_filled,
                      size: 36,
                      color: role.isHighlight ? const Color(0xFF8B7FEF) : const Color(0xFF6E6E76),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      slotNames[slotIdx],
                      style: const TextStyle(fontSize: 9.5, color: Color(0xFF6E6E76)),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          // 表情/动作徽章（点击修改）
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => _showEditRoleActionDialog(slotIdx, role, talk),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
                decoration: BoxDecoration(
                  color: const Color(0xFF2C283E),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: const Color(0xFF5A4EB8)),
                ),
                child: Text(
                  '🎭 $emotionName (${role.actionCode})',
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 10, color: Color(0xFFC7C0F9), fontWeight: FontWeight.w500),
                ),
              ),
            ),
          ),
          const SizedBox(height: 4),
          // 移动站位按钮组
          Row(
            children: [
              Expanded(
                child: _miniShiftButton(
                  '◀',
                  slotIdx > 0 ? () => _shiftRoleSlot(slotIdx, slotIdx - 1, role, talk) : null,
                ),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: _miniShiftButton(
                  '高亮',
                  () {
                    setState(() {
                      final h = ensureList(talk['highlights']);
                      if (h.contains(role.roleId)) {
                        h.remove(role.roleId);
                      } else {
                        h.add(role.roleId);
                      }
                      talk['highlights'] = h.map((e) => int.tryParse(e) ?? e).toList();
                      _dirty = true;
                    });
                  },
                ),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: _miniShiftButton(
                  '▶',
                  slotIdx < 4 ? () => _shiftRoleSlot(slotIdx, slotIdx + 1, role, talk) : null,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _miniShiftButton(String text, VoidCallback? onTap) {
    final enabled = onTap != null;
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 2),
          decoration: BoxDecoration(
            color: enabled ? const Color(0xFF26262B) : const Color(0xFF1E1E23),
            borderRadius: BorderRadius.circular(3),
            border: Border.all(color: const Color(0xFF3A3A42)),
          ),
          child: Text(
            text,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 9.5, color: enabled ? const Color(0xFFD4D4D8) : const Color(0xFF4A4A52)),
          ),
        ),
      ),
    );
  }

  String _getEmotionName(String code) {
    switch (code) {
      case '3000':
        return '普通';
      case '3001':
        return '开心';
      case '3002':
        return '生气';
      case '3003':
        return '悲伤';
      case '3004':
        return '害羞';
      case '3005':
        return '惊讶';
      case '3006':
        return '得意';
      case '3007':
        return '叹气';
      default:
        return code.startsWith('30') ? '动作 $code' : code;
    }
  }

  void _shiftRoleSlot(int oldSlot, int newSlot, _StageRoleInfo role, Map<String, dynamic> talk) {
    setState(() {
      final currentRoles = ensureList(talk['roles']).where((r) => !r.startsWith('$oldSlot,') && !r.startsWith('$newSlot,')).toList();
      currentRoles.add('$newSlot,${role.roleId},${role.actionCode}');
      talk['roles'] = currentRoles;
      _dirty = true;
    });
  }

  Future<void> _showPlaceRoleToSlotDialog(int slotIdx, Map<String, dynamic> talk) async {
    final allRoles = _allRoles();
    final personKeys = allRoles.keys.toList()..sort((a, b) {
      final na = int.tryParse(a);
      final nb = int.tryParse(b);
      if (na != null && nb != null) return na.compareTo(nb);
      if (na != null) return -1;
      if (nb != null) return 1;
      return a.compareTo(b);
    });

    final currentTalkRoles = ensureList(talk['roleIds'])
        .map((e) => e.toString().trim())
        .where((e) => e.isNotEmpty && e != '-1' && e != '0')
        .toList();

    String selectedPerson;
    if (currentTalkRoles.isNotEmpty && personKeys.contains(currentTalkRoles.first)) {
      selectedPerson = currentTalkRoles.first;
    } else if (personKeys.contains('10')) {
      selectedPerson = '10';
    } else if (personKeys.isNotEmpty) {
      selectedPerson = personKeys.first;
    } else {
      selectedPerson = '1';
    }

    var actionCode = '3000';

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => fluent.ContentDialog(
          title: Text('放置角色到 站位 $slotIdx'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('选择角色:', style: TextStyle(fontSize: 12)),
              const SizedBox(height: 6),
              fluent.ComboBox<String>(
                value: personKeys.contains(selectedPerson) ? selectedPerson : (personKeys.isNotEmpty ? personKeys.first : null),
                placeholder: const Text('请选择角色', style: TextStyle(fontSize: 12)),
                isExpanded: true,
                items: personKeys.map((k) {
                  final name = allRoles[k] ?? _roleName(k);
                  return fluent.ComboBoxItem(
                    value: k,
                    child: Text('[$k] ${name.isNotEmpty ? name : '角色'}', style: const TextStyle(fontSize: 12)),
                  );
                }).toList(),
                onChanged: (v) {
                  if (v != null) setDialogState(() => selectedPerson = v);
                },
              ),
              const SizedBox(height: 12),
              const Text('表情与动作 (30xx):', style: TextStyle(fontSize: 12)),
              const SizedBox(height: 6),
              fluent.TextBox(
                controller: TextEditingController(text: actionCode),
                onChanged: (v) => actionCode = v.trim(),
                placeholder: '如 3000(普通), 3001(开心), 3002(生气)',
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  ('3000', '普通'),
                  ('3001', '开心'),
                  ('3002', '生气'),
                  ('3003', '悲伤'),
                  ('3004', '害羞'),
                  ('3005', '惊讶'),
                  ('3006', '得意'),
                  ('3007', '叹气'),
                ].map((pair) {
                  return _ActionPill(
                    label: '${pair.$2} (${pair.$1})',
                    primary: actionCode == pair.$1,
                    onPressed: () {
                      setDialogState(() => actionCode = pair.$1);
                    },
                  );
                }).toList(),
              ),
            ],
          ),
          actions: [
            fluent.Button(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('取消'),
            ),
            fluent.FilledButton(
              onPressed: () {
                setState(() {
                  final roles = ensureList(talk['roles']).where((r) => !r.startsWith('$slotIdx,')).toList();
                  roles.add('$slotIdx,$selectedPerson,$actionCode');
                  talk['roles'] = roles;
                  _dirty = true;
                });
                Navigator.of(ctx).pop();
              },
              child: const Text('确定放置'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showAddStageRoleDialog(Map<String, dynamic> talk) async {
    await _showPlaceRoleToSlotDialog(2, talk);
  }

  Future<void> _showEditRoleActionDialog(int slotIdx, _StageRoleInfo role, Map<String, dynamic> talk) async {
    var actionCode = role.actionCode;
    await showDialog(
      context: context,
      builder: (ctx) => fluent.ContentDialog(
        title: Text('修改 角色 [${role.roleId}] 动作与表情'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('常用表情代码预设:', style: TextStyle(fontSize: 12, color: Color(0xFF9B9BA3))),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                ('3000', '普通'),
                ('3001', '开心'),
                ('3002', '生气'),
                ('3003', '悲伤'),
                ('3004', '害羞'),
                ('3005', '惊讶'),
                ('3006', '得意'),
                ('3007', '叹气'),
              ].map((pair) {
                return _ActionPill(
                  label: '${pair.$2} (${pair.$1})',
                  primary: actionCode == pair.$1,
                  onPressed: () {
                    setState(() {
                      final roles = ensureList(talk['roles']).where((r) => !r.startsWith('$slotIdx,')).toList();
                      roles.add('$slotIdx,${role.roleId},${pair.$1}');
                      talk['roles'] = roles;
                      _dirty = true;
                    });
                    Navigator.of(ctx).pop();
                  },
                );
              }).toList(),
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

  /// 3. 右栏：流程操作 + 场景人物控制 + 玩家选项配置
  Widget _buildClassicRightPanel(Map<String, dynamic>? talk) {
    final opts = ensureList(talk != null ? talk['option'] : null);
    final rolesStr = ensureList(talk != null ? talk['roles'] : null).join(';');
    final screenEffect = cln(talk != null ? talk['screenEffect'] : '');

    return Container(
      color: const Color(0xFF1B1B1F),
      padding: const EdgeInsets.all(12),
      child: ListView(
        children: [
          // 流程操作
          const Text('流程操作', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold, color: Colors.white)),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: _ActionPill(
                  label: '⬇ 插入对话',
                  onPressed: _insertTalk,
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: _ActionPill(
                  label: '➕ 新建对话',
                  primary: true,
                  onPressed: _appendTalk,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: _ActionPill(
                  label: '🗑️ 删除选中',
                  danger: true,
                  onPressed: _selectedTalkIds.isEmpty ? null : _deleteSelectedTalks,
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: _ActionPill(
                  label: '▶ 运行态预览',
                  onPressed: () {
                    if (widget.onPreview != null && _evtId != null) {
                      widget.onPreview!(_evtId!);
                    }
                  },
                ),
              ),
            ],
          ),
          const Divider(height: 24, color: Color(0xFF2A2A2E)),

          // 场景人物控制
          const Text('✨ 场景人物控制', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold, color: Color(0xFFE08A3C))),
          const SizedBox(height: 8),
          const Text('人物动作/表情(30xx):', style: TextStyle(fontSize: 11.5, color: Color(0xFF9B9BA3))),
          const SizedBox(height: 4),
          fluent.TextBox(
            controller: TextEditingController(text: rolesStr),
            placeholder: '支持模糊连打 (例: 0,3000 或 白雨移动-250)',
            onChanged: (v) {
              if (talk != null) {
                talk['roles'] = v.split(';').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
                _dirty = true;
              }
            },
          ),
          const SizedBox(height: 10),
          const Text('屏幕效果(40xx):', style: TextStyle(fontSize: 11.5, color: Color(0xFF9B9BA3))),
          const SizedBox(height: 4),
          fluent.TextBox(
            controller: TextEditingController(text: screenEffect),
            placeholder: '输入效果关键字调出提示(如抖动或CG名字)...',
            onChanged: (v) {
              if (talk != null) {
                talk['screenEffect'] = v.trim();
                _dirty = true;
              }
            },
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 4,
            runSpacing: 4,
            children: ['抖动', '闪白', '黑屏', '淡入', 'CG特写'].map((tag) {
              return MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {
                    if (talk != null) {
                      talk['screenEffect'] = tag;
                      _dirty = true;
                      setState(() {});
                    }
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: const Color(0xFF26262B),
                      borderRadius: BorderRadius.circular(3),
                      border: Border.all(color: const Color(0xFF3A3A42)),
                    ),
                    child: Text(tag, style: const TextStyle(fontSize: 10, color: Color(0xFFD4D4D8))),
                  ),
                ),
              );
            }).toList(),
          ),

          const Divider(height: 24, color: Color(0xFF2A2A2E)),

          // 玩家选项配置
          const Text('🎯 玩家选项配置', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold, color: Color(0xFFE08A3C))),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: fluent.FilledButton(
              onPressed: talk == null ? null : _addOption,
              style: const fluent.ButtonStyle(
                backgroundColor: WidgetStatePropertyAll(Color(0xFFE08A3C)),
              ),
              child: const Text('➕ 添加选项按钮', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ),
          const SizedBox(height: 8),

          // 选项列表表格
          Container(
            decoration: BoxDecoration(
              color: const Color(0xFF18181C),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: const Color(0xFF2E2E35)),
            ),
            child: Column(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  color: const Color(0xFF222228),
                  child: const Row(
                    children: [
                      SizedBox(width: 50, child: Text('选项ID', style: TextStyle(fontSize: 11, color: Color(0xFF9B9BA3)))),
                      Expanded(child: Text('选项文本', style: TextStyle(fontSize: 11, color: Color(0xFF9B9BA3)))),
                      SizedBox(width: 60, child: Text('跳转至(ID)', style: TextStyle(fontSize: 11, color: Color(0xFF9B9BA3)))),
                      SizedBox(width: 24),
                    ],
                  ),
                ),
                if (opts.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 14),
                    child: Text('当前对白无选项按钮', style: TextStyle(fontSize: 11, color: Color(0xFF6E6E76))),
                  )
                else
                  for (final optId in opts) _buildClassicOptionRow(optId),
              ],
            ),
          ),

          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            height: 36,
            child: fluent.FilledButton(
              onPressed: _save,
              style: const fluent.ButtonStyle(
                backgroundColor: WidgetStatePropertyAll(Color(0xFF6C5CE7)),
              ),
              child: const Text('💾 保存修改至 Mod', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildClassicOptionRow(String optId) {
    final opt = _stageOpts[optId];
    final text = opt is Map ? cln(opt['content']) : '';
    final target = opt is Map ? ensureList(opt['talkId']).join(',') : '';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: Color(0xFF222228))),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 50,
            child: Text(optId, style: const TextStyle(fontSize: 10.5, color: Color(0xFFA99FF4))),
          ),
          Expanded(
            child: SizedBox(
              height: 28,
              child: fluent.TextBox(
                controller: TextEditingController(text: text),
                style: const TextStyle(fontSize: 11),
                placeholder: '选项文本',
                onChanged: (v) {
                  if (opt is Map) {
                    opt['content'] = v;
                    _dirty = true;
                  }
                },
              ),
            ),
          ),
          const SizedBox(width: 4),
          SizedBox(
            width: 60,
            child: SizedBox(
              height: 28,
              child: fluent.TextBox(
                controller: TextEditingController(text: target),
                style: const TextStyle(fontSize: 11),
                placeholder: '跳转ID',
                onChanged: (v) {
                  if (opt is Map) {
                    opt['talkId'] = v.split(',').map((s) => int.tryParse(s.trim()) ?? s.trim()).toList();
                    _dirty = true;
                  }
                },
              ),
            ),
          ),
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => _removeOption(optId),
              child: const Padding(
                padding: EdgeInsets.all(4),
                child: Icon(FluentIcons.delete_16_regular, size: 13, color: Color(0xFFE5484D)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _smallButton(String label, VoidCallback? onPressed, {IconData? icon, bool primary = false, bool danger = false}) {
    Color bg = const Color(0xFF26262B);
    Color fg = const Color(0xFFD4D4D8);
    if (primary) {
      bg = const Color(0xFF6C5CE7);
      fg = Colors.white;
    } else if (danger) {
      bg = const Color(0xFF2D1E1E);
      fg = const Color(0xFFFF6B6B);
    }
    return MouseRegion(
      cursor: onPressed != null ? SystemMouseCursors.click : SystemMouseCursors.basic,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onPressed,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(4),
            border: primary ? null : Border.all(color: const Color(0xFF3A3A42)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 13, color: fg),
                const SizedBox(width: 4),
              ],
              Text(
                label,
                style: TextStyle(fontSize: 11.5, color: fg, fontWeight: primary ? FontWeight.bold : FontWeight.normal),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---- 左栏：事件列表 ----

  Widget _buildEventList() {
    final query = _evtSearch.trim();
    final keys = _evtCfg.keys.toList()..sort(compareEventIds);
    final filtered = query.isEmpty
        ? keys
        : keys
              .where(
                (k) =>
                    cln(k).contains(query) || cln(_evtTitle(k)).contains(query),
              )
              .toList();
    return SizedBox(
      width: 250,
      child: Column(
        children: [
          Container(
            height: 38,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                const Text(
                  'EvtCfg 事件',
                  style: TextStyle(fontSize: 12, color: Color(0xFF9B9BA3)),
                ),
                const Spacer(),
                MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    onTap: _addEvent,
                    child: const Icon(
                      FluentIcons.add_24_regular,
                      size: 15,
                      color: Color(0xFF8B8B93),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 0),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '输入事件 ID 或标题关键词，实时过滤左侧 EvtCfg 事件列表',
                style: const TextStyle(fontSize: 11, color: Color(0xFF8B8B93)),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 4, 10, 8),
            child: fluent.TextBox(
              placeholder: '搜索事件 ID / 标题',
              style: const TextStyle(fontSize: 12, color: Colors.white),
              onChanged: (v) => setState(() => _evtSearch = v),
            ),
          ),
          const Divider(height: 1, color: Color(0xFF2A2A2E)),
          Expanded(
            child: ListView.builder(
              itemCount: filtered.length,
              itemBuilder: (context, i) {
                final id = filtered[i];
                final selected = id == _evtId;
                final title = _evtTitle(id);
                final typeName = _evtTypeName(id);
                return MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    onTap: () => _selectEvent(id),
                    child: Container(
                      color: selected
                          ? const Color(0xFF2B2B31)
                          : Colors.transparent,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  '[$id] ${title.isNotEmpty ? title : '（无标题）'}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.w600,
                                    color: selected
                                        ? Colors.white
                                        : const Color(0xFFD4D4D8),
                                  ),
                                ),
                              ),
                              if (widget.onPreview != null)
                                MouseRegion(
                                  cursor: SystemMouseCursors.click,
                                  child: GestureDetector(
                                    onTap: () => widget.onPreview!(id),
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 5,
                                        vertical: 3,
                                      ),
                                      decoration: BoxDecoration(
                                        color: const Color(0xFF2E2A45),
                                        borderRadius: BorderRadius.circular(4),
                                        border: Border.all(
                                          color: const Color(0xFF4A3DB8),
                                        ),
                                      ),
                                      child: const Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(
                                            FluentIcons.play_24_regular,
                                            size: 11,
                                            color: Color(0xFF8B7FEF),
                                          ),
                                          SizedBox(width: 3),
                                          Text(
                                            '预览',
                                            style: TextStyle(
                                              fontSize: 10.5,
                                              color: Color(0xFFA99FF4),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '对白 ${_eventTalkCount(id)} · ${typeName.isEmpty ? '未分类' : typeName}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 11,
                              color: Color(0xFF6E6E76),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          const Divider(height: 1, color: Color(0xFF2A2A2E)),
          Container(
            height: 36,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                Expanded(
                  child: fluent.Button(
                    onPressed: _evtId == null ? null : _deleteEvent,
                    style: const fluent.ButtonStyle(
                      padding: WidgetStatePropertyAll(
                        EdgeInsets.symmetric(vertical: 4),
                      ),
                    ),
                    child: const Text('删除事件', style: TextStyle(fontSize: 11)),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _evtTitle(String id) {
    final info = _evtCfg[id];
    if (info is Map) {
      final t = info['title'];
      if (t is String) return t;
    }
    return '';
  }

  int _eventTalkCount(String evtId) {
    final prefixes = storyRelatedPrefixes(evtId, _evtCfg);
    var n = 0;
    for (final k in _talkCfg.keys) {
      if (storyIsInPrefixes(prefixes, k)) n++;
    }
    return n;
  }

  // ---- 中栏：剧情线 ----

  Widget _buildStoryLine() {
    final evtId = _evtId;
    final talkIds = _eventTalkIds();
    return SizedBox(
      width: 330,
      child: Column(
        children: [
          Container(
            height: 38,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    evtId == null ? '剧情线' : '事件 $evtId 的对话线（${talkIds.length}）',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xFF9B9BA3),
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (evtId != null)
            Container(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
              child: Row(
                children: [
                  Expanded(
                    child: _smallButton(
                      '插入对话',
                      _insertTalk,
                      icon: FluentIcons.arrow_down_24_regular,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: _smallButton(
                      '新建对话',
                      _appendTalk,
                      icon: FluentIcons.add_24_regular,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: _smallButton(
                      '删除选中',
                      _deleteSelectedTalks,
                      icon: FluentIcons.delete_24_regular,
                      danger: true,
                    ),
                  ),
                ],
              ),
            ),
          if (evtId != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 6),
              child: Row(
                children: [
                  const Icon(
                    FluentIcons.info_24_regular,
                    size: 11,
                    color: Color(0xFF6E6E76),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    '按住 Shift 点击可多选，支持批量删除',
                    style: const TextStyle(
                      fontSize: 10.5,
                      color: Color(0xFF6E6E76),
                    ),
                  ),
                ],
              ),
            ),
          const Divider(height: 1, color: Color(0xFF2A2A2E)),
          Expanded(
            child: evtId == null
                ? const Center(
                    child: Text(
                      '选择左侧事件开始编排',
                      style: TextStyle(color: Color(0xFF6E6E76), fontSize: 13),
                    ),
                  )
                : ListView.builder(
                    itemCount: talkIds.length,
                    itemBuilder: (context, i) {
                      final id = talkIds[i];
                      return _buildTalkNode(id);
                    },
                  ),
          ),
          // 底部：台词展示区 + 立绘角色卡片
          if (_talkId != null) ...[
            const Divider(height: 1, color: Color(0xFF2A2A2E)),
            _buildTalkPreviewPane(),
          ],
        ],
      ),
    );
  }

  /// 底部预览区：当前对白的说话人立绘卡片 + 大字号台词全文。
  Widget _buildTalkPreviewPane() {
    final talkId = _talkId!;
    final talk = _stageTalks[talkId];
    if (talk is! Map) return const SizedBox.shrink();
    final content = cln(talk['content']);
    final speaker = _talkDisplayName(talkId);
    // 说话人角色卡片（取 roleIds 前 2 个角色）
    final roleIds = ensureList(talk['roleIds']);
    final persons = roleIds
        .map((id) => (id: cln(id), cfg: _personCfg[cln(id)]))
        .where((p) => p.cfg is Map)
        .take(2)
        .toList();
    return Container(
      height: 132,
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      color: const Color(0xFF1E1C17),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text(
                '当前台词',
                style: TextStyle(
                  fontSize: 11,
                  color: Color(0xFF8B8B93),
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 10),
              Flexible(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: const Color(0xFF2A2418),
                    borderRadius: BorderRadius.circular(3),
                  ),
                  child: Text(
                    speaker,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 11,
                      color: Color(0xFFE8D5B0),
                    ),
                  ),
                ),
              ),
              const Spacer(),
              for (final p in persons)
                Flexible(child: _personCard(p.id, p.cfg as Map<String, dynamic>)),
            ],
          ),
          const SizedBox(height: 8),
          Expanded(
            child: content.isEmpty
                ? const Text(
                    '（此对白暂无内容）',
                    style: TextStyle(fontSize: 12, color: Color(0xFF6E6E76)),
                  )
                : SingleChildScrollView(
                    child: Text(
                      content,
                      style: const TextStyle(
                        fontSize: 15,
                        height: 1.5,
                        color: Color(0xFFF0EDE6),
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  /// 立绘角色卡片：圆形头像占位（名字首字）+ 角色名 + 立绘资源 key。
  Widget _personCard(String id, Map<String, dynamic> cfg) {
    final name = cln(cfg['name']);
    final urls = ensureList(cfg['url']);
    final faceKey = urls.isNotEmpty ? urls.first : '';
    return Padding(
      padding: const EdgeInsets.only(left: 8),
      child: Row(
        children: [
          Container(
            width: 30,
            height: 30,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: const Color(0xFF332B22),
              border: Border.all(color: const Color(0xFF4A3B22)),
            ),
            child: Text(
              name.isNotEmpty ? name.characters.first : '?',
              style: const TextStyle(fontSize: 13, color: Color(0xFFE8D5B0)),
            ),
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  name.isEmpty ? '角色$id' : name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11, color: Color(0xFFE4E4E8)),
                ),
                Text(
                  faceKey.isEmpty ? 'ID $id' : '立绘 $faceKey',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 9.5, color: Color(0xFF8B7B5E)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTalkNode(String id) {
    final talk = _stageTalks[id];
    final selected = _selectedTalkIds.contains(id);
    final isCurrent = id == _talkId;
    final opts = talk is Map
        ? normalizeStoryIdList(talk['option'])
        : <dynamic>[];
    final hasBranch =
        talk is Map && normalizeStoryIdList(talk['check']).isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            onTap: () => _selectTalk(id),
            child: Container(
              // 左侧高亮条：选中 = 主题紫，当前节点 = 橙色
              decoration: BoxDecoration(
                color: selected
                    ? const Color(0xFF2B2B31)
                    : (isCurrent
                          ? const Color(0xFF232329)
                          : Colors.transparent),
                border: Border(
                  left: BorderSide(
                    width: 3,
                    color: selected
                        ? const Color(0xFF6C5CE7)
                        : (isCurrent
                              ? const Color(0xFFC97018)
                              : Colors.transparent),
                  ),
                ),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: Row(
                children: [
                  Icon(
                    hasBranch
                        ? FluentIcons.branch_fork_24_regular
                        : FluentIcons.chat_24_regular,
                    size: 13,
                    color: hasBranch
                        ? const Color(0xFFE08A3C)
                        : const Color(0xFF6E6E76),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '[$id] ${_talkDisplayName(id)}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: selected
                                ? Colors.white
                                : const Color(0xFFD4D4D8),
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          cln(talk is Map ? talk['content'] : ''),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 11,
                            color: Color(0xFF8B8B93),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (opts.isNotEmpty)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 5,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFF2A2418),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        '${opts.length} 选项',
                        style: const TextStyle(
                          fontSize: 9.5,
                          color: Color(0xFFE08A3C),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
        for (final optId in opts) _buildOptionNode(cln(optId), isCurrent),
      ],
    );
  }

  Widget _buildOptionNode(String optId, bool parentSelected) {
    final opt = _stageOpts[optId];
    final text = opt is Map ? cln(opt['content']) : '';
    final target = opt is Map ? ValueCodec.encode(opt['talkId']) : '';
    return Container(
      margin: const EdgeInsets.only(left: 26, right: 8, bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF23201A),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: const Color(0xFF4A3B22)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                FluentIcons.circle_half_fill_24_regular,
                size: 12,
                color: Color(0xFFE08A3C),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  text.isEmpty ? '（空选项文本）' : text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFFE8D5B0),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            '[$optId] → ${target.isEmpty ? '未设置跳转' : target}',
            style: const TextStyle(fontSize: 10.5, color: Color(0xFF8B7B5E)),
          ),
        ],
      ),
    );
  }

  void _selectTalk(String id) {
    setState(() {
      _talkId = id;
      // Shift + 点击：切换该节点选中状态（不清空其它选中），实现批量多选
      if (HardwareKeyboard.instance.isShiftPressed) {
        if (!_selectedTalkIds.remove(id)) {
          _selectedTalkIds.add(id);
        }
      } else if (!_selectedTalkIds.contains(id)) {
        _selectedTalkIds.clear();
        _selectedTalkIds.add(id);
      }
    });
  }

  // ---- 右栏：对白编辑器 ----

  Widget _buildTalkEditor() {
    final talkId = _talkId;
    if (talkId == null) {
      return const Center(
        child: Text(
          '选择剧情线中的对白节点进行编辑',
          style: TextStyle(color: Color(0xFF6E6E76), fontSize: 13),
        ),
      );
    }
    final talk = _stageTalks[talkId];
    if (talk is! Map) {
      return const Center(
        child: Text(
          '选择剧情线中的对白节点进行编辑',
          style: TextStyle(color: Color(0xFF6E6E76), fontSize: 13),
        ),
      );
    }
    return KeyedSubtree(
      key: ValueKey('talk-$talkId'),
      child: _TalkEditorPane(
        talkId: talkId,
        talk: talk.cast<String, dynamic>(),
        stageOpts: _stageOpts,
        personCfg: _personCfg,
        bgCfg: _bgCfg,
        audioCfg: _audioCfg,
        translator: translator,
        dirty: _dirty,
        onChanged: () => setState(() => _dirty = true),
        onSave: _save,
        onAddOption: _addOption,
        onRemoveOption: _removeOption,
      ),
    );
  }
}

/// 对白节点编辑器（右侧面板）。
class _TalkEditorPane extends StatefulWidget {
  const _TalkEditorPane({
    required this.talkId,
    required this.talk,
    required this.stageOpts,
    required this.personCfg,
    required this.bgCfg,
    required this.audioCfg,
    required this.translator,
    required this.dirty,
    required this.onChanged,
    required this.onSave,
    required this.onAddOption,
    required this.onRemoveOption,
  });
  final String talkId;
  final Map<String, dynamic> talk;
  final Map<String, dynamic> stageOpts;
  final Map<String, dynamic> personCfg;
  final Map<String, dynamic> bgCfg;
  final Map<String, dynamic> audioCfg;
  final KeyTranslator translator;
  final bool dirty;
  final VoidCallback onChanged;
  final VoidCallback onSave;
  final VoidCallback onAddOption;
  final void Function(String optId) onRemoveOption;

  @override
  State<_TalkEditorPane> createState() => _TalkEditorPaneState();
}

class _TalkEditorPaneState extends State<_TalkEditorPane> {
  final _contentCtrl = TextEditingController();
  final _roleIdsCtrl = TextEditingController();
  final _roleNameCtrl = TextEditingController();
  final _highlightsCtrl = TextEditingController();
  final _checkCtrl = TextEditingController();
  final _nextTalkCtrl = TextEditingController();
  final _nextTalk2Ctrl = TextEditingController();
  final _rolesCtrl = TextEditingController();
  final _screenEffectCtrl = TextEditingController();
  final _bgCtrl = TextEditingController();
  final _audioCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  bool _showAdvanced = true; // 默认展开属性表，常用字段直接可见

  @override
  void initState() {
    super.initState();
    _syncFromTalk();
  }

  void _syncFromTalk() {
    final t = widget.talk;
    _contentCtrl.text = cln(t['content']);
    _roleIdsCtrl.text = ensureList(t['roleIds']).join(', ');
    _roleNameCtrl.text = cln(t['roleName']);
    _highlightsCtrl.text = ensureList(t['highlights']).join(', ');
    _checkCtrl.text = ValueCodec.encode(t['check']);
    _nextTalkCtrl.text = ValueCodec.encode(t['nextTalk']);
    _nextTalk2Ctrl.text = ValueCodec.encode(t['nextTalk2']);
    _rolesCtrl.text = ValueCodec.encode(t['roles']);
    _screenEffectCtrl.text = ValueCodec.encode(t['screenEffect']);
    _bgCtrl.text = cln(t['bg']);
    _audioCtrl.text = cln(t['audio']);
  }

  @override
  void dispose() {
    _contentCtrl.dispose();
    _roleIdsCtrl.dispose();
    _roleNameCtrl.dispose();
    _highlightsCtrl.dispose();
    _checkCtrl.dispose();
    _nextTalkCtrl.dispose();
    _nextTalk2Ctrl.dispose();
    _rolesCtrl.dispose();
    _screenEffectCtrl.dispose();
    _bgCtrl.dispose();
    _audioCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _setField(String key, dynamic value) {
    widget.talk[key] = value;
    widget.onChanged();
  }

  /// 逗号分隔文本 → 1D 数字/字符串列表（保持原值类型语义）。
  List<dynamic> _splitIds(String text) {
    return ValueCodec.decode(text.isEmpty ? '' : text, '1D Array');
  }

  String _roleNamesPreview() {
    final ids = _splitIds(_roleIdsCtrl.text);
    final names = ids.map((id) {
      final p = widget.personCfg[cln(id)];
      String? n = p is Map ? p['name'] : null;
      if (n == null || n.isEmpty) {
        final roles = widget.translator.state.gameDicts['roles'];
        if (roles is Map && roles[cln(id)] != null) {
          n = roles[cln(id)].toString();
        }
      }
      return n != null && n.isNotEmpty ? '$id($n)' : cln(id);
    }).toList();
    return names.isEmpty ? '旁白' : names.join('、');
  }

  String _fieldLabel(String key) {
    final custom = widget.translator.translate(key, 'TalkCfg');
    return _talkLabels[key] ?? (custom == key ? key : custom);
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.talk;
    final opts = normalizeStoryIdList(t['option']);
    final advancedKeys = _advancedKeys();
    return Column(
      children: [
        Container(
          height: 38,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              const Text(
                '对白节点',
                style: TextStyle(
                  fontSize: 12,
                  color: Color(0xFF9B9BA3),
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 10),
              Text(
                'ID: ${widget.talkId}',
                style: const TextStyle(fontSize: 12, color: Color(0xFFC97018)),
              ),
              const Spacer(),
              Text(
                '对白: ${opts.length} 选项',
                style: const TextStyle(fontSize: 11, color: Color(0xFF6E6E76)),
              ),
              const SizedBox(width: 12),
            ],
          ),
        ),
        const Divider(height: 1, color: Color(0xFF2A2A2E)),
        Expanded(
          child: fluent.Scrollbar(
            controller: _scrollCtrl,
            child: ListView(
              controller: _scrollCtrl,
              padding: const EdgeInsets.all(16),
              children: [
                _section('角色与台词', [
                  _labelField(
                    '说话人群组',
                    'roleIds',
                    '输入角色 ID，逗号隔开',
                    _roleIdsCtrl,
                    (v) => _setField('roleIds', _splitIds(v)),
                    trailing: Text(
                      _roleNamesPreview(),
                      style: const TextStyle(
                        fontSize: 11,
                        color: Color(0xFF6E6E76),
                      ),
                    ),
                  ),
                  _labelField(
                    '自定义名字',
                    'roleName',
                    '留空则显示说话人名字',
                    _roleNameCtrl,
                    (v) => _setField('roleName', v),
                  ),
                  _labelField(
                    '高亮人物',
                    'highlights',
                    '逗号隔开',
                    _highlightsCtrl,
                    (v) => _setField('highlights', _splitIds(v)),
                  ),
                ]),
                _section('场景与表现', [
                  _labelField(
                    '切换背景',
                    'bg',
                    '0=继承上文 -1=清空人物 -2=仅转场',
                    _bgCtrl,
                    (v) => _setField('bg', _numOr(v, 0)),
                    trailing: _bgHint(),
                  ),
                  _labelField(
                    '背景音乐',
                    'audio',
                    'AudioCfg ID',
                    _audioCtrl,
                    (v) => _setField('audio', _numOr(v, 0)),
                    trailing: _audioHint(),
                  ),
                  _labelField(
                    '人物控制指令',
                    'roles',
                    '行: 动作,角色; 列: 动作ID,角色ID…',
                    _rolesCtrl,
                    (v) => _setField('roles', _decode2d(v)),
                  ),
                  _labelField(
                    '屏幕画面特效',
                    'screenEffect',
                    '特效 ID，逗号隔开',
                    _screenEffectCtrl,
                    (v) => _setField('screenEffect', _splitIds(v)),
                  ),
                ]),
                _section('台词内容', [
                  const Text(
                    '该条对白显示的文字内容；<color=..>、<size=..> 标签可控制颜色与字号',
                    style: TextStyle(fontSize: 11, color: Color(0xFF8B8B93)),
                  ),
                  const SizedBox(height: 4),
                  fluent.TextBox(
                    controller: _contentCtrl,
                    maxLines: 6,
                    placeholder: '输入对白内容（支持 <color=..> <size=..> 富文本标签）',
                    style: const TextStyle(fontSize: 14, color: Colors.white),
                    onChanged: (v) => _setField('content', v),
                  ),
                ]),
                _section('流程与分支', [
                  _labelField(
                    '前提判定 check',
                    'check',
                    '行: 条件类型,属性ID,值; 分号分隔多条件',
                    _checkCtrl,
                    (v) => _setField('check', _decode2d(v)),
                  ),
                  _labelField(
                    '下一句对话ID',
                    'nextTalk',
                    '空 = 对话结束',
                    _nextTalkCtrl,
                    (v) => _setField('nextTalk', _splitIds(v)),
                  ),
                  _labelField(
                    '失败跳转ID',
                    'nextTalk2',
                    'check 判定失败时跳转',
                    _nextTalk2Ctrl,
                    (v) => _setField('nextTalk2', _splitIds(v)),
                  ),
                ]),
                _section('玩家选项', [
                  for (final optId in opts)
                    _OptionRow(
                      optId: cln(optId),
                      opt: widget.stageOpts[cln(optId)],
                      onChanged: widget.onChanged,
                      onRemove: () => widget.onRemoveOption(cln(optId)),
                    ),
                  const SizedBox(height: 8),
                  MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: GestureDetector(
                      onTap: widget.onAddOption,
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        decoration: BoxDecoration(
                          color: const Color(0xFF23201A),
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(color: const Color(0xFF4A3B22)),
                        ),
                        child: const Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              FluentIcons.add_24_regular,
                              size: 13,
                              color: Color(0xFFE08A3C),
                            ),
                            SizedBox(width: 6),
                            Text(
                              '添加选项按钮',
                              style: TextStyle(
                                fontSize: 12,
                                color: Color(0xFFE8D5B0),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ]),
                _advancedSection(advancedKeys),
              ],
            ),
          ),
        ),
        const Divider(height: 1, color: Color(0xFF2A2A2E)),
        Container(
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  widget.dirty ? '有未保存的修改' : '已保存（切换事件前请保存）',
                  style: TextStyle(
                    fontSize: 11,
                    color: widget.dirty
                        ? const Color(0xFFE08A3C)
                        : const Color(0xFF6E6E76),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              fluent.FilledButton(
                onPressed: widget.onSave,
                style: const fluent.ButtonStyle(
                  padding: WidgetStatePropertyAll(
                    EdgeInsets.symmetric(horizontal: 18, vertical: 6),
                  ),
                ),
                child: const Text('保存全部', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // 底部保存按钮通过父级回调触发；此处仅展示状态。
  List<String> _advancedKeys() {
    const special = {
      'id',
      'content',
      'roleIds',
      'roleName',
      'highlights',
      'bg',
      'audio',
      'roles',
      'screenEffect',
      'check',
      'nextTalk',
      'nextTalk2',
      'option',
    };
    final keys = <String>{...widget.talk.keys.map(cln)};
    final out = keys.where((k) => !special.contains(k)).toList()..sort();
    return out;
  }

  Widget _section(String title, List<Widget> children) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 12.5,
              color: Color(0xFFC97018),
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          ...children,
        ],
      ),
    );
  }

  Widget _labelField(
    String label,
    String key,
    String hint,
    TextEditingController ctrl,
    ValueChanged<String> onChanged, {
    Widget? trailing,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                label,
                style: const TextStyle(
                  fontSize: 12.5,
                  color: Color(0xFFD4D4D8),
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                key,
                style: const TextStyle(fontSize: 11, color: Color(0xFF5E5E66)),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: fluent.TextBox(
                  controller: ctrl,
                  placeholder: hint,
                  style: const TextStyle(fontSize: 12.5, color: Colors.white),
                  onChanged: onChanged,
                ),
              ),
              if (trailing != null) ...[const SizedBox(width: 8), trailing],
            ],
          ),
        ],
      ),
    );
  }

  Widget _bgHint() {
    final v = cln(_bgCtrl.text);
    if (v.isEmpty) return const SizedBox.shrink();
    final special = switch (v) {
      '0' => '继承上文',
      '-1' => '清空人物',
      '-2' => '仅特效转场',
      _ => '',
    };
    if (special.isNotEmpty) {
      return Text(
        special,
        style: const TextStyle(fontSize: 11, color: Color(0xFF8B8B93)),
      );
    }
    final p = widget.bgCfg[v];
    final n = p is Map ? p['name'] : null;
    if (n is String && n.isNotEmpty) {
      return Text(
        n,
        style: const TextStyle(fontSize: 11, color: Color(0xFF8B8B93)),
      );
    }
    return const SizedBox.shrink();
  }

  Widget _audioHint() {
    final v = cln(_audioCtrl.text);
    if (v.isEmpty || v == '0') return const SizedBox.shrink();
    final p = widget.audioCfg[v];
    final n = p is Map ? p['name'] : null;
    if (n is String && n.isNotEmpty) {
      return Text(
        n,
        style: const TextStyle(fontSize: 11, color: Color(0xFF8B8B93)),
      );
    }
    return const SizedBox.shrink();
  }

  Widget _advancedSection(List<String> keys) {
    if (keys.isEmpty) return const SizedBox.shrink();
    // 属性表：两列（属性名 | 属性值），默认展开
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              onTap: () => setState(() => _showAdvanced = !_showAdvanced),
              child: Row(
                children: [
                  Icon(
                    _showAdvanced
                        ? FluentIcons.chevron_down_24_regular
                        : FluentIcons.chevron_right_24_regular,
                    size: 13,
                    color: const Color(0xFF8B8B93),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '属性表（${keys.length}）',
                    style: const TextStyle(
                      fontSize: 12.5,
                      color: Color(0xFF8B8B93),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (_showAdvanced) ...[
            const SizedBox(height: 8),
            Container(
              decoration: BoxDecoration(
                border: Border.all(color: const Color(0xFF2E2E34)),
                borderRadius: BorderRadius.circular(6),
              ),
              clipBehavior: Clip.antiAlias,
              child: Column(
                children: [
                  for (var i = 0; i < keys.length; i++) ...[
                    if (i > 0)
                      const Divider(height: 1, color: Color(0xFF2A2A2E)),
                    _attrRow(keys[i]),
                  ],
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 属性表行：左侧固定宽属性名，右侧值输入框。
  Widget _attrRow(String key) {
    return Container(
      color: const Color(0xFF1F1F24),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: Row(
        children: [
          SizedBox(
            width: 108,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _fieldLabel(key),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFFD4D4D8),
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  key,
                  style: const TextStyle(
                    fontSize: 10,
                    color: Color(0xFF5E5E66),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '「${_fieldLabel(key)}」字段值，按类型输入',
                  style: const TextStyle(
                    fontSize: 11,
                    color: Color(0xFF8B8B93),
                  ),
                ),
                const SizedBox(height: 2),
                fluent.TextBox(
                  controller: TextEditingController(
                    text: ValueCodec.encode(widget.talk[key]),
                  ),
                  maxLines: 2,
                  style: const TextStyle(fontSize: 12.5, color: Colors.white),
                  onChanged: (v) => _setField(key, _decodeByType(key, v)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  dynamic _decodeByType(String key, String text) {
    final schema = _schemaType(key);
    if (schema != null) {
      try {
        return ValueCodec.decode(text, schema);
      } catch (_) {}
    }
    return text;
  }

  String? _schemaType(String key) {
    final schema = _schemaCache[key];
    return schema;
  }

  static const _schemaCache = <String, String>{
    'effect': '2D Array',
    'effect2': '2D Array',
    'miniGame': '1D Array',
    'replace': '1D Array',
    'showTxt': 'String',
    'time': 'Number',
    'vocals': '1D Array',
    'maxoptions': 'Number',
  };

  dynamic _numOr(String text, int fallback) {
    final n = num.tryParse(text.trim());
    return n ?? fallback;
  }

  List<dynamic> _decode2d(String text) {
    try {
      return ValueCodec.decode(text, '2D Array');
    } catch (_) {
      return <dynamic>[];
    }
  }
}

/// 玩家选项行（独立 StatefulWidget，避免每次重建创建 controller）。
class _OptionRow extends StatefulWidget {
  const _OptionRow({
    required this.optId,
    required this.opt,
    required this.onChanged,
    required this.onRemove,
  });
  final String optId;
  final dynamic opt;
  final VoidCallback onChanged;
  final VoidCallback onRemove;

  @override
  State<_OptionRow> createState() => _OptionRowState();
}

class _OptionRowState extends State<_OptionRow> {
  late final TextEditingController _contentCtrl;
  late final TextEditingController _targetCtrl;

  @override
  void initState() {
    super.initState();
    _contentCtrl = TextEditingController(
      text: widget.opt is Map ? cln(widget.opt['content']) : '',
    );
    _targetCtrl = TextEditingController(
      text: widget.opt is Map ? ValueCodec.encode(widget.opt['talkId']) : '',
    );
  }

  @override
  void dispose() {
    _contentCtrl.dispose();
    _targetCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final opt = widget.opt;
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFF23201A),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: const Color(0xFF4A3B22)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                FluentIcons.circle_half_fill_24_regular,
                size: 12,
                color: Color(0xFFE08A3C),
              ),
              const SizedBox(width: 6),
              Text(
                '选项 ${widget.optId}',
                style: const TextStyle(
                  fontSize: 12,
                  color: Color(0xFFE8D5B0),
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  onTap: widget.onRemove,
                  child: const Icon(
                    FluentIcons.delete_24_regular,
                    size: 13,
                    color: Color(0xFFE05656),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            '玩家看到的选项按钮文字，点击后进入对应分支',
            style: TextStyle(fontSize: 11, color: Color(0xFF8B8B93)),
          ),
          const SizedBox(height: 4),
          fluent.TextBox(
            controller: _contentCtrl,
            placeholder: '选项文本',
            style: const TextStyle(fontSize: 12.5, color: Colors.white),
            onChanged: (v) {
              if (opt is Map) {
                opt['content'] = v;
                widget.onChanged();
              }
            },
          ),
          const SizedBox(height: 6),
          const Text(
            '玩家选择该选项后跳转到的对话 ID；多个 ID 用逗号分隔',
            style: TextStyle(fontSize: 11, color: Color(0xFF8B8B93)),
          ),
          const SizedBox(height: 4),
          fluent.TextBox(
            controller: _targetCtrl,
            placeholder: '跳转至对话 ID（talkId）',
            style: const TextStyle(fontSize: 12.5, color: Colors.white),
            onChanged: (v) {
              if (opt is Map) {
                opt['talkId'] = ValueCodec.decode(v, '1D Array');
                widget.onChanged();
              }
            },
          ),
        ],
      ),
    );
  }
}

class _StageRoleInfo {
  _StageRoleInfo({
    required this.roleId,
    required this.slot,
    required this.actionCode,
    this.isHighlight = false,
  });
  final String roleId;
  final int slot;
  final String actionCode;
  final bool isHighlight;
}

class _ActionPill extends StatelessWidget {
  const _ActionPill({
    required this.label,
    required this.onPressed,
    this.primary = false,
    this.danger = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool primary;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    Color bg = const Color(0xFF26262B);
    Color fg = const Color(0xFFD4D4D8);
    Color? borderColor = const Color(0xFF3A3A42);

    if (primary) {
      bg = const Color(0xFF6C5CE7);
      fg = Colors.white;
      borderColor = null;
    } else if (danger) {
      bg = const Color(0xFF2D1E1E);
      fg = const Color(0xFFFF6B6B);
      borderColor = const Color(0xFF4D2A2A);
    }

    return MouseRegion(
      cursor: onPressed != null ? SystemMouseCursors.click : SystemMouseCursors.basic,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onPressed,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(5),
            border: borderColor != null ? Border.all(color: borderColor) : null,
          ),
          child: Text(
            label,
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11.5,
              color: fg,
              fontWeight: primary ? FontWeight.bold : FontWeight.normal,
            ),
          ),
        ),
      ),
    );
  }
}

