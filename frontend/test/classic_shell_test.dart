// 经典布局（ClassicShell）冒烟测试：无后端时可渲染，导航/工具栏可交互。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_age_editor/core/api_client.dart';
import 'package:student_age_editor/core/models.dart';
import 'package:student_age_editor/core/ui_mode.dart';
import 'package:student_age_editor/features/shell/classic_shell.dart';
import 'package:student_age_editor/features/shell/shell_state.dart';

void main() {
  testWidgets('经典布局渲染冒烟：标题 + 工具栏 + 分组导航 + 状态栏', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    ApiClient.instance.client = MockClient((req) async =>
        http.Response('{"ok":true,"data":[]}', 200,
            headers: {'content-type': 'application/json'}));

    final state = AppState()..modName = '测试模组';
    final shell = ShellState();
    UiMode? changed;

    await tester.pumpWidget(fluent.FluentApp(
      debugShowCheckedModeBanner: false,
      home: ClassicShell(
        state: state,
        shell: shell,
        uiMode: UiMode.classic,
        onUiModeChanged: (m) => changed = m,
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(tester.takeException(), isNull, reason: '经典布局渲染不应异常');
    // 标题行（顶栏 + 编辑区欢迎页各一处）
    expect(find.text('学生时代模组编辑器'), findsNWidgets(2));
    expect(find.text('当前模组: 测试模组'), findsOneWidget);
    // 工具栏按钮
    expect(find.text('切换模组'), findsOneWidget);
    expect(find.text('全局搜索'), findsOneWidget);
    expect(find.text('扫描修复'), findsOneWidget);
    // 分组导航
    expect(find.text('常用'), findsOneWidget);
    expect(find.text('工具'), findsOneWidget);
    expect(find.text('模组'), findsWidgets); // 导航项 + 模组面板标题

    // 导航切换面板（导航项在左侧，工具栏的"设置"按钮在前）
    await tester.tap(find.text('设置').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(shell.pane, SidePane.settings);
    expect(tester.takeException(), isNull, reason: '切换到设置面板不应异常');
    // 设置页包含界面风格选择
    expect(find.text('界面风格'), findsOneWidget);
    expect(find.text('创作'), findsOneWidget);
    expect(find.text('经典'), findsOneWidget);

    // 顶栏切换布局按钮
    await tester.tap(find.text('创作布局'));
    expect(changed, UiMode.creation);

    // 工具栏按钮切换面板
    await tester.tap(find.text('全局搜索'));
    await tester.pump();
    expect(shell.pane, SidePane.base);

    await tester.tap(find.text('扫描修复'));
    await tester.pump();
    expect(shell.pane, SidePane.bugfix);
    expect(tester.takeException(), isNull, reason: '切换到诊断修复面板不应异常');
  });

  testWidgets('经典布局 AI 面板开关', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    ApiClient.instance.client = MockClient((req) async =>
        http.Response('{}', 200,
            headers: {'content-type': 'application/json'}));

    final shell = ShellState()..toggleAi(); // 默认关
    await tester.pumpWidget(fluent.FluentApp(
      debugShowCheckedModeBanner: false,
      home: ClassicShell(
        state: AppState(),
        shell: shell,
        uiMode: UiMode.classic,
        onUiModeChanged: (_) {},
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);

    // 导航底部 AI 开关（顶栏工具栏也有"AI 助手"按钮，取导航项）
    await tester.tap(find.text('AI 助手').last);
    await tester.pump();
    expect(shell.aiOpen, isTrue);
    expect(tester.takeException(), isNull, reason: '打开 AI 面板不应异常');
  });
}
