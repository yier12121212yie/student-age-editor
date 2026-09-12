/// 共享图片资源选择器：大窗口网格画廊 + 单击直接预览（免双击）。
///
/// 供三处复用：
/// - 剧情图媒体资产面板的「放大选择」按钮；
/// - Schema 编辑器立绘/背景 url 字段的「从资源选择」按钮；
/// - 剧情图 Inspector 的 bg/url 字段。
///
/// 同时导出进程级 [TexBytesCache]（tex key → 字节缓存 + 并发去重）与
/// [TexThumb]（异步缩略图组件），替代各页面散落的 `_thumbs`/`_imgCache`，
/// 避免同一 key 被多处重复请求 `/api/aa/preview`。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../../core/api_client.dart';
import '../files/file_viewer.dart' show ImagePreview;
import '../../core/app_theme.dart';

// ---------------- 进程级字节缓存 ----------------

/// tex key → PNG/WebP 字节的进程级缓存（null = 已加载但失败，避免反复请求）。
class TexBytesCache {
  TexBytesCache._();
  static final Map<String, Uint8List?> _cache = {};
  static final Map<String, Future<Uint8List?>> _inflight = {};

  static Uint8List? peek(String key) => _cache[key];

  /// 命中缓存直接返回；未命中发起请求并去重并发。
  static Future<Uint8List?> load(String key) {
    if (key.isEmpty) return Future.value(null);
    final cached = _cache[key];
    if (_cache.containsKey(key)) return Future.value(cached);
    final inflight = _inflight[key];
    if (inflight != null) return inflight;
    final f = _fetch(key).whenComplete(() => _inflight.remove(key));
    _inflight[key] = f;
    return f;
  }

  static Future<Uint8List?> _fetch(String key) async {
    try {
      final r = await ApiClient.instance
          .post('/api/aa/preview', body: {'kind': 'tex', 'key': key});
      final data = r['data'];
      final bytes = data is String ? base64Decode(data) : null;
      _cache[key] = bytes;
      return bytes;
    } catch (_) {
      _cache[key] = null;
      return null;
    }
  }

  /// 测试隔离用。
  static void clear() => _cache.clear();

  /// 测试注入：直接填充缓存，跳过网络栈（假时钟下 http 栈不与 pumpAndSettle
  /// 交错完成）。
  static void debugPut(String key, Uint8List? bytes) => _cache[key] = bytes;

  /// 字段 url 值 → 候选 tex key 列表：原样 + 去 bg/ cg/ 路径前缀。
  /// 本体数据 url 带 `bg/`、`cg/` 前缀而 AA 索引 key 不带，两个方向都可能命中。
  static List<String> keyCandidates(String raw) {
    final v = raw.trim();
    if (v.isEmpty) return const [];
    final cands = <String>[v];
    for (final p in const ['bg/', 'cg/']) {
      if (v.startsWith(p)) cands.add(v.substring(p.length));
    }
    return cands;
  }

  /// 依次尝试 [keyCandidates] 直到命中；全失败返回 null。
  static Future<Uint8List?> loadSmart(String raw) async {
    String? firstKey;
    Uint8List? bytes;
    for (final k in keyCandidates(raw)) {
      firstKey ??= k;
      bytes = await load(k);
      if (bytes != null) return bytes;
    }
    // 全部未命中：把负结果缓存到首个候选，避免同值反复试探
    if (firstKey != null && !_cache.containsKey(firstKey)) _cache[firstKey] = null;
    return bytes;
  }
}

// ---------------- 合并元数据（mod + 本体） ----------------

/// BgCfg id → tex key（GET /api/preview/meta 的 bgKeys，mod+本体合并）。
/// TalkCfg.bg 缩略图与「选图反查 id」共用；加载失败返回 null。
Map<String, String>? _bgKeysCache;
Future<Map<String, String>?>? _bgKeysInflight;

/// 当前已就绪的 id→key 映射；未拉取过返回 null（不发请求）。
/// 供 BgIdThumb 渲染期被动消费——渲染路径禁止发起请求（Inspector 的
/// 「回显不发额外请求」测试即此约束），拉取只由用户点击路径触发。
Map<String, String>? get bgIdKeyMapOrNull => _bgKeysCache;

/// 拉取（幂等 + 并发去重）。失败缓存 null 不重试。
Future<Map<String, String>?> loadBgIdKeyMap() async {
  if (_bgKeysCache != null) return _bgKeysCache;
  if (_bgKeysInflight != null) return _bgKeysInflight;
  final f = _fetchBgKeys().whenComplete(() => _bgKeysInflight = null);
  _bgKeysInflight = f;
  return f;
}

