import 'dart:async' show unawaited;
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'api_client_http.dart';
import 'heavy_task.dart';
import 'web_frame.dart';

/// 字节 → JSON 的**融合**解码器：`utf8.decoder.fuse(json.decoder)` 一次流式
/// 完成「UTF-8 解码 + JSON 解析」，省去 `jsonDecode(utf8.decode(bytes))` 那
/// 一份数兆～数十兆的中间 UTF-16 `String` 分配。
final Converter<List<int>, Object?> _jsonFromBytes =
    utf8.decoder.fuse(json.decoder);

/// 与本地 HTTP 后端通信的客户端（桌面/Android 直连 127.0.0.1；Web 同源）。
class ApiClient {
  ApiClient._();
  static final ApiClient instance = ApiClient._();

  /// 本地后端握手 Token（安全批次 B）。后端启动时生成随机 Token 并落盘，
  /// 桌面/Android/CLI/TUI 启动链路读出后写入此处；非空时所有请求自动携带
  /// `X-Backend-Token` 头。Web 同源与旧后端（无 Token 文件）保持 null。
  static String? backendToken;

  /// --dart-define=API_BASE=http://host:port 可整体覆盖 baseUrl（web 调试
  /// 前端与后端不同源时用）。
  static const String _apiBaseOverride = String.fromEnvironment('API_BASE');

  /// 后端地址：
  /// - 桌面/Android：本机 8765；
  /// - Web：与页面同源（后端 --web-root 托管静态资源，/api/* 优先路由），
  ///   注意各请求路径本身已带 `/api` 前缀，这里不能再拼 `/api`；
  /// - API_BASE 非空时无条件覆盖。
  String baseUrl = kIsWeb
      ? (_apiBaseOverride.isNotEmpty
          ? _apiBaseOverride
          : Uri.base.origin)
      : (_apiBaseOverride.isNotEmpty ? _apiBaseOverride : 'http://127.0.0.1:8765');

  /// 会话访问令牌（M2.4 登录 UI 接入）。非空时所有请求自动携带
  /// `Authorization: Bearer <token>` 头；桌面端恒 null，行为不变。
  String? accessToken;

  /// 长期鉴权刷新令牌（网页端「记住我」）。access token 过期时由
  /// [onRefresh] 换新；未勾选「记住我」时不持久化、仅内存。
  String? refreshToken;

  /// 收到 401 时回调（登录态失效钩子，M2.4 登录 UI 接入）。
  void Function()? onUnauthorized;

  /// access token 过期时的刷新回调：返回 true 表示已换到新 token（请求可
  /// 重试一次）。由 AuthState 注入（refreshSession）。并发 401 只触发一次。
  Future<bool> Function()? onRefresh;

  Future<bool>? _refreshInFlight;

  /// 单飞刷新：并发 401 共享同一次刷新，避免刷新风暴与令牌竞态。
  Future<bool> _ensureRefreshed() {
    final existing = _refreshInFlight;
    if (existing != null) return existing;
    final cb = onRefresh;
    if (cb == null) return Future<bool>.value(false);
    final fut = cb().then((ok) => ok, onError: (_) => false);
    _refreshInFlight = fut;
    unawaited(fut.whenComplete(() {
      if (identical(_refreshInFlight, fut)) _refreshInFlight = null;
    }));
    return fut;
  }

  /// 发送请求；遇 401 且配置了 [onRefresh] 时刷新令牌并重试一次
  /// （业务请求在鉴权失败时对后端无副作用，重试安全）。
  Future<http.Response> _sendWithRefresh(
      Future<http.Response> Function() send,
      {String method = '', String path = ''}) async {
    final sw = kDebugMode ? (Stopwatch()..start()) : null;
    http.Response resp;
    try {
      resp = await send();
      if (resp.statusCode == 401 && onRefresh != null) {
        final ok = await _ensureRefreshed();
        if (ok) resp = await send();
      }
    } catch (e) {
      if (kDebugMode && sw != null) {
        final m = method.isNotEmpty ? method : 'REQ';
        debugPrint('[ApiClient] $m $path 异常 (${sw.elapsedMilliseconds}ms): $e');
      }
      rethrow;
    }
    if (kDebugMode && sw != null) {
      final req = resp.request;
      final m = method.isNotEmpty ? method : (req?.method ?? 'REQ');
      final p = path.isNotEmpty ? path : (req?.url.path ?? '');
      final query = (req != null && req.url.hasQuery && path.isEmpty) ? '?${req.url.query}' : '';
      debugPrint(
          '[ApiClient] $m $p$query -> ${resp.statusCode} (${sw.elapsedMilliseconds}ms)');
    }
    return resp;
  }

