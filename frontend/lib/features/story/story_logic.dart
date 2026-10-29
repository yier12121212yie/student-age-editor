/// 故事编排核心逻辑（移植自官方编辑器 story.py 的剧情处理器）。
///
/// 组织方式：以 EvtCfg 事件为入口，按 ID 前缀聚合属于该事件的全部
/// 对白（TalkCfg，ID 形如 `{事件ID}xxx`）与选项（OptionCfg，ID 形如 `{事件ID}xx`），
/// 形成一条可编排的"剧情线"。本文件只含纯函数，便于单测。
library;

/// 值清理：去空白、去掉数字末尾的 `.0`。
/// 全表扫描时逐行调用：模式复用 + 只在确有可能时才扫描（见 bench A1）。
final RegExp _tailZero = RegExp(r'\.0$');

String cln(dynamic v) {
  if (v == null) return '';
  final s = v.toString().trim();
  return s.endsWith('.0') ? s.replaceAll(_tailZero, '') : s;
}

/// 简易模式的事件 ID 自动分配：在 `min..max` 家族内取第一个空闲位。
/// 优先「最大已用 + 1」，被占则顺序上探；上探越过 `max`（上界本身被占用）
/// 时从 `min` 回绕扫描区间内的首个空闲 ID。家族全占时：给了 [fallbackStart]
/// 则从它起向上分配，否则返回 null。
///
/// 导演视图用 8000~8999（[fallbackStart] 9000）、剧情工作台用 7 位 `1xxxxxx`，
/// 两者共用本函数。
String? allocEventId(
  Iterable<String> existing, {
  int min = 1000000,
  int max = 1999999,
  int? fallbackStart,
}) {
  final ids = {for (final s in existing) s};
  var maxN = min - 1;
  var seen = false;
  for (final s in ids) {
    final n = int.tryParse(s);
    if (n != null && n >= min && n <= max) {
      seen = true;
      if (n > maxN) maxN = n;
    }
  }
  var id = seen ? maxN + 1 : min;
  while (id <= max && ids.contains(id.toString())) {
    id++;
  }
  if (id <= max) return id.toString();
  // 递增扫描越过上界（上界被占用）：从 min 回绕找第一个空闲 ID。
  for (var i = min; i <= max; i++) {
    if (!ids.contains(i.toString())) return i.toString();
  }
  if (fallbackStart == null) return null;
  // 区间全占：从 fallbackStart 起向上分配（与区间外 ID 共存）。
  var f = fallbackStart;
  while (ids.contains(f.toString())) {
    f++;
  }
  return f.toString();
}

/// 值 → 字符串列表（单值包一层，列表拍平一层）。
List<String> ensureList(dynamic v) {
  if (v == null || v == '') return [];
  if (v is List) return v.map((e) => e.toString()).toList();
  return [v.toString()];
}

/// 一组对白/选项前缀的匹配器。
///
/// [storyIsInPrefixes] 每次调用都要把前缀列表规范化成一个 Set，而
/// [stageOf] / [mergeStageBack] 对整张 TalkCfg（真实约 9.8 万行）逐行调用它
/// —— 等于每行一次 Set 分配。循环侧改用本类，Set 只建一次。
class PrefixMatcher {
  PrefixMatcher(Iterable<String> prefixes) {
    for (final p in prefixes) {
      final c = cln(p);
      if (c.isNotEmpty) clean.add(c);
    }
  }

  final Set<String> clean = {};

  bool get isEmpty => clean.isEmpty;

  /// [isOption] 为 true 按选项规则（ID 去后 2 位），否则对白规则（去后 3 位）。
  bool match(dynamic id, {bool isOption = false}) {
    if (clean.isEmpty) return false;
    final tid = cln(id);
    if (tid.isEmpty) return false;
    final suffixLen = isOption ? 2 : 3;
    if (tid.length > suffixLen) {
      return clean.contains(tid.substring(0, tid.length - suffixLen));
    }
    return clean.contains(tid);
  }
}

/// 判断对白/选项 ID 是否属于某组前缀。
/// [isOption] 为 true 时按选项规则（ID 去掉后 2 位比对），否则按对白规则（去后 3 位）。
///
/// 单次判定用这个即可；**逐行扫描整张表请改用 [PrefixMatcher.match]**，
/// 否则每行都会重建前缀 Set。
bool storyIsInPrefixes(
  List<String> prefixes,
  dynamic id, {
  bool isOption = false,
}) => PrefixMatcher(prefixes).match(id, isOption: isOption);

