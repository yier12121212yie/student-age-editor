// AI 侧栏自适应显示：窄窗口（含 Web）下 AI 浮层化，不再挤占编辑区。
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
import 'package:student_age_editor/features/shell/ai_dock.dart';
import 'package:student_age_editor/features/shell/classic_shell.dart';
import 'package:student_age_editor/features/shell/editor_area.dart';
import 'package:student_age_editor/features/shell/editor_shell.dart';
import 'package:student_age_editor/features/shell/shell_state.dart';
import 'package:student_age_editor/features/shell/story_flow_shell.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ApiClient.instance.client = MockClient((req) async =>
        http.Response('{"ok":true,"data":[]}', 200,
            headers: {'content-type': 'application/json'}));
  });

  tearDown(() {
    ApiClient.instance.client = http.Client();
  });

  Future<void> pumpShell(WidgetTester tester, Widget shell, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(fluent.FluentApp(
      debugShowCheckedModeBanner: false,
      home: shell,
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  Widget creation(ShellState shell) => CreationShell(
        state: AppState(),
        shell: shell,
        pluginState: PluginState(),
        uiMode: UiMode.creation,
        onUiModeChanged: (_) {},
      );

  Widget classic(ShellState shell) => ClassicShell(
        state: AppState(),
        shell: shell,
        pluginState: PluginState(),
        uiMode: UiMode.classic,
        onUiModeChanged: (_) {},
      );

  Widget storyFlow(ShellState shell) => StoryFlowShell(
        state: AppState(),
        shell: shell,
        pluginState: PluginState(),
        uiMode: UiMode.storyFlow,
        onUiModeChanged: (_) {},
      );

  testWidgets('创作壳紧凑宽度：AI 浮层化且编辑区仍在（不挤占）', (tester) async {
    final shell = ShellState(); // aiOpen 默认 true
    await pumpShell(tester, creation(shell), const Size(900, 700));

    expect(tester.takeException(), isNull);
    expect(find.byType(AiOverlayDock), findsOneWidget);
    expect(find.byKey(const ValueKey('ai-overlay')), findsOneWidget);
    expect(find.byKey(const ValueKey('ai-overlay-button')), findsNothing);
    // 编辑区在浮层之下仍完整存在（此前并排停靠会把编辑区压成负宽 / 溢出）。
    expect(find.byType(EditorArea), findsOneWidget);
  });

  testWidgets('创作壳宽布局：AI 恢复并排停靠', (tester) async {
    final shell = ShellState();
    await pumpShell(tester, creation(shell), const Size(1400, 900));

    expect(tester.takeException(), isNull);
    expect(find.byType(AiDock), findsOneWidget);
    expect(find.byType(AiOverlayDock), findsNothing);
  });

  testWidgets('创作壳紧凑宽度：收起显示悬浮按钮，再展开可回切', (tester) async {
    final shell = ShellState();
    await pumpShell(tester, creation(shell), const Size(900, 700));

    shell.setAiOpen(false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('ai-overlay-button')), findsOneWidget);
    expect(find.byKey(const ValueKey('ai-overlay')), findsNothing);

    shell.setAiOpen(true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('ai-overlay')), findsOneWidget);
    expect(find.byKey(const ValueKey('ai-overlay-button')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('经典壳紧凑宽度：AI 浮层化且无溢出', (tester) async {
    final shell = ShellState();
    await pumpShell(tester, classic(shell), const Size(900, 700));

    expect(find.byType(AiOverlayDock), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('剧情图壳紧凑宽度：AI 浮层化', (tester) async {
    final shell = ShellState();
    await pumpShell(tester, storyFlow(shell), const Size(900, 700));

    expect(find.byType(AiOverlayDock), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
