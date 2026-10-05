// 社交动态工作台（导演布局的「社交」专属界面）冒烟测试：三栏渲染、
// 评论树展示、窄窗不溢出，以及从导演主页卡片进入。
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
import 'package:student_age_editor/features/shell/director_shell.dart';
import 'package:student_age_editor/features/shell/shell_state.dart';
import 'package:student_age_editor/features/social/social_workbench.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ApiClient.instance.client = MockClient((req) async {
      final path = req.url.path;
      if (path.startsWith('/api/cfg/')) {
        final cfg = path.substring('/api/cfg/'.length);
        Map<String, dynamic> data;
        switch (cfg) {
          case 'KZoneContentCfg':
            data = {
              '1001': {
                'id': 1001,
                'role': 10,
                'title': '周记一则',
                'content': '今天天气很好。',
                'imgs': <dynamic>[],
                'thumbs': [
                  [10, 0],
                ],
                'comments': [
                  [100101, 0],
                ],
                'options': <dynamic>[],
                'cond': <dynamic>[],
              },
            };
            break;
          case 'KZoneCommentCfg':
            data = {
              '100101': {
                'id': 100101,
                'roles': [10],
                'parent': 0,
                'content': '第一条评论',
                'comments': <dynamic>[],
                'options': <dynamic>[],
                'effect': <dynamic>[],
                'condition': <dynamic>[],
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
        home: SocialWorkbench(state: AppState()..modName = '测试模组'),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('社交动态工作台：三栏渲染 + 评论树', (tester) async {
    await pumpWorkbench(tester, const Size(1600, 1000));

    expect(tester.takeException(), isNull, reason: '社交工作台渲染不应异常');
    // 左栏按钮 + 动态正文 + 评论
    expect(find.text('＋ 发布动态'), findsOneWidget);
    expect(find.text('评论与回复'), findsOneWidget);
    expect(find.text('第一条评论'), findsWidgets);
    // 右栏动态设置
    expect(find.text('动态设置'), findsOneWidget);
    expect(find.text('点赞人物'), findsOneWidget);
  });

  testWidgets('社交动态工作台：选中评论显示评论设置', (tester) async {
    await pumpWorkbench(tester, const Size(1600, 1000));

    // 点击评论卡片「设置」→ 右栏切到评论设置。
    await tester.tap(find.text('设置').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('评论设置'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('社交动态工作台：800x600 无像素溢出', (tester) async {
    await pumpWorkbench(tester, const Size(800, 600));
    expect(tester.takeException(), isNull, reason: '窄窗不应溢出');
  });

  testWidgets('导演主页「社交」卡片进入社交动态工作台', (tester) async {
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

    await tester.tap(find.text('社交').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('＋ 发布动态'), findsOneWidget);
    expect(find.text('评论与回复'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
