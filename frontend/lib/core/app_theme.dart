import 'dart:math' as math;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart' show ThemeData;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Dart -> Windows runner channel for the native title bar (no-op elsewhere).
const MethodChannel _appearanceChannel = MethodChannel('studentage/appearance');

bool? _titleBarDark;

/// Match the native window title bar to the app's appearance (bug #4: it used
/// to follow only the OS setting, so forcing light kept a dark title bar).
void _syncNativeTitleBar(bool dark) {
  if (kIsWeb || _titleBarDark == dark) return;
  _titleBarDark = dark;
  _appearanceChannel.invokeMethod('setDarkTitleBar', dark).catchError((_) {});
}

/// GUI 外观模式：跟随系统 / 亮色 / 暗色（默认亮色）。
enum AppThemeMode {
  system('跟随系统', 'system'),
  light('亮色', 'light'),
  dark('暗色', 'dark');

  const AppThemeMode(this.label, this.prefsValue);

  /// 显示名称。
  final String label;

  /// 持久化存储值。
  final String prefsValue;

  static const prefsKey = 'app_theme_mode_v1';

  /// 根据持久化值解析，默认亮色。
  static AppThemeMode fromPrefsValue(String? v) {
    for (final m in AppThemeMode.values) {
      if (m.prefsValue == v) return m;
    }
    return AppThemeMode.light;
  }

  /// 从 SharedPreferences 读取。
  static Future<AppThemeMode> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return AppThemeMode.fromPrefsValue(prefs.getString(prefsKey));
    } catch (_) {
      return AppThemeMode.light;
    }
  }

  Future<void> save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(prefsKey, prefsValue);
    } catch (_) {}
  }
}

/// 默认品牌强调色：用户没有自定义主题色时的种子（品牌蓝）。
const Color kDefaultAccent = Color(0xFF4F6EF7);

/// 当前生效的强调色种子（用户可在设置页改，随 [AppTheme.accent] 变化）。
///
/// 现在是 [AppTheme.accentSeed] 的兼容别名——实底主色取它，「随外观变化的
/// 强调色变体」走 [AppPalette.accentDeep] 等 token（两者都已随主题色联动）。
Color get accentColor => AppTheme.accentSeed;

/// 近黑前景：亮强调色之上的 onAccent 替代（与 light.textHigh 同值）。
const Color _onAccentDark = Color(0xFF101014);

/// WCAG 2.1 相对亮度（通道取 0..1）。
double relativeLuminance(Color c) {
  double lin(double v) => v <= 0.04045
      ? v / 12.92
      : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b);
}

