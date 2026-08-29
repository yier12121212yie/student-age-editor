import 'package:flutter/material.dart';
import '../../core/motion.dart';
import '../../core/app_theme.dart';

class SectionCard extends StatefulWidget {
  const SectionCard({
    super.key,
    required this.title,
    this.desc,
    this.child,
    this.padding = const EdgeInsets.all(12),
  });

  final String title;
  final String? desc;
  final Widget? child;
  final EdgeInsetsGeometry padding;

  @override
  State<SectionCard> createState() => _SectionCardState();
}

class _SectionCardState extends State<SectionCard> {
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
          color: palette.panel,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: _hover ? palette.borderHover : palette.surface),
          boxShadow: _hover ? [BoxShadow(color: Colors.black.withValues(alpha: 0.18), blurRadius: 12, offset: const Offset(0, 4))] : [],
        ),
        transform: Matrix4.identity()..translateByDouble(0.0, _hover ? -1.0 : 0.0, 0.0, 1.0),
        padding: widget.padding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.title.isNotEmpty) ...[
              Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: palette.textHigh, fontWeight: FontWeight.w600)),
              if (widget.desc != null) ...[
                const SizedBox(height: 4),
                Text(widget.desc!, style: TextStyle(fontSize: 11, color: palette.textMuted)),
              ],
              const SizedBox(height: 8),
            ],
            if (widget.child != null) Expanded(child: widget.child!),
          ],
        ),
      ),
    );
  }
}
