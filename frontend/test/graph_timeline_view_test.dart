// TimelineView 渲染回归（MockClient 桩 /api/graph/timeline）：
//   * 年/季色带 + holiday 条纹段渲染；
//   * spans.to=null 的条目画到轴末（矩形右缘 == 轴末端）；
//   * 重叠条目分泳道（y 不同）；
//   * 点条目出详情面板（name/codes/timeKinds/完整 spans），「打开该事件」回调；
//   * npc/mapId chips 过滤；special 条目不上轴、进底部折叠列表。
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:student_age_editor/core/api_client.dart';
import 'package:student_age_editor/features/graph/timeline_view.dart';

// 4 回合（1 年 3 季，round 3 holiday）。世界轴宽 = 4 * kTlRoundW(46) = 184；
// 初始视口 pan=(12,8)、scale=1 → 屏幕右缘可预测：12 + 184 - 1 = 195。
final _timeline = <String, dynamic>{
  'rounds': [
    {'round': 1, 'year': 1, 'season': 1, 'seasonName': '小一 春', 'months': [3, 4, 5], 'holiday': false},
    {'round': 2, 'year': 1, 'season': 2, 'seasonName': '小一 夏', 'months': [6, 7, 8], 'holiday': false},
    {'round': 3, 'year': 1, 'season': 2, 'seasonName': '小一 夏', 'months': [7, 8, 9], 'holiday': true},
    {'round': 4, 'year': 2, 'season': 3, 'seasonName': '小二 秋', 'months': [9, 10, 11], 'holiday': false},
  ],
  'items': [
    {
      'cfg': 'EvtCfg', 'id': '1200001', 'name': '开学礼', 'mapId': '3',
      'npc': '101', 'timeKinds': ['round'],
      'spans': [{'from': 1, 'to': 2}], 'codes': ['[2,0,1]'],
    },
    {
      'cfg': 'EvtCfg', 'id': '1200002', 'name': '贯穿事件', 'mapId': '3',
      'npc': '202', 'timeKinds': ['round'],
      'spans': [{'from': 2, 'to': null}], 'codes': ['[2,0,2]'],
    },
    {
      'cfg': 'TalkCfg', 'id': '300', 'name': '特殊约束', 'mapId': '',
      'npc': '', 'timeKinds': ['special'], 'spans': [], 'codes': ['[9,0]'],
    },
  ],
};

