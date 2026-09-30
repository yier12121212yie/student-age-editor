/// 最小 MCP（Model Context Protocol）客户端：只实现 tools 能力域。
///
/// 分层：
/// - [McpTransport] 抽象传输层，两个实现
///   [StdioTransport]（本地子进程、行分隔 JSON-RPC）与
///   [HttpTransport]（streamable HTTP，支持 JSON 与 SSE 两种响应）；
/// - [McpClient] JSON-RPC 客户端：`initialize` 握手 →
///   `notifications/initialized` → `tools/list`，之后可 [McpClient.callTool]。
///
/// 依赖方向：本文件 import `../ai_client.dart` 仅借用
/// [McpToolInfo.toToolDef] 的目标类型 [AiToolDef]，ai_client 不反向依赖本目录。
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../ai_client.dart';
import 'mcp_types.dart';

/// MCP 交互失败（JSON-RPC error 响应、超时、传输未启动等统一异常）。
class McpException implements Exception {
  McpException(this.message);

  /// 人类可读的错误信息（中文，UI 直接展示）。
  final String message;

  @override
  String toString() => 'McpException: $message';
}

/// 把 dynamic 值安全转成 `Map<String, dynamic>`（非 Map 返回 null）。
/// 与 ai_client.dart 同款防御：避免嵌套 JSON 的 `_Map<dynamic, dynamic>`
/// 被 `as Map<String, dynamic>` 强转抛类型错误。
Map<String, dynamic>? _asStringMap(dynamic v) {
  if (v is! Map) return null;
  return v.map((k, val) => MapEntry(k.toString(), val));
}

/// 行分隔协议解码（stdio 传输与 SSE 解析共用）：只接受以 `{` 开头且能
/// 解析为 JSON 对象的行，其余（服务器日志、进度输出、半截行）返回 null 忽略。
Map<String, dynamic>? decodeJsonLine(String line) {
  if (!line.startsWith('{')) return null;
  try {
    final v = jsonDecode(line);
    return v is Map<String, dynamic> ? v : null;
  } catch (_) {
    return null;
  }
}

/// 从 tools/list 响应解析出的一个 MCP 工具。
class McpToolInfo {
  McpToolInfo({
    required this.name,
    this.description = '',
    this.inputSchema = const {},
  });

  /// 从 tools/list 的单个工具对象解析；缺字段走默认值。
  factory McpToolInfo.fromJson(Map<String, dynamic> json) {
    return McpToolInfo(
      name: json['name']?.toString() ?? '',
      description: json['description']?.toString() ?? '',
      inputSchema: _asStringMap(json['inputSchema']) ?? const {},
    );
  }

  /// MCP 服务器内的原始工具名（[callTool] 使用）。
  final String name;

  /// 给模型看的工具说明。
  final String description;

  /// JSON Schema（object 型参数描述），直接作为 function 的 parameters。
  final Map<String, dynamic> inputSchema;

  /// 转成项目 AI 客户端的工具定义（OpenAI function 格式）：
  /// 名字加 `mcp__<serverId>__` 前缀做多服务器命名空间隔离，
  /// [AiToolDef.parameters] 即 MCP 的 inputSchema。
  ///
  /// 注意：调用时去前缀得到的名字即 [name]，接线层
  /// （tools 分发处）负责反向映射回服务器与原始名。
  AiToolDef toToolDef(String serverId) => AiToolDef(
        name: 'mcp__${serverId}__$name',
        description: description,
        parameters: inputSchema,
      );
}

/// MCP 消息传输层抽象：发收 JSON-RPC 消息（已完成对象化，
/// 具体的行分隔 / SSE 解析藏在实现里）。
abstract class McpTransport {
  /// 建立底层连接（拉起进程 / 校验 URL）。失败抛 [McpException]。
  Future<void> start();

  /// 发送一条 JSON-RPC 消息（请求或通知），fire-and-forget。
  void send(Map<String, dynamic> msg);

  /// 收到的 JSON-RPC 消息流（响应 / 通知 / 服务端请求混在一起，
  /// 由 [McpClient] 按 id 与 method 分发）。
  Stream<Map<String, dynamic>> get incoming;

  /// 关闭底层连接并释放资源，可安全重复调用。
  Future<void> close();
}

/// streamable HTTP 传输：每条 JSON-RPC 消息单独 POST 到 [cfg.url]。
///
/// 响应两种形态都支持（取决于 Accept 协商与服务器实现）：
/// - `application/json`：单个 JSON-RPC 响应对象；
/// - `text/event-stream`：SSE，逐个 `data:` 行解析 JSON 消息。
/// 首次响应的 `mcp-session-id` 响应头会记下来带到后续请求。
class HttpTransport implements McpTransport {
  HttpTransport(this.cfg, {http.Client? client})
      : _client = client ?? http.Client(),
        _ownsClient = client == null;

  final McpServerConfig cfg;

