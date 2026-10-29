/// Web HTTP 客户端工厂：浏览器（XHR/fetch）自己管理连接池与并发，
/// 这里保持平台默认实现，不做任何干预。
library;

import 'package:http/http.dart' as http;

http.Client createApiClient() => http.Client();
