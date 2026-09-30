// MCP 客户端核心单元测试：用内存 FakeTransport 按脚本应答
// initialize / tools/list / tools/call，不拉起真实进程、不发真实网络请求。
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:student_age_editor/features/ai/mcp/mcp_client.dart';
import 'package:student_age_editor/features/ai/mcp/mcp_stdio_transport.dart';
import 'package:student_age_editor/features/ai/mcp/mcp_types.dart';

/// 假传输：send 时把消息交给 responder 脚本，脚本返回的
/// `{result|error}` 片段自动补上 jsonrpc/id 后异步回灌 incoming。
class FakeTransport implements McpTransport {
  FakeTransport(this.responder);

  /// 请求 → 响应片段（返回 null 表示故意不响应，用于测超时）。
  final Map<String, dynamic>? Function(Map<String, dynamic> request) responder;

  /// 已发出的全部消息（含通知），按序断言用。
  final sent = <Map<String, dynamic>>[];
  bool started = false;
  bool closed = false;

  final StreamController<Map<String, dynamic>> _incoming =
      StreamController.broadcast();

  /// 注入一条服务器方向的原始消息（通知 / 乱序响应等）。
  void emit(Map<String, dynamic> msg) => _incoming.add(msg);

  @override
  Future<void> start() async {
    started = true;
  }

  @override
  void send(Map<String, dynamic> msg) {
    sent.add(msg);
    final id = msg['id'];
    if (id == null) return; // 通知无需应答
    final response = responder(msg);
    if (response == null) return;
    // broadcast 流默认异步派发，等价于真实传输的回包时序。
    _incoming.add({
      'jsonrpc': '2.0',
      'id': id,
      ...response,
    });
  }

  @override
  Stream<Map<String, dynamic>> get incoming => _incoming.stream;

  @override
  Future<void> close() async {
    closed = true;
    await _incoming.close();
  }
}

/// 默认脚本：完整应答 tools 能力域的三个请求。
Map<String, dynamic>? defaultResponder(Map<String, dynamic> msg) {
  switch (msg['method']) {
    case 'initialize':
      return {
        'result': {
          'protocolVersion': McpClient.protocolVersion,
          'capabilities': {'tools': {}},
          'serverInfo': {'name': 'fake-server', 'version': '0.0.1'},
        },
      };
    case 'tools/list':
      return {
        'result': {
          'tools': [
            {
              'name': 'echo',
              'description': '回显文本',
              'inputSchema': {
                'type': 'object',
                'properties': {
                  'text': {'type': 'string'},
                },
              },
            },
          ],
        },
      };
    case 'tools/call':
      final text =
          ((msg['params'] as Map?)?['arguments'] as Map?)?['text'] ?? '';
      return {
        'result': {
          'content': [
            {'type': 'text', 'text': 'echo: $text'},
          ],
        },
      };
  }
  return null;
}

McpServerConfig testConfig({String id = 'srv'}) => McpServerConfig(
      id: id,
      name: '测试服务器',
      transport: 'stdio',
      command: 'fake',
    );

