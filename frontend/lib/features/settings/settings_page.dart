import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:file_selector/file_selector.dart';

import '../../core/api_client.dart';
import '../../core/backend_retry.dart';
import '../../core/no_code_mode.dart';
import '../../core/platform_env.dart';
import '../ai/ai_policy.dart';
import '../ai/mcp/mcp_types.dart';
import '../../core/responsive.dart';
import '../../core/ui_mode.dart';
import '../../core/app_theme.dart';
import 'update_section.dart';
import '../../core/app_dialogs.dart';

/// AI 服务配置。
class AiSettings {
  AiSettings({
    this.provider = 'openai_compatible',
    this.baseUrl = '',
    this.apiKey = '',
    this.model = '',
    this.temperature = 0.7,
    this.imageModel = '',
    this.imageApiKey = '',
    this.imageBaseUrl = '',
    this.ttsProvider = '',
    this.ttsApiKey = '',
    this.ttsBaseUrl = '',
    this.ttsModel = '',
    this.ttsVoice = '',
    this.ttsGroupId = '',
    this.ttsSpeed = 1.0,
    this.ttsVolume = 1.0,
    this.ttsPitch = 0,
    this.ttsFormat = 'wav',
    this.permissionMode = 'confirm',
    this.recentModels = const [],
    this.customInstructions = '',
    this.mcpServers = const [],
  });

  String provider; // openai_compatible | openai_responses | anthropic
  String baseUrl;
  String apiKey;
  String model;
  double temperature;

  /// 图片生成（openai-image-api）配置；留空时自动复用对话配置。
  String imageModel;
  String imageApiKey;
  String imageBaseUrl;

  /// 配音（TTS）配置：provider 取 '' | minimax | aliyun，密钥与对话/生图相互独立。
  String ttsProvider;
  String ttsApiKey;
  String ttsBaseUrl; // 可选自定义网关（MiniMax 代理 / DashScope 端点）
  String ttsModel;
  String ttsVoice; // 默认音色
  String ttsGroupId; // MiniMax 专用
  double ttsSpeed;
  double ttsVolume;
  int ttsPitch;
  String ttsFormat; // wav | ogg
  /// AI 写操作权限模式：confirm=变更前逐项弹窗确认（默认），full=完全访问（不弹确认）。
  String permissionMode; // confirm | full

  /// 最近使用过的对话模型（面板内快捷切换候选，最新在前，上限 8）。
  List<String> recentModels;

  /// 用户附加指令：追加到系统提示词尾部区域（三端共享，影响所有端）。
  String customInstructions;

  /// MCP 服务器列表（GUI 聊天链路按 enabled 项连接；
  /// id 经 [McpServerConfig.sanitizeId] 清洗，用作工具命名空间前缀）。
  List<McpServerConfig> mcpServers;

  static const prefsKey = 'ai_settings_v1';

  /// PUT /api/ai/settings 的保留哨兵（安全批次 B，与后端
  /// p3b_domain_tools_routes.cpp 的 kKeyUnchangedSentinel 一致）：key 仍是
  /// 掩码回显且用户未修改时上送该值，后端见哨兵即沿用共享文件现值。
  /// 注意：哨兵不是任何服务商的密钥形态，不可当作真实 key 使用
  /// （想清空 key 应上送空串）。
  static const keyUnchangedSentinel = '***UNCHANGED***';

  /// 是否为服务端掩码回显形态（GET /api/ai/settings 对 key 类字段返回
  /// 「前4+***+后4」或整串 ***MASKED***）。真实密钥不会包含 ***。
  static bool isMaskedKey(String v) => v.contains('***');

  /// 当前是否为完全访问模式（AI 写操作跳过确认弹窗）。
  bool get isFullAccess => permissionMode == 'full';

  /// 图片生成实际使用的模型：图片模型 > 对话模型 > 默认 gpt-image-2。
  String get effectiveImageModel {
    final m = imageModel.trim();
    if (m.isNotEmpty) return m;
    final chat = model.trim();
    return chat.isNotEmpty ? chat : 'gpt-image-2';
  }

  /// 图片生成实际使用的 API Key：图片 Key > 对话 Key。
  String get effectiveImageApiKey {
    final k = imageApiKey.trim();
    return k.isNotEmpty ? k : apiKey.trim();
  }

  /// 图片生成实际使用的 Base URL：图片 Base URL > 对话 Base URL > 官方默认。
  String get effectiveImageBaseUrl {
    var b = imageBaseUrl.trim();
    if (b.isEmpty) b = baseUrl.trim();
    return b.isNotEmpty ? b : 'https://api.openai.com/v1';
  }

  Map<String, dynamic> toJson() => {
    'provider': provider,
    'baseUrl': baseUrl,
    'apiKey': apiKey,
    'model': model,
    'temperature': temperature,
    'imageModel': imageModel,
    'imageApiKey': imageApiKey,
    'imageBaseUrl': imageBaseUrl,
    'ttsProvider': ttsProvider,
    'ttsApiKey': ttsApiKey,
    'ttsBaseUrl': ttsBaseUrl,
    'ttsModel': ttsModel,
    'ttsVoice': ttsVoice,
    'ttsGroupId': ttsGroupId,
    'ttsSpeed': ttsSpeed,
    'ttsVolume': ttsVolume,
    'ttsPitch': ttsPitch,
    'ttsFormat': ttsFormat,
    'permissionMode': permissionMode,
    'recentModels': recentModels,
    'customInstructions': customInstructions,
    'mcpServers': mcpServers.map((e) => e.toJson()).toList(),
  };

  factory AiSettings.fromJson(Map<String, dynamic> json) => AiSettings(
    provider: json['provider'] as String? ?? 'openai_compatible',
    baseUrl: json['baseUrl'] as String? ?? '',
    apiKey: json['apiKey'] as String? ?? '',
    model: json['model'] as String? ?? '',
    temperature: (json['temperature'] as num?)?.toDouble() ?? 0.7,
    imageModel: json['imageModel'] as String? ?? '',
    imageApiKey: json['imageApiKey'] as String? ?? '',
    imageBaseUrl: json['imageBaseUrl'] as String? ?? '',
    ttsProvider: json['ttsProvider'] as String? ?? '',
    ttsApiKey: json['ttsApiKey'] as String? ?? '',
    ttsBaseUrl: json['ttsBaseUrl'] as String? ?? '',
    ttsModel: json['ttsModel'] as String? ?? '',
    ttsVoice: json['ttsVoice'] as String? ?? '',
    ttsGroupId: json['ttsGroupId'] as String? ?? '',
    ttsSpeed: (json['ttsSpeed'] as num?)?.toDouble() ?? 1.0,
    ttsVolume: (json['ttsVolume'] as num?)?.toDouble() ?? 1.0,
    ttsPitch: (json['ttsPitch'] as num?)?.toInt() ?? 0,
    ttsFormat: json['ttsFormat'] as String? ?? 'wav',
    permissionMode: json['permissionMode'] as String? ?? 'confirm',
    recentModels: [
      for (final m in (json['recentModels'] as List? ?? const []))
        if (m is String && m.trim().isNotEmpty) m.trim(),
    ],
    customInstructions: json['customInstructions'] as String? ?? '',
    mcpServers: _parseMcpServers(json['mcpServers']),
  );

  /// 解析 MCP 服务器列表：非 Map 条目或构造抛错的非法项一律跳过，
  /// 不让个别坏数据炸掉整份 AI 设置加载。
  static List<McpServerConfig> _parseMcpServers(dynamic raw) {
    if (raw is! List) return const [];
    final out = <McpServerConfig>[];
    for (final e in raw) {
      try {
        if (e is! Map) continue;
        out.add(McpServerConfig.fromJson(Map<String, dynamic>.from(e)));
      } catch (_) {}
    }
    return out;
  }

  /// 记录一个最近使用的模型（去重、最新在前、上限 8）。
  void rememberModel(String m) {
    final name = m.trim();
    if (name.isEmpty) return;
    recentModels = [
      name,
      ...recentModels.where((e) => e != name),
    ].take(8).toList();
  }

