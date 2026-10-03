import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../../core/api_client.dart';
import '../../core/mobile_widgets.dart';
import '../../core/models.dart';
import '../../core/responsive.dart';
import '../ai/ai_panel.dart';
import '../editor/editor_controller.dart';
import '../resources/image_asset_picker.dart'
    show TexBytesCache, TexSource, TexSourceImage;
import '../settings/settings_page.dart';
import 'preview_audio.dart';
import 'preview_models.dart';
import 'stage_effects.dart';
import '../../core/app_theme.dart';

/// 事件场景预览视图：把当前事件（EvtCfg + TalkCfg + OptionCfg）渲染成
/// 视觉小说式游戏场景（背景 + 立绘 + 对白 + 选项），支持对白导航、
/// 画笔圈选并呼出 AI 侧栏修改命中内容。
class EventPreviewView extends StatefulWidget {
  const EventPreviewView(
      {super.key, required this.state, required this.controller, required this.eventId});
  final AppState state;
  final EditorController controller;
  final String eventId;
  @override
  State<EventPreviewView> createState() => _EventPreviewViewState();
}

class _EventPreviewViewState extends State<EventPreviewView> {
  PreviewEventData? _data;
  String? _error;
  bool _loading = true;

  // 导航状态
  String? _curTalkId;
  final List<String> _hist = [];
  String? _curBgKey;
  String? _curBgName;

  // 图片缓存：tex key -> PNG bytes（按总字节封顶的 LRU，见 [_BytesLru]）
  final _BytesLru _imgCache = _BytesLru();
  final Set<String> _imgLoading = {};
  /// tex key -> 加载失败原因（用于替代「加载中」占位）。
  final Map<String, String> _imgErrors = {};
  /// 人物图片扩展走对象存储时的公开 URL：tex key -> url（客户端自行 GET）。
  final Map<String, String> _imgUrls = {};

  // AI 侧栏（桌面内嵌；移动端改底部滑出层，380px 并排栏会压垮窄屏舞台）
  final GlobalKey<AiPanelState> _aiKey = GlobalKey<AiPanelState>();
  Timer? _aiInjectTimer;
  AiSettings _aiSettings = AiSettings();
  bool _aiSettingsLoaded = false;
  bool _aiOpen = false;
  bool _aiSheetOpen = false;
  final double _aiWidth = 380;

  // 画笔模式
  bool _brushMode = false;

  // 全屏预览：OverlayEntry 盖住壳层（AppBar/TabBar/底导），复用同一份导航
  // 状态与图片缓存；State 变化时经 markNeedsBuild 同步重绘。
  OverlayEntry? _fsEntry;

  // 音频演出层：BGM/音效/人声通道 + 全局静音；onError 只冒一次 InfoBar。
  late final PreviewAudioController _audio;
  bool _audioWarned = false;

  // 屏幕效果（screenEffect）演出状态机：持续滤镜/黑屏/CG + 一次性闪白/抖动 token。
  StageVisual _fx = const StageVisual();
  int _fxFlashToken = 0;
  int _fxShakeToken = 0;
  double _fxShakeSec = 0.6;
  // CG：cgRef → 字节的会话缓存 + CGCfg id→url 表 + 取字节世代号（防跨句回填竞态）。
  final _BytesLru _cgCache = _BytesLru();
  Map<String, String>? _cgUrlTable;
  Uint8List? _cgBytes;
  int _cgGen = 0;
  bool _cgDismissed = false;

  @override
  void setState(VoidCallback fn) {
    super.setState(fn);
    _fsEntry?.markNeedsBuild();
  }

  void _toggleFullscreen() {
    final existing = _fsEntry;
    if (existing != null) {
      existing.remove();
      setState(() => _fsEntry = null);
      return;
    }
    // opaque: 全屏层是不透明黑底铺满（见 _buildFullscreenLayer），声明不透明
    // 后 Flutter 会跳过被完全遮住的标签页舞台的绘制与布局——否则每次 setState
    // 都会把两套舞台各画一遍（内联那份用户根本看不见）。
    final entry = OverlayEntry(builder: (_) => _buildFullscreenLayer(), opaque: true);
    Overlay.of(context).insert(entry);
    setState(() => _fsEntry = entry);
  }

