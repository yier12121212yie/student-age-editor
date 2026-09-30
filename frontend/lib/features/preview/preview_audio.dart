import 'dart:async';
import 'dart:convert';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

import '../../core/api_client.dart';
import 'preview_models.dart';

/// 预览音频控制器：给 `EventPreviewView` 提供 BGM / 音效 / 人声通道 + 全局静音。
///
/// 设计对齐仓库既有先例（`features/editor/visual_fields.dart` 的
/// `resolveAudioBytes` 与 `features/files/file_viewer.dart` 的 `AudioPreview`）：
/// - 取字节先 `/api/aa/preview`（`kind:'aud'`, `key:url`，走 AA 索引），
///   仅在 **404 / 422**（未命中索引 / 索引未就绪）时回落
///   `GET /api/tools/read?scope=mod&path=url`（mod 相对路径 base64）。
/// - BGM 走单例播放器循环；音效 / 人声各用一个复用的一次性播放器。
/// - **播放失败静默**：无平台实现（widget/单元测试下的 `MissingPluginException`）、
///   解码失败、资源缺失——一律吞掉，仅经 [onError] 冒一次（视图侧弹一条 InfoBar，
///   不弹窗轰炸，也不阻断对白推进）。
///
/// 关键：字节获取在触碰播放器 **之前** 完成，因此「推进触发 BGM 请求」在无音频
/// 插件的测试环境里依然可断言——`/api/aa/preview` 请求照常发出，随后 `play()`
/// 抛异常被 catch。
class PreviewAudioController {
  PreviewAudioController({this.onError});

  /// 播放 / 取字节失败的一次性上报（视图决定如何提示，只回调一次）。
  final void Function(String message)? onError;

  /// 全局静音状态（状态栏小按钮绑定；静音时 [playTalk] 直接短路，不发请求）。
  final ValueNotifier<bool> muted = ValueNotifier<bool>(false);

  AudioPlayer? _bgmPlayer;
  AudioPlayer? _sfxPlayer;
  AudioPlayer? _vocalPlayer;

  /// 当前 BGM 的 audio id：同值不重播、不重取（去重也防止失败反复重试）。
  String? _curBgmId;

  /// audio id → 字节（会话级；null = 已试取失败，避免同句反复请求）。
  final Map<String, Uint8List?> _byteCache = {};

  bool _disposed = false;
  bool _reportedError = false;

  String? get currentBgmId => _curBgmId;

  // ---------------- 对外：进入某句对白的音频演出 ----------------

  /// 推进 / 回跳 / 首句时调用。按 `talk.audio`（-1 停 BGM / >0 播引用 / 0 不变）
  /// 与 `talk.vocals`（id>0 尝试人声）演音频。不阻塞——内部异步取字节 + 播放，
  /// 异常自吞。[defaultBgmId] 仅首句传入（talk 无显式 audio 时作环境 BGM）。
  void playTalk(
    PreviewTalk? talk,
    Map<String, PreviewAudio> audios, {
    int defaultBgmId = 0,
  }) {
    if (_disposed || muted.value || talk == null) return;
    unawaited(_playTalk(talk, audios, defaultBgmId));
  }

  Future<void> _playTalk(
      PreviewTalk talk, Map<String, PreviewAudio> audios, int defaultBgmId) async {
    final audio = talk.audio;
    // --- BGM：优先后端逐句解析好的最终态 stage.bgm（BFS：type=1 切、-1 清、2 不改）；
    //     旧数据 stage 无 bgm 键时，回落到 talk.audio 的即时语义。 ---
    if (talk.stage.hasBgm) {
      final id = talk.stage.bgmId;
      if (id == null || id.isEmpty) {
        await stopBgm();
      } else {
        await _playBgmById(id, audios);
      }
    } else if (audio == -1) {
      await stopBgm();
    } else if (audio > 0 && audios['$audio']?.isBgm == true) {
      await _playBgmById('$audio', audios);
    } else if (audio == 0 && defaultBgmId > 0) {
      await _playBgmById('$defaultBgmId', audios);
    }

    // --- 一次性音效：talk.audio 引用的非 BGM(type=2) 条目（BGM 已由上面处理，不重复）。---
    if (audio > 0) {
      final e = audios['$audio'];
      if (e != null && !e.isBgm) {
        final bytes = await loadBytes('$audio', audios, e.url);
        if (bytes != null) {
          await _playOneShot(_sfxPlayer ??= AudioPlayer(), bytes);
        }
      }
    }

    // --- 人声：vocalsId>0 且能在 audios 里解析到条目时，一次性叠加播放。---
    if (talk.vocalsId > 0) {
      final vid = talk.vocalsId.toString();
      final entry = audios[vid];
      if (entry != null) {
        final bytes = await loadBytes(vid, audios, entry.url);
        if (bytes != null) {
          await _playOneShot(_vocalPlayer ??= AudioPlayer(), bytes);
        }
      }
    }
  }

  /// 播/切 BGM（循环）。url 取自 audios 条目；条目缺失时 url 传空 → playBgm 内
  /// 取不到字节即静默（并把该 id 记为目标 BGM 以免同句反复试探）。
  Future<void> _playBgmById(String id, Map<String, PreviewAudio> audios) async {
    await playBgm(id, audios[id]?.url ?? '');
  }

