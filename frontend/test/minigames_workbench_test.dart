// 小游戏库工作台（导演布局「小游戏」专属界面）冒烟测试：三栏渲染、新增关卡置脏、
// 关卡效果打开积木库、保存写回两表、窄窗不溢出、导演主页卡片进入。
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
import 'package:student_age_editor/features/minigames/minigames_workbench.dart';
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
          case 'MinigameCfg':
            data = {
              '5': {'id': 5, 'name': '数独', 'tips': '6×6 数独', 'bgm': 0},
              '9': {'id': 9, 'name': '卖货', 'tips': '议价小游戏', 'bgm': 0},
            };
            break;
          case 'MinigameActionCfg':
            data = {
              '501': {
                'id': 501,
                'cost': 10,
                'effect': <dynamic>[],
                'loseTalk': 0,
                'mode': 0,
                'needRelation': 1,
                'parms': [30, 60],
                'startTalk': 1001,
                'winTalk': 1002,
              },
              '502': {
                'id': 502,
                'cost': 20,
                'effect': <dynamic>[],
                'loseTalk': 0,
                'mode': 0,
                'needRelation': 1,
                'parms': <dynamic>[],
                'startTalk': 0,
                'winTalk': 0,
              },
            };
            break;
          case 'GuideCfg':
            data = {
              '501': {'id': 501, 'url': 'guide_sudoku', 'tips': '原版玩法说明'},
            };
            break;
          case 'RelationCfg':
            data = {
              '1': {'id': 1, 'name': '朋友'},
            };
            break;
          case 'TalkCfg':
            data = {
              '1001': {'id': 1001, 'content': '开始吧'},
              '1002': {'id': 1002, 'content': '赢了'},
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
                'desc': '属性 +V',
                'raw_code': '[1, 1, V]',
                'slots': [
                  {'kind': 'number', 'name': 'V', 'count': 1}
                ],
              },
            ],
            'mode': 'effect',
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
                'template': {'code': body['text'], 'desc': '测试效果'},
                'slots': <dynamic>[],
                'nested': <dynamic>[],
              },
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
        home: MinigamesWorkbench(state: AppState()..modName = '测试模组'),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  testWidgets('小游戏库：三栏渲染 + 关卡列表', (tester) async {
    await pumpWorkbench(tester, const Size(1500, 950));

    expect(tester.takeException(), isNull, reason: '小游戏库渲染不应异常');
    expect(find.text('＋ 新建小游戏'), findsOneWidget);
    expect(find.text('小游戏定义'), findsOneWidget);
    expect(find.text('数独'), findsWidgets);
    expect(find.text('关卡（MinigameActionCfg）'), findsOneWidget);
    expect(find.text('第 1 关'), findsWidgets);
    expect(find.text('玩法预览'), findsOneWidget);
  });

  testWidgets('小游戏库：新增关卡并置脏', (tester) async {
    await pumpWorkbench(tester, const Size(1500, 950));

    await tester.tap(find.text('＋ 关卡'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('第 3 关'), findsWidgets);
    expect(find.text('有未保存的修改'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('小游戏库：关卡效果打开积木库', (tester) async {
    await pumpWorkbench(tester, const Size(1500, 950));

    await tester.ensureVisible(find.text('打开积木库'));
    await tester.pump();
    await tester.tap(find.text('打开积木库'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('积木库 · 关卡效果'), findsWidgets);
    expect(find.text('应用'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('小游戏库：新建小游戏后保存写回两表', (tester) async {
    await pumpWorkbench(tester, const Size(1500, 950));

    await tester.tap(find.text('＋ 新建小游戏'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('有未保存的修改'), findsOneWidget);

    await tester.tap(find.text('保存修改'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(putPaths, contains('MinigameCfg'));
    expect(putPaths, contains('MinigameActionCfg'));
    // 等 InfoBar 自动关闭，避免遗留定时器。
    await tester.pump(const Duration(seconds: 4));
    expect(tester.takeException(), isNull);
  });

  testWidgets('小游戏库：800x600 无像素溢出', (tester) async {
    await pumpWorkbench(tester, const Size(800, 600));
    expect(tester.takeException(), isNull, reason: '窄窗不应溢出');
  });

  testWidgets('导演主页「小游戏库」卡片进入', (tester) async {
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

    await tester.ensureVisible(find.text('小游戏').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('小游戏').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('＋ 新建小游戏'), findsOneWidget);
    expect(find.text('玩法预览'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