/// 从 EvtCfg 推导某事件相关的全部前缀：事件 ID 本身 + 首句对白 ID 去掉后 3 位。
/// 长前缀排前面（匹配时优先命中更长前缀，与官方 reverse=True 一致）。
List<String> storyRelatedPrefixes(String evtId, Map<String, dynamic> evtCfg) {
  final evtIdStr = cln(evtId);
  final prefixes = <String>{if (evtIdStr.isNotEmpty) evtIdStr};
  final info = evtCfg[evtIdStr];
  if (info is Map) {
    for (final startId in ensureList(info['talkId'])) {
      final s = cln(startId);
      if (s.length >= 4) {
        prefixes.add(s.substring(0, s.length - 3));
      } else if (s.isNotEmpty) {
        prefixes.add(s);
      }
    }
  }
  final list = prefixes.toList();
  list.sort((a, b) => b.length.compareTo(a.length));
  return list;
}

/// ID 列表规范化：字符串数字 → int，嵌套列表拍平，空值剔除。
List<dynamic> normalizeStoryIdList(dynamic value) {
  final result = <dynamic>[];
  if (value == null || value == '') return result;
  final items = value is List ? value : [value];
  for (final item in items) {
    if (item is List) {
      result.addAll(normalizeStoryIdList(item));
      continue;
    }
    final s = cln(item);
    if (s.isEmpty) continue;
    result.add(int.tryParse(s) ?? s);
  }
  return result;
}

/// 当前事件的起始对白 ID 列表（EvtCfg.talkId），为空时回退 `{evtId}001`。
List<String> storyStartIds(
  String evtId,
  Map<String, dynamic> evtCfg,
  Map<String, dynamic> talks,
) {
  final info = evtCfg[cln(evtId)];
  var starts = <String>[];
  if (info is Map) {
    starts = [for (final s in ensureList(info['talkId'])) cln(s)]
        .where((s) => s.isNotEmpty)
        .toList();
  }
  if (starts.isEmpty) starts = ['${cln(evtId)}001'];
  if (talks.isNotEmpty) {
    starts = starts.where((s) => talks.containsKey(s)).toList();
  }
  if (talks.isNotEmpty && starts.isEmpty) {
    final matcher = PrefixMatcher(storyRelatedPrefixes(evtId, evtCfg));
    final eventTalks = talks.keys.map(cln).where(matcher.match).toList()
      ..sort((a, b) {
        final an = int.tryParse(a);
        final bn = int.tryParse(b);
        if (an != null && bn != null) return an.compareTo(bn);
        return a.compareTo(b);
      });
    if (eventTalks.isNotEmpty) starts = [eventTalks.first];
  }
  final unique = <String>[];
  for (final s in starts) {
    if (s.isNotEmpty && !unique.contains(s)) unique.add(s);
  }
  return unique;
}

/// 当前对白 ID 的选项前缀（对白 ID 去掉后 3 位）。
String getTalkPrefix(String talkId) {
  final s = cln(talkId);
  if (s.length > 3) return s.substring(0, s.length - 3);
  return s;
}

/// 删除 nextTalk 为空的对白时的回退：返回同对白前缀下 ID 大于 [deletedId]
/// 的最小对白 ID（"后续最近的同事件对白"，兑现 [remapDeletedTarget]
/// 注释承诺）；无候选返回 null。
String? nextTalkInEvent(Iterable<String> talkKeys, String deletedId) {
  final del = int.tryParse(cln(deletedId));
  if (del == null) return null;
  final prefix = getTalkPrefix(deletedId);
  String? best;
  int? bestId;
  for (final k in talkKeys) {
    final ks = cln(k);
    final n = int.tryParse(ks);
    if (n == null || n <= del) continue;
    if (getTalkPrefix(ks) != prefix) continue;
    if (bestId == null || n < bestId) {
      bestId = n;
      best = ks;
    }
  }
  return best;
}

/// 分配一个未占用的选项 ID：`{前缀}{01..99}`。
/// [used] 为已占用的 ID 集合（含 base 数据）。
String? allocOptionId(String prefix, Set<String> used) {
  final p = cln(prefix);
  for (var i = 1; i < 100; i++) {
    final candidate = '$p${i.toString().padLeft(2, '0')}';
    if (!used.contains(candidate)) return candidate;
  }
  return null;
}

/// 插入对话：在当前对白后插入一个新节点（ID = 当前 ID + 1，跳过已占用）。
/// 新节点继承原节点的 nextTalk；原节点 nextTalk 指向新节点。
String insertTalkId(String currentId, Map<String, dynamic> talks) {
  final base = int.tryParse(cln(currentId));
  if (base == null) return '';
  var id = base + 1;
  while (talks.containsKey(id.toString())) {
    id++;
  }
  return id.toString();
}

