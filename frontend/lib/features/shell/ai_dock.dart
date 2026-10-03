import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../../core/app_theme.dart';
import '../../core/models.dart';
import '../../core/motion.dart';
import '../../core/responsive.dart';
import '../ai/ai_panel.dart';
import '../settings/settings_page.dart';
import 'shell_state.dart';
import 'shell_widgets.dart';

/// AI 右侧停靠区（三个桌面壳共用，阶段 2 从各壳内联拷贝中提取）。
///
/// - 展开：可拖拽调宽的 AiPanel，宽度经 [ShellState.aiWidthV] 局部重建，
///   拖拽不再触发整壳重绘；
/// - 收起：不再整个消失，保留一条折叠图标条（[AiCollapsedRail]），
///   带「正在回复」「待审批」角标；
/// - 开合状态与宽度由 ShellState 持久化（冷启动恢复）。
class AiDock extends StatelessWidget {
  const AiDock({
    super.key,
    required this.state,
    required this.shell,
    this.onOpenSettings,
    this.panelBackground,
  });
  final AppState state;
  final ShellState shell;
  final VoidCallback? onOpenSettings;

  /// 非空则面板自带不透明圆角底板（经典/剧情图壳侧栏悬浮在内容之上时必须）。
  final Color? panelBackground;

  /// 折叠图标条宽度。
  static const double railWidth = 36;

  /// 面板总宽 = aiWidth + 该值；手柄命中区（ResizeHandle.hitWidth）
  /// 与面板左缘重叠，不在此宽度之外。
  static const double handleWidth = 5;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<double>(
      valueListenable: shell.aiWidthV,
      builder: (context, aiWidth, _) {
        final open = shell.aiOpen;
        return AnimatedContainer(
          duration: AppMotion.normal,
          curve: AppMotion.easeOut,
          width: open ? aiWidth + handleWidth : railWidth,
          child: AnimatedSwitcher(
            duration: AppMotion.normal,
            switchInCurve: AppMotion.easeOut,
            switchOutCurve: AppMotion.easeOut,
            transitionBuilder: (child, anim) =>
                FadeTransition(opacity: anim, child: child),
            child: open
                ? _panel(aiWidth, key: const ValueKey('ai-panel'))
                : AiCollapsedRail(
                    key: const ValueKey('ai-rail'),
                    shell: shell,
                    state: state,
                  ),
          ),
        );
      },
    );
  }

  Widget _panel(double aiWidth, {Key? key}) {
    Widget panel = _buildAiPanelBody(
      state: state,
      shell: shell,
      onOpenSettings: onOpenSettings,
      background: panelBackground,
    );
    // 宽度动画期间面板保持固定宽度、右对齐裁剪（与旧壳内联实现一致）。
    // 手柄命中区 hitWidth 与面板左缘用 Stack 叠放：若按 Row 相加，
    // 总宽会超出 aiWidth + handleWidth 定宽盒 4px 导致溢出。
    return ClipRect(
      key: key,
      child: OverflowBox(
        alignment: Alignment.centerRight,
        maxWidth: aiWidth + handleWidth,
        minWidth: aiWidth + handleWidth,
        child: Stack(
          children: [
            Positioned.fill(child: panel),
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              width: ResizeHandle.hitWidth,
              child: ResizeHandle(
                width: aiWidth,
                min: ShellState.minAiWidth,
                max: ShellState.maxAiWidth,
                defaultWidth: ShellState.defaultAiWidth,
                inverted: true,
                onChanged: shell.setAiWidth,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 共享的 AiPanel 构造（停靠 / 悬浮两种形态复用，保证行为一致）。
///
/// [background] 非空时包一层不透明圆角底板：悬浮抽屉与经典/剧情图停靠必须，
/// 否则底下的内容会透出。
Widget _buildAiPanelBody({
  required AppState state,
  required ShellState shell,
  VoidCallback? onOpenSettings,
  Color? background,
}) {
  Widget panel = AiPanel(
    state: state,
    controller: shell.chatControllerFor(state),
    settings: shell.settingsLoaded ? shell.aiSettings : AiSettings(),
    onChanged: shell.setAiSettings,
    onOpenSettings: onOpenSettings,
  );
  if (background != null) {
    panel = ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: ColoredBox(color: background, child: panel),
    );
  }
  return panel;
}

/// 自适应 AI 停靠宿主：宽布局并排停靠，紧凑布局改为悬浮抽屉。
///
/// - 宽度 ≥ [Breakpoints.compact]：`content` 与 [AiDock] 并排，AI 占据固定
///   宽度（历史行为，桌面大窗不受影响）；
/// - 宽度 < 断点：AI 改为 [AiOverlayDock] 悬浮在 `content` 右缘之上，
///   **不再占用布局宽度**，编辑区保持全宽，从根上消除「活动栏 + 侧边栏 +
///   AI 侧栏」叠加把窄 Web 窗口编辑区压成负宽 / 溢出的问题。
class AiDockHost extends StatelessWidget {
  const AiDockHost({
    super.key,
    required this.state,
    required this.shell,
    required this.content,
    this.onOpenSettings,
    this.panelBackground,
  });

  final AppState state;
  final ShellState shell;
  final Widget content;
  final VoidCallback? onOpenSettings;
  final Color? panelBackground;

  @override
  Widget build(BuildContext context) {
    // 按整窗宽度判定：低于紧凑断点（窄 Web 浏览器窗口 / 小桌面窗）才浮层化，
    // 常规桌面大窗维持并排停靠。
    final compact = isCompactWidth(context);
    if (!compact) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: content),
          AiDock(
            state: state,
            shell: shell,
            onOpenSettings: onOpenSettings,
            panelBackground: panelBackground,
          ),
        ],
      );
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        content,
        AiOverlayDock(
          state: state,
          shell: shell,
          onOpenSettings: onOpenSettings,
          panelBackground: panelBackground,
        ),
      ],
    );
  }
}

