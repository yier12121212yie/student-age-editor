// 「降 GPU 负担」阶段 4 准出：空闲时**根本不出帧**。
//
// 阶段 1~3 收的是重绘范围（RepaintBoundary）和隐藏视图停表（TickerMode）。但
// 只要还有一个 `repeat()` 活着，引擎每个 vsync 都要排一帧——停在欢迎页、空编辑
// 区、任意一屏都一样，Task Manager 里就是一条下不来的 GPU 占用。所以这一阶段
// 钉的是「谁在排帧」而不是「重绘多大」：
//   1. PulseDot 只在状态变化时呼吸几下，之后自行停表（旧实现是永久 repeat，
//      而这条状态栏在所有桌面壳的每一屏都在 → 全局空闲出帧的主因）；
//   2. 欢迎页（CreationShell 空编辑区）settle 之后不再排帧；
//   3. MotionGate：失焦 → 常驻装饰动画停表；最小化 → 整棵子树 ticker 停；
//      回到前台能续播（停过头 = 界面死掉）；
//   4. 系统「减少动画」→ 装饰动画不播，且内容必须落在**终态**（不能停在
//      opacity 0 上等聚焦才显形）。
//
// 判定手段统一用 `SchedulerBinding.hasScheduledFrame`：它等价于「下一帧还要不要
// 出」，正是 GPU 空闲占用的因。
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart' show StringCodec;
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:student_age_editor/core/api_client.dart';
import 'package:student_age_editor/core/models.dart';
import 'package:student_age_editor/core/motion.dart';
import 'package:student_age_editor/core/plugin_state.dart';
import 'package:student_age_editor/core/ui_mode.dart';
import 'package:student_age_editor/features/shell/editor_shell.dart';
import 'package:student_age_editor/features/shell/shell_state.dart';

/// 引擎→App 的生命周期通知走 `flutter/lifecycle` 通道，测试里照该通道喂。
Future<void> _setLifecycle(WidgetTester tester, AppLifecycleState state) async {
  final message = const StringCodec().encodeMessage(state.toString());
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    'flutter/lifecycle',
    message,
    (_) {},
  );
}

/// 推进 n 帧（每帧间隔 [step]），用于等有限动画自然结束。
/// 不用 pumpAndSettle：常驻动画会让它一直转，失败现象是一句超时而不是一句断言。
Future<void> _pumpIdleFrames(WidgetTester tester,
    {int frames = 12, Duration step = const Duration(milliseconds: 400)}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(step);
  }
}