void main() {
  group('McpServerConfig', () {
    test('id 构造时清洗为字母数字下划线', () {
      expect(McpServerConfig(id: 'test server!').id, 'test_server_');
      expect(McpServerConfig(id: '  ').id, 'mcp_server');
      expect(McpServerConfig(id: 'fs-01').id, 'fs_01');
      expect(McpServerConfig(id: 'ok_id9').id, 'ok_id9');
    });

    test('name 为空时回填清洗后的 id', () {
      expect(McpServerConfig(id: 'my srv').name, 'my_srv');
      expect(McpServerConfig(id: 'a', name: ' 显示名 ').name, '显示名');
    });

    test('fromJson/toJson 往返一致', () {
      final cfg = McpServerConfig.fromJson({
        'id': 'fs',
        'name': '文件',
        'transport': 'http',
        'command': '',
        'args': ['a', 'b'],
        'url': 'http://127.0.0.1:3000/mcp',
        'enabled': false,
      });
      expect(cfg.transport, 'http');
      expect(cfg.args, ['a', 'b']);
      expect(cfg.enabled, false);
      final back = McpServerConfig.fromJson(cfg.toJson());
      expect(back.toJson(), cfg.toJson());
    });

    test('fromJson 缺字段走默认值', () {
      final cfg = McpServerConfig.fromJson({'id': 'x'});
      expect(cfg.transport, 'stdio');
      expect(cfg.enabled, true);
      expect(cfg.args, isEmpty);
    });
  });

  group('McpClient 握手', () {
    test('start 成功后 connected，按序发送 initialize/通知/tools/list 并缓存工具',
        () async {
      final fake = FakeTransport(defaultResponder);
      final client = McpClient(testConfig(), fake);
      expect(client.connected, isFalse);

      await client.start();

      expect(fake.started, isTrue);
      expect(client.connected, isTrue);
      final methods =
          fake.sent.map((m) => m['method']).toList(); // 通知无 id
      expect(methods, ['initialize', 'notifications/initialized', 'tools/list']);

      final init = fake.sent.first;
      expect(init['id'], 1); // JSON-RPC id 自增，握手请求占 1
      expect(init['jsonrpc'], '2.0');
      final params = init['params'] as Map<String, dynamic>;
      expect(params['protocolVersion'], '2025-03-26');
      expect(params['capabilities'], isEmpty);
      expect((params['clientInfo'] as Map)['name'], 'StudentAgeEditor');
      // 通知不带 id（JSON-RPC 通知语义）。
      expect(fake.sent[1].containsKey('id'), isFalse);

      // tools/list 结果已缓存，callTool 用的 id 继续自增到 3。
      expect(client.tools.map((t) => t.name), ['echo']);
      final callResp = await client.callTool('echo', {'text': 'hi'});
      expect(callResp, 'echo: hi');
      expect(fake.sent.last['id'], 3);
      await client.close();
    });

    test('initialize 返回 error 时 start 抛 McpException 且不置 connected',
        () async {
      final fake = FakeTransport((msg) {
        if (msg['method'] == 'initialize') {
          return {
            'error': {'code': -32001, 'message': '握手失败'},
          };
        }
        return defaultResponder(msg);
      });
      final client = McpClient(testConfig(), fake);
      await expectLater(
        client.start(),
        throwsA(isA<McpException>()
            .having((e) => e.message, 'message', contains('握手失败'))),
      );
      expect(client.connected, isFalse);
      await client.close();
    });
  });

  group('tools/list 与工具定义转换', () {
    test('解析 name/description/inputSchema 并缓存', () async {
      final client = McpClient(testConfig(), FakeTransport(defaultResponder));
      await client.start();
      final tools = await client.listTools();
      expect(tools, hasLength(1));
      expect(tools.first.name, 'echo');
      expect(tools.first.description, '回显文本');
      expect(tools.first.inputSchema['type'], 'object');
      expect(client.tools, hasLength(1));
      await client.close();
    });

    test('toToolDef 生成 OpenAI function 定义并加命名空间前缀', () async {
      final client = McpClient(testConfig(id: 'fs'), FakeTransport(defaultResponder));
      await client.start();
      final def = client.tools.first.toToolDef('fs');
      expect(def.name, 'mcp__fs__echo');
      expect(def.description, '回显文本');
      expect(def.parameters['type'], 'object');
      await client.close();
    });
  });

  group('tools/call 内容拼接', () {
    test('text 块直接拼接，image/resource 块降级为 [image] 占位', () async {
      final fake = FakeTransport((msg) {
        if (msg['method'] == 'tools/call') {
          return {
            'result': {
              'content': [
                {'type': 'text', 'text': 'A'},
                {'type': 'image', 'mimeType': 'image/png', 'data': '...'},
                {'type': 'resource', 'resource': {'uri': 'file:///x'}},
                {'type': 'audio', 'mimeType': 'audio/wav'},
                {'type': 'text', 'text': 'B'},
              ],
            },
          };
        }
        return defaultResponder(msg);
      });
      final client = McpClient(testConfig(), fake);
      await client.start();
      expect(await client.callTool('echo', {}), 'A\n[image]\n[image]\n[audio]\nB');
      await client.close();
    });

    test('isError 时返回 MCP 工具错误文本而不是抛异常', () async {
      final fake = FakeTransport((msg) {
        if (msg['method'] == 'tools/call') {
          return {
            'result': {
              'isError': true,
              'content': [
                {'type': 'text', 'text': '文件不存在'},
              ],
            },
          };
        }
        return defaultResponder(msg);
      });
      final client = McpClient(testConfig(), fake);
      await client.start();
      final out = await client.callTool('echo', {});
      expect(out, 'MCP 工具错误: 文件不存在');
      await client.close();
    });

    test('error 响应抛 McpException', () async {
      final fake = FakeTransport((msg) {
        if (msg['method'] == 'tools/call') {
          return {
            'error': {'code': -32603, 'message': 'Internal error'},
          };
        }
        return defaultResponder(msg);
      });
      final client = McpClient(testConfig(), fake);
      await client.start();
      await expectLater(
        client.callTool('echo', {}),
        throwsA(isA<McpException>()
            .having((e) => e.message, 'message', contains('Internal error'))),
      );
      await client.close();
    });

    test('带 method 的响应（服务端消息）不参与 id 匹配，不干扰在途请求',
        () async {
      final fake = FakeTransport(defaultResponder);
      final client = McpClient(testConfig(), fake);
      await client.start();
      final future = client.callTool('echo', {'text': 'hi'});
      fake.emit({'jsonrpc': '2.0', 'method': 'notifications/message'});
      fake.emit({'jsonrpc': '2.0', 'method': 'ping', 'id': 999});
      expect(await future, 'echo: hi');
      await client.close();
    });
  });

  group('超时与断连', () {
    test('无响应时 callTool 超时抛 McpException', () async {
      final fake = FakeTransport((msg) {
        if (msg['method'] == 'tools/call') return null; // 故意不回
        return defaultResponder(msg);
      });
      final client = McpClient(
        testConfig(),
        fake,
        callTimeout: const Duration(milliseconds: 50),
      );
      await client.start();
      await expectLater(
        client.callTool('echo', {}),
        throwsA(isA<McpException>()
            .having((e) => e.message, 'message', contains('超时'))),
      );
      await client.close();
    });

    test('close 后在途请求立即失败而不是等满超时', () async {
      final fake = FakeTransport((msg) {
        if (msg['method'] == 'tools/call') return null;
        return defaultResponder(msg);
      });
      final client = McpClient(testConfig(), fake);
      await client.start();
      final future = client.callTool('echo', {});
      // 先订阅再 close：避免错误在无人监听时到达被判为 unhandled。
      final checked = expectLater(
        future,
        throwsA(isA<McpException>()
            .having((e) => e.message, 'message', contains('已关闭'))),
      );
      await pumpEventQueue(); // 让 callTool 进入等待响应状态
      await client.close();
      // 不 await 满 120s 默认超时：close 应让在途请求立刻失败。
      await checked.timeout(const Duration(seconds: 5));
      expect(client.connected, isFalse);
      expect(fake.closed, isTrue);
    });

    test('默认超时：callTool 120s、握手 15s', () {
      final client = McpClient(testConfig(), FakeTransport(defaultResponder));
      expect(client.callTimeout, const Duration(seconds: 120));
      expect(client.requestTimeout, const Duration(seconds: 15));
    });
  });

  group('行分隔 JSON-RPC 解码（stdio 协议层）', () {
    test('忽略不以 { 开头的行与非法 JSON', () {
      // 服务器日志行 / 进度输出：不以 { 开头 → null。
      expect(decodeJsonLine('[info] server listening'), isNull);
      expect(decodeJsonLine(''), isNull);
      expect(decodeJsonLine('{"broken'), isNull);
      expect(decodeJsonLine('{not json}'), isNull);
      // 前导空格不算 JSON 行（协议要求逐行原文匹配）。
      expect(decodeJsonLine(' {"a":1}'), isNull);
      // 数组/标量不是合法 JSON-RPC 消息。
      expect(decodeJsonLine('[1,2]'), isNull);
    });

    test('合法消息行正常解码', () {
      final msg = decodeJsonLine(
        '{"jsonrpc":"2.0","id":1,"result":{"ok":true}}',
      );
      expect(msg, isNotNull);
      expect(msg!['id'], 1);
      expect((msg['result'] as Map)['ok'], isTrue);
    });
  });

  group('传输层参数校验（纯逻辑，不碰真实进程/网络）', () {
    test('StdioTransport 未配置 command 时 start 抛错', () async {
      final transport =
          StdioTransport(McpServerConfig(id: 'bad', command: ''));
      await expectLater(
        transport.start(),
        throwsA(isA<McpException>()
            .having((e) => e.message, 'message', contains('command'))),
      );
    });

    test('HttpTransport 未配置有效 url 时 start 抛错', () async {
      final transport =
          HttpTransport(McpServerConfig(id: 'bad', transport: 'http'));
      await expectLater(
        transport.start(),
        throwsA(isA<McpException>()
            .having((e) => e.message, 'message', contains('url'))),
      );
      await transport.close();
    });

    test('StdioTransport 未启动时 send 抛错', () async {
      final transport =
          StdioTransport(McpServerConfig(id: 'bad', command: 'noop'));
      addTearDown(transport.close);
      expect(() => transport.send({'jsonrpc': '2.0'}),
          throwsA(isA<McpException>()));
    });
  });
}