  Widget _buildFullscreenLayer() {
    final data = _data;
    final talk = currentTalk;
    return Material(
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          _buildStage(),
          SafeArea(
            bottom: false,
            child: Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0xB3000000), Colors.transparent],
                ),
              ),
              child: SizedBox(
                height: 48,
                child: Row(
                  children: [
                    _FsBtn(FluentIcons.full_screen_minimize_24_regular,
                        '退出全屏', _toggleFullscreen),
                    _FsBtn(
                        _audio.muted.value
                            ? FluentIcons.speaker_mute_24_regular
                            : FluentIcons.speaker_2_24_regular,
                        _audio.muted.value ? '取消静音' : '静音', () {
                      _audio.toggleMute();
                      setState(() {});
                    }),
                    Expanded(
                      child: Text(
                        data?.title ?? '',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: Colors.white),
                      ),
                    ),
                    _FsBtn(FluentIcons.chevron_left_24_regular, '上一条对白',
                        _hist.isNotEmpty ? _goBack : null),
                    _FsBtn(FluentIcons.chevron_right_24_regular, '下一条对白',
                        _canNext() ? _goNext : null),
                  ],
                ),
              ),
            ),
          ),
          if (data != null && talk != null)
            Positioned(
              right: 12,
              bottom: 8,
              child: IgnorePointer(
                child: Text(
                  '${data.linearIndex(_curTalkId) + 1} / ${data.talkCount}',
                  style: const TextStyle(fontSize: 11, color: Colors.white54),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 点按画面推进（视觉小说惯例）。选项显示时/画笔模式下不推进，
  /// 避免误触跳对白。
  void _advanceOnTap() {
    if (_brushMode) return;
    final t = currentTalk;
    if (t == null || t.options.isNotEmpty) return;
    _goNext();
  }

  Widget _buildAiPanel() => AiPanel(
        key: _aiKey,
        state: widget.state,
        settings: _aiSettingsLoaded ? _aiSettings : AiSettings(),
        onChanged: (s) => setState(() => _aiSettings = s),
        onOpenSettings: null,
      );

  /// 移动端以底部滑出层呼出 AI（替代桌面 380px 内嵌侧栏）。
  void _openAiSheet() {
    if (_aiSheetOpen) return;
    _aiSheetOpen = true;
    if (!_aiOpen) setState(() => _aiOpen = true);
    showMobileSheet(context, _buildAiPanel()).whenComplete(() {
      _aiSheetOpen = false;
      if (mounted) setState(() => _aiOpen = false);
    });
  }

  @override
  void initState() {
    super.initState();
    _audio = PreviewAudioController(onError: (m) {
      // 播放/取字节失败只提示一次，不弹窗轰炸、不阻断推进。
      if (_audioWarned || !mounted) return;
      _audioWarned = true;
      _toast(m);
    });
    _load();
    _loadAiSettings();
  }

  Future<void> _loadAiSettings() async {
    final s = await AiSettings.loadWithRemote();
    if (!mounted) return;
    setState(() {
      _aiSettings = s;
      _aiSettingsLoaded = true;
    });
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await ApiClient.instance
          .post('/api/preview/event', body: {'evt_id': widget.eventId});
      if (!mounted) return;
      setState(() {
        _data = PreviewEventData.fromJson(r);
        _hist.clear();
        _imgCache.clear();
        _imgErrors.clear();
        _imgUrls.clear();
        // 音频/效果状态随整场重置。
        _fx = const StageVisual();
        _fxFlashToken = _fxShakeToken = 0;
        _cgBytes = null;
        _cgDismissed = false;
        _audioWarned = false;
        final starts = _data!.starts;
        _curTalkId = starts.isNotEmpty ? starts.first : null;
        _curBgKey = null;
        _curBgName = null;
        _loading = false;
      });
      _preloadImages();
      // 首句：应用屏效 + 演音频（无显式 audio 时用环境 bgm）。
      _applyScreenEffects(currentTalk);
      _audio.playTalk(currentTalk, _data!.audios, defaultBgmId: _data!.bgmId);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  /// 预加载当前对白的背景与立绘（并缓存）。
  Future<void> _preloadImages() async {
    final talk = currentTalk;
    if (talk == null) return;
    final stage = talk.stage;
    final bg = stage.bg;
    if (bg != null && bg.key.isNotEmpty) {
      _ensureBg(bg);
    }
    // 立绘并发预加载：逐张 await 会把 N 张图的「下载+解码」串成 N 倍延迟。
    // _loadTex 自带错误处理（失败记入 _imgErrors）与完成后的局部 setState，
    // 即各自完成后只刷新对应项，不因并发丢错误，这里也无需聚合结果。
    await Future.wait([
      for (final c in stage.chars)
        if (c.tex.isNotEmpty) _loadTex(c.tex),
    ]);
    if (mounted) setState(() {});
  }

  Future<Uint8List?> _loadTex(String key) async {
    if (key.isEmpty) return null;
    final cached = _imgCache.get(key);
    if (cached != null) return cached;
    if (_imgLoading.contains(key)) return null;
    _imgLoading.add(key);
    try {
      final r = await ApiClient.instance
          .post('/api/aa/preview', body: {'kind': 'tex', 'key': key});
      // 人物图片扩展：服务端只回 COS 公开 URL，客户端自行请求（web 端
      // 用 HTML <img> 策略渲染，无需对象存储开 CORS）。
      final url = r['url'];
      if (url is String && url.isNotEmpty) {
        _imgUrls[key] = url;
        _imgErrors.remove(key);
        if (mounted) setState(() {});
        return null;
      }
      final data = r['data'];
      if (data is String) {
        // 1080p 背景的 base64 有数 MB，解码搬去后台 isolate（手机预览掉帧源之一）。
        final bytes = data.length > 256 * 1024
            ? await compute(_base64DecodeIsolate, data)
            : base64Decode(data);
        _imgCache.put(key, bytes);
        _imgErrors.remove(key);
        if (mounted) setState(() {});
        return bytes;
      }
      _imgErrors[key] = '资源返回异常';
    } on ApiException catch (e) {
      // 记录具体原因：索引未就绪 / 纹理不存在 / 解码失败
      _imgErrors[key] = e.statusCode == 400 ? '资源索引未就绪' : '资源缺失';
    } catch (_) {
      _imgErrors[key] = '加载失败';
    } finally {
      _imgLoading.remove(key);
    }
    if (mounted) setState(() {});
    return null;
  }

  PreviewTalk? get currentTalk {
    final d = _data;
    final id = _curTalkId;
    if (d == null || id == null) return null;
    return d.talks[id];
  }

  /// 背景切换：bg 快照为 null 时沿用当前背景。_curBgKey 保存 tex key。
  void _ensureBg(PreviewBg? bg) {
    if (bg == null) return;
    if (bg.key == _curBgKey) return;
    _curBgKey = bg.key;
    _curBgName = bg.name;
    if (bg.key.isNotEmpty) _loadTex(bg.key);
  }

  /// 跳到指定对白（记录历史）。
  void _jumpTo(String talkId) {
    final d = _data;
    if (d == null) return;
    final t = d.talks[talkId];
    if (t == null) return;
    final cur = _curTalkId;
    if (cur != null) _hist.add(cur);
    setState(() {
      _curTalkId = talkId;
    });
    // 应用该对白的背景与立绘
    _ensureBg(t.stage.bg);
    _preloadImages();
    // 屏效 + 音频按目标句重设状态（推进/选项分支/回跳共用此入口）。
    _applyScreenEffects(t);
    _audio.playTalk(t, d.audios);
  }

  void _goBack() {
    if (_hist.isEmpty) return;
    setState(() {
      _curTalkId = _hist.removeLast();
    });
    _preloadImages();
    // 回跳：按目标句重演屏效与音频（同 playTalk 的去重规则）。
    final t = currentTalk;
    _applyScreenEffects(t);
    _audio.playTalk(t, _data?.audios ?? const {});
  }

  void _goNext() {
    final t = currentTalk;
    if (t == null) return;
    final next = t.nextTalk.isNotEmpty ? t.nextTalk.first : null;
    if (next != null && _data!.talks.containsKey(next)) {
      _jumpTo(next);
    } else {
      _toast('已经是最后一条对白');
    }
  }

  void _chooseOption(String optId) {
    final d = _data;
    final t = currentTalk;
    if (d == null || t == null) return;
    final opt = d.options[optId];
    final branch = opt != null && opt.talkId.isNotEmpty ? opt.talkId.first : null;
    if (branch != null && d.talks.containsKey(branch)) {
      _jumpTo(branch);
    } else {
      _toast('该选项无后续对白（事件结束）');
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    fluent.displayInfoBar(context,
        builder: (ctx, close) => fluent.InfoBar(title: Text(msg)));
  }

  // ---------------- 屏幕效果（screenEffect）演出 ----------------

  /// 进入某句：把 screenEffect 编译进画面状态机（持续滤镜/黑屏/CG + 一次性闪白/抖动）。
  /// 一次性动画用自增 token 触发，不阻塞推进。
  void _applyScreenEffects(PreviewTalk? talk) {
    final fx = _resolveScreenEffect(talk);
    final one = stageOneShotOf(fx);
    setState(() {
      _fx = nextStageVisual(_fx, fx);
      _cgDismissed = false;
      if (one == StageOneShot.flash) {
        _fxFlashToken++;
      } else if (one == StageOneShot.shake) {
        _fxShakeSec = (fx?.firstParam ?? 0) > 0 ? fx!.firstParam : 0.6;
        _fxShakeToken++;
      }
      final cg = _fx.cgRef;
      if (cg == null) {
        _cgBytes = null;
      } else {
        final key = cg.toString();
        final cached = _cgCache.get(key);
        if (cached != null) {
          _cgBytes = cached;
        } else {
          _cgBytes = null;
          _cgGen++; // 世代号：回填时若已切句则丢弃，防竞态串图。
          unawaited(_loadCg(cg, key, _cgGen));
        }
      }
    });
  }

  /// 解析当前句的屏幕效果：优先顶层 screen_effects 映射（talkId → {code,args}|null），
  /// 兼容旧数据里嵌在 talk 上的原始 screenEffect 字段。
  ScreenEffect? _resolveScreenEffect(PreviewTalk? talk) {
    if (talk == null) return null;
    final map = _data?.screenEffects;
    if (map != null && map.containsKey(talk.id)) {
      final d = map[talk.id];
      return d == null ? null : ScreenEffect.fromDirective(d.code, d.args);
    }
    return ScreenEffect.parse(talk.screenEffect);
  }

  /// 取 CG 字节并回填（CGCfg id → url → TexBytesCache.loadSmart）。
  Future<void> _loadCg(Object cgRef, String key, int gen) async {
    await _ensureCgUrlTable();
    final url = _cgUrlFor(cgRef);
    final bytes = await TexBytesCache.loadSmart(url);
    _cgCache.put(key, bytes);
    if (!mounted || _cgGen != gen) return;
    if (_fx.cgRef?.toString() != key) return;
    setState(() => _cgBytes = bytes);
  }

  String _cgUrlFor(Object cgRef) {
    final s = cgRef.toString();
    if (int.tryParse(s) == null) return s; // 非纯数字：已是 url / tex key
    return _cgUrlTable?[s] ?? s; // 表未就绪时回落用 id 当 key 试探
  }

  /// 惰性拉取并缓存 CGCfg 的 id→url 表（会话级）。失败静默，回落用 id 当 key。
  Future<void> _ensureCgUrlTable() async {
    if (_cgUrlTable != null) return;
    final out = <String, String>{};
    try {
      final r = await ApiClient.instance.get('/api/cfg/CGCfg');
      final data = r is Map ? r['data'] : null;
      if (data is Map) {
        data.forEach((k, v) {
          if (v is Map) {
            final u = _cgUrlFromRow(v);
            if (u.isNotEmpty) out[k.toString()] = u;
          }
        });
      }
    } catch (_) {
      // 表不可用：_cgUrlFor 用原始 id 当 key，交给 TexBytesCache 试探候选。
    }
    _cgUrlTable = out;
  }

  static String _cgUrlFromRow(Map row) {
    final u = row['url'];
    if (u is String && u.trim().isNotEmpty) return u.trim();
    final us = row['urls'];
    if (us is List && us.isNotEmpty && us.first is String) {
      return (us.first as String).trim();
    }
    return '';
  }

  void _dismissCg() {
    if (!_cgDismissed) setState(() => _cgDismissed = true);
  }

  // ---------------- 画笔圈选 ----------------

  void _onBrushDone(Rect rect, Size canvasSize) {
    final data = _data;
    final talk = currentTalk;
    if (!_brushMode || data == null || talk == null) return;
    final hit = _hitTest(rect, canvasSize, data, talk);
    if (hit.isEmpty) {
      _toast('圈选区域未命中任何内容（背景/对白/角色/选项）');
      return;
    }
    final ctx = _buildAiContext(hit);
    if (!mounted) return;
    showDialog<void>(
      context: context,
      builder: (dialogCtx) => _BrushResultDialog(
        title: '圈选内容',
        description: ctx,
        onConfirm: () {
          Navigator.of(dialogCtx).pop();
          _submitToAi(ctx);
        },
      ),
    );
  }

  /// 圈选矩形命中检测：返回命中的内容描述列表。
  /// [canvasSize] 为完整画布尺寸（16:9 场景），目标区域按画布比例计算。
  List<String> _hitTest(
      Rect rect, Size canvasSize, PreviewEventData data, PreviewTalk talk) {
    final hits = <String>[];
    final w = canvasSize.width;
    final h = canvasSize.height;
    // 选项区域（对白框上方）
    if (talk.options.isNotEmpty) {
      final optRect = Rect.fromLTWH(w * 0.08, h * 0.52, w * 0.84, h * 0.18);
      final optIds = talk.options;
      for (final oid in optIds) {
        final opt = data.options[oid];
        if (opt != null && _overlap(rect, optRect) > 0.25) {
          hits.add('选项（OptionCfg id=$oid）：「${opt.content}」');
        }
      }
    }
    // 对白框区域（底部大横条：圈中该区域任意部分即命中当前对白）
    final boxRect = Rect.fromLTWH(0, h * 0.72, w, h * 0.28);
    if (_overlap(rect, boxRect) > 0.25) {
      final speaker = talk.speakerLabel(data);
      final content = talk.content.trim();
      hits.add('对白（TalkCfg id=${talk.id}）：说话人「$speaker」${content.isEmpty ? '' : '，内容「$content」'}');
    }
    // 立绘区域（按站位）
    for (final c in talk.stage.chars) {
      final x0 = switch (c.pos) {
        'left' => w * 0.02,
        'right' => w * 0.62,
        _ => w * 0.30,
      };
      final charRect = Rect.fromLTWH(x0, h * 0.12, w * 0.36, h * 0.62);
      if (_overlap(rect, charRect) > 0.15) {
        final name = data.meta.roles[c.roleId] ?? c.roleId;
        hits.add('立绘角色（PersonCfg id=${c.roleId}）：$name（站位：${_posLabel(c.pos)}${c.expr > 0 ? '，表情${c.expr}' : ''}）');
      }
    }
    // 兜底：圈在场景上部/空白处 → 命中背景（含「沿用上一背景」的情形）
    if (hits.isEmpty) {
      final bg = _currentBg(talk);
      hits.add(bg != null
          ? '背景（BGCfg id=${bg.id}）：「${bg.name.isNotEmpty ? bg.name : bg.id}」'
          : '背景区域（当前场景无背景条目，仅背景画面）');
    }
    return hits;
  }

  /// 当前背景（含沿用情形）：优先本条对白显式背景，否则用 _curBgKey 反查。
  ({String id, String name})? _currentBg(PreviewTalk talk) {
    final d = _data;
    if (d == null) return null;
    final stageBg = talk.stage.bg;
    if (stageBg != null && stageBg.id.isNotEmpty) {
      return (id: stageBg.id, name: stageBg.name);
    }
    final key = _curBgKey;
    if (key == null || key.isEmpty) return null;
    String? matched;
    d.meta.bgKeys.forEach((k, v) {
      if (v == key) matched = k;
    });
    final bgId = matched;
    if (bgId == null) return null;
    return (id: bgId, name: d.meta.bgs[bgId] ?? '');
  }

  /// 圈选矩形被目标区域覆盖的比例（= 交集面积 / 圈选面积）。
  double _overlap(Rect sel, Rect target) {
    final inter = sel.intersect(target);
    if (inter.isEmpty || sel.isEmpty) return 0;
    return inter.width * inter.height / (sel.width * sel.height);
  }

  static String _posLabel(String pos) => switch (pos) {
        'left' => '左',
        'right' => '右',
        _ => '中',
      };

  String _buildAiContext(List<String> hits) {
    final talk = currentTalk;
    final buf = StringBuffer();
    buf.write('【预览场景圈选修改请求】\n');
    buf.write('我在事件场景预览中圈选了内容，请根据圈选结果修改对应的配置表条目。\n');
    buf.write('圈选命中的内容：\n');
    for (final h in hits) {
      buf.write('- $h\n');
    }
    if (talk != null && _curBgName != null && _curBgName!.isNotEmpty) {
      buf.write('当前场景背景：$_curBgName\n');
    }
    buf.write('\n请先调用工具读取对应条目（get_domain_item），确认后修改（update_domain_item）。'
        '若圈选包含对白，重点检查说话人与内容是否合理。');
    return buf.toString();
  }

  void _submitToAi(String ctx) {
    if (!_aiOpen) {
      if (isMobileWidth(context)) {
        _openAiSheet();
      } else {
        setState(() => _aiOpen = true);
      }
    }
    // AI 面板挂载 + 异步初始化需要时间，轮询重试直到注入成功。
    // timer 存字段并随 State 释放：页面在时限内开关时定时器不至于短暂存活。
    // 阶段 2f：① in-flight 门——Timer.periodic 不等 async 回调，sendText
    // 现在内含 mod 同步网络往返，可能超过 tick 间隔造成并发注入；② busy
    // 拒绝不计 attempts（面板正在流式输出时轮询只是等待，不该 5s 判死），
    // 改以挂钟 20s 兜底。
    _aiInjectTimer?.cancel();
    var attempts = 0;
    var inFlight = false;
    final started = DateTime.now();
    _aiInjectTimer = Timer.periodic(const Duration(milliseconds: 250), (timer) async {
      if (inFlight) return;
      if (!mounted) {
        timer.cancel();
        return;
      }
      final panel = _aiKey.currentState;
      if (panel == null || !panel.isBusy) attempts++;
      inFlight = true;
      bool ok;
      try {
        ok = panel != null && await panel.sendText(ctx);
      } finally {
        inFlight = false;
      }
      final timeout =
          DateTime.now().difference(started) > const Duration(seconds: 20);
      if (ok || attempts >= 20 || timeout) {
        timer.cancel();
        if (mounted && !ok) {
          _toast('AI 侧栏暂不可用，请稍后重试');
        }
      }
    });
  }

  // ---------------- 构建 ----------------

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(
          child: SizedBox(
              width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 2)));
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(FluentIcons.error_circle_24_regular, size: 36, color: palette.statusDanger),
            const SizedBox(height: 12),
            Text('预览加载失败: $_error',
                style: TextStyle(fontSize: 13, color: palette.textSecondary)),
            const SizedBox(height: 12),
            fluent.Button(onPressed: _load, child: const Text('重试')),
          ],
        ),
      );
    }
    final data = _data!;
    final mobile = isMobileWidth(context);
    return Column(
      children: [
        _Toolbar(
          title: data.title,
          evtId: data.evtId,
          talkIndex: data.talkCount == 0
              ? 0
              : data.linearIndex(_curTalkId) + 1,
          talkCount: data.talkCount,
          canBack: _hist.isNotEmpty,
          canNext: _canNext(),
          brushOn: _brushMode,
          aiOn: _aiOpen,
          fullscreenOn: _fsEntry != null,
          muted: _audio.muted.value,
          onBack: _goBack,
          onNext: _goNext,
          onMute: () {
            _audio.toggleMute();
            setState(() {});
          },
          onBrush: () => setState(() => _brushMode = !_brushMode),
          onAi: () {
            if (mobile) {
              _openAiSheet();
            } else {
              setState(() => _aiOpen = !_aiOpen);
            }
          },
          onFullscreen: _toggleFullscreen,
          onRefresh: _load,
          onEdit: () => widget.controller
              .open(OpenDoc.cfg(cfgName: 'EvtCfg')),
        ),
        Divider(height: 1, color: palette.border),
        Expanded(
          // 移动端不内嵌 380px AI 侧栏（会把舞台压成 0 宽），AI 走底部滑出层。
          child: mobile
              ? _buildStage()
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: _buildStage(),
                    ),
                    if (_aiOpen) ...[
                      VerticalDivider(width: 1, color: palette.border),
                      SizedBox(
                        width: _aiWidth,
                        child: _buildAiPanel(),
                      ),
                    ],
                  ],
                ),
        ),
      ],
    );
  }

  bool _canNext() {
    final t = currentTalk;
    if (t == null) return false;
    if (t.nextTalk.isNotEmpty && _data!.talks.containsKey(t.nextTalk.first)) {
      return true;
    }
    return false;
  }

  Widget _buildStage() {
    final data = _data;
    final talk = currentTalk;
    if (data == null || talk == null) {
      return Center(
          child: Text('该事件没有可预览的对白', style: TextStyle(fontSize: 13, color: palette.textHint)));
    }
    // 背景沿用：本条对白显式切换则用新背景，否则沿用当前背景
    final bgKey = (talk.stage.bg?.key.isNotEmpty ?? false)
        ? talk.stage.bg!.key
        : _curBgKey;
    final bgBytes = bgKey != null ? _imgCache.get(bgKey) : null;
    final options = [
      for (final oid in talk.options)
        if (data.options[oid] != null) (oid, data.options[oid]!),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        // 16:9 画布在可用区域内居中
        final canvasW = constraints.maxWidth;
        final canvasH = constraints.maxHeight;
        double cw, ch;
        if (canvasW / canvasH > 16 / 9) {
          ch = canvasH;
          cw = ch * 16 / 9;
        } else {
          cw = canvasW;
          ch = cw * 9 / 16;
        }
        return Center(
          child: SizedBox(
            width: cw,
            height: ch,
            child: ClipRect(
              // 点画面推进对白：选项/按钮有自己的命中区优先响应，
              // 画笔模式在 _advanceOnTap 内禁用。
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _advanceOnTap,
                child: StageShake(
                  token: _fxShakeToken,
                  seconds: _fxShakeSec,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      // 背景 + 立绘：这一层受持续屏效滤镜影响（4002 模糊 / 4010 反色）。
                      // RepaintBoundary 把「模糊/反色输出」冻结成独立图层：
                      // 对白框/选项/闪白/黑幕这些同帧变化的兄弟节点重绘时不再
                      // 带着整画布 sigma=10 模糊重算（预览里最贵的一笔 GPU 开销）。
                      RepaintBoundary(
                        child: applyStageFilters(
                          Stack(
                            fit: StackFit.expand,
                            children: [
                              if (bgBytes != null)
                                // 按画布显示宽度 × DPR 限制解码尺寸（1080p 背景降采样）。
                                Image.memory(bgBytes,
                                    fit: BoxFit.cover,
                                    gaplessPlayback: true,
                                    cacheWidth:
                                        _decodeCacheWidth(context, cw, factor: 2))
                              else
                                _Placeholder(
                                  label: (bgKey == null || bgKey.isEmpty)
                                      ? '无背景画面（该对白未指定背景）'
                                      : (_imgErrors.containsKey(bgKey)
                                          ? '背景不可用：${_imgErrors[bgKey]}'
                                          : '背景加载中…'),
                                  color: palette.bgDeep,
                                ),
                              for (final c in talk.stage.chars)
                                _CharSprite(
                                  char: c,
                                  bytes:
                                      c.tex.isNotEmpty ? _imgCache.get(c.tex) : null,
                                  url: c.tex.isNotEmpty ? _imgUrls[c.tex] : null,
                                ),
                            ],
                          ),
                          blur: _fx.blur,
                          invert: _fx.invert,
                        ),
                      ),
                      // 选项 / 对白框：不进滤镜层，保持清晰可读。
                      if (options.isNotEmpty)
                        Positioned(
                          left: cw * 0.08,
                          right: cw * 0.08,
                          top: ch * 0.52,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              for (final (oid, opt) in options)
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 6),
                                  child: _OptionButton(
                                    text: opt.content,
                                    onTap: () => _chooseOption(oid),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: _TalkBox(
                          speaker: talk.speakerLabel(data),
                          isNarrator: talk.isNarrator,
                          content: talk.content,
                          talkId: talk.id,
                        ),
                      ),
                      // 黑屏（4006）：逐句，渐入渐出。
                      StageBlackCurtain(on: _fx.black),
                      // 闪白（4012）：一次性叠加。
                      StageFlashBurst(token: _fxFlashToken),
                      // 全屏 CG（4015）：黑底控图，点击提前结束。
                      if (_fx.cgRef != null && !_cgDismissed)
                        StageCgLayer(
                          bytes: _cgBytes,
                          onDismiss: _dismissCg,
                          // BoxFit.contain 装得下整图，无需 overscan（factor=1）。
                          cacheWidth: _decodeCacheWidth(context, cw),
                        ),
                      // 画笔覆盖层（最上层，交互优先）。
                      if (_brushMode)
                        _BrushOverlay(
                          onDone: _onBrushDone,
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  void dispose() {
    _aiInjectTimer?.cancel();
    unawaited(_audio.dispose());
    _fsEntry?.remove();
    _fsEntry = null;
    super.dispose();
  }
}

// ---------------- 解码尺寸辅助 ----------------

/// 会话级字节 LRU（键 → 原图字节；null = 已取过但失败，占位防反复重试）。
///
/// 预览页原先用普通 Map：长会话连续切对白/切事件会把每张 1080p 背景、立绘
/// 与 CG 字节全部留在内存（几十张就上百 MB），CG 那层还会把全局
/// [TexBytesCache] 的 LRU 淘汰钩死。按总字节数封顶，超限淘汰最旧
/// （Map 插入序即 LRU 序，同 TexBytesCache 的做法）。
class _BytesLru {
  static const int _maxBytes = 48 * 1024 * 1024;

  final Map<String, Uint8List?> _m = {};
  int _bytes = 0;

  /// 命中即续命（移到 LRU 尾）；未命中或曾是失败占位返回 null。
  Uint8List? get(String key) {
    if (!_m.containsKey(key)) return null;
    final v = _m.remove(key);
    _m[key] = v;
    return v;
  }

  void put(String key, Uint8List? bytes) {
    _bytes -= _m.remove(key)?.length ?? 0;
    _m[key] = bytes;
    _bytes += bytes?.length ?? 0;
    while (_bytes > _maxBytes && _m.length > 1) {
      _bytes -= _m.remove(_m.keys.first)?.length ?? 0;
    }
  }

  void clear() {
    _m.clear();
    _bytes = 0;
  }
}

/// [compute] 入口：后台 isolate 解码 base64 纹理（手机预览切背景/立绘不掉帧）。
Uint8List _base64DecodeIsolate(String b64) => base64Decode(b64);

/// 解码宽度上限（物理像素）= 显示宽（逻辑像素）× devicePixelRatio × [factor]，
/// 夹在 64–4096；显示宽未知（无限约束）返回 null，保持原始解码尺寸。
///
/// 阶段 4d：`cacheWidth` 只影响解码采样，不改布局尺寸——Flutter 在原图更小时
/// 按原尺寸解码，因此视觉不变。背景用 [factor] > 1 留余量：`BoxFit.cover`
/// 会裁切，源图远宽于 16:9 画布时显示宽大于画布宽，需要多解一些才不糊。
int? _decodeCacheWidth(BuildContext context, double displayWidth,
    {double factor = 1}) {
  if (!displayWidth.isFinite || displayWidth <= 0) return null;
  final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1;
  final px = (displayWidth * (dpr > 0 ? dpr : 1) * factor).ceil();
  return px < 64 ? 64 : (px > 4096 ? 4096 : px);
}

// ---------------- 工具栏 ----------------

class _Toolbar extends StatelessWidget {
  const _Toolbar({
    required this.title,
    required this.evtId,
    required this.talkIndex,
    required this.talkCount,
    required this.canBack,
    required this.canNext,
    required this.brushOn,
    required this.aiOn,
    required this.fullscreenOn,
    required this.muted,
    required this.onBack,
    required this.onNext,
    required this.onMute,
    required this.onBrush,
    required this.onAi,
    required this.onFullscreen,
    required this.onRefresh,
    required this.onEdit,
  });
  final String title;
  final String evtId;
  final int talkIndex;
  final int talkCount;
  final bool canBack;
  final bool canNext;
  final bool brushOn;
  final bool aiOn;
  final bool fullscreenOn;
  final bool muted;
  final VoidCallback onBack;
  final VoidCallback onNext;
  final VoidCallback onMute;
  final VoidCallback onBrush;
  final VoidCallback onAi;
  final VoidCallback onFullscreen;
  final VoidCallback onRefresh;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final backBtn = _ToolButton(
      icon: FluentIcons.chevron_left_24_regular,
      tooltip: '上一条对白',
      enabled: canBack,
      onTap: onBack,
    );
    final nextBtn = _ToolButton(
      icon: FluentIcons.chevron_right_24_regular,
      tooltip: '下一条对白',
      enabled: canNext,
      onTap: onNext,
    );
    final fullscreenBtn = _ToolButton(
      icon: fullscreenOn
          ? FluentIcons.full_screen_minimize_24_regular
          : FluentIcons.full_screen_maximize_24_regular,
      tooltip: fullscreenOn ? '退出全屏预览' : '全屏预览',
      enabled: true,
      active: fullscreenOn,
      onTap: onFullscreen,
    );
    // 全局静音开关（🔊/🔇）：只关声音，不阻断对白推进。
    final muteBtn = _ToolButton(
      icon: muted
          ? FluentIcons.speaker_mute_24_regular
          : FluentIcons.speaker_2_24_regular,
      tooltip: muted ? '取消静音' : '静音',
      enabled: true,
      active: muted,
      onTap: onMute,
    );
    if (isMobileWidth(context)) {
      // 窄屏：标题+计数占一行会被七个按钮挤爆，低频动作（刷新/开表/
      // 画笔/AI）收进溢出菜单。
      return Container(
        height: 48,
        color: palette.bg,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Row(
          children: [
            Icon(FluentIcons.tv_24_regular,
                size: 15, color: accentColor),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                '$title · $talkIndex/$talkCount',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 12,
                    color: palette.textHigh,
                    fontWeight: FontWeight.w600),
              ),
            ),
            backBtn,
            nextBtn,
            fullscreenBtn,
            muteBtn,
            PopupMenuButton<String>(
              tooltip: '更多操作',
              color: palette.card,
              icon: Icon(FluentIcons.more_horizontal_24_regular,
                  size: 16, color: palette.textMuted),
              onSelected: (v) => switch (v) {
                'refresh' => onRefresh(),
                'edit' => onEdit(),
                'brush' => onBrush(),
                'ai' => onAi(),
                _ => null,
              },
              itemBuilder: (_) => [
                const PopupMenuItem(value: 'refresh', child: Text('重新加载')),
                const PopupMenuItem(value: 'edit', child: Text('打开事件配置表')),
                PopupMenuItem(
                    value: 'brush',
                    child: Text(brushOn ? '退出画笔模式' : '画笔圈选交给 AI')),
                const PopupMenuItem(value: 'ai', child: Text('呼出 AI 面板')),
              ],
            ),
          ],
        ),
      );
    }
    return Container(
      height: 40,
      color: palette.bg,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Row(
        children: [
          Icon(FluentIcons.tv_24_regular, size: 15, color: accentColor),
          const SizedBox(width: 8),
          Flexible(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 260),
              child: Text(title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12.5, color: palette.textHigh, fontWeight: FontWeight.w600)),
            ),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text('事件 $evtId',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: palette.textHint)),
          ),
          const Spacer(),
          Text('对白 $talkIndex / $talkCount',
              style: TextStyle(fontSize: 11, color: palette.textMuted)),
          const SizedBox(width: 12),
          backBtn,
          nextBtn,
          const SizedBox(width: 8),
          _VDiv(),
          _ToolButton(
            icon: FluentIcons.arrow_sync_24_regular,
            tooltip: '重新加载',
            enabled: true,
            onTap: onRefresh,
          ),
          _ToolButton(
            icon: FluentIcons.table_24_regular,
            tooltip: '打开事件配置表',
            enabled: true,
            onTap: onEdit,
          ),
          fullscreenBtn,
          muteBtn,
          _VDiv(),
          _ToolButton(
            icon: FluentIcons.draw_shape_24_regular,
            tooltip: '画笔模式：圈出内容让 AI 修改',
            enabled: true,
            active: brushOn,
            onTap: onBrush,
          ),
          _ToolButton(
            icon: FluentIcons.chat_multiple_24_regular,
            tooltip: '呼出 AI 侧栏',
            enabled: true,
            active: aiOn,
            onTap: onAi,
          ),
        ],
      ),
    );
  }
}

