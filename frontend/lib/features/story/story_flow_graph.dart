/// ComfyUI 式剧情流程图画布：节点卡片自由拖拽、输出端口连线编辑跳转、平移缩放。
///
/// 实现要点：用 Listener 原始指针事件手写平移/缩放（canvas 坐标 ↔ 屏幕坐标 =
/// pos * scale + pan），避免与 InteractiveViewer 的手势竞技场冲突；节点位置由
/// 外部（workspace）持有并持久化。画布持有交互状态，节点卡片仅作静态渲染。
library;

import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/app_theme.dart';
import 'story_flow_models.dart';

const double kFlowNodeW = 200;
const double kFlowNodeH = 112;
const double kFlowMissingH = 56;
const double kPortR = 5;

class StoryFlowGraph extends StatefulWidget {
  const StoryFlowGraph({
    super.key,
    required this.graph,
    required this.positions,
    this.selectedNode,
    this.selectedEdge,
    required this.onSelectNode,
    required this.onSelectEdge,
    required this.onSelectNone,
    required this.onMoveNode,
    required this.onAddEdge,
    required this.onDeleteEdge,
    required this.onRequestDelete,
  });

  final FlowGraph graph;

  /// 节点 id → 画布坐标（workspace 持久化）。
  final Map<String, Offset> positions;
  final String? selectedNode;
  final FlowEdge? selectedEdge;
  final ValueChanged<String> onSelectNode;
  final ValueChanged<FlowEdge> onSelectEdge;
  final VoidCallback onSelectNone;
  final void Function(String id, Offset pos) onMoveNode;

  /// 建边（field 为 null 表示终端边，拒绝）。
  final void Function(String fromId, String field, String targetId) onAddEdge;
  final void Function(String fromId, String field, String targetId) onDeleteEdge;
  final VoidCallback onRequestDelete;

  @override
  State<StoryFlowGraph> createState() => StoryFlowGraphState();
}

class StoryFlowGraphState extends State<StoryFlowGraph> {
  double _scale = 1;
  Offset _pan = Offset.zero;

  _DragMode _mode = _DragMode.none;
  String? _dragNodeId;
  Offset _dragStartLocal = Offset.zero;
  Offset _dragStartPos = Offset.zero;
  Offset _dragStartPan = Offset.zero;
  String? _wireFrom;
  String? _wireField;
  Offset _wireToLocal = Offset.zero;
  Size _viewSize = Size.zero;

  // ---------- 坐标换算 ----------
  Offset _toScreen(Offset canvas) => canvas * _scale + _pan;
  Offset _toCanvas(Offset screen) => (screen - _pan) / _scale;
  double _nodeH(FlowNode n) => n.isMissing ? kFlowMissingH : kFlowNodeH;

  Rect _nodeScreenRect(FlowNode n) {
    final p = _toScreen(widget.positions[n.id] ?? Offset.zero);
    return Rect.fromLTWH(p.dx, p.dy, kFlowNodeW, _nodeH(n) * _scale);
  }

  Offset _nodeAnchor(FlowNode n) {
    return (widget.positions[n.id] ?? Offset.zero);
  }

  /// 输入端口屏幕坐标：对白/选项=顶部中心，缺失节点=左侧边中点（终端接入点）。
  Offset _inputPortScreen(FlowNode n) {
    final p = _nodeAnchor(n);
    if (n.isMissing) {
      return _toScreen(p + Offset(0, _nodeH(n) / 2));
    }
    return _toScreen(p + Offset(kFlowNodeW / 2, 0));
  }

