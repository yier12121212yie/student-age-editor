/// 把字节保存到本地文件的条件导出（网页版模组下载用）：
/// - Web：Blob + <a download> 触发浏览器下载；
/// - 有 dart:io 的平台：文件选择器选位置后写盘。
///
/// 两份实现暴露同一公共 API：[saveBytesToFile]。
library;

export 'file_save_stub.dart' if (dart.library.io) 'file_save_io.dart';
