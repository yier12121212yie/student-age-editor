/// 浏览器下载文件名的净化（Web 专用 `saveBytesToFile` 使用）。
///
/// `<a download="...">` 的文件名不会被浏览器校验：含 `/` `\` 时 Chrome 会把
/// 它们替换成 `_`，而部分浏览器会直接截断或拒绝下载；以 `.` / 空格开头或
/// 结尾的名字在 Windows 上落盘会变成不可用文件名。这里统一收口，并在超长时
/// 保留扩展名截断（某些系统路径上限 255 字节）。
library;

/// 文件名里不允许出现的字符（Windows 保留字符 + 控制字符）。
final RegExp _illegal = RegExp(r'[\\/:*?"<>|\x00-\x1F\x7F]');

/// 返回一个可直接交给 `download` 属性的安全文件名。
///
/// - 非法字符替换为 `_`；
/// - 去掉首尾的点与空白（`.`/`..` 会变成 `_`）；
/// - 空串回退 `download`；
/// - 超过 [maxLength] 个字符时截断主体、保留扩展名。
String safeDownloadName(String name, {int maxLength = 120}) {
  var out = name.replaceAll(_illegal, '_').trim();
  out = out.replaceAll(RegExp(r'^[.\s]+|[.\s]+$'), '');
  if (out.isEmpty) return 'download';
  if (out.length <= maxLength) return out;

  final dot = out.lastIndexOf('.');
  // 扩展名过长（或没有扩展名）时直接硬截断。
  if (dot <= 0 || out.length - dot > 16) {
    return out.substring(0, maxLength);
  }
  final ext = out.substring(dot);
  final keep = maxLength - ext.length;
  if (keep <= 0) return out.substring(0, maxLength);
  return out.substring(0, keep) + ext;
}
