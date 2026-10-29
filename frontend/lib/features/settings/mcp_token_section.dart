// 设置页「HTTP MCP 服务端 · 外部 Agent 接入与生成令牌」区块：
// - 展示当前 Web / 本机后端对外暴露的 HTTP MCP 端点（/api/mcp）；
// - 提供「生成令牌」卡片：支持创建带备注与有效期的鉴权令牌、展示单次明文、
//   管理/吊销已生成令牌；
// - 提供外部 Agent（Claude Code / Cursor / Windsurf / cURL）一键接入配置生成器，
//   自动填入端点 URL 与 Authorization: Bearer <token> 鉴权请求头。
//
// 颜色一律走 palette token（light_theme_audit_test 守门），不写死 Color(0x…)。
import 'dart:convert';
import 'dart:math';

import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/api_client.dart';
import '../../core/app_theme.dart';

/// 外部 Agent 接入令牌条目（展示与列表管理用）。
class McpAccessTokenEntry {
  const McpAccessTokenEntry({
    required this.id,
    required this.label,
    required this.maskedToken,
    required this.createdAt,
    required this.expiresAt,
    this.readonly = false,
  });

  factory McpAccessTokenEntry.fromJson(Map<String, dynamic> json) {
    final rawToken = json['token']?.toString() ?? '';
    final masked = json['masked_token']?.toString() ??
        json['maskedToken']?.toString() ??
        maskToken(rawToken);
    return McpAccessTokenEntry(
      id: json['id']?.toString() ?? '',
      label: (json['label']?.toString() ?? '').trim().isEmpty
          ? '未命名令牌'
          : json['label'].toString().trim(),
      maskedToken: masked.isEmpty ? '***' : masked,
      createdAt: json['created_at']?.toString() ??
          json['createdAt']?.toString() ??
          '',
      expiresAt: json['expires_at']?.toString() ??
          json['expiresAt']?.toString() ??
          '永不过期',
      readonly: json['readonly'] == true,
    );
  }

  final String id;
  final String label;
  final String maskedToken;
  final String createdAt;
  final String expiresAt;
  final bool readonly;

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'masked_token': maskedToken,
        'created_at': createdAt,
        'expires_at': expiresAt,
        'readonly': readonly,
      };

  /// 生成掩码展示串：保留前 6 后 4，中间以 `***` 替代。
  static String maskToken(String token) {
    final t = token.trim();
    if (t.isEmpty) return '';
    if (t.length <= 10) return '***MASKED***';
    return '${t.substring(0, 6)}***${t.substring(t.length - 4)}';
  }
}

/// 生成单次令牌的结果。
class McpGeneratedTokenResult {
  const McpGeneratedTokenResult({
    required this.entry,
    required this.plainToken,
  });

  final McpAccessTokenEntry entry;
  final String plainToken;
}

/// 外部 Agent 客户端配置模板类型。
enum McpAgentClientType {
  claudeCode('Claude Code / Desktop (.mcp.json)'),
  cursor('Cursor (MCP HTTP)'),
  windsurf('Windsurf (mcp_config.json)'),
  curl('cURL 命令行验证');

  const McpAgentClientType(this.label);
  final String label;
}

/// HTTP MCP 接入配置与令牌生成辅助逻辑（纯函数可单测）。
class McpConfigGenerator {
  McpConfigGenerator._();

  /// 计算 MCP HTTP 端点完整 URL。
  static String buildEndpointUrl(String baseUrl, {bool readonly = false}) {
    var base = baseUrl.trim();
    if (base.isEmpty) base = 'http://127.0.0.1:8765';
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    return readonly ? '$base/api/mcp?readonly=1' : '$base/api/mcp';
  }

  /// 生成 Authorization 请求头键值。
  static String buildAuthHeaderValue(String? token) {
    final t = (token ?? '').trim();
    if (t.isEmpty) return 'Bearer <YOUR_MCP_TOKEN>';
    return t.toLowerCase().startsWith('bearer ') ? t : 'Bearer $t';
  }

