import 'dart:math' as math;

import 'package:flutter/material.dart' show Brightness, Color;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_age_editor/core/app_theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    // 每个用例从暗色基线开始；主题色也清回默认品牌蓝（ValueNotifier 是静态的，
    // 不清会跨用例残留派生调色板，破坏 `same(AppPalette.dark)` 断言）。
    AppTheme.accent.value = kDefaultAccent;
    await AppTheme.apply(AppThemeMode.dark, save: false);
  });

  test('AppThemeMode 解析：默认亮色，非法值回退亮色', () {
    expect(AppThemeMode.fromPrefsValue(null), AppThemeMode.light);
    expect(AppThemeMode.fromPrefsValue('light'), AppThemeMode.light);
    expect(AppThemeMode.fromPrefsValue('dark'), AppThemeMode.dark);
    expect(AppThemeMode.fromPrefsValue('system'), AppThemeMode.system);
    expect(AppThemeMode.fromPrefsValue('bogus'), AppThemeMode.light);
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

  // ---------- 白日模式：WCAG 2.1 对比度守门 ----------
  //
  // 防的是同一类历史事故：给暗底调好的浅灰搬到白底后掉进不可读区间
  // （light.textHint 曾只有 2.72:1、light.iconDisabled 1.60:1）。
  // 阈值：正文 4.5:1；三级文本与图形 3.0:1；禁用态按 1.4.3 豁免，只守 2.5:1 兜底。
  void checkContrast(AppPalette p, String tag) {
    final body = <String, Color>{
      'textHigh': p.textHigh,
      'textBody': p.textBody,
      'textPrimary': p.textPrimary,
      'textMid': p.textMid,
      'textSecondary': p.textSecondary,
      'textMuted': p.textMuted,
    };
    body.forEach((name, c) {
      expect(_contrast(c, p.bg), greaterThanOrEqualTo(4.5), reason: tag + '/' + name + ' vs bg');
      expect(_contrast(c, p.card), greaterThanOrEqualTo(4.5), reason: tag + '/' + name + ' vs card');
    });

    // 三级文本：允许降到 3.0（提示/占位），但不得再低。
    final tertiary = <String, Color>{'textHint': p.textHint, 'textFaint': p.textFaint};
    tertiary.forEach((name, c) {
      expect(_contrast(c, p.bg), greaterThanOrEqualTo(3.0), reason: tag + '/' + name + ' vs bg');
    });

    // 图形/状态色：既做图标也做小字，一律 3.0 起步。
    final graphic = <String, Color>{
      'warning': p.warning,
      'danger': p.danger,
      'statusOk': p.statusOk,
      'statusWarn': p.statusWarn,
      'statusTan': p.statusTan,
      'statusInfo': p.statusInfo,
      'statusDanger': p.statusDanger,
      'goldText': p.goldText,
      'warmText': p.warmText,
      'amberText': p.amberText,
      'accentLight': p.accentLight,
      'accentLighter': p.accentLighter,
      'accentPale': p.accentPale,
      'primaryColor': p.primaryColor,
      'catSprite': p.catSprite,
      'catTexture': p.catTexture,
      'catAudio': p.catAudio,
      'flowBg': p.flowBg,
      'flowAudio': p.flowAudio,
      'flowTime': p.flowTime,
      'flowFx': p.flowFx,
      'flowCheck': p.flowCheck,
      'flowNext': p.flowNext,
      'flowMissing': p.flowMissing,
    };
    graphic.forEach((name, c) {
      expect(_contrast(c, p.bg), greaterThanOrEqualTo(3.0), reason: tag + '/' + name + ' vs bg');
      expect(_contrast(c, p.card), greaterThanOrEqualTo(3.0), reason: tag + '/' + name + ' vs card');
    });

    // 禁用态（WCAG 豁免）：仍守一个地板值，避免退化成「看不见」。
    expect(_contrast(p.iconDisabled, p.bg), greaterThanOrEqualTo(3.0), reason: tag + '/iconDisabled vs bg');
    expect(_contrast(p.iconDisabled, p.card), greaterThanOrEqualTo(2.5), reason: tag + '/iconDisabled vs card');

    // 实底强调色之上的前景。
    expect(_contrast(p.onAccent, p.accentDeep), greaterThanOrEqualTo(4.5), reason: tag + '/onAccent vs accentDeep');
    // 品牌蓝多用于加粗按钮文字，按大字档 3.0 守。
    expect(_contrast(p.onAccent, p.primaryColor), greaterThanOrEqualTo(3.0), reason: tag + '/onAccent vs primaryColor');

    // 灰阶阶梯必须严格单调，否则「更弱的文本」会比更强的还显眼。
    final ladder = <Color>[
      p.textSecondary,
      p.textMuted,
      p.textHint,
      p.textFaint,
      p.iconDisabled,
    ];
    for (var i = 0; i + 1 < ladder.length; i++) {
      expect(_contrast(ladder[i], p.bg),
          greaterThan(_contrast(ladder[i + 1], p.bg)),
          reason: tag + ' 阶梯第 ' + i.toString() + ' 档不强于第 ' + (i + 1).toString() + ' 档');
    }
    expect(_contrast(p.textHigh, p.bg), greaterThan(10.0), reason: tag + '/textHigh 应远高于 10:1');
  }

  test('暗色与亮色两套调色板都过 WCAG 阈值', () {
    checkContrast(AppPalette.dark, 'dark');
    checkContrast(AppPalette.light, 'light');
  });

  test('暗色基线：新 token 的 dark 值必须等于被替换的历史字面量', () {
    // 白日模式的前提是「暗色逐像素不变」；改动这些值等于改暗色外观。
    const d = AppPalette.dark;
    expect(d.isLight, isFalse);
    expect(d.flowBg.toARGB32(), 0xFF3498DB);
    expect(d.flowAudio.toARGB32(), 0xFF27AE60);
    expect(d.flowTime.toARGB32(), 0xFF95A5A6);
    expect(d.flowFx.toARGB32(), 0xFFE91E63);
    expect(d.flowCheck.toARGB32(), 0xFFE67E22);
    expect(d.flowNext.toARGB32(), 0xFF95A5A6);
    expect(d.flowMissing.toARGB32(), 0xFFE74C3C);
    expect(d.warmText.toARGB32(), 0xFF8B7B5E);
    expect(d.amberText.toARGB32(), 0xFFC97018);
    expect(d.statusWarnFill.toARGB32(), 0xFF6B4A2A);
    expect(d.overlayWeak.toARGB32(), 0x0DFFFFFF);
    expect(d.overlayMedium.toARGB32(), 0x1AFFFFFF);
    expect(d.scrim.toARGB32(), 0x59000000);
    expect(d.scrimWeak.toARGB32(), 0x42000000);
    expect(d.checkerA.toARGB32(), 0xFFE1E1E6);
    expect(d.checkerB.toARGB32(), 0xFFFFFFFF);
    expect(d.chipSep.toARGB32(), 0xFFFFFFFF);
    expect(d.accentDeep.toARGB32(), 0xFF2F49C4);
    expect(d.primaryColor.toARGB32(), 0xFF4F6EF7);
    expect(d.tombstoneFill.toARGB32(), 0xFF424242);
    expect(d.catSprite.toARGB32(), 0xFF0078D4);
    expect(d.catTexture.toARGB32(), 0xFF00B294);
    expect(d.catAudio.toARGB32(), 0xFFF25460);
    expect(accentColor.toARGB32(), 0xFF4F6EF7); // 品牌蓝：两模式同值
  });

  test('亮色是独立一套值，且 isLight 为真', () {
    const l = AppPalette.light;
    const d = AppPalette.dark;
    expect(l.isLight, isTrue);
    // 关键方向：白底上文字必须转深，分类色必须降明度。
    expect(_contrast(l.textHigh, l.bg), greaterThan(_contrast(d.textHigh, d.bg)));
    expect(_contrast(l.flowBg, l.bg), lessThan(_contrast(d.flowBg, d.bg)));
    expect(l.bg.toARGB32(), isNot(equals(d.bg.toARGB32())));
    // 两模式同值的 token 不许漂移。
    expect(l.onAccent.toARGB32(), d.onAccent.toARGB32());
    expect(l.chipSep.toARGB32(), d.chipSep.toARGB32());
    expect(l.accentDeep.toARGB32(), d.accentDeep.toARGB32());
    expect(l.primaryColor.toARGB32(), d.primaryColor.toARGB32());
  });

  test('AppShadow 随外观变浅（白底上纯黑阴影会发脏）', () {
    final dark = AppShadow.float(AppPalette.dark).single;
    final light = AppShadow.float(AppPalette.light).single;
    expect(light.color.a, lessThan(dark.color.a));
    expect(light.blurRadius, greaterThan(dark.blurRadius));
  });

  // ---------- 用户主题色 ----------

  test('默认品牌蓝：withAccent 恒等返回，accentSwatch 固定七档（逐位不变回归守门）', () {
    expect(AppPalette.dark.withAccent(kDefaultAccent), same(AppPalette.dark));
    expect(AppPalette.light.withAccent(kDefaultAccent), same(AppPalette.light));
    final sw = accentSwatch();
    expect(sw['normal']!.toARGB32(), 0xFF4F6EF7);
    expect(sw['dark']!.toARGB32(), 0xFF3E5BE8);
    expect(sw['darker']!.toARGB32(), 0xFF2F49C4);
    expect(sw['darkest']!.toARGB32(), 0xFF22379E);
    expect(sw['light']!.toARGB32(), 0xFF778EF9);
    expect(sw['lighter']!.toARGB32(), 0xFF99ABFA);
    expect(sw['lightest']!.toARGB32(), 0xFFBBC7FC);
  });

  test('HEX 解析/序列化与非法值', () {
    expect(AppAccentColor.parse('#4F6EF7')!.toARGB32(), 0xFF4F6EF7);
    expect(AppAccentColor.parse('4f6ef7')!.toARGB32(), 0xFF4F6EF7);
    expect(AppAccentColor.parse(' #FF0000 '), const Color(0xFFFF0000));
    expect(AppAccentColor.parse('#12345'), isNull);
    expect(AppAccentColor.parse('#1234567'), isNull);
    expect(AppAccentColor.parse('zzzzzz'), isNull);
    expect(AppAccentColor.parse(null), isNull);
    expect(AppAccentColor.toHex(const Color(0xFF0A14FF)), '#0a14ff');
  });

  test('极端种子色派生都可读：onAccent ≥4.3、变体对底 ≥3.0、其余 token 不漂移', () {
    const seeds = <Color>[
      Color(0xFFFFFFFF),
      Color(0xFF000000),
      Color(0xFFFFEB3B),
      Color(0xFF0000FF),
      Color(0xFF808080),
      Color(0xFFFF0000),
      Color(0xFF00FF00),
      Color(0xFF616161),
    ];
    for (final base in const [AppPalette.dark, AppPalette.light]) {
      for (final seed in seeds) {
        final p = base.withAccent(seed);
        final tag = '${base.isLight ? 'light' : 'dark'}/${AppAccentColor.toHex(seed)}';
        // 实底强调色上的前景：白/近黑择优，理论最差 ~4.33（等对比平衡点）。
        expect(_contrast(p.onAccent, seed), greaterThanOrEqualTo(4.3),
            reason: tag + ' onAccent vs seed');
        expect(_contrast(p.onAccent, p.accentDeep), greaterThanOrEqualTo(4.3),
            reason: tag + ' onAccent vs accentDeep');
        // 图标/强调用变体在底上至少可辨（3.0）。
        final variants = {
          'accentLight': p.accentLight,
          'accentLighter': p.accentLighter,
          'accentPale': p.accentPale,
        };
        variants.forEach((name, c) {
          expect(_contrast(c, p.bg), greaterThanOrEqualTo(3.0), reason: tag + ' $name vs bg');
          expect(_contrast(c, p.card), greaterThanOrEqualTo(3.0), reason: tag + ' $name vs card');
        });
        // 非强调色 token 一律不漂移（主题色只动强调色族）。
        expect(p.bg.toARGB32(), base.bg.toARGB32(), reason: tag);
        expect(p.warning.toARGB32(), base.warning.toARGB32(), reason: tag);
        expect(p.primaryColor.toARGB32(), base.primaryColor.toARGB32(), reason: tag);
        expect(p.isLight, base.isLight);
      }
    }
  });

  test('setAccent：换色/通知/落盘，且与亮度切换正交', () async {
    final seed = const Color(0xFF0078D4);
    await AppTheme.setAccent(seed);
    expect(AppTheme.accent.value, seed);
    expect(accentColor, seed);
    expect(AppTheme.userTouchedAccentThisSession, isTrue);
    expect(palette, isNot(same(AppPalette.dark)));
    expect(palette.isLight, isFalse);
    expect(palette.accentLight.toARGB32(),
        AppPalette.dark.withAccent(seed).accentLight.toARGB32());

    // 切亮度保留主题色。
    await AppTheme.set(AppThemeMode.light);
    expect(palette.isLight, isTrue);
    expect(palette.accentLight.toARGB32(),
        AppPalette.light.withAccent(seed).accentLight.toARGB32());

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(AppAccentColor.prefsKey), '#0078d4');
  });

  test('AppAccentColor.load：正常回读 / 非法回退默认', () async {
    SharedPreferences.setMockInitialValues({AppAccentColor.prefsKey: '#e5484d'});
    expect(await AppAccentColor.load(), const Color(0xFFE5484D));
    SharedPreferences.setMockInitialValues({AppAccentColor.prefsKey: 'garbage'});
    expect(await AppAccentColor.load(), kDefaultAccent);
  });

  test('AppShadow.selected 随主题色', () {
    expect(AppShadow.selected().single.color.toARGB32(), 0x804F6EF7); // 默认品牌蓝
    AppTheme.accent.value = const Color(0xFF0078D4);
    expect(AppShadow.selected().single.color.toARGB32(), 0x800078D4);
  });

  test('自定义色的 accentSwatch：normal=种子，明度序单调（允许并列）', () {
    AppTheme.accent.value = const Color(0xFFE67E22);
    final sw = accentSwatch();
    expect(sw['normal'], const Color(0xFFE67E22));
    final order = ['darkest', 'darker', 'dark', 'normal', 'light', 'lighter', 'lightest'];
    for (var i = 0; i + 1 < order.length; i++) {
      expect(_relLuminance(sw[order[i]]!),
          lessThanOrEqualTo(_relLuminance(sw[order[i + 1]]!)),
          reason: '${order[i]} 不比 ${order[i + 1]} 亮');
    }
  });
}

// WCAG 2.1 相对亮度/对比度，独立实现（不复用生产代码，避免互相印证）。
double _relLuminance(Color c) {
  // Flutter 3.27+：Color.r/g/b 是 0..1 的 double。
  double lin(double v) => v <= 0.03928
      ? v / 12.92
      : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b);
}

double _contrast(Color fg, Color bg) {
  final a = _relLuminance(fg);
  final b = _relLuminance(bg);
  final hi = a > b ? a : b;
  final lo = a > b ? b : a;
  return (hi + 0.05) / (lo + 0.05);
}
