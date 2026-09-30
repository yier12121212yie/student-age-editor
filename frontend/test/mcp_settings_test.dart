// MCP 配置接线测试：AiSettings 序列化往返（customInstructions + mcpServers）、
// 非法 mcpServers 条目容错，以及 AiChatController.parseMcpToolName
// 对 mcp__<serverId>__<tool> 工具名的解析（含 id 带下划线的歧义处理）。
import 'package:flutter_test/flutter_test.dart';
import 'package:student_age_editor/features/ai/ai_chat_controller.dart';
import 'package:student_age_editor/features/ai/mcp/mcp_types.dart';
import 'package:student_age_editor/features/settings/settings_page.dart';

void main() {
  test('AiSettings 序列化往返（customInstructions + mcpServers）', () {
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
    expect(fs.enabled, isTrue);
    final remote = restored.mcpServers[1];
    expect(remote.id, 'remote');
    expect(remote.transport, 'http');
    expect(remote.url, 'https://example.com/mcp');
    expect(remote.enabled, isFalse);
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