/// 紧凑布局下的 AI 悬浮抽屉：展开时覆盖内容右缘、点遮罩或折叠按钮收起。
/// 始终不占用布局宽度，因此窄窗下编辑区不会被压窄。视觉与交互尽量与
/// 停靠态保持一致：可拖拽调宽（双击复位）与同一套「正在回复 / 待审批」角标。
class AiOverlayDock extends StatelessWidget {
  const AiOverlayDock({
    super.key,
    required this.state,
    required this.shell,
    this.onOpenSettings,
    this.panelBackground,
  });

  final AppState state;
  final ShellState shell;
  final VoidCallback? onOpenSettings;
  final Color? panelBackground;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return ValueListenableBuilder<double>(
          valueListenable: shell.aiWidthV,
          builder: (context, aiWidth, _) {
            final open = shell.aiOpen;
            // 悬浮宽度不超过可用宽度的 92%，小窗下也给内容留出余地。
            final maxW = constraints.maxWidth;
            final total = maxW.isFinite
                ? math.min(aiWidth + AiDock.handleWidth, maxW * 0.92)
                : aiWidth + AiDock.handleWidth;
            return AnimatedSwitcher(
              duration: AppMotion.normal,
              switchInCurve: AppMotion.easeOut,
              switchOutCurve: AppMotion.easeOut,
              transitionBuilder: (child, anim) =>
                  FadeTransition(opacity: anim, child: child),
              child: open
                  ? _panel(aiWidth, total, key: const ValueKey('ai-overlay'))
                  : _collapsedButton(key: const ValueKey('ai-overlay-button')),
            );
          },
        );
      },
    );
  }

  Widget _panel(double aiWidth, double total, {Key? key}) {
    return Stack(
      key: key,
      children: [
        // 遮罩：点空白处收起，内容恢复完全可交互。
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => shell.setAiOpen(false),
            child: ColoredBox(color: palette.scrim),
          ),
        ),
        Positioned(
          right: 0,
          top: 0,
          bottom: 0,
          width: total,
          child: Stack(
            children: [
              Positioned.fill(
                child: _buildAiPanelBody(
                  state: state,
                  shell: shell,
                  onOpenSettings: onOpenSettings,
                  // 悬浮在内容之上：必须自带不透明底板。
                  background: panelBackground ?? palette.panel,
                ),
              ),
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                width: ResizeHandle.hitWidth,
                child: ResizeHandle(
                  width: aiWidth,
                  min: ShellState.minAiWidth,
                  max: ShellState.maxAiWidth,
                  defaultWidth: ShellState.defaultAiWidth,
                  inverted: true,
                  onChanged: shell.setAiWidth,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _collapsedButton({Key? key}) {
    return Stack(
      key: key,
      children: [
        Positioned(
          right: 14,
          bottom: 16,
          child: _AiOverlayToggle(shell: shell, state: state),
        ),
      ],
    );
  }
}

/// 紧凑布局收起态的右下角悬浮按钮：点击展开；角标语义同 [AiCollapsedRail]
/// （待审批优先于正在回复）。
class _AiOverlayToggle extends StatelessWidget {
  const _AiOverlayToggle({required this.shell, required this.state});

  final ShellState shell;
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final chat = shell.chatControllerFor(state);
    return ListenableBuilder(
      listenable: chat,
      builder: (context, _) {
        final busy = chat.busy;
        final pending = chat.hasPendingPrompt;
        final tip = pending
            ? 'AI 助手（等待你审批）· 点击展开'
            : busy
            ? 'AI 助手（正在回复…）· 点击展开'
            : '展开 AI 助手';
        return Tooltip(
          message: tip,
          child: GestureDetector(
            onTap: shell.toggleAi,
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: palette.panel,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: pending ? palette.warning : palette.border,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: palette.scrimWeak,
                      blurRadius: 10,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Stack(
                  clipBehavior: Clip.none,
                  alignment: Alignment.center,
                  children: [
                    Icon(
                      FluentIcons.bot_24_regular,
                      size: 20,
                      color: pending
                          ? palette.warning
                          : busy
                          ? accentColor
                          : palette.textSecondary,
                    ),
                    if (pending)
                      const Positioned(
                        right: 5,
                        top: 5,
                        child: _AttentionDot(kind: _DotKind.staticWarn),
                      )
                    else if (busy)
                      const Positioned(
                        right: 5,
                        top: 5,
                        child: _AttentionDot(kind: _DotKind.pulseAccent),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// AI 收起后的竖排图标条：点击展开；「正在回复」呼吸点与「待审批」警示点。
class AiCollapsedRail extends StatelessWidget {
  const AiCollapsedRail({super.key, required this.shell, required this.state});
  final ShellState shell;
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final chat = shell.chatControllerFor(state);
    return ListenableBuilder(
      listenable: chat,
      builder: (context, _) {
        final busy = chat.busy;
        final pending = chat.hasPendingPrompt;
        final tip = pending
            ? 'AI 助手（等待你审批）· 点击展开'
            : busy
            ? 'AI 助手（正在回复…）· 点击展开'
            : '展开 AI 助手';
        return Container(
          width: AiDock.railWidth,
          decoration: BoxDecoration(
            color: palette.panel,
            border: Border(left: BorderSide(color: palette.border)),
          ),
          child: Center(
            child: Tooltip(
              message: tip,
              child: GestureDetector(
                onTap: shell.toggleAi,
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: Container(
                    padding: const EdgeInsets.all(7),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(6),
                      color: pending ? palette.tintWarn : Colors.transparent,
                    ),
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Icon(
                          FluentIcons.bot_24_regular,
                          size: 18,
                          color: pending
                              ? palette.warning
                              : busy
                              ? accentColor
                              : palette.textMuted,
                        ),
                        if (pending)
                          const Positioned(
                            right: -2,
                            top: -2,
                            child: _AttentionDot(kind: _DotKind.staticWarn),
                          )
                        else if (busy)
                          const Positioned(
                            right: -2,
                            top: -2,
                            child: _AttentionDot(kind: _DotKind.pulseAccent),
                          ),
                      ],
                    ),
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

enum _DotKind { pulseAccent, staticWarn }

/// 折叠条角标：呼吸动画点（流式进行中）或实心警示点（待审批）。
class _AttentionDot extends StatefulWidget {
  const _AttentionDot({required this.kind});
  final _DotKind kind;

  @override
  State<_AttentionDot> createState() => _AttentionDotState();
}

class _AttentionDotState extends State<_AttentionDot>
    with SingleTickerProviderStateMixin, DecorativeLoopMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    attachLoop(_c, reverse: true);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.kind == _DotKind.staticWarn
        ? palette.warning
        : accentColor;
    final dot = Container(
      width: 7,
      height: 7,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
    if (widget.kind == _DotKind.staticWarn) return dot;
    // repeat(reverse) 的呼吸动画每帧标脏：边界收在这个小点自身，
    // 不把整条折叠条（乃至侧栏）拖进每帧重绘。
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, child) =>
            Opacity(opacity: 0.35 + 0.65 * _c.value, child: child),
        child: dot,
      ),
    );
  }
}
