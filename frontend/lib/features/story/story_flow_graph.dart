/// ComfyUI 式剧情流程图画布：节点卡片自由拖拽、输出端口连线编辑跳转、平移缩放。
///
/// 实现要点：
/// - 用 Listener 原始指针事件手写平移/缩放，避免与 InteractiveViewer 的手势
///   竞技场冲突；节点位置由外部（workspace）持有并持久化。
/// - 世界坐标 = 卡片布局坐标，屏幕位置只由一个 FlowViewport(scale, pan) 经外层
///   Transform 施加（screen = pan + scale·world）。Listener 在 Transform 之外，
///   所以指针一律先 _toCanvas 换算再命中。
/// - 平移/缩放只换视口对象：卡片子树按 LOD 档缓存复用，加视口裁剪，
///   一帧不重建任何卡片；连线由 CustomPaint 在同一变换下画世界坐标。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;

import '../../core/app_theme.dart';
import '../../core/history_client.dart';
import 'story_flow_models.dart';
import 'story_flow_snap.dart';
import 'tombstone_node_widget.dart';

const double kFlowNodeW = 200;
const double kFlowNodeH = 112;
const double kFlowMissingH = 56;
const double kPortR = 5;

/// 卡片标题条（说话人输入行）高度。
const double kFlowHeaderH = 30;

/// 标题条左侧拖拽把手宽度：这块归画布的节点拖拽命中，其余标题区让给
/// 说话人输入框（见 StoryFlowGraphState._titleFieldWorldRect）。
const double kFlowGripW = 18;

/// 卡片正文（对白/选项文本）输入区的四周内边距。
const double kFlowBodyPad = 6;

/// 画布视口：世界 → 屏幕 = pan + scale·world。
///
/// [matrix] 与命中测试用的 _toCanvas 必须互逆，否则缩放时连线与卡片会错位。
/// 平移/缩放只换这个对象，卡片子树原样复用（RenderTransform 只 markNeedsPaint）。
@immutable
class FlowViewport {
  const FlowViewport(this.scale, this.pan);

  final double scale;
  final Offset pan;

  static const double minScale = 0.2;
  static const double maxScale = 2.5;

  Matrix4 get matrix =>
      Matrix4.translationValues(pan.dx, pan.dy, 0)
        ..multiply(Matrix4.diagonal3Values(scale, scale, 1));

  Offset toWorld(Offset screen) => (screen - pan) / scale;

  /// [toWorld] 的逆变换：给「画在变换之外」的屏幕层（框选橡皮筋）用。
  Offset toScreen(Offset world) => world * scale + pan;

  /// 当前可见的世界矩形（未加裁剪留白）。
  Rect worldRect(Size view) => Rect.fromLTWH(
    -pan.dx / scale,
    -pan.dy / scale,
    view.width / scale,
    view.height / scale,
  );

  FlowViewport withZoom(double nextScale, Offset anchorScreen) =>
      FlowViewport(nextScale, anchorScreen - toWorld(anchorScreen) * nextScale);

  @override
  bool operator ==(Object other) =>
      other is FlowViewport && other.scale == scale && other.pan == pan;

  @override
  int get hashCode => Object.hash(scale, pan);
}

/// LOD 阈值：**升档**用 0.45 / 0.60，**降档**用 0.43 / 0.58（迟滞带）。
/// 没有迟滞时，缩放停在临界值会让整批卡片每帧在两档间反复重建。
const double kLodTitleUp = 0.45, kLodTitleDown = 0.43;
const double kLodFullUp = 0.60, kLodFullDown = 0.58;

/// LOD 档位：2=完整卡片，1=仅标题条，0=无 Widget（由连线 painter 画色块）。
const int kLodBlocks = 0, kLodTitle = 1, kLodFull = 2;

/// 基准探针：连线 painter 的 paint 次数（每次是一整批边的全量重绘）。
@visibleForTesting
int debugEdgePaintCount = 0;

/// S0 护栏新增：性能计数器
/// - debugBuildSlotsCalls: _buildSlots 调用次数（应随宿主重建频率）
/// - debugSlotCardsBuilt: 每次 _buildSlots 构建的卡片数量。
///   兼作原 debugNodeCardBuilds 的替代探针：卡片实例按 [_contentSig]
///   缓存、identical 复用，「新建卡片实例」与「卡片进 build」一一对应，
///   纯平移/缩放/拖拽一帧应为 **0**。
/// - debugLayoutSnapshots: 布局快照写入次数
/// - debugWorkspaceBuilds: workspace setState({}) 触发次数（拖拽期间应为 0）
/// - debugFlowFieldMetasBuilds: inlineMetas 重算次数
/// - debugSuggestClosuresBuilt: suggest 闭包构建次数
/// - debugEchoQueries: echo 查询次数
@visibleForTesting
int debugBuildSlotsCalls = 0;

@visibleForTesting
int debugSlotCardsBuilt = 0;

@visibleForTesting
int debugLayoutSnapshots = 0;

@visibleForTesting
int debugWorkspaceBuilds = 0;

@visibleForTesting
int debugFlowFieldMetasBuilds = 0;

@visibleForTesting
int debugSuggestClosuresBuilt = 0;

@visibleForTesting
int debugEchoQueries = 0;

/// C4 准出探针：虚线缓存整体作废次数（[_dashCacheFor] 里 rev 变化触发清空）。
/// 首次初始化不计。拖拽帧必须为 0 —— positionsVersion 已从 _geometryRev
/// 移除，端点位移由每条边的 4px 量化缓存键逐条消化，不再整批清空。
@visibleForTesting
int debugDashCacheClears = 0;

// 卡片编辑通道的默认值。函数型属性的默认值必须是编译期常量，所以只能是
// 这样一组顶层函数：宿主不接就等于「无说话人控制器、提交无操作、无
// Inspector」，画布自身仍然完整可用。
TextEditingController? _noSpeakerCtl(String _) => null;
void _noSpeakerSubmit(String _, String _) {}
VoidCallback? _noInspector(String _) => null;

class StoryFlowGraph extends StatefulWidget {
  const StoryFlowGraph({
    super.key,
    required this.graph,
    required this.positions,
    this.selection = FlowSelection.none,
    this.highlightNode,
    this.tombstones,
    this.speakerController = _noSpeakerCtl,
    this.onSpeakerSubmitted = _noSpeakerSubmit,
    this.onNodeFocused,
    this.onRequestInspector = _noInspector,
    required this.onSelectionChanged,
    required this.onMoveNode,
    required this.onAddEdge,
    required this.onDeleteEdge,
    required this.onRequestDelete,
    required this.fieldController,
    required this.onFieldChanged,
    this.onDeleteNode,
    this.onContextMenu,
    this.onUndo,
    this.onRedo,
    this.onCopy,
    this.onPaste,
    this.positionsVersion = 0,
  });

  final FlowGraph graph;

  /// 节点 id → 画布坐标（workspace 持久化）。
  ///
  /// 宿主**原地**改这个 Map（拖拽时 `_positions[id] = pos`），实例身份永不变，
  /// 因此 [positionsVersion] 必须随之递增：`shouldRepaint` 比不出 positions。
  final Map<String, Offset> positions;

  /// [positions] 的修改次数。宿主缓存 graph 后，这是连线重绘的唯一位置信号。
  final int positionsVersion;

  /// 选中集（节点 id + 边）。状态由宿主持有，画布只算出「下一次选什么」。
  final FlowSelection selection;

  /// 资产拖拽悬停高亮的节点。
  final String? highlightNode;

  /// P8 墓碑集合（阶段 4a）：story 级共享、随 story 数据单次拉取，
  /// talk/option 卡片**同步**读 [TombstoneStore.contains] 判墓碑渲染。
  /// 旧实现每卡片 `FutureBuilder(future: isDeleted(id))` 各发一次
  /// GET /api/cfg/deleted_talks，几十个节点=几十次 HTTP。
  /// null = 宿主未接墓碑，talk/option 一律按普通卡片渲染。
  final TombstoneStore? tombstones;

  /// 说话人标题输入：nodeId → 控制器（展示名；null=该节点无记录/不可编辑）。
  /// 提交（回车/失焦）后由宿主演绎「名称/ID → 人物 id」并回写卡片文本。
  final TextEditingController? Function(String nodeId) speakerController;

  /// 提交说话人输入（回车/失焦）：匹配成功写 roleIds，失败弹窗列相近人物。
  final void Function(String nodeId, String text) onSpeakerSubmitted;

  /// 卡片输入区获得焦点：宿主据此选中节点（输入区已让位，指针按下不再选中）。
  final ValueChanged<String>? onNodeFocused;

  /// 请求打开该节点的完整参数 Inspector（双击卡片）。
  final VoidCallback? Function(String nodeId) onRequestInspector;

  /// 无代码模式（后端共享开关）：开启后内联区不再铺任何可输入的代码/ID 框 ——
  /// 码字段铺内联积木编辑器，引用字段只显示现值 + 去 Inspector 选择的入口。
  final void Function(FlowSelection next) onSelectionChanged;
  final void Function(String id, Offset pos) onMoveNode;

  /// 建边（field 为 null 表示终端边，拒绝）。
  final void Function(String fromId, String field, String targetId) onAddEdge;
  final void Function(String fromId, String field, String targetId)
  onDeleteEdge;
  final VoidCallback onRequestDelete;

  /// 卡片正文输入控制器（null=该字段不显示输入框，退化为只读文本）。
  final TextEditingController? Function(String nodeId, String field)
  fieldController;

  /// 卡片正文文本变更写回（按字段类型解析）。
  final void Function(String nodeId, String field, String text) onFieldChanged;

  /// 删除该节点（宿主程序化删除；卡片内不再有删除按钮）。
  final ValueChanged<String>? onDeleteNode;

