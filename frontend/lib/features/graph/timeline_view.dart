/// 事件时间轴：横向轴按 rounds（契约上限 62 回合）铺年/季/回合刻度带，
/// holiday 段加条纹灰底；事件条目按 [assignLanes] 的泳道贪心算法排布，
/// 颜色按 cfg 类别；顶部 npc/mapId 过滤 chips。
///
/// 实现形态：与 story_flow_graph 同款「Listener 原始指针手写平移缩放 +
/// 外层单个 Transform 施加视口矩阵」，但内容全部是真实 Widget（色带/标签/
/// 条目条），而非 CustomPaint——条目点击天然走子树 GestureDetector，
/// 测试也能按 key 断言色带与泳道。视口用独立的 [GraphViewport]（零画布依赖）。
///
/// 平移/缩放只换视口 notifier：顶栏/底栏/详情面板不随拖动帧重建；世界层按
/// 可见世界矩形裁剪，视口外子项不构建，可见子项按内容签名缓存实例复用
/// （同 story_flow_graph 的阶段 4 做法，探针见 [debugTimelineChildBuilds]）。
///
/// 交互：拖拽平移、滚轮以光标为不动点缩放、点条目 → 右侧详情面板
/// （name + timeKinds + codes + 完整 spans），面板里「打开该事件」调
/// [TimelineView.onOpenSource]；点空白收起详情。底部图例 +
/// 「无法映射到回合的特殊时间约束」折叠列表（[TimelineData.specialItems]）。
library;

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../core/api_client.dart';
import '../../core/app_theme.dart';
import 'graph_models.dart';

/// 每回合在世界坐标里的基准宽度（像素；缩放由视口叠加）。
const double kTlRoundW = 46;

/// 基准探针：宿主 build 次数。平移/缩放不应让它增长（旧实现每帧 setState
/// 会把顶栏/底栏/详情面板一起重建），它是「拖动帧是否整树重建」的准出指标。
@visibleForTesting
int debugTimelineHostBuilds = 0;

/// 基准探针：世界层重建次数（每次视口变化 +1，与拖动帧同频）。
@visibleForTesting
int debugTimelineWorldBuilds = 0;

/// 基准探针：新建世界层子项 Widget 实例的次数（内容签名变化时才应增长；
/// 纯平移一帧、可见集合不变时应为 0）。
@visibleForTesting
int debugTimelineChildBuilds = 0;

/// 基准探针：因视口裁剪跳过的子项数（视口外条目一次都不构建）。
@visibleForTesting
int debugTimelineCulledChildren = 0;

// 世界 y 带布局（自上而下）：年份行 / 季节色带 / 刻度行 / 泳道区。
const double _kYearH = 20, _kSeasonH = 22, _kTickH = 16;
const double _kLaneTop = _kYearH + _kSeasonH + _kTickH;
const double _kLaneH = 18, _kLaneGap = 4;

class TimelineView extends StatefulWidget {
  const TimelineView({super.key, this.onOpenSource});

  /// 点详情「打开该事件」→ 宿主打开 (cfg, id) 文档。
  final void Function(String cfg, String id)? onOpenSource;

  @override
  State<TimelineView> createState() => TimelineViewState();
}

class TimelineViewState extends State<TimelineView> {
  bool _loading = true;
  String _error = '';
  TimelineData _data = TimelineData(rounds: const [], items: const []);

  TimelineItem? _selected;
  String? _npc;
  String? _mapId;
  bool _specialOpen = false;

  // 视口（世界→屏幕 = pan + scale·world）。只走 notifier 不走 setState：
  // setState 会让顶栏/底栏/详情面板跟着拖动帧一起重建（旧实现的负担来源）。
  final ValueNotifier<GraphViewport> _vp =
      ValueNotifier(const GraphViewport(1, Offset(12, 8)));
  int? _activePointer;
  Offset _downLocal = Offset.zero;
  Offset _downPan = Offset.zero;

  /// 世界层子项实例缓存（key = 稳定标识）。内容签名不变时按 key 复用同一
  /// Widget 实例：平移帧里 Element.updateChild 对 identical 子项短路，可见
  /// 条目一次 build 都不进（同 story_flow_graph 的卡片实例缓存思路）。
  final Map<String, Widget> _worldChildren = {};
  int? _worldSig;

