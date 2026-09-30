import 'package:flutter/material.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../../core/app_theme.dart';
import '../../core/models.dart';
import '../../core/motion.dart';
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
    Widget panel = AiPanel(
      state: state,
      controller: shell.chatControllerFor(state),
      settings: shell.settingsLoaded ? shell.aiSettings : AiSettings(),
      onChanged: shell.setAiSettings,
      onOpenSettings: onOpenSettings,
    );
    if (panelBackground != null) {
      panel = ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: ColoredBox(color: panelBackground!, child: panel),
      );
    }
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
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

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
    return AnimatedBuilder(
      animation: _c,
      builder: (context, child) =>
          Opacity(opacity: 0.35 + 0.65 * _c.value, child: child),
      child: dot,
    );
  }
}
