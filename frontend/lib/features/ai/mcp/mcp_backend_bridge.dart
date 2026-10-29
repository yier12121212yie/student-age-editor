/// Web 端 stdio MCP 桥接（C2）：浏览器不能起子进程，改由后端持有。
///
/// 后端接口见 `native/server/services/mcp_bridge.h`：
///   start → 拿 session_id；send → 写一行 JSON-RPC；stream → SSE `data:` 行；
///   stop → 终止子进程。本文件只在 Web 工厂里装配。
///
/// 可用性由后端 policy 决定：本机浏览器版恒可用；自托管默认关闭，管理员
/// 在 gateway.json 的 `mcp_stdio` 显式开启并给出命令白名单后可用。
library;

import 'dart:async';

import '../../../core/api_client.dart';
import '../../../core/sse_client.dart';
import 'mcp_client.dart' show McpException, McpTransport, decodeJsonLine;
import 'mcp_types.dart';

class McpStdioBridge {
  McpStdioBridge._();

  static Future<bool>? _cached;

  /// 后端桥接是否可用（同一次运行缓存；设置页与聊天接线共用）。
  static Future<bool> available() => _cached ??= _probe();

  /// 强制下次重新探测（网关管理员刚开启/关闭时）。
  static void invalidate() => _cached = null;

  static Future<bool> _probe() async {
    try {
      final raw = await ApiClient.instance.get('/api/mcp/stdio/policy');
      return raw is Map && raw['available'] == true;
    } catch (_) {
      // 旧后端没有该端点：网页版仍按「不支持 stdio」处理。
      return false;
    }
  }
}

/// 通过后端 `/api/mcp/stdio/*` 代持子进程的传输实现。
class BackendStdioTransport implements McpTransport {
  BackendStdioTransport(this.cfg);

  final McpServerConfig cfg;

  final StreamController<Map<String, dynamic>> _incoming =
      StreamController.broadcast();
  StreamSubscription<String>? _sub;
  void Function()? _abort;
  String? _sessionId;
  bool _closed = false;

  @override
  Future<void> start() async {
    if (cfg.command.trim().isEmpty) {
      throw McpException('stdio 传输缺少 command（服务器 ${cfg.id}）');
    }
    final raw = await ApiClient.instance.post(
      '/api/mcp/stdio/start',
      body: <String, dynamic>{
        'command': cfg.command.trim(),
        'args': cfg.args,
      },
      timeout: const Duration(seconds: 30),
    );
    final map = raw is Map ? raw.cast<String, dynamic>() : const <String, dynamic>{};
    final sid = (map['session_id'] ?? '').toString();
    if (sid.isEmpty) throw McpException('MCP 桥接未返回 session_id（服务器 ${cfg.id}）');
    _sessionId = sid;

    final uri = Uri.parse(
      '${ApiClient.instance.baseUrl}/api/mcp/stdio/stream'
      '?session_id=${Uri.encodeQueryComponent(sid)}',
    );
    final stream = openSseGetStream(
      uri: uri,
      headers: ApiClient.instance.authHeaders(),
      registerAbort: (abort) => _abort = abort,
    );
    _sub = stream.listen(
      (line) {
        final msg = decodeJsonLine(line);
        if (msg != null && !_closed) _incoming.add(msg);
      },
      onError: (_) => _onStreamDone(),
      onDone: _onStreamDone,
    );
  }

  void _onStreamDone() {
    if (_closed) return;
    _closed = true;
    unawaited(_incoming.close());
  }

  @override
  void send(Map<String, dynamic> msg) {
    unawaited(_send(msg));
  }

  Future<void> _send(Map<String, dynamic> msg) async {
    final sid = _sessionId;
    if (sid == null) {
      throw McpException('stdio 桥接未启动（服务器 ${cfg.id}）');
    }
    try {
      await ApiClient.instance.post(
        '/api/mcp/stdio/send',
        body: <String, dynamic>{'session_id': sid, 'message': msg},
        timeout: const Duration(seconds: 30),
      );
    } catch (e) {
      // 带 id 的请求失败：合成一条 error 响应，避免客户端白等超时。
      final id = msg['id'];
      if (!_closed && id != null) {
        _incoming.add(<String, dynamic>{
          'jsonrpc': '2.0',
          'id': id,
          'error': <String, dynamic>{'code': -32000, 'message': 'MCP 桥接失败: $e'},
        });
      }
    }
  }

  @override
  Stream<Map<String, dynamic>> get incoming => _incoming.stream;

  @override
  Future<void> close() async {
    if (_closed) {
      await _sub?.cancel();
      _sub = null;
      return;
    }
    _closed = true;
    final sid = _sessionId;
    _sessionId = null;
    try {
      _abort?.call();
    } catch (_) {}
    _abort = null;
    await _sub?.cancel();
    _sub = null;
    if (sid != null) {
      try {
        await ApiClient.instance.post(
          '/api/mcp/stdio/stop',
          body: <String, dynamic>{'session_id': sid},
          timeout: const Duration(seconds: 10),
        );
      } catch (_) {
        // best-effort：后端空闲回收会兜底。
      }
    }
    if (!_incoming.isClosed) await _incoming.close();
  }
}
