/// 阶段 7 吸附「接线」回归：真实 pointer 手势 → `_applySnap` → `onMoveNode`。
///
/// `story_flow_snap_test.dart` 钉的是纯函数数学，画布那边只要「忘了调」或
/// 「调错了参数」单测照样全绿。这里钉的是链路本身：
/// - pointer-move 每帧是否真的过吸附（而不是只在抬手时算一次）；
/// - 右边缘命中时对齐的是右边缘（且优先于更近的网格线，不是被 96 抢走）；
/// - Alt 是否真的旁路整条链路，落点分毫不动；
/// - 组拖是否**一帧只做一次**吸附决策，再把同一位移分给每个成员。
///
/// 辅助线（FlowGuide）在 widget 测试里**不可观测**：它住在 `StoryFlowGraphState`
/// 的私有字段 `_snapGuides` 上，由 CustomPaint 的 painter 在同一帧里画掉，
/// 既没有 listenable 也没有 public getter，而跨库读私有成员在 Dart 里是编译错误。
/// 所以下面一律用「落点是否恰好等于目标边缘值」反证命中了哪一类线。
library;

import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:student_age_editor/features/story/story_flow_graph.dart';
import 'package:student_age_editor/features/story/story_flow_models.dart';

const _n1 = '1000001001';
const _n2 = '1000001002';
const _n3 = '1000001003';

/// 邻近带用例专用的远邻：x 区间与被拖卡重叠，y 由该用例分别在带外（上方
/// 600 世界 px）与带内两种摆位下给出，其余一切不变。
const _n4 = '1000001004';

/// 屏幕 px == 世界 px（harness 起始 scale 1 / pan 0），所以卡宽就是 200。
const double _w = kFlowNodeW;

/// 三个链式对白节点（边不参与吸附与选中判定，只为端口渲染）。
/// [withFar] 追加一个孤立节点，供邻近带用例当「看得见的远邻」。
FlowGraph _graph({bool withFar = false}) => buildFlowGraph(
  talks: {
    _n1: {
      'content': '一',
      'nextTalk': [_n2],
    },
    _n2: {
      'content': '二',
      'nextTalk': [_n3],
    },
    _n3: {'content': '三', 'nextTalk': []},
    if (withFar) _n4: {'content': '远', 'nextTalk': []},
  },
  options: {},
  prefixes: ['1000001'],
  starts: [_n1],
);

/// 一行三张卡：x 从 40 起、间距 60，(10,10) 恒为空白可作框选起点。
Map<String, Offset> _positions() => {
  _n1: const Offset(40, 40),
  _n2: const Offset(300, 40),
  _n3: const Offset(560, 40),
};

/// 卡片底座中部：避开底部端口行与右下角展开箭头。
Offset _cardCenter(Map<String, Offset> p, String id) =>
    p[id]! + const Offset(60, 40);

