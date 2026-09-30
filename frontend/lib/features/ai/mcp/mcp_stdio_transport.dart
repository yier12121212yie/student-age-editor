/// stdio 传输（独立文件，网页版拆分 M0）：依赖 `dart:io` 拉起本地子进程，
/// 因此**不能**进入 web 编译的依赖图——由 [../mcp/mcp_transport_factory.dart]
/// 条件导出，仅在有 dart:io 的平台（桌面/Android）被装配。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'mcp_client.dart' show McpException, McpTransport, decodeJsonLine;
import 'mcp_types.dart';

/// stdio 传输：拉起子进程，stdout 按行读取分隔 JSON-RPC。
class StdioTransport implements McpTransport {
  StdioTransport(this.cfg);

  final McpServerConfig cfg;

  Process? _process;
  StreamSubscription<String>? _stdoutSub;
  final StreamController<Map<String, dynamic>> _incoming =
      StreamController.broadcast();
  bool _closed = false;

  /// terminate 后等待子进程退出的宽限期，超时升级 SIGKILL。
  static const _killGrace = Duration(seconds: 3);

  @override
  Future<void> start() async {
    if (cfg.command.trim().isEmpty) {
      throw McpException('stdio 传输缺少 command（服务器 ${cfg.id}）');
    }
    // 注意：Windows 下 `npx` 实际是 npx.cmd，直接 exec 会失败，
    // 接线层配置命令时应使用 `npx.cmd` 或 `cmd /c` 包装。
    final process = await Process.start(cfg.command, cfg.args);
    _process = process;
    // allowMalformed：个别服务器偶尔向 stdout 写非 UTF-8 字节时
    // 不能让解码异常炸掉整条消息流。
    _stdoutSub = process.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen((line) {
          final msg = decodeJsonLine(line);
          if (msg != null && !_closed) _incoming.add(msg);
        });
    // 持续排空 stderr，防止管道写满阻塞子进程；输出内容不参与协议。
    unawaited(process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .drain<void>()
        .catchError((_) {}));
    // 子进程意外退出时关闭消息流，让上层（及挂起请求）尽快感知。
    unawaited(process.exitCode.then((_) => _onChildExit()));
  }

  void _onChildExit() {
    if (!_closed) {
      _closed = true;
      unawaited(_incoming.close());
    }
  }

  @override
  void send(Map<String, dynamic> msg) {
    final stdin = _process?.stdin;
    if (stdin == null) {
      throw McpException('stdio 传输未启动（服务器 ${cfg.id}）');
    }
    stdin.writeln(jsonEncode(msg));
  }

  @override
  Stream<Map<String, dynamic>> get incoming => _incoming.stream;

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final process = _process;
    _process = null;
    await _stdoutSub?.cancel();
    _stdoutSub = null;
    if (process != null) {
      try {
        process.stdin.close();
      } catch (_) {}
      // 先礼貌 terminate（Windows 上即 TerminateProcess），
      // 宽限期内没退就 SIGKILL 兜底，绝不留孤儿进程。
      process.kill(ProcessSignal.sigterm);
      try {
        await process.exitCode.timeout(_killGrace);
      } on TimeoutException {
        process.kill(ProcessSignal.sigkill);
        try {
          await process.exitCode.timeout(_killGrace);
        } catch (_) {}
      } catch (_) {}
    }
    await _incoming.close();
  }
}
