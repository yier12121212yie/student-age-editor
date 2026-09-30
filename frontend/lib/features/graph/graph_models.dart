/// 可视化分析视图（人物关系图 / 事件时间轴）的数据模型与纯函数。
///
/// 设计约束（与后端锁定的契约逐字段对齐，不得改名）：
/// - [parseRelations] 吃 GET /api/graph/relations 的信封；
/// - [parseTimeline] 吃 GET /api/graph/timeline 的信封。
/// 解析层与绘制层解耦：所有「坐标 / 泳道 / 过滤 / 分色」都是这里的**纯函数**，
/// 由 test/graph_models_test.dart 钉死，widget 层只负责把它们画到画布上。
///
/// 取色一律走 [palette]（当前生效调色板），不写死 `Color(0x…)`；
/// 非法色值一律回退到 [AppPalette.tintInfo]。
library;

import 'dart:math' as math;

import 'package:flutter/painting.dart' show Color, HSLColor, Offset, Rect, Size;

import '../../core/app_theme.dart';

// ======================= 画布视口（纯数据） =======================

/// 自绘画布视口：世界 → 屏幕 = pan + scale·world。
///
/// 语义与 story_flow_graph 的 FlowViewport 一致（只读借鉴其手写手势方案，
/// 不 import 该文件），这里独立一份让 graph 功能包保持零画布依赖、可单测。
class GraphViewport {
  const GraphViewport(this.scale, this.pan);

  final double scale;
  final Offset pan;

  static const double minScale = 0.2;
  static const double maxScale = 2.5;

  Offset toWorld(Offset screen) => (screen - pan) / scale;

  Offset toScreen(Offset world) => world * scale + pan;

  /// 以屏幕点 [anchorScreen] 为不动点缩放到 [nextScale]。
  GraphViewport withZoom(double nextScale, Offset anchorScreen) =>
      GraphViewport(nextScale, anchorScreen - toWorld(anchorScreen) * nextScale);

  /// 可见世界矩形（供裁剪与「适配视图」包围盒兜底）。
  Rect worldRect(Size view) => Rect.fromLTWH(
        -pan.dx / scale,
        -pan.dy / scale,
        view.width / scale,
        view.height / scale,
      );

  @override
  bool operator ==(Object other) =>
      other is GraphViewport && other.scale == scale && other.pan == pan;

  @override
  int get hashCode => Object.hash(scale, pan);
}

// ======================= 通用解析小工具 =======================

/// 安全地把任意 JSON 值读成字符串（缺失 / null → 空串）。
String asStr(Object? v) => v?.toString() ?? '';

/// 安全地把任意 JSON 值读成 int（非数值 → null）。契约里 id 是字符串，
/// 但 year/season/value 等是数值，统一走这里避免 `as int` 直接崩。
int? asInt(Object? v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v);
  return null;
}

/// 把 JSON 里的 `List` 安全转成 `List<Map>`（元素非 Map 的跳过）。
List<Map> asMapList(Object? v) =>
    v is List ? v.whereType<Map>().toList() : const [];

/// 把 JSON 里的 `List` 安全转成 `List<String>`（null 元素跳过）。
List<String> asStrList(Object? v) => v is List
    ? [for (final e in v) if (e != null) e.toString()]
    : const [];

/// `#RRGGBB` / `RRGGBB`（大小写不限）→ [Color]；非法或空 → [palette.tintInfo]。
///
/// 关系等级 color 字段是后端直接透出的字符串，可能畸形（缺位、含空格、
/// 写成 `rgb(...)`），这里只认六位十六进制，其余一律回退，保证画布不崩。
Color parseHexColor(Object? raw) {
  var s = asStr(raw).trim();
  if (s.startsWith('#')) s = s.substring(1);
  if (s.length != 6) return palette.tintInfo;
  final v = int.tryParse(s, radix: 16);
  return v == null ? palette.tintInfo : Color(0xFF000000 | v);
}

/// 按 HSL 明度提亮（徽标描边一类）：lightness + dl，钳到 1.0。
Color lightenColor(Color c, [double dl = 0.12]) {
  final h = HSLColor.fromColor(c);
  return h.withLightness(math.min(1.0, h.lightness + dl)).toColor();
}

