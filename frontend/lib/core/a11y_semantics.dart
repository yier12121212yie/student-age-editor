// 屏幕阅读器语义树开关（Web 专用）。
//
// 背景：app.dart 全局包了 `ExcludeSemantics`——那是为了压掉 Windows 平台
// accessibility_bridge 的 AXTree 刷屏/冻结。副作用是 Web 上语义树也一起没了，
// 屏幕阅读器只能看到 Flutter 引擎插入的那颗英文「Enable accessibility」小按钮。
//
// 这里把「是否生成语义树」变成用户可选项：
// - 默认关（CanvasKit 的语义树会显著增加每帧开销，编辑器的自绘控件很多）；
// - 打开后调用 `ensureSemantics()` 并持久化，下次启动自动恢复；
// - 桌面/移动端不提供（那边的 ExcludeSemantics 有明确的历史原因，暂不动）。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

class A11ySemantics {
  A11ySemantics._();

  static const String _prefsKey = 'a11y_semantics_v1';

  /// 语义树是否开启（供根部 builder 决定是否包 ExcludeSemantics）。
  static final ValueNotifier<bool> enabled = ValueNotifier<bool>(false);

  static SemanticsHandle? _handle;

  /// 启动时恢复上次的选择。非 Web 直接返回。
  static Future<void> init() async {
    if (!kIsWeb) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(_prefsKey) == true) {
        await setEnabled(true, persist: false);
      }
    } catch (_) {
      // 读偏好失败按默认（关闭）处理。
    }
  }

  /// 开关语义树。[persist] 为 false 时不写偏好（启动恢复用）。
  static Future<void> setEnabled(bool value, {bool persist = true}) async {
    if (!kIsWeb) return;
    if (value == enabled.value) return;
    if (value) {
      _handle ??= WidgetsBinding.instance.ensureSemantics();
    } else {
      _handle?.dispose();
      _handle = null;
    }
    enabled.value = value;
    if (!persist) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefsKey, value);
    } catch (_) {
      // 写失败只影响下次启动的默认值，本次会话照常生效。
    }
  }
}
