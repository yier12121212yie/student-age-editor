import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

/// 与 Python 后端通信的本地 HTTP 客户端。
class ApiClient {
  ApiClient._();
  static final ApiClient instance = ApiClient._();

  String baseUrl = 'http://127.0.0.1:8765';

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
    final payload = jsonDecode(utf8.decode(resp.bodyBytes));
    if (resp.statusCode >= 400) {
      throw ApiException(resp.statusCode, payload is Map ? (payload['error'] ?? payload.toString()) : payload.toString());
    }
    return payload;
  }
}

class ApiException implements Exception {
  ApiException(this.statusCode, this.message);
  final int statusCode;
  final String message;
  @override
  String toString() => 'API $statusCode: $message';
}
