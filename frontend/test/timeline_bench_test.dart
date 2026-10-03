/// 事件时间轴画布性能基准（「降 GPU 负担」阶段 1 准出）。
///
/// 证据分工同 story_flow_bench_test.dart：**墙钟时间只报告不断言**（机器
/// 相关，断言必 flaky），**重建计数才断言**（确定性，跨机器可比）。
///
/// 场景：40 回合（世界宽 40 × kTlRoundW(46) = 1840px）、122 条上轴条目，
/// 视口 1400×900。改造前（阶段 0 基线）：拖动每帧 `setState` → 宿主整树
/// 重建（顶栏/底栏/详情面板 + 世界层全量子项，无视口裁剪）。
///
/// ── 墙钟对照（同机同 harness，本文件 spread 场景平移 30 帧，debug 模式）──
///   改造前：中位 **23.83 ms/帧**（min 18.45 / max 43.20）
///   改造后：中位 **11.00 ms/帧**（min 7.28 / max 25.11）· 约 **2.2×**
///   ⚠ 墙钟只报告不断言（机器相关）；下面的计数才是准出。
///
/// ── 计数准出（改造后读数）────────────────────────────────────
///   H1 平移 30 帧（20 回合 / 920px 世界，全可见）：
///     宿主 build **0** · 世界层 build 30 · 子项新建 **0**
///   H2 裁剪（40 回合 spread）：平移帧内跳过子项 2232 次、仅新建 28 次
///     （视口外条目一次都不构建，进入视口才建）
///   H3 缩放 6 档：宿主 build **0** · 世界层 build 6（刻度档切换重编译）
library;

import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:student_age_editor/core/api_client.dart';
import 'package:student_age_editor/features/graph/timeline_view.dart';

const int _kRounds = 40;
const int _kItems = 120;
const int _kPanFrames = 30;
const Offset _kPanStep = Offset(-5, 0);

/// 合成时间轴。[spread] 为真时把条目铺满整轴（裁剪用），否则聚在前 10
/// 回合；[rounds] 控制世界宽度（平移用 20 回合 = 920px < 视口宽，拖动不会
/// 把任何新子项带进视口，可见集合恒定）。
Map<String, dynamic> synthTimeline({bool spread = false, int rounds = _kRounds}) {
  final roundRows = <Map<String, dynamic>>[
    for (var i = 1; i <= rounds; i++)
      {
        'round': i,
        'year': 1 + (i - 1) ~/ 4,
        'season': 1 + (i - 1) % 4,
        'seasonName': 'S$i',
        'months': const [3, 4, 5],
        'holiday': i % 8 == 0,
      },
  ];
  final items = <Map<String, dynamic>>[
    for (var k = 0; k < _kItems; k++)
      {
        'cfg': k.isEven ? 'EvtCfg' : 'TalkCfg',
        'id': '${9000000 + k}',
        'name': '条目 $k',
        'mapId': '3',
        'npc': '${100 + k % 5}',
        'timeKinds': const ['round'],
        'spans': [
          {
            'from': spread ? 1 + (k * 7) % 36 : 1 + (k % 10),
            'to': spread ? 2 + (k * 7) % 36 : 2 + (k % 10),
          },
        ],
        'codes': ['[1,0,${k % 9}]'],
      },
  ];
  if (spread) {
    // 裁剪锚点：from=2 → 世界 x≈46（初始视口内）；from=39 → x≈1748（1400
    // 宽的初始视口看不到，且平移 300px 后仍在更右侧）。
    for (final from in const [2, 39]) {
      items.add({
        'cfg': 'EvtCfg',
        'id': from == 2 ? '9900001' : '9900002',
        'name': '锚点 $from',
        'mapId': '3',
        'npc': '101',
        'timeKinds': const ['round'],
        'spans': [
          {'from': from, 'to': from + 1},
        ],
        'codes': const ['[1,0,0]'],
      });
    }
  }
  return {'rounds': roundRows, 'items': items};
}

double median(List<double> xs) {
  final s = [...xs]..sort();
  final m = s.length ~/ 2;
  return s.length.isOdd ? s[m] : (s[m - 1] + s[m]) / 2;
}

String ms(double v) => v.toStringAsFixed(2);

void report(String line) => debugPrint('[bench] $line');

