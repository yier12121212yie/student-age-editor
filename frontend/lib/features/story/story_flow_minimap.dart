/// 剧情图小地图（阶段 7）：把节点分布与当前视口框压进一个固定尺寸的定位浮层，
/// 点击或拖过即请求宿主把画布居中到对应世界点。
///
/// 三条不可破坏的约定：
/// - 世界 → 小地图只允许**一个等比 scale**（letterbox 居中）。任何一轴单独缩放
///   都会让「点在哪、跳到哪」对不上，所以反向映射必须是它的严格逆函数；
///   映射全部抽成纯函数（[computeFlowMinimapBounds] / [computeFlowMinimapFit] /
///   [worldPointToMinimap] / [minimapPointToWorld]），由单测钉死，不靠肉眼像素。
/// - 本 app 有全局透明 Material 祖先，浮层必须自己铺不透明底色（[palette].bgDeep），
///   否则画布内容会从小地图底下透出来。
/// - 只读 [StoryFlowMinimap.viewport]、绝不写；重绘被自己的 RepaintBoundary 圈住，
///   一帧只画这一个 180×120 的盒子，不牵动画布。
library;

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../../core/app_theme.dart';
import 'story_flow_graph.dart';
import 'story_flow_models.dart';

/// 视口框用色：与画布的选中/拉线强调色同一支品牌色（不入 palette）。
const Color kFlowMinimapAccent = Color(0xFF6C5CE7);

/// 包围盒退化时占位用的最小世界尺寸，保证 scale 有限、映射仍可逆（不除零）。
const double kFlowMinimapMinExtent = 1;

/// 节点块最短边下限（小地图像素）：整图拉到很远时块会小于 1 像素，
/// 按中心对称外扩，中心不变所以「点在块中心」仍然等价于「点在世界中心」。
const double kFlowMinimapMinBlock = 2;

/// 世界包围盒 → 小地图的等比映射结果。
///
/// 与小画布同式的语义：`minimap = world·scale + origin`（等价于 FlowViewport 的
/// `screen = pan + scale·world`），反解见 [minimapPointToWorld]。
@immutable
class FlowMinimapFit {
  const FlowMinimapFit({
    required this.scale,
    required this.origin,
    required this.bounds,
    required this.area,
  });

  /// 每 1 世界像素占多少小地图像素（x/y 共用一个值，故不可能被拉伸）。
  final double scale;

  /// [scale] 之外的平移量（小地图本地坐标）。
  final Offset origin;

  /// 参与拟合的世界包围盒（节点 ∪ 当前视口）。
  final Rect bounds;

  /// 可画区域（widget 本地，已扣掉 padding）。
  final Rect area;

  @override
  bool operator ==(Object other) =>
      other is FlowMinimapFit &&
      other.scale == scale &&
      other.origin == origin &&
      other.bounds == bounds &&
      other.area == area;

  @override
  int get hashCode => Object.hash(scale, origin, bounds, area);

  @override
  String toString() =>
      'FlowMinimapFit(scale: $scale, origin: $origin, bounds: $bounds)';
}

/// 纯映射：世界点 → 小地图本地点。
Offset worldPointToMinimap(FlowMinimapFit fit, Offset world) =>
    world * fit.scale + fit.origin;

/// 纯映射：小地图本地点 → 世界点（[worldPointToMinimap] 的严格逆）。
Offset minimapPointToWorld(FlowMinimapFit fit, Offset local) =>
    (local - fit.origin) / fit.scale;

/// 纯映射：世界矩形 → 小地图矩形（等比，所以只需变换左上角 + 乘 scale）。
Rect worldRectToMinimap(FlowMinimapFit fit, Rect world) {
  final tl = worldPointToMinimap(fit, world.topLeft);
  return Rect.fromLTWH(
    tl.dx,
    tl.dy,
    world.width * fit.scale,
    world.height * fit.scale,
  );
}

/// 拟合参数：把 [worldBounds] 等比塞进 `size` 内缩 [padding] 后的方框并居中。
///
/// padding 按小地图像素计（不是世界像素）：等比映射下两者只差一个 scale 因子，
/// 用像素才能保证任何尺寸的包围盒都至少留出这条边。
FlowMinimapFit computeFlowMinimapFit({
  required Rect worldBounds,
  required Size size,
  double padding = 10,
}) {
  final area = Rect.fromLTWH(
    padding,
    padding,
    math.max(1.0, size.width - padding * 2),
    math.max(1.0, size.height - padding * 2),
  );
  final box = worldBounds.isFinite ? worldBounds : Rect.zero;
  // 退化包围盒（空图/零尺寸）按单位盒处理：直接除就是除零或 NaN。
  final bw = box.width > 0 ? box.width : kFlowMinimapMinExtent;
  final bh = box.height > 0 ? box.height : kFlowMinimapMinExtent;
  final scale = math.min(area.width / bw, area.height / bh);
  // letterbox：长边贴满，短边留白后居中 —— x/y 必须共用这个 scale。
  final origin = Offset(
    area.left + (area.width - bw * scale) / 2 - box.left * scale,
    area.top + (area.height - bh * scale) / 2 - box.top * scale,
  );
  return FlowMinimapFit(scale: scale, origin: origin, bounds: box, area: area);
}