/// 构建「插入对话」的新节点记录。
/// roleIds 复制而非引用原节点列表，避免新旧节点共享同一个 List，
/// 后续任一方原地修改（编辑器增删角色）互相污染；元素类型保持原样
/// （数字仍是数字，避免 ensureList 的 toString 造成类型漂移）。
Map<String, dynamic> buildInsertedTalkRecord(
  Map<String, dynamic>? curTalk,
  String newId,
  List<dynamic> next,
) {
  dynamic rawIds = curTalk?['roleIds'];
  List<dynamic> roleIds;
  if (rawIds is List) {
    roleIds = List<dynamic>.from(rawIds);
  } else if (rawIds == null || rawIds == '') {
    roleIds = <dynamic>[];
  } else {
    roleIds = [rawIds];
  }
  return {
    'id': int.parse(newId),
    'roleIds': roleIds,
    'content': '【新插入的对话】',
    'nextTalk': next,
    'nextTalk2': <dynamic>[],
    'option': <dynamic>[],
  };
}

/// 新建对话：取当前 ID + 1 的下一个可用数字；无当前节点时用 `{前缀}001`。
String appendTalkId(
  String? currentId,
  String evtId,
  Map<String, dynamic> talks,
) {
  if (currentId != null) {
    // 有当前节点：与「插入对话」同一套「当前 ID + 1 跳过已占用」探针，
    // 直接复用以免两份实现漂移。
    return insertTalkId(currentId, talks);
  }
  var start = int.tryParse('${cln(evtId)}001') ?? 0;
  while (talks.containsKey(start.toString())) {
    start++;
  }
  return start.toString();
}

/// 删除对白后的引用重映射：
/// 所有指向被删节点的跳转（talk 的 nextTalk/nextTalk2、option 的 talkId/talkId2）
/// 替换为 [replacementTargets]（被删节点自己的 nextTalk；没有则取后续最近的同事件对白）。
void remapDeletedTarget(
  Map<String, dynamic> talks,
  Map<String, dynamic> options,
  List<String> prefixes,
  String deletedId,
  List<dynamic> replacementTargets,
) {
  final delStr = cln(deletedId);
  final delInt = int.tryParse(delStr);

  List<dynamic> remapOne(dynamic raw) {
    final t = cln(raw);
    if (t.isEmpty) return const [];
    final targetInt = int.tryParse(t);
    if (targetInt == null) return [t];
    if (delInt == null || targetInt != delInt) return [t];
    final mapped = <dynamic>[];
    for (final rep in replacementTargets) {
      final r = cln(rep);
      if (r.isEmpty) continue;
      final rInt = int.tryParse(r);
      if (rInt != null && rInt == delInt) continue;
      if (r == delStr) continue;
      mapped.add(rInt ?? r);
    }
    return mapped;
  }

  void remapTargetList(Map<String, dynamic> container, String key) {
    if (!container.containsKey(key)) return;
    final remapped = <dynamic>[];
    final seen = <String>{};
    for (final target in normalizeStoryIdList(container[key])) {
      for (final t in remapOne(target)) {
        final tk = cln(t);
        if (tk.isEmpty || seen.contains(tk)) continue;
        seen.add(tk);
        remapped.add(t);
      }
    }
    // 与官方保存时的 _normalize_stage_story_links 一致：
    // 数字字符串统一规范回 int，避免类型漂移。
    container[key] = normalizeStoryIdList(remapped);
  }

  final matcher = PrefixMatcher(prefixes);

  for (final entry in talks.entries) {
    if (!matcher.match(entry.key)) continue;
    if (entry.value is! Map) continue;
    final v = entry.value as Map<String, dynamic>;
    for (final key in ['nextTalk', 'nextTalk2']) {
      remapTargetList(v, key);
    }
  }
  for (final entry in options.entries) {
    if (!matcher.match(entry.key, isOption: true)) continue;
    if (entry.value is! Map) continue;
    final v = entry.value as Map<String, dynamic>;
    for (final key in ['talkId', 'talkId2']) {
      remapTargetList(v, key);
    }
  }
}

/// 把"舞台"（当前事件的编辑结果）合并回全量表：
/// 1) 删除 baseline 中属于该事件、但舞台里已不存在的 key；
/// 2) 舞台里的 key 覆盖全量表。
void mergeStageBack(
  Map<String, dynamic> target,
  Map<String, dynamic> baseline,
  Map<String, dynamic> stage,
  List<String> prefixes, {
  bool isOption = false,
}) {
  final matcher = PrefixMatcher(prefixes);
  for (final key in baseline.keys.toList()) {
    final ks = key.toString();
    if (matcher.match(ks, isOption: isOption) &&
        !stage.containsKey(key) &&
        !stage.containsKey(ks)) {
      target.remove(key);
    }
  }
  for (final entry in stage.entries) {
    // 合并必须深拷贝：舞台记录仍是 UI 持有并正在编辑的活对象，直接塞引用
    // 会让全量表别名持有它——用户"放弃修改"后舞台被 baseline 重建为新对象，
    // 被丢弃的旧对象仍被全量表引用，切走再切回时以"干净"状态复活并落盘。
    target[entry.key] = copyRecordValue(entry.value);
  }
}

