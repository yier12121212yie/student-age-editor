import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import '../../core/api_client.dart';
import '../../core/app_theme.dart';
import '../../core/models.dart';
import 'story_flow_graph.dart';
import 'story_flow_models.dart';
import 'story_flow_node_presets.dart';
import 'story_flow_side_toolbar.dart';
import 'story_logic.dart';

/// 剧情图模式工作区：满铺流程图画布 + 浮动层（事件切换器、操作簇、
/// 左侧工具栏、媒体资产面板），节点内联展开编辑参数。
///
/// 数据流与故事导演一致：并行加载 8 张表 → 选事件用 stageOf 切舞台副本 →
/// 编辑副本 → mergeStageBack 后顺序 PUT 三张表。节点位置持久化到
/// `<mod根>/.editor_flow.json`（游戏不读取该文件）。
class StoryFlowWorkspace extends StatefulWidget {
  const StoryFlowWorkspace({
    super.key,
    required this.state,
    required this.onPreview,
    this.aiOpen = false,
    this.onToggleAi,
    required this.onOpenPlugins,
    required this.onOpenSettings,
  });

  final AppState state;

  /// 事件 id → 打开场景预览（宿主打开 OpenDoc.preview）。
  final ValueChanged<String> onPreview;

  /// AI 侧栏开关状态与切换（透传外壳的 AiPanel 控制）。
  final bool aiOpen;
  final VoidCallback? onToggleAi;

  /// 插件页 / 设置页入口（外壳切换内容栈视图）。
  final VoidCallback onOpenPlugins;
  final VoidCallback onOpenSettings;

  @override
  State<StoryFlowWorkspace> createState() => _StoryFlowWorkspaceState();
}

class _StoryFlowWorkspaceState extends State<StoryFlowWorkspace> {
  static const _tables = [
    'EvtCfg', 'TalkCfg', 'OptionCfg',
    'PersonCfg', 'BgCfg', 'AudioCfg', 'EvtTypeCfg', 'CGCfg',
  ];

  final _graphKey = GlobalKey<StoryFlowGraphState>();
  final Map<String, TextEditingController> _ctls = {};
  final List<TextEditingController> _allCtls = [];

  // 全量表（GET /api/cfg 的 data）
  final Map<String, Map<String, dynamic>> _tablesData = {};

  /// 插件流程卡片声明（GET /api/plugins/ui/flow_cards）。
  List<Map<String, dynamic>> _flowCards = [];
  bool _loading = true;
  String _error = '';

  // 当前事件舞台
  String? _evtId;
  List<String> _prefixes = const [];
  Map<String, dynamic> _stageTalks = {};
  Map<String, dynamic> _stageOpts = {};
  Map<String, dynamic> _talkBaseline = {};
  Map<String, dynamic> _optBaseline = {};
  bool _dirty = false;

  // 节点位置
  Map<String, Offset> _positions = {};
  Map<String, dynamic> _flowFile = {};
  Timer? _layoutSaveTimer;

  /// `.editor_flow.json` 是否已加载完成；就绪前禁止回写布局，
  /// 避免用空壳数据覆盖其他事件已保存的节点坐标。
  bool _flowLoaded = false;

  // 选中
  String? _selectedNode;
  FlowEdge? _selectedEdge;

  // 内联编辑展开的节点
  final Set<String> _expandedNodes = {};

  /// 检定 check JSON 解析失败的节点（卡片内红字提示）。
  final Set<String> _checkInvalid = {};