  /// 刷新/登出专用 POST：不参与 401 自动重试（避免刷新失败时递归），
  /// 其余与 [post] 一致。
  Future<dynamic> postRefresh(String path,
      {Object? body, Duration timeout = const Duration(seconds: 15)}) async {
    final resp = await client
        .post(_uri(path),
            headers: _authHeaders({'Content-Type': 'application/json'}),
            body: jsonEncode(body ?? {}))
        .timeout(timeout);
    return _decode(resp);
  }

  /// 公开的鉴权头快照（SSE fetch 等绕过 [http.Client] 的通道使用）。
  Map<String, String> authHeaders([Map<String, String>? base]) =>
      _authHeaders(base);

  Map<String, String> _authHeaders([Map<String, String>? base]) {
    final h = <String, String>{...?base};
    final token = accessToken;
    if (token != null && token.isNotEmpty) {
      h['Authorization'] = 'Bearer $token';
    }
    final backend = backendToken;
    if (backend != null && backend.isNotEmpty) {
      h['X-Backend-Token'] = backend;
    }
    return h;
  }

  void _notifyUnauthorized(int statusCode) {
    if (statusCode == 401) {
      try {
        onUnauthorized?.call();
      } catch (_) {}
    }
  }

  /// Debug counters for performance tracking
  static int debugDecodedRows = 0;
  static int debugUiIsolateParsedRows = 0;
  static int debugOffIsolateParses = 0;

  /// 可替换的 HTTP 客户端（测试中注入 MockClient 用；默认等价于 http 全局函数）。
  ///
  /// 桌面/移动端由 [createApiClient] 放宽底层连接池并发（6 -> 32）；Web 端保持
  /// 平台默认。测试可整体替换该字段（`ApiClient.instance.client = MockClient(...)`）。
  http.Client client = createApiClient();

  Uri _uri(String path, [Map<String, String>? query]) {
    var url = baseUrl + path;
    if (query != null && query.isNotEmpty) {
      final qs = query.entries
          .map((e) => '${e.key}=${Uri.encodeQueryComponent(e.value)}')
          .join('&');
      url = '$url?$qs';
    }
    return Uri.parse(url);
  }

  Future<dynamic> get(String path, {Map<String, String>? query}) async {
    final resp = await _sendWithRefresh(
        () => client
            .get(_uri(path, query), headers: _authHeaders())
            .timeout(const Duration(seconds: 60)),
        method: 'GET',
        path: path);
    return _decodeMaybeOffload(resp);
  }

  /// P1：大响应自动把 UTF-8 + JSON 解码搬到后台 isolate。
  ///
  /// 剧情导演 / 工作室 / 事件工作台首开会并发拉 6~7 张整表（TalkCfg 可达数
  /// 十万行、数十 MB）。此前只有经典编辑器的 [getBig] 走 `compute`，其余
  /// 入口都在 UI isolate 同步 `jsonDecode`，首帧会冻结数百毫秒到数秒。
  /// ≤ 2MB 仍走同步路径，避免小响应付出 isolate 启动成本。
  Future<dynamic> _decodeMaybeOffload(http.Response resp) async {
    if (resp.statusCode >= 400 ||
        resp.bodyBytes.length <= bigIsolateThreshold) {
      return _decode(resp);
    }
    if (kDebugMode) debugOffIsolateParses++;
    // Web：compute 退化为同步，先把「正在解析」画上屏再冻住。
    final began = resp.bodyBytes.length > _webHeavyFeedbackBytes
        ? await _beginHeavyTask('正在解析 ${_megabytes(resp.bodyBytes.length)} MB 数据…')
        : false;
    try {
      final out = await compute(_decodeAnyIsolate, resp.bodyBytes);
      if (out['ok'] != true) {
        throw ApiException(resp.statusCode, 'invalid JSON response');
      }
      final payload = out['data'];
      if (kDebugMode && payload is Map && payload.length > 1000) {
        debugDecodedRows += payload.length;
      }
      return payload;
    } finally {
      _endHeavyTask(began);
    }
  }

  /// Web 主线程同步解析的可见提示阈值：比 isolate 阈值（2MB）略高——
  /// 2~3MB 的解析通常在百毫秒内，弹提示反而闪一下。
  static const int _webHeavyFeedbackBytes = 3 * 1024 * 1024;

