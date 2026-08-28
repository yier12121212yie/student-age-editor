import 'package:flutter/material.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../../core/api_client.dart';

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
        color: const Color(0xFF1E1E22),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF2A2A2E)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(FluentIcons.checkmark_circle_24_regular,
                  size: 15, color: Color(0xFF4CAF50)),
              const SizedBox(width: 8),
              const Text('模组清单检查',
                  style: TextStyle(fontSize: 12.5, color: Colors.white, fontWeight: FontWeight.w600)),
              const Spacer(),
              MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                    onTap: () {
                      setState(() => _loading = true);
                      _load();
                    },
                    child: const Icon(FluentIcons.arrow_sync_24_regular,
                        size: 14, color: Color(0xFF8B8B93))),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (!_selected)
            const Text('请先选择模组', style: TextStyle(fontSize: 12, color: Color(0xFF8B8B93)))
          else if (_checks.isEmpty)
            const Text('（无检查项）', style: TextStyle(fontSize: 12, color: Color(0xFF8B8B93)))
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
                      color: c['ok'] == true ? const Color(0xFF4CAF50) : const Color(0xFFE08A3C),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text('${c['label'] ?? c['key']}: ${c['detail']}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 12, color: Color(0xFFC8C8CF))),
                    ),
                  ],
                ),
              ),
        ],
      ),
    );
  }
}