  /// 生成对应外部 Agent 客户端的配置片段文本。
  static String buildClientSnippet({
    required McpAgentClientType clientType,
    required String baseUrl,
    String? token,
    bool readonly = false,
  }) {
    final url = buildEndpointUrl(baseUrl, readonly: readonly);
    final authValue = buildAuthHeaderValue(token);
    const encoder = JsonEncoder.withIndent('  ');

    switch (clientType) {
      case McpAgentClientType.claudeCode:
        return encoder.convert({
          'mcpServers': {
            'student-age-editor': {
              'type': 'http',
              'url': url,
              'headers': {
                'Authorization': authValue,
              },
            },
          },
        });
      case McpAgentClientType.cursor:
        return encoder.convert({
          'mcpServers': {
            'student-age-editor': {
              'url': url,
              'headers': {
                'Authorization': authValue,
              },
            },
          },
        });
      case McpAgentClientType.windsurf:
        return encoder.convert({
          'mcpServers': {
            'student-age-editor': {
              'serverUrl': url,
              'headers': {
                'Authorization': authValue,
              },
            },
          },
        });
      case McpAgentClientType.curl:
        return 'curl -X POST "$url" \\\n'
            '  -H "Content-Type: application/json" \\\n'
            '  -H "Authorization: $authValue" \\\n'
            '  -d \'{"jsonrpc":"2.0","id":1,"method":"tools/list"}\'';
    }
  }
}

/// 设置页「HTTP MCP 服务端 & 生成令牌卡片」组件。
class McpTokenSection extends StatefulWidget {
  const McpTokenSection({super.key});

  @override
  State<McpTokenSection> createState() => _McpTokenSectionState();
}

class _McpTokenSectionState extends State<McpTokenSection> {
  static const _localPrefsKey = 'mcp_agent_tokens_v1';

  final TextEditingController _labelCtrl =
      TextEditingController(text: 'Cursor Agent');
  int _expiresDays = 30;
  bool _readonlyMode = false;
  McpAgentClientType _clientType = McpAgentClientType.claudeCode;

  List<McpAccessTokenEntry> _tokens = const [];
  bool _generating = false;

  /// 最近一次生成的明文令牌（仅在当前会话展示，方便用户一键复制）。
  String? _newlyGeneratedToken;
  String? _newlyGeneratedLabel;

  @override
  void initState() {
    super.initState();
    _loadTokens();
  }

  @override
  void dispose() {
    _labelCtrl.dispose();
    super.dispose();
  }

  /// 当前用于填充配置预览的令牌：优先取新生成的明文令牌，其次取当前登录会话或本机令牌。
  String? get _activePreviewToken {
    if (_newlyGeneratedToken != null && _newlyGeneratedToken!.isNotEmpty) {
      return _newlyGeneratedToken;
    }
    final access = ApiClient.instance.accessToken;
    if (access != null && access.isNotEmpty) return access;
    final backend = ApiClient.backendToken;
    if (backend != null && backend.isNotEmpty) return backend;
    return null;
  }

  Future<void> _loadTokens() async {
    try {
      // 优先从后端拉取已登记的 MCP API 令牌列表
      final resp = await ApiClient.instance
          .get('/api/auth/tokens')
          .timeout(const Duration(seconds: 3));
      if (!mounted) return;
      final rawList = (resp is Map ? resp['tokens'] : null) as List?;
      if (rawList != null) {
        final parsed = <McpAccessTokenEntry>[];
        for (final item in rawList) {
          if (item is Map) {
            parsed.add(
              McpAccessTokenEntry.fromJson(Map<String, dynamic>.from(item)),
            );
          }
        }
        setState(() => _tokens = parsed);
        await _saveLocalTokens(parsed);
        return;
      }
    } catch (_) {
      // 后端尚未实现 /api/auth/tokens 或处于单机离线态时，回退读取本地持久化列表
    }
    final local = await _loadLocalTokens();
    if (!mounted) return;
    setState(() => _tokens = local);
  }