Future<void> pumpTimeline(WidgetTester tester, Map<String, dynamic> data) async {
  ApiClient.instance.client = MockClient((req) async {
    if (req.url.path == '/api/graph/timeline') {
      return http.Response(jsonEncode(data), 200,
          headers: {'content-type': 'application/json'});
    }
    return http.Response('{"error":"unexpected"}', 500);
  });
  addTearDown(() => ApiClient.instance.client = http.Client());
  tester.view.physicalSize = const Size(1400, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(const MaterialApp(home: Scaffold(body: TimelineView())));
  await tester.pumpAndSettle();
}

/// 一次平移拖拽的测量结果：每帧墙钟 + 三类重建计数增量 + 视口位移证据。
typedef BenchPan = ({
  List<double> frameMs,
  int hostBuilds,
  int worldBuilds,
  int childBuilds,
  int culled,
  Offset panDelta,
});

Future<BenchPan> benchPan(WidgetTester tester,
    {int frames = _kPanFrames, Offset step = _kPanStep}) async {
  final host0 = debugTimelineHostBuilds;
  final world0 = debugTimelineWorldBuilds;
  final child0 = debugTimelineChildBuilds;
  final culled0 = debugTimelineCulledChildren;
  final vp = tester
      .state<TimelineViewState>(find.byType(TimelineView))
      .viewportListenable;
  final pan0 = vp.value.pan;
  final center = tester.getCenter(find.byType(TimelineView));
  final g = await tester.startGesture(center);
  await tester.pump();
  var pos = center;
  final frameMs = <double>[];
  for (var i = 0; i < frames; i++) {
    pos += step;
    final sw = Stopwatch()..start();
    await g.moveTo(pos);
    await tester.pump();
    sw.stop();
    frameMs.add(sw.elapsedMicroseconds / 1000);
  }
  await g.up();
  await tester.pump();
  // 视口平移量是「指针事件真的送达画布」的证据（裁剪会让某些条目离屏，
  // 不能拿条目位置当锚点）。
  return (
    frameMs: frameMs,
    hostBuilds: debugTimelineHostBuilds - host0,
    worldBuilds: debugTimelineWorldBuilds - world0,
    childBuilds: debugTimelineChildBuilds - child0,
    culled: debugTimelineCulledChildren - culled0,
    panDelta: vp.value.pan - pan0,
  );
}

void main() {
  testWidgets('平移一帧：宿主与世界层外的控件零重建，子项实例全复用', (tester) async {
    // 20 回合 = 920px 世界宽 < 1400px 视口：全部内容常驻可见，
    // 平移只移动画面、不把新子项带进视口，子项新建数该严格为 0。
    await pumpTimeline(tester, synthTimeline(rounds: 20));

    // 初始构建后拍平基线，只量拖拽帧。
    final r = await benchPan(tester);

    final perFrame = r.hostBuilds / _kPanFrames;
    report('H1 平移 $_kPanFrames 帧 · 中位帧耗时 : ${ms(median(r.frameMs))} ms');
    report('   宿主 build / 帧 : ${perFrame.toStringAsFixed(1)}'
        ' · 世界层 build / 帧 : ${(r.worldBuilds / _kPanFrames).toStringAsFixed(1)}'
        ' · 子项新建 / 帧 : ${(r.childBuilds / _kPanFrames).toStringAsFixed(1)}');

    expect(r.panDelta.dx, lessThan(-100),
        reason: '指针事件没送达画布：视口平移量为 ${r.panDelta.dx}');
    expect(r.worldBuilds, greaterThan(0), reason: '世界层没有跟随视口重建');
    // 准出：平移只换视口 notifier，宿主（顶栏/底栏/详情面板）不重建；
    // 可见集合不变 → 子项一次都不新建（identical 实例短路）。
    expect(r.hostBuilds, equals(0),
        reason: '平移触发了宿主 build：又在拖动路径上 setState 了');
    expect(r.childBuilds, equals(0),
        reason: '平移帧仍新建了世界层子项：实例缓存 / 视口不进签名未生效');
  });

  testWidgets('视口裁剪：视口外条目一次都不构建，平移进出视口', (tester) async {
    await pumpTimeline(tester, synthTimeline(spread: true));

    const nearKey = ValueKey('tl-item-EvtCfg-9900001');
    const farKey = ValueKey('tl-item-EvtCfg-9900002');
    expect(find.byKey(nearKey), findsOneWidget);
    expect(find.byKey(farKey), findsNothing,
        reason: '世界 x≈1748 的条目不该出现在 1400px 宽的初始视口里');

    // 平移 1350px：远端条目进入视口，近端条目（x≈46）离开。
    final r = await benchPan(tester, step: const Offset(-45, 0));
    report('H2 裁剪：平移帧内跳过子项 ${r.culled} 次 · 新建 ${r.childBuilds} 次');
    expect(r.culled, greaterThan(0), reason: '没有任何子项被裁剪，裁剪逻辑没生效');
    expect(find.byKey(farKey), findsOneWidget, reason: '平移后远端条目应进入视口');
    expect(find.byKey(nearKey), findsNothing, reason: '平移后近端条目应离开视口');
  });

  testWidgets('缩放：只重编译世界层，宿主不重建', (tester) async {
    await pumpTimeline(tester, synthTimeline());

    final host0 = debugTimelineHostBuilds;
    final world0 = debugTimelineWorldBuilds;
    final center = tester.getCenter(find.byType(TimelineView));
    // 放大到 ≥60px/回合：刻度档从 season 切到 full（世界层该重编译），
    // 但宿主（顶栏/底栏）不应跟着重建。
    for (var i = 0; i < 6; i++) {
      await tester.sendEventToBinding(
        PointerScrollEvent(position: center, scrollDelta: const Offset(0, -120)),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();

    report('H3 缩放 6 档：宿主 build ${debugTimelineHostBuilds - host0} 次'
        ' · 世界层 build ${debugTimelineWorldBuilds - world0} 次');
    expect(debugTimelineWorldBuilds - world0, greaterThan(0));
    expect(debugTimelineHostBuilds - host0, equals(0),
        reason: '缩放触发了宿主 build：又走 setState 了');
  });
}