/// WCAG 2.1 对比度（1..21）。
double contrastRatio(Color a, Color b) {
  final la = relativeLuminance(a);
  final lb = relativeLuminance(b);
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

/// 把颜色拉进目标相对亮度带：保色相/饱和度，只以 0.01 步进调 HSL 明度。
/// 用于让任意用户色在深/浅两种外观下都保持可辨。
Color _fitLuminance(Color c, {required double min, required double max}) {
  var h = HSLColor.fromColor(c);
  while (relativeLuminance(h.toColor()) < min && h.lightness < 1.0) {
    h = h.withLightness(math.min(1.0, h.lightness + 0.01));
  }
  while (relativeLuminance(h.toColor()) > max && h.lightness > 0.0) {
    h = h.withLightness(math.max(0.0, h.lightness - 0.01));
  }
  return h.toColor();
}

/// 按 HSL 明度平移（0..1 域，自动钳位）。
Color _shiftLightness(Color c, double dl) {
  final h = HSLColor.fromColor(c);
  return h.withLightness((h.lightness + dl).clamp(0.0, 1.0)).toColor();
}

/// Fluent 控件的强调色色阶（[fluent.AccentColor.swatch] 的输入）。
///
/// 默认品牌蓝沿用固定七档；自定义主题色按明度阶梯派生，与
/// [AppPalette.withAccent] 同源，保证 Fluent 控件与自绘 UI 一致。
Map<String, Color> accentSwatch() {
  final seed = accentColor;
  if (seed == kDefaultAccent) {
    return const <String, Color>{
      'normal': Color(0xFF4F6EF7),
      'dark': Color(0xFF3E5BE8),
      'darker': Color(0xFF2F49C4),
      'darkest': Color(0xFF22379E),
      'light': Color(0xFF778EF9),
      'lighter': Color(0xFF99ABFA),
      'lightest': Color(0xFFBBC7FC),
    };
  }
  final deep = _fitLuminance(seed, min: 0.0, max: 0.10);
  return <String, Color>{
    'normal': seed,
    'dark': _shiftLightness(seed, -0.08),
    'darker': deep,
    'darkest': _shiftLightness(deep, -0.10),
    'light': _shiftLightness(seed, 0.085),
    'lighter': _shiftLightness(seed, 0.165),
    'lightest': _shiftLightness(seed, 0.25),
  };
}

/// 用户主题色的本机持久化：prefs 存 `#rrggbb` 小写；非法值回退默认品牌蓝。
class AppAccentColor {
  AppAccentColor._();

  static const prefsKey = 'app_accent_color_v1';

  /// `#rrggbb` / `rrggbb`（大小写不限）→ [Color]；非法返回 null。
  static Color? parse(String? raw) {
    if (raw == null) return null;
    var s = raw.trim();
    if (s.startsWith('#')) s = s.substring(1);
    if (s.length != 6) return null;
    final v = int.tryParse(s, radix: 16);
    return v == null ? null : Color(0xFF000000 | v);
  }

  /// [Color] → `#rrggbb` 小写（供共享设置写穿与输入框回填）。
  static String toHex(Color c) {
    final v = c.toARGB32() & 0xFFFFFF;
    return '#${v.toRadixString(16).padLeft(6, '0')}';
  }

  static Future<Color> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return parse(prefs.getString(prefsKey)) ?? kDefaultAccent;
    } catch (_) {
      return kDefaultAccent;
    }
  }

  static Future<void> save(Color c) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(prefsKey, toHex(c));
    } catch (_) {}
  }
}

/// 语义化调色板：暗色基线与历史版本一致，亮色为白日模式新增。
///
/// 约定（由 `test/light_theme_audit_test.dart` 机器守门）：
/// - 自定义控件一律从 [palette]（当前生效实例）取色，不写死 `Color(0x…)`，
///   也不用 Material 的 `Colors.*` 语义色——两者都不随外观切换；
/// - 确需两模式同值的品牌色/几何色（如 [accentColor]、[chipSep]、[onAccent]）
///   也做成 token，并在审计测试的白名单里登记；
/// - 只在少数「同色不同 alpha」的场景用 [isLight] 分支，别为每个 alpha 造 token。
class AppPalette {
  const AppPalette({
    required this.bg,
    required this.bgAlt,
    required this.bgDeep,
    required this.bgDeep2,
    required this.panel,
    required this.card,
    required this.hover,
    required this.surface,
    required this.border,
    required this.borderHover,
    required this.textHigh,
    required this.textBody,
    required this.textPrimary,
    required this.textMid,
    required this.textSecondary,
    required this.textMuted,
    required this.textHint,
    required this.textFaint,
    required this.iconDisabled,
    required this.accentLight,
    required this.accentLighter,
    required this.accentPale,
    required this.warning,
    required this.danger,
    required this.statusOk,
    required this.statusWarn,
    required this.statusTan,
    required this.statusInfo,
    required this.statusDanger,
    required this.goldText,
    required this.tintAccent,
    required this.tintOk,
    required this.tintWarn,
    required this.tintDanger,
    required this.tintInfo,
    required this.primaryColor,
    required this.warmText,
    required this.amberText,
    required this.statusWarnFill,
    required this.overlayWeak,
    required this.overlayMedium,
    required this.scrim,
    required this.scrimWeak,
    required this.onAccent,
    required this.checkerA,
    required this.checkerB,
    required this.chipSep,
    required this.accentDeep,
    required this.tombstoneFill,
    required this.catSprite,
    required this.catTexture,
    required this.catAudio,
    required this.flowBg,
    required this.flowAudio,
    required this.flowTime,
    required this.flowFx,
    required this.flowCheck,
    required this.flowNext,
    required this.flowMissing,
    required this.isLight,
  });

