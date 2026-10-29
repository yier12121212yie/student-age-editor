/// Web 运行时错误的采集与「重新加载」（条件导出）。
///
/// Flutter Web 的异常有两条出口，缺一不可：
/// 1. **Dart 侧**（`FlutterError.onError` / `PlatformDispatcher.onError`）——
///    框架层异常，见 `core/error_fallback.dart`；
/// 2. **JS 侧**（`error` / `unhandledrejection`）——引擎/插件/浏览器扩展抛出的
///    异常，很多根本到不了 Dart，但往往就是「界面一夜之间空白」的元凶。
///
/// 这里只收集、不拦截（不 `preventDefault`），保留浏览器控制台原有的输出，
/// 同时把最近几条压进 `__editorDiag` 与诊断报告，便于用户直接反馈。
///
/// 桌面/移动端为空实现。
library;

export 'web_errors_stub.dart'
    if (dart.library.js_interop) 'web_errors_web.dart';
