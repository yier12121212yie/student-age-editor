/// 效果/条件「可视化搭建器」（M2 前端）。
///
/// 把简易模式的输入从「单条候选 + 槽表单」升级为「整数组的行级积木编辑」：
///   * 进入时把字段当前文本 POST `/api/effect/parse` 拆成行（[EffectBlockRow]）；
///   * 每行渲染成一张积木卡：中文人话（template.desc 槽代入 + 字典名称）、原码小字、
///     error 红标、取反徽章；支持删除/复制/上移下移、点开重编辑槽值；
///   * 嵌套 998 行以缩进子卡渲染（子行可改槽/取反，也可在父组内增删移；结构会
///     内联回父行的嵌套数组，往返安全——见 [EffectBlockRow.toLine] / D8）；
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
import '../../core/design_tokens.dart';
import '../../core/error_text.dart';
import '../../core/mobile_widgets.dart';
import '../../core/responsive.dart';
import '../../core/status_pill.dart';
import '../editor/suggestion_text_field.dart';
import 'effect_slot_form.dart';
import '../../core/app_dialogs.dart';

/// 解析端点（后端并行开发中，契约已锁定）。
const String kEffectParsePath = '/api/effect/parse';

/// 拆解状态码（与后端 `status` 字段同源）：
///   * `ok`                   —— 全部行拆解成功；
///   * `empty`                —— 输入为空；
///   * `logic_error`          —— **仍返回完整 rows**，其中个别行带行级 `error`；
///   * `partial`              —— 整体 JSON 解析失败但逐行回退成功，坏行 `unrecognized`；
///   * `missing_outer_bracket`—— 缺外层方括号（前端会尝试自动补全重试）；
///   * `json_error`           —— 括号/逗号不匹配且无法逐行回退；
///   * `error`                —— 请求异常 / 后端不可达（前端本地合成）。
const String kParseStatusOk = 'ok';
const String kParseStatusEmpty = 'empty';
const String kParseStatusLogicError = 'logic_error';
const String kParseStatusPartial = 'partial';
const String kParseStatusMissingBracket = 'missing_outer_bracket';
const String kParseStatusJsonError = 'json_error';
const String kParseStatusError = 'error';

// ---------------------------------------------------------------------------
// D（singleRow 单点化）：1D 码字段（screenEffect）「一句话一条」的唯一判定。
// 字段侧的类型判定、行侧能否再加、单行收敛写入与提示文案都收在这里，
// 目录添加 / 内嵌加行 / 复制 / 加行按钮四条路径共用，不再各自手写条件。
// ---------------------------------------------------------------------------

/// 字段类型 → 单行约束：1D Array 码字段（如 screenEffect）只能填一条。
bool singleRowForType(String type) => type == '1D Array';

/// 单行约束的提示文案（加行按钮 / 复制 / 目录添加共用）。
const String kSingleRowHint = '一句话只能一个屏幕效果';

/// 还能不能再加一行：非约束恒 true；单行约束下仅当现在没有任何行。
bool blockCanAddRow({required bool singleRow, required int rowCount}) =>
    !singleRow || rowCount == 0;

/// 单行约束下的列表写入：单行 → 整列表替换为 [rows]；非单行 → 追加。
/// 积木库右栏的目录添加与内嵌编辑器的加行共用同一处收敛逻辑。
void applyRowsWithSingleRow(
  List<EffectBlockRow> host,
  List<EffectBlockRow> rows, {
  required bool singleRow,
}) {
  if (singleRow) {
    host
      ..clear()
      ..addAll(rows);
  } else {
    host.addAll(rows);
  }
}

/// 一次拆解的结构化结果（D1）：不再把「有行 + 行级错误」整体判死。
class ParseOutcome {
  const ParseOutcome({
    required this.status,
    required this.ok,
    this.message,
    this.rows = const [],
    this.fixedText,
    this.errorOffset,
    this.errorLine,
    this.errorCol,
  });

  /// 见 [kParseStatusOk] 等常量。
  final String status;

  /// 是否「完全成功」（行级全部无 error）。
  final bool ok;

  /// 后端给的用户可见文案（失败原因 / 自动补全提示）。
  final String? message;

  /// 拆解出的行（[logic_error] / [partial] 也会返回，含带 error 的行）。
  final List<EffectBlockRow> rows;