/// 解析剧情 code 串（形如 `[20, 1, 101, 10]` / `[7,-1,...]`）成整数数组。
/// 非数字 token 跳过；解析失败返回空表。negate 语义由调用方按元素自行判读。
List<int> parseCodeList(Object? raw) {
  final s = asStr(raw);
  final body = s.replaceAll('[', '').replaceAll(']', '');
  if (body.trim().isEmpty) return const [];
  return [
    for (final t in body.split(','))
      if (int.tryParse(t.trim()) != null) int.parse(t.trim()),
  ];
}

// ======================= 关系：kind 词表 / 取色 =======================

/// 关系记录的九种 kind（契约固定，展示顺序即此表顺序）。
const List<String> kRelationKinds = [
  'favorGain',
  'favorLoss',
  'favorCond',
  'relationSet',
  'relationCond',
  'lover',
  'interact',
  'friendRequest',
  'loveScene',
];

/// kind → 中文徽章前缀（好感+10 之类由 value 追加）。
const Map<String, String> kRelationKindLabels = {
  'favorGain': '好感',
  'favorLoss': '好感',
  'favorCond': '条件:好感',
  'relationSet': '设为关系',
  'relationCond': '条件:关系',
  'lover': '成为恋人',
  'interact': '互动',
  'friendRequest': '送花请求',
  'loveScene': '约会场景',
};

/// kind → 徽章底色（取自 palette token，随外观切换）。
Color relationKindColor(String kind) {
  switch (kind) {
    case 'favorGain':
      return palette.statusOk;
    case 'favorLoss':
      return palette.statusDanger;
    case 'favorCond':
      return palette.statusWarn;
    case 'relationSet':
      return palette.flowBg;
    case 'relationCond':
      return palette.statusInfo;
    case 'lover':
      return palette.danger;
    case 'interact':
      return palette.flowAudio;
    case 'friendRequest':
      return palette.flowCheck;
    case 'loveScene':
      return palette.flowFx;
    default:
      return palette.tintInfo;
  }
}

/// 一条边的展示徽章文本：kind 词 + 可选数值（好感类带 ±value）。
String relationBadgeLabel(RelationEdge e) {
  final base = kRelationKindLabels[e.kind] ?? e.kind;
  if (e.kind == 'favorGain' || e.kind == 'favorLoss') {
    final sign = e.kind == 'favorGain' ? '+' : '-';
    return '$base$sign${e.value}';
  }
  if (e.kind == 'relationSet' || e.kind == 'relationCond') {
    final lvl = e.relationLevelName;
    return lvl == null || lvl.isEmpty ? base : '$base:$lvl';
  }
  return base;
}

// ======================= 关系图数据模型 =======================

/// 人物节点（契约 nodes）。
class RelationNode {
  RelationNode({
    required this.id,
    required this.name,
    this.gender,
    this.tex,
  });

  final String id;
  final String name;
  final int? gender;

  /// 立绘 key（可空）；非空时走 [TexThumb] 渲染缩略图。
  final String? tex;

  factory RelationNode.fromJson(Map j) => RelationNode(
        id: asStr(j['id']),
        name: asStr(j['name']),
        gender: asInt(j['gender']),
        tex: j['tex'] == null ? null : asStr(j['tex']),
      );
}

/// 关系等级（契约 levels；即 RelationCfg 一行）。
class RelationLevel {
  RelationLevel({
    required this.id,
    required this.name,
    this.color,
    this.condition,
    this.upgrade,
    this.upgradeCost = 0,
    this.socialCapacity = 0,
    this.iconRelation,
  });

  final String id;
  final String name;

  /// 后端原样透出的 `#RRGGBB`；解析交给 [RelationLevel.parseColor]。
  final String? color;

  /// 达到该等级所需好感阈值。
  final int? condition;

  /// 可升级到的下一级 id（null = 顶级）。
  final String? upgrade;
  final int upgradeCost;
  final int socialCapacity;
  final String? iconRelation;

  /// 解析后的等级色；非法 → [palette.tintInfo]。
  Color get parseColor => parseHexColor(color);

  factory RelationLevel.fromJson(Map j) => RelationLevel(
        id: asStr(j['id']),
        name: asStr(j['name']),
        color: j['color'] == null ? null : asStr(j['color']),
        condition: asInt(j['condition']),
        upgrade: j['upgrade'] == null ? null : asStr(j['upgrade']),
        upgradeCost: asInt(j['upgradeCost']) ?? 0,
        socialCapacity: asInt(j['socialCapacity']) ?? 0,
        iconRelation:
            j['iconRelation'] == null ? null : asStr(j['iconRelation']),
      );
}