void main() {
  late _HarnessState host;

  Future<Map<String, Offset>> mount(
    WidgetTester tester, {
    FlowGraph? graph,
    Map<String, Offset>? positions,
  }) async {
    final p = positions ?? _positions();
    await tester.pumpWidget(
      MaterialApp(
        home: fluent.FluentTheme(
          data: fluent.FluentThemeData(brightness: Brightness.dark),
          child: Scaffold(
            body: SizedBox(
              width: 900,
              height: 700,
              child: _Harness(graph: graph ?? _graph(), positions: p),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    host = tester.state<_HarnessState>(find.byType(_Harness));
    return p;
  }

  /// 一次性拖到位：一次 moveTo 即一帧 pointer-move，落点就是该帧的吸附结果。
  /// （这个 Flutter 版本没有 `tester.drag(from, delta)`，只能自己起手。）
  Future<void> dragTo(WidgetTester tester, Offset from, Offset to) async {
    final g = await tester.startGesture(from);
    await g.moveTo(to);
    await tester.pump();
    await g.up();
    await tester.pumpAndSettle();
  }

  /// 按住 Alt 执行一段手势。HardwareKeyboard 是全局单例，
  /// 必须收尾，否则后续用例都跑在「关掉吸附」态下。
  Future<void> withAlt(
    WidgetTester tester,
    Future<void> Function() body,
  ) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    try {
      await body();
    } finally {
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pumpAndSettle();
    }
  }

  /// 同 withAlt，用于组拖前的 Shift 增选。
  Future<void> withShift(
    WidgetTester tester,
    Future<void> Function() body,
  ) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    try {
      await body();
    } finally {
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pumpAndSettle();
    }
  }

  testWidgets('右边缘吸附到邻居左边缘，且优先于更近的网格线', (tester) async {
    final p = await mount(tester);
    final from = _cardCenter(p, _n1);

    // 期望左上角 x = 40 + 57 = 97 → 右边缘 297，离 n2 左边缘 3（世界 px），
    // 已在容差 6 内。同一帧网格只想搬 1（97 → 96），边缘优先必须赢。
    await dragTo(tester, from, from + const Offset(57, 0));

    expect(p[_n1]!.dx, 100.0, reason: '吸到 100 而不是网格的 96');
    expect(p[_n1]!.dx + _w, p[_n2]!.dx, reason: '对齐的是右边缘贴 n2 左边缘，不是左边缘对左边缘');
    expect(p[_n1]!.dy, 40.0, reason: '纯水平拖，y 落在同行顶线上不动');
    // 此刻 _applySnap 同时产出了竖线 @300（右边缘命中）与横线 @40（顶边命中），
    // 但如文件头所述，widget 测试读不到 _snapGuides，只能靠上面的落点反证。
  });

  testWidgets('Alt 按住时不吸附：落点等于原始期望位移', (tester) async {
    final p = await mount(tester);
    final from = _cardCenter(p, _n1);

    await withAlt(
      tester,
      () => dragTo(tester, from, from + const Offset(57, 0)),
    );

    expect(
      p[_n1]!,
      const Offset(97, 40),
      reason: 'Alt 应分毫不改：既不去边缘 100，也不去网格 96',
    );
  });

  testWidgets('远离任何节点时落 8px 网格兜底', (tester) async {
    final p = await mount(tester);
    final from = _cardCenter(p, _n1);

    // 期望左上角 (542, 442)：两轴都离 8 的倍数差 2（544 / 440）。
    // 同行的 n2/n3 已掉出纵向邻近带，不该给 x 出候选线。
    await dragTo(tester, from, from + const Offset(502, 402));

    expect(p[_n1]!, const Offset(544, 440), reason: '边缘无命中 → 网格兜底');
    expect(p[_n1]!.dx % 8, 0.0, reason: '网格吸附后的左上角必然落在 8 的格点上');
    expect(p[_n1]!.dy % 8, 0.0);
    // 纯网格吸附不产生辅助线，所以这一帧 painter 一条线都不画（同样读不到，
    // 只能由「落点是网格而不是任何节点边」间接确认）。
  });

  testWidgets('组拖刚性：包围盒吸附，整组共享同一位移', (tester) async {
    final p = await mount(tester);
    await tester.tapAt(_cardCenter(p, _n1));
    await tester.pumpAndSettle();
    await withShift(tester, () async {
      await tester.tapAt(_cardCenter(p, _n2));
      await tester.pumpAndSettle();
    });
    expect(host.selection.nodes, {_n1, _n2});
    final a = p[_n1]!, b = p[_n2]!, c = p[_n3]!;
    final from = _cardCenter(p, _n1);

    // 组包围盒 460×112：期望左 97 / 右 557，右边缘离 n3 左边缘 3。
    await dragTo(tester, from, from + const Offset(57, 0));

    expect(p[_n1]!.dx, 100.0, reason: '被拖框（包围盒）自己吸住了');
    expect(p[_n2]!.dx, 360.0, reason: '成员拿到的是同一个 +60，不是各自再吸一次');
    expect(p[_n2]! - p[_n1]!, b - a, reason: '一帧只做一次吸附决策并分给每个成员，否则整组会散架');
    expect(p[_n1]!.dx + (b.dx - a.dx) + _w, p[_n3]!.dx, reason: '包围盒右边缘贴住 n3');
    expect(p[_n3], c, reason: '未选中节点不该跟着动');
  });

  testWidgets('邻近带生效：正上方 600px 的远邻不该抢走 x', (tester) async {
    // 直接在 positions 里放一个「同 x 区间、纵向 600 世界 px 之上」的卡：
    // 它仍在可见矩形内（可见判定按 inflate 一个卡宽），所以确实被喂给了
    // snapDrag，只是被邻近带挡在候选之外。
    final far = _positions()..[_n4] = const Offset(302, -160);
    final p = await mount(tester, graph: _graph(withFar: true), positions: far);
    final from = _cardCenter(p, _n1);

    // 期望左上角 (99, 440)：右边缘 299 离 n4 左边缘 302 差 3，
    // 同时离 8 的网格线也差 3（96）——两者数值不同，正好能分辨谁赢了。
    await dragTo(tester, from, from + const Offset(59, 400));

    expect(p[_n1]!.dx, 96.0, reason: 'n4 在纵向邻近带外，x 只能落网格');
    expect(
      p[_n1]!.dx,
      isNot(102.0),
      reason: '102 才是「右边缘贴住远处 n4 左边缘」，出现即说明邻近带失效',
    );
    expect(p[_n1]!.dy, 440.0, reason: '远邻的顶/底/中线都在容差外，y 落自己的网格');

    // 对照组：只把 n4 沿 y 挪进邻近带（三条 x 候选线一毫未变），同一手势
    // 立刻吸到 102。少了这一步，上面的 96 可能只是「远邻压根没进候选集」
    // 的假阳性——可见矩形过滤也会给出同样的落点。
    final near = _positions()..[_n4] = const Offset(302, 400);
    final q = await mount(
      tester,
      graph: _graph(withFar: true),
      positions: near,
    );
    final again = _cardCenter(q, _n1);
    await dragTo(tester, again, again + const Offset(59, 400));

    expect(q[_n1]!.dx, 102.0, reason: '同一批候选线一进带内就命中，且仍优先于更近的网格线 96');
    expect(q[_n1]!.dy, 440.0);
  });

  testWidgets('拖动中每帧都跟手（吸附在 move 循环里，不是抬手才算）', (tester) async {
    final p = await mount(tester);
    final from = _cardCenter(p, _n1);
    final g = await tester.startGesture(from);

    // 第 1 帧：期望左上角 58 → 无边缘命中，网格 -2。
    await g.moveTo(from + const Offset(18, 0));
    await tester.pump();
    expect(p[_n1]!.dx, 56.0, reason: '第一帧就该看到吸附后的落点');

    // 第 2 帧：期望左上角 97 → 右边缘进容差，吸到 100。
    await g.moveTo(from + const Offset(57, 0));
    await tester.pump();
    expect(p[_n1]!.dx, 100.0, reason: '跟手且已吸附，此时还没抬手');

    // 第 3 帧：继续走，期望左上角 338 → 两边都没沾上，网格 -2。
    await g.moveTo(from + const Offset(298, 0));
    await tester.pump();
    expect(p[_n1]!.dx, 336.0, reason: '每帧从拖拽基准重算，不是逐帧累加修正量');

    final beforeUp = p[_n1]!;
    await g.up();
    await tester.pumpAndSettle();
    expect(p[_n1]!, beforeUp, reason: '抬手不该再产生第二次跳变');
    expect(p[_n2], const Offset(300, 40), reason: '全程没拖到别人');
  });
}

class _Harness extends StatefulWidget {
  const _Harness({required this.graph, required this.positions});

  final FlowGraph graph;

  /// 与真实宿主一致：原地修改同一个 Map 实例。
  final Map<String, Offset> positions;

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  FlowSelection selection = FlowSelection.none;
  int requestDeleteCalls = 0;
  int _rev = 0;

  @override
  Widget build(BuildContext context) {
    return StoryFlowGraph(
      graph: widget.graph,
      positions: widget.positions,
      positionsVersion: _rev,
      selection: selection,
      onSelectionChanged: (s) => setState(() => selection = s),
      onMoveNode: (id, pos) => setState(() {
        widget.positions[id] = pos;
        _rev++;
      }),
      onAddEdge: (_, _, _) {},
      onDeleteEdge: (_, _, _) {},
      onRequestDelete: () => requestDeleteCalls++,
      onToggleExpand: (_) {},
      fieldController: (_, _) => null,
      onFieldChanged: (_, _, _) {},
      onDeleteNode: (_) {},
    );
  }
}
