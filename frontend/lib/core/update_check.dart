// 检查更新：查询 GitHub 最新发行版，并把「当前版本 / 上次检查 / 跳过版本 /
// 是否自动检查」持久化到本机偏好。
//
// 设计要点：
// - **版本比较与 GitHub 抓取全在 native 后端**（GET /api/update/check，规则见
//   server/services/ai_image.cpp 的 update_check）——三端共用一套规则，前端不
//   重复实现，也不需要直连 GitHub（Web/网关下同源走后端，天然免 CORS 与限流
//   放大）。
// - **当前版本来自后端** GET /api/version（构建期 -DSA_APP_VERSION 注入，与
//   产物命名同源）；前端不需要 --dart-define，也就不会出现「界面版本号与后端
//   比较版本号不一致」。
// - 网络失败（超时/断网/限流/旧后端无端点）不抛异常：统一折叠成
//   ok=false + error 文案，UI 只负责展示。
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api_client.dart';

String _str(dynamic v) => v is String ? v : (v == null ? '' : v.toString());

int _int(dynamic v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v) ?? 0;
  return 0;
}

bool _bool(dynamic v) => v == true;

/// 发行版附件（更新说明下方的下载清单）。
class UpdateAsset {
  const UpdateAsset({this.name = '', this.url = '', this.size = 0});

  final String name;
  final String url;
  final int size;

  /// 人类可读体积（旧后端可能没有 size：为 0 时返回空串）。
  String get sizeText {
    if (size <= 0) return '';
    const mb = 1024 * 1024;
    if (size >= mb) return '${(size / mb).toStringAsFixed(1)} MB';
    return '${(size / 1024).toStringAsFixed(0)} KB';
  }

  static UpdateAsset fromJson(dynamic raw) {
    if (raw is! Map) return const UpdateAsset();
    return UpdateAsset(
      name: _str(raw['name']),
      url: _str(raw['url']),
      size: _int(raw['size']),
    );
  }
}

/// GET /api/update/check 的结果（全部字段防御式解析，缺字段/错类型不抛）。
class UpdateCheckResult {
  const UpdateCheckResult({
    required this.ok,
    this.error = '',
    this.current = '',
    this.latestTag = '',
    this.latestName = '',
    this.prerelease = false,
    this.publishedAt = '',
    this.htmlUrl = '',
    this.notes = '',
    this.updateAvailable = false,
    this.assets = const [],
  });

  /// false 表示查询本身失败（网络/限流/旧后端），此时 [error] 有值。
  final bool ok;
  final String error;

  /// 本机版本（后端注入的发行版本号）。
  final String current;
  final String latestTag;
  final String latestName;
  final bool prerelease;
  final String publishedAt;
  final String htmlUrl;
  final String notes;
  final bool updateAvailable;
  final List<UpdateAsset> assets;

  /// 仓库尚无可用发行版（正常结果，不是错误）。
  bool get noRelease => ok && latestTag.isEmpty;

  /// 确实存在可下载的新版本。
  bool get hasNewVersion => ok && updateAvailable && latestTag.isNotEmpty;

  /// 最新版本的展示名：`Alpha-v0.6  正式版 v0.6`（name 为空时只用 tag）。
  String get latestText =>
      latestName.isEmpty ? latestTag : '$latestTag  $latestName';

  static UpdateCheckResult failure(String error, {String current = ''}) =>
      UpdateCheckResult(ok: false, error: error, current: current);

  static UpdateCheckResult fromJson(dynamic raw) {
    if (raw is! Map) {
      return UpdateCheckResult.failure('后端返回了意外的响应格式（非 JSON 对象）');
    }
    final assets = <UpdateAsset>[];
    final rawAssets = raw['assets'];
    if (rawAssets is List) {
      for (final a in rawAssets) {
        assets.add(UpdateAsset.fromJson(a));
      }
    }
    return UpdateCheckResult(
      ok: _bool(raw['ok']),
      error: _str(raw['error']),
      current: _str(raw['current']),
      latestTag: _str(raw['latest_tag']),
      latestName: _str(raw['latest_name']),
      prerelease: _bool(raw['prerelease']),
      publishedAt: _str(raw['published_at']),
      htmlUrl: _str(raw['html_url']),
      notes: _str(raw['notes']),
      updateAvailable: _bool(raw['update_available']),
      assets: assets,
    );
  }
}

/// 单次查询最新发行版。后端默认 6s 超时，这里留到 12s（含后端排队）。
Future<UpdateCheckResult> checkForUpdates({int timeoutSeconds = 6}) async {
  try {
    final raw = await ApiClient.instance
        .get('/api/update/check', query: {'timeout': '$timeoutSeconds'})
        .timeout(const Duration(seconds: 12));
    return UpdateCheckResult.fromJson(raw);
  } on ApiException catch (e) {
    // 旧后端没有该端点时是 404：文案里保留状态码，便于判断是「旧后端」。
    return UpdateCheckResult.failure(e.message.isEmpty ? e.toString() : e.message);
  } catch (e) {
    return UpdateCheckResult.failure(e.toString());
  }
}

