/// 无代码模式的效果选择机器：参数槽表单 + 效果目录浏览。
///
/// 后端 /api/effect_suggest 的每条候选带 `slots`（`@ATTR@` 占位符与裸字母
/// 数值槽）。本文件提供：
///   * [assembleEffectCode] —— 纯函数：代码模板 + 槽值 → 完整效果码（可单测）；
///   * [showEffectSlotForm] —— 带槽候选的参数表单对话框（字典槽 → 「ID · 名称」
///     下拉，数值槽 → 数字输入，实时中文预览）；
///   * [showEffectCatalogBrowser] —— 效果目录浏览：搜索 + 点击选择 → 表单/插入。
library;

import 'package:flutter/material.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;

import '../../core/api_client.dart';
import '../../core/app_theme.dart';
import '../editor/suggestion_text_field.dart';

/// 字典池名（ATTR/ROLE/…）→ /api/dicts game_dicts 的键。
/// 未列出的池（STATE/TEXT/NEGOTIATION_* 等 CSV 派生）在仓库运行环境里为空，
/// 表单退化为手输 ID。
const Map<String, String> kSlotPoolToDictKey = {
  'ATTR': 'attrs',
  'ROLE': 'roles',
  'ITEM': 'items',
  'RELATION': 'relations',
  'MAP': 'maps',
  'JOB': 'jobs',
  'BG': 'bgs',
  'STATE': 'states',
  'TEXT': 'texts',
  'GAME': 'games',
};

/// 解析池对应的字典条目 `{id: 名称}`；无池返回 null（表单退化为输入框）。
Map<String, String>? slotDictEntries(SuggestionSlot slot, Map<String, dynamic> gameDicts) {
  if (slot.kind != 'dict' || slot.dict.isEmpty) return null;
  final key = kSlotPoolToDictKey[slot.dict.toUpperCase()];
  if (key == null) return null;
  final raw = gameDicts[key];
  if (raw is! Map) return null;
  return raw.map((k, v) => MapEntry(k.toString(), v.toString()));
}

/// 字典槽的「人话」显示名：有池可查返回名称，否则回退到裸值。
/// number 槽或空值原样返回。供积木编辑器行卡片渲染 desc 预览复用，
/// 与 [showEffectSlotForm] 内的 `_display` 同一套取数逻辑。
String slotDisplayName(
    SuggestionSlot slot, String value, Map<String, dynamic> gameDicts) {
  if (slot.kind != 'dict' || value.isEmpty) return value;
  final entries = slotDictEntries(slot, gameDicts);
  return entries != null ? (entries[value] ?? value) : value;
}

/// 代码模板 + 槽值 → 完整代码：
///   * `@NAME@` 占位符整体替换为该槽的值（所有出现处）；
///   * 剩余裸字母（N/V/S/X…）按 [slots] 顺序替换为该槽的值。
/// 值缺失时保留原槽文本（宁可给用户看见没填完的 @ATTR@，不产出坏码）。
String assembleEffectCode(String template, List<SuggestionSlot> slots, Map<String, String> values) {
  var out = template;
  for (final s in slots) {
    final v = values[s.name];
    if (v == null || v.isEmpty) continue;
    if (s.kind == 'dict') {
      out = out.replaceAll('@${s.name}@', v);
    } else {
      // 裸字母槽：同字母的所有出现共享同一值。
      out = out.replaceAll(RegExp('(?<![A-Za-z0-9_])${s.name}(?![A-Za-z0-9_])'), v);
    }
  }
  return out;
}

/// desc 模板同步替换，用于表单里的中文预览。
String assembleEffectDesc(String desc, List<SuggestionSlot> slots, Map<String, String> values,
    Map<String, String> displayNames) {
  var out = desc;
  for (final s in slots) {
    var v = values[s.name] ?? '';
    if (v.isEmpty) continue;
    final shown = displayNames[s.name] ?? v;
    if (s.kind == 'dict') {
      out = out.replaceAll('@${s.name}@', shown);
    } else {
      out = out.replaceAll(RegExp('(?<![A-Za-z0-9_])${s.name}(?![A-Za-z0-9_])'), shown);
    }
  }
  return out;
}

