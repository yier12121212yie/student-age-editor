// 工作台三栏布局的统一骨架（N2 + N8）。
//
// 背景：12 个专属工作台此前各写一套 `LayoutBuilder` + 魔法数——断点
// 980 / 1000 / 1040 / 1080 混用，左栏 188–350、右栏 262–350 各不相同；
// 且低于阈值时**直接把右栏整块丢掉**，导致窄窗（720–1000）下「设置 / 预览」
// 无法打开。
//
// [WorkbenchScaffold] 统一为：
// - 宽布局（≥ [WorkbenchLayout.sideBreakpoint]）：左栏 + 中栏 + 右栏并排；
// - 窄布局：右栏收成右侧常驻图标条（rail），点击以浮层抽屉展开，**能力不丢**；
// - 尺寸全部取自 [WorkbenchLayout] token，各工作台不再自带断点与栏宽。
//
// 左右栏以 builder 传入：builder 接收本骨架计算出的宽度，内部仍可沿用
// 既有的 `_leftPanel(double w)` / `_rightPanel(double w)`（其内部 `width: w`
// 与本骨架的 SizedBox 一致）。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import 'app_theme.dart';
import 'motion.dart';

/// 工作台布局尺寸 token（单一来源）。
class WorkbenchLayout {
  WorkbenchLayout._();

  /// 低于此宽度：右栏从并排改为收进右侧浮层抽屉（而不是直接丢弃）。
  /// 桌面壳在宽度 ≥720 时可用，因此这是常见窗口宽度下的关键阈值。
  static const double sideBreakpoint = 1000;

  /// 宽档起始宽度：达到后左/右栏切到更宽档位。
  static const double wideBreakpoint = 1320;

  static const double leftNarrow = 240;
  static const double leftWide = 300;
  static const double rightNarrow = 300;
  static const double rightWide = 340;

  /// 窄布局下右侧常驻图标条宽度。
  static const double railWidth = 36;

  static double leftWidth(double maxWidth) =>
      maxWidth >= wideBreakpoint ? leftWide : leftNarrow;

  static double rightWidth(double maxWidth) =>
      maxWidth >= wideBreakpoint ? rightWide : rightNarrow;
}

/// 工作台三栏骨架。左/右栏用 builder，宽度由骨架按 token 决定。
class WorkbenchScaffold extends StatefulWidget {
  const WorkbenchScaffold({
    super.key,
    required this.leftBuilder,
    required this.center,
    required this.rightBuilder,
    required this.rightLabel,
    this.rightIcon = FluentIcons.settings_24_regular,
  });

  /// 左栏（列表 / 目录）。参数为本骨架分配的宽度。
  final Widget Function(double width) leftBuilder;

  /// 中栏（编辑 / 预览主区）。
  final Widget center;

  /// 右栏（设置 / 概览 / 预览）。窄布局下收进浮层抽屉。
  final Widget Function(double width) rightBuilder;

  /// 右栏名称：窄布局 rail 的 tooltip 与浮层标题。
  final String rightLabel;

  final IconData rightIcon;

  @override
  State<WorkbenchScaffold> createState() => _WorkbenchScaffoldState();
}

class _WorkbenchScaffoldState extends State<WorkbenchScaffold> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: palette.bgDeep2,
      child: LayoutBuilder(
        builder: (context, box) {
          final w = box.maxWidth;
          final docked = w >= WorkbenchLayout.sideBreakpoint;
          final leftW = WorkbenchLayout.leftWidth(w);
          final rightW = WorkbenchLayout.rightWidth(w);

          if (docked) {
            return Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(width: leftW, child: widget.leftBuilder(leftW)),
                VerticalDivider(width: 1, color: palette.border),
                Expanded(child: widget.center),
                VerticalDivider(width: 1, color: palette.border),
                SizedBox(width: rightW, child: widget.rightBuilder(rightW)),
              ],
            );
          }

          // 窄布局：右栏收进浮层，宽度不超过可用宽度的 92%。
          final overlayW = math.min(rightW, w * 0.92);
          return Stack(
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(width: leftW, child: widget.leftBuilder(leftW)),
                  VerticalDivider(width: 1, color: palette.border),
                  Expanded(child: widget.center),
                  _RightRail(
                    icon: widget.rightIcon,
                    label: widget.rightLabel,
                    active: _open,
                    onTap: () => setState(() => _open = !_open),
                  ),
                ],
              ),
              if (_open) ...[
                // 遮罩：点空白处收起；给 rail 让出宽度，点 rail 也能收起。
                Positioned.fill(
                  right: WorkbenchLayout.railWidth,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => setState(() => _open = false),
                    child: ColoredBox(color: palette.scrim),
                  ),
                ),
                Positioned(
                  top: 0,
                  bottom: 0,
                  right: WorkbenchLayout.railWidth,
                  width: overlayW,
                  child: _OverlayPanel(
                    icon: widget.rightIcon,
                    label: widget.rightLabel,
                    onClose: () => setState(() => _open = false),
                    child: widget.rightBuilder(overlayW),
                  ),
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}

/// 窄布局右侧常驻图标条：点击展开/收起浮层。
class _RightRail extends StatefulWidget {
  const _RightRail({
    required this.icon,
    required this.label,
    required this.active,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  State<_RightRail> createState() => _RightRailState();
}

class _RightRailState extends State<_RightRail> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: WorkbenchLayout.railWidth,
      decoration: BoxDecoration(
        color: palette.panel,
        border: Border(left: BorderSide(color: palette.border)),
      ),
      child: Center(
        child: Tooltip(
          message: widget.active ? '收起${widget.label}' : '展开${widget.label}',
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            onEnter: (_) => setState(() => _hover = true),
            onExit: (_) => setState(() => _hover = false),
            child: GestureDetector(
              onTap: widget.onTap,
              child: AnimatedContainer(
                duration: AppMotion.fast,
                curve: AppMotion.easeOut,
                padding: const EdgeInsets.all(7),
                decoration: BoxDecoration(
                  color: widget.active
                      ? accentColor.withValues(alpha: 0.14)
                      : _hover
                          ? palette.card
                          : Colors.transparent,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Icon(
                  widget.active
                      ? FluentIcons.dismiss_24_regular
                      : widget.icon,
                  size: 18,
                  color: widget.active
                      ? accentColor
                      : _hover
                          ? palette.textPrimary
                          : palette.textMuted,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 窄布局右栏浮层：不透明底板 + 标题栏（含关闭），正文复用右栏 builder。
class _OverlayPanel extends StatelessWidget {
  const _OverlayPanel({
    required this.icon,
    required this.label,
    required this.onClose,
    required this.child,
  });

  final IconData icon;
  final String label;
  final VoidCallback onClose;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: palette.panel,
        border: Border(left: BorderSide(color: palette.border)),
        boxShadow: [
          BoxShadow(
            color: palette.scrimWeak,
            blurRadius: 18,
            offset: const Offset(-4, 0),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: 40,
            padding: const EdgeInsets.only(left: 14, right: 6),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: palette.border)),
            ),
            child: Row(
              children: [
                Icon(icon, size: 15, color: accentColor),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: palette.textHigh,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '收起',
                  icon: Icon(
                    FluentIcons.dismiss_24_regular,
                    size: 16,
                    color: palette.textSecondary,
                  ),
                  onPressed: onClose,
                ),
              ],
            ),
          ),
          Expanded(child: child),
        ],
      ),
    );
  }
}
