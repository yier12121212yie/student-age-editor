import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// GUI 外观模式：跟随系统 / 亮色 / 暗色（默认暗色，与历史版本一致）。
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

  /// 根据持久化值解析，默认暗色。
  static AppThemeMode fromPrefsValue(String? v) {
    for (final m in AppThemeMode.values) {
      if (m.prefsValue == v) return m;
    }
    return AppThemeMode.dark;
  }

  /// 从 SharedPreferences 读取。
  static Future<AppThemeMode> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return AppThemeMode.fromPrefsValue(prefs.getString(prefsKey));
    } catch (_) {
      return AppThemeMode.dark;
    }
  }

  Future<void> save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(prefsKey, prefsValue);
    } catch (_) {}
  }
}

/// 语义化调色板：暗色值与历史版本完全一致，亮色为新增。
///
/// 自定义控件统一从 [palette]（当前生效实例）取色，不直接写死颜色值；
/// 强调色 #6C5CE7 等品牌色两种模式共用，保持在此调色板之外。
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
    textMuted: Color(0xFF8B8B93),
    textHint: Color(0xFF6E6E76),
    textFaint: Color(0xFF5E5E66),
    iconDisabled: Color(0xFF4A4A52),
    accentLight: Color(0xFF8B7FEF),
    accentLighter: Color(0xFFA99FF4),
    accentPale: Color(0xFFC7C0F9),
    warning: Color(0xFFE08A3C),
    danger: Color(0xFFE5484D),
    statusOk: Color(0xFF5FBE8C),
    statusWarn: Color(0xFFF2C25C),
    statusTan: Color(0xFFD9A15E),
    statusInfo: Color(0xFF9DB8FF),
    statusDanger: Color(0xFFFF8A8A),
    goldText: Color(0xFFE8D5B0),
    tintAccent: Color(0xFF2E2A45),
    tintOk: Color(0xFF1E2A22),
    tintWarn: Color(0xFF2A2418),
    tintDanger: Color(0xFF2D1E1E),
    tintInfo: Color(0xFF2A3B52),
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
    textHint: Color(0xFF8A8A94),
    textFaint: Color(0xFF9C9CA6),
    iconDisabled: Color(0xFFB6B6C0),
    accentLight: Color(0xFF6C5CE7),
    accentLighter: Color(0xFF7A6CE9),
    accentPale: Color(0xFF8B7FEF),
    warning: Color(0xFFB9761E),
    danger: Color(0xFFD63A40),
    statusOk: Color(0xFF1F8A4C),
    statusWarn: Color(0xFF9A6C0B),
    statusTan: Color(0xFF9C6B33),
    statusInfo: Color(0xFF3A66B8),
    statusDanger: Color(0xFFC74040),
    goldText: Color(0xFF8A6A35),
    tintAccent: Color(0xFFECE9F8),
    tintOk: Color(0xFFE7F3EB),
    tintWarn: Color(0xFFF8F0DE),
    tintDanger: Color(0xFFFBEAEA),
    tintInfo: Color(0xFFE7EEF8),
  );
}

/// 当前生效调色板（应用启动与主题切换时由 [AppTheme] 整体替换）。
AppPalette palette = AppPalette.dark;

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
class AppShadow {
  AppShadow._();

  static const List<BoxShadow> float = [
    BoxShadow(color: Color(0x66000000), blurRadius: 10, offset: Offset(0, 3)),
  ];

  static const List<BoxShadow> selected = [
    BoxShadow(color: Color(0x806C5CE7), blurRadius: 8, offset: Offset(0, 0)),
  ];
}

/// 主题控制器：读写持久化模式，同步当前调色板，并通知监听者重建。
class AppTheme {
  AppTheme._();

  /// 主题变化通知（app 根组件监听以切换 FluentTheme）。
  static final ValueNotifier<AppThemeMode> mode =
      ValueNotifier(AppThemeMode.dark);

  static bool _initialized = false;

  /// 启动时加载持久化主题并应用。
  static Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    await apply(await AppThemeMode.load(), save: false);
  }

  /// 应用主题模式（更新调色板并持久化）。
  static Future<void> apply(AppThemeMode m, {bool save = true}) async {
    final brightness = m == AppThemeMode.system
        ? WidgetsBinding.instance.platformDispatcher.platformBrightness
        : (m == AppThemeMode.light ? Brightness.light : Brightness.dark);
    palette =
        brightness == Brightness.light ? AppPalette.light : AppPalette.dark;
    if (mode.value != m) mode.value = m;
    if (save) await m.save();
  }

  /// 切换主题（设置页调用）。
  static Future<void> set(AppThemeMode m) => apply(m);
}
