import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_age_editor/core/api_client.dart';
import 'package:student_age_editor/core/app_theme.dart';
import 'package:student_age_editor/core/ui_mode.dart';
import 'package:student_age_editor/features/settings/settings_page.dart';

/// 亮/暗色切换回归：切外观后界面必须整体换色，不能留下「半张深色」。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    AppTheme.accent.value = kDefaultAccent;
    await AppTheme.apply(AppThemeMode.dark, save: false);
  });

  test('跟随系统：OS 亮度变化（模式值不变）也会通知根部重建', () async {
    final binding = TestWidgetsFlutterBinding.instance;
    binding.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    await AppTheme.apply(AppThemeMode.system, save: false);
    expect(palette, same(AppPalette.light));

    var notified = 0;
    void listener() => notified++;
    AppTheme.changes.addListener(listener);
    addTearDown(() => AppTheme.changes.removeListener(listener));

    // 模式仍是 system，只有生效亮度变了——旧实现只刷新全局 palette 不发通知，
    // 界面会一直停在旧外表。
    binding.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    await AppTheme.apply(AppThemeMode.system, save: false);
    expect(palette, same(AppPalette.dark));
    expect(notified, greaterThan(0), reason: '调色板变化必须通知监听者');
  });

  testWidgets('切换外观后设置页各分区（含 const 子树）立即改用新调色板', (tester) async {
    // mock 所有接口，避免失败路径的 InfoBar 计时器触发 timersPending。
    ApiClient.instance.client = MockClient((req) async => http.Response(
        '{"packs":[],"active":"","settings":{}}', 200,
        headers: {'content-type': 'application/json'}));
    addTearDown(() {
      ApiClient.instance.client = http.Client();
    });

    await tester.binding.setSurfaceSize(const Size(1100, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(ListenableBuilder(
      listenable: AppTheme.changes,
      builder: (context, _) => fluent.FluentApp(
        theme: fluent.FluentThemeData(brightness: Brightness.light),
        darkTheme: fluent.FluentThemeData(brightness: Brightness.dark),
        themeMode: AppTheme.mode.value == AppThemeMode.light
            ? ThemeMode.light
            : ThemeMode.dark,
        home: Material(
          type: MaterialType.transparency,
          child: SettingsPage(
            settings: AiSettings(),
            onChanged: (_) {},
            uiMode: UiMode.creation,
            onUiModeChanged: (_) {},
          ),
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 100));

    Color? colorOf(String text) {
      final finder = find.text(text);
      if (finder.evaluate().isEmpty) return null;
      return tester.widget<Text>(finder.first).style?.color;
    }

    expect(colorOf('外观'), AppPalette.dark.textHigh);

    await AppTheme.set(AppThemeMode.light);
    await tester.pump(const Duration(milliseconds: 200));

    expect(palette, same(AppPalette.light));
    // 这些标题都在各自分区的 build 里读全局 palette；若分区被 const 固定住，
    // 切换后仍会是暗色近白字（亮底上几乎不可读）。
    expect(colorOf('外观'), AppPalette.light.textHigh);
    expect(colorOf('主题色'), AppPalette.light.textHigh);
    expect(colorOf('界面风格'), AppPalette.light.textHigh);
    expect(colorOf('无代码模式'), AppPalette.light.textHigh);
  });
}
