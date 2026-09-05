/// 剧情图字段值的类型驱动编解码：记录里的 JSON 值 ↔ 输入框里的展示文本。
///
/// 取代原先按字段名硬编码的 `switch (field)`：新增字段自动按 schema 类型正确
/// 读写，不会因为漏分支而被当成字符串写进存档。全部为纯函数，便于单测。
library;

import 'dart:convert';

import '../editor/field_utils.dart';
import 'story_logic.dart';

/// 字段类型（Number / String / 1D Array / 2D Array）；schema 无此字段返回 null。
String? cfgTypeOf(Map<String, dynamic> gameSchema, String cfg, String field) {
  final table = gameSchema[cfg];
  if (table is! Map) return null;
  final t = table[field];
  return t is String ? t : null;
}

/// 字段是否允许被编辑写回。`id` 是主键，插件扩表带来的未知类型一律拒写。
bool flowFieldWritable(Map<String, dynamic> gameSchema, String cfg, String field) {
  if (field.isEmpty || field == 'id') return false;
  return cfgTypeOf(gameSchema, cfg, field) != null;
}

/// 记录值 → 输入框文本。
///
/// - Number / String：`cln`
/// - 1D Array：逗号分隔的扁平代码文本（与指南「`4015,0.5`」写法一致）
/// - 2D Array：JSON（与内联编辑器历史文案一致，`[[1,2],[3,4]]`）
String encodeFieldValue(Map<String, dynamic> rec, String field, String type) {
  final v = rec[field];
  if (v == null) return '';
  switch (type) {
    case '1D Array':
      return normalizeStoryIdList(v).join(', ');
    case '2D Array':
      return jsonEncode(v);
    default:
      return cln(v);
  }
}

/// 输入框文本 → 记录值的三态结果。
///
/// [ok] 为 false 时调用方**不得**触碰记录，只标红：把「手滑打了半个 `-`」
/// 当成「用户想清空」会把好数据写坏（旧实现正是如此，`bg` 会当场落盘成缺省）。
/// [cleared] 为 true 表示用户清空了该字段，调用方应 `rec.remove(field)`。
class FieldDecode {
  const FieldDecode.ok(this.value)
    : ok = true,
      cleared = false;

  const FieldDecode.cleared()
    : ok = true,
      value = null,
      cleared = true;

  const FieldDecode.rejected()
    : ok = false,
      value = null,
      cleared = false;

  final bool ok;
  final bool cleared;
  final dynamic value;
}

/// 文本 → 记录值。未知类型拒写（不能猜，猜错就是污染存档）。
FieldDecode decodeFieldValue(String text, String? type) {
  final t = text.trim();
  switch (type) {
    case 'Number':
      if (t.isEmpty) return const FieldDecode.cleared();
      final n = num.tryParse(t) ?? num.tryParse(t.replaceAll(',', ''));
      if (n == null) return const FieldDecode.rejected();
      return FieldDecode.ok(n);
    case 'String':
      if (t.isEmpty) return const FieldDecode.cleared();
      return FieldDecode.ok(text);
    case '1D Array':
      if (t.isEmpty) return const FieldDecode.cleared();
      // 只切分＋转数值，不套 normalizeStoryIdList：那是 ID 列表专用规范化器，
      // 会把非整数落成字符串（0.5 → "0.5"），screenEffect 的时长参数就毁了。
      final list = ValueCodec.decode(t, '1D Array');
      return list is List && list.isNotEmpty
          ? FieldDecode.ok(list)
          : const FieldDecode.rejected();
    case '2D Array':
      if (t.isEmpty) return const FieldDecode.cleared();
      return _decode2d(t);
    default:
      return const FieldDecode.rejected();
  }
}

/// 2D Array 双解析：先按 JSON（兼容 `[[1,2],[3,4]]`），失败再按分隔符写法
/// （兼容 `1,2;3,4`）。出现方括号却解析不动，说明是半截 JSON —— 拒写而不是
/// 退化成 `ValueCodec.decode`，否则 `[[1,2` 会变成一堆垃圾行。
FieldDecode _decode2d(String t) {
  if (t.startsWith('[')) {
    try {
      final parsed = jsonDecode(t);
      if (parsed is List) return FieldDecode.ok(parsed);
      return const FieldDecode.rejected();
    } catch (_) {
      return const FieldDecode.rejected();
    }
  }
  final rows = ValueCodec.decode(t, '2D Array');
  return rows is List && rows.isNotEmpty
      ? FieldDecode.ok(rows)
      : const FieldDecode.rejected();
}

/// 便捷入口：把文本写进记录。返回 false 表示解析失败、记录未改动。
bool applyFieldText(
  Map<String, dynamic> rec,
  String field,
  String? type,
  String text,
) {
  final r = decodeFieldValue(text, type);
  if (!r.ok) return false;
  if (r.cleared) {
    rec.remove(field);
  } else {
    rec[field] = r.value;
  }
  return true;
}
