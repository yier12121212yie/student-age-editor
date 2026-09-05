/// 子图复制：把画布选中的对白/选项记录克隆进**当前舞台**的同两张表。
///
/// 为什么单独成文件：TalkCfg / OptionCfg 的 ID 既是主键又是边——
/// `nextTalk` / `nextTalk2` / `option` / `talkId` / `talkId2` 里存的就是目标 ID。
/// 所以「复制」的难点全在 ID 上，与画布渲染无关：
/// - 新 ID 不能撞上舞台上任何既有记录（含本轮刚分配的那几个），否则保存后
///   两条剧情线共用一个主键，后写的那条把前一条整条吃掉且毫无报错；
/// - 选中集**内部**的连线必须改指副本，不然副本会去给未选中节点接第二条线；
/// - 指向选区**外**的连线一律剪断（粘贴出去的入边属于别人的节点），
///   但 `nextEvtId` 这类跨事件字段是实义数值、不是本事件内的边，原样保留。
///
/// 全部是纯函数，只吃舞台 Map，便于单测；节点坐标由宿主 `_positions` 自己管。
library;

import 'story_logic.dart';

/// 对白记录里承载连线的字段（与 buildFlowGraph 的读边口径一致）。
const List<String> _talkLinkFields = ['nextTalk', 'nextTalk2'];

/// 选项记录里指向对白的字段。
const List<String> _optionLinkFields = ['talkId', 'talkId2'];

/// 对白指向选项的字段（单列一份：目标在另一张表，要换映射表查）。
const List<String> _talkOptionField = ['option'];

/// 把选中的子图复制进舞台：返回 旧 id → 新 id。
///
/// [talks] / [opts] 是**舞台副本**（已按当前事件前缀过滤，见 stageOf），
/// 本函数原地往里写新记录；[prefixes] 是当前事件前缀，用于判定 key 是
/// 对白还是选项、以及新 ID 是否还落在本事件段内。
///
/// 失败语义：**要么整组落盘、要么舞台一字不改**。ID 分配不出来时（对白编号
/// 逼近上限后 +1 会跨进下一事件、选项 01..99 用尽）返回空 Map，调用方应据此
/// 提示失败——半份粘贴会留下没有来源的孤儿节点，比不粘更糟。
/// [sourceTalks]/[sourceOpts] 用于「从剪贴板粘贴」：记录来自这两张表，
/// 但新 ID 的占用判定仍然只看目标舞台 [talks]/[opts]——否则会与舞台上原封不动
/// 留着的那批同源记录撞号。
Map<String, String> cloneSubgraphInto({
  required Set<String> selected,
  required Map<String, dynamic> talks,
  required Map<String, dynamic> opts,
  required List<String> prefixes,
  Map<String, dynamic>? sourceTalks,
  Map<String, dynamic>? sourceOpts,
}) {
  final matcher = PrefixMatcher(prefixes);
  final stageTalks = sourceTalks ?? talks;
  final stageOpts = sourceOpts ?? opts;
  final picked = <String>{
    for (final id in selected)
      if (cln(id).isNotEmpty) cln(id),
  };
  if (picked.isEmpty) return const <String, String>{};

  // 1) 取源记录。按舞台自身的遍历顺序（与 buildFlowGraph 建节点的顺序一致，
  //    同一份输入永远得到同一批新 ID），并用 PrefixMatcher 判类型：
  //    选项 ID 与对白 ID 只差一位后缀，硬按长度猜会把 1000001 认成选项。
  final srcTalks = <String, Map<String, dynamic>>{};
  for (final entry in stageTalks.entries) {
    final key = cln(entry.key);
    if (!picked.contains(key)) continue;
    if (!matcher.isEmpty && !matcher.match(key)) continue;
    final rec = _asRecord(entry.value);
    if (rec == null) continue;
    srcTalks[entry.key] = rec;
  }
  final claimed = <String>{for (final k in srcTalks.keys) cln(k)};
  final srcOpts = <String, Map<String, dynamic>>{};
  for (final entry in stageOpts.entries) {
    final key = cln(entry.key);
    if (!picked.contains(key)) continue;
    // 一个 ID 同时挂在两张表上（脏数据）时以对白为准：返回值只能有一个新 ID。
    if (claimed.contains(key)) continue;
    if (!matcher.isEmpty && !matcher.match(key, isOption: true)) continue;
    final rec = _asRecord(entry.value);
    if (rec == null) continue;
    srcOpts[entry.key] = rec;
  }
  if (srcTalks.isEmpty && srcOpts.isEmpty) return const <String, String>{};

  // 2) 先把全部新 ID 规划出来（不碰舞台），确认没有一个越界再落盘。
  final clonePrefix = _clonePrefix(
    matcher,
    firstTalkKey: srcTalks.isEmpty ? null : srcTalks.keys.first,
    firstOptionKey: srcOpts.isEmpty ? null : srcOpts.keys.first,
  );
  final talkMap = <String, String>{};
  if (srcTalks.isNotEmpty) {
    // appendTalkId 只看传入 Map 的 key，浅拷贝一份把本轮已分配的新 ID 也标成占用，
    // 于是同一批克隆不会互相撞号。
    final taken = Map<String, dynamic>.of(talks);
    for (final oldKey in srcTalks.keys) {
      final newId = appendTalkId(null, clonePrefix, taken);
      if (!_usable(newId, matcher)) return const <String, String>{};
      taken[newId] = const <String, dynamic>{};
      talkMap[oldKey] = newId;
    }
  }
  final optMap = <String, String>{};
  if (srcOpts.isNotEmpty) {
    // 候选串固定是 `{前缀}{01..99}`，已占用集合必须用 cln 归一后的 key，
    // 否则舞台上写成 '100001.0' 这类脏 key 会漏判、把在用 ID 再分配一次。
    final used = <String>{for (final k in opts.keys) cln(k)};
    for (final oldKey in srcOpts.keys) {
      final newId = allocOptionId(clonePrefix, used);
      if (newId == null || !_usable(newId, matcher, isOption: true)) {
        return const <String, String>{};
      }
      used.add(newId);
      optMap[oldKey] = newId;
    }
  }

  // 3) 落盘：深拷贝 → 改写自身 id → 只重映射选中集内部的引用。
  talkMap.forEach((oldKey, newId) {
    final rec = copyRecords(srcTalks[oldKey]!);
    rec['id'] = _asIdValue(newId);
    _remapLinks(rec, _talkLinkFields, talkMap);
    _remapLinks(rec, _talkOptionField, optMap);
    talks[newId] = rec;
  });
  optMap.forEach((oldKey, newId) {
    final rec = copyRecords(srcOpts[oldKey]!);
    rec['id'] = _asIdValue(newId);
    _remapLinks(rec, _optionLinkFields, talkMap);
    opts[newId] = rec;
  });
  return <String, String>{...talkMap, ...optMap};
}