  /// 右键命中上报（null = 宿主不接菜单）。菜单本体是 GUI 层，宿主用
  /// showMenu 绘制并保证底板不透明，画布只负责把命中换算成屏幕锚点。
  final void Function(FlowContextTap tap)? onContextMenu;

  /// Ctrl+Z / Ctrl+Y（含 Ctrl+Shift+Z）。撤销栈属于宿主数据层，画布只识别按键。
  final VoidCallback? onUndo;
  final VoidCallback? onRedo;

  /// Ctrl+C / Ctrl+V：复制选中子图、在选中处粘贴。纯内存剪贴板，
  /// 与系统剪贴板无关（跨程序粘贴对 cfg 记录没有意义）。
  final VoidCallback? onCopy;
  final VoidCallback? onPaste;

  @override
  State<StoryFlowGraph> createState() => StoryFlowGraphState();
}

class StoryFlowGraphState extends State<StoryFlowGraph> {
  /// 视口。平移/缩放只改它，不走 setState：卡片子树因此可以整体复用。
  final ValueNotifier<FlowViewport> _vp = ValueNotifier(
    const FlowViewport(1, Offset.zero),
  );
  double get _scale => _vp.value.scale;
  Offset get _pan => _vp.value.pan;
  final FocusNode _focus = FocusNode(debugLabel: 'storyFlowCanvas');

  @override
  void initState() {
    super.initState();
    // 阶段 4a：订阅共享墓碑集合。reload() 只在内容变化时 notify——
    // 删除成功/保存删行的刷新触发点不一定伴随宿主 setState，
    // 靠这里把变化转成一次重建（version 已并入 _contentSig）。
    widget.tombstones?.addListener(_onTombstonesChanged);
  }

