// 手机消息工作台（导演布局的「手机消息」专属界面）冒烟测试：手机对话视图、
// 白雨回复分支、窄窗不溢出，以及从导演主页卡片进入。
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
import 'package:student_age_editor/features/messages/messages_workbench.dart';
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
          case 'PhoneMsgCfg':
            data = {
              '100': {
                'id': 100,
                'role': 10,
                'content': '在吗？',
                'next': [101],
                'option': '',
                'cond': <dynamic>[],
                'effect': <dynamic>[],
              },
              '101': {
                'id': 101,
                'role': 0,
                'content': '在的',
                'next': [102],
                'option': '在的',
                'cond': <dynamic>[],
                'effect': <dynamic>[],
              },
              '102': {
                'id': 102,
                'role': 10,
                'content': '今天有空吗',
                'next': <dynamic>[],
                'option': '',
                'cond': <dynamic>[],
                'effect': <dynamic>[],
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
        home: MessagesWorkbench(state: AppState()..modName = '测试模组'),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('手机消息工作台：对话视图 + 设置', (tester) async {
    await pumpWorkbench(tester, const Size(1600, 1000));

    expect(tester.takeException(), isNull, reason: '手机消息工作台渲染不应异常');
    expect(find.text('＋ 创建短信'), findsOneWidget);
    expect(find.text('在吗？'), findsWidgets);
    // 默认选中根消息 → 右栏短信设置
    expect(find.text('短信设置'), findsOneWidget);
  });

  testWidgets('手机消息工作台：点击白雨回复展开后续', (tester) async {
    await pumpWorkbench(tester, const Size(1600, 1000));

    // 白雨回复选项「在的」尚未展开时是选项气泡。
    await tester.tap(find.text('在的').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    // 选中回复后，链继续到 102。
    expect(find.text('今天有空吗'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('手机消息工作台：800x600 无像素溢出', (tester) async {
    await pumpWorkbench(tester, const Size(800, 600));
    expect(tester.takeException(), isNull, reason: '窄窗不应溢出');
  });

  testWidgets('导演主页「手机消息」卡片进入手机消息工作台', (tester) async {
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

    await tester.ensureVisible(find.text('短信').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('短信').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('＋ 创建短信'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