/// 全屏预览顶栏按钮（覆盖在深色画面上）。
class _FsBtn extends StatelessWidget {
  const _FsBtn(this.icon, this.tip, this.onTap);
  final IconData icon;
  final String tip;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(icon,
          size: 20, color: onTap == null ? Colors.white24 : Colors.white),
      tooltip: tip,
      onPressed: onTap,
      splashRadius: 22,
    );
  }
}

class _VDiv extends StatelessWidget {
  const _VDiv();
  @override
  Widget build(BuildContext context) {
    return Container(width: 1, height: 18, color: palette.border, margin: const EdgeInsets.symmetric(horizontal: 6));
  }
}

class _ToolButton extends StatelessWidget {
  const _ToolButton(
      {required this.icon, required this.tooltip, required this.enabled, required this.onTap, this.active = false});
  final IconData icon;
  final String tooltip;
  final bool enabled;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = !enabled
        ? palette.borderHover
        : active
            ? palette.accentLight
            : palette.textMuted;
    // 移动端工具栏 48 高：按钮热区放大到 40，图标随之增大。
    final mobile = isMobileWidth(context);
    final side = mobile ? 40.0 : 30.0;
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.forbidden,
      child: fluent.Tooltip(
        message: tooltip,
        child: GestureDetector(
          onTap: enabled ? onTap : null,
          child: Container(
            width: side,
            height: side,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: active ? palette.tintAccent : Colors.transparent,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Icon(icon, size: mobile ? 17 : 15, color: color),
          ),
        ),
      ),
    );
  }
}