/// 动画刚被 stop 时，本帧的排帧请求已经发出去了（`Ticker.stop` 不撤回它），
/// 停表判定要先把这几帧结算掉，否则会把「最后一帧」误读成「还在出帧」。
Future<void> _settleAfterStop(WidgetTester tester) async {
  for (var i = 0; i < 3; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

/// 取 ShimmerBox 里渐变的起点 x，用来证明动画推不推进。
List<double> shimmerBegins(WidgetTester tester) => [
      for (final e in find.byType(DecoratedBox).evaluate())
        if (((e.widget as DecoratedBox).decoration as BoxDecoration).gradient
            case final LinearGradient g)
          if (g.begin case final Alignment a) a.x,
    ];

void main() {
  testWidgets('PulseDot：呼吸几下后自己停表，不再逐帧排帧', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: Center(child: PulseDot(color: Colors.green))),
    ));
    await tester.pump(const Duration(milliseconds: 100));
    expect(SchedulerBinding.instance.hasScheduledFrame, isTrue,
        reason: '脉冲期间没排帧：动画压根没起来');

    // 2 次 × 1600ms，留足余量后必须彻底静默。
    await _pumpIdleFrames(tester);
    expect(SchedulerBinding.instance.hasScheduledFrame, isFalse,
        reason: 'PulseDot 仍在出帧：永久 repeat() 又回来了');
    expect(find.byType(PulseDot), findsOneWidget, reason: '状态点应当一直可见');
  });

  testWidgets('PulseDot：颜色变了（离线↔在线）才重播一次脉冲', (tester) async {
    Widget wrap(Color color) => MaterialApp(
          home: Scaffold(body: Center(child: PulseDot(color: color))),
        );
    await tester.pumpWidget(wrap(Colors.green));
    await _pumpIdleFrames(tester);
    expect(SchedulerBinding.instance.hasScheduledFrame, isFalse);

    // 换色 → 重新呼吸几下，然后再次停表。
    await tester.pumpWidget(wrap(Colors.red));
    await tester.pump(const Duration(milliseconds: 100));
    expect(SchedulerBinding.instance.hasScheduledFrame, isTrue,
        reason: '状态变化没有触发脉冲：提示意义丢了');
    await _pumpIdleFrames(tester);
    expect(SchedulerBinding.instance.hasScheduledFrame, isFalse);
  });

  testWidgets('MotionGate：失焦停装饰动画、最小化停整棵子树、回焦点续播',
      (tester) async {
    // 树里同时放两种 ticker：
    //   * ShimmerBox —— 本 App 自绘的常驻装饰动画，受 focused 闸门管；
    //   * CircularProgressIndicator —— 框架转圈，只有 visible 闸门（TickerMode）
    //     能停。两条判据必须彼此独立，不然「失焦」会误伤过渡/转圈。
    await tester.pumpWidget(const MotionGate(
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ShimmerBox(width: 80, height: 10),
            CircularProgressIndicator(),
          ],
        ),
      ),
    ));
    await tester.pump();
    expect(SchedulerBinding.instance.hasScheduledFrame, isTrue);

    // 失焦（桌面：点到别的窗口）→ 只剩装饰动画该停：渐变不再推进。
    await _setLifecycle(tester, AppLifecycleState.inactive);
    await _settleAfterStop(tester);
    final a = shimmerBegins(tester);
    await tester.pump(const Duration(milliseconds: 300));
    expect(shimmerBegins(tester), equals(a), reason: '失焦后装饰动画还在推进');
    expect(SchedulerBinding.instance.hasScheduledFrame, isTrue,
        reason: '失焦不该连框架转圈一起停（那会把过渡/加载冻住）');

    // 最小化 → TickerMode 兜住整棵子树：框架转圈也停，后台彻底零帧。
    await _setLifecycle(tester, AppLifecycleState.hidden);
    await _settleAfterStop(tester);
    expect(SchedulerBinding.instance.hasScheduledFrame, isFalse,
        reason: '最小化后仍在出帧：TickerMode 没兜住框架动画');

    // 回到前台 → 两条闸门都开，动画续播（停过头 = 界面死掉）。
    await _setLifecycle(tester, AppLifecycleState.resumed);
    await tester.pump();
    expect(SchedulerBinding.instance.hasScheduledFrame, isTrue,
        reason: '恢复聚焦后动画没接着跑');
    final b = shimmerBegins(tester);
    await tester.pump(const Duration(milliseconds: 200));
    expect(shimmerBegins(tester), isNot(equals(b)), reason: '恢复后渐变没续推');
  });

  testWidgets('系统「减少动画」：装饰动画不播，内容落在终态', (tester) async {
    // 不套 MaterialApp：首帧的页面过渡自己会排帧，会把「谁在排帧」这个问题搅浑。
    Widget app({required bool reduce}) => MediaQuery(
          data: MediaQueryData(disableAnimations: reduce),
          child: MotionGate(
            child: Directionality(
              textDirection: TextDirection.ltr,
              child: Center(
                child: Column(
                  children: [
                    const ShimmerBox(width: 80, height: 10),
                    FadeSlide(key: const Key('fs'), child: const Text('欢迎')),
                  ],
                ),
              ),
            ),
          ),
        );

    await tester.pumpWidget(app(reduce: true));
    await _settleAfterStop(tester);
    expect(SchedulerBinding.instance.hasScheduledFrame, isFalse,
        reason: '减少动画时仍有动画在排帧');
    // FadeSlide/ScaleFade 必须直接给终态：挂着停在 0 的 FadeTransition 会让
    // 内容一直看不见（非但省不了 GPU，还把界面钉死）。
    expect(
      find.descendant(
          of: find.byKey(const Key('fs')), matching: find.byType(FadeTransition)),
      findsNothing,
      reason: '减少动画时不该还挂着过渡包装',
    );
    expect(find.text('欢迎'), findsOneWidget);

    // 关掉减少动画：内容照旧可见，且不是从 opacity 0 重播。
    await tester.pumpWidget(app(reduce: false));
    await tester.pump();
    final ft = tester.widgetList<FadeTransition>(
      find.descendant(
          of: find.byKey(const Key('fs')), matching: find.byType(FadeTransition)),
    );
    expect(ft.every((w) => w.opacity.value > 0.99), isTrue,
        reason: '恢复后把已展示的入口动画从透明重播：内容会闪没');
  });

  testWidgets('欢迎页空闲零排帧：CreationShell settle 后不再出帧', (tester) async {
    // 端到端钉住本次的症状：「停在欢迎页/空编辑区，GPU 也降不下来」。这条走真壳层
    // （含状态栏那颗曾经永久呼吸的 PulseDot），settle 之后必须彻底不排帧。
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
        // 在线状态打开：状态栏那颗曾经永久呼吸的 PulseDot 才会挂上，
        // 「空闲零排帧」才是在真场景里被验证的。
        state: AppState()..setBackendOnline(true),
        shell: ShellState()..toggleAi(),
        pluginState: PluginState(),
        uiMode: UiMode.creation,
        onUiModeChanged: (_) {},
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // 前提成立：欢迎页与状态栏那颗在线点都在画面里。
    expect(find.text('学生时代模组编辑器'), findsOneWidget);
    expect(find.byType(PulseDot), findsOneWidget);

    await _pumpIdleFrames(tester, frames: 24);
    expect(SchedulerBinding.instance.hasScheduledFrame, isFalse,
        reason: '欢迎页空闲仍在出帧：又有常驻动画漏进来了');
    expect(tester.takeException(), isNull);
  });

  testWidgets('MotionScope 缺省=放行：不挂闸门时动画照旧跑（阶段 3 行为不变）',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: Center(child: ShimmerBox(width: 80, height: 10))),
    ));
    await tester.pump();
    expect(SchedulerBinding.instance.hasScheduledFrame, isTrue);
    final a = shimmerBegins(tester);
    await tester.pump(const Duration(milliseconds: 200));
    expect(shimmerBegins(tester), isNot(equals(a)));
  });
}
