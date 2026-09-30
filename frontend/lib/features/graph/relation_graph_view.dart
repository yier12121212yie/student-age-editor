/// 人物关系图（ego 视图）：顶部人物搜索选择器 + 关系等级过滤器，
/// 中央画布把手选所选人的关联记录按 kind 分扇区放射摆放，
/// 右侧栏是两张手写图表（[relation_charts]）。
///
/// 数据：进入视图时 GET /api/graph/relations 一次，缓存于本 State；
/// 顶栏「刷新」按钮重拉。画布平移/缩放走手写 Listener（借鉴
/// story_flow_graph 的视口方案，但用独立的 [GraphViewport]），
/// 与 story_flow_graph 零耦合。
///
/// 点击任一关联徽标 → [RelationGraphView.onOpenSource]（交宿主打开来源 cfg 文档）。
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../core/api_client.dart';
import '../../core/app_theme.dart';
import '../resources/image_asset_picker.dart' show TexThumb;
import 'graph_models.dart';
import 'relation_charts.dart';

/// 关系图主体。宿主在 [onOpenSource] 里决定「打开来源事件文档」的落地方式
/// （剧情图壳里先以切页 + 打开 cfg 文档实现，或退化为 InfoBar 提示）。
class RelationGraphView extends StatefulWidget {
  const RelationGraphView({
    super.key,
    this.onOpenSource,
  });

  /// 点击关联记录的来源行 → 交给宿主打开 (sourceCfg, sourceId)。
  final void Function(String sourceCfg, String sourceId)? onOpenSource;

  @override
  State<RelationGraphView> createState() => RelationGraphViewState();
}

class RelationGraphViewState extends State<RelationGraphView> {
  bool _loading = true;
  String _error = '';
  RelationsData _data = RelationsData(nodes: const [], levels: const [], edges: const []);

  /// 当前聚焦人物 id（默认取 nodes 第一个）。
  String? _focusId;

  /// 关系等级过滤器（空 = 全部）。
  final Set<String> _levelFilter = {};

  /// 人物搜索下拉是否展开 + 搜索词。
  bool _pickerOpen = false;
  String _query = '';
  final TextEditingController _searchCtl = TextEditingController();

  /// 视口 + 视图尺寸（手写平移缩放）。
  final ValueNotifier<GraphViewport> _vp =
      ValueNotifier(const GraphViewport(1, Offset.zero));
  Offset _panStart = Offset.zero;
  Offset _panStartVP = Offset.zero;
  int? _activePointer;
  bool _autoFit = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchCtl.dispose();
    _vp.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      final resp = await ApiClient.instance.get('/api/graph/relations');
      if (!mounted) return;
      final data = parseRelations(resp is Map ? resp : const {});
      setState(() {
        _data = data;
        _loading = false;
        _focusId ??= data.nodes.isEmpty ? null : data.nodes.first.id;
        _autoFit = true;
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

  // ---------- 派生（每次 build 量级很小：边数封顶后才画） ----------

  RelationNode? get _focusNode {
    final id = _focusId;
    if (id == null) return null;
    return _data.nodeById[id];
  }

  List<RelationEdge> get _visibleEdges {
    final id = _focusId;
    if (id == null) return const [];
    return filterEdgesByLevel(edgesConnectedTo(_data.edges, id), _levelFilter);
  }

  List<(String, int)> get _kindCounts {
    final c = <String, int>{};
    for (final e in _visibleEdges) {
      c[e.kind] = (c[e.kind] ?? 0) + 1;
    }
    // 稳定序：先词表内 kind，再字典序补集。
    final keys = <String>[
      for (final k in kRelationKinds)
        if (c.containsKey(k)) k,
      for (final k in c.keys.toList()..sort())
        if (!kRelationKinds.contains(k)) k,
    ];
    return [for (final k in keys) (k, c[k]!)];
  }

  // ---------- 视口手势 ----------

  void _onPanDown(PointerDownEvent e) {
    if (_activePointer != null) return;
    _activePointer = e.pointer;
    _panStart = e.localPosition;
    _panStartVP = _vp.value.pan;
  }

  void _onPanMove(PointerMoveEvent e) {
    if (e.pointer != _activePointer) return;
    _vp.value = GraphViewport(
      _vp.value.scale,
      _panStartVP + (e.localPosition - _panStart),
    );
  }

  void _onPanEnd(PointerUpEvent e) {
    if (e.pointer == _activePointer) _activePointer = null;
  }

  void _onPointerSignal(PointerSignalEvent e) {
    if (e is! PointerScrollEvent) return;
    final factor = e.scrollDelta.dy > 0 ? 0.9 : 1.1;
    final next = (_vp.value.scale * factor)
        .clamp(GraphViewport.minScale, GraphViewport.maxScale)
        .toDouble();
    if (next == _vp.value.scale) return;
    _vp.value = _vp.value.withZoom(next, e.localPosition);
  }

  void _fitCenter(Size size) {
    // 把放射图中心（focus 人）落到画布正中。
    _vp.value = GraphViewport(1, Offset(size.width / 2, size.height / 2));
  }

  @override
  Widget build(BuildContext context) {
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
                    : Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(child: _canvas()),
                          SizedBox(
                            width: 260,
                            child: _sidePanel(),
                          ),
                        ],
                      ),
          ),
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

