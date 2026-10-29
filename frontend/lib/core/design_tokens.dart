/// 通用设计 token（单一来源）：字号 / 间距 / 圆角。
///
/// 颜色不在本文件——`app_theme.dart` 的 `AppPalette` 是颜色唯一来源
/// （项目约定：自定义控件不写死十六进制色值、不用 Material 语义色）。
///
/// [AppRadius] / [AppSpace] / [AppType] 原定义在 app_theme.dart（由画布
/// story_flow 系列先起用），R3 起迁到本文件作为全局唯一阶梯并补齐通用档位；
/// app_theme.dart 仍 re-export 这三个类，既有引用不受影响。
///
/// 圆角/间距两套阶梯各取「全仓字面量频次簇」为心，档位之间不新增近似值：
/// - 圆角频次：6(109) / 8(96) / 4(82) / 10(34) / 12(20) / 5(16) / 3(14)；
/// - 间距频次：2/4/6/8/10/12/16 为主，24 为面板级。
library;

/// 通用字号阶梯。
///
/// 档位取自全仓 `fontSize:` 字面量频次簇（12 / 11 / 11.5 / 12.5 / 10.5…），
/// 不再新增 11.8 这类临时值——需要新档先改这里。
class AppText {
  AppText._();

  /// 极小（徽标/角标）。
  static const double tiny = 9.5;

  /// 微号（胶囊按钮、密集标签）。
  static const double micro = 10;

  /// 高密度正文（表格、卡片摘要）。
  static const double dense = 10.5;

  /// 小号（次级说明、按钮提示）。
  static const double small = 11;

  /// 图注（状态文案、图注）。
  static const double caption = 11.5;

  /// 正文（默认）。
  static const double body = 12;

  /// 次标题（主按钮文案、列表主名）。
  static const double subhead = 12.5;

  /// 强调正文（区块小标题）。
  static const double emphasis = 13;

  /// 标题。
  static const double title = 14;

  /// 大标题（面板/页内主标题）。
  static const double heading = 15;

  /// 页面主标题（导航栏）。
  static const double display = 16;
}

/// 通用间距阶梯（2 的倍数为主，几何以现状频次为准）。
///
/// [s6] / [s10] 是半档：频次很高（比 12 与 8 还常见于行内间隔），
/// 但插进 xxs/xs/s/m/l 的命名阶梯会打乱档距，故直接以数值命名。
class AppSpace {
  AppSpace._();

  static const double xxs = 2;
  static const double xs = 4;

  /// 6px 半档——介于 [xs]=4 与 [s]=8（图标与文案之间等）。
  static const double s6 = 6;

  static const double s = 8;

  /// 10px 半档——介于 [s]=8 与 [m]=12（工具条内边距等）。
  static const double s10 = 10;

  static const double m = 12;
  static const double l = 16;
  static const double xl = 24;
}

/// 圆角阶梯：卡片/浮层/芯片共用，避免同一层级在不同文件里取不同值。
class AppRadius {
  AppRadius._();

  /// 徽标/角标。
  static const double xxs = 3;

  /// 小控件/芯片（通用最常用档之一）。
  static const double xs = 4;

  static const double s = 5;

  /// 按钮/输入框（默认档）。
  static const double m = 6;

  /// 卡片。
  static const double l = 8;

  static const double xl = 10;

  /// 浮层/大卡片。
  static const double xxl = 12;
}

/// 画布字号阶梯：剧情图画布信息密度高，正文比全局默认小一档。
///
/// 通用界面用 [AppText]；本类仅供 story_flow 画布体系（既有标定）。
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
