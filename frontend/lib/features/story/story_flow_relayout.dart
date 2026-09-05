/// 阶段 7「局部重排」：只理齐**选中的那一坨**节点，选区外一个坐标都不碰。
///
/// 为什么不直接调 [layoutFlow]：全图自动布局会为图里**每个**节点返回坐标，宿主
/// 一次 `addAll` 就把用户手摆的整张画布冲掉——这正是本功能存在的理由（手摆的
/// 位置是劳动成果，不是待整理的首屏）。本文件把 [layoutFlow] 的网格算法留作
/// 唯一的排布口径（列宽/行距/分层规则与全图布局逐像素一致，两种布局不会打架），
/// 只在它外面套三层：
///
/// 1. **诱导子图**：节点 = selected ∩ graph.nodes，边 = 两端都被选中的边。选中
///    节点的未选中子节点压根不进图，所以「拖一个带全族」不会发生；反向也成立。
/// 2. **起点集合**：选中集内入度为 0 的节点是根，按当前 y 从上到下进第 0 列。
///    纯环里没有入度为 0 的节点，于是按同一把排序键补一个确定性的破环点，
///    保证 [layoutFlow] 末尾那条「不可达节点各自占一列」的兜底分支永不触发——
///    它既 O(N²)（每个不可达节点都 `reduce` 一遍全 layer），又会把选中块横向
///    拉成一条看不到头的长带，等于把「局部」二字当场违约。
/// 3. **锚点**：[layoutFlow] 的产物左上角落在它自己的 (startX, startY)，这里
///    整体平移到选中块**当前**包围盒的左上角——原地理齐，不瞬移到 (40, 40)。
///
/// 纯函数：只读 [graph] 与 [positions]，不改它们，也不改调用方传入的 `selected`。
/// 代价 O((N+E) + N log N)（N/E = 选中节点数/选中内部边数，N log N 花在排序键上），
/// 手势级调用（最多几百个选中节点）完全够用；文件内没有任何 O(N²) 的环节。
library;

import 'dart:ui' show Offset;

import 'story_flow_models.dart';

