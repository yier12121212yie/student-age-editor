import 'package:flutter/material.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../../core/api_client.dart';
import '../../core/app_theme.dart';

/// 官方模组工具：manifest 校验卡片。
class ManifestStatusCard extends StatefulWidget {
  const ManifestStatusCard({super.key});
  @override
  State<ManifestStatusCard> createState() => _ManifestStatusCardState();
}

class _ManifestStatusCardState extends State<ManifestStatusCard> {
  List<Map<String, dynamic>> _checks = [];
  bool _selected = false;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await ApiClient.instance.get('/api/manifest/status');
      if (!mounted) return;
      setState(() {
        _checks = (r['checks'] as List? ?? []).cast<Map<String, dynamic>>();
        _selected = r['selected'] == true;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.all(12),
        child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: palette.bgDeep,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: palette.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(FluentIcons.checkmark_circle_24_regular,
                  size: 15, color: Color(0xFF4CAF50)),
              const SizedBox(width: 8),
              Text('模组清单检查',
                  style: TextStyle(fontSize: 12.5, color: palette.textHigh, fontWeight: FontWeight.w600)),
              const Spacer(),
              MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                    onTap: () {
                      setState(() => _loading = true);
                      _load();
                    },
                    child: Icon(FluentIcons.arrow_sync_24_regular,
                        size: 14, color: palette.textMuted)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (!_selected)
            Text('请先选择模组', style: TextStyle(fontSize: 12, color: palette.textMuted))
          else if (_checks.isEmpty)
            Text('（无检查项）', style: TextStyle(fontSize: 12, color: palette.textMuted))
          else
            for (final c in _checks)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  children: [
                    Icon(
                      c['ok'] == true
                          ? FluentIcons.checkmark_24_regular
                          : FluentIcons.dismiss_24_regular,
                      size: 13,
                      color: c['ok'] == true ? const Color(0xFF4CAF50) : palette.warning,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text('${c['label'] ?? c['key']}: ${c['detail']}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 12, color: palette.textMid)),
                    ),
                  ],
                ),
              ),
        ],
      ),
    );
  }
}