/// 关系边（契约 edges）。`role` 是该记录归属的人物 id。
class RelationEdge {
  RelationEdge({
    required this.role,
    required this.kind,
    this.value = 0,
    this.relation,
    this.code,
    required this.sourceCfg,
    required this.sourceId,
    required this.sourceName,
    this.relationLevelName,
  });

  final String role;
  final String kind;
  final int value;

  /// 关联的等级 id（relationSet/relationCond 时有值）。
  final String? relation;
  final String? code;
  final String sourceCfg;
  final String sourceId;
  final String sourceName;

  /// 解析期回填的等级名（仅用于徽章文本；由 [parseRelations] 建立 id→name 索引）。
  final String? relationLevelName;

  factory RelationEdge.fromJson(Map j, Map<String, String> levelNames) {
    final rel = j['relation'] == null ? null : asStr(j['relation']);
    return RelationEdge(
      role: asStr(j['role']),
      kind: asStr(j['kind']),
      value: asInt(j['value']) ?? 0,
      relation: rel,
      code: j['code'] == null ? null : asStr(j['code']),
      sourceCfg: asStr(j['sourceCfg']),
      sourceId: asStr(j['sourceId']),
      sourceName: asStr(j['sourceName']),
      relationLevelName: rel == null ? null : levelNames[rel],
    );
  }
}

/// 关系图整份数据。
class RelationsData {
  RelationsData({
    required this.nodes,
    required this.levels,
    required this.edges,
  });

  final List<RelationNode> nodes;
  final List<RelationLevel> levels;
  final List<RelationEdge> edges;

  // Built once and reused: the relation view rebuilds badges every pan frame,
  // and the old getter re-created this map on every access (O(E x N)).
  Map<String, RelationNode>? _byId;
  Map<String, RelationNode> get nodeById =>
      _byId ??= {for (final n in nodes) n.id: n};

  Set<String>? _ids;
  Set<String> get nodeIds => _ids ??= {for (final n in nodes) n.id};

  /// 按 condition 升序排列的等级（阶梯图用；condition 缺失排最后）。
  List<RelationLevel> get levelsSortedByCondition => [
        ...levels,
      ]..sort((a, b) {
          final ac = a.condition ?? 1 << 30;
          final bc = b.condition ?? 1 << 30;
          return ac == bc ? a.id.compareTo(b.id) : ac.compareTo(bc);
        });
}

/// 解析 /api/graph/relations 信封。缺失字段一律降级为空集合，不抛。
RelationsData parseRelations(Map json) {
  final levels = [for (final m in asMapList(json['levels']))
    RelationLevel.fromJson(m)];
  final levelNames = {for (final l in levels) l.id: l.name};
  return RelationsData(
    nodes: [for (final m in asMapList(json['nodes'])) RelationNode.fromJson(m)],
    levels: levels,
    edges: [
      for (final m in asMapList(json['edges']))
        RelationEdge.fromJson(m, levelNames),
    ],
  );
}

// ======================= 关系图：过滤 + 放射布局（纯函数） =======================

/// 与所选人「相连」的边（契约边爆炸对策，双向匹配）：role 就是所选人，
/// 或 code 整数里出现所选人 id（另一端被编码进 code 的记录）。
List<RelationEdge> edgesConnectedTo(List<RelationEdge> edges, String focusId) {
  final fid = int.tryParse(focusId);
  return [
    for (final e in edges)
      if (e.role == focusId ||
          (fid != null && parseCodeList(e.code).contains(fid)))
        e,
  ];
}

/// 边的「另一端」人物 id：role 不是所选人时 role 即对方；否则取 code 整数里
/// 第一个出现的已知人物 id（跳过所选人自身）。都找不到返回 null
/// （=纯数值记录，例如对主角的好感变化，不指向具名人物）。
String? counterpartOfEdge(
  RelationEdge e,
  String focusId,
  Set<String> nodeIds,
) {
  if (e.role != focusId && nodeIds.contains(e.role)) return e.role;
  for (final v in parseCodeList(e.code)) {
    final s = '$v';
    if (s != focusId && nodeIds.contains(s)) return s;
  }
  return null;
}

