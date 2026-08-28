import 'package:flutter/material.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import '../../core/models.dart';
import '../../core/ui_mode.dart';
import '../../core/motion.dart';

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
        color: const Color(0xFF1E1E22),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          physics: const ClampingScrollPhysics(),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(width: 10),
              const Icon(FluentIcons.branch_fork_24_regular, size: 13, color: Color(0xFF8B8B93)),
              const SizedBox(width: 6),
              _text('主分支'),
              const SizedBox(width: 14),
              const Icon(FluentIcons.arrow_sync_24_regular, size: 13, color: Color(0xFF8B8B93)),
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
                    style: const TextStyle(fontSize: 12, color: Color(0xFF9B9BA3)),
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
                  style: const TextStyle(fontSize: 12, color: Color(0xFF9B9BA3)),
                ),
              ),
              const SizedBox(width: 14),
              _AnimatedText(text: 'AA: '),
              const SizedBox(width: 14),
              if (uiMode != null && onUiModeChanged != null)
                _HoverButton(
                  onTap: () => onUiModeChanged!(uiMode == UiMode.creation ? UiMode.classic : UiMode.creation),
                  child: Row(
                    children: [
                      AnimatedSwitcher(
                        duration: AppMotion.fast,
                        transitionBuilder: (c, a) => RotationTransition(turns: a, child: c),
                        child: Icon(
                            key: ValueKey(uiMode),
                            uiMode == UiMode.creation ? FluentIcons.list_24_regular : FluentIcons.paint_brush_24_regular,
                            size: 13,
                            color: const Color(0xFF8B8B93)),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        uiMode == UiMode.creation ? '切换经典布局' : '切换创作布局',
                        style: const TextStyle(fontSize: 12, color: Color(0xFFC8C8CF)),
                      ),
                      const SizedBox(width: 14),
                    ],
                  ),
                ),
              _HoverButton(
                onTap: onToggleAi,
                child: const Row(
                  children: [
                    Icon(FluentIcons.bot_24_regular, size: 13, color: Color(0xFF8B8B93)),
                    SizedBox(width: 6),
                    Text('AI', style: TextStyle(fontSize: 12, color: Color(0xFFC8C8CF))),
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

  Widget _text(String s) => Text(s, style: const TextStyle(fontSize: 12, color: Color(0xFF9B9BA3)));
}

class _AnimatedText extends StatelessWidget {
  const _AnimatedText({required this.text});
  final String text;
  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: AppMotion.fast,
      transitionBuilder: (c, a) => FadeTransition(opacity: a, child: c),
      child: Text(key: ValueKey(text), text, style: const TextStyle(fontSize: 12, color: Color(0xFF9B9BA3))),
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
            color: _hover ? const Color(0xFF26262B) : Colors.transparent,
            borderRadius: BorderRadius.circular(4),
          ),
          child: widget.child,
        ),
      ),
    );
  }
}