/// 公开深比较（sameStage / diffStage 共用）：判断两份 JSON 值是否逐字段相等。
bool valueEquals(dynamic a, dynamic b) {
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (!b.containsKey(entry.key.toString())) return false;
      if (!valueEquals(entry.value, b[entry.key.toString()])) return false;
    }
    return true;
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!valueEquals(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
}

/// 增量补丁（S3）：舞台相对基线的「变化集」，随 `PUT /api/cfg/<t>` 的
/// `patch` 字段发往后端（cfg_store.apply_patch），替代 GET 全表 merge 全表。
class StagePatch {
  StagePatch({required this.set, required this.remove, required this.ifMatch});

  /// 变更/新增的行：{key: 深拷贝后的舞台值}
  final Map<String, dynamic> set;

  /// 被删除的行（基线∩前缀且舞台已不存在）
  final List<String> remove;

  /// 行级乐观锁：被变更行在基线中的原值——后端逐行深比对，
  /// 外部改动过这些行时返回 409 + conflicting_keys（不回全表）。
  final Map<String, dynamic> ifMatch;

  bool get isEmpty => set.isEmpty && remove.isEmpty;
}

/// 从舞台与基线推导增量补丁。与 [mergeStageBack] **逐 key 等价**：
/// 对同一张全量表，apply(patch) 的结果 == mergeStageBack(table, baseline, stage)。
/// （等价性由 test/cfg_patch_equivalence_test.dart 随机用例硬校验。）
StagePatch diffStage(
  Map<String, dynamic> baseline,
  Map<String, dynamic> stage,
  List<String> prefixes, {
  bool isOption = false,
}) {
  final matcher = PrefixMatcher(prefixes);
  final set = <String, dynamic>{};
  final remove = <String>[];
  final ifMatch = <String, dynamic>{};

  baseline.forEach((key, value) {
    final ks = key.toString();
    if (!matcher.match(ks, isOption: isOption)) return;
    if (!stage.containsKey(key) && !stage.containsKey(ks)) {
      // 基线有、舞台无 = 用户删除
      remove.add(ks);
      return;
    }
    final stageVal = stage.containsKey(key) ? stage[key] : stage[ks];
    if (!valueEquals(value, stageVal)) {
      set[ks] = copyRecordValue(stageVal);
      ifMatch[ks] = copyRecordValue(value);
    }
  });
  stage.forEach((key, value) {
    final ks = key.toString();
    if (baseline.containsKey(key) || baseline.containsKey(ks)) return;
    // 基线缺失 = 用户新增（mergeStageBack 会写入全部舞台行，
    // 这里同样不做前缀过滤，保持逐 key 等价）
    set[ks] = copyRecordValue(value);
  });
  return StagePatch(set: set, remove: remove, ifMatch: ifMatch);
}

/// 把记录复制为舞台数据（仅保留属于该事件的 key，值深拷贝）。
Map<String, dynamic> stageOf(
  Map<String, dynamic> full,
  List<String> prefixes, {
  bool isOption = false,
}) {
  final out = <String, dynamic>{};
  final matcher = PrefixMatcher(prefixes);
  for (final entry in full.entries) {
    if (matcher.match(entry.key, isOption: isOption)) {
      out[entry.key.toString()] = copyRecordValue(entry.value);
    }
  }
  return out;
}

/// 整表深拷贝（舞台基线、撤销快照都要与当前内容彻底脱钩）。
Map<String, dynamic> copyRecords(Map<String, dynamic> src) {
  final out = <String, dynamic>{};
  src.forEach((k, v) => out[k] = copyRecordValue(v));
  return out;
}

dynamic copyRecordValue(dynamic v) {
  if (v is Map) {
    // 键统一转 String：避免 v 为无泛型 Map 时 map() 产生
    // _Map<dynamic, dynamic>，后续被 `as Map<String, dynamic>` 强转崩溃。
    return v.map((k, val) => MapEntry(k.toString(), copyRecordValue(val)));
  }
  if (v is List) {
    return v.map(copyRecordValue).toList();
  }
  return v;
}

