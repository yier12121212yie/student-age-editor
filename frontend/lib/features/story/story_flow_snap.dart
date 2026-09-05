/// 剧情图拖拽吸附：把「未吸附的世界左上角」修到最近的边缘线或网格上。
///
/// 为什么单独成文件、且坚持纯函数：
/// - 画布每帧（pointer-move）都要调一次，输入最多 ~400 个 rect，任何
///   「每个候选一次分配」或嵌套遍历 others 的写法都会直接掉帧；
/// - 吸附只认几何，不认 FlowNode / Widget / Canvas：坐标语言与画布完全一致
///   （世界像素、rect 由 `positions[id]` 这个**左上角锚点** + 卡宽高推出），
///   所以这里只吃 `List<Rect>`，可见性过滤由宿主负责（见 [flowNodeRects]）。
///
/// 不变量沿用画布的 `screen = pan + scale·world`：[snapDrag] 的容差是
/// **屏幕像素**手感，内部一律先除以 scale 再比世界距离。忘了除是最典型的
/// bug——缩小后吸附会「黏」一倍。
library;

import 'dart:ui' show Offset, Rect, Size;

import 'package:flutter/foundation.dart' show immutable;

/// 标准卡片世界尺寸（与 `story_flow_graph.dart` 的 kFlowNodeW / kFlowNodeH 同值）。
///
/// 这里刻意不 import 画布文件：那是 Widget 库，纯函数层反向依赖它会让单测
/// 起不了干净的 dart:ui 环境。值若变动，两处需一起改。
const double kFlowSnapNodeW = 200;
const double kFlowSnapNodeH = 112;

/// 一条吸附辅助线。宿主在**世界变换内**画：[vertical] 为真时 [at] 是世界 x
/// （画竖线），否则是世界 y（画横线）。纯网格吸附不产生任何辅助线。
@immutable
class FlowGuide {
  const FlowGuide({required this.vertical, required this.at});

  final bool vertical;
  final double at;

  @override
  bool operator ==(Object other) =>
      other is FlowGuide && other.vertical == vertical && other.at == at;

  @override
  int get hashCode => Object.hash(vertical, at);

  @override
  String toString() => 'FlowGuide(${vertical ? '竖' : '横'} @$at)';
}

/// 一次拖拽的吸附结果：修正后的世界左上角 + 要画的辅助线（世界坐标）。
@immutable
class FlowSnap {
  const FlowSnap({required this.pos, this.guides = const <FlowGuide>[]});

  /// 吸附后的世界左上角（写回 `positions[id]` 的那个值）。
  final Offset pos;

  /// 需要画的辅助线，最多两条（一竖一横）。
  final List<FlowGuide> guides;

  bool get hasGuides => guides.isNotEmpty;

  /// 被吸附到的那条**竖线**的世界 x（无则 null）——宿主画线时用不到 List 迭代。
  double? get verticalGuideX {
    for (final g in guides) {
      if (g.vertical) return g.at;
    }
    return null;
  }

  /// 被吸附到的那条**横线**的世界 y（无则 null）。
  double? get horizontalGuideY {
    for (final g in guides) {
      if (!g.vertical) return g.at;
    }
    return null;
  }
}