  /// 输出端口列表（含屏幕坐标与写回字段）。
  List<_OutPort> _outputPorts(FlowNode n) {
    final out = <_OutPort>[];
    if (n.isMissing) return out;
    final edges = widget.graph.edgesFrom(n.id);
    if (n.isOption) {
      out.add(_OutPort('主支', FlowEdgeKind.optionMain));
      out.add(_OutPort('支线', FlowEdgeKind.optionSide));
    } else {
      final dual = edges.any((e) => e.kind == FlowEdgeKind.checkFail);
      out.add(_OutPort(
          dual ? '检定成功' : '下一句',
          dual ? FlowEdgeKind.checkPass : FlowEdgeKind.next));
      if (dual) out.add(_OutPort('检定失败', FlowEdgeKind.checkFail));
      if (edges.any((e) => e.kind == FlowEdgeKind.option)) {
        out.add(_OutPort('选项', FlowEdgeKind.option));
      }
    }
    final base = _toScreen(_nodeAnchor(n));
    final h = _nodeH(n) * _scale;
    final count = out.length;
    for (var i = 0; i < count; i++) {
      out[i] = out[i].withPos(
          base + Offset(kFlowNodeW * (i + 1) / (count + 1), h));
    }
    return out;
  }

  // ---------- 指针交互 ----------
  void _onPointerDown(PointerDownEvent e) {
    final local = e.localPosition;
    _dragStartLocal = local;
    _dragStartPan = _pan;

    for (final n in widget.graph.nodes) {
      final field = _fieldOfPort(n, local);
      if (field != null) {
        _mode = _DragMode.wire;
        _wireFrom = n.id;
        _wireField = field;
        _wireToLocal = local;
        setState(() {});
        return;
      }
    }
    for (final n in widget.graph.nodes) {
      if (n.isMissing) continue;
      if (_nodeScreenRect(n).inflate(4).contains(local)) {
        _mode = _DragMode.node;
        _dragNodeId = n.id;
        _dragStartPos = _nodeAnchor(n);
        if (widget.selectedNode != n.id) widget.onSelectNode(n.id);
        setState(() {});
        return;
      }
    }
    _mode = _DragMode.pan;
  }

  String? _fieldOfPort(FlowNode n, Offset local) {
    for (final p in _outputPorts(n)) {
      if ((local - p.pos).distance <= kPortR + 6) return fieldForEdge(p.kind);
    }
    return null;
  }

  void _onPointerMove(PointerMoveEvent e) {
    final local = e.localPosition;
    switch (_mode) {
      case _DragMode.node:
        final delta = (local - _dragStartLocal) / _scale;
        widget.onMoveNode(_dragNodeId!, _dragStartPos + delta);
      case _DragMode.wire:
        setState(() => _wireToLocal = local);
      case _DragMode.pan:
        setState(() => _pan = _dragStartPan + (local - _dragStartLocal));
      case _DragMode.none:
        break;
    }
  }

  void _onPointerUp(PointerUpEvent e) {
    final local = e.localPosition;
    final mode = _mode;
    _mode = _DragMode.none;
    switch (mode) {
      case _DragMode.wire:
        final fromId = _wireFrom!;
        final field = _wireField!;
        _wireFrom = null;
        _wireField = null;
        final target = _hitInputPort(local);
        if (target != null && target != fromId) {
          widget.onAddEdge(fromId, field, target);
        }
        setState(() {});
      case _DragMode.node:
        _dragNodeId = null;
        setState(() {});
      case _DragMode.pan:
        if ((local - _dragStartLocal).distance < 4) {
          final hit = _hitEdge(local);
          if (hit != null) {
            widget.onSelectEdge(hit);
          } else {
            widget.onSelectNone();
          }
        }
      case _DragMode.none:
        break;
    }
  }

  String? _hitInputPort(Offset local) {
    String? best;
    var bestD = double.infinity;
    for (final n in widget.graph.nodes) {
      if (n.isMissing) continue;
      final d = (local - _inputPortScreen(n)).distance;
      if (d < bestD && d <= kPortR + 10) {
        bestD = d;
        best = n.id;
      }
    }
    return best;
  }

