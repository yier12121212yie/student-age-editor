import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:student_age_editor/core/app_theme.dart';

/// 回归守门：FluentApp 注入的 Material 层表面色是 Fluent 的 Mica 半透明资源色
/// （暗色下 5% 白），所有没显式底板的 Material 弹层（AlertDialog、
/// DropdownButton 菜单、showModalBottomSheet、PopupMenuButton 缺省色）都会
/// 「整窗透明」。opaqueMaterialSurfaces 必须把这些表面覆盖成不透明色。
void main() {
  void expectOpaque(Color? c, String label) {
    expect(c, isNotNull, reason: '$label 不应为 null');
    expect(c!.a, 1.0, reason: '$label 应完全不透明，实际 alpha=${c.a}');
  }

  for (final entry in {
    'dark': AppPalette.dark,
    'light': AppPalette.light,
  }.entries) {
    test('${entry.key} 外观下 Material 弹层表面不透明', () {
      final data = opaqueMaterialSurfaces(null, entry.value);

      expectOpaque(data.canvasColor, 'canvasColor');
      expectOpaque(data.cardColor, 'cardColor');
      expectOpaque(data.colorScheme.surface, 'colorScheme.surface');
      expectOpaque(
        data.dialogTheme.backgroundColor,
        'dialogTheme.backgroundColor',
      );
      expectOpaque(data.popupMenuTheme.color, 'popupMenuTheme.color');
      expectOpaque(
        data.bottomSheetTheme.backgroundColor,
        'bottomSheetTheme.backgroundColor',
      );

      expect(data.cardColor, entry.value.card);
      expect(data.canvasColor, entry.value.card);
    });
  }

  test('外观切换后（全局 palette）仍取当前调色板', () {
    syncGlobalPalette(AppPalette.light);
    addTearDown(() => syncGlobalPalette(AppPalette.dark));
    final data = opaqueMaterialSurfaces();
    expect(data.cardColor, AppPalette.light.card);
  });

  testWidgets('FluentApp.builder 注入的不透明主题覆盖 AlertDialog 底色', (
    tester,
  ) async {
    await tester.pumpWidget(
      fluent.FluentApp(
        builder: (context, child) => Theme(
          data: opaqueMaterialSurfaces(Theme.of(context), AppPalette.dark),
          child: child ?? const SizedBox.shrink(),
        ),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => const AlertDialog(title: Text('弹窗')),
                ),
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    final dialogMaterial = tester.widget<Material>(
      find
          .descendant(
            of: find.byType(AlertDialog),
            matching: find.byType(Material),
          )
          .first,
    );
    expect(dialogMaterial.color?.a, 1.0);
  });
}