  /// 页面主背景。
  final Color bg;

  /// 略深背景（编辑区/预览底色）。
  final Color bgAlt;

  /// 深背景（侧栏、代码块、面板底）。
  final Color bgDeep;

  /// 最深背景（整页背景、终端区）。
  final Color bgDeep2;

  /// 侧栏/面板背景。
  final Color panel;

  /// 卡片/浮层背景。
  final Color card;

  /// 悬停/选中填充。
  final Color hover;

  /// 输入填充/实边框。
  final Color surface;

  /// 分隔线/常规边框。
  final Color border;

  /// 悬停边框。
  final Color borderHover;

  /// 最亮标题文本。
  final Color textHigh;

  /// 正文文本。
  final Color textBody;

  /// 主要文本。
  final Color textPrimary;

  /// 中等亮度文本。
  final Color textMid;

  /// 次要文本。
  final Color textSecondary;

  /// 弱化文本。
  final Color textMuted;

  /// 提示文本。
  final Color textHint;

  /// 极弱文本。
  final Color textFaint;

  /// 禁用图标/占位图标。
  final Color iconDisabled;

  /// 亮强调色（渐变辅色/高亮图标）。
  final Color accentLight;

  /// 更亮强调色。
  final Color accentLighter;

  /// 最浅强调色（浅色芯片/描边）。
  final Color accentPale;

  /// 警告橙。
  final Color warning;

  /// 危险红（填充/图标）。
  final Color danger;

  /// 成功状态绿。
  final Color statusOk;

  /// 警告状态黄。
  final Color statusWarn;

  /// 棕褐状态色。
  final Color statusTan;

  /// 信息状态蓝。
  final Color statusInfo;

  /// 危险状态红。
  final Color statusDanger;

  /// 金色文本（剧本导演等暖色高亮）。
  final Color goldText;

  /// 强调色浅底。
  final Color tintAccent;

  /// 成功浅底。
  final Color tintOk;

  /// 警告浅底。
  final Color tintWarn;

  /// 危险浅底。
  final Color tintDanger;

  /// 信息浅底。
  final Color tintInfo;

  /// 品牌主色（两模式同值：链接/上传/主操作蓝）。
  final Color primaryColor;

  /// 暖棕正文（剧本导演旁白/说明类文本）。
  final Color warmText;

  /// 琥珀高亮文本（导演视图的数值/提示）。
  final Color amberText;

  /// 警示实心 pill 底（AI 面板「空」徽标一类）。
  final Color statusWarnFill;

  /// 弱叠加层（取代白色 withOpacity(.05)）。
  final Color overlayWeak;

  /// 中叠加层（输入底/选中 chip，取代白色 withOpacity(.1)）。
  final Color overlayMedium;

  /// 模态遮罩。
  final Color scrim;

  /// 弱遮罩（图上角标底，取代 Colors.black26）。
  final Color scrimWeak;

  /// 实底强调色按钮/徽标之上的前景（两模式同值）。
  final Color onAccent;

  /// 透明图棋盘亮格 / 暗格。
  final Color checkerA;
  final Color checkerB;

  /// 节点色块之间的分隔描边（两模式同值的几何色）。
  final Color chipSep;

  /// 强调色深变体（选中态实底）。
  final Color accentDeep;

  /// 墓碑节点填充（已删除 ID 在剧情图上的失效占位灰块）。
  final Color tombstoneFill;

  // ---- 资源浏览器分类图标色 ----
  /// 角色（sprite）分类：蓝。
  final Color catSprite;

  /// 背景（texture）分类：青。
  final Color catTexture;

  /// 音频（audio）分类：红。
  final Color catAudio;

  // ---- 剧情图节点分类色（画布上的徽标/连线，随外观提/降明度）----
  /// 背景（bgId）分类：蓝。
  final Color flowBg;

  /// 音乐/音效分类：绿。
  final Color flowAudio;

  /// 时刻/旁白分类：灰。
  final Color flowTime;