  @override
  void didUpdateWidget(covariant StoryFlowGraph oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.tombstones, widget.tombstones)) {
      oldWidget.tombstones?.removeListener(_onTombstonesChanged);
      widget.tombstones?.addListener(_onTombstonesChanged);
    }
  }

  void _onTombstonesChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _longPressTimer?.cancel();
    widget.tombstones?.removeListener(_onTombstonesChanged);
    _focus.dispose();
    _vp.dispose();
    super.dispose();
  }

  _DragMode _mode = _DragMode.none;

  /// 本次手势按下瞬间的 Shift 状态（增删选中 / 框选）。
  bool _additive = false;

  /// 本次拖拽要一起移动的节点：按下点落在选中集里=整组，否则只有它自己。
  List<String> _dragNodeIds = const [];

  /// 组拖开始时各节点的世界坐标基准（避免逐帧累加漂移）。
  final Map<String, Offset> _dragStartPos = {};
  Offset _dragStartLocal = Offset.zero;
  Offset _dragStartPan = Offset.zero;

  /// 框选矩形（世界坐标，未归一化）。
  Offset _marqueeFrom = Offset.zero;
  Offset _marqueeTo = Offset.zero;
  String? _wireFrom;
  String? _wireField;
  FlowEdgeKind _wireKind = FlowEdgeKind.next;
  Offset _wireFromWorld = Offset.zero;
  Offset _wireToLocal = Offset.zero;
  Size _viewSize = Size.zero;

  /// 供宿主小地图（阶段 7）订阅：平移/缩放后反算视口框。
  ValueListenable<FlowViewport> get viewportListenable => _vp;

  /// 当前 LOD 档。低于完整档时展开区与端口圆点都不渲染，
  /// 节点高度也随之回到折叠足迹（见 [_nodeH]）。
  int _lodTier = kLodFull;

  /// 带迟滞的换档判定：升档用 0.45 / 0.60，降档用 0.43 / 0.58。
  /// 没有迟滞，缩放停在临界值会让整批卡片每帧在两档间反复重建；
  /// fitView 这类跳变则一次落到位。
  int _tierFor(int cur, double s) {
    if (cur == kLodFull) {
      if (s >= kLodFullDown) return kLodFull;
      return s < kLodTitleDown ? kLodBlocks : kLodTitle;
    }
    if (cur == kLodTitle) {
      if (s >= kLodFullUp) return kLodFull;
      if (s < kLodTitleDown) return kLodBlocks;
      return kLodTitle;
    }
    if (s < kLodTitleUp) return kLodBlocks;
    return s >= kLodFullUp ? kLodFull : kLodTitle;
  }

  /// 当前跟踪的唯一指针 id：只接管左键/触摸，忽略附加指针与悬停 move；
  /// up/cancel 收不到时（窗口外释放、系统抢占）配合 _onPointerCancel 复位。
  int? _activePointer;

  // ---------- 触控：双指缩放 + 长按菜单 ----------
  /// 活跃触摸/触笔指针 → 最近一帧屏幕(local)坐标。鼠标不入此表：
  /// 鼠标永远单指针，右键/滚轮已有自己的路径，混入会让 pinch 状态机分叉。
  final Map<int, Offset> _touchPositions = {};

  /// 双指及以上视为 pinch（进入时第二指落下的瞬间完成快照）。
  bool get _pinching => _touchPositions.length >= 2;

  /// pinch 起始快照：跨度/缩放/焦点下的世界点。
  /// 缩放全程保持「起始焦点下的世界内容钉在当前焦点下」，两指中点
  /// 平移时内容跟着抓走，不会漂。
  double _pinchStartSpan = 1;
  double _pinchStartScale = 1;
  Offset _pinchStartWorld = Offset.zero;

  /// pinch 退化为单指平移后，抑制该指针抬起时的 <4px「点击」语义
  /// （捏合结束抬指不是点击，不该清空选中集）。
  int? _suppressTapPointer;

  /// 长按菜单：触摸/触笔单指按下 ~500ms 未超出 slop → 走与右键完全
  /// 相同的命中判定与 onContextMenu（菜单本体在宿主）。
  Timer? _longPressTimer;
  int? _longPressPointer;
  Offset _longPressLocal = Offset.zero;

  bool _isTouchKind(PointerDownEvent e) =>
      e.kind == PointerDeviceKind.touch || e.kind == PointerDeviceKind.stylus;

  // ---------- 虚线路径缓存 ----------
  /// 世界坐标下虚线路径与缩放无关，故平移/缩放帧可整体复用；图内容、
  /// 展开态或档位变化时由 [_dashCacheFor] 整体作废。拖拽（positionsVersion）
  /// **不再**整体作废：端点位移由每条边的量化缓存键（见 painter 的
  /// dashKey）逐条消化，跨 4px 桶才重算那一条路径。
  final Map<String, Path> _dashCache = {};
  int _dashCacheRev = -1;

  /// 不含 positionsVersion：旧实现把它算进 rev，拖一帧就整批清空 52 条
  /// 虚线路径缓存再逐条重算，拖拽帧凭空多出全量 computeMetrics/extract。
  int get _geometryRev => Object.hash(widget.graph, _lodTier);

  Map<String, Path> _dashCacheFor() {
    final rev = _geometryRev;
    if (_dashCacheRev != rev) {
      if (kDebugMode && _dashCacheRev != -1) debugDashCacheClears++;
      _dashCache.clear();
      _dashCacheRev = rev;
    }
    return _dashCache;
  }

  // ---------- 坐标换算 ----------
  // 卡片与连线都在世界坐标里布局，屏幕位置由外层 Transform / canvas 变换施加；
  // 只有命中测试要比较原始指针坐标，故只保留屏幕→世界方向。
  Offset _toCanvas(Offset screen) => (screen - _pan) / _scale;

  /// 卡片高度：对白/选项恒为 [kFlowNodeH]，缺失节点为终端占位高度。
  double _nodeH(FlowNode n) => n.isMissing ? kFlowMissingH : kFlowNodeH;

  /// 节点世界足迹（与卡片 Positioned 同式）。
  Rect _nodeWorldRect(FlowNode n) {
    final p = _nodeAnchor(n);
    return Rect.fromLTWH(p.dx, p.dy, kFlowNodeW, _nodeH(n));
  }

  Rect _toScreenRect(Rect r) {
    final s = _scale;
    return Rect.fromLTWH(
      r.left * s + _pan.dx,
      r.top * s + _pan.dy,
      r.width * s,
      r.height * s,
    );
  }

  /// 展开编辑区（底座以下的扩展部分）屏幕矩形；未展开返回 null。
  /// 标题条说话人输入区（世界坐标）：把左侧拖拽把手让给节点拖拽，其余归输入。
  Rect _titleFieldWorldRect(FlowNode n) {
    final p = _nodeAnchor(n);
    return Rect.fromLTWH(
      p.dx + kFlowGripW,
      p.dy,
      kFlowNodeW - kFlowGripW,
      kFlowHeaderH,
    );
  }

  /// 正文输入区（世界坐标）：标题条以下的正文块，左右各留 [kFlowBodyPad]。
  Rect _bodyFieldWorldRect(FlowNode n) {
    final p = _nodeAnchor(n);
    return Rect.fromLTWH(
      p.dx + kFlowBodyPad,
      p.dy + kFlowHeaderH,
      kFlowNodeW - kFlowBodyPad * 2,
      _nodeH(n) - kFlowHeaderH - kFlowBodyPad,
    );
  }

  /// 指针是否落在卡片的可输入字段上：是则画布让位给内层输入框（聚焦/编辑），
  /// 拖拽改由标题条左侧把手与卡片边框/徽章行承载。
  bool _hitsEditableField(FlowNode n, Offset world) {
    if (n.isMissing || _lodTier != kLodFull) return false;
    return _titleFieldWorldRect(n).contains(world) ||
        _bodyFieldWorldRect(n).contains(world);
  }

  /// 节点屏幕足迹。Listener 在 Transform 之外，拿到的是屏幕坐标，
  /// 所以命中统一在屏幕系比较；宽高必须乘 scale 否则缩放后与卡片错位。
  Rect _nodeScreenRect(FlowNode n) => _toScreenRect(_nodeWorldRect(n));

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

  /// 输入端口世界坐标：对白/选项=顶部中心，缺失节点=左侧边中点（终端接入点）。
  Offset _inputPortWorld(FlowNode n) {
    final p = _nodeAnchor(n);
    if (n.isMissing) {
      return p + Offset(0, _nodeH(n) / 2);
    }
    return p + Offset(kFlowNodeW / 2, 0);
  }

  /// 输出端口列表（**相对节点锚点**的偏移 + 写回字段）。
  ///
  /// 卡片实例按 [_contentSig] 缓存复用，位置不属于卡片内容：端口圆点在
  /// 卡片内直接用相对偏移定位（世界位置 = 锚点 + 偏移，锚点由外层
  /// Positioned 施加），端口命中测试用 锚点+偏移 还原世界坐标（见
  /// [_fieldOfPort] / [_edgeFromWorld]）。屏幕位置仍一律由外层
  /// Transform / canvas translate+scale 施加，缩放平移不会让端口错位。
  List<_OutPort> _outputPorts(FlowNode n) {
    if (n.isMissing) return const [];
    final kinds = flowPortKinds(n);
    final count = kinds.length;
    return [
      for (var i = 0; i < count; i++)
        _OutPort(
          _portLabel(kinds[i]),
          kinds[i],
          Offset(kFlowNodeW * (i + 1) / (count + 1), _nodeH(n)),
        ),
    ];
  }

  // ---------- 指针交互 ----------

  /// 收回画布键盘焦点：真实应用里输入框（AI 侧栏、事件搜索等）常持有
  /// 焦点，点画布不回收的话 Delete/Backspace/Ctrl+= 永远进不了 _onKey。
  /// 仅在画布接管交互时收回，编辑区/输入框路径不调用。
  void _takeCanvasFocus() {
    if (!_focus.hasFocus) _focus.requestFocus();
  }

  void _onPointerDown(PointerDownEvent e) {
    // 右键只报菜单锚点：不接管拖拽、不收回焦点（后者会打断输入框编辑）。
    if ((e.buttons & kSecondaryButton) != 0) {
      _reportContextMenu(e.localPosition);
      return;
    }
    // 只接管左键/触摸：右键、中键此前会被当普通按下触发平移/拉线，
    // 与系统菜单手势打架；拖拽进行中忽略第二根指针。
    // 触摸/触笔额外走多指追踪：第二指落下即进 pinch；第三指起忽略。
    // 触摸进行中忽略鼠标，避免两套指针状态交叉。
    if ((e.buttons & kPrimaryButton) == 0) return;
    if (_isTouchKind(e)) {
      if (_pinching) return;
      _touchPositions[e.pointer] = e.localPosition;
      if (_touchPositions.length >= 2) {
        _enterPinch();
        return;
      }
      if (_activePointer != null) return;
    } else if (_touchPositions.isNotEmpty || _activePointer != null) {
      return;
    }
    _activePointer = e.pointer;
    // 新手势开始：清除上一 pinch 留下的「抬指不点击」标记（指针 id 单调
    // 递增本不会撞，显式清掉防语义泄漏）。
    _suppressTapPointer = null;
    final local = e.localPosition;
    final world = _toCanvas(local);
    // Shift 在按下瞬间定调（增删/框选），整次手势内不再重新读取。
    final additive = _additive = HardwareKeyboard.instance.isShiftPressed;
    _dragStartLocal = local;
    _dragStartPan = _pan;

    for (final n in widget.graph.nodes) {
      final port = _outPortAt(n, world);
      if (port != null) {
        final field = fieldForEdge(port.kind);
        if (field != null) {
          _mode = _DragMode.wire;
          _wireFrom = n.id;
          _wireField = field;
          _wireKind = port.kind;
          _wireFromWorld = _nodeAnchor(n) + port.pos;
          _wireToLocal = local;
          _takeCanvasFocus();
          _armLongPress(e.pointer, local);
          setState(() {});
          return;
        }
      }
    }
    // 卡片输入区（说话人标题 / 正文）：让位给内层输入框，画布不拖拽/不抢
    // 焦点；但仍更新选中集（否则点卡片正文编辑时键盘删除等失焦）。
    // 输入区之外（标题把手、卡片边框、徽章行）仍归节点拖拽/选中。
    for (final n in widget.graph.nodes) {
      if (_hitsEditableField(n, world)) {
        _mode = _DragMode.none;
        final sel = widget.selection;
        final already = sel.nodes.contains(n.id);
        final next = additive
            ? sel.toggledNode(n.id)
            : (already ? sel : FlowSelection.ofNode(n.id));
        if (next != sel) widget.onSelectionChanged(next);
        return;
      }
    }
    for (final n in widget.graph.nodes) {
      if (n.isMissing) continue;
      if (_nodeScreenRect(n).inflate(4).contains(local)) {
        _mode = _DragMode.node;
        final sel = widget.selection;
        final already = sel.nodes.contains(n.id);
        // Shift = 增删该节点；点在已选中节点上 = 保留整组；否则单选它。
        final next = additive
            ? sel.toggledNode(n.id)
            : already
            ? sel
            : FlowSelection.ofNode(n.id);
        if (next != sel) widget.onSelectionChanged(next);
        // 刚被 Shift 取消选中的那个仍跟着手走，其余按新选中集成组移动。
        _beginNodeDrag(
          additive && already
              ? {n.id}
              : (next.nodes.isEmpty ? {n.id} : next.nodes),
        );
        _takeCanvasFocus();
        _armLongPress(e.pointer, local);
        setState(() {});
        return;
      }
    }
    // 空白处：Shift = 框选，否则保持平移（不破坏既有肌肉记忆）。
    if (additive) {
      _mode = _DragMode.marquee;
      _marqueeFrom = _marqueeTo = world;
      _takeCanvasFocus();
      _armLongPress(e.pointer, local);
      setState(() {});
      return;
    }
    _mode = _DragMode.pan;
    _takeCanvasFocus();
    _armLongPress(e.pointer, local);
  }

  /// 右键上报：端口/卡片 → 边 → 空白。菜单本体与动作全在宿主。
  void _reportContextMenu(Offset local) {
    final cb = widget.onContextMenu;
    if (cb == null) return;
    final world = _toCanvas(local);
    for (final n in widget.graph.nodes) {
      if (n.isMissing) continue;
      if (_fieldOfPort(n, world) != null ||
          _nodeScreenRect(n).contains(local)) {
        cb(FlowContextTap(nodeId: n.id, screen: local));
        return;
      }
    }
    cb(FlowContextTap(edge: _hitEdge(local), screen: local));
  }

  /// 拖拽吸附命中的辅助线（世界坐标）。每帧由 [_applySnap] 重写。
  List<FlowGuide> _snapGuides = const [];

  /// 记住这一组节点的起始世界坐标，之后每帧按指针位移整体平移。
  void _beginNodeDrag(Set<String> ids) {
    _dragStartPos.clear();
    _dragNodeIds = [
      for (final id in ids)
        if (widget.graph.nodeById(id) != null) id,
    ];
    for (final id in _dragNodeIds) {
      _dragStartPos[id] = widget.positions[id] ?? Offset.zero;
    }
  }

  /// [world] 已是世界坐标；容差除以 scale 保证不同缩放下屏幕手感一致。
  /// 端口表存的是相对锚点的偏移，这里加回锚点得世界坐标。
  _OutPort? _outPortAt(FlowNode n, Offset world) {
    final anchor = _nodeAnchor(n);
    final r = (kPortR + 11) / _scale;
    _OutPort? best;
    var bestD = double.infinity;
    for (final p in _outputPorts(n)) {
      final d = (world - (anchor + p.pos)).distance;
      if (d <= r && d < bestD) {
        bestD = d;
        best = p;
      }
    }
    return best;
  }

  String? _fieldOfPort(FlowNode n, Offset world) {
    final p = _outPortAt(n, world);
    return p != null ? fieldForEdge(p.kind) : null;
  }

  void _onPointerMove(PointerMoveEvent e) {
    // 触摸轨迹与 pinch 不依赖 _activePointer：pinch 期间两指都未认领。
    if (_touchPositions.containsKey(e.pointer)) {
      _touchPositions[e.pointer] = e.localPosition;
      if (_pinching) {
        _applyPinch();
        return;
      }
    }
    if (e.pointer != _activePointer) return;
    final local = e.localPosition;
    // 长按计时：指针位移超出触摸 slop 即取消（拖动不是长按）。
    if (_longPressTimer != null &&
        (local - _longPressLocal).distance > kTouchSlop) {
      _cancelLongPress();
    }
    switch (_mode) {
      case _DragMode.node:
        _applySnap((local - _dragStartLocal) / _scale);
      case _DragMode.wire:
        setState(() => _wireToLocal = local);
      case _DragMode.pan:
        // 只换视口：不 setState，卡片子树与虚线缓存都不受影响。
        _vp.value = FlowViewport(
          _scale,
          _dragStartPan + (local - _dragStartLocal),
        );
      case _DragMode.marquee:
        setState(() => _marqueeTo = _toCanvas(local));
      case _DragMode.none:
        break;
    }
  }

  void _onPointerUp(PointerUpEvent e) {
    // pinch 成员抬指：剩指退化为平移（该指抬起不再触发 <4px 点击语义）；
    // 全部抬起则收场。注意 wasPinching 要在 remove 前取样。
    final wasPinching = _pinching;
    final had = _touchPositions.remove(e.pointer) != null;
    if (wasPinching && had) {
      _pinchMemberExited();
      return;
    }
    if (e.pointer != _activePointer) return;
    _cancelLongPress();
    _activePointer = null;
    final local = e.localPosition;
    final mode = _mode;
    _mode = _DragMode.none;
    switch (mode) {
      case _DragMode.wire:
        final fromId = _wireFrom!;
        final field = _wireField!;
        _wireFrom = null;
        _wireField = null;
        _wireFromWorld = Offset.zero;
        final target = _hitInputPort(local);
        if (target != null && target != fromId) {
          widget.onAddEdge(fromId, field, target);
        }
        setState(() {});
      case _DragMode.node:
        _dragNodeIds = const [];
        _dragStartPos.clear();
        _snapGuides = const [];
        setState(() {});
      case _DragMode.marquee:
        _commitMarquee();
        setState(() {});
      case _DragMode.pan:
        // pinch 退化后的抬指不是点击，不清选中集。
        if (e.pointer != _suppressTapPointer &&
            (local - _dragStartLocal).distance < 4) {
          final hit = _hitEdge(local);
          if (hit != null) {
            widget.onSelectionChanged(
              _additive
                  ? widget.selection.toggledEdge(hit)
                  : FlowSelection.ofEdge(hit),
            );
          } else if (!_additive) {
            // Shift 点空白是框选手势，不该把已有选中集清掉。
            widget.onSelectionChanged(FlowSelection.none);
          }
        }
        _suppressTapPointer = null;
      case _DragMode.none:
        break;
    }
  }

  /// 拖拽吸附：单选直接吸该框，多选吸整组包围盒再把同一位移分给每个成员。
  /// Alt 按住 = 临时关掉吸附（精细摆位用）。
  ///
  /// 这里不 setState：`onMoveNode` 会让宿主重建，画布跟着拿到新的
  /// positionsVersion 重绘，[_snapGuides] 在同一帧里被 painter 读到。
  void _applySnap(Offset delta) {
    final ids = _dragNodeIds;
    if (ids.isEmpty) return;
    var offset = delta;
    if (!HardwareKeyboard.instance.isAltPressed) {
      var minX = double.infinity, minY = double.infinity;
      var maxX = -double.infinity, maxY = -double.infinity;
      for (final id in ids) {
        final p = _dragStartPos[id]! + delta;
        if (p.dx < minX) minX = p.dx;
        if (p.dy < minY) minY = p.dy;
        if (p.dx + kFlowNodeW > maxX) maxX = p.dx + kFlowNodeW;
        if (p.dy + kFlowNodeH > maxY) maxY = p.dy + kFlowNodeH;
      }
      final snap = snapDrag(
        desired: Offset(minX, minY),
        self: Size(maxX - minX, maxY - minY),
        // 只喂视口内的其它节点，且排除被拖的这几个（否则组内互吸会抖）。
        others: flowNodeRects(
          positions: widget.positions,
          exclude: Set<String>.of(ids),
          visible: _vp.value.worldRect(_viewSize).inflate(kFlowNodeW),
        ),
        scale: _scale,
      );
      offset = delta + (snap.pos - Offset(minX, minY));
      _snapGuides = snap.guides;
    } else {
      _snapGuides = const [];
    }
    for (final id in ids) {
      widget.onMoveNode(id, _dragStartPos[id]! + offset);
    }
  }

  /// 框选收口：矩形与节点足迹相交即选中；边按贝塞尔中点落在框内判定。
  void _commitMarquee() {
    final box = Rect.fromPoints(_marqueeFrom, _marqueeTo);
    final picked = <String>{};
    for (final n in widget.graph.nodes) {
      if (n.isMissing) continue;
      if (box.overlaps(_nodeWorldRect(n))) picked.add(n.id);
    }
    final pickedEdges = <FlowEdge>{};
    for (final e in widget.graph.edges) {
      final from = widget.graph.nodeById(e.from);
      final to = widget.graph.nodeById(e.to);
      if (from == null || to == null) continue;
      if (box.contains(
        _bezierMid(_edgeFromWorld(from, e), _inputPortWorld(to)),
      )) {
        pickedEdges.add(e);
      }
    }
    if (picked.isEmpty && pickedEdges.isEmpty) return;
    // 框选只在按下 Shift 时进入，因此语义是「并入现有选中集」。
    widget.onSelectionChanged(
      widget.selection.union(FlowSelection(nodes: picked, edges: pickedEdges)),
    );
  }

  /// 三次贝塞尔 t=0.5 点（控制柄与 _paintEdge/_hitEdge 同式）。
  static Offset _bezierMid(Offset s, Offset t) {
    final dx = (t.dx - s.dx).abs().clamp(40.0, 200.0);
    final c1 = s + Offset(dx, 0);
    final c2 = t + Offset(-dx, 0);
    return (s + c1 * 3 + c2 * 3 + t) / 8;
  }

  /// 指针被系统抢占（弹窗/菜单抢焦点、触摸被取消）时收不到 PointerUp：
  /// 必须复位拖拽态，否则桌面端悬停 move 仍按残留 _mode 触发，
  /// 节点会不按键跟随鼠标、幻影连线悬挂。
  void _onPointerCancel(PointerCancelEvent e) {
    final wasPinching = _pinching;
    final had = _touchPositions.remove(e.pointer) != null;
    if (wasPinching && had) {
      _pinchMemberExited();
      return;
    }
    if (e.pointer != _activePointer) return;
    _activePointer = null;
    _cancelLongPress();
    if (_mode == _DragMode.none) return;
    _abortSingleGesture();
    setState(() {});
  }

  /// pinch 中一指离场（抬起或被取消）后的收场：剩指退化为平移，
  /// 全部离场则复位。调用方需已把该指针从 [_touchPositions] 移除。
  void _pinchMemberExited() {
    _activePointer = null;
    _mode = _DragMode.none;
    if (_touchPositions.length == 1) {
      final remaining = _touchPositions.keys.single;
      _activePointer = remaining;
      _mode = _DragMode.pan;
      _dragStartLocal = _touchPositions[remaining]!;
      _dragStartPan = _pan;
      _suppressTapPointer = remaining;
    }
    setState(() {});
  }

  /// 终止进行中的单指手势（长按触发菜单 / 进入 pinch 前调用）。
  /// [revertNodeDrag] 时把已被单指拖动的节点组弹回起点——两指按下或
  /// 长按不是拖拽意图，散乱半个身位的节点比「没拖」更糟。
  void _abortSingleGesture({bool revertNodeDrag = false}) {
    if (revertNodeDrag && _mode == _DragMode.node) {
      for (final id in _dragNodeIds) {
        final start = _dragStartPos[id];
        if (start != null) widget.onMoveNode(id, start);
      }
    }
    _mode = _DragMode.none;
    _wireFrom = null;
    _wireField = null;
    _wireFromWorld = Offset.zero;
    _dragNodeIds = const [];
    _dragStartPos.clear();
    _snapGuides = const [];
  }

  // ---------- 触控手势核心 ----------

  /// 第二指落下：快照 pinch 基准（跨度/焦点/焦点下世界点），并终止
  /// 单指正在进行的拖拽/拉线/框选。
  void _enterPinch() {
    _cancelLongPress();
    _abortSingleGesture(revertNodeDrag: true);
    _activePointer = null;
    final pts = _touchPositions.values.toList();
    final span = (pts[0] - pts[1]).distance;
    final focal = Offset(
      (pts[0].dx + pts[1].dx) / 2,
      (pts[0].dy + pts[1].dy) / 2,
    );
    _pinchStartSpan = span > 0 ? span : 1;
    _pinchStartScale = _scale;
    _pinchStartWorld = _toCanvas(focal);
    _applyPinch();
    setState(() {});
  }

  /// 由当前两指几何推出新视口：scale 按跨度比值相对**起始**缩放缩放
  /// （clamp 到画布上下限），pan 保持起始焦点下的世界点钉在当前两指
  /// 中点下（内容跟手不漂）。
  void _applyPinch() {
    final pts = _touchPositions.values.toList();
    if (pts.length < 2) return;
    final span = (pts[0] - pts[1]).distance;
    final focal = Offset(
      (pts[0].dx + pts[1].dx) / 2,
      (pts[0].dy + pts[1].dy) / 2,
    );
    final nextScale = (_pinchStartScale * span / _pinchStartSpan).clamp(
      FlowViewport.minScale,
      FlowViewport.maxScale,
    );
    _vp.value = FlowViewport(
      nextScale.toDouble(),
      focal - _pinchStartWorld * nextScale,
    );
  }

  // ---------- 长按菜单 ----------

  void _armLongPress(int pointer, Offset local) {
    _cancelLongPress();
    _longPressPointer = pointer;
    _longPressLocal = local;
    _longPressTimer = Timer(kLongPressTimeout, _onLongPressElapsed);
  }

  void _cancelLongPress() {
    _longPressTimer?.cancel();
    _longPressTimer = null;
    _longPressPointer = null;
  }

  /// 长按成立：终止进行中的手势（节点弹回起点），走与右键完全相同的
  /// 命中判定上报菜单；此后该指针的 up 被 _activePointer=null 吞掉。
  void _onLongPressElapsed() {
    _longPressTimer = null;
    if (_pinching ||
        _activePointer == null ||
        _activePointer != _longPressPointer ||
        _mode == _DragMode.none) {
      return;
    }
    final local = _longPressLocal;
    _abortSingleGesture(revertNodeDrag: true);
    _activePointer = null;
    _reportContextMenu(local);
    setState(() {});
  }

  String? _hitInputPort(Offset local) {
    final world = _toCanvas(local);
    final reach = (kPortR + 10) / _scale;
    String? best;
    var bestD = double.infinity;
    for (final n in widget.graph.nodes) {
      if (n.isMissing) continue;
      // 1. 指针释放于目标节点卡片区域内（含容差）：直接连向该卡片
      final cardRect = _nodeWorldRect(n).inflate(reach);
      final portPos = _inputPortWorld(n);
      final portDist = (world - portPos).distance;
      if (cardRect.contains(world)) {
        if (portDist < bestD) {
          bestD = portDist;
          best = n.id;
        }
        continue;
      }
      // 2. 指针释放于输入端口附近（例如卡片上方接入点外扩）
      if (portDist < bestD && portDist <= reach * 2.0) {
        bestD = portDist;
        best = n.id;
      }
    }
    return best;
  }

  FlowEdge? _hitEdge(Offset local) {
    final world = _toCanvas(local);
    final reach = 8 / _scale;
    FlowEdge? best;
    var bestD = double.infinity;
    for (final e in widget.graph.edges) {
      final from = widget.graph.nodeById(e.from);
      final to = widget.graph.nodeById(e.to);
      if (from == null || to == null) continue;
      final s = _edgeFromWorld(from, e);
      final t = _inputPortWorld(to);
      // 控制柄最多外扩 200 世界像素；先粗筛再采样，避免每条边都做 20 点。
      if (!Rect.fromPoints(s, t).inflate(200 + reach).contains(world)) {
        continue;
      }
      final d = _distToBezier(world, s, t);
      if (d < bestD && d <= reach) {
        bestD = d;
        best = e;
      }
    }
    return best;
  }

  Offset _edgeFromWorld(FlowNode from, FlowEdge e) {
    if (from.isMissing) return _inputPortWorld(from);
    // 端口表存相对锚点的偏移，加回锚点得世界坐标（连线命中/框选判定用）。
    final anchor = _nodeAnchor(from);
    for (final p in _outputPorts(from)) {
      if (p.kind == e.kind) return anchor + p.pos;
    }
    return anchor + Offset(kFlowNodeW / 2, _nodeH(from));
  }

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
        v * v * v * s.dx +
            3 * v * v * u * c1.dx +
            3 * v * u * u * c2.dx +
            u * u * u * t.dx,
        v * v * v * s.dy +
            3 * v * v * u * c1.dy +
            3 * v * u * u * c2.dy +
            u * u * u * t.dy,
      );
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
    // 指针在卡片正文输入区：滚轮只归内层文本滚动视图。Listener 是画布
    // 祖先，信号事件沿命中链直达，不在这里让位就会出现「滚台词把整个
    // 画布一起缩放」的连滚。
    final world = _toCanvas(local);
    for (final n in widget.graph.nodes) {
      if (!n.isMissing && _bodyFieldWorldRect(n).contains(world)) return;
    }
    final factor = e.scrollDelta.dy > 0 ? 0.9 : 1.1;
    final next = (_scale * factor)
        .clamp(FlowViewport.minScale, FlowViewport.maxScale)
        .toDouble();
    if (next == _scale) return;
    _vp.value = _vp.value.withZoom(next, local);
  }

  /// 适配视图：计算全部节点世界包围盒并缩放平移居中。
  void fitView() {
    if (widget.graph.nodes.isEmpty || _viewSize.isEmpty) return;
    var minX = double.infinity, minY = double.infinity;
    var maxX = -double.infinity, maxY = -double.infinity;
    for (final n in widget.graph.nodes) {
      final r = _nodeWorldRect(n);
      minX = math.min(minX, r.left);
      minY = math.min(minY, r.top);
      maxX = math.max(maxX, r.right);
      maxY = math.max(maxY, r.bottom);
    }
    final box = Rect.fromLTRB(minX, minY, maxX, maxY);
    const pad = 40.0;
    final sx = (_viewSize.width - pad * 2) / box.width;
    final sy = (_viewSize.height - pad * 2) / box.height;
    final scale = math
        .min(sx, sy)
        .clamp(FlowViewport.minScale, FlowViewport.maxScale)
        .toDouble();
    final cx = box.center.dx * scale;
    final cy = box.center.dy * scale;
    // 只换视口：卡片层由 ValueListenableBuilder 重建，不走 setState。
    _vp.value = FlowViewport(
      scale,
      Offset(_viewSize.width / 2 - cx, _viewSize.height / 2 - cy),
    );
  }

  /// 把某个世界点居中（小地图点击/拖拽用）。只换视口，不碰卡片子树。
  void centerOn(Offset world) {
    if (_viewSize.isEmpty) return;
    final s = _scale;
    _vp.value = FlowViewport(
      s,
      Offset(
        _viewSize.width / 2 - world.dx * s,
        _viewSize.height / 2 - world.dy * s,
      ),
    );
  }

  /// 画布快捷键。焦点在输入框内时整体让位（内联编辑里的 Backspace/Escape
  /// 不该变成删节点/取消选中）。
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (focusInEditableText()) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (HardwareKeyboard.instance.isControlPressed) {
      final cb = key == LogicalKeyboardKey.keyC
          ? widget.onCopy
          : (key == LogicalKeyboardKey.keyV ? widget.onPaste : null);
      if (cb != null) {
        cb();
        return KeyEventResult.handled;
      }
    }
    final hist = historyKeyOp(event);
    if (hist != null) {
      final cb = hist == 'undo' ? widget.onUndo : widget.onRedo;
      if (cb == null) return KeyEventResult.ignored;
      cb();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.delete ||
        key == LogicalKeyboardKey.backspace) {
      if (widget.selection.isNotEmpty) {
        widget.onRequestDelete();
        return KeyEventResult.handled;
      }
    }
    if (key == LogicalKeyboardKey.escape) {
      if (widget.selection.isNotEmpty) {
        widget.onSelectionChanged(FlowSelection.none);
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

  // ---------- 卡片层（视口裁剪 + LOD 档 + 卡片实例缓存） ----------

  /// 卡片槽位：世界足迹（供裁剪求交）+ 已定位的槽位包装（Positioned）。
  List<_FlowSlot> _slots = const [];

  /// 卡片实例缓存（key = 节点 id）：卡片 Widget 只在 [_contentSig] 变化时
  /// 重算一次，其余场景原样复用同一实例。旧实现每次宿主重建都无条件作废
  /// 全部槽位（didUpdateWidget 里 _slotsTier=-1），拖一个节点也要为全部
  /// N 个节点新建卡片 + 端口表 + 世界足迹，~2,500 次分配/帧。
  final Map<String, Widget> _cards = {};

  /// [_slots] 当前对应的内容签名与 positionsVersion；null = 尚未构建过。
  /// graph 身份由 _slotsGraph 单独 identical 精确比对（不走哈希，零碰撞）。
  int? _slotsSig;
  int? _slotsPosVer;
  FlowGraph? _slotsGraph;

  /// 槽位内容签名：决定「卡片实例能否复用」的全部输入。
  ///
  /// - tier：LOD 档（titleOnly / 节点高度都随档变）；
  /// - selection / highlight：卡片边框、阴影、选中态；
  /// - tombstones.version：集合内容变化（reload 后 bump）必须作废卡片缓存。
  ///
  /// 正文/说话人文本的变更走宿主 `_bumpGraph` 换新图对象，由 graph 身份比对
  /// 捕获；**positionsVersion 刻意不进来**：位置只影响外层 Positioned 包装的
  /// left/top（见 [_slotsFor]），卡片内容与位置无关；把它算进签名等于回到
  /// 「拖拽每帧全量重建卡片」。
  int _contentSig(int tier) {
    return Object.hash(
      tier,
      widget.selection,
      widget.highlightNode,
      widget.tombstones?.version,
    );
  }

  /// 槽位获取门控，画布子树每次重渲染都会经过这里：
  /// - graph 换了或内容签名变了 → 清卡片缓存并整体重建（卡片实例 + 包装）；
  /// - 仅 positionsVersion 变了（拖拽/落点）→ 只重建 Positioned 包装，
  ///   child 仍是缓存里的 identical 卡片实例：Element.updateChild 对
  ///   identical child 短路，卡片连 build 都不会进；
  /// - 两者都没变（纯宿主重泵）→ 什么都不做，原槽位列表直接复用。
  List<_FlowSlot> _slotsFor(int tier) {
    final sig = _contentSig(tier);
    final posVer = widget.positionsVersion;
    if (_slotsSig != sig ||
        !identical(_slotsGraph, widget.graph) ||
        _slotsPosVer == null) {
      _cards.clear();
      _slots = _buildSlots(tier);
      _slotsSig = sig;
      _slotsPosVer = posVer;
      _slotsGraph = widget.graph;
    } else if (_slotsPosVer != posVer) {
      _slots = _buildSlots(tier);
      _slotsPosVer = posVer;
    }
    return _slots;
  }

  List<_FlowSlot> _buildSlots(int tier) {
    if (kDebugMode) debugBuildSlotsCalls++;
    final full = tier == kLodFull;
    return [
      for (final n in widget.graph.nodes)
        _FlowSlot(
          _nodeWorldRect(n),
          Positioned(
            key: ValueKey(n.id),
            left: _nodeAnchor(n).dx,
            top: _nodeAnchor(n).dy,
            width: kFlowNodeW,
            height: _nodeH(n),
            child: _cardFor(n, full),
          ),
        ),
    ];
  }

  /// 取（或构建）节点卡片实例。只有缓存未命中才新建：拖拽帧与纯宿主重泵
  /// 都应 0 次新建（准出探针 [debugSlotCardsBuilt]）。
  Widget _cardFor(FlowNode n, bool full) {
    final hit = _cards[n.id];
    if (hit != null) return hit;
    if (kDebugMode) debugSlotCardsBuilt++;
    final card = _FlowNodeCard(
      key: ValueKey(n.id),
      node: n,
      titleOnly: !full,
      selected: widget.selection.nodes.contains(n.id),
      highlighted: widget.highlightNode == n.id,
      // 逐节点数据一律以函数形式下传：卡片是 StatelessWidget 且实例被
      // 缓存复用，读全局会在内容变更前渲染出旧值。
      speakerController: widget.speakerController,
      onSpeakerSubmitted: widget.onSpeakerSubmitted,
      onNodeFocused: widget.onNodeFocused,
      onRequestInspector: widget.onRequestInspector,
      outputPorts: _outputPorts(n),
      fieldController: widget.fieldController,
      onFieldChanged: widget.onFieldChanged,
      tombstones: widget.tombstones,
      onDeleteNode: widget.onDeleteNode,
    );
    _cards[n.id] = card;
    return card;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: _onKey,
      child: LayoutBuilder(
        builder: (context, box) {
          _viewSize = box.biggest;
          // Listener 必须在 Transform 之外：localPosition 保持屏幕坐标，
          // 命中测试在入口处统一 _toCanvas 换算成世界坐标。
          return Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: _onPointerDown,
            onPointerMove: _onPointerMove,
            onPointerUp: _onPointerUp,
            onPointerCancel: _onPointerCancel,
            onPointerSignal: _onPointerSignal,
            child: ClipRect(
              child: ValueListenableBuilder<FlowViewport>(
                valueListenable: _vp,
                builder: (context, vp, _) {
                  _lodTier = _tierFor(_lodTier, vp.scale);
                  return CustomPaint(
                    size: _viewSize,
                    painter: _FlowEdgesPainter(
                      graph: widget.graph,
                      positions: widget.positions,
                      positionsVersion: widget.positionsVersion,
                      viewport: vp,
                      lodTier: _lodTier,
                      nodeH: _nodeH,
                      selection: widget.selection,
                      marquee: _mode == _DragMode.marquee
                          ? Rect.fromPoints(
                              vp.toScreen(_marqueeFrom),
                              vp.toScreen(_marqueeTo),
                            )
                          : null,
                      dashCache: _dashCacheFor(),
                      guides: _snapGuides,
                      wire: _mode == _DragMode.wire && _wireFrom != null
                          ? (_wireFromWorld, _wireToLocal, _wireKind)
                          : null,
                    ),
                    // 视口只改这一个矩阵：RenderTransform 只 markNeedsPaint，
                    // 卡片子树与虚线缓存都不受影响。
                    child: Transform(
                      alignment: Alignment.topLeft,
                      transform: vp.matrix,
                      child: _cardLayer(vp),
                    ),
                  );
                },
              ),
            ),
          );
        },
      ),
    );
  }

  /// 可见卡片层。裁剪留一个节点宽的外圈，拖动时不会看到卡片从边缘「长出来」。
  Widget _cardLayer(FlowViewport vp) {
    if (_lodTier == kLodBlocks) return const SizedBox.shrink();
    final visible = vp.worldRect(_viewSize).inflate(kFlowNodeW);
    return Stack(
      clipBehavior: Clip.none,
      children: [
        for (final s in _slotsFor(_lodTier))
          if (visible.overlaps(s.rect)) s.child,
      ],
    );
  }
}

