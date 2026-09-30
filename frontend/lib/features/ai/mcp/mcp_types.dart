/// MCP（Model Context Protocol）客户端的核心数据类型。
///
/// 本目录（`lib/features/ai/mcp/`）是自包含的 MCP 客户端实现，
/// 不依赖项目其他模块（除 `mcp_client.dart` 借用 `../ai_client.dart`
/// 的 [AiToolDef] 做工具定义转换）；接线层只需 import 本目录即可。
library;

/// 清洗后的 id 允许字符集：字母、数字与下划线。
///
/// id 会作为工具命名空间前缀拼进 OpenAI function 名
/// （`mcp__<id>__<tool>`），必须满足模型提供方对 function name 的
/// 字符集约束（`^[a-zA-Z0-9_]+$`），因此构造 [McpServerConfig] 时
/// 其余字符一律替换为 `_`。
final RegExp _idForbiddenChars = RegExp(r'[^A-Za-z0-9_]');

/// MCP 服务器连接配置（描述「怎么连上一个小工具服务器」）。
///
/// 两种传输（[transport]）：
/// - `stdio`：本地子进程，读 [command] + [args]（如 `npx` +
///   `-y @modelcontextprotocol/server-filesystem ...`）；
/// - `http`：远程 streamable HTTP 端点，读 [url]。
class McpServerConfig {
  /// 构造并清洗 [id]：非 `[A-Za-z0-9_]` 字符替换为 `_`，
  /// 清洗后为空时回退为 `mcp_server`（保证命名空间前缀永远非空）。
  McpServerConfig({
    required String id,
    String name = '',
    this.transport = 'stdio',
    this.command = '',
    this.args = const [],
    this.url = '',
    this.enabled = true,
  })  : id = sanitizeId(id),
        name = name.trim().isEmpty ? sanitizeId(id) : name.trim();

  /// 从 JSON（设置页持久化格式）解析；缺字段全部走默认值。
  factory McpServerConfig.fromJson(Map<String, dynamic> json) {
    return McpServerConfig(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      transport: json['transport']?.toString() ?? 'stdio',
      command: json['command']?.toString() ?? '',
      args: (json['args'] as List? ?? const [])
          .map((e) => e.toString())
          .toList(growable: false),
      url: json['url']?.toString() ?? '',
      enabled: json['enabled'] != false,
    );
  }

  /// 把任意字符串清洗成合法 id（公开给接线层复用，同一份规则单源在此）。
  static String sanitizeId(String raw) {
    final cleaned = raw.trim().replaceAll(_idForbiddenChars, '_');
    return cleaned.isEmpty ? 'mcp_server' : cleaned;
  }

  /// 服务器唯一标识，用作工具命名空间前缀（`mcp__<id>__<tool>`）。
  /// 构造时已清洗为仅含字母数字下划线。
  final String id;

  /// 展示名（UI 列表用）；为空时构造器回填为清洗后的 [id]。
  final String name;

  /// 传输类型：`'stdio'` 或 `'http'`。
  final String transport;

  /// stdio 传输的可执行文件路径/命令名。
  final String command;

  /// stdio 传输的命令行参数。
  final List<String> args;

  /// http 传输的端点 URL。
  final String url;

  /// 是否启用；接线层应跳过 disabled 的配置。
  final bool enabled;

  /// 序列化为 JSON（与 [McpServerConfig.fromJson] 往返一致）。
  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'transport': transport,
        'command': command,
        'args': args,
        'url': url,
        'enabled': enabled,
      };
}
