/// 非 Web 平台：无拖放导入（空实现）。
library;

import 'dart:typed_data';

/// 拖入的文件（只有文件名与字节；浏览器拿不到路径）。
typedef DroppedFile = ({String name, Uint8List bytes});

/// 收到一批拖入文件时的回调。
typedef DropHandler = Future<void> Function(List<DroppedFile> files);

/// 见 web_drop_web.dart 的同名类。
class WebFileDrop {
  WebFileDrop._();

  /// 非 Web 返回 null，调用方据此跳过接线。
  static WebFileDrop? install({required DropHandler onFiles}) => null;

  static void uninstall() {}

  void dispose() {}
}
