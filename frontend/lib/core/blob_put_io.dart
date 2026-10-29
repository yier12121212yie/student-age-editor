/// 直传 PUT / 直链下载（IO 平台兜底）：读全量字节走 package:http。
///
/// 桌面/安卓的模组导入导出走本机路径与文件选择器，正常不会走到这里；保留一份
/// 可用实现是为了条件导出的 API 面完整（同一公共签名）。
library;

import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:http/http.dart' as http;

import 'file_save.dart';

Future<void> putXFileToUrl(
  XFile file,
  String url, {
  void Function(int sent, int total)? onProgress,
  Duration timeout = const Duration(minutes: 60),
}) async {
  final bytes = await file.readAsBytes();
  await putBytesToUrl(bytes, url, onProgress: onProgress, timeout: timeout);
}

Future<void> putBytesToUrl(
  Uint8List bytes,
  String url, {
  void Function(int sent, int total)? onProgress,
  Duration timeout = const Duration(minutes: 60),
}) async {
  onProgress?.call(0, bytes.length);
  final req = http.Request('PUT', Uri.parse(url))..bodyBytes = bytes;
  final streamed = await http.Client().send(req).timeout(timeout);
  final resp = await http.Response.fromStream(streamed);
  if (resp.statusCode < 200 || resp.statusCode >= 300) {
    throw Exception('直传失败：HTTP ${resp.statusCode}');
  }
  onProgress?.call(bytes.length, bytes.length);
}

/// 分片上传（IO 兜底）：从 [offset, offset+length) 流式读取分段并 PUT，
/// 返回 ETag。桌面/安卓正常走本机路径导入，这里是公共 API 的完整实现。
Future<String> putXFileRangeToUrl(
  XFile file,
  String url, {
  required int offset,
  required int length,
  void Function(int sent, int total)? onProgress,
  Duration timeout = const Duration(minutes: 60),
}) async {
  onProgress?.call(0, length);
  final client = http.Client();
  try {
    final req = http.StreamedRequest('PUT', Uri.parse(url));
    req.contentLength = length;
    final respFuture = client.send(req);
    int sent = 0;
    await for (final chunk in file.openRead(offset, offset + length)) {
      req.sink.add(chunk);
      sent += chunk.length;
      onProgress?.call(sent, length);
    }
    await req.sink.close();
    final resp = await respFuture.timeout(timeout);
    await resp.stream.drain<void>();
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw Exception('分片直传失败：HTTP ${resp.statusCode}');
    }
    return resp.headers['etag'] ?? resp.headers['ETag'] ?? '';
  } finally {
    client.close();
  }
}

Future<Uint8List> getBytesFromUrl(
  String url, {
  void Function(int received, int total)? onProgress,
  Duration timeout = const Duration(minutes: 60),
}) async {
  final resp = await http.get(Uri.parse(url)).timeout(timeout);
  if (resp.statusCode < 200 || resp.statusCode >= 300) {
    throw Exception('下载失败：HTTP ${resp.statusCode}');
  }
  onProgress?.call(resp.bodyBytes.length, resp.bodyBytes.length);
  return resp.bodyBytes;
}

/// 带自定义请求头的直链 GET（本地文件流转的 `/api/v1/files/{id}/raw`）。
Future<Uint8List> getBytesFromUrlWithHeaders(
  String url, {
  Map<String, String> headers = const {},
  void Function(int received, int total)? onProgress,
  Duration timeout = const Duration(minutes: 60),
}) async {
  final req = http.Request('GET', Uri.parse(url))..headers.addAll(headers);
  final client = http.Client();
  try {
    final resp = await client.send(req).timeout(timeout);
    final builder = BytesBuilder(copy: false);
    final total = resp.contentLength ?? 0;
    await for (final chunk in resp.stream) {
      builder.add(chunk);
      if (total > 0) onProgress?.call(builder.length, total);
    }
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw Exception('下载失败：HTTP ${resp.statusCode}');
    }
    final bytes = builder.takeBytes();
    onProgress?.call(bytes.length, total > 0 ? total : bytes.length);
    return bytes;
  } finally {
    client.close();
  }
}

/// IO 平台没有「浏览器原生下载」，这里 GET 全量后交给 [saveBytesToFile] 落盘。
Future<void> downloadUrlNative(String url, {String? filename}) async {
  final resp = await http.get(Uri.parse(url)).timeout(const Duration(minutes: 60));
  if (resp.statusCode < 200 || resp.statusCode >= 300) {
    throw Exception('下载失败：HTTP ${resp.statusCode}');
  }
  await saveBytesToFile(
    filename: (filename == null || filename.isEmpty) ? 'download.bin' : filename,
    bytes: resp.bodyBytes,
  );
}