/// 卡片槽位：世界足迹（供裁剪求交）+ 已定位的槽位包装。
///
/// 包装（Positioned）在内容签名或 positionsVersion 变化时由 [_buildSlots]
/// 重建；child 始终是卡片实例缓存里的 identical 实例 —— 拖拽帧只更新
/// 包装的 left/top，卡片子树原样复用，一次 build 都不进。
class _FlowSlot {
  const _FlowSlot(this.rect, this.child);
  final Rect rect;
  final Widget child;
}

enum _DragMode { none, node, wire, pan, marquee }

class _OutPort {
  const _OutPort(this.label, this.kind, this.pos);
  final String label;
  final FlowEdgeKind kind;

  /// 相对节点锚点的偏移（卡片内坐标）；世界坐标 = _nodeAnchor(n) + pos。
  final Offset pos;
}

class _FlowNodeCard extends StatelessWidget {
  const _FlowNodeCard({
    super.key,
    required this.node,
    required this.selected,
    required this.highlighted,
    required this.speakerController,
    required this.onSpeakerSubmitted,
    required this.onNodeFocused,
    required this.onRequestInspector,
    required this.outputPorts,
    required this.fieldController,
    required this.onFieldChanged,
    required this.tombstones,
    this.onDeleteNode,
    this.titleOnly = false,
  });

