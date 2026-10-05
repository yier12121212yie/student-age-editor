// JSON 侧栏工作台冒烟测试：选表渲染、非法 JSON 提示、编辑保存写回、窄窗不溢出、
// 导演主页卡片进入。
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
import 'package:student_age_editor/features/json/json_workbench.dart';
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
        final data = cfg == 'EvtCfg'
            ? {
                '1': {'id': 1, 'title': '事件A'},
                '2': {'id': 2, 'title': '事件B'},
              }
            : <String, dynamic>{};
        return http.Response(
          jsonEncode({'data': data, 'exists': true, 'mtime_ns': 1}),
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
        home: JsonWorkbench(state: AppState()..modName = '测试模组'),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  Future<void> openEvt(WidgetTester tester) async {
    await tester.enterText(find.byType(EditableText).first, 'EvtCfg');
    await tester.pump();
    await tester.tap(find.text('EvtCfg').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('JSON 侧栏：选表后渲染记录与 JSON', (tester) async {
    await pumpWorkbench(tester, const Size(1500, 950));
    expect(find.text('选择左侧一张配置表，查看与编辑其原始 JSON。'), findsOneWidget);

    await openEvt(tester);
    expect(tester.takeException(), isNull, reason: 'JSON 侧栏渲染不应异常');
    expect(find.text('记录 #1'), findsOneWidget);
    expect(find.text('事件A'), findsWidgets);
    expect(find.text('JSON 有效'), findsOneWidget);
    expect(find.text('2 条记录 · JSON 原始编辑'), findsOneWidget);
  });

  testWidgets('JSON 侧栏：非法 JSON 提示且禁止保存', (tester) async {
    await pumpWorkbench(tester, const Size(1500, 950));
    await openEvt(tester);

    await tester.enterText(find.byType(EditableText).last, '不是 JSON');
    await tester.pump();
    expect(find.text('JSON 有误'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('JSON 侧栏：编辑合法 JSON 并保存写回', (tester) async {
    await pumpWorkbench(tester, const Size(1500, 950));
    await openEvt(tester);

    await tester.enterText(
        find.byType(EditableText).last, '{"id":1,"title":"改过了"}');
    await tester.pump();
    expect(find.text('JSON 有效'), findsOneWidget);
    expect(find.text('有未保存的修改'), findsOneWidget);

    await tester.tap(find.text('保存修改'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(putPaths, contains('EvtCfg'));
    // 等 InfoBar 自动关闭，避免遗留定时器。
    await tester.pump(const Duration(seconds: 4));
    expect(tester.takeException(), isNull);
  });

  testWidgets('JSON 侧栏：800x600 无像素溢出', (tester) async {
    await pumpWorkbench(tester, const Size(800, 600));
    expect(tester.takeException(), isNull, reason: '窄窗不应溢出');
  });

  testWidgets('导演主页「JSON 侧栏」卡片进入', (tester) async {
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

    await tester.ensureVisible(find.text('JSON 侧栏').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('JSON 侧栏').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('搜索配置表名（如 EvtCfg）'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
