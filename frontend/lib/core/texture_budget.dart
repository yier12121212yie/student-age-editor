
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// 纹理预算（GPU 峰值）中枢 —— 「降 GPU 峰值占用」阶段 5。
///
/// ## 为什么必须有这一层
///
/// 全库有三层自研图片缓存（`TexBytesCache` / `_BytesLru` / Live2D `_renderCache`），
/// 但它们存的全是**压缩字节**（webp / png 原文件），吃 Dart 堆、**不吃 GPU**。
/// GPU 纹理的唯一来源是引擎的 [ImageCache]——它存的是**解码后 RGBA 位图**。
/// 而这一层此前**全库从未配置**（[main] 里没有任何 `imageCache` 设置），走
/// Flutter 默认 **1000 条 / 100 MiB**，且没有任何回收挂钩。于是：
///
/// * 调那三层字节缓存，GPU 峰值纹丝不动；
/// * 切模组、关预览都不 `evict`，解码位图只进不出。
///
/// ## 峰值量级（RGBA = 4 B/px，取自仓库真实资源 `Tex2D/`）
///
/// | 资源 | 尺寸 | 解码后 |
/// | --- | --- | --- |
/// | 背景（295 张） | 2048×1152 | 9.0 MB |
/// | 背景（74 张） | 1920×1080 | 8.3 MB |
/// | 立绘 | 557×1000 | 2.1 MB |
/// | SDF 字体图集（3 张） | **8192×8192** | **256 MB** |
/// | 全屏 CG（4096 档） | 4096×2304 | 37.7 MB |
///
/// 结论：**背景/立绘源图最大就是 2048 宽，解到 2048 已是无损**（Flutter 不会
/// 超过源分辨率上采样），此前的 4096 档纯属浪费；而 8192² 的字体图集若按原尺寸
/// 解码，单张就是 256 MB —— 那不是「慢」，是一次崩溃。所以所有 `cacheWidth`
/// 都必须走这里，不允许各处再手写 `math.min(4096, ...)`。
class TextureBudget {
  const TextureBudget._();

  /// 解码档位（物理像素宽）。缩略图 / 面板 / 悬停共用同一档，避免同一张图按
  /// 4~6 个不同尺寸各解一份位图（阶段 5 · A3「一条目/一个尺寸」）。
  ///
  /// 选档依据实际显示盒：44（头像位）/ 56（面板行）/ 172（画廊格）/ 280（背景格）
  /// / 340（悬停浮层）/ 舞台画布。取 64 / 176 / 352 / 1024 / 2048 覆盖两套 DPR。
  static const List<int> kDecodeTiers = <int>[64, 176, 352, 1024, 2048];

  /// 解码宽硬上限：任何调用点都不得越过它。
  static const int kMaxDecodeWidth = 4096;

  /// 最小解码宽：比它还小的盒子没必要按更小尺寸解（省不了多少，还多一档）。
  static const int kMinDecodeWidth = 64;

  /// 背景上限。真实资源最大 2048×1152 —— 解到 2048 已经**无损**。
  /// （此前用 factor 2 → 4096 档，单张 37.7 MB，纯浪费。）
  static const int kBackgroundMaxDecodeWidth = 2048;

  /// 立绘上限。真实资源约 557×1000，2048 同为无损上限。
  static const int kPortraitMaxDecodeWidth = 2048;

  /// 全屏 CG 上限：唯一真正需要 4K 的场景，保留 4096。
  static const int kCgMaxDecodeWidth = 4096;

  /// 「看原图」全屏预览上限。刻意给 4096 而不是「不设限」：不设限时双击一张
  /// 8192² 字体图集就是 256 MB 单张纹理。
  static const int kFullViewMaxDecodeWidth = 4096;

  /// Live2D 渲染 PNG 上限（面板通常不到 1000 逻辑宽，留放大余量）。
  static const int kLive2dMaxDecodeWidth = 1536;

  static const int _desktopSizeBytes = 48 << 20;
  static const int _mobileSizeBytes = 32 << 20;
  static const int _webSizeBytes = 64 << 20;

  static const int _desktopEntries = 200;
  static const int _mobileEntries = 120;
  static const int _webEntries = 240;

  /// 是否移动端目标（不含 Web）。用 [defaultTargetPlatform] 而非 dart:io，
  /// 保证 Web 构建不会因为引入 `dart:io` 而炸。
  static bool get isMobileTarget =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  /// 当前平台的解码位图预算（字节）。
  static int get sizeBytes =>
      kIsWeb ? _webSizeBytes : (isMobileTarget ? _mobileSizeBytes : _desktopSizeBytes);

  /// 当前平台的解码位图预算（条目数）。
  static int get entryLimit =>
      kIsWeb ? _webEntries : (isMobileTarget ? _mobileEntries : _desktopEntries);

  /// 收紧引擎解码位图预算。启动时调用一次——必须在任何图片开始解码之前。
  static void apply() {
    final cache = PaintingBinding.instance.imageCache;
    cache.maximumSizeBytes = sizeBytes;
    cache.maximumSize = entryLimit;
  }

