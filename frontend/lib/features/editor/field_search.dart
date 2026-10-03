/// 编辑页「查找字段」的模糊匹配（纯函数，便于单测）。
///
/// 目标：在一条记录的字段表单里，按「标签 / 键 / 帮助文案 / 类型」快速定位
/// 可编辑字段。匹配共两层，命中任一层即可：
///   1. 子串（忽略大小写）——最直观，如 `名称` 命中 `名称`、`name` 命中 `name`；
///   2. 子序列——允许跳字连打，如 `nm` 命中 `name`。
/// 查询按空白拆成多词时，每个词都必须命中（可分别落在不同文本上）。
///
/// 说明：本实现按 UTF-16 code unit 逐个比较。字段标签/键以中文与 ASCII 为主，
/// `toLowerCase()` 不会改变它们的长度，故索引可安全复用；出现的匹配区间
/// 也就与原文索引一致。
library;

/// 子串 / 子序列的模糊得分；无命中返回 null，空查询返回 0。
///
/// 分值只用于排序，不承诺跨字段绝对可比：
/// - 完全相等 3000；前缀 2000；普通子串约 1000；子序列 300~900。
int? fuzzyScore(String query, String target) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return 0;
  final t = target.toLowerCase();
  if (t == q) return 3000;
  final idx = t.indexOf(q);
  if (idx == 0) return 2000;
  if (idx > 0) {
    // 越靠前分越高；目标越长、相对查询越长，略有衰减。
    final near = 100 - idx < 0 ? 0 : 100 - idx;
    final extraLen = t.length - q.length;
    final penalty = (extraLen < 0 ? 0 : extraLen) ~/ 4;
    return 1000 + near - penalty;
  }
  // 子序列：查询字符须按序出现。
  var ti = 0;
  var first = -1;
  var last = -1;
  for (var qi = 0; qi < q.length; qi++) {
    final c = q[qi];
    var found = -1;
    for (var j = ti; j < t.length; j++) {
      if (t[j] == c) {
        found = j;
        break;
      }
    }
    if (found < 0) return null;
    if (first < 0) first = found;
    last = found;
    ti = found + 1;
  }
  // 跨度越紧凑、起始越靠前，分越高。
  final span = last - first + 1;
  final lead = 100 - first < 0 ? 0 : 100 - first;
  return 300 + ((q.length / span) * 300).round() + lead ~/ 2;
}

/// 字段查找得分：在标签 / 键 / 帮助 / 类型上取加权最高分；任一查询词无命中
/// 则整个字段不匹配（返回 null）。标签与键权重最高，帮助与类型仅作辅助。
int? fuzzyFieldScore({
  required String query,
  required String label,
  required String key,
  String help = '',
  String type = '',
}) {
  final terms = query
      .trim()
      .toLowerCase()
      .split(RegExp(r'\s+'))
      .where((e) => e.isNotEmpty)
      .toList();
  if (terms.isEmpty) return 0;
  var total = 0;
  for (final term in terms) {
    int? best;
    void consider(String text, int weight) {
      final s = fuzzyScore(term, text);
      if (s == null) return;
      final w = s * weight;
      if (best == null || w > best!) best = w;
    }

    consider(label, 10);
    consider(key, 9);
    consider(help, 2);
    consider(type, 1);
    if (best == null) return null; // 有词未命中 → 整个字段不匹配
    total += best!;
  }
  return total;
}

/// 在 [target] 中定位 [query] 的匹配区间（`[start, end)` 半开）。
///
/// 优先整词子串；否则按子序列逐字符标记；多个查询词的结果取并集后合并为
/// 连续区间，供高亮渲染。无命中返回空列表。
List<(int, int)> fuzzyMatchRanges(String query, String target) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty || target.isEmpty) return const [];
  final lower = target.toLowerCase();
  final marked = List<bool>.filled(target.length, false);
  for (final term in q.split(RegExp(r'\s+')).where((e) => e.isNotEmpty)) {
    if (term.isEmpty) continue;
    final idx = lower.indexOf(term);
    if (idx >= 0) {
      final end = idx + term.length;
      for (var i = idx; i < end && i < marked.length; i++) {
        marked[i] = true;
      }
      continue;
    }
    // 子序列：按序找到每个字符。
    var ti = 0;
    final hits = <int>[];
    for (var qi = 0; qi < term.length; qi++) {
      final c = term[qi];
      var found = -1;
      for (var j = ti; j < lower.length; j++) {
        if (lower[j] == c) {
          found = j;
          break;
        }
      }
      if (found < 0) {
        hits.clear();
        break;
      }
      hits.add(found);
      ti = found + 1;
    }
    for (final h in hits) {
      if (h < marked.length) marked[h] = true;
    }
  }
  final out = <(int, int)>[];
  var i = 0;
  while (i < marked.length) {
    if (!marked[i]) {
      i++;
      continue;
    }
    final start = i;
    while (i < marked.length && marked[i]) {
      i++;
    }
    out.add((start, i));
  }
  return out;
}
