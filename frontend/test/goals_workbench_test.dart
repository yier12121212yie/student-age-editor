// 目标工作台（导演布局的「目标 / 意愿」专属界面）冒烟测试：三栏渲染、
// 标签切换、窄窗不溢出，以及从导演主页卡片进入。
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
import 'package:student_age_editor/features/goals/goals_workbench.dart';
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
          case 'IntentCfg':
            data = {
              '1': {
                'id': 1,
                'name': '考进年级前十',
                'group': 999,
                'desc': '努力学习，冲进前十。',
                'npc': 10,
                'finishType': 0,
                'round': 0,
                'before': 0,
                'next': 0,
                'targetRound': 0,
                'weight': 1,
                'tag': 1,
                'renshengguan': 0,
                'demand': [
                  [1, 1],
                ],
                'condition': <dynamic>[],
                'reward': <dynamic>[],
                'fail': <dynamic>[],
                'finishTalk': <dynamic>[],
                'failTalk': <dynamic>[],
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
        home: GoalsWorkbench(state: AppState()..modName = '测试模组'),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('目标工作台：列表 + 预览 + 设置', (tester) async {
    await pumpWorkbench(tester, const Size(1600, 1000));

    expect(tester.takeException(), isNull, reason: '目标工作台渲染不应异常');
    expect(find.text('＋ 添加目标'), findsOneWidget);
    expect(find.text('游戏内目标预览'), findsOneWidget);
    expect(find.text('考进年级前十'), findsWidgets);
    expect(find.text('完成要求 1 条'), findsOneWidget);
    // 默认基本设置
    expect(find.text('基本设置'), findsWidgets);
  });

  testWidgets('目标工作台：切换标签到扩展设置', (tester) async {
    await pumpWorkbench(tester, const Size(1600, 1000));

    await tester.tap(find.text('扩展设置'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    // 出现条件卡 + 前后置分类卡
    expect(find.text('前后置与分类'), findsOneWidget);
    expect(find.text('完成要求 1 条'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('目标工作台：800x600 无像素溢出', (tester) async {
    await pumpWorkbench(tester, const Size(800, 600));
    expect(tester.takeException(), isNull, reason: '窄窗不应溢出');
  });

  testWidgets('导演主页「目标工作台」卡片进入目标工作台', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
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

    await tester.ensureVisible(find.text('目标').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('目标').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('＋ 添加目标'), findsOneWidget);
    expect(find.text('游戏内目标预览'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
