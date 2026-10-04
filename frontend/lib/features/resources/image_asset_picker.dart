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

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../../core/api_client.dart';
import '../files/file_viewer.dart' show ImagePreview;
import '../../core/app_theme.dart';
import '../../core/responsive.dart';
import 'local_import.dart'
    show
        PickedLocalFile,
        importPickedLocalAssets,
        pickLocalFilesResolved,
        texKeyOfImportedPath;

// ---------------- 进程级字节缓存 ----------------

/// 一张 tex 的来源：解码后的字节，或对象存储的公开 URL。
///
/// 人物图片扩展走对象存储时，服务端只回公开 URL（不代浏览器下载整张图），
/// 由客户端自行 GET；web 端对象存储通常未开 CORS，故 URL 来源用
/// `Image.network` 的 HTML `<img>` 策略渲染（见 [TexSourceImage]）。
class TexSource {
  const TexSource.bytes(this.bytes) : url = null;
  const TexSource.url(this.url) : bytes = null;
  final Uint8List? bytes;
  final String? url;

  bool get isEmpty => bytes == null && url == null;
  bool get isNotEmpty => !isEmpty;
}

/// tex key → 来源（字节或 URL）的进程级缓存（null = 已加载但失败，避免反复请求）。
///
/// LRU 上限 [_maxBytes]：画廊连续翻看几十张 1080p 原图时旧实现只进不出，
/// 原图字节常驻可到上百 MB，低端手机直接 OOM。Map 插入序即 LRU 序
/// （命中/写入都先 remove 再放回头部），超限时从最旧端淘汰。URL 来源不占
/// 字节，只按条数常驻。
class TexBytesCache {
  TexBytesCache._();
  static final Map<String, TexSource?> _cache = {};
  static final Map<String, Future<TexSource?>> _inflight = {};
  static int _bytes = 0;
  static const int _maxBytes = 64 * 1024 * 1024;

  static void _put(String key, TexSource? src) {
    _bytes -= _cache.remove(key)?.bytes?.length ?? 0;
    _cache[key] = src;
    _bytes += src?.bytes?.length ?? 0;
    while (_bytes > _maxBytes && _cache.length > 1) {
      var oldest = _cache.keys.first;
      if (oldest == key) oldest = _cache.keys.elementAt(1);
      _bytes -= _cache.remove(oldest)?.bytes?.length ?? 0;
    }
  }

  static Uint8List? peek(String key) => _cache[key]?.bytes;

  /// 命中缓存直接返回；未命中发起请求并去重并发。
  static Future<TexSource?> loadSource(String key) {
    if (key.isEmpty) return Future.value(null);
    if (_cache.containsKey(key)) {
      // 触碰即续命：移到 LRU 尾部。负缓存（值为 null）也走这里，不能 `!`。
      final cached = _cache.remove(key);
      _cache[key] = cached;
      return Future.value(cached);
    }
    final inflight = _inflight[key];
    if (inflight != null) return inflight;
    final f = _fetch(key).whenComplete(() => _inflight.remove(key));
    _inflight[key] = f;
    return f;
  }

  /// 兼容旧消费方：只要字节（URL 来源返回 null）。
  static Future<Uint8List?> load(String key) async =>
      (await loadSource(key))?.bytes;

  static Future<TexSource?> _fetch(String key) async {
    try {
      final r = await ApiClient.instance
          .post('/api/aa/preview', body: {'kind': 'tex', 'key': key});
      // 对象存储立绘：服务端只回 URL，客户端自行请求。
      final url = r['url'];
      if (url is String && url.isNotEmpty) {
        final src = TexSource.url(url);
        _put(key, src);
        return src;
      }
      final data = r['data'];
      // 大图 base64 解码（数百 KB~数 MB 字符串）搬去后台 isolate：
      // 主 isolate 同步解是手机端滑画廊掉帧的直接原因。
      final bytes = data is String
          ? (data.length > 256 * 1024
              ? await compute(_base64DecodeIsolate, data)
              : base64Decode(data))
          : null;
      final src = TexSource.bytes(bytes);
      _put(key, src);
      return src;
    } catch (_) {
      _put(key, null);
      return null;
    }
  }

  /// 测试隔离用。
  static void clear() {
    _cache.clear();
    _bytes = 0;
  }

