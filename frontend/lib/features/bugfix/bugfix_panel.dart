import 'package:flutter/material.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../../core/api_client.dart';
import '../../core/models.dart';
import '../../core/app_theme.dart';

/// 编译级 Mod 语义诊断与一键修复中心 (Diagnostic Center)
class BugfixPanel extends StatefulWidget {
  const BugfixPanel({super.key, required this.state});
  final AppState state;
  @override
  State<BugfixPanel> createState() => _BugfixPanelState();
}

class _BugfixPanelState extends State<BugfixPanel> {
  List<Map<String, dynamic>> _issues = [];
  Map<String, dynamic>? _selected;
  bool _busy = false;
  String? _error;
  int _healthScore = 100;
  String _currentTab = '全部'; // 全部, 错误, 警告, 建议

  @override
  void initState() {
    super.initState();
    _scan();
  }

  Future<void> _scan() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await ApiClient.instance.post('/api/linter/diagnose');
      if (!mounted) return;
      if (r is Map) {
        setState(() {
          _issues = (r['issues'] as List? ?? []).cast<Map<String, dynamic>>();
          _healthScore = r['health_score'] as int? ?? 100;
          _selected = null;
        });
      }
    } catch (e) {
      // 回退至旧 bugfix 扫描
      try {
        final fallback = await ApiClient.instance.post('/api/bugfix/scan');
        if (!mounted) return;
        final bugs = ((fallback as Map)['bugs'] as List? ?? []).cast<Map<String, dynamic>>();
        setState(() {
          _issues = bugs.map((b) => {
            'id': b['key'] ?? b['id'] ?? '',
            'severity': b['flag'] == 'ERROR' || b['flag'] == 'LOGIC' ? 'error' : 'warning',
            'table': b['cfg'] ?? '',
            'row_id': b['id'] ?? '',
            'field': b['key'] ?? '',
            'title': b['desc'] ?? '格式异常',
            'message': '${b['cfg']} 第 ${b['id']} 行 ${b['desc'] ?? ''}',
            'can_fix': true,
          }).toList();
          _healthScore = (100 - _issues.length * 10).clamp(0, 100);
          _selected = null;
        });
      } catch (err) {
        if (mounted) setState(() => _error = err.toString());
      }
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
      final r = await ApiClient.instance.post('/api/linter/quickfix', body: {'fix_all': true});
      if (!mounted) return;
      final fixed = (r as Map)['fixed_count'] as int? ?? 0;
      await _scan();
      if (!mounted) return;
      fluent.displayInfoBar(
        context,
        builder: (ctx, close) => fluent.InfoBar(
          title: const Text('安全修复完成'),
          content: Text('已自动修复 $fixed 处异常，健康分回升至 $_healthScore 分'),
          severity: _issues.isEmpty
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

  Future<void> _fixSingle(Map<String, dynamic> issue) async {
    setState(() => _busy = true);
    try {
      await ApiClient.instance.post('/api/linter/quickfix', body: {'issue': issue});
      await _scan();
      if (!mounted) return;
      fluent.displayInfoBar(
        context,
        builder: (ctx, close) => fluent.InfoBar(
          title: const Text('修复成功'),
          content: Text('已修复 ${issue['title']}'),
          severity: fluent.InfoBarSeverity.success,
        ),
      );
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  List<Map<String, dynamic>> get _filteredIssues {
    if (_currentTab == '全部') return _issues;
    if (_currentTab == '错误') return _issues.where((e) => e['severity'] == 'error').toList();
    if (_currentTab == '警告') return _issues.where((e) => e['severity'] == 'warning').toList();
    if (_currentTab == '建议') return _issues.where((e) => e['severity'] == 'info').toList();
    return _issues;
  }

  Color _severityColor(String sev) {
    if (sev == 'error') return Colors.red;
    if (sev == 'warning') return Colors.orange;
    return Colors.blue;
  }

  String _severityLabel(String sev) {
    if (sev == 'error') return '错误';
    if (sev == 'warning') return '警告';
    return '建议';
  }

  @override
  Widget build(BuildContext context) {
    
    final errorsCount = _issues.where((e) => e['severity'] == 'error').length;
    final warningsCount = _issues.where((e) => e['severity'] == 'warning').length;
    final infosCount = _issues.where((e) => e['severity'] == 'info').length;

    return Column(
      children: [
        // 顶部控制栏与健康分仪表盘
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          color: palette.panel,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(FluentIcons.stethoscope_24_regular, size: 20, color: accentColor),
                  const SizedBox(width: 8),
                  Text(
                    '语义诊断与修复中心',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: palette.textPrimary,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: Icon(FluentIcons.arrow_sync_24_regular, size: 16, color: palette.textSecondary),
                    onPressed: _busy ? null : _scan,
                  ),
                ],
              ),
              const SizedBox(height: 10),
              // 健康分卡片
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: palette.bg,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: palette.border),
                ),
                child: Row(
                  children: [
                    Stack(
                      alignment: Alignment.center,
                      children: [
                        SizedBox(
                          width: 48,
                          height: 48,
                          child: CircularProgressIndicator(
                            value: _healthScore / 100.0,
                            strokeWidth: 5,
                            backgroundColor: palette.border,
                            valueColor: AlwaysStoppedAnimation<Color>(
                              _healthScore >= 90
                                  ? Colors.green
                                  : (_healthScore >= 60 ? Colors.orange : Colors.red),
                            ),
                          ),
                        ),
                        Text(
                          '$_healthScore',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                            color: palette.textPrimary,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _healthScore >= 90
                                ? 'Mod 健康状况良好'
                                : (_healthScore >= 60 ? '存在潜在风险，建议修复' : '存在严重断链或数据冲突'),
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: palette.textPrimary,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '$errorsCount 错误  ·  $warningsCount 警告  ·  $infosCount 建议',
                            style: TextStyle(fontSize: 11, color: palette.textSecondary),
                          ),
                        ],
                      ),
                    ),
                    if (_issues.any((e) => e['can_fix'] == true))
                      fluent.FilledButton(
                        onPressed: _busy ? null : _fixAll,
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(FluentIcons.wrench_24_regular, size: 14),
                            SizedBox(width: 4),
                            Text('全部修复'),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),

        // 分类 Tab 切换
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          color: palette.bg,
          child: Row(
            children: [
              _buildTab('全部', _issues.length),
              _buildTab('错误', errorsCount),
              _buildTab('警告', warningsCount),
              _buildTab('建议', infosCount),
            ],
          ),
        ),
        Divider(height: 1, color: palette.border),

        if (_error != null)
          Container(
            padding: const EdgeInsets.all(10),
            color: Colors.red.withOpacity(0.08),
            child: Text(_error!, style: const TextStyle(fontSize: 12, color: Colors.red)),
          ),

        // 诊断问题列表
        Expanded(
          child: _filteredIssues.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(FluentIcons.shield_checkmark_24_regular, size: 42, color: Colors.green),
                      const SizedBox(height: 10),
                      Text('未发现当前分类问题', style: TextStyle(color: palette.textSecondary, fontSize: 13)),
                    ],
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(8),
                  itemCount: _filteredIssues.length,
                  itemBuilder: (context, i) {
                    final item = _filteredIssues[i];
                    final sev = item['severity'] as String? ?? 'info';
                    final table = item['table'] as String? ?? '';
                    final rowId = item['row_id'] as String? ?? '';
                    final title = item['title'] as String? ?? '';
                    final msg = item['message'] as String? ?? '';
                    final canFix = item['can_fix'] == true;
                    final isSel = _selected == item;

                    return Container(
                      margin: const EdgeInsets.only(bottom: 6),
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: isSel ? palette.hover : palette.panel,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(
                          color: isSel ? accentColor : palette.border,
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                                decoration: BoxDecoration(
                                  color: _severityColor(sev).withOpacity(0.15),
                                  borderRadius: BorderRadius.circular(3),
                                ),
                                child: Text(
                                  _severityLabel(sev),
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                    color: _severityColor(sev),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  title,
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                    color: palette.textPrimary,
                                  ),
                                ),
                              ),
                              if (canFix)
                                fluent.Button(
                                  onPressed: _busy ? null : () => _fixSingle(item),
                                  child: const Text('一键修复', style: TextStyle(fontSize: 11)),
                                ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Text(
                            msg,
                            style: TextStyle(fontSize: 11, color: palette.textSecondary),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '目标：$table · 行 ID: $rowId',
                            style: TextStyle(
                              fontSize: 10,
                              fontFamily: 'monospace',
                              color: palette.textHint,
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildTab(String label, int count) {
    final active = _currentTab == label;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: GestureDetector(
        onTap: () => setState(() => _currentTab = label),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: active ? accentColor.withOpacity(0.18) : Colors.transparent,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            '$label ($count)',
            style: TextStyle(
              fontSize: 11,
              fontWeight: active ? FontWeight.bold : FontWeight.normal,
              color: active ? accentColor : palette.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}
