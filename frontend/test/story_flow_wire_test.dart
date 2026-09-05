import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;

import 'package:student_age_editor/features/story/story_flow_graph.dart';
import 'package:student_age_editor/features/story/story_flow_models.dart';

/// 连线（wire）回归测试：输出端口按下 → 拖到目标节点 → 松手应回调 onAddEdge。
void main() {
  const aId = '1000001001';
  const bId = '1000001002';

  late FlowGraph graph;
  late List<(String, String, String)> addedEdges;
  late Map<String, Offset> positions;

  setUp(() {
    final talks = <String, dynamic>{
      aId: {'roleName': '甲', 'content': 'a', 'nextTalk': []},
      bId: {'roleName': '乙', 'content': 'b', 'nextTalk': []},
    };
    graph = buildFlowGraph(
      talks: talks,
      options: {},
      prefixes: ['1000001'],
      starts: [aId],
    );
    addedEdges = [];
    positions = {aId: const Offset(100, 100), bId: const Offset(400, 100)};
  });

  Future<void> pump(WidgetTester tester) async {
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
                positions: positions,
                selection: FlowSelection.none,
                expandedNodes: {},
                onSelectionChanged: (_) {},
                onMoveNode: (_, _) {},
                onAddEdge: (from, field, to) => addedEdges.add((from, field, to)),
                onDeleteEdge: (_, _, _) {},
                onRequestDelete: () {},
                onToggleExpand: (_) {},
                fieldController: (_, _) => null,
                inlineMetas: (_) => const [],
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

  /// 世界坐标 → 全局屏幕坐标（与画布同一套换算：screen = pan + scale·world）。
  Offset screenOf(WidgetTester tester, Offset world) {
    final vp = tester
        .state<StoryFlowGraphState>(find.byType(StoryFlowGraph))
        .viewportListenable
        .value;
    return world * vp.scale + vp.pan + tester.getTopLeft(find.byType(StoryFlowGraph));
  }

  /// 拖线：A 的 next 输出端口 → 目标世界点。
  Future<void> dragWire(WidgetTester tester, Offset toWorld) async {
    final fromWorld = const Offset(100, 100) + const Offset(200 / 3, 112);
    final g = await tester.startGesture(screenOf(tester, fromWorld));
    await g.moveTo(screenOf(tester, toWorld));
    await g.up();
    await tester.pumpAndSettle();
  }

  /// 滚轮缩放（真实应用的 fitView 后视口≠恒等）。
  Future<void> wheelZoom(WidgetTester tester, Offset pos, double dy) async {
    await tester.sendEventToBinding(
      PointerScrollEvent(position: pos, scrollDelta: Offset(0, dy)),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('从输出端口拖到目标输入端口应产生连线', (tester) async {
    await pump(tester);
    // 对白节点无检定：两个端口 next/option，next 在 x=W/3，y=节点高。
    await dragWire(tester, const Offset(400, 100) + const Offset(100, 0));
    expect(
      addedEdges,
      [(aId, 'nextTalk', bId)],
      reason: '拖线松手后未回调 onAddEdge：连线功能失效',
    );
  });

  testWidgets('缩放（fitView 类视口）后拖线仍应产生连线', (tester) async {
    await pump(tester);
    // 放大两档再缩小两档：确保平移缩放下的命中换算与世界一致。
    await wheelZoom(tester, const Offset(450, 350), -120);
    await wheelZoom(tester, const Offset(450, 350), -120);
    await wheelZoom(tester, const Offset(450, 350), 120);
    await wheelZoom(tester, const Offset(450, 350), 120);
    await dragWire(tester, const Offset(400, 100) + const Offset(100, 0));
    expect(
      addedEdges,
      [(aId, 'nextTalk', bId)],
      reason: '非恒等视口下连线命中失效',
    );
  });

  testWidgets('标题档（端口圆点不渲染）拖线仍应产生连线', (tester) async {
    await pump(tester);
    for (var i = 0; i < 6; i++) {
      await wheelZoom(tester, const Offset(450, 350), 120);
    }
    final vp = tester
        .state<StoryFlowGraphState>(find.byType(StoryFlowGraph))
        .viewportListenable
        .value;
    expect(vp.scale, inExclusiveRange(kLodTitleDown, kLodFullDown),
        reason: '前置：视口应落在标题档');
    await dragWire(tester, const Offset(400, 100) + const Offset(100, 0));
    expect(
      addedEdges,
      [(aId, 'nextTalk', bId)],
      reason: '标题档下连线失效',
    );
  });

  testWidgets('从输出端口拖到目标卡片正中（非顶部端口）应成功产生连线', (tester) async {
    await pump(tester);
    // 拖到目标卡片正中（x=W/2, y=H/2）：真实用户最常见操作
    await dragWire(tester, const Offset(400, 100) + const Offset(100, 56));
    expect(
      addedEdges,
      [(aId, 'nextTalk', bId)],
      reason: '拖线释放到目标卡片体未连上',
    );
  });

  testWidgets('从输出端口拖到目标卡片标题栏或右下方应成功产生连线', (tester) async {
    await pump(tester);
    await dragWire(tester, const Offset(400, 100) + const Offset(180, 80));
    expect(
      addedEdges,
      [(aId, 'nextTalk', bId)],
      reason: '拖线释放到目标卡片右下区域未连上',
    );
  });
}