/// 对白记录排序比较（按数字 ID，非数字排后）。
int compareIds(dynamic a, dynamic b) {
  final an = int.tryParse(cln(a));
  final bn = int.tryParse(cln(b));
  if (an != null && bn != null) return an.compareTo(bn);
  if (an != null) return -1;
  if (bn != null) return 1;
  return cln(a).compareTo(cln(b));
}

/// 事件 ID 数字比较（用于事件列表排序）。
int compareEventIds(dynamic a, dynamic b) {
  final an = int.tryParse(cln(a));
  final bn = int.tryParse(cln(b));
  if (an != null && bn != null) return an.compareTo(bn);
  return cln(a).compareTo(cln(b));
}

// ---------------------------------------------------------------------------
// 舞台指令（TalkCfg.roles）
//
// roles **不是** "槽,人物,动作" CSV 字符串，而是指令行数组
// `[[roleId, 指令码, ...参数], ...]`（见 native stage_service.cpp STAGE_ACTIONS，
// 后端 preview build_stage 以此为真源）：
//   入场 1001 滑动 / 1002 直接 / 1003 底部，参数 [1, pos]（pos 1=左 2=右 3=中）
//   退场 2001 滑动 / 2002 直接
//   表情 3000 + expr（0..26）
//   动作 3001 微动 / 3002 震动 / 3005 转身 / 3006 换装 / 3007 镜像 / 3009 气泡
//   移动 3004 左右 / 3008 上下
// 之前剧情舞台把它当 CSV 解析，导致人物显示成错误 ID（如把入场指令码 1001 当角色）。
// 下列纯函数与后端 build_stage / preview_event 同口径，供 GUI / 移动端复用。
// ---------------------------------------------------------------------------

/// 游戏表情编号 → 中文名（0..26）。与后端 `stage_service.cpp:kExpressionNames`
/// 及 `semantic_core.cpp:expression_dict()` 同口径，供 GUI / 移动端复用。
///
/// 22=喜极而泣、26=尴尬（口径依据游戏本体 TalkCfg 实测：带 `[role,3000,22]` 的
/// 台词正文为「肖清雅流出了开心的泪水」；26 号与台词标注「（尴尬）」共现）。
const List<(int, String)> kEmotionNames = [
  (0, '默认'),
  (1, '开心'),
  (2, '生气'),
  (3, '伤心'),
  (4, '害羞'),
  (5, '喜欢'),
  (6, '认真'),
  (7, '疑惑'),
  (8, '惊讶'),
  (9, '得意'),
  (10, '微笑'),
  (11, '坏笑'),
  (12, '担心'),
  (13, '害怕'),
  (14, '难过'),
  (15, '咆哮'),
  (16, '窘迫'),
  (17, '不满'),
  (18, '冷笑'),
  (19, '无语'),
  (20, '苦笑'),
  (21, '挫败'),
  (22, '喜极而泣'),
  (23, '迷茫'),
  (24, '嫌弃'),
  (25, '俏皮'),
  (26, '尴尬'),
];

/// 表情编号 → 中文名；未知编号回退为「表情 N」。
String emotionNameOf(int expr) {
  for (final e in kEmotionNames) {
    if (e.$1 == expr) return e.$2;
  }
  return '表情 $expr';
}

/// 在场角色的舞台状态（单个 talk 内或跨 talk 累积）。
class StageCharState {
  StageCharState({
    required this.roleId,
    this.pos = 3,
    this.expr = 0,
    this.flip = false,
    this.present = false,
  });

  final String roleId;

  /// 站位：1=左 2=右 3=中。
  int pos;

  /// 表情编号 0..26。
  int expr;

  /// 是否水平翻转（镜像）。
  bool flip;

  /// 是否在场。
  bool present;
}

bool _isStageRow(dynamic row) => row is List && row.length >= 2;

/// 把一组 roles 指令作用到 [state] 上（可跨对白累积），语义同后端 build_stage。
void applyStageCommands(Map<String, StageCharState> state, dynamic roles) {
  if (roles is! List) return;
  for (final row in roles) {
    if (!_isStageRow(row)) continue;
    final r = row as List;
    final rid = cln(r[0]);
    if (rid.isEmpty) continue;
    final tid = int.tryParse(cln(r[1]));
    if (tid == null) continue;

    StageCharState touch() =>
        state.putIfAbsent(rid, () => StageCharState(roleId: rid));

    if (tid == 1001 || tid == 1002 || tid == 1003) {
      final e = touch();
      var pos = r.length > 3 ? (int.tryParse(cln(r[3])) ?? 3) : 3;
      if (pos != 1 && pos != 2) pos = 3;
      e.pos = pos;
      e.present = true;
    } else if (tid == 2001 || tid == 2002) {
      state[rid]?.present = false;
    } else if (tid == 3000) {
      // 3000（表情）本身即是「在场角色」的动作；单句对白若只写了这一条，
      // 必须一并标记在场，否则 parseStageChars 会把角色整条丢弃（角色消失
      // 或降级回默认），历史 bug 之一。
      final e = touch();
      e.expr = r.length > 2 ? (int.tryParse(cln(r[2])) ?? 0) : 0;
      e.present = true;
    } else if (tid == 3006) {
      // 3006（换装）同理：作为该角色唯一动作时也要维持在场。
      touch().present = true;
    } else if (tid == 3007) {
      final e = touch();
      e.flip = !e.flip;
      e.present = true;
    }
  }
}

