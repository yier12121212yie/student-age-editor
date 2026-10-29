/// 非 Web：没有浏览器错误事件，也没有页面可重载（空实现）。
library;

void installWebErrorCapture() {}

List<String> webCapturedErrors() => const <String>[];

String webEnvironmentSummary() => '';

void reloadWebPage() {}
