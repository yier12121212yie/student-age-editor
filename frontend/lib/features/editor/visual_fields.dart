/// 全字段可视化输入（M1）的共享控件：步进/滑杆数字框、音频行内试听、
/// 多值 ID chips。判定真源在 field_meta.dart 的 [fieldVisualFor]，
/// 这里只提供控件；schema 编辑器与剧情图（后续接入）共用同一套。
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;

import '../../core/api_client.dart';
import '../../core/app_theme.dart';
import '../../core/models.dart';

/// 带步进按钮（可选区间滑杆提示）的数字输入。
///
/// 与旧裸 TextBox 的区别：加减按钮微调 +（命中 [kFieldNumericHints] 时）
/// 一根语义区间滑杆。手输精确值的能力保留；滑杆只在提示区间与当前值
/// 的并集上显示，越界值扩轨显示、绝不钳制数据。
class NumberStepField extends StatelessWidget {
  const NumberStepField({
    super.key,
    required this.value,
    required this.onChanged,
    this.hint,
    this.placeholder,
  });

  final num? value;
  final ValueChanged<num> onChanged;

  /// (min, max, step) 滑杆提示区间；null = 仅步进框。
  final (double, double, double)? hint;
  final String? placeholder;

  @override
  Widget build(BuildContext context) {
    final step = (hint?.$3 ?? 1);
    // compact 模式会在后缀固定保留 60px 占位（kNumberBoxOverlayWidth），
    // 格子窄于它时（如 800px 窗口的编辑器网格）TextBox 内部 Row 亚像素溢出；
    // 此时退化为纯手输框，滑杆步进仍在。
    final box = LayoutBuilder(
      builder: (context, c) => fluent.NumberBox(
        value: value,
        placeholder: placeholder ?? '输入数字',
        smallChange: step,
        largeChange: step * 10,
        mode: c.maxWidth < 92
            ? fluent.SpinButtonPlacementMode.none
            : fluent.SpinButtonPlacementMode.compact,
        // min/max 一律不设：NumberBox 会把越界手输钳进区间，语义数据不能被钳。
        onChanged: (v) => onChanged(v ?? 0),
      ),
    );
    if (hint == null) return box;
    final v = (value ?? hint!.$1).toDouble();
    final lo = math.min(hint!.$1, v);
    final hi = math.max(hint!.$2, v);
    // 网格点密集到看不清时退化为连续滑杆（divisions=null）。
    final divisions = (hi - lo) / step <= 1000 && step > 0
        ? ((hi - lo) / step).round()
        : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        box,
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: fluent.Slider(
            value: v.clamp(lo, hi),
            min: lo,
            max: hi,
            divisions: divisions,
            label: _fmt(v),
            onChanged: (x) => onChanged(step >= 1 ? x.round() : _snap(x, step)),
          ),
        ),
      ],
    );
  }

  /// 滑杆落点吸附到 step 网格并消除二进制累加毛刺。
  static double _snap(double x, double step) {
    final g = (x / step).round() * step;
    return double.parse(g.toStringAsFixed(4));
  }

  static String _fmt(num v) =>
      v is int || v == v.roundToDouble() ? v.round().toString() : v.toStringAsFixed(2);
}

/// 1D 多值字段的「ID · 名称」chips 行：按文本顺序展示，可移除、左右移序。
///
/// 纯受控组件：回调只做列表变换，文本写回由宿主完成（与文本框单一真源）。
class ValueNameChips extends StatelessWidget {
  const ValueNameChips({
    super.key,
    required this.tokens,
    required this.nameOf,
    required this.onRemove,
    required this.onMove,
    this.maxChips = 32,
  });

  final List<String> tokens;
  final String? Function(String id) nameOf;
  final void Function(int index) onRemove;
  final void Function(int from, int to) onMove;

  /// 超过该数量只渲染前 N 个并提示总数（防千项字典数组撑爆行高）。
  final int maxChips;

  @override
  Widget build(BuildContext context) {
    if (tokens.isEmpty) return const SizedBox.shrink();
    final shown = tokens.take(maxChips).toList();
    final more = tokens.length - shown.length;
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      children: [
        for (var i = 0; i < shown.length; i++) _chip(shown[i], i),
        if (more > 0)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: palette.surface,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text('还有 $more 项',
                style: TextStyle(fontSize: 11, color: palette.textMuted)),
          ),
      ],
    );
  }

  Widget _chip(String id, int index) {
    final name = nameOf(id);
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 2, 2, 2),
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: palette.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 160),
            child: Text(
              name == null || name.isEmpty ? id : '$id · $name',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11.5),
            ),
          ),
          _chipBtn('◀', index > 0, () => onMove(index, index - 1)),
          _chipBtn('▶', index < tokens.length - 1,
              () => onMove(index, index + 1)),
          _chipBtn('✕', true, () => onRemove(index)),
        ],
      ),
    );
  }

  Widget _chipBtn(String label, bool enabled, VoidCallback onTap) {
    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 3),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            color: enabled ? palette.textSecondary : palette.iconDisabled,
          ),
        ),
      ),
    );
  }
}

