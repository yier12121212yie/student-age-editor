/// 拆解体检报告（D6）。
///
/// 场景：用户开启简易模式 / 打开一个手写代码的 mod 时，先告诉他「共 N 个码字段：
/// 可完整拆解 X、含问题 Y、无法拆解 Z」，并可点击跳到具体字段，而不是让他一个个
/// 点开才发现拆不动。
///
/// 实现复用 [BugfixPanel] 的「扫描 → 列表 → 跳转」交互（不新造一套），数据侧：
///   1. 从前端已加载的 `gameSchema` 枚举当前 mod 的码字段（判定单一真源
///      [isEffectLikeField]，与 schema 编辑器/剧情图一致）；
///   2. 逐表 GET `/api/cfg/<name>` 取行数据，抽出每个码字段的文本；
///   3. 一次 POST `/api/effect/parse_batch`（后端只读批量端点，避免 N 次往返），
///      拿到 summary + 逐项 status；
///   4. 列表按「无法拆解 → 含问题 → 正常」排序，点击经 [onJump] 交给宿主打开字段。
library;

import 'package:flutter/material.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../../core/api_client.dart';
import '../../core/app_theme.dart';
import '../../core/mobile_widgets.dart' show MobileHaptic;
import '../../core/models.dart';
import '../editor/field_meta.dart' show isEffectLikeField, effectSuggestMode;

/// 一个码字段（体检的输入单元 + 跳转目标）。
class EffectCodeField {
  EffectCodeField({
    required this.cfg,
    required this.rowId,
    required this.field,
    required this.mode,
    required this.text,
  });

  final String cfg;
  final String rowId;
  final String field;
  final String mode;
  final String text;

  String get key => '$cfg\u0000$rowId\u0000$field';
}

/// 单条体检结果（后端 parse_batch 的逐项 + 前端定位信息）。
class EffectHealthItem {
  EffectHealthItem({
    required this.field,
    required this.status,
    required this.ok,
    this.message,
    this.errorRowCount = 0,
    this.unrecognizedRows = 0,
  });

  final EffectCodeField field;
  final String status;
  final bool ok;
  final String? message;
  final int errorRowCount;
  final int unrecognizedRows;

  /// 三档：0 = 无法拆解，1 = 含问题，2 = 正常。列表按此升序（问题优先）。
  int get severityRank {
    if (status == 'ok' || status == 'empty') return 2;
    if (status == 'logic_error' || status == 'partial') return 1;
    return 0;
  }

  String get severityLabel => switch (severityRank) {
        0 => '无法拆解',
        1 => '含问题',
        _ => '可完整拆解',
      };

  Color get severityColor => switch (severityRank) {
        0 => palette.statusDanger,
        1 => palette.statusWarn,
        _ => palette.statusOk,
      };
}

/// 体检汇总。
class EffectHealthSummary {
  const EffectHealthSummary({
    required this.total,
    required this.parsed,
    required this.problem,
    required this.unparseable,
    required this.empty,
  });

  final int total;
  final int parsed;
  final int problem;
  final int unparseable;
  final int empty;

  static const emptySummary =
      EffectHealthSummary(total: 0, parsed: 0, problem: 0, unparseable: 0, empty: 0);

  factory EffectHealthSummary.fromJson(Map m) => EffectHealthSummary(
        total: (m['total'] as num?)?.toInt() ?? 0,
        parsed: (m['parsed'] as num?)?.toInt() ?? 0,
        problem: (m['problem'] as num?)?.toInt() ?? 0,
        unparseable: (m['unparseable'] as num?)?.toInt() ?? 0,
        empty: (m['empty'] as num?)?.toInt() ?? 0,
      );

  /// 一句话摘要。
  String get text => '共 $total 个码字段：可完整拆解 $parsed、'
      '含问题 $problem、无法拆解 $unparseable'
      '${empty > 0 ? '、空字段 $empty' : ''}';
}

/// 拆解体检面板。
class EffectHealthPanel extends StatefulWidget {
  const EffectHealthPanel({
    super.key,
    required this.state,
    this.onJump,
  });

  final AppState state;

  /// 点击某条结果时跳转到具体字段（宿主负责切页/滚动/高亮）。
  final void Function(EffectCodeField field)? onJump;

  @override
  State<EffectHealthPanel> createState() => _EffectHealthPanelState();
}

