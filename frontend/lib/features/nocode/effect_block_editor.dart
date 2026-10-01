/// 效果/条件「可视化搭建器」（M2 前端）。
///
/// 把无代码模式的输入从「单条候选 + 槽表单」升级为「整数组的行级积木编辑」：
///   * 进入时把字段当前文本 POST `/api/effect/parse` 拆成行（[EffectBlockRow]）；
///   * 每行渲染成一张积木卡：中文人话（template.desc 槽代入 + 字典名称）、原码小字、
///     error 红标、取反徽章；支持删除/复制/上移下移、点开重编辑槽值；
///   * 嵌套 998 行以缩进子卡渲染（子行可编辑，结构归属由父 998 行持有）；
///   * 加行走既有 [showEffectCatalogBrowser] 目录 → 填槽 → 成行；
///   * 底部可折叠「原始文本」通道直接改 DSL，应用时重新 parse；两通道以「最后编辑」
///     为准（改行自动回写原始文本；改原始文本需点「应用解析」才回填积木）。
///
/// 文本层格式与 `/api/effect_validate`、`/api/effect/parse` 的 `text` 一致：
///   每行形如 `[1, 1, 3, 5]`（行内 `, `、行间 `; `，对齐 ValueCodec.encode 的风格），
///   序列化只走 [assembleEffectCode]（既有纯函数，槽值缺保留原槽文本），
///   取反 = 把行第二元素（secondary）的符号写成负（negate ⇔ secondary<0）。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;

import '../../core/api_client.dart';
import '../../core/app_theme.dart';
import '../../core/mobile_widgets.dart';
import '../../core/responsive.dart';
import '../editor/suggestion_text_field.dart';
import 'effect_slot_form.dart';

/// 解析端点（后端并行开发中，契约已锁定）。
const String kEffectParsePath = '/api/effect/parse';

/// POST /api/effect/parse → 行模型；`ok != true` 或异常返回 null（调用方保留旧态）。
Future<List<EffectBlockRow>?> parseEffectText(String text, String mode) async {
  try {
    final resp = await ApiClient.instance
        .post(kEffectParsePath, body: {'text': text, 'mode': mode});
    if (resp is! Map) return null;
    if (resp['ok'] != true) return null;
    return rowsFromParse(resp);
  } catch (_) {
    return null;
  }
}

/// 一行积木：镜像 /api/effect/parse 的 row 结构（可递归嵌套）。
class EffectBlockRow {
  EffectBlockRow({
    this.primary,
    this.secondary,
    this.negate = false,
    this.templateCode,
    this.templateDesc,
    this.rawCode,
    List<SuggestionSlot>? slots,
    Map<String, String>? values,
    List<EffectBlockRow>? nested,
    this.error,
  })  : slots = slots ?? const [],
        values = values ?? {},
        nested = nested ?? [];

  int? primary;
  int? secondary;
  bool negate;
  String? templateCode;
  String? templateDesc;
  String? rawCode; // 无模板兜底时的原始行文本
  List<SuggestionSlot> slots;
  Map<String, String> values; // 槽名 → 值字符串
  List<EffectBlockRow> nested;
  String? error;

  bool get hasTemplate => (templateCode ?? '').isNotEmpty;
  bool get canNegate => secondary != null;
  bool get editable => hasTemplate && slots.isNotEmpty;

  factory EffectBlockRow.fromJson(Map j) {
    final slotMaps = (j['slots'] as List? ?? const []).cast<Map>();
    final slots = [for (final m in slotMaps) SuggestionSlot.fromJson(m)];
    final values = <String, String>{
      for (var i = 0; i < slotMaps.length && i < slots.length; i++)
        slots[i].name: slotMaps[i]['value']?.toString() ?? '',
    };
    final tmpl = j['template'];
    final nestedRaw = j['nested'];
    return EffectBlockRow(
      primary: _asInt(j['primary']),
      secondary: _asInt(j['secondary']),
      negate: j['negate'] == true,
      templateCode: tmpl is Map ? tmpl['code']?.toString() : null,
      templateDesc: tmpl is Map ? tmpl['desc']?.toString() : null,
      rawCode: j['display']?.toString(),
      slots: slots,
      values: values,
      nested: nestedRaw is List
          ? [for (final n in nestedRaw.cast<Map>()) EffectBlockRow.fromJson(n)]
          : [],
      error: j['error']?.toString(),
    );
  }

