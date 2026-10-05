/// 条件 / 效果「积木库」的浏览与搭建组件。
///
/// 把无代码模式原来「目录弹窗 + 槽表单」的点选，升级为对标成熟的
/// **目录 + 已添加清单** 双栏工作台：
///   * 左栏 [BlockCatalogList]：模式标签 / 分类（来自游戏自带类型表）/
///     搜索 / 分页，点一条即补参入列；
///   * 右栏 [BlockDraftList]：已添加的积木行，支持编辑参数 / 取反 /
///     上移下移 / 复制 / 删除，顶部实时给出中文摘要与代码。
///
/// 行模型、解析、序列化全部复用 `nocode/effect_block_editor.dart`，
/// 保证「目录浏览」「字段内联」两条路径产生完全一致的文本。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../../core/app_dialogs.dart';
import '../../core/app_theme.dart';
import '../../core/mobile_widgets.dart';
import '../../core/motion.dart';
import '../../core/responsive.dart';
import '../editor/suggestion_text_field.dart';
import '../nocode/effect_block_editor.dart';
import '../nocode/effect_slot_form.dart';
import 'block_catalog.dart';
import 'catalog_visuals.dart';

// ---------------------------------------------------------------------------
// 草稿行控制器：由宿主持有 rows，本控制器只在变更后回调刷新。
// ---------------------------------------------------------------------------

class BlockDraftController {
  BlockDraftController({required this.rows, required this.onChanged});

  final List<EffectBlockRow> rows;
  final VoidCallback onChanged;

  bool get isEmpty => rows.isEmpty;

  void add(EffectBlockRow row) {
    rows.add(row);
    onChanged();
  }

  void addAll(List<EffectBlockRow> next) {
    rows.addAll(next);
    onChanged();
  }

  void removeAt(int i) {
    if (i < 0 || i >= rows.length) return;
    rows.removeAt(i);
    onChanged();
  }

  void move(int i, int delta) {
    final j = i + delta;
    if (i < 0 || j < 0 || i >= rows.length || j >= rows.length) return;
    final r = rows.removeAt(i);
    rows.insert(j, r);
    onChanged();
  }

  void duplicate(int i) {
    if (i < 0 || i >= rows.length) return;
    rows.insert(i + 1, rows[i].copy());
    onChanged();
  }

  void toggleNegate(EffectBlockRow r) {
    if (!r.canNegate) return;
    r.negate = !r.negate;
    onChanged();
  }

  void replaceAll(List<EffectBlockRow> next) {
    rows
      ..clear()
      ..addAll(next);
    onChanged();
  }

  void clear() {
    rows.clear();
    onChanged();
  }
}

// ---------------------------------------------------------------------------
// 左栏：目录（模式 / 分类 / 搜索 / 分页）
// ---------------------------------------------------------------------------

class BlockCatalogList extends StatefulWidget {
  const BlockCatalogList({
    super.key,
    required this.gameDicts,
    required this.onAdd,
    this.initialMode = 'effect',
    this.lockedMode,
    this.showModeTabs = true,
    this.onModeChanged,
    this.padding = const EdgeInsets.all(12),
  });

  final Map<String, dynamic> gameDicts;

  /// 选中一条候选并把补参后的完整代码交回宿主（suggestion 为 null = 自定义）。
  final void Function(String code, Suggestion? suggestion) onAdd;

  final String initialMode;

  /// 模式切换回调（供宿主 rail 同步显示）。
  final ValueChanged<String>? onModeChanged;

  /// 非 null 时锁定模式（不显示标签，也不允许切换）。
  final String? lockedMode;
  final bool showModeTabs;
  final EdgeInsets padding;

  @override
  State<BlockCatalogList> createState() => _BlockCatalogListState();
}

class _BlockCatalogListState extends State<BlockCatalogList> {
  static const _pageSize = 24;

