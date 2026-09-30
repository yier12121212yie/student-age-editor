import 'package:flutter/material.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../../core/app_theme.dart';
import '../../core/motion.dart';
import 'auth_state.dart';

/// 状态栏用户芯片（M2.4）：托管模式下显示当前用户名 + 登出入口。
///
/// 从 [AuthState.current] 取全局态，非 hosted/未登录时整体收起为
/// 零尺寸（含尾随间距），本机/桌面模式状态栏与现状完全一致。
class AuthUserChip extends StatelessWidget {
  const AuthUserChip({super.key});

  @override
  Widget build(BuildContext context) {
    final auth = AuthState.current;
    if (auth == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: auth,
      builder: (context, _) {
        if (!auth.showUserChip) return const SizedBox.shrink();
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(FluentIcons.person_24_regular,
                size: 13, color: palette.textMuted),
            const SizedBox(width: 6),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 140),
              child: AnimatedSwitcher(
                duration: AppMotion.fast,
                child: Text(
                  auth.name ?? '',
                  key: ValueKey(auth.name),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 12, color: palette.textSecondary),
                ),
              ),
            ),
            const SizedBox(width: 8),
            _LogoutLink(onTap: auth.logout),
            const SizedBox(width: 14),
          ],
        );
      },
    );
  }
}

class _LogoutLink extends StatefulWidget {
  const _LogoutLink({required this.onTap});
  final VoidCallback onTap;
  @override
  State<_LogoutLink> createState() => _LogoutLinkState();
}

class _LogoutLinkState extends State<_LogoutLink> {
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
          child: Text('登出',
              style: TextStyle(fontSize: 12, color: palette.textMid)),
        ),
      ),
    );
  }
}
