// AI 三协议客户端集成测试：本地 mock SSE 服务模拟
// OpenAI Compatible / OpenAI Responses / Anthropic 三种协议，
// 验证流式解析与工具调用循环。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:student_age_editor/features/ai/ai_client.dart';
import 'package:student_age_editor/features/settings/settings_page.dart';

/// 简易 mock：按协议返回 SSE 流。
/// 行为：收到请求后先流式输出文本，然后返回一次工具调用（read_file），
/// 工具结果回传后输出最终文本。
class MockSseServer {
  late HttpServer server;
  int port = 0;
  final requests = <Map<String, dynamic>>[];

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    port = server.port;
    server.listen((req) async {
      try {
        await _handle(req);
      } catch (e, st) {
        // ignore: avoid_print
        print('MOCK ERROR: $e\n$st');
        try {
          req.response.statusCode = 500;
          req.response.write('mock error: $e');
          await req.response.close();
        } catch (_) {}
      }
    });
  }

  Future<void> _handle(HttpRequest req) async {
    // ignore: avoid_print
    print('MOCK got ${req.method} ${req.uri.path}');
    final body = jsonDecode(await utf8.decoder.bind(req).join());
    requests.add({
      'path': req.uri.path,
      'body': body,
    });
      final path = req.uri.path;
      req.response.headers.contentType = ContentType('text', 'event-stream', charset: 'utf-8');
      req.response.headers.set('Cache-Control', 'no-cache');
      final buf = StringBuffer();
      if (path.endsWith('/chat/completions')) {
        final messages = (body['messages'] as List).cast<Map<String, dynamic>>();
        final hasToolResult = messages.any((m) => m['role'] == 'tool');
        if (!hasToolResult) {
          buf
            ..writeln(_sse({'id': '1', 'choices': [
                {'delta': {'role': 'assistant', 'content': '我先读取文件。'}, 'finish_reason': null}
              ]}))
            ..writeln(_sse({'id': '1', 'choices': [
                {'delta': {'tool_calls': [
                    {'index': 0, 'id': 'call_1', 'type': 'function',
                     'function': {'name': 'read_file', 'arguments': '{"path": "a.json"'}}
                  ]}, 'finish_reason': null}
              ]}))
            ..writeln(_sse({'id': '1', 'choices': [
                {'delta': {'tool_calls': [
                    {'index': 0, 'id': 'call_1', 'type': 'function',
                     'function': {'arguments': '}'}}
                  ]}, 'finish_reason': 'tool_calls'}
              ]}));
        } else {
          buf
            ..writeln(_sse({'id': '2', 'choices': [
                {'delta': {'role': 'assistant', 'content': '文件内容是 hello。'}, 'finish_reason': null}
              ]}))
            ..writeln(_sse({'id': '2', 'choices': [
                {'delta': {}, 'finish_reason': 'stop'}
              ]}));
        }
      } else if (path.endsWith('/responses')) {
        final input = (body['input'] as List).cast<Map<String, dynamic>>();
        final hasToolResult =
            input.any((m) => m['type'] == 'function_call_output');
        if (!hasToolResult) {
          buf
            ..writeln(_sse({'type': 'response.output_text.delta', 'delta': '正在处理…'}))
            ..writeln(_sse({'type': 'response.output_item.added', 'item': {
                'type': 'function_call', 'id': 'fc_1', 'name': 'read_file',
                'arguments': '{"path": "b.json"}'
              }}))
            ..writeln(_sse({'type': 'response.output_item.done'}));
        } else {
          buf
            ..writeln(_sse({'type': 'response.output_text.delta', 'delta': '完成，内容是 world。'}))
            ..writeln(_sse({'type': 'response.completed'}));
        }
      } else if (path.endsWith('/messages')) {
        final messages = (body['messages'] as List).cast<Map<String, dynamic>>();
        final hasToolResult = messages.any((m) =>
            m['content'] is List &&
            (m['content'] as List).any((b) =>
                b is Map && b['type'] == 'tool_result'));
        if (!hasToolResult) {
          buf
            ..writeln(_sse({'type': 'content_block_start', 'index': 0,
                'content_block': {'type': 'text', 'text': ''}}))
            ..writeln(_sse({'type': 'content_block_delta', 'index': 0,
                'delta': {'type': 'text_delta', 'text': '我看看文件。'}}))
            ..writeln(_sse({'type': 'content_block_stop', 'index': 0}))
            ..writeln(_sse({'type': 'content_block_start', 'index': 1,
                'content_block': {'type': 'tool_use', 'id': 'toolu_1', 'name': 'read_file', 'input': {}}}))
            ..writeln(_sse({'type': 'content_block_delta', 'index': 1,
                'delta': {'type': 'input_json_delta', 'partial_json': '{"path": "c.json"'}}))
            ..writeln(_sse({'type': 'content_block_delta', 'index': 1,
                'delta': {'type': 'input_json_delta', 'partial_json': '}'}}))
            ..writeln(_sse({'type': 'content_block_stop', 'index': 1}))
            ..writeln(_sse({'type': 'message_delta', 'delta': {'stop_reason': 'tool_use'}}));
        } else {
          buf
            ..writeln(_sse({'type': 'content_block_start', 'index': 0,
                'content_block': {'type': 'text', 'text': ''}}))
            ..writeln(_sse({'type': 'content_block_delta', 'index': 0,
                'delta': {'type': 'text_delta', 'text': '内容是 你好。'}}))
            ..writeln(_sse({'type': 'content_block_stop', 'index': 0}))
            ..writeln(_sse({'type': 'message_delta', 'delta': {'stop_reason': 'end_turn'}}));
        }
      } else {
        req.response.statusCode = 404;
        buf.write('not found');
      }
      req.response.write(buf.toString());
      await req.response.close();
  }

  String _sse(Map<String, dynamic> json) => 'data: ${jsonEncode(json)}\n\n';

  Future<void> stop() async => server.close(force: true);
}