  late String _mode = widget.lockedMode ?? widget.initialMode;
  List<Suggestion> _items = const [];
  bool _loading = true;
  String _query = '';
  String _category = '全部';
  int _page = 0;
  final TextEditingController _searchCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    await BlockCategoryEngine.instance.ensureLoaded();
    final items = await loadBlockCatalog(_mode, _query);
    if (!mounted) return;
    setState(() {
      _items = items;
      _page = 0;
      _loading = false;
    });
  }

  void _setMode(String mode) {
    if (_mode == mode) return;
    setState(() {
      _mode = mode;
      _category = '全部';
      _query = '';
      _page = 0;
      _searchCtrl.clear();
    });
    widget.onModeChanged?.call(mode);
    _load();
  }

  Future<void> _pick(Suggestion s) async {
    String? code;
    if (s.slots.isNotEmpty) {
      code = await showEffectSlotForm(
        context,
        suggestion: s,
        gameDicts: widget.gameDicts,
      );
    } else {
      code = s.code;
    }
    if (code == null || code.trim().isEmpty || !mounted) return;
    reportUsage(_mode, s.template.isNotEmpty ? s.template : code);
    widget.onAdd(code, s);
  }

  Future<void> _custom() async {
    final ctrl = TextEditingController();
    final code = await fluent.showDialog<String>(
      context: context,
      builder: (ctx) => AppContentDialog(
        title: const Text('自定义积木'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('按原版格式输入用逗号分隔的数字参数。',
                  style: TextStyle(fontSize: 11.5, color: palette.textMuted)),
              const SizedBox(height: 8),
              fluent.TextBox(
                controller: ctrl,
                autofocus: true,
                placeholder: '例如：1, 1, 3, 5',
                style: const TextStyle(fontSize: 12, fontFamily: 'Consolas'),
              ),
            ],
          ),
        ),
        actions: [
          fluent.Button(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          fluent.FilledButton(
            onPressed: () {
              final t = ctrl.text.trim();
              if (t.isNotEmpty) Navigator.pop(ctx, t);
            },
            child: const Text('添加'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (code == null || !mounted) return;
    widget.onAdd(code, null);
  }

  @override
  Widget build(BuildContext context) {
    final engine = BlockCategoryEngine.instance;
    final categories = engine.categoriesFor(
      _mode,
      _items.map((e) => e.code),
    );
    if (!categories.contains(_category)) _category = '全部';
    final filtered = _items
        .where((e) =>
            _category == '全部' || engine.categoryFor(_mode, e.code) == _category)
        .toList();
    final pages = filtered.isEmpty ? 1 : ((filtered.length - 1) ~/ _pageSize) + 1;
    if (_page >= pages) _page = pages - 1;
    final visible = filtered.skip(_page * _pageSize).take(_pageSize).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.lockedMode == null && widget.showModeTabs)
          Padding(
            padding: widget.padding,
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final m in kBlockModes)
                  _ModeTab(
                    label: m.label,
                    selected: _mode == m.code,
                    onTap: () => _setMode(m.code),
                  ),
              ],
            ),
          ),
        Padding(
          padding: EdgeInsets.fromLTRB(widget.padding.left, 0,
              widget.padding.right, 8),
          child: fluent.TextBox(
            controller: _searchCtrl,
            placeholder: '搜索${blockModeFor(_mode).label}、属性或名称',
            style: const TextStyle(fontSize: 12),
            onChanged: (v) {
              _query = v.trim();
              _load();
            },
          ),
        ),
        if (categories.length > 1)
          SizedBox(
            height: 34,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: EdgeInsets.symmetric(horizontal: widget.padding.left),
              children: [
                for (final c in categories)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: BlockCategoryChip(
                      label: c,
                      selected: _category == c,
                      onTap: () => setState(() {
                        _category = c;
                        _page = 0;
                      }),
                    ),
                  ),
              ],
            ),
          ),
        const SizedBox(height: 4),
        Expanded(
          child: _loading && _items.isEmpty
              ? const Center(child: fluent.ProgressRing())
              : visible.isEmpty
                  ? Center(
                      child: Text(
                        '没有匹配的${blockModeFor(_mode).label}',
                        style: TextStyle(fontSize: 12, color: palette.textHint),
                      ),
                    )
                  : ListView.builder(
                      padding: EdgeInsets.fromLTRB(widget.padding.left, 0,
                          widget.padding.right, 8),
                      itemCount: visible.length,
                      itemBuilder: (c, i) {
                        final s = visible[i];
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: BlockCatalogTile(
                            title: humanizeBlockDesc(s.desc, s.slots),
                            category: engine.categoryFor(_mode, s.code),
                            onTap: () => _pick(s),
                          ),
                        );
                      },
                    ),
        ),
        if (!_loading || _items.isNotEmpty)
          Padding(
            padding: EdgeInsets.fromLTRB(widget.padding.left, 4,
                widget.padding.right, 8),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              alignment: WrapAlignment.end,
              children: [
                _MiniBtn(label: '＋ 自定义', onTap: _custom),
                Text('${filtered.length} 项 · ${_page + 1}/$pages',
                    style:
                        TextStyle(fontSize: 10.5, color: palette.textHint)),
                _MiniBtn(
                  label: '上一页',
                  enabled: _page > 0,
                  onTap: () => setState(() => _page--),
                ),
                _MiniBtn(
                  label: '下一页',
                  enabled: _page + 1 < pages,
                  onTap: () => setState(() => _page++),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 右栏：已添加积木清单
// ---------------------------------------------------------------------------

class BlockDraftList extends StatelessWidget {
  const BlockDraftList({
    super.key,
    required this.controller,
    required this.gameDicts,
    this.singleRow = false,
    this.emptyHint = '还没有积木，从目录点击添加。',
    this.padding = const EdgeInsets.all(12),
  });

  final BlockDraftController controller;
  final Map<String, dynamic> gameDicts;
  final bool singleRow;
  final String emptyHint;
  final EdgeInsets padding;

  Future<void> _editSlots(BuildContext context, EffectBlockRow r) async {
    if (!r.editable) return;
    final res = await showSlotValueEditor(
      context,
      slots: r.slots,
      initialValues: r.values,
      gameDicts: gameDicts,
      templateCode: r.templateCode,
      templateDesc: r.templateDesc,
    );
    if (res == null) return;
    r.values = res;
    controller.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final rows = controller.rows;
    final human = rows
        .map((r) => r.toHumanText(gameDicts))
        .where((t) => t.trim().isNotEmpty)
        .join('，且 ');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(
              padding.left, padding.top, padding.right, 6),
          child: Row(
            children: [
              Text('已添加 ${rows.length} 条',
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: palette.goldText)),
              const SizedBox(width: 8),
              if (rows.isNotEmpty && human.isNotEmpty)
                Expanded(
                  child: Text(
                    human,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, color: palette.textMuted),
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: rows.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      emptyHint,
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 12, color: palette.textHint),
                    ),
                  ),
                )
              : ListView.builder(
                  padding: EdgeInsets.fromLTRB(
                      padding.left, 0, padding.right, 8),
                  itemCount: rows.length,
                  itemBuilder: (c, i) => _rowCard(context, rows[i], i),
                ),
        ),
      ],
    );
  }

  Widget _rowCard(BuildContext context, EffectBlockRow r, int i) {
    final line = r.toLine();
    final human = r.toHumanText(gameDicts);
    final hasError = (r.error ?? '').isNotEmpty;
    final top = i;
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        color: palette.card,
        borderRadius: BorderRadius.circular(7),
        border: Border.all(
            color: hasError ? palette.statusDanger : palette.border),
      ),
      padding: const EdgeInsets.fromLTRB(9, 7, 6, 7),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: MouseRegion(
                  cursor: r.editable
                      ? SystemMouseCursors.click
                      : SystemMouseCursors.basic,
                  child: GestureDetector(
                    onTap: r.editable ? () => _editSlots(context, r) : null,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                human.isEmpty ? line : human,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: hasError
                                      ? palette.statusDanger
                                      : palette.textBody,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (r.negate && r.canNegate)
                              Padding(
                                padding: const EdgeInsets.only(left: 6),
                                child: _Badge(
                                    text: '取反',
                                    bg: palette.tintWarn,
                                    fg: palette.statusWarn),
                              ),
                            if (hasError)
                              Padding(
                                padding: const EdgeInsets.only(left: 6),
                                child: _Badge(
                                    text: '异常',
                                    bg: palette.tintDanger,
                                    fg: palette.statusDanger),
                              ),
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          line,
                          style: TextStyle(
                            fontSize: 10,
                            fontFamily: 'Consolas',
                            color: palette.textSecondary,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (hasError)
                          Text(r.error!,
                              style: TextStyle(
                                  fontSize: 10.5,
                                  color: palette.statusDanger,
                                  height: 1.3)),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 4),
              _actions(r, top),
            ],
          ),
          // 无模板行（自定义代码 / 解析失败）：给一个原始参数编辑框。
          if (!r.hasTemplate) ...[
            const SizedBox(height: 6),
            _RawRowField(row: r, onChanged: controller.onChanged),
          ],
        ],
      ),
    );
  }

  Widget _actions(EffectBlockRow r, int i) {
    final negColor = r.negate ? palette.statusWarn : palette.textMuted;
    return Wrap(
      spacing: 1,
      children: [
        if (r.canNegate)
          _act('bl-neg-$i', r.negate ? '取消取反' : '取反',
              FluentIcons.subtract_24_regular,
              color: negColor, onPressed: () => controller.toggleNegate(r)),
        _act('bl-up-$i', '上移', FluentIcons.arrow_up_24_regular,
            onPressed: i == 0 ? null : () => controller.move(i, -1)),
        _act('bl-down-$i', '下移', FluentIcons.arrow_down_24_regular,
            onPressed: i >= controller.rows.length - 1
                ? null
                : () => controller.move(i, 1)),
        _act('bl-copy-$i', '复制', FluentIcons.copy_24_regular,
            onPressed: () => controller.duplicate(i)),
        _act('bl-del-$i', '删除', FluentIcons.delete_24_regular,
            color: palette.statusDanger,
            onPressed: () => controller.removeAt(i)),
      ],
    );
  }

  Widget _act(
    String key,
    String tip,
    IconData icon, {
    Color? color,
    VoidCallback? onPressed,
  }) {
    return fluent.Tooltip(
      key: ValueKey(key),
      message: tip,
      child: fluent.IconButton(
        icon: Icon(icon, size: 13, color: color),
        onPressed: onPressed,
      ),
    );
  }
}

