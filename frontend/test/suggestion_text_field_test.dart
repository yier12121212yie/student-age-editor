// SuggestionTextField 行为回归：Tab/↑↓/Enter/Esc 的键盘接管 + 插入位置与分隔符。
//
// 这个框的两条设计约束最值得测：
//   1. 按键只在「KeyDown」上生效：按住 Tab 若连发接受，会一口吃掉好几个字段；
//   2. 插入点由「光标向左扫到 token 边界」决定，因此光标不在句尾也不会错位，
//      且光标之后的文本必须原样保留（旧实现用 lastIndexOf(keyword) 会错位）。
import 'dart:async';

import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:student_age_editor/features/editor/suggestion_text_field.dart';

const _cands = <Suggestion>[
  Suggestion('4015', '屏幕效果：模糊'),
  Suggestion('4016', '屏幕效果：震动'),
  Suggestion('4017', '屏幕效果：黑屏'),
];

void main() {
  late TextEditingController ctrl;
  late FocusNode node;

  setUp(() {
    ctrl = TextEditingController();
    node = FocusNode();
  });

  tearDown(() {
    node.dispose();
    ctrl.dispose();
  });

  SuggestionSource sourceOf(List<Suggestion> out) => (_) async => out;

  Future<void> mount(
    WidgetTester tester, {
    SuggestionSource? source,
    bool multivalued = false,
    bool replaceWholeOnAccept = false,
    bool enabled = true,
    VoidCallback? onTabWithoutCandidates,
    ValueChanged<String>? onChanged,
    Widget? second,
    double topGap = 0,
  }) async {
    // 固定逻辑尺寸 800x600：候选层的翻转判定直接依赖视口高度。
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(fluent.FluentApp(
      home: Scaffold(
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(height: topGap),
            SizedBox(
              width: 360,
              child: SuggestionTextField(
                controller: ctrl,
                focusNode: node,
                source: source,
                multivalued: multivalued,
                replaceWholeOnAccept: replaceWholeOnAccept,
                enabled: enabled,
                onTabWithoutCandidates: onTabWithoutCandidates,
                onChanged: onChanged,
              ),
            ),
            if (second != null) SizedBox(width: 360, child: second),
          ],
        ),
      ),
    ));
    await tester.pump();
  }

  /// 走真实 IME 通道写文本：`enterText` 只会把光标停在句尾，这里能指定光标位置。
  Future<void> typeAt(WidgetTester tester, String text, int caret) async {
    await tester.showKeyboard(find.byType(fluent.TextBox).first);
    tester.testTextInput.updateEditingValue(
      TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: caret),
      ),
    );
    await tester.idle();
    await tester.pump();
    // 候选查询有 220ms 防抖。
    await tester.pump(const Duration(milliseconds: 300));
  }

  SuggestionTextFieldState state(WidgetTester tester) => tester
      .state<SuggestionTextFieldState>(
        find.byType(SuggestionTextField).first,
      );

  /// 候选层：以第一条候选的描述文本为锚，往上找承载它的跟随层（翻转断言就看它的 offset）。
  Finder popupLayer() => find
      .ancestor(
        of: find.text(_cands.first.desc),
        matching: find.byType(CompositedTransformFollower),
      )
      .first;

  testWidgets('Tab 接受高亮候选，光标停在插入文本之后', (tester) async {
    String? changed;
    await mount(tester, source: sourceOf(_cands), onChanged: (v) => changed = v);
    await typeAt(tester, '40', 2);
    expect(state(tester).candidateCount, 3, reason: '防抖后应拿到 3 条候选');
    expect(state(tester).overlayOpen, isTrue);
    expect(find.text(_cands.first.desc), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();

    // 非多值 + 光标前没有已完成的值：整段 token（'40'）被候选替换。
    expect(ctrl.text, '4015');
    expect(ctrl.selection.baseOffset, 4, reason: '光标应紧跟在插入文本之后');
    expect(state(tester).overlayOpen, isFalse, reason: '接受后候选层要收起');
    expect(changed, '4015', reason: '宿主必须收到最终文本');
  });

  testWidgets('无候选时 Tab 交给 onTabWithoutCandidates', (tester) async {
    var tabbed = 0;
    await mount(
      tester,
      source: sourceOf(const []),
      onTabWithoutCandidates: () => tabbed++,
    );
    await typeAt(tester, '40', 2);
    expect(state(tester).candidateCount, 0);
    expect(state(tester).overlayOpen, isFalse);

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();

    expect(tabbed, 1, reason: '没有候选时 Tab 必须等于「跳下一个字段」');
    expect(ctrl.text, '40', reason: '不得往框里塞任何东西');
  });

  testWidgets('无候选且无回调时不吞事件：焦点按树序后移', (tester) async {
    final ctrl2 = TextEditingController();
    final node2 = FocusNode();
    addTearDown(ctrl2.dispose);
    addTearDown(node2.dispose);

    await mount(
      tester,
      source: null,
      second: SuggestionTextField(controller: ctrl2, focusNode: node2),
    );
    await typeAt(tester, '40', 2);
    expect(state(tester).candidateCount, 0);

    // 契约本身：既不接受也不回调，必须把事件交回系统。
    expect(
      state(tester).handleKeyEvent(
        node,
        const KeyDownEvent(
          physicalKey: PhysicalKeyboardKey.tab,
          logicalKey: LogicalKeyboardKey.tab,
          timeStamp: Duration.zero,
        ),
      ),
      KeyEventResult.ignored,
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(node2.hasFocus, isTrue, reason: 'Tab 要能正常走到下一个字段');
    expect(node.hasFocus, isFalse);
  });

  testWidgets('按住 Tab 的 KeyRepeatEvent 不会二次触发接受', (tester) async {
    var tabbed = 0;
    await mount(tester, source: sourceOf(_cands), onTabWithoutCandidates: () => tabbed++);
    await typeAt(tester, '40', 2);
    expect(state(tester).candidateCount, 3);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(ctrl.text, '4015', reason: '第一次 down 应当接受候选');
    expect(tabbed, 0);

    // 键还不松：系统接下来发的是 KeyRepeatEvent。
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.tab);
    await tester.pump();

    expect(ctrl.text, '4015', reason: '重复事件不得再接受一条候选');
    expect(tabbed, 0, reason: '重复事件也不得当成「跳到下一字段」——按住就吃掉整排字段');
    expect(
      state(tester).handleKeyEvent(
        node,
        const KeyRepeatEvent(
          physicalKey: PhysicalKeyboardKey.tab,
          logicalKey: LogicalKeyboardKey.tab,
          timeStamp: Duration(milliseconds: 500),
        ),
      ),
      KeyEventResult.ignored,
      reason: 'handleKeyEvent 必须把 KeyRepeatEvent 整个忽略',
    );
  });

  testWidgets('↑↓ 只移动高亮，不改文本也不动光标', (tester) async {
    await mount(tester, source: sourceOf(_cands));
    await typeAt(tester, '40', 2);
    expect(state(tester).overlayOpen, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();

    expect(ctrl.text, '40', reason: '上下键只用于选候选');
    expect(ctrl.selection.baseOffset, 2);
    expect(state(tester).overlayOpen, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(ctrl.text, '4016', reason: '↓↓↑ 之后高亮应停在第 2 条');
    expect(ctrl.selection.baseOffset, 4);
  });

  testWidgets('↑ 在首条不再下越界，↓ 在末条不再上越界', (tester) async {
    await mount(tester, source: sourceOf(_cands));
    await typeAt(tester, '40', 2);
    for (var i = 0; i < 5; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(ctrl.text, '4015', reason: '钳在首条');

    await typeAt(tester, '40', 2);
    for (var i = 0; i < 5; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(ctrl.text, '4017', reason: '钳在末条');
  });

  testWidgets('多值字段补 ", " 分隔并保留光标之后的文本', (tester) async {
    await mount(tester, source: sourceOf(_cands), multivalued: true);
    // 光标停在 '200' 之后：token='200' 被替换，',300' 必须整段留下。
    await typeAt(tester, '[100]200,300', 8);
    expect(state(tester).candidateCount, 3);

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();

    expect(ctrl.text, '[100], 4015,300');
    expect(ctrl.selection.baseOffset, 11, reason: '光标停在插入文本之后，不是整串末尾');
  });

  testWidgets('光标前已是逗号时只补空格，不重复逗号', (tester) async {
    await mount(tester, source: sourceOf(_cands), multivalued: true);
    await typeAt(tester, '100,200', 7);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(ctrl.text, '100, 4015');
    expect(ctrl.text, isNot(contains(',,')), reason: '不得出现双逗号');
  });

  testWidgets('2D：光标前最后一个分隔符是分号时沿用分号', (tester) async {
    await mount(tester, source: sourceOf(_cands), multivalued: true);
    await typeAt(tester, '1,2;[30]40', 10);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(ctrl.text, '1,2;[30]; 4015', reason: '沿用分号=另起一行');
    expect(ctrl.selection.baseOffset, 14);
  });

  testWidgets('2D：用户已自己打了分号时不得再补一个分号', (tester) async {
    await mount(tester, source: sourceOf(_cands), multivalued: true);
    await typeAt(tester, '1,2;3', 5);
    expect(state(tester).candidateCount, 3);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    // token 边界扫描必然把已输入的 `;` 留在前缀里，此时只补空格；
    // 早先的版本先判 lastSemi>lastComma 直接返回 `; `，会拼出 `1,2;; 4015`。
    expect(ctrl.text, '1,2; 4015');
    expect(ctrl.text, isNot(contains(';;')), reason: '不得出现双分号');
    expect(ctrl.selection.baseOffset, 9);
  });

  testWidgets('分隔符后已有空格时不再补任何分隔符', (tester) async {
    await mount(tester, source: sourceOf(_cands), multivalued: true);
    // 「`; ` 分隔符 + 半个数字」正是 ValueCodec.encode 的输出形状。
    await typeAt(tester, '1,2; 3', 6);
    expect(state(tester).candidateCount, 3);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(ctrl.text, '1,2; 4015', reason: '已有 `; ` 就只替换 token，不再补分隔符');
    expect(ctrl.text, isNot(contains('  ')), reason: '不得出现双空格');
  });

  testWidgets('replaceWholeOnAccept：接受候选整串替换', (tester) async {
    await mount(
      tester,
      source: sourceOf(_cands),
      replaceWholeOnAccept: true,
      multivalued: true,
    );
    await typeAt(tester, '震动,3;模糊', 7);
    expect(state(tester).candidateCount, 3);

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();

    expect(
      ctrl.text,
      '4015',
      reason: 'screenEffect 一行只允许一个屏幕效果，旧效果必须整条清掉',
    );
    expect(ctrl.selection.baseOffset, 4);
  });

  testWidgets('Enter 接受高亮候选，Esc 只收候选', (tester) async {
    var tabbed = 0;
    await mount(
      tester,
      source: sourceOf(_cands),
      onTabWithoutCandidates: () => tabbed++,
    );
    await typeAt(tester, '40', 2);
    expect(state(tester).candidateCount, 3);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(ctrl.text, '4015', reason: 'Enter 与 Tab 一样接受候选');
    expect(ctrl.text, isNot(contains('\n')), reason: '单行框不得插入换行');

    // Esc 只收起候选层：文本不动，收起来之后那批候选不得再被接受。
    await typeAt(tester, '震', 1);
    expect(state(tester).candidateCount, 3);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(state(tester).overlayOpen, isFalse);
    expect(state(tester).candidateCount, 0);
    expect(ctrl.text, '震', reason: 'Esc 只收层，不能顺手改文本');

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(ctrl.text, '震', reason: 'Esc 之后再按 Tab 不应接受过期候选');
    expect(tabbed, 1, reason: '没有候选了，Tab 就是跳字段');
  });

  testWidgets('宿主从外部改文本要收起候选（否则旧候选会被误接受）', (tester) async {
    await mount(tester, source: sourceOf(_cands));
    await typeAt(tester, '40', 2);
    expect(state(tester).candidateCount, 3);

    // 撤销回滚 / 资产拖放：直接写 controller，不经过输入框。
    ctrl.value = TextEditingValue(
      text: '外部回填',
      selection: const TextSelection.collapsed(offset: 4),
    );
    await tester.pump();

    expect(state(tester).candidateCount, 0);
    expect(state(tester).overlayOpen, isFalse);
  });

  testWidgets('请求期间的过期候选要丢弃', (tester) async {
    final first = Completer<List<Suggestion>>();
    final second = Completer<List<Suggestion>>();
    var calls = 0;
    await mount(
      tester,
      source: (_) {
        calls++;
        return calls == 1 ? first.future : second.future;
      },
    );
    await typeAt(tester, '40', 2);
    expect(calls, 1);
    await typeAt(tester, '409', 3);
    expect(calls, 2, reason: '新 token 应重新查询');

    first.complete(const [Suggestion('AAA', '过期批次')]);
    await tester.pump();
    expect(state(tester).candidateCount, 0, reason: 'token 已变成 409，40 那批必须丢弃');

    second.complete(_cands);
    await tester.pump();
    expect(state(tester).candidateCount, 3);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(ctrl.text, '4015');
  });

  testWidgets('光标在方括号内是在填参数，不提示', (tester) async {
    var calls = 0;
    await mount(
      tester,
      source: (_) {
        calls++;
        return Future.value(_cands);
      },
    );
    await typeAt(tester, '4015[压', 5);
    expect(calls, 0, reason: 'token 里有未闭合方括号时不该发起查询');
    expect(state(tester).candidateCount, 0);
  });

  testWidgets('enabled=false 不查候选，退化成普通输入框', (tester) async {
    var calls = 0;
    await mount(
      tester,
      enabled: false,
      source: (_) {
        calls++;
        return Future.value(_cands);
      },
    );
    await typeAt(tester, '40', 2);
    expect(calls, 0);
    expect(state(tester).candidateCount, 0);
    expect(ctrl.text, '40', reason: '只读态不该被改写');
  });

  testWidgets('候选默认画在输入框下方', (tester) async {
    await mount(tester, source: sourceOf(_cands));
    await typeAt(tester, '40', 2);
    expect(state(tester).overlayOpen, isTrue);
    expect(
      tester.widget<CompositedTransformFollower>(popupLayer()).offset.dy,
      greaterThan(0),
    );
  });

  testWidgets('下方空间不足时候选层向上翻转', (tester) async {
    await mount(tester, source: sourceOf(_cands), topGap: 500);
    await typeAt(tester, '40', 2);
    expect(state(tester).overlayOpen, isTrue);

    final dy = tester.widget<CompositedTransformFollower>(popupLayer()).offset.dy;
    expect(dy, lessThan(0), reason: '输入框贴底时候选必须画到上方，否则整层看不见');
    // 翻转后不能溢出视口上沿：层最高 168。
    final top = tester.getTopLeft(find.byType(fluent.TextBox).first).dy;
    expect(top + dy, greaterThanOrEqualTo(0));
    expect(tester.takeException(), isNull);
  });
}
