/// 非 Web 平台的空实现：桌面/移动端没有「关标签页」这一回事，
/// 退出流程由 app.dart 的 AppLifecycleListener 处理。
library;

/// 现取「是否有未保存修改」的回调（必须同步、轻量：浏览器事件不能 await）。
typedef UnsavedProbe = bool Function();

/// 见 web_lifecycle_web.dart 的同名类。
class WebLifecycle {
  WebLifecycle._();

  static WebLifecycle? _instance;

  /// 幂等安装。重复调用返回同一个实例（脏判定在事件发生时现取，
  /// 因此无需更新回调）。
  static WebLifecycle? install({required UnsavedProbe isDirty}) {
    return _instance ??= WebLifecycle._();
  }

  /// 卸载（测试/热重启兜底）。非 Web 无需清理。
  static void uninstall() {
    _instance = null;
  }

  void dispose() {}
}
