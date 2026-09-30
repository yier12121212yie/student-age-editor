// RelationGraphView 渲染回归（MockClient 桩 /api/graph/relations）：
//   * 默认聚焦第一人且只显示其相连边（边爆炸对策）；
//   * 点来源徽标回调 onOpenSource(sourceCfg, sourceId)；
//   * 等级色非法 → 回退 tintInfo 不抛；等级过滤器收敛边；
//   * 顶部人物搜索下拉可切换聚焦对象。
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:student_age_editor/core/api_client.dart';
import 'package:student_age_editor/features/graph/relation_graph_view.dart';

final _relations = <String, dynamic>{
  'nodes': [
    {'id': '101', 'name': '小明', 'gender': 1, 'tex': null},
    {'id': '202', 'name': '小红', 'gender': 2, 'tex': null},
  ],
  'levels': [
    {
      'id': '520', 'name': '恋人', 'color': '#FF3B30', 'condition': 90,
      'upgrade': null, 'upgradeCost': 0, 'socialCapacity': 1,
      'iconRelation': 'icon_lover',
    },
    {
      'id': '521', 'name': '青梅', 'color': 'bad-color', 'condition': 60,
      'upgrade': '520', 'upgradeCost': 500, 'socialCapacity': 2,
      'iconRelation': 'icon_child',
    },
  ],
  'edges': [
    {
      'role': '101', 'kind': 'favorGain', 'value': 10, 'relation': null,
      'code': '[20, 1, 101, 10]', 'sourceCfg': 'TalkCfg',
      'sourceId': '32010101', 'sourceName': '台词前二十四字',
    },
    {
      'role': '202', 'kind': 'favorGain', 'value': 5, 'relation': null,
      'code': '[20, 1, 202, 5]', 'sourceCfg': 'TalkCfg',
      'sourceId': '32010109', 'sourceName': '争吵',
    },
    {
      'role': '101', 'kind': 'relationSet', 'value': 0, 'relation': '521',
      'code': '[7, -1, 521]', 'sourceCfg': 'EvtCfg',
      'sourceId': '1200001', 'sourceName': '成为青梅竹马',
    },
    {
      // role 是别人，但 code 里出现 101 → 也「与所选人相连」，另一端解析为小红。
      'role': '202', 'kind': 'favorGain', 'value': 7, 'relation': null,
      'code': '[20, 1, 101, 7]', 'sourceCfg': 'TalkCfg',
      'sourceId': '32010110', 'sourceName': '给小明的信',
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
      if (req.url.path == '/api/graph/relations') return jsonResp(_relations);
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
      home: Scaffold(body: RelationGraphView(onOpenSource: onOpen)),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('默认聚焦第一人且只显示其边', (tester) async {
    await pumpView(tester);
    expect(tester.takeException(), isNull);
    // 进入视图只打一次端点（缓存于 State）。
    expect(
        requests.where((u) => u.path == '/api/graph/relations').length, 1);
    // 中央 focus 卡 = 第一位人物。
    expect(find.byKey(const ValueKey('rg-focus-card')), findsOneWidget);
    expect(find.text('小明'), findsWidgets);
    // 相连边 = 索引 0/2（role=101）+ 索引 3（code 含 101）；
    // 仅属于 202 且 code 不含 101 的 32010109 不显示（边爆炸对策）。
    expect(find.byKey(const ValueKey('rg-badge-TalkCfg-32010101')), findsOneWidget);
    expect(find.byKey(const ValueKey('rg-badge-EvtCfg-1200001')), findsOneWidget);
    expect(
        find.byKey(const ValueKey('rg-badge-TalkCfg-32010110')), findsOneWidget);
    expect(find.byKey(const ValueKey('rg-badge-TalkCfg-32010109')), findsNothing);
    expect(find.text('好感+10'), findsOneWidget);
    expect(find.text('好感+7'), findsOneWidget);
    // 32010110 的另一端解析为小红（role=202），卫星卡带其名字。
    expect(find.text('小红'), findsWidgets);
    expect(find.text('设为关系:青梅'), findsOneWidget);
    expect(find.textContaining('争吵'), findsNothing);
    // 侧栏两张图与来源行。
    expect(find.text('关系等级阶梯'), findsOneWidget);
    expect(find.text('关联计数（按类型）'), findsOneWidget);
    expect(find.text('TalkCfg·台词前二十四字'), findsOneWidget);
  });

  testWidgets('点来源徽标 → onOpenSource(sourceCfg, sourceId)', (tester) async {
    (String, String)? opened;
    await pumpView(tester, onOpen: (c, i) => opened = (c, i));

    await tester.tap(
        find.byKey(const ValueKey('rg-badge-TalkCfg-32010101')));
    await tester.pump();
    expect(opened, ('TalkCfg', '32010101'));

    await tester.tap(find.byKey(const ValueKey('rg-badge-EvtCfg-1200001')));
    await tester.pump();
    expect(opened, ('EvtCfg', '1200001'));
  });

  testWidgets('等级色非法回退渲染不抛；等级过滤器收敛边', (tester) async {
    await pumpView(tester);
    // 等级 521 color 非法 → 回退 tintInfo（非法值本身已由 models 单测钉死），
    // 徽章照常渲染。
    expect(find.text('设为关系:青梅'), findsOneWidget);

    // 只勾「恋人」(520)：带 relation=521 的边被滤掉；relation=null 的好感边恒通过。
    await tester.tap(find.text('恋人'));
    await tester.pumpAndSettle();
    expect(find.text('好感+10'), findsOneWidget);
    expect(find.text('设为关系:青梅'), findsNothing);

    // 恢复「全部」。
    await tester.tap(find.text('全部'));
    await tester.pumpAndSettle();
    expect(find.text('设为关系:青梅'), findsOneWidget);
  });

  testWidgets('搜索下拉切换聚焦人物 → 边集合随聚焦切换', (tester) async {
    await pumpView(tester);
    // 顶栏选择按钮（树序在 focus 卡之前）。
    await tester.tap(find.text('小明').first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('rg-search')), '红');
    await tester.pumpAndSettle();
    // 画布徽标上也有「小红」，限定到搜索结果列表项。
    await tester.tap(find.widgetWithText(ListTile, '小红'));
    await tester.pumpAndSettle();

    // 聚焦 202：两条 role=202 的边在，focus=101 的边消失。
    expect(find.byKey(const ValueKey('rg-badge-TalkCfg-32010109')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('rg-badge-TalkCfg-32010110')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('rg-badge-TalkCfg-32010101')),
        findsNothing);
    expect(find.byKey(const ValueKey('rg-badge-EvtCfg-1200001')), findsNothing);
    expect(find.textContaining('争吵'), findsOneWidget);
    expect(find.text('好感+5'), findsOneWidget);
  });

  testWidgets('刷新按钮重拉端点', (tester) async {
    await pumpView(tester);
    expect(requests.where((u) => u.path == '/api/graph/relations').length, 1);
    await tester.tap(find.byTooltip('刷新'));
    await tester.pumpAndSettle();
    expect(requests.where((u) => u.path == '/api/graph/relations').length, 2);
  });

  testWidgets('后端 500：错误态 + 重试，不抛', (tester) async {
    ApiClient.instance.client = MockClient(
        (req) async => http.Response('{"error":"boom"}', 500));
    await pumpView(tester);
    expect(tester.takeException(), isNull);
    expect(find.textContaining('加载失败'), findsOneWidget);
  });
}
