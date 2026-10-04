/// ID 引用浏览对话框（M1）：「ID · 内容预览」候选的统一挑选入口。
///
/// 与 `_FieldInput` 里既有的「从列表选择」互补：本对话框承载**有序**语义——
/// 多选时顶部「已选」区按写回顺序排列，可 ◀ ▶ 移序、✕ 移除（跳转/选项数组
/// 的顺序即游戏行为顺序）；单选点行即返回。音频候选（audition=true）每行
/// 带试听按钮。缩略图类字段不从这里走（role_picker / image_asset_picker
/// 已有专属浏览面板）。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;

import '../../core/app_theme.dart';
import 'visual_fields.dart';
import '../../core/app_dialogs.dart';

/// 打开浏览对话框。返回选中的 ID 列表（有序）；取消返回 null。
Future<List<String>?> showIdBrowseDialog(
  BuildContext context, {
  required String title,
  required List<(String, String)> options,
  required bool multi,
  List<String> initialSelected = const [],
  bool audition = false,
}) {
  return fluent.showDialog<List<String>>(
    context: context,
    builder: (ctx) => _IdBrowseDialog(
      title: title,
      options: options,
      multi: multi,
      initialSelected: initialSelected,
      audition: audition,
    ),
  );
}

class _IdBrowseDialog extends StatefulWidget {
  const _IdBrowseDialog({
    required this.title,
    required this.options,
    required this.multi,
    required this.initialSelected,
    required this.audition,
  });

  final String title;
  final List<(String, String)> options;
  final bool multi;
  final List<String> initialSelected;
  final bool audition;

  @override
  State<_IdBrowseDialog> createState() => _IdBrowseDialogState();
}

class _IdBrowseDialogState extends State<_IdBrowseDialog> {
  final TextEditingController _queryCtrl = TextEditingController();

  /// 已选 ID（有序）：数组字段的顺序即语义顺序，勾选只追加、移序手动调。
  late final List<String> _ordered = [...widget.initialSelected];

  /// 输入防抖：过滤是对全量候选的线性扫描 + 整表重建，逐字符即时过滤在
  /// 长列表下会卡输入法，停顿 200ms 后才应用过滤词。
  Timer? _debounce;

  /// id→name 映射缓存：每次 build 重建 Map 是 O(候选数)，勾选/移序触发的
  /// setState 不该重复付这笔。失效判据用数据源 identity + 长度（在 getter
  /// 里每次核对，最稳——即使调用方换列表或原地增删也不会读到陈旧缓存）。
  Map<String, String>? _nameCache;
  List<(String, String)>? _nameCacheSource;

  /// 过滤结果缓存：同上，勾选/移序触发的 setState 直接复用上次扫描结果。
  List<(String, String)>? _filterCache;
  List<(String, String)>? _filterCacheSource;
  String _filterCacheQuery = '';

  @override
  void dispose() {
    // 防抖定时器必须随 State 释放，否则 dispose 后 setState 报错。
    _debounce?.cancel();
    _queryCtrl.dispose();
    super.dispose();
  }

  List<(String, String)> get _filtered {
    final source = widget.options;
    final q = _queryCtrl.text.trim();
    if (q.isEmpty) return source;
    if (identical(_filterCacheSource, source) &&
        _filterCacheSource!.length == source.length &&
        _filterCacheQuery == q) {
      return _filterCache!;
    }
    final result =
        source.where((o) => o.$1.contains(q) || o.$2.contains(q)).toList();
    _filterCache = result;
    _filterCacheSource = source;
    _filterCacheQuery = q;
    return result;
  }

  Map<String, String> get _nameById {
    final source = widget.options;
    if (identical(_nameCacheSource, source) &&
        _nameCacheSource!.length == source.length) {
      return _nameCache!;
    }
    final m = <String, String>{for (final (id, name) in source) id: name};
    _nameCache = m;
    _nameCacheSource = source;
    return m;
  }

  void _toggle(String id) {
    setState(() {
      if (_ordered.contains(id)) {
        _ordered.remove(id);
      } else {
        _ordered.add(id);
      }
    });
  }

