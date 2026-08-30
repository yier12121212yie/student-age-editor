import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../../core/api_client.dart';
import '../../core/motion.dart';
import '../../core/responsive.dart';
import '../../core/ui_mode.dart';
import '../settings/settings_page.dart';
import '../../core/app_theme.dart';

/// 首次使用引导页（OOBE）。
///
/// 首次访问自动显示，也可用启动参数 --oobe 强制开启。
/// 步骤（均为可选，下一步即跳过）：欢迎 → 工作区 → 首个 Mod → AI 助手
/// → TTS 配音 → 界面风格 → 云存储 → 完成提交。
/// 完成或跳过都会写入后端共享标记（editor_env.json 的 oobe_completed），
/// 与 CLI / TUI 共用，任一端完成后不再自动弹出。
class OobePage extends StatefulWidget {
  const OobePage({
    super.key,
    required this.onFinished,
    this.forced = false,
    this.onUiModeChanged,
  });

  /// 完成引导后的回调（应用侧重新加载状态并进入主界面）。
  final VoidCallback onFinished;

  /// 是否由 --oobe 强制开启（仅影响文案）。
  final bool forced;

  /// 界面风格变更回调（应用侧持久化并立即切换）；为空时由本页兜底保存。
  final Future<void> Function(UiMode)? onUiModeChanged;

  @override
  State<OobePage> createState() => _OobePageState();
}

class _OobePageState extends State<OobePage> {
  static const accent = Color(0xFF6C5CE7);
  static Color get hintColor => palette.textMuted;
  static const _totalSteps = 7; // 欢迎·工作区·Mod·AI·TTS·风格·云

  int _step = 0;
  bool _busy = false;

  // 来自后端状态
  String _suggestedWorkspace = '';
  int _modsCount = 0;

  // 工作区步骤
  bool _useRecommended = true;
  late final TextEditingController _wsCtrl;
  String? _wsError;

  // 首个 Mod 步骤
  late final TextEditingController _modCtrl;
  late final TextEditingController _descCtrl;
  String? _modError;

  // AI 助手步骤
  String _aiProvider = 'openai_compatible';
  late final TextEditingController _aiBaseUrlCtrl;
  late final TextEditingController _aiApiKeyCtrl;
  late final TextEditingController _aiModelCtrl;
  double _aiTemp = 0.7;

  // TTS 配音步骤
  String _ttsProvider = '';
  late final TextEditingController _ttsApiKeyCtrl;
  late final TextEditingController _ttsGroupIdCtrl;
  late final TextEditingController _ttsModelCtrl;
  late final TextEditingController _ttsVoiceCtrl;
  double _ttsSpeed = 1.0;

  // 界面风格步骤
  late UiMode _uiMode = UiMode.creation;
  late UiMode _uiModeInitial = UiMode.creation;

  // 云存储步骤
  String _cloudType = 'local';
  late final TextEditingController _cloudNameCtrl;
  late final TextEditingController _cloudUrlCtrl; // webdav / openlist 地址
  late final TextEditingController _cloudRootCtrl; // local 根目录
  late final TextEditingController _cloudUserCtrl;
  late final TextEditingController _cloudPassCtrl;
  late final TextEditingController _cloudTokenCtrl;
  late final TextEditingController _cloudRemoteCtrl;
  bool _cloudTesting = false;
  String? _cloudTestMsg;

  @override
  void initState() {
    super.initState();
    _wsCtrl = TextEditingController();
    _modCtrl = TextEditingController();
    _descCtrl = TextEditingController();
    _aiBaseUrlCtrl = TextEditingController();
    _aiApiKeyCtrl = TextEditingController();
    _aiModelCtrl = TextEditingController();
    _ttsApiKeyCtrl = TextEditingController();
    _ttsGroupIdCtrl = TextEditingController();
    _ttsModelCtrl = TextEditingController();
    _ttsVoiceCtrl = TextEditingController();
    _cloudNameCtrl = TextEditingController();
    _cloudUrlCtrl = TextEditingController();
    _cloudRootCtrl = TextEditingController();
    _cloudUserCtrl = TextEditingController();
    _cloudPassCtrl = TextEditingController();
    _cloudTokenCtrl = TextEditingController();
    _cloudRemoteCtrl = TextEditingController(text: 'mods');
    _loadStatus();
    _prefillSettings();
  }

