import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'api_client.dart';

/// 发行模式后端进程管理。
///
/// 桌面发行版目录内包含一个 PyInstaller 打包的后端可执行文件
/// （Windows 为 backend.exe，macOS/Linux 为 backend）：
/// 前端启动时探测本地 API 是否就绪，未就绪则自动拉起该文件，
/// 前端退出时回收自己拉起的进程。开发模式（flutter run，由 run_dev.py
/// 启动后端）下同目录不存在后端可执行文件，本类不干预。
/// Android 上无法运行 PyInstaller 子进程，由 Chaquopy 内嵌后端负责，
/// 本类仅做 API 探测。
class BackendLauncher {
  BackendLauncher._();
  static final BackendLauncher instance = BackendLauncher._();

  static const int port = 8765;

  /// 各平台桌面发行版中后端可执行文件名（与前端主程序同目录）。
  static String get backendExeName =>
      Platform.isWindows ? 'backend.exe' : 'backend';

  /// Android 上后端由 Chaquopy 内嵌运行（BackendEmbed），不走子进程。
  static bool get supportsSpawn => !Platform.isAndroid;

  Process? _process; // 由本类拉起的后端进程
  Future<bool>? _pending; // ensureBackend 防重入

  /// 是否由本类拉起了后端（发行模式）。
  bool get launchedByUs => _process != null;

  /// 探测后端 API 是否已就绪（短超时）。
  Future<bool> probe({Duration timeout = const Duration(milliseconds: 800)}) async {
    try {
      final resp = await http
          .get(Uri.parse('http://127.0.0.1:$port/api/ping'))
          .timeout(timeout);
      return resp.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// 确保后端就绪：已就绪直接返回 true；
  /// 否则查找并拉起同目录 backend.exe（发行模式），等待其就绪后返回 true；
  /// 找不到 backend.exe（开发模式）或拉起失败返回 false。
  Future<bool> ensureBackend() => _pending ??= _ensure();

  Future<bool> _ensure() async {
    try {
      if (await probe()) return true;
      if (!supportsSpawn) return false; // Android：由原生侧内嵌后端负责

      final exe = _findBackendExe();
      if (exe == null) return false; // 开发模式：后端由 run_dev.py 负责

      final proc = await Process.start(
        exe,
        ['--port', '$port'],
        workingDirectory: File(exe).parent.path,
      );
      _process = proc;

      // onefile 首次解压较慢，轮询等待就绪（最多约 30 秒）。
      for (var i = 0; i < 60; i++) {
        if (await probe(timeout: const Duration(seconds: 1))) return true;
        if (await _hasExited(proc)) {
          _process = null; // 启动即退出（如端口被占、环境异常），不再重试
          return false;
        }
        await Future.delayed(const Duration(milliseconds: 500));
      }
      return false;
    } catch (_) {
      return false;
    } finally {
      _pending = null;
    }
  }

  /// 回收本类拉起的后端进程（前端退出时调用）。
  ///
  /// PyInstaller onefile 由「引导进程 + 服务子进程」组成，直接 kill 只能
  /// 杀掉引导进程、留下服务子进程占用端口，因此优先调用 /api/shutdown
  /// 让服务进程自退，引导进程随之退出；失败再兜底 kill。
  Future<void> shutdownBackend() async {
    final proc = _process;
    _process = null;
    if (proc == null || await _hasExited(proc)) return;

    try {
      await ApiClient.instance
          .post('/api/shutdown')
          .timeout(const Duration(seconds: 3));
    } catch (_) {
      // 服务端可能在响应前就退出，忽略连接类异常
    }
    try {
      await proc.exitCode.timeout(const Duration(seconds: 5));
      return; // 引导进程已随服务进程退出
    } on TimeoutException {
      // 优雅关闭失败，兜底强杀引导进程
    }
    try {
      proc.kill();
    } catch (_) {}
    try {
      await proc.exitCode.timeout(const Duration(seconds: 3));
    } catch (_) {}
  }

  /// 进程是否已退出（exitCode 是 Future，用零超时探测）。
  Future<bool> _hasExited(Process proc) async {
    try {
      await proc.exitCode.timeout(Duration.zero);
      return true;
    } on TimeoutException {
      return false;
    }
  }

  String? _findBackendExe() {
    // 环境变量覆盖（便于开发/测试时指定后端路径）。
    final fromEnv = Platform.environment['STUDENT_AGE_BACKEND_EXE'];
    if (fromEnv != null && fromEnv.isNotEmpty && File(fromEnv).existsSync()) {
      return fromEnv;
    }
    // 发行模式：后端可执行文件与前端主程序同目录。
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final bundled = File('$exeDir${Platform.pathSeparator}$backendExeName');
    if (bundled.existsSync()) return bundled.path;
    return null;
  }
}