/// 读取后端注入的发行版本号（GET /api/version）；旧后端/离线返回空串。
Future<String> fetchAppVersion() async {
  try {
    final raw = await ApiClient.instance
        .get('/api/version')
        .timeout(const Duration(seconds: 8));
    if (raw is Map) return _str(raw['version']);
  } catch (_) {
    // 版本号只用于展示：拿不到就不显示，不影响检查更新本身。
  }
  return '';
}

/// 全局更新状态：设置页区块与启动静默检查共用一份结果。
class UpdateState extends ChangeNotifier {
  UpdateState._();

  /// 进程内单例（沿用 ApiClient.instance 约定）。
  static final UpdateState instance = UpdateState._();

  /// 本机偏好键（仅 GUI 本地：是否自动检查、跳过哪个版本、上次尝试时间）。
  static const prefsLastAttempt = 'update_last_attempt_ms';
  static const prefsSkippedTag = 'update_skipped_tag';
  static const prefsAutoCheck = 'update_auto_check';

  /// 启动静默检查的最小间隔：同一天不重复打扰、也不重复打 GitHub。
  static const startupThrottle = Duration(hours: 24);

  /// 开发构建的版本占位（构建期未注入 -DSA_APP_VERSION）。
  static const devVersion = 'dev';

  String version = '';
  UpdateCheckResult? last;
  bool checking = false;
  bool autoCheck = true;
  String skippedTag = '';
  DateTime? lastAttemptAt;

  /// 版本号是否已知（未知时界面标注「开发构建」）。
  bool get versionKnown => version.isNotEmpty && version != devVersion;

  /// 是否有需要提示的新版本（已跳过该版本时不提示）。
  bool get hasNewVersion {
    final r = last;
    return r != null && r.hasNewVersion && r.latestTag != skippedTag;
  }

  /// 读取本机偏好（幂等；启动宿主与设置页都会调用）。
  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      autoCheck = prefs.getBool(prefsAutoCheck) ?? true;
      skippedTag = prefs.getString(prefsSkippedTag) ?? '';
      final ms = prefs.getInt(prefsLastAttempt);
      lastAttemptAt =
          ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
      notifyListeners();
    } catch (_) {
      // 读不到偏好（极少见）按默认值继续，检查更新本身不受影响。
    }
  }

  Future<void> setAutoCheck(bool value) async {
    autoCheck = value;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(prefsAutoCheck, value);
    } catch (_) {}
  }

  /// 跳过当前最新版本：启动提示不再弹出，设置页手动检查仍可看到。
  Future<void> skipLatest() async {
    final tag = last?.latestTag ?? '';
    if (tag.isEmpty) return;
    skippedTag = tag;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(prefsSkippedTag, tag);
    } catch (_) {}
  }

  /// 读取并缓存当前版本（设置页展示用；失败静默）。
  Future<void> ensureVersion() async {
    if (version.isNotEmpty) return;
    final v = await fetchAppVersion();
    if (v.isEmpty) return;
    version = v;
    notifyListeners();
  }

  /// 单次检查。manual=true 表示用户点击触发（当前与自动检查同一实现，
  /// 差别只在调用方是否弹提示）。
  Future<UpdateCheckResult> check({bool manual = false}) async {
    if (checking) {
      return last ?? UpdateCheckResult.failure('已有检查在进行中');
    }
    checking = true;
    notifyListeners();
    final r = await checkForUpdates();
    checking = false;
    last = r;
    if (r.current.isNotEmpty) version = r.current;
    lastAttemptAt = DateTime.now();
    notifyListeners();
    // 记录「尝试」时间（成功与失败都记）：离线时也不会每次启动都重试；
    // 手动检查同样写入，避免用户连点/频繁启动打爆 GitHub 未鉴权限流。
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(
          prefsLastAttempt, lastAttemptAt!.millisecondsSinceEpoch);
    } catch (_) {}
    return r;
  }

  /// 启动静默检查：关闭自动检查、或距上次尝试不足 [startupThrottle] →
  /// 返回 null（不请求、不提示）。返回非 null 表示「有未跳过的新版本，
  /// 调用方应提示一次」。
  Future<UpdateCheckResult?> maybeStartupCheck() async {
    if (!autoCheck) return null;
    final at = lastAttemptAt;
    if (at != null && DateTime.now().difference(at) < startupThrottle) {
      return null;
    }
    await ensureVersion();
    final r = await check();
    return r.hasNewVersion && r.latestTag != skippedTag ? r : null;
  }

  /// 测试用：清空进程内状态（偏好由 SharedPreferences mock 提供）。
  @visibleForTesting
  void resetForTest() {
    version = '';
    last = null;
    checking = false;
    autoCheck = true;
    skippedTag = '';
    lastAttemptAt = null;
  }
}