  final FlowNode node;

  /// 位置不在卡片上：卡片实例按画布 State 的 _contentSig 缓存复用，
  /// 世界坐标的 Positioned 在槽位包装（_FlowSlot）上，拖拽帧只更新包装。
  final bool selected;
  final bool highlighted;

  /// 说话人标题输入控制器（null=无记录/不可编辑，退化为静态标题）。
  final TextEditingController? Function(String nodeId) speakerController;

  /// 提交说话人输入（回车/失焦）：宿主匹配人物 id 或弹窗。
  final void Function(String nodeId, String text) onSpeakerSubmitted;

  /// 输入区获得焦点：宿主据此选中节点（画布已对输入区让位）。
  final ValueChanged<String>? onNodeFocused;

  /// 请求打开完整参数 Inspector（双击卡片）。
  final VoidCallback? Function(String nodeId) onRequestInspector;

  final List<_OutPort> outputPorts;
  final TextEditingController? Function(String nodeId, String field)
  fieldController;
  final void Function(String nodeId, String field, String text) onFieldChanged;

  /// 阶段 4a：story 级共享墓碑集合，由画布原样递下（卡片实例被缓存复用，
  /// 自己去读全局会在集合变更后渲染出旧值）。
  /// null = 宿主未接墓碑，talk/option 按普通卡片渲染。
  final TombstoneStore? tombstones;