/// 按等级过滤器收敛边：[levelFilter] 为空表示「不过滤」（全部等级）。
/// 只有 relationSet/relationCond 这类带 relation 的边才受等级过滤约束，
/// 纯好感 / 互动类边恒显示。
List<RelationEdge> filterEdgesByLevel(
  List<RelationEdge> edges,
  Set<String> levelFilter,
) {
  if (levelFilter.isEmpty) return edges;
  return [
    for (final e in edges)
      if (e.relation == null || levelFilter.contains(e.relation)) e,
  ];
}

/// 一条边的分组徽标色：带 relation 的边取等级色（[RelationLevel.parseColor]），
/// 否则取 kind 色。等级 id 找不到对应 level 时回退 kind 色。
Color edgeBadgeColor(RelationEdge e, Map<String, RelationLevel> levelsById) {
  final rel = e.relation;
  if (rel != null) {
    final lvl = levelsById[rel];
    if (lvl != null) return lvl.parseColor;
  }
  return relationKindColor(e.kind);
}

/// 放射布局的单个落点：一条边在画布世界坐标里的位置。
class RelationPlacement {
  const RelationPlacement({
    required this.edge,
    required this.index,
    required this.kindGroup,
    required this.center,
    required this.angleRad,
  });

  final RelationEdge edge;

  /// 在过滤后边表里的稳定序号（供 key / 断言）。
  final int index;

  /// 分组键（= kind），同 kind 的边落在同一扇区。
  final String kindGroup;

  /// 世界坐标落点。
  final Offset center;

  /// 相对圆心的弧度（供画连线）。
  final double angleRad;
}

/// 边数超过此阈值时不再逐条铺满整圈，而是按 kind 压缩成组徽标（防炸）。
const int kRelationEdgeCap = 60;

/// 把「与所选人相连」的边按 kind 分扇区、放射状摆放在以 [center] 为圆心、
/// [radius] 为半径的圆上（focus 人居中，本函数只算外围落点）。
///
/// 纯函数、确定性：先按 [kRelationKinds] 的固定顺序分桶，桶内按原始顺序排；
/// 每桶占一份等分弧（无 kind 命中的空桶不占弧），桶内多条边再在该弧内均分。
/// 这样同样输入永远得到同样坐标，便于单测钉死与截图回归。
///
/// [edgeCountCap] 超过时只布局前 N 条（其余由 widget 层折叠成「更多」徽标）。
List<RelationPlacement> layoutEgoGraph({
  required List<RelationEdge> edges,
  Offset center = Offset.zero,
  double radius = 240,
  int edgeCountCap = kRelationEdgeCap,
}) {
  if (edges.isEmpty) return const [];

  // 1) 按 kind 分桶，保持输入相对顺序。
  final buckets = <String, List<RelationEdge>>{};
  final indexIn = <RelationEdge, int>{};
  for (var i = 0; i < edges.length; i++) {
    indexIn[edges[i]] = i;
    buckets.putIfAbsent(edges[i].kind, () => []).add(edges[i]);
  }

  // 2) 扇区顺序：命中 kRelationKinds 的按词表序，未知 kind 追加在后面。
  final orderedKinds = <String>[
    for (final k in kRelationKinds)
      if (buckets.containsKey(k)) k,
    for (final k in buckets.keys)
      if (!kRelationKinds.contains(k)) k,
  ];

  // 3) 每 kind 一份等分弧（整圈 2π，起点 -π/2 即正上方顺时针铺开）。
  final kindCount = orderedKinds.length;
  final arcPerKind = (2 * math.pi) / kindCount;
  const startAngle = -math.pi / 2;

  final placed = <RelationPlacement>[];
  for (var ki = 0; ki < kindCount; ki++) {
    final kind = orderedKinds[ki];
    final group = buckets[kind]!;
    final sectorStart = startAngle + arcPerKind * ki;
    final m = group.length;
    for (var j = 0; j < m; j++) {
      final e = group[j];
      if (placed.length >= edgeCountCap) break;
      // 单条边落在扇区正中；多条在扇区内部 (j+1)/(m+1) 均分。
      final frac = (j + 1) / (m + 1);
      final angle = sectorStart + arcPerKind * frac;
      placed.add(RelationPlacement(
        edge: e,
        index: indexIn[e]!,
        kindGroup: kind,
        center: Offset(
          center.dx + radius * math.cos(angle),
          center.dy + radius * math.sin(angle),
        ),
        angleRad: angle,
      ));
    }
  }
  return placed;
}