// ---------------- 舞台元素 ----------------

class _Placeholder extends StatelessWidget {
  const _Placeholder({required this.label, required this.color});
  final String label;
  final Color color;
  @override
  Widget build(BuildContext context) {
    return Container(
      color: color,
      alignment: Alignment.center,
      child: Text(label,
          style: TextStyle(fontSize: 12, color: palette.iconDisabled)),
    );
  }
}

/// 立绘精灵：底部对齐 + 按站位横向定位 + 镜像翻转。
class _CharSprite extends StatelessWidget {
  const _CharSprite({required this.char, required this.bytes, this.url});
  final PreviewChar char;
  final Uint8List? bytes;
  final String? url;

  @override
  Widget build(BuildContext context) {
    if (char.tex.isEmpty) return const SizedBox.shrink();
    final hasBytes = bytes != null;
    final hasUrl = url != null && url!.isNotEmpty;
    if (!hasBytes && !hasUrl) return const SizedBox.shrink();
    return Positioned.fill(
      child: Align(
        alignment: switch (char.pos) {
          'left' => Alignment.bottomLeft,
          'right' => Alignment.bottomRight,
          _ => Alignment.bottomCenter,
        },
        child: FractionallySizedBox(
          widthFactor: switch (char.pos) {
            'left' || 'right' => 0.36,
            _ => 0.42,
          },
          heightFactor: 0.9,
          child: Transform.flip(
            flipX: char.flip,
            child: hasBytes
                // 立绘解码宽度按站位盒实际宽度 × DPR（4d）：
                // 只降采样，显示尺寸仍由 FractionallySizedBox 决定。
                ? LayoutBuilder(
                    builder: (context, box) => Image.memory(
                      bytes!,
                      fit: BoxFit.contain,
                      alignment: Alignment.bottomCenter,
                      gaplessPlayback: true,
                      cacheWidth: _decodeCacheWidth(context, box.maxWidth),
                    ),
                  )
                : TexSourceImage(
                    source: TexSource.url(url!),
                    fit: BoxFit.contain,
                  ),
          ),
        ),
      ),
    );
  }
}

