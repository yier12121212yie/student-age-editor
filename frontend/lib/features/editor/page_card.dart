import 'package:flutter/material.dart';
import '../../core/motion.dart';

class PageCard extends StatefulWidget {
  const PageCard({
    super.key,
    required this.title,
    this.icon,
    this.actions,
    this.child,
    this.footer,
    this.expandChild = true,
  });

  final String title;
  final IconData? icon;
  final List<Widget>? actions;
  final Widget? child;
  final Widget? footer;
  final bool expandChild;

  @override
  State<PageCard> createState() => _PageCardState();
}

class _PageCardState extends State<PageCard> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedContainer(
        duration: AppMotion.fast,
        curve: AppMotion.easeOut,
        decoration: BoxDecoration(
          color: const Color(0xFF1E1E23),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: _hover ? const Color(0xFF3A3A42) : const Color(0xFF2E2E35)),
          boxShadow: _hover
              ? [BoxShadow(color: Colors.black.withValues(alpha: 0.22), blurRadius: 16, offset: const Offset(0, 6))]
              : [],
        ),
        transform: Matrix4.identity()..translateByDouble(0.0, _hover ? -1.0 : 0.0, 0.0, 1.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
              child: Row(
                children: [
                  if (widget.icon != null) ...[
                    TweenAnimationBuilder<double>(
                      tween: Tween(begin: 0, end: _hover ? 1 : 0),
                      duration: AppMotion.fast,
                      builder: (c, v, child) => Transform.rotate(angle: v * 0.08, child: child),
                      child: Icon(widget.icon, size: 14, color: const Color(0xFF6C5CE7)),
                    ),
                    const SizedBox(width: 6),
                  ],
                  Expanded(
                    child: Text(
                      widget.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13, color: Colors.white, fontWeight: FontWeight.w600),
                    ),
                  ),
                  if (widget.actions != null && widget.actions!.isNotEmpty) ...[
                    const SizedBox(width: 8),
                    Flexible(child: Wrap(spacing: 6, runSpacing: 4, alignment: WrapAlignment.end, children: widget.actions!)),
                  ],
                ],
              ),
            ),
            if (widget.child != null) widget.expandChild ? Expanded(child: widget.child!) : widget.child!,
            if (widget.footer != null) Padding(padding: const EdgeInsets.all(10), child: widget.footer!),
          ],
        ),
      ),
    );
  }
}
