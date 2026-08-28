import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../../core/api_client.dart';
import '../../core/models.dart';
import '../files/file_viewer.dart';

/// Unity 资源侧边栏：AA bundle 索引状态、资源列表（tex/aud/txt）。
class ResourcesPage extends StatefulWidget {
  const ResourcesPage({super.key, required this.state});
  final AppState state;
  @override
  State<ResourcesPage> createState() => _ResourcesPageState();
}

class _ResourcesPageState extends State<ResourcesPage> {
  List<String> _tex = [];
  List<String> _aud = [];
  List<String> _txt = [];
  String _tab = 'tex';
  bool _busy = false;
  String? _selected;
  String? _exportMsg;
  bool _exporting = false;

  // 来源状态横幅数据（来自 /api/aa/status）
  String _detectedDir = '';
  Map<String, dynamic>? _bundled;

  @override
  void initState() {
    super.initState();
    _refreshStatus();
  }

  Future<void> _refreshStatus() async {
    try {
      final st = await ApiClient.instance.get('/api/aa/status');
      if (!mounted) return;
      setState(() {
        _detectedDir = (st['detected'] as String?) ?? '';
        final b = st['bundled'];
        _bundled = b is Map ? Map<String, dynamic>.from(b) : null;
      });
    } catch (_) {
      // 状态拉取失败不阻塞资源页现有流程
    }
  }

