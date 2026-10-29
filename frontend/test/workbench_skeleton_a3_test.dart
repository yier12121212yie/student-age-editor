import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;

import 'package:student_age_editor/core/save_bar.dart';
import 'package:student_age_editor/features/editor/synced_fields.dart';

Widget _host(Widget child) => fluent.FluentApp(
      home: fluent.ScaffoldPage(
        content: Center(child: SizedBox(width: 420, child: child)),
      ),
    );

void main() {
  group('A3 · SyncedTextField', () {
    testWidgets('聚焦中不打断：外部值变化不改输入框', (tester) async {
      var value = 'a';
      late StateSetter set;
      await tester.pumpWidget(_host(StatefulBuilder(
        builder: (c, s) {
          set = s;
          return SyncedTextField(value: value, onChanged: (_) {});
        },
      )));
      final field = find.byType(fluent.TextBox);
      expect(field, findsOneWidget);

      // 聚焦并输入
      await tester.tap(find.byType(EditableText));
      await tester.pump();
      await tester.enterText(find.byType(EditableText), 'abc');
      await tester.pump();

      // 外部把值改成别处（模拟后端刷新）—— 聚焦中不应回填
      set(() => value = 'zzz');
      await tester.pump();
      expect(
        tester.widget<fluent.TextBox>(field).controller!.text,
        'abc',
      );
    });

    testWidgets('失焦后跟随外部值', (tester) async {
      var value = 'a';
      late StateSetter set;
      await tester.pumpWidget(_host(StatefulBuilder(
        builder: (c, s) {
          set = s;
          return SyncedTextField(value: value, onChanged: (_) {});
        },
      )));
      set(() => value = 'next');
      await tester.pump();
      expect(
        tester.widget<fluent.TextBox>(find.byType(fluent.TextBox)).controller!.text,
        'next',
      );
    });
  });

  group('A3 · NumBox', () {
    testWidgets('空串上报 null', (tester) async {
      num? got = 5;
      await tester.pumpWidget(_host(
        NumBox(value: 5, onChanged: (v) => got = v),
      ));
      await tester.enterText(find.byType(EditableText), '');
      await tester.pump();
      expect(got, isNull);
    });

    testWidgets('intOnly：小数输入上报 null', (tester) async {
      num? got = 1;
      await tester.pumpWidget(_host(
        NumBox(value: 1, intOnly: true, onChanged: (v) => got = v),
      ));
      await tester.enterText(find.byType(EditableText), '3.5');
      await tester.pump();
      expect(got, isNull);
    });

    testWidgets('intOnly：整数正常解析', (tester) async {
      num? got;
      await tester.pumpWidget(_host(
        NumBox(value: 1, intOnly: true, onChanged: (v) => got = v),
      ));
      await tester.enterText(find.byType(EditableText), '42');
      await tester.pump();
      expect(got, 42);
    });

    testWidgets('format：3.0 显示为 3', (tester) async {
      await tester.pumpWidget(_host(
        NumBox(value: 3.0, format: true, onChanged: (_) {}),
      ));
      expect(
        tester.widget<fluent.TextBox>(find.byType(fluent.TextBox)).controller!.text,
        '3',
      );
    });

    testWidgets('不带 format：3.0 保持 3.0', (tester) async {
      await tester.pumpWidget(_host(
        NumBox(value: 3.0, onChanged: (_) {}),
      ));
      expect(
        tester.widget<fluent.TextBox>(find.byType(fluent.TextBox)).controller!.text,
        '3.0',
      );
    });
  });

  group('A3 · ListNumField', () {
    testWidgets('半角逗号解析', (tester) async {
      List<int>? got;
      await tester.pumpWidget(_host(
        ListNumField(value: const [1], onChanged: (v) => got = v),
      ));
      await tester.enterText(find.byType(EditableText), '1, 2, 3');
      await tester.pump();
      expect(got, const [1, 2, 3]);
    });

    testWidgets('全角逗号也解析', (tester) async {
      List<int>? got;
      await tester.pumpWidget(_host(
        ListNumField(value: const [1], onChanged: (v) => got = v),
      ));
      await tester.enterText(find.byType(EditableText), '4，5');
      await tester.pump();
      expect(got, const [4, 5]);
    });

    testWidgets('含非法项时不写回（保留半截输入）', (tester) async {
      List<int>? got = const [7];
      await tester.pumpWidget(_host(
        ListNumField(value: const [7], onChanged: (v) => got = v),
      ));
      await tester.enterText(find.byType(EditableText), '1, x');
      await tester.pump();
      expect(got, const [7]); // 未被覆盖
    });
  });

  group('A3 · SaveBar', () {
    testWidgets('脏态：状态文案 + 保存可用 + Ctrl+S 提示', (tester) async {
      var saved = 0;
      await tester.pumpWidget(_host(SaveBar(
        dirty: true,
        onSave: () async => saved++,
        onDiscard: () {},
      )));
      expect(find.text(kUnsavedLabel), findsOneWidget);
      expect(find.text('Ctrl+S'), findsOneWidget);
      await tester.tap(find.text('保存修改'));
      await tester.pumpAndSettle();
      expect(saved, 1);
    });

    testWidgets('干净态：同步文案 + 保存禁用 + 放弃禁用', (tester) async {
      var saved = 0;
      var discarded = 0;
      await tester.pumpWidget(_host(SaveBar(
        dirty: false,
        onSave: () async => saved++,
        onDiscard: () => discarded++,
      )));
      expect(find.text(kSyncedLabel), findsOneWidget);
      // 保存按钮禁用
      final btn = tester.widget<fluent.FilledButton>(find.byType(fluent.FilledButton));
      expect(btn.onPressed, isNull);
      // 放弃按钮禁用（MiniButton 内部 onTap 不触发）
      await tester.tap(find.text('放弃修改'));
      await tester.pumpAndSettle();
      expect(discarded, 0);
    });

    testWidgets('保存中：显示进度环且保存禁用', (tester) async {
      await tester.pumpWidget(_host(SaveBar(
        dirty: true,
        saving: true,
        onSave: () async {},
        onDiscard: () {},
      )));
      expect(find.byType(fluent.ProgressRing), findsOneWidget);
      final btn = tester.widget<fluent.FilledButton>(find.byType(fluent.FilledButton));
      expect(btn.onPressed, isNull);
    });

    testWidgets('提供了 onOpenSearch 才显示检索按钮', (tester) async {
      await tester.pumpWidget(_host(SaveBar(
        dirty: false,
        onSave: () async {},
        onDiscard: () {},
        onOpenSearch: () {},
      )));
      expect(find.text('检索剧情库'), findsOneWidget);
    });
  });
}
