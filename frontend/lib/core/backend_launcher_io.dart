import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import 'api_client.dart';
import 'models.dart';

/// 单次就绪探测的结果分类。
enum _ProbeOutcome {
  /// 200：后端已就绪。
  ready,

  /// SocketException（端口尚未监听等）：socket 毫秒级失败。
  refused,

  /// 达到单次请求超时：端口已在监听但 HTTP 未就绪，本轮已烧满探测预算。
  timedOut,

  /// 其他失败（非 200 状态码、连接被重置等瞬时错误）。
  failed,
}

/// 后端进程管理（发行模式 + 开发模式从源码启动）。
///
/// 桌面发行版目录内包含一个原生 C++ 后端可执行文件（Windows 为 backend.exe，
/// macOS/Linux 为 backend）：前端启动时探测本地 API 是否就绪，未就绪则自动
/// 拉起该文件，前端退出时回收自己拉起的进程。
/// 开发模式（flutter run）下同目录没有后端可执行文件，debug 构建会回退到
/// 仓库源码构建产物（native/build/bin 或 build-native/bin，可由 run_dev.py
/// 自动构建），探测逻辑见 [sourceBackendPath] / [buildSourceBackend]。
/// Android 上无法运行子进程，后端由原生 JNI（libbackend_shared.so）在后台线程
/// 内嵌启动（见 MainActivity.kt / jni_bridge.cpp），本类轮询等待其就绪。
class BackendLauncher {
  BackendLauncher._();
  static final BackendLauncher instance = BackendLauncher._();

  static const int port = 8765;

  /// 各平台桌面发行版中后端可执行文件名（与前端主程序同目录）。
  static String get backendExeName =>
      Platform.isWindows ? 'backend.exe' : 'backend';

  /// Android 上后端由原生 JNI 内嵌运行，不走子进程。
  static bool get supportsSpawn => !Platform.isAndroid;

  Process? _process; // 由本类拉起的后端进程
  Future<bool>? _pending; // ensureBackend 防重入
  bool _intentionalShutdown = false; // 主动回收中（区别于崩溃/被杀）

  /// 就绪探测复用的客户端：顶层 http.get 每次新建 HttpClient 且不关闭，
  /// 冷启动等待轮询（Android 最多百余轮）会成倍泄漏 socket 组。整个
  /// ensureBackend 周期共用本实例（[_ensure] 的 finally 中关闭并置空），
  /// 单次请求只设短超时。
  http.Client? _probeClient;

  /// 是否由本类拉起了后端（发行模式）。
  bool get launchedByUs => _process != null;

  /// 单次就绪探测：返回结果分类，供轮询方区分「连接拒绝（socket 瞬时
  /// 失败，可立即重试）」与「真超时（端口已监听但 HTTP 未就绪）」做分级退避。
  Future<_ProbeOutcome> _probeOutcome({
    Duration timeout = const Duration(milliseconds: 800),
  }) async {
    try {
      final resp = await (_probeClient ??= http.Client())
          .get(Uri.parse('http://127.0.0.1:$port/api/ping'))
          .timeout(timeout);
      return resp.statusCode == 200
          ? _ProbeOutcome.ready
          : _ProbeOutcome.failed;
    } on SocketException {
      return _ProbeOutcome.refused;
    } on TimeoutException {
      return _ProbeOutcome.timedOut;
    } catch (_) {
      return _ProbeOutcome.failed;
    }
  }

  /// 探测后端 API 是否已就绪（短超时）。
  Future<bool> probe({Duration timeout = const Duration(milliseconds: 800)}) async =>
      (await _probeOutcome(timeout: timeout)) == _ProbeOutcome.ready;

  /// 读取后端落盘的进程令牌（安全批次 B：X-Backend-Token）。
  ///
  /// 后端把令牌写在 editor_root()/.backend_token（桌面=后端可执行文件同目
  /// 录、Android=<filesDir>/data）。桌面发行版前后端同目录；开发模式后端从
  /// 源码构建产物启动，用其后端 exe 目录。Android 经 MainActivity 的
  /// MethodChannel 读取（dataRoot 只有原生侧知道，Dart 无 path_provider）。
  /// 读不到（旧包后端未启用令牌）返回 null，ApiClient 不带令牌头；若后端
  /// 实际已启用会以 403 fail-closed 拒绝，属预期错误面。
  Future<String?> _loadBackendToken() async {
    try {
      if (!supportsSpawn) {
        const ch = MethodChannel('studentage/backend');
        final t = await ch.invokeMethod<String>('backendToken');
        return (t == null || t.isEmpty) ? null : t;
      }
      final exe = _findBackendExe();
      final candidates = <String>[
        if (exe != null) File(exe).parent.path,
        File(Platform.resolvedExecutable).parent.path,
      ];
      for (final dir in candidates) {
        final f = File('$dir${Platform.pathSeparator}.backend_token');
        if (f.existsSync()) {
          final t = f.readAsStringSync().trim();
          if (t.isNotEmpty) return t;
        }
      }
    } catch (_) {
      // 令牌读取失败不阻断启动：后端侧未启用令牌时无影响；已启用时表现为
      // 403（fail-closed），比静默禁用安全。
    }
    return null;
  }

