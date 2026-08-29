import 'package:flutter/material.dart' show Brightness;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_age_editor/core/app_theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    // 每个用例从暗色基线开始
    await AppTheme.apply(AppThemeMode.dark, save: false);
  });

  test('AppThemeMode 解析：默认暗色，非法值回退暗色', () {
    expect(AppThemeMode.fromPrefsValue(null), AppThemeMode.dark);
    expect(AppThemeMode.fromPrefsValue('light'), AppThemeMode.light);
    expect(AppThemeMode.fromPrefsValue('dark'), AppThemeMode.dark);
    expect(AppThemeMode.fromPrefsValue('system'), AppThemeMode.system);
    expect(AppThemeMode.fromPrefsValue('bogus'), AppThemeMode.dark);
  });

  test('切亮色：调色板翻转并写入持久化', () async {
    expect(palette, same(AppPalette.dark));
    await AppTheme.set(AppThemeMode.light);
    expect(palette, same(AppPalette.light));
    expect(AppTheme.mode.value, AppThemeMode.light);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(AppThemeMode.prefsKey), 'light');

    await AppTheme.set(AppThemeMode.dark);
    expect(palette, same(AppPalette.dark));
    expect((await SharedPreferences.getInstance()).getString(AppThemeMode.prefsKey),
        'dark');
  });

  test('跟随系统：按平台亮度解析调色板', () async {
    final binding = TestWidgetsFlutterBinding.instance;
    binding.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    await AppTheme.set(AppThemeMode.system);
    expect(palette, same(AppPalette.light));

    binding.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    await AppTheme.apply(AppThemeMode.system, save: false);
    expect(palette, same(AppPalette.dark));
  });

  test('init：从持久化值恢复亮色主题', () async {
    SharedPreferences.setMockInitialValues({AppThemeMode.prefsKey: 'light'});
    await AppTheme.init();
    expect(AppTheme.mode.value, AppThemeMode.light);
    expect(palette, same(AppPalette.light));
  });
}