  final http.Client _client;
  final bool _ownsClient;
  final StreamController<Map<String, dynamic>> _incoming =
      StreamController.broadcast();
  String? _sessionId;
  bool _closed = false;

  /// 单次 HTTP 请求的兜底超时（正常由 [McpClient] 的 JSON-RPC
  /// 超时先行触发，这里只是防止 socket 永久悬挂）。
  static const _httpTimeout = Duration(minutes: 5);

  @override
  Future<void> start() async {
    final uri = Uri.tryParse(cfg.url.trim());
    if (uri == null ||
        !uri.hasScheme ||
        !const {'http', 'https'}.contains(uri.scheme)) {
      throw McpException('http 传输缺少有效 url（服务器 ${cfg.id}）');
    }
  }

  @override
  void send(Map<String, dynamic> msg) {
    unawaited(_post(msg));
  }

  Future<void> _post(Map<String, dynamic> msg) async {
    final id = msg['id'];
    try {
      final request = http.Request('POST', Uri.parse(cfg.url.trim()))
        ..headers.addAll({
          'content-type': 'application/json',
          'accept': 'application/json, text/event-stream',
          'mcp-session-id': ?_sessionId,
        })
        ..body = jsonEncode(msg);
      final response =
          await _client.send(request).timeout(_httpTimeout);
      final sid = response.headers['mcp-session-id'];
      if (sid != null && sid.isNotEmpty) _sessionId = sid;
      final status = response.statusCode;
      if (status == 202 || status == 204) return; // 通知已接受，无响应体
      if (status != 200) {
        await response.stream.drain<void>();
        throw McpException('HTTP $status');
      }
      final contentType = response.headers['content-type'] ?? '';
      final body =
          await response.stream.transform(const Utf8Decoder()).join();
      final messages = contentType.contains('text/event-stream')
          ? _decodeSse(body)
          : _decodeJsonBody(body);
      for (final m in messages) {
        if (!_closed) _incoming.add(m);
      }
    } catch (e) {
      // 带 id 的请求失败：合成一条 error 响应唤醒挂起的 _request，
      // 不让调用方白等满超时；通知失败则静默丢弃。
      if (!_closed && id != null) {
        _incoming.add({
          'jsonrpc': '2.0',
          'id': id,
          'error': {'code': -32000, 'message': 'HTTP 传输失败: $e'},
        });
      }
    }
  }

  /// application/json 响应体：单个对象或批量数组。
  static List<Map<String, dynamic>> _decodeJsonBody(String body) {
    final trimmed = body.trim();
    if (trimmed.isEmpty) return const [];
    final decoded = jsonDecode(trimmed);
    if (decoded is Map<String, dynamic>) return [decoded];
    if (decoded is List) {
      return decoded.whereType<Map<String, dynamic>>().toList();
    }
    return const [];
  }

  /// SSE 响应体：取每个 `data:` 行的 JSON 对象，其余行
  /// （event:/id:/注释/空行）与非 JSON 负载全部忽略。
  static List<Map<String, dynamic>> _decodeSse(String body) {
    final out = <Map<String, dynamic>>[];
    for (var line in const LineSplitter().convert(body)) {
      line = line.trim();
      if (!line.startsWith('data:')) continue;
      final payload = line.substring(5).trim();
      if (payload.isEmpty || payload == '[DONE]') continue;
      final msg = decodeJsonLine(payload);
      if (msg != null) out.add(msg);
    }
    return out;
  }

  @override
  Stream<Map<String, dynamic>> get incoming => _incoming.stream;

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _incoming.close();
    if (_ownsClient) _client.close();
  }
}

/// MCP 客户端：JSON-RPC 请求/响应匹配 + tools 能力域的三个动作。
///
/// 生命周期：`start()`（握手并缓存工具列表）→ 多次 `callTool()` →
/// `close()`。请求以自增数字 id 发出，响应按 id 回填到各自的
/// [Completer]；`initialize`/`tools/list` 用 [requestTimeout]
/// （默认 15s），`tools/call` 用 [callTimeout]（默认 120s，工具
/// 可能跑构建/检索这类长任务）。
class McpClient {
  McpClient(
    this.cfg,
    this.transport, {
    this.requestTimeout = const Duration(seconds: 15),
    this.callTimeout = const Duration(seconds: 120),
  });

  /// 服务器配置（id 用作工具命名空间前缀）。
  final McpServerConfig cfg;

  /// 底层传输（生产用 [StdioTransport]/[HttpTransport]，测试可注入假传输）。
  final McpTransport transport;

  /// 握手与 tools/list 的超时。
  final Duration requestTimeout;

  /// 单次 tools/call 的超时。
  final Duration callTimeout;

  /// MCP 协议版本（streamable HTTP 世代）。
  static const protocolVersion = '2025-03-26';

  int _nextId = 1;
  final Map<int, Completer<Map<String, dynamic>>> _pending = {};
  StreamSubscription<Map<String, dynamic>>? _sub;
  List<McpToolInfo> _tools = const [];
  bool _connected = false;

