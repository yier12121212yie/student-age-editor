import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter/material.dart';

import '../../core/api_client.dart';
import '../../core/app_theme.dart';

/// 配音（TTS）面板。
///
/// 从剧本 / 任意文本合成语音（阿里云 DashScope 百炼 / MiniMax T2A V2）：
/// - 音色列表：MiniMax 实时拉取（失败回退内置表），阿里云内置预设 + 可手填 voice id
/// - 试听：后端返回 base64 直接由 audioplayers 播放，不落盘
/// - 保存：写入当前 mod 的 audio/tts/ 目录，可登记 AudioCfg 行
///   （原版游戏无逐行配音通道，TalkCfg.vocals 仅作人声效果叠加，因此不写 vocals）
///
/// 以独立内容面板形式嵌入 ContentDialog 使用（见 story_director_view 的「台词配音」入口）。
class TtsPanel extends StatefulWidget {
  const TtsPanel({
    super.key,
    this.initText = '',
    this.initTitle = '',
    this.initTalkId = '',
  });

  /// 预填的合成文本（通常为当前对话行内容）。
  final String initText;

  /// 保存时写入 AudioCfg.name 的标题摘要（缺省取文本前 24 字）。
  final String initTitle;

  /// 建议的素材键名前缀（如 talk_32010101）。
  final String initTalkId;

  @override
  State<TtsPanel> createState() => _TtsPanelState();
}

class _TtsPanelState extends State<TtsPanel> {
  final AudioPlayer _player = AudioPlayer();

  final TextEditingController _textCtrl = TextEditingController();
  final TextEditingController _voiceCtrl = TextEditingController();

  Map<String, dynamic> _settings = {};
  String _provider = 'aliyun';
  List<Map<String, dynamic>> _voices = [];
  String _voicesSource = '';
  bool _voicesLoading = false;
  String? _voicesError;
  double _speed = 1.0;

  Uint8List? _lastAudio;
  String _lastExt = 'wav';
  int _lastBytes = 0;
  bool _synthBusy = false;
  bool _saving = false;
  String? _result;
  String? _savedPath;
  String? _savedCfgId;
  bool _convertedOgg = false;

  List<Map<String, dynamic>> _materials = [];
  bool _materialsLoading = false;

  @override
  void initState() {
    super.initState();
    _textCtrl.text = widget.initText;
    // 音色不预填 initTalkId（那是保存素材键名前缀），
    // 默认音色由 _matchedVoice 从设置 ttsVoice 读取。
    _loadSettings();
  }

  @override
  void dispose() {
    _player.dispose();
    _textCtrl.dispose();
    _voiceCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadSettings() async {
    try {
      final r = await ApiClient.instance
          .get('/api/tts/settings')
          .timeout(const Duration(seconds: 5));
      if (!mounted) return;
      final s = (r is Map ? r['settings'] : null) as Map<String, dynamic>? ?? {};
      final speed = (s['ttsSpeed'] as num?)?.toDouble() ?? 1.0;
      setState(() {
        _settings = s;
        _provider = (s['ttsProvider'] as String? ?? 'aliyun').isEmpty
            ? 'aliyun'
            : s['ttsProvider'] as String;
        _speed = speed.clamp(0.5, 2.0);
      });
      if (!mounted) return;
      await _loadVoices();
    } catch (_) {
      if (!mounted) return;
      setState(() => _voicesError = '读取配音设置失败（后端未就绪？）');
    }
    if (!mounted) return;
    _refreshMaterials();
  }

  Future<void> _loadVoices() async {
    setState(() {
      _voicesLoading = true;
      _voicesError = null;
    });
    try {
      final r = await ApiClient.instance
          .get('/api/tts/voices', query: {'provider': _provider})
          .timeout(const Duration(seconds: 40));
      final list = ((r['voices'] as List?) ?? [])
          .whereType<Map<String, dynamic>>()
          .toList();
      if (!mounted) return;
      setState(() {
        _voices = list;
        _voicesSource = r['source']?.toString() ?? '';
        _voicesLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _voices = [];
        _voicesLoading = false;
        _voicesError = '音色列表加载失败：$e';
      });
    }
  }

  Future<void> _refreshMaterials() async {
    setState(() => _materialsLoading = true);
    try {
      final r = await ApiClient.instance.get('/api/tts/list');
      if (!mounted) return;
      setState(() => _materialsLoading = false);
      setState(() {
        _materials = ((r['items'] as List?) ?? [])
            .whereType<Map<String, dynamic>>()
            .toList();
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _materialsLoading = false);
    }
  }

  Future<void> _synth() async {
    final text = _textCtrl.text.trim();
    if (text.isEmpty) {
      _toast('配音文本不能为空', severe: true);
      return;
    }
    setState(() {
      _synthBusy = true;
      _result = null;
    });
    try {
      final r = await ApiClient.instance
          .post('/api/tts/synthesize',
              body: {
                'provider': _provider,
                'text': text,
                'voice': _voiceCtrl.text.trim(),
                'params': {'speed': _speed},
              })
          .timeout(const Duration(minutes: 6));
      final b64 = r['audio'] as String? ?? '';
      final ext = r['ext']?.toString() ?? 'wav';
      final bytes = Uint8List.fromList(base64Decode(b64));
      if (!mounted) return;
      setState(() {
        _lastAudio = bytes;
        _lastExt = ext;
        _lastBytes = bytes.length;
        _synthBusy = false;
        _result = '合成完成：${bytes.length} 字节 (.$ext)';
      });
      await _play(bytes);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _synthBusy = false;
        _result = null;
      });
      _toast('合成失败：$e', severe: true);
    }
  }

