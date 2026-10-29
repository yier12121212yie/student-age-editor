import 'dart:async' show unawaited;
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'download_name.dart';

/// Web：用 Blob + 隐藏 <a download> 触发浏览器下载（拿不到本机路径）。
/// 返回下载用的文件名（无落盘路径）。
Future<String?> saveBytesToFile({
  required String filename,
  required Uint8List bytes,
  String mimeType = 'application/octet-stream',
}) async {
  final name = safeDownloadName(filename);
  final blob = web.Blob(
    <web.BlobPart>[bytes.toJS].toJS,
    web.BlobPropertyBag(type: mimeType),
  );
  final url = web.URL.createObjectURL(blob);
  final anchor = web.document.createElement('a') as web.HTMLAnchorElement;
  anchor
    ..href = url
    ..download = name
    ..style.display = 'none';
  web.document.body?.appendChild(anchor);
  anchor.click();
  anchor.remove();
  // 不能立即 revoke：Firefox / Safari 在 click() 返回后才开始真正读取 Blob，
  // 当场释放会让下载中断或得到 0 字节文件。60s 后释放（大包也够）。
  unawaited(Future<void>.delayed(
    const Duration(seconds: 60),
    () => web.URL.revokeObjectURL(url),
  ));
  return name;
}
