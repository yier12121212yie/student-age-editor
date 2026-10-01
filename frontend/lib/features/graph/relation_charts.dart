/// 关系图侧栏的两张手写图表（不引第三方绘图库）：
/// - [RelationLadderChart]：关系等级阶梯图——levels 按 condition 升序画台阶，
///   每级标「名称 + 阈值 (+升级消耗)」，色块用等级自身 color（非法回退 tintInfo）；
/// - [RelationKindBarsChart]：所选人关联计数条形图——按 kind 分组的边数横条。
///
/// 两者都是 CustomPaint 的哑组件：数据→几何映射写在 painter 内部，
/// 依赖注入的只有当前 [palette]；文本用 TextPainter 直绘，字号走 [AppType]。
library;

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/app_theme.dart';
import 'graph_models.dart';

/// 关系等级阶梯图。高度按台阶数自适应建议给 [preferredHeight]。
class RelationLadderChart extends StatelessWidget {
  const RelationLadderChart({
    super.key,
    required this.levels,
    this.highlightLevelIds = const {},
    this.preferredHeight = 150,
  });

  /// 已按 condition 升序的等级（[RelationsData.levelsSortedByCondition]）。
  final List<RelationLevel> levels;

  /// 当前过滤器选中的等级 id（高亮描边；空 = 不高亮）。
  final Set<String> highlightLevelIds;

  final double preferredHeight;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: preferredHeight,
      child: CustomPaint(
        painter: _LadderPainter(
          levels: levels,
          highlight: highlightLevelIds,
        ),
        size: Size.infinite,
      ),
    );
  }
}

class _LadderPainter extends CustomPainter {
  _LadderPainter({required this.levels, required this.highlight})
      : _light = palette.isLight,
        _accent = accentColor;

  final List<RelationLevel> levels;
  final Set<String> highlight;

  /// 绘制时读取的全局调色板快照：亮暗/主题色切换后必须重绘（否则旧色残留）。
  final bool _light;
  final Color _accent;

  static const double _pad = 6;
  static const double _labelH = 26; // 底部文本区高度

  @override
  void paint(Canvas canvas, Size size) {
    if (levels.isEmpty) return;
    final bodyH = math.max(10.0, size.height - _labelH - _pad);
    final maxCond = levels
        .map((l) => (l.condition ?? 0).toDouble())
        .fold(1.0, math.max);
    final stepW = (size.width - _pad * 2) / levels.length;
    final fill = Paint();
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;

    for (var i = 0; i < levels.length; i++) {
      final l = levels[i];
      final c = l.parseColor;
      // 台阶高度按 condition 归一化；0 阈值也给一个最小可见高度。
      final h = 12.0 +
          bodyH *
              ((l.condition ?? 0).clamp(0, maxCond).toDouble() /
                  (maxCond == 0 ? 1 : maxCond));
      final x = _pad + stepW * i;
      final rect = Rect.fromLTWH(
        x + 1.5,
        _pad + (bodyH - h) + 6,
        stepW - 3,
        h,
      );
      final rrect = RRect.fromRectAndCorners(
        rect,
        topLeft: const Radius.circular(AppRadius.s),
        topRight: const Radius.circular(AppRadius.s),
      );
      fill.color = c.withValues(alpha: 0.85);
      canvas.drawRRect(rrect, fill);
      line.color = highlight.contains(l.id)
          ? accentColor
          : lightenColor(c).withValues(alpha: 0.5);
      canvas.drawRRect(rrect, line);

      // 台阶下：名称 + 阈值；有余宽再加升级消耗。
      _drawLabel(canvas, l.name, rect.bottomLeft + const Offset(0, _pad * .5),
          stepW, palette.textPrimary, FontWeight.w600);
      final thr = '好感≥${l.condition ?? 0}';
      _drawLabel(
          canvas,
          l.upgradeCost > 0 ? '$thr · 升级${l.upgradeCost}' : thr,
          rect.bottomLeft + const Offset(0, _pad * .5),
          stepW,
          palette.textHint,
          FontWeight.normal,
          dy: 12);
    }
  }

  void _drawLabel(Canvas canvas, String text, Offset at, double maxW,
      Color color, FontWeight weight,
      {double dy = 0}) {
    final tp = TextPainter(
      text: TextSpan(
          text: text,
          style: TextStyle(
              fontSize: AppType.badge + 1,
              color: color,
              fontWeight: weight,
              fontFamily: 'Microsoft YaHei')),
      maxLines: 1,
      ellipsis: '…',
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: math.max(8, maxW - 2));
    tp.paint(canvas, at + Offset(1, dy));
  }

  @override
  bool shouldRepaint(covariant _LadderPainter old) =>
      old._light != _light ||
      old._accent != _accent ||
      !identical(old.levels, levels) ||
      !setEquals(old.highlight, highlight);
}

/// kind 计数横条图。[entries] 建议来自「所选人相连边」按 kind 聚合。
class RelationKindBarsChart extends StatelessWidget {
  const RelationKindBarsChart({
    super.key,
    required this.entries,
    this.rowHeight = 18,
  });

  /// (kind, 条数) 位记录。按传入顺序绘制，空表整块留白。
  final List<(String, int)> entries;
  final double rowHeight;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: math.max(rowHeight, entries.length * rowHeight + 4),
      child: CustomPaint(
        painter: _BarsPainter(entries: entries, rowHeight: rowHeight),
        size: Size.infinite,
      ),
    );
  }
}

class _BarsPainter extends CustomPainter {
  _BarsPainter({required this.entries, required this.rowHeight})
      : _light = palette.isLight,
        _accent = accentColor;

  final List<(String, int)> entries;
  final double rowHeight;
  final bool _light;
  final Color _accent;

  static const double _labelW = 64;

  @override
  void paint(Canvas canvas, Size size) {
    if (entries.isEmpty) return;
    final maxC = entries.map((e) => e.$2).fold(1, math.max);
    final barW = size.width - _labelW - 30;
    final fill = Paint();
    for (var i = 0; i < entries.length; i++) {
      final (kind, count) = entries[i];
      final y = 2 + i * rowHeight;
      final cy = y + rowHeight / 2;

      final tp = TextPainter(
        text: TextSpan(
            text: kRelationKindLabels[kind] ?? kind,
            style: TextStyle(
                fontSize: AppType.badge + 1,
                color: palette.textSecondary,
                fontFamily: 'Microsoft YaHei')),
        maxLines: 1,
        ellipsis: '…',
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: _labelW - 4);
      tp.paint(canvas, Offset(0, cy - tp.height / 2));

      final w = math.max(3.0, barW * count / maxC);
      fill.color = relationKindColor(kind).withValues(alpha: 0.85);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
            Rect.fromLTWH(_labelW, cy - 5, w, 10), const Radius.circular(3)),
        fill,
      );

      final np = TextPainter(
        text: TextSpan(
            text: '$count',
            style: TextStyle(
                fontSize: AppType.badge + 1,
                color: palette.textMuted,
                fontFamily: 'Microsoft YaHei')),
        textDirection: TextDirection.ltr,
      )..layout();
      np.paint(canvas, Offset(_labelW + w + 4, cy - np.height / 2));
    }
  }

  @override
  bool shouldRepaint(covariant _BarsPainter old) =>
      old._light != _light ||
      old._accent != _accent ||
      old.rowHeight != rowHeight ||
      old.entries.length != entries.length ||
      !_listEq(old.entries, entries);
}

bool _listEq(List<(String, int)> a, List<(String, int)> b) {
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
