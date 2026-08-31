/// 剧情流程图：节点连线编辑画布的数据模型与纯函数。
///
/// 数据语义与游戏配置一致（见 story_logic.dart）：
/// - 对白节点 = TalkCfg 记录，输出端口映射 nextTalk / nextTalk2 / option；
/// - 选项节点 = OptionCfg 记录，输出端口映射 talkId / talkId2 / nextEvtId；
/// - 边 = 源节点字段数组里的一个目标 id，连线操作即增删该数组元素。
library;

import 'dart:ui' show Offset;

import 'story_flow_node_presets.dart';
import 'story_logic.dart';

/// 节点类型。
enum FlowNodeKind { talk, option, missing }

/// 边类型（决定线型与写回字段）。
enum FlowEdgeKind {
  /// 对白线性后续（nextTalk；无检定双支时）。
  next,

  /// 检定成功支（nextTalk，check 非空且 nextTalk2 非空时）。
  checkPass,

  /// 检定失败支（nextTalk2）。
  checkFail,

  /// 对白 → 选项（talk.option）。
  option,

  /// 选项主支 → 对白（option.talkId）。
  optionMain,

  /// 选项支线 → 对白（option.talkId2）。
  optionSide,

  /// 选项跳转事件（option.nextEvtId，终端边，不可编辑）。
  nextEvt,
}

/// 边类型对应的写回字段；nextEvt 为终端边（无字段）。
String? fieldForEdge(FlowEdgeKind kind) {
  switch (kind) {
    case FlowEdgeKind.next:
    case FlowEdgeKind.checkPass:
      return 'nextTalk';
    case FlowEdgeKind.checkFail:
      return 'nextTalk2';
    case FlowEdgeKind.option:
      return 'option';
    case FlowEdgeKind.optionMain:
      return 'talkId';
    case FlowEdgeKind.optionSide:
      return 'talkId2';
    case FlowEdgeKind.nextEvt:
      return null;
  }
}

/// 节点底部输出端口类型（交互命中与连线绘制共用，顺序即从左到右）。
///
/// 对白节点恒含「选项」端口（尚无选项节点时拖线会被校验拦截并提示）；
/// 有检定数据（check 非空）即成对给出 成功/失败 端口，失败支可暂空待连线。
List<FlowEdgeKind> flowPortKinds(FlowNode n) {
  if (n.isMissing) return const [];
  if (n.isOption) {
    return const [FlowEdgeKind.optionMain, FlowEdgeKind.optionSide];
  }
  return [
    if (n.hasCheck)
      ...[FlowEdgeKind.checkPass, FlowEdgeKind.checkFail]
    else
      FlowEdgeKind.next,
    FlowEdgeKind.option,
  ];
}

class FlowNode {
  const FlowNode({
    required this.kind,
    required this.id,
    this.roleName = '',
    this.content = '',
    this.hasCheck = false,
    this.isNarrator = false,
    this.cardKey = '',
    this.cardLabel = '',
    this.cardColor = '',
    this.bgId = '',
    this.audioId = '',
    this.timeStr = '',
    this.mainCount = '',
    this.sideCount = '',
    this.nextEvtId = '',
    this.fxSummary = '',
  });

  final FlowNodeKind kind;
  final String id;
  final String roleName;
  final String content;

  /// 检定节点（check 非空）：输出恒为 成功/失败 双端口，失败支可暂空待连线。
  final bool hasCheck;
  final bool isNarrator;

  /// 插件流程卡片标注（空=未命中任何卡型）。
  final String cardKey;
  final String cardLabel;
  final String cardColor; // #RRGGBB

  /// 卡片参数摘要（空=未设置）：对白 bg/audio/time，选项 主支/支线数与跳转事件。
  final String bgId;
  final String audioId;
  final String timeStr;
  final String mainCount;
  final String sideCount;
  final String nextEvtId;

  /// 屏幕效果摘要（对白）：如「播CG·12」「黑屏」「模糊+黑屏」，取自 screenEffect。
  final String fxSummary;

  /// 缺失/跨事件引用目标（终端徽标，不可编辑）。
  bool get isMissing => kind == FlowNodeKind.missing;
  bool get isOption => kind == FlowNodeKind.option;

  /// 卡片是否有可展示的参数徽章。
  bool get hasParamBadges {
    if (isMissing) return false;
    if (isOption) {
      return mainCount.isNotEmpty ||
          sideCount.isNotEmpty ||
          nextEvtId.isNotEmpty;
    }
    return bgId.isNotEmpty ||
        audioId.isNotEmpty ||
        timeStr.isNotEmpty ||
        fxSummary.isNotEmpty;
  }

