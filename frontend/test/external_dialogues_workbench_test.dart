// 外部对话工作台冒烟测试：三栏渲染、用途筛选、小游戏入口参数、添加对白置脏、
// 保存写回入口表与 TalkCfg、窄窗不溢出、导演主页卡片进入。
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
import 'package:student_age_editor/features/external/external_dialogues_workbench.dart';
import 'package:student_age_editor/features/shell/director_shell.dart';
import 'package:student_age_editor/features/shell/shell_state.dart';

void main() {
  final putPaths = <String>[];

  setUp(() {
    putPaths.clear();
    SharedPreferences.setMockInitialValues({});
    ApiClient.instance.client = MockClient((req) async {
      final path = req.url.path;
      if (path.startsWith('/api/cfg/')) {
        if (req.method == 'PUT') {
          putPaths.add(path.substring('/api/cfg/'.length));
          final body = jsonDecode(req.body) as Map;
          return http.Response(
            jsonEncode({'data': body['data'], 'mtime_ns': 2}),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        final cfg = path.substring('/api/cfg/'.length);
        Map<String, dynamic> data;
        switch (cfg) {
          case 'GiftEvtCfg':
            data = {
              '1': {
                'id': 1,
                'npc': [10, 20],
                'item': 100,
                'talkId': [
                  [2001],
                  [2002]
                ],
                'type': [0, 1],
                'cond': <dynamic>[],
                'redpoint': 0,
              },
            };
            break;
          case 'MinigameActionCfg':
            data = {
              '501': {
                'id': 501,
                'cost': 10,
                'effect': <dynamic>[],
                'loseTalk': 3003,
                'mode': 0,
                'needRelation': 1,
                'parms': <dynamic>[],
                'startTalk': 3001,
                'winTalk': 3002,
              },
            };
            break;
          case 'InteractCfg':
            data = {
              '1': {
                'id': 1,
                'npc': 10,
                'name': '课间',
                'text': '课间闲聊',
                'map': [101],
                'talkId': 4001,
                'cond': <dynamic>[],
                'effect': <dynamic>[],
              },
            };
            break;
          case 'TalkCfg':
            data = {
              '2001': {
                'id': 2001,
                'content': '谢谢你的礼物',
                'roleIds': [10],
                'nextTalk': [2002],
              },
              '2002': {
                'id': 2002,
                'content': '不用谢',
                'roleIds': [0],
                'nextTalk': <dynamic>[],
              },
              '3001': {
                'id': 3001,
                'content': '来玩数独吧',
                'roleIds': [10],
                'nextTalk': <dynamic>[],
              },
              '3002': {
                'id': 3002,
                'content': '你赢了',
                'roleIds': [10],
                'nextTalk': <dynamic>[],
              },
              '3003': {
                'id': 3003,
                'content': '下次再来',
                'roleIds': [10],
                'nextTalk': <dynamic>[],
              },
              '4001': {
                'id': 4001,
                'content': '早上好呀',
                'roleIds': [10],
                'nextTalk': <dynamic>[],
              },
            };
            break;
          case 'PersonGrowCfg':
            data = {
              '10': {'id': 10, 'minigame': 5},
            };
            break;
          case 'ItemCfg':
            data = {
              '100': {'id': 100, 'name': '苹果', 'type': 1},
            };
            break;
          case 'MinigameCfg':
            data = {
              '5': {'id': 5, 'name': '数独', 'tips': '', 'bgm': 0},
            };
            break;
          case 'RelationCfg':
            data = {
              '1': {'id': 1, 'name': '朋友'},
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
      if (path == '/api/roles') {
        return http.Response(
          jsonEncode({
            'roles': [
              {'id': '10', 'name': '小雨', 'portrait1': '', 'portrait2': ''},
              {'id': '20', 'name': '小刚', 'portrait1': '', 'portrait2': ''},
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
        home: ExternalDialoguesWorkbench(state: AppState()..modName = '测试模组'),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  testWidgets('外部对话：三栏渲染 + 入口列表', (tester) async {
    await pumpWorkbench(tester, const Size(1500, 950));

    expect(tester.takeException(), isNull, reason: '外部对话渲染不应异常');
    expect(find.text('共 6 个入口'), findsOneWidget);
    expect(find.text('送礼 · 小雨 ← 苹果'), findsWidgets);
    expect(find.text('对白链（TalkCfg）'), findsOneWidget);
    expect(find.text('对话预览'), findsOneWidget);
    expect(find.text('谢谢你的礼物'), findsWidgets);
  });

  testWidgets('外部对话：按用途筛选', (tester) async {
    await pumpWorkbench(tester, const Size(1500, 950));

    await tester.tap(find.text('送礼对话').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('共 2 个入口'), findsOneWidget);

    expect(tester.takeException(), isNull);
  });

  testWidgets('外部对话：小游戏入口显示人物与关卡', (tester) async {
    await pumpWorkbench(tester, const Size(1500, 950));

    await tester.tap(find.text('小游戏开场').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('共 1 个入口'), findsOneWidget);
    expect(find.text('小游戏用途'), findsOneWidget);
    expect(find.text('数独 · 第1关'), findsWidgets);
    expect(find.text('来玩数独吧'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('外部对话：添加对白并置脏', (tester) async {
    await pumpWorkbench(tester, const Size(1500, 950));

    await tester.ensureVisible(find.text('＋ 小雨对白'));
    await tester.pump();
    await tester.tap(find.text('＋ 小雨对白'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('有未保存的修改'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('外部对话：保存写回入口表与 TalkCfg', (tester) async {
    await pumpWorkbench(tester, const Size(1500, 950));

    // GiftEvtCfg：切换赠送方式；TalkCfg：追加一句。
    await tester.tap(find.text('仅播放对话'));
    await tester.pump();
    await tester.ensureVisible(find.text('＋ 小雨对白'));
    await tester.pump();
    await tester.tap(find.text('＋ 小雨对白'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    await tester.tap(find.text('保存修改'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(putPaths, contains('GiftEvtCfg'));
    expect(putPaths, contains('TalkCfg'));
    // 等 InfoBar 自动关闭，避免遗留定时器。
    await tester.pump(const Duration(seconds: 4));
    expect(tester.takeException(), isNull);
  });

  testWidgets('外部对话：800x600 无像素溢出', (tester) async {
    await pumpWorkbench(tester, const Size(800, 600));
    expect(tester.takeException(), isNull, reason: '窄窗不应溢出');
  });

  testWidgets('导演主页「外部对话」卡片进入', (tester) async {
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

    await tester.ensureVisible(find.text('事件外对话').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('事件外对话').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('对白链（TalkCfg）'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
