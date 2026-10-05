// 导演布局（DirectorShell）冒烟测试：无后端时可渲染三栏舞台工作台 +
// 顶部工程栏 + 状态栏，且布局切换按钮循环到下一模式。
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
              '8000': {
                'id': '8000',
                'title': '测试事件',
                'talkIds': ['800001'],
              },
            };
            break;
          case 'TalkCfg':
            data = {
              '800001': {
                'id': 800001,
                'roleIds': [10],
                'content': '测试台词',
              },
            };
            break;
          case 'PersonCfg':
            data = {
              '10': {'id': 10, 'name': '主角'},
            };
            break;
          default:
            data = {};
        }
        return http.Response(
          jsonEncode({'data': data, 'exists': true}),
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

  testWidgets('导演布局渲染冒烟：工程栏 + 舞台工作台 + 状态栏', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    final state = AppState()..modName = '测试模组';
    final shell = ShellState()..setAiOpen(false);
    UiMode? changed;

    await tester.pumpWidget(
      fluent.FluentApp(
        debugShowCheckedModeBanner: false,
        home: DirectorShell(
          state: state,
          shell: shell,
          pluginState: PluginState(),
          uiMode: UiMode.director,
          onUiModeChanged: (m) => changed = m,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(tester.takeException(), isNull, reason: '导演布局渲染不应异常');
    // 顶部工程栏品牌 + 副标题
    expect(find.text('学生时代模组编辑器'), findsOneWidget);
    expect(find.text('导演工作台'), findsOneWidget);
    // 进入导演布局先到主页（功能总览）
    expect(find.text('模组编辑功能'), findsOneWidget);
    // 状态栏模组名
    expect(find.text('模组: 测试模组'), findsOneWidget);
    // 导演的下一模式是创作
    expect(find.text('切换创作布局'), findsOneWidget);
    await tester.tap(find.text('切换创作布局'));
    expect(changed, UiMode.creation);
    expect(tester.takeException(), isNull);
  });

  testWidgets('导演布局紧凑窗口（800x600）无像素溢出', (tester) async {
    tester.view.physicalSize = const Size(800, 600);
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

    expect(tester.takeException(), isNull, reason: '导演布局在 800x600 下不应溢出');

    // 配置表工作台的「条目列表 / 表单 / 信息栏」三栏在窄窗下也不应溢出。
    await tester.ensureVisible(find.text('珍贵记忆'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('珍贵记忆'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.takeException(), isNull, reason: '配置表工作台在 800x600 下不应溢出');
  });

  testWidgets('导演工作台：主页卡片 / 功能切换 / 操作说明', (tester) async {
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

    // 首页：标题 + 功能卡片 + 模组管理工具 + 打开入口。
    expect(find.text('模组编辑功能'), findsOneWidget);
    expect(find.text('剧情编辑'), findsWidgets);
    expect(find.text('模组管理'), findsOneWidget);
    expect(find.text('打开 →'), findsWidgets);

    // 点「珍贵记忆」功能卡片进入配置表工作台（该表归在社交页）。
    await tester.ensureVisible(find.text('珍贵记忆'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('珍贵记忆'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('可编辑配置表'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // 操作说明覆盖层。
    await tester.tap(find.text('操作说明'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('常用快捷键'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('导演主页：按参考产品的功能目录渲染卡片', (tester) async {
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

    // 参考产品 workshop-features.json 的功能目录原样出现在主页：
    // 常用功能、人物、结局与记忆、玩法与配置、恋爱与送礼等分组的功能卡片。
    for (final label in [
      '剧情编辑',
      '人物',
      '物品',
      '企鹅动态',
      '珍贵记忆',
      '目标',
      '看番与漫展',
      '生日派对',
      '表白与成功率',
      '送礼事件',
    ]) {
      expect(find.text(label), findsWidgets, reason: '主页应有「$label」功能卡片');
    }

    // 点「珍贵记忆」直达该表的配置表编辑器（社交页 + 信息栏）。
    await tester.ensureVisible(find.text('珍贵记忆'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('珍贵记忆'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('可编辑配置表'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