  // 媒体资产
  bool _assetsOpen = false;
  String? _dragHoverNode;

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _layoutSaveTimer?.cancel();
    for (final c in _allCtls) {
      c.dispose();
    }
    super.dispose();
  }

  // ---------- 数据层 ----------
  /// 先加载布局文件再加载配置表：`_load` 完成后要按 `_flowFile` 恢复
  /// 节点位置，且布局未就绪前禁止回写，两步必须串行不能并行。
  Future<void> _init() async {
    await _loadFlowFile();
    if (!mounted) return;
    await _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      final results = await Future.wait([
        for (final t in _tables)
          ApiClient.instance.get('/api/cfg/$t'),
      ]);
      for (var i = 0; i < _tables.length; i++) {
        final raw = results[i]['data'];
        _tablesData[_tables[i]] = raw is Map
            ? {for (final e in raw.entries) e.key.toString(): e.value}
            : {};
      }
      // 卡型声明：插件 flow_cards 在前、内置节点预设在后（first-match 即插件优先）
      List<Map<String, dynamic>> pluginCards = [];
      try {
        final fc = await ApiClient.instance.get('/api/plugins/ui/flow_cards');
        final list = fc['flow_cards'];
        pluginCards = list is List
            ? [for (final c in list) if (c is Map) Map<String, dynamic>.from(c)]
            : [];
      } catch (_) {
        pluginCards = [];
      }
      _flowCards = [...pluginCards, ...builtinFlowCardSpecs()];
      if (mounted) {
        setState(() {
          _loading = false;
          final evts = _tablesData['EvtCfg']!.keys.toList()..sort(compareEventIds);
          if (evts.isNotEmpty) _selectEventInner(evts.first);
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '加载配置失败: $e';
        });
      }
    }
  }

  Future<void> _loadFlowFile() async {
    try {
      final r = await ApiClient.instance.get('/api/tools/read',
          query: {'path': '.editor_flow.json'});
      final text = r['text'];
      if (text is String && text.trim().isNotEmpty) {
        final parsed = jsonDecode(text);
        if (parsed is Map) {
          _flowFile = Map<String, dynamic>.from(parsed);
        }
      }
    } catch (_) {
      // 文件不存在或沙箱拒绝：使用空布局
    } finally {
      _flowLoaded = true;
    }
  }

  void _persistLayout() {
    _layoutSaveTimer?.cancel();
    _layoutSaveTimer = Timer(const Duration(milliseconds: 800), () {
      if (!mounted) return;
      try {
        ApiClient.instance.put('/api/tools/write',
            body: {
              'path': '.editor_flow.json',
              'content': jsonEncode(_flowFile),
            });
      } catch (_) {}
    });
  }

  // ---------- 事件选择 ----------
  Future<void> _selectEvent(String evtId) async {
    if (evtId == _evtId) return;
    if (_dirty) {
      final action = await _confirmDirtyDiscard();
      if (!mounted) return;
      if (action == null) return;
      if (action == 'discard') {
        _discardStage();
      } else {
        final saved = await _save();
        if (!mounted || !saved) return;
      }
    }
    if (mounted) _selectEventInner(evtId);
  }

  /// 全局切换 Mod：未保存修改先确认，POST /api/mods/select 成功后同步
  /// AppState，并重载布局文件与配置表（事件列表/舞台数据/保存目标
  /// 全部随新 mod 根切换，与模组页、AI 面板的切换语义一致）。
  Future<void> _switchMod(String name) async {
    if (name == widget.state.modName) return;
    if (_dirty) {
      final action = await _confirmDirtyDiscard();
      if (!mounted) return;
      if (action == null) return;
      if (action == 'discard') {
        _discardStage();
      } else {
        final saved = await _save();
        if (!mounted || !saved) return;
      }
    }
    // 取消防抖中的布局回写：该写入指向旧 mod 的沙箱，切换后不得串档
    _layoutSaveTimer?.cancel();
    _layoutSaveTimer = null;
    try {
      final r = await ApiClient.instance
          .post('/api/mods/select', body: {'name': name});
      final mod = r['mod'];
      if (mod is! Map) throw '响应缺少 mod 字段';
      if (!mounted) return;
      widget.state.setMod(
          mod['name'] as String? ?? name, mod['root'] as String? ?? '');
      // 清掉旧 mod 的舞台残留：新 mod 若无事件，_load 不会自动选中
      _evtId = null;
      _prefixes = const [];
      _stageTalks = {};
      _stageOpts = {};
      _talkBaseline = {};
      _optBaseline = {};
      _flowFile = {};
      _flowLoaded = false;
      await _loadFlowFile();
      if (!mounted) return;
      await _load();
      if (!mounted) return;
      _toast('已切换到 Mod：$name', fluent.InfoBarSeverity.success);
    } catch (e) {
      if (!mounted) return;
      _toast('切换 Mod 失败: $e', fluent.InfoBarSeverity.error);
    }
  }

  String? _eventTitle(String id) {
    final e = _tablesData['EvtCfg']?[id];
    if (e is Map) {
      final t = cln(e['title']);
      if (t.isNotEmpty) return t;
    }
    return null;
  }

  void _discardStage() {
    _stageTalks = _deepCopy(_talkBaseline);
    _stageOpts = _deepCopy(_optBaseline);
    _resetPanelCtls();
    if (mounted) setState(() => _dirty = false);
  }

  void _selectEventInner(String evtId) {
    setState(() {
      _evtId = evtId;
      _prefixes = storyRelatedPrefixes(evtId, _tablesData['EvtCfg']!);
      final allTalks = _tablesData['TalkCfg']!;
      final allOpts = _tablesData['OptionCfg']!;
      _stageTalks = stageOf(allTalks, _prefixes);
      _stageOpts = stageOf(allOpts, _prefixes, isOption: true);
      _talkBaseline = _deepCopy(_stageTalks);
      _optBaseline = _deepCopy(_stageOpts);
      _dirty = false;
      _selectedNode = null;
      _selectedEdge = null;
      _expandedNodes.clear();
      _checkInvalid.clear();
      _dragHoverNode = null;
      _loadPositionsForEvent();
    });
  }

  Future<String?> _confirmDirtyDiscard() {
    return fluent.showDialog<String>(
      context: context,
      builder: (ctx) => fluent.ContentDialog(
        title: const Text('未保存的修改'),
        content: Text(
          '当前事件的修改尚未保存，切换事件前要保存吗？',
          style: TextStyle(fontSize: 12.5, color: palette.textPrimary),
        ),
        actions: [
          fluent.Button(
            onPressed: () => Navigator.pop(ctx, 'discard'),
            child: const Text('放弃修改'),
          ),
          fluent.Button(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          fluent.FilledButton(
            onPressed: () => Navigator.pop(ctx, 'save'),
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }

  Future<bool> _save() async {
    if (_evtId == null) return false;
    final talks = _tablesData['TalkCfg']!;
    final opts = _tablesData['OptionCfg']!;
    mergeStageBack(talks, _talkBaseline, _stageTalks, _prefixes);
    mergeStageBack(opts, _optBaseline, _stageOpts, _prefixes, isOption: true);
    try {
      await ApiClient.instance.put('/api/cfg/TalkCfg', body: {'data': talks});
      await ApiClient.instance.put('/api/cfg/OptionCfg', body: {'data': opts});
      await ApiClient.instance.put('/api/cfg/EvtCfg',
          body: {'data': _tablesData['EvtCfg']!});
      if (!mounted) return false;
      setState(() {
        _talkBaseline = _deepCopy(_stageTalks);
        _optBaseline = _deepCopy(_stageOpts);
        _dirty = false;
      });
      _toast('已保存', fluent.InfoBarSeverity.success);
      return true;
    } catch (e) {
      if (!mounted) return false;
      _toast('保存失败: $e', fluent.InfoBarSeverity.error);
      return false;
    }
  }

  void _toast(String msg, fluent.InfoBarSeverity sev) {
    if (!mounted) return;
    fluent.displayInfoBar(
      context,
      builder: (ctx, close) => fluent.InfoBar(
        title: Text(msg),
        severity: sev,
      ),
    );
  }

  // ---------- 图数据 ----------
  FlowGraph get _graph {
    final evtTitles = <String, String>{};
    _tablesData['EvtCfg']!.forEach((id, v) {
      if (v is Map) {
        final t = cln(v['title']);
        if (t.isNotEmpty) evtTitles[id] = t;
      }
    });
    return buildFlowGraph(
      talks: _stageTalks,
      options: _stageOpts,
      prefixes: _prefixes,
      evtTitles: evtTitles,
      starts: _evtId == null
          ? const []
          : storyStartIds(_evtId!, _tablesData['EvtCfg']!, _stageTalks),
      cardStyles: _flowCards,
    );
  }

  // ---------- 节点位置 ----------
  void _loadPositionsForEvent() {
    final out = <String, Offset>{};
    final saved = _flowFile[_evtId];
    if (saved is Map) {
      saved.forEach((id, v) {
        if (v is Map) {
          final x = (v['x'] is num) ? (v['x'] as num).toDouble() : null;
          final y = (v['y'] is num) ? (v['y'] as num).toDouble() : null;
          if (x != null && y != null) out[id.toString()] = Offset(x, y);
        }
      });
    }
    _positions = out;
    // 缺少位置的节点用分层 DAG 自动布局补齐
    final layout = layoutFlow(graph: _graph);
    final auto = <String, Offset>{};
    layout.forEach((id, pos) {
      if (!_positions.containsKey(id)) auto[id] = pos;
    });
    _positions.addAll(auto);
  }

  void _markLayoutDirty() {
    // 布局文件未加载完成前不回写：此时 _flowFile 可能是空壳，
    // 全量 PUT 会清空其他事件已保存的节点坐标。
    if (!_flowLoaded) return;
    final evt = _evtId;
    if (evt == null) return;
    final saved = <String, dynamic>{};
    _positions.forEach((id, pos) {
      saved[id] = {'x': pos.dx.round(), 'y': pos.dy.round()};
    });
    _flowFile[evt] = saved;
    _persistLayout();
  }

  // ---------- 图编辑操作 ----------
  void _onMoveNode(String id, Offset pos) {
    _positions[id] = pos;
    _markLayoutDirty();
    if (id == _selectedNode) {
      setState(() {});
    }
  }

  void _onAddEdge(String fromId, String field, String targetId) {
    final rec = _stageTalks[fromId] ?? _stageOpts[fromId];
    if (rec == null) return;
    // 语义校验：选项端口只能连到选项节点，跳转端口只能连到对白节点
    if (field == 'option') {
      if (!_stageOpts.containsKey(targetId)) {
        _toast('「选项」端口只能连接到选项节点，请先添加选项', fluent.InfoBarSeverity.warning);
        return;
      }
    } else {
      if (!_stageTalks.containsKey(targetId)) {
        _toast('该端口只能连接到对白节点', fluent.InfoBarSeverity.warning);
        return;
      }
    }
    pushEdgeTarget(rec, field, targetId);
    setState(() => _dirty = true);
  }

  void _onDeleteEdge(String fromId, String field, String targetId) {
    final rec = _stageTalks[fromId] ?? _stageOpts[fromId];
    if (rec == null) return;
    removeEdgeTarget(rec, field, targetId);
    setState(() {
      _selectedEdge = null;
      _dirty = true;
    });
  }

  void _requestDelete() {
    final edge = _selectedEdge;
    if (edge != null) {
      final field = fieldForEdge(edge.kind);
      if (field == null) {
        _toast('终端跳转边不可删除（请直接编辑选项的 nextEvtId）',
            fluent.InfoBarSeverity.warning);
        return;
      }
      _onDeleteEdge(edge.from, field, edge.to);
      return;
    }
    final node = _selectedNode;
    if (node == null) return;
    _deleteNode(node);
  }

  void _deleteNode(String id) {
    if (_stageTalks.containsKey(id)) {
      final replacement = normalizeStoryIdList(_stageTalks[id]['nextTalk']);
      remapDeletedTarget(_stageTalks, _stageOpts, _prefixes, id, replacement);
      _stageTalks.remove(id);
    } else if (_stageOpts.containsKey(id)) {
      _stageOpts.remove(id);
      // 选项被删，从所有对白的 option 引用中移除该 id
      for (final t in _stageTalks.values) {
        if (t is Map && t['option'] != null) {
          (t as Map<String, dynamic>)['option'] = normalizeStoryIdList(t['option'])
              .where((e) => cln(e) != id)
              .toList();
        }
      }
    }
    _positions.remove(id);
    _expandedNodes.remove(id);
    _checkInvalid.remove(id);
    setState(() {
      _selectedNode = null;
      _selectedEdge = null;
      _dirty = true;
    });
  }

  // ---------- 添加节点 ----------
  void _addTalkAfterSelected() {
    final sel = _selectedNode;
    final cur = sel != null ? _stageTalks[sel] : null;
    final curId = sel;
    final newId = curId == null || cur == null
        ? appendTalkId(null, _evtId ?? '', _stageTalks)
        : insertTalkId(curId, _stageTalks);
    if (newId.isEmpty) {
      _toast('无法分配对白 ID', fluent.InfoBarSeverity.warning);
      return;
    }
    final next = cur == null ? <dynamic>[] : normalizeStoryIdList(cur['nextTalk']);
    final newTalk = cur == null
        ? {
            'id': int.tryParse(newId) ?? 0,
            'roleIds': <dynamic>[],
            'content': '【新对白】',
            'nextTalk': <dynamic>[],
            'nextTalk2': <dynamic>[],
            'option': <dynamic>[],
          }
        : buildInsertedTalkRecord(cur as Map<String, dynamic>, newId, next);
    if (cur != null) {
      cur['nextTalk'] = normalizeStoryIdList([newId]);
    }
    _stageTalks[newId] = newTalk;
    final base = _positions[curId] ?? Offset(60, 40);
    _positions[newId] = base + const Offset(0, kFlowNodeH + 24);
    setState(() {
      _selectedNode = newId;
      _selectedEdge = null;
      _dirty = true;
    });
  }

  void _addOptionForSelected() {
    final sel = _selectedNode;
    if (sel == null || !_stageTalks.containsKey(sel)) {
      _toast('请先选中一个对白节点', fluent.InfoBarSeverity.warning);
      return;
    }
    final oid = allocOptionId(getTalkPrefix(sel), _stageOpts.keys.toSet());
    if (oid == null) {
      _toast('选项 ID 已用尽', fluent.InfoBarSeverity.warning);
      return;
    }
    _stageOpts[oid] = {
      'id': int.tryParse(oid) ?? 0,
      'content': '新选项',
      'talkId': <dynamic>[],
      'talkId2': <dynamic>[],
    };
    pushEdgeTarget(_stageTalks[sel], 'option', oid);
    final base = _positions[sel] ?? Offset(60, 40);
    _positions[oid] = base + const Offset(kFlowNodeW + 60, 20);
    setState(() {
      _selectedNode = oid;
      _selectedEdge = null;
      _dirty = true;
    });
  }

  /// 卡型节点添加（插件卡与内置预设共用）：新建 talk/option 记录后，
  /// 按 match 的 equals 播种字段（插件协议）、再整体合并 initial 预置字段
  /// （内置预设），使其按卡型渲染。
  void _addPluginCard(String typeId, String appliesTo) {
    Map<String, dynamic>? style;
    for (final c in _flowCards) {
      if (c['type_id'] == typeId) {
        style = c;
        break;
      }
    }
    if (style == null) return;
    void applyMatch(Map<String, dynamic> rec) {
      final m = style!['match'];
      if (m is Map && m['field'] is String && m['equals'] != null) {
        rec[m['field'] as String] = m['equals'];
      }
    }

    void applyInitial(Map<String, dynamic> rec) {
      final init = style!['initial'];
      if (init is Map && init.isNotEmpty) {
        // JSON 往返深拷贝：避免多个新节点共享预设里的 const 列表
        rec.addAll(jsonDecode(jsonEncode(init)) as Map<String, dynamic>);
      }
    }

    final selPos = _positions[_selectedNode] ?? const Offset(60, 40);
    if (appliesTo == 'talk') {
      final newId = appendTalkId(null, _evtId ?? '', _stageTalks);
      if (newId.isEmpty) {
        _toast('无法分配对白 ID', fluent.InfoBarSeverity.warning);
        return;
      }
      final rec = <String, dynamic>{
        'id': int.tryParse(newId) ?? 0,
        'roleIds': <dynamic>[],
        'content': '【${style['name'] ?? '新对白'}】',
        'nextTalk': <dynamic>[],
        'nextTalk2': <dynamic>[],
        'option': <dynamic>[],
      };
      applyMatch(rec);
      applyInitial(rec);
      _stageTalks[newId] = rec;
      _positions[newId] = selPos + const Offset(0, kFlowNodeH + 24);
      setState(() {
        _selectedNode = newId;
        _selectedEdge = null;
        _dirty = true;
      });
    } else {
      final sel = _selectedNode;
      if (sel == null || !_stageTalks.containsKey(sel)) {
        _toast('请先选中一个对白节点', fluent.InfoBarSeverity.warning);
        return;
      }
      final oid = allocOptionId(getTalkPrefix(sel), _stageOpts.keys.toSet());
      if (oid == null) {
        _toast('选项 ID 已用尽', fluent.InfoBarSeverity.warning);
        return;
      }
      final rec = <String, dynamic>{
        'id': int.tryParse(oid) ?? 0,
        'content': '【${style['name'] ?? '新选项'}】',
        'talkId': <dynamic>[],
        'talkId2': <dynamic>[],
      };
      applyMatch(rec);
      applyInitial(rec);
      _stageOpts[oid] = rec;
      pushEdgeTarget(_stageTalks[sel], 'option', oid);
      _positions[oid] = selPos + const Offset(kFlowNodeW + 60, 20);
      setState(() {
        _selectedNode = oid;
        _selectedEdge = null;
        _dirty = true;
      });
    }
  }

  // ---------- 事件增删 ----------
  void _promptCreateEvent() {
    final idCtl = _makeCtl('_evtId', '');
    final titleCtl = _makeCtl('_evtTitle', '');
    fluent.showDialog<String>(
      context: context,
      builder: (ctx) => fluent.ContentDialog(
        title: const Text('新建事件'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: idCtl,
              decoration: const InputDecoration(labelText: '事件 ID（7 位数字，首位 1）'),
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            ),
            const SizedBox(height: 8),
            TextField(
              controller: titleCtl,
              decoration: const InputDecoration(labelText: '事件标题'),
            ),
          ],
        ),
        actions: [
          fluent.Button(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          fluent.FilledButton(
            onPressed: () => Navigator.pop(ctx, 'ok'),
            child: const Text('创建'),
          ),
        ],
      ),
    ).then((r) async {
      if (r != 'ok' || !mounted) return;
      final id = idCtl.text.trim();
      if (!RegExp(r'^1\d{6}$').hasMatch(id)) {
        _toast('事件 ID 必须是 7 位数字且首位为 1', fluent.InfoBarSeverity.warning);
        return;
      }
      if (_tablesData['EvtCfg']!.containsKey(id)) {
        _toast('事件 $id 已存在', fluent.InfoBarSeverity.warning);
        return;
      }
      final title = titleCtl.text.trim();
      _tablesData['EvtCfg']![id] = {'id': int.parse(id), if (title.isNotEmpty) 'title': title};
      try {
        await ApiClient.instance.put('/api/cfg/EvtCfg',
            body: {'data': _tablesData['EvtCfg']!});
        if (!mounted) return;
        _selectEventInner(id);
        _toast('事件已创建', fluent.InfoBarSeverity.success);
      } catch (e) {
        if (!mounted) return;
        _toast('创建失败: $e', fluent.InfoBarSeverity.error);
      }
    });
  }

  void _promptDeleteEvent() {
    final evt = _evtId;
    if (evt == null) return;
    fluent.showDialog<bool>(
      context: context,
      builder: (ctx) => fluent.ContentDialog(
        title: const Text('删除事件'),
        content: Text(
          '删除事件 $evt${_eventTitle(evt) == null ? '' : '（${_eventTitle(evt)}）'}？'
          '该事件下的全部对白与选项也会一并删除。',
          style: TextStyle(fontSize: 12.5, color: palette.textPrimary),
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
    ).then((ok) async {
      if (ok != true || !mounted) return;
      final prefixes = _prefixes;
      final talks = _tablesData['TalkCfg']!;
      final opts = _tablesData['OptionCfg']!;
      talks.removeWhere((k, _) => storyIsInPrefixes(prefixes, k));
      opts.removeWhere((k, _) => storyIsInPrefixes(prefixes, k, isOption: true));
      _flowFile.remove(evt);
      _tablesData['EvtCfg']!.remove(evt);
      try {
        await ApiClient.instance.put('/api/cfg/TalkCfg', body: {'data': talks});
        await ApiClient.instance.put('/api/cfg/OptionCfg', body: {'data': opts});
        await ApiClient.instance.put('/api/cfg/EvtCfg',
            body: {'data': _tablesData['EvtCfg']!});
        if (!mounted) return;
        _evtId = null;
        _stageTalks = {};
        _stageOpts = {};
        _expandedNodes.clear();
        _checkInvalid.clear();
        setState(() => _dirty = false);
        _toast('事件已删除', fluent.InfoBarSeverity.success);
      } catch (e) {
        if (!mounted) return;
        _toast('删除失败: $e', fluent.InfoBarSeverity.error);
      }
    });
  }

  // ---------- 字段编辑 ----------
  /// 控制器按 key（事件|节点|字段 或专用键）懒创建，仅在创建时设初值。
  /// 重建时不重置文本：用户正在输入的中间态（逗号分隔、半截 JSON）一旦被
  /// 回退成上一个合法值，字段就永远打不进去。需要刷新文本时用
  /// [_resetPanelCtls] 清缓存，下次 build 以记录现值重建。
  TextEditingController _makeCtl(String key, String init) {
    return _ctls.putIfAbsent(key, () {
      final c = TextEditingController(text: init);
      _allCtls.add(c);
      return c;
    });
  }

  /// 数据被外部回退（放弃修改等）时清除字段控制器缓存。
  /// 控制器本体留在 _allCtls 里，仍由 dispose 统一释放。
  void _resetPanelCtls() {
    final prefix = '$_evtId|';
    _ctls.removeWhere((k, _) => k.startsWith(prefix));
  }

  /// 内联展开卡片的字段输入控制器（key = evtId|n:nodeId|field）。
  TextEditingController? _nodeCtlFor(String nodeId, String field) {
    final rec = _stageTalks[nodeId] ?? _stageOpts[nodeId];
    if (rec == null || _evtId == null) return null;
    final key = '$_evtId|n:$nodeId|$field';
    return _ctls.putIfAbsent(key, () {
      final String init;
      if (field == 'talkId' || field == 'talkId2') {
        init = normalizeStoryIdList(rec[field]).join(', ');
      } else if (field == 'check' || field == 'screenEffect') {
        init = jsonEncode(rec[field] ?? []);
      } else {
        init = cln(rec[field]);
      }
      final c = TextEditingController(text: init);
      _allCtls.add(c);
      return c;
    });
  }

  /// 外部写回字段后同步已存在的输入框文案（如资产拖放设置 bg/audio）。
  void _syncNodeCtl(String nodeId, String field) {
    final key = '$_evtId|n:$nodeId|$field';
    final c = _ctls[key];
    if (c == null) return;
    final rec = _stageTalks[nodeId] ?? _stageOpts[nodeId];
    if (rec == null) return;
    c.text = (field == 'check' || field == 'screenEffect')
        ? jsonEncode(rec[field] ?? [])
        : cln(rec[field]);
  }

  /// 内联编辑文本写回（按字段类型解析）。与旧右栏 _setCheckField /
  /// _setIdListField / _setIntField 语义一致，只是目标改为任意节点。
  void _applyFieldText(String nodeId, String field, String text) {
    final rec = _stageTalks[nodeId] ?? _stageOpts[nodeId];
    if (rec == null) return;
    switch (field) {
      case 'bg':
      case 'audio':
      case 'time':
      case 'nextEvtId':
        final v = int.tryParse(text.trim());
        if (v == null) {
          rec.remove(field);
        } else {
          rec[field] = v;
        }
      case 'talkId':
      case 'talkId2':
        rec[field] = text
            .split(RegExp(r'[,，\s]+'))
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty && int.tryParse(s) != null)
            .map(int.parse)
            .toList();
      case 'check':
      case 'screenEffect':
        dynamic parsed;
        try {
          parsed = jsonDecode(text.trim());
        } catch (_) {
          parsed = null;
        }
        if (parsed is List || text.trim().isEmpty) {
          _checkInvalid.remove(nodeId);
          rec[field] = parsed ?? <dynamic>[];
        } else {
          _checkInvalid.add(nodeId);
        }
      default:
        // roleName / content 直接写文本
        rec[field] = text;
    }
    setState(() => _dirty = true);
  }

  // ---------- 媒体资产拖放 ----------
  /// 资产 key ↔ AudioCfg/BgCfg.url 匹配：basename（去目录/扩展名）相等。
  List<(String, Map<String, dynamic>)> _matchCfgByUrl(
      Map<String, dynamic> table, String key) {
    final kb = _baseName(key);
    final out = <(String, Map<String, dynamic>)>[];
    table.forEach((id, v) {
      if (v is! Map) return;
      final url = cln(v['url']);
      if (url.isEmpty) return;
      if (_baseName(url) == kb) {
        out.add((id.toString(), Map<String, dynamic>.from(v)));
      }
    });
    return out;
  }

  String _baseName(String p) {
    var s = p.replaceAll('\\', '/').toLowerCase();
    final i = s.lastIndexOf('/');
    if (i >= 0) s = s.substring(i + 1);
    final d = s.lastIndexOf('.');
    if (d > 0) s = s.substring(0, d);
    return s.trim();
  }

  /// CGCfg.urls（贴图 key/路径数组）↔ 资产 key basename 匹配。
  List<(String, Map<String, dynamic>)> _matchCgByUrl(
      Map<String, dynamic> table, String key) {
    final kb = _baseName(key);
    final out = <(String, Map<String, dynamic>)>[];
    table.forEach((id, v) {
      if (v is! Map) return;
      final urls = v['urls'];
      if (urls is! List) return;
      for (final u in urls) {
        if (_baseName(cln(u)) == kb) {
          out.add((id.toString(), Map<String, dynamic>.from(v)));
          break;
        }
      }
    });
    return out;
  }

  /// 拖入相册 CG（未命中 BgCfg 时）：整句只有一个屏幕效果，直接写
  /// screenEffect = [4015, CGid]（播放CG 指令，data_dicts SCREEN_EFFECT_DB）。
  void _writePlayCg(String nodeId, (String, Map<String, dynamic>) hit) {
    final rec = _stageTalks[nodeId];
    if (rec == null) return;
    final cgId = int.tryParse(hit.$1) ?? hit.$1;
    rec['screenEffect'] = [4015, cgId];
    _syncNodeCtl(nodeId, 'screenEffect');
    setState(() => _dirty = true);
    final name = cln(hit.$2['name']);
    _toast(name.isEmpty ? '已插入播放CG（CG $cgId）' : '已插入播放CG：$name',
        fluent.InfoBarSeverity.success);
  }

  Future<void> _applyAssetDrop(String nodeId, FlowAssetRef ref) async {
    final rec = _stageTalks[nodeId];
    if (rec == null) {
      _toast('媒体资产只能拖到对白节点上', fluent.InfoBarSeverity.warning);
      return;
    }
    final tableName = ref.kind == 'aud' ? 'AudioCfg' : 'BgCfg';
    final field = ref.kind == 'aud' ? 'audio' : 'bg';
    final table = _tablesData[tableName];
    final List<(String, Map<String, dynamic>)> matches =
        (table == null || table.isEmpty) ? const [] : _matchCfgByUrl(table, ref.key);
    if (matches.isEmpty) {
      // 贴图未命中背景表：再按 CG 相册表匹配 → 插入播放CG 指令
      if (ref.kind != 'aud') {
        final cgTable = _tablesData['CGCfg'];
        final cgMatches = cgTable == null || cgTable.isEmpty
            ? const <(String, Map<String, dynamic>)>[]
            : _matchCgByUrl(cgTable, ref.key);
        if (cgMatches.isNotEmpty) {
          final hit = cgMatches.length > 1
              ? await _pickCfgDialog('CGCfg', cgMatches)
              : cgMatches.single;
          if (hit == null || !mounted) return;
          _writePlayCg(nodeId, hit);
          return;
        }
      }
      if (table == null || table.isEmpty) {
        _toast('$tableName 为空，无法匹配资产', fluent.InfoBarSeverity.warning);
        return;
      }
      _toast('$tableName 中 url 没有匹配「${ref.key}」的记录，'
          '请先在资源页导出或登记该资产', fluent.InfoBarSeverity.warning);
      return;
    }
    if (matches.length > 1) {
      final picked = await _pickCfgDialog(tableName, matches);
      if (picked == null || !mounted) return;
      _writeAssetField(nodeId, field, picked);
      return;
    }
    _writeAssetField(nodeId, field, matches.single);
  }

  void _writeAssetField(
      String nodeId, String field, (String, Map<String, dynamic>) hit) {
    final rec = _stageTalks[nodeId];
    if (rec == null) return;
    final idVal = int.tryParse(hit.$1) ?? hit.$1;
    rec[field] = idVal;
    _syncNodeCtl(nodeId, field);
    setState(() => _dirty = true);
    final name = cln(hit.$2['name']);
    _toast('已将对白 $nodeId 的${field == 'audio' ? '音频' : '背景'}设为 '
        '#${hit.$1}${name.isEmpty ? '' : '（$name）'}', fluent.InfoBarSeverity.success);
  }

  /// 多个候选时弹选择框（id + name + url 列表）。
  Future<(String, Map<String, dynamic>)?> _pickCfgDialog(
    String tableName,
    List<(String, Map<String, dynamic>)> matches,
  ) {
    return fluent.showDialog<(String, Map<String, dynamic>)>(
      context: context,
      builder: (ctx) => fluent.ContentDialog(
        title: Text('$tableName 匹配到 ${matches.length} 条记录，请选择'),
        content: SizedBox(
          width: 420,
          height: math.min(320, matches.length * 44 + 16),
          child: ListView.builder(
            itemCount: matches.length,
            itemBuilder: (context, i) {
              final hit = matches[i];
              final name = cln(hit.$2['name']);
              final url = cln(hit.$2['url']);
              return InkWell(
                onTap: () => Navigator.pop(ctx, hit),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 7),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(5),
                    color: palette.panel,
                  ),
                  margin: const EdgeInsets.only(bottom: 4),
                  child: Row(
                    children: [
                      Text('#${hit.$1}',
                          style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: const Color(0xFF6C5CE7))),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          name.isEmpty ? url : '$name\n$url',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 11.5, color: palette.textPrimary),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
        actions: [
          fluent.Button(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
        ],
      ),
    );
  }

  // ---------- UI ----------
  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: fluent.ProgressRing());
    }
    if (_error.isNotEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, color: palette.textHint, size: 32),
            const SizedBox(height: 8),
            Text(_error, style: TextStyle(color: palette.textSecondary)),
          ],
        ),
      );
    }
    return Stack(
      children: [
        Positioned.fill(
          child: ColoredBox(color: palette.bgAlt, child: _buildCanvasPane()),
        ),
        // 右上：操作簇（适配视图 / 预览 / 保存）
        Positioned(
          right: 12,
          top: 10,
          child: _buildActionsPill(),
        ),
        // 左侧浮动工具栏
        Positioned(
          left: 12,
          top: 0,
          bottom: 0,
          child: Center(
            child: StoryFlowSideToolbar(
              enabled: _evtId != null,
              flowCards: _flowCards,
              assetsOpen: _assetsOpen,
              aiOpen: widget.aiOpen,
              onToggleAssets: () => setState(() => _assetsOpen = !_assetsOpen),
              onToggleAi: widget.onToggleAi ?? () {},
              onAddTalk: _addTalkAfterSelected,
              onAddOption: _addOptionForSelected,
              onAddCard: _addPluginCard,
              onOpenPlugins: widget.onOpenPlugins,
              onOpenSettings: widget.onOpenSettings,
            ),
          ),
        ),
        // 媒体资产浮动面板
        if (_assetsOpen)
          Positioned(
            left: 62,
            top: 48,
            bottom: 16,
            width: 252,
            child: FlowAssetPanel(state: widget.state),
          ),
        // 左上：事件切换器 + Mod 切换器
        Positioned(
          left: 12,
          top: 10,
          child: Row(
            children: [
              _EventChip(
                evtId: _evtId,
                title: _evtId == null ? null : _eventTitle(_evtId!),
                events: _tablesData['EvtCfg']!.keys.toList()
                  ..sort(compareEventIds),
                titleOf: _eventTitle,
                onSelect: _selectEvent,
                onCreate: _promptCreateEvent,
                onDelete: _evtId == null ? null : _promptDeleteEvent,
              ),
              const SizedBox(width: 8),
              _ModChip(
                modName: widget.state.modName,
                onSelect: _switchMod,
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ----- 画布 -----
  Widget _buildCanvasPane() {
    if (_evtId == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.hub_outlined, size: 40, color: palette.iconDisabled),
            const SizedBox(height: 10),
            Text('从左上角选择或新建一个事件开始编排',
                style: TextStyle(color: palette.textHint)),
            const SizedBox(height: 4),
            Text('提示：靠近屏幕顶部可呼出标签条，展开节点右下角箭头可编辑参数',
                style: TextStyle(fontSize: 11, color: palette.textFaint)),
          ],
        ),
      );
    }
    final graph = _graph;
    // DragTarget 直接包裹画布：onMove 用画布命中高亮目标节点
    return DragTarget<FlowAssetRef>(
      onWillAcceptWithDetails: (_) => true,
      onMove: (details) {
        final id = _graphKey.currentState?.hitNodeAt(details.offset);
        if (id != _dragHoverNode) setState(() => _dragHoverNode = id);
      },
      onLeave: (_) {
        if (_dragHoverNode != null) {
          setState(() => _dragHoverNode = null);
        }
      },
      onAcceptWithDetails: (details) {
        final node = _graphKey.currentState?.hitNodeAt(details.offset);
        setState(() => _dragHoverNode = null);
        if (node != null) _applyAssetDrop(node, details.data);
      },
      builder: (context, candidate, rejected) => StoryFlowGraph(
        key: _graphKey,
        graph: graph,
        positions: _positions,
        selectedNode: _selectedNode,
        selectedEdge: _selectedEdge,
        expandedNodes: _expandedNodes,
        highlightNode: _dragHoverNode,
        checkInvalidNodes: _checkInvalid,
        onSelectNode: (id) => setState(() {
          _selectedNode = id;
          _selectedEdge = null;
        }),
        onSelectEdge: (e) => setState(() {
          _selectedEdge = e;
          _selectedNode = null;
        }),
        onSelectNone: () => setState(() {
          _selectedNode = null;
          _selectedEdge = null;
        }),
        onMoveNode: _onMoveNode,
        onAddEdge: _onAddEdge,
        onDeleteEdge: _onDeleteEdge,
        onRequestDelete: _requestDelete,
        onToggleExpand: (id) => setState(() {
          if (!_expandedNodes.remove(id)) _expandedNodes.add(id);
        }),
        fieldController: _nodeCtlFor,
        onFieldChanged: _applyFieldText,
        onDeleteNode: _deleteNode,
      ),
    );
  }

  // ----- 右上操作簇 -----
  Widget _buildActionsPill() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      decoration: BoxDecoration(
        color: palette.card,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: palette.border),
        boxShadow: [
          BoxShadow(
            color: palette.bgDeep2.withValues(alpha: 0.55),
            blurRadius: 14,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _pillAction(
            icon: Icons.fit_screen_outlined,
            label: '适配视图',
            onTap: () => _graphKey.currentState?.fitView(),
          ),
          if (_dirty) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: const Color(0xFFE67E22).withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text('未保存',
                  style:
                      TextStyle(fontSize: 10.5, color: Color(0xFFE67E22))),
            ),
          ],
          _pillAction(
            icon: Icons.play_circle_outline,
            label: '运行预览',
            onTap: _evtId == null ? null : () => widget.onPreview(_evtId!),
          ),
          _pillAction(
            icon: Icons.save_outlined,
            label: _dirty ? '保存修改' : '已保存',
            onTap: (_dirty && _evtId != null) ? _save : null,
            primary: true,
          ),
        ],
      ),
    );
  }

  Widget _pillAction({
    required IconData icon,
    required String label,
    required VoidCallback? onTap,
    bool primary = false,
  }) {
    final enabled = onTap != null;
    return Tooltip(
      message: label,
      waitDuration: const Duration(milliseconds: 400),
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: primary
                  ? const Color(0xFF6C5CE7)
                  : enabled
                      ? palette.hover
                      : Colors.transparent,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  icon,
                  size: 13,
                  color: primary
                      ? Colors.white
                      : enabled
                          ? palette.textSecondary
                          : palette.iconDisabled,
                ),
                const SizedBox(width: 4),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 11.5,
                    color: primary
                        ? Colors.white
                        : enabled
                            ? palette.textPrimary
                            : palette.iconDisabled,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Map<String, dynamic> _deepCopy(Map<String, dynamic> src) {
    final out = <String, dynamic>{};
    src.forEach((k, v) => out[k] = _deepCopyVal(v));
    return out;
  }

  dynamic _deepCopyVal(dynamic v) {
    if (v is Map) {
      return v.map((k, val) => MapEntry(k.toString(), _deepCopyVal(val)));
    }
    if (v is List) {
      return v.map(_deepCopyVal).toList();
    }
    return v;
  }
}

