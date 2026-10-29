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
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../../core/api_client.dart';
import '../files/file_viewer.dart' show ImagePreview;
import '../../core/app_theme.dart';
import '../../core/empty_state.dart';
import '../../core/responsive.dart';
import '../../core/app_dialogs.dart';
import '../../core/long_task_progress.dart';
import '../../core/texture_budget.dart';
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

  /// 本轮**瞬时失败**的 key（连不上后端 / 超时 / 5xx / 403 / 200 但无可用载荷）。
  ///
  /// 这类失败**不写入 [_cache]**：它与「后端确实没有这张贴图」是两回事。旧实现
  /// 把两者一视同仁地按 `_cache[key] = null` 记下来，于是冷启动 / 后端未就绪 /
  /// 长连接被复用关闭时的那一次失败，会让这张贴图在**本进程内永远**显示占位图
  /// —— 只有重建该组件（切对白触发 `KeyedSubtree` 重挂）才会重新发起请求，
  /// 这正是「进入剧情舞台人物/背景是占位图，要换几次页才显示」的根因。
  ///
  /// 记录在这里只为让渲染组件知道自己「可以再试」（见 [TexThumb]）。
  static final Set<String> _transient = {};

  /// [key] 上一次尝试是否属「瞬时失败」（可安全重试）。
  static bool isTransientFailure(String key) => _transient.contains(key);

  /// 清空某 key 的瞬时失败标记（成功拿到来源时调用）。
  static void _clearTransient(String key) => _transient.remove(key);

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
    final f = _fetch(key);
    _inflight[key] = f;
    // 完成后把 key 移出在飞去重表。
    //
    // **绝不能**写成 `_fetch(key).whenComplete(() => _inflight.remove(key))`：
    // `Map.remove` 返回的正是刚存进 `_inflight[key]` 的 `f` 本身，而
    // `whenComplete` 会等待回调**返回的 Future**，于是 `f` 等待自己，永不完成
    // —— 调用方的 `await` 永远挂起。表现出来就是：首次进入剧情舞台时，贴图
    // 请求其实已经成功（副作用里已 `_put` 进缓存），但 `loadSource` 的返回值
    // 永不落地，`TexThumb` 停在占位图上；直到用户切换一次对白，同一 key 命中
    // `_cache` 分支（`Future.value` 直接完成）才显示 —— 即「要切换一次才正常」。
    //
    // 这里用 `then<void>` + 块体（返回 void，不产生自等待），并把返回的 Future
    // 交给 `unawaited` 显式丢弃。
    unawaited(f.then<void>(
      (_) {
        _inflight.remove(key);
      },
      onError: (_) {
        _inflight.remove(key);
      },
    ));
    return f;
  }

  /// 兼容旧消费方：只要字节（URL 来源返回 null）。
  static Future<Uint8List?> load(String key) async =>
      (await loadSource(key))?.bytes;

  /// 优先二进制高速通道，失败/旧后端再降级旧版 Base64 通道。
  static Future<TexSource?> _fetch(String key) async {
    // 1) GET /api/aa/raw：直接拿原始字节，彻底跳过 Base64 + JSON + Isolate 解码。
    //    对象存储命中时后端回 302，http 客户端自动跳转拉取；web 端若因 CORS
    //    无法读取跳转结果，会抛错落到下面的旧通道降级（旧通道回 URL 供 <img>）。
    try {
      final resp = await ApiClient.instance
          .getRaw('/api/aa/raw', query: {'kind': 'tex', 'key': key});
      if (resp.statusCode == 200) {
        final bytes = resp.bodyBytes;
        if (bytes.isNotEmpty && ApiClient.looksBinaryPayload(bytes)) {
          final src = TexSource.bytes(bytes);
          _put(key, src);
          _clearTransient(key);
          return src;
        }
        if (bytes.isEmpty) {
          // 200 但空载荷：后端贴图尚未就绪，属瞬时失败，可重试。
          _transient.add(key);
          return null;
        }
        // 200 但载荷不像图片字节（桩服务把任意路径回成 JSON）：降级旧通道。
      } else if (resp.statusCode == 422) {
        // 索引里有这张贴图但没有可解码文件：确定性结论，负缓存避免反复试探。
        _transient.remove(key);
        _put(key, null);
        return null;
      }
      // 404/405（旧后端无该路由 / 桩服务）/ 400 / 5xx：降级旧通道。
    } catch (_) {
      // 传输层失败（连接被拒 / 超时 / CORS 读取失败）：降级旧通道。
    }
    return _fetchLegacy(key);
  }

  /// 旧版通道：POST /api/aa/preview -> Base64 JSON。保留为降级路径与测试兼容。
  static Future<TexSource?> _fetchLegacy(String key) async {
    try {
      final r = await ApiClient.instance
          .post('/api/aa/preview', body: {'kind': 'tex', 'key': key});
      // 对象存储立绘：服务端只回 URL，客户端自行请求。
      final url = r['url'];
      if (url is String && url.isNotEmpty) {
        final src = TexSource.url(url);
        _put(key, src);
        _clearTransient(key);
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
      if (bytes == null || bytes.isEmpty) {
        // 200 但载荷为空（后端贴图尚未就绪 / 解码空转）：**不能**当作
        // 「这张贴图不存在」缓存下来，否则本次进程生命周期内它永远显示占位图。
        _transient.add(key);
        return null;
      }
      final src = TexSource.bytes(bytes);
      _put(key, src);
      _clearTransient(key);
      return src;
    } on ApiException catch (e) {
      // 404 / 422：后端明确答复「没有这张贴图」或「有但解不开」——这是确定性
      // 结论，可以负缓存（避免同一 key 反复试探）。
      if (e.statusCode == 404 || e.statusCode == 422) {
        _transient.remove(key);
        _put(key, null);
        return null;
      }
      // 403 / 400 index not ready / 5xx 等：后端还没就绪，属瞬时失败，保持可重试。
      _transient.add(key);
      return null;
    } catch (_) {
      // 连接被拒 / 超时 / 长连接被复用关闭（ClientException）等传输层失败：
      // 同样是瞬时失败，绝不能负缓存 —— 这是「必须切页才显示」的主要来源。
      _transient.add(key);
      return null;
    }
  }

  /// 测试隔离用。
  static void clear() {
    _cache.clear();
    _transient.clear();
    _bytes = 0;
  }

  /// 测试注入：直接填充缓存，跳过网络栈（假时钟下 http 栈不与 pumpAndSettle
  /// 交错完成）。
  static void debugPut(String key, Uint8List? bytes) =>
      _put(key, bytes == null ? null : TexSource.bytes(bytes));

  /// 字段 url 值 → 候选 tex key 列表：原样 + 规范化路径 + 去前缀 + 去扩展名。
  /// 支持模组中的反斜杠路径（如 Mods\wuqixiaoya\Textures\Bg\x.png）、本体 bg/、cg/、role/ 前缀等。
  static List<String> keyCandidates(String raw) {
    final v = raw.trim();
    if (v.isEmpty || v == '[]' || v == 'null' || v == 'None' || v == '{}') return const [];
    final cands = <String>[];

    void addCand(String s) {
      final trimmed = s.trim();
      if (trimmed.isNotEmpty && trimmed != '[]' && trimmed != 'null' && !cands.contains(trimmed)) {
        cands.add(trimmed);
      }
    }

    addCand(v);
    if (v.contains('\\')) {
      addCand(v.replaceAll('\\', '/'));
    }

    var prevCount = 0;
    while (cands.length > prevCount) {
      final snapshot = List<String>.from(cands.sublist(prevCount));
      prevCount = cands.length;

      for (final base in snapshot) {
        if (base.contains('\\')) {
          addCand(base.replaceAll('\\', '/'));
        }

        final lower = base.toLowerCase();

        // 1. 模组路径去 Mods/<name>/
        if (lower.startsWith('mods/')) {
          final firstSlash = base.indexOf('/');
          if (firstSlash >= 0) {
            final secondSlash = base.indexOf('/', firstSlash + 1);
            if (secondSlash >= 0) {
              addCand(base.substring(secondSlash + 1));
            }
          }
        }

        // 2. 剥离 Textures/ 前缀
        if (lower.startsWith('textures/')) {
          addCand(base.substring(9));
        }

        // 3. 去 bg/、cg/、role/、role2/ 前缀
        for (final p in const ['bg/', 'cg/', 'role/', 'role2/']) {
          if (lower.startsWith(p)) {
            addCand(base.substring(p.length));
          }
        }

        // 4. 剥离常见图片扩展名（.png, .webp, .jpg, .jpeg）
        for (final ext in const ['.png', '.webp', '.jpg', '.jpeg']) {
          if (lower.endsWith(ext)) {
            addCand(base.substring(0, base.length - ext.length));
          }
        }

        // 5. 文件名 basename
        final slashIdx = base.lastIndexOf('/');
        if (slashIdx >= 0 && slashIdx + 1 < base.length) {
          addCand(base.substring(slashIdx + 1));
        }
      }
    }

    return cands;
  }

  /// 依次尝试 [keyCandidates] 直到命中；全失败返回 null。
  static Future<TexSource?> loadSmartSource(String raw) async {
    String? firstKey;
    TexSource? src;
    var transient = false;
    for (final k in keyCandidates(raw)) {
      firstKey ??= k;
      src = await loadSource(k);
      if (src != null && src.isNotEmpty) return src;
      if (_transient.contains(k)) transient = true;
    }
    // 全部未命中：**只有确定「不存在」时**才把负结果缓存到首个候选（避免同值
    // 反复试探）；若失败里含瞬时失败，保持不缓存，让之后的重试能够真正重发。
    if (!transient && firstKey != null && !_cache.containsKey(firstKey)) {
      _put(firstKey, null);
    }
    if (transient) {
      // 瞬时失败还要标到**调用方传入的原始 key** 上：消费方（[TexThumb]）用它判
      // `isTransientFailure` 决定是否自重试，而真正发请求的是内层候选。只标内层
      // 时，若首个候选是「确定性缺失」、后续候选才瞬时失败，外层会误判成不可
      // 重试 —— 那张图便一直停在占位图上。
      _transient.add(raw.trim());
    }
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

/// 人物 id → `{base, base2, l2d}`（GET /api/preview/meta 的 charKeys，mod+本体
/// 合并）。与 [bgIdKeyMapOrNull] 同一次请求填充；供剧情舞台按小学/中学阶段取
/// 立绘 key（比工作区 PersonCfg 更全：含随包官方表与 base 抽取表）。未拉取过返回 null。
Map<String, dynamic>? _charKeysCache;

/// 合并元数据请求代次：只采纳「最新一次」请求的结果。
///
/// 刷新（切模组 / 本地导入新背景）与进入页面可能各发一次请求，两个响应到达
/// 顺序不定；先发的旧响应若整表为空，会把新拿到的数据覆盖回空 —— 舞台于是
/// 又退回占位图，且再没有任何东西会二次刷新。用代次把迟到响应丢掉。
int _metaSeq = 0;

/// 单次拉取内部的**即时**重试次数（不挂定时器，只在一次拉取内重发）。
const int _metaAttempts = 3;

/// 拉取失败 / 拿到空表后的**自动重试**间隔（无需用户操作）。
///
/// 后端冷启动、刚切完模组、刚被拉起时，`GET /api/preview/meta` 可能返回
/// **空表**（HTTP 200，`bgKeys`/`charKeys` 皆空 —— 后端尚未装载模组与本体
/// 数据时就是这种形态）。旧实现把空表当终态缓存下来（`_bgKeysCache = {}`），
/// 而 `loadBgIdKeyMap()` 见到非 null 就直接返回，于是**本次进程内再也不会
/// 重新拉取**，舞台与缩略图永远停在占位图上；只有用户切换对白/事件触发的
/// 强制刷新（`refreshBgIdKeyMap`）才会兜回来 —— 这正是「导演模式要换几次页
/// 才正常显示人物和背景」的根因。
///
/// 现在失败/空表都会自动重试（上限 [_metaMissLimit] 次），用户什么都不用做。
/// 由挂载在舞台宿主上的 [MergedMetaAutoRetry] 负责按时重发（定时器归 State
/// 所有、随 dispose 取消，避免测试结束留下未消费的定时器）。测试可改小/置零。
Duration debugMetaRetryDelay = const Duration(seconds: 2);

/// 连续「未就绪」（请求失败或拿到空表）的自动重试上限。
///
/// 连续计数在**拿到非空映射**时清零；显式刷新（[refreshBgIdKeyMap]）也清零。
/// 有上限是为了防住「后端确实没有背景表」这种正常的空表情形——否则渲染路径
/// 的兜底重试会随着每次重建无限发请求。
const int _metaMissLimit = 8;

int _metaMissCount = 0;

/// 合并元数据是否**可用**（已拉到非空映射）。
///
/// 「缓存非 null」不等于可用：空表也是非 null，消费方拿它查 id 只会得到
/// null。判定可用性必须看**非空**，否则空表会被当成「已经加载过」而永不重试。
bool get mergedMetaUsable => _bgKeysCache != null && _bgKeysCache!.isNotEmpty;

/// 连续未就绪次数是否已达上限（不再自动重试，需显式 [refreshBgIdKeyMap]）。
bool get mergedMetaRetryExhausted => _metaMissCount >= _metaMissLimit;

/// 渲染路径的兜底入口：元数据不可用时补发一次拉取（已可用/正在拉取/已放弃
/// 自动重试时是空操作）。由 [MergedMetaAutoRetry] 周期调用，使「首次拉取失败
/// 或拿到空表」时仍会重发，无需用户切页触发重建。
void ensureMergedMeta() {
  if (mergedMetaUsable) return;
  if (_metaMissCount >= _metaMissLimit) return;
  unawaited(loadBgIdKeyMap());
}

/// 当前已就绪的 id→key 映射；未拉取过返回 null（不发请求）。
/// 供 BgIdThumb 渲染期被动消费——渲染路径禁止发起请求（Inspector 的
/// 「回显不发额外请求」测试即此约束），拉取只由用户点击路径触发。
Map<String, String>? get bgIdKeyMapOrNull => _bgKeysCache;

/// 当前已就绪的人物 id→立绘 stage 映射；未拉取过返回 null（不发请求）。
Map<String, dynamic>? get charKeysMapOrNull => _charKeysCache;

/// 合并元数据（bgKeys / charKeys）**就绪或刷新后的修订号**。
///
/// 渲染期读取 [bgIdKeyMapOrNull] / [charKeysMapOrNull] 的组件（[BgIdThumb]、
/// 剧情舞台的立绘/背景）**不发请求**，地图未就绪时只能显示占位图；旧实现里
/// 元数据异步到达后没有任何广播，必须靠一次用户交互（切换对白）触发的重建
/// 才会换成真实图片 —— 表现为「进入页面人物/背景是占位，要换几次页才显示」。
///
/// 现在 [_fetchBgKeys] 填充缓存后自增本修订号，订阅方（见 [BgIdThumb] 与各
/// 舞台宿主）据此自动重建，无需用户操作。
final ValueNotifier<int> mergedMetaRevision = ValueNotifier<int>(0);

/// 拉取（幂等 + 并发去重）。
///
/// [force] 为真时忽略已有缓存强制重拉（本地导入新背景 / 切换模组后调用）。
/// **不清空旧缓存**：旧映射留在原处继续供舞台渲染，避免「刷新窗口内舞台先退回
/// 占位图」的闪烁；新数据到达后 [mergedMetaRevision] 自增，订阅方一次换到新图。
///
/// 「已就绪」的判定是 [mergedMetaUsable]（非空），不是「缓存非 null」：空表
/// 必须继续尝试，否则会被当成加载完成而永久停留在占位图。
Future<Map<String, String>?> loadBgIdKeyMap({bool force = false}) async {
  if (!force && mergedMetaUsable) return _bgKeysCache;
  final inflight = _bgKeysInflight;
  if (inflight != null) return inflight;
  // 连续未就绪达上限后不再自动发请求（显式 [refreshBgIdKeyMap] 不受限）。
  if (!force && _metaMissCount >= _metaMissLimit) return _bgKeysCache;
  _metaMissCount++;
  final f = _fetchBgKeys().whenComplete(() => _bgKeysInflight = null);
  _bgKeysInflight = f;
  return f;
}

/// 合并元数据「未就绪就自动重拉」的驱动组件。
///
/// 挂在剧情舞台宿主（经典剧情视图 / 三栏剧情编辑器）上，负责在元数据不可用时
/// 按 [debugMetaRetryDelay] 周期重发请求，直到拿到非空映射或重试配额耗尽。
///
/// 关键点：定时器由本 State **持有**，并在 [State.dispose] 里取消。此前把定时器
/// 放在进程级全局变量里，出了 widget 树也不会被取消——测试结束后 `flutter_test`
/// 会因为「A Timer is still pending even after the widget tree was disposed」而
/// 让所有渲染舞台的用例集体失败；让 State 拥有它即可随树的销毁一并取消。
class MergedMetaAutoRetry extends StatefulWidget {
  const MergedMetaAutoRetry({super.key, required this.child});

  final Widget child;

  @override
  State<MergedMetaAutoRetry> createState() => _MergedMetaAutoRetryState();
}

class _MergedMetaAutoRetryState extends State<MergedMetaAutoRetry> {
  Timer? _timer;
  bool _pending = false; // 已排定一次重试（定时器或微任务），避免重复排期

  @override
  void initState() {
    super.initState();
    // 元数据就绪（修订号自增）时立即停掉重试，不再空转。
    mergedMetaRevision.addListener(_onMetaChanged);
    _tick();
  }

  @override
  void dispose() {
    mergedMetaRevision.removeListener(_onMetaChanged);
    _timer?.cancel();
    _timer = null;
    _pending = false;
    super.dispose();
  }

  void _onMetaChanged() {
    if (mergedMetaUsable) {
      _timer?.cancel();
      _timer = null;
      _pending = false;
      return;
    }
    _schedule();
  }

  /// 补发一次拉取并排定下一次重试。
  void _tick() {
    if (mergedMetaUsable) return;
    ensureMergedMeta();
    _schedule();
  }

  void _schedule() {
    if (_pending) return;
    if (mergedMetaUsable || mergedMetaRetryExhausted) return;
    final delay = debugMetaRetryDelay;
    if (delay <= Duration.zero) {
      // 测试用零延迟：走微任务立即再试，不产生定时器。
      _pending = true;
      scheduleMicrotask(() {
        _pending = false;
        if (!mounted) return;
        _tick();
      });
      return;
    }
    _pending = true;
    _timer = Timer(delay, () {
      _pending = false;
      _timer = null;
      if (!mounted) return;
      _tick();
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

Future<Map<String, String>?> _fetchBgKeys() async {
  final seq = ++_metaSeq;
  Map<String, String>? bg;
  Map<String, dynamic>? ck;
  for (var attempt = 1; attempt <= _metaAttempts; attempt++) {
    try {
      final r = await ApiClient.instance.get('/api/preview/meta');
      final raw = r is Map ? r['bgKeys'] : null;
      if (raw is Map && raw.isNotEmpty) {
        bg = {
          for (final e in raw.entries)
            if (e.value != null) e.key.toString(): e.value.toString(),
        };
      }
      final c = r is Map ? r['charKeys'] : null;
      if (c is Map && c.isNotEmpty) ck = c.cast<String, dynamic>();
    } catch (_) {
      // 后端未就绪 / 首次建索引时可能直接失败：交给下面的重试。
    }
    if (bg != null && bg.isNotEmpty) break;
    // 已被更新的请求取代：本次结果作废，避免覆盖更新的数据。
    if (seq != _metaSeq) return _bgKeysCache;
  }
  if (seq != _metaSeq) return _bgKeysCache;
  // 非破坏性写入：拿不到（或拿到空的）新数据时保留上一份，而不是把缓存清掉。
  final wroteBg = bg != null && bg.isNotEmpty;
  final wroteChar = ck != null && ck.isNotEmpty;
  if (wroteBg) _bgKeysCache = bg;
  if (wroteChar) _charKeysCache = ck;
  if (mergedMetaUsable) {
    // 真正就绪：清零连续未就绪计数，驱动组件随之停掉定时重试。
    _metaMissCount = 0;
  }
  // 只有真的写入了新数据才广播：失败/空表无新数据可显示，广播只会白重建。
  // 重试由 [MergedMetaAutoRetry] 的定时器负责，不依赖这里自增。
  if (wroteBg || wroteChar) {
    // 元数据（首次到达 / 重新拉取）已刷新：广播一次，让所有在 build 中被动消费
    // 它的舞台/缩略图立即重建，不必等用户切换对白才从占位图切到真实图片。
    mergedMetaRevision.value++;
  }
  return _bgKeysCache;
}

/// 测试隔离用：清空合并元数据缓存，下一次 [loadBgIdKeyMap] 重新请求。
/// 同时清零未就绪计数（自动重试的定时器归 [MergedMetaAutoRetry] 所有，随树销毁
/// 自动取消，此处无需处理）。
@visibleForTesting
void debugResetMergedMetaCache() {
  _bgKeysCache = null;
  _charKeysCache = null;
  _bgKeysInflight = null;
  _metaMissCount = 0;
  _metaSeq++; // 作废在飞的旧请求，避免其迟到响应污染下一次用例
}

/// 强制重拉合并元数据（本地导入新背景 / 切换模组后调用）。
/// 显式刷新视作「用户/程序重试」：清零未就绪计数，让自动重试重新获得配额。
Future<Map<String, String>?> refreshBgIdKeyMap() {
  _metaMissCount = 0;
  return loadBgIdKeyMap(force: true);
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

// 解码宽度计算已上收到 `core/texture_budget.dart`（阶段 5 · D14「档位唯一来源」）：
// 本文件原先自带的 `_decodeCacheWidth` 上限写死 4096、不做档位收敛，已删除。
// 一律改用 `TextureBudget.decodeWidth(context, w, factor:, max:)`。

/// [TexThumb] 瞬时失败后的**自重试**间隔（无需用户操作）。
///
/// 「瞬时失败」= 后端贴图尚未就绪（200 空载荷 / 403 / 5xx / 传输层断开），
/// 这类失败**不进负缓存**（见 [TexBytesCache._transient]），所以重发是有效的。
///
/// 旧实现把「重试」寄托在**宿主重建**上（`didUpdateWidget` 里顺带重试）；但元数据
/// 就绪后宿主往往不再重建 —— 那张贴图便永远停在占位图上，直到用户切一次对白
/// （换掉 `ValueKey` → 组件重挂 → 重新发请求）。这正是「进剧情舞台人物/背景是
/// 占位图，要切一次才正常显示」的根因：**依赖无关的重建来重试是不可靠的**。
///
/// 现在由组件自己按本间隔重试（上限 [TexThumb] 的 `_maxAttempts`），定时器归
/// State 所有、`dispose` 时取消。测试可改小/置零（置零走微任务，不留定时器）。
Duration debugTexRetryDelay = const Duration(milliseconds: 800);

/// 按需加载的缩略图：命中缓存即显，未命中后台加载后刷新。
/// 支持 [keyCandidates] 候选链回退（如：表情差分变体 → 基础立绘）。
class TexThumb extends StatefulWidget {
  const TexThumb({
    super.key,
    this.keyName = '',
    this.keyCandidates,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.alignment = Alignment.center,
    this.borderRadius,
  });
  final String keyName;
  final List<String>? keyCandidates;
  final double? width;
  final double? height;
  final BoxFit fit;
  final AlignmentGeometry alignment;
  final BorderRadius? borderRadius;

  @override
  State<TexThumb> createState() => _TexThumbState();
}

class _TexThumbState extends State<TexThumb> {
  TexSource? _src;
  bool _done = false;

  /// 上次尝试是否属「瞬时失败」（后端未就绪 / 传输层失败）。
  ///
  /// 这类失败**不进负缓存**，重发是有效的，所以组件必须自己把它救回来：见
  /// [_scheduleRetry]。仅靠「宿主重建时顺带重试」不够 —— 元数据就绪后宿主不再
  /// 重建，那张图就一直停在占位图上，直到用户切一次对白把组件重挂。
  bool _transient = false;

  /// 累计发起次数与代数：代数用于丢弃过期结果（重试期间又发生一次重建）。
  int _attempts = 0;
  int _token = 0;

  /// 瞬时失败的自重试定时器与排期标记（归本 State 所有，[dispose] 里取消）。
  Timer? _retryTimer;
  bool _retryScheduled = false;

  /// 单个组件最多尝试次数（含首次）。限定上限避免后端长时间不可用时反复空转。
  static const int _maxAttempts = 10;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _cancelRetry();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant TexThumb old) {
    super.didUpdateWidget(old);
    final oldCands = old.keyCandidates?.join('|') ?? '';
    final newCands = widget.keyCandidates?.join('|') ?? '';
    if (old.keyName != widget.keyName || oldCands != newCands) {
      _reset();
      _load();
      return;
    }
    // 参数没变但上次是瞬时失败：宿主重建（合并元数据到达、页面刷新、用户操作
    // 等）即视为一次「后端可能已就绪」的时机，立即重试一次（撤掉待发的定时器，
    // 避免与自重试各发一次）。
    if (_src == null && _done && _transient && _attempts < _maxAttempts) {
      _cancelRetry();
      _load();
    }
  }

  void _reset() {
    _cancelRetry();
    _src = null;
    _done = false;
    _transient = false;
    _attempts = 0;
  }

  /// 瞬时失败后**自己**排定一次重试。
  ///
  /// 不能依赖「宿主之后会重建」：元数据就绪后宿主就不再重建了，靠
  /// `didUpdateWidget` 兜底等于把成功与否交给巧合 —— 用户必须切一次对白
  /// （换 `ValueKey` 让组件重挂）才能看到图。这里让组件自己按
  /// [debugTexRetryDelay] 重试，最多 [_maxAttempts] 次。
  void _scheduleRetry() {
    if (_retryScheduled || !mounted) return;
    if (_attempts >= _maxAttempts) return;
    final delay = debugTexRetryDelay;
    _retryScheduled = true;
    if (delay <= Duration.zero) {
      // 测试用零延迟：走微任务立即再试，不产生定时器。
      scheduleMicrotask(() {
        _retryScheduled = false;
        if (!mounted) return;
        _load();
      });
      return;
    }
    _retryTimer = Timer(delay, () {
      _retryScheduled = false;
      _retryTimer = null;
      if (!mounted) return;
      _load();
    });
  }

  void _cancelRetry() {
    _retryTimer?.cancel();
    _retryTimer = null;
    _retryScheduled = false;
  }

  List<String> get _effectiveCandidates {
    final list = <String>[];
    if (widget.keyCandidates != null) {
      for (final k in widget.keyCandidates!) {
        final s = k.trim();
        if (s.isNotEmpty && !list.contains(s)) list.add(s);
      }
    }
    final primary = widget.keyName.trim();
    if (primary.isNotEmpty && !list.contains(primary)) {
      list.insert(0, primary);
    }
    return list;
  }

  Future<void> _load() async {
    final cands = _effectiveCandidates;
    if (cands.isEmpty) {
      // 没有可试的 key（元数据/目录还没就绪）：重试没有意义，等宿主重建补候选。
      _cancelRetry();
      return;
    }
    if (_attempts >= _maxAttempts) {
      _cancelRetry();
      return;
    }
    _attempts++;
    final token = ++_token;
    TexSource? found;
    var transient = false;
    for (final cand in cands) {
      if (TexBytesCache.keyCandidates(cand).isEmpty) continue;
      final src = await TexBytesCache.loadSmartSource(cand);
      if (token != _token || !mounted) return; // 已被更新的一次尝试取代
      // 只有拿到「非空」来源才算命中；空来源（无字节也无 URL）要继续沿候选链
      // 回退（如表情差分缺失 → 基础立绘），否则会停在占位图上。
      if (src != null && src.isNotEmpty) {
        found = src;
        break;
      }
      if (TexBytesCache.isTransientFailure(cand)) transient = true;
    }
    if (!mounted || token != _token) return;
    setState(() {
      _src = found;
      _done = true;
      // 没拿到图且失败可重试 → 标记，并**自行**排定下一次重试。
      _transient = found == null && transient;
    });
    if (_src == null && _transient) {
      _scheduleRetry();
    } else {
      _cancelRetry();
    }
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
      // 阶段 5：档位由 TextureBudget 收敛（同一张图在这些盒子间共享同一档，
      // 不再按 4~6 个不同尺寸各解一份）。
      child = LayoutBuilder(
        builder: (context, box) => Image.memory(
          src!.bytes!,
          fit: widget.fit,
          alignment: widget.alignment,
          gaplessPlayback: true,
          cacheWidth: TextureBudget.decodeWidth(context, box.maxWidth),
        ),
      );
    } else if (src?.url != null) {
      child = TexSourceImage(
        source: src!,
        fit: widget.fit,
        alignment: widget.alignment,
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
    this.alignment = Alignment.center,
    this.errorBuilder,
  });
  final TexSource source;
  final BoxFit fit;
  final AlignmentGeometry alignment;
  final Widget Function(BuildContext, Object, StackTrace?)? errorBuilder;

  @override
  Widget build(BuildContext context) {
    final bytes = source.bytes;
    final url = source.url;
    if (bytes == null && (url == null || url.isEmpty)) {
      return const SizedBox.shrink();
    }
    // 阶段 5：本组件此前两个分支都**没给 cacheWidth**，等于按原图尺寸解码——
    // 而 `Tex2D/` 里有 8192×8192 的 SDF 字体图集，单张就是 256 MB 位图。
    // 包一层 LayoutBuilder 拿到实际盒宽，走统一档位。
    return LayoutBuilder(
      builder: (context, box) {
        final cacheWidth = TextureBudget.decodeWidth(context, box.maxWidth);
        if (bytes != null) {
          return Image.memory(bytes,
              fit: fit,
              alignment: alignment,
              gaplessPlayback: true,
              cacheWidth: cacheWidth);
        }
        return Image.network(
          url!,
          fit: fit,
          alignment: alignment,
          gaplessPlayback: true,
          cacheWidth: cacheWidth,
          webHtmlElementStrategy: WebHtmlElementStrategy.prefer,
          errorBuilder: errorBuilder,
        );
      },
    );
  }
}

/// 引用 bg id 的字段（如 TalkCfg.bg）的当前值缩略图：
/// id → key（[bgIdKeyMapOrNull]）→ [TexThumb]。
///
/// 渲染路径**不发请求**：地图未就绪时显示占位，待用户点过「选背景图」或
/// 缩略图后（拉取入口）随宿主重建显示。
class BgIdThumb extends StatelessWidget {
  const BgIdThumb({
    super.key,
    required this.id,
    this.width = 60,
    this.height = 45,
    this.fit = BoxFit.cover,
    this.alignment = Alignment.center,
  });
  final String id;
  final double width;
  final double height;
  final BoxFit fit;
  final AlignmentGeometry alignment;

  @override
  Widget build(BuildContext context) {
    // 监听合并元数据修订号：元数据异步到达（或切换模组后刷新）时自动重建，
    // 从占位图切到真实背景缩略图，无需用户再点一下（见 [mergedMetaRevision]）。
    return ValueListenableBuilder<int>(
      valueListenable: mergedMetaRevision,
      builder: (context, _, _) {
        final key = (id.isEmpty || id == '0') ? null : bgIdKeyMapOrNull?[id];
        if (key == null || key.isEmpty) {
          return Container(
            width: width,
            height: height,
            decoration: BoxDecoration(
              color: palette.panel,
              borderRadius: BorderRadius.circular(AppRadius.xxs),
              border: Border.all(color: palette.border),
            ),
            child: Icon(FluentIcons.image_24_regular,
                size: 13, color: palette.iconDisabled),
          );
        }
        return TexThumb(
          key: ValueKey('bg-thumb-$id-$key'),
          keyName: key,
          width: width,
          height: height,
          fit: fit,
          alignment: alignment,
          borderRadius: BorderRadius.circular(AppRadius.xxs),
        );
      },
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
                      // 阶段 5·「看原图」：这里刻意保留「尽量按原图看」的语义，
                      // 但**必须封顶**——不封顶时打开一张 8192×8192 的 SDF
                      // 字体图集就是 256 MB 单张纹理（直接崩）。
                      // 上限 = 屏幕宽 × DPR，再夹到 4096：比屏幕更大的分辨率在
                      // 本机看不到差别，却会把峰值按面积平方放大。
                      child: Image.memory(
                        bytes!,
                        fit: BoxFit.contain,
                        cacheWidth: TextureBudget.decodeWidth(
                            context, MediaQuery.sizeOf(context).width,
                            max: TextureBudget.kFullViewMaxDecodeWidth),
                      ),
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

  /// C5：扫描取消标志。置位后 [_scan] 的轮询循环尽快退出（不再等满 300s）。
  bool _scanAbort = false;

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
    _scanAbort = false;
    _scanning.value = true;
    try {
      var status = await ApiClient.instance
          .post('/api/aa/scan')
          .then((r) => r['status'] as String? ?? 'scanning');
      for (var i = 0; i < 300; i++) {
        await Future<void>.delayed(const Duration(seconds: 1));
        if (!mounted) return;
        if (_scanAbort) break; // C5：用户取消，不再等满 300s
        final st = await ApiClient.instance.get('/api/aa/status');
        status = st['status'] as String? ?? 'idle';
        if (status != 'scanning') break;
      }
      if (mounted && !_scanAbort) await _loadKeys();
    } catch (_) {
      // 扫描失败保持空列表与错误提示
    } finally {
      if (mounted) _scanning.value = false;
    }
  }

  /// C5：取消正在进行的扫描（前端层）。下一跳即退出轮询，不再刷新列表。
  void _cancelScan() {
    _scanAbort = true;
  }

  List<String> get _filtered {
    // (页签, 过滤词) × 数据版本缓存：数据未变时直接复用上次的过滤结果，
    // 切页签/敲搜索词之外的重建（选中、预览切换）不再全量扫描。
    final q = _filter.trim().toLowerCase();
    final cacheKey = '$_dataVersion|${_tab.index}|$q';
    final cached = _filteredCache;
    if (cached != null && _filteredCacheKey == cacheKey) return cached;
    bool isBg(String k) =>
        k.startsWith('bg/') || k.startsWith('bg_') || k.startsWith('img_');
    Iterable<String> pool = switch (_tab) {
      _AssetTab.bg => _tex.where(isBg),
      _AssetTab.cg => _cgKeys,
      _AssetTab.other => _tex.where(
          (k) => !isBg(k) && !_cgKeys.contains(k)),
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

    // C5：导入期间给进度对话框 + 「取消」。base64 通道是一次 POST，进度为不确定；
    // 取消为前端层（置位后丢弃在途结果）。
    final ctl = showLongTaskProgress(context,
        title: '导入图片', initialLabel: '上传中');
    List<Map<String, dynamic>> saved;
    try {
      saved = await importPickedLocalAssets(
        context,
        picked,
        kind: 'image',
        onStage: (label, [frac]) => ctl.update(label, frac),
        isCancelled: () => ctl.isCancelled,
      );
      ctl.finish('导入完成');
      await ctl.closed;
      if (ctl.isCancelled) return;
    } on LongTaskCancelled {
      await ctl.closed;
      return;
    } catch (e) {
      ctl.fail('导入失败');
      await ctl.closed;
      rethrow;
    } finally {
      ctl.dispose();
    }
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
    return AppContentDialog(
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
                onPressed: _scanning.value ? _cancelScan : _scan,
                child: Text(_scanning.value ? '取消扫描' : '扫描游戏资源'),
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
                // 阶段 5·4d 漏点：这里此前**没有 cacheWidth**——一个 44×44 的
                // 头像位在按原图解码。遇到 8192² 的字体图集就是 256 MB 位图换
                // 一个 44px 的显示盒（放大 186 倍的浪费）。
                // 走统一档位后 44 × DPR 会被吸到 176 档，约 124 KB。
                child: Image.memory(localBytes,
                    width: 44,
                    height: 44,
                    fit: BoxFit.contain,
                    cacheWidth: TextureBudget.decodeWidth(context, 44,
                        max: TextureBudget.kPortraitMaxDecodeWidth)),
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
    final scanBtn = ListenableBuilder(
      listenable: _scanning,
      builder: (context, _) => fluent.Tooltip(
        message: _scanning.value ? '取消扫描' : '重新扫描游戏资源',
        // 轮询态只重建这一个图标（阶段 4c）。扫描中给「取消」，不再干等。
        child: fluent.IconButton(
          icon: _scanning.value
              ? const Icon(FluentIcons.dismiss_24_regular, size: 14)
              : const Icon(FluentIcons.arrow_sync_24_regular, size: 14),
          onPressed: _scanning.value ? _cancelScan : _scan,
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
      return const EmptyState('没有匹配的资源');
    }
    return GridView.builder(
      scrollCacheExtent: const ScrollCacheExtent.pixels(210), controller: _gridScroll,
      padding: const EdgeInsets.all(8),
      // 全库没有任何 AutomaticKeepAliveClientMixin：这些 tile 不需要保活，
      // 关掉可省掉每个 tile 两层 KeepAlive/AutomaticKeepAlive 包装
      // （大画廊一次几十个 tile，纯减开销，行为不变）。
      addAutomaticKeepAlives: false,
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
                      // 阶段 5·4d 漏点：本地点选文件的预览同样缺 cacheWidth，
                      // 一个 172 档的格子会按原图解码。补上统一档位。
                      LayoutBuilder(
                        builder: (context, tile) => Image.memory(
                          _localPreviewBytes[key]!,
                          fit: BoxFit.contain,
                          gaplessPlayback: true,
                          cacheWidth:
                              TextureBudget.decodeWidth(context, tile.maxWidth),
                          // 选中文件解不出图（损坏/伪装扩展名）时回落索引缩略图。
                          errorBuilder: (_, _, _) =>
                              TexThumb(keyName: key, fit: BoxFit.contain),
                        ),
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
