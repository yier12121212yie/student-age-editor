import 'dart:async';

import 'package:http/http.dart' as http;

import 'backend_launcher.dart';

/// 幂等加载的「后端断线自愈」包装：连接级失败时重新拉起后端并重试一次。
///
/// 从源码运行（debug）时后端由前端按需拉起（见 [BackendLauncher]）：首次
/// 请求可能早于后端就绪，或会话中途后端被外部回收（run_dev 收尾、手动结束、
/// detach 后工具退出等），此时请求会以 SocketException / ClientException
/// 失败（表现为「远程计算机拒绝网络连接」）。本包装捕获这类**连接级**失败，
/// 调 [BackendLauncher.ensureBackend] 把源码构建产物重新拉起就绪，再重试动作。
///
/// **仅用于幂等加载（GET/只读）**：连接失败时服务端可能已收到并处理过写请求，
/// 重试会重复执行，因此有副作用的 POST/PUT/DELETE 不要使用本包装。业务错误
/// （HTTP 4xx/5xx，ApiClient 解码为 ApiException）不属于连接级失败，原样
/// 抛出，不掩盖真实问题。
Future<T> withBackendRetry<T>(
  Future<T> Function() action, {
  int attempts = 2,
  Duration ensureTimeout = const Duration(seconds: 15),
  Future<bool> Function()? ensureBackend,
}) async {
  final ensure = ensureBackend ?? BackendLauncher.instance.ensureBackend;
  Object? last;
  for (var i = 0; i < attempts; i++) {
    try {
      return await action();
    } catch (e) {
      last = e;
      if (!isBackendConnectionError(e) || i == attempts - 1) rethrow;
      // 重新确保后端就绪；失败/超时也不阻断重试（可能是瞬时抖动）。
      try {
        await ensure().timeout(ensureTimeout);
      } catch (_) {}
    }
  }
  throw last!; // 循环内要么 return、要么 rethrow，理论上不可达。
}

/// 是否为「连不上后端」类失败（区别于 HTTP 4xx/5xx 业务错误）。
///
/// IOClient 会把底层 SocketException 包成 [http.ClientException]；Web 的
/// BrowserClient 亦抛 [http.ClientException]。二者都按连接级处理。
bool isBackendConnectionError(Object e) {
  if (e is http.ClientException) return true;
  final s = e.toString();
  return s.contains('SocketException') ||
      s.contains('Connection refused') ||
      s.contains('Connection reset') ||
      s.contains('Connection closed') ||
      s.contains('Failed host lookup');
}
