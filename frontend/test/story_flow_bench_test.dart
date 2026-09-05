/// 剧情图画布性能基准。
///
/// 证据分工：**墙钟时间只报告不断言**（机器相关，断言必 flaky），
/// **重建计数才断言**（确定性，跨机器可比）。时间看改善倍数，计数卡住
/// 「每帧全量重建」这条回归 —— 后者才是阶段 2/4 的准出凭据。
///
/// 跑法：`flutter test test/story_flow_bench_test.dart -r expanded`
/// debug 模式数字远大于 release，跨阶段比较只用本文件自身基线。
///
/// ── 基线与逐阶段回填 ──────────────────────────────────────────
/// 阶段 0 基线（优化前）：
///   A1 stageOf        98,963 行 → 1,000 行 :  55.45 ms（单跑）
///   A2 buildFlowGraph 419 节点 / 418 边     :   5.99 ms（单跑）
///   A3 layoutFlow     419 节点              :   5.66 ms（单跑，噪声见下）
///   B1 平移一帧（200 节点）                  :  78.86 ms
///      nodeCard build / 帧 200.0 · edge paint / 帧 1.0
///   B2 拖节点一帧（200 节点，真实宿主）       :  72.74 ms
///      buildFlowGraph / 帧 1.0 · nodeCard build / 帧 206.7 · paint 1.0
///
/// 阶段 1 后（A 段改为中位计时 + 同进程 legacy 对照，故与上面单跑数字不可直接比）：
///   A1 5.16 ms ← 参照旧写法 46.92 ms，**9.1×**
///   A2 1.12 ms · A3 2.31 ms
///   B1/B2 未动（阶段 1 只改数据层，画布帧不变）
///
/// 阶段 2 后（宿主 graph 缓存 + FlowGraph 索引）：
///   B2 buildFlowGraph / 帧 : **1.0 → 0.0**（拖节点只改位置，不再重算图）
///   A3 layoutFlow 419 节点 : 2.31 → **0.18 ms（12×）**，来自 edgesFrom 索引化
///   A1 5.90 ms（9.3× 于参照）· A2 1.19 ms
///   B1/B2 帧耗时仍 ~84 ms —— 卡片重建未动，是阶段 4 的目标
///
/// ⚠ 阶段 3 起重画场景变了：合成图每 8 句挂一个未定义选项，产生缺失节点与
/// **52 条虚线边**（原场景 0 条虚线，等于没测 dash 路径）。节点数 200 → 224。
/// **之后的帧耗时只能与阶段 3 这组比，不要与阶段 0/1/2 的帧耗时对比。**
///
/// 阶段 3 后（paint 走画布变换 + Paint/Path 复用 + 虚线缓存 + 命中粗筛）：
///   A1 5.93 ms（10.7× 于参照）· A2 1.95 ms / 471 节点 470 边 · A3 0.36 ms
///   B1 平移 : **121.30 ms**/帧 · 224 cards/帧 · 1 paint/帧
///   B2 拖节点 : **101.40 ms**/帧 · 231 cards/帧 · 0 buildFlowGraph/帧
///   → 更真实的场景约 8–10fps；卡片重建仍占绝对大头，阶段 4 是主战场
///
/// 阶段 4 后（卡片按世界像素布局 + 外层 Transform 施加视口 + 裁剪 + 三档 LOD）：
///   A1 5.23 ms（9.5× 于参照）· A2 1.39 ms · A3 0.20 ms
///   B1 平移 : 121.30 → **3.01 ms/帧（40×）** · 224 → **0.0** cards/帧 · 挂载 3/200
///   B2 拖节点 : 101.40 → **14.81 ms/帧（6.8×）** · 231 → 4.0 cards/帧（=可见区张数）
///   B3 密集场景 471/562 节点、展开 48/57：平移 3.8/3.3 ms/帧（完整档）、
///      2.2/2.7（标题档）、2.0/2.0 ms/帧（色块档，挂载 0 张卡片）
///   → 帧成本已从「卡片重建」转为「连线批量重绘」，且与节点总数解耦：
///      200 节点与 562 节点的平移帧同为个位数毫秒。
///   → 展开态限流（kMaxExpandedNodes）不需要：裁剪后常驻卡片只有 11 张。
///
/// 阶段 5 后（多选/框选，未改渲染热路径）重新读数，全部计数项与阶段 4 一致：
///   A1 5.68 ms · A2 1.33 ms · A3 0.20 ms
///   B1 平移 2.80 ms/帧 · 0.0 cards/帧 · 挂载 3/200
///   B2 拖节点 17.07 ms/帧 · 0.0 buildFlowGraph/帧 · 4.0 cards/帧
///   → B2 毫秒与阶段 4 的 14.81 差异属本机抖动：紧接着原样重跑一次，全部计数
///     项不变但 B3 三档毫秒从 5.28/3.73/3.80 变成 3.12/2.19/1.85 —— 墙钟单次
///     波动可达 ±40%，能跨阶段比较的只有计数。多选只给每帧加一次选中集比较。
///
/// 阶段 6 后（S4 C1/C2/C4/C6：卡片实例缓存 + 槽位门控 + 连线裁剪 + 虚线键量化）：
///   A1 5.15 ms（10.69× 于参照）· A2 1.30 ms / 471 节点 470 边 · A3 0.26 ms
///   B1 平移 : 1.94 ms/帧 · 0.0 cards/帧 · 挂载 3/200
///   B2 拖节点 : 11.11 ms/帧 · 0.0 buildFlowGraph/帧 · **4.0 → 0.0 cards/帧**
///      · dashCache 清空 0 次（positionsVersion 已移出 _geometryRev）
///   B3 471/562 节点、展开 48/57：完整档 1.62/1.34 ms/帧（挂载 4/4）、
///      标题档 1.34/1.20（挂载 5/5）、色块档 1.16/0.97 ms/帧（挂载 0/0）
///   → C2 把「宿主每帧全量重算槽位（N 张卡片+端口表+足迹 ≈2,500 分配/帧）」
///     压成「只重建 Positioned 包装」；C4 连线可见区求交跳过后帧耗时进一步
///     下降（视口外边不再 cubicTo）。卡片重建计数从 4.0 收紧为 equals(0)。
///
/// 第二轮读数（大表链路批：S4-C10 拖帧去宿主 setState，benchDrag 记录
/// workspaceBuilds 并新增 equals(0) 断言；按下选中态的跨帧重建在采样前排空）：
///   A1 5.69 ms（8.61× 于参照）· A2 1.65 ms / 471 节点 470 边 · A3 0.39 ms
///   B1 平移 : 2.10 ms/帧 · 0.0 cards/帧 · 挂载 3/200
///   B2 拖节点 : **11.11 → 3.85 ms/帧** · 0.0 buildFlowGraph/帧 · 0.0 cards/帧
///      · **workspace build 0 / 30 帧**（C10 准出，此前 ≥1 次/帧）
///   B3 471/562 节点：完整档 1.74/1.37、标题档 1.40/1.13、色块档 1.23/0.91 ms/帧
///   → C10 后拖帧成本主体只剩连线重绘 + Positioned 包装；M4（<5ms）达成。
///
/// 结构性事实（基线读出，阶段 4 前）：
/// - 拖一个节点 = 宿主每帧重建整张图（1.0 次 buildFlowGraph/帧），因为
///   story_flow_workspace.dart:567 的 _graph 是 getter。
/// - 纯平移不动任何图数据，却仍全量重绘连线并重建全部 200 张卡片。
/// - **帧成本由卡片重建主导**（200 张 ≈ 67ms，buildFlowGraph 只占 6ms）：
///   渲染层重写（阶段 4）对流畅度的收益高于图缓存（阶段 2）；阶段 2 仍要做，
///   因为它顺带消掉 O(E×N) 查找并修掉重绘触发的隐式耦合。
/// - 73–79ms/帧 ≈ 13fps（debug 模式）。单次计时噪声可达 2×，一律取中位数。
library;