  FlowEdge? _hitEdge(Offset local) {
    FlowEdge? best;
    var bestD = double.infinity;
    for (final e in widget.graph.edges) {
      final from = widget.graph.nodeById(e.from);
      final to = widget.graph.nodeById(e.to);
      if (from == null || to == null) continue;
      final d = _distToBezier(local, _edgeFromScreen(from, e), _edgeToScreen(to));
      if (d < bestD && d <= 8) {
        bestD = d;
        best = e;
      }
    }
    return best;
  }

  Offset _edgeFromScreen(FlowNode from, FlowEdge e) {
    if (from.isMissing) {
      return _inputPortScreen(from);
    }
    for (final p in _outputPorts(from)) {
      if (p.kind == e.kind) return p.pos;
    }
    return _toScreen(_nodeAnchor(from) +
        Offset(kFlowNodeW / 2, _nodeH(from)));
  }

  Offset _edgeToScreen(FlowNode to) => _inputPortScreen(to);

  double _distToBezier(Offset p, Offset s, Offset t) {
    final dx = ((t.dx - s.dx).abs()).clamp(40.0, 200.0);
    final c1 = s + Offset(dx, 0);
    final c2 = t + Offset(-dx, 0);
    var best = double.infinity;
    var prev = s;
    for (var i = 1; i <= 20; i++) {
      final u = i / 20;
      final v = 1 - u;
      final q = Offset(
          v * v * v * s.dx + 3 * v * v * u * c1.dx + 3 * v * u * u * c2.dx +
              u * u * u * t.dx,
          v * v * v * s.dy + 3 * v * v * u * c1.dy + 3 * v * u * u * c2.dy +
              u * u * u * t.dy);
      final d = _segDist(p, prev, q);
      if (d < best) best = d;
      prev = q;
    }
    return best;
  }

  double _segDist(Offset p, Offset a, Offset b) {
    final ab = b - a;
    final len2 = ab.dx * ab.dx + ab.dy * ab.dy;
    if (len2 == 0) return (p - a).distance;
    var t = ((p - a).dx * ab.dx + (p - a).dy * ab.dy) / len2;
    t = t.clamp(0.0, 1.0);
    return (p - (a + ab * t)).distance;
  }

  void _onPointerSignal(PointerSignalEvent e) {
    if (e is! PointerScrollEvent) return;
    final local = e.localPosition;
    final factor = e.scrollDelta.dy > 0 ? 0.9 : 1.1;
    final next = (_scale * factor).clamp(0.2, 2.5).toDouble();
    final canvasAt = _toCanvas(local);
    setState(() {
      _scale = next;
      _pan = local - canvasAt * next;
    });
  }

