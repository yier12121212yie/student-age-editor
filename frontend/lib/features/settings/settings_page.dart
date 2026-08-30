import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:file_selector/file_selector.dart';

import '../../core/api_client.dart';
import '../../core/ui_mode.dart';
import '../../core/app_theme.dart';

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

  static const prefsKey = 'ai_settings_v1';

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
      );

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(prefsKey, jsonEncode(toJson()));
    // 写穿三端共享文件 .editor_ai.json（CLI/TUI/GUI 唯一数据源）。
    // 失败只影响终端同步，不阻塞本地保存。
    try {
      await ApiClient.instance
          .put('/api/ai/settings', body: toJson())
          .timeout(const Duration(seconds: 5));
      await prefs.setBool(remoteMigratedFlag, true);
    } catch (_) {}
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
      final raw = (r is Map ? r['settings'] : null) as Map<String, dynamic>? ?? {};
      final remote = AiSettings.fromJson(raw);
      if (meaningful(remote)) {
        await _cachePrefs(remote);
        return remote;
      }
      if (meaningful(local)) {
        final prefs = await SharedPreferences.getInstance();
        if (prefs.getBool(remoteMigratedFlag) != true) {
          try {
            await ApiClient.instance
                .put('/api/ai/settings', body: local.toJson())
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
  });
  final AiSettings settings;
  final ValueChanged<AiSettings> onChanged;

  /// 界面风格（可为空：不展示风格切换区块）。
  final UiMode? uiMode;
  final ValueChanged<UiMode>? onUiModeChanged;
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
  String _provider = 'openai_compatible';
  double _temperature = 0.7;
  String _ttsProvider = '';
  double _ttsSpeed = 1.0;
  bool _ttsTesting = false;
  String _permissionMode = 'confirm';

  @override
  void initState() {
    super.initState();
    _provider = widget.settings.provider;
    _baseUrlCtrl = TextEditingController(text: widget.settings.baseUrl);
    _apiKeyCtrl = TextEditingController(text: widget.settings.apiKey);
    _modelCtrl = TextEditingController(text: widget.settings.model);
    _imageModelCtrl = TextEditingController(text: widget.settings.imageModel);
    _imageApiKeyCtrl = TextEditingController(text: widget.settings.imageApiKey);
    _imageBaseUrlCtrl = TextEditingController(text: widget.settings.imageBaseUrl);
    _ttsProvider = widget.settings.ttsProvider;
    _ttsApiKeyCtrl = TextEditingController(text: widget.settings.ttsApiKey);
    _ttsGroupIdCtrl = TextEditingController(text: widget.settings.ttsGroupId);
    _ttsModelCtrl = TextEditingController(text: widget.settings.ttsModel);
    _ttsBaseUrlCtrl = TextEditingController(text: widget.settings.ttsBaseUrl);
    _ttsVoiceCtrl = TextEditingController(text: widget.settings.ttsVoice);
    _ttsSpeed = widget.settings.ttsSpeed.clamp(0.5, 2.0);
    _temperature = widget.settings.temperature;
    _permissionMode = widget.settings.permissionMode;
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
      final r = await ApiClient.instance
          .post('/api/tts/test',
              body: {'provider': _ttsProvider, 'settings': _ttsSettingsMap()})
          .timeout(const Duration(seconds: 60));
      final ok = r['ok'] == true;
      if (!mounted) return;
      fluent.displayInfoBar(context,
          builder: (ctx, close) => fluent.InfoBar(
              title: Text(ok ? '配音服务连接成功' : '配音服务连接失败'),
              content: Text(ok
                  ? (r['detail']?.toString() ?? '')
                  : (r['error']?.toString() ?? '未知错误')),
              severity: ok
                  ? fluent.InfoBarSeverity.success
                  : fluent.InfoBarSeverity.error));
    } catch (e) {
      if (mounted) {
        fluent.displayInfoBar(context,
            builder: (ctx, close) => fluent.InfoBar(
                title: const Text('配音服务连接失败'),
                content: Text(e.toString()),
                severity: fluent.InfoBarSeverity.error));
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
    );
    await s.save();
    widget.onChanged(s);
    if (mounted) {
      fluent.displayInfoBar(context,
          builder: (ctx, close) => const fluent.InfoBar(
              title: Text('已保存 AI 配置'), severity: fluent.InfoBarSeverity.success));
    }
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
          child: Text('设置',
              style: TextStyle(fontSize: 12, color: palette.textSecondary, fontWeight: FontWeight.w600)),
        ),
        Divider(height: 1, color: palette.border),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('AI 服务',
                    style: TextStyle(fontSize: 13, color: palette.textHigh, fontWeight: FontWeight.w600)),
                const SizedBox(height: 12),
                Text('接口协议', style: TextStyle(fontSize: 12, color: hintColor)),
                const SizedBox(height: 6),
                fluent.ComboBox<String>(
                  value: _provider,
                  isExpanded: true,
                  items: const [
                    fluent.ComboBoxItem(
                        value: 'openai_compatible',
                        child: Text('OpenAI Compatible',
                            maxLines: 1, overflow: TextOverflow.ellipsis)),
                    fluent.ComboBoxItem(
                        value: 'openai_responses',
                        child: Text('OpenAI Responses API',
                            maxLines: 1, overflow: TextOverflow.ellipsis)),
                    fluent.ComboBoxItem(
                        value: 'anthropic',
                        child: Text('Anthropic Compatible',
                            maxLines: 1, overflow: TextOverflow.ellipsis)),
                  ],
                  onChanged: (v) => setState(() => _provider = v ?? _provider),
                ),
                const SizedBox(height: 12),
                Text('Base URL（留空使用官方默认）',
                    style: TextStyle(fontSize: 12, color: hintColor)),
                const SizedBox(height: 4),
                Text('接口地址，通常保持默认即可；使用自建代理或中转服务时才需修改',
                    style: TextStyle(fontSize: 11, color: palette.textMuted)),
                const SizedBox(height: 6),
                fluent.TextBox(
                  controller: _baseUrlCtrl,
                  placeholder: 'https://api.openai.com/v1',
                  onChanged: (_) {},
                ),
                const SizedBox(height: 12),
                Text('API Key', style: TextStyle(fontSize: 12, color: hintColor)),
                const SizedBox(height: 4),
                Text('调用 AI 服务所需的密钥，在服务商控制台获取；仅保存在本机',
                    style: TextStyle(fontSize: 11, color: palette.textMuted)),
                const SizedBox(height: 6),
                fluent.TextBox(
                  controller: _apiKeyCtrl,
                  obscureText: true,
                  placeholder: 'sk-...',
                ),
                const SizedBox(height: 12),
                Text('模型', style: TextStyle(fontSize: 12, color: hintColor)),
                const SizedBox(height: 4),
                Text('选择或填写要使用的模型名称；留空则使用所选接口协议的默认模型',
                    style: TextStyle(fontSize: 11, color: palette.textMuted)),
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
                Text('变更前确认：AI 的每次写入/删除/生图都会弹出审批框；'
                    '完全访问：AI 直接执行修改，不再弹出确认框',
                    style: TextStyle(fontSize: 11, color: palette.textMuted)),
                const SizedBox(height: 6),
                fluent.ComboBox<String>(
                  value: _permissionMode == 'full' ? 'full' : 'confirm',
                  isExpanded: true,
                  items: const [
                    fluent.ComboBoxItem(
                        value: 'confirm',
                        child: Text('变更前确认（每次修改弹出审批框）')),
                    fluent.ComboBoxItem(
                        value: 'full',
                        child: Text('完全访问（不再弹出确认框，AI 直接修改）')),
                  ],
                  onChanged: (v) =>
                      setState(() => _permissionMode = v ?? _permissionMode),
                ),
                const SizedBox(height: 20),
                Divider(color: palette.border),
                const SizedBox(height: 8),
                Text('图片生成（openai-image-api）',
                    style: TextStyle(fontSize: 13, color: palette.textHigh, fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                Text('供 AI 侧栏的生图 / 改图工具调用，遵循 OpenAI Images API 标准（images/generations、images/edits）。'
                    '留空时自动复用上方对话配置；使用 Anthropic 等非 OpenAI 接口时请单独填写',
                    style: TextStyle(fontSize: 11, color: palette.textMuted)),
                const SizedBox(height: 12),
                Text('图片模型', style: TextStyle(fontSize: 12, color: hintColor)),
                const SizedBox(height: 6),
                fluent.TextBox(
                  controller: _imageModelCtrl,
                  placeholder: 'gpt-image-2 / gpt-image-1 / dall-e-3（留空使用对话模型）',
                  onChanged: (_) {},
                ),
                const SizedBox(height: 12),
                Text('图片 API Key', style: TextStyle(fontSize: 12, color: hintColor)),
                const SizedBox(height: 6),
                fluent.TextBox(
                  controller: _imageApiKeyCtrl,
                  obscureText: true,
                  placeholder: 'sk-...（留空复用对话 API Key）',
                ),
                const SizedBox(height: 12),
                Text('图片 Base URL（留空使用对话地址或官方默认）',
                    style: TextStyle(fontSize: 12, color: hintColor)),
                const SizedBox(height: 6),
                fluent.TextBox(
                  controller: _imageBaseUrlCtrl,
                  placeholder: 'https://api.openai.com/v1',
                  onChanged: (_) {},
                ),
                const SizedBox(height: 20),
                Divider(color: palette.border),
                const SizedBox(height: 8),
                Text('配音（TTS）',
                    style: TextStyle(fontSize: 13, color: palette.textHigh, fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                Text('为剧本/文本合成语音：阿里云（DashScope 百炼，Bearer sk-*）或 MiniMax（T2A V2）。'
                    '密钥仅保存在本机；生成内容存到当前 mod 的 audio/tts/ 目录',
                    style: TextStyle(fontSize: 11, color: palette.textMuted)),
                const SizedBox(height: 12),
                Text('服务商', style: TextStyle(fontSize: 12, color: hintColor)),
                const SizedBox(height: 6),
                fluent.ComboBox<String>(
                  value: _ttsProvider,
                  isExpanded: true,
                  items: const [
                    fluent.ComboBoxItem(
                        value: '', child: Text('未配置（在配音面板中按需选择）')),
                    fluent.ComboBoxItem(
                        value: 'aliyun', child: Text('阿里云 DashScope（百炼）')),
                    fluent.ComboBoxItem(
                        value: 'minimax', child: Text('MiniMax（T2A V2）')),
                  ],
                  onChanged: (v) => setState(() => _ttsProvider = v ?? ''),
                ),
                const SizedBox(height: 12),
                Text('API Key', style: TextStyle(fontSize: 12, color: hintColor)),
                const SizedBox(height: 6),
                fluent.TextBox(
                  controller: _ttsApiKeyCtrl,
                  obscureText: true,
                  placeholder: 'sk-...（阿里云）或 MiniMax API Key',
                ),
                if (_ttsProvider == 'minimax') ...[
                  const SizedBox(height: 12),
                  Text('Group ID（MiniMax 控制台获取）',
                      style: TextStyle(fontSize: 12, color: hintColor)),
                  const SizedBox(height: 6),
                  fluent.TextBox(
                    controller: _ttsGroupIdCtrl,
                    placeholder: '19xxxxxxxxxxxxxxxxxxxxxxxxxxxxxx',
                  ),
                ],
                const SizedBox(height: 12),
                Text('模型（留空使用默认）',
                    style: TextStyle(fontSize: 12, color: hintColor)),
                const SizedBox(height: 6),
                fluent.TextBox(
                  controller: _ttsModelCtrl,
                  placeholder: 'qwen-tts / cosyvoice-v2 / speech-02-hd',
                ),
                const SizedBox(height: 12),
                Text('默认音色（留空使用服务商默认）',
                    style: TextStyle(fontSize: 12, color: hintColor)),
                const SizedBox(height: 6),
                fluent.TextBox(
                  controller: _ttsVoiceCtrl,
                  placeholder: 'Cherry / female-shaonv / 其他 voice id',
                ),
                const SizedBox(height: 12),
                Text('Base URL（留空使用官方默认；自建代理/中转时才需修改）',
                    style: TextStyle(fontSize: 12, color: hintColor)),
                const SizedBox(height: 6),
                fluent.TextBox(
                  controller: _ttsBaseUrlCtrl,
                  placeholder: _ttsProvider == 'minimax'
                      ? 'https://api.minimax.chat'
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
                Row(children: [
                  fluent.Button(
                    onPressed:
                        (_ttsTesting || _ttsProvider.isEmpty) ? null : _ttsTest,
                    child: _ttsTesting
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Text('测试连接'),
                  ),
                  const SizedBox(width: 8),
                  if (_ttsProvider.isEmpty)
                    Expanded(
                        child: Text('先选择服务商并填写 API Key 再测试',
                            style:
                                TextStyle(fontSize: 11, color: palette.textMuted))),
                ]),
                const SizedBox(height: 16),
                fluent.FilledButton(
                  onPressed: _save,
                  child: const Text('保存配置'),
                ),
                if (widget.uiMode != null && widget.onUiModeChanged != null) ...[
                  const SizedBox(height: 24),
                  Divider(color: palette.border),
                  const SizedBox(height: 8),
                  Text('界面风格',
                      style: TextStyle(fontSize: 13, color: palette.textHigh, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: _StyleCard(
                          title: '创作',
                          desc: '图标活动栏 + 侧边栏 + 标签编辑区（当前默认）',
                          icon: FluentIcons.paint_brush_24_regular,
                          selected: widget.uiMode == UiMode.creation,
                          onTap: () => widget.onUiModeChanged!(UiMode.creation),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _StyleCard(
                          title: '经典',
                          desc: '顶部工具栏 + 左侧分组导航（传统桌面风格）',
                          icon: FluentIcons.list_24_regular,
                          selected: widget.uiMode == UiMode.classic,
                          onTap: () => widget.onUiModeChanged!(UiMode.classic),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text('切换后立即生效，已打开的文档与 AI 配置会保留',
                      style: TextStyle(fontSize: 11, color: palette.textMuted)),
                ],
                const SizedBox(height: 24),
                Divider(color: palette.border),
                const SizedBox(height: 8),
                Text('外观',
                    style: TextStyle(fontSize: 13, color: palette.textHigh, fontWeight: FontWeight.w600)),
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
                          onTap: () => AppTheme.set(AppThemeMode.system),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _StyleCard(
                          title: '亮色',
                          desc: '浅色界面，适合明亮环境',
                          icon: FluentIcons.weather_sunny_24_regular,
                          selected: AppTheme.mode.value == AppThemeMode.light,
                          onTap: () => AppTheme.set(AppThemeMode.light),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _StyleCard(
                          title: '暗色',
                          desc: '深色界面（默认），适合夜间使用',
                          icon: FluentIcons.weather_moon_24_regular,
                          selected: AppTheme.mode.value == AppThemeMode.dark,
                          onTap: () => AppTheme.set(AppThemeMode.dark),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                Text('切换后立即生效并记忆，下次启动保持所选外观',
                    style: TextStyle(fontSize: 11, color: palette.textMuted)),
                const SizedBox(height: 24),
                Divider(color: palette.border),
                const SizedBox(height: 8),
                const _SaveValidateSection(),
                const SizedBox(height: 24),
                Divider(color: palette.border),
                const SizedBox(height: 8),
                const _ResourcePackSection(),
const SizedBox(height: 24),
                Divider(color: palette.border),
                const SizedBox(height: 8),
                Text('关于',
                    style: TextStyle(fontSize: 13, color: palette.textHigh, fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                Text('学生时代模组编辑器 · Flutter 前端\n'
                    '核心引擎：Python + UnityPy + Steamworks\n'
                    'UI：Fluent 2 设计语言（创作布局 + 经典布局）',
                    style: TextStyle(fontSize: 12, color: hintColor, height: 1.6)),
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
  String _active = "";
  bool _loading = true;
  @override
  void initState() { super.initState(); _load(); }
  Future<void> _load() async {
    setState(()=>_loading=true);
    try {
      final r = await ApiClient.instance.get('/api/resource_packs');
      setState((){ _packs = (r['packs'] as List?) ?? []; _active = r['active'] as String? ?? ""; });
    } catch (e) {
      if (mounted) fluent.displayInfoBar(context, builder: (c,close)=>fluent.InfoBar(title: const Text('加载扩展失败'), content: Text(e.toString()), severity: fluent.InfoBarSeverity.error));
    } finally { setState(()=>_loading=false); }
  }
  Future<void> _pickZip() async {
    try {
      final typeGroup = XTypeGroup(label: 'zip', extensions: ['zip']);
      final file = await openFile(acceptedTypeGroups: [typeGroup]);
      if (file==null) return;
      final bytes = await file.readAsBytes();
      final b64 = base64Encode(bytes);
      await ApiClient.instance.post('/api/resource_packs/install', body: {'zip_base64': b64, 'filename': file.name});
      await _load();
      if (mounted) fluent.displayInfoBar(context, builder: (c,close)=>const fluent.InfoBar(title: Text('扩展已安装'), severity: fluent.InfoBarSeverity.success));
    } catch (e) {
      if (mounted) fluent.displayInfoBar(context, builder: (c,close)=>fluent.InfoBar(title: const Text('安装失败'), content: Text(e.toString()), severity: fluent.InfoBarSeverity.error));
    }
  }
  Future<void> _activate(String id) async {
    try {
      await ApiClient.instance.post('/api/resource_packs/active', body: {'id': id});
      await _load();
    } catch (e) { if (mounted) fluent.displayInfoBar(context, builder: (c,close)=>fluent.InfoBar(title: const Text('切换失败'), content: Text(e.toString()), severity: fluent.InfoBarSeverity.error)); }
  }
  Future<void> _remove(String id) async {
    final ok = await fluent.showDialog<bool>(context: context, builder: (ctx)=>fluent.ContentDialog(title: const Text('删除扩展'), content: Text('确认删除 $id ?'), actions: [fluent.Button(onPressed: ()=>Navigator.pop(ctx,false), child: const Text('取消')), fluent.FilledButton(onPressed: ()=>Navigator.pop(ctx,true), child: const Text('删除'))]));
    if (ok!=true) return;
    try { await ApiClient.instance.delete('/api/resource_packs/$id'); await _load(); } catch (e) { if (mounted) fluent.displayInfoBar(context, builder: (c,close)=>fluent.InfoBar(title: const Text('删除失败'), content: Text(e.toString()), severity: fluent.InfoBarSeverity.error)); }
  }
  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children:[
        // 窄侧栏（<300px）时标题可收缩省略，避免与右侧按钮挤爆
        Flexible(
          child: Text('资源扩展 (Zip)', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize:13, color: palette.textHigh, fontWeight: FontWeight.w600)),
        ),
        const Spacer(),
        fluent.Button(onPressed: _loading? null : _load, child: const Icon(FluentIcons.arrow_sync_24_regular, size:14)),
        const SizedBox(width:8),
        fluent.FilledButton(onPressed: _pickZip, child: const Text('加载 Zip 扩展')),
      ]),
      const SizedBox(height:4),
      Text('将游戏资源打包为 Zip（含 aa_index.json / base_data.json / Cfgs），可在设置中加载，兼容无游戏的 Android/Linux。', style: TextStyle(fontSize:11, color: palette.textMuted)),
      const SizedBox(height:8),
      if (_loading) const SizedBox(width:16,height:16, child: CircularProgressIndicator(strokeWidth:2))
      else if (_packs.isEmpty) Text('暂无扩展，可点击“加载 Zip 扩展”', style: TextStyle(fontSize:11, color: palette.textHint))
      else ..._packs.map((p){
        final id = p['id'] as String; final isActive = id==_active;
        return Container(margin: const EdgeInsets.symmetric(vertical:4), padding: const EdgeInsets.all(8), decoration: BoxDecoration(color: isActive? palette.card: palette.bg, borderRadius: BorderRadius.circular(6), border: Border.all(color: isActive? const Color(0xFF6C5CE7): palette.border)), child: Row(children:[
          Icon(isActive? FluentIcons.checkmark_circle_24_filled : FluentIcons.box_24_regular, size:16, color: isActive? const Color(0xFF6C5CE7): palette.textMuted),
          const SizedBox(width:8),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children:[
            Text(p['name'] as String? ?? id, style: TextStyle(fontSize:12, color: palette.textHigh)),
            Text('$id  ${p['version'] ?? ''}  ${p['files'] ?? 0} 文件', style: TextStyle(fontSize:10, color: palette.textHint)),
            if ((p['description']??'').toString().isNotEmpty) Text(p['description'] as String, style: TextStyle(fontSize:10, color: palette.textMuted)),
          ])),
          if (!isActive) fluent.Button(onPressed: ()=>_activate(id), child: const Text('启用')),
          if (isActive) const Padding(padding: EdgeInsets.symmetric(horizontal:8), child: Text('已启用', style: TextStyle(fontSize:11, color: Color(0xFF6C5CE7)))),
          const SizedBox(width:4),
          fluent.Button(onPressed: ()=>_remove(id), child: const Icon(FluentIcons.delete_24_regular, size:14)),
        ]));
      }),
    ]);
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
        Text('保存校验',
            style: TextStyle(fontSize: 13, color: palette.textHigh, fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        Text('保存前调用后端按官方《学生时代》Mod 指南校验当前配置表',
            style: TextStyle(fontSize: 11, color: palette.textMuted)),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('保存时指南校验错误阻止保存',
                      style: TextStyle(fontSize: 12, color: palette.textPrimary)),
                  SizedBox(height: 2),
                  Text('依据官方《学生时代》Mod 指南；关闭后错误仅在保存结果中提示，不阻止保存',
                      style: TextStyle(fontSize: 11, color: palette.textMuted)),
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
                color: selected ? const Color(0xFF6C5CE7) : palette.border,
                width: selected ? 1.5 : 1),
          ),
          child: Row(
            children: [
              Icon(icon, size: 18, color: selected ? const Color(0xFF6C5CE7) : palette.textMuted),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: TextStyle(
                            fontSize: 12, color: palette.textHigh, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    Text(desc,
                        style: TextStyle(fontSize: 10, color: palette.textMuted, height: 1.4)),
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