/// 拟合用的世界包围盒：所有非缺失节点的世界足迹 ∪ 当前视口矩形。
///
/// 节点高度一律按折叠足迹 [kFlowNodeH] 近似：小地图是定位器，不镜像
/// LOD/展开态那套高度算式。[canvasSize] 为空（宿主还没测量）时不并入视口，
/// 免得把 `-pan/scale` 这个远点拖进包围盒。
Rect computeFlowMinimapBounds({
  required FlowGraph graph,
  required Map<String, Offset> positions,
  FlowViewport? viewport,
  Size canvasSize = Size.zero,
}) {
  var minX = double.infinity, minY = double.infinity;
  var maxX = double.negativeInfinity, maxY = double.negativeInfinity;
  // 只求四个标量极值：逐帧分配一份 Rect 列表是这里最容易省掉的浪费。
  void grow(double l, double t, double r, double b) {
    if (l < minX) minX = l;
    if (t < minY) minY = t;
    if (r > maxX) maxX = r;
    if (b > maxY) maxY = b;
  }

  for (final n in graph.nodes) {
    if (n.isMissing) continue;
    final p = positions[n.id] ?? Offset.zero;
    if (!p.isFinite) continue;
    grow(p.dx, p.dy, p.dx + kFlowNodeW, p.dy + kFlowNodeH);
  }
  final vp = viewport;
  if (vp != null && !canvasSize.isEmpty) {
    final r = vp.worldRect(canvasSize);
    if (r.isFinite) grow(r.left, r.top, r.right, r.bottom);
  }
  if (minX > maxX || minY > maxY) return Rect.zero;
  final box = Rect.fromLTRB(minX, minY, maxX, maxY);
  return box.isFinite ? box : Rect.zero;
}

/// 小地图重绘判定（可测纯函数，被 [_MinimapPainter.shouldRepaint] 使用）。
///
/// 比较逻辑（任一成立即需要重绘）：
/// - [oldPositionsVersion] != [positionsVersion]：positions 与画布共用同一个
///   Map，宿主**原地修改内容**（对象身份不变），identical 对它永远判不出
///   「节点被拖动了」，所以节点位置变化只能靠宿主递增的版本号上报；
/// - graph 身份变化（重建了图）；
/// - fit / viewport / canvasSize 值变化（视口或尺寸变了）。
bool flowMinimapNeedsRepaint({
  required FlowGraph oldGraph,
  required FlowGraph graph,
  required int oldPositionsVersion,
  required int positionsVersion,
  required FlowMinimapFit oldFit,
  required FlowMinimapFit fit,
  required FlowViewport oldViewport,
  required FlowViewport viewport,
  required Size oldCanvasSize,
  required Size canvasSize,
}) {
  return oldPositionsVersion != positionsVersion ||
      !identical(oldGraph, graph) ||
      oldFit != fit ||
      oldViewport != viewport ||
      oldCanvasSize != canvasSize;
}

/// 剧情图小地图。宿主放在画布之上（Stack 右下角之类），自己决定居中语义。
class StoryFlowMinimap extends StatelessWidget {
  const StoryFlowMinimap({
    super.key,
    required this.graph,
    required this.positions,
    required this.positionsVersion,
    required this.viewport,
    required this.canvasSize,
    required this.onJumpTo,
    this.width = 180,
    this.height = 120,
    this.padding = 10,
  });

  final FlowGraph graph;

  /// 世界坐标（节点左上角）。与画布共用同一个 Map，宿主**原地改内容**——
  /// Map 对象身份不变，因此不能拿它做重绘判定；节点是否动了要看宿主在
  /// 拖拽/位置变化时递增的 [positionsVersion]。
  final Map<String, Offset> positions;

  /// [positions] 的内容版本：宿主原地改 Map 不会换引用，必须在节点位置
  /// 变化时递增此值，小地图的节点块才能跟手重绘（见
  /// [flowMinimapNeedsRepaint]）。
  final int positionsVersion;

  /// 画布暴露的实时视口（只读）。
  final ValueListenable<FlowViewport> viewport;

  /// 画布自身的逻辑尺寸，用于把 [FlowViewport.worldRect] 换算成视口框。
  final Size canvasSize;

  /// 点击/拖过小地图 → 要居中到这个世界点。
  final void Function(Offset worldCenter) onJumpTo;

  final double width;
  final double height;