  /// 特效分类：品红。
  final Color flowFx;

  /// 检定分类：橙。
  final Color flowCheck;

  /// 跳转后继分类：灰。
  final Color flowNext;

  /// 缺失/错误分类：红。
  final Color flowMissing;

  /// 当前是否白日（亮色）模式：仅供少量「同色不同 alpha」分支使用。
  final bool isLight;

  /// 暗色调色板（与历史硬编码值一一对应）。
  static const dark = AppPalette(
    bg: Color(0xFF1B1B1F),
    bgAlt: Color(0xFF18181C),
    bgDeep: Color(0xFF141418),
    bgDeep2: Color(0xFF131316),
    panel: Color(0xFF1E1E23),
    card: Color(0xFF26262B),
    hover: Color(0xFF2B2B31),
    surface: Color(0xFF2E2E35),
    border: Color(0xFF2A2A2E),
    borderHover: Color(0xFF3A3A42),
    textHigh: Color(0xFFF0F0F4),
    textBody: Color(0xFFE4E4E8),
    textPrimary: Color(0xFFD4D4D8),
    textMid: Color(0xFFC8C8CF),
    textSecondary: Color(0xFF9B9BA3),
    textMuted: Color(0xFF8D8D95),
    textHint: Color(0xFF7A7A84),
    textFaint: Color(0xFF6E6E76),
    iconDisabled: Color(0xFF66666F),
    accentLight: Color(0xFF778EF9),
    accentLighter: Color(0xFF99ABFA),
    accentPale: Color(0xFFBBC7FC),
    warning: Color(0xFFE08A3C),
    danger: Color(0xFFE5484D),
    statusOk: Color(0xFF5FBE8C),
    primaryColor: Color(0xFF4F6EF7), // 品牌主色
    statusWarn: Color(0xFFF2C25C),
    statusTan: Color(0xFFD9A15E),
    statusInfo: Color(0xFF9DB8FF),
    statusDanger: Color(0xFFFF8A8A),
    goldText: Color(0xFFE8D5B0),
    tintAccent: Color(0xFF1E2A4A),
    tintOk: Color(0xFF1E2A22),
    tintWarn: Color(0xFF2A2418),
    tintDanger: Color(0xFF2D1E1E),
    tintInfo: Color(0xFF2A3B52),
    warmText: Color(0xFF8B7B5E),
    amberText: Color(0xFFC97018),
    statusWarnFill: Color(0xFF6B4A2A),
    overlayWeak: Color(0x0DFFFFFF),
    overlayMedium: Color(0x1AFFFFFF),
    scrim: Color(0x59000000),
    scrimWeak: Color(0x42000000),
    onAccent: Color(0xFFFFFFFF),
    checkerA: Color(0xFFE1E1E6),
    checkerB: Color(0xFFFFFFFF),
    chipSep: Color(0xFFFFFFFF),
    accentDeep: Color(0xFF2F49C4),
    flowBg: Color(0xFF3498DB),
    flowAudio: Color(0xFF27AE60),
    flowTime: Color(0xFF95A5A6),
    flowFx: Color(0xFFE91E63),
    flowCheck: Color(0xFFE67E22),
    flowNext: Color(0xFF95A5A6),
    flowMissing: Color(0xFFE74C3C),
    tombstoneFill: Color(0xFF424242),
    catSprite: Color(0xFF0078D4),
    catTexture: Color(0xFF00B294),
    catAudio: Color(0xFFF25460),
    isLight: false,
  );