  static String _megabytes(int bytes) => (bytes / 1048576).toStringAsFixed(1);

  /// 写提示并等一帧；返回「是否真的进入重活路径」（false = 无需清理）。
  ///
  /// 用计数器而不是单槽：导演/工作室首开会并发拉好几张整表，先完成的那张
  /// 不能把还在解析时的提示清掉。
  Future<bool> _beginHeavyTask(String label) async {
    if (!kIsWeb) return false;
    _heavyDepth++;
    HeavyTask.message.value = label;
    await nextWebPaint();
    return true;
  }

  int _heavyDepth = 0;

  void _endHeavyTask(bool began) {
    if (!began) return;
    if (_heavyDepth > 0) _heavyDepth--;
    if (_heavyDepth == 0) HeavyTask.message.value = null;
  }

  /// 二进制直发 GET（性能优化）：图片/音频走原始字节流，免 Base64 / JSON 解析 /
  /// Isolate 解码。返回原始 [http.Response]，调用方自行读 `bodyBytes` 与状态码。
  ///
  /// 与 [get] 不同，本方法**不对 4xx/5xx 抛异常**——调用方需要按 404（旧后端无
  /// 该路由 / 资源缺失）、422（索引有但无可解码文件）等状态做确定性判定或降级。
  /// 仍带 auth 头与 401 刷新重试。
  Future<http.Response> getRaw(String path,
      {Map<String, String>? query, Map<String, String>? headers}) {
    return _sendWithRefresh(
        () => client
            .get(_uri(path, query), headers: _authHeaders(headers))
            .timeout(const Duration(seconds: 60)),
        method: 'GET',
        path: path);
  }

  /// 判断 200 响应体是否**看起来**是原始二进制（而非 JSON）。
  ///
  /// 后端二进制直发路由的资源一律是 PNG/JPEG/WEBP/AVIF/GIF/… 原始字节；而桩服务
  /// （单元测试 MockClient）常把未 Mock 的路径一律回成 `200 {json}`。若把这种 JSON
  /// 载荷当成图片字节喂给 `Image.memory`，就会渲染失败并干扰降级判定。这里对首个
  /// 非空白字节做廉价嗅探：`{`/`[` 视为 JSON（非二进制）。
  static bool looksBinaryPayload(Uint8List bytes) {
    for (var i = 0; i < bytes.length; i++) {
      final c = bytes[i];
      if (c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D) continue;
      return c != 0x7B /* { */ && c != 0x5B /* [ */;
    }
    return false;
  }

  Future<dynamic> post(String path,
      {Object? body, Duration timeout = const Duration(seconds: 120)}) async {
    final resp = await _sendWithRefresh(
        () => client
            .post(_uri(path),
                headers: _authHeaders({'Content-Type': 'application/json'}),
                body: jsonEncode(body ?? {}))
            .timeout(timeout),
        method: 'POST',
        path: path);
    return _decode(resp);
  }

  Future<dynamic> put(String path,
      {Object? body, Duration timeout = const Duration(seconds: 120)}) async {
    final resp = await _sendWithRefresh(
        () => client
            .put(_uri(path),
                headers: _authHeaders({'Content-Type': 'application/json'}),
                body: jsonEncode(body ?? {}))
            .timeout(timeout),
        method: 'PUT',
        path: path);
    return _decode(resp);
  }

  /// 原始字节 PUT（本地分片上传：每片 8 MiB 直接作为请求体）。
  ///
  /// 与 [put] 共用 401 刷新重试；响应按 JSON 解析（后端分片应答是 JSON）。
  Future<dynamic> putBytes(
    String path,
    List<int> bytes, {
    String contentType = 'application/octet-stream',
    Duration timeout = const Duration(minutes: 10),
  }) async {
    final resp = await _sendWithRefresh(
        () => client
            .put(_uri(path),
                headers: _authHeaders({'Content-Type': contentType}),
                body: bytes)
            .timeout(timeout),
        method: 'PUT',
        path: path);
    return _decode(resp);
  }

  /// 后台 isolate 序列化的触发门槛（结构元素数）。40MB 表（约 10 万行）远超
  /// 门槛；小表/测试桩（几十行）走同步编码——既省一次 isolate 往返，也让
  /// `testWidgets` 的伪异步区能正常完成（真实 isolate 在该区永不返回，
  /// 会把保存 Future 悬死）。
  static const int _offloadEntryThreshold = 2000;

