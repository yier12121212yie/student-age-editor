// MCP 配置接线测试：AiSettings 序列化往返（customInstructions + mcpServers）、
// 非法 mcpServers 条目容错，以及 AiChatController.parseMcpToolName
// 对 mcp__<serverId>__<tool> 工具名的解析（含 id 带下划线的歧义处理）。
import 'dart:convert';

import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_age_editor/features/ai/ai_chat_controller.dart';
import 'package:student_age_editor/features/ai/mcp/mcp_types.dart';
import 'package:student_age_editor/features/settings/mcp_token_section.dart';
import 'package:student_age_editor/features/settings/settings_page.dart';

void main() {
  test('AiSettings 序列化往返（customInstructions + mcpServers + headers）', () {
    final s = AiSettings(
      baseUrl: 'https://x/v1',
      apiKey: 'k',
      customInstructions: '文案保持口语化，不要堆砌数字',
      mcpServers: [
        McpServerConfig(
          id: 'fs',
          name: '文件系统',
          transport: 'stdio',
          command: 'npx.cmd',
          args: const ['-y', '@modelcontextprotocol/server-filesystem', r'D:\my data'],
        ),
        McpServerConfig(
          id: 'remote',
          transport: 'http',
          url: 'https://example.com/mcp',
          headers: const {'Authorization': 'Bearer tok_123', 'X-Tenant': 'alice'},
          enabled: false,
        ),
      ],
    );
    final restored = AiSettings.fromJson(s.toJson());
    expect(restored.baseUrl, 'https://x/v1');
    expect(restored.customInstructions, '文案保持口语化，不要堆砌数字');
    expect(restored.mcpServers.length, 2);
    final fs = restored.mcpServers[0];
    expect(fs.id, 'fs');
    expect(fs.name, '文件系统');
    expect(fs.transport, 'stdio');
    expect(fs.command, 'npx.cmd');
    expect(fs.args, ['-y', '@modelcontextprotocol/server-filesystem', r'D:\my data']);
    expect(fs.headers, isEmpty);
    expect(fs.enabled, isTrue);
    final remote = restored.mcpServers[1];
    expect(remote.id, 'remote');
    expect(remote.transport, 'http');
    expect(remote.url, 'https://example.com/mcp');
    expect(remote.headers, {'Authorization': 'Bearer tok_123', 'X-Tenant': 'alice'});
    expect(remote.enabled, isFalse);
  });

  test('McpServerConfig.parseHeadersInput 支持裸 token、Bearer 前缀与多行键值', () {
    expect(
      McpServerConfig.parseHeadersInput('my_secret_token'),
      {'Authorization': 'Bearer my_secret_token'},
    );
    expect(
      McpServerConfig.parseHeadersInput('Bearer abc_123'),
      {'Authorization': 'Bearer abc_123'},
    );
    expect(
      McpServerConfig.parseHeadersInput(
        'Authorization: Bearer tok_xyz\nX-Backend-Token: btok_999',
      ),
      {
        'Authorization': 'Bearer tok_xyz',
        'X-Backend-Token': 'btok_999',
      },
    );
  });

  test('McpConfigGenerator 生成端点与各客户端鉴权配置', () {
    expect(
      McpConfigGenerator.buildEndpointUrl('https://editor.example.com/'),
      'https://editor.example.com/api/mcp',
    );
    expect(
      McpConfigGenerator.buildEndpointUrl(
        'https://editor.example.com',
        readonly: true,
      ),
      'https://editor.example.com/api/mcp?readonly=1',
    );

    final claudeJson = jsonDecode(
      McpConfigGenerator.buildClientSnippet(
        clientType: McpAgentClientType.claudeCode,
        baseUrl: 'https://editor.example.com',
        token: 'sa_mcp_abcdef123456',
      ),
    ) as Map<String, dynamic>;
    final srv =
        (claudeJson['mcpServers'] as Map)['student-age-editor'] as Map;
    expect(srv['url'], 'https://editor.example.com/api/mcp');
    expect(
      (srv['headers'] as Map)['Authorization'],
      'Bearer sa_mcp_abcdef123456',
    );

    final curlCmd = McpConfigGenerator.buildClientSnippet(
      clientType: McpAgentClientType.curl,
      baseUrl: 'http://127.0.0.1:8765',
      token: 'tok_test',
      readonly: true,
    );
    expect(curlCmd, contains('http://127.0.0.1:8765/api/mcp?readonly=1'));
    expect(curlCmd, contains('Authorization: Bearer tok_test'));
  });

  test('McpAccessTokenEntry.maskToken 掩码规则', () {
    expect(McpAccessTokenEntry.maskToken(''), '');
    expect(McpAccessTokenEntry.maskToken('short'), '***MASKED***');
    expect(
      McpAccessTokenEntry.maskToken('sa_mcp_1234567890abcdef'),
      'sa_mcp***cdef',
    );
  });

  testWidgets('McpTokenSection 渲染生成令牌卡片并完成生成与吊销交互', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      fluent.FluentApp(
        home: fluent.NavigationView(
          content: fluent.ScaffoldPage(
            content: const SingleChildScrollView(
              child: McpTokenSection(),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('HTTP MCP 服务端（供外部 Agent 接入）'), findsOneWidget);
    expect(find.text('生成令牌（鉴权请求头凭据）'), findsOneWidget);
    expect(find.text('生成令牌'), findsOneWidget);

    // 点击「生成令牌」按钮
    await tester.tap(find.text('生成令牌'));
    await tester.pumpAndSettle();

    // 验证新生成令牌提示框与列表展示
    expect(find.textContaining('已生成（请立即复制保存'), findsOneWidget);
    expect(find.text('复制令牌'), findsOneWidget);
    expect(find.text('复制鉴权请求头'), findsOneWidget);
    expect(find.text('已生成令牌（1）'), findsOneWidget);
    expect(find.text('吊销'), findsOneWidget);

    // 点击「吊销」按钮移除该令牌条目
    await tester.ensureVisible(find.text('吊销'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('吊销'));
    await tester.pumpAndSettle();
    expect(find.text('已生成令牌（1）'), findsNothing);

    // 清空 InfoBar 的 3 秒自动关闭定时器
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
  });

  test('旧设置 JSON 缺新字段时取默认值', () {
    final s = AiSettings.fromJson({
      'provider': 'openai_compatible',
      'apiKey': 'k',
    });
    expect(s.customInstructions, '');
    expect(s.mcpServers, isEmpty);
  });

  test('非法 mcpServers 条目容错：坏项跳过，好项保留', () {
    final s = AiSettings.fromJson({
      'mcpServers': [
        42, // 非 Map
        'oops',
        null,
        {
          'id': 'good',
          'transport': 'http',
          'url': 'https://a/mcp',
        },
        {
          'id': 'bad',
          'args': 'not-a-list',
        }, // fromJson 内部强转抛错
        'tail',
      ],
    });
    expect(s.mcpServers.length, 1);
    expect(s.mcpServers[0].id, 'good');
    // id 为 'bad' 的条目 args 非法：McpServerConfig.fromJson 抛错被吞掉
    expect(s.mcpServers.any((e) => e.id == 'bad'), isFalse);
    expect(s.toJson()['mcpServers'], isA<List>());
  });

  test('mcpServers 非列表整值容错', () {
    final s = AiSettings.fromJson({'mcpServers': 'not-a-list'});
    expect(s.mcpServers, isEmpty);
  });

  test('parseMcpToolName：优先按已登记服务器 id 匹配（取最长）', () {
    final known = ['fs', 'a__b'];
    final p = AiChatController.parseMcpToolName('mcp__a__b__search', known);
    expect(p, isNotNull);
    expect(p!.serverId, 'a__b');
    expect(p.toolName, 'search');
    // 服务器名含下划线也能正确切分
    final q = AiChatController.parseMcpToolName('mcp__my_srv__get-file', ['my_srv']);
    expect(q!.serverId, 'my_srv');
    expect(q.toolName, 'get-file');
  });

  test('parseMcpToolName：id 未登记时退回第一个 __ 分段', () {
    // 服务器已被摘除（断开/删除）：按第一个 '__' 尽力解析，供路由给出明确报错
    final q = AiChatController.parseMcpToolName('mcp__a__b__search', ['fs']);
    expect(q!.serverId, 'a');
    expect(q.toolName, 'b__search');
    final p = AiChatController.parseMcpToolName('mcp__srv__tool.name', const []);
    expect(p!.serverId, 'srv');
    expect(p.toolName, 'tool.name');
  });

  test('parseMcpToolName：非 mcp__ 前缀与畸形名返回 null', () {
    expect(AiChatController.parseMcpToolName('read_file', const []), isNull);
    expect(AiChatController.parseMcpToolName('mcp____tool', const []), isNull); // id 为空
    expect(AiChatController.parseMcpToolName('mcp__srv__', const []), isNull); // 工具名为空
    expect(AiChatController.parseMcpToolName('mcp__', const []), isNull);
    // 已登记 id 精确命中但工具名为空 → 也判非法
    expect(AiChatController.parseMcpToolName('mcp__fs__', ['fs']), isNull);
  });
}
