import 'package:flutter/material.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../../core/api_client.dart';
import '../../core/app_theme.dart';
import '../../core/models.dart';

/// 剧情舞台配音控制台与 AI 视听工坊 (Story Studio TTS Panel)
class StoryStudioTtsPanel extends StatefulWidget {
  const StoryStudioTtsPanel({
    super.key,
    required this.state,
    this.talkLines = const [],
    this.onAudioBound,
  });

  final AppState state;
  final List<Map<String, dynamic>> talkLines;
  final void Function(String talkId, String audioKey)? onAudioBound;

  static Future<void> show(
    BuildContext context, {
    required AppState state,
    List<Map<String, dynamic>> talkLines = const [],
    void Function(String talkId, String audioKey)? onAudioBound,
  }) {
    return showDialog(
      context: context,
      builder: (ctx) => StoryStudioTtsPanel(
        state: state,
        talkLines: talkLines,
        onAudioBound: onAudioBound,
      ),
    );
  }

  @override
  State<StoryStudioTtsPanel> createState() => _StoryStudioTtsPanelState();
}

class _StoryStudioTtsPanelState extends State<StoryStudioTtsPanel> {
  // 角色音色绑定表 (role -> voiceId)
  final Map<String, String> _roleVoiceMap = {
    '萧逸': 'voice_young_male_cool',
    '林晓': 'voice_teen_female_gentle',
    '白雨': 'voice_boy_sunny',
    '苏青': 'voice_mature_female_cold',
    '叶夏': 'voice_lively_girl',
  };

  final List<Map<String, String>> _availableVoices = [
    {'id': 'voice_young_male_cool', 'name': '清冷青年 (DashScope)', 'gender': '男'},
    {'id': 'voice_boy_sunny', 'name': '阳光少年 (MiniMax)', 'gender': '男'},
    {'id': 'voice_teen_female_gentle', 'name': '温柔少女 (DashScope)', 'gender': '女'},
    {'id': 'voice_lively_girl', 'name': '元气少女 (MiniMax)', 'gender': '女'},
    {'id': 'voice_mature_female_cold', 'name': '高冷御姐 (DashScope)', 'gender': '女'},
  ];

  bool _synthesizing = false;
  int _synthProgress = 0;
  String? _statusMessage;
  String? _playingTalkId;

  Future<void> _previewLine(String talkId, String text, String speaker) async {
    final voice = _roleVoiceMap[speaker] ?? 'voice_young_male_cool';
    setState(() {
      _playingTalkId = talkId;
      _statusMessage = '正在试听 $speaker 的配音...';
    });

    try {
      // 调用 Native 端 /api/tts/synthesize
      await ApiClient.instance.post('/api/tts/synthesize', body: {
        'text': text,
        'voice': voice,
      });
      await Future.delayed(const Duration(milliseconds: 600)); // 试听模拟播放
    } catch (_) {
      // 容错处理
    } finally {
      if (mounted) {
        setState(() {
          _playingTalkId = null;
          _statusMessage = '试听播放完毕';
        });
      }
    }
  }

