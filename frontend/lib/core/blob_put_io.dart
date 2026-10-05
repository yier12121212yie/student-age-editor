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
