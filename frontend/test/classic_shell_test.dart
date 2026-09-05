// 经典布局（ClassicShell）冒烟测试：无后端时可渲染，导航/工具栏可交互。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_age_editor/core/api_client.dart';
import 'package:student_age_editor/core/models.dart';
import 'package:student_age_editor/core/plugin_state.dart';
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
        pluginState: PluginState(),
        uiMode: UiMode.classic,
        onUiModeChanged: (m) => changed = m,
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(tester.takeException(), isNull, reason: '经典布局渲染不应异常');
    // 顶栏：标题 + 工作区信息（编辑区默认打开「人物综合配置」页，欢迎页已移除）
    expect(find.text('学生时代模组编辑器'), findsOneWidget);
    expect(find.textContaining('当前工作区: 测试模组'), findsOneWidget);
    // 状态栏模组名
    expect(find.text('模组: 测试模组'), findsOneWidget);
    // 工具栏按钮（_ToolbarButton 将 emoji 与文字分成两个 Text）
    expect(find.text('加载 / 切换模组'), findsOneWidget);
    expect(find.text('全局搜索 (Ctrl+F)'), findsOneWidget);
    expect(find.text('扫描修复'), findsOneWidget);
    // 分组导航（基础配置 / 内容创作 / 官方生态）
    expect(find.text('基础配置'), findsOneWidget);
    expect(find.text('内容创作'), findsOneWidget);
    expect(find.text('官方生态'), findsOneWidget);
    expect(find.text('人物综合配置'), findsWidgets);
    expect(find.text('系统设置'), findsOneWidget); // 导航底部入口

    // 工具栏「设置」按钮：当前实现为弹窗（不再切 SidePane）
    await tester.tap(find.text('设置'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.takeException(), isNull, reason: '打开设置弹窗不应异常');
    // 设置弹窗包含界面风格选择
    expect(find.text('界面风格'), findsOneWidget);
    expect(find.text('创作'), findsOneWidget);
    expect(find.text('经典'), findsOneWidget);
    expect(find.text('剧情图'), findsOneWidget);

    // 关闭弹窗（弹窗独有的 dismiss 图标）
    await tester.tap(find.byIcon(FluentIcons.dismiss_24_regular));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('界面风格'), findsNothing);

    // 顶栏布局切换按钮：classic 的下一模式是剧情图
    await tester.tap(find.text('剧情图布局'));
    await tester.pump();
    expect(changed, UiMode.storyFlow);

    // 「扫描修复」工具栏按钮同样打开弹窗（BugfixPanel）
    await tester.tap(find.text('扫描修复'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('开始扫描'), findsOneWidget);
    expect(tester.takeException(), isNull, reason: '打开扫描修复弹窗不应异常');
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
        pluginState: PluginState(),
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
