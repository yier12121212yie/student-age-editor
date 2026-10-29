import 'package:flutter/material.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../../core/app_theme.dart';

/// 保存前修改项记录
class SaveReviewItem {
  SaveReviewItem({
    required this.table,
    required this.rowId,
    required this.field,
    required this.oldValue,
    required this.newValue,
    this.selected = true,
  });

  final String table;
  final String rowId;
  final String field;
  final dynamic oldValue;
  final dynamic newValue;
  bool selected;
}

/// 保存前可视化差异审查面板 (Visual Save Review Drawer)
class SaveReviewDrawer extends StatefulWidget {
  const SaveReviewDrawer({
    super.key,
    required this.items,
    required this.onConfirmSave,
    this.onCancel,
  });

  final List<SaveReviewItem> items;
  final Future<void> Function(List<SaveReviewItem> selectedItems) onConfirmSave;
  final VoidCallback? onCancel;

  /// 唤起审查抽屉模态框
  static Future<bool?> show(
    BuildContext context, {
    required List<SaveReviewItem> items,
    required Future<void> Function(List<SaveReviewItem> selectedItems) onConfirmSave,
  }) {
    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => SaveReviewDrawer(
        items: items,
        onConfirmSave: onConfirmSave,
      ),
    );
  }

  @override
  State<SaveReviewDrawer> createState() => _SaveReviewDrawerState();
}

class _SaveReviewDrawerState extends State<SaveReviewDrawer> {
  late List<SaveReviewItem> _items;
  bool _saving = false;
  String _filterTable = '全部';

  @override
  void initState() {
    super.initState();
    _items = List.from(widget.items);
  }

  Set<String> get _tables => {'全部', ..._items.map((e) => e.table)};

  List<SaveReviewItem> get _filteredItems {
    if (_filterTable == '全部') return _items;
    return _items.where((e) => e.table == _filterTable).toList();
  }

  int get _selectedCount => _items.where((e) => e.selected).length;

  Future<void> _handleConfirm() async {
    final selected = _items.where((e) => e.selected).toList();
    if (selected.isEmpty) {
      fluent.displayInfoBar(
        context,
        builder: (ctx, close) => const fluent.InfoBar(
          title: Text('提示'),
          content: Text('请至少选择一项需要保存的变更'),
          severity: fluent.InfoBarSeverity.warning,
        ),
      );
      return;
    }

    setState(() => _saving = true);
    try {
      await widget.onConfirmSave(selected);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        fluent.displayInfoBar(
          context,
          builder: (ctx, close) => fluent.InfoBar(
            title: const Text('保存失败'),
            content: Text(e.toString()),
            severity: fluent.InfoBarSeverity.error,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: MediaQuery.of(context).size.height * 0.78,
      decoration: BoxDecoration(
        color: palette.panel,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.25),
            blurRadius: 18,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 顶部标题栏
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: palette.border)),
            ),
            child: Row(
              children: [
                Icon(FluentIcons.save_edit_24_regular, color: accentColor, size: 22),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '保存前可视化差异审查 (Save Review)',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: palette.textPrimary,
                        ),
                      ),
                      Text(
                        '发现 ${_items.length} 处未落盘变更，已选中 $_selectedCount 处',
                        style: TextStyle(fontSize: 12, color: palette.textSecondary),
                      ),
                    ],
                  ),
                ),
                // 全选 / 取消全选
                fluent.Button(
                  onPressed: () {
                    final allSelected = _items.every((e) => e.selected);
                    setState(() {
                      for (final it in _items) {
                        it.selected = !allSelected;
                      }
                    });
                  },
                  child: Text(_items.every((e) => e.selected) ? '取消全选' : '全部勾选'),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () => Navigator.of(context).pop(false),
                ),
              ],
            ),
          ),

          // 表格分类过滤
          if (_tables.length > 2)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              color: palette.bg,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: _tables.map((t) {
                    final isCur = t == _filterTable;
                    return Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: fluent.Button(
                        style: fluent.ButtonStyle(
                          backgroundColor: isCur
                              ? WidgetStateProperty.all(accentColor.withOpacity(0.2))
                              : null,
                        ),
                        onPressed: () => setState(() => _filterTable = t),
                        child: Text(t),
                      ),
                    );
                  }).toList(),
                ),
              ),
            ),

          // 差异明细列表
          Expanded(
            child: _filteredItems.isEmpty
                ? Center(
                    child: Text('无变更内容', style: TextStyle(color: palette.textSecondary)),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: _filteredItems.length,
                    itemBuilder: (context, i) {
                      final item = _filteredItems[i];
                      return Container(
                        margin: const EdgeInsets.only(bottom: 10),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: palette.bg,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: item.selected ? accentColor.withOpacity(0.5) : palette.border,
                          ),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Checkbox(
                              value: item.selected,
                              onChanged: (val) {
                                setState(() => item.selected = val ?? false);
                              },
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                        decoration: BoxDecoration(
                                          color: accentColor.withOpacity(0.15),
                                          borderRadius: BorderRadius.circular(4),
                                        ),
                                        child: Text(
                                          item.table,
                                          style: TextStyle(
                                            fontSize: 11,
                                            fontWeight: FontWeight.bold,
                                            color: accentColor,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Text(
                                        '行 ID: ${item.rowId}  ·  字段: ${item.field}',
                                        style: TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.w600,
                                          color: palette.textPrimary,
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 8),
                                  // 前后对比红绿差异
                                  Row(
                                    children: [
                                      Expanded(
                                        child: Container(
                                          padding: const EdgeInsets.all(6),
                                          decoration: BoxDecoration(
                                            color: Colors.red.withOpacity(0.08),
                                            borderRadius: BorderRadius.circular(4),
                                            border: Border.all(color: Colors.red.withOpacity(0.2)),
                                          ),
                                          child: Text(
                                            '- 原值: ${item.oldValue ?? "(空)"}',
                                            style: const TextStyle(
                                              fontSize: 11,
                                              color: Colors.red,
                                              fontFamily: 'monospace',
                                            ),
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Container(
                                          padding: const EdgeInsets.all(6),
                                          decoration: BoxDecoration(
                                            color: Colors.green.withOpacity(0.08),
                                            borderRadius: BorderRadius.circular(4),
                                            border: Border.all(color: Colors.green.withOpacity(0.2)),
                                          ),
                                          child: Text(
                                            '+ 新值: ${item.newValue ?? "(空)"}',
                                            style: const TextStyle(
                                              fontSize: 11,
                                              color: Colors.green,
                                              fontFamily: 'monospace',
                                            ),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),

          // 底部操作区
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: palette.border)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                fluent.Button(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('暂不保存'),
                ),
                const SizedBox(width: 12),
                fluent.FilledButton(
                  onPressed: _saving ? null : _handleConfirm,
                  child: _saving
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text('安全落盘已选 ($_selectedCount 项)'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