  /// 便宜的规模估算：只数 Map/List 长度、达到 [cap] 提前返回，不建字符串、
  /// 不深拷贝；10 万行量级在主 isolate 上也是亚毫秒级。
  static int _estimateEntries(dynamic v, [int cap = _offloadEntryThreshold]) {
    var n = 0;
    final stack = <dynamic>[v];
    while (stack.isNotEmpty) {
      final cur = stack.removeLast();
      if (cur is Map) {
        n += cur.length;
        if (n >= cap) return n;
        stack.addAll(cur.values);
      } else if (cur is List) {
        n += cur.length;
        if (n >= cap) return n;
        stack.addAll(cur);
      }
    }
    return n;
  }

  /// 大 payload 走后台 isolate 编码（性能 P0-3），小 payload 同步编码。
  Future<String> _encodeBody(Object? body) async {
    final payload = body ?? const <String, dynamic>{};
    if (_estimateEntries(payload) >= _offloadEntryThreshold) {
      final began = await _beginHeavyTask('正在整理大表数据…');
      try {
        return await compute(jsonEncode, payload);
      } finally {
        _endHeavyTask(began);
      }
    }
    return jsonEncode(payload);
  }

  /// 大表保存专用（性能 P0-3）：jsonEncode 搬进后台 isolate。
  ///
  /// 40MB 表的 jsonEncode 在主 isolate 上要跑数秒、UI 直接冻结；postRaw/
  /// putRaw 把编码挪进 `compute`，只付一次 payload 送入 isolate 的拷贝
  /// （几十毫秒级），换保存期间零卡顿。body 必须是 JSON 可表示的纯结构
  /// （Map/List/String/num/bool/null —— 直接 jsonDecode 出来的表满足）。
  /// Web 端 compute 回落为同步执行，行为等价。
  Future<dynamic> postRaw(String path,
      {Object? body, Duration timeout = const Duration(seconds: 120)}) async {
    final encoded = await _encodeBody(body);
    final resp = await _sendWithRefresh(
        () => client
            .post(_uri(path),
                headers: _authHeaders({'Content-Type': 'application/json'}),
                body: encoded)
            .timeout(timeout),
        method: 'POST',
        path: path);
    return _decode(resp);
  }

  /// 同 [postRaw]，走 PUT（cfg 大表整表写回是主要调用方）。
  Future<dynamic> putRaw(String path,
      {Object? body, Duration timeout = const Duration(seconds: 120)}) async {
    final encoded = await _encodeBody(body);
    final resp = await _sendWithRefresh(
        () => client
            .put(_uri(path),
                headers: _authHeaders({'Content-Type': 'application/json'}),
                body: encoded)
            .timeout(timeout),
        method: 'PUT',
        path: path);
    return _decode(resp);
  }

  /// 长任务发起专用 URI：给 path 追加（或合并进已有 query）`async=1`，
  /// 让后端走 202 + job_id 异步信封。path 自带 query 时用 Uri 合并而不是
  /// 手拼，避免出现 `?a=b?async=1` 这类坏 URL；已有 async 参数一律覆盖为 1。
  Uri _longTaskUri(String path) {
    final base = Uri.parse(baseUrl + path);
    final query = <String, String>{...base.queryParameters, 'async': '1'};
    return base.replace(queryParameters: query);
  }

  /// 长任务透明轮询（性能 P1-1）：POST 发起一个可能耗时的任务。
  ///
  /// 发起 POST 时自动带 `async=1`（opt-in）：后端把 AI relay/TTS/生图/
  /// 全量云同步推入后端任务队列，POST 返回 `202 {job_id}` 后自动轮询
  /// `GET /api/jobs/{id}`，任务完成后返回最终结果（即原同步响应体）；任务
  /// 失败抛 ApiException。旧后端不认识 async=1，仍同步执行并直接返回
  /// 200/4xx，原样透传 —— 调用方无感知，面板无需分支。[timeout] 约束的
  /// 是发起 POST 本身（旧后端同步路径要靠它兜底），[maxWait] 约束整个
  /// 轮询周期的墙钟上限。
  Future<dynamic> runLongTask(String path,
      {Object? body,
      Duration timeout = const Duration(seconds: 120),
      Duration pollInterval = const Duration(milliseconds: 400),
      Duration? maxWait}) async {
    final resp = await _sendWithRefresh(
        () => client
            .post(_longTaskUri(path),
                headers: _authHeaders({'Content-Type': 'application/json'}),
                body: jsonEncode(body ?? {}))
            .timeout(timeout),
        method: 'POST',
        path: path);
    if (resp.statusCode != 202) return _decode(resp);
    final payload = _tryDecodeJsonBytes(resp.bodyBytes);
    final jobId = payload is Map ? payload['job_id']?.toString() : null;
    if (jobId == null || jobId.isEmpty) {
      throw ApiException(resp.statusCode, '202 accepted without job_id');
    }
    final deadline = maxWait == null ? null : DateTime.now().add(maxWait);
    while (true) {
      if (deadline != null && DateTime.now().isAfter(deadline)) {
        throw ApiException(504, 'long task $jobId timed out');
      }
      await Future<void>.delayed(pollInterval);
      final status = await get('/api/jobs/$jobId');
      if (status is! Map) continue;
      final st = status['status']?.toString();
      if (st == 'done') return status['result'];
      if (st == 'error') {
        throw ApiException(
            status['status_code'] is int ? status['status_code'] as int : 500,
            status['error']?.toString() ?? 'long task $jobId failed');
      }
    }
  }