/// 无模板行的原始参数编辑框（逗号分隔数字，失焦/回车写回行）。
class _RawRowField extends StatefulWidget {
  const _RawRowField({required this.row, required this.onChanged});

  final EffectBlockRow row;
  final VoidCallback onChanged;

  @override
  State<_RawRowField> createState() => _RawRowFieldState();
}

class _RawRowFieldState extends State<_RawRowField> {
  late final TextEditingController _c = TextEditingController(
    text: _rawBody(widget.row.toLine()),
  );
  final FocusNode _focus = FocusNode();

  static String _rawBody(String line) {
    var t = line.trim();
    if (t.startsWith('[') && t.endsWith(']')) t = t.substring(1, t.length - 1);
    return t.trim();
  }

  @override
  void didUpdateWidget(covariant _RawRowField old) {
    super.didUpdateWidget(old);
    if (!_focus.hasFocus) {
      final next = _rawBody(widget.row.toLine());
      if (next != _c.text) _c.text = next;
    }
  }

  @override
  void dispose() {
    _c.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _commit() {
    widget.row.rawCode = '[${_c.text.trim()}]';
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    return fluent.TextBox(
      controller: _c,
      focusNode: _focus,
      placeholder: '1, 1, 3, 5',
      style: const TextStyle(fontSize: 11, fontFamily: 'Consolas'),
      onSubmitted: (_) => _commit(),
      onChanged: (_) => _commit(),
    );
  }
}

// ---------------------------------------------------------------------------
// 积木库弹窗（两栏：目录 | 已添加 + 输出）
// ---------------------------------------------------------------------------

/// 打开积木库。返回组装好的文本（null = 取消）。
Future<String?> showBlockLibrary(
  BuildContext context, {
  required String initialText,
  String initialMode = 'effect',
  Map<String, dynamic> gameDicts = const {},
  bool singleRow = false,
  String title = '积木库',
}) async {
  final result = ValueNotifier<String?>(null);
  final body = BlockLibraryPanel(
    initialText: initialText,
    initialMode: initialMode,
    gameDicts: gameDicts,
    singleRow: singleRow,
    title: title,
    onResult: (v) => result.value = v,
  );
  if (isMobileWidth(context)) {
    await showMobileSheet(context, body);
  } else {
    await showDialog<void>(
      context: context,
      barrierColor: palette.scrim,
      builder: (ctx) => AppContentDialog(
        preferredWidth: 940,
        title: Text(title),
        content: SizedBox(width: 900, height: 560, child: body),
      ),
    );
  }
  final out = result.value;
  result.dispose();
  return out;
}

class BlockLibraryPanel extends StatefulWidget {
  const BlockLibraryPanel({
    super.key,
    required this.initialText,
    required this.onResult,
    this.initialMode = 'effect',
    this.gameDicts = const {},
    this.singleRow = false,
    this.title = '积木库',
  });