/// 画布左上角事件切换 chip：点击弹出锚定面板（搜索 + 列表 + 新建/删除）。
class _EventChip extends StatefulWidget {
  const _EventChip({
    required this.evtId,
    required this.title,
    required this.events,
    required this.titleOf,
    required this.onSelect,
    required this.onCreate,
    this.onDelete,
  });

  final String? evtId;
  final String? title;
  final List<String> events;

  /// 事件 id → 标题（无标题返回 null/空串），列表行与搜索用它显示名称。
  final String? Function(String id) titleOf;
  final ValueChanged<String> onSelect;
  final VoidCallback onCreate;
  final VoidCallback? onDelete;

  @override
  State<_EventChip> createState() => _EventChipState();
}

class _EventChipState extends State<_EventChip> {
  final _link = LayerLink();
  OverlayEntry? _overlay;
  String _filter = '';

  @override
  void dispose() {
    _close();
    super.dispose();
  }

  void _close() {
    _overlay?.remove();
    _overlay = null;
  }

  String _rowLabel(String id) {
    final t = widget.titleOf(id);
    if (t == null || t.isEmpty) return id;
    return '$id  $t';
  }

  @override
  void didUpdateWidget(covariant _EventChip old) {
    super.didUpdateWidget(old);
    if (old.evtId != widget.evtId && _overlay != null) _close();
  }

