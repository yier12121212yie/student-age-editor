/// IO（桌面/移动）HTTP 客户端工厂：解除 dart:io HttpClient 默认的
/// `maxConnectionsPerHost = 6` 并发限制（画廊网格一屏 30~50 个瓦片时，
/// 40 多张图片会被 6 个一组串行阻塞，造成严重瀑布流等待）。
library;

import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

http.Client createApiClient() {
  final io = HttpClient()
    ..maxConnectionsPerHost = 32
    ..idleTimeout = const Duration(seconds: 30);
  return IOClient(io);
}