  Future<void> _scan() async {
    setState(() => _busy = true);
    try {
      final r = await ApiClient.instance.post('/api/aa/scan');
      var status = r['status'] as String? ?? 'scanning';
      widget.state.setAaStatus(status);
      if (status == 'scanning') {
        // 扫描在后台线程异步执行，轮询 /api/aa/status 直到就绪或出错
        for (var i = 0; i < 300; i++) {
          await Future<void>.delayed(const Duration(seconds: 1));
          if (!mounted) return;
          final st = await ApiClient.instance.get('/api/aa/status');
          if (!mounted) return;
          status = st['status'] as String? ?? 'idle';
          widget.state.setAaStatus(status);
          if (status == 'error') {
            _err('索引失败：${st['error'] ?? '未知错误'}');
          }
          if (status != 'scanning') break;
        }
      }
      if (status != 'error') {
        await _loadKeys();
        await _refreshStatus();
      }
    } catch (e) {
      if (mounted) _err(e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _loadKeys() async {
    final r = await ApiClient.instance.get('/api/aa/keys', query: {'limit': '800'});
    if (!mounted) return;
    setState(() {
      _tex = (r['tex'] as List).cast<String>();
      _aud = (r['aud'] as List).cast<String>();
      _txt = (r['txt'] as List).cast<String>();
    });
  }

  void _err(String msg) {
    fluent.displayInfoBar(context,
        builder: (ctx, close) =>
            fluent.InfoBar(title: Text('资源操作失败'), content: Text(msg), severity: fluent.InfoBarSeverity.error));
  }

  /// 把选中的 AA 资源导出到当前 Mod（kind: tex → Textures, aud → Audios, txt → Cfgs/zh-cn）。
  Future<void> _exportSelected() async {
    final key = _selected;
    if (key == null || _exporting) return;
    setState(() {
      _exporting = true;
      _exportMsg = null;
    });
    final String out;
    if (_tab == 'tex') {
      out = 'Textures/$key.png';
    } else if (_tab == 'aud') {
      out = 'Audios/$key';
    } else {
      out = 'Cfgs/zh-cn/$key.json';
    }
    try {
      final r = await ApiClient.instance.post('/api/aa/export',
          body: {'kind': _tab, 'key': key, 'out': out});
      final saved = (r as Map)['out'] as String? ?? out;
      if (!mounted) return;
      setState(() => _exportMsg = '已导出到 Mod：$saved');
    } catch (e) {
      if (mounted) {
        setState(() => _exportMsg = null);
        _err(e.toString());
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  /// 双击资源：请求 /api/aa/preview 并以对话框展示内容（贴图/音频/文本）。
  Future<void> _preview(String key) async {
    setState(() {
      _selected = key;
      _exportMsg = null;
    });
    await fluent.showDialog<void>(
      context: context,
      builder: (ctx) => _AaPreviewDialog(kind: _tab, resourceKey: key),
    );
  }

  @override
  Widget build(BuildContext context) {
    final list = _tab == 'tex' ? _tex : (_tab == 'aud' ? _aud : _txt);
    return Column(
      children: [
        Container(
          height: 38,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              const Text('资源',
                  style: TextStyle(fontSize: 12, color: Color(0xFF9B9BA3), fontWeight: FontWeight.w600)),
              const Spacer(),
              MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                    onTap: _busy ? null : _scan,
                    child: const Icon(FluentIcons.scan_camera_24_regular,
                        size: 15, color: Color(0xFF8B8B93))),
              ),
            ],
          ),
        ),
        const Divider(height: 1, color: Color(0xFF2A2A2E)),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              _tabBtn('tex', '贴图'),
              const SizedBox(width: 4),
              _tabBtn('aud', '音频'),
              const SizedBox(width: 4),
              _tabBtn('txt', '文本'),
            ],
          ),
        ),
        const Divider(height: 1, color: Color(0xFF2A2A2E)),
        _sourceBanner(),
        Expanded(
          child: widget.state.aaStatus == 'idle'
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(FluentIcons.scan_camera_24_regular, size: 36, color: Color(0xFF3A3A42)),
                      const SizedBox(height: 12),
                      const Text('尚未扫描游戏资源\n点击右上角扫描按钮建立索引',
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 12, color: Color(0xFF6E6E76))),
                      const SizedBox(height: 10),
                      if (_busy)
                        const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                    ],
                  ),
                )
              : Column(
                  children: [
                    Expanded(
                      child: ListView.builder(
                        itemCount: list.length,
                        itemBuilder: (context, i) {
                          final key = list[i];
                          final selected = _selected == key;
                          return MouseRegion(
                            cursor: SystemMouseCursors.click,
                            child: GestureDetector(
                              onTap: () => setState(() {
                                _selected = selected ? null : key;
                                _exportMsg = null;
                              }),
                              onDoubleTap: () => _preview(key),
                              child: Container(
                                margin: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 2),
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 5),
                                decoration: BoxDecoration(
                                  color: selected
                                      ? const Color(0xFF2B2B31)
                                      : Colors.transparent,
                                  borderRadius: BorderRadius.circular(4),
                                  border: Border.all(
                                      color: selected
                                          ? const Color(0xFF6C5CE7)
                                          : Colors.transparent),
                                ),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: Text(key,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                              fontSize: 12,
                                              color: Color(0xFFD4D4D8))),
                                    ),
                                    if (selected)
                                      const Icon(
                                          FluentIcons.checkmark_24_regular,
                                          size: 12,
                                          color: Color(0xFF6C5CE7)),
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                    const Divider(height: 1, color: Color(0xFF2A2A2E)),
                    Padding(
                      padding: const EdgeInsets.all(8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          fluent.Button(
                            onPressed: (_selected == null || _exporting)
                                ? null
                                : _exportSelected,
                            child: Text(_exporting
                                ? '导出中…'
                                : (_selected == null
                                    ? '点击上方资源选择后导出到 Mod'
                                    : '导出 $_selected 到 Mod'),
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                          ),
                          if (_exportMsg != null) ...[
                            const SizedBox(height: 6),
                            Text(_exportMsg!,
                                style: const TextStyle(
                                    fontSize: 11, color: Color(0xFF9BD1A6))),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
        ),
      ],
    );
  }

  /// 资源来源状态横幅：内置资源包 > 已检测游戏目录 > 未就绪；扫描中优先显示扫描态。
  Widget _sourceBanner() {
    final scanning = widget.state.aaStatus == 'scanning';
    final bundled = _bundled;

    final Color fg;
    final Color bg;
    final Color border;
    final Widget leading;
    final String text;
    if (scanning) {
      fg = const Color(0xFF9B9BA3);
      bg = const Color(0xFF26262B);
      border = const Color(0xFF2A2A2E);
      leading = const SizedBox(
          width: 13, height: 13, child: CircularProgressIndicator(strokeWidth: 2));
      text = '正在扫描资源…';
    } else if (bundled != null) {
      final name = (bundled['name'] as String?) ?? '未知';
      final tex = (bundled['tex'] as num?)?.toInt() ?? 0;
      final aud = (bundled['aud'] as num?)?.toInt() ?? 0;
      fg = const Color(0xFF8B7FEF);
      bg = const Color(0xFF6C5CE7).withValues(alpha: 0.14);
      border = const Color(0xFF6C5CE7).withValues(alpha: 0.38);
      leading = const Icon(FluentIcons.box_24_regular, size: 14, color: Color(0xFF8B7FEF));
      text = '内置资源包：$name（纹理 $tex / 音频 $aud）';
    } else if (_detectedDir.isNotEmpty) {
      fg = const Color(0xFF5FBE8C);
      bg = const Color(0xFF5FBE8C).withValues(alpha: 0.12);
      border = const Color(0xFF5FBE8C).withValues(alpha: 0.35);
      leading = const Icon(FluentIcons.hard_drive_24_regular, size: 14, color: Color(0xFF5FBE8C));
      text = '游戏目录：已检测到 $_detectedDir';
    } else {
      fg = const Color(0xFFD9A15E);
      bg = const Color(0xFFD9A15E).withValues(alpha: 0.12);
      border = const Color(0xFFD9A15E).withValues(alpha: 0.35);
      leading = const Icon(FluentIcons.warning_24_regular, size: 14, color: Color(0xFFD9A15E));
      text = '未就绪：请安装资源包或接入游戏目录';
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 2),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: border),
        ),
        child: Row(
          children: [
            leading,
            const SizedBox(width: 6),
            Expanded(
              child: Text(text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11.5, color: fg)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _tabBtn(String key, String label) {
    final selected = _tab == key;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => setState(() => _tab = key),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: selected ? const Color(0xFF2B2B31) : Colors.transparent,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(label,
              style: TextStyle(
                  fontSize: 12,
                  color: selected ? Colors.white : const Color(0xFF9B9BA3))),
        ),
      ),
    );
  }
}

/// 资源预览对话框：按 kind 展示贴图 / 音频播放器 / 文本内容。
class _AaPreviewDialog extends StatefulWidget {
  const _AaPreviewDialog({required this.kind, required this.resourceKey});
  final String kind; // tex | aud | txt
  final String resourceKey;
  @override
  State<_AaPreviewDialog> createState() => _AaPreviewDialogState();
}

class _AaPreviewDialogState extends State<_AaPreviewDialog> {
  Uint8List? _bytes;
  String? _text;
  bool _truncated = false;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await ApiClient.instance
          .post('/api/aa/preview',
              body: {'kind': widget.kind, 'key': widget.resourceKey});
      if (!mounted) return;
      final b64 = r['data'] as String?;
      setState(() {
        if (b64 != null) {
          _bytes = base64Decode(b64);
        } else {
          _text = r['text'] as String? ?? '';
        }
        _truncated = r['truncated'] == true;
        _error = null;
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
    final kindLabel =
        widget.kind == 'tex' ? '贴图' : (widget.kind == 'aud' ? '音频' : '文本');
    final size = MediaQuery.sizeOf(context);
    return fluent.ContentDialog(
      constraints: BoxConstraints(
        minWidth: math.min(480, size.width - 48),
        maxWidth: math.min(880, size.width - 48),
        maxHeight: math.min(680, size.height - 80),
      ),
      title: Text('预览 $kindLabel · ${widget.resourceKey}'),
      content: _buildContent(),
      actions: [
        fluent.Button(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    );
  }

  Widget _buildContent() {
    // 预留给标题/操作按钮的空间，避免固定内容高度在小屏越界
    final maxContentH =
        math.max(160.0, MediaQuery.sizeOf(context).height - 150);
    if (_loading) {
      return SizedBox(
          height: math.min(480, maxContentH),
          child: const Center(
              child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2))));
    }
    if (_error != null) {
      return SizedBox(
        height: 200,
        child: Center(
          child: Text(_error!,
              style: const TextStyle(color: Color(0xFF9B9BA3), fontSize: 13)),
        ),
      );
    }
    if (widget.kind == 'tex') {
      return SizedBox(
        height: math.min(520, maxContentH),
        child: ImagePreview(bytes: _bytes!, name: widget.resourceKey),
      );
    }
    if (widget.kind == 'aud') {
      return SizedBox(
        height: math.min(320, maxContentH),
        child: AudioPreview(bytes: _bytes!, name: widget.resourceKey),
      );
    }
    // txt
    return SizedBox(
      height: math.min(480, maxContentH),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_truncated) ...[
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Text('内容过大，仅预览前 200K 字符',
                  style: TextStyle(fontSize: 11, color: Color(0xFF6E6E76))),
            ),
            const Divider(height: 1, color: Color(0xFF2A2A2E)),
          ],
          Expanded(
            child: fluent.Scrollbar(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: SelectableText(_text!,
                    style: const TextStyle(
                        fontFamily: 'Consolas',
                        fontSize: 12.5,
                        color: Color(0xFFD4D4D8),
                        height: 1.5)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