  /// 握手完成后可用的工具列表缓存（start 期间填充）。
  List<McpToolInfo> get tools => List.unmodifiable(_tools);

  /// 是否已完成 initialize 握手并处于可用状态。
  bool get connected => _connected;

  /// 建立连接：transport.start → `initialize` 握手 →
  /// `notifications/initialized` → `tools/list`（结果缓存到 [tools]）。
  Future<void> start() async {
    await transport.start();
    _sub = transport.incoming.listen(
      _onMessage,
      // 传输侧以 done 表示断连，错误同样按断连处理（挂起请求统一失败）。
      onError: (_) => _onTransportDone(),
      onDone: _onTransportDone,
    );
    await _request('initialize', {
      'protocolVersion': protocolVersion,
      'capabilities': const <String, dynamic>{},
      'clientInfo': const {'name': 'StudentAgeEditor', 'version': '0.1.0'},
    }, requestTimeout);
    // 握手回执后的确认通知（无 id、无响应）。
    transport.send({
      'jsonrpc': '2.0',
      'method': 'notifications/initialized',
    });
    _connected = true;
    _tools = await listTools();
  }

  /// 拉取工具列表（也用于 start 内部；结果同步刷新 [tools] 缓存）。
  Future<List<McpToolInfo>> listTools() async {
    final resp = await _request('tools/list', const {}, requestTimeout);
    final result = _asStringMap(resp['result']) ?? const {};
    final list = (result['tools'] as List? ?? const [])
        .map((e) => McpToolInfo.fromJson(_asStringMap(e) ?? const {}))
        .toList();
    _tools = list;
    return list;
  }

  /// 调用工具并把 content 块拼接为纯文本返回（给模型直接吃）。
  ///
  /// text 块原文拼接；image/resource 块降级为 `[image]` 占位；
  /// 其余块类型降级为 `[<type>]`。服务器返回 `isError: true` 时
  /// 不抛异常，而是返回 `MCP 工具错误: …` 文本，让模型自行纠正。
  Future<String> callTool(String name, Map<String, dynamic> args) async {
    final resp = await _request(
        'tools/call', {'name': name, 'arguments': args}, callTimeout);
    final result = _asStringMap(resp['result']) ?? const {};
    final parts = <String>[];
    for (final item in (result['content'] as List? ?? const [])) {
      final block = _asStringMap(item);
      if (block == null) continue;
      switch (block['type']) {
        case 'text':
          parts.add(block['text']?.toString() ?? '');
        case 'image':
        case 'resource':
          parts.add('[image]');
        default:
          parts.add('[${block['type'] ?? 'unknown'}]');
      }
    }
    final text = parts.join('\n');
    if (result['isError'] == true) {
      return text.isEmpty ? 'MCP 工具错误: （无内容）' : 'MCP 工具错误: $text';
    }
    return text;
  }

  /// 关闭连接：断消息流订阅、把在途请求全部判失败、关传输。可重复调用。
  Future<void> close() async {
    _connected = false;
    await _sub?.cancel();
    _sub = null;
    _failPending('MCP 客户端已关闭（${cfg.id}）');
    await transport.close();
  }

  /// 发一条 JSON-RPC 请求并等待按 id 匹配的响应；返回完整响应
  /// （含 result/error，由调用方判错）。超时/断连抛 [McpException]。
  Future<Map<String, dynamic>> _request(
    String method,
    Map<String, dynamic> params,
    Duration timeout,
  ) async {
    final id = _nextId++;
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;
    try {
      transport.send({
        'jsonrpc': '2.0',
        'id': id,
        'method': method,
        'params': params,
      });
    } catch (e) {
      _pending.remove(id);
      rethrow;
    }
    final resp = await completer.future.timeout(timeout, onTimeout: () {
      _pending.remove(id);
      throw McpException('MCP 请求 $method 超时（${timeout.inSeconds}s）');
    });
    final error = _asStringMap(resp['error']);
    if (error != null) {
      final message = error['message']?.toString() ?? '未知错误';
      final code = error['code'];
      throw McpException(code == null ? message : 'MCP 错误 $code: $message');
    }
    return resp;
  }

  /// 收到消息：只处理带 id 的响应；通知与服务端请求（带 method）忽略。
  void _onMessage(Map<String, dynamic> msg) {
    final rawId = msg['id'];
    final id = rawId is int ? rawId : int.tryParse(rawId?.toString() ?? '');
    if (id == null || msg.containsKey('method')) return;
    _pending.remove(id)?.complete(msg);
  }

  /// 传输关闭（子进程退出 / SSE 断流）：挂起请求立即失败而不是干等超时。
  void _onTransportDone() {
    _connected = false;
    _failPending('MCP 传输已断开（${cfg.id}）');
  }

  void _failPending(String reason) {
    final pending = Map.of(_pending);
    _pending.clear();
    for (final completer in pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(McpException(reason));
      }
    }
  }
}