/// 底部对白框：说话人 + 内容。
class _TalkBox extends StatelessWidget {
  const _TalkBox(
      {required this.speaker, required this.isNarrator, required this.content, required this.talkId});
  final String speaker;
  final bool isNarrator;
  final String content;
  final String talkId;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(28, 14, 28, 18),
      decoration: const BoxDecoration(
        // 图上底部遮罩：保证白字在任意背景图上可读，两模式同值
        //（已登记 light_theme_audit_test 白名单）。
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.transparent, Color(0xE6101014)],
          stops: [0.0, 0.35],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Flexible(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                  decoration: BoxDecoration(
                    color: isNarrator ? palette.card : accentColor,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(speaker,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: isNarrator ? palette.textSecondary : palette.textHigh)),
                ),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text('TalkCfg #$talkId',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 10.5, color: palette.textFaint)),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            content.isEmpty ? '（本条为舞台指令/空对白）' : content,
            style: TextStyle(
              fontSize: 15,
              height: 1.6,
              color: content.isEmpty ? palette.textFaint : palette.textHigh,
            ),
          ),
        ],
      ),
    );
  }
}

class _OptionButton extends StatelessWidget {
  const _OptionButton({required this.text, required this.onTap});
  final String text;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: palette.scrim,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: palette.borderHover),
          ),
          child: Row(
            children: [
              Icon(FluentIcons.diamond_24_regular, size: 13, color: accentColor),
              const SizedBox(width: 8),
              Expanded(
                child: Text(text,
                    style: TextStyle(fontSize: 13.5, color: palette.textBody)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------- 画笔覆盖层 ----------------

/// 画笔覆盖层：监听拖拽绘制圈选矩形。
class _BrushOverlay extends StatefulWidget {
  const _BrushOverlay({required this.onDone});
  final void Function(Rect rect, Size canvasSize) onDone;
  @override
  State<_BrushOverlay> createState() => _BrushOverlayState();
}

class _BrushOverlayState extends State<_BrushOverlay> {
  Offset? _start;
  Rect? _dragging;

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: Listener(
        onPointerDown: (e) {
          if (e.buttons & kPrimaryButton == 0) return;
          _start = e.localPosition;
          _dragging = null;
          setState(() {});
        },
        onPointerMove: (e) {
          final s = _start;
          if (s == null) return;
          setState(() {
            _dragging = Rect.fromPoints(s, e.localPosition);
          });
        },
        onPointerUp: (e) {
          final r = _dragging;
          _start = null;
          _dragging = null;
          setState(() {});
          if (r != null && r.width > 8 && r.height > 8) {
            widget.onDone(r, context.size ?? Size.zero);
          }
        },
        child: CustomPaint(painter: _BrushPainter(rect: _dragging)),
      ),
    );
  }
}

class _BrushPainter extends CustomPainter {
  _BrushPainter({this.rect})
      : _light = palette.isLight,
        _accent = accentColor;
  final Rect? rect;
  final bool _light;
  final Color _accent;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = palette.overlayMedium,
    );
    final r = rect;
    if (r == null) return;
    final paint = Paint()
      ..color = accentColor.withValues(alpha: 0.2)
      ..style = PaintingStyle.fill;
    canvas.drawRect(r, paint);
    canvas.drawRect(
      r,
      Paint()
        ..color = palette.accentLight
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
    // 圈选标记文字
    final tp = TextPainter(
      text: TextSpan(
        text: '已圈选，松开后交给 AI',
        style: TextStyle(fontSize: 12, color: palette.onAccent),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(r.left + 6, r.top - tp.height - 4));
  }

  @override
  bool shouldRepaint(covariant _BrushPainter old) =>
      old.rect != rect || old._light != _light || old._accent != _accent;
}

// ---------------- 圈选结果弹窗 ----------------

class _BrushResultDialog extends StatelessWidget {
  const _BrushResultDialog(
      {required this.title, required this.description, required this.onConfirm});
  final String title;
  final String description;
  final VoidCallback onConfirm;

  @override
  Widget build(BuildContext context) {
    // 桌面端放宽到 480；窄屏跟随弹窗默认宽度（ContentDialog 上限 368），
    // 固定 480 会超出弹窗约束导致横向溢出
    final wide = MediaQuery.sizeOf(context).width >= 560;
    return fluent.ContentDialog(
      title: Text(title),
      content: Container(
        width: wide ? 480 : null,
        constraints: const BoxConstraints(maxHeight: 320),
        child: SingleChildScrollView(
          child: Text(description,
              style: TextStyle(fontSize: 13, color: palette.textPrimary, height: 1.6)),
        ),
      ),
      actions: [
        fluent.Button(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        fluent.FilledButton(
          onPressed: onConfirm,
          child: const Text('交给 AI 修改'),
        ),
      ],
    );
  }
}
