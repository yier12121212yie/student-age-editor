import 'package:shared_preferences/shared_preferences.dart';

/// 界面布局风格。
enum UiMode {
  /// 创作：当前 Cursor 风格（图标活动栏 + 侧边栏 + 标签编辑区 + AI 面板）。
  creation('创作', 'icon', 'icon_creation'),

  /// 经典：传统桌面工具风格（顶部标题+工具栏 + 左侧分组导航 + 中央内容区）。
  classic('经典', 'list', 'icon_classic');

  const UiMode(this.label, this.iconKey, this.prefsValue);

  /// 显示名称。
  final String label;

  /// 导航样式标识（creation=图标活动栏，classic=分组文字导航）。
  final String iconKey;

  /// 持久化存储值。
  final String prefsValue;

  static const prefsKey = 'ui_mode_v1';

  /// 根据持久化值解析，默认创作。
  static UiMode fromPrefsValue(String? v) {
    for (final m in UiMode.values) {
      if (m.prefsValue == v) return m;
    }
    return UiMode.creation;
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(prefsKey, prefsValue);
  }

  static Future<UiMode> load() async {
    final prefs = await SharedPreferences.getInstance();
    return UiMode.fromPrefsValue(prefs.getString(prefsKey));
  }
}
