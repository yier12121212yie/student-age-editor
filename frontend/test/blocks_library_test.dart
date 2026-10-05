// 条件 / 效果积木库（导演布局「积木库」专属界面 + 无代码模式入口）冒烟测试：
// 目录分类、点击入库生成代码、分类筛选、窄窗不溢出、导演主页卡片进入，
// 以及无代码字段的「打开积木库」入口。
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
import 'package:student_age_editor/features/blocks/blocks_workbench.dart';
import 'package:student_age_editor/features/nocode/nocode_effect_field.dart';
import 'package:student_age_editor/features/shell/director_shell.dart';
import 'package:student_age_editor/features/shell/shell_state.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ApiClient.instance.client = MockClient((req) async {
      final path = req.url.path;
      if (path == '/api/effect_suggest') {
        final mode = req.url.queryParameters['mode'] ?? 'effect';
        final items = mode == 'condition'
            ? [
                {
                  'code': '[1, 97, 1]',
                  'desc': '已经文理分班',
                  'raw_code': '[1, 97, 1]',
                  'slots': <dynamic>[],
                },
                {
                  'code': '[7, 0, 0, 1]',
                  'desc': '和某人是朋友',
                  'raw_code': '[7, 0, 0, 1]',
                  'slots': <dynamic>[],
                },
              ]
            : [
                {
                  'code': '[1, 1, @ATTR@, V]',
                  'desc': '属性 @ATTR@ 增加 V',
                  'raw_code': '[1, 1, @ATTR@, V]',
                  'slots': [
                    {
                      'kind': 'dict',
                      'name': 'ATTR',
                      'dict': 'ATTR',
                      'label': '属性',
                      'count': 1,
                    },
                    {'kind': 'number', 'name': 'V', 'count': 1},
                  ],
                },
              ];
        return http.Response(
          jsonEncode({'items': items, 'mode': mode, 'q': ''}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (path == '/api/effect/parse') {
        final body = jsonDecode(req.body) as Map;
        final text = body['text']?.toString() ?? '';
        return http.Response(
          jsonEncode({
            'ok': true,
            'rows': [
              {
                'primary': 1,
                'secondary': 97,
                'negate': false,
                'display': text,
                'template': {'code': text, 'desc': '测试积木'},
                'slots': <dynamic>[],
                'nested': <dynamic>[],
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (path.startsWith('/api/cfg/')) {
        final cfg = path.substring('/api/cfg/'.length);
        Map<String, dynamic> data;
        switch (cfg) {
          case 'ConditionTypeCfg':
            data = {
              '1': {'id': 1, 'name': '年龄限制'},
              '7': {'id': 7, 'name': '社交'},
            };
            break;
          case 'EffectTypeCfg':
            data = {
              '1': {'id': 1, 'name': '改变属性'},
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
        home: BlocksWorkbench(state: AppState()..modName = '测试模组'),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('积木库工作台：目录 + 构建清单渲染', (tester) async {
    await pumpWorkbench(tester, const Size(1400, 900));

    expect(tester.takeException(), isNull, reason: '积木库渲染不应异常');
    expect(find.text('积木目录'), findsOneWidget);
    expect(find.text('构建清单'), findsOneWidget);
    // 默认效果模式：候选来自 mock，目录卡片只显示人话标题（无占位符/原始代码）。
    expect(find.text('属性 增加 数值'), findsWidgets);
  });

  testWidgets('积木库工作台：切换条件模式并按分类入库生成代码', (tester) async {
    await pumpWorkbench(tester, const Size(1400, 900));

    // 切到条件模式。
    await tester.tap(find.text('条件'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // 分类来自 ConditionTypeCfg。
    expect(find.text('年龄限制'), findsWidgets);
    expect(find.text('社交'), findsWidgets);

    // 无参候选：点击直接入库。
    await tester.tap(find.text('已经文理分班'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('已添加 1 条'), findsOneWidget);
    expect(find.text('[1, 97, 1]'), findsWidgets);

    // 按分类筛选：只看社交。
    await tester.tap(find.text('社交').first);
    await tester.pump();
    expect(find.text('和某人是朋友'), findsOneWidget);

    await tester.tap(find.text('和某人是朋友'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('已添加 2 条'), findsOneWidget);
    expect(find.textContaining('[7, 0, 0, 1]'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('积木库工作台：窄窗（隐藏说明栏）无像素溢出', (tester) async {
    await pumpWorkbench(tester, const Size(820, 620));
    expect(tester.takeException(), isNull, reason: '窄窗不应溢出');
  });

  testWidgets('导演主页「积木库」卡片进入积木库工作台', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
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

    await tester.ensureVisible(find.text('积木库').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('积木库').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('积木目录'), findsOneWidget);
    expect(find.text('构建清单'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('无代码字段：显示「打开积木库」入口', (tester) async {
    await tester.pumpWidget(
      fluent.FluentApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          body: SingleChildScrollView(
            child: NoCodeEffectField(
              value: [
                [1, 1, 3, 5],
              ],
              type: '2D Array',
              cfg: 'TalkCfg',
              fieldKey: 'effect',
              mode: 'effect',
              onChanged: (_) {},
              onDisableNoCode: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('打开积木库'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