  /// 深拷贝（复制行时用，nested 一并复制）。
  EffectBlockRow copy() => EffectBlockRow(
        primary: primary,
        secondary: secondary,
        negate: negate,
        templateCode: templateCode,
        templateDesc: templateDesc,
        rawCode: rawCode,
        slots: List<SuggestionSlot>.of(slots),
        values: Map<String, String>.of(values),
        nested: [for (final n in nested) n.copy()],
        error: error,
      );

  /// 本行的代码文本：模板 → 槽值装配（无模板用原始 display 兜底），
  /// 归一分隔符后，把 secondary 的符号按 negate 写回。
  String toLine() {
    final base = hasTemplate
        ? assembleEffectCode(templateCode!, slots, values)
        : (rawCode ?? '');
    var code = _normalizeRow(base);
    if (canNegate) code = _setSecondarySign(code, negate);
    return code;
  }

  /// 行卡片的中文人话：template.desc 代入槽值（dict 槽显示名称）；无 desc 回退代码。
  String toHumanText(Map<String, dynamic> gameDicts) {
    final desc = templateDesc ?? '';
    if (desc.isEmpty) return toLine();
    final names = <String, String>{
      for (final s in slots) s.name: slotDisplayName(s, values[s.name] ?? '', gameDicts),
    };
    return assembleEffectDesc(desc, slots, names, names);
  }
}

/// 解析响应里的 rows → 行模型列表。
List<EffectBlockRow> rowsFromParse(dynamic resp) {
  final rows = (resp is Map ? resp['rows'] : null) as List? ?? const [];
  return [for (final r in rows.cast<Map>()) EffectBlockRow.fromJson(r)];
}

/// 整串序列化：顶层行按序输出，父行紧跟其 nested 子行（重解析时由 998 逻辑再归组）；
/// 行间 `; `、行内 `, `，与 ValueCodec.encode 风格一致。
String serializeBlockRows(List<EffectBlockRow> rows) {
  final lines = <String>[];
  void emit(List<EffectBlockRow> rs) {
    for (final r in rs) {
      final c = r.toLine();
      if (c.trim().isNotEmpty) lines.add(c);
      if (r.nested.isNotEmpty) emit(r.nested);
    }
  }
  emit(rows);
  return lines.join('; ');
}

int? _asInt(dynamic v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v.trim());
  return null;
}

/// 把一行拆成 [primary, secondary, ...] 后按 `, ` 归一（方括号原样保留）。
String _normalizeRow(String code) {
  final t = code.trim();
  if (t.isEmpty) return '';
  final bracket = t.startsWith('[') && t.endsWith(']');
  final body = bracket ? t.substring(1, t.length - 1) : t;
  final parts = body
      .split(',')
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toList();
  final joined = parts.join(', ');
  return bracket ? '[$joined]' : joined;
}

/// 把行第二元素（secondary）的符号按 [negate] 写回；非数字/元素不足则原样返回。
String _setSecondarySign(String code, bool negate) {
  final t = code.trim();
  final bracket = t.startsWith('[') && t.endsWith(']');
  final body = bracket ? t.substring(1, t.length - 1) : t;
  final parts = body.split(',').map((e) => e.trim()).toList();
  if (parts.length < 2) return code;
  final n = num.tryParse(parts[1]);
  if (n == null) return code;
  final v = n.abs();
  parts[1] = (negate ? -v : v).toString();
  final joined = parts.join(', ');
  return bracket ? '[$joined]' : joined;
}

/// 打开积木编辑器：桌面用 [fluent.ContentDialog]，窄屏用 [showMobileSheet]。
/// 确认返回整串文本，取消返回 null。
Future<String?> showEffectBlockEditor(
  BuildContext context, {
  required String text,
  required String mode,
  Map<String, dynamic> gameDicts = const {},
  bool singleRow = false,
  String title = '积木编辑',
}) async {
  final result = ValueNotifier<String?>(null);
  final body = EffectBlockEditor(
    initialText: text,
    mode: mode,
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
      builder: (ctx) => fluent.ContentDialog(
        title: Text(title),
        content: SizedBox(width: 560, height: 520, child: body),
      ),
    );
  }
  final out = result.value;
  result.dispose();
  return out;
}