  /// 场景级回收：切模组 / 关闭（或切走）预览时调用，把已缓存但**未被引用**的
  /// 解码位图全部丢掉，让下一场从零开始而不是在旧峰值上继续堆。
  ///
  /// 刻意**不**调 [ImageCache.clearLiveImages]：正被 widget 引用的纹理不该被
  /// 抽走（那会让在屏图片闪一下再重解）。[ImageCache.clear] 只清缓存表，
  /// 持有引用的存活位图不受影响。
  static void releaseScene() {
    PaintingBinding.instance.imageCache.clear();
  }

  /// 精确回收若干字节载荷对应的解码位图（Live2D 淘汰、替换舞台背景等
  /// 「换掉这一张」的场景）。
  ///
  /// 必须复刻 [Image.memory] 的 provider 形状：一旦给了 `cacheWidth`，[Image]
  /// 会把 provider 包进 [ResizeImage]，此时只 evict [MemoryImage] 匹配不到任何
  /// 条目——只会白跑一趟。所以两档都按档位逐个试。
  ///
  /// 尽力而为：失败不抛（回收是优化，不是正确性）。
  static Future<void> evictBytes(Iterable<Uint8List?> payloads) async {
    for (final b in payloads) {
      if (b == null) continue;
      try {
        await MemoryImage(b).evict();
        for (final tier in kDecodeTiers) {
          await ResizeImage(MemoryImage(b), width: tier).evict();
        }
      } catch (_) {
        // 忽略：回收失败不影响渲染。
      }
    }
  }

  /// 把物理像素宽吸到档位上：**向上**取最近一档（绝不下取——下取会让图变小、
  /// 视觉变糊）。超过最大档时不吸档，原值交给 [max] 夹。
  static int snapUpToTier(int px) {
    for (final t in kDecodeTiers) {
      if (t >= px) return t;
    }
    return px;
  }

  /// 纯函数版解码宽计算（无 BuildContext，便于单测）。
  ///
  /// [logicalWidth] 显示宽（逻辑像素）；[dpr] 设备像素比；[factor] overscan
  /// 系数（`BoxFit.cover` 裁切时源图可能比显示盒宽）；[max] 上限；
  /// [snapToTier] 是否吸档。显示宽未知（无限约束且无显式宽）返回 null，
  /// 保持原图解码尺寸。
  static int? decodeWidthFor(
    double? logicalWidth,
    double dpr, {
    double factor = 1,
    int max = kMaxDecodeWidth,
    bool snapToTier = true,
  }) {
    final w = logicalWidth;
    if (w == null || !w.isFinite || w <= 0) return null;
    final safeDpr = (dpr.isFinite && dpr > 0) ? dpr : 1.0;
    final safeFactor = (factor.isFinite && factor > 0) ? factor : 1.0;
    final safeMax = max < kMinDecodeWidth ? kMinDecodeWidth : max;

    var px = (w * safeDpr * safeFactor).ceil();
    if (px < kMinDecodeWidth) px = kMinDecodeWidth;
    if (snapToTier) px = snapUpToTier(px);
    return px > safeMax ? safeMax : px;
  }

  /// 控件内快捷版：自己读 [MediaQuery] 的 DPR。
  static int? decodeWidth(
    BuildContext context,
    double? logicalWidth, {
    double factor = 1,
    int max = kMaxDecodeWidth,
    bool snapToTier = true,
  }) {
    final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1;
    return decodeWidthFor(logicalWidth, dpr,
        factor: factor, max: max, snapToTier: snapToTier);
  }
}

/// 按「条数 + 总字节」双上限的字节 LRU（存**压缩字节**，吃 Dart 堆）。
///
/// 给 Live2D 用：它的 `_renderCache` 原先是一个**裸 `Map`，没有任何上限**，
/// 而注释自己写着「Live2D 渲染 PNG 可达数 MB」——切 20 个表达式就是 20 张常驻。
class BoundedByteLru {
  BoundedByteLru({required this.maxEntries, required this.maxBytes});

  final int maxEntries;
  final int maxBytes;

  final Map<String, Uint8List> _m = <String, Uint8List>{};
  int _bytes = 0;

  int get length => _m.length;
  int get bytes => _bytes;

  /// 命中即续命（Map 插入序即 LRU 序）；未命中返回 null。
  Uint8List? operator [](String key) {
    final v = _m.remove(key);
    if (v != null) _m[key] = v;
    return v;
  }

  bool containsKey(String key) => _m.containsKey(key);

  /// 写入并返回**被淘汰的载荷**（调用方负责把它们也从引擎 [ImageCache] 里赶走，
  /// 否则压缩字节没了、解码位图还占着）。
  List<Uint8List> put(String key, Uint8List value) {
    final dropped = <Uint8List>[];
    final old = _m.remove(key);
    if (old != null) _bytes -= old.length;
    _m[key] = value;
    _bytes += value.length;
    while ((_bytes > maxBytes || _m.length > maxEntries) && _m.length > 1) {
      final oldest = _m.remove(_m.keys.first);
      if (oldest == null) continue;
      _bytes -= oldest.length;
      dropped.add(oldest);
    }
    return dropped;
  }

  /// 清空并交出全部载荷（组件销毁时用，便于连带回收解码位图）。
  List<Uint8List> clear() {
    final all = _m.values.toList(growable: false);
    _m.clear();
    _bytes = 0;
    return all;
  }
}
