import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../../core/api_client.dart';
import '../../core/models.dart';
import '../ai/ai_panel.dart';
import '../editor/editor_controller.dart';
import '../settings/settings_page.dart';
import 'preview_models.dart';
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

  // 图片缓存：tex key -> PNG bytes
  final Map<String, Uint8List> _imgCache = {};
  final Set<String> _imgLoading = {};
  /// tex key -> 加载失败原因（用于替代「加载中」占位）。
  final Map<String, String> _imgErrors = {};

  // AI 侧栏
  final GlobalKey<AiPanelState> _aiKey = GlobalKey<AiPanelState>();
  AiSettings _aiSettings = AiSettings();
  bool _aiSettingsLoaded = false;
  bool _aiOpen = false;
  final double _aiWidth = 380;

  // 画笔模式
  bool _brushMode = false;

  @override
  void initState() {
    super.initState();
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
        final starts = _data!.starts;
        _curTalkId = starts.isNotEmpty ? starts.first : null;
        _curBgKey = null;
        _curBgName = null;
        _loading = false;
      });
      _preloadImages();
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
    for (final c in stage.chars) {
      if (c.tex.isNotEmpty) {
        await _loadTex(c.tex);
      }
    }
    if (mounted) setState(() {});
  }

  Future<Uint8List?> _loadTex(String key) async {
    if (key.isEmpty) return null;
    final cached = _imgCache[key];
    if (cached != null) return cached;
    if (_imgLoading.contains(key)) return null;
    _imgLoading.add(key);
    try {
      final r = await ApiClient.instance
          .post('/api/aa/preview', body: {'kind': 'tex', 'key': key});
      final data = r['data'];
      if (data is String) {
        final bytes = base64Decode(data);
        _imgCache[key] = bytes;
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
  }

  void _goBack() {
    if (_hist.isEmpty) return;
    setState(() {
      _curTalkId = _hist.removeLast();
    });
    _preloadImages();
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
      setState(() => _aiOpen = true);
    }
    // AI 面板挂载 + 异步初始化需要时间，轮询重试直到注入成功（最多 5s）。
    var attempts = 0;
    Timer.periodic(const Duration(milliseconds: 250), (timer) async {
      attempts++;
      final ok = await _aiKey.currentState?.sendText(ctx) ?? false;
      if (ok || attempts >= 20 || !mounted) {
        timer.cancel();
        if (mounted && !ok && attempts >= 20) {
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
          onBack: _goBack,
          onNext: _goNext,
          onBrush: () => setState(() => _brushMode = !_brushMode),
          onAi: () => setState(() => _aiOpen = !_aiOpen),
          onRefresh: _load,
          onEdit: () => widget.controller
              .open(OpenDoc.cfg(cfgName: 'EvtCfg')),
        ),
        Divider(height: 1, color: palette.border),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: _buildStage(),
              ),
              if (_aiOpen) ...[
                VerticalDivider(width: 1, color: palette.border),
                SizedBox(
                  width: _aiWidth,
                  child: AiPanel(
                    key: _aiKey,
                    state: widget.state,
                    settings: _aiSettingsLoaded ? _aiSettings : AiSettings(),
                    onChanged: (s) => setState(() => _aiSettings = s),
                    onOpenSettings: null,
                  ),
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
    final bgBytes = bgKey != null ? _imgCache[bgKey] : null;
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
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // 背景
                  if (bgBytes != null)
                    Image.memory(bgBytes,
                        fit: BoxFit.cover, gaplessPlayback: true)
                  else
                    _Placeholder(
                      label: (bgKey == null || bgKey.isEmpty)
                          ? '无背景画面（该对白未指定背景）'
                          : (_imgErrors.containsKey(bgKey)
                              ? '背景不可用：${_imgErrors[bgKey]}'
                              : '背景加载中…'),
                      color: palette.bgDeep,
                    ),
                  // 立绘
                  for (final c in talk.stage.chars)
                    _CharSprite(
                      char: c,
                      bytes: c.tex.isNotEmpty ? _imgCache[c.tex] : null,
                    ),
                  // 选项
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
                  // 对白框
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
                  // 画笔覆盖层
                  if (_brushMode)
                    _BrushOverlay(
                      onDone: _onBrushDone,
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  void dispose() {
    super.dispose();
  }
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
    required this.onBack,
    required this.onNext,
    required this.onBrush,
    required this.onAi,
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
  final VoidCallback onBack;
  final VoidCallback onNext;
  final VoidCallback onBrush;
  final VoidCallback onAi;
  final VoidCallback onRefresh;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 40,
      color: palette.bg,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Row(
        children: [
          const Icon(FluentIcons.tv_24_regular, size: 15, color: Color(0xFF6C5CE7)),
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
          _ToolButton(
            icon: FluentIcons.chevron_left_24_regular,
            tooltip: '上一条对白',
            enabled: canBack,
            onTap: onBack,
          ),
          _ToolButton(
            icon: FluentIcons.chevron_right_24_regular,
            tooltip: '下一条对白',
            enabled: canNext,
            onTap: onNext,
          ),
          const SizedBox(width: 8),
          const _VDiv(),
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
          const _VDiv(),
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
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.forbidden,
      child: fluent.Tooltip(
        message: tooltip,
        child: GestureDetector(
          onTap: enabled ? onTap : null,
          child: Container(
            width: 30,
            height: 30,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: active ? palette.tintAccent : Colors.transparent,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Icon(icon, size: 15, color: color),
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
  const _CharSprite({required this.char, required this.bytes});
  final PreviewChar char;
  final Uint8List? bytes;

  @override
  Widget build(BuildContext context) {
    if (char.tex.isEmpty) return const SizedBox.shrink();
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
          child: bytes == null
              ? const SizedBox.shrink()
              : Transform.flip(
                  flipX: char.flip,
                  child: Image.memory(
                    bytes!,
                    fit: BoxFit.contain,
                    alignment: Alignment.bottomCenter,
                    gaplessPlayback: true,
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
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0x00000000), Color(0xE6101014)],
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
                    color: isNarrator ? palette.card : const Color(0xFF6C5CE7),
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
            color: const Color(0xCC1E1E24),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: palette.borderHover),
          ),
          child: Row(
            children: [
              const Icon(FluentIcons.diamond_24_regular, size: 13, color: Color(0xFF6C5CE7)),
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
  _BrushPainter({this.rect});
  final Rect? rect;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0x14000000),
    );
    final r = rect;
    if (r == null) return;
    final paint = Paint()
      ..color = const Color(0x338B7FEF)
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
      text: const TextSpan(
        text: '已圈选，松开后交给 AI',
        style: TextStyle(fontSize: 12, color: Colors.white),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(r.left + 6, r.top - tp.height - 4));
  }

  @override
  bool shouldRepaint(covariant _BrushPainter old) => old.rect != rect;
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
