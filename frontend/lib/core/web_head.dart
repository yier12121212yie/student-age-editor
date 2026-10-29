/// 浏览器 `<head>` 守护（条件导出）。
///
/// 两件 Flutter 会「抢」的事，必须由我们自己守住：
/// 1. **标签页标题**：`WidgetsApp` 内部的 `Title` 每次重建都会把
///    `document.title` 写回构造函数里的静态文案；
/// 2. **theme-color**：引擎处理 `setApplicationSwitcherDescription` 时会用
///    `primaryColor`（FluentApp 默认 `#0078d4`）插入一个**不带 media** 的
///    `<meta name="theme-color">`，把 index.html 里按 `prefers-color-scheme`
///    配好的浅/深一对覆盖掉（深色主题下浏览器 UI 变成突兀的蓝）。
///
/// 桌面/移动端为空实现。
library;

export 'web_head_stub.dart'
    if (dart.library.js_interop) 'web_head_web.dart';
