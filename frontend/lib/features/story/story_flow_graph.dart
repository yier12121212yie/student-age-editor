/// ComfyUI 式剧情流程图画布：节点卡片自由拖拽、输出端口连线编辑跳转、平移缩放。
///
/// 实现要点：用 Listener 原始指针事件手写平移/缩放（canvas 坐标 ↔ 屏幕坐标 =
/// pos * scale + pan），避免与 InteractiveViewer 的手势竞技场冲突；节点位置由
/// 外部（workspace）持有并持久化。画布持有交互状态，节点卡片仅作静态渲染。
library;

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import '../../core/app_theme.dart';
import 'story_flow_models.dart';

const double kFlowNodeW = 200;
const double kFlowNodeH = 112;
const double kFlowMissingH = 56;
const double kPortR = 5;

/// 展开态高度（内联参数编辑器；可滚动，超出部分滚动查看）。
const double kFlowTalkExpandedH = 316;
const double kFlowOptionExpandedH = 276;

/// 展开箭头命中区（折叠足迹右下角，屏幕像素随缩放）。
const double kExpandArrowSize = 18;

class StoryFlowGraph extends StatefulWidget {
  const StoryFlowGraph({
    super.key,
    required this.graph,
    required this.positions,
    this.selectedNode,
    this.selectedEdge,
    this.expandedNodes = const {},
    this.highlightNode,
    this.checkInvalidNodes = const {},
    required this.onSelectNode,
    required this.onSelectEdge,
    required this.onSelectNone,
    required this.onMoveNode,
    required this.onAddEdge,
    required this.onDeleteEdge,
    required this.onRequestDelete,
    required this.onToggleExpand,
    required this.fieldController,
    required this.onFieldChanged,
    required this.onDeleteNode,
  });

  final FlowGraph graph;

  /// 节点 id → 画布坐标（workspace 持久化）。
  final Map<String, Offset> positions;
  final String? selectedNode;
  final FlowEdge? selectedEdge;

  /// 展开参数编辑器的节点集合（workspace 持有）。
  final Set<String> expandedNodes;

  /// 资产拖拽悬停高亮的节点。
  final String? highlightNode;

  /// 检定 JSON 解析失败的节点（内联编辑区红字提示）。
  final Set<String> checkInvalidNodes;
  final ValueChanged<String> onSelectNode;
  final ValueChanged<FlowEdge> onSelectEdge;
  final VoidCallback onSelectNone;
  final void Function(String id, Offset pos) onMoveNode;

  /// 建边（field 为 null 表示终端边，拒绝）。
  final void Function(String fromId, String field, String targetId) onAddEdge;
  final void Function(String fromId, String field, String targetId) onDeleteEdge;
  final VoidCallback onRequestDelete;

  /// 右下角箭头切换展开/收起。
  final ValueChanged<String> onToggleExpand;

  /// 内联编辑：字段输入控制器（null=该字段不显示输入框）。
  final TextEditingController? Function(String nodeId, String field)
      fieldController;

  /// 内联编辑：文本变更写回（按字段类型解析）。
  final void Function(String nodeId, String field, String text) onFieldChanged;

  /// 内联编辑：删除该节点。
  final ValueChanged<String> onDeleteNode;

  @override
  State<StoryFlowGraph> createState() => StoryFlowGraphState();
}

class StoryFlowGraphState extends State<StoryFlowGraph> {
  double _scale = 1;
  Offset _pan = Offset.zero;
  final FocusNode _focus = FocusNode(debugLabel: 'storyFlowCanvas');

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

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

  bool _isExpanded(FlowNode n) => widget.expandedNodes.contains(n.id);

  /// 折叠态高度（展开时即「底座」高度，箭头与拖拽命中都锚在这里）。
  double _baseH(FlowNode n) => n.isMissing ? kFlowMissingH : kFlowNodeH;

  /// 当前渲染高度：展开的节点为内联编辑器全高。
  double _nodeH(FlowNode n) {
    if (n.isMissing) return kFlowMissingH;
    if (!_isExpanded(n)) return kFlowNodeH;
    return n.isOption ? kFlowOptionExpandedH : kFlowTalkExpandedH;
  }

