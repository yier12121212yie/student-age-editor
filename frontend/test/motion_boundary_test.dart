// 常驻动画的绘制隔离回归（「降 GPU 负担」阶段 3 准出）。
//
// 背景：`..repeat()` 的动画每帧标脏绘制。不加 RepaintBoundary 时重绘会向上
// 传播到最近的边界（整条状态栏/整块编辑区），空闲停在这些画面上就是持续
// 60fps 烧 GPU。本文件钉住四件事：
//   1. ShimmerBox / TypingDots 自带 RepaintBoundary 且动画仍在跑；
//   2. 欢迎页浮动方块的边界只包住方块本身（不把欢迎文案一起拖进每帧重绘）；
//   3. 隐藏视图（StoryFlowShell 的保活栈）ticker 必须为停；
//   4. 当前视图 ticker 必须为开（停过头会让可见动画不动）。
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:student_age_editor/core/api_client.dart';
import 'package:student_age_editor/core/models.dart';
import 'package:student_age_editor/core/motion.dart';
import 'package:student_age_editor/core/plugin_state.dart';
import 'package:student_age_editor/core/ui_mode.dart';
import 'package:student_age_editor/features/ai/ai_chat_widgets.dart';
import 'package:student_age_editor/features/shell/editor_shell.dart';
import 'package:student_age_editor/features/shell/shell_state.dart';
import 'package:student_age_editor/features/shell/story_flow_shell.dart';
import 'package:student_age_editor/features/story/story_flow_workspace.dart';
import 'package:student_age_editor/features/story/story_flow_top_tabs.dart';

/// 取 [of] 子树里「渐变起点」的当前值，用来证明动画确实在推进。
List<double> gradientBegins(WidgetTester tester) => [
      for (final e in find.byType(DecoratedBox).evaluate())
        if ((e.widget as DecoratedBox).decoration is BoxDecoration)
          if (((e.widget as DecoratedBox).decoration as BoxDecoration).gradient
              case final LinearGradient g)
            if (g.begin case final Alignment a) a.x,
    ];

void main() {
  testWidgets('ShimmerBox：自带 RepaintBoundary，且渐变逐帧推进', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: Center(child: ShimmerBox(width: 80, height: 10))),
    ));
    expect(
      find.descendant(
          of: find.byType(ShimmerBox), matching: find.byType(RepaintBoundary)),
      findsOneWidget,
      reason: 'repeat() 动画必须自带 RepaintBoundary，否则重绘向宿主传播',
    );

    final a = gradientBegins(tester);
    await tester.pump(const Duration(milliseconds: 200));
    final b = gradientBegins(tester);
    expect(a, isNotEmpty);
    expect(a, isNot(equals(b)), reason: '渐变没推进：shimmer 动画被意外停掉');
  });

  testWidgets('TypingDots：自带 RepaintBoundary，且透明度逐帧变化', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: Center(child: TypingDots())),
    ));
    expect(
      find.descendant(
          of: find.byType(TypingDots), matching: find.byType(RepaintBoundary)),
      findsOneWidget,
    );

    double firstDotOpacity() => tester
        .widgetList<Opacity>(find.descendant(
            of: find.byType(TypingDots), matching: find.byType(Opacity)))
        .first
        .opacity;
    final a = firstDotOpacity();
    await tester.pump(const Duration(milliseconds: 150));
    expect(firstDotOpacity(), isNot(equals(a)));
  });

  testWidgets('欢迎页浮动方块：边界只包住方块，不牵动欢迎文案', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    ApiClient.instance.client = MockClient((req) async =>
        http.Response('{"ok":true,"data":[]}', 200,
            headers: {'content-type': 'application/json'}));
    addTearDown(() => ApiClient.instance.client = http.Client());

    await tester.pumpWidget(fluent.FluentApp(
      debugShowCheckedModeBanner: false,
      home: CreationShell(
        state: AppState(),
        shell: ShellState()..toggleAi(),
        pluginState: PluginState(),
        uiMode: UiMode.creation,
        onUiModeChanged: (_) {},
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    const title = '学生时代模组编辑器';
    expect(find.text(title), findsOneWidget, reason: '欢迎页未渲染，用例前提不成立');
    // 浮动方块：72×72、带 blurRadius 24 阴影的那个 Container。
    final floating = find.byWidgetPredicate((w) =>
        w is Container &&
        w.decoration is BoxDecoration &&
        ((w.decoration as BoxDecoration).boxShadow?.any(
                (s) => s.blurRadius == 24) ??
            false));
    expect(floating, findsOneWidget);

    final boundaries =
        find.ancestor(of: floating, matching: find.byType(RepaintBoundary));
    expect(boundaries, findsWidgets, reason: '浮动方块没有最近的绘制边界');
    final nearest = boundaries.evaluate().first;
    // 最近边界必须「只包住方块」：欢迎文案在它外面，否则文案所在的整块区域
    // 每帧都会被这个永久动画拖进重绘。
    expect(
      find.descendant(of: find.byElementPredicate((e) => e == nearest),
          matching: find.text(title)),
      findsNothing,
      reason: '最近的 RepaintBoundary 把欢迎文案也包进去了（边界过粗）',
    );
  });

  testWidgets('StoryFlowShell：隐藏视图 ticker 停、当前视图 ticker 开', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    ApiClient.instance.client = MockClient((req) async =>
        http.Response('{"ok":true,"data":[]}', 200,
            headers: {'content-type': 'application/json'}));
    addTearDown(() => ApiClient.instance.client = http.Client());

    await tester.pumpWidget(fluent.FluentApp(
      debugShowCheckedModeBanner: false,
      home: StoryFlowShell(
        state: AppState(),
        shell: ShellState()..toggleAi(),
        pluginState: PluginState(),
        uiMode: UiMode.creation,
        onUiModeChanged: (_) {},
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // 保活栈里被隐藏的视图是 Offstage：finder 必须 skipOffstage: false 才看得到。
    final ws = find.byType(StoryFlowWorkspace, skipOffstage: false);
    expect(find.byType(StoryFlowWorkspace), findsOneWidget);
    expect(TickerMode.valuesOf(tester.element(ws)).enabled, isTrue, reason: '当前视图的 ticker 必须是开的');

    // 切到基础库：画布进保活栈但隐藏 → ticker 必须停。
    await tester.tap(find.text(StoryFlowView.base.label));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(TickerMode.valuesOf(tester.element(ws)).enabled, isFalse,
        reason: '隐藏的剧情图画布 ticker 没停：保活视图仍在持续出帧');

    // 切回剧情图：恢复。
    await tester.tap(find.text(StoryFlowView.graph.label));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(TickerMode.valuesOf(tester.element(ws)).enabled, isTrue);
    expect(tester.takeException(), isNull);
  });
}
