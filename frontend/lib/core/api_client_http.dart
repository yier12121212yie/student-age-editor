/// 平台化 HTTP 客户端工厂（条件导出）。
///
/// 桌面/移动端（dart:io）放宽 `HttpClient.maxConnectionsPerHost` 默认的 6 并发
/// 限制到 32，让画廊一屏几十张缩略图能并行流水线拉取；Web 端交给浏览器自身的
/// 连接池管理（不应也不能干预）。
library;

export 'api_client_http_io.dart'
    if (dart.library.js_interop) 'api_client_http_web.dart';
