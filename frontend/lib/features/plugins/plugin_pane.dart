import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../../core/api_client.dart';
import '../../core/app_theme.dart';

/// 插件声明式面板渲染器：拉 GET /api/plugins/`pluginId`/panel/`panelId`，
/// 渲染 {"title", "blocks"}。支持 markdown / stats / table / form / actions 五种块。
///
/// 不自带 Scaffold：既可嵌入创作模式侧栏（SidePaneView），
/// 也可嵌入移动端 MobileSubPage（[showHeader] 置 false，头部由子页提供）。
/// 头部返回按钮通过 [onClosed] 通知壳层清除 activePluginPanel。
class PluginPane extends StatefulWidget {
  const PluginPane({
    super.key,
    required this.pluginId,
    required this.panelId,
    required this.onClosed,
    this.showHeader = true,
  });

  final String pluginId;
  final String panelId;
  final VoidCallback onClosed;
  final bool showHeader;

  @override
  State<PluginPane> createState() => _PluginPaneState();
}

class _PluginPaneState extends State<PluginPane> {
  Map<String, dynamic>? _data;
  bool _loading = false;
  String? _error;

  /// 表单字段控件状态（按字段 name 索引）。
  final Map<String, TextEditingController> _editControllers = {};
  final Map<String, bool> _checkboxValues = {};
  final Map<String, String> _selectValues = {};
  bool _submitting = false;
  bool _busyAction = false;

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  @override
  void dispose() {
    for (final c in _editControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  // ---------------- 数据 ----------------

  Future<void> _fetch() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await ApiClient.instance
          .get('/api/plugins/${widget.pluginId}/panel/${widget.panelId}');
      if (!mounted) return;
      setState(() {
        _data = r is Map ? Map<String, dynamic>.from(r) : <String, dynamic>{};
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  // ---------------- 头部 ----------------

  Widget _header() {
    final title = (_data?['title'] as String?) ?? widget.panelId;
    return Container(
      height: 38,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.onClosed,
              child: Padding(
                padding: const EdgeInsets.all(6),
                child: Icon(FluentIcons.chevron_left_24_regular,
                    size: 16, color: palette.textSecondary),
              ),
            ),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 12,
                  color: palette.textSecondary,
                  fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(width: 4),
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _loading ? null : _fetch,
              child: Padding(
                padding: const EdgeInsets.all(6),
                child: Icon(FluentIcons.arrow_sync_24_regular,
                    size: 15, color: palette.textMuted),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ---------------- 主体 ----------------

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        if (widget.showHeader) ...[
          _header(),
          Divider(height: 1, color: palette.border),
        ],
        Expanded(child: _buildBody()),
      ],
    );
  }

  Widget _buildBody() {
    if (_loading && _data == null) {
      return const Center(
        child: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (_error != null && _data == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(FluentIcons.error_circle_24_regular,
                size: 28, color: palette.statusDanger),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                '面板加载失败：$_error',
                textAlign: TextAlign.center,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: palette.textMuted),
              ),
            ),
            const SizedBox(height: 8),
            fluent.Button(onPressed: _fetch, child: const Text('重试')),
          ],
        ),
      );
    }
    final blocks = (_data?['blocks'] as List? ?? const []);
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        for (final b in blocks)
          if (b is Map) _buildBlock(Map<String, dynamic>.from(b)),
      ],
    );
  }

  Widget _buildBlock(Map<String, dynamic> block) {
    switch (block['type'] as String? ?? '') {
      case 'markdown':
        return _mdBlock(block['text'] as String? ?? '');
      case 'stats':
        return _statsBlock(block['items']);
      case 'table':
        return _tableBlock(block['columns'], block['rows']);
      case 'form':
        return _formBlock(block);
      case 'actions':
        return _actionsBlock(block['buttons']);
      default:
        return const SizedBox.shrink();
    }
  }

  // ---------------- markdown 块 ----------------

  Widget _mdBlock(String text) {
    if (text.trim().isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: MarkdownBody(
        data: text,
        selectable: true,
        styleSheet: _panelMdStyle(),
      ),
    );
  }

  // ---------------- stats 块 ----------------

  Widget _statsBlock(dynamic itemsRaw) {
    final items = itemsRaw is List ? itemsRaw.whereType<Map>().toList() : const [];
    if (items.isEmpty) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: palette.panel,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: palette.surface),
      ),
      child: Wrap(
        spacing: 16,
        runSpacing: 10,
        children: [
          for (final item in items)
            SizedBox(
              width: 120,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    (item['label'] as String? ?? '').trim(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, color: palette.textHint),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    (item['value'] as String? ?? '').trim(),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 15,
                        color: palette.textHigh,
                        fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  // ---------------- table 块 ----------------

  Widget _tableBlock(dynamic colsRaw, dynamic rowsRaw) {
    final columns = colsRaw is List
        ? colsRaw.map((e) => e?.toString() ?? '').toList()
        : <String>[];
    final rows = rowsRaw is List
        ? rowsRaw.whereType<List>().toList()
        : <List>[];
    if (columns.isEmpty && rows.isEmpty) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: palette.surface),
      ),
      clipBehavior: Clip.antiAlias,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Table(
          border: TableBorder.all(color: palette.surface),
          defaultVerticalAlignment: TableCellVerticalAlignment.middle,
          children: [
            if (columns.isNotEmpty)
              TableRow(
                decoration: BoxDecoration(color: palette.bgDeep),
                children: [
                  for (final c in columns)
                    _tableCell(Text(c.isEmpty ? ' ' : c,
                        style: TextStyle(
                            fontSize: 12,
                            color: palette.textHigh,
                            fontWeight: FontWeight.w600))),
                ],
              ),
            for (final row in rows)
              TableRow(
                children: [
                  for (var i = 0; i < row.length; i++)
                    _tableCell(Text(
                        (row[i]?.toString() ?? ' ').isEmpty
                            ? ' '
                            : row[i].toString(),
                        style: TextStyle(fontSize: 12, color: palette.textSecondary))),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _tableCell(Widget child) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: child,
    );
  }

  // ---------------- form 块 ----------------

  Widget _formBlock(Map<String, dynamic> block) {
    final fields = (block['fields'] as List? ?? const [])
        .whereType<Map>()
        .toList();
    final submit = block['submit'] is Map
        ? Map<String, dynamic>.from(block['submit'])
        : const <String, dynamic>{};
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: palette.panel,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: palette.surface),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final f in fields) _formField(Map<String, dynamic>.from(f)),
          if (submit['url'] is String &&
              (submit['url'] as String).trim().isNotEmpty) ...[
            const SizedBox(height: 4),
            fluent.FilledButton(
              onPressed: _submitting ? null : () => _submitForm(block),
              child: Text((submit['label'] as String? ?? '提交')),
            ),
          ],
        ],
      ),
    );
  }

  TextEditingController _controllerFor(String name, String def) {
    var c = _editControllers[name];
    if (c == null) {
      c = TextEditingController(text: def);
      _editControllers[name] = c;
    }
    return c;
  }

  Widget _formField(Map<String, dynamic> field) {
    final name = (field['name'] as String? ?? '').trim();
    final label = (field['label'] as String? ?? name).trim();
    final type = field['type'] as String? ?? 'text';
    final def = field['default'];
    switch (type) {
      case 'number':
        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                  style: TextStyle(fontSize: 12, color: palette.textSecondary)),
              const SizedBox(height: 4),
              TextField(
                controller: _controllerFor(name, def?.toString() ?? ''),
                keyboardType: TextInputType.number,
                style: TextStyle(fontSize: 13, color: palette.textBody),
                decoration: _inputDeco(),
              ),
            ],
          ),
        );
      case 'select':
        final options = (field['options'] as List? ?? const [])
            .map((e) => e?.toString() ?? '')
            .where((s) => s.isNotEmpty)
            .toList();
        final current = _selectValues[name] ??
            (def?.toString() ?? (options.isNotEmpty ? options.first : ''));
        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                  style: TextStyle(fontSize: 12, color: palette.textSecondary)),
              const SizedBox(height: 4),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(
                  color: palette.bgDeep,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: palette.surface),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    value: current.isEmpty || !options.contains(current)
                        ? (options.isNotEmpty ? options.first : null)
                        : current,
                    isExpanded: true,
                    isDense: true,
                    dropdownColor: palette.panel,
                    style: TextStyle(fontSize: 13, color: palette.textBody),
                    items: [
                      for (final o in options)
                        DropdownMenuItem(value: o, child: Text(o)),
                    ],
                    onChanged: options.isEmpty
                        ? null
                        : (v) {
                            if (v == null) return;
                            setState(() => _selectValues[name] = v);
                          },
                  ),
                ),
              ),
            ],
          ),
        );
      case 'checkbox':
        final val = _checkboxValues[name] ?? (def == true);
        return Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Row(
            children: [
              Checkbox(
                value: val,
                onChanged: (v) =>
                    setState(() => _checkboxValues[name] = v ?? false),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(label,
                    style:
                        TextStyle(fontSize: 12, color: palette.textSecondary)),
              ),
            ],
          ),
        );
      case 'text':
      default:
        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                  style: TextStyle(fontSize: 12, color: palette.textSecondary)),
              const SizedBox(height: 4),
              TextField(
                controller: _controllerFor(name, def?.toString() ?? ''),
                style: TextStyle(fontSize: 13, color: palette.textBody),
                decoration: _inputDeco(),
              ),
            ],
          ),
        );
    }
  }

  InputDecoration _inputDeco() => InputDecoration(
        isDense: true,
        filled: true,
        fillColor: palette.bgDeep,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: BorderSide(color: palette.surface),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: BorderSide(color: palette.surface),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: BorderSide(color: const Color(0xFF6C5CE7)),
        ),
      );

  Future<void> _submitForm(Map<String, dynamic> block) async {
    final submit = block['submit'] is Map
        ? Map<String, dynamic>.from(block['submit'])
        : const <String, dynamic>{};
    final url = (submit['url'] as String? ?? '').trim();
    if (url.isEmpty || _submitting) return;
    final values = <String, dynamic>{};
    final fields = (block['fields'] as List? ?? const [])
        .whereType<Map>()
        .toList();
    for (final fRaw in fields) {
      final f = Map<String, dynamic>.from(fRaw);
      final name = (f['name'] as String? ?? '').trim();
      if (name.isEmpty) continue;
      switch (f['type'] as String? ?? 'text') {
        case 'number':
          final raw = _controllerFor(name, '').text.trim();
          if (raw.isEmpty) {
            _showError('请填写「${f['label'] ?? name}」后再提交');
            return;
          }
          final v = num.tryParse(raw);
          if (v == null) {
            _showError('「${f['label'] ?? name}」必须是数字');
            return;
          }
          values[name] = v;
        case 'checkbox':
          values[name] = _checkboxValues[name] ?? false;
        case 'select':
          values[name] =
              _selectValues[name] ?? (f['default']?.toString() ?? '');
        case 'text':
        default:
          values[name] = _controllerFor(name, '').text;
      }
    }
    setState(() => _submitting = true);
    try {
      final r = await _request(url, method: 'POST', body: values);
      _handleActionResponse(r);
    } catch (e) {
      _showError('表单提交失败：$e');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  // ---------------- actions 块 ----------------

  Widget _actionsBlock(dynamic buttonsRaw) {
    final buttons = buttonsRaw is List
        ? buttonsRaw.whereType<Map>().toList()
        : const [];
    if (buttons.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final b in buttons)
            _actionButton(Map<String, dynamic>.from(b)),
        ],
      ),
    );
  }

  Widget _actionButton(Map<String, dynamic> btn) {
    final label = (btn['label'] as String? ?? '操作').trim();
    final url = (btn['url'] as String? ?? '').trim();
    final confirm = btn['confirm'] is String ? (btn['confirm'] as String).trim() : '';
    final body = btn['body'] is Map
        ? Map<String, dynamic>.from(btn['body'])
        : const <String, dynamic>{};
    final method = (btn['method'] as String? ?? 'POST').toUpperCase();
    return fluent.Button(
      onPressed: url.isEmpty || _busyAction
          ? null
          : () => _runAction(label, url, method, body, confirm),
      child: Text(label),
    );
  }

  Future<void> _runAction(String label, String url, String method,
      Map<String, dynamic> body, String confirm) async {
    if (confirm.isNotEmpty) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => fluent.ContentDialog(
          title: Text('确认操作'),
          content: Text(confirm),
          actions: [
            fluent.Button(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            fluent.FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('确认'),
            ),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }
    setState(() => _busyAction = true);
    try {
      final r = await _request(url, method: method, body: body);
      _handleActionResponse(r);
    } catch (e) {
      _showError('操作「$label」失败：$e');
    } finally {
      if (mounted) setState(() => _busyAction = false);
    }
  }

  /// url 为相对路径：统一拼 `/api/plugins/<pluginId>/` 前缀。
  /// method 缺省 POST；GET 时 body 参数拼入 query。
  Future<dynamic> _request(String url,
      {String method = 'POST', Map<String, dynamic>? body}) {
    final full =
        '/api/plugins/${widget.pluginId}/${url.replaceFirst(RegExp(r'^/+'), '')}';
    switch (method) {
      case 'GET':
        return ApiClient.instance.get(full, query: {
          for (final e in (body ?? const {}).entries)
            e.key: '${e.value}',
        });
      case 'PUT':
        return ApiClient.instance.put(full, body: body ?? {});
      case 'DELETE':
        return ApiClient.instance.delete(full);
      case 'POST':
      default:
        return ApiClient.instance.post(full, body: body ?? {});
    }
  }

  /// 动作响应：{"message": str?, "refresh": bool?}。
  /// message 非空 → InfoBar；refresh == true → 重新拉面板。
  void _handleActionResponse(dynamic r) {
    if (!mounted) return;
    if (r is Map) {
      final msg = r['message'] as String?;
      if (msg != null && msg.trim().isNotEmpty) _showInfo(msg.trim());
      if (r['refresh'] == true) _fetch();
    } else {
      _showInfo('操作完成');
    }
  }

  // ---------------- 提示 ----------------

  void _showError(String msg) {
    if (!mounted) return;
    fluent.displayInfoBar(
      context,
      builder: (ctx, close) => fluent.InfoBar(
        title: const Text('操作失败'),
        content: Text(msg),
        severity: fluent.InfoBarSeverity.error,
      ),
    );
  }

  void _showInfo(String msg) {
    if (!mounted) return;
    fluent.displayInfoBar(
      context,
      builder: (ctx, close) => fluent.InfoBar(
        title: Text(msg),
        severity: fluent.InfoBarSeverity.info,
      ),
    );
  }
}