// ======================= 时间轴数据模型 =======================

/// 一个回合（契约 rounds）。全年 12 个月按 season 分四段，rounds 1..62。
class TimelineRound {
  TimelineRound({
    required this.round,
    required this.year,
    required this.season,
    required this.seasonName,
    required this.months,
    this.holiday = false,
  });

  final int round;
  final int year;

  /// 季节序号 1..4（春夏秋冬）。
  final int season;
  final String seasonName;
  final List<int> months;
  final bool holiday;

  factory TimelineRound.fromJson(Map j) => TimelineRound(
        round: asInt(j['round']) ?? 0,
        year: asInt(j['year']) ?? 0,
        season: asInt(j['season']) ?? 0,
        seasonName: asStr(j['seasonName']),
        months: [for (final v in (j['months'] is List ? j['months'] as List : const []))
          if (asInt(v) != null) asInt(v)!],
        holiday: j['holiday'] == true,
      );
}

/// 一条时间跨度（契约 items[].spans）。[to] == null 表示「自此以后」。
class TimeRange {
  TimeRange({required this.from, this.to});

  final int from;
  final int? to;

  factory TimeRange.fromJson(Map j) => TimeRange(
        from: asInt(j['from']) ?? 0,
        to: asInt(j['to']),
      );
}

/// 一个可上轴的事件条目（契约 items）。
class TimelineItem {
  TimelineItem({
    required this.cfg,
    required this.id,
    required this.name,
    required this.mapId,
    required this.npc,
    required this.timeKinds,
    required this.spans,
    required this.codes,
  });

  final String cfg;
  final String id;
  final String name;
  final String mapId;
  final String npc;

  /// 时间语义标签集合；含 "special" 的条目单列、不上轴。
  final List<String> timeKinds;
  final List<TimeRange> spans;
  final List<String> codes;

  bool get isSpecial => timeKinds.contains('special');

  /// 覆盖到的回合闭区间 [startRound, endRound]；to==null 时 [endRound] 取 [maxRound]。
  ({int start, int end}) resolvedRange(int maxRound) {
    if (spans.isEmpty) return (start: 0, end: -1);
    var s = spans.first.from;
    var e = spans.first.to ?? maxRound;
    for (final r in spans) {
      if (r.from < s) s = r.from;
      final re = r.to ?? maxRound;
      if (re > e) e = re;
    }
    return (start: s, end: e);
  }

  factory TimelineItem.fromJson(Map j) => TimelineItem(
        cfg: asStr(j['cfg']),
        id: asStr(j['id']),
        name: asStr(j['name']),
        mapId: asStr(j['mapId']),
        npc: asStr(j['npc']),
        timeKinds: asStrList(j['timeKinds']),
        spans: [for (final m in asMapList(j['spans'])) TimeRange.fromJson(m)],
        codes: asStrList(j['codes']),
      );
}

/// 时间轴整份数据。
class TimelineData {
  TimelineData({required this.rounds, required this.items});

  final List<TimelineRound> rounds;
  final List<TimelineItem> items;

  /// 轴上条目（timeKinds 不含 special）。
  List<TimelineItem> get axisItems =>
      [for (final it in items) if (!it.isSpecial && it.spans.isNotEmpty) it];

  /// 单列展示的特殊时间约束条目。
  List<TimelineItem> get specialItems =>
      [for (final it in items) if (it.isSpecial) it];

  /// 最大回合号（rounds 为空回退 62，对应整年跨度上限）。
  int get maxRound => rounds.isEmpty
      ? 62
      : rounds.map((r) => r.round).fold(0, math.max);

  Map<int, TimelineRound> get roundByNumber => {
        for (final r in rounds) r.round: r,
      };
}

/// 解析 /api/graph/timeline 信封。
TimelineData parseTimeline(Map json) => TimelineData(
      rounds: [
        for (final m in asMapList(json['rounds'])) TimelineRound.fromJson(m),
      ],
      items: [
        for (final m in asMapList(json['items'])) TimelineItem.fromJson(m),
      ],
    );

// ======================= 时间轴：过滤 + 泳道（纯函数） =======================