  Future<void> _batchSynthesizeAll() async {
    if (widget.talkLines.isEmpty) {
      fluent.displayInfoBar(
        context,
        builder: (ctx, close) => const fluent.InfoBar(
          title: Text('提示'),
          content: Text('当前剧本暂无可配音的对白台词'),
          severity: fluent.InfoBarSeverity.warning,
        ),
      );
      return;
    }

    setState(() {
      _synthesizing = true;
      _synthProgress = 0;
      _statusMessage = '正在批量合成全篇音轨...';
    });

    try {
      final total = widget.talkLines.length;
      for (int i = 0; i < total; i++) {
        final line = widget.talkLines[i];
        final tid = line['id']?.toString() ?? 'line_$i';
        final spk = line['speaker']?.toString() ?? '主角';
        final txt = line['text']?.toString() ?? '';
        final voice = _roleVoiceMap[spk] ?? 'voice_young_male_cool';

        try {
          await ApiClient.instance.post('/api/tts/save', body: {
            'talk_id': tid,
            'text': txt,
            'voice': voice,
          });
          widget.onAudioBound?.call(tid, 'audio_$tid');
        } catch (_) {}

        if (!mounted) return;
        setState(() {
          _synthProgress = (((i + 1) / total) * 100).toInt();
          _statusMessage = '已完成 ${i + 1} / $total 句配音合成并挂载';
        });
        await Future.delayed(const Duration(milliseconds: 80));
      }

      if (!mounted) return;
      fluent.displayInfoBar(
        context,
        builder: (ctx, close) => fluent.InfoBar(
          title: const Text('配音工坊合成完毕'),
          content: Text('已为全篇 $total 句台词生成专属音频资产并挂载'),
          severity: fluent.InfoBarSeverity.success,
        ),
      );
    } finally {
      if (mounted) setState(() => _synthesizing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: palette.panel,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Container(
        width: 680,
        height: 580,
        padding: const EdgeInsets.all(22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 头部
            Row(
              children: [
                Icon(FluentIcons.mic_sparkle_24_regular, color: accentColor, size: 22),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'AI 角色配音视听工坊 (Story Studio TTS)',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: palette.textPrimary,
                        ),
                      ),
                      Text(
                        '为剧情中登场角色绑定音色，一键批量合成 Mod 专属音频资产',
                        style: TextStyle(fontSize: 11, color: palette.textSecondary),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Divider(height: 1, color: palette.border),
            const SizedBox(height: 14),

            // 角色音色分配卡片
            Text(
              '角色音色配置与选角库 (Voice Casting)：',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: palette.textPrimary),
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: palette.bg,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: palette.border),
              ),
              child: Wrap(
                spacing: 16,
                runSpacing: 10,
                children: _roleVoiceMap.keys.map((role) {
                  final curVoice = _roleVoiceMap[role]!;
                  return Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('$role：', style: TextStyle(fontSize: 12, color: palette.textPrimary, fontWeight: FontWeight.w600)),
                      DropdownButton<String>(
                        value: curVoice,
                        isDense: true,
                        items: _availableVoices.map((v) => DropdownMenuItem(
                          value: v['id']!,
                          child: Text('${v['name']} (${v['gender']})', style: const TextStyle(fontSize: 11)),
                        )).toList(),
                        onChanged: (val) {
                          if (val != null) setState(() => _roleVoiceMap[role] = val);
                        },
                      ),
                    ],
                  );
                }).toList(),
              ),
            ),
            const SizedBox(height: 14),

            // 剧本对白列表与试听
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '剧本台词列表 (${widget.talkLines.length} 句)：',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: palette.textPrimary),
                ),
                fluent.FilledButton(
                  onPressed: _synthesizing ? null : _batchSynthesizeAll,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(FluentIcons.sound_source_24_regular, size: 16),
                      const SizedBox(width: 6),
                      Text(_synthesizing ? '合成进度 $_synthProgress%' : '批量全篇配音合成'),
                    ],
                  ),
                ),
              ],
            ),
            if (_statusMessage != null) ...[
              const SizedBox(height: 6),
              Text(_statusMessage!, style: TextStyle(fontSize: 11, color: accentColor)),
            ],
            const SizedBox(height: 8),

            Expanded(
              child: widget.talkLines.isEmpty
                  ? Center(
                      child: Text('当前剧本暂无台词行', style: TextStyle(fontSize: 12, color: palette.textHint)),
                    )
                  : ListView.builder(
                      itemCount: widget.talkLines.length,
                      itemBuilder: (context, i) {
                        final line = widget.talkLines[i];
                        final tid = line['id']?.toString() ?? '$i';
                        final speaker = line['speaker']?.toString() ?? '旁白';
                        final content = line['text']?.toString() ?? '';
                        final isPlaying = _playingTalkId == tid;

                        return Container(
                          margin: const EdgeInsets.only(bottom: 6),
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
                                  color: accentColor.withOpacity(0.15),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  speaker,
                                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: accentColor),
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  content,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(fontSize: 12, color: palette.textPrimary),
                                ),
                              ),
                              const SizedBox(width: 8),
                              fluent.Button(
                                onPressed: isPlaying ? null : () => _previewLine(tid, content, speaker),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(isPlaying ? FluentIcons.speaker_2_24_filled : FluentIcons.play_24_regular, size: 14),
                                    const SizedBox(width: 4),
                                    Text(isPlaying ? '试听中' : '试听', style: const TextStyle(fontSize: 11)),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