class _EffectHealthPanelState extends State<EffectHealthPanel> {
  EffectHealthSummary _summary = EffectHealthSummary.emptySummary;
  List<EffectHealthItem> _items = const [];
  bool _busy = false;
  bool _scanned = false;
  String? _error;

  Set<String> get _knownCfgs => widget.state.gameSchema.keys.toSet();

  /// 枚举当前 mod 里所有码字段（需要 gameSchema 已加载）。
  Future<List<EffectCodeField>> _collectFields() async {
    final schema = widget.state.gameSchema;
    if (schema.isEmpty) return const [];
    final out = <EffectCodeField>[];
    for (final entry in schema.entries) {
      final cfg = entry.key;
      final fields = entry.value;
      if (fields is! Map) continue;
      // 该表里是否有码字段？没有就跳过，避免无谓请求。
      final codeKeys = <String, String>{};
      for (final f in fields.entries) {
        final key = f.key;
        final type = f.value?.toString() ?? '';
        if (isEffectLikeField(cfg, key, type)) {
          codeKeys[key] = effectSuggestMode(cfg, key) ?? 'effect';
        }
      }
      if (codeKeys.isEmpty) continue;

      Map<String, dynamic> data;
      try {
        final r = await ApiClient.instance.get('/api/cfg/$cfg');
        if (r is! Map || r['data'] is! Map) continue;
        data = (r['data'] as Map).cast<String, dynamic>();
      } catch (_) {
        continue; // 单表拉取失败不阻断整体体检
      }
      for (final row in data.entries) {
        final v = row.value;
        if (v is! Map) continue;
        for (final ck in codeKeys.entries) {
          final raw = v[ck.key];
          final text = _textOf(raw);
          if (text.isEmpty) continue;
          out.add(EffectCodeField(
            cfg: cfg,
            rowId: row.key,
            field: ck.key,
            mode: ck.value,
            text: text,
          ));
        }
      }
    }
    return out;
  }

  /// 码字段值 → parse 用的文本。1D/2D 数组序列化成 `[..]; [..]` 风格。
  String _textOf(dynamic raw) {
    if (raw == null) return '';
    if (raw is String) return raw.trim();
    if (raw is List) {
      if (raw.isEmpty) return '';
      // 1D 数组（元素非数组）→ 单行 `[a, b]`；2D → `[..]; [..]`。
      if (raw.first is List) {
        final rows = <String>[];
        for (final r in raw) {
          if (r is List) rows.add('[${r.join(', ')}]');
        }
        return rows.join('; ');
      }
      return '[${raw.join(', ')}]';
    }
    return raw.toString().trim();
  }