  /// 展开编辑区（底座以下的扩展部分）屏幕矩形；未展开返回 null。
  Rect? _editorScreenRect(FlowNode n) {
    if (!_isExpanded(n)) return null;
    final p = _toScreen(widget.positions[n.id] ?? Offset.zero);
    final baseH = _baseH(n) * _scale;
    return Rect.fromLTWH(
        p.dx, p.dy + baseH, kFlowNodeW * _scale, _nodeH(n) * _scale - baseH);
  }

  /// 展开箭头命中区：固定在折叠足迹右下角，展开/收起位置不变。
  Rect _arrowScreenRect(FlowNode n) {
    final p = _toScreen(widget.positions[n.id] ?? Offset.zero);
    final s = kExpandArrowSize * _scale;
    return Rect.fromLTWH(
      p.dx + kFlowNodeW * _scale - s - 2 * _scale,
      p.dy + _baseH(n) * _scale - s - 2 * _scale,
      s,
      s,
    );
  }

  /// 节点屏幕足迹。宽必须同样乘 scale，否则缩放后右侧/底部命中区
  /// 与卡片错位：点不中、选不了，也连带键盘删除失效。
  Rect _nodeScreenRect(FlowNode n) {
    final p = _toScreen(widget.positions[n.id] ?? Offset.zero);
    return Rect.fromLTWH(p.dx, p.dy, kFlowNodeW * _scale, _nodeH(n) * _scale);
  }

