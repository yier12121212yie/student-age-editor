import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../../core/api_client.dart';
import '../../core/models.dart';
import '../files/file_viewer.dart';
import 'asset_explorer_panel.dart';
import 'image_asset_picker.dart' show HoverTexPreview;
import 'live2d_preview_panel.dart';
import '../../core/app_theme.dart';

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
  String? _selected;
  String? _exportMsg;
  bool _exporting = false;

  // 来源状态横幅数据（来自 /api/aa/status）
  String _detectedDir = '';
  Map<String, dynamic>? _bundled;

  /// 扫描忙碌态与 AA 状态的本地镜像（阶段 4c）：轮询/定时刷新只写这两个
  /// notifier，订阅方仅扫描图标、来源横幅与列表区；索引与横幅数据到位才是
  /// 结构性变化，仍走整页 setState。全局 [AppState.aaStatus] 照常双写，
  /// 跨页消费方（状态栏等）语义不变。
  final ValueNotifier<bool> _busy = ValueNotifier<bool>(false);
  final ValueNotifier<String> _aaStatus = ValueNotifier<String>('idle');

  /// 列表区同时关心忙碌态（空态里的转圈）与 AA 状态（空态/列表分支）。
  late final Listenable _bodyTick = Listenable.merge([_busy, _aaStatus]);

  @override
  void initState() {
    super.initState();
    _aaStatus.value = widget.state.aaStatus;
    _refreshStatus();
  }

  @override
  void didUpdateWidget(covariant ResourcesPage old) {
    super.didUpdateWidget(old);
    // 其他页面/启动流程改过全局状态时跟随，避免镜像滞后
    if (widget.state.aaStatus != _aaStatus.value) {
      _aaStatus.value = widget.state.aaStatus;
    }
  }

  @override
  void dispose() {
    _busy.dispose();
    _aaStatus.dispose();
    super.dispose();
  }

  /// 状态双写：本地 notifier（局部订阅，只刷横幅与列表区）+ 全局 AppState
  /// （值未变化时其内部去重，不通知）。
  void _setStatus(String status) {
    _aaStatus.value = status;
    widget.state.setAaStatus(status);
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

  /// 扫描游戏资源并轮询直到就绪/出错。
  ///
  /// 阶段 4c：轮询期间只写 [_busy]/[_aaStatus]，重建范围限于扫描图标、来源
  /// 横幅与列表区；索引（[_loadKeys]）与横幅数据（[_refreshStatus]）到位才是
  /// 结构性变化，仍走整页 setState。
  Future<void> _scan() async {
    _busy.value = true;
    try {
      final r = await ApiClient.instance.post('/api/aa/scan');
      var status = r['status'] as String? ?? 'scanning';
      _setStatus(status);
      if (status == 'scanning') {
        // 扫描在后台线程异步执行，轮询 /api/aa/status 直到就绪或出错
        for (var i = 0; i < 300; i++) {
          await Future<void>.delayed(const Duration(seconds: 1));
          if (!mounted) return;
          final st = await ApiClient.instance.get('/api/aa/status');
          if (!mounted) return;
          status = st['status'] as String? ?? 'idle';
          _setStatus(status);
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
      if (mounted) _busy.value = false;
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
    return Column(
      children: [
        Container(
          height: 38,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              Text('资源',
                  style: TextStyle(fontSize: 12, color: palette.textSecondary, fontWeight: FontWeight.w600)),
              const Spacer(),
              // 扫描忙碌态只重建这一个图标（阶段 4c）
              ListenableBuilder(
                listenable: _busy,
                builder: (context, _) => MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                      onTap: _busy.value ? null : _scan,
                      behavior: HitTestBehavior.opaque,
                      // 裸 15px 图标手机点不中：扩出触控热区。
                      child: Padding(
                        padding: const EdgeInsets.all(10),
                        child: Icon(FluentIcons.scan_camera_24_regular,
                            size: 18, color: palette.textMuted),
                      )),
                ),
              ),
            ],
          ),
        ),
        Divider(height: 1, color: palette.border),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              _tabBtn('tex', '贴图'),
              const SizedBox(width: 4),
              _tabBtn('aud', '音频'),
              const SizedBox(width: 4),
              _tabBtn('txt', '文本'),
              const SizedBox(width: 4),
              _tabBtn('explorer', '资源库'),
              const SizedBox(width: 4),
              _tabBtn('live2d', 'Live2D'),
            ],
          ),
        ),
        Divider(height: 1, color: palette.border),
        // 「资源库」/「Live2D」页签是独立面板（插件域挂载）：不共用 AA 索引的
        // 横幅、列表与导出栏，进入后整页交给对应面板。
        if (_tab == 'explorer' || _tab == 'live2d') ...[
          Expanded(
            child: _tab == 'explorer'
                ? const AssetExplorerPanel()
                : const Live2DPreviewPanel(),
          ),
        ] else ...[
        // 来源横幅：AA 状态变化只重建这一条（阶段 4c）
        ListenableBuilder(
          listenable: _aaStatus,
          builder: (context, _) => _sourceBanner(),
        ),
        Expanded(
          // 轮询/忙碌态局部订阅：重建范围限于这一段状态区，
          // 索引与横幅数据到位才走整页 setState（阶段 4c）。
          child: ListenableBuilder(
            listenable: _bodyTick,
            builder: (context, _) {
              final list = _tab == 'tex' ? _tex : (_tab == 'aud' ? _aud : _txt);
              return _aaStatus.value == 'idle'
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(FluentIcons.scan_camera_24_regular, size: 36, color: palette.borderHover),
                      const SizedBox(height: 12),
                      Text('尚未扫描游戏资源\n点击右上角扫描按钮建立索引',
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 12, color: palette.textHint)),
                      const SizedBox(height: 10),
                      if (_busy.value)
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
                          return HoverTexPreview(
                            keyName: _tab == 'tex' ? key : '',
                            child: MouseRegion(
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
                                      ? palette.hover
                                      : Colors.transparent,
                                  borderRadius: BorderRadius.circular(4),
                                  border: Border.all(
                                      color: selected
                                          ? accentColor
                                          : Colors.transparent),
                                ),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: Text(key,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                              fontSize: 12,
                                              color: palette.textPrimary)),
                                    ),
                                    // 预览入口按钮：手机端不必依赖双击（双击易与
                                    // 滚动惯性冲突且无提示），桌面双击保留不变。
                                    GestureDetector(
                                      onTap: () => _preview(key),
                                      behavior: HitTestBehavior.opaque,
                                      child: Padding(
                                        padding: const EdgeInsets.all(8),
                                        child: Icon(
                                            FluentIcons.eye_24_regular,
                                            size: 14,
                                            color: palette.textHint),
                                      ),
                                    ),
                                    if (selected)
                                      Icon(
                                          FluentIcons.checkmark_24_regular,
                                          size: 12,
                                          color: accentColor),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        );
                        },
                      ),
                    ),
                    Divider(height: 1, color: palette.border),
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
                                style: TextStyle(
                                    fontSize: 11, color: palette.statusOk)),
                          ],
                        ],
                      ),
                    ),
                  ],
                );
            },
          ),
        ),
        ],
      ],
    );
  }

  /// 资源来源状态横幅：内置资源包 > 已检测游戏目录 > 未就绪；扫描中优先显示扫描态。
  Widget _sourceBanner() {
    final scanning = _aaStatus.value == 'scanning';
    final bundled = _bundled;

    final Color fg;
    final Color bg;
    final Color border;
    final Widget leading;
    final String text;
    if (scanning) {
      fg = palette.textSecondary;
      bg = palette.card;
      border = palette.border;
      leading = const SizedBox(
          width: 13, height: 13, child: CircularProgressIndicator(strokeWidth: 2));
      text = '正在扫描资源…';
    } else if (bundled != null) {
      final name = (bundled['name'] as String?) ?? '未知';
      final tex = (bundled['tex'] as num?)?.toInt() ?? 0;
      final aud = (bundled['aud'] as num?)?.toInt() ?? 0;
      fg = palette.accentLight;
      bg = accentColor.withValues(alpha: 0.14);
      border = accentColor.withValues(alpha: 0.38);
      leading = Icon(FluentIcons.box_24_regular, size: 14, color: palette.accentLight);
      text = '内置资源包：$name（纹理 $tex / 音频 $aud）';
    } else if (_detectedDir.isNotEmpty) {
      fg = palette.statusOk;
      bg = palette.statusOk.withValues(alpha: 0.12);
      border = palette.statusOk.withValues(alpha: 0.35);
      leading = Icon(FluentIcons.hard_drive_24_regular, size: 14, color: palette.statusOk);
      text = '游戏目录：已检测到 $_detectedDir';
    } else {
      fg = palette.statusTan;
      bg = palette.statusTan.withValues(alpha: 0.12);
      border = palette.statusTan.withValues(alpha: 0.35);
      leading = Icon(FluentIcons.warning_24_regular, size: 14, color: palette.statusTan);
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
            color: selected ? palette.hover : Colors.transparent,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(label,
              style: TextStyle(
                  fontSize: 12,
                  color: selected ? palette.textHigh : palette.textSecondary)),
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
              style: TextStyle(color: palette.textSecondary, fontSize: 13)),
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
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Text('内容过大，仅预览前 200K 字符',
                  style: TextStyle(fontSize: 11, color: palette.textHint)),
            ),
            Divider(height: 1, color: palette.border),
          ],
          Expanded(
            child: fluent.Scrollbar(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: SelectableText(_text!,
                    style: TextStyle(
                        fontFamily: 'Consolas',
                        fontSize: 12.5,
                        color: palette.textPrimary,
                        height: 1.5)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