  final String initialText;
  final String initialMode;
  final Map<String, dynamic> gameDicts;
  final bool singleRow;
  final String title;

  /// null = 取消；非空 = 确认后的整串文本。
  final void Function(String? text) onResult;

  @override
  State<BlockLibraryPanel> createState() => _BlockLibraryPanelState();
}

class _BlockLibraryPanelState extends State<BlockLibraryPanel> {
  final List<EffectBlockRow> _rows = [];
  late BlockDraftController _controller;
  String _mode = 'effect';
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _mode = widget.initialMode;
    _controller = BlockDraftController(rows: _rows, onChanged: _refresh);
    _load();
  }

  Future<void> _load() async {
    final t = widget.initialText.trim();
    if (t.isEmpty) {
      setState(() => _loading = false);
      return;
    }
    final rows = await parseEffectText(t, _mode);
    if (!mounted) return;
    setState(() {
      _rows
        ..clear()
        ..addAll(rows ?? []);
      _loading = false;
    });
  }

  void _refresh() => setState(() {});

  Future<void> _onAdd(String code, Suggestion? s) async {
    final rows = await parseEffectText(code, _mode);
    if (!mounted) return;
    setState(() {
      if (rows != null && rows.isNotEmpty) {
        if (widget.singleRow) {
          _rows
            ..clear()
            ..addAll(rows);
        } else {
          _rows.addAll(rows);
        }
      } else {
        final row = EffectBlockRow(rawCode: code);
        if (widget.singleRow) {
          _rows
            ..clear()
            ..add(row);
        } else {
          _rows.add(row);
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final singleRow = widget.singleRow && _rows.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: _loading
              ? const Center(child: fluent.ProgressRing())
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      flex: 5,
                      child: Container(
                        decoration: BoxDecoration(
                          color: palette.panel,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: palette.border),
                        ),
                        child: BlockCatalogList(
                          gameDicts: widget.gameDicts,
                          initialMode: _mode,
                          onModeChanged: (m) => setState(() => _mode = m),
                          onAdd: _onAdd,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      flex: 4,
                      child: Container(
                        decoration: BoxDecoration(
                          color: palette.panel,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: palette.border),
                        ),
                        child: Column(
                          children: [
                            Expanded(
                              child: BlockDraftList(
                                controller: _controller,
                                gameDicts: widget.gameDicts,
                                singleRow: widget.singleRow,
                              ),
                            ),
                            _outputBar(singleRow),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            fluent.Button(
              onPressed: () => widget.onResult(null),
              child: const Text('取消'),
            ),
            const Spacer(),
            fluent.FilledButton(
              onPressed: () =>
                  widget.onResult(serializeBlockRows(_rows)),
              child: const Text('应用'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _outputBar(bool singleRow) {
    final text = serializeBlockRows(_rows);
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: palette.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text('输出',
                  style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      color: palette.textSecondary)),
              const Spacer(),
              _MiniBtn(
                label: '清空',
                enabled: _rows.isNotEmpty,
                onTap: _controller.clear,
              ),
              const SizedBox(width: 6),
              _MiniBtn(
                label: '复制',
                enabled: text.isNotEmpty,
                onTap: () {
                  Clipboard.setData(ClipboardData(text: text));
                  fluent.displayInfoBar(
                    context,
                    builder: (ctx, close) => const fluent.InfoBar(
                      title: Text('已复制积木代码'),
                      severity: fluent.InfoBarSeverity.success,
                    ),
                  );
                },
              ),
            ],
          ),
          const SizedBox(height: 4),
          SelectableText(
            text.isEmpty ? '（空）' : text,
            maxLines: 3,
            style: TextStyle(
                fontSize: 10.5, fontFamily: 'Consolas', color: palette.textBody),
          ),
          if (singleRow)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('该字段只允许一条积木，添加将替换现有行。',
                  style: TextStyle(fontSize: 10, color: palette.warning)),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 小组件
// ---------------------------------------------------------------------------

class _ModeTab extends StatelessWidget {
  const _ModeTab({
    required this.label,
    required this.selected,
    required this.onTap,
  });
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: AnimatedContainer(
          duration: AppMotion.fast,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: selected
                ? accentColor.withValues(alpha: 0.16)
                : palette.bgAlt,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: selected
                  ? accentColor.withValues(alpha: 0.45)
                  : palette.border,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: selected ? palette.textHigh : palette.textSecondary,
              fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
            ),
          ),
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.text, required this.bg, required this.fg});
  final String text;
  final Color bg;
  final Color fg;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(3),
        border: Border.all(color: fg),
      ),
      child: Text(text, style: TextStyle(fontSize: 9.5, color: fg)),
    );
  }
}

class _MiniBtn extends StatefulWidget {
  const _MiniBtn({
    required this.label,
    required this.onTap,
    this.enabled = true,
  });
  final String label;
  final VoidCallback onTap;
  final bool enabled;

  @override
  State<_MiniBtn> createState() => _MiniBtnState();
}

class _MiniBtnState extends State<_MiniBtn> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final color =
        widget.enabled ? palette.textPrimary : palette.iconDisabled;
    return MouseRegion(
      cursor: widget.enabled
          ? SystemMouseCursors.click
          : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.enabled ? widget.onTap : null,
        child: AnimatedContainer(
          duration: AppMotion.fast,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: _hover && widget.enabled ? palette.card : palette.bgAlt,
            borderRadius: BorderRadius.circular(7),
            border: Border.all(color: palette.border),
          ),
          child: Text(
            widget.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11.5, color: color),
          ),
        ),
      ),
    );
  }
}