  Future<void> _play(Uint8List bytes) async {
    try {
      await _player.stop();
      await _player.play(BytesSource(bytes));
    } catch (e) {
      _toast('播放失败：$e', severe: true);
    }
  }

  Future<void> _save() async {
    if (_lastAudio == null) {
      _toast('请先合成并试听，再保存', severe: true);
      return;
    }
    setState(() => _saving = true);
    try {
      final keyBase =
          widget.initTalkId.isNotEmpty ? widget.initTalkId : 'tts';
      final key = '${keyBase}_${DateTime.now().millisecondsSinceEpoch}';
      // 从剧情导演打开时 initTalkId 形如 'talk_<对白id>'：剥离前缀得到真实对白 id，
      // 供"配音打通"使用（后端写回 TalkCfg.audio，即引擎的逐句配音通道）
      final bindTalkId = widget.initTalkId.startsWith('talk_')
          ? widget.initTalkId.substring(5)
          : (widget.initTalkId.isEmpty ? '' : widget.initTalkId);
      final r = await ApiClient.instance
          .post('/api/tts/save',
              body: {
                'audio': base64Encode(_lastAudio!),
                'ext': _lastExt,
                'key': key,
                'ogg': true, // 有 ffmpeg/oggenc 时自动转 Ogg（游戏原生格式）
                'writeCfg': true,
                if (bindTalkId.isNotEmpty) 'bindTalkId': bindTalkId,
                'title': widget.initTitle.isNotEmpty
                    ? widget.initTitle
                    : _textCtrl.text.trim(),
              })
          // 后端 ogg 转码最长 120s（ffmpeg/oggenc），超时须留足余量，
          // 否则慢转码下前端先报失败而后端实际已写完文件
          .timeout(const Duration(seconds: 150));
      if (!mounted) return;
      setState(() {
        _saving = false;
        _savedPath = r['path']?.toString() ?? '';
        _savedCfgId = r['audioCfgId']?.toString();
        _convertedOgg = r['convertedOgg'] == true;
      });
      _refreshMaterials();
      final cfgNote =
          r['audioCfgId'] != null ? '，已登记 AudioCfg #${r['audioCfgId']}' : '';
      final boundNote = r['boundTalkId'] != null
          ? '，已绑定对白 ${r['boundTalkId']}'
          : '';
      // 后端如实上报：绑定未发生（未登记 AudioCfg）或失败时 boundTalkId
      // 为 null 并带 warning——提示必须透传，不能只报「已保存」
      final warnNote = r['warning'] != null ? '\n⚠ ${r['warning']}' : '';
      _toast('已保存：$_savedPath$cfgNote$boundNote$warnNote',
          severe: r['warning'] != null);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      _toast('保存失败：$e', severe: true);
    }
  }

