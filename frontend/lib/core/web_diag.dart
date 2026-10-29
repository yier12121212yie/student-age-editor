/// Web 启动/渲染诊断探针（条件导出）。
///
/// 为什么需要：Web 端最常见的故障是「停在加载页」——但 Flutter 全部画在
/// canvas 上，DevTools 的元素树里只有一个空壳，用户（和远程支持）看不到
/// 到底卡在哪个阶段。这里把少量关键状态挂到 `window.__editorDiag` 上，
/// F12 控制台一眼可见（不需要重新构建 debug 包）。
///
/// 同一份数据也留在 Dart 侧，供设置页「复制诊断信息」拼成一段文本。只写
/// 字符串、每次覆盖同名字段，开销可忽略；非 Web 为空实现。
library;

export 'web_diag_stub.dart'
    if (dart.library.js_interop) 'web_diag_web.dart';