  // ---------- 顶栏 ----------

  Widget _topBar() {
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
              Icon(Icons.family_restroom, size: 15, color: accentColor),
              const SizedBox(width: 6),
              Text('人物关系图',
                  style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: palette.textHigh)),
              const SizedBox(width: 14),
              _focusPicker(),
              const SizedBox(width: 10),
              _levelFilterChipLabel(),
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
          if (_data.levels.isNotEmpty) _levelFilterRow(),
        ],
      ),
    );
  }

  /// 顶部人物搜索下拉（自绘：按钮 + 展开面板里的搜索框 + 结果列表）。
  Widget _focusPicker() {
    final name = _focusNode?.name ?? (_focusId ?? '选择人物');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () => setState(() {
            _pickerOpen = !_pickerOpen;
            if (_pickerOpen) {
              _searchCtl.clear();
              _query = '';
            }
          }),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: palette.surface,
              borderRadius: BorderRadius.circular(AppRadius.m),
              border: Border.all(color: palette.border),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.person_search, size: 13, color: palette.textHint),
                const SizedBox(width: 5),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 140),
                  child: Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 11.5, color: palette.textPrimary),
                  ),
                ),
                Icon(
                  _pickerOpen ? Icons.expand_less : Icons.expand_more,
                  size: 14,
                  color: palette.textHint,
                ),
              ],
            ),
          ),
        ),
        if (_pickerOpen) _pickerPanel(),
      ],
    );
  }

  Widget _pickerPanel() {
    final q = _query.trim().toLowerCase();
    final matches = [
      for (final n in _data.nodes)
        if (q.isEmpty ||
            n.name.toLowerCase().contains(q) ||
            n.id.toLowerCase().contains(q))
          n,
    ];
    return SizedBox(
      width: 200,
      child: Material(
        // 浮动层必须自带不透明底板（本 app 有全局透明 Material 祖先）。
        color: palette.card,
        elevation: 6,
        borderRadius: BorderRadius.circular(AppRadius.l),
        child: Container(
          decoration: BoxDecoration(
            border: Border.all(color: palette.border),
            borderRadius: BorderRadius.circular(AppRadius.l),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 6, 8, 0),
                child: TextField(
                  key: const ValueKey('rg-search'),
                  autofocus: true,
                  controller: _searchCtl,
                  style: TextStyle(fontSize: 11.5, color: palette.textPrimary),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: '搜索人物…',
                    hintStyle:
                        TextStyle(fontSize: 11.5, color: palette.textHint),
                    border: InputBorder.none,
                    prefixIcon: Icon(Icons.search,
                        size: 14, color: palette.textHint),
                    prefixIconConstraints:
                        const BoxConstraints(minWidth: 26, minHeight: 26),
                  ),
                  onChanged: (v) => setState(() => _query = v),
                ),
              ),
              const SizedBox(height: 6),
              Divider(height: 1, color: palette.border),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 220),
                child: ListView.builder(
                  shrinkWrap: true,
                  padding: EdgeInsets.zero,
                  itemCount: matches.length,
                  itemBuilder: (context, i) {
                    final n = matches[i];
                    final sel = n.id == _focusId;
                    return ListTile(
                      dense: true,
                      visualDensity: VisualDensity.compact,
                      selected: sel,
                      selectedTileColor: accentColor.withValues(alpha: 0.12),
                      leading: SizedBox(
                        width: 26,
                        height: 26,
                        child: _roleThumb(n, 26),
                      ),
                      title: Text(n.name.isEmpty ? '#${n.id}' : n.name,
                          style: const TextStyle(fontSize: 11.5)),
                      onTap: () => setState(() {
                        _focusId = n.id;
                        _pickerOpen = false;
                        _query = '';
                        _searchCtl.clear();
                        _autoFit = true;
                      }),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _levelFilterChipLabel() => Text(
        _levelFilter.isEmpty
            ? '全部等级'
            : '等级筛选 ${_levelFilter.length}',
        style: TextStyle(fontSize: 11, color: palette.textMuted),
      );

  Widget _levelFilterRow() {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Wrap(
        spacing: 6,
        runSpacing: 4,
        children: [
          _filterChip(
            label: '全部',
            color: palette.textMuted,
            selected: _levelFilter.isEmpty,
            onTap: () => setState(_levelFilter.clear),
          ),
          for (final l in _data.levels)
            _filterChip(
              label: l.name.isEmpty ? '#${l.id}' : l.name,
              color: l.parseColor,
              selected: _levelFilter.contains(l.id),
              onTap: () => setState(() {
                if (!_levelFilter.add(l.id)) _levelFilter.remove(l.id);
              }),
            ),
        ],
      ),
    );
  }

  Widget _filterChip({
    required String label,
    required Color color,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: selected ? color.withValues(alpha: 0.22) : palette.surface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: selected ? color : palette.border,
            width: selected ? 1.2 : 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 5),
            Text(label,
                style: TextStyle(
                    fontSize: 10.5,
                    color:
                        selected ? palette.textHigh : palette.textSecondary)),
          ],
        ),
      ),
    );
  }

  // ---------- 画布 ----------

  Widget _canvas() {
    final focus = _focusNode;
    final placed = layoutEgoGraph(edges: _visibleEdges, radius: 230);
    final levelsById = {for (final l in _data.levels) l.id: l};

    return LayoutBuilder(builder: (context, box) {
      final size = Size(box.maxWidth, box.maxHeight);
      if (_autoFit) {
        _autoFit = false;
        // post-frame 换视口：LayoutBuilder 帧内改 ValueNotifier 会与本帧 Transform 打架。
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _fitCenter(size);
        });
      }
      return ClipRect(
        child: Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: _onPanDown,
          onPointerMove: _onPanMove,
          onPointerUp: _onPanEnd,
          onPointerCancel: (e) {
            if (e.pointer == _activePointer) _activePointer = null;
          },
          onPointerSignal: _onPointerSignal,
          child: ValueListenableBuilder<GraphViewport>(
            valueListenable: _vp,
            builder: (context, vp, _) {
              return Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned.fill(
                    child: Transform(
                      transform: _matrixOf(vp),
                      child: CustomPaint(
                        painter: _EgoEdgesPainter(
                          viewport: vp,
                          placed: placed,
                          levelsById: levelsById,
                          size: size,
                        ),
                        size: Size.infinite,
                      ),
                    ),
                  ),
                  // 外围 kind 徽标（世界坐标经视口换算到屏幕）
                  for (final p in placed)
                    _placedBadge(p, vp, levelsById),
                  // 中央 focus 人卡片
                  if (focus != null) _focusCard(focus, vp),
                ],
              );
            },
          ),
        ),
      );
    });
  }

  Matrix4 _matrixOf(GraphViewport vp) => Matrix4.translationValues(
          vp.pan.dx, vp.pan.dy, 0)
        ..multiply(Matrix4.diagonal3Values(vp.scale, vp.scale, 1));

  Widget _focusCard(RelationNode n, GraphViewport vp) {
    const w = 150.0, h = 66.0;
    final screen = vp.toScreen(Offset.zero) - const Offset(w / 2, h / 2);
    return Positioned(
      left: screen.dx,
      top: screen.dy,
      child: Container(
        key: const ValueKey('rg-focus-card'),
        width: w,
        height: h,
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: palette.card,
          borderRadius: BorderRadius.circular(AppRadius.l),
          border: Border.all(color: accentColor, width: 1.4),
          boxShadow: AppShadow.float(),
        ),
        child: Row(
          children: [
            SizedBox(width: 42, height: 42, child: _roleThumb(n, 42)),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    n.name.isEmpty ? '#${n.id}' : n.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: palette.textHigh),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _genderLabel(n.gender) +
                        (n.tex == null || n.tex!.isEmpty ? '' : ' · 有立绘'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 10, color: palette.textHint),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _placedBadge(
    RelationPlacement p,
    GraphViewport vp,
    Map<String, RelationLevel> levelsById,
  ) {
    final e = p.edge;
    final color = edgeBadgeColor(e, levelsById);
    final label = relationBadgeLabel(e);
    final screen = vp.toScreen(p.center);
    final src = e.sourceName.isEmpty
        ? e.sourceCfg
        : '${e.sourceCfg}·${_clip(e.sourceName, 16)}';
    // 另一端人物（若可从 role/code 解出）→ 节点卡带立绘缩略图 + 名字。
    final nodesById = _data.nodeById;
    final cpId = _focusId == null
        ? null
        : counterpartOfEdge(e, _focusId!, _data.nodeIds);
    final cp = cpId == null ? null : nodesById[cpId];
    return Positioned(
      left: screen.dx - 70,
      top: screen.dy - 16,
      child: GestureDetector(
        onTap: () => widget.onOpenSource?.call(e.sourceCfg, e.sourceId),
        child: Container(
          // key 用来源标识而非过滤后的序号：切换聚焦人物时徽标身份仍稳定。
          key: ValueKey('rg-badge-${e.sourceCfg}-${e.sourceId}'),
          constraints: const BoxConstraints(maxWidth: 150),
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
          decoration: BoxDecoration(
            color: palette.card,
            borderRadius: BorderRadius.circular(AppRadius.m),
            border: Border.all(color: color, width: 1.2),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (cp != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 3),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                          width: 18, height: 18, child: _roleThumb(cp, 18)),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          cp.name.isEmpty ? '#${cp.id}' : cp.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 10.5,
                              fontWeight: FontWeight.w600,
                              color: palette.textHigh),
                        ),
                      ),
                    ],
                  ),
                ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 7,
                    height: 7,
                    decoration:
                        BoxDecoration(color: color, shape: BoxShape.circle),
                  ),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 10.5,
                            fontWeight: FontWeight.w600,
                            color: palette.textHigh)),
                  ),
                ],
              ),
              if (src.isNotEmpty)
                Text(src,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 9, color: palette.textHint)),
            ],
          ),
        ),
      ),
    );
  }

  // ---------- 右侧栏图表 ----------

  Widget _sidePanel() {
    return Container(
      decoration: BoxDecoration(
        color: palette.panel,
        border: Border(left: BorderSide(color: palette.border)),
      ),
      child: ListView(
        padding: const EdgeInsets.all(10),
        children: [
          Text('关系等级阶梯',
              style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: palette.textPrimary)),
          const SizedBox(height: 6),
          if (_data.levels.isEmpty)
            _emptyHint('无等级数据')
          else
            RelationLadderChart(
              levels: _data.levelsSortedByCondition,
              highlightLevelIds: _levelFilter,
            ),
          const SizedBox(height: 14),
          Text('关联计数（按类型）',
              style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: palette.textPrimary)),
          const SizedBox(height: 6),
          if (_kindCounts.isEmpty)
            _emptyHint('该人物暂无关联记录')
          else
            RelationKindBarsChart(entries: _kindCounts),
          const SizedBox(height: 14),
          Text('聚焦：${_focusNode?.name ?? _focusId ?? '—'}（${_visibleEdges.length} 条）',
              style: TextStyle(fontSize: 10.5, color: palette.textMuted)),
        ],
      ),
    );
  }

  Widget _emptyHint(String t) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(t, style: TextStyle(fontSize: 10.5, color: palette.textHint)),
      );

  Widget _roleThumb(RelationNode n, double box) {
    final tex = n.tex;
    if (tex == null || tex.isEmpty) {
      return Container(
        decoration: BoxDecoration(
          color: palette.surface,
          borderRadius: BorderRadius.circular(AppRadius.s),
        ),
        child: Icon(Icons.person, size: box * 0.55, color: palette.iconDisabled),
      );
    }
    return TexThumb(
      keyName: tex,
      width: box,
      height: box,
      borderRadius: BorderRadius.circular(AppRadius.s),
    );
  }

  String _genderLabel(int? g) =>
      g == 1 ? '男' : (g == 2 ? '女' : (g == null ? '未知' : '其他'));

  static String _clip(String s, int n) =>
      s.length <= n ? s : '${s.substring(0, n)}…';
}

