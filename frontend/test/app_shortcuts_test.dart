// A2 全局快捷键 + 命令面板测试。
//
// 覆盖（见 plan/ux_roadmap_r2.md A2 验收）：
// - 模糊过滤：空查询原样返回、子串优先、多词全命中；
// - Ctrl+K 打开命令面板、输入过滤、Enter 执行选中命令；
// - **文本框聚焦时 Ctrl+S 不被吞**（仍触发保存，且焦点不丢）；
// - Ctrl+F 触发剧情库检索回调；
// - 未就绪（enabled=false）时不抢按键。
//
// W1（UX R3）追加：
// - SaveHub 登记栈语义（LIFO / 注销回退）；
// - SaveBar 可见时 Ctrl+S 落到它登记的工作台保存句柄；隐藏（TickerMode
//   disabled，即导演壳 Offstage 保活 / 移动壳 IndexedStack 的隐藏页）不抢键；
// - 可见性来回切换时 SaveHub.active 跟随（didChangeDependencies 重新裁决）；
// - `ShellState.openSearch` 的 Ctrl+F 解析：壳登记优先、否则回退检索面板。
//
// 每个用例结束时都把面板关掉 / 让信息条的定时器走完，避免残留
// pending timer 影响其它用例。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:student_age_editor/core/api_client.dart';
import 'package:student_age_editor/core/app_command.dart';
import 'package:student_age_editor/core/app_feedback.dart';
import 'package:student_age_editor/core/app_shortcuts.dart';
import 'package:student_age_editor/core/command_palette.dart';
import 'package:student_age_editor/core/save_bar.dart';
import 'package:student_age_editor/core/save_hub.dart';
import 'package:student_age_editor/core/workbench_controller.dart';
import 'package:student_age_editor/features/shell/shell_state.dart';

AppCommand _cmd(
  String id,
  String label, {
  String description = '',
  void Function()? onRun,
}) {
  return AppCommand(
    id: id,
    label: label,
    description: description,
    category: AppCommandCategory.action,
    run: (context) async => onRun?.call(),
  );
}

/// 按住 Ctrl 敲一个键（Windows 平台修饰键语义），随后静置。
Future<void> pressCtrl(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(key);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pumpAndSettle();
}

/// app.dart `_saveCurrent()` 的同款解析：活动工作台句柄优先，其次（本测试
/// 不涉及）壳登记的 host.save。返回 false = 当前没有可保存的内容。
Future<bool> saveViaHub(SaveHub hub) async {
  final handle = hub.active;
  if (handle != null && handle.canSave()) {
    await handle.save();
    return true;
  }
  return false;
}

/// app.dart `_undoCurrent()` 的同款解析（N12）。
Future<bool> undoViaHub(SaveHub hub) async {
  final handle = hub.active;
  if (handle == null || !(handle.canUndo?.call() ?? false)) return false;
  await handle.undo?.call();
  return true;
}

/// app.dart `_redoCurrent()` 的同款解析（N12）。
Future<bool> redoViaHub(SaveHub hub) async {
  final handle = hub.active;
  if (handle == null || !(handle.canRedo?.call() ?? false)) return false;
  await handle.redo?.call();
  return true;
}

/// 信息条（AppFeedback.info）先渲染空占位，过 mediumAnimationDuration 才把
/// 内容塞进 Overlay 且定时器不排帧——显式跨过该时长再静置，让内容可见。
Future<void> pumpInfoBarIn(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 500));
  await tester.pumpAndSettle();
}

/// 让 InfoBar 的自动关闭计时器走完（约 4s），避免残留 pending timer；
/// 必须在「已断言信息条内容」之后调用。
Future<void> drainInfoBar(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 4));
  await tester.pumpAndSettle();
}

