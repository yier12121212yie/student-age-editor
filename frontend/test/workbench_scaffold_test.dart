// WorkbenchScaffold（工作台三栏骨架）行为测试：
// - 宽布局三栏并排；
// - 窄布局右栏收成 rail，点击以浮层展开（能力不丢），点遮罩收起。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:student_age_editor/core/workbench_scaffold.dart';

void main() {
  Future<void> pumpScaffold(WidgetTester tester, double width) async {
    tester.view.physicalSize = Size(width, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      fluent.FluentApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          body: WorkbenchScaffold(
            leftBuilder: (_) => const ColoredBox(
              color: Color(0xFF111111),
              child: Center(child: Text('LEFT')),
            ),
            center: const Center(child: Text('CENTER')),
            rightBuilder: (_) => const Center(child: Text('RIGHT')),
            rightLabel: '设置',
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('宽布局：三栏并排', (tester) async {
    await pumpScaffold(tester, 1400);
    expect(find.text('LEFT'), findsOneWidget);
    expect(find.text('CENTER'), findsOneWidget);
    expect(find.text('RIGHT'), findsOneWidget);
    // 宽布局无 rail。
    expect(find.byTooltip('展开设置'), findsNothing);
  });

  testWidgets('窄布局：右栏收成 rail，点击展开、点遮罩收起', (tester) async {
    await pumpScaffold(tester, 900);
    expect(find.text('LEFT'), findsOneWidget);
    expect(find.text('CENTER'), findsOneWidget);
    // 右栏不再并排，而是隐藏在 rail 之后。
    expect(find.text('RIGHT'), findsNothing);
    expect(find.byTooltip('展开设置'), findsOneWidget);

    await tester.tap(find.byTooltip('展开设置'));
    await tester.pump();
    expect(find.text('RIGHT'), findsOneWidget, reason: '展开后右栏应可见');
    expect(find.byTooltip('收起设置'), findsOneWidget);

    // 点遮罩（覆盖中栏）收起。
    await tester.tap(find.text('CENTER'));
    await tester.pump();
    expect(find.text('RIGHT'), findsNothing);
    expect(find.byTooltip('展开设置'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