Future<Map<String, String>?> _fetchBgKeys() async {
  try {
    final r = await ApiClient.instance.get('/api/preview/meta');
    final raw = r is Map ? r['bgKeys'] : null;
    if (raw is Map) {
      _bgKeysCache = {
        for (final e in raw.entries)
          if (e.value != null) e.key.toString(): e.value.toString(),
      };
    }
  } catch (_) {}
  return _bgKeysCache;
}

/// 选择器选中的 tex key → BgCfg id（basename 归一后比对）。找不到返回 null。
Future<String?> bgIdForKey(String pickedKey) async {
  final map = await loadBgIdKeyMap();
  if (map == null || pickedKey.isEmpty) return null;
  String base(String k) {
    final s = k.toLowerCase();
    final i = s.lastIndexOf('/');
    return i >= 0 ? s.substring(i + 1) : s;
  }

  final target = base(pickedKey);
  for (final e in map.entries) {
    if (base(e.value) == target) return e.key;
  }
  return null;
}

// ---------------- 异步缩略图组件 ----------------

/// 按需加载的缩略图：命中缓存即显，未命中后台加载后刷新。
class TexThumb extends StatefulWidget {
  const TexThumb({
    super.key,
    required this.keyName,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.borderRadius,
  });
  final String keyName;
  final double? width;
  final double? height;
  final BoxFit fit;
  final BorderRadius? borderRadius;

  @override
  State<TexThumb> createState() => _TexThumbState();
}

class _TexThumbState extends State<TexThumb> {
  Uint8List? _bytes;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant TexThumb old) {
    super.didUpdateWidget(old);
    if (old.keyName != widget.keyName) _load();
  }

  Future<void> _load() async {
    if (TexBytesCache.keyCandidates(widget.keyName).isEmpty) return;
    final bytes = await TexBytesCache.loadSmart(widget.keyName);
    if (!mounted) return;
    setState(() {
      _bytes = bytes;
      _done = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    Widget child;
    if (bytes != null) {
      child = Image.memory(bytes, fit: widget.fit, gaplessPlayback: true);
    } else {
      child = Center(
        child: Icon(
          FluentIcons.image_24_regular,
          size: 14,
          color: _done ? palette.iconDisabled : palette.borderHover,
        ),
      );
    }
    final box = SizedBox(
      width: widget.width,
      height: widget.height,
      child: child,
    );
    return widget.borderRadius != null
        ? ClipRRect(borderRadius: widget.borderRadius!, child: box)
        : box;
  }
}

/// 引用 bg id 的字段（如 TalkCfg.bg）的当前值缩略图：
/// id → key（[bgIdKeyMapOrNull]）→ [TexThumb]。
///
/// 渲染路径**不发请求**：地图未就绪时显示占位，待用户点过「选背景图」或
/// 缩略图后（拉取入口）随宿主重建显示。
class BgIdThumb extends StatelessWidget {
  const BgIdThumb({super.key, required this.id, this.width = 60, this.height = 45});
  final String id;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    final key = (id.isEmpty || id == '0') ? null : bgIdKeyMapOrNull?[id];
    if (key == null || key.isEmpty) {
      return Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          color: palette.panel,
          borderRadius: BorderRadius.circular(AppRadius.xs),
          border: Border.all(color: palette.border),
        ),
        child: Icon(FluentIcons.image_24_regular,
            size: 13, color: palette.iconDisabled),
      );
    }
    return TexThumb(
      keyName: key,
      width: width,
      height: height,
      borderRadius: BorderRadius.circular(AppRadius.xs),
    );
  }
}

// ---------------- 悬停预览浮层 ----------------

/// 悬停 0.4s 后在条目旁浮现大图预览浮层（免双击）。
/// [keyName] 为空时组件惰性（原样返回 child），方便非贴图条目复用同一包装。
class HoverTexPreview extends StatefulWidget {
  const HoverTexPreview({super.key, required this.keyName, required this.child});
  final String keyName;
  final Widget child;

  @override
  State<HoverTexPreview> createState() => _HoverTexPreviewState();
}

class _HoverTexPreviewState extends State<HoverTexPreview> {
  Timer? _timer;
  OverlayEntry? _entry;
  static const _delay = Duration(milliseconds: 400);
  static const _cardW = 340.0;
  static const _cardH = 250.0;

  void _enter() {
    if (TexBytesCache.keyCandidates(widget.keyName).isEmpty) return;
    _timer?.cancel();
    _timer = Timer(_delay, _show);
  }