  /// 删除落盘成功后通知宿主把该节点从画布数据里摘掉（阶段 2d：删失败不摘，
  /// 避免「画布删了但磁盘还在」的分叉）。缺省时只刷新墓碑集合。
  final ValueChanged<String>? onDeleteNode;

  /// LOD 中档：只画标题条。低缩放下正文与端口都不可读，省掉整段排版。
  final bool titleOnly;

  double get _h => node.isMissing ? kFlowMissingH : kFlowNodeH;

  Color get _tint => flowNodeTint(node);

  Color get _borderColor {
    if (selected) return _tint;
    if (highlighted) return palette.flowAudio;
    return palette.border;
  }

  @override
  Widget build(BuildContext context) {
    final card = _buildCard(context);

    // P8: 墓碑节点（已删除但仍被引用）渲染为占位方块。
    // 阶段 4a：同步读 story 级共享的 [TombstoneStore]——旧实现每张
    // talk/option 卡片包一层 `FutureBuilder(future: isDeleted(id))`，
    // 一次加载 = 节点数那么多次 GET /api/cfg/deleted_talks。
    if ((node.kind == FlowNodeKind.talk || node.isOption) &&
        tombstones?.contains(node.id) == true) {
      return TombstoneNodeWidget(
        id: node.id,
        store: tombstones,
        onRestore: () async {
          // 阶段 2d：删除失败不再静默——不本地摘节点 + toast 报因，
          // 否则画布「删掉了」而磁盘记录/墓碑还在，下次加载死灰复燃。
          try {
            await deleteRecord(
              cfgName: node.isOption ? 'OptionCfg' : 'TalkCfg',
              id: node.id,
            );
            // 删除落盘 = 墓碑集合可能变化：刷新共享集合（单飞拉取，
            // 内容变了才 bump version → _contentSig 变 → 卡片重渲染）。
            await tombstones!.reload();
            // 删除落盘成功后才本地摘节点（失败走 catch，画布保持原样）。
            onDeleteNode?.call(node.id);
          } catch (e) {
            if (context.mounted) {
              fluent.displayInfoBar(
                context,
                builder: (ctx, close) => fluent.InfoBar(
                  title: const Text('删除节点失败'),
                  content: Text('$e'),
                  severity: fluent.InfoBarSeverity.error,
                ),
              );
            }
          }
        },
      );
    }
    return card;
  }