  Future<dynamic> delete(String path,
      {Map<String, String>? query, Object? body}) async {
    final resp = await _sendWithRefresh(
        () => client
            .delete(
                _uri(path, query),
                headers: body == null
                    ? (_authHeaders().isEmpty ? null : _authHeaders())
                    : _authHeaders({'Content-Type': 'application/json'}),
                body: body == null ? null : jsonEncode(body))
            .timeout(const Duration(seconds: 120)),
        method: 'DELETE',
        path: path);
    return _decode(resp);
  }

  dynamic _decode(http.Response resp) {
    // Track parsing metrics in debug mode
    if (kDebugMode && resp.bodyBytes.isNotEmpty) {
      final sizeMb = resp.bodyBytes.length / (1024 * 1024);
      if (sizeMb > 2.0) {
        debugOffIsolateParses++;
        // 注意：主 isolate 大包走同步 jsonDecode（getBig 才用 compute），
        // 计数器名 debugOffIsolateParses 仅表示「>2MB 大包」次数
        debugPrint(
          '[ApiClient] Large payload (${sizeMb.toStringAsFixed(2)}MB)',
        );
      } else {
        debugUiIsolateParsedRows++;
      }
    }

    if (resp.statusCode >= 400) {
      // 401：触发登录态失效钩子（M2.4）。
      _notifyUnauthorized(resp.statusCode);
      // 先判状态码再解码：4xx/5xx 可能返回纯文本/空体/HTML（代理拦截页、
      // 裸错误页），直接 jsonDecode 会抛 FormatException 掩盖真正的状态码。
      throw _apiError(resp);
    }

    final payload = _tryDecodeJsonBytes(resp.bodyBytes);
    if (payload == null) {
      throw ApiException(resp.statusCode, 'invalid JSON response');
    }

    // Count rows for tables (approximate by number of top-level keys)
    if (payload is Map && kDebugMode) {
      final rowCount = payload.length;
      if (rowCount > 1000) {
        debugDecodedRows += rowCount;
      }
    }
    return payload;
  }

  /// 从错误响应构造 ApiException：JSON 体里的 error 字段优先、code 字段
  /// 透传（如 history 空栈的 "empty" 标记），失败则用响应原文兜底。
  /// body 保留完整错误信封（阶段 2d）：409 冲突的 current_revision、
  /// reason、conflicting_keys 等字段都在信封里——只留 error 字符串会让
  /// 冲突处理链路拿不到重试所需的最新指纹。
  static ApiException _apiError(http.Response resp) {
    try {
      final payload = _jsonFromBytes.convert(resp.bodyBytes);
      if (payload is Map) {
        final e = payload['error'];
        return ApiException(
          resp.statusCode,
          e?.toString() ?? payload.toString(),
          code: payload['code']?.toString(),
          body: payload.map((k, v) => MapEntry(k.toString(), v)),
        );
      }
      return ApiException(resp.statusCode, payload.toString());
    } catch (_) {
      try {
        return ApiException(resp.statusCode, utf8.decode(resp.bodyBytes));
      } catch (_) {
        return ApiException(resp.statusCode, 'HTTP ${resp.statusCode}');
      }
    }
  }

  static dynamic _tryDecodeJsonBytes(List<int> bytes) {
    try {
      return _jsonFromBytes.convert(bytes);
    } catch (_) {
      return null;
    }
  }