/// 按 npc / mapId 过滤上轴条目。任一维度为 null 表示「该维度不过滤」。
List<TimelineItem> filterTimelineItems(
  List<TimelineItem> items, {
  String? npc,
  String? mapId,
}) =>
    [
      for (final it in items)
        if ((npc == null || it.npc == npc) &&
            (mapId == null || it.mapId == mapId))
          it,
    ];

/// 泳道分配结果：每个条目落在第几行（0 基），以及总行数。
class LaneLayout {
  LaneLayout({required this.laneByIndex, required this.laneCount});

  /// 与输入 items 同序的泳道号数组（laneByIndex[i] 是 items[i] 的行号）。
  final List<int> laneByIndex;
  final int laneCount;
}

/// 经典「区间图贪心着色」：把 [items] 按起始回合排序，逐条放进第一条
/// 「结束回合 < 本条起始」的泳道，没有就新开一泳道。返回原始序的泳道号。
///
/// 确定性：排序键为 (start, end, id)，故同输入同输出；重叠条目必然分行，
/// 由单测钉死「N 条全重叠 → laneCount == N」。to==null 的条目按延伸到
/// [maxRound] 参与判定（画到轴末）。
LaneLayout assignLanes(
  List<TimelineItem> items, {
  required int maxRound,
}) {
  if (items.isEmpty) return LaneLayout(laneByIndex: const [], laneCount: 0);

  final order = [for (var i = 0; i < items.length; i++) i];
  final ranges = {
    for (var i = 0; i < items.length; i++) i: items[i].resolvedRange(maxRound),
  };
  order.sort((a, b) {
    final ra = ranges[a]!, rb = ranges[b]!;
    if (ra.start != rb.start) return ra.start.compareTo(rb.start);
    if (ra.end != rb.end) return ra.end.compareTo(rb.end);
    return items[a].id.compareTo(items[b].id);
  });

  // lanes[k] = 第 k 条泳道当前占用到的结束回合。
  final laneEnd = <int>[];
  final laneByIndex = List<int>.filled(items.length, 0);
  for (final idx in order) {
    final r = ranges[idx]!;
    var lane = -1;
    for (var k = 0; k < laneEnd.length; k++) {
      if (r.start > laneEnd[k]) {
        lane = k;
        break;
      }
    }
    if (lane < 0) {
      lane = laneEnd.length;
      laneEnd.add(r.end);
    } else {
      laneEnd[lane] = r.end;
    }
    laneByIndex[idx] = lane;
  }
  return LaneLayout(laneByIndex: laneByIndex, laneCount: laneEnd.length);
}

/// 季节底色四色（色板派生：春夏秋冬 → 冷→暖→灰循环）。
/// 索引 = (season - 1) % 4；season<=0 时用第一色兜底。
List<Color> seasonPalette() => [
      palette.flowBg, // 春·蓝
      palette.statusOk, // 夏·绿
      palette.flowCheck, // 秋·橙
      palette.flowTime, // 冬·灰
    ];

Color seasonColor(int season) {
  final p = seasonPalette();
  if (season <= 0) return p.first;
  return p[(season - 1) % p.length];
}

/// 一条跨度的中文文案：to==null 画「第 N 回合起」（至轴末），否则「第 a~b 回合」。
String timelineSpanLabel(TimeRange r) =>
    r.to == null ? '第${r.from}回合起' : '第${r.from}~${r.to}回合';

/// 刻度标签密度档位（缩放级别少时只标 year）。
enum TimelineTickMode { year, season, full }

/// 依据「每回合有效屏幕像素」选刻度密度：≥60 全标（round+seasonName）、
/// ≥26 只标季节起点、其余只标年份分界。
TimelineTickMode timelineTickMode(double pxPerRound) {
  if (pxPerRound >= 60) return TimelineTickMode.full;
  if (pxPerRound >= 26) return TimelineTickMode.season;
  return TimelineTickMode.year;
}

/// 时间轴事件按 cfg 类别取色（Evt/Talk/Option/… 各分一色，未知回退 info）。
Color timelineCfgColor(String cfg) {
  switch (cfg) {
    case 'EvtCfg':
      return palette.accentLight;
    case 'TalkCfg':
      return palette.flowBg;
    case 'OptionCfg':
      return palette.flowAudio;
    case 'CGCfg':
      return palette.flowFx;
    case 'BgCfg':
      return palette.statusInfo;
    case 'AudioCfg':
      return palette.statusWarn;
    default:
      return palette.tintInfo;
  }
}