  /// [kParseStatusMissingBracket] 自动补全后的文本（未补全为新文本时为 null）。
  /// 调用方通常在用户未编辑前**不写回**，仅用于展示与后续编辑。
  final String? fixedText;

  /// D4：`json_error` 时的失败位置（0-based 码点偏移、1-based 行列），
  /// 后端在整体解析失败且无一行可救回时给出；无则 null。
  final int? errorOffset;
  final int? errorLine;
  final int? errorCol;

  bool get hasRows => rows.isNotEmpty;

  /// 行级有问题的行数（`error` 非空）。
  int get errorRowCount => rows.where((r) => r.hasError).length;

  /// D4：把定位信息拼成用户可读的「（第 N 个字符附近）」；无定位则空串。
  String get locationSuffix {
    if (errorLine == null && errorOffset == null) return '';
    // 编码后按「字符」计（后端按 UTF-8 码点，与用户数格子的直觉一致）。
    final at = errorOffset != null ? errorOffset! + 1 : null;
    final lc = (errorLine != null && errorLine! > 1)
        ? '第 $errorLine 行第 ${errorCol ?? 1} 列'
        : null;
    final parts = <String>[
      if (at != null) '第 $at 个字符附近',
      if (lc != null) lc,
    ];
    return parts.isEmpty ? '' : '（${parts.join('，')}）';
  }

  /// `json_error` 的完整用户文案：后端 message + 可选定位后缀。
  String get jsonErrorText {
    final m = (message ?? '括号或逗号不匹配').trim();
    final s = locationSuffix;
    return s.isEmpty ? m : '$m$s';
  }
}

/// POST /api/effect/parse → [ParseOutcome]；网络/异常不再是 null，而是
/// [kParseStatusError]（带 message），调用方据此展示原因而非笼统灰字。
Future<ParseOutcome> parseEffectOutcome(String text, String mode) async {
  Map? resp;
  try {
    final r = await ApiClient.instance
        .post(kEffectParsePath, body: {'text': text, 'mode': mode});
    if (r is! Map) {
      return const ParseOutcome(
          status: kParseStatusError, ok: false, message: '后端未返回有效的解析结果');
    }
    resp = r;
  } catch (e) {
    // C3：网络/后端异常走统一人性化文案，不把技术串直接丢给用户。
    return ParseOutcome(
      status: kParseStatusError,
      ok: false,
      message: '解析失败：${humanizeErrorMessage(e)}',
    );
  }

  final status = (resp['status']?.toString() ?? '').trim().isEmpty
      ? (resp['ok'] == true ? kParseStatusOk : kParseStatusLogicError)
      : resp['status'].toString().trim();
  final message = resp['message']?.toString();
  final rows = rowsFromParse(resp);
  final errOffset = _asIntOrNull(resp['error_offset']);
  final errLine = _asIntOrNull(resp['error_line']);
  final errCol = _asIntOrNull(resp['error_col']);

  // 缺外层方括号：自动补 `[ … ]` 重试一次（后端只在 effect/condition 触发）。
  if (status == kParseStatusMissingBracket) {
    final t = resp['text']?.toString() ?? text;
    final fixed = '[[${t.trim()}]]';
    try {
      final r2 = await ApiClient.instance
          .post(kEffectParsePath, body: {'text': fixed, 'mode': mode});
      if (r2 is Map && r2['ok'] == true) {
        return ParseOutcome(
          status: kParseStatusOk,
          ok: true,
          message: '已自动补全外层括号',
          rows: rowsFromParse(r2),
          fixedText: fixed,
        );
      }
    } catch (_) {}
    return ParseOutcome(
      status: status,
      ok: false,
      message: message ?? '缺少外层方括号',
      rows: rows,
      fixedText: fixed,
    );
  }

  return ParseOutcome(
    status: status,
    ok: resp['ok'] == true,
    message: message,
    rows: rows,
    errorOffset: errOffset,
    errorLine: errLine,
    errorCol: errCol,
  );
}

int? _asIntOrNull(dynamic v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v.trim());
  return null;
}