  /// 切/播 BGM（循环）。同 id 已在播则直接返回（去重：不重复取字节 / 不重置进度）。
  Future<void> playBgm(String id, String url) async {
    if (_disposed || muted.value) return;
    if (_curBgmId == id) return;
    final bytes = await loadBytes(id, const {}, url);
    if (_disposed) return;
    _curBgmId = id; // 无论成功与否都记为「目标 BGM」，避免同句反复试探。
    if (bytes == null) return;
    final player = _bgmPlayer ??= AudioPlayer();
    try {
      await player.setReleaseMode(ReleaseMode.loop);
      await player.play(BytesSource(bytes));
    } catch (_) {
      _fail('背景音乐播放失败');
    }
  }

  /// 停掉 BGM（audio=-1 指令 / 静音）。
  Future<void> stopBgm() async {
    _curBgmId = null;
    final p = _bgmPlayer;
    if (p == null) return;
    try {
      await p.stop();
    } catch (_) {
      // 无平台实现：忽略。
    }
  }

  // ---------------- 字节获取 ----------------

  /// 取音频字节：命中会话缓存直接返回；否则先 `/api/aa/preview kind=aud`，
  /// 404/422（或未带 data）回落 `GET /api/tools/read scope=mod`。
  /// 两路都拿不到则缓存 null（避免反复请求）并按需冒一次错误。
  Future<Uint8List?> loadBytes(
      String id, Map<String, PreviewAudio> audios, String url) async {
    if (_disposed) return null;
    final key = id.isNotEmpty ? id : url;
    if (key.isNotEmpty && _byteCache.containsKey(key)) return _byteCache[key];
    var effectiveUrl = url;
    if (effectiveUrl.isEmpty && id.isNotEmpty) {
      effectiveUrl = audios[id]?.url ?? '';
    }
    Uint8List? bytes;
    if (effectiveUrl.isNotEmpty) {
      bytes = await _fetchAud(effectiveUrl);
    }
    if (key.isNotEmpty) _byteCache[key] = bytes;
    if (bytes == null && effectiveUrl.isNotEmpty) _fail('音频资源加载失败');
    return bytes;
  }

  Future<Uint8List?> _fetchAud(String url) async {
    bool fallback = false;
    try {
      final r = await ApiClient.instance
          .post('/api/aa/preview', body: {'kind': 'aud', 'key': url});
      final data = r is Map ? r['data'] : null;
      if (data is String && data.isNotEmpty) {
        return await _decodeB64(data);
      }
      fallback = true; // 200 但无 data：视为未命中，回落。
    } on ApiException catch (e) {
      fallback = e.statusCode == 404 || e.statusCode == 422;
    } catch (_) {
      return null; // 网络层异常：不回落，直接失败。
    }
    if (!fallback) return null;
    try {
      final r = await ApiClient.instance
          .get('/api/tools/read', query: {'scope': 'mod', 'path': url});
      final b64 = r is Map ? r['base64'] : null;
      if (b64 is String && b64.isNotEmpty) return await _decodeB64(b64);
    } catch (_) {
      // 回落也失败：静默。
    }
    return null;
  }

  // ---------------- 播放器通道 ----------------

  Future<void> _playOneShot(AudioPlayer player, Uint8List bytes) async {
    if (_disposed) return;
    try {
      await player.setReleaseMode(ReleaseMode.stop);
      await player.stop();
      await player.play(BytesSource(bytes));
    } catch (_) {
      _fail('音效播放失败');
    }
  }

  // ---------------- 静音 ----------------

  void toggleMute() => setMuted(!muted.value);

  /// 静音即停 BGM（不阻断推进；解除后由下一次 [playTalk] 重设）。
  Future<void> setMuted(bool value) async {
    if (muted.value == value) return;
    muted.value = value;
    if (value) await stopBgm();
  }

  // ---------------- 生命周期 ----------------

  /// 一次性上报错误（由视图侧转成单条 InfoBar）。
  void _fail(String message) {
    if (_reportedError) return;
    _reportedError = true;
    onError?.call(message);
  }

  Future<void> dispose() async {
    _disposed = true;
    for (final p in [_bgmPlayer, _sfxPlayer, _vocalPlayer]) {
      if (p == null) continue;
      try {
        await p.dispose();
      } catch (_) {
        // 无平台实现：忽略。
      }
    }
    _bgmPlayer = _sfxPlayer = _vocalPlayer = null;
    muted.dispose();
  }
}

/// [compute] 入口：后台 isolate 解码大体积 base64（与仓库既有音频/纹理一致）。
Uint8List _base64DecodeIsolate(String b64) => base64Decode(b64);

/// base64 → 字节；大体积（>256KB）搬后台 isolate，小样本同步解；解码失败返回 null。
Future<Uint8List?> _decodeB64(String data) async {
  try {
    return data.length > 256 * 1024
        ? await compute(_base64DecodeIsolate, data)
        : base64Decode(data);
  } catch (_) {
    return null;
  }
}