/// Markdown 配色（对齐 AI 面板风格，简版）。
MarkdownStyleSheet _panelMdStyle() => MarkdownStyleSheet(
      p: TextStyle(fontSize: 13, color: palette.textBody, height: 1.55),
      h1: TextStyle(
          fontSize: 16, color: palette.textHigh, fontWeight: FontWeight.w700),
      h2: TextStyle(
          fontSize: 15, color: palette.textHigh, fontWeight: FontWeight.w700),
      h3: TextStyle(
          fontSize: 14, color: palette.textHigh, fontWeight: FontWeight.w600),
      strong: TextStyle(fontWeight: FontWeight.w700, color: palette.textHigh),
      em: const TextStyle(fontStyle: FontStyle.italic),
      code: TextStyle(
          fontFamily: 'Consolas',
          fontSize: 12,
          color: palette.statusTan,
          backgroundColor: palette.bgDeep),
      codeblockPadding: EdgeInsets.zero,
      codeblockDecoration: const BoxDecoration(),
      blockSpacing: 8,
      listBullet: TextStyle(fontSize: 13, color: palette.textSecondary),
      listIndent: 18,
      blockquote: TextStyle(
          fontSize: 13, color: palette.textSecondary, height: 1.5),
      blockquoteDecoration: BoxDecoration(
        color: palette.panel,
        border: Border(left: BorderSide(color: Color(0xFF6C5CE7), width: 3)),
      ),
      horizontalRuleDecoration: BoxDecoration(
          border: Border(top: BorderSide(color: palette.border))),
      tableHead: TextStyle(
          fontSize: 12, color: palette.textBody, fontWeight: FontWeight.w600),
      tableBody: TextStyle(fontSize: 12, color: palette.textMid),
      tableBorder: TableBorder(
        horizontalInside: BorderSide(color: palette.border),
        verticalInside: BorderSide(color: palette.border),
        top: BorderSide(color: palette.border),
        bottom: BorderSide(color: palette.border),
        left: BorderSide(color: palette.border),
        right: BorderSide(color: palette.border),
      ),
    );

