import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';

/// 桌面/Android：弹保存位置对话框，写盘。取消返回 null，成功返回落盘路径。
Future<String?> saveBytesToFile({
  required String filename,
  required Uint8List bytes,
  String mimeType = 'application/octet-stream',
}) async {
  final location = await getSaveLocation(suggestedName: filename);
  if (location == null) return null;
  final file = File(location.path);
  await file.writeAsBytes(bytes, flush: true);
  return location.path;
}