class EffectBlockEditor extends StatefulWidget {
  const EffectBlockEditor({
    super.key,
    required this.initialText,
    required this.mode,
    required this.onResult,
    this.gameDicts = const {},
    this.singleRow = false,
    this.title = '积木编辑',
    this.embedded = false,
  });

  final String initialText;
  final String mode;
  final Map<String, dynamic> gameDicts;

  /// 单行约束（screenEffect：一句话只能一个屏幕效果）。true 时加行按钮禁用并提示。
  final bool singleRow;
  final String title;

  /// 内嵌形态（无代码模式）：直接铺进字段行，**没有任何文本输入**——
  /// 去掉「原始文本」通道与取消/确定按钮，行变更即时写回 [onResult]；
  /// 文本无法解析时退化为只读原文展示，绝不覆写数据。
  final bool embedded;

  /// 提交结果：null=取消；非空=确认后的整串文本。宿主用它写回并触发校验。
  final void Function(String? text) onResult;

  @override
  State<EffectBlockEditor> createState() => EffectBlockEditorState();
}

class EffectBlockEditorState extends State<EffectBlockEditor> {
  List<EffectBlockRow> _rows = [];
  bool _loading = true;
  bool _rawOpen = false;
  String? _hint; // 交互提示（无槽/单行约束/原始应用失败等）
  String? _loadError;
  late final TextEditingController _rawCtrl;

  /// 内嵌形态的写回防抖：连续点「上移/删除」只回写一次。
  Timer? _emitDebounce;

  String get _browserTitle => switch (widget.mode) {
        'action' => '浏览人物指令',
        'screen' => '浏览屏幕效果',
        'condition' => '浏览条件',
        'cost' => '浏览消耗',
        _ => '浏览效果',
      };

  String get _addLabel => switch (widget.mode) {
        'action' => '＋ 添加指令',
        'screen' => '＋ 添加屏幕效果',
        'condition' => '＋ 添加条件',
        'cost' => '＋ 添加消耗',
        _ => '＋ 添加效果',
      };

  @override
  void initState() {
    super.initState();
    _rawCtrl = TextEditingController(text: widget.initialText);
    _loadInitial();
  }

  @override
  void dispose() {
    _emitDebounce?.cancel();
    _rawCtrl.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant EffectBlockEditor old) {
    super.didUpdateWidget(old);
    if (!widget.embedded) return;
    final t = widget.initialText;
    if (t == old.initialText) return;
    // 自己写回产生的回声（父级把同一串文本又传回来）不重解析，否则会打断编辑。
    if (t == serializeBlockRows(_rows)) return;
    _reload(t);
  }

  /// 外部改值（撤销回滚、切换字段、宿主重载）后重新拆行。
  void _reload(String text) {
    _emitDebounce?.cancel();
    _loading = true;
    _loadError = null;
    _hint = null;
    _rows = [];
    _rawCtrl.text = text;
    _loadText(text);
  }

  Future<void> _loadInitial() => _loadText(widget.initialText);

