/// 阶段 5 回归：多选、Shift 增删、框选与组拖。
///
/// 选中态由宿主持有，画布只算「下一次选什么」，所以这里用一个 _Harness
/// 状态组件扮演宿主：没有它，widget.selection 永远停在初值，
/// 「第二次 Shift 点选应累加」这类断言会假通过。
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

/// 三个链式对白节点（边不参与选中判定，只为端口渲染）。
FlowGraph _graph() => buildFlowGraph(
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

  Future<Map<String, Offset>> mount(WidgetTester tester) async {
    final p = _positions();
    await tester.pumpWidget(
      MaterialApp(
        home: fluent.FluentTheme(
          data: fluent.FluentThemeData(brightness: Brightness.dark),
          child: Scaffold(
            body: SizedBox(
              width: 900,
              height: 700,
              child: _Harness(graph: _graph(), positions: p),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    host = tester.state<_HarnessState>(find.byType(_Harness));
    return p;
  }

  /// 按住 Shift 执行一段手势。HardwareKeyboard 是全局单例，
  /// 必须收尾，否则后续用例都跑在 Shift 态下。
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

  FlowViewport view(WidgetTester tester) => tester
      .state<StoryFlowGraphState>(find.byType(StoryFlowGraph))
      .viewportListenable
      .value;

  testWidgets('普通点选替换选中集，Shift 点选增删', (tester) async {
    final p = await mount(tester);

    await tester.tapAt(_cardCenter(p, _n1));
    await tester.pumpAndSettle();
    expect(host.selection.nodes, {_n1});

    await tester.tapAt(_cardCenter(p, _n2));
    await tester.pumpAndSettle();
    expect(host.selection.nodes, {_n2}, reason: '普通点选应替换而不是累加');

    await withShift(tester, () async {
      await tester.tapAt(_cardCenter(p, _n1));
      await tester.pumpAndSettle();
    });
    expect(host.selection.nodes, {_n1, _n2}, reason: 'Shift 点选应累加');

    await withShift(tester, () async {
      await tester.tapAt(_cardCenter(p, _n2));
      await tester.pumpAndSettle();
    });
    expect(host.selection.nodes, {_n1}, reason: 'Shift 再点应把它移出选中集');
  });

  testWidgets('Shift 拖空白=框选，且不会把视图拖走', (tester) async {
    await mount(tester);
    final panBefore = view(tester).pan;

    await withShift(tester, () async {
      final g = await tester.startGesture(const Offset(10, 10));
      await g.moveTo(const Offset(700, 200));
      await tester.pump();
      await g.up();
      await tester.pumpAndSettle();
    });

    expect(host.selection.nodes, {
      _n1,
      _n2,
      _n3,
    }, reason: '框住整行就该全选（节点足迹与框相交即中）');
    expect(view(tester).pan, panBefore, reason: 'Shift 拖空白必须走框选，不能顺手平移视图');
  });

  testWidgets('空白拖拽（不按 Shift）仍然平移且不改选中集', (tester) async {
    final p = await mount(tester);
    await tester.tapAt(_cardCenter(p, _n1));
    await tester.pumpAndSettle();
    expect(host.selection.nodes, {_n1});

    final g = await tester.startGesture(const Offset(10, 400));
    await g.moveTo(const Offset(210, 500));
    await tester.pump();
    await g.up();
    await tester.pumpAndSettle();

    expect(view(tester).pan, const Offset(200, 100), reason: '空手拖应平移视口');
    expect(host.selection.nodes, {_n1}, reason: '平移不该动选中集');
    expect(p[_n1], const Offset(40, 40), reason: '平移也不该动节点');
  });

  testWidgets('拖已选中节点 = 整组同位移；未选中节点不被牵连', (tester) async {
    final p = await mount(tester);
    await tester.tapAt(_cardCenter(p, _n1));
    await tester.pumpAndSettle();
    await withShift(tester, () async {
      await tester.tapAt(_cardCenter(p, _n2));
      await tester.pumpAndSettle();
    });
    expect(host.selection.nodes, {_n1, _n2});
    final a = p[_n1]!, b = p[_n2]!, c = p[_n3]!;

    final g = await tester.startGesture(_cardCenter(p, _n1));
    await g.moveBy(const Offset(50, 60));
    await tester.pump();
    await g.up();
    await tester.pumpAndSettle();

    const d = Offset(50, 60);
    // 阶段 7 起拖拽落点会先过吸附（这里是 8px 网格），所以断言「相对关系」
    // 而不是绝对落点：整组刚性 + 未选中节点分文不动 + 偏移不超过一个容差。
    final moved = p[_n1]! - a;
    expect(
      (moved - d).distance,
      lessThanOrEqualTo(6),
      reason: '被拖节点应位移，允许被吸附挪动至多世界容差 6px',
    );
    expect(p[_n2]! - p[_n1]!, b - a, reason: '同组节点必须刚性移动，否则整组会散架');
    expect(p[_n3], c, reason: '未选中节点不该跟着动');
  });

  testWidgets('点在已选中组内的空白卡片上不丢整组选中', (tester) async {
    final p = await mount(tester);
    await tester.tapAt(_cardCenter(p, _n1));
    await tester.pumpAndSettle();
    await withShift(tester, () async {
      await tester.tapAt(_cardCenter(p, _n2));
      await tester.pumpAndSettle();
    });
    // 再普通点 n1：它已在组里 → 保留整组，才能继续拖动整组。
    await tester.tapAt(_cardCenter(p, _n1));
    await tester.pumpAndSettle();
    expect(host.selection.nodes, {_n1, _n2}, reason: '点在组内应保留多选，否则每次起手都掉成单选');
  });

  testWidgets('多选时按一次 Delete 只发一次删除请求', (tester) async {
    final p = await mount(tester);
    await tester.tapAt(_cardCenter(p, _n1));
    await tester.pumpAndSettle();
    await withShift(tester, () async {
      await tester.tapAt(_cardCenter(p, _n2));
      await tester.pumpAndSettle();
    });
    expect(host.selection.nodes, {_n1, _n2});

    await tester.sendKeyDownEvent(LogicalKeyboardKey.delete);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.delete);
    await tester.pumpAndSettle();
    expect(host.requestDeleteCalls, 1, reason: '批量删除由宿主一次处理，画布不该逐项触发');
  });

  testWidgets('Escape 清空整个选中集', (tester) async {
    final p = await mount(tester);
    await withShift(tester, () async {
      await tester.tapAt(_cardCenter(p, _n1));
      await tester.pumpAndSettle();
      await tester.tapAt(_cardCenter(p, _n2));
      await tester.pumpAndSettle();
    });
    expect(host.selection.count, 2);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.escape);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(host.selection.isEmpty, isTrue);
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
