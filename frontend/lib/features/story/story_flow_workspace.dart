import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart' hide Card;
import 'package:flutter/services.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import '../../core/api_client.dart';
import '../../core/app_theme.dart';
import '../../core/models.dart';
import 'story_flow_graph.dart';
import 'story_flow_models.dart';
import 'story_logic.dart';

/// 剧情图模式工作区：左=事件列表，中=流程图画布，右=节点编辑面板。
///
/// 数据流与故事导演一致：并行加载 7 张表 → 选事件用 stageOf 切舞台副本 →
/// 编辑副本 → mergeStageBack 后顺序 PUT 三张表。节点位置持久化到
/// `<mod根>/.editor_flow.json`（游戏不读取该文件）。
class StoryFlowWorkspace extends StatefulWidget {
  const StoryFlowWorkspace({
    super.key,
    required this.state,
    required this.onPreview,
  });

  final AppState state;

  /// 事件 id → 打开场景预览（宿主打开 OpenDoc.preview）。
  final ValueChanged<String> onPreview;

  @override
  State<StoryFlowWorkspace> createState() => _StoryFlowWorkspaceState();
}

class _StoryFlowWorkspaceState extends State<StoryFlowWorkspace> {
  static const _tables = [
    'EvtCfg', 'TalkCfg', 'OptionCfg',
    'PersonCfg', 'BgCfg', 'AudioCfg', 'EvtTypeCfg',
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

  // 选中
  String? _selectedNode;
  FlowEdge? _selectedEdge;

  // 事件列表
  String _evtFilter = '';
  bool _checkError = false;

  @override
  void initState() {
    super.initState();
    _load();
    _loadFlowFile();
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
      // 插件流程卡片声明（引擎无影响，命中 match 的节点按卡型渲染）
      try {
        final fc = await ApiClient.instance.get('/api/plugins/ui/flow_cards');
        final list = fc['flow_cards'];
        _flowCards = list is List
            ? [for (final c in list) if (c is Map) Map<String, dynamic>.from(c)]
            : [];
      } catch (_) {
        _flowCards = [];
      }
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
          _flowFile = parsed.cast<String, dynamic>();
        }
      }
    } catch (_) {
      // 文件不存在或沙箱拒绝：使用空布局
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
        await _save();
        if (!mounted) return;
      }
    }
    if (mounted) _selectEventInner(evtId);
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
    if (mounted) setState(() => _dirty = false);
  }

  void _selectEventInner(String evtId) {
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
    _loadPositionsForEvent();
    _syncCheckField();
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

  Future<void> _save() async {
    if (_evtId == null) return;
    final talks = _tablesData['TalkCfg']!;
    final opts = _tablesData['OptionCfg']!;
    mergeStageBack(talks, _talkBaseline, _stageTalks, _prefixes);
    mergeStageBack(opts, _optBaseline, _stageOpts, _prefixes, isOption: true);
    try {
      await ApiClient.instance.put('/api/cfg/TalkCfg', body: {'data': talks});
      await ApiClient.instance.put('/api/cfg/OptionCfg', body: {'data': opts});
      await ApiClient.instance.put('/api/cfg/EvtCfg',
          body: {'data': _tablesData['EvtCfg']!});
      if (!mounted) return;
      setState(() {
        _talkBaseline = _deepCopy(_stageTalks);
        _optBaseline = _deepCopy(_stageOpts);
        _dirty = false;
      });
      _toast('已保存', fluent.InfoBarSeverity.success);
    } catch (e) {
      if (!mounted) return;
      _toast('保存失败: $e', fluent.InfoBarSeverity.error);
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

  /// 插件流程卡片：以内置新节点预置卡型 match 字段，使其按插件定义渲染。
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
        setState(() => _dirty = false);
        _toast('事件已删除', fluent.InfoBarSeverity.success);
      } catch (e) {
        if (!mounted) return;
        _toast('删除失败: $e', fluent.InfoBarSeverity.error);
      }
    });
  }

  // ---------- 字段编辑 ----------
  TextEditingController _makeCtl(String key, String init) {
    var c = _ctls[key];
    if (c != null) {
      if (c.text != init) {
        c.text = init;
      }
      return c;
    }
    c = TextEditingController(text: init);
    _ctls[key] = c;
    _allCtls.add(c);
    return c;
  }

  /// 选中 fallback 时同步各字段输入框文案（不更新光标提示）。
  String _selKey(String field) => '$_evtId|$_selectedNode|$field';

  Map<String, dynamic>? get _selRecord =>
      _selectedNode == null ? null : (_stageTalks[_selectedNode] ?? _stageOpts[_selectedNode]);

  void _syncCheckField() {
    _checkError = false;
  }

  void _setField(String key, dynamic value) {
    final rec = _selRecord;
    if (rec == null) return;
    if (value == null) {
      rec.remove(key);
    } else {
      rec[key] = value;
    }
    setState(() => _dirty = true);
  }

  void _setIntField(String key, String text) {
    _setField(key, int.tryParse(text.trim()));
  }

  void _setCheckField(String text) {
    dynamic parsed;
    try {
      parsed = jsonDecode(text.trim());
    } catch (_) {
      parsed = null;
    }
    if (parsed is List || text.trim().isEmpty) {
      _checkError = false;
    } else {
      _checkError = true;
      if (mounted) setState(() {});
      return;
    }
    _setField('check', parsed ?? <dynamic>[]);
  }

  void _setIdListField(String key, String text) {
    final ids = text
        .split(RegExp(r'[,，\s]+'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty && int.tryParse(s) != null)
        .map(int.parse)
        .toList();
    _setField(key, ids);
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
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildEventList(),
        VerticalDivider(width: 1, color: palette.border),
        Expanded(child: _buildCanvasPane()),
        VerticalDivider(width: 1, color: palette.border),
        SizedBox(width: 340, child: _buildRightPane()),
      ],
    );
  }

  // ----- 左：事件列表 -----
  Widget _buildEventList() {
    final evts = _tablesData['EvtCfg']!.keys.toList()..sort(compareEventIds);
    final filter = _evtFilter.trim();
    final shown = filter.isEmpty
        ? evts
        : [
            for (final id in evts)
              if (id.contains(filter) ||
                  (_eventTitle(id) ?? '').contains(filter))
                id,
          ];
    return SizedBox(
      width: 280,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.all(8),
            child: fluent.TextBox(
              controller: _makeCtl('_evtFilter', _evtFilter),
              placeholder: '搜索事件 ID / 标题',
              onChanged: (v) => setState(() => _evtFilter = v),
              prefix: const Icon(Icons.search, size: 14),
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(10, 2, 10, 6),
            child: Text('事件', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: shown.length,
              itemBuilder: (context, i) {
                final id = shown[i];
                final sel = id == _evtId;
                final title = _eventTitle(id);
                return InkWell(
                  onTap: () => _selectEvent(id),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                    color: sel ? palette.panel : Colors.transparent,
                    child: Row(
                      children: [
                        Icon(Icons.event_note,
                            size: 14, color: sel ? const Color(0xFF6C5CE7) : palette.textHint),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            '$id${title == null ? '' : '  $title'}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              color: sel ? palette.textHigh : palette.textSecondary,
                              fontWeight: sel ? FontWeight.w600 : FontWeight.normal,
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
          Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                Expanded(
                  child: fluent.Button(
                    onPressed: _promptCreateEvent,
                    child: const Text('＋ 新建事件', style: TextStyle(fontSize: 12)),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: fluent.Button(
                    onPressed: _evtId == null ? null : _promptDeleteEvent,
                    child: const Text('删除当前', style: TextStyle(fontSize: 12)),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ----- 中：画布 -----
  Widget _buildCanvasPane() {
    final graph = _graph;
    final evtTitle = _evtId == null ? null : _eventTitle(_evtId!);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          height: 40,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          color: palette.bg,
          child: Row(
            children: [
              if (_evtId != null) ...[
                Icon(Icons.alt_route, size: 14, color: const Color(0xFF6C5CE7)),
                const SizedBox(width: 6),
                Text(
                  evtTitle == null || evtTitle.isEmpty
                      ? _evtId!
                      : '$_evtId  $evtTitle',
                  style: TextStyle(fontSize: 12, color: palette.textHigh, fontWeight: FontWeight.w600),
                ),
                const SizedBox(width: 8),
                if (_dirty)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: const Color(0xFFE67E22).withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: const Text('有未保存修改', style: TextStyle(fontSize: 11, color: Color(0xFFE67E22))),
                  ),
              ] else
                Text('选择一个事件开始编排',
                    style: TextStyle(fontSize: 12, color: palette.textHint)),
              const Spacer(),
              PopupMenuButton<String>(
                tooltip: '添加节点',
                enabled: _evtId != null,
                onSelected: (v) {
                  if (v == 'talk') _addTalkAfterSelected();
                  if (v == 'option') _addOptionForSelected();
                  if (v.startsWith('card:')) {
                    final parts = v.split(':');
                    if (parts.length >= 3) _addPluginCard(parts[1], parts[2]);
                  }
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(
                    value: 'talk',
                    child: Row(children: [
                      Icon(Icons.add_comment, size: 14),
                      SizedBox(width: 8),
                      Text('插入新对白（选中对白后）', style: TextStyle(fontSize: 12)),
                    ]),
                  ),
                  const PopupMenuItem(
                    value: 'option',
                    child: Row(children: [
                      Icon(Icons.alt_route, size: 14),
                      SizedBox(width: 8),
                      Text('为选中对白添加选项', style: TextStyle(fontSize: 12)),
                    ]),
                  ),
                  if (_flowCards.isNotEmpty) const PopupMenuDivider(),
                  // 插件流程卡片：创建节点时预置 match 字段，节点按卡型渲染
                  for (final c in _flowCards)
                    PopupMenuItem(
                      value: 'card:${c['type_id']}:${c['applies_to']}',
                      child: Row(
                        children: [
                          const Icon(Icons.extension, size: 14),
                          const SizedBox(width: 8),
                          Text(
                            '插件卡片 · ${c['name'] ?? c['type_id']}'
                            '（${c['applies_to'] == 'talk' ? '对白' : '选项'}）',
                            style: const TextStyle(fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                ],
                child: fluent.Button(
                  onPressed: _evtId == null ? null : () {},
                  child: const Text('＋ 添加节点', style: TextStyle(fontSize: 12)),
                ),
              ),
              const SizedBox(width: 8),
              fluent.Button(
                onPressed: () => _graphKey.currentState?.fitView(),
                child: const Text('适配视图', style: TextStyle(fontSize: 12)),
              ),
              const SizedBox(width: 8),
              fluent.FilledButton(
                onPressed: _evtId == null
                    ? null
                    : () => widget.onPreview(_evtId!),
                child: const Text('▶ 运行预览', style: TextStyle(fontSize: 12)),
              ),
              const SizedBox(width: 8),
              fluent.FilledButton(
                onPressed: (_dirty && _evtId != null) ? _save : null,
                style: const fluent.ButtonStyle(
                  backgroundColor: WidgetStatePropertyAll(Color(0xFF6C5CE7)),
                ),
                child: Text(_dirty ? '💾 保存修改' : '已保存', style: const TextStyle(fontSize: 12)),
              ),
            ],
          ),
        ),
        Expanded(
          child: _evtId == null
              ? Center(
                  child: Text('← 从左侧选择一个事件',
                      style: TextStyle(color: palette.textHint)),
                )
              : Padding(
                  padding: const EdgeInsets.all(10),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: ColoredBox(
                      color: palette.panel,
                      child: StoryFlowGraph(
                        key: _graphKey,
                        graph: graph,
                        positions: _positions,
                        selectedNode: _selectedNode,
                        selectedEdge: _selectedEdge,
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
                      ),
                    ),
                  ),
                ),
        ),
      ],
    );
  }

  // ----- 右：节点编辑 -----
  Widget _buildRightPane() {
    final rec = _selRecord;
    if (rec == null) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Text('未选中节点\n\n点击画布中的节点卡片进行编辑；'
            '从端口拖线到另一节点建立跳转。',
            style: TextStyle(fontSize: 12, color: palette.textHint, height: 1.8)),
      );
    }
    final id = _selectedNode!;
    final isOpt = _stageOpts.containsKey(id);
    final title = isOpt ? '选项 $id' : (rec['roleName'] == '旁白' ? '旁白 $id' : '对白 $id');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          height: 40,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          color: palette.bg,
          child: Row(
            children: [
              Icon(isOpt ? Icons.alt_route : Icons.chat,
                  size: 14, color: isOpt ? const Color(0xFF6C5CE7) : const Color(0xFF3498DB)),
              const SizedBox(width: 6),
              Expanded(
                child: Text(title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: palette.textHigh, fontWeight: FontWeight.w600)),
              ),
              fluent.Button(
                onPressed: () => _deleteNode(id),
                child: const Text('删除节点', style: TextStyle(fontSize: 11)),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(12),
            children: [
              _label('ID'),
              Text(cln(id), style: TextStyle(fontSize: 11, color: palette.textMuted)),
              const SizedBox(height: 10),
              if (isOpt) ...[
                _label('选项内容'),
                fluent.TextBox(
                  controller: _makeCtl(_selKey('content'), cln(rec['content'])),
                  maxLines: 3,
                  onChanged: (v) => _setField('content', v),
                ),
                const SizedBox(height: 10),
                _label('主支对白 talkId（逗号分隔）'),
                fluent.TextBox(
                  controller: _makeCtl(_selKey('talkId'),
                      normalizeStoryIdList(rec['talkId']).join(', ')),
                  onChanged: (v) {
                    _setIdListField('talkId', v);
                    _syncListCtl('talkId', _stageOpts[id]);
                  },
                ),
                const SizedBox(height: 10),
                _label('支线对白 talkId2（逗号分隔）'),
                fluent.TextBox(
                  controller: _makeCtl(_selKey('talkId2'),
                      normalizeStoryIdList(rec['talkId2']).join(', ')),
                  onChanged: (v) => _setIdListField('talkId2', v),
                ),
                const SizedBox(height: 10),
                _label('跳转事件 nextEvtId'),
                fluent.TextBox(
                  controller: _makeCtl(_selKey('nextEvtId'), cln(rec['nextEvtId'])),
                  onChanged: (v) => _setIntField('nextEvtId', v),
                ),
              ] else ...[
                _label('说话人 roleName'),
                fluent.TextBox(
                  controller: _makeCtl(_selKey('roleName'), cln(rec['roleName'])),
                  onChanged: (v) => _setField('roleName', v),
                ),
                const SizedBox(height: 10),
                _label('台词 content'),
                fluent.TextBox(
                  controller: _makeCtl(_selKey('content'), cln(rec['content'])),
                  maxLines: 4,
                  onChanged: (v) => _setField('content', v),
                ),
                const SizedBox(height: 10),
                _label('检定 check（JSON 二维数组，如 [[80301,1]]）'),
                fluent.TextBox(
                  controller: _makeCtl(_selKey('check'), jsonEncode(rec['check'] ?? [])),
                  maxLines: 3,
                  onChanged: _setCheckField,
                ),
                if (_checkError)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text('JSON 解析失败，未生效',
                        style: TextStyle(fontSize: 11, color: const Color(0xFFE74C3C))),
                  ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: _label('背景 bg'),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _label('音频 audio'),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _label('时间 time'),
                    ),
                  ],
                ),
                Row(
                  children: [
                    Expanded(
                      child: fluent.TextBox(
                        controller: _makeCtl(_selKey('bg'), cln(rec['bg'])),
                        onChanged: (v) => _setIntField('bg', v),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: fluent.TextBox(
                        controller: _makeCtl(_selKey('audio'), cln(rec['audio'])),
                        onChanged: (v) => _setIntField('audio', v),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: fluent.TextBox(
                        controller: _makeCtl(_selKey('time'), cln(rec['time'])),
                        onChanged: (v) => _setIntField('time', v),
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 16),
              Text(
                '提示：在画布中拖动画布空白处平移，滚轮缩放；'
                '拖节点底部端口连线，点选连线后按 Delete 删除。',
                style: TextStyle(fontSize: 11, color: palette.textHint, height: 1.6),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _label(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Text(text, style: TextStyle(fontSize: 11, color: palette.textSecondary)),
      );

  /// 列表型字段输入框在节点切换时会残留旧文本，重新对齐（talkId 用）。
  void _syncListCtl(String field, Map<String, dynamic> rec) {
    final c = _ctls[_selKey(field)];
    if (c != null && c.text.isNotEmpty) {
      // 规范化显示（已在 onChanged 写入 record，此处仅校正显示文本）
      final norm = normalizeStoryIdList(rec[field]).join(', ');
      if (c.text != norm) c.text = norm;
    }
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