/// POST /api/effect/parse → 行模型（**兼容壳**，保持既有 5 处调用方行为）。
///
/// `ok / empty / logic_error / partial` 返回 rows（可能为空列表）；
/// `json_error / missing_outer_bracket(自动修复失败) / 异常` 返回 null
/// （调用方保留旧态）。新代码请直接用 [parseEffectOutcome] 以拿到 status/message。
Future<List<EffectBlockRow>?> parseEffectText(String text, String mode) async {
  final o = await parseEffectOutcome(text, mode);
  switch (o.status) {
    case kParseStatusOk:
    case kParseStatusEmpty:
    case kParseStatusLogicError:
    case kParseStatusPartial:
      return o.rows;
    default:
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
    this.unrecognized = false,
    this.family = '',
    this.familyLabel = '',
    this.op = '',
    List<EffectOpVariant>? ops,
  })  : slots = slots ?? const [],
        values = values ?? {},
        nested = nested ?? [],
        ops = ops ?? const [];

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

  /// A1 元数据（后端 parse 的 `template.family` 等；老后端为空）。
  String family;
  String familyLabel;
  String op;
  List<EffectOpVariant> ops;

  /// 未识别行（D3 `partial` 回退时的坏行）：原文只读、保序、逐字节保留，
  /// 用户不碰就不改；`toLine()` 不做任何归一/取反改写。
  bool unrecognized;

  bool get hasTemplate => (templateCode ?? '').isNotEmpty;
  bool get hasError => (error ?? '').isNotEmpty;
  bool get canNegate => secondary != null;

  /// 无模板但后端给了通用参数槽（`param_N`，见 cost/action/screen 分支）：
  /// 可按参数编辑并正确序列化（D2）。
  bool get hasGenericSlots =>
      slots.isNotEmpty && slots.every((s) => s.name.startsWith('param_'));

  /// 可编辑参数槽：排除 rest 槽（`kind == 'nested'`，如 998 的 `EFFECTS*`）——
  /// 那一格的内容由嵌套子行卡片承载，不该在槽表单里当文本改。
  List<SuggestionSlot> get editableSlots =>
      [for (final s in slots) if (s.kind != 'nested') s];

  /// 可编辑：未识别行不可编辑；有（非 rest）参数槽即可（含无模板的 `param_N`）。
  bool get editable => !unrecognized && editableSlots.isNotEmpty;

  /// 模板里带 rest 槽（`kind == 'nested'`，如 998 的 `EFFECTS*`）：子行内联进
  /// 嵌套数组，而不是另起一行。这样父行的代码形态与后端 998 归组规则一致
  /// （`[998, 2, 0, [[1, 1, 3, 5], …]]`），往返不丢结构（D8）。
  bool get inlinesNested => slots.any((s) => s.kind == 'nested');

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
      unrecognized: j['unrecognized'] == true,
      family: tmpl is Map ? (tmpl['family']?.toString() ?? '') : '',
      familyLabel: tmpl is Map ? (tmpl['family_label']?.toString() ?? '') : '',
      op: tmpl is Map ? (tmpl['op']?.toString() ?? '') : '',
      ops: tmpl is Map
          ? [
              for (final o in (tmpl['ops'] as List? ?? const []).cast<Map>())
                EffectOpVariant.fromJson(o),
            ]
          : const [],
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
        unrecognized: unrecognized,
        family: family,
        familyLabel: familyLabel,
        op: op,
        ops: List<EffectOpVariant>.of(ops),
      );

  /// 本行的代码文本：模板 → 槽值装配；无模板但有通用槽 → 按槽值位置重建；
  /// 未识别行 → 原文原样；其余回退原始 display。归一分隔符后把 secondary
  /// 的符号按 negate 写回。
  String toLine() {
    if (unrecognized) return rawCode ?? '';
    final String base;
    if (hasTemplate) {
      base = _assembleRowCode(templateCode!, slots, values, nested);
    } else if (hasGenericSlots) {
      // 通用槽按位置（param_0, param_1 …）重建 `[a, b, c]`；任一槽为空则
      // 退回原文，避免丢位（空值会把后续参数左移）。
      final parts = [for (final s in slots) values[s.name] ?? ''];
      base = parts.any((p) => p.isEmpty)
          ? (rawCode ?? '')
          : '[${parts.join(', ')}]';
    } else {
      base = rawCode ?? '';
    }
    var code = _normalizeRow(base);
    if (canNegate) code = _setSecondarySign(code, negate);
    return code;
  }

  /// 行卡片的中文人话：template.desc 代入槽值（dict 槽显示名称）；
  /// 无模板 → 通用槽拼一行「未收录的指令：…」；再退代码。
  String toHumanText(Map<String, dynamic> gameDicts) {
    final desc = templateDesc ?? '';
    if (desc.isEmpty) {
      if (hasGenericSlots) {
        final shown = [
          for (final s in slots)
            slotDisplayName(s, values[s.name] ?? '', gameDicts),
        ].where((v) => v.isNotEmpty).join(', ');
        return shown.isEmpty ? '未收录的指令' : '未收录的指令：$shown';
      }
      return toLine();
    }
    final names = <String, String>{
      for (final s in slots) s.name: slotDisplayName(s, values[s.name] ?? '', gameDicts),
    };
    return assembleEffectDesc(desc, slots, names, names);
  }
}

