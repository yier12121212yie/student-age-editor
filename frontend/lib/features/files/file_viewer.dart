import 'dart:convert';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../../core/api_client.dart';
import '../../core/models.dart';
import '../../core/app_theme.dart';

/// 文件查看器：文本只读展示；图片/音频走媒体预览（通过 /api/tools/read 的 base64）。
class FileViewer extends StatefulWidget {
  const FileViewer({super.key, required this.state, required this.path, required this.title});
  final AppState state;
  final String path;
  final String title;
  @override
  State<FileViewer> createState() => _FileViewerState();
}

enum _Kind { image, audio }

/// 按扩展名判断媒体类型；非媒体返回 null（走文本/二进制分支）。
_Kind? _kindFor(String path) {
  final i = path.lastIndexOf('.');
  if (i < 0) return null;
  final ext = path.substring(i + 1).toLowerCase();
  if (const {'png', 'jpg', 'jpeg', 'webp', 'bmp', 'gif'}.contains(ext)) {
    return _Kind.image;
  }
  if (const {'wav', 'ogg', 'mp3', 'flac', 'm4a'}.contains(ext)) {
    return _Kind.audio;
  }
  return null;
}

String _fmtSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / 1024 / 1024).toStringAsFixed(2)} MB';
}

class _FileViewerState extends State<FileViewer> {
  String? _text;
  String? _error;
  Uint8List? _media;
  bool _loading = true;

  final ScrollController _scrollCtrl = ScrollController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _scrollCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final kind = _kindFor(widget.path);
    try {
      if (kind != null) {
        // 媒体文件：走 /api/tools/read 的 base64 字段（后端对媒体扩展名返回 base64，
        // 且不受 8MB 文本上限限制），解码为字节后交给对应预览组件。
        final r = await ApiClient.instance.get('/api/tools/read',
            query: {'scope': 'mod', 'path': widget.path});
        final b64 = r['base64'] as String?;
        if (b64 == null) {
          throw ApiException(-1, '媒体文件读取失败：后端未返回数据');
        }
        final bytes = base64Decode(b64);
        if (!mounted) return;
        setState(() {
          _media = bytes;
          _error = null;
          _loading = false;
        });
        return;
      }
      final r = await ApiClient.instance.get('/api/tools/read',
          query: {'scope': 'mod', 'path': widget.path});
      if (!mounted) return;
      final text = r['text'] as String?;
      if (text != null) {
        setState(() {
          _text = text;
          _error = null;
          _loading = false;
        });
        return;
      }
      // 其他二进制文件：尝试附带大小信息
      String? sizeText;
      try {
        final st = await ApiClient.instance.get('/api/tools/stat',
            query: {'scope': 'mod', 'path': widget.path});
        final size = st['size'] as int?;
        if (size != null) sizeText = _fmtSize(size);
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _error = '二进制文件，暂不支持预览${sizeText == null ? '' : '（$sizeText）'}';
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(
          child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)));
    }
    if (_error != null) {
      return Center(
        child: Text(_error!,
            style: TextStyle(color: palette.textSecondary, fontSize: 13)),
      );
    }
    switch (_kindFor(widget.path)) {
      case _Kind.image:
        return ImagePreview(bytes: _media!, name: widget.title);
      case _Kind.audio:
        return AudioPreview(bytes: _media!, name: widget.title);
      case null:
        return _buildText();
    }
  }

  Widget _buildText() {
    return fluent.Scrollbar(
      controller: _scrollCtrl,
      child: SingleChildScrollView(
        controller: _scrollCtrl,
        padding: const EdgeInsets.all(16),
        child: SelectableText(_text!,
            style: TextStyle(
                fontFamily: 'Consolas',
                fontSize: 12.5,
                color: palette.textPrimary,
                height: 1.5)),
      ),
    );
  }
}

/// 预览区顶部信息栏：图标 + 文件名 + 操作提示。
class _InfoBar extends StatelessWidget {
  const _InfoBar({required this.name, required this.icon, required this.hint});
  final String name;
  final IconData icon;
  final String hint;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 38,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          Icon(icon, size: 14, color: palette.textMuted),
          const SizedBox(width: 8),
          Expanded(
            child: Text(name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: palette.textSecondary)),
          ),
          if (hint.isNotEmpty)
            Text(hint,
                style: TextStyle(fontSize: 11, color: palette.textHint)),
        ],
      ),
    );
  }
}