  void _exit() {
    _timer?.cancel();
    _entry?.remove();
    _entry = null;
  }

  void _show() {
    if (_entry != null || !mounted) return;
    final box = context.findRenderObject() as RenderBox?;
    final overlay = Overlay.of(context);
    final screen = MediaQuery.sizeOf(context);
    Offset pos = const Offset(0, 0);
    if (box != null && box.attached) {
      pos = box.localToGlobal(Offset(box.size.width + 10, 0));
      if (pos.dx + _cardW > screen.width - 8) {
        pos = Offset(
            (box.localToGlobal(Offset.zero).dx - _cardW - 10)
                .clamp(8.0, screen.width - _cardW - 8),
            pos.dy);
      }
      pos = Offset(
          pos.dx, pos.dy.clamp(8.0, (screen.height - _cardH - 8).clamp(8.0, double.infinity)));
    }
    _entry = OverlayEntry(
      builder: (_) => Positioned(
        left: pos.dx,
        top: pos.dy,
        child: IgnorePointer(
          child: Container(
            width: _cardW,
            height: _cardH,
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: palette.card,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: palette.borderHover),
              boxShadow: [
                BoxShadow(
                  color: palette.bgDeep2.withValues(alpha: 0.6),
                  blurRadius: 16,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: TexThumb(
                    keyName: widget.keyName,
                    fit: BoxFit.contain,
                    borderRadius: BorderRadius.circular(5),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    widget.keyName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 10, color: palette.textHint),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    overlay.insert(_entry!);
  }

  @override
  void dispose() {
    _exit();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => _enter(),
      onExit: (_) => _exit(),
      child: widget.child,
    );
  }
}

// ---------------- 大窗口选择器 ----------------

/// 打开图片资源选择器，返回选中的 tex key 列表（取消返回 null）。
/// [multiSelect] 为 false 时列表至多一项。
Future<List<String>?> showImageAssetPicker(
  BuildContext context, {
  String title = '选择图片资源',
  bool multiSelect = false,
  List<String> initialSelected = const [],
}) {
  return fluent.showDialog<List<String>>(
    context: context,
    builder: (_) => ImageAssetPickerDialog(
      title: title,
      multiSelect: multiSelect,
      initialSelected: initialSelected,
    ),
  );
}

/// 资产分类页签。
enum _AssetTab { all, bg, cg, other }

class ImageAssetPickerDialog extends StatefulWidget {
  const ImageAssetPickerDialog({
    super.key,
    this.title = '选择图片资源',
    this.multiSelect = false,
    this.initialSelected = const [],
  });
  final String title;
  final bool multiSelect;
  final List<String> initialSelected;

  @override
  State<ImageAssetPickerDialog> createState() => _ImageAssetPickerDialogState();
}

class _ImageAssetPickerDialogState extends State<ImageAssetPickerDialog> {
  List<String> _tex = [];
  List<String> _cgKeys = const [];
  Map<String, List<int>> _meta = {};
  bool _loading = true;
  bool _scanning = false;
  String _error = '';

  _AssetTab _tab = _AssetTab.all;
  String _filter = '';
  final Set<String> _selected = {};
  String? _previewKey;

  @override
  void initState() {
    super.initState();
    _selected.addAll(widget.initialSelected);
    _previewKey = widget.initialSelected.isEmpty ? null : widget.initialSelected.first;
    _loadKeys();
  }

  Future<void> _loadKeys() async {
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      final r = await ApiClient.instance.get(
        '/api/aa/keys',
        query: {'limit': '4000'},
      );
      if (!mounted) return;
      final meta = <String, List<int>>{};
      final rawMeta = r['meta'];
      if (rawMeta is Map) {
        rawMeta.forEach((k, v) {
          if (v is List && v.length == 2 && v[0] is num && v[1] is num) {
            meta[k.toString()] = [(v[0] as num).toInt(), (v[1] as num).toInt()];
          }
        });
      }
      setState(() {
        _tex = ((r['tex'] as List?) ?? const []).cast<String>();
        _meta = meta;
        _loading = false;
      });
      _loadCgKeys();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '加载资源索引失败: $e';
      });
    }
  }

  /// CG 口径与剧情图资产面板一致：scope=flow 由后端按尺寸过滤。
  Future<void> _loadCgKeys() async {
    try {
      final r = await ApiClient.instance.get(
        '/api/aa/keys',
        query: {'limit': '800', 'scope': 'flow'},
      );
      if (!mounted) return;
      setState(() {
        _cgKeys = ((r['tex'] as List?) ?? const []).cast<String>();
      });
    } catch (_) {
      // CG 过滤失败只影响该页签，保持空列表
    }
  }

  /// 扫描游戏资源并轮询直到完成（与资源页/资产面板流程一致）。
  Future<void> _scan() async {
    if (_scanning) return;
    setState(() => _scanning = true);
    try {
      var status = await ApiClient.instance
          .post('/api/aa/scan')
          .then((r) => r['status'] as String? ?? 'scanning');
      for (var i = 0; i < 300; i++) {
        await Future<void>.delayed(const Duration(seconds: 1));
        if (!mounted) return;
        final st = await ApiClient.instance.get('/api/aa/status');
        status = st['status'] as String? ?? 'idle';
        if (status != 'scanning') break;
      }
      if (mounted) await _loadKeys();
    } catch (_) {
      // 扫描失败保持空列表与错误提示
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  List<String> get _filtered {
    Iterable<String> pool = switch (_tab) {
      _AssetTab.bg => _tex.where((k) => k.startsWith('bg/')),
      _AssetTab.cg => _cgKeys,
      _AssetTab.other => _tex.where(
          (k) => !k.startsWith('bg/') && !_cgKeys.contains(k)),
      _AssetTab.all => _tex,
    };
    final q = _filter.trim().toLowerCase();
    if (q.isNotEmpty) pool = pool.where((k) => k.toLowerCase().contains(q));
    return pool.toList();
  }

  void _onTapTile(String key) {
    setState(() {
      _previewKey = key;
      if (widget.multiSelect) {
        if (!_selected.add(key)) _selected.remove(key);
      } else {
        _selected
          ..clear()
          ..add(key);
      }
    });
  }

  void _confirm() {
    if (_selected.isEmpty) return;
    Navigator.of(context).pop(_selected.toList());
  }

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.sizeOf(context);
    // ContentDialog 默认 constraints 上限 368 且自带 20 padding：大窗口必须
    // 显式传 constraints，内容宽度相应减去左右 padding。
    final w = math.min(960.0, screen.width - 60);
    final h = math.min(700.0, screen.height - 150);
    return fluent.ContentDialog(
      constraints: BoxConstraints(maxWidth: w, maxHeight: h + 140),
      title: Row(
        children: [
          const Icon(FluentIcons.image_24_regular,
              size: 15, color: Color(0xFF6C5CE7)),
          const SizedBox(width: 8),
          Expanded(child: Text(widget.title)),
          Text(
            widget.multiSelect
                ? '已选 ${_selected.length} 项'
                : (_selected.isEmpty ? '单击图片直接预览' : '已选：${_selected.first}'),
            style: TextStyle(fontSize: 11, color: palette.textHint),
          ),
        ],
      ),
      content: SizedBox(
        width: w - 40,
        height: h,
        child: _buildBody(),
      ),
      actions: [
        fluent.Button(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        fluent.FilledButton(
          onPressed: _selected.isEmpty ? null : _confirm,
          child: Text(widget.multiSelect ? '确定（${_selected.length}）' : '使用所选'),
        ),
      ],
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(
        child: SizedBox(
          width: 26,
          height: 26,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (_error.isNotEmpty && _tex.isEmpty) {
      return _buildEmpty(
        icon: FluentIcons.error_circle_24_regular,
        label: _error,
        action: fluent.Button(onPressed: _loadKeys, child: const Text('重试')),
      );
    }
    if (_tex.isEmpty) {
      return _buildEmpty(
        icon: FluentIcons.image_24_regular,
        label: '尚未扫描游戏资源，无法浏览立绘 / 背景图片',
        action: fluent.FilledButton(
          onPressed: _scanning ? null : _scan,
          child: Text(_scanning ? '扫描中…' : '扫描游戏资源'),
        ),
      );
    }
    final list = _filtered;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildTopBar(),
              Divider(height: 1, color: palette.border),
              Expanded(child: _buildGrid(list)),
            ],
          ),
        ),
        VerticalDivider(width: 1, color: palette.border),
        SizedBox(width: 300, child: _buildPreviewPane()),
      ],
    );
  }

  Widget _buildEmpty({
    required IconData icon,
    required String label,
    required Widget action,
  }) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 30, color: palette.iconDisabled),
          const SizedBox(height: 10),
          Text(label,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12.5, color: palette.textSecondary)),
          const SizedBox(height: 14),
          action,
        ],
      ),
    );
  }

  Widget _buildTopBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      child: Row(
        children: [
          _tabBtn(_AssetTab.all, '全部'),
          const SizedBox(width: 4),
          _tabBtn(_AssetTab.bg, '背景'),
          const SizedBox(width: 4),
          _tabBtn(_AssetTab.cg, 'CG'),
          const SizedBox(width: 4),
          _tabBtn(_AssetTab.other, '其他'),
          const Spacer(),
          Flexible(
            child: SizedBox(
              width: 200,
              child: fluent.TextBox(
                placeholder: '搜索资源 key',
                prefix: const Icon(FluentIcons.search_24_regular, size: 13),
                style: const TextStyle(fontSize: 12),
                onChanged: (v) => setState(() => _filter = v),
              ),
            ),
          ),
          const SizedBox(width: 6),
          fluent.Tooltip(
            message: '重新扫描游戏资源',
            child: fluent.IconButton(
              icon: _scanning
                  ? const SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(FluentIcons.arrow_sync_24_regular, size: 14),
              onPressed: _scanning ? null : _scan,
            ),
          ),
        ],
      ),
    );
  }

  Widget _tabBtn(_AssetTab tab, String label) {
    final selected = _tab == tab;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => setState(() => _tab = tab),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: selected ? palette.tintAccent : Colors.transparent,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              color: selected ? palette.accentLight : palette.textSecondary,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildGrid(List<String> list) {
    if (list.isEmpty) {
      return Center(
        child: Text('没有匹配的资源',
            style: TextStyle(fontSize: 12, color: palette.textHint)),
      );
    }
    return GridView.builder(
      padding: const EdgeInsets.all(8),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 172,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        childAspectRatio: 0.82,
      ),
      itemCount: list.length,
      itemBuilder: (context, i) => _tile(list[i]),
    );
  }

  Widget _tile(String key) {
    final size = _meta[key];
    final selected = _selected.contains(key);
    final isPreviewing = _previewKey == key;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => _onTapTile(key),
        child: Container(
          decoration: BoxDecoration(
            color: palette.panel,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: selected
                  ? palette.accentLight
                  : isPreviewing
                      ? palette.borderHover
                      : palette.border,
              width: selected || isPreviewing ? 1.6 : 1,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    TexThumb(keyName: key, fit: BoxFit.contain),
                    if (selected)
                      Positioned(
                        top: 4,
                        right: 4,
                        child: Container(
                          width: 18,
                          height: 18,
                          decoration: const BoxDecoration(
                            color: Color(0xFF6C5CE7),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(FluentIcons.check_24_regular,
                              size: 11, color: Colors.white),
                        ),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(6, 4, 6, 5),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      key,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 10, color: palette.textPrimary),
                    ),
                    if (size != null)
                      Text('${size[0]}×${size[1]}',
                          style:
                              TextStyle(fontSize: 9, color: palette.textHint)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 右侧固定预览区：单击即预览（免双击），滚轮缩放 / 拖拽平移。
  Widget _buildPreviewPane() {
    final key = _previewKey;
    if (key == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(FluentIcons.image_24_regular, size: 26, color: palette.iconDisabled),
            const SizedBox(height: 8),
            Text('单击左侧图片\n在此直接预览',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11.5, color: palette.textHint)),
          ],
        ),
      );
    }
    return _PreviewPane(key: ValueKey(key), keyName: key, meta: _meta);
  }
}

