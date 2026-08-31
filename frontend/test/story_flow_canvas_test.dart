import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;

import 'package:student_age_editor/features/story/story_flow_graph.dart';
import 'package:student_age_editor/features/story/story_flow_models.dart';

/// 画布交互回归测试：内联编辑区的滚轮隔离、删除入口（按钮/键盘）、
/// 缩放状态下的节点命中。
void main() {
  const nodeId = '1000001001';

  late FlowGraph graph;
  late Map<String, TextEditingController> ctls;
  late Set<String> expanded;
  late List<String> deletedNodes;
  late int requestDeleteCalls;
  late List<String> toggleExpandCalls;
  late String? selected;

  setUp(() {
    final talks = <String, dynamic>{
      nodeId: {'roleName': '旁白', 'content': 'a', 'nextTalk': []},
    };
    graph = buildFlowGraph(
        talks: talks, options: {}, prefixes: ['1000001'], starts: [nodeId]);
    ctls = {};
    expanded = {};
    deletedNodes = [];
    requestDeleteCalls = 0;
    toggleExpandCalls = [];
    selected = null;
  });

  TextEditingController ctlFor(String id, String field) =>
      ctls.putIfAbsent('$id|$field', () => TextEditingController(text: ''));

  // 回调触发后需以新的 selected/expanded 重建（模拟宿主 setState）。
  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      home: fluent.FluentTheme(
        data: fluent.FluentThemeData(brightness: Brightness.dark),
        child: Scaffold(
          body: SizedBox(
            width: 900,
            height: 700,
            child: StoryFlowGraph(
              graph: graph,
              positions: const {nodeId: Offset(100, 100)},
              selectedNode: selected,
              expandedNodes: expanded,
              onSelectNode: (id) => selected = id,
              onSelectEdge: (_) {},
              onSelectNone: () => selected = null,
              onMoveNode: (_, _) {},
              onAddEdge: (_, _, _) {},
              onDeleteEdge: (_, _, _) {},
              onRequestDelete: () => requestDeleteCalls++,
              onToggleExpand: (id) => toggleExpandCalls.add(id),
              fieldController: ctlFor,
              onFieldChanged: (_, _, _) {},
              onDeleteNode: deletedNodes.add,
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  /// 发送滚轮信号（PointerSignalEvent 按事件位置逐次命中测试，无需注册指针）。
  Future<void> wheel(WidgetTester tester, Offset pos, double dy) async {
    await tester.sendEventToBinding(PointerScrollEvent(
      position: pos,
      scrollDelta: Offset(0, dy),
    ));
    await tester.pumpAndSettle();
  }

  double editorScrollOffset(WidgetTester tester) {
    final scrollable = find.descendant(
        of: find.byType(StoryFlowGraph), matching: find.byType(Scrollable));
    return tester
        .state<ScrollableState>(scrollable.first)
        .position
        .pixels;
  }

  group('展开内联编辑器', () {
    testWidgets('点击删除按钮调用 onDeleteNode', (tester) async {
      expanded.add(nodeId);
      await pump(tester);
      expect(find.text('参数'), findsOneWidget);
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      expect(deletedNodes, [nodeId]);
    });

    testWidgets('展开对白节点含 screenEffect 编辑行', (tester) async {
      expanded.add(nodeId);
      await pump(tester);
      expect(find.textContaining('屏幕效果 screenEffect'), findsOneWidget);
      // 选项类字段不应出现在对白编辑区
      expect(find.textContaining('主支对白'), findsNothing);
    });

    testWidgets('编辑区内的滚轮只滚编辑区，不缩放画布', (tester) async {
      expanded.add(nodeId);
      await pump(tester);
      final textBox = find.byType(fluent.TextBox).first;
      final before = tester.getSize(textBox);
      await wheel(tester, const Offset(200, 300), 120);
      final after = tester.getSize(textBox);
      expect(after, before, reason: '画布被缩放：滚轮穿透到了画布 zoom');
      expect(editorScrollOffset(tester), greaterThan(0.0),
          reason: '编辑区自身应可滚动');
    });

    testWidgets('空白画布上的滚轮仍然缩放', (tester) async {
      expanded.add(nodeId);
      await pump(tester);
      final textBox = find.byType(fluent.TextBox).first;
      final before = tester.getSize(textBox).width;
      await wheel(tester, const Offset(600, 500), -120);
      final after = tester.getSize(textBox).width;
      expect(after, isNot(before), reason: '画布空白处滚轮应缩放视图');
    });
  });

  group('删除入口', () {
    testWidgets('选中节点后按 Delete 键触发 onRequestDelete', (tester) async {
      await pump(tester);
      // 点击底座卡片选中节点（不落在端口/箭头上）
      await tester.tapAt(const Offset(150, 130));
      await tester.pumpAndSettle();
      await pump(tester); // 以 selected 重建，模拟宿主 setState
      expect(selected, nodeId);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.delete);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.delete);
      await tester.pumpAndSettle();
      expect(requestDeleteCalls, 1);
    });

    testWidgets('缩放状态下点击卡片实际足迹仍能选中节点', (tester) async {
      await pump(tester);
      // 在空白处 (600,500) 放大 1.1 倍：pan = (600,500)*(-0.1) = (-60,-50)，
      // 节点 (100,100) → 屏幕 (50,60)，卡片足迹 x∈[50,270]、y∈[60,183]。
      // 旧命中矩形宽未乘 scale（右缘 250+4），260 处落空 → 复现该 bug。
      await wheel(tester, const Offset(600, 500), -120);
      await tester.tapAt(const Offset(260, 120));
      await tester.pumpAndSettle();
      expect(selected, nodeId,
          reason: '_nodeScreenRect 宽未乘 scale，缩放后命中区与卡片错位');
    });

    testWidgets('焦点在外部输入框时，点选节点后 Delete 仍可删除', (tester) async {
      // 复现真实应用情形：AI 输入框等拿走过焦点后，点画布节点应把
      // 键盘焦点收回画布，否则 Delete/Backspace 永远传不进 onRequestDelete。
      final fieldFocus = FocusNode();
      Future<void> pumpWithField() async {
        await tester.pumpWidget(MaterialApp(
          home: fluent.FluentTheme(
            data: fluent.FluentThemeData(brightness: Brightness.dark),
            child: Scaffold(
              body: Column(
                children: [
                  SizedBox(height: 30, child: TextField(focusNode: fieldFocus)),
                  Expanded(
                    child: StoryFlowGraph(
                      graph: graph,
                      positions: const {nodeId: Offset(100, 100)},
                      selectedNode: selected,
                      expandedNodes: expanded,
                      onSelectNode: (id) => selected = id,
                      onSelectEdge: (_) {},
                      onSelectNone: () => selected = null,
                      onMoveNode: (_, _) {},
                      onAddEdge: (_, _, _) {},
                      onDeleteEdge: (_, _, _) {},
                      onRequestDelete: () => requestDeleteCalls++,
                      onToggleExpand: (id) => toggleExpandCalls.add(id),
                      fieldController: ctlFor,
                      onFieldChanged: (_, _, _) {},
                      onDeleteNode: deletedNodes.add,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ));
        await tester.pumpAndSettle();
      }

      await pumpWithField();
      await tester.tapAt(const Offset(20, 15)); // 点外部文本框，焦点离开画布
      await tester.pumpAndSettle();
      expect(fieldFocus.hasFocus, isTrue);
      await tester.tapAt(const Offset(150, 130)); // 点选节点
      await tester.pumpAndSettle();
      await pumpWithField(); // 以 selected 重建，模拟宿主 setState
      expect(selected, nodeId);
      expect(fieldFocus.hasFocus, isFalse,
          reason: '点选画布节点后画布应收回键盘焦点');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.delete);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.delete);
      await tester.pumpAndSettle();
      expect(requestDeleteCalls, 1);
      fieldFocus.dispose();
    });
  });
}