Future<void> pumpShortcuts(
  WidgetTester tester, {
  required List<AppCommand> Function(BuildContext context) commands,
  Widget? child,
  bool enabled = true,
  Future<bool> Function()? onSave,
  VoidCallback? onSearch,
  Future<bool> Function()? onUndo,
  Future<bool> Function()? onRedo,
  SaveHub? hub,
}) async {
  Widget tree = AppShortcuts(
    enabled: enabled,
    commands: commands,
    onSave: onSave,
    onSearch: onSearch,
    onUndo: onUndo,
    onRedo: onRedo,
    child: child ?? const SizedBox.expand(),
  );
  // SaveHubScope 挂在 Navigator 之上（app.dart 同款位置）：home 与后续
  // 全屏子页里的 SaveBar 都能找到它。
  if (hub != null) tree = SaveHubScope(hub: hub, child: tree);
  await tester.pumpWidget(
    fluent.FluentApp(
      debugShowCheckedModeBanner: false,
      home: tree,
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  // AppFeedback 的同文案去重基于真实时钟（widget 测试的 pump 只推进虚拟
  // 时间）：每个用例开始前清空，避免前一用例刚弹过的提示被误判为「连点」。
  setUp(AppFeedback.debugResetDedupe);

  group('filterCommands', () {
    final all = <AppCommand>[
      _cmd('page:person', '人物', description: '角色与成长'),
      _cmd('feature:crafts', '手工', description: '手工玩法'),
      _cmd('action:search', '剧情库检索', description: '原版事件与台词全文检索'),
    ];

    test('空查询原样返回', () {
      expect(filterCommands(all, ''), all);
      expect(filterCommands(all, '   '), all);
    });

    test('子串命中', () {
      final r = filterCommands(all, '人物');
      expect(r, hasLength(1));
      expect(r.first.id, 'page:person');
    });

    test('顺序子序列命中（跨词跳跃）', () {
      final r = filterCommands(all, '剧情检索');
      expect(r.map((c) => c.id), contains('action:search'));
    });

    test('多词需全部命中', () {
      expect(filterCommands(all, '人物 检索'), isEmpty);
      final r = filterCommands(all, '剧情 台词');
      expect(r, hasLength(1));
      expect(r.first.id, 'action:search');
    });

    test('无命中返回空', () {
      expect(filterCommands(all, 'zzz'), isEmpty);
    });
  });

  testWidgets('Ctrl+K 打开命令面板并列出命令', (tester) async {
    await pumpShortcuts(
      tester,
      commands: (_) => [_cmd('a', '打开设置'), _cmd('b', '剧情库检索')],
    );

    expect(find.byKey(const ValueKey('command-palette')), findsNothing);
    await pressCtrl(tester, LogicalKeyboardKey.keyK);

    expect(find.byKey(const ValueKey('command-palette')), findsOneWidget);
    expect(find.text('打开设置'), findsOneWidget);
    expect(find.text('剧情库检索'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
  });

  testWidgets('输入过滤 + Enter 执行选中命令，面板关闭', (tester) async {
    String? ran;
    await pumpShortcuts(
      tester,
      commands: (_) => [
        _cmd('a', '打开设置', onRun: () => ran = 'a'),
        _cmd('b', '剧情库检索', onRun: () => ran = 'b'),
      ],
    );

    await pressCtrl(tester, LogicalKeyboardKey.keyK);
    await tester.enterText(find.byType(EditableText), '检索');
    await tester.pumpAndSettle();
    // 过滤后只剩「剧情库检索」。
    expect(find.text('打开设置'), findsNothing);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(ran, 'b');
    expect(find.byKey(const ValueKey('command-palette')), findsNothing);
  });

  testWidgets('文本框聚焦时 Ctrl+S 仍触发保存（不被吞）', (tester) async {
    var saved = 0;
    final field = FocusNode();
    addTearDown(field.dispose);

    await pumpShortcuts(
      tester,
      commands: (_) => const <AppCommand>[],
      onSave: () async {
        saved++;
        return true;
      },
      child: Scaffold(body: TextField(focusNode: field)),
    );

    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    expect(field.hasFocus, isTrue);

    await pressCtrl(tester, LogicalKeyboardKey.keyS);

    expect(saved, 1);
    expect(field.hasFocus, isTrue, reason: '保存不应把焦点从输入框里抢走');

    field.unfocus();
    await tester.pumpAndSettle();
  });

  testWidgets('没有保存处理器时给出「无可保存内容」提示', (tester) async {
    await pumpShortcuts(
      tester,
      commands: (_) => const <AppCommand>[],
    );

    await pressCtrl(tester, LogicalKeyboardKey.keyS);

    // fluent 的 displayInfoBar 先渲染一个空占位（isFading=true），要等一个
    // mediumAnimationDuration 的定时器到点后才把真正的内容塞进 Overlay；
    // 定时器不排帧，pumpAndSettle 会提前返回，故这里显式跨过该时长。
    await pumpInfoBarIn(tester);

    expect(find.text('当前界面没有可保存的内容'), findsOneWidget);
    await drainInfoBar(tester);
  });

  testWidgets('Ctrl+F 触发剧情库检索回调', (tester) async {
    var searched = 0;
    await pumpShortcuts(
      tester,
      commands: (_) => const <AppCommand>[],
      onSearch: () => searched++,
    );

    await pressCtrl(tester, LogicalKeyboardKey.keyF);

    expect(searched, 1);
  });

  testWidgets('未就绪时快捷键不生效', (tester) async {
    await pumpShortcuts(
      tester,
      enabled: false,
      commands: (_) => [_cmd('a', '打开设置')],
    );

    await pressCtrl(tester, LogicalKeyboardKey.keyK);

    expect(find.byKey(const ValueKey('command-palette')), findsNothing);
  });

  testWidgets('Esc 关闭命令面板且不执行任何命令', (tester) async {
    String? ran;
    await pumpShortcuts(
      tester,
      commands: (_) => [_cmd('a', '打开设置', onRun: () => ran = 'a')],
    );

    await pressCtrl(tester, LogicalKeyboardKey.keyK);
    expect(find.byKey(const ValueKey('command-palette')), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('command-palette')), findsNothing);
    expect(ran, isNull);
  });

  group('SaveHub 登记栈', () {
    SaveHandle handle(String owner) => SaveHandle(
          debugOwner: owner,
          canSave: () => true,
          save: () async {},
        );

    test('LIFO：最后登记者为 active，注销后回退上一个', () {
      final hub = SaveHub();
      final a = handle('a');
      final b = handle('b');

      expect(hub.active, isNull);
      hub.register(a);
      expect(hub.active, same(a));
      hub.register(b);
      expect(hub.active, same(b));
      hub.unregister(b);
      expect(hub.active, same(a));
      hub.unregister(a);
      expect(hub.active, isNull);
    });

    test('重复登记同一句柄提升到栈顶（不产生重复项）', () {
      final hub = SaveHub();
      final a = handle('a');
      final b = handle('b');

      hub.register(a);
      hub.register(b);
      hub.register(a);
      expect(hub.active, same(a));
      hub.unregister(a);
      expect(hub.active, same(b));
      hub.unregister(a); // 重复注销是 no-op
      expect(hub.active, same(b));
    });
  });

  group('W1 全局 Ctrl+S 落到当前可见的 SaveBar', () {
    Widget saveBar({required Future<void> Function() onSave}) =>
        Scaffold(body: Column(children: [
          const Expanded(child: SizedBox()),
          SaveBar(
            dirty: true,
            onSave: onSave,
            onDiscard: () {},
          ),
        ]));

    testWidgets('可见 SaveBar 已登记，Ctrl+S 调用其保存回调', (tester) async {
      final hub = SaveHub();
      var saved = 0;
      await pumpShortcuts(
        tester,
        commands: (_) => const <AppCommand>[],
        hub: hub,
        onSave: () => saveViaHub(hub),
        child: saveBar(onSave: () async => saved++),
      );

      expect(hub.active, isNotNull, reason: '可见的保存条应在首帧完成登记');

      await pressCtrl(tester, LogicalKeyboardKey.keyS);

      expect(saved, 1);
      expect(find.text('当前界面没有可保存的内容'), findsNothing);
    });

    testWidgets('隐藏（TickerMode 关闭）的 SaveBar 不登记、不抢 Ctrl+S',
        (tester) async {
      final hub = SaveHub();
      var saved = 0;
      await pumpShortcuts(
        tester,
        commands: (_) => const <AppCommand>[],
        hub: hub,
        onSave: () => saveViaHub(hub),
        // 导演壳 Offstage 保活 / 移动壳 IndexedStack 的隐藏页同款表达。
        child: TickerMode(
          enabled: false,
          child: saveBar(onSave: () async => saved++),
        ),
      );

      expect(hub.active, isNull, reason: '隐藏视图的保存条不得登记');

      await pressCtrl(tester, LogicalKeyboardKey.keyS);

      expect(saved, 0);
      // 无活动句柄时按「无可保存内容」给反馈（原协议不变）。
      await pumpInfoBarIn(tester);
      expect(find.text('当前界面没有可保存的内容'), findsOneWidget);
      await drainInfoBar(tester);
    });

    testWidgets('可见性切换时登记状态跟随变化', (tester) async {
      final hub = SaveHub();
      final visible = ValueNotifier<bool>(true);
      addTearDown(visible.dispose);

      await pumpShortcuts(
        tester,
        commands: (_) => const <AppCommand>[],
        hub: hub,
        onSave: () => saveViaHub(hub),
        child: ValueListenableBuilder<bool>(
          valueListenable: visible,
          builder: (context, v, _) => TickerMode(
            enabled: v,
            child: saveBar(onSave: () async {}),
          ),
        ),
      );
      expect(hub.active, isNotNull);

      visible.value = false;
      await tester.pumpAndSettle();
      expect(hub.active, isNull, reason: '切到隐藏视图后应注销');

      visible.value = true;
      await tester.pumpAndSettle();
      expect(hub.active, isNotNull, reason: '切回可见后应重新登记');
    });

    testWidgets('SaveBar 不脏（canSave=false）时 Ctrl+S 仍给提示', (tester) async {
      final hub = SaveHub();
      var saved = 0;
      await pumpShortcuts(
        tester,
        commands: (_) => const <AppCommand>[],
        hub: hub,
        onSave: () => saveViaHub(hub),
        child: Scaffold(body: Column(children: [
          const Expanded(child: SizedBox()),
          SaveBar(
            dirty: false,
            onSave: () async => saved++,
            onDiscard: () {},
          ),
        ])),
      );

      await pressCtrl(tester, LogicalKeyboardKey.keyS);

      expect(saved, 0);
      await pumpInfoBarIn(tester);
      expect(find.text('当前界面没有可保存的内容'), findsOneWidget);
      await drainInfoBar(tester);
    });
  });

  group('W1 Ctrl+F 解析（ShellState.openSearch）', () {
    test('壳登记了 openSearch 时优先走壳回调，不动左侧栏', () {
      final shell = ShellState();
      var opened = 0;
      shell.registerCommandHost(AppCommandHost(openSearch: () => opened++));

      shell.openSearch();

      expect(opened, 1);
      expect(shell.pane, SidePane.mods, reason: '壳自己处理时不应切换面板');
    });

    test('壳未登记时回退到左侧栏「检索」面板', () {
      final shell = ShellState();

      shell.openSearch();

      expect(shell.pane, SidePane.base);
    });
  });

  group('N12 Ctrl+Z / Ctrl+Y 落到当前可见工作台', () {
    setUp(() {
      ApiClient.instance.client = MockClient((req) async => http.Response(
          '{"data":{"1":{"name":"甲"}},"mtime_ns":1}',
          200,
          headers: {'content-type': 'application/json'}));
    });

    tearDown(() {
      ApiClient.instance.client = http.Client();
    });

    WorkbenchController makeCtl() {
      final ctl = WorkbenchController(cfgs: const ['ATable']);
      addTearDown(ctl.dispose);
      return ctl;
    }

    Widget bar(WorkbenchController ctl) => Scaffold(
          body: Column(children: [
            const Expanded(child: SizedBox()),
            SaveBar(
              dirty: true,
              onSave: () async {},
              onDiscard: () {},
              history: ctl,
            ),
          ]),
        );

    testWidgets('Ctrl+Z 撤销工作台的一步编辑，Ctrl+Y 重做', (tester) async {
      final ctl = makeCtl();
      await ctl.load();
      ctl.table('ATable').data['x'] = 1; // 待撤销的一步编辑
      final hub = SaveHub();

      await pumpShortcuts(
        tester,
        commands: (_) => const <AppCommand>[],
        hub: hub,
        onUndo: () => undoViaHub(hub),
        onRedo: () => redoViaHub(hub),
        child: bar(ctl),
      );
      expect(hub.active, isNotNull, reason: '可见 SaveBar 应已登记（含撤销/重做能力）');

      await pressCtrl(tester, LogicalKeyboardKey.keyZ);
      expect(ctl.table('ATable').data.containsKey('x'), isFalse,
          reason: 'Ctrl+Z 应撤销工作台数据');

      await pressCtrl(tester, LogicalKeyboardKey.keyY);
      expect(ctl.table('ATable').data['x'], 1, reason: 'Ctrl+Y 应重做');

      await pressCtrl(tester, LogicalKeyboardKey.keyY);
      expect(ctl.canRedo, isFalse, reason: '重做链耗尽后 Ctrl+Y 静默');
    });

    testWidgets('聚焦文本框时 Ctrl+Z 留给文本撤销，不触发工作台撤销', (tester) async {
      final ctl = makeCtl();
      await ctl.load();
      ctl.table('ATable').data['x'] = 1;
      final hub = SaveHub();
      final probe = FocusNode(debugLabel: 'probe');
      addTearDown(probe.dispose);

      await pumpShortcuts(
        tester,
        commands: (_) => const <AppCommand>[],
        hub: hub,
        onUndo: () => undoViaHub(hub),
        onRedo: () => redoViaHub(hub),
        child: Scaffold(
          body: Column(children: [
            fluent.TextBox(autofocus: true),
            const Expanded(child: SizedBox()),
            Focus(focusNode: probe, child: const SizedBox(width: 4, height: 4)),
            SaveBar(
              dirty: true,
              onSave: () async {},
              onDiscard: () {},
              history: ctl,
            ),
          ]),
        ),
      );
      // AppShortcuts 的首帧兜底会先抢到焦点（autofocus 与它竞争）；显式点一下
      // 文本框，让焦点稳定落到文本输入内。
      await tester.tap(find.byType(fluent.TextBox));
      await tester.pumpAndSettle();
      final ctx = FocusManager.instance.primaryFocus?.context;
      expect(ctx?.findAncestorWidgetOfExactType<EditableText>(), isNotNull,
          reason: '前置条件：焦点应落在文本框内');

      await pressCtrl(tester, LogicalKeyboardKey.keyZ);
      expect(ctl.table('ATable').data['x'], 1,
          reason: '文本框内的 Ctrl+Z 不应动工作台数据');
      expect(ctl.canUndo, isTrue, reason: '工作台撤销栈应原样保留');

      // 焦点离开文本框（落到普通控件上）后，Ctrl+Z 恢复落到工作台。
      probe.requestFocus();
      await tester.pumpAndSettle();
      await pressCtrl(tester, LogicalKeyboardKey.keyZ);
      expect(ctl.table('ATable').data.containsKey('x'), isFalse);
    });
  });
}
