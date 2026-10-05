/// 条件 / 效果「积木库」的目录与分类引擎。
///
/// 「积木」= 一条指令行（如 `[1, 1, 3, 5]`）。本文件提供：
///   * [kBlockModes] —— 五个积木类别（条件 / 效果 / 指令 / 消耗 / 屏幕效果），
///     与 `/api/effect_suggest` 的 `mode` 参数一一对应；
///   * [BlockCategoryEngine] —— 按代码首元素 + 游戏自带
///     `ConditionTypeCfg` / `EffectTypeCfg` 归类（表缺失时用内置中文名兜底），
///     让目录能像游戏的指令类型表那样分组；
///   * [loadBlockCatalog] —— 拉取 `/api/effect_suggest` 候选（复用 [Suggestion]）。
///
/// 这里只做「目录/分类/取数」，行模型的解析与序列化仍由
/// `features/nocode/effect_block_editor.dart` 的 [EffectBlockRow] 单点负责。
library;

import '../../core/api_client.dart';
import '../editor/suggestion_text_field.dart';

/// 一个积木类别（对应 `/api/effect_suggest` 的一个 mode）。
class BlockMode {
  const BlockMode({
    required this.code,
    required this.label,
    required this.addLabel,
    required this.browserTitle,
    this.categoryTable,
  });

  /// mode 参数值。
  final String code;

  /// 顶部标签。
  final String label;

  /// 加行按钮 / 目录标题。
  final String addLabel;
  final String browserTitle;

  /// 类别来源表（`ConditionTypeCfg` / `EffectTypeCfg`）；null = 无官方类型表。
  final String? categoryTable;
}

const kBlockModes = <BlockMode>[
  BlockMode(
    code: 'condition',
    label: '条件',
    addLabel: '＋ 添加条件',
    browserTitle: '浏览条件',
    categoryTable: 'ConditionTypeCfg',
  ),
  BlockMode(
    code: 'effect',
    label: '效果',
    addLabel: '＋ 添加效果',
    browserTitle: '浏览效果',
    categoryTable: 'EffectTypeCfg',
  ),
  BlockMode(
    code: 'action',
    label: '指令',
    addLabel: '＋ 添加指令',
    browserTitle: '浏览人物指令',
  ),
  BlockMode(
    code: 'cost',
    label: '消耗',
    addLabel: '＋ 添加消耗',
    browserTitle: '浏览消耗',
  ),
  BlockMode(
    code: 'screen',
    label: '屏幕效果',
    addLabel: '＋ 添加屏幕效果',
    browserTitle: '浏览屏幕效果',
  ),
];

BlockMode blockModeFor(String code) => kBlockModes.firstWhere(
      (m) => m.code == code,
      orElse: () => kBlockModes[1],
    );

/// 内置条件类型名（游戏 `ConditionTypeCfg` 缺失时的兜底，取自原版表）。
const kConditionTypeNames = <int, String>{
  0: '概率',
  1: '年龄限制',
  2: '年月限制',
  3: '事件限制',
  4: '属性限制',
  5: '技能/成就/专长',
  6: '性格/人格/价值观',
  7: '社交',
  8: '状态与压力',
  10: '学习',
  11: '恋爱相关',
  12: '行动',
  13: '阅读',
  15: '目标',
  22: '同学机制',
  23: '空间',
  31: '舌战',
  34: '游戏',
  35: '创作',
  36: '动画（弃用）',
  38: '手工',
  42: '篮球',
  52: '恋爱',
  60: '物品限制',
  90: '庆典',
  100: '其他属性',
  101: 'UI与引导',
  111: '事件值限制',
  200: '结局/全局',
  333: '概率判断',
  999: '特殊',
};

/// 内置效果类型名（游戏 `EffectTypeCfg` 缺失时的兜底，取自原版表）。
const kEffectTypeNames = <int, String>{
  1: '改变属性',
  2: '价值观与人格',
  3: '改变技能',
  4: '学习',
  5: '改变性格',
  7: '改变状态',
  8: '人生观',
  10: '压力相关',
  20: '社交',
  21: '社交活动',
  22: 'NPC相关',
  23: '空间',
  30: '学习相关',
  31: '话术相关',
  32: '创作相关',
  33: '阅读',
  34: '游戏相关',
  40: '改变行动',
  41: '创作',
  42: '篮球',
  50: '改变事件',
  52: '恋爱',
  60: '改变物品',
  61: '商店相关',
  70: '改变目标、抱负',
  80: '金钱购物',
  90: '庆典',
  100: '常用',
  101: 'UI',
  160: '需求',
  998: 'NPC改变',
  999: '特殊效果',
};

/// 一行代码的首个数字（去掉方括号 / 忽略 `@NAME@` 与裸字母槽）。
int? blockPrimary(String code) {
  final t = code.replaceAll('[', '').replaceAll(']', '');
  for (final part in t.split(',')) {
    final v = int.tryParse(part.trim());
    if (v != null) return v;
  }
  return null;
}

