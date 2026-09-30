/// 网页版 AI 双通道策略（已批准计划 M0.4）。
///
/// 后端契约：
/// - `GET /api/ai/policy` → `{relay_available, provider, model, models,
///   own_key_allowed, tts_image_available, stream, limits:{daily}}`；
/// - `POST /api/ai/relay/chat` → 请求体为某 provider 协议的完整**非流式**
///   对话体，服务端强制 stream:false、按服务端配置补 model 与密钥并转发，
///   上游 status/JSON 原样透传。
///
/// 仅 `kIsWeb` 消费本文件；桌面端不拉 policy、直连流式行为零改动。
/// 拉取失败（未登录/后端不支持/超时）兜底为「无网关、允许自带 key、
/// TTS/生图可用」——即与引入双通道前的旧行为一致。
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show ChangeNotifier;
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/api_client.dart';

/// 浏览器直连第三方服务商被 CORS 封锁时的统一文案（web 直连失败提示）。
const String kAiBrowserCorsHint =
    '该服务商不支持浏览器直连（CORS 封锁），'
    '请改用平台 AI，或配置允许浏览器访问的服务商地址';

/// 托管形态下 TTS/生图入口禁用时的提示文案。
const String kAiTtsImageDisabledHint = '当前部署未开启服务端 TTS/生图';

/// `GET /api/ai/policy` 的解析结果。
class AiPolicy {
  const AiPolicy({
    this.relayAvailable = false,
    this.provider = '',
    this.model = '',
    this.models = const [],
    this.ownKeyAllowed = true,
    this.ttsImageAvailable = true,
    this.stream = false,
    this.dailyLimit = 0,
  });

  /// 服务端是否开启了 AI 转发网关（平台 AI 通道）。
  final bool relayAvailable;

  /// 网关使用的 provider 协议（openai_compatible | openai_responses | anthropic）。
  final String provider;

  /// 网关默认模型（用户侧留空时由服务端回填）。
  final String model;

  /// 网关允许的模型清单（空 = 未提供清单）。
  final List<String> models;

  /// 是否允许用户在浏览器里填自己的 key 直连服务商。
  final bool ownKeyAllowed;

  /// 服务端 TTS/生图是否可用（托管形态常为 false：密钥不在服务端）。
  final bool ttsImageAvailable;

  /// 网关是否支持流式（当前契约恒 false；web 端一律非流式，字段仅透传）。
  final bool stream;

  /// 每日调用额度（<=0 视为不展示）。
  final int dailyLimit;

  /// 失败兜底：无网关、允许自带 key、TTS/生图可用（= 旧行为）。
  static const AiPolicy fallback = AiPolicy();

  factory AiPolicy.fromJson(Map<dynamic, dynamic> json) {
    final raw = json.map((k, v) => MapEntry(k.toString(), v));
    final limits = raw['limits'];
    return AiPolicy(
      relayAvailable: raw['relay_available'] == true,
      provider: raw['provider'] as String? ?? '',
      model: raw['model'] as String? ?? '',
      models: [
        for (final m in (raw['models'] as List? ?? const []))
          if (m is String && m.trim().isNotEmpty) m.trim(),
      ],
      ownKeyAllowed: raw['own_key_allowed'] != false,
      ttsImageAvailable: raw['tts_image_available'] != false,
      stream: raw['stream'] == true,
      dailyLimit: (limits is Map ? (limits['daily'] as num?)?.toInt() : null) ??
          0,
    );
  }

  /// 面板展示用模型描述：清单优先，退回默认模型。
  String get displayModels =>
      models.isNotEmpty ? models.join('、') : model;

  /// 「每日 N 次」注行；额度未配置（<=0）时为空串。
  String get dailyNote => dailyLimit > 0 ? '每日 $dailyLimit 次' : '';
}

/// policy 拉取器（测试注入用）：返回响应 JSON，非 Map/失败返回 null。
typedef AiPolicyLoader = Future<Map<String, dynamic>?> Function();

Future<Map<String, dynamic>?> _defaultPolicyLoader() async {
  final r = await ApiClient.instance
      .get('/api/ai/policy')
      .timeout(const Duration(seconds: 5));
  return r is Map ? Map<String, dynamic>.from(r) : null;
}

/// 应用内一次性 policy 缓存（进程级单例；失败也记为已加载，不反复重试）。
///
/// 变更后 notifyListeners，面板/控制器据此刷新双通道 UI。
class AiPolicyStore extends ChangeNotifier {
  AiPolicyStore({AiPolicyLoader? loader})
    : _loader = loader ?? _defaultPolicyLoader;

  static final AiPolicyStore instance = AiPolicyStore();

  final AiPolicyLoader _loader;
  AiPolicy _policy = AiPolicy.fallback;
  bool _loaded = false;
  Future<AiPolicy>? _inFlight;

  AiPolicy get policy => _policy;
  bool get loaded => _loaded;

  /// 已加载直接返回缓存；否则发起一次拉取（并发调用共享同一请求）。
  Future<AiPolicy> ensureLoaded() {
    if (_loaded) return Future.value(_policy);
    return _inFlight ??= _fetch();
  }

  Future<AiPolicy> _fetch() async {
    var p = AiPolicy.fallback;
    try {
      final raw = await _loader();
      if (raw != null) p = AiPolicy.fromJson(raw);
    } catch (_) {
      p = AiPolicy.fallback;
    }
    _policy = p;
    _loaded = true;
    _inFlight = null;
    notifyListeners();
    return p;
  }
}

/// 用户在面板上显式选择的通道；auto = 未显式选择（有 key 直连、无 key 走网关）。
enum AiChannelChoice { auto, platform, own }

/// 通道选择持久化（仅 web 使用；独立 prefs key，不触碰 AiSettings）。
class AiChannelPrefs {
  AiChannelPrefs._();
  static const _key = 'ai_web_channel_v1';

  static Future<AiChannelChoice> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return _parse(prefs.getString(_key));
    } catch (_) {
      return AiChannelChoice.auto;
    }
  }

  static Future<void> save(AiChannelChoice choice) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, choice.name);
    } catch (_) {}
  }

  static AiChannelChoice _parse(String? raw) => switch (raw) {
    'platform' => AiChannelChoice.platform,
    'own' => AiChannelChoice.own,
    _ => AiChannelChoice.auto,
  };
}

/// 解析 web 端实际走哪条通道：true = 平台网关 relay，false = 浏览器直连。
///
/// - [web] 传入 kIsWeb（桌面恒 false → 永不 relay，行为零改动）；
/// - 显式选平台：需网关可用（不可用时退回直连，UI 已禁用该选项）；
/// - 显式选自带 key：总是直连（key 为空时 AiClient 给出既有的「未配置」报错）；
/// - auto：网关可用且用户没填自己的 key → 平台；否则直连（旧行为）。
bool resolveUseRelay({
  required bool web,
  required AiChannelChoice choice,
  required AiPolicy policy,
  required bool hasOwnKey,
}) {
  if (!web) return false;
  return switch (choice) {
    AiChannelChoice.platform => policy.relayAvailable,
    AiChannelChoice.own => false,
    AiChannelChoice.auto => policy.relayAvailable && !hasOwnKey,
  };
}