  FlowNode copyWith({
    String? cardKey,
    String? cardLabel,
    String? cardColor,
  }) {
    return FlowNode(
      kind: kind,
      id: id,
      roleName: roleName,
      content: content,
      hasCheck: hasCheck,
      isNarrator: isNarrator,
      cardKey: cardKey ?? this.cardKey,
      cardLabel: cardLabel ?? this.cardLabel,
      cardColor: cardColor ?? this.cardColor,
      bgId: bgId,
      audioId: audioId,
      timeStr: timeStr,
      mainCount: mainCount,
      sideCount: sideCount,
      nextEvtId: nextEvtId,
      fxSummary: fxSummary,
    );
  }

  /// 卡片标题：对白=说话人，选项=选项 N，缺失=引用目标描述。
  String get title {
    switch (kind) {
      case FlowNodeKind.talk:
        return isNarrator ? '旁白' : (roleName.isEmpty ? '对白' : roleName);
      case FlowNodeKind.option:
        return '选项 $id';
      case FlowNodeKind.missing:
        return content;
    }
  }
}

class FlowEdge {
  const FlowEdge({
    required this.from,
    required this.to,
    required this.kind,
    this.optionId,
  });

  final String from;
  final String to;
  final FlowEdgeKind kind;

  /// 选项边（talk.option）对应的选项节点 id（联动选中用）。
  final String? optionId;

  @override
  bool operator ==(Object other) =>
      other is FlowEdge &&
      other.from == from &&
      other.to == to &&
      other.kind == kind;
  @override
  int get hashCode => Object.hash(from, to, kind);
}

class FlowGraph {
  const FlowGraph({required this.nodes, required this.edges, required this.starts});
  final List<FlowNode> nodes;
  final List<FlowEdge> edges;

  /// 事件首句对白 id（跨事件截断/布局起点）。
  final List<String> starts;

  FlowNode? nodeById(String id) {
    for (final n in nodes) {
      if (n.id == id) return n;
    }
    return null;
  }

  List<FlowEdge> edgesFrom(String id) =>
      edges.where((e) => e.from == id && e.kind != FlowEdgeKind.nextEvt).toList();
}