import 'dart:convert';

import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:student_age_editor/core/api_client.dart';
import 'package:student_age_editor/core/models.dart';
import 'package:student_age_editor/features/story/story_flow_graph.dart';
import 'package:student_age_editor/features/story/story_flow_models.dart';
import 'package:student_age_editor/features/story/story_flow_node_presets.dart';
import 'package:student_age_editor/features/story/story_flow_workspace.dart';
import 'package:student_age_editor/features/story/story_logic.dart';

const int _kRealTalkRows = 98963;
const int _kBenchNodes = 419;
const int _kCanvasBenchNodes = 200;
const int _kDragFrames = 30;

/// 真实数据里事件 1000001 名下的对白 id 是 10 位、前 7 位即事件号，
/// 每事件最多 1000 句 —— 连续 id 段天然复现这个分布。
String _talkId(int i) => '${1000001000 + i}';

/// [rows] 行合成 TalkCfg；前 [chain] 行的 nextTalk 串成单链。
/// 每 8 句挂一个指向未定义选项的 option 引用：真实事件普遍如此，且它产生
/// 缺失节点与**虚线边** —— 不加的话 bench 完全测不到 dash 路径。
Map<String, dynamic> synthTalksTable({required int rows, int chain = 0}) {
  final out = <String, dynamic>{};
  for (var i = 0; i < rows; i++) {
    final id = _talkId(i);
    out[id] = {
      'id': int.parse(id),
      'roleName': '旁白',
      'content': '台词 $i',
      'nextTalk': (chain > 0 && i < chain - 1) ? [_talkId(i + 1)] : <String>[],
      if (chain > 0 && i < chain - 1 && i % 8 == 7) 'option': ['undef$id'],
    };
  }
  return out;
}