  /// 供基准测试读取视口平移量（同 story_flow_graph 的 viewportListenable）。
  @visibleForTesting
  ValueListenable<GraphViewport> get viewportListenable => _vp;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _vp.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      final resp = await ApiClient.instance.get('/api/graph/timeline');
      if (!mounted) return;
      final data = parseTimeline(resp is Map ? resp : const {});
      setState(() {
        _data = data;
        _loading = false;
        _selected = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '加载失败：$e';
      });
    }
  }

  /// 供测试/宿主触发重拉。
  void refresh() => _load();

  /// 过滤后的上轴条目（special 已被 [TimelineData.axisItems] 挡在外面）。
  List<TimelineItem> get _axisItems =>
      filterTimelineItems(_data.axisItems, npc: _npc, mapId: _mapId);

  // ---------- 手写平移 / 缩放 ----------

  void _onPointerDown(PointerDownEvent e) {
    if (_activePointer != null || (e.buttons & kPrimaryButton) == 0) return;
    _activePointer = e.pointer;
    _downLocal = e.localPosition;
    _downPan = _vp.value.pan;
  }

  void _onPointerMove(PointerMoveEvent e) {
    if (e.pointer != _activePointer) return;
    // GraphViewport 有值相等语义：原地未动时 notifier 不发通知，零重建。
    _vp.value =
        GraphViewport(_vp.value.scale, _downPan + (e.localPosition - _downLocal));
  }

  void _onPointerUp(PointerUpEvent e) {
    if (e.pointer == _activePointer) _activePointer = null;
  }

  void _onPointerSignal(PointerSignalEvent e) {
    if (e is! PointerScrollEvent) return;
    final vp = _vp.value;
    final factor = e.scrollDelta.dy > 0 ? 0.9 : 1.1;
    final next = (vp.scale * factor)
        .clamp(GraphViewport.minScale, GraphViewport.maxScale)
        .toDouble();
    if (next == vp.scale) return;
    _vp.value = vp.withZoom(next, e.localPosition);
  }

  // ---------- 世界几何 ----------

  /// 回合号 → 色带左缘世界 x（找不到时按相对首回合的序号线性外推并钳位）。
  double _xOfRound(TimelineRound first, Map<int, int> roundIndex, int count,
      int round,
      {bool end = false}) {
    final idx = roundIndex[round] ??
        (round - first.round).clamp(0, count - 1);
    final x = idx * kTlRoundW;
    return end ? x + kTlRoundW : x.toDouble();
  }

  @override
  Widget build(BuildContext context) {
    if (kDebugMode) debugTimelineHostBuilds++;
    return Container(
      color: palette.bg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _topBar(),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error.isNotEmpty
                    ? _errorState()
                    : _data.rounds.isEmpty
                        ? _emptyState()
                        : Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Expanded(child: _axis()),
                              if (_selected != null)
                                SizedBox(width: 280, child: _detailPanel()),
                            ],
                          ),
          ),
          _bottomBar(),
        ],
      ),
    );
  }

  Widget _errorState() => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 32, color: palette.statusDanger),
            const SizedBox(height: 8),
            Text(_error,
                style: TextStyle(fontSize: 12, color: palette.textSecondary)),
            const SizedBox(height: 10),
            TextButton(
                onPressed: _load,
                child: const Text('重试', style: TextStyle(fontSize: 12))),
          ],
        ),
      );

  Widget _emptyState() => Center(
        child: Text('没有时间轴数据\n（后端 GET /api/graph/timeline 未返回 rounds）',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: palette.textHint)),
      );

  // ---------- 顶栏：过滤 chips ----------

  Widget _topBar() {
    final items = _data.items;
    final npcs = {for (final it in items) if (it.npc.isNotEmpty) it.npc}.take(10).toList();
    final maps = {for (final it in items) if (it.mapId.isNotEmpty) it.mapId}.take(10).toList();
    return Container(
      decoration: BoxDecoration(
        color: palette.card,
        border: Border(bottom: BorderSide(color: palette.border)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.timeline, size: 15, color: accentColor),
              const SizedBox(width: 6),
              Text('事件时间轴',
                  style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: palette.textHigh)),
              const SizedBox(width: 10),
              Text('共 ${_axisItems.length} 条上轴',
                  style: TextStyle(fontSize: 10.5, color: palette.textMuted)),
              const Spacer(),
              IconButton(
                tooltip: '刷新',
                onPressed: _load,
                iconSize: 16,
                visualDensity: VisualDensity.compact,
                icon: Icon(Icons.refresh, color: palette.textSecondary),
              ),
            ],
          ),
          if (npcs.isNotEmpty || maps.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  for (final n in npcs)
                    _chip(
                      keyName: 'tl-chip-npc-$n',
                      label: '人物 $n',
                      on: _npc == n,
                      onTap: () =>
                          setState(() => _npc = _npc == n ? null : n),
                    ),
                  for (final m in maps)
                    _chip(
                      keyName: 'tl-chip-map-$m',
                      label: '地图 $m',
                      on: _mapId == m,
                      onTap: () =>
                          setState(() => _mapId = _mapId == m ? null : m),
                    ),
                  if (_npc != null || _mapId != null)
                    _chip(
                      keyName: 'tl-chip-clear',
                      label: '清除过滤',
                      on: false,
                      onTap: () => setState(() {
                        _npc = null;
                        _mapId = null;
                      }),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _chip({
    required String keyName,
    required String label,
    required bool on,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      key: ValueKey(keyName),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: on ? accentColor.withValues(alpha: 0.18) : palette.surface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: on ? accentColor : palette.border),
        ),
        child: Text(label,
            style: TextStyle(
                fontSize: 10.5,
                color: on ? palette.textHigh : palette.textSecondary)),
      ),
    );
  }

  // ---------- 画布：视口 + 世界坐标 Widget 层 ----------

  Widget _axis() {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _onPointerDown,
      onPointerMove: _onPointerMove,
      onPointerUp: _onPointerUp,
      onPointerCancel: (e) {
        if (e.pointer == _activePointer) _activePointer = null;
      },
      onPointerSignal: _onPointerSignal,
      child: GestureDetector(
        // 空白处点击收起详情（条目自己的 onTap 在子树里优先赢下竞技场）。
        behavior: HitTestBehavior.translucent,
        onTap: () {
          if (_selected != null) setState(() => _selected = null);
        },
        child: ClipRect(
          child: LayoutBuilder(builder: (context, box) {
            final size = Size(box.maxWidth, box.maxHeight);
            return ValueListenableBuilder<GraphViewport>(
              valueListenable: _vp,
              builder: (context, vp, _) {
                // 平移/缩放只途经这个 builder：世界层外的控件（顶栏/底栏/
                // 详情面板/过滤 chips）一帧都不重建。
                final world = SizedBox(
                  width: size.width / vp.scale,
                  height: size.height / vp.scale,
                  child: _worldLayer(vp, size),
                );
                return Transform(
                  transform: Matrix4.translationValues(vp.pan.dx, vp.pan.dy, 0)
                    ..multiply(Matrix4.diagonal3Values(vp.scale, vp.scale, 1)),
                  // 边界收在画布内：世界层重绘不向上传播到宿主页面。
                  child: RepaintBoundary(child: world),
                );
              },
            );
          }),
        ),
      ),
    );
  }

  /// 按 key 取（或构建）子项实例。同 story_flow 的 `_cardFor`：只有缓存
  /// 未命中才新建，纯平移帧应为 0 次新建（探针 [debugTimelineChildBuilds]）。
  Widget _child(String key, Widget Function() build, {bool culled = false}) {
    if (culled) {
      if (kDebugMode) debugTimelineCulledChildren++;
      return const SizedBox.shrink();
    }
    final hit = _worldChildren[key];
    if (hit != null) return hit;
    if (kDebugMode) debugTimelineChildBuilds++;
    final w = build();
    _worldChildren[key] = w;
    return w;
  }

  /// 世界层内容签名：数据 / 过滤后的上轴集合（同一批 [TimelineItem] 实例）/
  /// 选中项 / 刻度档 / 调色板实例（亮暗与主题色变化都会换新实例）。
  /// 只有这些变化才作废子项实例缓存；视口（平移缩放）刻意不进签名。
  /// 用 identityHashCode 逐个混入：O(n) 且不分配字符串，拖动帧开销可忽略。
  int _worldSignature(List<TimelineItem> items, TimelineTickMode tick) {
    var sig = Object.hash(identityHashCode(_data), identityHashCode(_selected),
        identityHashCode(palette), tick.index);
    for (final it in items) {
      sig = Object.hash(sig, identityHashCode(it));
    }
    return sig;
  }

  Widget _worldLayer(GraphViewport vp, Size viewSize) {
    if (kDebugMode) debugTimelineWorldBuilds++;
    final rounds = _data.rounds;
    final items = _axisItems;
    final n = rounds.length;
    final worldW = n * kTlRoundW;
    final roundIndex = <int, int>{
      for (var i = 0; i < n; i++) rounds[i].round: i,
    };
    final layout = assignLanes(items, maxRound: _data.maxRound);
    final laneCount = math.max(1, layout.laneCount);
    final contentH = _kLaneTop + laneCount * (_kLaneH + _kLaneGap) + 10;
    final tickMode = timelineTickMode(kTlRoundW * vp.scale);

    final sig = _worldSignature(items, tickMode);
    if (sig != _worldSig) {
      _worldChildren.clear();
      _worldSig = sig;
    }
    // 可见世界矩形（外扩一回合宽，拖动时不会看到色带从边缘「长出来」）。
    final visible = vp.worldRect(viewSize).inflate(kTlRoundW * 2);

    bool xVisible(double x, double w) =>
        x + w >= visible.left && x <= visible.right;

    final children = <Widget>[
      // 年分隔线（细竖线，画满内容高）。
      for (var i = 0; i < n; i++)
        if (i == 0 || rounds[i - 1].year != rounds[i].year)
          _child(
            'tl-yline-$i',
            () => Positioned(
              left: i * kTlRoundW,
              top: 0,
              width: 1,
              height: contentH,
              child: ColoredBox(color: palette.borderHover),
            ),
            culled: !xVisible(i * kTlRoundW, 1),
          ),
      // 季节色带 + holiday 条纹。
      for (var i = 0; i < n; i++)
        _child(
          'tl-band-${rounds[i].round}',
          () => Positioned(
            key: ValueKey('tl-band-${rounds[i].round}'),
            left: i * kTlRoundW,
            top: _kYearH,
            width: kTlRoundW,
            height: _kSeasonH,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: seasonColor(rounds[i].season)
                    .withValues(alpha: rounds[i].holiday ? 0.22 : 0.5),
                border: Border(
                  left: BorderSide(color: palette.border.withValues(alpha: 0.6)),
                ),
              ),
              child: rounds[i].holiday
                  ? CustomPaint(
                      key: ValueKey('tl-holiday-${rounds[i].round}'),
                      painter: _StripePainter(),
                      size: Size.infinite,
                    )
                  : const SizedBox.shrink(),
            ),
          ),
          culled: !xVisible(i * kTlRoundW, kTlRoundW),
        ),
      // 年份标签：只在年段起点出现一次。
      for (var i = 0; i < n; i++)
        if (i == 0 || rounds[i - 1].year != rounds[i].year)
          _child(
            'tl-year-${rounds[i].year}',
            () => Positioned(
              key: ValueKey('tl-year-${rounds[i].year}'),
              left: i * kTlRoundW + 4,
              top: 2,
              child: Text(
                '第${rounds[i].year}年',
                style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    color: palette.textPrimary),
              ),
            ),
            // 标签宽度不定，左侧多留一格作余量。
            culled: !xVisible(i * kTlRoundW + 4, kTlRoundW * 2),
          ),
      // 刻度标签：密度自适应（full=每回合 round+名；season=季节起点；year=年份）。
      for (var i = 0; i < n; i++)
        if (_showsTick(tickMode, rounds, i))
          _child(
            'tl-tick-${rounds[i].round}',
            () => Positioned(
              key: ValueKey('tl-tick-${rounds[i].round}'),
              left: i * kTlRoundW + 2,
              top: _kYearH + _kSeasonH + 2,
              child: Text(
                _tickLabel(tickMode, rounds[i]),
                style: TextStyle(fontSize: 8.5, color: palette.textHint),
              ),
            ),
            culled: !xVisible(i * kTlRoundW + 2, kTlRoundW),
          ),
    ];

    // 泳道条目。
    final first = rounds.first;
    for (var k = 0; k < items.length; k++) {
      final it = items[k];
      final lane = layout.laneByIndex[k];
      final rng = it.resolvedRange(_data.maxRound);
      final x1 = _xOfRound(first, roundIndex, n, rng.start);
      // to==null（或钳到轴末）→ 画到轴末。
      final x2 = rng.end >= _data.maxRound
          ? worldW.toDouble()
          : _xOfRound(first, roundIndex, n, rng.end, end: true);
      final y = _kLaneTop + lane * (_kLaneH + _kLaneGap);
      final sel = identical(_selected, it);
      final color = timelineCfgColor(it.cfg);
      final w = math.max(6.0, x2 - x1 - 2);
      children.add(_child(
        'tl-item-${it.cfg}-${it.id}',
        () => Positioned(
          key: ValueKey('tl-item-${it.cfg}-${it.id}'),
          left: x1 + 1,
          top: y,
          width: w,
          height: _kLaneH,
          child: GestureDetector(
            onTap: () => setState(() => _selected = it),
            child: Tooltip(
              message: it.name.isEmpty ? it.id : it.name,
              child: Container(
                decoration: BoxDecoration(
                  color: color.withValues(alpha: sel ? 0.95 : 0.7),
                  borderRadius: BorderRadius.circular(3),
                  border: sel
                      ? Border.all(color: accentColor, width: 1.4)
                      : Border.all(
                          color: lightenColor(color).withValues(alpha: 0.5)),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 4),
                alignment: Alignment.centerLeft,
                child: Text(
                  it.name.isEmpty ? '#${it.id}' : it.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 9,
                      color: sel ? palette.onAccent : palette.textHigh),
                ),
              ),
            ),
          ),
        ),
        culled: !xVisible(x1 + 1, w),
      ));
    }

    return Stack(clipBehavior: Clip.none, children: children);
  }

  bool _showsTick(TimelineTickMode mode, List<TimelineRound> rounds, int i) {
    switch (mode) {
      case TimelineTickMode.full:
        return true;
      case TimelineTickMode.season:
        return i == 0 || rounds[i - 1].season != rounds[i].season;
      case TimelineTickMode.year:
        return i == 0 || rounds[i - 1].year != rounds[i].year;
    }
  }

  String _tickLabel(TimelineTickMode mode, TimelineRound r) {
    switch (mode) {
      case TimelineTickMode.full:
        return '${r.round}·${r.seasonName}';
      case TimelineTickMode.season:
        return r.seasonName.isEmpty ? '${r.round}' : r.seasonName;
      case TimelineTickMode.year:
        return '第${r.year}年';
    }
  }

  // ---------- 右侧详情 ----------

  Widget _detailPanel() {
    final it = _selected!;
    return Container(
      decoration: BoxDecoration(
        color: palette.panel,
        border: Border(left: BorderSide(color: palette.border)),
      ),
      child: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Row(
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                    color: timelineCfgColor(it.cfg),
                    borderRadius: BorderRadius.circular(2)),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  it.name.isEmpty ? '#${it.id}' : it.name,
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: palette.textHigh),
                ),
              ),
              IconButton(
                key: const ValueKey('tl-detail-close'),
                iconSize: 14,
                visualDensity: VisualDensity.compact,
                onPressed: () => setState(() => _selected = null),
                icon: Icon(Icons.close, color: palette.textHint),
              ),
            ],
          ),
          const SizedBox(height: 6),
          _kv('来源', '${it.cfg} · #${it.id}'),
          _kv('人物', it.npc.isEmpty ? '—' : 'id ${it.npc}'),
          _kv('地图', it.mapId.isEmpty ? '—' : 'id ${it.mapId}'),
          _kv('时间语义', it.timeKinds.isEmpty ? '—' : it.timeKinds.join(' / ')),
          _kv('跨段',
              it.spans.map(timelineSpanLabel).join('\n')),
          const SizedBox(height: 8),
          Text('代码',
              style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: palette.textPrimary)),
          const SizedBox(height: 4),
          for (final c in it.codes)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 1),
              child: Text(c,
                  style: TextStyle(
                      fontSize: 10.5,
                      fontFamily: 'Consolas',
                      color: palette.textSecondary)),
            ),
          const SizedBox(height: 12),
          SizedBox(
            height: 30,
            child: FilledButton.icon(
              key: const ValueKey('tl-open-source'),
              onPressed: () => widget.onOpenSource?.call(it.cfg, it.id),
              icon: const Icon(Icons.open_in_new, size: 15),
              label: const Text('打开该事件', style: TextStyle(fontSize: 12)),
              style: FilledButton.styleFrom(
                backgroundColor: accentColor,
                foregroundColor: palette.onAccent,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 56,
              child: Text(k,
                  style: TextStyle(fontSize: 10.5, color: palette.textHint)),
            ),
            Expanded(
              child: Text(v,
                  style: TextStyle(fontSize: 11, color: palette.textPrimary)),
            ),
          ],
        ),
      );

  // ---------- 底部：图例 + 特殊约束折叠 ----------

  Widget _bottomBar() {
    final cfgs = {for (final it in _data.items) it.cfg}.toList()..sort();
    final specials = _data.specialItems;
    return Container(
      decoration: BoxDecoration(
        color: palette.card,
        border: Border(top: BorderSide(color: palette.border)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('图例：',
                  style: TextStyle(fontSize: 10.5, color: palette.textMuted)),
              Expanded(
                child: Wrap(
                  spacing: 10,
                  runSpacing: 3,
                  children: [
                    for (final c in cfgs)
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 9,
                            height: 9,
                            decoration: BoxDecoration(
                                color: timelineCfgColor(c),
                                borderRadius: BorderRadius.circular(2)),
                          ),
                          const SizedBox(width: 4),
                          Text(c,
                              style: TextStyle(
                                  fontSize: 10.5,
                                  color: palette.textSecondary)),
                        ],
                      ),
                  ],
                ),
              ),
            ],
          ),
          if (specials.isNotEmpty) ...[
            const SizedBox(height: 4),
            InkWell(
              key: const ValueKey('tl-special-toggle'),
              onTap: () => setState(() => _specialOpen = !_specialOpen),
              child: Row(
                children: [
                  Icon(
                    _specialOpen ? Icons.expand_less : Icons.expand_more,
                    size: 14,
                    color: palette.textHint,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    '无法映射到回合的特殊时间约束（${specials.length}）',
                    key: const ValueKey('tl-special-summary'),
                    style: TextStyle(
                        fontSize: 10.5,
                        color: palette.statusWarn,
                        fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ),
            if (_specialOpen)
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 120),
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final s in specials)
                      Padding(
                        key: ValueKey('tl-special-${s.cfg}-${s.id}'),
                        padding: const EdgeInsets.symmetric(vertical: 1),
                        child: Text(
                          '· ${s.name.isEmpty ? s.id : s.name}  [${s.timeKinds.join(',')}] ${s.codes.join(' ')}',
                          style: TextStyle(
                              fontSize: 10.5, color: palette.textSecondary),
                        ),
                      ),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }
}

/// holiday 色带的斜纹：45° 一组细线，画进色带自身的盒子里。
class _StripePainter extends CustomPainter {
  _StripePainter() : _light = palette.isLight;

  /// 斜纹取自 palette.textHint：亮暗切换后必须重绘（旧代码恒 false 会留旧色）。
  final bool _light;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = palette.textHint.withValues(alpha: 0.35)
      ..strokeWidth = 1;
    for (var dx = -size.height; dx < size.width; dx += 6) {
      canvas.drawLine(Offset(dx.toDouble(), size.height),
          Offset(dx + size.height, 0), p);
    }
  }

  @override
  bool shouldRepaint(covariant _StripePainter old) => old._light != _light;
}