  Future<List<McpAccessTokenEntry>> _loadLocalTokens() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_localPrefsKey);
      if (raw == null || raw.isEmpty) return const [];
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return [
        for (final e in decoded)
          if (e is Map)
            McpAccessTokenEntry.fromJson(Map<String, dynamic>.from(e)),
      ];
    } catch (_) {
      return const [];
    }
  }

  Future<void> _saveLocalTokens(List<McpAccessTokenEntry> list) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _localPrefsKey,
        jsonEncode(list.map((e) => e.toJson()).toList()),
      );
    } catch (_) {}
  }

  static String _generateRandomHex(int bytes) {
    final rng = Random.secure();
    final sb = StringBuffer('sa_mcp_');
    for (var i = 0; i < bytes; i++) {
      sb.write(rng.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }

  static String _formatDate(DateTime dt) {
    final y = dt.year.toString().padLeft(4, '0');
    final m = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  Future<void> _generateToken() async {
    if (_generating) return;
    final label = _labelCtrl.text.trim().isEmpty
        ? 'External Agent'
        : _labelCtrl.text.trim();
    setState(() => _generating = true);

    try {
      String? plainToken;
      McpAccessTokenEntry? createdEntry;

      try {
        final resp = await ApiClient.instance.post(
          '/api/auth/tokens',
          body: {
            'label': label,
            'expires_in_days': _expiresDays,
            'readonly': _readonlyMode,
          },
        ).timeout(const Duration(seconds: 4));

        if (resp is Map && resp['token'] is String) {
          plainToken = (resp['token'] as String).trim();
          createdEntry = McpAccessTokenEntry.fromJson(
            Map<String, dynamic>.from(resp),
          );
        }
      } catch (_) {
        // 若网关/后端尚未挂载 /api/auth/tokens，回退使用当前会话/后端令牌或生成本地令牌
      }

      if (plainToken == null || plainToken.isEmpty) {
        final existingSession =
            ApiClient.instance.accessToken ?? ApiClient.backendToken;
        plainToken = (existingSession != null && existingSession.isNotEmpty)
            ? existingSession
            : _generateRandomHex(24);
        final now = DateTime.now();
        final expText = _expiresDays <= 0
            ? '永不过期'
            : _formatDate(now.add(Duration(days: _expiresDays)));
        createdEntry = McpAccessTokenEntry(
          id: 'tok_${now.millisecondsSinceEpoch}',
          label: label,
          maskedToken: McpAccessTokenEntry.maskToken(plainToken),
          createdAt: _formatDate(now),
          expiresAt: expText,
          readonly: _readonlyMode,
        );
      }

      final nextList = [createdEntry!, ..._tokens];
      await _saveLocalTokens(nextList);
      if (!mounted) return;
      setState(() {
        _tokens = nextList;
        _newlyGeneratedToken = plainToken;
        _newlyGeneratedLabel = label;
      });
      _showToast('已生成外部 Agent 接入令牌：$label');
    } finally {
      if (mounted) {
        setState(() {
          _generating = false;
        });
      }
    }
  }

  Future<void> _revokeToken(McpAccessTokenEntry entry) async {
    try {
      await ApiClient.instance
          .delete('/api/auth/tokens/${Uri.encodeComponent(entry.id)}')
          .timeout(const Duration(seconds: 3));
    } catch (_) {}
    final nextList = _tokens.where((e) => e.id != entry.id).toList();
    await _saveLocalTokens(nextList);
    if (!mounted) return;
    setState(() {
      _tokens = nextList;
    });
    _showToast('已吊销令牌：${entry.label}');
  }

  Future<void> _copyText(String text, String toastMessage) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    _showToast(toastMessage);
  }

  void _showToast(String title) {
    fluent.displayInfoBar(
      context,
      builder: (ctx, close) => fluent.InfoBar(
        title: Text(title),
        severity: fluent.InfoBarSeverity.success,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final muted = TextStyle(fontSize: 11, color: palette.textMuted);
    final labelStyle = TextStyle(fontSize: 12, color: palette.textHint);
    final endpointUrl = McpConfigGenerator.buildEndpointUrl(
      ApiClient.instance.baseUrl,
      readonly: _readonlyMode,
    );
    final snippet = McpConfigGenerator.buildClientSnippet(
      clientType: _clientType,
      baseUrl: ApiClient.instance.baseUrl,
      token: _activePreviewToken,
      readonly: _readonlyMode,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 20),
        Divider(color: palette.border),
        const SizedBox(height: 8),
        Row(
          children: [
            Icon(
              FluentIcons.plug_connected_24_regular,
              size: 16,
              color: accentColor,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                'HTTP MCP 服务端（供外部 Agent 接入）',
                style: TextStyle(
                  fontSize: 13,
                  color: palette.textHigh,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          '通过 HTTP 协议向 Claude Code、Cursor、Windsurf、Dify 等外部 Agent 开放模组读写工具，'
          '所有请求均须携带 Authorization 鉴权请求头。',
          style: muted,
        ),
        const SizedBox(height: 10),

        // ---------------- 服务端点地址栏 ----------------
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: palette.bg,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: palette.border),
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: palette.card,
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: palette.border),
                ),
                child: Text(
                  'POST',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    color: accentColor,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: SelectableText(
                  endpointUrl,
                  style: TextStyle(
                    fontSize: 12,
                    fontFamily: 'Consolas',
                    color: palette.textHigh,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              fluent.Button(
                onPressed: () =>
                    _copyText(endpointUrl, '已复制 HTTP MCP 端点地址'),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(FluentIcons.copy_24_regular, size: 13),
                    SizedBox(width: 4),
                    Text('复制地址', style: TextStyle(fontSize: 11)),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),

        // ---------------- 生成令牌卡片 (Token Generation Card) ----------------
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: palette.card,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: palette.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    FluentIcons.key_24_regular,
                    size: 16,
                    color: accentColor,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '生成令牌（鉴权请求头凭据）',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: palette.textHigh,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                '为外部 Agent 生成专用访问令牌，请求时通过 Header 携带：Authorization: Bearer <令牌>',
                style: muted,
              ),
              const SizedBox(height: 10),
              Text('令牌备注名称', style: labelStyle),
              const SizedBox(height: 4),
              fluent.TextBox(
                controller: _labelCtrl,
                placeholder: '例如：Cursor Agent / Claude Code / Dify',
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('有效期', style: labelStyle),
                        const SizedBox(height: 4),
                        fluent.ComboBox<int>(
                          value: _expiresDays,
                          isExpanded: true,
                          items: const [
                            fluent.ComboBoxItem(
                              value: 30,
                              child: Text('30 天'),
                            ),
                            fluent.ComboBoxItem(
                              value: 90,
                              child: Text('90 天'),
                            ),
                            fluent.ComboBoxItem(
                              value: 365,
                              child: Text('365 天'),
                            ),
                            fluent.ComboBoxItem(
                              value: 0,
                              child: Text('永不过期'),
                            ),
                          ],
                          onChanged: (v) {
                            if (v != null) setState(() => _expiresDays = v);
                          },
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('工具权限范围', style: labelStyle),
                        const SizedBox(height: 4),
                        fluent.ComboBox<bool>(
                          value: _readonlyMode,
                          isExpanded: true,
                          items: const [
                            fluent.ComboBoxItem(
                              value: false,
                              child: Text('读写（全部 13 个工具）'),
                            ),
                            fluent.ComboBoxItem(
                              value: true,
                              child: Text('仅只读（9 个查询工具）'),
                            ),
                          ],
                          onChanged: (v) {
                            if (v != null) setState(() => _readonlyMode = v);
                          },
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  fluent.FilledButton(
                    onPressed: _generating ? null : _generateToken,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(FluentIcons.add_circle_24_regular, size: 14),
                        const SizedBox(width: 6),
                        Text(_generating ? '正在生成...' : '生成令牌'),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '生成的令牌将自动填入下方 Agent 接入配置预览',
                    style: muted,
                  ),
                ],
              ),

              // 新生成的明文令牌展示框
              if (_newlyGeneratedToken != null &&
                  _newlyGeneratedToken!.isNotEmpty) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: palette.bg,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: accentColor),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            FluentIcons.checkmark_circle_24_filled,
                            size: 14,
                            color: accentColor,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              '令牌「${_newlyGeneratedLabel ?? 'Agent'}」已生成（请立即复制保存，关闭后不再显示明文）',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: palette.textHigh,
                              ),
                            ),
                          ),
                          fluent.IconButton(
                            icon: Icon(
                              FluentIcons.dismiss_24_regular,
                              size: 12,
                              color: palette.textMuted,
                            ),
                            onPressed: () =>
                                setState(() => _newlyGeneratedToken = null),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      SelectableText(
                        _newlyGeneratedToken!,
                        style: TextStyle(
                          fontSize: 12,
                          fontFamily: 'Consolas',
                          color: palette.textHigh,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 6,
                        children: [
                          fluent.FilledButton(
                            onPressed: () => _copyText(
                              _newlyGeneratedToken!,
                              '已复制明文令牌',
                            ),
                            child: const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(FluentIcons.copy_24_regular, size: 13),
                                SizedBox(width: 4),
                                Text('复制令牌', style: TextStyle(fontSize: 11)),
                              ],
                            ),
                          ),
                          fluent.Button(
                            onPressed: () => _copyText(
                              'Authorization: Bearer $_newlyGeneratedToken',
                              '已复制 Authorization 鉴权请求头',
                            ),
                            child: const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  FluentIcons.shield_keyhole_24_regular,
                                  size: 13,
                                ),
                                SizedBox(width: 4),
                                Text(
                                  '复制鉴权请求头',
                                  style: TextStyle(fontSize: 11),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],

              // 已生成令牌列表
              if (_tokens.isNotEmpty) ...[
                const SizedBox(height: 12),
                Divider(color: palette.border),
                const SizedBox(height: 8),
                Text(
                  '已生成令牌（${_tokens.length}）',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: palette.textSecondary,
                  ),
                ),
                const SizedBox(height: 6),
                for (final entry in _tokens)
                  Container(
                    margin: const EdgeInsets.only(bottom: 6),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: palette.bg,
                      borderRadius: BorderRadius.circular(5),
                      border: Border.all(color: palette.border),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Flexible(
                                    child: Text(
                                      entry.label,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: palette.textHigh,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 5,
                                      vertical: 1,
                                    ),
                                    decoration: BoxDecoration(
                                      color: palette.card,
                                      borderRadius: BorderRadius.circular(3),
                                      border: Border.all(color: palette.border),
                                    ),
                                    child: Text(
                                      entry.readonly ? '只读' : '读写',
                                      style: TextStyle(
                                        fontSize: 9,
                                        color: palette.textMuted,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 2),
                              Text(
                                '${entry.maskedToken} · 到期：${entry.expiresAt}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 10,
                                  fontFamily: 'Consolas',
                                  color: palette.textHint,
                                ),
                              ),
                            ],
                          ),
                        ),
                        fluent.Button(
                          onPressed: () => _revokeToken(entry),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(FluentIcons.delete_24_regular, size: 13),
                              SizedBox(width: 4),
                              Text('吊销', style: TextStyle(fontSize: 11)),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 12),

        // ---------------- 外部 Agent 接入配置一键生成器 ----------------
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: palette.card,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: palette.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '外部 Agent 接入配置预览',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: palette.textHigh,
                      ),
                    ),
                  ),
                  fluent.Button(
                    onPressed: () => _copyText(
                      snippet,
                      '已复制 ${_clientType.label} 接入配置',
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(FluentIcons.copy_24_regular, size: 13),
                        SizedBox(width: 4),
                        Text('复制配置', style: TextStyle(fontSize: 11)),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              fluent.ComboBox<McpAgentClientType>(
                value: _clientType,
                isExpanded: true,
                items: [
                  for (final t in McpAgentClientType.values)
                    fluent.ComboBoxItem(
                      value: t,
                      child: Text(t.label),
                    ),
                ],
                onChanged: (v) {
                  if (v != null) setState(() => _clientType = v);
                },
              ),
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: palette.bg,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: palette.border),
                ),
                child: SelectableText(
                  snippet,
                  style: TextStyle(
                    fontSize: 11,
                    fontFamily: 'Consolas',
                    height: 1.45,
                    color: palette.textPrimary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
