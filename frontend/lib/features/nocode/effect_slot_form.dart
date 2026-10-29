/// 简易模式的效果选择机器：参数槽表单 + 效果目录浏览。
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
import '../../core/design_tokens.dart';
import '../blocks/block_catalog.dart';
import '../blocks/catalog_visuals.dart';
import '../editor/suggestion_text_field.dart';

/// 字典池名（ATTR/ROLE/…）→ /api/dicts game_dicts 的键。
/// 未列出的池（STATE/TEXT/NEGOTIATION_* 等）走 [kSlotPoolToTable] 读配置表。
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

/// 字典池名 → 配置表（`GET /api/cfg/<表>`）。
///
/// game_dicts 没有的池（STATE/TEXT/GAME/谈判/空间/手机消息）从这里补候选，
/// 让简易「只选不敲」覆盖全部 `SECONDARY_PLACEHOLDER_MAP` 里的占位符。
const Map<String, String> kSlotPoolToTable = {
  'ATTR': 'PersonAttrCfg',
  'ROLE': 'PersonCfg',
  'ITEM': 'ItemCfg',
  'RELATION': 'RelationCfg',
  'MAP': 'MapCfg',
  'JOB': 'JobCfg',
  'BG': 'BgCfg',
  'STATE': 'PersonStateCfg',
  'TEXT': 'TextCfg',
  'GAME': 'MinigameCfg',
  'NEGOTIATION_SKILL': 'NegotiationSkillCfg',
  'NEGOTIATION_BUFF': 'NegotiationBuffCfg',
  'KZONE_POST': 'KZoneContentCfg',
  'KZONE_MESSAGE': 'KZoneMessageBoardCfg',
  'PHONE_MSG': 'PhoneMsgCfg',
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

/// 池条目 `{id: 名称}` 的会话缓存（一次会话内稳定，避免重复请求）。
final Map<String, Map<String, String>> _slotPoolEntriesCache = {};

String _entryLabel(dynamic v) {
  if (v is List && v.isNotEmpty) return v.first.toString().trim();
  return v?.toString().trim() ?? '';
}

/// 一个字典池的候选条目：先查 `game_dicts`，为空再读 `/api/cfg/<表>`。
/// 结果按池缓存；读取失败返回空表（[SlotField] 才退回手输兜底）。
Future<Map<String, String>> loadSlotPoolEntries(
    String pool, Map<String, dynamic> gameDicts) async {
  final key = pool.toUpperCase();
  final cached = _slotPoolEntriesCache[key];
  if (cached != null) return cached;
  final out = <String, String>{};
  final dictKey = kSlotPoolToDictKey[key];
  final raw = dictKey == null ? null : gameDicts[dictKey];
  if (raw is Map) {
    raw.forEach((k, v) => out[k.toString()] = _entryLabel(v));
  }
  if (out.isEmpty) {
    final table = kSlotPoolToTable[key];
    if (table != null) {
      try {
        final r = await ApiClient.instance.get('/api/cfg/$table');
        final data = (r is Map && r['data'] is Map)
            ? (r['data'] as Map)
            : const {};
        for (final e in data.entries) {
          final row = e.value;
          final name = row is Map
              ? _entryLabel(row['name'] ??
                  row['title'] ??
                  row['content'] ??
                  row['desc'] ??
                  row['text'])
              : '';
          final id = e.key.toString();
          out[id] = name.isEmpty ? id : name;
        }
      } catch (_) {
        // 后端不可达：保持空表，由 SlotField 退回手输兜底。
      }
    }
  }
  _slotPoolEntriesCache[key] = out;
  return out;
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

/// A4：数字槽值的即时校验（后端暂无 min/max 元数据，按**整数**为默认规则）。
/// 返回空串 = 合法；非空 = 用户可读错误（直接展示在槽下方）。
/// 空值不在此报错——「未填」由表单的完整性检查兜底。
String numberSlotError(String value) {
  final t = value.trim();
  if (t.isEmpty) return '';
  if (RegExp(r'^[+-]?\d+$').hasMatch(t)) return '';
  return '请输入整数（原版参数为整数）';
}

/// A2：目录/行卡上的行内算符切换按钮组（`= > ≥ < ≤ ≠ 范围`）。
/// [ops] 来自后端 `ops[]`（已按循环序排好）；[current] 是当前选中算符
/// （空 = 无条件）；[onPick] 收到变体整条（code/slots 自给自足）。
class BlockOpChips extends StatelessWidget {
  const BlockOpChips({
    super.key,
    required this.ops,
    required this.current,
    required this.onPick,
    this.dense = false,
    this.keyPrefix = 'opchip',
  });

  final List<EffectOpVariant> ops;
  final String current;
  final ValueChanged<EffectOpVariant> onPick;
  final bool dense;
  final String keyPrefix;

  @override
  Widget build(BuildContext context) {
    final seen = <String>{};
    final uniq = <EffectOpVariant>[];
    for (final v in ops) {
      if (seen.add(v.displayOp)) uniq.add(v);
    }
    return Wrap(
      spacing: 3,
      runSpacing: 3,
      children: [
        for (final v in uniq)
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => onPick(v),
              child: Container(
                key: ValueKey('$keyPrefix-${v.op}'),
                padding: EdgeInsets.symmetric(
                    horizontal: dense ? AppSpace.s : AppSpace.m,
                    vertical: dense ? AppSpace.xxs : AppSpace.xs),
                decoration: BoxDecoration(
                  color: v.op == current
                      ? accentColor.withValues(alpha: 0.18)
                      : palette.bgAlt,
                  borderRadius: BorderRadius.circular(AppRadius.m),
                  border: Border.all(
                    color: v.op == current
                        ? accentColor.withValues(alpha: 0.5)
                        : palette.border,
                  ),
                ),
                child: Text(
                  v.displayOp,
                  style: TextStyle(
                    fontSize: dense ? AppText.micro : AppText.small,
                    color: v.op == current ? palette.textHigh : palette.textSecondary,
                    fontWeight:
                        v.op == current ? FontWeight.w600 : FontWeight.normal,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// 带槽候选的参数表单。确认返回填好的完整代码，取消返回 null。
/// [initialValues] 是调用方记忆的槽值（同一 family 上次填过的）；[onValues]
/// 在确认时回传本次填值，供目录做「算符切换保留已填值」。
Future<String?> showEffectSlotForm(
  BuildContext context, {
  required Suggestion suggestion,
  required Map<String, dynamic> gameDicts,
  Map<String, String> initialValues = const {},
  void Function(Map<String, String> values)? onValues,
}) async {
  return showDialog<String>(
    context: context,
    builder: (ctx) => _SlotFormDialog(
      suggestion: suggestion,
      gameDicts: gameDicts,
      initialValues: initialValues,
      onValues: onValues,
    ),
  );
}

class _SlotFormDialog extends StatefulWidget {
  const _SlotFormDialog({
    required this.suggestion,
    required this.gameDicts,
    this.initialValues = const {},
    this.onValues,
  });
  final Suggestion suggestion;
  final Map<String, dynamic> gameDicts;
  final Map<String, String> initialValues;
  final void Function(Map<String, String> values)? onValues;

  @override
  State<_SlotFormDialog> createState() => _SlotFormDialogState();
}

class _SlotFormDialogState extends State<_SlotFormDialog> {
  final Map<String, String> _values = {};
  // 槽值的人话形态（下拉选中后显示名称而非裸 ID），用于中文预览。
  final Map<String, String> _display = {};
  // A4：逐槽的即时校验错误（'name' → 错误文案）。
  final Map<String, String> _errors = {};
  String? _prefillNote;

  bool get _complete => widget.suggestion.slots.every((s) {
        final v = _values[s.name];
        return v != null &&
            v.trim().isNotEmpty &&
            (_errors[s.name] ?? '').isEmpty;
      });

  @override
  void initState() {
    super.initState();
    _prefill();
  }

  /// A7：新增候选自动带出**第一个合法引用**——dict 槽没有值时按池序取首条；
  /// 池为空时给出可读提示（而不是让用户在空下拉前发愣）。调用方记忆的
  /// [widget.initialValues] 优先于首条引用。
  Future<void> _prefill() async {
    for (final e in widget.initialValues.entries) {
      final match = [
        for (final s in widget.suggestion.slots)
          if (s.name == e.key) s,
      ];
      _values[e.key] = e.value;
      _display[e.key] = match.isEmpty
          ? e.value
          : slotDisplayName(match.first, e.value, widget.gameDicts);
    }
    if (mounted) setState(() {});
    final missing = [
      for (final s in widget.suggestion.slots)
        if (s.kind == 'dict' && (_values[s.name] ?? '').trim().isEmpty) s,
    ];
    if (missing.isEmpty) return;
    final emptyPools = <String>[];
    for (final s in missing) {
      final entries = await loadSlotPoolEntries(s.dict, widget.gameDicts);
      if (!mounted) return;
      if (entries.isEmpty) {
        emptyPools.add(s.label.isNotEmpty ? s.label : s.name);
        continue;
      }
      final k = entries.keys.first;
      setState(() {
        _values[s.name] = k;
        _display[s.name] = entries[k] ?? k;
      });
    }
    if (emptyPools.isNotEmpty) {
      setState(() =>
          _prefillNote = '参数「${emptyPools.join('、')}」没有可用候选，请手动填写');
    }
  }

  @override
  Widget build(BuildContext context) {
    final slots = widget.suggestion.slots;
    final preview = assembleEffectDesc(
        widget.suggestion.desc, slots, _values, _display);
    return AlertDialog(
      title: Text(widget.suggestion.desc,
          style: const TextStyle(fontSize: AppText.title)),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if ((widget.suggestion.description).isNotEmpty) ...[
              Text(widget.suggestion.description,
                  style: TextStyle(fontSize: AppText.dense, color: palette.textHint)),
              const SizedBox(height: AppSpace.s6),
            ],
            for (final s in slots) _slotEditor(s),
            if (_prefillNote != null) ...[
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpace.s),
                child: Text(_prefillNote!,
                    style:
                        TextStyle(fontSize: AppText.dense, color: palette.statusWarn)),
              ),
            ],
            const SizedBox(height: AppSpace.s10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(AppSpace.s),
              decoration: BoxDecoration(
                color: palette.surface,
                borderRadius: BorderRadius.circular(AppRadius.xs),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('预览：$preview',
                      style:
                          TextStyle(fontSize: AppText.caption, color: palette.textBody)),
                  const SizedBox(height: AppSpace.xxs),
                  Text('代码：${assembleEffectCode(widget.suggestion.code, slots, _values)}',
                      style: TextStyle(
                          fontSize: AppText.dense,
                          fontFamily: 'Consolas',
                          color: palette.textSecondary)),
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
              ? () {
                  // 回传本次填值（目录记忆它，同行内切算符时复用）。
                  widget.onValues?.call(Map<String, String>.of(_values));
                  Navigator.pop(
                      context, assembleEffectCode(widget.suggestion.code, slots, _values));
                }
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
      key: ValueKey('slot-${s.name}'),
      slot: s,
      gameDicts: widget.gameDicts,
      initialValue: _values[s.name] ?? '',
      onChanged: (v, name) => setState(() {
        _values[s.name] = v;
        _display[s.name] = name;
      }),
      onError: (err) => setState(() {
        if (err.isEmpty) {
          _errors.remove(s.name);
        } else {
          _errors[s.name] = err;
        }
      }),
    );
  }
}

/// 槽标签列宽（标签列与错误提示的左缩进共用同一个值）。
const double _kLabelWidth = 84;

/// 单个参数槽的编辑控件（「新建」与「编辑已有行」共用）：
///   * number 槽 → [fluent.TextBox] 数值输入；
///   * 字典槽 → 先 game_dicts、再 `/api/cfg/<表>` 取候选，有则 [fluent.ComboBox]
///     「ID · 名称」下拉（真正的「只选不敲」）；读取中/真无候选才退回手输。
/// 用户每次改动通过 [onChanged] 回传 `(值, 人话显示名)`；输入框自带控制器，
/// 因此编辑已有行时能显示当前值，而不是每次都从空开始。
class SlotField extends StatefulWidget {
  const SlotField({
    super.key,
    required this.slot,
    required this.gameDicts,
    required this.onChanged,
    this.initialValue = '',
    this.onError,
  });
  final SuggestionSlot slot;
  final Map<String, dynamic> gameDicts;
  final String initialValue;
  final void Function(String value, String displayName) onChanged;

  /// A4：校验状态回调（空串 = 合法），宿主据此禁用「确定」。
  final ValueChanged<String>? onError;

  @override
  State<SlotField> createState() => _SlotFieldState();
}

class _SlotFieldState extends State<SlotField> {
  Map<String, String>? _entries;
  bool _loading = false;
  late final TextEditingController _ctrl;
  String? _sel;
  String _error = '';

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.initialValue);
    if (widget.slot.kind == 'dict') {
      _loading = true;
      _loadEntries();
    }
  }

  @override
  void didUpdateWidget(covariant SlotField old) {
    super.didUpdateWidget(old);
    // A7 预填 / 记忆值回灌：外部初值变化时同步输入框与下拉选中（用户正在
    // 输入时父级回传的就是输入值本身，两者相等，不会打断）。
    if (widget.initialValue != old.initialValue &&
        widget.initialValue != _ctrl.text) {
      _ctrl.text = widget.initialValue;
    }
    final entries = _entries;
    if (widget.slot.kind == 'dict' &&
        widget.initialValue != old.initialValue &&
        entries != null &&
        entries.containsKey(widget.initialValue)) {
      _sel = widget.initialValue;
    }
  }

  Future<void> _loadEntries() async {
    final entries =
        await loadSlotPoolEntries(widget.slot.dict, widget.gameDicts);
    if (!mounted) return;
    setState(() {
      _entries = entries;
      _loading = false;
      if (entries.containsKey(widget.initialValue)) _sel = widget.initialValue;
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  /// 值变更统一入口：先做 A4 校验（初值原样保留视为可信，避免历史怪值
  /// 把编辑已有行锁死），再向外回传值/显示名/错误。
  void _setValue(String v, String name) {
    final trusted =
        widget.slot.kind == 'number' && v.trim() == widget.initialValue.trim();
    final err = widget.slot.kind == 'number' && !trusted
        ? numberSlotError(v)
        : '';
    if (err != _error) {
      setState(() => _error = err);
      widget.onError?.call(err);
    }
    widget.onChanged(v, name);
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.slot;
    final label = s.label.isNotEmpty ? s.label : s.name;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpace.s),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SizedBox(
                width: _kLabelWidth,
                child: Text('$label（${s.name}）',
                    style: const TextStyle(fontSize: AppText.body),
                    overflow: TextOverflow.ellipsis),
              ),
              Expanded(child: _input(s, label, _entries)),
            ],
          ),
          if (_error.isNotEmpty)
            Padding(
              padding:
                  const EdgeInsets.only(left: _kLabelWidth, top: AppSpace.xxs),
              child: Text(_error,
                  style:
                      TextStyle(fontSize: AppText.dense, color: palette.statusDanger)),
            ),
        ],
      ),
    );
  }

  Widget _input(SuggestionSlot s, String label, Map<String, String>? entries) {
    if (s.kind != 'dict') {
      return fluent.TextBox(
        controller: _ctrl,
        placeholder: '输入数值',
        style: const TextStyle(fontSize: AppText.body),
        onChanged: (v) {
          final t = v.trim();
          _setValue(t, t);
        },
      );
    }
    if (_loading) {
      return Text('正在读取候选…',
          style: TextStyle(fontSize: AppText.body, color: palette.textHint));
    }
    if (entries != null && entries.isNotEmpty) {
      return fluent.ComboBox<String>(
        items: [
          for (final e in entries.entries)
            fluent.ComboBoxItem(
                value: e.key, child: Text('${e.key} · ${e.value}')),
        ],
        value: _sel != null && entries.containsKey(_sel) ? _sel : null,
        placeholder: const Text('选择…', style: TextStyle(fontSize: AppText.body)),
        isExpanded: true,
        onChanged: (v) {
          setState(() => _sel = v);
          _setValue(v ?? '', v != null ? (entries[v] ?? v) : '');
        },
      );
    }
    // 真没读到候选（后端不可达 / 表不存在）才手输兜底。
    return fluent.TextBox(
      controller: _ctrl,
      placeholder: '未读到候选，输入 $label 的 ID',
      style: const TextStyle(fontSize: AppText.body),
      onChanged: (v) {
        final t = v.trim();
        _setValue(t, t);
      },
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
  // A4：逐槽校验错误 → 任一非法即禁用「确定」。
  final Map<String, String> _errors = {};

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

  bool get _hasError => _errors.values.any((e) => e.isNotEmpty);

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
      title: Text(widget.title, style: const TextStyle(fontSize: AppText.title)),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final s in slots)
              SlotField(
                key: ValueKey('slot-${s.name}'),
                slot: s,
                gameDicts: widget.gameDicts,
                initialValue: _values[s.name] ?? '',
                onChanged: (v, name) => setState(() {
                  _values[s.name] = v;
                  _display[s.name] = name;
                }),
                onError: (err) => setState(() {
                  if (err.isEmpty) {
                    _errors.remove(s.name);
                  } else {
                    _errors[s.name] = err;
                  }
                }),
              ),
            if (code.isNotEmpty || preview.isNotEmpty) ...[
              const SizedBox(height: AppSpace.s10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(AppSpace.s),
                decoration: BoxDecoration(
                  color: palette.surface,
                  borderRadius: BorderRadius.circular(AppRadius.xs),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (preview.isNotEmpty)
                      Text('预览：$preview',
                          style: TextStyle(
                              fontSize: AppText.caption,
                              color: palette.textBody)),
                    if (code.isNotEmpty) ...[
                      const SizedBox(height: AppSpace.xxs),
                      Text('代码：$code',
                          style: TextStyle(
                              fontSize: AppText.dense,
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
          onPressed: _hasError ? null : () => Navigator.pop(context, _values),
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
  static const _pageSize = 24;

  final TextEditingController _q = TextEditingController();
  List<Suggestion> _items = const [];
  bool _loading = true;
  String _category = '全部';
  int _page = 0;

  /// A2：每个 family 当前选中的算符 / 上次填过的槽值（同行内切换复用）。
  final Map<String, String> _familyOp = {};
  final Map<String, Map<String, String>> _familyValues = {};

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
    await BlockCategoryEngine.instance.ensureLoaded();
    final found = await loadBlockCatalog(widget.mode, q);
    if (!mounted) return;
    setState(() {
      _items = found;
      _page = 0;
      _loading = false;
    });
  }

  Future<void> _pick(Suggestion s) async {
    String? code;
    if (s.slots.isNotEmpty) {
      Map<String, String>? filled;
      code = await showEffectSlotForm(
        context,
        suggestion: s,
        gameDicts: widget.gameDicts,
        initialValues: _familyValues[s.family] ?? const {},
        onValues: (v) => filled = v,
      );
      if (filled != null && s.family.isNotEmpty) {
        _familyValues[s.family] = filled!;
      }
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
    final engine = BlockCategoryEngine.instance;
    final mode = blockModeFor(widget.mode);
    final categories = engine.categoriesFor(
      widget.mode,
      _items.map((e) => e.code),
    );
    if (!categories.contains(_category)) _category = '全部';
    final filtered = _items
        .where((e) =>
            _category == '全部' ||
            engine.categoryFor(widget.mode, e.code) == _category)
        .toList();
    // A2：与积木库左栏同一份折叠逻辑（family 一条 + 行内算符）。
    final groups = groupByFamily(filtered);
    final pages = groups.isEmpty ? 1 : ((groups.length - 1) ~/ _pageSize) + 1;
    if (_page >= pages) _page = pages - 1;
    final visible = groups.skip(_page * _pageSize).take(_pageSize).toList();
    return AlertDialog(
      title: Text(widget.title, style: const TextStyle(fontSize: AppText.title)),
      content: SizedBox(
        width: 500,
        height: 480,
        child: Column(
          children: [
            fluent.TextBox(
              controller: _q,
              placeholder: '搜索${mode.label}、属性或名称…',
              style: const TextStyle(fontSize: AppText.body),
              onChanged: (v) => _fetch(v.trim()),
            ),
            const SizedBox(height: AppSpace.s),
            if (categories.length > 1)
              Align(
                alignment: Alignment.centerLeft,
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final c in categories)
                      BlockCategoryChip(
                        label: c,
                        selected: _category == c,
                        onTap: () => setState(() {
                          _category = c;
                          _page = 0;
                        }),
                      ),
                  ],
                ),
              ),
            const SizedBox(height: AppSpace.xs),
            Expanded(
              child: _loading && _items.isEmpty
                  ? const Center(child: fluent.ProgressRing())
                  : visible.isEmpty
                      ? Center(
                          child: Text('没有匹配的候选',
                              style: TextStyle(
                                  fontSize: AppText.body,
                                  color: palette.textHint)))
                      : ListView.separated(
                          itemCount: visible.length,
                          separatorBuilder: (c, i) =>
                              const SizedBox(height: AppSpace.s),
                          itemBuilder: (c, i) {
                            final g = visible[i];
                            final family = g.first.family;
                            final folded = g.length > 1 && family.isNotEmpty;
                            final selected = folded
                                ? blockGroupPick(g, _familyOp[family] ?? '')
                                : g.first;
                            return BlockCatalogTile(
                              title: folded
                                  ? blockGroupTitle(g)
                                  : humanizeBlockDesc(
                                      selected.desc, selected.slots),
                              subtitle: folded
                                  ? humanizeBlockDesc(
                                      selected.desc, selected.slots)
                                  : '',
                              category: engine.categoryFor(
                                  widget.mode, selected.code),
                              footer: folded
                                  ? BlockOpChips(
                                      keyPrefix: 'fldop-${selected.family}',
                                      ops: selected.ops.isEmpty
                                          ? [
                                              for (final s in g)
                                                EffectOpVariant(
                                                    op: s.op,
                                                    code: s.code,
                                                    slots: s.slots),
                                            ]
                                          : selected.ops,
                                      current: selected.op,
                                      onPick: (v) => setState(
                                          () => _familyOp[family] = v.op),
                                      dense: true,
                                    )
                                  : null,
                              onTap: () => _pick(selected),
                            );
                          },
                        ),
            ),
            if (!_loading || _items.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: AppSpace.xs),
                child: Row(
                  children: [
                    Text('${groups.length} 项 · ${_page + 1}/$pages',
                        style: TextStyle(
                            fontSize: AppText.dense, color: palette.textHint)),
                    const Spacer(),
                    fluent.Button(
                      onPressed: _page > 0
                          ? () => setState(() => _page--)
                          : null,
                      child: const Text('上一页',
                          style: TextStyle(fontSize: AppText.small)),
                    ),
                    const SizedBox(width: AppSpace.s6),
                    fluent.Button(
                      onPressed: _page + 1 < pages
                          ? () => setState(() => _page++)
                          : null,
                      child: const Text('下一页',
                          style: TextStyle(fontSize: AppText.small)),
                    ),
                  ],
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