  Future<void> _playMaterial(String rel) async {
    try {
      final r = await ApiClient.instance
          .get('/api/tts/audio', query: {'path': rel})
          .timeout(const Duration(seconds: 30));
      final bytes = Uint8List.fromList(
          base64Decode(r['audio'] as String? ?? ''));
      if (!mounted) return;
      await _play(bytes);
    } catch (e) {
      _toast('试听失败：$e', severe: true);
    }
  }

  Future<void> _deleteMaterial(Map<String, dynamic> item) async {
    final path = item['path']?.toString() ?? '';
    final ok = await fluent.showDialog<bool>(
      context: context,
      builder: (ctx) => fluent.ContentDialog(
        title: const Text('删除配音素材'),
        content: Text('确认删除 $path ？'),
        actions: [
          fluent.Button(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          fluent.FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('删除')),
        ],
      ),
    );
    if (ok != true) return;
    if (!mounted) return;
    try {
      await ApiClient.instance
          .post('/api/tts/delete', body: {'path': path})
          .timeout(const Duration(seconds: 20));
      _refreshMaterials();
    } catch (e) {
      _toast('删除失败：$e', severe: true);
    }
  }

  void _toast(String msg, {bool severe = false}) {
    if (!mounted) return;
    fluent.displayInfoBar(context,
        builder: (ctx, close) => fluent.InfoBar(
            title: Text(msg),
            severity: severe
                ? fluent.InfoBarSeverity.error
                : fluent.InfoBarSeverity.success));
  }

  Future<void> _test() async {
    try {
      final r = await ApiClient.instance
          .post('/api/tts/test',
              body: {
                'provider': _provider,
                'settings': {
                  'ttsProvider': _provider,
                  'ttsApiKey': _settings['ttsApiKey'] ?? '',
                  'ttsGroupId': _settings['ttsGroupId'] ?? '',
                  'ttsBaseUrl': _settings['ttsBaseUrl'] ?? '',
                  'ttsModel': _settings['ttsModel'] ?? '',
                },
              })
          .timeout(const Duration(minutes: 2));
      if (r['ok'] == true) {
        _toast('连接成功：${r['detail'] ?? ''}');
      } else {
        _toast('连接失败：${r['error'] ?? ''}', severe: true);
      }
    } catch (e) {
      _toast('连接失败：$e', severe: true);
    }
  }

