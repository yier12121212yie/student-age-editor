// 剧情图工作区外部 Mod 切换回归：模组页 / AI 面板的 setMod 不经过
// _switchMod，此前保活的画布仍持旧 Mod 全表缓存，点保存会把旧数据写进
// 新 Mod。修复后工作区监听 AppState，root 变化即自动重载数据。
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:student_age_editor/core/api_client.dart';
import 'package:student_age_editor/core/models.dart';
import 'package:student_age_editor/features/story/story_flow_workspace.dart';

void main() {
  late AppState state;
  // 模拟后端“当前选中 mod”：/api/cfg 只反映它的表
  late String backendMod;

  Map<String, dynamic> evtCfgFor(String mod) => switch (mod) {
        'A' => {'1000001': {'id': 1000001, 'title': '事件甲'}},
        _ => {'7000001': {'id': 7000001, 'title': '事件乙'}},
      };

  setUp(() {
    state = AppState();
    state.modName = 'A';
    state.modRoot = r'C:\mods\A';
    backendMod = 'A';
    ApiClient.instance.client = MockClient((request) async {
      final path = request.url.path;
      if (path.startsWith('/api/cfg/')) {
        final name = path.split('/').last;
        final data = name == 'EvtCfg' ? evtCfgFor(backendMod) : <String, dynamic>{};
        return http.Response(
            jsonEncode({'cfg': name, 'data': data, 'keys': data.keys.toList(),
              'exists': true, 'mtime_ns': 12345}),
            200,
            headers: {'content-type': 'application/json'});
      }
      if (path == '/api/plugins/ui/flow_cards') {
        return http.Response('{"flow_cards": []}', 200,
            headers: {'content-type': 'application/json'});
      }
      if (path == '/api/tools/read') {
        // 文件不存在（400 not a file）→ 合法空布局
        return http.Response('{"error": "not a file"}', 400,
            headers: {'content-type': 'application/json'});
      }
      return http.Response('{"error": "unexpected $path"}', 500,
          headers: {'content-type': 'application/json'});
    });
  });

  tearDown(() {
    ApiClient.instance.client = http.Client();
  });

  /// displayInfoBar：250ms 延迟弹出 + 3s 自动收起，两个都是纯 Timer，
  /// pumpAndSettle 不等它们。逐段推进假时间，避免测试结束残留 pending timer。
  Future<void> drain(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 400)); // 弹出延时
    await tester.pumpAndSettle(); // 弹出动画
    await tester.pump(const Duration(seconds: 4)); // 自动收起
    await tester.pumpAndSettle(); // 收起动画
  }

  Future<void> mount(WidgetTester tester) async {
    await tester.pumpWidget(fluent.FluentApp(
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
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('外部 setMod 后画布自动重载为新 Mod 的数据', (tester) async {
    await mount(tester);
    expect(find.textContaining('1000001'), findsWidgets,
        reason: '初始应显示 A 的事件');

    // 模拟模组页链路：先切后端选中，再 AppState.setMod（不经过画布 chip）
    backendMod = 'B';
    state.setMod('B', r'C:\mods\B');
    await drain(tester);

    expect(find.textContaining('7000001'), findsWidgets,
        reason: '外部切换后画布必须跟随重载，而非继续展示 A 的陈旧数据');
    expect(find.textContaining('1000001'), findsNothing);
  });
}