/// uiPanels 声明中的 icon 字段 → IconData；未知/空回退到扩展（拼图）图标。
IconData pluginPanelIcon(String? name) {
  switch (name?.trim().toLowerCase().replaceAll('_', '') ?? '') {
    case 'box':
      return FluentIcons.box_24_regular;
    case 'apps':
      return FluentIcons.apps_24_regular;
    case 'folder':
      return FluentIcons.folder_24_regular;
    case 'image':
    case 'photo':
    case 'picture':
      return FluentIcons.image_24_regular;
    case 'book':
    case 'books':
    case 'search':
      return FluentIcons.book_search_24_regular;
    case 'cloud':
      return FluentIcons.cloud_24_regular;
    case 'wrench':
    case 'tool':
      return FluentIcons.wrench_24_regular;
    case 'settings':
      return FluentIcons.settings_24_regular;
    case 'chat':
    case 'message':
      return FluentIcons.chat_24_regular;
    case 'heart':
      return FluentIcons.heart_24_regular;
    case 'chart':
    case 'statistics':
    case 'stats':
      return FluentIcons.chart_multiple_24_regular;
    case 'document':
    case 'form':
      return FluentIcons.document_24_regular;
    case 'grid':
      return FluentIcons.grid_24_regular;
    case 'shield':
      return FluentIcons.shield_task_24_regular;
    case 'puzzle':
    case 'extension':
      return Icons.extension;
    default:
      return Icons.extension;
  }
}