  String _fmtSize(int size) {
    if (size < 1024) return '$size B';
    if (size < 1024 * 1024) return '${(size / 1024).toStringAsFixed(1)} KB';
    return '${(size / 1024 / 1024).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final bg = palette.bg;
    final hint = palette.textMuted;
    final border = palette.surface;
    // 窄屏自适应：面板随屏幕收缩，宽度不足以并排放下服务商+音色时改纵向堆叠
    final size = MediaQuery.sizeOf(context);
    final compact = size.width < 560;
    // 窄屏两个主按钮等宽铺满，宽屏保持固有宽度并在右侧显示说明
    final synthBtn = fluent.FilledButton(
      onPressed: _synthBusy ? null : _synth,
      style: fluent.ButtonStyle(
        backgroundColor: WidgetStatePropertyAll(palette.warning),
      ),
      child: _synthBusy
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2))
          : const Text('🧪 合成并试听'),
    );
    final saveBtn = fluent.FilledButton(
      onPressed: (_saving || _lastAudio == null) ? null : _save,
      style: const fluent.ButtonStyle(
        backgroundColor: WidgetStatePropertyAll(Color(0xFF6C5CE7)),
      ),
      child: _saving
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2))
          : const Text('💾 保存到模组'),
    );
    return Container(
      // 预留 Dialog 默认 insetPadding（水平 40 / 垂直 24），避免弹窗内溢出
      width: min(680, size.width - 88),
      height: min(620, size.height - 72),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: border),
      ),
      child: Column(
        children: [
          // 标题栏
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: border)),
            ),
            child: Row(
              children: [
                Icon(FluentIcons.mic_24_regular,
                    size: 18, color: palette.warning),
                const SizedBox(width: 8),
                Text('配音（TTS）',
                    style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: palette.textHigh)),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(_voicesSource == 'live'
                      ? '· MiniMax 音色在线'
                      : '· 内置音色表',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11, color: hint)),
                ),
                const Spacer(),
                fluent.Button(
                  onPressed: _test,
                  child: const Text('测试连接'),
                ),
                const SizedBox(width: 8),
                fluent.IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(FluentIcons.dismiss_24_regular, size: 16),
                ),
              ],
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 服务商 + 音色（窄屏纵向堆叠，宽屏并排）
                  if (compact) ...[
                    _label('服务商'),
                    const SizedBox(height: 6),
                    _providerCombo(),
                    const SizedBox(height: 12),
                    _label('音色（voice id）'),
                    const SizedBox(height: 6),
                    _voiceRow(),
                    const SizedBox(height: 6),
                    fluent.TextBox(
                      controller: _voiceCtrl,
                      placeholder: '或手填 voice id',
                    ),
                  ] else ...[
                    Row(
                      children: [
                        Expanded(child: _label('服务商')),
                        const SizedBox(width: 12),
                        Expanded(
                            flex: 2, child: _label('音色（voice id）')),
                        const SizedBox(width: 4),
                      ],
                    ),
                    const SizedBox(height: 6),
                    _providerAndVoiceRow(),
                  ],
                  if (_voicesError != null) ...[
                    const SizedBox(height: 6),
                    Text(_voicesError!,
                        style: TextStyle(
                            fontSize: 11, color: palette.statusDanger)),
                  ] else if (_voices.isEmpty && !_voicesLoading) ...[
                    const SizedBox(height: 6),
                    Text('请先在「设置 → 配音」填写 API Key 后刷新音色',
                        style: TextStyle(fontSize: 11, color: hint)),
                  ],
                  const SizedBox(height: 14),
                  _label('合成文本'),
                  const SizedBox(height: 6),
                  fluent.TextBox(
                    controller: _textCtrl,
                    maxLines: 6,
                    minLines: 3,
                    placeholder: '输入要配音的文本…\n（从故事导演带入时会自动填充当前行内容）',
                  ),
                  const SizedBox(height: 14),
                  _label('语速'),
                  fluent.Slider(
                    value: _speed,
                    min: 0.5,
                    max: 2,
                    onChanged: (v) => setState(() => _speed = v),
                    label: '${_speed.toStringAsFixed(1)}x',
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      if (compact) Expanded(child: synthBtn) else synthBtn,
                      const SizedBox(width: 10),
                      if (compact) Expanded(child: saveBtn) else saveBtn,
                      if (!compact && _lastAudio != null) ...[
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            '$_lastBytes 字节(.$_lastExt)，'
                            '保存时自动转为游戏原生 Ogg（若本机装有 ffmpeg/oggenc）',
                            style:
                                TextStyle(fontSize: 11, color: hint),
                          ),
                        ),
                      ],
                    ],
                  ),
                  if (compact && _lastAudio != null) ...[
                    const SizedBox(height: 6),
                    Text(
                      '$_lastBytes 字节(.$_lastExt)，'
                      '保存时自动转为游戏原生 Ogg（若本机装有 ffmpeg/oggenc）',
                      style: TextStyle(fontSize: 11, color: hint),
                    ),
                  ],
                  const SizedBox(height: 8),
                  if (_result != null)
                    Text(_result!,
                        style: const TextStyle(
                            fontSize: 11, color: Color(0xFF6C5CE7))),
                  if (_savedPath != null) ...[
                    const SizedBox(height: 6),
                    Text(
                      '已保存：$_savedPath'
                      '${_convertedOgg ? '（已转码 Ogg）' : ''}'
                      '${_savedCfgId != null ? ' · AudioCfg #$_savedCfgId' : ''}',
                      style:
                          const TextStyle(fontSize: 11, color: Color(0xFF3FA46B)),
                    ),
                  ],
                  const SizedBox(height: 6),
                  Text(
                    '原版游戏无逐行配音通道（TalkCfg.vocals 为人声效果叠加），'
                    '因此不写 vocals；生成素材登记在 AudioCfg，供 mod 作者自行接入。',
                    style: TextStyle(fontSize: 10.5, color: hint, height: 1.5),
                  ),
                  const SizedBox(height: 16),
                  Divider(color: border),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Text('素材库（当前 mod audio/tts/）',
                          style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                              color: palette.textHigh)),
                      const Spacer(),
                      fluent.IconButton(
                        onPressed: _refreshMaterials,
                        icon: const Icon(FluentIcons.arrow_sync_24_regular,
                            size: 15),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  if (_materialsLoading)
                    const Padding(
                      padding: EdgeInsets.all(8),
                      child: SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2)),
                    )
                  else if (_materials.isEmpty)
                    Padding(
                      padding: EdgeInsets.symmetric(vertical: 10),
                      child: Text('暂无配音素材，合成后点击「保存到模组」',
                          style: TextStyle(fontSize: 11, color: hint)),
                    )
                  else
                    for (final item in _materials)
                      Container(
                        margin: const EdgeInsets.symmetric(vertical: 3),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: palette.bgAlt,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: border),
                        ),
                        child: Row(
                          children: [
                            Icon(FluentIcons.mic_24_regular,
                                size: 14, color: palette.textMuted),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                item['path']?.toString() ?? '',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    fontSize: 11.5, color: palette.textPrimary),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                                _fmtSize(
                                    (item['size'] as num?)?.toInt() ?? 0),
                                style: TextStyle(
                                    fontSize: 10.5, color: hint)),
                            const SizedBox(width: 4),
                            fluent.IconButton(
                              onPressed: () => _playMaterial(
                                  item['path']?.toString() ?? ''),
                              icon: const Icon(FluentIcons.play_24_regular,
                                  size: 14),
                            ),
                            fluent.IconButton(
                              onPressed: () => _deleteMaterial(item),
                              icon: const Icon(FluentIcons.delete_24_regular,
                                  size: 14),
                            ),
                          ],
                        ),
                      ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _providerCombo() => fluent.ComboBox<String>(
        value: _provider,
        isExpanded: true,
        items: const [
          fluent.ComboBoxItem(
              value: 'aliyun', child: Text('阿里云 DashScope（百炼）')),
          fluent.ComboBoxItem(value: 'minimax', child: Text('MiniMax（T2A V2）')),
        ],
        onChanged: (v) {
          if (v == null || v == _provider) return;
          setState(() => _provider = v);
          _loadVoices();
        },
      );

  Widget _voiceCombo() => fluent.ComboBox<String>(
        value: _matchedVoice,
        isExpanded: true,
        placeholder: _voicesLoading
            ? const Text('加载中…')
            : const Text('选择音色'),
        items: [
          for (final v in _voices)
            fluent.ComboBoxItem(
              value: v['id'] as String,
              child: Text(
                  '${v['name'] ?? v['id']}'
                  '${(v['gender'] as String? ?? '').isNotEmpty ? '（${v['gender']}）' : ''}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
            ),
        ],
        onChanged: (v) => setState(() {
          _voiceCtrl.text = v ?? '';
        }),
      );

  /// 音色行：下拉选择 + 刷新（窄屏）；手填 voice id 输入框在窄屏单独成行。
  Widget _voiceRow() => Row(
        children: [
          Expanded(child: _voiceCombo()),
          const SizedBox(width: 8),
          fluent.IconButton(
            onPressed: _voicesLoading ? null : _loadVoices,
            icon: const Icon(FluentIcons.arrow_sync_24_regular, size: 15),
          ),
        ],
      );

  /// 宽屏布局：服务商 + 音色下拉 + 手填输入框 + 刷新并排。
  Widget _providerAndVoiceRow() => Row(
        children: [
          Expanded(child: _providerCombo()),
          const SizedBox(width: 12),
          Expanded(
            flex: 2,
            child: _voiceCombo(),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: fluent.TextBox(
              controller: _voiceCtrl,
              placeholder: '或手填 voice id',
            ),
          ),
          const SizedBox(width: 4),
          fluent.IconButton(
            onPressed: _voicesLoading ? null : _loadVoices,
            icon: const Icon(FluentIcons.arrow_sync_24_regular, size: 15),
          ),
        ],
      );

  /// 当前音色（手填 / 默认设置），仅当存在于预设列表时才作为下拉选中值；
  /// 手填的自定义 voice id 不匹配列表项时下拉回到占位符。
  String? get _matchedVoice {
    final v = _voiceCtrl.text.trim();
    if (v.isEmpty) {
      final d = _settings['ttsVoice']?.toString().trim() ?? '';
      return _voices.any((x) => x['id'] == d) ? d : null;
    }
    return _voices.any((x) => x['id'] == v) ? v : null;
  }

  Widget _label(String s) =>
      Text(s, style: TextStyle(fontSize: 12, color: palette.textPrimary));
}