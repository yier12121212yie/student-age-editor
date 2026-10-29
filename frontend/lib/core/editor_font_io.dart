// 桌面/移动端：系统自带中文字体（Microsoft YaHei / 思源黑体等），无需内置。
//
// 与 Web 实现保持同一 API（main.dart 无条件调用 ensureEditorCjkFont）。
/// 与 Web 实现保持同一族名；桌面端主题不使用该族名。
const String kEditorCjkFamily = 'EditorCJK';

/// 桌面端没有内置字体，直接返回（保留同一 API 供 main 调用）。
Future<void> ensureEditorCjkFont() async {}