/// 带槽候选的参数表单。确认返回填好的完整代码，取消返回 null。
Future<String?> showEffectSlotForm(
  BuildContext context, {
  required Suggestion suggestion,
  required Map<String, dynamic> gameDicts,
}) async {
  return showDialog<String>(
    context: context,
    builder: (ctx) => _SlotFormDialog(suggestion: suggestion, gameDicts: gameDicts),
  );
}

class _SlotFormDialog extends StatefulWidget {
  const _SlotFormDialog({required this.suggestion, required this.gameDicts});
  final Suggestion suggestion;
  final Map<String, dynamic> gameDicts;

  @override
  State<_SlotFormDialog> createState() => _SlotFormDialogState();
}

class _SlotFormDialogState extends State<_SlotFormDialog> {
  final Map<String, String> _values = {};
  // 槽值的人话形态（下拉选中后显示名称而非裸 ID），用于中文预览。
  final Map<String, String> _display = {};

  bool get _complete => widget.suggestion.slots.every((s) {
        final v = _values[s.name];
        return v != null && v.trim().isNotEmpty;
      });

  @override
  Widget build(BuildContext context) {
    final slots = widget.suggestion.slots;
    final preview = assembleEffectDesc(
        widget.suggestion.desc, slots, _values, _display);
    return AlertDialog(
      title: Text(widget.suggestion.desc, style: const TextStyle(fontSize: 14)),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final s in slots) _slotEditor(s),
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: palette.surface,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('预览：$preview',
                      style: TextStyle(fontSize: 11.5, color: palette.textBody)),
                  const SizedBox(height: 2),
                  Text('代码：${assembleEffectCode(widget.suggestion.code, slots, _values)}',
                      style: TextStyle(
                          fontSize: 10.5, fontFamily: 'Consolas', color: palette.textSecondary)),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        fluent.Button(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        fluent.FilledButton(
          onPressed: _complete
              ? () => Navigator.pop(
                  context, assembleEffectCode(widget.suggestion.code, slots, _values))
              : null,
          child: const Text('确定'),
        ),
      ],
    );
  }

  // 每个槽的编辑控件统一交给 [SlotField]：新建（空值）与积木编辑器的「编辑已有行」
  // （带初值）走同一份实现，避免两处复制。值经回调写回本表单的 `_values`/`_display`。
  Widget _slotEditor(SuggestionSlot s) {
    return SlotField(
      slot: s,
      gameDicts: widget.gameDicts,
      initialValue: _values[s.name] ?? '',
      onChanged: (v, name) => setState(() {
        _values[s.name] = v;
        _display[s.name] = name;
      }),
    );
  }
}

/// 单个参数槽的编辑控件（「新建」与「编辑已有行」共用）：
///   * 字典池有数据 → [fluent.ComboBox]「ID · 名称」下拉；
///   * 否则（number 槽 / 无池 dict 槽）→ [fluent.TextBox]，按 [initialValue] 预填。
/// 用户每次改动通过 [onChanged] 回传 `(值, 人话显示名)`；输入框自带控制器，
/// 因此编辑已有行时能显示当前值，而不是每次都从空开始。
class SlotField extends StatefulWidget {
  const SlotField({
    super.key,
    required this.slot,
    required this.gameDicts,
    required this.onChanged,
    this.initialValue = '',
  });
  final SuggestionSlot slot;
  final Map<String, dynamic> gameDicts;
  final String initialValue;
  final void Function(String value, String displayName) onChanged;

  @override
  State<SlotField> createState() => _SlotFieldState();
}

class _SlotFieldState extends State<SlotField> {
  late final Map<String, String>? _entries;
  late final TextEditingController _ctrl;
  String? _sel;

