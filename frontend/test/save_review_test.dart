import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:student_age_editor/features/editor/save_review_drawer.dart';

void main() {
  testWidgets('SaveReviewDrawer renders items and handles selection', (tester) async {
    final items = [
      SaveReviewItem(
        table: 'EvtCfg',
        rowId: '1001',
        field: 'name',
        oldValue: '旧事件',
        newValue: '新事件名称',
      ),
      SaveReviewItem(
        table: 'TalkCfg',
        rowId: '2001',
        field: 'text',
        oldValue: '你好',
        newValue: '你好呀，今天天气真好！',
      ),
    ];

    List<SaveReviewItem>? savedItems;

    await tester.pumpWidget(
      fluent.FluentApp(
        home: Scaffold(
          body: SaveReviewDrawer(
            items: items,
            onConfirmSave: (selected) async {
              savedItems = selected;
            },
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('保存前可视化差异审查 (Save Review)'), findsOneWidget);
    expect(find.text('EvtCfg'), findsWidgets);
    expect(find.text('TalkCfg'), findsWidgets);
    expect(find.text('- 原值: 旧事件'), findsOneWidget);
    expect(find.text('+ 新值: 新事件名称'), findsOneWidget);

    final saveBtn = find.text('安全落盘已选 (2 项)');
    expect(saveBtn, findsOneWidget);
    await tester.tap(saveBtn);
    await tester.pumpAndSettle();

    expect(savedItems, isNotNull);
    expect(savedItems!.length, equals(2));
  });
}