/// chain 节点、chain-1 条边的舞台数据。
Map<String, dynamic> synthStage(int chain) =>
    synthTalksTable(rows: chain, chain: chain);

/// 优化前写法的逐字复刻（每行新建 RegExp、每行重建前缀 Set、无条件正则替换），
/// 用于在同一进程、同一份数据上量出真实倍数 —— 跨机抄来的基线数字不可比。
/// 注：命中的行用浅拷贝代替私有的 `_deepCopy`，所以倍数只会低估不会高估。
Map<String, dynamic> legacyStageOf(
  Map<String, dynamic> full,
  List<String> prefixes,
) {
  final out = <String, dynamic>{};
  for (final entry in full.entries) {
    final tid = entry.key.trim().replaceAll(RegExp(r'\.0$'), '');
    if (tid.isEmpty) continue;
    final clean = prefixes
        .map((p) => p.trim().replaceAll(RegExp(r'\.0$'), ''))
        .where((p) => p.isNotEmpty)
        .toSet();
    if (clean.isEmpty) continue;
    final hit = tid.length > 3
        ? clean.contains(tid.substring(0, tid.length - 3))
        : clean.contains(tid);
    if (hit) out[tid] = entry.value;
  }
  return out;
}

FlowGraph benchGraph(int nodes) => buildFlowGraph(
  talks: synthStage(nodes),
  options: {},
  prefixes: ['1000001'],
  starts: ['1000001000'],
  cardStyles: builtinFlowCardSpecs(),
);

double median(List<double> xs) {
  final s = [...xs]..sort();
  final m = s.length ~/ 2;
  return s.length.isOdd ? s[m] : (s[m - 1] + s[m]) / 2;
}

String ms(double v) => v.toStringAsFixed(2);

/// [iters] 次调用的中位耗时（ms）。单次计时在 JIT 下噪声可达 2×
/// （实测 layoutFlow 同一份代码在 5.7 与 10.5 之间跳），必须取中位数。
double timeMs(void Function() body, {int iters = 7}) {
  body(); // 预热：首调用含 JIT 编译
  final xs = <double>[];
  for (var i = 0; i < iters; i++) {
    final sw = Stopwatch()..start();
    body();
    sw.stop();
    xs.add(sw.elapsedMicroseconds / 1000);
  }
  return median(xs);
}

void report(String line) => debugPrint('[bench] $line');

/// 展开区不建控制器时的占位工厂。
TextEditingController? _noField(String nodeId, String field) => null;