/// 图片预览：自适应显示 + 滚轮缩放/拖拽平移。
class ImagePreview extends StatelessWidget {
  const ImagePreview({super.key, required this.bytes, required this.name});
  final Uint8List bytes;
  final String name;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _InfoBar(name: name, icon: FluentIcons.image_24_regular, hint: '滚轮缩放 · 拖拽平移'),
        Divider(height: 1, color: palette.border),
        Expanded(
          child: InteractiveViewer(
            maxScale: 8,
            child: Center(
              child: Image.memory(bytes,
                  fit: BoxFit.contain,
                  gaplessPlayback: true,
                  errorBuilder: (_, _, _) => Text('图片解码失败',
                      style: TextStyle(color: palette.textSecondary, fontSize: 13))),
            ),
          ),
        ),
      ],
    );
  }
}

/// 音频预览：加载完成后提供播放/暂停、进度拖动、音量控制。
class AudioPreview extends StatefulWidget {
  const AudioPreview({super.key, required this.bytes, required this.name});
  final Uint8List bytes;
  final String name;
  @override
  State<AudioPreview> createState() => _AudioPreviewState();
}

class _AudioPreviewState extends State<AudioPreview> {
  final AudioPlayer _player = AudioPlayer();
  Duration _duration = Duration.zero;
  Duration _position = Duration.zero;
  double _volume = 1.0;
  bool _playing = false;
  bool _dragging = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    _player.onDurationChanged.listen((d) {
      if (mounted) setState(() => _duration = d);
    });
    _player.onPositionChanged.listen((p) {
      if (mounted && !_dragging) setState(() => _position = p);
    });
    _player.onPlayerStateChanged.listen((s) {
      if (mounted) setState(() => _playing = s == PlayerState.playing);
    });
    _player.onPlayerComplete.listen((_) {
      if (mounted) {
        setState(() {
          _playing = false;
          _position = _duration;
        });
      }
    });
    try {
      // BytesSource 由插件写入临时文件播放，无需落盘到模组目录
      await _player.play(BytesSource(widget.bytes));
    } catch (e) {
      if (mounted) setState(() => _error = '音频播放失败: $e');
    }
  }

  Future<void> _toggle() async {
    if (_playing) {
      await _player.pause();
    } else {
      // 播完后再次播放从头开始
      if (_duration > Duration.zero && _position >= _duration) {
        await _player.seek(Duration.zero);
      }
      await _player.resume();
    }
  }

  Future<void> _onSeek(double v) async {
    await _player.seek(Duration(milliseconds: v.round()));
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final maxMs = _duration.inMilliseconds.toDouble().clamp(1.0, double.infinity);
    // 本预览运行在 Fluent UI 的组件树中（没有 MaterialApp/Material 祖先），
    // 而 Slider、IconButton 等 Material 组件必须有 Material 祖先才能渲染；
    // 否则它们会被 ErrorWidget（固定 100000×100000 布局）替换，导致底部溢出。
    return Material(
      type: MaterialType.transparency,
      child: Column(
        children: [
          _InfoBar(
              name: widget.name,
              icon: FluentIcons.music_note_2_24_regular,
              hint: ''),
          Divider(height: 1, color: palette.border),
          Expanded(
            child: Center(
              child: _error != null
                  ? Text(_error!,
                      style: TextStyle(color: palette.textSecondary, fontSize: 13))
                  : ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 560),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                        Icon(FluentIcons.music_note_2_24_regular,
                            size: 56, color: palette.borderHover),
                        const SizedBox(height: 12),
                        Text(widget.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 13, color: palette.textPrimary)),
                        const SizedBox(height: 4),
                        Text('${_fmt(_position)} / ${_fmt(_duration)}',
                            style: TextStyle(
                                fontSize: 11, color: palette.textHint)),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            IconButton(
                              icon: Icon(
                                  _playing
                                      ? FluentIcons.pause_24_regular
                                      : FluentIcons.play_24_regular,
                                  size: 20,
                                  color: palette.textPrimary),
                              onPressed: _toggle,
                            ),
                            Expanded(
                              child: Slider(
                                value: _position.inMilliseconds
                                    .toDouble()
                                    .clamp(0.0, maxMs),
                                max: maxMs,
                                onChangeStart: (_) => _dragging = true,
                                onChanged: (v) {
                                  setState(() =>
                                      _position = Duration(milliseconds: v.round()));
                                },
                                onChangeEnd: (v) {
                                  _dragging = false;
                                  _onSeek(v);
                                },
                              ),
                            ),
                            const SizedBox(width: 8),
                            Icon(FluentIcons.speaker_1_24_regular,
                                size: 14, color: palette.textMuted),
                            SizedBox(
                              width: 90,
                              child: Slider(
                                value: _volume,
                                onChangeEnd: (v) => _player.setVolume(v),
                                onChanged: (v) {
                                  setState(() => _volume = v);
                                  _player.setVolume(v);
                                },
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
          ),
        ),
        ],
      ),
    );
  }
}