/// 引用字段重映射：命中选中集的换成新 ID，其余（指向选区外）剪断。
/// 写回统一走 normalizeStoryIdList：数字串归一成 int，与 buildFlowGraph
/// 读边时 `cln(t)` 的口径一致，避免同一目标一次是 int 一次是字符串。
void _remapLinks(
  Map<String, dynamic> rec,
  List<String> fields,
  Map<String, String> mapping,
) {
  final byOld = <String, String>{
    for (final e in mapping.entries) cln(e.key): e.value,
  };
  for (final field in fields) {
    if (!rec.containsKey(field)) continue;
    final out = <dynamic>[];
    for (final target in normalizeStoryIdList(rec[field])) {
      final newId = byOld[cln(target)];
      if (newId == null) continue;
      if (out.any((e) => cln(e) == newId)) continue; // 源里重复的目标只留一条
      out.add(newId);
    }
    rec[field] = normalizeStoryIdList(out);
  }
}

/// 副本落在的事件段前缀：与「添加节点」同源，取首个选中对白 ID 去掉后 3 位；
/// 只选中选项时退到该选项 ID 命中的前缀。整份粘贴因此落在同一个号段里。
String _clonePrefix(
  PrefixMatcher matcher, {
  String? firstTalkKey,
  String? firstOptionKey,
}) {
  if (firstTalkKey != null) return getTalkPrefix(firstTalkKey);
  if (firstOptionKey == null) return '';
  final id = cln(firstOptionKey);
  // 前缀集合里有命中就用它（长前缀优先），否则按选项规则去后 2 位。
  final hits =
      matcher.clean
          .where((p) => id.length > p.length && id.startsWith(p))
          .toList()
        ..sort((a, b) => b.length.compareTo(a.length));
  if (hits.isNotEmpty) return hits.first;
  return id.length > 2 ? id.substring(0, id.length - 2) : id;
}

/// 新 ID 必须仍属于当前事件：对白编号逼近上限时 +1 会跨进下一事件
/// （1000999→1001000），这种节点图上看不见、保存后却会写进别的事件里。
/// 前缀表为空时不校验（与 workspace 的 `_talkIdUsable` 同规则）。
bool _usable(String id, PrefixMatcher matcher, {bool isOption = false}) =>
    id.isNotEmpty && (matcher.isEmpty || matcher.match(id, isOption: isOption));

/// 记录值 → 可写回字段的 Map。非 Map（脏行）返回 null，由调用方跳过。
Map<String, dynamic>? _asRecord(dynamic value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) return value.map((k, v) => MapEntry(k.toString(), v));
  return null;
}

/// 记录主键字段（`id`）与 Map key 保持同型：能转 int 就转 int。
dynamic _asIdValue(String newId) => int.tryParse(newId) ?? newId;
