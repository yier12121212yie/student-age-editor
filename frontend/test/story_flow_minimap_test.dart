import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;

import 'package:student_age_editor/features/story/story_flow_graph.dart';
import 'package:student_age_editor/features/story/story_flow_minimap.dart';
import 'package:student_age_editor/features/story/story_flow_models.dart';

/// 小地图回归测试：这里唯一要钉死的是**映射数学**（点在哪就该跳到哪），
/// 所以纯函数直接单测，组件测试只验「组件真的接了这套逆函数」。
/// 不用 golden —— 本仓库没有 golden 基线。
void main() {
  const size = Size(180, 120);
  const pad = 10.0;

  FlowNode talk(String id) =>
      FlowNode(kind: FlowNodeKind.talk, id: id, roleName: '角色$id');
  FlowNode option(String id) =>
      FlowNode(kind: FlowNodeKind.option, id: id, content: '选一下');
  FlowNode missing(String id) =>
      FlowNode(kind: FlowNodeKind.missing, id: id, content: '缺失$id');
  FlowGraph graphOf(List<FlowNode> nodes) =>
      FlowGraph(nodes: nodes, edges: const [], starts: const []);

  /// 节点世界矩形（与绘制同式：折叠足迹 200×112，不看展开态）。
  Rect nodeRect(Offset pos) =>
      Rect.fromLTWH(pos.dx, pos.dy, kFlowNodeW, kFlowNodeH);

  group('拟合映射（纯函数）', () {
    /// 往返误差必须小于半像素：再大就会「点到隔壁节点上」。
    test('world ↔ 小地图 往返在 0.5px 内', () {
      final layouts = <Rect>[
        const Rect.fromLTWH(0, 0, 800, 400),
        const Rect.fromLTWH(100, -50, 200, 600),
        const Rect.fromLTWH(-1200, 340, 2400, 120),
        const Rect.fromLTWH(50, 50, 200, 112),
        const Rect.fromLTRB(0, 0, 4000, 300),
        Rect.zero,
      ];
      for (final bounds in layouts) {
        final fit = computeFlowMinimapFit(
          worldBounds: bounds,
          size: size,
          padding: pad,
        );
        for (final w in <Offset>[
          bounds.center,
          bounds.topLeft,
          bounds.bottomRight,
          Offset.zero,
          const Offset(37, -1234.5),
        ]) {
          final back = minimapPointToWorld(fit, worldPointToMinimap(fit, w));
          expect(
            (back - w).distance,
            lessThan(0.5),
            reason: '往返世界点漂移：bounds=$bounds $w→$back',
          );
        }
        for (final q in <Offset>[
          fit.area.topLeft,
          fit.area.center,
          fit.area.bottomRight,
          const Offset(1, 1),
        ]) {
          final back = worldPointToMinimap(fit, minimapPointToWorld(fit, q));
          expect(
            (back - q).distance,
            lessThan(0.5),
            reason: '往返小地图点漂移：bounds=$bounds $q→$back',
          );
        }
      }
    });

    test('scale 等比：x/y 同一个除数，长边贴满短边居中', () {
      for (final bounds in [
        const Rect.fromLTWH(0, 0, 1600, 200), // 横长
        const Rect.fromLTWH(0, 0, 200, 1600), // 竖长
        const Rect.fromLTWH(0, 0, 800, 400),
      ]) {
        final fit = computeFlowMinimapFit(
          worldBounds: bounds,
          size: size,
          padding: pad,
        );
        final m = worldRectToMinimap(fit, bounds);
        expect(m.width / bounds.width, closeTo(fit.scale, 1e-9));
        expect(m.height / bounds.height, closeTo(fit.scale, 1e-9));
        // 长轴铺满可画区域，短轴居中留白（letterbox）。
        if (bounds.width > bounds.height) {
          expect(m.width, closeTo(fit.area.width, 1e-6));
          expect(m.height, lessThan(fit.area.height));
          expect(
            m.top - fit.area.top,
            closeTo(fit.area.bottom - m.bottom, 1e-6),
          );
        } else {
          expect(m.height, closeTo(fit.area.height, 1e-6));
          expect(m.width, lessThan(fit.area.width));
          expect(
            m.left - fit.area.left,
            closeTo(fit.area.right - m.right, 1e-6),
          );
        }
      }
    });

    test('手算布局：scale=0.2、origin=(10,20)，包围盒中心落在区域中心', () {
      // 区域 160×100，包围盒 800×400 → scale=min(160/800,100/400)=0.2，
      // 内容 160×80 竖直居中 → origin=(10+(160-160)/2, 10+(100-80)/2)=(10,20)。
      final fit = computeFlowMinimapFit(
        worldBounds: const Rect.fromLTWH(0, 0, 800, 400),
        size: size,
        padding: pad,
      );
      expect(fit.scale, closeTo(0.2, 1e-12));
      expect(fit.origin, const Offset(10, 20));
      expect(worldPointToMinimap(fit, Offset.zero), const Offset(10, 20));
      expect(
        worldPointToMinimap(fit, const Offset(800, 400)),
        const Offset(170, 100),
      );
      // 不变式：bounds.center 永远映射到 area.center（居中语义）。
      expect(
        (worldPointToMinimap(fit, fit.bounds.center) - fit.area.center)
            .distance,
        lessThan(1e-9),
      );
    });

    test('退化输入不除零：空图 / 零尺寸 / 单节点都拿到有限正 scale', () {
      for (final bounds in [
        Rect.zero,
        const Rect.fromLTWH(700, 700, 0, 0),
        const Rect.fromLTWH(-40, -40, 0, 0),
        const Rect.fromLTWH(50, 50, 200, 112),
      ]) {
        final fit = computeFlowMinimapFit(
          worldBounds: bounds,
          size: size,
          padding: pad,
        );
        expect(fit.scale.isFinite, isTrue, reason: 'bounds=$bounds');
        expect(fit.scale, greaterThan(0), reason: 'bounds=$bounds');
        expect(fit.origin.isFinite, isTrue, reason: 'bounds=$bounds');
        final back = minimapPointToWorld(
          fit,
          worldPointToMinimap(fit, bounds.center),
        );
        expect((back - bounds.center).distance, lessThan(0.5));
      }
      // padding 比盒子还大时也不能出 NaN/负 scale。
      final tiny = computeFlowMinimapFit(
        worldBounds: const Rect.fromLTWH(0, 0, 500, 500),
        size: const Size(12, 8),
        padding: 30,
      );
      expect(tiny.scale.isFinite, isTrue);
      expect(tiny.scale, greaterThan(0));
      expect(tiny.area.width, greaterThan(0));
    });

    test('已知节点中心映射进它自己的小地图块', () {
      const pos = Offset(400, 200);
      final fit = computeFlowMinimapFit(
        worldBounds: const Rect.fromLTWH(0, 0, 800, 400),
        size: size,
        padding: pad,
      );
      final block = worldRectToMinimap(fit, nodeRect(pos));
      final center = worldPointToMinimap(fit, nodeRect(pos).center);
      expect(block.contains(center), isTrue);
      // 世界中心 (500,256) → (0.2*500+10, 0.2*256+20)
      expect((center - const Offset(110, 71.2)).distance, lessThan(1e-9));
    });
  });

  group('世界包围盒', () {
    test('跳过缺失节点，按折叠足迹 200×112 计入', () {
      final g = graphOf([talk('A'), option('B'), missing('M')]);
      final bounds = computeFlowMinimapBounds(
        graph: g,
        positions: const {'A': Offset(100, 100), 'B': Offset(300, 200)},
      );
      expect(bounds, const Rect.fromLTWH(100, 100, 400, 212));
      // 缺失节点哪怕在很远的位置也不该把包围盒撑大。
      expect(
        computeFlowMinimapBounds(
          graph: g,
          positions: const {
            'A': Offset(100, 100),
            'B': Offset(300, 200),
            'M': Offset(9000, 9000),
          },
        ),
        bounds,
      );
    });

    test('positions 缺项按原点处理；空图给 Rect.zero', () {
      expect(
        computeFlowMinimapBounds(
          graph: graphOf([talk('A')]),
          positions: const {},
        ),
        const Rect.fromLTWH(0, 0, kFlowNodeW, kFlowNodeH),
      );
      expect(
        computeFlowMinimapBounds(graph: graphOf(const []), positions: const {}),
        Rect.zero,
      );
    });

    test('并入当前视口矩形；canvasSize 未测量时不并入', () {
      final g = graphOf([talk('A'), option('B')]);
      const positions = {'A': Offset(0, 0), 'B': Offset(300, 200)};
      // worldRect = (-pan/scale, view/scale) = (200,100,400,300)
      const vp = FlowViewport(2, Offset(-400, -200));
      expect(
        computeFlowMinimapBounds(
          graph: g,
          positions: positions,
          viewport: vp,
          canvasSize: const Size(800, 600),
        ),
        const Rect.fromLTWH(0, 0, 600, 400),
      );
      // 宿主还没量到画布尺寸：只按节点算，别把 -pan/scale 那个远点拖进来。
      expect(
        computeFlowMinimapBounds(
          graph: g,
          positions: positions,
          viewport: vp,
          canvasSize: Size.zero,
        ),
        const Rect.fromLTWH(0, 0, 500, 312),
      );
    });
  });

  group('StoryFlowMinimap 组件', () {
    const nodePositions = {
      'A': Offset(100, 100),
      'B': Offset(400, 250),
      'C': Offset(700, 400),
    };
    const canvasSize = Size(900, 700);
    final threeNodes = graphOf([talk('A'), option('B'), talk('C')]);

    /// 与组件同一套输入重算 fit（只用来**瞄准**，断言的是手算已知的世界点）。
    FlowMinimapFit fitFor(FlowViewport vp) => computeFlowMinimapFit(
      worldBounds: computeFlowMinimapBounds(
        graph: threeNodes,
        positions: nodePositions,
        viewport: vp,
        canvasSize: canvasSize,
      ),
      size: size,
      padding: pad,
    );

    /// 返回小地图盒子的全局左上角，测试里一律用「左上角 + 本地点」下针。
    Future<Offset> pumpMinimap(
      WidgetTester tester, {
      required ValueListenable<FlowViewport> viewport,
      required List<Offset> jumps,
      FlowGraph? graph,
      Map<String, Offset>? positions,
      Size? canvas,
      int positionsVersion = 0,
    }) async {
      await tester.pumpWidget(
        fluent.FluentApp(
          debugShowCheckedModeBanner: false,
          theme: fluent.FluentThemeData(brightness: Brightness.dark),
          home: Scaffold(
            body: Center(
              child: StoryFlowMinimap(
                graph: graph ?? threeNodes,
                positions: positions ?? nodePositions,
                positionsVersion: positionsVersion,
                viewport: viewport,
                canvasSize: canvas ?? canvasSize,
                onJumpTo: jumps.add,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      return tester.getTopLeft(find.byType(StoryFlowMinimap));
    }

    testWidgets('点节点块中心 → 上报该节点世界中心，且不回写 viewport', (tester) async {
      final vp = ValueNotifier(const FlowViewport(1, Offset.zero));
      addTearDown(vp.dispose);
      final jumps = <Offset>[];
      final topLeft = await pumpMinimap(tester, viewport: vp, jumps: jumps);

      // 视口 (1,0) + 画布 900×700 ⇒ 包围盒 (0,0,900,700)、scale=1/7、
      // origin=(10+(160-900/7)/2, 10)；B 世界中心 (500,306) → 本地 (97.14,53.71)。
      final fit = fitFor(vp.value);
      expect(fit.scale, closeTo(1 / 7, 1e-12));
      expect(fit.origin.dx, closeTo(10 + (160 - 900 / 7) / 2, 1e-9));
      expect(fit.origin.dy, closeTo(10, 1e-9));
      final bCenter = nodeRect(nodePositions['B']!).center;
      final aim = worldPointToMinimap(fit, bCenter);
      expect(
        worldRectToMinimap(fit, nodeRect(nodePositions['B']!)).contains(aim),
        isTrue,
        reason: '瞄准点必须落在 B 的块里，否则等于没测命中',
      );

      await tester.tapAt(topLeft + aim);
      await tester.pumpAndSettle();
      expect(jumps, hasLength(1));
      expect((jumps.single - bCenter).distance, lessThan(2.0));
      // 只读视口：小地图不该反过来动画布。
      expect(vp.value, const FlowViewport(1, Offset.zero));
    });

    testWidgets('视口变化后重新拟合，同一世界点仍点得准', (tester) async {
      final vp = ValueNotifier(const FlowViewport(1, Offset.zero));
      addTearDown(vp.dispose);
      final jumps = <Offset>[];
      final topLeft = await pumpMinimap(tester, viewport: vp, jumps: jumps);
      final oldAim = worldPointToMinimap(
        fitFor(vp.value),
        nodeRect(nodePositions['A']!).center,
      );

      vp.value = const FlowViewport(0.5, Offset(-300, -120));
      await tester.pumpAndSettle();
      final aCenter = nodeRect(nodePositions['A']!).center;
      final aim = worldPointToMinimap(fitFor(vp.value), aCenter);
      expect((aim - oldAim).distance, greaterThan(2.0), reason: 'fit 没随视口重算');
      await tester.tapAt(topLeft + aim);
      await tester.pumpAndSettle();
      expect(jumps, hasLength(1));
      expect((jumps.single - aCenter).distance, lessThan(2.0));
    });

    testWidgets('拖过小地图持续上报，最后一次对应松开位置', (tester) async {
      final vp = ValueNotifier(const FlowViewport(1, Offset.zero));
      addTearDown(vp.dispose);
      final jumps = <Offset>[];
      final topLeft = await pumpMinimap(tester, viewport: vp, jumps: jumps);
      final fit = fitFor(vp.value);
      final from = worldPointToMinimap(fit, const Offset(200, 150));
      final to = worldPointToMinimap(fit, const Offset(760, 150));

      final g = await tester.startGesture(topLeft + from);
      await tester.pump();
      await g.moveTo(topLeft + from + const Offset(25, 0));
      await tester.pump();
      await g.moveTo(topLeft + to);
      await tester.pump();
      await g.up();
      await tester.pumpAndSettle();

      expect(jumps.length, greaterThan(1), reason: '拖过应当持续上报，不只是按下那一下');
      expect(
        (jumps.last - minimapPointToWorld(fit, to)).distance,
        lessThan(2.0),
        reason: '拖拽终点必须仍解析回同一个世界点',
      );
    });

    testWidgets('盒子外的点击不触发 onJumpTo', (tester) async {
      final vp = ValueNotifier(const FlowViewport(1, Offset.zero));
      addTearDown(vp.dispose);
      final jumps = <Offset>[];
      final topLeft = await pumpMinimap(tester, viewport: vp, jumps: jumps);
      // 盒子外左上角外 20px：事件根本不该命中小地图。
      await tester.tapAt(topLeft - const Offset(20, 20));
      await tester.pumpAndSettle();
      expect(jumps, isEmpty);
    });

    testWidgets('极端缩小 + 远平移：视口框被裁住且不抛异常', (tester) async {
      final vp = ValueNotifier(const FlowViewport(0.2, Offset(-8000, -6000)));
      addTearDown(vp.dispose);
      final jumps = <Offset>[];
      final topLeft = await pumpMinimap(tester, viewport: vp, jumps: jumps);

      final fit = fitFor(vp.value);
      final vpRect = vp.value.worldRect(canvasSize);
      // 包围盒恒含视口矩形（Rect.contains 是半开区间，共享边会假报 false，
      // 所以这里按边比较）。
      expect(
        fit.bounds.left <= vpRect.left &&
            fit.bounds.top <= vpRect.top &&
            fit.bounds.right >= vpRect.right &&
            fit.bounds.bottom >= vpRect.bottom,
        isTrue,
      );
      // 语义映射不因「只裁画的」而失真：区域中心仍解析回包围盒中心。
      await tester.tapAt(topLeft + fit.area.center);
      await tester.pumpAndSettle();
      expect(jumps, hasLength(1));
      expect(
        (jumps.single - fit.bounds.center).distance,
        lessThan(2.0),
        reason: '裁剪后的中心点击，反解仍应是未裁剪的世界中心',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('canvasSize 为空（宿主首帧未测量）也不崩', (tester) async {
      final vp = ValueNotifier(const FlowViewport(1, Offset.zero));
      addTearDown(vp.dispose);
      final jumps = <Offset>[];
      final topLeft = await pumpMinimap(
        tester,
        viewport: vp,
        jumps: jumps,
        graph: graphOf([talk('A')]),
        positions: const {'A': Offset(10, 10)},
        canvas: Size.zero,
      );
      expect(tester.takeException(), isNull);
      final center = nodeRect(const Offset(10, 10)).center;
      final fit = computeFlowMinimapFit(
        worldBounds: computeFlowMinimapBounds(
          graph: graphOf([talk('A')]),
          positions: const {'A': Offset(10, 10)},
          viewport: vp.value,
          canvasSize: Size.zero,
        ),
        size: size,
        padding: pad,
      );
      await tester.tapAt(topLeft + worldPointToMinimap(fit, center));
      await tester.pumpAndSettle();
      expect(jumps, hasLength(1));
      expect((jumps.single - center).distance, lessThan(2.0));
    });
  });

  group('D1：positions 原地改、身份不变，repaint 判定靠 positionsVersion', () {
    const vp = FlowViewport(1, Offset.zero);
    final g = graphOf([talk('A')]);
    const canvas = Size(900, 700);

    Future<Offset> pump(WidgetTester tester, {int version = 0}) async {
      final jumps = <Offset>[];
      await tester.pumpWidget(
        fluent.FluentApp(
          debugShowCheckedModeBanner: false,
          theme: fluent.FluentThemeData(brightness: Brightness.dark),
          home: Scaffold(
            body: Center(
              child: StoryFlowMinimap(
                graph: g,
                positions: const {'A': Offset(100, 100)},
                positionsVersion: version,
                viewport: ValueNotifier(vp),
                canvasSize: canvas,
                onJumpTo: jumps.add,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      return tester.getTopLeft(find.byType(StoryFlowMinimap));
    }

    testWidgets('pump 不同 version 的重建不抛异常（组件接线冒烟）', (tester) async {
      await pump(tester, version: 1);
      await pump(tester, version: 2);
      expect(tester.takeException(), isNull);
    });

    test('同 version 且视口/图/尺寸不变 → 不重绘', () {
      const fit = FlowMinimapFit(scale: 1, origin: Offset.zero, bounds: Rect.zero, area: Rect.zero);
      expect(
        flowMinimapNeedsRepaint(
          oldGraph: g,
          graph: g,
          oldPositionsVersion: 3,
          positionsVersion: 3,
          oldFit: fit,
          fit: fit,
          oldViewport: vp,
          viewport: vp,
          oldCanvasSize: canvas,
          canvasSize: canvas,
        ),
        isFalse,
      );
    });

    test('version 变化 → 必须重绘（拖拽时小地图节点块跟手）', () {
      const fit = FlowMinimapFit(scale: 1, origin: Offset.zero, bounds: Rect.zero, area: Rect.zero);
      expect(
        flowMinimapNeedsRepaint(
          oldGraph: g,
          graph: g,
          oldPositionsVersion: 3,
          positionsVersion: 4,
          oldFit: fit,
          fit: fit,
          oldViewport: vp,
          viewport: vp,
          oldCanvasSize: canvas,
          canvasSize: canvas,
        ),
        isTrue,
      );
    });

    test('同 version 但 fit/viewport 变化 → 仍需重绘（负向对照防写死）', () {
      expect(
        flowMinimapNeedsRepaint(
          oldGraph: g,
          graph: g,
          oldPositionsVersion: 3,
          positionsVersion: 3,
          oldFit: const FlowMinimapFit(scale: 1, origin: Offset.zero, bounds: Rect.zero, area: Rect.zero),
          fit: const FlowMinimapFit(scale: 1, origin: Offset(10, 10), bounds: Rect.zero, area: Rect.zero),
          oldViewport: vp,
          viewport: const FlowViewport(2, Offset.zero),
          oldCanvasSize: canvas,
          canvasSize: canvas,
        ),
        isTrue,
      );
    });
  });
}