  /// 亮色调色板（新增）。
  static const light = AppPalette(
    bg: Color(0xFFF5F5F8),
    bgAlt: Color(0xFFF0F0F4),
    bgDeep: Color(0xFFEBEBEF),
    bgDeep2: Color(0xFFE9E9ED),
    panel: Color(0xFFEDEDF1),
    card: Color(0xFFFFFFFF),
    hover: Color(0xFFE9E9EF),
    surface: Color(0xFFE5E5EB),
    border: Color(0xFFE1E1E6),
    borderHover: Color(0xFFC9C9D2),
    textHigh: Color(0xFF101014),
    textBody: Color(0xFF26262C),
    textPrimary: Color(0xFF1B1B20),
    textMid: Color(0xFF3D3D46),
    textSecondary: Color(0xFF65656E),
    textMuted: Color(0xFF6F6F79),
    textHint: Color(0xFF71717B),
    textFaint: Color(0xFF84848E),
    iconDisabled: Color(0xFF8C8C95),
    accentLight: Color(0xFF4F6EF7),
    accentLighter: Color(0xFF637EF8),
    accentPale: Color(0xFF6882F8),
    warning: Color(0xFFA6650F),
    danger: Color(0xFFD63A40),
    statusOk: Color(0xFF1F8A4C),
    primaryColor: Color(0xFF4F6EF7),
    statusWarn: Color(0xFF8A5D08),
    statusTan: Color(0xFF9C6B33),
    statusInfo: Color(0xFF3A66B8),
    statusDanger: Color(0xFFC74040),
    goldText: Color(0xFF8A6A35),
    tintAccent: Color(0xFFE9EEFD),
    tintOk: Color(0xFFE7F3EB),
    tintWarn: Color(0xFFF8F0DE),
    tintDanger: Color(0xFFFBEAEA),
    tintInfo: Color(0xFFE7EEF8),
    warmText: Color(0xFF6B5A3A),
    amberText: Color(0xFF9A5B0A),
    statusWarnFill: Color(0xFFF6E3C6),
    overlayWeak: Color(0x0A000000),
    overlayMedium: Color(0x12000000),
    scrim: Color(0x66000000),
    scrimWeak: Color(0x33000000),
    onAccent: Color(0xFFFFFFFF),
    checkerA: Color(0xFFD8D8DE),
    checkerB: Color(0xFFF2F2F5),
    chipSep: Color(0xFFFFFFFF),
    accentDeep: Color(0xFF2F49C4),
    flowBg: Color(0xFF2471A3),
    flowAudio: Color(0xFF1E8449),
    flowTime: Color(0xFF6C7A7B),
    flowFx: Color(0xFFAD1457),
    flowCheck: Color(0xFFB9631A),
    flowNext: Color(0xFF6C7A7B),
    flowMissing: Color(0xFFC0392B),
    tombstoneFill: Color(0xFFE0E0E0),
    catSprite: Color(0xFF0078D4),
    catTexture: Color(0xFF008A73),
    catAudio: Color(0xFFF25460),
    isLight: true,
  );

  /// 换用用户主题色后的调色板：只重算强调色族 token，其余原样保留。
  ///
  /// 默认品牌蓝直接返回自身——[dark]/[light] 两张表本就是它的标定结果
  /// （默认态逐位不变，回归由 app_theme_test 守门）。自定义色的派生规则：
  /// - onAccent 在白/近黑间按对种子色的对比择一（数学上最差也有 ~4.3:1）；
  /// - accentDeep 反向定带：白前景时压到足够暗（对比 ≥7:1），近黑前景时
  ///   留在足够亮的区间（≥5:1），避免「深变体 + 深色文字」的组合塌陷；
  /// - accentLight/Lighter/Pale 沿明度阶梯展开，并按所在外观的可读带钳制
  ///   （暗底 ≥3:1、白底 ≥3:1 起步）。
  AppPalette withAccent(Color seed) {
    if (seed == kDefaultAccent) return this;
    const white = Color(0xFFFFFFFF);
    final onWhite =
        contrastRatio(white, seed) >= contrastRatio(_onAccentDark, seed);
    final base = isLight
        ? _fitLuminance(seed, min: 0.0, max: 0.24)
        : _fitLuminance(seed, min: 0.17, max: 0.60);
    final step = isLight ? 0.04 : 0.08;
    // ramp 方向恒为「提亮」；带界随外观定（暗底要够亮，白底要够暗）。
    Color ramp(Color c) => isLight
        ? _fitLuminance(_shiftLightness(c, step), min: 0.0, max: 0.26)
        : _fitLuminance(_shiftLightness(c, step), min: 0.17, max: 0.98);
    final deep = onWhite
        ? _fitLuminance(_shiftLightness(seed, -0.15), min: 0.0, max: 0.10)
        : _fitLuminance(_shiftLightness(seed, -0.10), min: 0.26, max: 1.0);
    return _replace(
      accentLight: base,
      accentLighter: ramp(base),
      accentPale: ramp(ramp(base)),
      accentDeep: deep,
      tintAccent: HSLColor.fromColor(seed)
          .withSaturation(isLight ? 0.5 : 0.24)
          .withLightness(isLight ? 0.945 : 0.22)
          .toColor(),
      onAccent: onWhite ? white : _onAccentDark,
    );
  }