/// 由当前事件的舞台副本构建流程图。
///
/// [evtTitles] 事件 id → 标题，用于跨事件终端边显示。
/// [cardStyles] 插件流程卡片声明（GET /api/plugins/ui/flow_cards），按
/// match 规则给节点标注卡型（颜色/名称随后端插件定义渲染）。
FlowGraph buildFlowGraph({
  required Map<String, dynamic> talks,
  required Map<String, dynamic> options,
  required List<String> prefixes,
  Map<String, String> evtTitles = const {},
  List<String>? starts,
  List<Map<String, dynamic>> cardStyles = const [],
}) {
  final nodes = <String, FlowNode>{};

  /// 卡型 match 命中即返回带卡片标注的节点副本。
  FlowNode applyCardStyle(FlowNode n, dynamic rec, String appliesTo) {
    for (final s in cardStyles) {
      if (s['applies_to'] != appliesTo) continue;
      final m = s['match'];
      if (m is! Map) continue;
      final field = cln(m['field']);
      if (field.isEmpty) continue;
      if (!_cardMatch(rec, m)) continue;
      return n.copyWith(
        cardKey: cln(s['type_id']),
        cardLabel: cln(s['name']),
        cardColor: cln(s['color']),
      );
    }
    return n;
  }

  void ensureOption(String id) {
    if (nodes.containsKey(id)) return;
    // 引用到不存在（或本体兜底）的选项：终端缺失节点
    nodes[id] = FlowNode(
      kind: FlowNodeKind.missing,
      id: id,
      content: '缺失选项 $id（未定义于当前事件）',
    );
  }

  void ensureTalkTarget(String id) {
    if (nodes.containsKey(id)) return;
    final eid = _eventOf(id);
    final title = evtTitles[eid];
    nodes[id] = FlowNode(
      kind: FlowNodeKind.missing,
      id: id,
      content: title == null || title.isEmpty
          ? '跳出到事件 $eid'
          : '跳出到事件 $eid（$title）',
    );
  }

  talks.forEach((key, value) {
    if (value is! Map) return;
    if (!storyIsInPrefixes(prefixes, key)) return;
    final talk = value;
    final role = cln(talk['roleName']);
    final check = talk['check'];
    nodes[key] = applyCardStyle(FlowNode(
      kind: FlowNodeKind.talk,
      id: key,
      roleName: role,
      content: cln(talk['content']),
      hasCheck: check is List && check.isNotEmpty,
      isNarrator: role == '旁白',
      bgId: _numText(talk['bg']),
      audioId: _numText(talk['audio']),
      timeStr: _numText(talk['time']),
      fxSummary: _fxSummaryOf(talk['screenEffect']),
    ), talk, 'talk');
  });
  options.forEach((key, value) {
    if (value is! Map) return;
    if (!storyIsInPrefixes(prefixes, key, isOption: true)) return;
    nodes[key] = applyCardStyle(FlowNode(
      kind: FlowNodeKind.option,
      id: key,
      roleName: '',
      content: cln(value['content']),
      mainCount: _numText(normalizeStoryIdList(value['talkId']).length),
      sideCount: _numText(normalizeStoryIdList(value['talkId2']).length),
      nextEvtId: _numText(value['nextEvtId']),
    ), value, 'option');
  });

  final edges = <FlowEdge>[];

  talks.forEach((key, value) {
    if (!nodes.containsKey(key) || value is! Map) return;
    final talk = value as Map<String, dynamic>;
    final next2 = normalizeStoryIdList(talk['nextTalk2']);
    // 有检定数据即双支：nextTalk=成功支（checkPass），nextTalk2（可暂空）=失败支
    final dual = nodes[key]!.hasCheck;
    for (final t in normalizeStoryIdList(talk['nextTalk'])) {
      final to = cln(t);
    if (to.isEmpty) continue;
      if (!nodes.containsKey(to)) ensureTalkTarget(to);
      edges.add(FlowEdge(
        from: key,
        to: to,
        kind: dual ? FlowEdgeKind.checkPass : FlowEdgeKind.next,
      ));
    }
    for (final t in next2) {
      final to = cln(t);
      if (to.isEmpty) continue;
      if (!nodes.containsKey(to)) ensureTalkTarget(to);
      edges.add(FlowEdge(from: key, to: to, kind: FlowEdgeKind.checkFail));
    }
    for (final o in normalizeStoryIdList(talk['option'])) {
      final oid = cln(o);
      if (oid.isEmpty) continue;
      if (!nodes.containsKey(oid)) ensureOption(oid);
      edges.add(FlowEdge(from: key, to: oid, kind: FlowEdgeKind.option, optionId: oid));
    }
  });

  options.forEach((key, value) {
    if (!nodes.containsKey(key) || value is! Map) return;
    final opt = value as Map<String, dynamic>;
    for (final t in normalizeStoryIdList(opt['talkId'])) {
      final to = cln(t);
      if (to.isEmpty) continue;
      if (!nodes.containsKey(to)) ensureTalkTarget(to);
      edges.add(FlowEdge(from: key, to: to, kind: FlowEdgeKind.optionMain));
    }
    for (final t in normalizeStoryIdList(opt['talkId2'])) {
      final to = cln(t);
      if (to.isEmpty) continue;
      if (!nodes.containsKey(to)) ensureTalkTarget(to);
      edges.add(FlowEdge(from: key, to: to, kind: FlowEdgeKind.optionSide));
    }
    final ne = opt['nextEvtId'];
    if (ne != null && ne != 0 && cln(ne).isNotEmpty && ne.toString() != '0') {
      final to = cln(ne);
      if (!nodes.containsKey(to)) ensureTalkTarget(to);
      edges.add(FlowEdge(from: key, to: to, kind: FlowEdgeKind.nextEvt));
    }
  });

  return FlowGraph(
    nodes: nodes.values.toList(),
    edges: edges,
    starts: starts ?? storyStartIds('', const {}, talks),
  );
}

String _eventOf(String id) {
  final s = cln(id);
  if (s.length > 3) return s.substring(0, s.length - 3);
  return s;
}

/// 参数摘要数值文本：0/空视为未设置返回空串，浮点归一去掉 `.0`。
String _numText(dynamic v) {
  if (v == null) return '';
  if (v is num) return v == 0 ? '' : cln(v);
  final s = cln(v);
  if (s.isEmpty || s == '0' || s == '0.0') return '';
  return s;
}

/// 卡型 match 谓词（match map 三种形态）：
/// - {field, equals}：字段值（或其数组元素）与 equals 做 cln 归一比较——
///   插件卡协议（register_flow_card），保持不变；
/// - {field, code|codes}：指令码字段任一命中（screenEffect 行首值等），
///   供内置预设匹配「播放CG/转场」这类带参数的数组指令；
/// - {field, nonEmpty:true}：字段有实义值（非 0/非空/数组含实义元素）。
bool _cardMatch(dynamic rec, Map m) {
  final field = cln(m['field']);
  if (field.isEmpty || rec is! Map) return false;
  final val = rec[field];
  if (m['nonEmpty'] == true) return _hasValue(val);
  if (val == null) return false;
  if (m.containsKey('code') || m.containsKey('codes')) {
    final codes = <int>{};
    for (final c in <dynamic>[
      m['code'],
      ...((m['codes'] as List?) ?? const []),
    ]) {
      final iv = c is num ? c.toInt() : int.tryParse(cln(c));
      if (iv != null) codes.add(iv);
    }
    for (final row in _fxRows(val)) {
      if (row.isEmpty) continue;
      final head = row.first is num
          ? (row.first as num).toInt()
          : int.tryParse(cln(row.first));
      if (head != null && codes.contains(head)) return true;
    }
    return false;
  }
  if (!m.containsKey('equals')) return false;
  final eq = m['equals'];
  if (cln(val) == cln(eq)) return true;
  if (val is List) {
    for (final x in val) {
      if (cln(x) == cln(eq)) return true;
    }
  }
  return false;
}