  @override
  void dispose() {
    _wsCtrl.dispose();
    _modCtrl.dispose();
    _descCtrl.dispose();
    _aiBaseUrlCtrl.dispose();
    _aiApiKeyCtrl.dispose();
    _aiModelCtrl.dispose();
    _ttsApiKeyCtrl.dispose();
    _ttsGroupIdCtrl.dispose();
    _ttsModelCtrl.dispose();
    _ttsVoiceCtrl.dispose();
    _cloudNameCtrl.dispose();
    _cloudUrlCtrl.dispose();
    _cloudRootCtrl.dispose();
    _cloudUserCtrl.dispose();
    _cloudPassCtrl.dispose();
    _cloudTokenCtrl.dispose();
    _cloudRemoteCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadStatus() async {
    try {
      final st = await ApiClient.instance.get('/api/oobe/status')
          .timeout(const Duration(seconds: 10));
      if (!mounted) return;
      setState(() {
        _suggestedWorkspace = (st['suggested_workspace'] as String?) ?? '';
        _modsCount = (st['mods_count'] as num?)?.toInt() ?? 0;
        final persisted = (st['workspace_root'] as String?) ?? '';
        if (persisted.isNotEmpty) {
          _wsCtrl.text = persisted;
        }
      });
    } catch (_) {
      // 状态获取失败不阻塞引导，使用默认值继续
    }
    if (!mounted) return;
    setState(() {
      if (_wsCtrl.text.isEmpty && _suggestedWorkspace.isNotEmpty) {
        _wsCtrl.text = _suggestedWorkspace;
      }
    });
  }

  /// 用本机已保存的 AI / 界面风格配置预填各步骤。
  Future<void> _prefillSettings() async {
    final ai = await AiSettings.load();
    final mode = await UiMode.load();
    if (!mounted) return;
    setState(() {
      _aiProvider = ai.provider;
      _aiBaseUrlCtrl.text = ai.baseUrl;
      _aiApiKeyCtrl.text = ai.apiKey;
      _aiModelCtrl.text = ai.model;
      _aiTemp = ai.temperature;
      _ttsProvider = ai.ttsProvider;
      _ttsApiKeyCtrl.text = ai.ttsApiKey;
      _ttsGroupIdCtrl.text = ai.ttsGroupId;
      _ttsModelCtrl.text = ai.ttsModel;
      _ttsVoiceCtrl.text = ai.ttsVoice;
      _ttsSpeed = ai.ttsSpeed.clamp(0.5, 2.0);
      _uiMode = mode;
      _uiModeInitial = mode;
    });
  }

  void _toast(String msg, {fluent.InfoBarSeverity severity = fluent.InfoBarSeverity.success}) {
    if (!mounted) return;
    fluent.displayInfoBar(
      context,
      builder: (ctx, close) => fluent.InfoBar(title: Text(msg), severity: severity),
    );
  }

  bool get _recommendedWorkspace =>
      _useRecommended || _wsCtrl.text.trim().isEmpty;

  String get _effectiveWorkspace => _useRecommended || _wsCtrl.text.trim().isEmpty
      ? _suggestedWorkspace
      : _wsCtrl.text.trim();

  /// AI / TTS 有任一输入时返回待保存的配置，否则返回 null（前端保存 + 写穿
  /// /api/ai/settings；生图等未编辑字段沿用既有配置，避免误覆盖）。
  Future<AiSettings?> _collectAiSettings() async {
    final base = await AiSettings.load();
    final ai = AiSettings(
      provider: _aiProvider,
      baseUrl: _aiBaseUrlCtrl.text.trim(),
      apiKey: _aiApiKeyCtrl.text.trim(),
      model: _aiModelCtrl.text.trim(),
      temperature: _aiTemp,
      imageModel: base.imageModel,
      imageApiKey: base.imageApiKey,
      imageBaseUrl: base.imageBaseUrl,
      ttsProvider: _ttsProvider,
      ttsApiKey: _ttsApiKeyCtrl.text.trim(),
      ttsBaseUrl: base.ttsBaseUrl,
      ttsModel: _ttsModelCtrl.text.trim(),
      ttsVoice: _ttsVoiceCtrl.text.trim(),
      ttsGroupId: _ttsGroupIdCtrl.text.trim(),
      ttsSpeed: _ttsSpeed,
      ttsVolume: base.ttsVolume,
      ttsPitch: base.ttsPitch,
      ttsFormat: base.ttsFormat,
    );
    final any = ai.apiKey.isNotEmpty ||
        ai.baseUrl.isNotEmpty ||
        ai.model.isNotEmpty ||
        ai.ttsProvider.isNotEmpty ||
        ai.ttsApiKey.isNotEmpty ||
        ai.ttsGroupId.isNotEmpty ||
        ai.ttsModel.isNotEmpty ||
        ai.ttsVoice.isNotEmpty;
    return any ? ai : null;
  }

  /// 云存储配置：必填项缺失返回 null（跳过该步）。
  Map<String, dynamic>? get _cloudProvider {
    final cfg = <String, dynamic>{};
    switch (_cloudType) {
      case 'local':
        final root = _cloudRootCtrl.text.trim();
        if (root.isEmpty) return null;
        cfg['root'] = root;
      case 'webdav':
        final url = _cloudUrlCtrl.text.trim();
        if (url.isEmpty) return null;
        cfg['url'] = url;
        if (_cloudUserCtrl.text.trim().isNotEmpty) {
          cfg['username'] = _cloudUserCtrl.text.trim();
        }
        if (_cloudPassCtrl.text.isNotEmpty) {
          cfg['password'] = _cloudPassCtrl.text;
        }
      case 'openlist':
        final url = _cloudUrlCtrl.text.trim();
        if (url.isEmpty) return null;
        cfg['url'] = url;
        if (_cloudTokenCtrl.text.trim().isNotEmpty) {
          cfg['token'] = _cloudTokenCtrl.text.trim();
        }
    }
    return {
      'name': _cloudNameCtrl.text.trim().isEmpty
          ? _cloudType
          : _cloudNameCtrl.text.trim(),
      'type': _cloudType,
      'config': cfg,
      'remote_root': _cloudRemoteCtrl.text.trim().isEmpty
          ? 'mods'
          : _cloudRemoteCtrl.text.trim(),
    };
  }

  Future<void> _cloudTest() async {
    final provider = _cloudProvider;
    final config = (provider?['config'] as Map?) ?? const {};
    if (provider == null || config.isEmpty) {
      _toast('请先填写所选类型的必填项', severity: fluent.InfoBarSeverity.warning);
      return;
    }
    setState(() {
      _cloudTesting = true;
      _cloudTestMsg = null;
    });
    try {
      final r = await ApiClient.instance.post('/api/cloud/test', body: {
        'type': provider['type'],
        'config': config,
      }).timeout(const Duration(seconds: 20));
      if (!mounted) return;
      setState(() =>
          _cloudTestMsg = (r is Map && r['ok'] == true) ? '连接成功' : '连接失败');
    } catch (e) {
      if (!mounted) return;
      setState(() => _cloudTestMsg = '连接失败：$e');
    } finally {
      if (mounted) setState(() => _cloudTesting = false);
    }
  }

  Future<void> _next() async {
    switch (_step) {
      case 0:
        setState(() => _step = 1);
        return;
      case 1:
        if (!_useRecommended && _wsCtrl.text.trim().isEmpty) {
          setState(() => _wsError = '请输入工作区路径，或选择推荐位置');
          return;
        }
        setState(() {
          _wsError = null;
          _step = 2;
        });
        return;
      default:
        if (_step == _totalSteps - 1) {
          await _finish(setupMod: true);
        } else {
          setState(() => _step += 1);
        }
        return;
    }
  }

  Future<void> _finish({required bool setupMod}) async {
    final modTitle = _modCtrl.text.trim();
    if (setupMod && modTitle.contains(RegExp(r'[\\/:*?"<>|\x00-\x1f]'))) {
      setState(() => _modError = '模组名不能包含 \\ / : * ? " < > | 等字符');
      return;
    }
    setState(() {
      _modError = null;
      _busy = true;
    });
    try {
      if (setupMod) {
        // AI / TTS：有输入才落盘（本地缓存 + 写穿 .editor_ai.json）
        final ai = await _collectAiSettings();
        if (ai != null) await ai.save();
        // 界面风格：有变更才切换（回调由应用侧持久化并立即生效）
        if (_uiMode != _uiModeInitial) {
          await (widget.onUiModeChanged?.call(_uiMode) ?? _uiMode.save());
        }
        await ApiClient.instance.post('/api/oobe/setup', body: {
          if (_effectiveWorkspace.isNotEmpty) 'workspace': _effectiveWorkspace,
          if (modTitle.isNotEmpty) 'mod_title': modTitle,
          if (_descCtrl.text.trim().isNotEmpty) 'mod_desc': _descCtrl.text.trim(),
          if (_cloudProvider != null) 'cloud_provider': _cloudProvider,
        }).timeout(const Duration(seconds: 30));
      } else {
        // 全部跳过：只写完成标记
        await ApiClient.instance.post('/api/oobe/complete', body: {})
            .timeout(const Duration(seconds: 10));
      }
      if (!mounted) return;
      _busy = false;
      widget.onFinished();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _modError = e.toString();
      });
      _toast('操作失败：$e', severity: fluent.InfoBarSeverity.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final mobile = isMobileWidth(context);
    final size = MediaQuery.sizeOf(context);
    final cardWidth = mobile ? size.width - 24 : 520.0;
    final cardMaxHeight = mobile ? size.height - 16 : 560.0;
    return Scaffold(
      backgroundColor: palette.bgDeep,
      body: SafeArea(
        child: Center(
          child: Container(
            width: cardWidth,
            constraints: BoxConstraints(maxHeight: cardMaxHeight),
            padding: mobile
                ? const EdgeInsets.fromLTRB(20, 18, 20, 14)
                : const EdgeInsets.all(28),
            decoration: BoxDecoration(
              color: palette.bg,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: palette.border),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildHeader(mobile),
                Expanded(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 240),
                    child: _buildStep(_step),
                  ),
                ),
                _buildNavBar(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 顶栏：桌面端标题与步骤指示器同行；窄屏下上下分置，避免横向溢出。
  Widget _buildHeader(bool mobile) {
    final title = Text(
        widget.forced ? 'OOBE 首次使用引导 (--oobe)' : '首次使用引导',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 11, color: hintColor));
    if (mobile) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          title,
          const SizedBox(height: 10),
          _stepIndicator(),
        ],
      );
    }
    return Row(
      children: [
        title,
        const Spacer(),
        _stepIndicator(),
      ],
    );
  }

  /// 横向步骤指示器（`_totalSteps` 段点），用 Wrap 保证窄屏下可换行不溢出。
  Widget _stepIndicator() {
    return Wrap(
      spacing: 4,
      runSpacing: 4,
      children: List.generate(_totalSteps, (i) {
        final active = i <= _step;
        return Container(
          width: active ? 20 : 6,
          height: 6,
          decoration: BoxDecoration(
            color: active ? accent : palette.borderHover,
            borderRadius: BorderRadius.circular(3),
          ),
        );
      }),
    );
  }

  Widget _buildStep(int step) {
    switch (step) {
      case 0:
        return SingleChildScrollView(
          key: const ValueKey('oobe-welcome'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 12),
              const Center(child: ScaleFade(child: Icon(FluentIcons.sparkle_48_regular, size: 44, color: accent))),
              const SizedBox(height: 14),
              Center(
                child: Text('欢迎使用 学生时代 · 模组编辑器',
                    style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700, color: palette.textHigh)),
              ),
              const SizedBox(height: 22),
              _feature(FluentIcons.folder_open_24_regular, '离线文件模式',
                  '直接读写 Cfgs/zh-cn/*.json，无需游戏进程'),
              _feature(FluentIcons.checkmark_circle_24_regular, 'Schema 校验',
                  '406 张配置表字段类型校验，避免脏数据写坏存档'),
              _feature(FluentIcons.code_24_regular, 'CLI / TUI / GUI',
                  '三种界面共用同一份配置；本向导完成后不会再次弹出'),
              _feature(FluentIcons.settings_24_regular, '一次性完成初始配置',
                  '工作区、首个 Mod、AI 助手、配音、云存储均可在此配置，随时可跳过'),
              if (_modsCount > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 14),
                  child: Text('检测到工作区内已有 $_modsCount 个模组', style: TextStyle(fontSize: 11, color: hintColor)),
                ),
            ],
          ),
        );
      case 1:
        return SingleChildScrollView(
          key: const ValueKey('oobe-workspace'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('① 选择工作区',
                  style: TextStyle(fontSize: 15, color: palette.textHigh, fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              Text('存放模组的根目录，选择后 CLI/TUI/GUI 三端通用；目录不存在会自动创建。',
                  style: TextStyle(fontSize: 11, color: hintColor)),
              const SizedBox(height: 16),
              _radioTile(
                icon: FluentIcons.pin_24_regular,
                title: '推荐位置',
                subtitle: _suggestedWorkspace.isEmpty
                    ? '(未获取到后端建议路径)'
                    : _suggestedWorkspace,
                value: true,
              ),
              const SizedBox(height: 8),
              _radioTile(
                icon: FluentIcons.folder_24_regular,
                title: '自定义',
                subtitle: '输入本机任意可用路径',
                value: false,
              ),
              const SizedBox(height: 10),
              if (!_useRecommended) ...[
                fluent.TextBox(
                  controller: _wsCtrl,
                  placeholder: Platform.isWindows
                    ? r'D:\MyMods 或 %USERPROFILE%\AppData\LocalLow\...\Mods'
                    : '例如 ~/学生时代Mods（Linux 经 Proton 运行游戏时建议指向\nsteamapps/compatdata 内的 Mods 目录）',
                ),
                const SizedBox(height: 6),
              ],
              if (_wsError != null)
                Text(_wsError!, style: const TextStyle(fontSize: 11, color: Colors.redAccent)),
            ],
          ),
        );
      case 2:
        return SingleChildScrollView(
          key: const ValueKey('oobe-mod'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('② 创建第一个模组（可选）',
                  style: TextStyle(fontSize: 15, color: palette.textHigh, fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              Text('生成 manifest.json 与 Cfgs/zh-cn 空骨架；留空则直接进入编辑器。',
                  style: TextStyle(fontSize: 11, color: hintColor)),
              const SizedBox(height: 16),
              Text('模组名称', style: TextStyle(fontSize: 12, color: hintColor)),
              const SizedBox(height: 6),
              fluent.TextBox(
                controller: _modCtrl,
                placeholder: 'MyFirstMod',
              ),
              const SizedBox(height: 12),
              Text('描述（可选）', style: TextStyle(fontSize: 12, color: hintColor)),
              const SizedBox(height: 6),
              fluent.TextBox(
                controller: _descCtrl,
                placeholder: '我的第一个《学生时代》模组',
              ),
              if (_modError != null) ...[
                const SizedBox(height: 8),
                Text(_modError!, maxLines: 3, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11, color: Colors.redAccent)),
              ],
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: palette.bgDeep,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: palette.border),
                ),
                child: Row(children: [
                  Icon(FluentIcons.info_24_regular, size: 14, color: hintColor),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                        '工作区(${_recommendedWorkspace ? '推荐位置' : '自定义'}): ${_effectiveWorkspace.isEmpty ? "(沿用当前设置)" : _effectiveWorkspace}',
                        maxLines: 2, overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 11, color: hintColor)),
                  ),
                ]),
              ),
            ],
          ),
        );
      case 3:
        return SingleChildScrollView(
          key: const ValueKey('oobe-ai'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('③ AI 助手（可选）',
                  style: TextStyle(fontSize: 15, color: palette.textHigh, fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              Text('为 AI 侧栏助手配置对话服务；字段全部留空即可跳过。生图/换图会自动复用对话配置。',
                  style: TextStyle(fontSize: 11, color: hintColor)),
              const SizedBox(height: 16),
              _fieldLabel('接口协议'),
              fluent.ComboBox<String>(
                value: _aiProvider,
                isExpanded: true,
                items: const [
                  fluent.ComboBoxItem(value: 'openai_compatible', child: Text('OpenAI Compatible')),
                  fluent.ComboBoxItem(value: 'openai_responses', child: Text('OpenAI Responses API')),
                  fluent.ComboBoxItem(value: 'anthropic', child: Text('Anthropic Compatible')),
                ],
                onChanged: (v) => setState(() => _aiProvider = v ?? _aiProvider),
              ),
              const SizedBox(height: 12),
              _fieldLabel('Base URL（留空使用官方默认）'),
              fluent.TextBox(
                controller: _aiBaseUrlCtrl,
                placeholder: 'https://api.openai.com/v1',
              ),
              const SizedBox(height: 12),
              _fieldLabel('API Key（仅保存在本机）'),
              fluent.TextBox(
                controller: _aiApiKeyCtrl,
                obscureText: true,
                placeholder: 'sk-...',
              ),
              const SizedBox(height: 12),
              _fieldLabel('模型（留空使用默认）'),
              fluent.TextBox(
                controller: _aiModelCtrl,
                placeholder: 'gpt-4o / claude-sonnet-4-20250514',
              ),
              const SizedBox(height: 12),
              _fieldLabel('温度'),
              fluent.Slider(
                value: _aiTemp,
                min: 0,
                max: 2,
                onChanged: (v) => setState(() => _aiTemp = v),
                label: _aiTemp.toStringAsFixed(1),
              ),
            ],
          ),
        );
      case 4:
        return SingleChildScrollView(
          key: const ValueKey('oobe-tts'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('④ 配音 TTS（可选）',
                  style: TextStyle(fontSize: 15, color: palette.textHigh, fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              Text('为文本合成语音：阿里云（DashScope）或 MiniMax（T2A V2）；留空即可跳过。',
                  style: TextStyle(fontSize: 11, color: hintColor)),
              const SizedBox(height: 16),
              _fieldLabel('服务商'),
              fluent.ComboBox<String>(
                value: _ttsProvider,
                isExpanded: true,
                items: const [
                  fluent.ComboBoxItem(value: '', child: Text('未配置（跳过）')),
                  fluent.ComboBoxItem(value: 'aliyun', child: Text('阿里云 DashScope（百炼）')),
                  fluent.ComboBoxItem(value: 'minimax', child: Text('MiniMax（T2A V2）')),
                ],
                onChanged: (v) => setState(() => _ttsProvider = v ?? ''),
              ),
              const SizedBox(height: 12),
              _fieldLabel('API Key'),
              fluent.TextBox(
                controller: _ttsApiKeyCtrl,
                obscureText: true,
                placeholder: 'sk-...（阿里云）或 MiniMax API Key',
              ),
              if (_ttsProvider == 'minimax') ...[
                const SizedBox(height: 12),
                _fieldLabel('Group ID（MiniMax 控制台获取）'),
                fluent.TextBox(
                  controller: _ttsGroupIdCtrl,
                  placeholder: '19xxxxxxxxxxxxxxxxxxxxxxxxxxxxxx',
                ),
              ],
              const SizedBox(height: 12),
              _fieldLabel('模型（留空使用默认）'),
              fluent.TextBox(
                controller: _ttsModelCtrl,
                placeholder: 'qwen-tts / cosyvoice-v2 / speech-02-hd',
              ),
              const SizedBox(height: 12),
              _fieldLabel('默认音色（留空使用服务商默认）'),
              fluent.TextBox(
                controller: _ttsVoiceCtrl,
                placeholder: 'Cherry / female-shaonv / 其他 voice id',
              ),
              const SizedBox(height: 12),
              _fieldLabel('语速'),
              fluent.Slider(
                value: _ttsSpeed,
                min: 0.5,
                max: 2,
                onChanged: (v) => setState(() => _ttsSpeed = v),
                label: '${_ttsSpeed.toStringAsFixed(1)}x',
              ),
            ],
          ),
        );
      case 5:
        return SingleChildScrollView(
          key: const ValueKey('oobe-style'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('⑤ 界面风格（可选）',
                  style: TextStyle(fontSize: 15, color: palette.textHigh, fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              Text('选择你习惯的界面布局，切换后立即生效，可随时在设置页修改。',
                  style: TextStyle(fontSize: 11, color: hintColor)),
              const SizedBox(height: 16),
              _styleTile(
                icon: FluentIcons.paint_brush_24_regular,
                title: '创作',
                desc: '图标活动栏 + 侧边栏 + 标签编辑区（默认）',
                selected: _uiMode == UiMode.creation,
                onTap: () => setState(() => _uiMode = UiMode.creation),
              ),
              const SizedBox(height: 8),
              _styleTile(
                icon: FluentIcons.list_24_regular,
                title: '经典',
                desc: '顶部工具栏 + 左侧分组导航（传统桌面风格）',
                selected: _uiMode == UiMode.classic,
                onTap: () => setState(() => _uiMode = UiMode.classic),
              ),
              const SizedBox(height: 8),
              _styleTile(
                icon: FluentIcons.flow_24_regular,
                title: '剧情图',
                desc: '节点画布编排剧情分支（连线式流程）',
                selected: _uiMode == UiMode.storyFlow,
                onTap: () => setState(() => _uiMode = UiMode.storyFlow),
              ),
            ],
          ),
        );
      default:
        return SingleChildScrollView(
          key: const ValueKey('oobe-cloud'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('⑥ 云存储（可选）',
                  style: TextStyle(fontSize: 15, color: palette.textHigh, fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              Text('把 Mod 目录连接到云盘做备份/同步；可留空跳过，之后在「云同步」面板随时添加。',
                  style: TextStyle(fontSize: 11, color: hintColor)),
              const SizedBox(height: 16),
              _fieldLabel('类型'),
              fluent.ComboBox<String>(
                value: _cloudType,
                isExpanded: true,
                items: const [
                  fluent.ComboBoxItem(value: 'local', child: Text('本地目录（测试用）')),
                  fluent.ComboBoxItem(value: 'webdav', child: Text('WebDAV（坚果云/Alist/Nextcloud）')),
                  fluent.ComboBoxItem(value: 'openlist', child: Text('OpenList / Alist 代理')),
                ],
                onChanged: (v) {
                  setState(() {
                    _cloudType = v ?? 'local';
                    _cloudTestMsg = null;
                  });
                },
              ),
              const SizedBox(height: 12),
              _fieldLabel('名称（留空使用类型名）'),
              fluent.TextBox(
                controller: _cloudNameCtrl,
                placeholder: _cloudType,
              ),
              const SizedBox(height: 12),
              if (_cloudType == 'local') ...[
                _fieldLabel('本地根目录'),
                fluent.TextBox(
                  controller: _cloudRootCtrl,
                  placeholder: r'D:\CloudMods 或 /tmp/mods',
                ),
              ] else ...[
                _fieldLabel(_cloudType == 'openlist' ? 'OpenList 地址' : 'WebDAV 地址'),
                fluent.TextBox(
                  controller: _cloudUrlCtrl,
                  placeholder: _cloudType == 'openlist'
                      ? 'http://127.0.0.1:5244'
                      : 'https://dav.example.com/',
                ),
                if (_cloudType == 'webdav') ...[
                  const SizedBox(height: 12),
                  _fieldLabel('用户名（可空）'),
                  fluent.TextBox(controller: _cloudUserCtrl, placeholder: 'user'),
                ],
                if (_cloudType == 'openlist') ...[
                  const SizedBox(height: 12),
                  _fieldLabel('Token（可空）'),
                  fluent.TextBox(controller: _cloudTokenCtrl, obscureText: true, placeholder: 'OpenList 令牌'),
                ],
                if (_cloudType == 'webdav') ...[
                  const SizedBox(height: 12),
                  _fieldLabel('密码（可空）'),
                  fluent.TextBox(controller: _cloudPassCtrl, obscureText: true, placeholder: '● ● ● ● ● ●'),
                ],
              ],
              const SizedBox(height: 12),
              _fieldLabel('远端根目录（留空使用 mods）'),
              fluent.TextBox(
                controller: _cloudRemoteCtrl,
                placeholder: 'mods',
              ),
              const SizedBox(height: 12),
              Row(children: [
                fluent.Button(
                  onPressed: _cloudTesting ? null : _cloudTest,
                  child: _cloudTesting
                      ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('测试连接'),
                ),
                if (_cloudTestMsg != null) ...[
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(_cloudTestMsg!, maxLines: 2, overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 11,
                            color: _cloudTestMsg!.contains('成功') ? palette.statusOk : Colors.redAccent)),
                  ),
                ],
              ]),
            ],
          ),
        );
    }
  }

  Widget _fieldLabel(String text) => Text(text,
      style: TextStyle(fontSize: 12, color: hintColor));

  Widget _feature(IconData icon, String title, String desc) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(7),
            ),
            child: Icon(icon, size: 15, color: accent),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: TextStyle(fontSize: 13, color: palette.textHigh, fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(desc, style: TextStyle(fontSize: 11, color: hintColor, height: 1.35)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 单选卡片（工作区「推荐/自定义」共用）。
  Widget _radioTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required bool value,
  }) {
    final selected = _useRecommended == value;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => setState(() => _useRecommended = value),
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: selected ? palette.card : palette.bgDeep,
            borderRadius: BorderRadius.circular(7),
            border: Border.all(color: selected ? accent : palette.border, width: selected ? 1.5 : 1),
          ),
          child: Row(
            children: [
              Icon(selected ? Icons.radio_button_checked : Icons.radio_button_off,
                  size: 16, color: selected ? accent : hintColor),
              const SizedBox(width: 10),
              Icon(icon, size: 15, color: selected ? accent : hintColor),
              const SizedBox(width: 8),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title,
                      style: TextStyle(fontSize: 12, color: palette.textHigh, fontWeight: FontWeight.w600)),
                  Text(subtitle,
                      maxLines: 2, overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 10.5, color: hintColor)),
                ]),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 界面风格选择卡片。
  Widget _styleTile({
    required IconData icon,
    required String title,
    required String desc,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: selected ? palette.card : palette.bgDeep,
            borderRadius: BorderRadius.circular(7),
            border: Border.all(color: selected ? accent : palette.border, width: selected ? 1.5 : 1),
          ),
          child: Row(
            children: [
              Icon(selected ? Icons.radio_button_checked : Icons.radio_button_off,
                  size: 16, color: selected ? accent : hintColor),
              const SizedBox(width: 12),
              Icon(icon, size: 16, color: selected ? accent : hintColor),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title,
                      style: TextStyle(fontSize: 12, color: palette.textHigh, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text(desc, style: TextStyle(fontSize: 10.5, color: hintColor)),
                ]),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildNavBar() {
    final mobile = isMobileWidth(context);
    final skip = fluent.HyperlinkButton(
      onPressed: _busy ? null : () => _finish(setupMod: false),
      child: const Text('跳过全部', style: TextStyle(fontSize: 11.5)),
    );
    final back = fluent.Button(
      onPressed: _busy ? null : () => setState(() => _step--),
      child: const Text('上一步'),
    );
    final primary = fluent.FilledButton(
      onPressed: _busy ? null : _next,
      child: _busy
          ? const SizedBox(width: 15, height: 15,
              child: CircularProgressIndicator(strokeWidth: 2))
          : Text(_step < _totalSteps - 1 ? '下一步' : '开始使用'),
    );

    if (mobile) {
      // 窄屏：主按钮全宽居下，次要操作一行排布，全部保证 ≥44px 触达高度
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Divider(height: 20, color: palette.border),
          SizedBox(height: 44, child: primary),
          const SizedBox(height: 10),
          Row(
            children: [
              SizedBox(height: 44, child: skip),
              const Spacer(),
              if (_step > 0)
                SizedBox(height: 44, width: 96, child: back),
            ],
          ),
        ],
      );
    }
    return Column(
      children: [
        Divider(height: 20, color: palette.border),
        Row(
          children: [
            skip,
            const Spacer(),
            if (_step > 0)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: back,
              ),
            primary,
          ],
        ),
      ],
    );
  }
}