  Widget _buildCard(BuildContext context) {
    final w = kFlowNodeW;
    final hh = _h;
    final r = kPortR;
    final dots = <Widget>[
      for (final p in outputPorts)
        Positioned(
          // 端口表已是相对卡片锚点的偏移，世界坐标由外层槽位包装施加。
          left: p.pos.dx - r,
          top: hh - r,
          width: r * 2,
          height: r * 2,
          child: _PortDot(label: p.label, color: _portColor(p.kind)),
        ),
    ];
    // Positioned（left/top/width/height）已上提到槽位包装 _FlowSlot：
    // 位置不属于卡片内容，实例才能跨拖拽帧 identical 复用。
    // 每张卡片自成重绘层：外层 Transform 只改矩阵时不牵连卡片内容。
    return RepaintBoundary(
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            left: 0,
            top: 0,
            width: w,
            height: hh,
            child: _baseCard(),
          ),
          if (!titleOnly) ...dots,
          // 输入接入点（顶部中心，缺失节点居左侧中点）
          if (!titleOnly)
            Positioned(
              left: node.isMissing ? -r : w / 2 - r,
              top: node.isMissing ? hh / 2 - r : -r,
              width: r * 2,
              height: r * 2,
              child: _PortDot(
                label: '接入点',
                color: palette.borderHover,
              ),
            ),
        ],
      ),
    );
  }

  Widget _baseCard() {
    final radius = BorderRadius.circular(AppRadius.m);
    return GestureDetector(
      // 双击卡片打开完整参数 Inspector（面板头「展开完整参数」入口的替代）。
      onDoubleTap: () => onRequestInspector(node.id)?.call(),
      child: Container(
        decoration: BoxDecoration(
          color: palette.card,
          border: Border.all(
            color: _borderColor,
            width: selected ? 1.6 : 1,
          ),
          borderRadius: radius,
          boxShadow: selected
              ? [BoxShadow(color: _tint.withValues(alpha: 0.22), blurRadius: 10)]
              : highlighted
              ? [
                  BoxShadow(
                    color: palette.flowAudio.withValues(alpha: 0.3),
                    blurRadius: 10,
                  ),
                ]
              : null,
        ),
        child: ClipRRect(
          borderRadius: radius,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _titleRow(),
              // LOD 中档：只留标题条。卡片尺寸不变，连线端点才不会错位。
              if (!titleOnly) Expanded(child: _bodyArea()),
              if (!titleOnly && node.hasParamBadges) _badgeRow(),
            ],
          ),
        ),
      ),
    );
  }

  /// 卡片标题条：左侧拖拽把手 + 说话人输入（对白），选项/缺失节点走静态标题。
  Widget _titleRow() {
    return Container(
      height: kFlowHeaderH,
      color: _tint.withValues(alpha: 0.16),
      padding: const EdgeInsets.only(right: AppSpace.xs),
      child: Row(
        children: [
          // 拖拽把手：这块宽度（kFlowGripW）由画布命中共为节点拖拽/选中。
          SizedBox(
            width: kFlowGripW,
            child: Icon(
              node.isMissing
                  ? Icons.link_off
                  : (node.isOption ? Icons.alt_route : Icons.drag_indicator),
              size: 13,
              color: _tint,
            ),
          ),
          Expanded(child: _titleContent()),
        ],
      ),
    );
  }

  Widget _titleContent() {
    if (node.isOption || node.isMissing) return _staticTitle();
    final ctl = speakerController(node.id);
    if (titleOnly || ctl == null) return _staticTitle();
    return _SpeakerField(
      key: ValueKey('flowSpeaker|${node.id}'),
      controller: ctl,
      placeholder: node.isNarrator ? '旁白' : '对白',
      onSubmitted: (v) => onSpeakerSubmitted(node.id, v),
      onFocused: () => onNodeFocused?.call(node.id),
    );
  }

  Widget _staticTitle() {
    return Align(
      alignment: Alignment.centerLeft,
      child: Text(
        node.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: AppType.title,
          fontWeight: FontWeight.w600,
          color: palette.textHigh,
        ),
      ),
    );
  }

  /// 卡片正文：对白/选项直接内联编辑 content，缺失节点/低档退化为只读文本。
  Widget _bodyArea() {
    final body = node.content;
    if (node.isMissing) {
      return Padding(
        padding: const EdgeInsets.all(7),
        child: Text(
          body.isEmpty ? '(空)' : body,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: AppType.body,
            color: palette.textSecondary,
            height: 1.3,
          ),
        ),
      );
    }
    final ctl = fieldController(node.id, 'content');
    if (titleOnly || ctl == null) {
      return Padding(
        padding: const EdgeInsets.all(7),
        child: Text(
          body.isEmpty ? '(空台词)' : body,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: AppType.body,
            color: body.isEmpty ? palette.textHint : palette.textSecondary,
            height: 1.3,
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(kFlowBodyPad, 3, kFlowBodyPad, 3),
      child: _BodyField(
        key: ValueKey('flowBody|${node.id}'),
        controller: ctl,
        placeholder: node.isOption ? '选项文本' : '台词内容',
        onChanged: (v) => onFieldChanged(node.id, 'content', v),
        onFocused: () => onNodeFocused?.call(node.id),
      ),
    );
  }

  /// 底部参数徽章行：对白 bg/audio/time/检定，选项 主支/支线/跳转事件。
  Widget _badgeRow() {
    final chips = <Widget>[
      if (!node.isOption) ...[
        if (node.bgId.isNotEmpty)
          _badge(Icons.landscape, node.bgId, palette.flowBg),
        if (node.audioId.isNotEmpty)
          _badge(Icons.music_note, node.audioId, palette.flowAudio),
        if (node.timeStr.isNotEmpty)
          _badge(Icons.schedule, node.timeStr, palette.flowTime),
        if (node.fxSummary.isNotEmpty)
          _badge(Icons.auto_fix_high, node.fxSummary, palette.flowFx),
        if (node.hasCheck)
          _badge(Icons.fact_check, '检定', palette.flowCheck),
      ] else ...[
        if (node.mainCount.isNotEmpty)
          _badge(
            Icons.call_made,
            '主${node.mainCount}',
            palette.flowAudio,
          ),
        if (node.sideCount.isNotEmpty)
          _badge(
            Icons.call_split,
            '支${node.sideCount}',
            palette.flowCheck,
          ),
        if (node.nextEvtId.isNotEmpty)
          _badge(Icons.logout, '→${node.nextEvtId}', palette.flowTime),
      ],
    ];
    return Container(
      height: 16,
      padding: EdgeInsets.symmetric(horizontal: 6),
      // 徽章无收缩时 5 个（bg+audio+time+特效+检定）在 200px 卡上必溢出
      // （RenderFlex overflow 黄黑条）；Flexible + 文本省略号兜住
      child: Row(
        children: [
          for (var i = 0; i < chips.length; i++) ...[
            if (i > 0) SizedBox(width: AppSpace.xs),
            Flexible(child: chips[i]),
          ],
        ],
      ),
    );
  }

  Widget _badge(IconData icon, String text, Color color) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: AppSpace.xs, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(AppRadius.xxs),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 8, color: color),
          SizedBox(width: AppSpace.xxs),
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: AppType.badge,
                color: color,
                fontWeight: FontWeight.w600,
                height: 1.1,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 标题条说话人输入：回车或失焦时把文本交给宿主匹配人物 id。
///
/// 只在失焦时提交（回车仅负责收起键盘/取消焦点），避免回车与失焦各触发
/// 一次匹配、弹出两个对话框。
class _SpeakerField extends StatefulWidget {
  const _SpeakerField({
    super.key,
    required this.controller,
    required this.placeholder,
    required this.onSubmitted,
    this.onFocused,
  });

  final TextEditingController controller;
  final String placeholder;
  final ValueChanged<String> onSubmitted;
  final VoidCallback? onFocused;

  @override
  State<_SpeakerField> createState() => _SpeakerFieldState();
}

class _SpeakerFieldState extends State<_SpeakerField> {
  final FocusNode _focus = FocusNode(debugLabel: 'flowSpeakerField');

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocusChange);
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocusChange);
    _focus.dispose();
    super.dispose();
  }

  void _onFocusChange() {
    if (_focus.hasFocus) {
      widget.onFocused?.call();
    } else {
      widget.onSubmitted(widget.controller.text);
    }
  }

  @override
  Widget build(BuildContext context) {
    return fluent.TextBox(
      controller: widget.controller,
      focusNode: _focus,
      maxLines: 1,
      placeholder: widget.placeholder,
      style: TextStyle(
        fontSize: AppType.title,
        fontWeight: FontWeight.w600,
        color: palette.textHigh,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      onSubmitted: (_) => _focus.unfocus(),
    );
  }
}

/// 卡片正文输入：对白/选项文本直接用输入框编辑，随卡片高度撑满。
class _BodyField extends StatefulWidget {
  const _BodyField({
    super.key,
    required this.controller,
    required this.placeholder,
    required this.onChanged,
    this.onFocused,
  });

  final TextEditingController controller;
  final String placeholder;
  final ValueChanged<String> onChanged;
  final VoidCallback? onFocused;

  @override
  State<_BodyField> createState() => _BodyFieldState();
}

class _BodyFieldState extends State<_BodyField> {
  final FocusNode _focus = FocusNode(debugLabel: 'flowBodyField');

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocusChange);
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocusChange);
    _focus.dispose();
    super.dispose();
  }

  void _onFocusChange() {
    if (_focus.hasFocus) widget.onFocused?.call();
  }

  @override
  Widget build(BuildContext context) {
    return fluent.TextBox(
      controller: widget.controller,
      focusNode: _focus,
      maxLines: null,
      expands: true,
      textAlignVertical: TextAlignVertical.top,
      placeholder: widget.placeholder,
      style: TextStyle(
        fontSize: AppType.body,
        color: palette.textSecondary,
        height: 1.3,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      onChanged: widget.onChanged,
    );
  }
}