  /// 供资产拖放的 DragTarget 命中测试：返回指针下的可放置节点 id。
  String? hitNodeAt(Offset local) {
    for (final n in widget.graph.nodes) {
      if (n.isMissing) continue;
      if (_nodeScreenRect(n).contains(local)) return n.id;
    }
    return null;
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

  /// 输出端口列表（含屏幕坐标与写回字段）。端口位置在画布坐标系算好后
  /// 统一经 _toScreen 缩放平移，与连线绘制端 _outputPort 的公式保持一致，
  /// 缩放非 100% 时命中测试、卡片圆点与绘制位置才不会错开。
  List<_OutPort> _outputPorts(FlowNode n) {
    if (n.isMissing) return const [];
    final out = [
      for (final k in flowPortKinds(n)) _OutPort(_portLabel(k), k),
    ];
    final anchor = _nodeAnchor(n);
    final count = out.length;
    for (var i = 0; i < count; i++) {
      out[i] = out[i].withPos(_toScreen(
        anchor + Offset(kFlowNodeW * (i + 1) / (count + 1), _nodeH(n)),
      ));
    }
    return out;
  }

  // ---------- 指针交互 ----------

  /// 收回画布键盘焦点：真实应用里输入框（AI 侧栏、事件搜索等）常持有
  /// 焦点，点画布不回收的话 Delete/Backspace/Ctrl+= 永远进不了 _onKey。
  /// 仅在画布接管交互时收回，编辑区/输入框路径不调用。
  void _takeCanvasFocus() {
    if (!_focus.hasFocus) _focus.requestFocus();
  }

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
        _takeCanvasFocus();
        setState(() {});
        return;
      }
    }
    // 展开箭头：切换内联参数编辑（不进入拖拽/选中）
    for (final n in widget.graph.nodes) {
      if (n.isMissing) continue;
      if (_arrowScreenRect(n).contains(local)) {
        _takeCanvasFocus();
        widget.onToggleExpand(n.id);
        return;
      }
    }
    // 展开编辑区：让位给内部输入框/滚动，画布手势全部不接管
    for (final n in widget.graph.nodes) {
      final editor = _editorScreenRect(n);
      if (editor != null && editor.contains(local)) {
        _mode = _DragMode.none;
        return;
      }
    }
    for (final n in widget.graph.nodes) {
      if (n.isMissing) continue;
      if (_nodeScreenRect(n).inflate(4).contains(local)) {
        _mode = _DragMode.node;
        _dragNodeId = n.id;
        _dragStartPos = _nodeAnchor(n);
        _takeCanvasFocus();
        if (widget.selectedNode != n.id) widget.onSelectNode(n.id);
        setState(() {});
        return;
      }
    }
    _mode = _DragMode.pan;
    _takeCanvasFocus();
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
    // 指针在展开的参数编辑区：滚轮只归内层滚动视图。Listener 是画布
    // 祖先，信号事件沿命中链直达，不在这里让位就会出现「滚参数把整个
    // 画布一起缩放」的连滚。
    for (final n in widget.graph.nodes) {
      final editor = _editorScreenRect(n);
      if (editor != null && editor.contains(local)) return;
    }
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

  /// 主焦点是否在文本输入控件内：内联编辑时让位给输入框自身按键
  /// （Backspace/Escape 不能触发删节点/取消选中）。
  bool _focusInEditableText() {
    final ctx = FocusManager.instance.primaryFocus?.context;
    if (ctx == null) return false;
    final self = ctx.widget;
    if (self is EditableText || self is TextField) return true;
    var found = false;
    ctx.visitAncestorElements((e) {
      final w = e.widget;
      if (w is EditableText || w is TextField) {
        found = true;
        return false;
      }
      return true;
    });
    return found;
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (_focusInEditableText()) return KeyEventResult.ignored;
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
      focusNode: _focus,
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
                  expandedNodes: widget.expandedNodes,
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
                        highlighted: widget.highlightNode == n.id,
                        expanded: _isExpanded(n),
                        checkInvalid: widget.checkInvalidNodes.contains(n.id),
                        outputPorts: _outputPorts(n),
                        fieldController: widget.fieldController,
                        onFieldChanged: widget.onFieldChanged,
                        onDeleteNode: widget.onDeleteNode,
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
    required this.highlighted,
    required this.expanded,
    required this.checkInvalid,
    required this.outputPorts,
    required this.fieldController,
    required this.onFieldChanged,
    required this.onDeleteNode,
  });

  final FlowNode node;
  final Offset screenPos;
  final double scale;
  final bool selected;
  final bool highlighted;
  final bool expanded;
  final bool checkInvalid;
  final List<_OutPort> outputPorts;
  final TextEditingController? Function(String nodeId, String field)
      fieldController;
  final void Function(String nodeId, String field, String text) onFieldChanged;
  final ValueChanged<String> onDeleteNode;

  double get _baseH => node.isMissing ? kFlowMissingH : kFlowNodeH;

  double get _h {
    if (node.isMissing) return kFlowMissingH;
    if (!expanded) return kFlowNodeH;
    return node.isOption ? kFlowOptionExpandedH : kFlowTalkExpandedH;
  }

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

  Color get _borderColor {
    if (selected) return _tint;
    if (highlighted) return const Color(0xFF27AE60);
    return palette.border;
  }

  @override
  Widget build(BuildContext context) {
    final w = kFlowNodeW * scale;
    final hh = _h * scale;
    final base = _baseH * scale;
    final r = kPortR * scale;
    final dots = <Widget>[
      for (final p in outputPorts)
        Positioned(
          left: (p.pos.dx - screenPos.dx) - r,
          top: hh - r,
          width: r * 2,
          height: r * 2,
          child: _PortDot(label: p.label, color: _portColor(p.kind)),
        ),
    ];
    return Positioned(
      left: screenPos.dx,
      top: screenPos.dy,
      width: w,
      height: hh,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // 底座卡片（折叠区）：拖拽/连线由画布 Listener 统一处理
          Positioned(
            left: 0,
            top: 0,
            width: w,
            height: base,
            child: IgnorePointer(child: _baseCard(base)),
          ),
          // 展开编辑区：指针直达输入框（画布对命中此区的手势让位）
          if (expanded && !node.isMissing)
            Positioned(
              left: 0,
              top: base,
              width: w,
              height: hh - base,
              child: _editorPanel(),
            ),
          ...dots,
          if (!node.isMissing) _arrow(base),
        ],
      ),
    );
  }

  Widget _baseCard(double base) {
    final radius = BorderRadius.vertical(
      top: Radius.circular(6 * scale),
      bottom: expanded ? Radius.zero : Radius.circular(6 * scale),
    );
    final body = node.content;
    return Container(
      decoration: BoxDecoration(
        color: palette.card,
        border: Border.all(color: _borderColor, width: selected ? 1.6 * scale : 1),
        borderRadius: radius,
        boxShadow: selected
            ? [
                BoxShadow(
                    color: _tint.withValues(alpha: 0.22), blurRadius: 10 * scale)
              ]
            : highlighted
                ? [
                    BoxShadow(
                        color: const Color(0xFF27AE60).withValues(alpha: 0.3),
                        blurRadius: 10 * scale)
                  ]
                : null,
      ),
      child: ClipRRect(
        borderRadius: radius,
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
                        : (node.isMissing ? Icons.link_off : Icons.chat),
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
            if (node.hasParamBadges) _badgeRow(),
          ],
        ),
      ),
    );
  }

  /// 底部参数徽章行：对白 bg/audio/time/检定，选项 主支/支线/跳转事件。
  Widget _badgeRow() {
    final chips = <Widget>[
      if (!node.isOption) ...[
        if (node.bgId.isNotEmpty)
          _badge(Icons.landscape, node.bgId, const Color(0xFF3498DB)),
        if (node.audioId.isNotEmpty)
          _badge(Icons.music_note, node.audioId, const Color(0xFF27AE60)),
        if (node.timeStr.isNotEmpty)
          _badge(Icons.schedule, node.timeStr, const Color(0xFF95A5A6)),
        if (node.fxSummary.isNotEmpty)
          _badge(Icons.auto_fix_high, node.fxSummary, const Color(0xFFE91E63)),
        if (node.hasCheck)
          _badge(Icons.fact_check, '检定', const Color(0xFFE67E22)),
      ] else ...[
        if (node.mainCount.isNotEmpty)
          _badge(Icons.call_made, '主${node.mainCount}', const Color(0xFF27AE60)),
        if (node.sideCount.isNotEmpty)
          _badge(Icons.call_split, '支${node.sideCount}', const Color(0xFFE67E22)),
        if (node.nextEvtId.isNotEmpty)
          _badge(Icons.logout, '→${node.nextEvtId}', const Color(0xFF95A5A6)),
      ],
    ];
    return Container(
      height: 16 * scale,
      padding: EdgeInsets.symmetric(horizontal: 6 * scale),
      child: Row(
        children: [
          for (var i = 0; i < chips.length; i++) ...[
            if (i > 0) SizedBox(width: 4 * scale),
            chips[i],
          ],
        ],
      ),
    );
  }

  Widget _badge(IconData icon, String text, Color color) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 4 * scale, vertical: 1 * scale),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(3 * scale),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 8 * scale, color: color),
          SizedBox(width: 2 * scale),
          Text(
            text,
            style: TextStyle(
              fontSize: 8.5 * scale,
              color: color,
              fontWeight: FontWeight.w600,
              height: 1.1,
            ),
          ),
        ],
      ),
    );
  }

  /// 右下角展开箭头（视觉；命中判定在画布 Listener 的 _arrowScreenRect）。
  Widget _arrow(double base) {
    final s = kExpandArrowSize * scale;
    return Positioned(
      right: 2 * scale,
      top: base - s - 2 * scale,
      width: s,
      height: s,
      child: IgnorePointer(
        child: Container(
          decoration: BoxDecoration(
            color: palette.card,
            shape: BoxShape.circle,
            border: Border.all(color: palette.borderHover),
          ),
          child: Icon(
            expanded ? Icons.expand_less : Icons.expand_more,
            size: 13 * scale,
            color: palette.textSecondary,
          ),
        ),
      ),
    );
  }

  /// 内联参数编辑器（展开区）：TextBox 直连 workspace 的字段控制器。
  Widget _editorPanel() {
    final radius =
        BorderRadius.vertical(bottom: Radius.circular(6 * scale));
    final fields = node.isOption
        ? <Widget>[
            _fieldRow('选项内容 content', 'content', maxLines: 2),
            _fieldRow('主支对白 talkId', 'talkId'),
            _fieldRow('支线对白 talkId2', 'talkId2'),
            _fieldRow('跳转事件 nextEvtId', 'nextEvtId'),
          ]
        : <Widget>[
            _fieldRow('说话人 roleName', 'roleName'),
            _fieldRow('台词 content', 'content', maxLines: 3),
            _fieldRow('检定 check（JSON 数组）', 'check', maxLines: 2),
            _fieldRow('屏幕效果 screenEffect（如 [4015, CGid]）', 'screenEffect',
                maxLines: 2),
            Row(children: [
              Expanded(child: _fieldRow('背景', 'bg')),
              SizedBox(width: 4 * scale),
              Expanded(child: _fieldRow('音频', 'audio')),
              SizedBox(width: 4 * scale),
              Expanded(child: _fieldRow('时间', 'time')),
            ]),
          ];
    return Container(
      decoration: BoxDecoration(
        color: palette.card,
        border: Border.all(
            color: _borderColor, width: selected ? 1.6 * scale : 1),
        borderRadius: radius,
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              height: 20 * scale,
              padding: EdgeInsets.symmetric(horizontal: 7 * scale),
              color: _tint.withValues(alpha: 0.08),
              child: Row(
                children: [
                  Icon(Icons.tune, size: 10 * scale, color: _tint),
                  SizedBox(width: 4 * scale),
                  Text('参数',
                      style: TextStyle(
                          fontSize: 9.5 * scale,
                          fontWeight: FontWeight.w600,
                          color: palette.textSecondary)),
                  const Spacer(),
                  Tooltip(
                    message: '删除该节点（或选中后按 Delete）',
                    child: MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => onDeleteNode(node.id),
                        child: Padding(
                          padding: EdgeInsets.symmetric(
                              horizontal: 5 * scale, vertical: 3 * scale),
                          child: Row(children: [
                            Icon(Icons.delete_outline,
                                size: 11 * scale,
                                color: const Color(0xFFE74C3C)),
                            SizedBox(width: 2 * scale),
                            Text('删除',
                                style: TextStyle(
                                    fontSize: 9.5 * scale,
                                    color: const Color(0xFFE74C3C))),
                          ]),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: EdgeInsets.all(7 * scale),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: fields,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _fieldRow(String label, String field, {int maxLines = 1}) {
    final ctl = fieldController(node.id, field);
    if (ctl == null) return const SizedBox.shrink();
    return Padding(
      padding: EdgeInsets.only(bottom: 6 * scale),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(label,
              style: TextStyle(
                  fontSize: 9 * scale, color: palette.textSecondary)),
          SizedBox(height: 2 * scale),
          fluent.TextBox(
            controller: ctl,
            maxLines: maxLines,
            minLines: 1,
            style: TextStyle(fontSize: 10 * scale),
            padding: EdgeInsets.symmetric(
                horizontal: 6 * scale, vertical: 3 * scale),
            onChanged: (v) => onFieldChanged(node.id, field, v),
          ),
          if ((field == 'check' || field == 'screenEffect') && checkInvalid)
            Padding(
              padding: EdgeInsets.only(top: 2 * scale),
              child: Text('JSON 解析失败，未生效',
                  style: TextStyle(
                      fontSize: 9 * scale,
                      color: const Color(0xFFE74C3C))),
            ),
        ],
      ),
    );
  }
}

/// 端口标签：与 flowPortKinds 的端口类型一一对应。
String _portLabel(FlowEdgeKind kind) {
  switch (kind) {
    case FlowEdgeKind.next:
      return '下一句';
    case FlowEdgeKind.checkPass:
      return '检定成功';
    case FlowEdgeKind.checkFail:
      return '检定失败';
    case FlowEdgeKind.option:
      return '选项';
    case FlowEdgeKind.optionMain:
      return '主支';
    case FlowEdgeKind.optionSide:
      return '支线';
    case FlowEdgeKind.nextEvt:
      return '跳转事件';
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
    required this.expandedNodes,
    required this.selection,
    this.wire,
  });

  final FlowGraph graph;
  final Map<String, Offset> positions;
  final double scale;
  final Offset pan;
  final double Function(FlowNode) nodeH;

  /// 展开节点集合：展开高度影响端口锚点，集合变化时需重绘连线。
  final Set<String> expandedNodes;
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
    final kinds = flowPortKinds(from);
    final n = kinds.length;
    var idx = kinds.indexOf(e.kind);
    if (idx < 0) idx = n > 0 ? n - 1 : 0;
    return _s(p + Offset(kFlowNodeW * (idx + 1) / (n + 1), nodeH(from)));
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
      !setEquals(old.expandedNodes, expandedNodes) ||
      old.selection != selection ||
      old.scale != scale ||
      old.pan != pan ||
      old.wire != wire;
}