/// 值是否有实义：null/0/空串/仅含空元素的数组视为无。
bool _hasValue(dynamic v) {
  if (v == null) return false;
  if (v is num) return v != 0;
  if (v is bool) return v;
  if (v is String) return cln(v).isNotEmpty;
  if (v is List) return v.any(_hasValue);
  return true;
}

/// 指令数组归一成行列表：2D（[[4015,id]]）逐行；纯标量数组（[4015,id]）
/// 视作单行；混合形态下标量元素各自成行。
List<List<dynamic>> _fxRows(dynamic val) {
  if (val is! List || val.isEmpty) return const [];
  final hasRow = val.any((x) => x is List);
  if (!hasRow) return [val];
  return [
    for (final x in val)
      if (x is List) x,
  ];
}

/// screenEffect → 节点参数摘要：如「CG·12」「黑屏」「闪白+抖动」；
/// 播 CG 未选目标（id=0）显示「CG·未选」。未知码跳过。
String _fxSummaryOf(dynamic screenEffect) {
  final parts = <String>[];
  for (final row in _fxRows(screenEffect)) {
    if (row.isEmpty) continue;
    final code = row.first is num
        ? (row.first as num).toInt()
        : int.tryParse(cln(row.first));
    if (code == null) continue;
    if (code == kFxPlayCg) {
      final id = row.length > 1 ? cln(row[1]) : '';
      parts.add(id.isEmpty || id == '0' ? 'CG·未选' : 'CG·$id');
    } else {
      final name = kScreenEffectNames[code];
      if (name != null) parts.add(name);
    }
  }
  return parts.join('+');
}

/// 分层 DAG 自动布局：从事件起点 BFS 定深度（列），同列按到达顺序定行。
/// 返回 节点 id → 画布坐标。不可达节点排在最后。
Map<String, Offset> layoutFlow({
  required FlowGraph graph,
  List<String>? starts,
  double colW = 250,
  double rowH = 130,
  double startX = 40,
  double startY = 40,
}) {
  final ids = graph.nodes.map((n) => n.id).toSet();
  final layer = <String, int>{};
  final order = <String>[];
  final queue = <String>[
    for (final s in (starts ?? graph.starts))
      if (ids.contains(s)) s,
  ];
  for (final s in queue) {
    layer[s] = 0;
    order.add(s);
  }
  var qi = 0;
  while (qi < queue.length) {
    final id = queue[qi++];
    final l = layer[id]!;
    for (final e in graph.edgesFrom(id)) {
      if (e.kind == FlowEdgeKind.nextEvt) continue;
      if (layer.containsKey(e.to)) continue;
      layer[e.to] = l + 1;
      order.add(e.to);
      queue.add(e.to);
    }
  }
  for (final n in graph.nodes) {
    if (!layer.containsKey(n.id)) {
      layer[n.id] = (layer.isEmpty ? 0 : (layer.values.reduce((a, b) => a > b ? a : b) + 1));
      order.add(n.id);
    }
  }
  final out = <String, Offset>{};
  final colIndex = <int, int>{};
  for (final id in order) {
    final l = layer[id] ?? 0;
    final idx = colIndex[l] ?? 0;
    colIndex[l] = idx + 1;
    out[id] = Offset(startX + l * colW, startY + idx * rowH);
  }
  return out;
}

/// 连边：把目标 id 追加进源节点字段数组（去重、数字归一）。
void pushEdgeTarget(Map<String, dynamic> record, String field, dynamic targetId) {
  final list = normalizeStoryIdList(record[field]);
  final t = int.tryParse(cln(targetId)) ?? cln(targetId);
  if (list.any((e) => cln(e) == cln(t))) return;
  record[field] = [...list, t];
}

/// 断边：从源节点字段数组移除目标 id。
void removeEdgeTarget(Map<String, dynamic> record, String field, dynamic targetId) {
  final t = cln(targetId);
  record[field] =
      normalizeStoryIdList(record[field]).where((e) => cln(e) != t).toList();
}