  /// 生成上送 /api/ai/settings 的请求体（安全批次 B）：key 类字段若仍是
  /// 服务端掩码回显（用户未修改），改发 [keyUnchangedSentinel] 让后端沿用
  /// 现值；用户新填的值与空串（清空）原样上送。
  Map<String, dynamic> toRemoteJson() {
    final body = toJson();
    for (final k in const ['apiKey', 'imageApiKey', 'ttsApiKey']) {
      final v = body[k];
      if (v is String && isMaskedKey(v)) body[k] = keyUnchangedSentinel;
    }
    return body;
  }

  /// 返回远端（三端共享）写入是否成功。本机 SharedPreferences 已成功；
  /// 远端失败只影响终端同步——调用方据此提示「已保存」还是「已保存，仅本机生效」。
  ///
  /// Web：API Key 只存浏览器本地（SharedPreferences），**绝不写穿到编辑器
  /// 后端**（共享文件会被 CLI/TUI 等其他端读到）；返回 true 表示本机保存成功。
  Future<bool> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(prefsKey, jsonEncode(toJson()));
    if (kIsWeb) return true;
    // 写穿三端共享文件 .editor_ai.json（CLI/TUI/GUI 唯一数据源）。
    try {
      await ApiClient.instance
          .put('/api/ai/settings', body: toRemoteJson())
          .timeout(const Duration(seconds: 5));
      await prefs.setBool(remoteMigratedFlag, true);
      return true;
    } catch (_) {
      return false;
    }
  }

  static const remoteMigratedFlag = 'ai_settings_remote_migrated_v1';

  /// 三端共享加载：`.editor_ai.json`（经后端 GET /api/ai/settings 读到）优先，
  /// 失败或为空时回退本地 SharedPreferences 缓存。
  ///
  /// - 首次共享：共享文件有配置 → 采用并刷新本地缓存；
  /// - 反向迁移：共享文件为空而本机已有可用配置 → 推送一次到文件（幂等，成功后打标记）；
  /// - 后端不可达（冷启动竞态/Android 沙箱等）：静默沿用本地值。
  static Future<AiSettings> loadWithRemote() async {
    final local = await load();
    // 有对话/生图配置，或任一 TTS 配置（TTS-only 也能从远端同步）即视为有效。
    bool meaningful(AiSettings s) =>
        s.apiKey.isNotEmpty ||
        s.model.isNotEmpty ||
        s.baseUrl.isNotEmpty ||
        s.ttsApiKey.isNotEmpty ||
        s.ttsGroupId.isNotEmpty ||
        s.ttsModel.isNotEmpty ||
        s.ttsBaseUrl.isNotEmpty ||
        s.ttsVoice.isNotEmpty;
    try {
      final r = await ApiClient.instance
          .get('/api/ai/settings')
          .timeout(const Duration(seconds: 4));
      final raw =
          (r is Map ? r['settings'] : null) as Map<String, dynamic>? ?? {};
      final remote = AiSettings.fromJson(raw);
      // 安全批次 B：远端 key 类字段是掩码回显而非可用密钥。本地已存有真实
      // 值时保留本地值，避免掩码覆盖后 GUI 直连请求带着掩码串被服务商 401；
      // 本地为空/同为掩码时维持远端掩码（设置页可见「已配置」形态）。
      if (isMaskedKey(remote.apiKey) &&
          local.apiKey.isNotEmpty &&
          !isMaskedKey(local.apiKey)) {
        remote.apiKey = local.apiKey;
      }
      if (isMaskedKey(remote.imageApiKey) &&
          local.imageApiKey.isNotEmpty &&
          !isMaskedKey(local.imageApiKey)) {
        remote.imageApiKey = local.imageApiKey;
      }
      if (isMaskedKey(remote.ttsApiKey) &&
          local.ttsApiKey.isNotEmpty &&
          !isMaskedKey(local.ttsApiKey)) {
        remote.ttsApiKey = local.ttsApiKey;
      }
      if (meaningful(remote)) {
        await _cachePrefs(remote);
        return remote;
      }
      if (meaningful(local)) {
        final prefs = await SharedPreferences.getInstance();
        if (prefs.getBool(remoteMigratedFlag) != true) {
          try {
            await ApiClient.instance
                .put('/api/ai/settings', body: local.toRemoteJson())
                .timeout(const Duration(seconds: 4));
            await prefs.setBool(remoteMigratedFlag, true);
          } catch (_) {}
        }
      }
    } catch (_) {}
    return local;
  }

  static Future<void> _cachePrefs(AiSettings s) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(prefsKey, jsonEncode(s.toJson()));
  }

  static Future<AiSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(prefsKey);
    if (raw == null || raw.isEmpty) return AiSettings();
    try {
      return AiSettings.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return AiSettings();
    }
  }
}

/// 保存前指南校验的严格度设置（与编辑器保存流程共享同一持久化 key）。
class SaveValidatePrefs {
  SaveValidatePrefs._();

  static const prefsKey = 'save_validate_strict';

  /// 读取严格模式开关（默认开启：保存时指南校验错误阻止保存）。
  static Future<bool> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(prefsKey) ?? true;
    } catch (_) {
      return true;
    }
  }

  /// 写入严格模式开关。
  static Future<void> save(bool strict) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(prefsKey, strict);
    } catch (_) {}
  }
}