  /// 适配视图：计算全部节点包围盒并缩放平移居中。
  void fitView() {
    if (widget.graph.nodes.isEmpty || _viewSize.isEmpty) return;
    var minX = double.infinity, minY = double.infinity;
    var maxX = -double.infinity, maxY = -double.infinity;
    for (final n in widget.graph.nodes) {
      final p = _nodeAnchor(n);
      final r = Rect.fromLTWH(p.dx, p.dy, kFlowNodeW, _nodeH(n));
      minX = math.min(minX, r.left);
      minY = math.min(minY, r.top);
      maxX = math.max(maxX, r.right);
      maxY = math.max(maxY, r.bottom);
    }
    final box = Rect.fromLTRB(minX, minY, maxX, maxY);
    const pad = 40.0;
    final sx = ((_viewSize.width - pad * 2) / box.width).clamp(0.2, 2.5);
    final sy = ((_viewSize.height - pad * 2) / box.height).clamp(0.2, 2.5);
    final scale = math.min(sx, sy);
    final cx = (minX + box.width / 2) * scale;
    final cy = (minY + box.height / 2) * scale;
    setState(() {
      _scale = scale;
      _pan = Offset(_viewSize.width / 2 - cx, _viewSize.height / 2 - cy);
    });
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.delete ||
        key == LogicalKeyboardKey.backspace) {
      if (widget.selectedNode != null || widget.selectedEdge != null) {
        widget.onRequestDelete();
        return KeyEventResult.handled;
      }
    }
    if (key == LogicalKeyboardKey.escape) {
      if (widget.selectedNode != null || widget.selectedEdge != null) {
        widget.onSelectNone();
        return KeyEventResult.handled;
      }
    }
    if (key == LogicalKeyboardKey.equal &&
        HardwareKeyboard.instance.isControlPressed) {
      fitView();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  String? _selectionKey(FlowEdge? e) =>
      e == null ? null : '${e.from}>${e.to}:${e.kind.index}';

  @override
  Widget build(BuildContext context) {
    return Focus(
      autofocus: true,
      onKeyEvent: _onKey,
      child: LayoutBuilder(
        builder: (context, box) {
          _viewSize = box.biggest;
          return Listener(
            onPointerDown: _onPointerDown,
            onPointerMove: _onPointerMove,
            onPointerUp: _onPointerUp,
            onPointerSignal: _onPointerSignal,
            child: ClipRect(
              child: CustomPaint(
                painter: _FlowEdgesPainter(
                  graph: widget.graph,
                  positions: widget.positions,
                  scale: _scale,
                  pan: _pan,
                  nodeH: _nodeH,
                  selection: _selectionKey(widget.selectedEdge),
                  wire: _mode == _DragMode.wire && _wireFrom != null
                      ? (_wireFrom!, _wireToLocal)
                      : null,
                ),
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    for (final n in widget.graph.nodes)
                      _FlowNodeCard(
                        node: n,
                        screenPos: _toScreen(_nodeAnchor(n)),
                        scale: _scale,
                        selected: widget.selectedNode == n.id,
                        outputPorts: _outputPorts(n),
                      ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

enum _DragMode { none, node, wire, pan }

class _OutPort {
  _OutPort(this.label, this.kind) : pos = Offset.zero;
  final String label;
  final FlowEdgeKind kind;
  Offset pos;
  _OutPort withPos(Offset p) {
    final out = _OutPort(label, kind);
    out.pos = p;
    return out;
  }
}

class _FlowNodeCard extends StatelessWidget {
  const _FlowNodeCard({
    required this.node,
    required this.screenPos,
    required this.scale,
    required this.selected,
    required this.outputPorts,
  });

  final FlowNode node;
  final Offset screenPos;
  final double scale;
  final bool selected;
  final List<_OutPort> outputPorts;

  Color get _tint {
    if (node.cardColor.isNotEmpty) {
      final hex = int.tryParse(node.cardColor.replaceFirst('#', ''), radix: 16);
      if (hex != null) return Color(0xFF000000 | hex);
    }
    if (node.isMissing) return const Color(0xFFE74C3C);
    if (node.isOption) return const Color(0xFF6C5CE7);
    if (node.hasCheck) return const Color(0xFFE67E22);
    if (node.isNarrator) return const Color(0xFF95A5A6);
    return const Color(0xFF3498DB);
  }

  @override
  Widget build(BuildContext context) {
    final w = kFlowNodeW * scale;
    final h = (node.isMissing ? kFlowMissingH : kFlowNodeH) * scale;
    final r = kPortR * scale;
    final dots = <Widget>[
      for (final p in outputPorts)
        Positioned(
          left: (p.pos.dx - screenPos.dx) - r,
          top: h - r,
          width: r * 2,
          height: r * 2,
          child: _PortDot(label: p.label, color: _portColor(p.kind)),
        ),
    ];
    final body = node.content;
    return Positioned(
      left: screenPos.dx,
      top: screenPos.dy,
      width: w,
      height: h,
      child: IgnorePointer(
        // 指针事件由画布 Listener 统一处理（拖拽/连线/平移）
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(6 * scale),
              child: Container(
                decoration: BoxDecoration(
                  color: palette.card,
                  border: Border.all(
                    color: selected ? _tint : palette.border,
                    width: selected ? 1.6 * scale : 1,
                  ),
                  boxShadow: selected
                      ? [
                          BoxShadow(
                              color: _tint.withValues(alpha: 0.22),
                              blurRadius: 10 * scale)
                        ]
                      : null,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Container(
                      height: 26 * scale,
                      color: _tint.withValues(alpha: 0.16),
                      padding: EdgeInsets.symmetric(horizontal: 8 * scale),
                      child: Row(
                        children: [
                          Icon(
                            node.isOption
                                ? Icons.alt_route
                                : (node.isMissing
                                    ? Icons.link_off
                                    : Icons.chat),
                            size: 12 * scale,
                            color: _tint,
                          ),
                          SizedBox(width: 5 * scale),
                          Expanded(
                            child: Text(
                              node.cardLabel.isNotEmpty
                                  ? '${node.title} · ${node.cardLabel}'
                                  : node.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 11 * scale,
                                fontWeight: FontWeight.w600,
                                color: palette.textHigh,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (!node.isMissing) ...[
                      Expanded(
                        child: Padding(
                          padding: EdgeInsets.all(7 * scale),
                          child: RichText(
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            text: TextSpan(
                              text: body.isEmpty ? '(空台词)' : body,
                              style: TextStyle(
                                fontSize: 10.5 * scale,
                                color: body.isEmpty
                                    ? palette.textHint
                                    : palette.textSecondary,
                                height: 1.3,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            ...dots,
          ],
        ),
      ),
    );
  }
}

Color _portColor(FlowEdgeKind kind) {
  switch (kind) {
    case FlowEdgeKind.next:
    case FlowEdgeKind.checkPass:
      return const Color(0xFF27AE60);
    case FlowEdgeKind.checkFail:
      return const Color(0xFFE67E22);
    case FlowEdgeKind.option:
    case FlowEdgeKind.optionMain:
    case FlowEdgeKind.optionSide:
      return const Color(0xFF6C5CE7);
    case FlowEdgeKind.nextEvt:
      return const Color(0xFF95A5A6);
  }
}

class _PortDot extends StatelessWidget {
  const _PortDot({required this.label, required this.color});
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: label,
      waitDuration: const Duration(milliseconds: 400),
      child: Container(
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(color: palette.card, width: 1),
        ),
      ),
    );
  }
}

class _FlowEdgesPainter extends CustomPainter {
  _FlowEdgesPainter({
    required this.graph,
    required this.positions,
    required this.scale,
    required this.pan,
    required this.nodeH,
    required this.selection,
    this.wire,
  });

  final FlowGraph graph;
  final Map<String, Offset> positions;
  final double scale;
  final Offset pan;
  final double Function(FlowNode) nodeH;
  final String? selection;
  final (String, Offset)? wire;

  Offset _s(Offset canvas) => canvas * scale + pan;

  Offset _nodeAnchor(FlowNode n) => positions[n.id] ?? Offset.zero;

  Offset _inputPort(FlowNode to) {
    final p = _nodeAnchor(to);
    return _s(to.isMissing
        ? p + Offset(0, nodeH(to) / 2)
        : p + Offset(kFlowNodeW / 2, 0));
  }

  Offset _outputPort(FlowNode from, FlowEdge e) {
    final p = _nodeAnchor(from);
    if (from.isMissing) return _inputPort(from);
    final kinds = _portKinds(from);
    final n = kinds.length;
    var idx = kinds.indexOf(e.kind);
    if (idx < 0) idx = n > 0 ? n - 1 : 0;
    return _s(p + Offset(kFlowNodeW * (idx + 1) / (n + 1), nodeH(from)));
  }

  List<FlowEdgeKind> _portKinds(FlowNode n) {
    final edges = graph.edgesFrom(n.id);
    if (n.isOption) {
      return const [FlowEdgeKind.optionMain, FlowEdgeKind.optionSide];
    }
    final dual = edges.any((e) => e.kind == FlowEdgeKind.checkFail);
    final out = <FlowEdgeKind>[
      dual ? FlowEdgeKind.checkPass : FlowEdgeKind.next
    ];
    if (dual) out.add(FlowEdgeKind.checkFail);
    if (edges.any((e) => e.kind == FlowEdgeKind.option)) {
      out.add(FlowEdgeKind.option);
    }
    return out;
  }

  @override
  void paint(Canvas canvas, Size size) {
    for (final e in graph.edges) {
      final from = graph.nodeById(e.from);
      final to = graph.nodeById(e.to);
      if (from == null || to == null) continue;
      final s = _outputPort(from, e);
      final t = _inputPort(to);
      final highlight = selection == '${e.from}>${e.to}:${e.kind.index}';
      final dashed = e.kind == FlowEdgeKind.nextEvt || to.isMissing;
      _paintEdge(canvas, s, t, _portColor(e.kind),
          selected: highlight, dashed: dashed);
    }
    final w = wire;
    if (w != null) {
      final from = graph.nodeById(w.$1);
      if (from != null) {
        final s = _outputPort(from,
            FlowEdge(from: w.$1, to: '', kind: _wireKind(from)));
        _paintEdge(canvas, s, w.$2, const Color(0xFF6C5CE7),
            selected: false, dashed: false);
      }
    }
  }

  FlowEdgeKind _wireKind(FlowNode n) =>
      n.isOption ? FlowEdgeKind.optionMain : FlowEdgeKind.next;

  void _paintEdge(Canvas canvas, Offset s, Offset t, Color color,
      {required bool selected, required bool dashed}) {
    final dx = ((t.dx - s.dx).abs()).clamp(40.0, 200.0);
    final path = Path()
      ..moveTo(s.dx, s.dy)
      ..cubicTo(s.dx + dx, s.dy, t.dx - dx, t.dy, t.dx, t.dy);
    if (dashed) {
      canvas.drawPath(
          _dashPath(path, 6, 5),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = (selected ? 2.2 : 1.2) * scale
            ..color = selected ? color : color.withValues(alpha: 0.45));
      return;
    }
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = (selected ? 2.4 : 1.4) * scale
      ..color = selected ? color : color.withValues(alpha: 0.6);
    canvas.drawPath(path, paint);
    final ang = (t - s).direction;
    final arrow = Path()
      ..moveTo(t.dx, t.dy)
      ..lineTo(t.dx - 9 * scale * math.cos(ang - 0.45),
          t.dy - 9 * scale * math.sin(ang - 0.45))
      ..moveTo(t.dx, t.dy)
      ..lineTo(t.dx - 9 * scale * math.cos(ang + 0.45),
          t.dy - 9 * scale * math.sin(ang + 0.45));
    canvas.drawPath(arrow,
        paint..strokeWidth = (selected ? 2.0 : 1.2) * scale);
  }

  /// 路径虚线化（dart:ui 无公开 PathEffect，用 computeMetrics 分段）。
  Path _dashPath(Path path, double dash, double gap) {
    final out = Path();
    final metrics = path.computeMetrics();
    for (final m in metrics) {
      var start = 0.0;
      final len = m.length;
      var on = true;
      while (start < len) {
        final seg = on ? dash : gap;
        final end = math.min(start + seg, len);
        out.addPath(m.extractPath(start, end), Offset.zero);
        start = end;
        on = !on;
      }
    }
    return out;
  }

  @override
  bool shouldRepaint(covariant _FlowEdgesPainter old) =>
      old.graph != graph ||
      old.positions != positions ||
      old.selection != selection ||
      old.scale != scale ||
      old.pan != pan ||
      old.wire != wire;
}