  /// 超过 2MB 的响应在后台 isolate 解码（getBig 专用阈值）。
  static const int _defaultBigIsolateThreshold = 2 * 1024 * 1024;

  /// 可注入阈值（测试用：用小载荷覆盖 isolate 分支，避免 3MB 数据传输）。
  @visibleForTesting
  static int bigIsolateThreshold = _defaultBigIsolateThreshold;

  /// 测试探针：是否应把该字节数的响应搬到后台 isolate（避免在单测里真的
  /// 启动 isolate —— flutter_tester 在部分环境退出时会挂住）。
  @visibleForTesting
  static bool shouldOffloadForTest(int byteLength) =>
      byteLength > bigIsolateThreshold;

  /// 测试探针：直接验证 isolate 解码入口的 JSON 结果（不启动 isolate）。
  @visibleForTesting
  static Map<String, dynamic> decodeAnyForTest(Uint8List bytes) =>
      _decodeAnyIsolate(bytes);

  /// 大表专用 GET（S3）：
  ///
  /// body > [bigIsolateThreshold] 时把解码搬到后台 isolate（`compute`，
  /// worker 内返回已 `Map<String, dynamic>`
  /// 化的表，避免主 isolate 再 cast）；≤ 阈值走普通路径。4xx → ApiException
  /// 的判定留在主 isolate（worker 里抛异常回传会丢类型与状态码）。
  ///
  /// 仅经典编辑器全表视图需要它；剧情图/导演走 `?prefix=` 小批量（S3 主线），
  /// `compute` 把 9.8 万条对象图整体序列化送回 UI 的总工作量反而更高。
  Future<Map<String, dynamic>> getBig(String path,
      {Map<String, String>? query}) async {
    final resp = await _sendWithRefresh(
        () => client
            .get(_uri(path, query), headers: _authHeaders())
            .timeout(const Duration(seconds: 120)),
        method: 'GET',
        path: path);
    if (resp.statusCode >= 400) {
      _notifyUnauthorized(resp.statusCode);
      // 与 _decode 一致：错误体可能不是 JSON，用原文兜底而不是抛 FormatException。
      throw _apiError(resp);
    }
    final bodyBytes = resp.bodyBytes;
    if (kDebugMode) debugOffIsolateParses++;
    final heavy = bodyBytes.length > _webHeavyFeedbackBytes;
    final began = heavy
        ? await _beginHeavyTask('正在解析 ${_megabytes(bodyBytes.length)} MB 表格…')
        : false;
    try {
      if (bodyBytes.length > bigIsolateThreshold) {
        // compute 送入一次字节拷贝（40MB ≈ 十几毫秒），换来的是
        // 几秒的 jsonDecode + utf8.decode 整体移出 UI isolate，净赚。
        final out = await compute(_decodeTableIsolate, bodyBytes);
        if (kDebugMode) debugDecodedRows += out.length;
        return out;
      }
      if (kDebugMode) debugUiIsolateParsedRows++;
      final payload = _jsonFromBytes.convert(bodyBytes);
      return payload is Map<String, dynamic>
          ? payload
          : <String, dynamic>{};
    } finally {
      _endHeavyTask(began);
    }
  }
}

/// [compute] 入口：在后台 isolate 解码整表 JSON。
Map<String, dynamic> _decodeTableIsolate(Uint8List bytes) {
  final payload = _jsonFromBytes.convert(bytes);
  if (payload is Map) {
    return payload.map((k, v) => MapEntry(k.toString(), v));
  }
  return <String, dynamic>{};
}

/// [compute] 入口：通用大响应解码（Map / List / 标量都原样回传）。
///
/// 用信封包住异常状态：isolate 内抛出会丢失类型与 HTTP 状态码，调用方需要
/// 统一转成 `invalid JSON response` 的 [ApiException]。
Map<String, dynamic> _decodeAnyIsolate(Uint8List bytes) {
  try {
    return {'ok': true, 'data': _jsonFromBytes.convert(bytes)};
  } catch (e) {
    return {'ok': false, 'error': e.toString()};
  }
}

class ApiException implements Exception {
  ApiException(this.statusCode, this.message, {this.code, this.body});
  final int statusCode;
  final String message;

  /// 后端错误体的结构化 code（如 history 空栈的 "empty"）；无则为 null。
  final String? code;

  /// JSON 错误信封原文（非 JSON 的 4xx/5xx 体为 null）。
  final Map<String, dynamic>? body;
  @override
  String toString() => 'API $statusCode: $message';
}