  @override
  void initState() {
    super.initState();
    _entries = slotDictEntries(widget.slot, widget.gameDicts);
    _ctrl = TextEditingController(text: widget.initialValue);
    if (_entries != null && _entries.containsKey(widget.initialValue)) {
      _sel = widget.initialValue;
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.slot;
    final label = s.label.isNotEmpty ? s.label : s.name;
    final entries = _entries;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          SizedBox(
            width: 84,
            child: Text('$label（${s.name}）',
                style: const TextStyle(fontSize: 12), overflow: TextOverflow.ellipsis),
          ),
          Expanded(
            child: entries != null && entries.isNotEmpty
                ? fluent.ComboBox<String>(
                    items: [
                      for (final e in entries.entries)
                        fluent.ComboBoxItem(
                            value: e.key, child: Text('${e.key} · ${e.value}')),
                    ],
                    value: _sel != null && entries.containsKey(_sel) ? _sel : null,
                    placeholder: const Text('选择…', style: TextStyle(fontSize: 12)),
                    isExpanded: true,
                    onChanged: (v) => setState(() {
                      _sel = v;
                      widget.onChanged(v ?? '', v != null ? (entries[v] ?? v) : '');
                    }),
                  )
                : fluent.TextBox(
                    controller: _ctrl,
                    placeholder: s.kind == 'dict' ? '输入 $label 的 ID' : '输入数值',
                    style: const TextStyle(fontSize: 12),
                    onChanged: (v) {
                      final t = v.trim();
                      widget.onChanged(t, t);
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

/// 编辑「一行已成型效果」的参数：与 [showEffectSlotForm] 同型，但初值来自已有槽值，
/// 确认返回填好的 `槽名 → 值` 映射（取消返回 null）——积木编辑器改槽后就地更新行，
/// 再由调用方用 [assembleEffectCode] 重生成行文本。
Future<Map<String, String>?> showSlotValueEditor(
  BuildContext context, {
  required List<SuggestionSlot> slots,
  required Map<String, String> initialValues,
  required Map<String, dynamic> gameDicts,
  String? templateCode,
  String? templateDesc,
  String title = '编辑参数',
}) async {
  return showDialog<Map<String, String>>(
    context: context,
    builder: (ctx) => _SlotValueEditDialog(
      slots: slots,
      initialValues: initialValues,
      gameDicts: gameDicts,
      templateCode: templateCode,
      templateDesc: templateDesc,
      title: title,
    ),
  );
}

class _SlotValueEditDialog extends StatefulWidget {
  const _SlotValueEditDialog({
    required this.slots,
    required this.initialValues,
    required this.gameDicts,
    required this.title,
    this.templateCode,
    this.templateDesc,
  });
  final List<SuggestionSlot> slots;
  final Map<String, String> initialValues;
  final Map<String, dynamic> gameDicts;
  final String title;
  final String? templateCode;
  final String? templateDesc;

  @override
  State<_SlotValueEditDialog> createState() => _SlotValueEditDialogState();
}

class _SlotValueEditDialogState extends State<_SlotValueEditDialog> {
  late final Map<String, String> _values;
  late final Map<String, String> _display;

  @override
  void initState() {
    super.initState();
    _values = {};
    _display = {};
    for (final s in widget.slots) {
      final v = widget.initialValues[s.name] ?? '';
      _values[s.name] = v;
      _display[s.name] = slotDisplayName(s, v, widget.gameDicts);
    }
  }

  @override
  Widget build(BuildContext context) {
    final slots = widget.slots;
    final code = widget.templateCode != null
        ? assembleEffectCode(widget.templateCode!, slots, _values)
        : '';
    final preview = widget.templateDesc != null
        ? assembleEffectDesc(widget.templateDesc!, slots, _values, _display)
        : '';
    return AlertDialog(
      title: Text(widget.title, style: const TextStyle(fontSize: 14)),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final s in slots)
              SlotField(
                slot: s,
                gameDicts: widget.gameDicts,
                initialValue: _values[s.name] ?? '',
                onChanged: (v, name) => setState(() {
                  _values[s.name] = v;
                  _display[s.name] = name;
                }),
              ),
            if (code.isNotEmpty || preview.isNotEmpty) ...[
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: palette.surface,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (preview.isNotEmpty)
                      Text('预览：$preview',
                          style: TextStyle(fontSize: 11.5, color: palette.textBody)),
                    if (code.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text('代码：$code',
                          style: TextStyle(
                              fontSize: 10.5,
                              fontFamily: 'Consolas',
                              color: palette.textSecondary)),
                    ],
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        fluent.Button(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        fluent.FilledButton(
          onPressed: () => Navigator.pop(context, _values),
          child: const Text('确定'),
        ),
      ],
    );
  }
}

/// 效果目录浏览对话框：搜索（走 /api/effect_suggest 打分排序）+ 点击选择。
/// 候选带参数槽时弹表单补全；确认后返回完整代码（null = 取消）。
Future<String?> showEffectCatalogBrowser(
  BuildContext context, {
  required String mode,
  required Map<String, dynamic> gameDicts,
  String title = '浏览效果',
}) async {
  return showDialog<String>(
    context: context,
    barrierColor: palette.scrim,
    builder: (ctx) => _CatalogBrowserDialog(mode: mode, gameDicts: gameDicts, title: title),
  );
}

class _CatalogBrowserDialog extends StatefulWidget {
  const _CatalogBrowserDialog({required this.mode, required this.gameDicts, required this.title});
  final String mode;
  final Map<String, dynamic> gameDicts;
  final String title;

  @override
  State<_CatalogBrowserDialog> createState() => _CatalogBrowserDialogState();
}

class _CatalogBrowserDialogState extends State<_CatalogBrowserDialog> {
  final TextEditingController _q = TextEditingController();
  List<Suggestion> _items = const [];
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _fetch('');
  }

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  Future<void> _fetch(String q) async {
    setState(() => _loading = true);
    List<Suggestion> found = const [];
    try {
      final resp = await ApiClient.instance
          .get('/api/effect_suggest', query: {'q': q, 'mode': widget.mode});
      final list = (resp['items'] as List? ?? const []).cast<Map>();
      found = [
        for (final e in list)
          Suggestion(
            e['code']?.toString() ?? '',
            e['desc']?.toString() ?? '',
            template: e['raw_code']?.toString() ?? e['code']?.toString() ?? '',
            slots: [
              for (final s in (e['slots'] as List? ?? const []).cast<Map>())
                SuggestionSlot.fromJson(s),
            ],
          ),
      ];
    } catch (_) {
      // 后端不可达时保持空列表（对话框仍可关闭）
    }
    if (!mounted) return;
    setState(() {
      _items = found;
      _loading = false;
    });
  }

  Future<void> _pick(Suggestion s) async {
    String? code;
    if (s.slots.isNotEmpty) {
      code = await showEffectSlotForm(context, suggestion: s, gameDicts: widget.gameDicts);
    } else {
      code = s.code;
    }
    if (code != null && code.isNotEmpty) {
      // 接受即上报使用度（空 q 的「最近使用」头部靠它）。
      reportUsage(widget.mode, s.template.isNotEmpty ? s.template : code);
      if (mounted) Navigator.pop(context, code);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title, style: const TextStyle(fontSize: 14)),
      content: SizedBox(
        width: 460,
        height: 420,
        child: Column(
          children: [
            fluent.TextBox(
              controller: _q,
              placeholder: '搜索效果（中文描述或代码片段）…',
              style: const TextStyle(fontSize: 12),
              onChanged: (v) => _fetch(v.trim()),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: _loading && _items.isEmpty
                  ? const Center(child: fluent.ProgressRing())
                  : ListView.builder(
                      itemCount: _items.length,
                      itemBuilder: (c, i) {
                        final s = _items[i];
                        return ListTile(
                          dense: true,
                          title: Text(s.desc,
                              style: const TextStyle(fontSize: 12.5),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis),
                          subtitle: Text(s.code,
                              style: const TextStyle(fontSize: 10.5, fontFamily: 'Consolas'),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis),
                          onTap: () => _pick(s),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        fluent.Button(onPressed: () => Navigator.pop(context), child: const Text('关闭')),
      ],
    );
  }
}

/// 使用度上报（fire-and-forget）；失败静默，不打扰编辑流。
void reportUsage(String kind, String key) {
  ApiClient.instance
      .post('/api/usage', body: {'kind': kind, 'key': key}, timeout: const Duration(seconds: 5))
      .catchError((_) => null);
}