/// A2：把一行的模板切换为同 family 的另一个算符变体（ops[] 条目），
/// **保留同名槽已填值**——如 `[1, 1, V]`（V=10）切到 `≤` 后得 `[1, 2, 10]`。
///
/// 变体需要的新槽（如范围的 X/Y）没有值、或行带嵌套子行 / 未识别时返回
/// false，调用方应改为打开槽表单补填而不是硬改。
bool switchRowOp(EffectBlockRow r, EffectOpVariant v) {
  if (v.code.isEmpty || r.unrecognized || r.inlinesNested) return false;
  final next = <String, String>{
    for (final s in v.slots) s.name: r.values[s.name] ?? '',
  };
  if (next.values.any((x) => x.trim().isEmpty)) return false;
  r
    ..templateCode = v.code
    ..slots = List<SuggestionSlot>.of(v.slots)
    ..values = next
    ..op = v.op;
  return true;
}

/// 解析响应里的 rows → 行模型列表。
List<EffectBlockRow> rowsFromParse(dynamic resp) {
  final rows = (resp is Map ? resp['rows'] : null) as List? ?? const [];
  return [for (final r in rows.cast<Map>()) EffectBlockRow.fromJson(r)];
}

/// 行代码拼装（D8）：普通槽沿用 [assembleEffectCode] 的替换规则；rest 槽
/// （`kind == 'nested'`，模板里写作 `<NAME>*`，如 998 的 `EFFECTS*`）把子行
/// 序列化成嵌套数组文本后替换该 token。
///
/// 为什么必须内联：后端只在**父行自己的数组里**认嵌套（`[[..],..]` 或扁平尾巴，
/// 见 [semantic_graph.cpp](../../../../native/server/services/semantic_graph.cpp) 的
/// 998 分支），而 `norm_effect_rows` 不会把后续独立行吸收进前一行。所以把子行
/// 另起一行（`… ; [1, 1, 3, 5]`）会让 998 组在重解析时散架。
String _assembleRowCode(
  String template,
  List<SuggestionSlot> slots,
  Map<String, String> values,
  List<EffectBlockRow> nested,
) {
  var out = template;
  for (final s in slots) {
    if (s.kind == 'nested') continue;
    final v = values[s.name];
    if (v == null || v.isEmpty) continue;
    if (s.kind == 'dict') {
      out = out.replaceAll('@${s.name}@', v);
    } else {
      out = out.replaceAll(
          RegExp('(?<![A-Za-z0-9_])${RegExp.escape(s.name)}(?![A-Za-z0-9_])'), v);
    }
  }
  for (final s in slots) {
    if (s.kind != 'nested') continue;
    final name = RegExp.escape(s.name);
    if (nested.isEmpty) {
      // 空组：连前置逗号一起摘掉，避免留下 `[998, 1, 101, ]` 这种残缺行。
      out = out.replaceAll(RegExp(',\\s*$name\\*'), '');
    } else {
      final body = '[${nested
          .map((r) => r.toLine())
          .where((c) => c.trim().isNotEmpty)
          .join(', ')}]';
      out = out.replaceAll(RegExp('(?<![A-Za-z0-9_])$name\\*'), body);
    }
  }
  return out;
}

