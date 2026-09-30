import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'api_client.dart';

/// Web 平台的后端「启动器」：浏览器无法拉起/回收本地进程，后端由部署方
/// （同源静态托管 + /api 反代，或 --dart-define=API_BASE 指向独立服务）提供。
/// 这里只保留与桌面版同签名的公共 API，探测逻辑退化为多次 GET /api/ping。
class BackendLauncher {
  BackendLauncher._();
  static final BackendLauncher instance = BackendLauncher._();

  /// Web 上无进程可管理：恒 false（app.dart 据此隐藏「编译并启动后端」按钮）。
  static bool get supportsSpawn => false;

  /// 是否由本类拉起了后端：Web 永不。
  bool get launchedByUs => false;

  Future<bool>? _pending; // ensureBackend 防重入

  Uri get _pingUri => Uri.parse('${ApiClient.instance.baseUrl}/api/ping');

  /// 单次就绪探测：短超时 GET /api/ping。
  Future<bool> probe({
    Duration timeout = const Duration(milliseconds: 1500),
  }) async {
    final client = http.Client();
    try {
      final resp = await client.get(_pingUri).timeout(timeout);
      return resp.statusCode == 200;
    } catch (_) {
      return false;
    } finally {
      client.close();
    }
  }

  /// 确保后端就绪：重试探测数次即返回成功/失败，绝不 spawn 进程。
  Future<bool> ensureBackend() => _pending ??= _ensure();

  Future<bool> _ensure() async {
    try {
      // 首次加载可能有冷启动竞态：最多探测 3 次，间隔递增。
      for (var i = 0; i < 3; i++) {
        if (await probe()) return true;
        await Future.delayed(Duration(milliseconds: 500 * (i + 1)));
      }
      return false;
    } finally {
      _pending = null;
    }
  }

  /// Web 无进程可回收：空操作。
  Future<void> shutdownBackend() async {}

  /// Web 无从源码构建后端：直接返回失败（桌面版才可达此路径）。
  Future<({bool ok, String log})> buildSourceBackend() async {
    return (
      ok: false,
      log: 'Web 平台无法从源码构建后端：请确保后端服务已启动并暴露 /api 端点',
    );
  }

  // 以下三个「源码后端探测」API 与 backend_launcher_io.dart 保持同签名，
  // 仅为满足本文件头注释「两份实现暴露同一公共 API」的约定：Web 上无本机
  // 文件系统与源码构建产物，全部返回「无」语义（真实实现见 io 版）。

  /// Web 无源码构建产物可探测：恒 null。
  String? sourceBackendPath() => null;

  /// Web 无文件系统搜索根：恒空列表（参数与 io 版一致，仅为 API 对称）。
  @visibleForTesting
  static List<String> sourceSearchRoots({
    required String cwd,
    required String exeDir,
    String separator = '/',
    int maxUp = 8,
  }) =>
      const [];

  /// Web 无从探测：恒 null。
  @visibleForTesting
  static String? resolveSourceBackend({
    required List<String> roots,
    required bool Function(String path) fileExists,
    String separator = '/',
    String exeName = 'backend',
  }) =>
      null;
}