  /// 字段级复制：仅供 [withAccent] 覆盖强调色族，其余 token 原样带走。
  AppPalette _replace({
    Color? accentLight,
    Color? accentLighter,
    Color? accentPale,
    Color? accentDeep,
    Color? tintAccent,
    Color? onAccent,
  }) =>
      AppPalette(
        bg: bg,
        bgAlt: bgAlt,
        bgDeep: bgDeep,
        bgDeep2: bgDeep2,
        panel: panel,
        card: card,
        hover: hover,
        surface: surface,
        border: border,
        borderHover: borderHover,
        textHigh: textHigh,
        textBody: textBody,
        textPrimary: textPrimary,
        textMid: textMid,
        textSecondary: textSecondary,
        textMuted: textMuted,
        textHint: textHint,
        textFaint: textFaint,
        iconDisabled: iconDisabled,
        accentLight: accentLight ?? this.accentLight,
        accentLighter: accentLighter ?? this.accentLighter,
        accentPale: accentPale ?? this.accentPale,
        warning: warning,
        danger: danger,
        statusOk: statusOk,
        statusWarn: statusWarn,
        statusTan: statusTan,
        statusInfo: statusInfo,
        statusDanger: statusDanger,
        goldText: goldText,
        tintAccent: tintAccent ?? this.tintAccent,
        tintOk: tintOk,
        tintWarn: tintWarn,
        tintDanger: tintDanger,
        tintInfo: tintInfo,
        primaryColor: primaryColor,
        warmText: warmText,
        amberText: amberText,
        statusWarnFill: statusWarnFill,
        overlayWeak: overlayWeak,
        overlayMedium: overlayMedium,
        scrim: scrim,
        scrimWeak: scrimWeak,
        onAccent: onAccent ?? this.onAccent,
        checkerA: checkerA,
        checkerB: checkerB,
        chipSep: chipSep,
        accentDeep: accentDeep ?? this.accentDeep,
        tombstoneFill: tombstoneFill,
        catSprite: catSprite,
        catTexture: catTexture,
        catAudio: catAudio,
        flowBg: flowBg,
        flowAudio: flowAudio,
        flowTime: flowTime,
        flowFx: flowFx,
        flowCheck: flowCheck,
        flowNext: flowNext,
        flowMissing: flowMissing,
        isLight: isLight,
      );
}

/// 当前生效调色板（应用启动与主题切换时由 [AppTheme] 整体替换）。
/// 默认亮色：与 [AppThemeMode] 的默认值保持一致，避免首帧闪暗。
AppPalette palette = AppPalette.light;

/// 同步顶层 [palette] 全局并回传（AppTheme 类内 `palette` 被静态 getter
/// 遮蔽，赋值必须经这里）。
AppPalette syncGlobalPalette(AppPalette p) => palette = p;

/// 圆角阶梯：卡片/浮层/芯片共用，避免同一层级在不同文件里取不同值。
class AppRadius {
  AppRadius._();

  static const double xs = 3;
  static const double s = 5;
  static const double m = 6;
  static const double l = 8;
  static const double xl = 10;
}

/// 间距阶梯（4 的倍数，画布卡片与浮层内边距用）。
class AppSpace {
  AppSpace._();

  static const double xxs = 2;
  static const double xs = 4;
  static const double s = 8;
  static const double m = 12;
  static const double l = 16;
  static const double xl = 24;
}

/// 字号阶梯：画布信息密度高，正文比全局默认小一档。
class AppType {
  AppType._();