/// 单个 talk 的显式舞台角色（不含跨对白继承），保持指令出现顺序。
List<StageCharState> parseStageChars(dynamic roles) {
  final s = <String, StageCharState>{};
  applyStageCommands(s, roles);
  return [for (final e in s.values) if (e.present) e];
}

/// 舞台状态深拷贝（BFS 分支隔离用）。
Map<String, StageCharState> _cloneStageState(
  Map<String, StageCharState> src,
) {
  return {
    for (final e in src.entries)
      e.key: StageCharState(
        roleId: e.value.roleId,
        pos: e.value.pos,
        expr: e.value.expr,
        flip: e.value.flip,
        present: e.value.present,
      ),
  };
}

/// 沿对白链（BFS，与后端 preview_event 同口径）计算每条对白的**有效**舞台：
/// talkId → 在场角色（含前面各句登场/退场/表情的累积）。
///
/// 队列元素携带**父节点状态的独立深拷贝**（`(tid, stateSnapshot)`），每个子
/// 分支只在自己的副本上累积。历史 bug：所有节点共享同一个可变 `state` Map，
/// 选项分支 A 里设置的表情/出退场会串进分支 B，导致不同分支表情错乱。
Map<String, List<StageCharState>> effectiveStages({
  required String evtId,
  required Map<String, dynamic> evtCfg,
  required Map<String, dynamic> talks,
  required Map<String, dynamic> options,
}) {
  final out = <String, List<StageCharState>>{};
  final seen = <String>{};
  final queue = <(String, Map<String, StageCharState>)>[];
  // 入队前判重（而不是出队时），并让状态快照**惰性构造**：被 [`seen`] 挡下的
  // 节点连克隆都不必做——同一父节点的多个子分支里只有一个会真正入队。
  void enqueue(String tid, Map<String, StageCharState> Function() makeState) {
    if (tid.isEmpty || !seen.add(tid)) return;
    queue.add((tid, makeState()));
  }

  for (final s in storyStartIds(evtId, evtCfg, talks)) {
    enqueue(cln(s), () => const <String, StageCharState>{});
  }

  // 索引游标遍历（替代 queue.removeAt(0) 的 O(N) 数组搬移）。
  for (var qi = 0; qi < queue.length; qi++) {
    final (tid, parentState) = queue[qi];
    final rec = talks[tid];
    if (rec is! Map) continue;
    // 每个节点在自己的深拷贝上应用指令：兄弟分支互不污染。无指令时直接沿用
    // 父快照（后续只读，不会被改写），省掉一次整状态克隆。
    final roles = rec['roles'];
    final hasCommands = roles is List && roles.isNotEmpty;
    final state = hasCommands ? _cloneStageState(parentState) : parentState;
    if (hasCommands) applyStageCommands(state, roles);
    out[tid] = [
      for (final e in state.values)
        if (e.present)
          StageCharState(
            roleId: e.roleId,
            pos: e.pos,
            expr: e.expr,
            flip: e.flip,
            present: true,
          ),
    ];
    // 子节点各自继承一份独立快照（同一父节点的多个子分支也不共享）。
    void enqueueChild(dynamic childId) {
      final cs = cln(childId);
      if (cs.isEmpty) return;
      enqueue(cs, () => _cloneStageState(state));
    }

    for (final oid in normalizeStoryIdList(rec['option'])) {
      final orec = options[cln(oid)];
      if (orec is! Map) continue;
      for (final branch in const ['talkId', 'talkId2']) {
        for (final b in normalizeStoryIdList(orec[branch])) {
          enqueueChild(b);
        }
      }
    }
    for (final key in const ['nextTalk', 'nextTalk2']) {
      for (final n in normalizeStoryIdList(rec[key])) {
        enqueueChild(n);
      }
    }
  }
  return out;
}

/// 对白节点的生效背景状态：当前有效背景 ID、是否继承自前文、来源对白 ID。
class EffectiveBgState {
  const EffectiveBgState({
    required this.bgId,
    this.isInherited = false,
    this.sourceTalkId,
  });