  Future<void> _loadText(String raw) async {
    final t = raw.trim();
    if (t.isEmpty) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    final rows = await parseEffectText(t, widget.mode);
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (rows != null) {
        _rows = rows;
        _rawCtrl.text = serializeBlockRows(_rows);
      } else {
        _loadError = widget.embedded
            ? '这段内容暂时无法拆成积木，已按原样保留'
            : '当前文本无法解析，可在下方「原始文本」中修正后重新应用';
      }
    });
  }

  // ---------- 行操作（仅顶层；nested 子行可编辑不可增删移） ----------

  void _afterRowsChanged() {
    _rawCtrl.text = serializeBlockRows(_rows);
    _emit();
  }

  /// 内嵌形态：行变更即时写回（防抖 250ms）。对话框形态无副作用——
  /// 结果只在点「确定」时经 [_commit] 交给宿主。
  void _emit() {
    if (!widget.embedded) return;
    _emitDebounce?.cancel();
    _emitDebounce = Timer(const Duration(milliseconds: 250), () {
      if (mounted) widget.onResult(serializeBlockRows(_rows));
    });
  }

  void _move(int i, int delta) {
    final j = i + delta;
    if (i < 0 || j < 0 || i >= _rows.length || j >= _rows.length) return;
    setState(() {
      final r = _rows.removeAt(i);
      _rows.insert(j, r);
      _afterRowsChanged();
    });
  }

  void _delete(int i) {
    if (i < 0 || i >= _rows.length) return;
    setState(() {
      _rows.removeAt(i);
      _afterRowsChanged();
    });
  }

  void _duplicate(int i) {
    if (widget.singleRow && _rows.isNotEmpty) {
      setState(() => _hint = '一句话只能一个屏幕效果');
      return;
    }
    if (i < 0 || i >= _rows.length) return;
    setState(() {
      _rows.insert(i + 1, _rows[i].copy());
      _afterRowsChanged();
    });
  }

  void _toggleNegate(EffectBlockRow r) {
    if (!r.canNegate) return;
    setState(() {
      r.negate = !r.negate;
      _afterRowsChanged();
    });
  }

  Future<void> _editSlots(EffectBlockRow r) async {
    if (!r.editable) {
      setState(() => _hint = r.hasTemplate ? '该行没有可编辑参数槽' : '该行无模板，请在原始文本中编辑');
      return;
    }
    final res = await showSlotValueEditor(
      context,
      slots: r.slots,
      initialValues: r.values,
      gameDicts: widget.gameDicts,
      templateCode: r.templateCode,
      templateDesc: r.templateDesc,
    );
    if (res == null || !mounted) return;
    setState(() {
      r.values = res;
      _afterRowsChanged();
    });
  }

  /// 加行：走目录浏览器 → 得完整码 → 回填成行（再 parse 拿回模板/槽以便二次编辑）。
  Future<void> _addRow() async {
    if (widget.singleRow && _rows.isNotEmpty) {
      setState(() => _hint = '一句话只能一个屏幕效果');
      return;
    }
    final code = await showEffectCatalogBrowser(
      context,
      mode: widget.mode,
      gameDicts: widget.gameDicts,
      title: _browserTitle,
    );
    if (code == null || code.isEmpty || !mounted) return;
    final rows = await parseEffectText(code, widget.mode);
    if (!mounted) return;
    setState(() {
      final row = (rows != null && rows.isNotEmpty)
          ? rows.first
          : EffectBlockRow(rawCode: code); // 解析失败：无模板兜底行，原始文本仍可改
      if (widget.singleRow) {
        _rows = [row];
      } else {
        _rows.add(row);
      }
      _afterRowsChanged();
    });
  }

  // ---------- 原始文本通道 ----------

  /// 「应用解析」：成功→用返回 rows 替换积木；失败→保留原积木并提示（两通道以最后编辑为准）。
  Future<void> _applyRaw() async {
    final t = _rawCtrl.text.trim();
    if (t.isEmpty) {
      setState(() {
        _rows = [];
        _hint = null;
      });
      return;
    }
    final rows = await parseEffectText(t, widget.mode);
    if (!mounted) return;
    if (rows == null) {
      setState(() => _hint = '原始文本解析失败，已保留当前积木');
      return;
    }
    setState(() {
      _rows = rows;
      _hint = null;
    });
  }

  void _commit() {
    widget.onResult(serializeBlockRows(_rows));
    _close();
  }

  void _cancel() {
    widget.onResult(null);
    _close();
  }

  void _close() {
    if (Navigator.of(context).canPop()) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    // 透明 Material 兜底：桌面 ContentDialog 路径可能没有 Material 祖先，
    // 而行卡片/原始文本头部用了 InkWell（需要 Material 才能画水波、避免断言）。
    return Material(
      type: MaterialType.transparency,
      child: widget.embedded ? _embeddedBuild() : _dialogBuild(),
    );
  }

  /// 内嵌形态：只有积木行 + 加行按钮（+ 解析失败的只读原文），
  /// **没有原始文本通道、没有取消/确定** —— 这是"开启后零代码输入"的落点。
  Widget _embeddedBuild() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _body(),
        if (_hint != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(2, 6, 2, 0),
            child: Text(_hint!,
                style:
                    TextStyle(fontSize: 11, color: palette.warning, height: 1.35)),
          ),
      ],
    );
  }

  /// 解析失败/后端不可达：只读展示原文，绝不覆写。
  Widget _embeddedUnparsed() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          _loadError ?? '这段内容暂时无法拆成积木，已按原样保留',
          style: TextStyle(fontSize: 11, color: palette.warning, height: 1.35),
        ),
        const SizedBox(height: 6),
        Container(
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: palette.card,
            borderRadius: BorderRadius.circular(AppRadius.xs),
            border: Border.all(color: palette.border),
          ),
          child: SelectableText(
            widget.initialText,
            style: const TextStyle(fontSize: 11, fontFamily: 'Consolas'),
          ),
        ),
        const SizedBox(height: 4),
        Text('如需手改，请关闭无代码模式（设置页 / 状态栏开关）。',
            style: TextStyle(fontSize: 10, color: palette.textHint)),
      ],
    );
  }

  Widget _dialogBuild() {
    return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: _body()),
          if (_hint != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(2, 6, 2, 0),
              child: Text(_hint!,
                  style: TextStyle(fontSize: 11, color: palette.warning, height: 1.35)),
            ),
          const SizedBox(height: 8),
          _rawSection(),
          const SizedBox(height: 8),
          Row(
            children: [
              fluent.Button(onPressed: _cancel, child: const Text('取消')),
              const SizedBox(width: 8),
              Expanded(
                  child: Text('改行会自动同步到原始文本；改原始文本需点「应用解析」',
                      style: TextStyle(fontSize: 10, color: palette.textHint))),
              const SizedBox(width: 8),
              fluent.FilledButton(onPressed: _commit, child: const Text('确定')),
            ],
          ),
        ],
    );
  }

  Widget _body() {
    if (_loading) return const Center(child: fluent.ProgressRing());
    // 内嵌形态 + 解析失败：只读原文，不给加行按钮（避免在无法解析的
    // 数据上继续叠加，也避免任何写回）。
    if (widget.embedded && _loadError != null) return _embeddedUnparsed();
    final addBtn = _addButton();
    if (_rows.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_loadError != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(_loadError!,
                  style: TextStyle(fontSize: 11.5, color: palette.statusDanger)),
            ),
          Text(_rows.isEmpty && (widget.initialText.trim().isEmpty)
                  ? '还没有积木，点击下方按钮添加第一条。'
                  : '（无有效行）',
              style: TextStyle(fontSize: 11.5, color: palette.textMuted)),
          const SizedBox(height: 8),
          addBtn,
        ],
      );
    }
    // 内嵌形态没有高度约束（父级是可变高文档流），用 Column 铺开；
    // 对话框形态保留 Expanded+ListView 以撑满固定高度的弹窗。
    final cards = [
      for (var i = 0; i < _rows.length; i++) _rowCard(_rows[i], i, top: true),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.embedded)
          ...cards
        else
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.only(bottom: 4),
              itemCount: cards.length,
              itemBuilder: (c, i) => cards[i],
            ),
          ),
        const SizedBox(height: 6),
        addBtn,
      ],
    );
  }

  Widget _addButton() {
    final disabled = widget.singleRow && _rows.isNotEmpty;
    return fluent.Button(
      key: const ValueKey('add-row'),
      onPressed: disabled ? null : _addRow,
      child: Text(
        widget.singleRow
            ? '$_addLabel（一句话只能一个屏幕效果）'
            : _addLabel,
        style: const TextStyle(fontSize: 11),
      ),
    );
  }

  Widget _rawSection() {
    return Container(
      decoration: BoxDecoration(
        color: palette.card,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: palette.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            key: const ValueKey('raw-toggle'),
            onTap: () => setState(() => _rawOpen = !_rawOpen),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Row(
                children: [
                  Icon(_rawOpen ? Icons.expand_less : Icons.expand_more,
                      size: 15, color: palette.textSecondary),
                  const SizedBox(width: 4),
                  Text('原始文本',
                      style: TextStyle(fontSize: 11.5, color: palette.textBody)),
                  const Spacer(),
                  Text(_rawOpen ? '▲' : '▼',
                      style: TextStyle(fontSize: 9, color: palette.textHint)),
                ],
              ),
            ),
          ),
          if (_rawOpen)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  fluent.TextBox(
                    key: const ValueKey('raw-input'),
                    controller: _rawCtrl,
                    maxLines: 4,
                    minLines: 2,
                    placeholder: '[1, 1, 3, 5]; [7, 1, 101, 50]',
                    style: const TextStyle(fontSize: 11, fontFamily: 'Consolas'),
                  ),
                  const SizedBox(height: 6),
                  Align(
                    alignment: Alignment.centerRight,
                    child: fluent.Button(
                      key: const ValueKey('raw-apply'),
                      onPressed: _applyRaw,
                      child: const Text('应用解析', style: TextStyle(fontSize: 11)),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _rowCard(EffectBlockRow r, int i, {required bool top}) {
    final line = r.toLine();
    final human = r.toHumanText(widget.gameDicts);
    final hasError = (r.error ?? '').isNotEmpty;
    return Container(
      key: top ? ValueKey('row-$i') : null,
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        color: palette.card,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: hasError ? palette.statusDanger : palette.border),
      ),
      padding: const EdgeInsets.fromLTRB(8, 6, 6, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: InkWell(
                  key: top ? ValueKey('edit-$i') : ValueKey('nedit-$i'),
                  onTap: () => _editSlots(r),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              human,
                              style: TextStyle(
                                fontSize: 12,
                                color: hasError ? palette.statusDanger : palette.textBody,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (r.negate && r.canNegate)
                            Padding(
                              padding: const EdgeInsets.only(left: 6),
                              child: _badge('取反', palette.tintWarn, palette.statusWarn),
                            ),
                          if (hasError)
                            Padding(
                              padding: const EdgeInsets.only(left: 6),
                              child: _badge('异常', palette.tintDanger, palette.statusDanger),
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
                                fontSize: 10.5, color: palette.statusDanger, height: 1.3)),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 4),
              _rowActions(r, i, top: top),
            ],
          ),
          // 嵌套子行：缩进卡片；可编辑不可增删移（结构归属父 998 行）。
          if (r.nested.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 16, top: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var ci = 0; ci < r.nested.length; ci++)
                    _rowCard(r.nested[ci], ci, top: false),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// 一个带 tooltip 的图标操作按钮（fluent.IconButton 无 tooltip 参数，外层包 Tooltip）。
  /// [key] 交给 Tooltip 承载，`find.byKey` 命中它、点击透传到内部 IconButton。
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
        icon: Icon(icon, size: 14, color: color),
        onPressed: onPressed,
      ),
    );
  }

  Widget _rowActions(EffectBlockRow r, int i, {required bool top}) {
    final negColor = r.negate ? palette.statusWarn : palette.textMuted;
    if (!top) {
      // 子行：只给「编辑（点卡体）/取反」，不给删除/复制/移动。
      return r.canNegate
          ? _act('neg-$i-child', r.negate ? '取消取反' : '取反', Icons.block,
              color: negColor, onPressed: () => _toggleNegate(r))
          : const SizedBox.shrink();
    }
    return Wrap(
      spacing: 2,
      children: [
        if (r.canNegate)
          _act('neg-$i', r.negate ? '取消取反' : '取反', Icons.block,
              color: negColor, onPressed: () => _toggleNegate(r)),
        _act('up-$i', '上移', Icons.arrow_upward,
            onPressed: i == 0 ? null : () => _move(i, -1)),
        _act('down-$i', '下移', Icons.arrow_downward,
            onPressed: i >= _rows.length - 1 ? null : () => _move(i, 1)),
        _act('copy-$i', '复制', Icons.copy, onPressed: () => _duplicate(i)),
        _act('del-$i', '删除', Icons.delete_outline, onPressed: () => _delete(i)),
      ],
    );
  }

  Widget _badge(String text, Color bg, Color fg) {
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
