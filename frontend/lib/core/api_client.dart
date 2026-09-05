import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// 与 Python 后端通信的本地 HTTP 客户端。
class ApiClient {
  ApiClient._();
  static final ApiClient instance = ApiClient._();

  String baseUrl = 'http://127.0.0.1:8765';

  /// Debug counters for performance tracking
  static int debugDecodedRows = 0;
  static int debugUiIsolateParsedRows = 0;
  static int debugOffIsolateParses = 0;

  /// 可替换的 HTTP 客户端（测试中注入 MockClient 用；默认等价于 http 全局函数）。
  http.Client client = http.Client();

  /// 后端进程句柄（由启动器注入）。
  Process? backendProcess;

  Uri _uri(String path, [Map<String, String>? query]) {
    var url = baseUrl + path;
    if (query != null && query.isNotEmpty) {
      final qs = query.entries
          .map((e) => '${e.key}=${Uri.encodeQueryComponent(e.value)}')
          .join('&');
      url = '$url?$qs';
    }
    return Uri.parse(url);
  }

  Future<dynamic> get(String path, {Map<String, String>? query}) async {
    final resp =
        await client.get(_uri(path, query)).timeout(const Duration(seconds: 60));
    return _decode(resp);
  }

  Future<dynamic> post(String path,
      {Object? body, Duration timeout = const Duration(seconds: 120)}) async {
    final resp = await client
        .post(_uri(path), headers: {'Content-Type': 'application/json'},
            body: jsonEncode(body ?? {}))
        .timeout(timeout);
    return _decode(resp);
  }

  Future<dynamic> put(String path,
      {Object? body, Duration timeout = const Duration(seconds: 120)}) async {
    final resp = await client
        .put(_uri(path), headers: {'Content-Type': 'application/json'},
            body: jsonEncode(body ?? {}))
        .timeout(timeout);
    return _decode(resp);
  }

  Future<dynamic> delete(String path, {Map<String, String>? query}) async {
    final resp = await client
        .delete(_uri(path, query))
        .timeout(const Duration(seconds: 120));
    return _decode(resp);
  }

  dynamic _decode(http.Response resp) {
    // Track parsing metrics in debug mode
    if (kDebugMode && resp.bodyBytes.length > 0) {
      final sizeMb = resp.bodyBytes.length / (1024 * 1024);
      if (sizeMb > 2.0) {
        debugOffIsolateParses++;
        // 注意：主 isolate 大包走同步 jsonDecode（getBig 才用 compute），
        // 计数器名 debugOffIsolateParses 仅表示「>2MB 大包」次数
        print('[ApiClient] Large payload (${sizeMb.toStringAsFixed(2)}MB)');
      } else {
        debugUiIsolateParsedRows++;
      }
    }

    final payload = jsonDecode(utf8.decode(resp.bodyBytes));

    // Count rows for tables (approximate by number of top-level keys)
    if (payload is Map && kDebugMode) {
      final rowCount = payload.length;
      if (rowCount > 1000) {
        debugDecodedRows += rowCount;
      }
    }

    if (resp.statusCode >= 400) {
      throw ApiException(resp.statusCode, payload is Map ? (payload['error'] ?? payload.toString()) : payload.toString());
    }
    return payload;
  }

  /// 超过 2MB 的响应在后台 isolate 解码（getBig 专用阈值）。
  static const int _bigIsolateThreshold = 2 * 1024 * 1024;

  /// 大表专用 GET（S3）：
  ///
  /// body > [_bigIsolateThreshold] 时把解码搬到后台 isolate（`compute`，
  /// worker 内返回已 `Map<String, dynamic>`
  /// 化的表，避免主 isolate 再 cast）；≤ 阈值走普通路径。4xx → ApiException
  /// 的判定留在主 isolate（worker 里抛异常回传会丢类型与状态码）。
  ///
  /// 仅经典编辑器全表视图需要它；剧情图/导演走 `?prefix=` 小批量（S3 主线），
  /// `compute` 把 9.8 万条对象图整体序列化送回 UI 的总工作量反而更高。
  Future<Map<String, dynamic>> getBig(String path,
      {Map<String, String>? query}) async {
    final resp = await client
        .get(_uri(path, query))
        .timeout(const Duration(seconds: 120));
    if (resp.statusCode >= 400) {
      final payload = jsonDecode(utf8.decode(resp.bodyBytes));
      throw ApiException(
          resp.statusCode,
          payload is Map
              ? (payload['error'] ?? payload.toString())
              : payload.toString());
    }
    final bodyBytes = resp.bodyBytes;
    if (kDebugMode) debugOffIsolateParses++;
    if (bodyBytes.length > _bigIsolateThreshold) {
      // compute 送入一次字节拷贝（40MB ≈ 十几毫秒），换来的是
      // 几秒的 jsonDecode + utf8.decode 整体移出 UI isolate，净赚。
      final out = await compute(_decodeTableIsolate, bodyBytes);
      if (kDebugMode) debugDecodedRows += out.length;
      return out;
    }
    if (kDebugMode) debugUiIsolateParsedRows++;
    final payload = jsonDecode(utf8.decode(bodyBytes));
    return payload is Map<String, dynamic>
        ? payload
        : <String, dynamic>{};
  }
}

/// [compute] 入口：在后台 isolate 解码整表 JSON。
Map<String, dynamic> _decodeTableIsolate(Uint8List bytes) {
  final payload = jsonDecode(utf8.decode(bytes));
  if (payload is Map) {
    return payload.map((k, v) => MapEntry(k.toString(), v));
  }
  return <String, dynamic>{};
}

class ApiException implements Exception {
  ApiException(this.statusCode, this.message);
  final int statusCode;
  final String message;
  @override
  String toString() => 'API $statusCode: $message';
}