  void _toggle() {
    if (_overlay != null) {
      _close();
    } else {
      _open();
    }
  }

  void _open() {
    _overlay = OverlayEntry(
      builder: (_) => Stack(
        children: [
          // 点击面板外关闭
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _close,
              child: const SizedBox.shrink(),
            ),
          ),
          CompositedTransformFollower(
            link: _link,
            targetAnchor: Alignment.bottomLeft,
            followerAnchor: Alignment.topLeft,
            offset: const Offset(0, 6),
            child: Material(
              type: MaterialType.transparency,
              child: _panel(),
            ),
          ),
        ],
      ),
    );
    Overlay.of(context, rootOverlay: true).insert(_overlay!);
  }

  Widget _panel() {
    return StatefulBuilder(
      builder: (context, setPanel) {
        final filter = _filter.trim();
        final shown = widget.events
            .where((id) =>
                filter.isEmpty ||
                id.contains(filter) ||
                (widget.titleOf(id)?.contains(filter) ?? false))
            .toList();
        return Container(
          width: 300,
          constraints: const BoxConstraints(maxHeight: 380),
          decoration: BoxDecoration(
            color: palette.card,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: palette.border),
            boxShadow: [
              BoxShadow(
                color: palette.bgDeep2.withValues(alpha: 0.6),
                blurRadius: 16,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.all(8),
                child: fluent.TextBox(
                  autofocus: true,
                  placeholder: '搜索事件 ID',
                  prefix: const Icon(Icons.search, size: 13),
                  style: const TextStyle(fontSize: 12),
                  onChanged: (v) => setPanel(() => _filter = v),
                ),
              ),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  itemCount: shown.length,
                  itemBuilder: (context, i) {
                    final id = shown[i];
                    final sel = id == widget.evtId;
                    return InkWell(
                      onTap: () {
                        setPanel(() => _filter = '');
                        _close();
                        widget.onSelect(id);
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 6),
                        decoration: BoxDecoration(
                          color: sel ? palette.hover : Colors.transparent,
                          borderRadius: BorderRadius.circular(5),
                          border: Border.all(
                            color: sel
                                ? const Color(0xFF6C5CE7)
                                : Colors.transparent,
                          ),
                        ),
                        child: Row(
                          children: [
                            Icon(Icons.event_note,
                                size: 13,
                                color: sel
                                    ? const Color(0xFF6C5CE7)
                                    : palette.textHint),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                _rowLabel(id),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: sel
                                      ? palette.textHigh
                                      : palette.textSecondary,
                                  fontWeight:
                                      sel ? FontWeight.w600 : FontWeight.normal,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
              Divider(height: 1, color: palette.border),
              Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: 8, vertical: 6),
                child: Row(
                  children: [
                    Expanded(
                      child: fluent.Button(
                        onPressed: () {
                          _close();
                          widget.onCreate();
                        },
                        child: const Text('＋ 新建事件',
                            style: TextStyle(fontSize: 12)),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: fluent.Button(
                        onPressed: widget.onDelete == null
                            ? null
                            : () {
                                _close();
                                widget.onDelete!();
                              },
                        child: const Text('删除当前',
                            style: TextStyle(fontSize: 12)),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final empty = widget.evtId == null;
    return CompositedTransformTarget(
      link: _link,
      child: Material(
        type: MaterialType.transparency,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            onTap: _toggle,
            child: Container(
              constraints: const BoxConstraints(maxWidth: 320),
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              decoration: BoxDecoration(
                color: palette.card,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: palette.border),
                boxShadow: [
                  BoxShadow(
                    color: palette.bgDeep2.withValues(alpha: 0.55),
                    blurRadius: 14,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.alt_route,
                      size: 14, color: Color(0xFF6C5CE7)),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      empty
                          ? '选择事件'
                          : (widget.title == null ||
                                  widget.title!.isEmpty
                              ? widget.evtId!
                              : '${widget.evtId}  ${widget.title}'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: empty
                            ? palette.textHint
                            : palette.textHigh,
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(Icons.arrow_drop_down,
                      size: 16, color: palette.textSecondary),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 画布左上角、事件切换器右侧的 Mod 切换 chip。
/// 点击时先经 GET /api/mods 拉最新列表再弹菜单（本版本 Flutter 的
/// PopupMenuItemBuilder 不支持异步）；选中项触发全局切换
/// （POST /api/mods/select，配置表/布局/保存目标随之换 mod 根）。
class _ModChip extends StatelessWidget {
  const _ModChip({required this.modName, required this.onSelect});

  final String modName;
  final ValueChanged<String> onSelect;

  Future<void> _openMenu(BuildContext context) async {
    // 菜单位置锚点须在 await 前取好，避免跨异步间隙使用 BuildContext
    final button = context.findRenderObject() as RenderBox?;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    List<ModInfo> mods = [];
    try {
      final r = await ApiClient.instance.get('/api/mods');
      final list = r['mods'];
      if (list is List) {
        mods = [
          for (final m in list)
            if (m is Map) ModInfo.fromJson(Map<String, dynamic>.from(m))
        ];
      }
    } catch (_) {
      // 拉取失败按空列表处理，菜单内给出提示
    }
    if (!context.mounted) return;
    final items = mods.isEmpty
        ? [
            const PopupMenuItem<String>(
              enabled: false,
              child: Text('没有可用的 Mod', style: TextStyle(fontSize: 12)),
            ),
          ]
        : [
            for (final m in mods)
              PopupMenuItem<String>(
                value: m.name,
                child: Row(
                  children: [
                    Icon(
                      m.name == modName
                          ? Icons.check
                          : Icons.inventory_2_outlined,
                      size: 14,
                      color: m.name == modName
                          ? const Color(0xFF6C5CE7)
                          : palette.textHint,
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 220,
                      child: Text(
                        m.manifestTitle.isEmpty
                            ? m.name
                            : '${m.name}（${m.manifestTitle}）',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
          ];
    if (button == null) return;
    final selected = await showMenu<String>(
      context: context,
      // 悬浮在画布上：指定不透明底板，避免透出节点/连线
      color: palette.card,
      position: RelativeRect.fromRect(
        Rect.fromPoints(
          button.localToGlobal(
              button.size.bottomLeft(Offset.zero), ancestor: overlay),
          button.localToGlobal(
              button.size.bottomRight(Offset.zero), ancestor: overlay),
        ),
        Offset.zero & overlay.size,
      ),
      items: items,
    );
    if (selected != null) onSelect(selected);
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => _openMenu(context),
        child: Container(
          constraints: const BoxConstraints(maxWidth: 220),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: BoxDecoration(
            color: palette.card,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: palette.border),
            boxShadow: [
              BoxShadow(
                color: palette.bgDeep2.withValues(alpha: 0.55),
                blurRadius: 14,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.inventory_2_outlined,
                  size: 14, color: Color(0xFF6C5CE7)),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  modName.isEmpty ? '选择 Mod' : modName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: modName.isEmpty
                        ? palette.textHint
                        : palette.textHigh,
                  ),
                ),
              ),
              const SizedBox(width: 4),
              Icon(Icons.arrow_drop_down,
                  size: 16, color: palette.textSecondary),
            ],
          ),
        ),
      ),
    );
  }
}