  /// 测试注入：直接填充缓存，跳过网络栈（假时钟下 http 栈不与 pumpAndSettle
  /// 交错完成）。
  static void debugPut(String key, Uint8List? bytes) =>
      _put(key, bytes == null ? null : TexSource.bytes(bytes));

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
  static Future<TexSource?> loadSmartSource(String raw) async {
    String? firstKey;
    TexSource? src;
    for (final k in keyCandidates(raw)) {
      firstKey ??= k;
      src = await loadSource(k);
      if (src != null && src.isNotEmpty) return src;
    }
    // 全部未命中：把负结果缓存到首个候选，避免同值反复试探
    if (firstKey != null && !_cache.containsKey(firstKey)) _put(firstKey, null);
    return src;
  }

  /// 兼容旧消费方：依次尝试 [keyCandidates] 直到命中字节；全失败返回 null。
  static Future<Uint8List?> loadSmart(String raw) async =>
      (await loadSmartSource(raw))?.bytes;
}

/// [compute] 入口：后台 isolate base64 解码。
Uint8List _base64DecodeIsolate(String b64) => base64Decode(b64);

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

/// 解码宽度上限（物理像素）：显示宽（逻辑像素）× devicePixelRatio 向上取整，
/// 夹在 32–4096。尺寸未知（约束无限且无显式宽）返回 null，保持原始解码尺寸。
///
/// 阶段 4d：只降采样、不改显示尺寸——cacheWidth 不小于盒宽×DPR，渲染盒
/// 仍是原来的约束，因此视觉不变；上限 4096 只在极端大屏+原图超大时才生效。
int? _decodeCacheWidth(BuildContext context, {required double? logicalWidth}) {
  final w = logicalWidth;
  if (w == null || !w.isFinite || w <= 0) return null;
  final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1;
  final px = (w * (dpr > 0 ? dpr : 1)).ceil();
  return math.min(4096, math.max(32, px));
}

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
  TexSource? _src;
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
    final src = await TexBytesCache.loadSmartSource(widget.keyName);
    if (!mounted) return;
    setState(() {
      _src = src;
      _done = true;
    });
  }

  Widget _placeholder() => Center(
        child: Icon(
          FluentIcons.image_24_regular,
          size: 14,
          color: _done ? palette.iconDisabled : palette.borderHover,
        ),
      );

  @override
  Widget build(BuildContext context) {
    final src = _src;
    Widget child;
    if (src?.bytes != null) {
      // 缩略图盒宽决定解码宽度：画廊 172 / 面板 56 / 悬停浮层 340 这类小盒
      // 不需要 1920×1080 原图常驻解码位图。
      child = LayoutBuilder(
        builder: (context, box) => Image.memory(
          src!.bytes!,
          fit: widget.fit,
          gaplessPlayback: true,
          cacheWidth: _decodeCacheWidth(context, logicalWidth: box.maxWidth),
        ),
      );
    } else if (src?.url != null) {
      child = TexSourceImage(
        source: src!,
        fit: widget.fit,
        errorBuilder: (_, _, _) => _placeholder(),
      );
    } else {
      child = _placeholder();
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

/// 渲染一个 [TexSource]：字节走 `Image.memory`；对象存储 URL 走 `Image.network`
/// 并采用 [WebHtmlElementStrategy.prefer]（web 端用 HTML `<img>` 元素加载，
/// 无需对象存储开启 CORS；桌面端忽略该策略、正常取字节）。
class TexSourceImage extends StatelessWidget {
  const TexSourceImage({
    super.key,
    required this.source,
    this.fit = BoxFit.contain,
    this.errorBuilder,
  });
  final TexSource source;
  final BoxFit fit;
  final Widget Function(BuildContext, Object, StackTrace?)? errorBuilder;

  @override
  Widget build(BuildContext context) {
    final bytes = source.bytes;
    if (bytes != null) {
      return Image.memory(bytes, fit: fit, gaplessPlayback: true);
    }
    final url = source.url;
    if (url == null || url.isEmpty) return const SizedBox.shrink();
    return Image.network(
      url,
      fit: fit,
      gaplessPlayback: true,
      webHtmlElementStrategy: WebHtmlElementStrategy.prefer,
      errorBuilder: errorBuilder,
    );
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
    // 触屏没有 hover 事件：窄屏下点按直接进全屏预览，悬停浮层仅桌面生效。
    if (isMobileWidth(context)) {
      return GestureDetector(
        onTap: () {
          if (TexBytesCache.keyCandidates(widget.keyName).isEmpty) return;
          openFullImagePreview(context, widget.keyName);
        },
        child: widget.child,
      );
    }
    return MouseRegion(
      onEnter: (_) => _enter(),
      onExit: (_) => _exit(),
      child: widget.child,
    );
  }
}

// ---------------- 移动端全屏图片预览 ----------------

/// 全屏预览一张 tex 图片（双指缩放/拖拽平移）。供选图器底部选中条与
/// [HoverTexPreview] 的触屏分支共用。
///
/// [bytes] 非空时直接渲染内存字节——刚从电脑导入、索引/预览缓存尚未就绪时用。
Future<void> openFullImagePreview(BuildContext context, String keyName,
    {String? subtitle, Uint8List? bytes}) {
  return Navigator.of(context).push(MaterialPageRoute<void>(
    builder: (_) => _MobileImagePreviewPage(
        keyName: keyName,
        subtitle: subtitle,
        bytes: bytes),
  ));
}

class _MobileImagePreviewPage extends StatelessWidget {
  const _MobileImagePreviewPage(
      {required this.keyName, this.subtitle, this.bytes});
  final String keyName;
  final String? subtitle;
  final Uint8List? bytes;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black,
      child: Stack(
        children: [
          Positioned.fill(
            child: bytes != null
                ? InteractiveViewer(
                    maxScale: 6,
                    child: Center(
                      child: Image.memory(bytes!, fit: BoxFit.contain),
                    ),
                  )
                : FutureBuilder<TexSource?>(
                    future: TexBytesCache.loadSmartSource(keyName),
                    builder: (context, snap) {
                      final src = snap.data;
                      if (src == null || src.isEmpty) {
                        return Center(
                          child:
                              snap.connectionState == ConnectionState.waiting
                                  ? const CircularProgressIndicator(
                                      color: Colors.white, strokeWidth: 2)
                                  : const Text('图片不可用（资源缺失或未导出）',
                                      style: TextStyle(
                                          color: Colors.white54, fontSize: 12)),
                        );
                      }
                      return InteractiveViewer(
                        maxScale: 6,
                        child: Center(
                          child:
                              TexSourceImage(source: src, fit: BoxFit.contain),
                        ),
                      );
                    },
                  ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 4, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      subtitle ?? keyName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: Colors.white, fontSize: 13),
                    ),
                  ),
                  GestureDetector(
                    onTap: () => Navigator.of(context).pop(),
                    // 44×44 触控热区
                    child: const Padding(
                      padding: EdgeInsets.all(10),
                      child: Icon(Icons.close, size: 22, color: Colors.white),
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

  /// CG 页签候选（scope=flow）。用 Set：「其他」页签要逐 key contains，
  /// List 是 O(n) 每次过滤全量扫，Set 摊平成 O(1)。
  Set<String> _cgKeys = const {};
  Map<String, List<int>> _meta = {};
  bool _loading = true;
  String _error = '';

  /// 扫描/轮询态：纯视觉进度，走 ValueNotifier 局部订阅（顶栏图标 + 空态按钮），
  /// 轮询开始与结束不再重建整页画廊与预览区（阶段 4c）。
  final ValueNotifier<bool> _scanning = ValueNotifier<bool>(false);

  _AssetTab _tab = _AssetTab.all;
  String _filter = '';

  /// 过滤结果缓存：_filtered 在每次 build 与 _revealKey 里被调用，几千
  /// key 的逐项扫描不该重复付。键 = 数据版本 + 页签 + 过滤词；数据版本
  /// 在 _tex/_cgKeys 变化处（_loadKeys/_loadCgKeys/本地导入）递增失效。
  int _dataVersion = 0;
  List<String>? _filteredCache;
  String _filteredCacheKey = '';
  final Set<String> _selected = {};
  String? _previewKey;

  /// 「导入本地图片…」进行中标记（按钮禁用，避免重复弹选择器）。
  bool _importing = false;

  /// 网格滚动控制器：导入成功后把新 key 滚进可视区。
  final ScrollController _gridScroll = ScrollController();

  /// tile key → GlobalKey。只给需要「滚进可视区」的 tile 用：同一 key 复用
  /// 同一实例（GlobalKey 按实例比对，不能每帧新建），随对话框一起释放。
  final Map<String, GlobalKey> _tileKeys = {};

  /// 本地导入 key → 原始字节：后端索引尚未刷新时也能直接渲染缩略图/大图。
  final Map<String, Uint8List> _localPreviewBytes = {};

  @override
  void initState() {
    super.initState();
    _selected.addAll(widget.initialSelected);
    _previewKey = widget.initialSelected.isEmpty ? null : widget.initialSelected.first;
    _loadKeys();
  }

  @override
  void dispose() {
    _scanning.dispose();
    _gridScroll.dispose();
    super.dispose();
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
        // 索引数据变了：_filtered 的过滤缓存作废（版本号失效判据）。
        _dataVersion++;
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
        _cgKeys = ((r['tex'] as List?) ?? const []).cast<String>().toSet();
        _dataVersion++; // _cgKeys 变了：过滤缓存作废
      });
    } catch (_) {
      // CG 过滤失败只影响该页签，保持空列表
    }
  }

  /// 扫描游戏资源并轮询直到完成（与资源页/资产面板流程一致）。
  ///
  /// 阶段 4c：轮询期间只写 [_scanning]，订阅方仅顶栏图标与空态按钮两处；
  /// 索引数据到位才是结构性变化，仍由 [_loadKeys] 的 setState 重建画廊。
  Future<void> _scan() async {
    if (_scanning.value) return;
    _scanning.value = true;
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
      if (mounted) _scanning.value = false;
    }
  }

  List<String> get _filtered {
    // (页签, 过滤词) × 数据版本缓存：数据未变时直接复用上次的过滤结果，
    // 切页签/敲搜索词之外的重建（选中、预览切换）不再全量扫描。
    final q = _filter.trim().toLowerCase();
    final cacheKey = '$_dataVersion|${_tab.index}|$q';
    final cached = _filteredCache;
    if (cached != null && _filteredCacheKey == cacheKey) return cached;
    Iterable<String> pool = switch (_tab) {
      _AssetTab.bg => _tex.where((k) => k.startsWith('bg/')),
      _AssetTab.cg => _cgKeys,
      _AssetTab.other => _tex.where(
          (k) => !k.startsWith('bg/') && !_cgKeys.contains(k)),
      _AssetTab.all => _tex,
    };
    if (q.isNotEmpty) pool = pool.where((k) => k.toLowerCase().contains(q));
    final result = pool.toList();
    _filteredCache = result;
    _filteredCacheKey = cacheKey;
    return result;
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

  /// 从电脑选择图片：一次完成「选择 → 自动导入 → 预勾选」，不必先导入再回来选。
  ///
  /// 选完先落盘并重读索引，新 key 直接进画廊并选中；同时把原始字节留在内存里，
  /// 索引/预览尚未刷新时也能直接显示缩略图与大图。
  Future<void> _importLocal() async {
    if (_importing) return;
    setState(() => _importing = true);
    List<PickedLocalFile> picked;
    try {
      picked = await pickLocalFilesResolved('image');
    } catch (e) {
      if (mounted) {
        _pickerBar('打开文件选择器失败', '$e', fluent.InfoBarSeverity.error);
      }
      return;
    } finally {
      if (mounted) setState(() => _importing = false);
    }
    if (!mounted || picked.isEmpty) return;

    final saved = await importPickedLocalAssets(context, picked, kind: 'image');
    if (!mounted || saved.isEmpty) return;

    final bytesByName = <String, Uint8List>{
      for (final f in picked) f.name: f.bytes,
    };
    final fresh = <String>[];
    final localBytes = <String, Uint8List>{};
    for (final s in saved) {
      final key = texKeyOfImportedPath((s['path'] ?? '').toString());
      if (key.isEmpty) continue;
      fresh.add(key);
      final b = bytesByName[(s['name'] ?? '').toString()];
      if (b != null) localBytes[key] = b;
    }
    if (fresh.isEmpty) return;

    // 清掉搜索词再重读索引，否则新 key 可能被当前过滤条件挡住看不见。
    _filter = '';
    _tab = _AssetTab.all;
    await _loadKeys();
    if (!mounted) return;
    // _tex 是 cast() 视图，不能直接 add：合并成新列表再赋值。
    setState(() {
      final merged = [..._tex];
      for (final k in fresh) {
        // 后端索引还没收进这批文件时本地补一份，保证 tile 能渲染、能确认回传。
        if (!merged.contains(k)) merged.add(k);
      }
      _tex = merged;
      _localPreviewBytes.addAll(localBytes);
      _dataVersion++; // 本地导入的 key 进池了：过滤缓存作废
      if (widget.multiSelect) {
        _selected.addAll(fresh);
      } else {
        _selected
          ..clear()
          ..add(fresh.first);
      }
      _previewKey = fresh.first;
    });
    _revealKey(fresh.first);
  }

  void _pickerBar(
      String title, String detail, fluent.InfoBarSeverity severity) {
    fluent.displayInfoBar(
      context,
      builder: (ctx, close) => fluent.InfoBar(
        title: Text(title),
        content: Text(detail, style: const TextStyle(fontSize: 11.5)),
        severity: severity,
      ),
    );
  }

  /// 滚到并高亮某个 key：先按比例粗定位（让 tile 进入构建范围），
  /// 下一帧用 [GlobalObjectKey] 精确 ensureVisible。
  void _revealKey(String key) {
    final list = _filtered;
    final idx = list.indexOf(key);
    if (idx < 0) return;
    if (_gridScroll.hasClients) {
      final pos = _gridScroll.position;
      if (pos.hasContentDimensions && list.length > 1 && pos.maxScrollExtent > 0) {
        pos.jumpTo(pos.maxScrollExtent * idx / (list.length - 1));
      }
    }
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final tileContext = _tileKeys[key]?.currentContext;
      if (tileContext == null) return;
      await Scrollable.ensureVisible(
        tileContext,
        alignment: 0.25,
        duration: const Duration(milliseconds: 200),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.sizeOf(context);
    // ContentDialog 默认 constraints 上限 368 且自带 20 padding：大窗口必须
    // 显式传 constraints，内容宽度相应减去左右 padding。手机上贴边，内容
    // 高度预留标题+按钮行与系统栏，避免再叠头部约束顶破屏幕。
    final mobile = isMobileWidth(context);
    final w = mobile ? screen.width - 24 : math.min(960.0, screen.width - 60);
    final h = mobile
        ? math.max(320.0, screen.height - 250)
        : math.min(700.0, screen.height - 150);
    return fluent.ContentDialog(
      constraints: BoxConstraints(maxWidth: w, maxHeight: h + 140),
      title: Row(
        children: [
          Icon(FluentIcons.image_24_regular,
              size: 15, color: accentColor),
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
        // 从电脑选择：落盘到 Textures/ 后自动预勾选，无需先导入再选。
        fluent.Button(
          onPressed: _importing ? null : _importLocal,
          child: Text(_importing ? '导入中…' : '从电脑选择图片…'),
        ),
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
      // 没扫过索引也能用：空态同时给「扫描」与「从电脑选择」两条路。
      return _buildEmpty(
        icon: FluentIcons.image_24_regular,
        label: '尚未扫描游戏资源\n也可以直接从电脑选择图片',
        action: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListenableBuilder(
              listenable: _scanning,
              builder: (context, _) => fluent.FilledButton(
                onPressed: _scanning.value ? null : _scan,
                child: Text(_scanning.value ? '扫描中…' : '扫描游戏资源'),
              ),
            ),
            const SizedBox(height: 8),
            fluent.Button(
              onPressed: _importing ? null : _importLocal,
              child: const Text('从电脑选择图片…'),
            ),
          ],
        ),
      );
    }
    final list = _filtered;
    if (isMobileWidth(context)) {
      // 窄屏下固定 300px 预览侧栏会把网格压成负宽：改单栏网格 + 底部选中条，
      // 点选中条看全屏大图（HoverTexPreview 那套悬停浮层触屏不可用）。
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildTopBar(),
          Divider(height: 1, color: palette.border),
          Expanded(child: _buildGrid(list)),
          if (_previewKey != null) ...[
            Divider(height: 1, color: palette.border),
            _buildMobileSelectionBar(),
          ],
        ],
      );
    }
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

  /// 移动端底部选中条：缩略图 + key + 尺寸，整条可点，点开全屏大图。
  Widget _buildMobileSelectionBar() {
    final key = _previewKey!;
    final size = _meta[key];
    final localBytes = _localPreviewBytes[key];
    return GestureDetector(
      onTap: () => openFullImagePreview(
        context,
        key,
        subtitle: size != null ? '$key  ·  ${size[0]}×${size[1]}' : key,
        bytes: localBytes,
      ),
      behavior: HitTestBehavior.opaque,
      child: Container(
        height: 56,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Row(
          children: [
            if (localBytes != null)
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: Image.memory(localBytes,
                    width: 44, height: 44, fit: BoxFit.contain),
              )
            else
              TexThumb(
                keyName: key,
                width: 44,
                height: 44,
                fit: BoxFit.contain,
                borderRadius: BorderRadius.circular(4),
              ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(key,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 12, color: palette.textPrimary)),
                  Text(
                    size != null ? '${size[0]}×${size[1]} · 点击查看大图' : '点击查看大图',
                    style: TextStyle(fontSize: 10.5, color: palette.textHint),
                  ),
                ],
              ),
            ),
            Icon(FluentIcons.zoom_in_24_regular,
                size: 15, color: palette.textHint),
          ],
        ),
      ),
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
    final tabs = [
      _tabBtn(_AssetTab.all, '全部'),
      const SizedBox(width: 4),
      _tabBtn(_AssetTab.bg, '背景'),
      const SizedBox(width: 4),
      _tabBtn(_AssetTab.cg, 'CG'),
      const SizedBox(width: 4),
      _tabBtn(_AssetTab.other, '其他'),
    ];
    final searchBox = fluent.TextBox(
      placeholder: '搜索资源 key',
      prefix: const Icon(FluentIcons.search_24_regular, size: 13),
      style: const TextStyle(fontSize: 12),
      onChanged: (v) => setState(() => _filter = v),
    );
    final scanBtn = fluent.Tooltip(
      message: '重新扫描游戏资源',
      // 轮询态只重建这一个图标（阶段 4c）
      child: ListenableBuilder(
        listenable: _scanning,
        builder: (context, _) => fluent.IconButton(
          icon: _scanning.value
              ? const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(FluentIcons.arrow_sync_24_regular, size: 14),
          onPressed: _scanning.value ? null : _scan,
        ),
      ),
    );
    if (isMobileWidth(context)) {
      // 窄屏拆两行：页签+刷新一行、搜索整行（单行 200px 固定搜索框必溢出）。
      return Padding(
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [...tabs, const Spacer(), scanBtn]),
            const SizedBox(height: 8),
            searchBox,
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      child: Row(
        children: [
          ...tabs,
          const Spacer(),
          Flexible(child: SizedBox(width: 200, child: searchBox)),
          const SizedBox(width: 6),
          scanBtn,
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
          padding: EdgeInsets.symmetric(
              horizontal: 10, vertical: isMobileWidth(context) ? 10 : 4),
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
      controller: _gridScroll,
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
      // 稳定 key：导入后 _revealKey 靠它把 tile 滚进可视区。
      key: _tileKeys.putIfAbsent(key, () => GlobalKey(debugLabel: 'tex:$key')),
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
                    if (_localPreviewBytes[key] != null)
                      Image.memory(
                        _localPreviewBytes[key]!,
                        fit: BoxFit.contain,
                        gaplessPlayback: true,
                        // 选中文件解不出图（损坏/伪装扩展名）时回落索引缩略图。
                        errorBuilder: (_, _, _) =>
                            TexThumb(keyName: key, fit: BoxFit.contain),
                      )
                    else
                      TexThumb(keyName: key, fit: BoxFit.contain),
                    if (selected)
                      Positioned(
                        top: 4,
                        right: 4,
                        child: Container(
                          width: 18,
                          height: 18,
                          decoration: BoxDecoration(
                            color: accentColor,
                            shape: BoxShape.circle,
                          ),
                          child: Icon(FluentIcons.check_24_regular,
                              size: 11, color: palette.onAccent),
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
    // 刚从电脑导入、索引/预览缓存尚未就绪时，直接用内存字节渲染。
    final localBytes = _localPreviewBytes[key];
    if (localBytes != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: ImagePreview(bytes: localBytes, name: key)),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
            child: Text(
              key,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 10.5, color: palette.textHint),
            ),
          ),
        ],
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
  late Future<TexSource?> _future;

  @override
  void initState() {
    super.initState();
    _future = TexBytesCache.loadSmartSource(widget.keyName);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<TexSource?>(
      future: _future,
      builder: (context, snap) {
        final src = snap.data;
        if (src == null || src.isEmpty) {
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
            Expanded(
              child: src.bytes != null
                  ? ImagePreview(bytes: src.bytes!, name: widget.keyName)
                  : InteractiveViewer(
                      maxScale: 6,
                      child: Center(
                        child: TexSourceImage(source: src, fit: BoxFit.contain),
                      ),
                    ),
            ),
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