void main() {
  late MockSseServer mock;

  setUp(() async {
    mock = MockSseServer();
    await mock.start();
  });

  tearDown(() => mock.stop());

  Future<(String, int, int)> runRound(AiSettings settings) async {
    final client = AiClient(settings);
    final text = StringBuffer();
    var toolCalls = 0;
    var done = 0;
    await client.send(
      history: [
        <String, dynamic>{'role': 'user', 'content': '请读取文件并总结'},
      ],
      tools: const [
        AiToolDef(name: 'read_file', description: '读文件', parameters: {
          'type': 'object',
          'required': ['path'],
          'properties': {
            'path': {'type': 'string'},
            'encoding': {'type': 'string', 'description': '编码，默认 utf-8'},
          },
        }),
      ],
      callbacks: AiCallbacks(
        onText: (d) => text.write(d),
        onToolCall: (call) async {
          toolCalls++;
          expect(call.name, 'read_file');
          expect(call.arguments['path'], isNotNull);
          return 'mock 文件内容';
        },
        onDone: () => done++,
      ),
    );
    return (text.toString(), toolCalls, done);
  }

  test('OpenAI Compatible 流式 + 工具循环', () async {
    final (text, calls, done) = await runRound(AiSettings(
      provider: 'openai_compatible',
      baseUrl: 'http://127.0.0.1:${mock.port}',
      apiKey: 'test-key',
      model: 'mock-model',
    ));
    expect(calls, 1, reason: '应执行一次工具调用');
    expect(done, 1);
    expect(text, contains('文件内容是 hello'));
    expect(text, contains('我先读取文件'));
    expect(mock.requests.length, 2, reason: '应有两次请求（工具循环）');
    expect(mock.requests.first['body']['tools'], isNotNull);
    // 系统提示必须明确告知模型「能直接修改 mod 且必须用工具」，防止模型回答「无法修改」
    final sysMsg = ((mock.requests.first['body']['messages'] as List)
            .firstWhere((m) => (m as Map<String, dynamic>)['role'] == 'system')
        as Map<String, dynamic>)['content'] as String;
    expect(sysMsg, contains('修改模组必须通过工具完成'));
    expect(sysMsg, contains('list_domains'));
    expect(sysMsg, contains('update_domain_item'));
    // 系统提示应包含「工具参数速查」：逐条列出每个工具允许携带的参数
    expect(sysMsg, contains('工具参数速查'));
    expect(sysMsg, contains('- read_file：path（string'));
    expect(sysMsg, contains('必填'));
    expect(sysMsg, contains('可空'));
    // 内容条目规则：说话人/发送者角色必填，roleName 只是可选显示名
    expect(sysMsg, contains('roleIds（说话人群组）'));
    expect(sysMsg, contains('PhoneMsgCfg 的 role（发送者）'));
    expect(sysMsg, contains('KZoneContentCfg 的 role（发布者）'));
    expect(sysMsg, contains('roleName（自定义名字）只是覆盖显示名的可选字段'));
    // 扩写的操作细节：TalkCfg.roles 是舞台编码不能手改；修改纪律防编造
    expect(sysMsg, contains('由 set_talk_stage 维护'));
    expect(sysMsg, contains('不要编造 id 或字段'));
    // 跨类联动：缺角色新建而非复用，引用存 ID
    expect(sysMsg, contains('【跨类联动】'));
    expect(sysMsg, contains('缺角色就新建，不要复用'));
    expect(sysMsg, contains('跨表引用存的都是 ID 不是名字'));
    // 剧情链路与社交挂接的具体引用字段
    expect(sysMsg, contains('nextEvtId 跳转到下一个事件'));
    expect(sysMsg, contains('parent 指向所属动态'));
  });

  test('OpenAI Responses API 流式 + 工具循环', () async {
    final (text, calls, done) = await runRound(AiSettings(
      provider: 'openai_responses',
      baseUrl: 'http://127.0.0.1:${mock.port}',
      apiKey: 'test-key',
      model: 'mock-model',
    ));
    expect(calls, 1);
    expect(done, 1);
    expect(text, contains('完成，内容是 world'));
    expect(mock.requests.first['body']['input'], isNotNull);
  });

  test('Anthropic 流式 + 工具循环', () async {
    final (text, calls, done) = await runRound(AiSettings(
      provider: 'anthropic',
      baseUrl: 'http://127.0.0.1:${mock.port}',
      apiKey: 'test-key',
      model: 'mock-model',
    ));
    expect(calls, 1);
    expect(done, 1);
    expect(text, contains('内容是 你好'));
    expect(mock.requests.first['body']['tools'], isNotNull);
  });

  test('工具轮次消息追加到传入 history（跨轮次上下文保留）', () async {
    final settings = AiSettings(
      provider: 'openai_compatible',
      baseUrl: 'http://127.0.0.1:${mock.port}',
      apiKey: 'test-key',
      model: 'mock-model',
    );
    final client = AiClient(settings);
    final history = <Map<String, dynamic>>[
      {'role': 'user', 'content': '请读取文件并总结'},
    ];
    const tools = [
      AiToolDef(name: 'read_file', description: '读文件', parameters: {
        'type': 'object',
        'properties': {'path': {'type': 'string'}},
      }),
    ];
    await client.send(
      history: history,
      tools: tools,
      callbacks: AiCallbacks(
        onToolCall: (call) async => 'mock 文件内容',
        onDone: () {},
      ),
    );
    // 工具轮次后，传入的 history 应包含 assistant(tool_calls) 与 tool 消息，
    // 以及最终的 assistant 文本回复（对话连贯性）。
    expect(history.length, 4,
        reason: 'user + assistant(tool_calls) + tool + assistant(最终文本)');
    expect(history[1]['role'], 'assistant');
    expect(
      ((history[1]['tool_calls'] as List).single
          as Map<String, dynamic>)['function']['name'],
      'read_file',
    );
    expect(history[2]['role'], 'tool');
    expect(history[2]['content'], 'mock 文件内容');
    expect(history[3]['role'], 'assistant');
    expect(history[3]['content'], contains('文件内容是 hello'));

    // 第二轮 send 沿用同一 history：因历史已含工具结果，mock 不再触发工具调用，
    // 直接输出最终文本（1 次请求）——证明上下文保留生效。
    history.add({'role': 'user', 'content': '继续'});
    await client.send(
      history: history,
      tools: tools,
      callbacks: AiCallbacks(
        onToolCall: (call) async => 'again',
        onDone: () {},
      ),
    );
    expect(mock.requests.length, 3,
        reason: '第一轮 2 次请求 + 第二轮 1 次请求（历史已含工具结果，不再调用工具）');
    final secondRoundFirst = (mock.requests[2]['body']
        as Map<String, dynamic>)['messages'] as List;
    expect(secondRoundFirst.length, greaterThan(3),
        reason: '第二轮请求应携带第一轮产生的 assistant/tool 消息');
    expect(
      secondRoundFirst.any((m) =>
          (m as Map<String, dynamic>)['role'] == 'tool' &&
          m['content'] == 'mock 文件内容'),
      isTrue,
      reason: '第一轮工具结果应出现在第二轮请求中',
    );
    expect(history.length, 6,
        reason: '第二轮结束后 history = user×2 + assistant(tool_calls) + tool + assistant×2');
  });

  // ---------- 多模态：user 消息图片块（content 为 List）----------
  const multimodalUserMsg = <String, dynamic>{
    'role': 'user',
    'content': [
      {'type': 'text', 'text': '看图说话'},
      {
        'type': 'image_url',
        'image_url': {'url': 'data:image/png;base64,QUJD'},
      },
    ],
  };

  test('多模态 OpenAI：image_url 块原样发送', () async {
    final settings = AiSettings(
      provider: 'openai_compatible',
      baseUrl: 'http://127.0.0.1:${mock.port}',
      apiKey: 'test-key',
      model: 'mock-model',
    );
    await AiClient(settings).send(
      history: [multimodalUserMsg],
      tools: const [],
      callbacks: AiCallbacks(onToolCall: (c) async => 'x', onDone: () {}),
    );
    final messages =
        (mock.requests.first['body'] as Map<String, dynamic>)['messages'] as List;
    final userMsg = messages
        .firstWhere((m) => (m as Map<String, dynamic>)['role'] == 'user')
        as Map<String, dynamic>;
    final content = userMsg['content'] as List;
    final img = content.firstWhere(
        (b) => (b as Map<String, dynamic>)['type'] == 'image_url')
        as Map<String, dynamic>;
    expect((img['image_url'] as Map)['url'], 'data:image/png;base64,QUJD');
  });

  test('多模态 Responses：image_url 转 input_image', () async {
    final settings = AiSettings(
      provider: 'openai_responses',
      baseUrl: 'http://127.0.0.1:${mock.port}',
      apiKey: 'test-key',
      model: 'mock-model',
    );
    await AiClient(settings).send(
      history: [multimodalUserMsg],
      tools: const [],
      callbacks: AiCallbacks(onToolCall: (c) async => 'x', onDone: () {}),
    );
    final input =
        (mock.requests.first['body'] as Map<String, dynamic>)['input'] as List;
    final img = input.firstWhere(
        (m) => (m as Map<String, dynamic>)['type'] == 'input_image')
        as Map<String, dynamic>;
    expect(img['image_url'], 'data:image/png;base64,QUJD');
    // 文本块也应转换为 input_text
    expect(
      input.any((m) =>
          (m as Map<String, dynamic>)['type'] == 'input_text' &&
          m['text'] == '看图说话'),
      isTrue,
    );
  });

  test('多模态 Anthropic：image_url 转 image source', () async {
    final settings = AiSettings(
      provider: 'anthropic',
      baseUrl: 'http://127.0.0.1:${mock.port}',
      apiKey: 'test-key',
      model: 'mock-model',
    );
    await AiClient(settings).send(
      history: [multimodalUserMsg],
      tools: const [],
      callbacks: AiCallbacks(onToolCall: (c) async => 'x', onDone: () {}),
    );
    final messages =
        (mock.requests.first['body'] as Map<String, dynamic>)['messages'] as List;
    final userMsg = messages
        .firstWhere((m) => (m as Map<String, dynamic>)['role'] == 'user')
        as Map<String, dynamic>;
    final content = userMsg['content'] as List;
    final img = content.firstWhere(
        (b) => (b as Map<String, dynamic>)['type'] == 'image')
        as Map<String, dynamic>;
    final source = img['source'] as Map;
    expect(source['type'], 'base64');
    expect(source['media_type'], 'image/png');
    expect(source['data'], 'QUJD');
    // 纯文本块原样保留
    expect(
      content.any((b) =>
          (b as Map<String, dynamic>)['type'] == 'text' &&
          b['text'] == '看图说话'),
      isTrue,
    );
  });
}
