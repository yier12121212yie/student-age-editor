// U1 回归：切换文档前必须先确认未保存修改，并支持「放弃并切换 / 取消」。
//
// 背景：页面列表、文件树、命令面板、导演壳、配置表下拉此前都直接
// controller.open()，会用新视图覆盖旧 SchemaEditorView 的内存改动。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:student_age_editor/core/editor_leave_guard.dart';
import 'package:student_age_editor/features/editor/editor_controller.dart';

void main() {
  Future<EditorController> pump(WidgetTester tester) async {
    final controller = EditorController();
    controller.open(OpenDoc.cfg(cfgName: 'A'));
    controller.markDirty(controller.current!, true);

    await tester.pumpWidget(fluent.FluentApp(
      debugShowCheckedModeBanner: false,
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: fluent.Button(
              key: const Key('switch'),
              onPressed: () => openDocGuarded(
                context,
                controller,
                OpenDoc.cfg(cfgName: 'B'),
              ),
              child: const Text('切换'),
            ),
          ),
        ),
      ),
    ));
    return controller;
  }

  testWidgets('脏文档切换弹确认；取消保持原文档', (tester) async {
    final controller = await pump(tester);
    await tester.tap(find.byKey(const Key('switch')));
    await tester.pumpAndSettle();

    expect(find.text('有未保存的修改'), findsOneWidget);
    expect(find.text('放弃并切换文档'), findsOneWidget);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(controller.current?.cfgName, 'A');
    expect(controller.isDirty(controller.current!), isTrue);
  });

  testWidgets('选择放弃后切换并清掉脏标记', (tester) async {
    final controller = await pump(tester);
    await tester.tap(find.byKey(const Key('switch')));
    await tester.pumpAndSettle();

    await tester.tap(find.text('放弃并切换文档'));
    await tester.pumpAndSettle();

    expect(controller.current?.cfgName, 'B');
    expect(controller.isDirty(OpenDoc.cfg(cfgName: 'A')), isFalse);
  });

  testWidgets('干净文档切换不弹确认', (tester) async {
    final controller = await pump(tester);
    controller.markDirty(controller.current!, false);

    await tester.tap(find.byKey(const Key('switch')));
    await tester.pumpAndSettle();

    expect(find.text('有未保存的修改'), findsNothing);
    expect(controller.current?.cfgName, 'B');
  });
}