/// 预览区状态体：future 存在 State 里，避免 build 期间新建 future 导致
/// FutureBuilder 无限重订阅。
class _PreviewPane extends StatefulWidget {
  const _PreviewPane({super.key, required this.keyName, required this.meta});
  final String keyName;
  final Map<String, List<int>> meta;

  @override
  State<_PreviewPane> createState() => _PreviewPaneState();
}

class _PreviewPaneState extends State<_PreviewPane> {
  late Future<Uint8List?> _future;

  @override
  void initState() {
    super.initState();
    _future = TexBytesCache.loadSmart(widget.keyName);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List?>(
      future: _future,
      builder: (context, snap) {
        final bytes = snap.data;
        if (bytes == null) {
          return Center(
            child: snap.connectionState == ConnectionState.waiting
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : Text('图片不可用（资源缺失或未导出）',
                    textAlign: TextAlign.center,
                    style:
                        TextStyle(fontSize: 11.5, color: palette.textHint)),
          );
        }
        final size = widget.meta[widget.keyName];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: ImagePreview(bytes: bytes, name: widget.keyName)),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
              child: Text(
                '${widget.keyName}${size != null ? '  ·  ${size[0]}×${size[1]}' : ''}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 10.5, color: palette.textHint),
              ),
            ),
          ],
        );
      },
    );
  }
}