  /// 就绪后装载令牌到 ApiClient（幂等；读不到保持 null）。
  Future<void> _loadBackendTokenIntoClient() async {
    final t = await _loadBackendToken();
    if (t != null) ApiClient.backendToken = t;
  }

  /// 确保后端就绪：已就绪直接返回 true；
  /// 否则查找并拉起 backend.exe（发行模式=同目录；debug 构建回退到
  /// 源码构建产物，见 [_findBackendExe]），等待其就绪后返回 true；
  /// 找不到可执行文件（开发模式且未构建）或拉起失败返回 false。
  Future<bool> ensureBackend() => _pending ??= _ensure();

  Future<bool> _ensure() async {
    try {
      if (await probe()) {
        await _loadBackendTokenIntoClient(); // 后端可能已被外部拉起（run_dev）
        return true;
      }
      if (!supportsSpawn) {
        // Android：后端由原生 JNI 在后台线程内嵌启动（见 MainActivity.kt /
        // jni_bridge.cpp），资源配置解压后端口才就绪，单次探测必然失败；
        // 此处轮询等待内嵌后端完成启动。
        // 退避按失败类型分级：真超时（端口已监听但 HTTP 未就绪，本轮已烧满
        // 1s 探测超时）再等 500ms；连接拒绝/瞬时失败（socket 毫秒级返回，
        // 无需为凑固定轮数干等）短睡 300ms 立即重试，就绪即弹出更快。
        // 总预算改为封顶 120s（与旧版约 45~135s 同量级、不低于 90s 下限，
        // 覆盖资源包解压极慢的场景），成功响应即刻返回。
        final deadline = DateTime.now().add(const Duration(seconds: 120));
        while (true) {
          final outcome =
              await _probeOutcome(timeout: const Duration(seconds: 1));
          if (outcome == _ProbeOutcome.ready) {
            await _loadBackendTokenIntoClient();
            return true;
          }
          if (!DateTime.now().isBefore(deadline)) return false;
          await Future.delayed(outcome == _ProbeOutcome.timedOut
              ? const Duration(milliseconds: 500)
              : const Duration(milliseconds: 300));
        }
      }

      final exe = _findBackendExe();
      if (exe == null) return false; // 开发模式未构建：走错误页「编译并启动后端」或 run_dev.py

      final proc = await Process.start(
        exe,
        ['--port', '$port'],
        workingDirectory: File(exe).parent.path,
      );
      _process = proc;

      // 阶段 3：订阅退出码。此前后端进程在会话中途崩溃/被外部杀掉无人察觉，
      // 状态栏仍显示 bootstrap 时的「在线」快照；现在退出即记日志并把
      // AppState 置为离线（主动 shutdown 流程除外）。
      unawaited(proc.exitCode.then((code) {
        if (kDebugMode) {
          debugPrint('[BackendLauncher] 后端进程退出 exitCode=$code '
              'intentional=$_intentionalShutdown');
        }
        if (!_intentionalShutdown && identical(_process, proc)) {
          _process = null;
          AppState.current?.setBackendOnline(false,
              error: '后端进程已退出（exitCode=$code）');
        }
      }));

      // 原生后端启动后首次就绪可能较慢，轮询等待（最多约 90 秒）。
      for (var i = 0; i < 60; i++) {
        if (await probe(timeout: const Duration(seconds: 1))) {
          await _loadBackendTokenIntoClient();
          return true;
        }
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
      // 本周期探测复用的客户端在此统一关闭（Android 轮询百余轮也只此一组 socket）
      _probeClient?.close();
      _probeClient = null;
      _pending = null;
    }
  }

  /// 回收本类拉起的后端进程（前端退出时调用）。
  ///
  /// PyInstaller onefile 由「引导进程 + 服务子进程」组成，直接 kill 只能
  /// 杀掉引导进程、留下服务子进程占用端口，因此优先调用 /api/shutdown
  /// 让服务进程自退，引导进程随之退出；失败再兜底 kill。
  Future<void> shutdownBackend() async {
    _intentionalShutdown = true; // 主动回收：退出监听不得把状态改成异常离线
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
    // 开发模式（flutter run）：回退到仓库源码构建产物；release 构建不探测，
    // 避免发行版误用开发机上构建目录里的旧后端。
    return sourceBackendPath();
  }

  /// debug 构建下探测仓库源码构建的后端可执行文件；未构建或非 debug 返回 null。
  /// 后端资源目录（native/assets）由 C++ 侧 assets::candidate_paths 从 exe
  /// 目录逐级向上解析，源码布局可直接运行，无需拷贝。
  String? sourceBackendPath() {
    if (!kDebugMode || !supportsSpawn) return null;
    return resolveSourceBackend(
      roots: sourceSearchRoots(
        cwd: Directory.current.path,
        exeDir: File(Platform.resolvedExecutable).parent.path,
        separator: Platform.pathSeparator,
      ),
      fileExists: (p) => File(p).existsSync(),
      separator: Platform.pathSeparator,
      exeName: backendExeName,
    );
  }

  /// 开发模式：从 native 源码增量构建后端目标（跳过 CLI/TUI 与测试，
  /// 见 build.cmd/build.sh 的 --no-tests --target），成功后拉起并等待就绪。
  /// 返回 (是否就绪, 构建输出末段)；失败时调用方把 log 展示到错误页。
  Future<({bool ok, String log})> buildSourceBackend() async {
    final nativeDir = _findNativeSourceDir();
    if (nativeDir == null) {
      return (
        ok: false,
        log: '未找到 native/build.cmd：当前不是仓库源码环境，无法自动构建',
      );
    }
    final script = Platform.isWindows ? 'build.cmd' : 'build.sh';
    ProcessResult res;
    try {
      res = await Process.run(
        Platform.isWindows ? 'cmd' : 'bash',
        [
          if (Platform.isWindows) '/c',
          script,
          '--no-tests',
          '--target',
          'backend',
        ],
        workingDirectory: nativeDir,
      );
    } catch (e) {
      return (ok: false, log: '启动构建进程失败：$e');
    }
    final log = _outputTail(res);
    if (res.exitCode != 0) {
      return (ok: false, log: '构建失败（exitCode=${res.exitCode}）：\n$log');
    }
    final ok = await ensureBackend();
    return (
      ok: ok,
      log: ok ? log : '构建成功但未能连接后端，请重试或运行 run_dev.py：\n$log',
    );
  }

  /// 从当前目录/主程序目录逐级向上定位含构建脚本的 native/ 源码目录。
  static String? _findNativeSourceDir() {
    for (final dir in sourceSearchRoots(
      cwd: Directory.current.path,
      exeDir: File(Platform.resolvedExecutable).parent.path,
      separator: Platform.pathSeparator,
    )) {
      for (final script in const ['build.cmd', 'build.sh']) {
        final f = File('$dir${Platform.pathSeparator}native'
            '${Platform.pathSeparator}$script');
        if (f.existsSync()) return f.parent.path;
      }
    }
    return null;
  }

  static String _outputTail(ProcessResult res) {
    var text = '${res.stdout ?? ''}\n${res.stderr ?? ''}'.trim();
    const maxChars = 1500;
    if (text.length > maxChars) text = '…\n${text.substring(text.length - maxChars)}';
    return text;
  }

  /// 源码后端探测的搜索根：从 [cwd] 与 [exeDir] 各自向上最多 [maxUp] 级
  /// （纯字符串运算，去重保序）。flutter run 的 cwd 通常是 frontend/；
  /// Windows runner 调试产物的 exeDir 则在 frontend/build/windows/.../Debug
  /// 深处，两者都需要向上走。
  @visibleForTesting
  static List<String> sourceSearchRoots({
    required String cwd,
    required String exeDir,
    String separator = '/',
    int maxUp = 8,
  }) {
    String parentOf(String p) {
      var s = p;
      while (s.length > 1 && s.endsWith(separator)) {
        s = s.substring(0, s.length - 1);
      }
      final i = s.lastIndexOf(separator);
      if (i < 0) return '';
      final head = s.substring(0, i);
      if (head.isEmpty) return separator; // '/x' 的父目录是 '/'
      // 'C:\x' 的父目录是 'C:\'（盘根保留尾分隔符）
      if (head.length == 2 && head[1] == ':') return '$head$separator';
      return head;
    }

    final out = <String>{}; // LinkedHashSet：去重且保序
    for (final start in [cwd, exeDir]) {
      var dir = start;
      for (var i = 0; i <= maxUp && dir.isNotEmpty; i++) {
        out.add(dir);
        final parent = parentOf(dir);
        if (parent == dir) break; // 已到文件系统根
        dir = parent;
      }
    }
    return out.toList();
  }

  /// 纯函数：在给定搜索根下探测源码构建的后端可执行文件，找不到返回 null。
  /// 仓库布局候选：`<root>/native/build/bin/<exeName>` 与
  /// `<root>/build-native/bin/<exeName>`。
  @visibleForTesting
  static String? resolveSourceBackend({
    required List<String> roots,
    required bool Function(String path) fileExists,
    String separator = '/',
    String exeName = 'backend',
  }) {
    for (final dir in roots) {
      for (final layout in const [
        ['native', 'build', 'bin'],
        ['build-native', 'bin'],
      ]) {
        final p = [dir, ...layout, exeName].join(separator);
        if (fileExists(p)) return p;
      }
    }
    return null;
  }
}
