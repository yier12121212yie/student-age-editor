/// 故事编排核心逻辑（移植自官方编辑器 story.py 的剧情处理器）。
///
/// 组织方式：以 EvtCfg 事件为入口，按 ID 前缀聚合属于该事件的全部
/// 对白（TalkCfg，ID 形如 `{事件ID}xxx`）与选项（OptionCfg，ID 形如 `{事件ID}xx`），
/// 形成一条可编排的"剧情线"。本文件只含纯函数，便于单测。
library;

/// 值清理：去空白、去掉数字末尾的 `.0`。
String cln(dynamic v) {
  if (v == null) return '';
  return v.toString().trim().replaceAll(RegExp(r'\.0$'), '');
}

/// 值 → 字符串列表（单值包一层，列表拍平一层）。
List<String> ensureList(dynamic v) {
  if (v == null || v == '') return [];
  if (v is List) return v.map((e) => e.toString()).toList();
  return [v.toString()];
}

/// 判断对白/选项 ID 是否属于某组前缀。
/// [isOption] 为 true 时按选项规则（ID 去掉后 2 位比对），否则按对白规则（去后 3 位）。
bool storyIsInPrefixes(List<String> prefixes, dynamic id, {bool isOption = false}) {
  final tid = cln(id);
  if (tid.isEmpty) return false;
  final clean = prefixes.map(cln).where((p) => p.isNotEmpty).toSet();
  if (clean.isEmpty) return false;
  final suffixLen = isOption ? 2 : 3;
  if (tid.length > suffixLen) {
    return clean.contains(tid.substring(0, tid.length - suffixLen));
  }
  return clean.contains(tid);
}

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
List<String> storyStartIds(String evtId, Map<String, dynamic> evtCfg, Map<String, dynamic> talks) {
  final info = evtCfg[cln(evtId)];
  var starts = <String>[];
  if (info is Map) {
    starts = [for (final s in ensureList(info['talkId'])) cln(s)].where((s) => s.isNotEmpty).toList();
  }
  if (starts.isEmpty) starts = ['${cln(evtId)}001'];
  if (talks.isNotEmpty) {
    starts = starts.where((s) => talks.containsKey(s)).toList();
  }
  if (talks.isNotEmpty && starts.isEmpty) {
    final prefixes = storyRelatedPrefixes(evtId, evtCfg);
    final eventTalks = talks.keys
        .map(cln)
        .where((k) => storyIsInPrefixes(prefixes, k))
        .toList()
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
    Map<String, dynamic>? curTalk, String newId, List<dynamic> next) {
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
String appendTalkId(String? currentId, String evtId, Map<String, dynamic> talks) {
  if (currentId != null) {
    final base = int.tryParse(cln(currentId));
    if (base == null) return '';
    var id = base + 1;
    while (talks.containsKey(id.toString())) {
      id++;
    }
    return id.toString();
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
void remapDeletedTarget(Map<String, dynamic> talks, Map<String, dynamic> options,
    List<String> prefixes, String deletedId, List<dynamic> replacementTargets) {
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

  for (final entry in talks.entries) {
    if (!storyIsInPrefixes(prefixes, entry.key)) continue;
    if (entry.value is! Map) continue;
    final v = entry.value as Map<String, dynamic>;
    for (final key in ['nextTalk', 'nextTalk2']) {
      remapTargetList(v, key);
    }
  }
  for (final entry in options.entries) {
    if (!storyIsInPrefixes(prefixes, entry.key, isOption: true)) continue;
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
void mergeStageBack(Map<String, dynamic> target, Map<String, dynamic> baseline,
    Map<String, dynamic> stage, List<String> prefixes, {bool isOption = false}) {
  for (final key in baseline.keys.toList()) {
    final ks = key.toString();
    if (storyIsInPrefixes(prefixes, ks, isOption: isOption) &&
        !stage.containsKey(key) &&
        !stage.containsKey(ks)) {
      target.remove(key);
    }
  }
  for (final entry in stage.entries) {
    target[entry.key] = entry.value;
  }
}

/// 把记录复制为舞台数据（仅保留属于该事件的 key，值深拷贝）。
Map<String, dynamic> stageOf(Map<String, dynamic> full, List<String> prefixes,
    {bool isOption = false}) {
  final out = <String, dynamic>{};
  for (final entry in full.entries) {
    if (storyIsInPrefixes(prefixes, entry.key, isOption: isOption)) {
      out[entry.key.toString()] = _deepCopy(entry.value);
    }
  }
  return out;
}

dynamic _deepCopy(dynamic v) {
  if (v is Map) {
    // 键统一转 String：避免 v 为无泛型 Map 时 map() 产生
    // _Map<dynamic, dynamic>，后续被 `as Map<String, dynamic>` 强转崩溃。
    return v.map((k, val) => MapEntry(k.toString(), _deepCopy(val)));
  }
  if (v is List) {
    return v.map(_deepCopy).toList();
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
