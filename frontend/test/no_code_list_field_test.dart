// 无代码模式「普通数据数组」列表编辑器的行为守护。
//
// 背景：PersonCfg:birthday / bubbleParm 这类字段不是效果码，早期被 catch-all
// 误当成效果码积木。现在走 NoCodeListField：逐行增删、编辑数值/文本，写回
// 走 ValueCodec 规范化，绝不出现效果码候选。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;

import 'package:student_age_editor/features/nocode/no_code_list_field.dart';

Future<List<dynamic>> _mount(
  WidgetTester t, {
  required dynamic value,
  required String type,
}) async {
  final writes = <dynamic>[];
  t.view.physicalSize = const Size(900, 700);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
  await t.pumpWidget(fluent.FluentApp(
    debugShowCheckedModeBanner: false,
    home: Scaffold(
      body: SingleChildScrollView(
        child: SizedBox(
          width: 640,
          child: NoCodeListField(
            value: value,
            type: type,
            onChanged: writes.add,
          ),
        ),
      ),
    ),
  ));
  await t.pump();
  return writes;
}

void main() {
  testWidgets('1D：按现值铺行、可增行、编辑行写回', (t) async {
    final writes = await _mount(t, value: [1995, 3, 15], type: '1D Array');
    expect(find.byType(fluent.TextBox), findsNWidgets(3));

    await t.tap(find.text('＋ 添加一项'));
    await t.pump();
    expect(find.byType(fluent.TextBox), findsNWidgets(4));

    await t.enterText(find.byType(fluent.TextBox).at(0), '2000');
    await t.pumpAndSettle();
    expect(writes.last, [2000, 3, 15]);
  });

  testWidgets('1D：删除行写回', (t) async {
    final writes = await _mount(t, value: [1, 2, 3], type: '1D Array');
    await t.tap(find.text('✕').first);
    await t.pump();
    expect(find.byType(fluent.TextBox), findsNWidgets(2));
    expect(writes.last, [2, 3]);
  });

  testWidgets('2D：行内逗号分隔，增行/编辑写回嵌套列表', (t) async {
    final writes =
        await _mount(t, value: [[0, 0, 1], [1, 1, 1]], type: '2D Array');
    expect(find.byType(fluent.TextBox), findsNWidgets(2));
    expect(find.text('0, 0, 1'), findsOneWidget);

    await t.tap(find.text('＋ 添加一行'));
    await t.pump();
    expect(find.byType(fluent.TextBox), findsNWidgets(3));

    await t.enterText(find.byType(fluent.TextBox).at(1), '2, 3');
    await t.pumpAndSettle();
    expect(writes.last, [[0, 0, 1], [2, 3]]);
  });

  testWidgets('空值：显示引导文案，不铺行', (t) async {
    await _mount(t, value: <dynamic>[], type: '1D Array');
    expect(find.text('还没有条目，点击下方按钮添加第一行。'), findsOneWidget);
    expect(find.byType(fluent.TextBox), findsNothing);
  });
}