/// 把模板 `desc` 变成**可读标题**（目录卡片主行）：
///   * `@NAME@` 占位符 → 槽标签（`@ATTR@`→「属性」、`@STATE@`→「状态」…）；
///   * 数字槽的裸字母（V/X/N…）→「数值」；
///   * 去掉未识别的 `@` 标记、折叠空白与相邻重复词（desc 常已含“属性”，
///     占位符又叫“属性”，折叠后不会出现「属性 属性」）。
///
/// 目录**只展示这个标题**，不再向用户暴露 `@ATTR@` 与原始代码。
String humanizeBlockDesc(String desc, List<SuggestionSlot> slots) {
  var out = desc;
  for (final s in slots) {
    if (s.kind != 'dict') continue;
    final label =
        s.label.isNotEmpty ? s.label : (s.dict.isNotEmpty ? s.dict : s.name);
    out = out.replaceAll('@${s.name}@', label);
  }
  // 未在 slots 里覆盖的占位符：去 @ 保留内部名，绝不外露 @。
  out = out.replaceAllMapped(RegExp(r'@([A-Za-z0-9_]+)@'), (m) => m.group(1) ?? '');
  for (final s in slots) {
    if (s.kind == 'dict') continue;
    final tok =
        RegExp('(?<![A-Za-z0-9_])${RegExp.escape(s.name)}(?![A-Za-z0-9_])');
    out = out.replaceAll(tok, '数值');
  }
  out = out.replaceAll(RegExp(r'\s+'), ' ').trim();
  final kept = <String>[];
  for (final p in out.split(' ')) {
    if (p.isEmpty) continue;
    if (kept.isNotEmpty && kept.last == p) continue; // 折叠相邻重复词
    kept.add(p);
  }
  return kept.join(' ');
}

/// 分类引擎：懒加载 `ConditionTypeCfg` / `EffectTypeCfg`，并缓存成本地映射。
class BlockCategoryEngine {
  BlockCategoryEngine._();
  static final BlockCategoryEngine instance = BlockCategoryEngine._();

  final Map<String, Map<int, String>> _typeNames = {};
  Future<void>? _loading;
  bool _loaded = false;

  bool get loaded => _loaded;

  Map<int, String> _fallbackFor(String table) =>
      table == 'ConditionTypeCfg' ? kConditionTypeNames : kEffectTypeNames;

  /// 加载两张官方类型表（失败静默，用内置名兜底）。
  Future<void> ensureLoaded() {
    if (_loaded) return Future.value();
    return _loading ??= _load();
  }

  Future<void> _load() async {
    for (final table in const ['ConditionTypeCfg', 'EffectTypeCfg']) {
      try {
        final r = await ApiClient.instance.get('/api/cfg/$table');
        final data = (r is Map && r['data'] is Map)
            ? (r['data'] as Map).cast<String, dynamic>()
            : <String, dynamic>{};
        final map = <int, String>{};
        for (final e in data.entries) {
          final id = int.tryParse(e.key);
          if (id == null || e.value is! Map) continue;
          final row = (e.value as Map).cast<String, dynamic>();
          final name = (row['name'] ?? row['title'] ?? '').toString().trim();
          if (name.isNotEmpty) map[id] = name;
        }
        if (map.isNotEmpty) _typeNames[table] = map;
      } catch (_) {
        // 后端不可达：保留内置兜底。
      }
    }
    _loaded = true;
  }

  /// 某条代码的类别名。
  String categoryFor(String mode, String code) {
    final m = blockModeFor(mode);
    final primary = blockPrimary(code);
    if (primary == null) return '其他';
    final table = m.categoryTable;
    if (table == null) return '类型 $primary';
    final name = _typeNames[table]?[primary] ?? _fallbackFor(table)[primary];
    return name ?? '类型 $primary';
  }

  /// 一组候选的类别清单（去重、稳定序、内含「全部」）。
  List<String> categoriesFor(String mode, Iterable<String> codes) {
    final seen = <String>{};
    final out = <String>['全部'];
    for (final c in codes) {
      final cat = categoryFor(mode, c);
      if (seen.add(cat)) out.add(cat);
    }
    return out;
  }
}

/// 拉取某 mode 的候选目录（`q` 为空时后端返回「最近使用 + 默认目录」）。
Future<List<Suggestion>> loadBlockCatalog(String mode, String q) async {
  try {
    final resp = await ApiClient.instance.get('/api/effect_suggest',
        query: {'q': q, 'mode': mode, 'limit': '1000'});
    final list = (resp is Map ? resp['items'] : null) as List? ?? const [];
    return [
      for (final e in list.cast<Map>())
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
    return const [];
  }
}