  /// 生效的背景 ID（如 "100"）。若整条链路无背景则为空串 ""。
  final String bgId;

  /// 是否继承自前文（true = 本句留空/0 延续；false = 本句显式切换）。
  final bool isInherited;

  /// 背景最初切换的对白 ID（若显式切换则为其自身 ID）。
  final String? sourceTalkId;
}

/// 沿对白链（与 effectiveStages 同口径）计算每条对白的生效背景：
/// talkId → 生效背景状态。
Map<String, EffectiveBgState> effectiveBackgrounds({
  required String evtId,
  required Map<String, dynamic> evtCfg,
  required Map<String, dynamic> talks,
  required Map<String, dynamic> options,
}) {
  final out = <String, EffectiveBgState>{};
  final starts = storyStartIds(evtId, evtCfg, talks);
  final seen = <String>{};
  final queue = <(String, String, String?)>[];
  void enqueue(String tid, String bg, String? src) {
    if (tid.isEmpty || !seen.add(tid)) return;
    queue.add((tid, bg, src));
  }

  for (final s in starts) {
    enqueue(cln(s), '', null);
  }

  // 索引游标遍历（替代 queue.removeAt(0) 的 O(N) 数组搬移）。
  for (var qi = 0; qi < queue.length; qi++) {
    final (tid, inheritBg, inheritSource) = queue[qi];
    final rec = talks[tid];
    if (rec is! Map) continue;

    final rawBg = cln(rec['bg']);
    final hasExplicit = rawBg.isNotEmpty && rawBg != '0';

    final String activeBg;
    final bool isInherited;
    final String? activeSource;

    if (hasExplicit) {
      activeBg = rawBg;
      isInherited = false;
      activeSource = tid;
    } else {
      activeBg = inheritBg;
      isInherited = inheritBg.isNotEmpty;
      activeSource = inheritSource;
    }

    out[tid] = EffectiveBgState(
      bgId: activeBg,
      isInherited: isInherited,
      sourceTalkId: activeSource,
    );

    for (final oid in normalizeStoryIdList(rec['option'])) {
      final orec = options[cln(oid)];
      if (orec is! Map) continue;
      for (final branch in const ['talkId', 'talkId2']) {
        for (final b in normalizeStoryIdList(orec[branch])) {
          enqueue(cln(b), activeBg, activeSource);
        }
      }
    }
    for (final key in const ['nextTalk', 'nextTalk2']) {
      for (final n in normalizeStoryIdList(rec[key])) {
        enqueue(cln(n), activeBg, activeSource);
      }
    }
  }

  for (final entry in talks.entries) {
    final tid = cln(entry.key);
    if (out.containsKey(tid)) continue;
    final rec = entry.value;
    if (rec is! Map) continue;
    final rawBg = cln(rec['bg']);
    if (rawBg.isNotEmpty && rawBg != '0') {
      out[tid] = EffectiveBgState(
        bgId: rawBg,
        isInherited: false,
        sourceTalkId: tid,
      );
    }
  }

  return out;
}

List<dynamic> _copyRoles(dynamic roles) {
  final v = copyRecordValue(roles);
  return v is List ? v.toList() : <dynamic>[];
}

dynamic _roleIdValue(String id) => int.tryParse(id) ?? id;

/// 设置角色入场站位（1=左 2=右 3=中）：已有入场指令改其 pos，否则追加滑动入场。
List<dynamic> setStagePos(dynamic roles, String roleId, int pos) {
  final id = cln(roleId);
  final out = _copyRoles(roles);
  for (final row in out) {
    if (_isStageRow(row) && cln((row as List)[0]) == id) {
      final tid = int.tryParse(cln(row[1]));
      if (tid == 1001 || tid == 1002 || tid == 1003) {
        while (row.length < 4) {
          row.add(0);
        }
        row[3] = pos;
        return out;
      }
    }
  }
  out.add(<dynamic>[_roleIdValue(id), 1001, 1, pos]);
  return out;
}

/// 设置角色表情（0..26）：已有 3000 指令改其 expr，否则追加。
List<dynamic> setStageExpr(dynamic roles, String roleId, int expr) {
  final id = cln(roleId);
  final out = _copyRoles(roles);
  for (final row in out) {
    if (_isStageRow(row) &&
        cln((row as List)[0]) == id &&
        int.tryParse(cln(row[1])) == 3000) {
      while (row.length < 3) {
        row.add(0);
      }
      row[2] = expr;
      return out;
    }
  }
  out.add(<dynamic>[_roleIdValue(id), 3000, expr]);
  return out;
}