  /// 内容区外圈留白（小地图像素）。
  final double padding;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<FlowViewport>(
      valueListenable: viewport,
      builder: (context, vp, _) {
        final size = Size(width, height);
        final fit = computeFlowMinimapFit(
          worldBounds: computeFlowMinimapBounds(
            graph: graph,
            positions: positions,
            viewport: vp,
            canvasSize: canvasSize,
          ),
          size: size,
          padding: padding,
        );
        // 只认落在小地图盒子里的指针：父层把手势透传进来时不该凭空跳走。
        final box = Offset.zero & size;
        void jump(Offset local) {
          if (!local.isFinite || !box.contains(local)) return;
          onJumpTo(minimapPointToWorld(fit, local));
        }

        return RepaintBoundary(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: (d) => jump(d.localPosition),
            onPanStart: (d) => jump(d.localPosition),
            onPanUpdate: (d) => jump(d.localPosition),
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: Container(
                width: width,
                height: height,
                decoration: const BoxDecoration(
                  boxShadow: AppShadow.float,
                  borderRadius: BorderRadius.all(Radius.circular(AppRadius.l)),
                ),
                child: CustomPaint(
                  size: size,
                  painter: _MinimapPainter(
                    graph: graph,
                    positions: positions,
                    positionsVersion: positionsVersion,
                    fit: fit,
                    viewport: vp,
                    canvasSize: canvasSize,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 小地图绘制：不透明底板 + 节点块 + 视口框。
class _MinimapPainter extends CustomPainter {
  _MinimapPainter({
    required this.graph,
    required this.positions,
    required this.positionsVersion,
    required this.fit,
    required this.viewport,
    required this.canvasSize,
  });

  final FlowGraph graph;
  final Map<String, Offset> positions;

  /// positions 内容版本（宿主原地改 Map 不换引用，见 [flowMinimapNeedsRepaint]）。
  final int positionsVersion;
  final FlowMinimapFit fit;
  final FlowViewport viewport;
  final Size canvasSize;

  /// 复用的画笔：一次 build 一套，paint 里只改 color/strokeWidth。
  final Paint _bg = Paint();
  final Paint _block = Paint();
  final Paint _border = Paint()..style = PaintingStyle.stroke;
  final Paint _fill = Paint();
  final Paint _stroke = Paint()..style = PaintingStyle.stroke;

  @override
  void paint(Canvas canvas, Size size) {
    final panel = RRect.fromRectAndRadius(
      Offset.zero & size,
      const Radius.circular(AppRadius.l),
    );
    canvas
      ..save()
      ..clipRRect(panel)
      // 必须自铺底：全局透明 Material 祖先下，没有这一步就会透出画布内容。
      ..drawRect(Offset.zero & size, _bg..color = palette.bgDeep);
    _paintNodes(canvas);
    _paintViewport(canvas);
    canvas
      ..restore()
      ..drawRRect(panel, _border..color = palette.border);
  }

  void _paintNodes(Canvas canvas) {
    final s = fit.scale;
    final o = fit.origin;
    final area = fit.area;
    for (final n in graph.nodes) {
      if (n.isMissing) continue;
      final p = positions[n.id] ?? Offset.zero;
      var r = Rect.fromLTWH(
        p.dx * s + o.dx,
        p.dy * s + o.dy,
        kFlowNodeW * s,
        kFlowNodeH * s,
      );
      if (r.width < kFlowMinimapMinBlock || r.height < kFlowMinimapMinBlock) {
        r = Rect.fromCenter(
          center: r.center,
          width: math.max(r.width, kFlowMinimapMinBlock),
          height: math.max(r.height, kFlowMinimapMinBlock),
        );
      }
      // 就地求交裁剪（不用 Rect.overlaps：它对所有边都取严格不等，
      // 贴边的块会被误裁）；越界的由 clipRRect 兜住。
      if (r.right < area.left ||
          r.left > area.right ||
          r.bottom < area.top ||
          r.top > area.bottom) {
        continue;
      }
      _block.color = flowNodeTint(n).withValues(alpha: 0.9);
      canvas.drawRRect(
        RRect.fromRectAndRadius(r, const Radius.circular(AppRadius.xs)),
        _block,
      );
    }
  }

  void _paintViewport(Canvas canvas) {
    if (canvasSize.isEmpty) return;
    final area = fit.area;
    final v = worldRectToMinimap(fit, viewport.worldRect(canvasSize));
    if (!v.isFinite) return;
    // 只裁**画出来**的矩形，不裁语义映射：缩得很小或平移出图外时框会溢出，
    // 但点在任何位置仍要还原成它真正代表的那个世界点。
    final box = Rect.fromLTRB(
      math.max(area.left, v.left),
      math.max(area.top, v.top),
      math.min(area.right, v.right),
      math.min(area.bottom, v.bottom),
    );
    if (box.width <= 0 || box.height <= 0) return;
    // 视口已盖住大半个区域时换中性色并减淡，否则整块强调色会糊掉节点。
    final big = box.width * box.height > 0.35 * area.width * area.height;
    final color = big ? palette.textSecondary : kFlowMinimapAccent;
    canvas
      ..drawRect(box, _fill..color = color.withValues(alpha: big ? 0.06 : 0.16))
      ..drawRect(box, _stroke..color = color.withValues(alpha: 0.95));
  }

  @override
  bool shouldRepaint(covariant _MinimapPainter old) => flowMinimapNeedsRepaint(
    oldGraph: old.graph,
    graph: graph,
    oldPositionsVersion: old.positionsVersion,
    positionsVersion: positionsVersion,
    oldFit: old.fit,
    fit: fit,
    oldViewport: old.viewport,
    viewport: viewport,
    oldCanvasSize: old.canvasSize,
    canvasSize: canvasSize,
  );
}
