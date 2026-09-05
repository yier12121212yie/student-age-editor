// 剧情图连线端到端回归：真实 workspace（fitView 视口 + 语义校验链路）里
// 从对白 A 的输出端口拖线到对白 B，应写回 nextTalk 并出现连线。
import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:student_age_editor/core/api_client.dart';
import 'package:student_age_editor/core/models.dart';
import 'package:student_age_editor/features/story/story_flow_graph.dart';
import 'package:student_age_editor/features/story/story_flow_workspace.dart';

void main() {
  const aId = '1000001001';
  const bId = '1000001002';
  final putBodies = <Map<String, dynamic>>[];

  setUp(() {
    putBodies.clear();
    ApiClient.instance.client = MockClient((request) async {
      final path = request.url.path;
      if (request.method == 'PUT' && path.startsWith('/api/cfg/')) {
        putBodies.add({
          'cfg': path.split('/').last,
          'body': jsonDecode(request.body) as Map<String, dynamic>,
        });
        return http.Response(jsonEncode({'mtime_ns': 12346}), 200,
            headers: {'content-type': 'application/json'});
      }
      if (path.startsWith('/api/cfg/')) {
        final name = path.split('/').last;
        final data = switch (name) {
          'EvtCfg' => {
              '1000001': {
                'id': 1000001,
                'title': '事件甲',
                'type': 0,
                'talkId': [aId],
              },
            },
          'TalkCfg' => {
              aId: {'id': aId, 'content': 'a', 'nextTalk': []},
              bId: {'id': bId, 'content': 'b', 'nextTalk': []},
            },
          _ => <String, dynamic>{},
        };
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
        return http.Response('{"flow_cards": []}', 200,
            headers: {'content-type': 'application/json'});
      }
      if (path == '/api/tools/read') {
        return http.Response('{"error": "not a file"}', 400);
      }
      return http.Response('{"error": "unexpected $path"}', 500);
    });
  });

  tearDown(() {
    ApiClient.instance.client = http.Client();
  });

  testWidgets('workspace 内拖线写回 nextTalk', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final state = AppState();
    state.modName = 'A';
    state.modRoot = r'C:\mods\A';

    await tester.pumpWidget(fluent.FluentApp(
      home: Scaffold(
        body: StoryFlowWorkspace(
          state: state,
          onPreview: (_) {},
          onOpenPlugins: () {},
          onOpenSettings: () {},
        ),
      ),
    ));
    await tester.pumpAndSettle();

    // 两张节点卡片都已挂载（ValueKey=节点 id）。
    final cardA = tester.getRect(find.byKey(const ValueKey(aId)).first);
    final cardB = tester.getRect(find.byKey(const ValueKey(bId)).first);
    final vp = tester
        .state<StoryFlowGraphState>(find.byType(StoryFlowGraph))
        .viewportListenable
        .value;
    // 端口世界偏移 (W/3, H)；卡片 rect 已含视口变换，偏移只需乘 scale。
    final from = cardA.topLeft + Offset(200 / 3 * vp.scale, 112 * vp.scale);
    final to = cardB.topCenter;
    // debugPrint 帮助诊断：卡与视口状态
    // ignore: avoid_print
    print('vp=$vp cardA=$cardA cardB=$cardB from=$from to=$to');

    final g = await tester.startGesture(from);
    await g.moveTo(to);
    await g.up();
    await tester.pumpAndSettle();

    // 验证图缓存已刷新，画布上的图对象包含新连线
    final graph =
        tester.widget<StoryFlowGraph>(find.byType(StoryFlowGraph)).graph;
    expect(
      graph.edges.any((e) => e.from == aId && e.to == bId),
      isTrue,
      reason: '连线未刷新至画布图对象：_bumpGraph 链路失效',
    );

    // 连线写回了舞台数据：脏标记应亮起（按钮从「已保存」变「保存修改」），
    // 触发保存后断言 PUT 补丁把 B 写进 A 的 nextTalk。
    expect(find.text('保存修改'), findsOneWidget,
        reason: '拖线后未标脏：onAddEdge 链路没生效');
    await tester.tap(find.text('保存修改'));
    await tester.pumpAndSettle();
    final talkPut = putBodies.where((p) => p['cfg'] == 'TalkCfg').toList();
    expect(talkPut, isNotEmpty, reason: '拖线后保存应发出 TalkCfg 补丁');
    final setPatch = (talkPut.last['body']['patch']
        as Map)['set'] as Map<String, dynamic>;
    expect(
      setPatch[aId],
      isNotNull,
      reason: '连线未写回：拖线→松手→保存链路断了',
    );
    final nextTalk = (setPatch[aId] as Map)['nextTalk'];
    expect(
      nextTalk.map((e) => e.toString()).toList(),
      contains(bId),
      reason: 'nextTalk 应包含新连线的目标 B',
    );

    // 消耗 displayInfoBar 留下的自动关闭定时器
    await tester.pump(const Duration(seconds: 5));
  });
}
