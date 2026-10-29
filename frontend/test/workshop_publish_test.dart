import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:student_age_editor/features/mods/workshop_publish_dialog.dart';

void main() {
  testWidgets('WorkshopPublishDialog renders title and controls', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() => tester.view.resetPhysicalSize());

    await tester.pumpWidget(
      fluent.FluentApp(
        home: Scaffold(
          body: const WorkshopPublishDialog(
            modName: 'TestMod',
            initialTitle: '测试模组标题',
            initialDesc: '这是一个测试模组简介',
          ),
        ),
      ),
    );

    // Initial pump
    await tester.pump();

    expect(find.text('发布到 Steam 创意工坊'), findsOneWidget);
    expect(find.text('模组：TestMod'), findsOneWidget);
    expect(find.text('一键同步发布'), findsOneWidget);
  });
}