/// 放射连线：从中心 (0,0) 画三次贝塞尔到每个 kind 徽标落点，
/// 颜色取该边等级色（回退 kind 色）。画在世界坐标系里，随视口整体变换。
class _EgoEdgesPainter extends CustomPainter {
  _EgoEdgesPainter({
    required this.viewport,
    required this.placed,
    required this.levelsById,
    required this.size,
  });

  final GraphViewport viewport;
  final List<RelationPlacement> placed;
  final Map<String, RelationLevel> levelsById;
  final Size size;

  final Paint _stroke = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1.4;
  final Path _path = Path();

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.translate(viewport.pan.dx, viewport.pan.dy);
    canvas.scale(viewport.scale);
    for (final p in placed) {
      final color = edgeBadgeColor(p.edge, levelsById);
      _stroke.color = color.withValues(alpha: 0.55);
      _path
        ..reset()
        ..moveTo(0, 0)
        ..cubicTo(
          p.center.dx * 0.55,
          0,
          p.center.dx * 0.45,
          p.center.dy,
          p.center.dx,
          p.center.dy,
        );
      canvas.drawPath(_path, _stroke);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _EgoEdgesPainter old) =>
      old.viewport != viewport ||
      old.placed.length != placed.length ||
      !identical(old.placed, placed);
}
