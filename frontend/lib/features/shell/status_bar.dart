import 'package:flutter/material.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import '../../core/models.dart';
import '../../core/ui_mode.dart';
import '../../core/motion.dart';
import '../../core/app_theme.dart';

class StatusBar extends StatelessWidget {
  const StatusBar({
    super.key,
    required this.state,
    required this.onToggleAi,
    this.uiMode,
    this.onUiModeChanged,
  });
  final AppState state;
  final VoidCallback onToggleAi;
  final UiMode? uiMode;
  final ValueChanged<UiMode>? onUiModeChanged;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) => Container(
        // 只约束最小高度：系统字体放大时允许自然变高，避免纵向溢出
        constraints: const BoxConstraints(minHeight: 26),
        color: palette.bgDeep,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          physics: const ClampingScrollPhysics(),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(width: 10),
              Icon(FluentIcons.branch_fork_24_regular, size: 13, color: palette.textMuted),
              const SizedBox(width: 6),
              _text('主分支'),
              const SizedBox(width: 14),
              Icon(FluentIcons.arrow_sync_24_regular, size: 13, color: palette.textMuted),
              const SizedBox(width: 6),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 240),
                child: AnimatedSwitcher(
                  duration: AppMotion.fast,
                  child: Text(
                    '模组: ${state.modName}',
                    key: ValueKey(state.modName),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: palette.textSecondary),
                  ),
                ),
              ),
              const SizedBox(width: 16),
              AnimatedSwitcher(
                duration: AppMotion.normal,
                child: state.backendOnline
                    ? const PulseDot(key: ValueKey('online'), color: Color(0xFF4CAF50), size: 8)
                    : Container(
                        key: const ValueKey('offline'),
                        width: 8,
                        height: 8,
                        decoration: const BoxDecoration(shape: BoxShape.circle, color: Color(0xFFE53935)),
                      ),
              ),
              const SizedBox(width: 6),
              AnimatedSwitcher(
                duration: AppMotion.fast,
                child: Text(
                  state.backendOnline ? '本地服务在线' : '本地服务离线',
                  key: ValueKey(state.backendOnline),
                  style: TextStyle(fontSize: 12, color: palette.textSecondary),
                ),
              ),
              const SizedBox(width: 14),
              _AnimatedText(text: 'AA: '),
              const SizedBox(width: 14),
              if (uiMode != null && onUiModeChanged != null)
                _HoverButton(
                  onTap: () => onUiModeChanged!(uiMode!.nextCycle()),
                  child: Row(
                    children: [
                      AnimatedSwitcher(
                        duration: AppMotion.fast,
                        transitionBuilder: (c, a) => RotationTransition(turns: a, child: c),
                        child: Icon(
                            key: ValueKey(uiMode),
                            _nextModeIcon(uiMode!.nextCycle()),
                            size: 13,
                            color: palette.textMuted),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        '切换${uiMode!.nextCycle().label}布局',
                        style: TextStyle(fontSize: 12, color: palette.textMid),
                      ),
                      const SizedBox(width: 14),
                    ],
                  ),
                ),
              _HoverButton(
                onTap: onToggleAi,
                child: Row(
                  children: [
                    Icon(FluentIcons.bot_24_regular, size: 13, color: palette.textMuted),
                    SizedBox(width: 6),
                    Text('AI', style: TextStyle(fontSize: 12, color: palette.textMid)),
                    SizedBox(width: 10),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _text(String s) => Text(s, style: TextStyle(fontSize: 12, color: palette.textSecondary));

  /// 目标模式的图标（循环切换按钮用）：创作=画笔，经典=列表，剧情图=流程图。
  IconData _nextModeIcon(UiMode m) => switch (m) {
        UiMode.creation => FluentIcons.paint_brush_24_regular,
        UiMode.classic => FluentIcons.list_24_regular,
        UiMode.storyFlow => FluentIcons.flow_24_regular,
      };
}

class _AnimatedText extends StatelessWidget {
  const _AnimatedText({required this.text});
  final String text;
  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: AppMotion.fast,
      transitionBuilder: (c, a) => FadeTransition(opacity: a, child: c),
      child: Text(key: ValueKey(text), text, style: TextStyle(fontSize: 12, color: palette.textSecondary)),
    );
  }
}

class _HoverButton extends StatefulWidget {
  const _HoverButton({required this.child, required this.onTap});
  final Widget child;
  final VoidCallback onTap;
  @override
  State<_HoverButton> createState() => _HoverButtonState();
}

class _HoverButtonState extends State<_HoverButton> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: AppMotion.fast,
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: _hover ? palette.card : Colors.transparent,
            borderRadius: BorderRadius.circular(4),
          ),
          child: widget.child,
        ),
      ),
    );
  }
}
