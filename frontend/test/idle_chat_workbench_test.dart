// 闲聊工作台（导演布局「闲聊」专属界面）冒烟测试：三栏渲染、线性对白链、
// 添加对白、条件打开积木库、窄窗不溢出、导演主页卡片进入。
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_age_editor/core/api_client.dart';
import 'package:student_age_editor/core/models.dart';
import 'package:student_age_editor/core/plugin_state.dart';
import 'package:student_age_editor/core/ui_mode.dart';
import 'package:student_age_editor/features/chats/idle_chat_workbench.dart';
import 'package:student_age_editor/features/shell/director_shell.dart';
import 'package:student_age_editor/features/shell/shell_state.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ApiClient.instance.client = MockClient((req) async {
      final path = req.url.path;
      if (path.startsWith('/api/cfg/')) {
        final cfg = path.substring('/api/cfg/'.length);
        Map<String, dynamic> data;
        switch (cfg) {
          case 'InteractCfg':
            data = {
              '1': {
                'id': 1,
                'npc': 10,
                'name': '测试人物',
                'text': '课间闲聊',
                'map': [101],
                'talkId': 1001,
                'cond': <dynamic>[],
                'effect': <dynamic>[],
              },
            };
            break;
          case 'TalkCfg':
            data = {
              '1001': {
                'id': 1001,
                'content': '嗨，早啊',
                'roleIds': [10],
                'nextTalk': [1002],
                'nextTalk2': <dynamic>[],
              },
              '1002': {
                'id': 1002,
                'content': '早呀',
                'roleIds': [0],
                'nextTalk': <dynamic>[],
                'nextTalk2': <dynamic>[],
              },
            };
            break;
          default:
            data = {};
        }
        return http.Response(
          jsonEncode({'data': data, 'exists': true, 'mtime_ns': 1}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (path == '/api/effect_suggest') {
        return http.Response(
          jsonEncode({
            'items': [
              {
                'code': '[1, 1, V]',
                'desc': '年龄 >= V',
                'raw_code': '[1, 1, V]',
                'slots': [
                  {'kind': 'number', 'name': 'V', 'count': 1}
                ],
              },
            ],
            'mode': 'condition',
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (path == '/api/effect/parse') {
        final body = jsonDecode(req.body) as Map;
        return http.Response(
          jsonEncode({
            'ok': true,
            'rows': [
              {
                'primary': 1,
                'secondary': 1,
                'negate': false,
                'display': body['text'],
                'template': {'code': body['text'], 'desc': '测试条件'},
                'slots': <dynamic>[],
                'nested': <dynamic>[],
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (path == '/api/roles') {
        return http.Response(
          jsonEncode({
            'roles': [
              {'id': '10', 'name': '测试人物', 'portrait1': '', 'portrait2': ''},
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (path == '/api/state') {
        return http.Response(
          jsonEncode({'mod_name': '测试模组', 'ok': true}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response(
        jsonEncode({'data': {}}),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
  });

  tearDown(() {
    ApiClient.instance.client = http.Client();
  });

  Future<void> pumpWorkbench(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      fluent.FluentApp(
        debugShowCheckedModeBanner: false,
        home: IdleChatWorkbench(state: AppState()..modName = '测试模组'),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  testWidgets('闲聊工作台：三栏渲染 + 对白链', (tester) async {
    await pumpWorkbench(tester, const Size(1500, 950));

    expect(tester.takeException(), isNull, reason: '闲聊工作台渲染不应异常');
    expect(find.text('＋ 添加闲聊'), findsOneWidget);
    expect(find.text('闲聊设置'), findsOneWidget);
    expect(find.text('对白链'), findsOneWidget);
    expect(find.text('课间闲聊'), findsWidgets);
    expect(find.text('嗨，早啊'), findsWidgets);
    expect(find.text('早呀'), findsWidgets);
    expect(find.text('对话预览'), findsOneWidget);
  });

  testWidgets('闲聊工作台：添加白雨对白并置脏', (tester) async {
    await pumpWorkbench(tester, const Size(1500, 950));

    await tester.tap(find.text('＋ 白雨对白'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.textContaining('共 3 句'), findsWidgets);
    expect(find.text('有未保存的修改'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('闲聊工作台：触发条件打开积木库', (tester) async {
    await pumpWorkbench(tester, const Size(1500, 950));

    await tester.tap(find.text('触发条件'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('积木库 · 条件'), findsWidgets);
    expect(find.text('应用'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('闲聊工作台：800x600 无像素溢出', (tester) async {
    await pumpWorkbench(tester, const Size(800, 600));
    expect(tester.takeException(), isNull, reason: '窄窗不应溢出');
  });

  testWidgets('导演主页「闲聊」卡片进入闲聊工作台', (tester) async {
    tester.view.physicalSize = const Size(1500, 950);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(
      fluent.FluentApp(
        debugShowCheckedModeBanner: false,
        home: DirectorShell(
          state: AppState()..modName = '测试模组',
          shell: ShellState()..setAiOpen(false),
          pluginState: PluginState(),
          uiMode: UiMode.director,
          onUiModeChanged: (_) {},
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    await tester.ensureVisible(find.text('闲聊').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('闲聊').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('＋ 添加闲聊'), findsOneWidget);
    expect(find.text('对白链'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