  Future<void> _scan() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final fields = await _collectFields();
      if (!mounted) return;
      if (fields.isEmpty) {
        setState(() {
          _items = const [];
          _summary = EffectHealthSummary.emptySummary;
          _scanned = true;
          _busy = false;
        });
        return;
      }
      final r = await ApiClient.instance.post(
        '/api/effect/parse_batch',
        body: {
          'items': [
            for (final f in fields)
              {'id': f.key, 'text': f.text, 'mode': f.mode},
          ],
        },
      );
      if (!mounted) return;
      final byKey = {for (final f in fields) f.key: f};
      final results = ((r as Map)['results'] as List? ?? const []);
      final items = <EffectHealthItem>[];
      for (final e in results) {
        if (e is! Map) continue;
        final f = byKey[e['id']?.toString() ?? ''];
        if (f == null) continue;
        items.add(EffectHealthItem(
          field: f,
          status: e['status']?.toString() ?? 'error',
          ok: e['ok'] == true,
          message: e['message']?.toString(),
          errorRowCount: (e['error_row_count'] as num?)?.toInt() ?? 0,
          unrecognizedRows: (e['unrecognized_rows'] as num?)?.toInt() ?? 0,
        ));
      }
      items.sort((a, b) {
        final c = a.severityRank.compareTo(b.severityRank);
        if (c != 0) return c;
        return a.field.cfg.compareTo(b.field.cfg);
      });
      setState(() {
        _items = items;
        _summary = r['summary'] is Map
            ? EffectHealthSummary.fromJson((r['summary'] as Map).cast<String, dynamic>())
            : _summaryFromItems(items);
        _scanned = true;
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _busy = false;
      });
    }
  }

  EffectHealthSummary _summaryFromItems(List<EffectHealthItem> items) {
    var parsed = 0, problem = 0, unparseable = 0, empty = 0;
    for (final it in items) {
      if (it.status == 'ok') {
        parsed++;
      } else if (it.status == 'empty') {
        empty++;
      } else if (it.status == 'logic_error' || it.status == 'partial') {
        problem++;
      } else {
        unparseable++;
      }
    }
    return EffectHealthSummary(
      total: items.length,
      parsed: parsed,
      problem: problem,
      unparseable: unparseable,
      empty: empty,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _header(),
        Divider(height: 1, color: palette.border),
        if (_summary.total > 0) _summaryBar(),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(_error!,
                style: TextStyle(fontSize: 12, color: palette.statusDanger)),
          ),
        Expanded(child: _body()),
      ],
    );
  }

  Widget _header() {
    return Container(
      height: 38,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          Icon(FluentIcons.clipboard_data_bar_24_regular,
              size: 15, color: accentColor),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '拆解体检',
              style: TextStyle(
                fontSize: 12,
                color: palette.textSecondary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              onTap: _busy ? null : _scan,
              child: Tooltip(
                message: '扫描全部码字段',
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: _busy
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(FluentIcons.scan_camera_24_regular,
                          size: 14, color: palette.textMuted),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _summaryBar() {
    return Container(
      key: const ValueKey('effect-health-summary'),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      color: palette.bgDeep,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_summary.text,
              style: TextStyle(fontSize: 12, color: palette.textBody, height: 1.4)),
          const SizedBox(height: 6),
          Row(
            children: [
              _stat('可拆解', _summary.parsed, palette.statusOk),
              const SizedBox(width: 10),
              _stat('含问题', _summary.problem, palette.statusWarn),
              const SizedBox(width: 10),
              _stat('无法拆解', _summary.unparseable, palette.statusDanger),
            ],
          ),
        ],
      ),
    );
  }

  Widget _stat(String label, int n, Color color) {
    return Row(
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 4),
        Text('$label $n',
            style: TextStyle(fontSize: 11, color: palette.textSecondary)),
      ],
    );
  }

  Widget _body() {
    if (_items.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(FluentIcons.clipboard_checkmark_24_regular,
                size: 36, color: palette.borderHover),
            const SizedBox(height: 12),
            Text(
              _scanned
                  ? '没有发现码字段\n（或当前 mod 未加载数据）'
                  : '扫描当前 Mod 的全部效果 / 条件 / 指令码字段\n统计拆解情况，点击可跳到具体字段',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: palette.textHint, height: 1.5),
            ),
            const SizedBox(height: 10),
            fluent.Button(
              onPressed: _busy ? null : _scan,
              child: Text(_busy ? '扫描中…' : '开始体检'),
            ),
          ],
        ),
      );
    }
    return ListView.builder(
      itemCount: _items.length,
      itemBuilder: (context, i) {
        final it = _items[i];
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              onTap: widget.onJump == null
                  ? null
                  : () {
                      MobileHaptic.lightImpact();
                      widget.onJump!(it.field);
                    },
              child: Container(
                key: ValueKey('health-${it.field.key}'),
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: palette.bgDeep,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: palette.border),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        _chip(it.severityLabel, it.severityColor),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            '${it.field.cfg} → ${it.field.rowId} · ${it.field.field}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 12, color: palette.textPrimary),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      it.field.text,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 10.5,
                        fontFamily: 'Consolas',
                        color: palette.textSecondary,
                      ),
                    ),
                    if (it.severityRank < 2)
                      Padding(
                        padding: const EdgeInsets.only(top: 3),
                        child: Text(
                          _reason(it),
                          style: TextStyle(
                              fontSize: 10.5, color: it.severityColor),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  String _reason(EffectHealthItem it) {
    switch (it.status) {
      case 'json_error':
        return it.message ?? '括号或逗号不匹配，整段无法拆解';
      case 'logic_error':
        return '${it.errorRowCount} 行有问题，可在积木里直接改参数';
      case 'partial':
        return '${it.unrecognizedRows} 行未识别，已按原样保留';
      default:
        return it.message ?? '无法拆解';
    }
  }

  Widget _chip(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(text, style: TextStyle(fontSize: 10, color: color)),
    );
  }
}