/// 只重排选中的子图：返回 节点 id → 新世界坐标，且**只包含选中集里的节点**。
///
/// 结果契约（宿主可直接 `addAll` 进 `_positions`，无需过滤）：
/// - key 集合 == selected ∩ graph.nodes：**恰好全覆盖、零外溢**。孤立被选中的
///   节点（与选区内任何节点都不相连）也一定有坐标——它按当前 y 落进第 0 列，
///   绝不从结果里静默消失；
/// - 只出现在 `selected` 里但图上没有这个节点的 id（记录已删/脏选中）不进结果；
/// - 每个 value 都是新算出的 [Offset]，不与 [positions] 共享可变对象。
Map<String, Offset> relayoutSelection({
  required FlowGraph graph,
  required Map<String, Offset> positions,
  required Set<String> selected,
  double colW = 250,
  double rowH = 130,
}) {
  if (selected.isEmpty) return const <String, Offset>{};

  // ---------- 1) 诱导子图 ----------
  // 按 graph.nodes 的既有顺序取选中 id：Set 的迭代序是插入序，宿主框选/Shift
  // 点选的先后不该影响布局结果，所以一切顺序都以 nodes 顺序 + 显式排序键为准。
  final byId = <String, FlowNode>{for (final n in graph.nodes) n.id: n};
  final picked = <String>{
    for (final n in graph.nodes)
      if (selected.contains(n.id)) n.id,
  };
  if (picked.isEmpty) return const <String, Offset>{};

  // 出边表 + 入度：与 FlowGraph.edgesFrom 同口径跳过 nextEvt（终端边不参与本
  // 事件内的出边遍历，让它算入度会把目标节点白白压深一列）。
  final adj = <String, List<String>>{};
  final indeg = <String, int>{for (final id in picked) id: 0};
  final subEdges = <FlowEdge>[];
  for (final e in graph.edges) {
    if (e.kind == FlowEdgeKind.nextEvt) continue;
    if (!picked.contains(e.from) || !picked.contains(e.to)) continue;
    subEdges.add(e);
    (adj[e.from] ??= <String>[]).add(e.to);
    indeg[e.to] = indeg[e.to]! + 1;
  }

  // ---------- 2) 起点集合（根按当前 y；环补破环点） ----------
  final order = picked.toList()..sort((a, b) => _cmpPlaced(positions, a, b));

  final starts = <String>[];
  final visited = <String>{};
  final queue = <String>[];
  for (final id in order) {
    if (indeg[id] != 0) continue;
    visited.add(id);
    starts.add(id);
    queue.add(id);
  }
  // 一次遍历同时完成「可达性检查」与「破环点补齐」：cursor 只朝一个方向走，
  // 且节点一旦 visited 永不回退，所以补点循环整体是 O(N)，不是 O(N²)。
  var cursor = 0;
  var qi = 0;
  while (true) {
    while (qi < queue.length) {
      final id = queue[qi++];
      for (final to in adj[id] ?? const <String>[]) {
        if (visited.add(to)) queue.add(to);
      }
    }
    while (cursor < order.length && visited.contains(order[cursor])) {
      cursor++;
    }
    if (cursor >= order.length) break;
    final breaker = order[cursor++]; // 剩下的是环（或环的下游），取最靠上的入口
    visited.add(breaker);
    starts.add(breaker);
    queue.add(breaker);
  }
  assert(visited.length == order.length, '起点集合必须覆盖全部选中节点');

  // ---------- 3) 交给 layoutFlow 排网格，再平移回原位 ----------
  final sub = FlowGraph(
    nodes: [for (final id in picked) byId[id]!],
    edges: subEdges,
    starts: starts,
  );
  // 不传 startX/startY：锚点靠下面按包围盒平移求得，与 layoutFlow 的原点取值无关。
  final raw = layoutFlow(graph: sub, starts: starts, colW: colW, rowH: rowH);

  final grid = _minBox(raw, picked);
  final anchor = _minBox(positions, picked);
  // 选中节点一个坐标都没有（首次进图/布局文件缺项）：没有「当前左上角」可锚，
  // 就原地用 layoutFlow 的自然原点，行为与全图自动布局一致。
  final shiftX = (anchor != null && grid != null) ? anchor.dx - grid.dx : 0.0;
  final shiftY = (anchor != null && grid != null) ? anchor.dy - grid.dy : 0.0;

  final out = <String, Offset>{};
  for (final id in picked) {
    final p = raw[id];
    // raw 缺项在正常路径下不会发生（起点集合已保证覆盖），兜底给个确定的
    // 堆叠位，宁可挤在第 0 列也不让节点从结果里消失。
    out[id] = p == null
        ? Offset(shiftX, shiftY + out.length * rowH)
        : Offset(p.dx + shiftX, p.dy + shiftY);
  }
  return out;
}

/// 一批 id 在 [src] 里的包围盒左上角；一个都没有坐标时返回 null。
/// 缺项的 id 直接跳过（图上选中但位置未存的节点不该把包围盒拽到 (0,0)）。
Offset? _minBox(Map<String, Offset> src, Iterable<String> ids) {
  double? x;
  double? y;
  for (final id in ids) {
    final p = src[id];
    if (p == null) continue;
    if (x == null || p.dx < x) x = p.dx;
    if (y == null || p.dy < y) y = p.dy;
  }
  return x == null || y == null ? null : Offset(x, y);
}

/// 布局顺序比较键：当前 y → 当前 x → id。
///
/// 缺坐标的节点排在最后（当作 `+infinity`）——已经摆好的节点先占位，孤儿接着
/// 往下堆；三级键全等时才依赖 id，保证「同输入必同输出」，不受 Set 插入序影响。
/// NaN 一类的脏坐标不参与判等，只做全序比较，不抛异常。
int _cmpPlaced(Map<String, Offset> positions, String a, String b) {
  final pa = positions[a];
  final pb = positions[b];
  final ay = pa?.dy ?? double.infinity;
  final by = pb?.dy ?? double.infinity;
  if (ay != by) return ay.compareTo(by);
  final ax = pa?.dx ?? double.infinity;
  final bx = pb?.dx ?? double.infinity;
  if (ax != bx) return ax.compareTo(bx);
  return a.compareTo(b);
}