/// 隔离挂载画布（不挂宿主：StoryFlowWorkspace 的浮动工具栏会吃掉指针事件）。
/// 测的是画布自身的帧成本。
Future<void> mountCanvas(
  WidgetTester tester, {
  required FlowGraph graph,
  required Map<String, Offset> positions,
  Set<String> expanded = const {},
  TextEditingController? Function(String nodeId, String field)? fieldController,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: fluent.FluentTheme(
        data: fluent.FluentThemeData(brightness: Brightness.dark),
        child: Scaffold(
          body: SizedBox(
            width: 1200,
            height: 700,
            child: StoryFlowGraph(
              graph: graph,
              positions: positions,
              expandedNodes: expanded,
              onSelectionChanged: (_) {},
              onMoveNode: (id, pos) => positions[id] = pos,
              onAddEdge: (_, _, _) {},
              onDeleteEdge: (_, _, _) {},
              onRequestDelete: () {},
              onToggleExpand: (_) {},
              fieldController: fieldController ?? _noField,
              onFieldChanged: (_, _, _) {},
              onDeleteNode: (_) {},
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 一次拖拽的测量结果：每帧墙钟 + 三类重建计数增量。
typedef BenchDrag = ({
  List<double> frameMs,
  int cards,
  int paints,
  int graphs,

  /// 拖拽期间虚线缓存整体作废次数（C4 准出：拖拽帧必须为 0）。
  int dashClears,

  /// 拖拽结束时视口平移量：证明指针事件真的送达画布。
  Offset panDelta,

  /// 视口裁剪后仍挂载的卡片数（每张卡片恰有一个 RepaintBoundary）。
  int mounted,

  /// 拖拽期间宿主 workspace build 次数（C10 准出：必须为 0，
  /// 位置更新走 ValueNotifier 直达画布，不再 setState 全宿主）。
  int workspaceBuilds,
});

/// 从 [from] 按下后做 [_kDragFrames] 次等距 move，逐帧计时。
/// 计数在按下之后才取基准，避免把「按下选中」那次重建算进帧成本。
Future<BenchDrag> benchDrag(
  WidgetTester tester,
  Offset from,
  Offset deltaPerFrame,
) async {
  final vp = tester
      .state<StoryFlowGraphState>(find.byType(StoryFlowGraph))
      .viewportListenable;
  final g = await tester.startGesture(from);
  await tester.pump();
  // 按下选中的 setState 可能跨到下一次 pump 才 build：再排空一帧，
  // 否则那一次合法重建会被算进拖拽帧（C10 断言会被它污染）。
  await tester.pump();
  final card0 = debugNodeCardBuilds;
  final paint0 = debugEdgePaintCount;
  final graph0 = debugBuildFlowGraphCalls;
  final dash0 = debugDashCacheClears;
  final ws0 = debugWorkspaceBuilds;
  final pan0 = vp.value.pan;
  final frames = <double>[];
  var pos = from;
  for (var i = 0; i < _kDragFrames; i++) {
    pos += deltaPerFrame;
    final sw = Stopwatch()..start();
    await g.moveTo(pos);
    await tester.pump();
    sw.stop();
    frames.add(sw.elapsedMicroseconds / 1000);
  }
  await g.up();
  await tester.pump();
  return (
    frameMs: frames,
    cards: debugNodeCardBuilds - card0,
    paints: debugEdgePaintCount - paint0,
    graphs: debugBuildFlowGraphCalls - graph0,
    dashClears: debugDashCacheClears - dash0,
    workspaceBuilds: debugWorkspaceBuilds - ws0,
    panDelta: vp.value.pan - pan0,
    mounted: find
        .descendant(
          of: find.byType(StoryFlowGraph),
          matching: find.byType(RepaintBoundary),
        )
        .evaluate()
        .length,
  );
}

void main() {
  group('A 数据层：切事件时的纯函数耗时', () {
    test('stageOf 扫全表 + buildFlowGraph/layoutFlow', () {
      final allTalks = synthTalksTable(rows: _kRealTalkRows);
      final prefixes = ['1000001'];

      final stageMs = timeMs(() {
        final stage = stageOf(allTalks, prefixes);
        expect(stage.length, 1000, reason: '前缀 1000001 应命中 1,000 行');
      });

      // 行为等价的直接证据：新旧实现对同一份全表产出完全相同的 key 集合。
      final newKeys = stageOf(allTalks, prefixes).keys.toList()..sort();
      final legacyKeys = legacyStageOf(allTalks, prefixes).keys.toList()
        ..sort();
      expect(newKeys, legacyKeys, reason: 'PrefixMatcher 改写不得改变命中集合');
      final legacyMs = timeMs(() => legacyStageOf(allTalks, prefixes));
      expect(stageMs, lessThan(legacyMs), reason: '新写法不应慢于参照实现');

      final graph = benchGraph(_kBenchNodes);
      expect(
        graph.nodes.length,
        greaterThanOrEqualTo(_kBenchNodes),
        reason: '链上 419 个对白 + 缺失选项终端节点',
      );
      final dashed = graph.edges
          .where((e) => e.kind == FlowEdgeKind.option)
          .length;
      expect(dashed, greaterThan(0), reason: '基准必须覆盖虚线边路径，否则 dashCache 形同没测');
      final buildMs = timeMs(() => benchGraph(_kBenchNodes));
      final layoutMs = timeMs(() => layoutFlow(graph: graph));

      report(
        'A1 stageOf $_kRealTalkRows 行 → 1000 行 : ${ms(stageMs)} ms'
        '（参照旧写法 ${ms(legacyMs)} ms，${ms(legacyMs / stageMs)}×）',
      );
      report(
        'A2 buildFlowGraph ${graph.nodes.length} 节点 / '
        '${graph.edges.length} 边（含虚线 $dashed）: ${ms(buildMs)} ms',
      );
      report('A3 layoutFlow ${graph.nodes.length} 节点 : ${ms(layoutMs)} ms');

      // 宽松下限，只为捕获数量级事故（真实预算另看报告倍数）。
      expect(buildMs, lessThan(500), reason: 'buildFlowGraph 异常慢');
      expect(stageMs, lessThan(2000), reason: 'stageOf 异常慢');
    });
  });

  group('B1 画布自身：纯平移一帧', () {
    // 隔离挂载：宿主 StoryFlowWorkspace 在画布之上还有浮动工具栏/操作药丸等
    // Stack 兄弟节点，会吃掉指针事件使平移根本不发生（首版基准就踩在此处，
    // 计到 0 次重建却毫无异常）。这里只测画布自己的视图移动成本。
    late FlowGraph graph;
    late Map<String, Offset> positions;

    setUp(() {
      graph = benchGraph(_kCanvasBenchNodes);
      positions = layoutFlow(graph: graph);
    });

    Future<void> mount(WidgetTester tester) async =>
        mountCanvas(tester, graph: graph, positions: positions);

    testWidgets('纯平移一帧：只换视口矩阵，零卡片重建', (tester) async {
      await mount(tester);
      // 链式布局全在 y=40 一行（高 112），(600,500) 确为空白 → 进入平移。
      final origin = tester.getTopLeft(find.byType(StoryFlowGraph));
      final r = await benchDrag(
        tester,
        origin + const Offset(600, 500),
        const Offset(8, 0),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      // 平移量必须精确等于指针位移：这是「事件送达画布」的硬证据，
      // 取代旧版「卡片计数 > 0」的弱判据（计数为 0 现在是正确结果）。
      expect(r.panDelta, const Offset(240, 0), reason: '平移未送达画布（30 帧 × 8px）');
      expect(r.cards, 0, reason: '阶段 4 验收：纯平移一帧不得重建任何卡片');
      expect(
        r.paints,
        greaterThanOrEqualTo(_kDragFrames),
        reason: '连线仍每帧重绘（位置变了必须重画）',
      );
      expect(r.graphs, 0, reason: '平移不经宿主 setState，本应为 0');

      report(
        'B1 平移 $_kCanvasBenchNodes 节点中位帧耗时 : '
        '${ms(median(r.frameMs))} ms',
      );
      report(
        '   nodeCard build / 帧 : ${(r.cards / _kDragFrames).toStringAsFixed(1)}',
      );
      report(
        '   edge paint / 帧     : ${(r.paints / _kDragFrames).toStringAsFixed(1)}',
      );
      report('   裁剪后挂载卡片        : ${r.mounted} / $_kCanvasBenchNodes');
    });
  });

  group('B2 真实宿主：拖节点一帧', () {
    late AppState state;

    setUp(() {
      state = AppState()
        ..modName = 'Bench'
        ..modRoot = r'C:\mods\bench';
      final evtCfg = <String, dynamic>{
        '1000001': {
          'id': 1000001,
          'title': '基准事件',
          'talkId': ['1000001000'],
        },
      };
      final talkCfg = synthStage(_kCanvasBenchNodes);
      ApiClient.instance.client = MockClient((request) async {
        final path = request.url.path;
        Map<String, dynamic> data = {};
        if (path.startsWith('/api/cfg/')) {
          final name = path.split('/').last;
          if (name == 'EvtCfg') {
            data = evtCfg;
          } else if (name == 'TalkCfg') {
            data = talkCfg;
          }
          return http.Response(
            jsonEncode({
              'cfg': name,
              'data': data,
              'keys': data.keys.toList(),
              'exists': true,
              'mtime_ns': 12345,
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (path == '/api/plugins/ui/flow_cards') {
          return http.Response(
            '{"flow_cards": []}',
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        // 400 = 文件不存在：合法的「空布局」，于是布局回写就绪。
        if (path == '/api/tools/read') {
          return http.Response(
            '{"error": "not a file"}',
            400,
            headers: {'content-type': 'application/json'},
          );
        }
        if (path == '/api/tools/write') {
          return http.Response(
            '{"ok": true}',
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response(
          '{"error": "unexpected $path"}',
          500,
          headers: {'content-type': 'application/json'},
        );
      });
    });

    tearDown(() {
      ApiClient.instance.client = http.Client();
    });

    Future<void> mount(WidgetTester tester) async {
      await tester.pumpWidget(
        fluent.FluentApp(
          home: Scaffold(
            body: SizedBox(
              width: 1200,
              height: 800,
              child: StoryFlowWorkspace(
                state: state,
                onPreview: (_) {},
                onOpenPlugins: () {},
                onOpenSettings: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byType(StoryFlowGraph),
        findsOneWidget,
        reason: '_load 会自动选中首个事件并挂出画布',
      );
    }

    /// 让 800ms 布局防抖落地并跑完 PUT，否则测试结束残留 pending timer。
    Future<void> drain(WidgetTester tester) async {
      await tester.pump(const Duration(milliseconds: 1000));
      await tester.pumpAndSettle();
    }

    testWidgets('拖节点一帧：图缓存生效，卡片重建量降到可见区', (tester) async {
      await mount(tester);
      // 首个节点世界坐标 (40,40)（layoutFlow startX/startY），初始
      // scale=1/pan=0；卡片中部 (120,70) 避开底部端口与右下展开箭头。
      final origin = tester.getTopLeft(find.byType(StoryFlowGraph));
      final r = await benchDrag(
        tester,
        origin + const Offset(120, 70),
        const Offset(6, 4),
      );
      await drain(tester);

      expect(tester.takeException(), isNull);
      // 阶段 2：拖节点只改位置，不再重算图（基线为 1.0 次/帧）。
      expect(
        r.graphs,
        0,
        reason:
            '位置不属于图数据；若重新出现每帧 buildFlowGraph，'
            '说明有新的舞台写入绕过了 _dirty 失效钩子',
      );
      // 阶段 6：拖拽帧只重建 Positioned 包装，卡片 child 是缓存里的
      // identical 实例（Element.updateChild 短路）→ 整段拖拽 0 次卡片 build。
      // （阶段 4 只做到「可见区张数」，宿主每帧仍全量重算槽位。）
      expect(
        r.cards,
        0,
        reason: '拖拽帧仍重建卡片：卡片实例缓存 / identical 短路未生效',
      );
      expect(
        r.paints,
        greaterThanOrEqualTo(_kDragFrames),
        reason: '基线：每帧全量重绘连线',
      );
      // C4：positionsVersion 已移出 _geometryRev，拖拽帧不再整批清空虚线
      // 缓存（本场景有 52 条虚线边；端点位移由 4px 量化缓存键逐条消化）。
      expect(
        r.dashClears,
        0,
        reason: '拖拽清空虚线缓存：positionsVersion 又被算进了失效键',
      );
      // C10：拖拽帧的位置更新走 ValueNotifier 直达画布，宿主 workspace
      // 不再每帧 setState 全 Stack 重绘（此前 ≥ 1 次/帧）。
      expect(
        r.workspaceBuilds,
        0,
        reason: '拖拽帧仍触发宿主 build：_onMoveNode 又开始 setState 了',
      );

      report(
        'B2 拖节点 $_kCanvasBenchNodes 节点中位帧耗时 : '
        '${ms(median(r.frameMs))} ms',
      );
      report(
        '   buildFlowGraph / 帧 : '
        '${(r.graphs / _kDragFrames).toStringAsFixed(1)}',
      );
      report(
        '   nodeCard build / 帧 : '
        '${(r.cards / _kDragFrames).toStringAsFixed(1)}',
      );
      report(
        '   edge paint / 帧     : '
        '${(r.paints / _kDragFrames).toStringAsFixed(1)}',
      );
      report('   dashCache 清空        : ${r.dashClears}');
      report('   workspace build       : ${r.workspaceBuilds} / $_kDragFrames 帧');
      report('   裁剪后挂载卡片        : ${r.mounted} / $_kCanvasBenchNodes');
    });
  });

  group('B3 密集场景：真实事件规模 + 10% 展开（阶段 4 决策依据）', () {
    for (final rows in const [_kBenchNodes, 500]) {
      testWidgets('$rows 句：纯平移穿过三档 LOD', (tester) async {
        final graph = benchGraph(rows);
        final positions = layoutFlow(graph: graph);
        final expanded = <String>{
          for (var i = 0; i < graph.nodes.length; i += 10) graph.nodes[i].id,
        };
        final ctls = <String, TextEditingController>{};
        await mountCanvas(
          tester,
          graph: graph,
          positions: positions,
          expanded: expanded,
          fieldController: (id, field) => ctls.putIfAbsent(
            '$id|$field',
            () => TextEditingController(text: ''),
          ),
        );
        final st = tester.state<StoryFlowGraphState>(
          find.byType(StoryFlowGraph),
        );
        final origin = tester.getTopLeft(find.byType(StoryFlowGraph));
        // layoutFlow 的 startX=40 且列坐标单调右移 → 世界 x<40 恒为空白带；
        // 把它当缩放锚点，换档后该带仍然停在同一屏幕位置。
        const empty = Offset(10, 300);
        final at = origin + empty;

        Future<void> zoomOut(int ticks) async {
          for (var i = 0; i < ticks; i++) {
            await tester.sendEventToBinding(
              PointerScrollEvent(
                position: at,
                scrollDelta: const Offset(0, 120),
              ),
            );
            await tester.pump();
          }
          await tester.pumpAndSettle();
        }

        Future<BenchDrag> pan() => benchDrag(tester, at, const Offset(6, 0));
        String tier(BenchDrag r) =>
            'scale='
            '${st.viewportListenable.value.scale.toStringAsFixed(2)} · '
            '${ms(median(r.frameMs))} ms/帧 · '
            '${(r.cards / _kDragFrames).toStringAsFixed(1)} cards/帧 · '
            '${(r.paints / _kDragFrames).toStringAsFixed(1)} paint/帧 · '
            '挂载 ${r.mounted}';

        // 结论 1：可见区只有巴掌大，展开态再多也只挂十几张卡片，
        // 不需要额外限流（kMaxExpandedNodes  contingency 不启用）。
        final full = await pan();
        expect(tester.takeException(), isNull);
        expect(full.panDelta, const Offset(180, 0), reason: '平移未送达画布');
        expect(full.cards, 0, reason: '密集场景下纯平移仍在重建卡片');
        expect(
          full.mounted,
          lessThanOrEqualTo(20),
          reason: '视口裁剪未生效：${full.mounted} 张卡片常驻',
        );
        report('B3 $rows 句 → ${graph.nodes.length} 节点（展开 ${expanded.length}）');
        report('   完整档 ${tier(full)}');

        await zoomOut(6); // 0.9^6 ≈ 0.53 → 仅标题档
        final title = await pan();
        expect(tester.takeException(), isNull);
        expect(title.cards, 0, reason: '标题档纯平移仍重建卡片');
        report('   标题档 ${tier(title)}');

        await zoomOut(5); // ≈0.31 → 色块档：整场节点不挂任何 Widget
        final blocks = await pan();
        expect(tester.takeException(), isNull);
        expect(blocks.cards, 0, reason: '最低档仍在挂载卡片');
        expect(blocks.mounted, 0, reason: '色块档下卡片子树应为空');
        report('   色块档 ${tier(blocks)}');
      });
    }
  });
}
