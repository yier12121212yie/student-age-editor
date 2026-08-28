import 'package:flutter/material.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../../core/api_client.dart';
import '../../core/models.dart';

/// 数据诊断与一键修复侧边栏。
class BugfixPanel extends StatefulWidget {
  const BugfixPanel({super.key, required this.state});
  final AppState state;
  @override
  State<BugfixPanel> createState() => _BugfixPanelState();
}

class _BugfixPanelState extends State<BugfixPanel> {
  List<Map<String, dynamic>> _bugs = [];
  Map<String, dynamic>? _selected;
  bool _busy = false;
  String? _error;

  Future<void> _scan() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await ApiClient.instance.post('/api/bugfix/scan');
      if (!mounted) return;
      setState(() {
        _bugs = ((r as Map)['bugs'] as List? ?? [])
            .cast<Map<String, dynamic>>();
        _selected = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _fixAll() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await ApiClient.instance.post('/api/bugfix/fix');
      if (!mounted) return;
      final fixed = (r as Map)['fixed'] as int? ?? 0;
      setState(() {
        _bugs = ((r['remaining'] as List? ?? []).cast<Map<String, dynamic>>());
        _selected = null;
      });
      if (!mounted) return;
      fluent.displayInfoBar(
        context,
        builder: (ctx, close) => fluent.InfoBar(
          title: Text('修复完成'),
          content: Text('已自动修复 $fixed 处异常，剩余 ${_bugs.length} 处（多为逻辑断层，需手动处理）'),
          severity: _bugs.isEmpty
              ? fluent.InfoBarSeverity.success
              : fluent.InfoBarSeverity.warning,
        ),
      );
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _flagLabel(String flag) {
    switch (flag) {
      case 'LOGIC':
        return '逻辑断层';
      case 'ERROR':
        return '致命错误';
      case 'FIX_OPTION_1':
        return '恶性冲突';
      case 'FIX_TALK_1':
        return '恶性冲突';
      case 'RENAME_NPC':
        return '字段升级';
      case 'RENAME_COND':
        return '字段升级';
      default:
        return '格式修正';
    }
  }

  Color _flagColor(String flag) {
    if (flag == 'LOGIC' ||
        flag == 'ERROR' ||
        flag == 'FIX_OPTION_1' ||
        flag == 'FIX_TALK_1') {
      return const Color(0xFFE5484D);
    }
    return const Color(0xFFF57C00);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          height: 38,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              const Icon(
                FluentIcons.wrench_24_regular,
                size: 15,
                color: Color(0xFF6C5CE7),
              ),
              const SizedBox(width: 8),
              const Text(
                '诊断修复',
                style: TextStyle(
                  fontSize: 12,
                  color: Color(0xFF9B9BA3),
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  onTap: _busy ? null : _scan,
                  child: Tooltip(
                    message: '深度扫描',
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: _busy
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(
                              FluentIcons.scan_camera_24_regular,
                              size: 14,
                              color: Color(0xFF8B8B93),
                            ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1, color: Color(0xFF2A2A2E)),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              _error!,
              style: const TextStyle(fontSize: 12, color: Color(0xFFE5484D)),
            ),
          ),
        Expanded(
          child: _bugs.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        FluentIcons.shield_checkmark_24_regular,
                        size: 36,
                        color: Color(0xFF3A3A42),
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        '扫描 Mod 数据结构异常\n（引用断层 / 字典越界 / 格式错误）',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 12,
                          color: Color(0xFF6E6E76),
                        ),
                      ),
                      const SizedBox(height: 10),
                      fluent.Button(
                        onPressed: _busy ? null : _scan,
                        child: Text(_busy ? '扫描中…' : '开始扫描'),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  itemCount: _bugs.length,
                  itemBuilder: (context, i) {
                    final bug = _bugs[i];
                    final flag = bug['flag'] as String? ?? '';
                    final cfg = bug['cfg'] as String? ?? '';
                    final id = bug['id'] as String? ?? '';
                    final key = bug['key'] as String? ?? '';
                    final desc = bug['desc'] as String? ?? '';
                    final selected = _selected == bug;
                    return Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      child: MouseRegion(
                        cursor: SystemMouseCursors.click,
                        child: GestureDetector(
                          onTap: () => setState(() => _selected = bug),
                          child: Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: selected
                                  ? const Color(0xFF2B2B31)
                                  : const Color(0xFF1F1F24),
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(
                                color: selected
                                    ? const Color(0xFF6C5CE7)
                                    : const Color(0xFF2A2A2E),
                              ),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 5,
                                        vertical: 1,
                                      ),
                                      decoration: BoxDecoration(
                                        color: _flagColor(flag)
                                            .withValues(alpha: 0.15),
                                        borderRadius: BorderRadius.circular(3),
                                      ),
                                      child: Text(
                                        _flagLabel(flag),
                                        style: TextStyle(
                                          fontSize: 10,
                                          color: _flagColor(flag),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    Expanded(
                                      child: Text(
                                        '$cfg → $id',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontSize: 12,
                                          color: Color(0xFFD4D4D8),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                if (selected) ...[
                                  const SizedBox(height: 6),
                                  Text(
                                    '属性：$key',
                                    style: const TextStyle(
                                      fontSize: 11,
                                      color: Color(0xFF9B9BA3),
                                    ),
                                  ),
                                  const SizedBox(height: 3),
                                  Text(
                                    desc,
                                    style: const TextStyle(
                                      fontSize: 11,
                                      color: Color(0xFFB4B4BC),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
        ),
        if (_bugs.isNotEmpty)
          Padding(
            padding: const EdgeInsets.all(8),
            child: fluent.FilledButton(
              onPressed: _busy ? null : _fixAll,
              style: fluent.ButtonStyle(
                backgroundColor: WidgetStatePropertyAll(
                  const Color(0xFFE8890C),
                ),
                foregroundColor: const WidgetStatePropertyAll(Colors.white),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(FluentIcons.wand_24_regular, size: 14),
                  const SizedBox(width: 6),
                  Text('一键修复全部异常（${_bugs.length}）'),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
