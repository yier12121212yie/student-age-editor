// M6 移动端切片：剧情图画布触控化——双指 pinch 缩放（围绕两指中点、
// clamp 上下限、内容跟手不漂）与长按菜单（与右键同一命中判定）。
// 桌面既有行为（右键菜单、单指/左键平移、滚轮）一并不回归。
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;

import 'package:student_age_editor/features/story/story_flow_graph.dart';
import 'package:student_age_editor/features/story/story_flow_models.dart';

void main() {
  const nodeId = '1000001001';
  // 节点世界矩形 (100,100)-(300,212)，scale=1、pan=0 时屏幕同值。
  const nodeCenterScreen = Offset(200, 156);

  late FlowGraph graph;
  late Map<String, TextEditingController> ctls;
  final contextTaps = <FlowContextTap>[];
  final selectionCalls = <FlowSelection>[];

  setUp(() {
    graph = buildFlowGraph(
      talks: {
        nodeId: {'roleName': '旁白', 'content': 'a', 'nextTalk': []},
      },
      options: {},
      prefixes: ['1000001'],
      starts: [nodeId],
    );
    ctls = {};
    contextTaps.clear();
    selectionCalls.clear();
  });

  TextEditingController ctlFor(String id, String field) =>
      ctls.putIfAbsent('$id|$field', () => TextEditingController(text: ''));

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1000, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: fluent.FluentTheme(
          data: fluent.FluentThemeData(brightness: Brightness.dark),
          child: Scaffold(
            body: SizedBox(
              width: 900,
              height: 700,
              child: StoryFlowGraph(
                graph: graph,
                positions: const {nodeId: Offset(100, 100)},
                selection: FlowSelection.none,
                expandedNodes: const {},
                onSelectionChanged: selectionCalls.add,
                onMoveNode: (_, _) {},
                onAddEdge: (_, _, _) {},
                onDeleteEdge: (_, _, _) {},
                onRequestDelete: () {},
                onToggleExpand: (_) {},
                fieldController: ctlFor,
                onFieldChanged: (_, _, _) {},
                onDeleteNode: (_) {},
                onContextMenu: contextTaps.add,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  FlowViewport vp(WidgetTester tester) =>
      tester.state<StoryFlowGraphState>(
        find.byType(StoryFlowGraph),
      ).viewportListenable.value;

  testWidgets('双指外扩：scale 按跨度比值增大，起始焦点下的内容不漂', (tester) async {
    await pump(tester);
    // 两指落点在空白处（避开节点），跨度 100，中点 (600,400)。
    final g1 = await tester.startGesture(const Offset(550, 400));
    await tester.pump();
    final g2 = await tester.startGesture(const Offset(650, 400));
    await tester.pump();
    // 各向外挪 60：跨度 100→220，scale 应为 2.2；中点不动，
    // pan = focal - focalWorld·scale = (600,400)·(1-2.2)。
    await g1.moveBy(const Offset(-60, 0));
    await g2.moveBy(const Offset(60, 0));
    await tester.pump();
    expect(vp(tester).scale, closeTo(2.2, 0.001));
    expect(vp(tester).pan.dx, closeTo(-720, 0.01));
    expect(vp(tester).pan.dy, closeTo(-480, 0.01));
    // 焦点世界点 (600,400) 在新视口下仍投影回屏幕 (600,400)。
    expect(
      vp(tester).toScreen(const Offset(600, 400)),
      const Offset(600, 400),
    );
    await g1.up();
    await g2.up();
    await tester.pump();
  });

  testWidgets('双指回捏：scale 被 clamp 到 minScale，不产生负 span 崩溃', (tester) async {
    await pump(tester);
    final g1 = await tester.startGesture(const Offset(550, 400));
    await tester.pump();
    final g2 = await tester.startGesture(const Offset(650, 400));
    await tester.pump();
    await g1.moveBy(const Offset(45, 0));
    await g2.moveBy(const Offset(-45, 0));
    await tester.pump();
    // 跨度 100→10，理论 scale 0.1 < minScale 0.2 → 取下限。
    expect(vp(tester).scale, FlowViewport.minScale);
    await g1.up();
    await g2.up();
    await tester.pump();
  });

  testWidgets('pinch 抬起一指退化平移，末指抬起不触发点击清选', (tester) async {
    await pump(tester);
    final g1 = await tester.startGesture(const Offset(550, 400));
    await tester.pump();
    final g2 = await tester.startGesture(const Offset(650, 400));
    await tester.pump();
    await g1.moveBy(const Offset(-60, 0));
    await g2.moveBy(const Offset(60, 0));
    await tester.pump();
    final scaleAfterPinch = vp(tester).scale;
    // 抬一指：剩指应接管平移，scale 保持。
    await g1.up();
    await tester.pump();
    expect(vp(tester).scale, scaleAfterPinch);
    // 末指原地上抬（<4px 位移）：不得当作点击清空选中集。
    await g2.up();
    await tester.pump();
    expect(selectionCalls, isEmpty);
  });

  testWidgets('长按节点：触发与右键同型的节点上下文菜单', (tester) async {
    await pump(tester);
    final g = await tester.startGesture(nodeCenterScreen);
    await tester.pump(const Duration(milliseconds: 600));
    await g.up();
    await tester.pump();
    expect(contextTaps, hasLength(1));
    expect(contextTaps.single.nodeId, nodeId);
    expect(contextTaps.single.screen, nodeCenterScreen);
  });

  testWidgets('长按空白：上报空区域菜单锚点', (tester) async {
    await pump(tester);
    const blank = Offset(700, 600);
    final g = await tester.startGesture(blank);
    await tester.pump(const Duration(milliseconds: 600));
    await g.up();
    await tester.pump();
    expect(contextTaps, hasLength(1));
    expect(contextTaps.single.isEmptyArea, isTrue);
    expect(contextTaps.single.screen, blank);
  });

  testWidgets('长按前移动超出 slop：按拖动处理，不出菜单', (tester) async {
    await pump(tester);
    final g = await tester.startGesture(const Offset(700, 600));
    await tester.pump();
    await g.moveBy(const Offset(60, 0));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await g.up();
    await tester.pump();
    expect(contextTaps, isEmpty);
    // 是平移：pan 跟了位移，scale 不变。
    expect(vp(tester).pan, const Offset(60, 0));
    expect(vp(tester).scale, 1);
  });

  testWidgets('单指平移与桌面右键菜单不回归', (tester) async {
    await pump(tester);
    // 单指（触摸）平移：只动 pan。
    final g = await tester.startGesture(const Offset(600, 300));
    await tester.pump();
    await g.moveBy(const Offset(-100, -50));
    await g.up();
    await tester.pump();
    expect(vp(tester).scale, 1);
    expect(vp(tester).pan, const Offset(-100, -50));
    // 右键菜单照旧。平移后节点屏幕矩形为 (0,50)-(200,162)，
    // 取内部点 (100,106)（避开 contains 不含右缘的边界）。
    final r = await tester.startGesture(
      const Offset(100, 106),
      buttons: kSecondaryButton,
    );
    await tester.pump();
    await r.up();
    await tester.pump();
    expect(contextTaps, hasLength(1));
    expect(contextTaps.single.nodeId, nodeId);
  });
}