  /// 角标/徽章。
  static const double badge = 8.5;

  /// 卡片正文。
  static const double body = 10.5;

  /// 卡片标题条。
  static const double title = 11;

  /// 芯片/按钮。
  static const double chip = 12;
}

/// 浮层阴影：[float] 给常驻浮层（工具条/小地图），[selected] 给选中态。
///
/// 亮色底上的纯黑大 alpha 阴影会发脏，所以 [float] 按 [AppPalette.isLight]
/// 降低不透明度、加大扩散；调用点传当前 [palette]。
class AppShadow {
  AppShadow._();

  /// 按 isLight 缓存两份静态列表（阶段 3）：float() 在高频 build 里被调用，
  /// 没必要每次重新分配 BoxShadow；返回的列表按只读约定使用。
  static final List<BoxShadow> _floatLight = List.unmodifiable(const [
    BoxShadow(
      color: Color(0x2E000000),
      blurRadius: 14,
      offset: Offset(0, 3),
    ),
  ]);
  static final List<BoxShadow> _floatDark = List.unmodifiable(const [
    BoxShadow(
      color: Color(0x66000000),
      blurRadius: 10,
      offset: Offset(0, 3),
    ),
  ]);

  static List<BoxShadow> float([AppPalette? p]) =>
      (p ?? palette).isLight ? _floatLight : _floatDark;

  // 选中态发光按当前主题色缓存一份（accentColor 已非编译期常量，无法 const）。
  static Color? _selectedColor;
  static List<BoxShadow>? _selectedCache;

  /// 选中态外发光：随用户主题色变化（历史版本写死品牌色 0x80 半透明）。
  static List<BoxShadow> selected() {
    final c = accentColor;
    if (_selectedCache == null || _selectedColor != c) {
      _selectedColor = c;
      _selectedCache = List.unmodifiable([
        BoxShadow(
            color: c.withAlpha(0x80), blurRadius: 8, offset: Offset(0, 0)),
      ]);
    }
    return _selectedCache!;
  }
}

/// 把 FluentApp 生成的 Material 主题里「半透明表面」覆盖为不透明调色板色。
///
/// FluentApp 的 Material 层默认把 `cardColor` / `canvasColor` /
/// `ColorScheme.surface` 设为 Fluent 的 Mica 资源色（暗色下是 `0x0dffffff`，
/// 只有 5% 白）。于是所有没显式指定底板的 Material 弹层——`AlertDialog`、
/// `DropdownButton` 下拉菜单、`showModalBottomSheet`、`PopupMenuButton` 缺省
/// 色——都会「整窗透明」，把下层内容透出来。这里一次性覆盖成不透明底板。
///
/// [base] 传 FluentApp 注入的 Material 主题；[p] 省略时取当前生效调色板。
ThemeData opaqueMaterialSurfaces([ThemeData? base, AppPalette? p]) {
  final pal = p ?? palette;
  final surface = pal.card;
  final data =
      base ??
      ThemeData(brightness: pal.isLight ? Brightness.light : Brightness.dark);
  return data.copyWith(
    canvasColor: surface,
    cardColor: surface,
    scaffoldBackgroundColor: pal.bg,
    colorScheme: data.colorScheme.copyWith(
      surface: surface,
      surfaceTint: const Color(0x00000000),
    ),
    dialogTheme: data.dialogTheme.copyWith(
      backgroundColor: surface,
      surfaceTintColor: const Color(0x00000000),
    ),
    popupMenuTheme: data.popupMenuTheme.copyWith(
      color: surface,
      surfaceTintColor: const Color(0x00000000),
    ),
    bottomSheetTheme: data.bottomSheetTheme.copyWith(
      backgroundColor: surface,
      surfaceTintColor: const Color(0x00000000),
    ),
  );
}

/// 主题控制器：读写持久化的外观模式与用户主题色，同步当前调色板，
/// 并通知监听者重建。
class AppTheme {
  AppTheme._();

  /// 外观模式变化通知（app 根组件监听以切换 FluentTheme）。默认亮色。
  static final ValueNotifier<AppThemeMode> mode =
      ValueNotifier(AppThemeMode.light);

