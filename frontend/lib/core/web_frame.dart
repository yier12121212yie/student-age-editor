/// 「让浏览器先画一帧」的条件导出（Web 主线程同步解析前使用）。
///
/// 桌面/移动端为空实现：那边的重活本来就在后台 isolate，不需要等帧。
library;

export 'web_frame_stub.dart'
    if (dart.library.js_interop) 'web_frame_web.dart';