/// 整串序列化：顶层行按序输出；行间 `; `、行内 `, `，与 ValueCodec.encode 风格一致。
///
/// 子行的归属（D8）：父行带 rest 槽时子行**内联**进父行（见 [_assembleRowCode]），
/// 不再另起一行；没有 rest 槽的容器行（如测试里手搓的 `[998, …]` 无槽形态）仍
/// 沿用「父行 + 紧跟子行」的旧形态。
String serializeBlockRows(List<EffectBlockRow> rows) {
  final lines = <String>[];
  void emit(List<EffectBlockRow> rs) {
    for (final r in rs) {
      final c = r.toLine();
      if (c.trim().isNotEmpty) lines.add(c);
      if (r.nested.isNotEmpty && !r.inlinesNested) emit(r.nested);
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
      builder: (ctx) => AppContentDialog(
        preferredWidth: 600,
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
    this.onUnparsedChanged,
  });

  final String initialText;
  final String mode;
  final Map<String, dynamic> gameDicts;

  /// 解析状态回调（D7）：true = 当前文本无法拆成积木（内嵌形态下会退化为只读
  /// 原文）。宿主据此决定要不要露「仅此字段文本编辑」的字段级逃生口。
  final ValueChanged<bool>? onUnparsedChanged;

  /// 单行约束（screenEffect：一句话只能一个屏幕效果）。true 时加行按钮禁用并提示。
  final bool singleRow;
  final String title;

  /// 内嵌形态（简易模式）：直接铺进字段行，**没有任何文本输入**——
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
  String? _summary; // 头部汇总（logic_error：N 行有问题；partial：N 行未识别）
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
    _summary = null;
    _rows = [];
    _rawCtrl.text = text;
    _loadText(text);
  }

  Future<void> _loadInitial() => _loadText(widget.initialText);

  Future<void> _loadText(String raw) async {
    final t = raw.trim();
    if (t.isEmpty) {
      if (mounted) {
        setState(() {
          _loading = false;
          _summary = null;
          _loadError = null;
        });
        widget.onUnparsedChanged?.call(false);
      }
      return;
    }
    final o = await parseEffectOutcome(t, widget.mode);
    if (!mounted) return;
    setState(() {
      _loading = false;
      _summary = null;
      switch (o.status) {
        // 整体不可拆：展示后端 message（不再统一灰字），保留原文只读。
        // D4：json_error 追加「第 N 个字符附近」定位。
        case kParseStatusError:
        case kParseStatusJsonError:
        case kParseStatusMissingBracket:
          _rows = [];
          _loadError = switch (o.status) {
            kParseStatusJsonError => o.jsonErrorText,
            kParseStatusMissingBracket => o.message ?? '缺少外层方括号',
            _ => o.message ??
                (widget.embedded
                    ? '这段内容暂时无法拆成积木，已按原样保留'
                    : '当前文本无法解析，可在下方「原始文本」中修正后重新应用'),
          };
          break;
        default:
          _loadError = null;
          _rows = o.rows;
          if (o.rows.isNotEmpty) _rawCtrl.text = serializeBlockRows(_rows);
          if (o.fixedText != null && o.status == kParseStatusOk) {
            // 缺括号自动补全成功：提示，但不主动写回（用户未编辑不影响数据）。
            _hint = o.message ?? '已自动补全外层括号';
          } else if (o.status == kParseStatusLogicError) {
            final n = o.errorRowCount;
            _summary = n > 0
                ? '$n 行有问题，可直接修改对应参数'
                : (o.message ?? '部分行有问题');
          } else if (o.status == kParseStatusPartial) {
            final n = _rows.where((r) => r.unrecognized).length;
            _summary = n > 0
                ? '$n 行未识别，已按原样保留（不修改则不影响保存）'
                : (o.message ?? '部分行未能识别');
          } else if (o.status == kParseStatusEmpty) {
            _rows = [];
          }
      }
    });
    // D7：把「拆不动」上报宿主（在 setState 之后调用，避免 build 期间回调）。
    widget.onUnparsedChanged?.call(_loadError != null);
  }

  // ---------- 行操作 ----------
  //
  // D8：嵌套子行补齐增删移。此前子行只能改槽/取反，结构改动必须回原始文本；
  // 现在父行带 rest 槽（`EFFECTS*`）时子行会内联进父行（见 [_assembleRowCode]），
  // 因此增删移是往返安全的。所有操作都作用在「宿主列表」上：顶层传 [_rows]，
  // 子行传其父行的 `nested`。

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

  void _moveIn(List<EffectBlockRow> host, int i, int delta) {
    final j = i + delta;
    if (i < 0 || j < 0 || i >= host.length || j >= host.length) return;
    setState(() {
      final r = host.removeAt(i);
      host.insert(j, r);
      _afterRowsChanged();
    });
  }

  /// 删除 host[i]。删的是子行且该组被删空时，容器行已无意义（会序列化出
  /// `[998, …]` 这种残缺组），一并移除 [owner]，并提示用户（D8）。
  void _deleteIn(
    List<EffectBlockRow> host,
    int i, {
    EffectBlockRow? owner,
    List<EffectBlockRow>? ownerHost,
  }) {
    if (i < 0 || i >= host.length) return;
    setState(() {
      host.removeAt(i);
      if (owner != null && host.isEmpty) {
        (ownerHost ?? _rows).remove(owner);
        _hint = '容器行已无子行，已一并移除';
      }
      _afterRowsChanged();
    });
  }

  void _duplicateIn(List<EffectBlockRow> host, int i) {
    // 单行约束只对顶层（screenEffect）生效。
    if (identical(host, _rows) &&
        !blockCanAddRow(singleRow: widget.singleRow, rowCount: _rows.length)) {
      setState(() => _hint = kSingleRowHint);
      return;
    }
    if (i < 0 || i >= host.length) return;
    setState(() {
      host.insert(i + 1, host[i].copy());
      _afterRowsChanged();
    });
  }

  /// 给容器行追加一条子行（D8）：走目录浏览器 → 拆成行 → 插到父行 nested 末尾。
  Future<void> _addChildRow(EffectBlockRow parent) async {
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
      parent.nested.add(
        (rows != null && rows.isNotEmpty) ? rows.first : EffectBlockRow(rawCode: code),
      );
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
      setState(() => _hint = r.unrecognized
          ? '未识别的行不可编辑（可删除后重新添加）'
          : (r.hasTemplate ? '该行没有可编辑参数槽' : '该行无模板，请在原始文本中编辑'));
      return;
    }
    final res = await showSlotValueEditor(
      context,
      slots: r.editableSlots,
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

  /// A2：行内切换算符——同族变体直接改写模板并保留已填槽值；变体需要新槽
  /// （如范围的上下限）还没有值时，打开槽表单补填后再切换。
  Future<void> _switchOp(EffectBlockRow r, EffectOpVariant v) async {
    if (r.op == v.op) return;
    if (switchRowOp(r, v)) {
      setState(_afterRowsChanged);
      return;
    }
    if (v.slots.isEmpty) return;
    final res = await showSlotValueEditor(
      context,
      slots: v.slots,
      initialValues: r.values,
      gameDicts: widget.gameDicts,
      templateCode: v.code,
      templateDesc: r.templateDesc,
      title: '切换为「${v.displayOp}」',
    );
    if (res == null || !mounted) return;
    setState(() {
      r
        ..templateCode = v.code
        ..slots = List<SuggestionSlot>.of(v.slots)
        ..values = res
        ..op = v.op;
      _afterRowsChanged();
    });
  }

  /// 加行：走目录浏览器 → 得完整码 → 回填成行（再 parse 拿回模板/槽以便二次编辑）。
  Future<void> _addRow() async {
    if (!blockCanAddRow(singleRow: widget.singleRow, rowCount: _rows.length)) {
      setState(() => _hint = kSingleRowHint);
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
      applyRowsWithSingleRow(_rows, [row], singleRow: widget.singleRow);
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
        _summary = null;
      });
      return;
    }
    final o = await parseEffectOutcome(t, widget.mode);
    if (!mounted) return;
    switch (o.status) {
      case kParseStatusOk:
      case kParseStatusEmpty:
      case kParseStatusLogicError:
      case kParseStatusPartial:
        setState(() {
          _rows = o.rows;
          _rawCtrl.text = o.fixedText ?? serializeBlockRows(_rows);
          _summary = o.status == kParseStatusLogicError && o.errorRowCount > 0
              ? '${o.errorRowCount} 行有问题，可直接修改对应参数'
              : (o.status == kParseStatusPartial
                  ? '部分行未识别，已按原样保留'
                  : null);
          _hint = o.fixedText != null ? (o.message ?? '已自动补全外层括号') : null;
        });
      default:
        // D1：失败原因以「说明 + 后端 message」呈现（不吞掉具体原因，也让用户
        // 一眼知道是「解析失败」而非别的提示）。D4：json_error 带字符定位。
        final msg = o.status == kParseStatusJsonError
            ? o.jsonErrorText
            : (o.message ?? '').trim();
        setState(() => _hint =
            msg.isEmpty ? '原始文本解析失败，已保留当前积木' : '解析失败：$msg');
    }
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
            borderRadius: BorderRadius.circular(AppRadius.xxs),
            border: Border.all(color: palette.border),
          ),
          child: SelectableText(
            widget.initialText,
            style: const TextStyle(fontSize: 11, fontFamily: 'Consolas'),
          ),
        ),
        const SizedBox(height: 4),
        Text('如需手改，请切换到高级编辑（设置页 / 状态栏开关）。',
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
    final banner = _summaryBanner();
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
          if (banner != null) ...[banner, const SizedBox(height: 8)],
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
      for (var i = 0; i < _rows.length; i++)
        _rowCard(_rows[i], i, top: true, host: _rows),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (banner != null) ...[banner, const SizedBox(height: 6)],
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

  /// 头部汇总（logic_error / partial）：提示「N 行有问题 / 未识别」但不阻断编辑。
  Widget? _summaryBanner() {
    final s = _summary;
    if (s == null || s.isEmpty) return null;
    return Container(
      key: const ValueKey('parse-summary'),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: palette.tintWarn,
        borderRadius: BorderRadius.circular(AppRadius.xxs),
        border: Border.all(color: palette.statusWarn),
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline, size: 13, color: palette.statusWarn),
          const SizedBox(width: 6),
          Expanded(
            child: Text(s,
                style: TextStyle(
                    fontSize: AppText.small,
                    color: palette.statusWarn,
                    height: 1.3)),
          ),
        ],
      ),
    );
  }

  Widget _addButton() {
    final disabled =
        !blockCanAddRow(singleRow: widget.singleRow, rowCount: _rows.length);
    return fluent.Button(
      key: const ValueKey('add-row'),
      onPressed: disabled ? null : _addRow,
      child: Text(
        widget.singleRow ? '$_addLabel（$kSingleRowHint）' : _addLabel,
        style: const TextStyle(fontSize: AppText.small),
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

  Widget _rowCard(
    EffectBlockRow r,
    int i, {
    required bool top,
    List<EffectBlockRow>? host,
    EffectBlockRow? owner,
    List<EffectBlockRow>? ownerHost,
  }) {
    final siblings = host ?? _rows;
    final line = r.toLine();
    final human = r.toHumanText(widget.gameDicts);
    final hasError = r.hasError;
    final body = Column(
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
                child: StatusPill('取反',
                    bg: palette.tintWarn, fg: palette.statusWarn),
              ),
            if (!r.hasTemplate && r.hasGenericSlots)
              Padding(
                padding: const EdgeInsets.only(left: 6),
                child: StatusPill('未收录',
                    bg: palette.overlayWeak, fg: palette.textSecondary),
              ),
            if (hasError)
              Padding(
                padding: const EdgeInsets.only(left: 6),
                child: StatusPill(
                    r.unrecognized ? '未识别行' : '异常',
                    bg: palette.tintDanger,
                    fg: palette.statusDanger),
              ),
          ],
        ),
        const SizedBox(height: 2),
        // 未识别行：原文只读、逐字节保留（不归一、不取反、不参与编辑）。
        if (r.unrecognized)
          SelectableText(
            line,
            style: TextStyle(
              fontSize: 10,
              fontFamily: 'Consolas',
              color: palette.textSecondary,
            ),
          )
        else
          Text(
            line,
            style: TextStyle(
              fontSize: 10,
              fontFamily: 'Consolas',
              color: palette.textSecondary,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        // A2：行内算符切换（同 family 多变体时出现；嵌套子行同样支持）。
        if (r.ops.length > 1 && !r.unrecognized)
          Padding(
            padding: const EdgeInsets.only(top: AppSpace.xs),
            child: BlockOpChips(
              keyPrefix: top ? 'op-$i' : 'op-$i-child',
              ops: r.ops,
              current: r.op,
              onPick: (v) => _switchOp(r, v),
              dense: true,
            ),
          ),
        if (hasError)
          Text(r.error!,
              style: TextStyle(
                  fontSize: AppText.dense,
                  color: palette.statusDanger,
                  height: 1.3)),
      ],
    );
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
                child: r.unrecognized
                    // 未识别行不可编辑：不包 InkWell，避免误开校验弹窗。
                    ? body
                    : InkWell(
                        key: top ? ValueKey('edit-$i') : ValueKey('nedit-$i'),
                        onTap: () => _editSlots(r),
                        child: body,
                      ),
              ),
              const SizedBox(width: 4),
              _rowActions(r, i, top: top, host: siblings, owner: owner, ownerHost: ownerHost),
            ],
          ),
          // 嵌套子行：缩进卡片。D8 起子行同样可增删移（在父组内），结构改动
          // 会内联回父行的嵌套数组（见 [_assembleRowCode]），往返安全。
          if (r.nested.isNotEmpty || r.inlinesNested || r.primary == 998)
            Padding(
              padding: const EdgeInsets.only(left: 16, top: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var ci = 0; ci < r.nested.length; ci++)
                    _rowCard(
                      r.nested[ci],
                      ci,
                      top: false,
                      host: r.nested,
                      owner: r,
                      ownerHost: siblings,
                    ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: fluent.Button(
                      key: top ? ValueKey('cadd-$i') : null,
                      onPressed: () => _addChildRow(r),
                      child: const Text('＋ 添加子行',
                          style: TextStyle(fontSize: AppText.dense)),
                    ),
                  ),
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

  Widget _rowActions(
    EffectBlockRow r,
    int i, {
    required bool top,
    required List<EffectBlockRow> host,
    EffectBlockRow? owner,
    List<EffectBlockRow>? ownerHost,
  }) {
    final negColor = r.negate ? palette.statusWarn : palette.textMuted;
    // 未识别行：只能删除（避免改坏）。保序保留，用户不碰就不动它。
    if (r.unrecognized) {
      return top
          ? _act('del-$i', '删除未识别行', Icons.delete_outline,
              onPressed: () => _deleteIn(host, i, owner: owner, ownerHost: ownerHost))
          : const SizedBox.shrink();
    }
    final neg = r.canNegate
        ? _act(top ? 'neg-$i' : 'neg-$i-child', r.negate ? '取消取反' : '取反', Icons.block,
            color: negColor, onPressed: () => _toggleNegate(r))
        : null;
    if (!top) {
      // 子行（D8）：取反 + 在父组内上移/下移/复制/删除。
      return Wrap(
        spacing: 2,
        children: [
          if (neg != null) neg,
          _act('cup-$i-child', '上移', Icons.arrow_upward,
              onPressed: i == 0 ? null : () => _moveIn(host, i, -1)),
          _act('cdown-$i-child', '下移', Icons.arrow_downward,
              onPressed: i >= host.length - 1 ? null : () => _moveIn(host, i, 1)),
          _act('ccopy-$i-child', '复制', Icons.copy,
              onPressed: () => _duplicateIn(host, i)),
          _act('cdel-$i-child', '删除子行', Icons.delete_outline,
              onPressed: () => _deleteIn(host, i, owner: owner, ownerHost: ownerHost)),
        ],
      );
    }
    return Wrap(
      spacing: 2,
      children: [
        if (neg != null) neg,
        _act('up-$i', '上移', Icons.arrow_upward,
            onPressed: i == 0 ? null : () => _moveIn(host, i, -1)),
        _act('down-$i', '下移', Icons.arrow_downward,
            onPressed: i >= host.length - 1 ? null : () => _moveIn(host, i, 1)),
        _act('copy-$i', '复制', Icons.copy, onPressed: () => _duplicateIn(host, i)),
        _act('del-$i', '删除', Icons.delete_outline,
            onPressed: () => _deleteIn(host, i, owner: owner, ownerHost: ownerHost)),
      ],
    );
  }
}