/// 节点主色：卡片标题条、LOD 低档色块、小地图点共用同一套取色规则，
/// 保证同一节点在任何一档视觉一致。
Color flowNodeTint(FlowNode node) {
  if (node.cardColor.isNotEmpty) {
    final hex = int.tryParse(node.cardColor.replaceFirst('#', ''), radix: 16);
    if (hex != null) return Color(0xFF000000 | hex);
  }
  if (node.isMissing) return palette.flowMissing;
  if (node.isOption) return accentColor;
  if (node.hasCheck) return palette.flowCheck;
  if (node.isNarrator) return palette.flowTime;
  return palette.flowBg;
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
      return palette.flowAudio;
    case FlowEdgeKind.checkFail:
      return palette.flowCheck;
    case FlowEdgeKind.option:
    case FlowEdgeKind.optionMain:
    case FlowEdgeKind.optionSide:
      return accentColor;
    case FlowEdgeKind.nextEvt:
      return palette.flowTime;
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
    required this.positionsVersion,
    required this.viewport,
    required this.lodTier,
    required this.nodeH,
    required this.selection,
    required this.dashCache,
    this.marquee,
    this.wire,
    this.guides = const <FlowGuide>[],
  })  : _light = palette.isLight,
        _accent = accentColor;

  /// 全局调色板快照（亮暗/主题色）：变化时重绘选中描边/连线。
  final bool _light;
  final Color _accent;

  final FlowGraph graph;

  /// 原地修改的坐标表；身份不变，重绘判定只能看 [positionsVersion]。
  final Map<String, Offset> positions;
  final int positionsVersion;

  /// 缩放与平移：paint 里一次性 translate+scale，端点全部走世界坐标。
  final FlowViewport viewport;

  /// LOD 档。最低档画布不挂任何卡片 Widget，节点改由本 painter 批量画色块。
  final int lodTier;
  final double Function(FlowNode) nodeH;

  /// 选中集：高亮的边 + 最低档要描边的节点。整体值相等，换一次选中就重绘。
  final FlowSelection selection;

  /// 由画布 State 持有、跨帧复用的虚线路径缓存。
  final Map<String, Path> dashCache;

  /// 框选橡皮筋（屏幕坐标，画在世界变换之外）。
  final Rect? marquee;
  final (Offset, Offset, FlowEdgeKind)? wire;

  /// 拖拽吸附辅助线（世界坐标，最多一竖一横）。
  final List<FlowGuide> guides;

  double get scale => viewport.scale;
  Offset get pan => viewport.pan;

  /// 拉线末端是屏幕坐标，画布已变换到世界系，进 paint 前先换算。
  Offset _toWorld(Offset screen) => viewport.toWorld(screen);

  Offset _nodeAnchor(FlowNode n) => positions[n.id] ?? Offset.zero;

  /// 以下端口坐标一律**世界坐标**：paint 里 canvas 已 translate+scale。
  Offset _inputPort(FlowNode to) {
    final p = _nodeAnchor(to);
    return to.isMissing
        ? p + Offset(0, nodeH(to) / 2)
        : p + Offset(kFlowNodeW / 2, 0);
  }

  Offset _outputPort(FlowNode from, FlowEdge e) {
    final p = _nodeAnchor(from);
    if (from.isMissing) return _inputPort(from);
    final kinds = flowPortKinds(from);
    final n = kinds.length;
    var idx = kinds.indexOf(e.kind);
    if (idx < 0) idx = n > 0 ? n - 1 : 0;
    return p + Offset(kFlowNodeW * (idx + 1) / (n + 1), nodeH(from));
  }

  /// 复用的画笔：原先每条边每帧新建 2~3 个 Paint + 2 个 Path。
  final Paint _stroke = Paint()..style = PaintingStyle.stroke;
  final Path _path = Path();
  final Path _arrowPath = Path();
  final Paint _block = Paint();
  final Paint _blockStroke = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 2;
  final Paint _guide = Paint()..style = PaintingStyle.stroke;
  final Paint _marqueeFill = Paint()
    ..color = accentColor.withValues(alpha: 0.12);

  @override
  void paint(Canvas canvas, Size size) {
    if (kDebugMode) debugEdgePaintCount++;
    canvas.save();
    canvas.translate(pan.dx, pan.dy);
    canvas.scale(scale);
    if (lodTier == kLodBlocks) _paintBlocks(canvas, size);
    // 连线可见区裁剪（与卡片层同一套世界矩形）：曲线被控制柄包在 s/t 的
    // 水平外扩矩形内（控制柄横向 ≤200、y 不越界），箭头/线宽再留 12px 余量。
    // 卡片有裁剪而连线没有的话，视口外那几百条边仍要逐条走 cubicTo。
    final visible = viewport.worldRect(size);
    for (final e in graph.edges) {
      final from = graph.nodeById(e.from);
      final to = graph.nodeById(e.to);
      if (from == null || to == null) continue;
      final highlight = selection.edges.contains(e);
      final dashed = e.kind == FlowEdgeKind.nextEvt || to.isMissing;
      final s = _outputPort(from, e);
      final t = _inputPort(to);
      final dx = ((t.dx - s.dx).abs()).clamp(40.0, 200.0);
      if (!visible.overlaps(Rect.fromPoints(s, t).inflate(dx + 12))) continue;
      _paintEdge(
        canvas,
        s,
        t,
        _portColor(e.kind),
        selected: highlight,
        dashed: dashed,
        // dashKey 只给虚线边分配（实线不走 _dashed 缓存，key 纯属垃圾）：
        // 键里带 4px 量化端点，拖拽端点只在跨桶时才重算该条虚线路径。
        dashKey: dashed
            ? '${e.from}>${e.to}:${e.kind.index}'
                  '|${_quantize(s)}|${_quantize(t)}'
            : '',
      );
    }
    _paintGuides(canvas, size);
    final w = wire;
    if (w != null) {
      _paintEdge(
        canvas,
        w.$1,
        _toWorld(w.$2),
        _portColor(w.$3),
        selected: false,
        dashed: false,
        dashKey: 'wire',
      );
    }
    canvas.restore();
    _paintMarquee(canvas);
  }

  /// 框选橡皮筋：屏幕坐标系画，线宽不随缩放变化。
  void _paintMarquee(Canvas canvas) {
    final r = marquee;
    if (r == null) return;
    _stroke
      ..strokeWidth = 1
      ..color = accentColor;
    canvas
      ..drawRect(r, _marqueeFill)
      ..drawRect(r, _stroke);
  }

  /// 最低档：卡片 Widget 全部不挂载（`fluent.TextBox`/Tooltip 不可能进
  /// CustomPaint），改由这里批量画圆角色块，位置与端口锚点同式。
  /// 吸附辅助线：只画真的对齐上的那 1~2 条，穿过整个可见世界区。
  /// 线宽除以 scale，保证任何缩放下都是 1 个屏幕像素。
  void _paintGuides(Canvas canvas, Size size) {
    final gs = guides;
    if (gs.isEmpty) return;
    final view = viewport.worldRect(size);
    _guide
      ..color = accentColor
      ..strokeWidth = 1 / scale;
    for (final g in gs) {
      if (g.vertical) {
        canvas.drawLine(
          Offset(g.at, view.top),
          Offset(g.at, view.bottom),
          _guide,
        );
      } else {
        canvas.drawLine(
          Offset(view.left, g.at),
          Offset(view.right, g.at),
          _guide,
        );
      }
    }
  }

  void _paintBlocks(Canvas canvas, Size size) {
    final visible = viewport.worldRect(size);
    for (final n in graph.nodes) {
      final p = _nodeAnchor(n);
      final r = Rect.fromLTWH(p.dx, p.dy, kFlowNodeW, nodeH(n));
      if (!visible.overlaps(r)) continue;
      _block.color = flowNodeTint(n).withValues(alpha: n.isMissing ? 0.5 : 0.9);
      canvas.drawRRect(
        RRect.fromRectAndRadius(r, const Radius.circular(AppRadius.m)),
        _block,
      );
      if (selection.nodes.contains(n.id)) {
        _blockStroke.color = palette.chipSep;
        canvas.drawRRect(
          RRect.fromRectAndRadius(r, const Radius.circular(AppRadius.m)),
          _blockStroke,
        );
      }
    }
  }

  void _paintEdge(
    Canvas canvas,
    Offset s,
    Offset t,
    Color color, {
    required bool selected,
    required bool dashed,
    required String dashKey,
  }) {
    final dx = ((t.dx - s.dx).abs()).clamp(40.0, 200.0);
    _path
      ..reset()
      ..moveTo(s.dx, s.dy)
      ..cubicTo(s.dx + dx, s.dy, t.dx - dx, t.dy, t.dx, t.dy);
    // 线宽不再乘 scale：画布变换已施加，重复乘是双重缩放。
    _stroke
      ..strokeWidth = selected ? 2.2 : 1.2
      ..color = selected ? color : color.withValues(alpha: 0.45);
    if (dashed) {
      canvas.drawPath(_dashed(dashKey, dx, s, t), _stroke);
      return;
    }
    _stroke
      ..strokeWidth = selected ? 2.4 : 1.4
      ..color = selected ? color : color.withValues(alpha: 0.6);
    canvas.drawPath(_path, _stroke);
    final ang = (t - s).direction;
    _arrowPath
      ..reset()
      ..moveTo(t.dx, t.dy)
      ..lineTo(t.dx - 9 * math.cos(ang - 0.45), t.dy - 9 * math.sin(ang - 0.45))
      ..moveTo(t.dx, t.dy)
      ..lineTo(
        t.dx - 9 * math.cos(ang + 0.45),
        t.dy - 9 * math.sin(ang + 0.45),
      );
    canvas.drawPath(_arrowPath, _stroke..strokeWidth = selected ? 2.0 : 1.2);
  }

  /// 端点量化（4px 桶）：拖拽改变端点时只有跨桶才重算该条虚线路径，桶内
  /// 相位误差 ≤4px（虚线段本身 6/5px，拖拽中不可辨，松手即精确）。这是
  /// _geometryRev 得以去掉 positionsVersion、拖拽帧不清空虚线缓存的前提。
  static String _quantize(Offset p) =>
      '${(p.dx / 4).round()}:${(p.dy / 4).round()}';

  /// 虚线化结果按几何键缓存：世界坐标下与缩放无关，平移/缩放帧可直接复用。
  /// computeMetrics/extractPath 是整批边里最贵的一步，原先每帧重算。
  /// 缓存的失效由画布 State 负责（见 StoryFlowGraphState._dashCacheFor）。
  Path _dashed(String key, double dx, Offset s, Offset t) =>
      dashCache[key] ??= _dashPath(_bezier(dx, s, t), 6, 5);

  Path _bezier(double dx, Offset s, Offset t) => Path()
    ..moveTo(s.dx, s.dy)
    ..cubicTo(s.dx + dx, s.dy, t.dx - dx, t.dy, t.dx, t.dy);

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
      // graph 由宿主缓存，身份变化即内容变化；positions 是同一个 Map 实例
      // 被原地改，只能靠 positionsVersion（旧代码里比较 positions 引用是空转）。
      old._light != _light ||
      old._accent != _accent ||
      old.graph != graph ||
      old.positionsVersion != positionsVersion ||
      old.selection != selection ||
      old.marquee != marquee ||
      old.lodTier != lodTier ||
      old.viewport != viewport ||
      old.wire != wire ||
      !listEquals(old.guides, guides);
}