/// AudioCfg id → {url, type, name} 会话级缓存（切 mod 失效）。
Map<String, Map<String, dynamic>>? _audioUrls;
String? _audioUrlsRoot;

Future<Map<String, Map<String, dynamic>>> _loadAudioUrls() async {
  final root = AppState.current?.modRoot ?? '';
  if (_audioUrls != null && _audioUrlsRoot == root) return _audioUrls!;
  final r = await ApiClient.instance.get('/api/cfg/AudioCfg');
  final data = r is Map ? r['data'] : null;
  final out = <String, Map<String, dynamic>>{};
  if (data is Map) {
    for (final e in data.entries) {
      final row = e.value;
      if (row is Map) {
        out[e.key.toString()] = {
          'url': (row['url'] ?? '').toString(),
          'type': row['type'] is num ? row['type'] as num : 0,
          'name': (row['name'] ?? '').toString(),
        };
      }
    }
  }
  _audioUrls = out;
  _audioUrlsRoot = root;
  return out;
}

/// 音频字节解析：先按 AA 索引 key 走 /api/aa/preview，未命中回落
/// mod 相对路径 /api/tools/read（两路都是仓库既有先例，base64 解码播放）。
Future<Uint8List?> resolveAudioBytes(String audioId) async {
  final id = audioId.trim();
  if (id.isEmpty) return null;
  try {
    final table = await _loadAudioUrls();
    final url = table[id]?['url']?.toString() ?? '';
    if (url.isEmpty) return null;
    try {
      final r = await ApiClient.instance
          .post('/api/aa/preview', body: {'kind': 'aud', 'key': url});
      final b64 = r is Map ? r['data'] : null;
      if (b64 is String && b64.isNotEmpty) return base64Decode(b64);
    } catch (_) {}
    final r = await ApiClient.instance
        .get('/api/tools/read', query: {'scope': 'mod', 'path': url});
    final b64 = r is Map ? r['base64'] : null;
    if (b64 is String && b64.isNotEmpty) return base64Decode(b64);
  } catch (_) {
    // 解析失败按「无字节」处理：由按钮呈现不可试听状态，不打断编辑。
  }
  return null;
}

/// 全局播放互斥：同一时刻只有一个试听在响。
final AudioPlayer _auditionPlayer = AudioPlayer();
final ValueNotifier<String?> auditionPlaying = ValueNotifier<String?>(null);

/// AudioCfg id 行内试听按钮：▶ 播放 / ■ 停止；无字节时禁用并提示。
class AudioAuditionButton extends StatefulWidget {
  const AudioAuditionButton({super.key, required this.audioId, this.width = 28});

  /// AudioCfg 表 id（字符串形态；空串 = 禁用）。
  final String audioId;
  final double width;

  @override
  State<AudioAuditionButton> createState() => _AudioAuditionButtonState();
}

class _AudioAuditionButtonState extends State<AudioAuditionButton> {
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    // 本按钮销毁时若正是它在外放，先停声（不持有跨生命周期播放权）。
    if (auditionPlaying.value == widget.audioId) {
      auditionPlaying.value = null;
      _auditionPlayer.stop().catchError((_) {});
    }
    super.dispose();
  }

  Future<void> _toggle() async {
    if (auditionPlaying.value == widget.audioId) {
      auditionPlaying.value = null;
      try {
        await _auditionPlayer.stop();
      } catch (_) {}
      return;
    }
    if (auditionPlaying.value != null) {
      auditionPlaying.value = null;
      try {
        await _auditionPlayer.stop();
      } catch (_) {}
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    final bytes = await resolveAudioBytes(widget.audioId);
    if (!mounted) return;
    setState(() => _loading = false);
    if (bytes == null) {
      setState(() => _error = '音频字节不可用（AudioCfg 无此行或资源未解码）');
      return;
    }
    try {
      auditionPlaying.value = widget.audioId;
      await _auditionPlayer.play(BytesSource(bytes));
      // 自然播完复位（不订阅完整事件流，避免离屏按钮的悬挂订阅）。
      Future.delayed(const Duration(seconds: 2), () {
        if (mounted && auditionPlaying.value == widget.audioId) {
          auditionPlaying.value = widget.audioId; // 保持图标为“播放中”，停止由再点/切曲触发
        }
      });
    } catch (_) {
      // 平台播放器不可用（如无插件环境）：字节已取到，视为已就绪。
      if (!mounted) return;
      setState(() => _error = '本机播放组件不可用，但音频字节已取到');
    }
  }

  @override
  Widget build(BuildContext context) {
    final disabled = widget.audioId.trim().isEmpty;
    return Tooltip(
      message: _error ?? (disabled ? '先填写音频 ID 再试听' : '试听'),
      child: ValueListenableBuilder<String?>(
        valueListenable: auditionPlaying,
        builder: (_, playing, _) => fluent.Button(
          onPressed: disabled || _loading ? null : _toggle,
          child: SizedBox(
            width: widget.width,
            height: 22,
            child: Icon(
              _loading
                  ? Icons.hourglass_top
                  : playing == widget.audioId
                      ? Icons.stop
                      : Icons.play_arrow,
              size: 14,
            ),
          ),
        ),
      ),
    );
  }
}