  /// 用户主题色（强调色种子）变化通知。
  static final ValueNotifier<Color> accent = ValueNotifier(kDefaultAccent);

  /// 当前生效调色板变化通知。
  ///
  /// 只监听 [mode] 不够：「跟随系统」下 OS 亮度变化时模式值不变，若只刷新
  /// 全局 [palette] 而不发通知，根部 ListenableBuilder 不会重建，界面会一直
  /// 停在旧外表（亮底白字/暗底黑字）。这里以调色板实例本身作为通知值——
  /// 亮/暗两张表是不同 const，withAccent 也会按主题色产生新实例，因此
  /// 亮度或主题色任一变化都能被感知。
  static final ValueNotifier<AppPalette> _paletteNotifier =
      ValueNotifier(AppPalette.light);

  // 合并监听：外观模式、主题色与生效调色板任一变化都触发根部重建。
  static final Listenable _changes =
      Listenable.merge([mode, accent, _paletteNotifier]);

  /// 根部统一监听入口（亮度 + 主题色）。
  static Listenable get changes => _changes;

  /// 当前生效调色板 - 用于兼容旧代码 (AppTheme.palette.xxx)
  static AppPalette get palette => _currentPalette;

  /// 当前生效的主题色种子。
  static Color get accentSeed => accent.value;

  static AppPalette _currentPalette = AppPalette.light;

  static Future<void>? _initFuture;

  /// 启动时加载持久化的外观模式与主题色并应用（幂等：重复调用返回同一 future）。
  static Future<void> init() => _initFuture ??= _initImpl();

  static Future<void> _initImpl() async {
    accent.value = await AppAccentColor.load();
    await apply(await AppThemeMode.load(), save: false);
  }

  /// 按当前 [mode] + [accent] 重算调色板并同步全局 [palette]。
  static void _refreshPalette() {
    final m = mode.value;
    final brightness = m == AppThemeMode.system
        ? WidgetsBinding.instance.platformDispatcher.platformBrightness
        : (m == AppThemeMode.light ? Brightness.light : Brightness.dark);
    final next =
        (brightness == Brightness.light ? AppPalette.light : AppPalette.dark)
            .withAccent(accent.value);
    _currentPalette = syncGlobalPalette(next);
    // 通知根部重建：模式/亮度/主题色任一变化都会让调色板实例发生变化。
    if (!identical(_paletteNotifier.value, next)) {
      _paletteNotifier.value = next;
    }
    _syncNativeTitleBar(brightness == Brightness.dark);
  }

  /// 应用外观模式（重算调色板并持久化）。
  static Future<void> apply(AppThemeMode m, {bool save = true}) async {
    if (mode.value != m) mode.value = m;
    _refreshPalette();
    if (save) await m.save();
  }

  /// 本次会话内用户是否手动选过外观。
  ///
  /// GUI 是唯一带完整外观 UI 的端，而外观值存在后端供三端共享；启动时
  /// bootstrap 会回读后端值，若用户在回读落地前后自己点过设置页，就不能用
  /// 后端值盖掉用户刚做的选择（否则会点完一秒又弹回去）。主题色同此约定，
  /// 见 [userTouchedAccentThisSession]。
  static bool userTouchedThisSession = false;

  /// 本次会话内用户是否手动选过主题色（共享值回灌防盖）。
  static bool userTouchedAccentThisSession = false;

  /// 切换外观（设置页调用）：标记用户意图并落盘。
  static Future<void> set(AppThemeMode m) {
    userTouchedThisSession = true;
    return apply(m);
  }

  /// 切换用户主题色（设置页 / 共享值同步调用）：重算调色板、通知重建、落盘。
  ///
  /// [userIntent] 为 false 时是采纳后端共享值，不置 [userTouchedAccentThisSession]。
  static Future<void> setAccent(Color seed, {bool userIntent = true}) async {
    if (userIntent) userTouchedAccentThisSession = true;
    if (accent.value != seed) accent.value = seed;
    _refreshPalette();
    await AppAccentColor.save(seed);
  }
}