  void _move(int index, int to) {
    setState(() {
      final id = _ordered.removeAt(index);
      _ordered.insert(to.clamp(0, _ordered.length), id);
    });
  }

  @override
  Widget build(BuildContext context) {
    final items = _filtered;
    final names = _nameById;
    return AppContentDialog(
      title: Text(widget.title),
      content: SizedBox(
        // 与 _IdPickerDialog 同一窄屏策略：桌面 520，窄屏贴边。
        width: math.min(520, MediaQuery.sizeOf(context).width - 72),
        height: 440,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            fluent.TextBox(
              controller: _queryCtrl,
              placeholder: '筛选 ID 或名称/预览…',
              // 防抖：输入过程中不重建列表，停顿 200ms 后再应用过滤词。
              onChanged: (_) {
                _debounce?.cancel();
                _debounce = Timer(const Duration(milliseconds: 200), () {
                  if (mounted) setState(() {});
                });
              },
            ),
            const SizedBox(height: 8),
            if (widget.multi && _ordered.isNotEmpty) ...[
              _orderedSection(names),
              const SizedBox(height: 6),
            ],
            Expanded(
              child: items.isEmpty
                  ? Center(
                      child: Text(
                        '无匹配候选',
                        style: TextStyle(fontSize: 12, color: palette.textMuted),
                      ),
                    )
                  : ListView.builder(
                      itemCount: items.length,
                      itemExtent: 36,
                      itemBuilder: (context, i) {
                        final o = items[i];
                        final selected = _ordered.contains(o.$1);
                        // fluent 对话框里无 Material 祖先：与 _IdPickerDialog
                        // 同款用不透明手势行，不用 InkWell。
                        return MouseRegion(
                          cursor: SystemMouseCursors.click,
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: widget.multi
                                ? () => _toggle(o.$1)
                                : () => Navigator.pop(context, [o.$1]),
                            child: Container(
                              color: selected ? palette.tintInfo : null,
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 8),
                              child: Row(
                                children: [
                                  if (widget.multi) ...[
                                    fluent.Checkbox(
                                      checked: selected,
                                      onChanged: (_) => _toggle(o.$1),
                                    ),
                                    const SizedBox(width: 8),
                                  ],
                                  Expanded(
                                    child: Text(
                                      o.$2.isEmpty
                                          ? o.$1
                                          : '${o.$1} · ${o.$2}',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: palette.textPrimary,
                                      ),
                                    ),
                                  ),
                                  if (widget.audition)
                                    AudioAuditionButton(audioId: o.$1),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                '共 ${widget.options.length} 项候选，已选 ${_ordered.length} 项（按写回顺序）',
                style: TextStyle(fontSize: 11, color: palette.textHint),
              ),
            ),
          ],
        ),
      ),
      actions: [
        fluent.Button(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        fluent.FilledButton(
          onPressed: _ordered.isEmpty && widget.multi
              ? null
              : () => Navigator.pop(context, [..._ordered]),
          child: const Text('确定'),
        ),
      ],
    );
  }

  /// 有序已选区：行 = 序号 + id·名称 + ◀ ▶ ✕。
  Widget _orderedSection(Map<String, String> names) {
    return Container(
      constraints: const BoxConstraints(maxHeight: 140),
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: palette.border),
      ),
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: SingleChildScrollView(
        child: Column(
          children: [
            for (var i = 0; i < _ordered.length; i++)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
                child: Row(
                  children: [
                    SizedBox(
                      width: 22,
                      child: Text(
                        '${i + 1}.',
                        style: TextStyle(fontSize: 11, color: palette.textMuted),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        _label(_ordered[i], names),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                    _miniBtn('◀', i > 0, () => _move(i, i - 1)),
                    _miniBtn('▶', i < _ordered.length - 1, () => _move(i, i + 1)),
                    _miniBtn('✕', true, () => setState(() => _ordered.removeAt(i))),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  String _label(String id, Map<String, String> names) {
    final name = names[id];
    return name == null || name.isEmpty ? id : '$id · $name';
  }

  Widget _miniBtn(String label, bool enabled, VoidCallback onTap) {
    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: enabled ? palette.textSecondary : palette.iconDisabled,
          ),
        ),
      ),
    );
  }
}