/// 设置页（AI 服务配置 + 界面风格 + 外观主题 + 工作区信息）。
class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.settings,
    required this.onChanged,
    this.uiMode,
    this.onUiModeChanged,
    this.settingsLoaded = true,
  });
  final AiSettings settings;
  final ValueChanged<AiSettings> onChanged;

  /// 界面风格（可为空：不展示风格切换区块）。
  final UiMode? uiMode;
  final ValueChanged<UiMode>? onUiModeChanged;

  /// 壳层的设置是否已加载完成。未加载时 widget.settings 是空占位，
  /// 此刻点保存会把全空配置写穿到三端共享的 .editor_ai.json —— 保存按钮禁用。
  final bool settingsLoaded;
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final TextEditingController _baseUrlCtrl;
  late final TextEditingController _apiKeyCtrl;
  late final TextEditingController _modelCtrl;
  late final TextEditingController _imageModelCtrl;
  late final TextEditingController _imageApiKeyCtrl;
  late final TextEditingController _imageBaseUrlCtrl;
  late final TextEditingController _ttsApiKeyCtrl;
  late final TextEditingController _ttsGroupIdCtrl;
  late final TextEditingController _ttsModelCtrl;
  late final TextEditingController _ttsBaseUrlCtrl;
  late final TextEditingController _ttsVoiceCtrl;
  late final TextEditingController _customInstructionsCtrl;
  String _provider = 'openai_compatible';
  double _temperature = 0.7;
  String _ttsProvider = '';
  double _ttsSpeed = 1.0;
  bool _ttsTesting = false;
  String _permissionMode = 'confirm';

  /// 服务端 TTS / 生图能力（网页版策略 `tts_image_available`）。桌面端与
  /// 本机浏览器版恒 true（不拉 policy）；自托管托管形态为 false，此时
  /// 「配音（TTS）」「图片生成」两块设置不再展示（服务端不提供服务）。
  bool _ttsImageAvailable = true;

  // ---------------- MCP 服务器编辑态 ----------------

  /// Android / Web 上无本机子进程能力，stdio 表单隐藏（与 backend_launcher
  /// supportsSpawn 同一判断口径）。
  static bool get _stdioSupported => !isAndroidPlatform && !kIsWeb;

  /// 当前编辑中的 MCP 列表（点「保存配置」才写回 AiSettings）。
  List<McpServerConfig> _mcpServers = [];

  /// 用户是否已手动增删改过列表：异步加载完成时不覆盖编辑中的内容。
  bool _mcpDirty = false;
  bool _mcpAdding = false;
  bool _mcpFormEnabled = true;
  String _mcpTransport = 'stdio';
  final _mcpNameCtrl = TextEditingController();
  final _mcpIdCtrl = TextEditingController();
  final _mcpCmdCtrl = TextEditingController();
  final _mcpArgsCtrl = TextEditingController();
  final _mcpUrlCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _provider = widget.settings.provider;
    _baseUrlCtrl = TextEditingController(text: widget.settings.baseUrl);
    _apiKeyCtrl = TextEditingController(text: widget.settings.apiKey);
    _modelCtrl = TextEditingController(text: widget.settings.model);
    _imageModelCtrl = TextEditingController(text: widget.settings.imageModel);
    _imageApiKeyCtrl = TextEditingController(text: widget.settings.imageApiKey);
    _imageBaseUrlCtrl = TextEditingController(
      text: widget.settings.imageBaseUrl,
    );
    _ttsProvider = widget.settings.ttsProvider;
    _ttsApiKeyCtrl = TextEditingController(text: widget.settings.ttsApiKey);
    _ttsGroupIdCtrl = TextEditingController(text: widget.settings.ttsGroupId);
    _ttsModelCtrl = TextEditingController(text: widget.settings.ttsModel);
    _ttsBaseUrlCtrl = TextEditingController(text: widget.settings.ttsBaseUrl);
    _ttsVoiceCtrl = TextEditingController(text: widget.settings.ttsVoice);
    _ttsSpeed = widget.settings.ttsSpeed.clamp(0.5, 2.0);
    _temperature = widget.settings.temperature;
    _permissionMode = widget.settings.permissionMode;
    _customInstructionsCtrl = TextEditingController(
      text: widget.settings.customInstructions,
    );
    _mcpServers = List.of(widget.settings.mcpServers);
    if (kIsWeb) _loadWebPolicy();
  }

  /// 网页版读取一次 AI 策略，决定服务端 TTS / 生图相关设置是否展示。
  /// 拉取失败按兜底（可用）处理，与 [AiPolicy.fallback] 口径一致。
  Future<void> _loadWebPolicy() async {
    try {
      await AiPolicyStore.instance.ensureLoaded();
    } catch (_) {}
    if (!mounted) return;
    final available = AiPolicyStore.instance.policy.ttsImageAvailable;
    if (available != _ttsImageAvailable) {
      setState(() => _ttsImageAvailable = available);
    }
  }

  @override
  void didUpdateWidget(covariant SettingsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.settings, widget.settings)) return;
    // 设置异步加载完成（或被外部修改）后同步控制器；用户正在编辑的字段
    // （有焦点）不覆盖，避免输入被打断。
    void sync(TextEditingController c, String v) {
      if (c.text != v && c.text.isEmpty) c.text = v;
    }

    sync(_baseUrlCtrl, widget.settings.baseUrl);
    sync(_apiKeyCtrl, widget.settings.apiKey);
    sync(_modelCtrl, widget.settings.model);
    sync(_imageModelCtrl, widget.settings.imageModel);
    sync(_imageApiKeyCtrl, widget.settings.imageApiKey);
    sync(_imageBaseUrlCtrl, widget.settings.imageBaseUrl);
    sync(_ttsApiKeyCtrl, widget.settings.ttsApiKey);
    sync(_ttsGroupIdCtrl, widget.settings.ttsGroupId);
    sync(_ttsModelCtrl, widget.settings.ttsModel);
    sync(_ttsBaseUrlCtrl, widget.settings.ttsBaseUrl);
    sync(_ttsVoiceCtrl, widget.settings.ttsVoice);
    sync(_customInstructionsCtrl, widget.settings.customInstructions);
    setState(() {
      _provider = widget.settings.provider;
      _ttsProvider = widget.settings.ttsProvider;
      _temperature = widget.settings.temperature;
      _permissionMode = widget.settings.permissionMode;
      // 用户未动过 MCP 列表时，跟随外部（异步加载/远端同步）的配置更新。
      if (!_mcpDirty) _mcpServers = List.of(widget.settings.mcpServers);
    });
  }

  @override
  void dispose() {
    _baseUrlCtrl.dispose();
    _apiKeyCtrl.dispose();
    _modelCtrl.dispose();
    _imageModelCtrl.dispose();
    _imageApiKeyCtrl.dispose();
    _imageBaseUrlCtrl.dispose();
    _ttsApiKeyCtrl.dispose();
    _ttsGroupIdCtrl.dispose();
    _ttsModelCtrl.dispose();
    _ttsBaseUrlCtrl.dispose();
    _ttsVoiceCtrl.dispose();
    _customInstructionsCtrl.dispose();
    _mcpNameCtrl.dispose();
    _mcpIdCtrl.dispose();
    _mcpCmdCtrl.dispose();
    _mcpArgsCtrl.dispose();
    _mcpUrlCtrl.dispose();
    super.dispose();
  }

  Map<String, dynamic> _ttsSettingsMap() => {
    'ttsProvider': _ttsProvider,
    'ttsApiKey': _ttsApiKeyCtrl.text.trim(),
    'ttsGroupId': _ttsGroupIdCtrl.text.trim(),
    'ttsModel': _ttsModelCtrl.text.trim(),
    'ttsBaseUrl': _ttsBaseUrlCtrl.text.trim(),
    'ttsVoice': _ttsVoiceCtrl.text.trim(),
    'ttsSpeed': _ttsSpeed,
    // 页面无编辑控件，从既有设置透传，供后端参数归一使用。
    'ttsVolume': widget.settings.ttsVolume,
    'ttsPitch': widget.settings.ttsPitch,
    'ttsFormat': widget.settings.ttsFormat,
  };

  Future<void> _ttsTest() async {
    setState(() => _ttsTesting = true);
    try {
      final r = await ApiClient.instance.runLongTask(
        '/api/tts/test',
        body: {'provider': _ttsProvider, 'settings': _ttsSettingsMap()},
        timeout: const Duration(seconds: 60),
        maxWait: const Duration(seconds: 300),
      );
      final ok = r['ok'] == true;
      if (!mounted) return;
      fluent.displayInfoBar(
        context,
        builder: (ctx, close) => fluent.InfoBar(
          title: Text(ok ? '配音服务连接成功' : '配音服务连接失败'),
          content: Text(
            ok
                ? (r['detail']?.toString() ?? '')
                : (r['error']?.toString() ?? '未知错误'),
          ),
          severity: ok
              ? fluent.InfoBarSeverity.success
              : fluent.InfoBarSeverity.error,
        ),
      );
    } catch (e) {
      if (mounted) {
        fluent.displayInfoBar(
          context,
          builder: (ctx, close) => fluent.InfoBar(
            title: const Text('配音服务连接失败'),
            content: Text(e.toString()),
            severity: fluent.InfoBarSeverity.error,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _ttsTesting = false);
    }
  }

  Future<void> _save() async {
    final s = AiSettings(
      provider: _provider,
      baseUrl: _baseUrlCtrl.text.trim(),
      apiKey: _apiKeyCtrl.text.trim(),
      model: _modelCtrl.text.trim(),
      temperature: _temperature,
      imageModel: _imageModelCtrl.text.trim(),
      imageApiKey: _imageApiKeyCtrl.text.trim(),
      imageBaseUrl: _imageBaseUrlCtrl.text.trim(),
      ttsProvider: _ttsProvider,
      ttsApiKey: _ttsApiKeyCtrl.text.trim(),
      ttsGroupId: _ttsGroupIdCtrl.text.trim(),
      ttsModel: _ttsModelCtrl.text.trim(),
      ttsBaseUrl: _ttsBaseUrlCtrl.text.trim(),
      ttsVoice: _ttsVoiceCtrl.text.trim(),
      ttsSpeed: _ttsSpeed,
      // 音量/音调/格式页面无编辑控件，从既有设置透传，避免保存时被重置。
      ttsVolume: widget.settings.ttsVolume,
      ttsPitch: widget.settings.ttsPitch,
      ttsFormat: widget.settings.ttsFormat,
      permissionMode: _permissionMode,
      customInstructions: _customInstructionsCtrl.text.trim(),
      mcpServers: List.of(_mcpServers),
    );
    final remoteOk = await s.save();
    widget.onChanged(s);
    if (mounted) {
      fluent.displayInfoBar(
        context,
        builder: (ctx, close) => fluent.InfoBar(
          title: Text(
            remoteOk ? '已保存 AI 配置（已同步三端共享）' : '已保存（仅本机生效，三端共享同步失败，可稍后重试）',
          ),
          severity: remoteOk
              ? fluent.InfoBarSeverity.success
              : fluent.InfoBarSeverity.warning,
        ),
      );
    }
  }

  // ---------------- MCP 服务器编辑 ----------------

  void _mcpStartAdd() {
    setState(() {
      _mcpAdding = true;
      _mcpFormEnabled = true;
      _mcpTransport = _stdioSupported ? 'stdio' : 'http';
      _mcpNameCtrl.clear();
      _mcpIdCtrl.clear();
      _mcpCmdCtrl.clear();
      _mcpArgsCtrl.clear();
      _mcpUrlCtrl.clear();
    });
  }

  void _mcpConfirmAdd() {
    final name = _mcpNameCtrl.text.trim();
    final idRaw = _mcpIdCtrl.text.trim().isNotEmpty
        ? _mcpIdCtrl.text.trim()
        : name;
    if (idRaw.isEmpty) return; // 名称与 id 至少填一项
    final id = McpServerConfig.sanitizeId(idRaw);
    if (_mcpServers.any((e) => e.id == id)) return; // id 重复（命名空间冲突）
    final cfg = McpServerConfig(
      id: id,
      name: name,
      transport: _stdioSupported ? _mcpTransport : 'http',
      command: _mcpCmdCtrl.text.trim(),
      // 一行一个参数：命令行里带空格的路径不会被拆坏
      args: [
        for (final line in _mcpArgsCtrl.text.split('\n'))
          if (line.trim().isNotEmpty) line.trim(),
      ],
      url: _mcpUrlCtrl.text.trim(),
      enabled: _mcpFormEnabled,
    );
    setState(() {
      _mcpServers = [..._mcpServers, cfg];
      _mcpDirty = true;
      _mcpAdding = false;
    });
  }

  void _mcpRemoveAt(int index) {
    setState(() {
      _mcpServers = [..._mcpServers]..removeAt(index);
      _mcpDirty = true;
    });
  }

  void _mcpToggleAt(int index, bool on) {
    setState(() {
      final cfg = _mcpServers[index];
      _mcpServers = [
        for (var i = 0; i < _mcpServers.length; i++)
          if (i == index)
            McpServerConfig(
              id: cfg.id,
              name: cfg.name,
              transport: cfg.transport,
              command: cfg.command,
              args: cfg.args,
              url: cfg.url,
              enabled: on,
            )
          else
            cfg,
      ];
      _mcpDirty = true;
    });
  }

  Widget _mcpLabel(String text) =>
      Text(text, style: TextStyle(fontSize: 12, color: palette.textHint));

  Widget _mcpRow(McpServerConfig cfg, int index) {
    final target = cfg.transport == 'http'
        ? (cfg.url.trim().isEmpty ? '（未填 url）' : cfg.url.trim())
        : (cfg.command.trim().isEmpty ? '（未填 command）' : cfg.command.trim());
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: palette.bg,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: palette.border),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  cfg.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: palette.textHigh),
                ),
                Text(
                  '${cfg.id} · ${cfg.transport == 'http' ? 'HTTP' : 'stdio'} · $target',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 10, color: palette.textHint),
                ),
              ],
            ),
          ),
          fluent.ToggleSwitch(
            checked: cfg.enabled,
            onChanged: (v) => _mcpToggleAt(index, v),
          ),
          const SizedBox(width: 4),
          fluent.Button(
            onPressed: () => _mcpRemoveAt(index),
            child: const Icon(FluentIcons.delete_24_regular, size: 14),
          ),
        ],
      ),
    );
  }

  /// 「MCP 服务器」区：列表 + 添加表单。无本机子进程能力的平台（Web / Android）
  /// 隐藏 stdio 相关字段，并隐藏列表中已存在的 stdio 服务器（在此平台永远连不上）。
  List<Widget> _buildMcpSection() {
    final muted = TextStyle(fontSize: 11, color: palette.textMuted);
    final formFields = <Widget>[
      const SizedBox(height: 8),
      _mcpLabel('名称'),
      const SizedBox(height: 4),
      fluent.TextBox(
        controller: _mcpNameCtrl,
        placeholder: '我的工具服务器（留空取 id）',
      ),
      const SizedBox(height: 8),
      _mcpLabel('ID（工具命名空间前缀 mcp__<id>__<tool>）'),
      const SizedBox(height: 4),
      fluent.TextBox(
        controller: _mcpIdCtrl,
        placeholder: 'filesystem（仅字母/数字/下划线，其余字符自动替换）',
      ),
      if (_stdioSupported) ...[
        const SizedBox(height: 8),
        _mcpLabel('传输方式'),
        const SizedBox(height: 4),
        fluent.ComboBox<String>(
          value: _mcpTransport,
          isExpanded: true,
          items: const [
            fluent.ComboBoxItem(value: 'stdio', child: Text('stdio（本地子进程）')),
            fluent.ComboBoxItem(value: 'http', child: Text('HTTP（远程端点）')),
          ],
          onChanged: (v) => setState(() => _mcpTransport = v ?? _mcpTransport),
        ),
        if (_mcpTransport == 'stdio') ...[
          const SizedBox(height: 8),
          _mcpLabel('Command（可执行文件/命令名）'),
          const SizedBox(height: 4),
          fluent.TextBox(
            controller: _mcpCmdCtrl,
            placeholder: 'npx.cmd / uvx / 绝对路径',
          ),
          const SizedBox(height: 8),
          _mcpLabel('参数（一行一个，可留空）'),
          const SizedBox(height: 4),
          fluent.TextBox(
            controller: _mcpArgsCtrl,
            minLines: 2,
            maxLines: 6,
            placeholder: '-y\n@modelcontextprotocol/server-filesystem\nD:\\data',
          ),
        ] else ...[
          const SizedBox(height: 8),
          _mcpLabel('URL'),
          const SizedBox(height: 4),
          fluent.TextBox(
            controller: _mcpUrlCtrl,
            placeholder: 'https://example.com/mcp',
          ),
        ],
      ] else ...[
        const SizedBox(height: 4),
        Text('当前平台仅支持 HTTP 传输（无法启动本地子进程）', style: muted),
        const SizedBox(height: 8),
        _mcpLabel('URL'),
        const SizedBox(height: 4),
        fluent.TextBox(
          controller: _mcpUrlCtrl,
          placeholder: 'https://example.com/mcp',
        ),
      ],
      const SizedBox(height: 8),
      Row(
        children: [
          Text('启用', style: TextStyle(fontSize: 12, color: palette.textHint)),
          const Spacer(),
          fluent.ToggleSwitch(
            checked: _mcpFormEnabled,
            onChanged: (v) => setState(() => _mcpFormEnabled = v),
          ),
        ],
      ),
      const SizedBox(height: 8),
      Row(
        children: [
          fluent.FilledButton(onPressed: _mcpConfirmAdd, child: const Text('添加')),
          const SizedBox(width: 8),
          fluent.Button(
            onPressed: () => setState(() => _mcpAdding = false),
            child: const Text('取消'),
          ),
        ],
      ),
    ];
    // 无本机子进程能力的平台（Web / Android）不展示 stdio 服务器：它们在此
    // 平台永远连不上（transport 工厂直接抛「网页版不支持本地进程 MCP」），
    // 展示只会误导。仅从渲染中过滤，_mcpServers 原样保留，保存时不丢配置。
    final rows = <Widget>[];
    var hiddenStdio = 0;
    for (var i = 0; i < _mcpServers.length; i++) {
      final cfg = _mcpServers[i];
      if (!_stdioSupported && cfg.transport != 'http') {
        hiddenStdio++;
        continue;
      }
      rows.add(_mcpRow(cfg, i));
    }
    return [
      const SizedBox(height: 20),
      Divider(color: palette.border),
      const SizedBox(height: 8),
      Text(
        'MCP 服务器',
        style: TextStyle(
          fontSize: 13,
          color: palette.textHigh,
          fontWeight: FontWeight.w600,
        ),
      ),
      const SizedBox(height: 4),
      Text(
        '接入 Model Context Protocol（MCP）工具服务器：其可用工具会追加进 AI 聊天，'
        '由模型按需调用；修改后需点击「保存配置」生效',
        style: muted,
      ),
      const SizedBox(height: 2),
      if (_stdioSupported)
        Text(
          '注意：stdio 服务器会以命令拉起本机外部进程，进程以本机用户权限运行，'
          '仅添加可信来源的服务器',
          style: TextStyle(fontSize: 11, color: palette.warning),
        )
      else if (hiddenStdio > 0)
        Text(
          '当前平台不支持本地子进程，已隐藏 $hiddenStdio 个 stdio 服务器'
          '（配置仍保留，可在桌面端管理）',
          style: TextStyle(fontSize: 11, color: palette.warning),
        ),
      const SizedBox(height: 8),
      if (rows.isEmpty)
        Text('尚未配置服务器', style: muted)
      else
        ...rows,
      const SizedBox(height: 8),
      if (_mcpAdding)
        ...formFields
      else
        fluent.Button(onPressed: _mcpStartAdd, child: const Text('添加服务器')),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final hintColor = palette.textHint;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          height: 38,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          alignment: Alignment.centerLeft,
          child: Text(
            '设置',
            style: TextStyle(
              fontSize: 12,
              color: palette.textSecondary,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        Divider(height: 1, color: palette.border),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'AI 服务',
                  style: TextStyle(
                    fontSize: 13,
                    color: palette.textHigh,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 12),
                Text('接口协议', style: TextStyle(fontSize: 12, color: hintColor)),
                const SizedBox(height: 6),
                fluent.ComboBox<String>(
                  value: _provider,
                  isExpanded: true,
                  items: const [
                    fluent.ComboBoxItem(
                      value: 'openai_compatible',
                      child: Text(
                        'OpenAI Compatible',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    fluent.ComboBoxItem(
                      value: 'openai_responses',
                      child: Text(
                        'OpenAI Responses API',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    fluent.ComboBoxItem(
                      value: 'anthropic',
                      child: Text(
                        'Anthropic Compatible',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                  onChanged: (v) => setState(() => _provider = v ?? _provider),
                ),
                const SizedBox(height: 12),
                Text(
                  'Base URL（留空使用官方默认）',
                  style: TextStyle(fontSize: 12, color: hintColor),
                ),
                const SizedBox(height: 4),
                Text(
                  '接口地址，通常保持默认即可；使用自建代理或中转服务时才需修改',
                  style: TextStyle(fontSize: 11, color: palette.textMuted),
                ),
                const SizedBox(height: 6),
                fluent.TextBox(
                  controller: _baseUrlCtrl,
                  placeholder: 'https://api.openai.com/v1',
                  onChanged: (_) {},
                ),
                const SizedBox(height: 12),
                Text(
                  'API Key',
                  style: TextStyle(fontSize: 12, color: hintColor),
                ),
                const SizedBox(height: 4),
                Text(
                  '调用 AI 服务所需的密钥，在服务商控制台获取；仅保存在本机',
                  style: TextStyle(fontSize: 11, color: palette.textMuted),
                ),
                const SizedBox(height: 6),
                fluent.TextBox(
                  controller: _apiKeyCtrl,
                  obscureText: true,
                  placeholder: 'sk-...',
                ),
                const SizedBox(height: 12),
                Text('模型', style: TextStyle(fontSize: 12, color: hintColor)),
                const SizedBox(height: 4),
                Text(
                  '选择或填写要使用的模型名称；留空则使用所选接口协议的默认模型',
                  style: TextStyle(fontSize: 11, color: palette.textMuted),
                ),
                const SizedBox(height: 6),
                fluent.TextBox(
                  controller: _modelCtrl,
                  placeholder: 'gpt-4o / claude-sonnet-4-20250514 / 自定义模型',
                ),
                const SizedBox(height: 12),
                Text('温度', style: TextStyle(fontSize: 12, color: hintColor)),
                fluent.Slider(
                  value: _temperature,
                  min: 0,
                  max: 2,
                  onChanged: (v) => setState(() => _temperature = v),
                  label: _temperature.toStringAsFixed(1),
                ),
                const SizedBox(height: 12),
                Text('AI 权限', style: TextStyle(fontSize: 12, color: hintColor)),
                const SizedBox(height: 4),
                Text(
                  '变更前确认：AI 的每次写入/删除/生图都会弹出审批框；'
                  '完全访问：AI 直接执行修改，不再弹出确认框',
                  style: TextStyle(fontSize: 11, color: palette.textMuted),
                ),
                const SizedBox(height: 6),
                fluent.ComboBox<String>(
                  value: _permissionMode == 'full' ? 'full' : 'confirm',
                  isExpanded: true,
                  items: const [
                    fluent.ComboBoxItem(
                      value: 'confirm',
                      child: Text('变更前确认（每次修改弹出审批框）'),
                    ),
                    fluent.ComboBoxItem(
                      value: 'full',
                      child: Text('完全访问（不再弹出确认框，AI 直接修改）'),
                    ),
                  ],
                  onChanged: (v) =>
                      setState(() => _permissionMode = v ?? _permissionMode),
                ),
                const SizedBox(height: 12),
                Text(
                  '附加指令',
                  style: TextStyle(fontSize: 12, color: hintColor),
                ),
                const SizedBox(height: 4),
                Text(
                  '可选：追加到 AI 系统提示词（影响所有端，GUI/CLI/TUI 共享同一份配置）；'
                  '与内置规则冲突时以内置规则为准',
                  style: TextStyle(fontSize: 11, color: palette.textMuted),
                ),
                const SizedBox(height: 6),
                fluent.TextBox(
                  controller: _customInstructionsCtrl,
                  minLines: 3,
                  maxLines: 8,
                  placeholder:
                      '例如：对话文案口语化、少用书面腔；新建条目命名参考已有条目的风格…',
                ),
                // 自托管网页形态（policy.tts_image_available=false）服务端不提供
                // TTS / 生图，这两块配置不再展示——填了也不会被服务端执行。
                if (_ttsImageAvailable) ...[
                  const SizedBox(height: 20),
                  Divider(color: palette.border),
                  const SizedBox(height: 8),
                  Text(
                    '图片生成（openai-image-api）',
                    style: TextStyle(
                      fontSize: 13,
                      color: palette.textHigh,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '供 AI 侧栏的生图 / 改图工具调用，遵循 OpenAI Images API 标准（images/generations、images/edits）。'
                    '留空时自动复用上方对话配置；使用 Anthropic 等非 OpenAI 接口时请单独填写',
                    style: TextStyle(fontSize: 11, color: palette.textMuted),
                  ),
                  const SizedBox(height: 12),
                  Text('图片模型', style: TextStyle(fontSize: 12, color: hintColor)),
                  const SizedBox(height: 6),
                  fluent.TextBox(
                    controller: _imageModelCtrl,
                    placeholder: 'gpt-image-2 / gpt-image-1 / dall-e-3（留空使用对话模型）',
                    onChanged: (_) {},
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '图片 API Key',
                    style: TextStyle(fontSize: 12, color: hintColor),
                  ),
                  const SizedBox(height: 6),
                  fluent.TextBox(
                    controller: _imageApiKeyCtrl,
                    obscureText: true,
                    placeholder: 'sk-...（留空复用对话 API Key）',
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '图片 Base URL（留空使用对话地址或官方默认）',
                    style: TextStyle(fontSize: 12, color: hintColor),
                  ),
                  const SizedBox(height: 6),
                  fluent.TextBox(
                    controller: _imageBaseUrlCtrl,
                    placeholder: 'https://api.openai.com/v1',
                    onChanged: (_) {},
                  ),
                  const SizedBox(height: 20),
                  Divider(color: palette.border),
                  const SizedBox(height: 8),
                  Text(
                    '配音（TTS）',
                    style: TextStyle(
                      fontSize: 13,
                      color: palette.textHigh,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '为剧本/文本合成语音：阿里云（DashScope 百炼，Bearer sk-*）或 MiniMax（T2A V2）。'
                    '密钥仅保存在本机；生成内容存到当前 mod 的 audio/tts/ 目录',
                    style: TextStyle(fontSize: 11, color: palette.textMuted),
                  ),
                  const SizedBox(height: 12),
                  Text('服务商', style: TextStyle(fontSize: 12, color: hintColor)),
                  const SizedBox(height: 6),
                  fluent.ComboBox<String>(
                    value: _ttsProvider,
                    isExpanded: true,
                    items: const [
                      fluent.ComboBoxItem(
                        value: '',
                        child: Text('未配置（在配音面板中按需选择）'),
                      ),
                      fluent.ComboBoxItem(
                        value: 'aliyun',
                        child: Text('阿里云 DashScope（百炼）'),
                      ),
                      fluent.ComboBoxItem(
                        value: 'minimax',
                        child: Text('MiniMax（T2A V2）'),
                      ),
                    ],
                    onChanged: (v) => setState(() => _ttsProvider = v ?? ''),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'API Key',
                    style: TextStyle(fontSize: 12, color: hintColor),
                  ),
                  const SizedBox(height: 6),
                  fluent.TextBox(
                    controller: _ttsApiKeyCtrl,
                    obscureText: true,
                    placeholder: 'sk-...（阿里云）或 MiniMax API Key',
                  ),
                  if (_ttsProvider == 'minimax') ...[
                    const SizedBox(height: 12),
                    Text(
                      'Group ID（MiniMax 控制台获取）',
                      style: TextStyle(fontSize: 12, color: hintColor),
                    ),
                    const SizedBox(height: 6),
                    fluent.TextBox(
                      controller: _ttsGroupIdCtrl,
                      placeholder: '19xxxxxxxxxxxxxxxxxxxxxxxxxxxxxx',
                    ),
                  ],
                  const SizedBox(height: 12),
                  Text(
                    '模型（留空使用默认）',
                    style: TextStyle(fontSize: 12, color: hintColor),
                  ),
                  const SizedBox(height: 6),
                  fluent.TextBox(
                    controller: _ttsModelCtrl,
                    placeholder: 'qwen-tts / cosyvoice-v2 / speech-02-hd',
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '默认音色（留空使用服务商默认）',
                    style: TextStyle(fontSize: 12, color: hintColor),
                  ),
                  const SizedBox(height: 6),
                  fluent.TextBox(
                    controller: _ttsVoiceCtrl,
                    placeholder: 'Cherry / female-shaonv / 其他 voice id',
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Base URL（留空使用官方默认；自建代理/中转时才需修改）',
                    style: TextStyle(fontSize: 12, color: hintColor),
                  ),
                  const SizedBox(height: 6),
                  fluent.TextBox(
                    controller: _ttsBaseUrlCtrl,
                    placeholder: _ttsProvider == 'minimax'
                        ? 'https://api.minimax.io'
                        : 'https://dashscope.aliyuncs.com/...',
                  ),
                  const SizedBox(height: 12),
                  Text('语速', style: TextStyle(fontSize: 12, color: hintColor)),
                  fluent.Slider(
                    value: _ttsSpeed,
                    min: 0.5,
                    max: 2,
                    onChanged: (v) => setState(() => _ttsSpeed = v),
                    label: '${_ttsSpeed.toStringAsFixed(1)}x',
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      fluent.Button(
                        onPressed: (_ttsTesting || _ttsProvider.isEmpty)
                            ? null
                            : _ttsTest,
                        child: _ttsTesting
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Text('测试连接'),
                      ),
                      const SizedBox(width: 8),
                      if (_ttsProvider.isEmpty)
                        Expanded(
                          child: Text(
                            '先选择服务商并填写 API Key 再测试',
                            style: TextStyle(
                              fontSize: 11,
                              color: palette.textMuted,
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
                ..._buildMcpSection(),
                const SizedBox(height: 16),
                fluent.FilledButton(
                  onPressed: widget.settingsLoaded ? _save : null,
                  child: Text(widget.settingsLoaded ? '保存配置' : '配置加载中…'),
                ),
                // 手机（宽度 <720）强制 MobileShell，界面风格选择器改了不生效——隐藏。
                if (widget.uiMode != null &&
                    widget.onUiModeChanged != null &&
                    !isMobileWidth(context)) ...[
                  const SizedBox(height: 24),
                  Divider(color: palette.border),
                  const SizedBox(height: 8),
                  Text(
                    '界面风格',
                    style: TextStyle(
                      fontSize: 13,
                      color: palette.textHigh,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 10),
                  // 四种风格用 Wrap：宽度足够时单行四等分，窄窗口自动换行避免溢出
                  LayoutBuilder(
                    builder: (context, box) {
                      final w = box.maxWidth;
                      final cardW = ((w - 30) / 4).clamp(140.0, 260.0);
                      return Wrap(
                        spacing: 10,
                        runSpacing: 10,
                        children: [
                          SizedBox(
                            width: cardW,
                            child: _StyleCard(
                              title: '创作',
                              desc: '图标活动栏 + 侧边栏 + 标签编辑区（当前默认）',
                              icon: FluentIcons.paint_brush_24_regular,
                              selected: widget.uiMode == UiMode.creation,
                              onTap: () =>
                                  widget.onUiModeChanged!(UiMode.creation),
                            ),
                          ),
                          SizedBox(
                            width: cardW,
                            child: _StyleCard(
                              title: '经典',
                              desc: '顶部工具栏 + 左侧分组导航（传统桌面风格）',
                              icon: FluentIcons.list_24_regular,
                              selected: widget.uiMode == UiMode.classic,
                              onTap: () =>
                                  widget.onUiModeChanged!(UiMode.classic),
                            ),
                          ),
                          SizedBox(
                            width: cardW,
                            child: _StyleCard(
                              title: '剧情图',
                              desc: '节点画布编排剧情分支（连线式流程）',
                              icon: FluentIcons.flow_24_regular,
                              selected: widget.uiMode == UiMode.storyFlow,
                              onTap: () =>
                                  widget.onUiModeChanged!(UiMode.storyFlow),
                            ),
                          ),
                          SizedBox(
                            width: cardW,
                            child: _StyleCard(
                              title: '导演',
                              desc: '三栏舞台工作台（对话线 + 舞台编辑 + 人物表情）',
                              icon: FluentIcons.movies_and_tv_24_regular,
                              selected: widget.uiMode == UiMode.director,
                              onTap: () =>
                                  widget.onUiModeChanged!(UiMode.director),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '切换后立即生效，已打开的文档与 AI 配置会保留',
                    style: TextStyle(fontSize: 11, color: palette.textMuted),
                  ),
                ],
                const SizedBox(height: 24),
                Divider(color: palette.border),
                const SizedBox(height: 8),
                _AppearanceSection(),
                const SizedBox(height: 24),
                Divider(color: palette.border),
                const SizedBox(height: 8),
                _SaveValidateSection(),
                const SizedBox(height: 24),
                Divider(color: palette.border),
                const SizedBox(height: 8),
                _NoCodeModeSection(),
                const SizedBox(height: 24),
                Divider(color: palette.border),
                const SizedBox(height: 8),
                _ResourcePackSection(),
                const SizedBox(height: 24),
                Divider(color: palette.border),
                const SizedBox(height: 8),
                UpdateCheckSection(),
                const SizedBox(height: 24),
                Divider(color: palette.border),
                const SizedBox(height: 8),
                Text(
                  '关于',
                  style: TextStyle(
                    fontSize: 13,
                    color: palette.textHigh,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '学生时代模组编辑器 · Flutter 前端 + native C++ 后端\n'
                  '核心引擎：C++20 自研 HTTP 服务（无 Python 运行时）+ Steamworks\n'
                  'UI：Fluent 2 设计语言（创作布局 + 经典布局）',
                  style: TextStyle(fontSize: 12, color: hintColor, height: 1.6),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// 界面风格选择卡片。

class _ResourcePackSection extends StatefulWidget {
  const _ResourcePackSection();
  @override
  State<_ResourcePackSection> createState() => _ResourcePackSectionState();
}

class _ResourcePackSectionState extends State<_ResourcePackSection> {
  List<dynamic> _packs = [];
  Set<String> _enabled = {};
  bool _loading = true;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      // 从源码运行时后端可能尚未就绪/中途被回收：连接级失败时自我恢复后重试。
      final r = await withBackendRetry(
        () => ApiClient.instance.get('/api/extensions'),
      );
      if (!mounted) return;
      final rmap = r is Map ? r : const {};
      setState(() {
        _packs = (rmap['extensions'] as List?) ?? [];
        _enabled = ((rmap['enabled'] as List?) ?? const [])
            .whereType<String>()
            .toSet();
      });
    } catch (e) {
      if (mounted)
        fluent.displayInfoBar(
          context,
          builder: (c, close) => fluent.InfoBar(
            title: const Text('加载扩展失败'),
            content: Text(e.toString()),
            severity: fluent.InfoBarSeverity.error,
          ),
        );
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _pickZip() async {
    try {
      final typeGroup = XTypeGroup(label: 'zip', extensions: ['zip']);
      final file = await openFile(acceptedTypeGroups: [typeGroup]);
      if (file == null) return;
      final bytes = await file.readAsBytes();
      final b64 = base64Encode(bytes);
      await ApiClient.instance.post(
        '/api/extensions/install',
        body: {'data': b64, 'filename': file.name},
      );
      await _load();
      if (mounted)
        fluent.displayInfoBar(
          context,
          builder: (c, close) => const fluent.InfoBar(
            title: Text('扩展已安装'),
            severity: fluent.InfoBarSeverity.success,
          ),
        );
    } catch (e) {
      if (mounted)
        fluent.displayInfoBar(
          context,
          builder: (c, close) => fluent.InfoBar(
            title: const Text('安装失败'),
            content: Text(e.toString()),
            severity: fluent.InfoBarSeverity.error,
          ),
        );
    }
  }

  Future<void> _toggle(String id, bool on) async {
    final next = {..._enabled};
    if (on) {
      next.add(id);
    } else {
      next.remove(id);
    }
    try {
      await ApiClient.instance.post(
        '/api/extensions/active',
        body: {'ids': next.toList()},
      );
      await _load();
    } catch (e) {
      if (mounted)
        fluent.displayInfoBar(
          context,
          builder: (c, close) => fluent.InfoBar(
            title: const Text('切换失败'),
            content: Text(e.toString()),
            severity: fluent.InfoBarSeverity.error,
          ),
        );
    }
  }

  Future<void> _remove(String id) async {
    final ok = await fluent.showDialog<bool>(
      context: context,
      builder: (ctx) => AppContentDialog(
        title: const Text('删除扩展'),
        content: Text('确认删除 $id ?'),
        actions: [
          fluent.Button(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          fluent.FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ApiClient.instance.delete('/api/extensions/${Uri.encodeComponent(id)}');
      await _load();
    } catch (e) {
      if (mounted)
        fluent.displayInfoBar(
          context,
          builder: (c, close) => fluent.InfoBar(
            title: const Text('删除失败'),
            content: Text(e.toString()),
            severity: fluent.InfoBarSeverity.error,
          ),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            // 窄侧栏（<300px）时标题可收缩省略，避免与右侧按钮挤爆
            Flexible(
              child: Text(
                '扩展 (Zip)',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  color: palette.textHigh,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const Spacer(),
            fluent.Button(
              onPressed: _loading ? null : _load,
              child: const Icon(FluentIcons.arrow_sync_24_regular, size: 14),
            ),
            const SizedBox(width: 8),
            fluent.FilledButton(
              onPressed: _pickZip,
              child: const Text('加载 Zip 扩展'),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          '将游戏资源打包为 Zip（含 aa_index.json / base_data.json / Cfgs），可在设置中加载，兼容无游戏的 Android/Linux。',
          style: TextStyle(fontSize: 11, color: palette.textMuted),
        ),
        const SizedBox(height: 8),
        if (_loading)
          const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        else if (_packs.isEmpty)
          Text(
            '暂无扩展，可点击“加载 Zip 扩展”',
            style: TextStyle(fontSize: 11, color: palette.textHint),
          )
        else
          ..._packs.map((p) {
            final id = p['id'] is String ? p['id'] as String : '';
            if (id.isEmpty) return const SizedBox.shrink(); // 畸形条目不再让 build 抛错
            final isActive = _enabled.contains(id);
            return Container(
              margin: const EdgeInsets.symmetric(vertical: 4),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: isActive ? palette.card : palette.bg,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: isActive ? accentColor : palette.border,
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    isActive
                        ? FluentIcons.checkmark_circle_24_filled
                        : FluentIcons.box_24_regular,
                    size: 16,
                    color: isActive ? accentColor : palette.textMuted,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          p['name'] as String? ?? id,
                          style: TextStyle(
                            fontSize: 12,
                            color: palette.textHigh,
                          ),
                        ),
                        Text(
                          '$id  ${(p['version'] ?? '').toString()}',
                          style: TextStyle(
                            fontSize: 10,
                            color: palette.textHint,
                          ),
                        ),
                        if ((p['description'] ?? '').toString().isNotEmpty)
                          Text(
                            p['description'] as String,
                            style: TextStyle(
                              fontSize: 10,
                              color: palette.textMuted,
                            ),
                          ),
                      ],
                    ),
                  ),
                  fluent.ToggleSwitch(
                    checked: isActive,
                    onChanged: (v) => _toggle(id, v),
                  ),
                  const SizedBox(width: 4),
                  fluent.Button(
                    onPressed: () => _remove(id),
                    child: const Icon(FluentIcons.delete_24_regular, size: 14),
                  ),
                ],
              ),
            );
          }),
      ],
    );
  }
}

/// 保存校验设置：保存时指南校验错误是否阻止保存。
class _SaveValidateSection extends StatefulWidget {
  const _SaveValidateSection();

  @override
  State<_SaveValidateSection> createState() => _SaveValidateSectionState();
}

class _SaveValidateSectionState extends State<_SaveValidateSection> {
  bool _strict = true; // 默认值与 SaveValidatePrefs 保持一致
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final v = await SaveValidatePrefs.load();
    if (!mounted) return;
    setState(() {
      _strict = v;
      _loaded = true;
    });
  }

  Future<void> _toggle(bool v) async {
    setState(() => _strict = v);
    await SaveValidatePrefs.save(v);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '保存校验',
          style: TextStyle(
            fontSize: 13,
            color: palette.textHigh,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          '保存前调用后端按官方《学生时代》Mod 指南校验当前配置表',
          style: TextStyle(fontSize: 11, color: palette.textMuted),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '保存时指南校验错误阻止保存',
                    style: TextStyle(fontSize: 12, color: palette.textPrimary),
                  ),
                  SizedBox(height: 2),
                  Text(
                    '依据官方《学生时代》Mod 指南；关闭后错误仅在保存结果中提示，不阻止保存',
                    style: TextStyle(fontSize: 11, color: palette.textMuted),
                  ),
                ],
              ),
            ),
            fluent.ToggleSwitch(
              checked: _strict,
              onChanged: _loaded ? _toggle : null,
            ),
          ],
        ),
      ],
    );
  }
}

/// 无代码模式：编辑器共享开关（后端 editor_env.json，GUI/CLI/TUI 读同一份）。
/// 外观（白日/暗色）选择器。
///
/// 与「无代码模式」同款：本机偏好立即生效（SharedPreferences），同时尽力写一份
/// 到后端共享设置，让 TUI / CLI 也跟着变；写失败**不回滚**——本机已生效，
/// 只提示「仅本机生效」，避免用户以为切换失败了。
class _AppearanceSection extends StatefulWidget {
  const _AppearanceSection();

  @override
  State<_AppearanceSection> createState() => _AppearanceSectionState();
}

class _AppearanceSectionState extends State<_AppearanceSection> {
  String _hint = '';
  final _hexCtrl = TextEditingController();

  /// 主题色预设色板：用户可直接点选的强调色种子。
  /// 这些字面量在 light_theme_audit_test 里按文件放行（预设清单必须写死）。
  static const _accentPresets = <(String, Color)>[
    ('品牌蓝', Color(0xFF4F6EF7)),
    ('弗蓝', Color(0xFF0078D4)),
    ('青碧', Color(0xFF00897B)),
    ('森绿', Color(0xFF43A047)),
    ('金褐', Color(0xFFC9A227)),
    ('橙杏', Color(0xFFE67E22)),
    ('珊瑚', Color(0xFFE5484D)),
    ('品红', Color(0xFFD81B60)),
    ('石墨', Color(0xFF616161)),
  ];

  @override
  void dispose() {
    _hexCtrl.dispose();
    super.dispose();
  }

  /// 与 [_pick] 同款：本机立即生效 + 尽力写穿后端，失败不回滚只提示。
  Future<void> _pickAccent(Color seed) async {
    await AppTheme.setAccent(seed);
    if (!mounted) return;
    _hexCtrl.clear();
    try {
      await ApiClient.instance.put(
        '/api/settings/editor',
        body: {'themeColor': AppAccentColor.toHex(seed)},
      );
      if (!mounted) return;
      setState(() => _hint = '');
    } catch (_) {
      // 旧后端没有这个键，或后端不在线：本机主题色已经生效，不打断用户。
      if (!mounted) return;
      setState(() => _hint = '主题色已在本机生效，但共享保存失败（三端可能不同步）');
    }
  }

  void _applyHex() {
    final c = AppAccentColor.parse(_hexCtrl.text);
    if (c == null) {
      setState(() => _hint = 'HEX 格式不正确，请输入如 #4F6EF7 的颜色');
      return;
    }
    _pickAccent(c);
  }

  Future<void> _pick(AppThemeMode m) async {
    await AppTheme.set(m);
    if (!mounted) return;
    try {
      await ApiClient.instance.put(
        '/api/settings/editor',
        body: {'appearanceMode': m.prefsValue},
      );
      if (!mounted) return;
      setState(() => _hint = '');
    } catch (_) {
      // 旧后端没有这个键，或后端不在线：本机外观已经生效，不打断用户。
      if (!mounted) return;
      setState(() => _hint = '已在本机生效，但共享保存失败（三端可能不同步）');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '外观',
          style: TextStyle(
            fontSize: 13,
            color: palette.textHigh,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          '白日模式（亮色）为明亮环境准备：界面转浅底深字，图形元素同步提/降明度',
          style: TextStyle(fontSize: 11, color: palette.textMuted),
        ),
        const SizedBox(height: 2),
        Text(
          '该开关保存在后端，GUI / CLI / TUI 三端共享生效',
          style: TextStyle(fontSize: 11, color: palette.textMuted),
        ),
        const SizedBox(height: 10),
        ListenableBuilder(
          listenable: AppTheme.mode,
          builder: (context, _) => Row(
            children: [
              Expanded(
                child: _StyleCard(
                  title: '跟随系统',
                  desc: '与操作系统的亮暗设置保持一致',
                  icon: FluentIcons.color_24_regular,
                  selected: AppTheme.mode.value == AppThemeMode.system,
                  onTap: () => _pick(AppThemeMode.system),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _StyleCard(
                  title: '亮色',
                  desc: '浅色界面（默认），适合明亮环境',
                  icon: FluentIcons.weather_sunny_24_regular,
                  selected: AppTheme.mode.value == AppThemeMode.light,
                  onTap: () => _pick(AppThemeMode.light),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _StyleCard(
                  title: '暗色',
                  desc: '深色界面，适合夜间使用',
                  icon: FluentIcons.weather_moon_24_regular,
                  selected: AppTheme.mode.value == AppThemeMode.dark,
                  onTap: () => _pick(AppThemeMode.dark),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Text(
          '切换后立即生效并记忆；写入共享设置后，终端（TUI/CLI）下次启动跟随',
          style: TextStyle(fontSize: 11, color: palette.textMuted),
        ),
        const SizedBox(height: 14),
        Text(
          '主题色',
          style: TextStyle(
            fontSize: 13,
            color: palette.textHigh,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          '选中态、焦点框与强调控件随此色联动；自定义色会先做可读性调整，再生成深浅变体',
          style: TextStyle(fontSize: 11, color: palette.textMuted),
        ),
        const SizedBox(height: 10),
        ListenableBuilder(
          listenable: AppTheme.accent,
          builder: (context, _) {
            final seed = AppTheme.accentSeed;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    for (final (label, color) in _accentPresets)
                      Tooltip(
                        message: label,
                        child: GestureDetector(
                          onTap: () => _pickAccent(color),
                          child: Container(
                            width: 28,
                            height: 28,
                            decoration: BoxDecoration(
                              color: color,
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: seed == color
                                    ? palette.textHigh
                                    : palette.border,
                                width: seed == color ? 2 : 1,
                              ),
                            ),
                            child: seed == color
                                ? Icon(
                                    FluentIcons.checkmark_24_regular,
                                    size: 14,
                                    color:
                                        contrastRatio(
                                              color,
                                              const Color(0xFFFFFFFF),
                                            ) >=
                                            4.5
                                        ? const Color(0xFFFFFFFF)
                                        : const Color(0xFF101014),
                                  )
                                : null,
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 10),
                // Wrap 而非 Row：侧栏 264px 下色板/输入框+按钮+状态文字
                // 一行放不下会向右溢出，换行布局自适应窄面板。
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    SizedBox(
                      width: 130,
                      child: fluent.TextBox(
                        controller: _hexCtrl,
                        placeholder: '#4F6EF7',
                        onSubmitted: (_) => _applyHex(),
                      ),
                    ),
                    fluent.Button(
                      onPressed: _applyHex,
                      child: const Text('应用自定义色'),
                    ),
                    if (seed != kDefaultAccent) ...[
                      fluent.Button(
                        onPressed: () => _pickAccent(kDefaultAccent),
                        child: const Text('恢复默认'),
                      ),
                    ],
                    Text(
                      '当前：${AppAccentColor.toHex(seed)}${seed == kDefaultAccent ? '（默认）' : ''}',
                      style: TextStyle(fontSize: 11, color: palette.textMuted),
                    ),
                  ],
                ),
              ],
            );
          },
        ),
        if (_hint.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              _hint,
              style: TextStyle(fontSize: 11, color: palette.warning),
            ),
          ),
      ],
    );
  }
}

class _NoCodeModeSection extends StatefulWidget {
  const _NoCodeModeSection();

  @override
  State<_NoCodeModeSection> createState() => _NoCodeModeSectionState();
}

class _NoCodeModeSectionState extends State<_NoCodeModeSection> {
  bool _on = false;
  bool _loaded = false;
  String _error = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await ApiClient.instance.get('/api/settings/editor');
      if (!mounted) return;
      final s = r is Map ? r['settings'] : null;
      setState(() {
        _on = s is Map && s['noCodeMode'] == true;
        _loaded = true;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '无法读取后端共享设置：$e');
    }
  }

  Future<void> _toggle(bool v) async {
    setState(() => _on = v);
    // 写穿逻辑收在 core/no_code_mode.dart：字段级逃生口（"关闭无代码模式以手动
    // 编辑"）与这里共用同一份"写穿 + 失败回滚"。
    final ok = await persistNoCodeMode(v);
    if (!mounted) return;
    if (!ok) {
      // 写失败回滚开关（旧后端无该端点时保持关闭，不假装生效）
      setState(() {
        _on = !v;
        _error = '保存失败：无法写穿后端共享设置';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '无代码模式',
          style: TextStyle(
            fontSize: 13,
            color: palette.textHigh,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          '开启后无需手写效果码：效果/指令字段点选即用（参数走表单补全），人物字段提供立绘浏览面板',
          style: TextStyle(fontSize: 11, color: palette.textMuted),
        ),
        const SizedBox(height: 2),
        Text(
          '该开关保存在后端，GUI / CLI / TUI 三端共享生效',
          style: TextStyle(fontSize: 11, color: palette.textMuted),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '选人物与效果，不写代码',
                    style: TextStyle(fontSize: 12, color: palette.textPrimary),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '自动补全同时增强：空输入即出候选，最近使用的高频项置顶',
                    style: TextStyle(fontSize: 11, color: palette.textMuted),
                  ),
                ],
              ),
            ),
            fluent.ToggleSwitch(
              checked: _on,
              onChanged: _loaded ? _toggle : null,
            ),
          ],
        ),
        if (_error.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              _error,
              style: TextStyle(fontSize: 11, color: palette.danger),
            ),
          ),
      ],
    );
  }
}

class _StyleCard extends StatelessWidget {
  const _StyleCard({
    required this.title,
    required this.desc,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final String title;
  final String desc;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: selected ? palette.card : palette.bg,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: selected ? accentColor : palette.border,
              width: selected ? 1.5 : 1,
            ),
          ),
          child: Row(
            children: [
              Icon(
                icon,
                size: 18,
                color: selected ? accentColor : palette.textMuted,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 12,
                        color: palette.textHigh,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      desc,
                      style: TextStyle(
                        fontSize: 10,
                        color: palette.textMuted,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