/// 单节点拖拽吸附。
///
/// - [desired] 未吸附的世界左上角（= 起始位置 + 指针位移 / scale）；
/// - [self] 被拖框的世界尺寸（多选时传**包围盒**尺寸）；
/// - [others] 其余节点的世界 rect：宿主负责只给可见的、并剔掉被拖的那几个；
/// - [scale] 当前视口缩放，[tolerance] 是屏幕像素容差；
/// - [grid] 世界网格步长，边缘没命中时兜底（兜底同样只在 [tolerance] 内生效）。
///
/// 规则（按优先级）：
/// 0. 邻近带：只有**另一个轴上真的重叠**（含容差）的 rect 才参与本轴对齐。
///    没有这一步，正上方一行的节点会隔空把自己的 x 递给正在拖的卡片，
///    419 节点的事件里几乎每次拖拽都被抽走几像素。判定用未吸附的 [desired]，
///    用吸附后的值会自我反馈抖动；
/// 1. 边缘对齐优先于网格：others 每条 rect 出 left / center / right 三条线，
///    被拖框也出自己的三条线，任一对进入容差即吸附到**对方的线值减去对应的
///    自身偏移**——右边缘命中时对齐的是右边缘，不是左边缘；
/// 2. 多条候选同时进容差时取**平移最小**的那条（吸附永不过冲：返回的
///    `pos` 到 `desired` 的距离不大于任何候选到 `desired` 的距离）；
/// 3. 什么都没对上才落网格；网格吸附不返回辅助线。
FlowSnap snapDrag({
  required Offset desired,
  required Size self,
  required List<Rect> others,
  required double scale,
  double grid = 8,
  double tolerance = 6,
}) {
  // 容差是屏幕手感 → 换算成世界像素。scale 异常（0/NaN）时退化成原始容差。
  final worldTol = scale.isFinite && scale > 0 ? tolerance / scale : tolerance;
  final x = _SnapAxis(desired.dx, self.width, worldTol);
  final y = _SnapAxis(desired.dy, self.height, worldTol);

  // 邻近带：只认「另一个轴上真的重叠」的 rect。缺这一步时，正上方 3000px 的
  // 一行节点会把自己的 x 当候选递给正在拖的卡片，用户会觉得吸附在抓人。
  // 用未吸附的 desired 判定即可 —— 用吸附后的值会自我反馈抖动。
  final dragTop = desired.dy - worldTol;
  final dragBottom = desired.dy + self.height + worldTol;
  final dragLeft = desired.dx - worldTol;
  final dragRight = desired.dx + self.width + worldTol;

  // 唯一一次遍历；每条 rect 只算 3 条线、每线 3 次纯 double 比较，零分配。
  for (var i = 0; i < others.length; i++) {
    final r = others[i];
    final right = r.left + r.width;
    final bottom = r.top + r.height;
    if (r.top < dragBottom && bottom > dragTop) {
      x.consider(r.left);
      x.consider(r.left + r.width * 0.5);
      x.consider(right);
    }
    if (r.left < dragRight && right > dragLeft) {
      y.consider(r.top);
      y.consider(r.top + r.height * 0.5);
      y.consider(bottom);
    }
  }

  final xAligned = x.aligned;
  final yAligned = y.aligned;
  x.snapToGrid(grid);
  y.snapToGrid(grid);

  // 只有边缘对齐才画线；无辅助线时复用 const 空表，不产生分配。
  final List<FlowGuide> guides;
  if (xAligned) {
    guides = yAligned
        ? [
            FlowGuide(vertical: true, at: x.line),
            FlowGuide(vertical: false, at: y.line),
          ]
        : [FlowGuide(vertical: true, at: x.line)];
  } else {
    guides = yAligned
        ? [FlowGuide(vertical: false, at: y.line)]
        : const <FlowGuide>[];
  }

  return FlowSnap(pos: Offset(x.pos, y.pos), guides: guides);
}

/// 一个轴上的候选收集器：只保留「平移量绝对值最小且进入容差」的那一对。
///
/// `base` 是 desired 在该轴的左上角值，`size` 是被拖框该轴的边长。
class _SnapAxis {
  _SnapAxis(this.base, this.size, this.tol) : _pos = base;

  final double base;
  final double size;

  /// 世界像素容差（已由屏幕容差除以 scale 换算）。
  final double tol;

  double _best = double.infinity;
  double _pos;
  double _line = 0;

  /// 吸附后的左上角取值。
  double get pos => _pos;

  /// 被吸附到的目标线（世界坐标），与自身对齐线重合。
  double get line => _line;

  /// 是否接受过任何候选。在 [snapToGrid] 之前问一次即为「边缘是否对齐」。
  bool get aligned => _best != double.infinity;

  /// 目标线 [v] 分别和自身 左/中/右 三条线配对，取平移最小者。
  void consider(double v) {
    final b = base;
    final shift = v - b;
    _try(v, shift);
    _try(v, shift - size * 0.5);
    _try(v, shift - size);
  }

  /// 边缘没命中才落到网格；`grid` 非正数即关闭网格。
  ///
  /// 只量左上角即可：卡宽（200）与常用步长都是 8 的倍数，三条自身线同网格相位。
  void snapToGrid(double step) {
    if (aligned || !(step > 0)) return;
    final g = (base / step).roundToDouble() * step;
    _try(g, g - base);
  }

  void _try(double v, double shift) {
    final ad = shift < 0 ? -shift : shift;
    // NaN 安全：写成 !(a && b) 让任何非有限比较都直接落回不吸附。
    if (!(ad <= tol && ad < _best)) return;
    _best = ad;
    _pos = base + shift;
    _line = v;
  }
}

/// 用画布同一份 `positions`（世界左上角）造吸附输入，一遍线性扫完。
///
/// [exclude] 传本次被拖的节点集合（多选时是整组）；[visible] 传宿主已
/// inflate 过一个卡宽的世界可见矩形，只收可见 rect；[heightOf] 用于高度不
/// 统一的卡（缺失徽标 56 / 展开编辑器 316·276 / 低于完整档回落折叠高）。
List<Rect> flowNodeRects({
  required Map<String, Offset> positions,
  double width = kFlowSnapNodeW,
  double height = kFlowSnapNodeH,
  double Function(String id)? heightOf,
  Set<String>? exclude,
  Rect? visible,
}) {
  final out = <Rect>[];
  for (final e in positions.entries) {
    final id = e.key;
    if (exclude != null && exclude.contains(id)) continue;
    final p = e.value;
    final h = heightOf == null ? height : heightOf(id);
    if (visible != null &&
        (p.dx > visible.right ||
            p.dy > visible.bottom ||
            p.dx + width < visible.left ||
            p.dy + h < visible.top)) {
      continue;
    }
    out.add(Rect.fromLTWH(p.dx, p.dy, width, h));
  }
  return out;
}
