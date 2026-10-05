// 事件工作台（导演布局「事件」专属界面）冒烟测试：三栏渲染、类型筛选、
// 窄窗不溢出、积木库集成、导演主页卡片进入。
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
import 'package:student_age_editor/features/events/event_workbench.dart';
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
          case 'EvtCfg':
            data = {
              '1': {
                'id': 1,
                'title': '开学第一天',
                'type': 0,
                'talkId': [101],
                'rate': 1,
                'npc': 10,
                'maxcount': 0,
                'mapId': 0,
                'effect': <dynamic>[],
                'condition': [
                  [1, 1, 3, 5]
                ],
                'displayType': 0,
                'content': '',
                'desc': '',
                'maxoptions': 0,
                'miniGame': <dynamic>[],
                'options': [201],
                'probability': <dynamic>[],
                'replace': <dynamic>[],
                'weight': 1,
              },
              '2': {
                'id': 2,
                'title': '篮球赛',
                'type': 4,
                'talkId': [102],
                'rate': 1,
                'npc': 0,
                'maxcount': 0,
                'mapId': 0,
                'effect': <dynamic>[],
                'condition': <dynamic>[],
                'displayType': 0,
                'content': '',
                'desc': '',
                'maxoptions': 0,
                'miniGame': <dynamic>[],
                'options': <dynamic>[],
                'probability': <dynamic>[],
                'replace': <dynamic>[],
                'weight': 1,
              },
            };
            break;
          case 'EvtTypeCfg':
            data = {
              '0': {'id': 0, 'name': '回合开始触发', 'type': [1, 3], 'emptyIsTrue': 0},
              '4': {'id': 4, 'name': '行动触发', 'type': <dynamic>[], 'emptyIsTrue': 0},
            };
            break;
          case 'TalkCfg':
            data = {
              '101': {
                'id': 101,
                'content': '早上好',
                'roleIds': [10],
                'nextTalk': <dynamic>[],
                'option': <dynamic>[],
              },
              '102': {
                'id': 102,
                'content': '开始比赛',
                'roleIds': <dynamic>[],
                'nextTalk': <dynamic>[],
                'option': <dynamic>[],
              },
            };
            break;
          case 'OptionCfg':
            data = {
              '201': {'id': 201, 'content': '去上学', 'nextEvtId': 0},
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
        home: EventWorkbench(state: AppState()..modName = '测试模组'),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  testWidgets('事件工作台：三栏渲染 + 详情分区', (tester) async {
    await pumpWorkbench(tester, const Size(1500, 950));

    expect(tester.takeException(), isNull, reason: '事件工作台渲染不应异常');
    expect(find.text('＋ 新建事件'), findsOneWidget);
    expect(find.text('基本信息'), findsOneWidget);
    expect(find.text('触发与效果'), findsOneWidget);
    expect(find.text('对白入口'), findsOneWidget);
    expect(find.text('开学第一天'), findsWidgets);
    expect(find.text('回合开始触发'), findsWidgets);
    // 右栏概览
    expect(find.text('概览'), findsOneWidget);
  });

  testWidgets('事件工作台：类型筛选', (tester) async {
    await pumpWorkbench(tester, const Size(1500, 950));

    await tester.tap(find.text('行动'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    // 事件 2 进入列表；事件 1 从列表消失（详情仍保留其选中态）。
    expect(find.text('篮球赛'), findsWidgets);
    expect(find.text('行动触发'), findsWidgets);
    expect(find.text('回合开始触发'), findsNothing);

    await tester.tap(find.text('全部'));
    await tester.pump();
    expect(find.text('回合开始触发'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('事件工作台：出现条件打开积木库', (tester) async {
    await pumpWorkbench(tester, const Size(1500, 950));

    await tester.tap(find.text('出现条件'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('积木库 · 条件'), findsWidgets);
    expect(find.text('应用'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('事件工作台：800x600 无像素溢出', (tester) async {
    await pumpWorkbench(tester, const Size(800, 600));
    expect(tester.takeException(), isNull, reason: '窄窗不应溢出');
  });

  testWidgets('导演主页「事件」卡片进入事件工作台', (tester) async {
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

    await tester.ensureVisible(find.text('事件').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('事件').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('＋ 新建事件'), findsOneWidget);
    expect(find.text('对白入口'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