void main() {
  final requests = <Uri>[];

  http.Response jsonResp(Object body) => http.Response(
      jsonEncode(body), 200,
      headers: {'content-type': 'application/json'});

  setUp(() {
    requests.clear();
    ApiClient.instance.client = MockClient((req) async {
      requests.add(req.url);
      if (req.url.path == '/api/graph/timeline') return jsonResp(_timeline);
      return http.Response('{"error":"unexpected ${req.url.path}"}', 500);
    });
  });

  tearDown(() {
    ApiClient.instance.client = http.Client();
  });

  Future<void> pumpView(WidgetTester tester,
      {void Function(String, String)? onOpen}) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: TimelineView(onOpenSource: onOpen)),
    ));
    await tester.pumpAndSettle();
  }

  const openEndKey = ValueKey('tl-item-EvtCfg-1200002');
  const boundedKey = ValueKey('tl-item-EvtCfg-1200001');

  testWidgets('年/季色带 + holiday 条纹段渲染', (tester) async {
    await pumpView(tester);
    expect(tester.takeException(), isNull);
    expect(requests.where((u) => u.path == '/api/graph/timeline').length, 1);
    // 每回合一条季节色带。
    for (final r in const [1, 2, 3, 4]) {
      expect(find.byKey(ValueKey('tl-band-$r')), findsOneWidget,
          reason: '回合 $r 色带');
    }
    // holiday=true 的 round 3 有斜纹层；其余没有。
    expect(find.byKey(const ValueKey('tl-holiday-3')), findsOneWidget);
    expect(find.byKey(const ValueKey('tl-holiday-1')), findsNothing);
    // 年标签按年分段各一枚。
    expect(find.byKey(const ValueKey('tl-year-1')), findsOneWidget);
    expect(find.text('第1年'), findsOneWidget);
    expect(find.text('第2年'), findsOneWidget);
    // 顶栏计数：special 不进轴 → 2 条上轴。
    expect(find.text('共 2 条上轴'), findsOneWidget);
  });

  testWidgets('spans.to=null 画到轴末；重叠条目分泳道', (tester) async {
    await pumpView(tester);
    // 初始视口确定：pan=(12,8)、scale=1，轴宽 184。
    final openEnd = tester.getRect(openEndKey.finder);
    final bounded = tester.getRect(boundedKey.finder);
    // to=null 的条目延伸到轴末（右缘 = 12 + 184 - 1）。
    expect(openEnd.right, closeTo(12 + 184 - 1, 1.0),
        reason: 'to=null 应画到轴末端');
    // 有界条目（1~2 回合）明显短于轴末。
    expect(bounded.right, lessThan(openEnd.right - 80));
    // 两条时间区间重叠 → 必在两条不同泳道（y 不同）。
    expect(openEnd.top, isNot(bounded.top));
    expect(openEnd.top, greaterThan(bounded.top),
        reason: '后开始者落更下面的泳道');
  });

  testWidgets('点条目 → 详情面板（codes/timeKinds/spans）→ 打开该事件',
      (tester) async {
    (String, String)? opened;
    await pumpView(tester, onOpen: (c, i) => opened = (c, i));

    await tester.tap(openEndKey.finder);
    await tester.pumpAndSettle();
    expect(find.text('贯穿事件'), findsWidgets); // 标题 + 色带名
    expect(find.text('第2回合起'), findsOneWidget); // to=null 的完整 span 文案
    expect(find.text('[2,0,2]'), findsOneWidget);
    expect(find.text('round'), findsWidgets); // timeKinds
    expect(find.text('EvtCfg · #1200002'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('tl-open-source')));
    await tester.pump();
    expect(opened, ('EvtCfg', '1200002'));

    // 收起详情。
    await tester.tap(find.byKey(const ValueKey('tl-detail-close')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('tl-open-source')), findsNothing);
  });

  testWidgets('special 条目不上轴，进底部折叠列表', (tester) async {
    await pumpView(tester);
    expect(find.byKey(const ValueKey('tl-item-TalkCfg-300')), findsNothing);
    expect(find.byKey(const ValueKey('tl-special-summary')), findsOneWidget);
    expect(find.text('无法映射到回合的特殊时间约束（1）'), findsOneWidget);
    // 折叠态不展开明细。
    expect(find.byKey(const ValueKey('tl-special-TalkCfg-300')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('tl-special-toggle')));
    await tester.pumpAndSettle();
    expect(find.textContaining('特殊约束'), findsOneWidget);
    expect(find.textContaining('[special]'), findsOneWidget);
  });

  testWidgets('npc chip 过滤只留该人物的条目', (tester) async {
    await pumpView(tester);
    await tester.tap(find.byKey(const ValueKey('tl-chip-npc-101')));
    await tester.pumpAndSettle();
    expect(boundedKey.finder, findsOneWidget);
    expect(openEndKey.finder, findsNothing);
    expect(find.text('共 1 条上轴'), findsOneWidget);
    // 清除过滤恢复。
    await tester.tap(find.byKey(const ValueKey('tl-chip-clear')));
    await tester.pumpAndSettle();
    expect(find.text('共 2 条上轴'), findsOneWidget);
  });

  testWidgets('空数据兜底：无 rounds 时画提示不抛', (tester) async {
    ApiClient.instance.client = MockClient(
        (req) async => jsonResp({'rounds': [], 'items': []}));
    await pumpView(tester);
    expect(tester.takeException(), isNull);
    expect(find.textContaining('没有时间轴数据'), findsOneWidget);
  });
}

extension on ValueKey<String> {
  /// key → finder 的糖：让上面的常量 key 可复用。
  Finder get finder => find.byKey(this);
}