/// 让角色退场：移除其全部指令并追加滑动退场（build_stage 会把其 present 置否）。
List<dynamic> removeStageRole(dynamic roles, String roleId) {
  final id = cln(roleId);
  final out = <dynamic>[
    for (final row in _copyRoles(roles))
      if (!(_isStageRow(row) && cln((row as List)[0]) == id)) row,
  ];
  out.add(<dynamic>[_roleIdValue(id), 2001]);
  return out;
}

/// 切换角色水平镜像（3007 镜像指令）：若已有 3007 指令则移除，否则追加。
List<dynamic> toggleStageFlip(dynamic roles, String roleId) {
  final id = cln(roleId);
  final out = _copyRoles(roles);
  var removed = false;
  out.removeWhere((row) {
    if (_isStageRow(row) &&
        cln((row as List)[0]) == id &&
        int.tryParse(cln(row[1])) == 3007) {
      removed = true;
      return true;
    }
    return false;
  });
  if (!removed) {
    out.add(<dynamic>[_roleIdValue(id), 3007]);
  }
  return out;
}

/// 角色引用替换：把 ID 列表（`roleIds` / `highlights`）中的 [oldRoleId]
/// 换成 [newRoleId]（仅当原列表确实包含 [oldRoleId]）。
///
/// 保持原有数值口径（数字 ID 写回仍为 int），顺带去重与剔除空值。
List<dynamic> replaceRoleRef(
  dynamic list,
  String oldRoleId,
  String newRoleId,
) {
  final oldId = cln(oldRoleId);
  final newId = cln(newRoleId);
  final src = normalizeStoryIdList(list);
  if (oldId.isEmpty || newId.isEmpty || oldId == newId) return src;
  final out = <dynamic>[];
  final seen = <String>{};
  var replaced = false;
  for (final item in src) {
    final cur = cln(item);
    final next = cur == oldId ? newId : cur;
    if (cur == oldId) replaced = true;
    if (next.isEmpty || !seen.add(next)) continue;
    out.add(int.tryParse(next) ?? next);
  }
  return replaced ? out : src;
}

/// 替换角色：把舞台指令中的 [oldRoleId] 替换为 [newRoleId]。
///
/// 与 [setStagePos] / [setStageExpr] / [removeStageRole] 同口径（纯函数，
/// 深拷贝后返回新列表，不修改入参）。
///
/// - 原指令中**显式包含** [oldRoleId] 的指令行：将其首项角色 ID 直接改写为
///   [newRoleId]（入场、表情、镜像、移动等动作全部随角色迁移）。若显式传入
///   [pos] / [expr] / [flip]，再确保新角色具备对应指令。
/// - 原指令中**未显式包含** [oldRoleId]（即角色由前序台词继承在场）：
///   追加 [oldRoleId] 的滑动退场（[removeStageRole]），再按相同站位与表情
///   追加 [newRoleId] 的入场/表情指令；[flip] 为 true 时追加镜像指令。
///
/// [pos] 为游戏站位（1=左 2=右 3=中），[expr] 为表情编号 0..26。
List<dynamic> replaceStageRole(
  dynamic roles,
  String oldRoleId,
  String newRoleId, {
  int? pos,
  int? expr,
  bool? flip,
}) {
  final oldId = cln(oldRoleId);
  final newId = cln(newRoleId);
  if (oldId.isEmpty || newId.isEmpty || oldId == newId) {
    return _copyRoles(roles);
  }

  var out = _copyRoles(roles);
  var explicit = false;
  for (final row in out) {
    if (_isStageRow(row) && cln((row as List)[0]) == oldId) {
      row[0] = _roleIdValue(newId);
      explicit = true;
    }
  }

  if (!explicit) {
    // 继承在场：让旧角色退场，再让新角色在相同站位/表情登场。
    out = removeStageRole(out, oldId);
    out = setStagePos(out, newId, pos ?? 3);
    if (expr != null) out = setStageExpr(out, newId, expr);
    if (flip == true) out = toggleStageFlip(out, newId);
    return out;
  }

  // 显式在场：ID 已改写，按需补齐/更新站位、表情与镜像指令。
  if (pos != null) out = setStagePos(out, newId, pos);
  if (expr != null) out = setStageExpr(out, newId, expr);
  if (flip != null) {
    bool hasFlipRow(dynamic row) =>
        _isStageRow(row) &&
        cln((row as List)[0]) == newId &&
        int.tryParse(cln(row[1])) == 3007;
    final hasFlip = out.any(hasFlipRow);
    if (flip && !hasFlip) {
      out.add(<dynamic>[_roleIdValue(newId), 3007]);
    } else if (!flip && hasFlip) {
      out.removeWhere(hasFlipRow);
    }
  }
  return out;
}
