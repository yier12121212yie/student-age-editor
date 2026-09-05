/// 剧情图（节点画布）字段候选来源：把五条通路收敛成一个 [sourceForField]。
///
/// 调用方（workspace 内联卡片 / Inspector）只拿到一个 [SuggestionSource] 塞进
/// `SuggestionTextField`，不关心数据从哪来、也不自己判要不要发请求。
///
/// 三条硬约束都是这个仓库里踩过的坑：
/// 1. **名称零请求**：`app.dart` 已把 `/api/dicts` 缓进 [AppState.gameDicts]，
///    MOD 侧名称来自工作区已加载的表（[FlowSuggestDeps.modTable]，同步命中内存）。
///    绝不为「补全」再发一次名字请求。
/// 2. **舞台内 ID 只能内存扫**：`/api/cfg_ids` 硬截断 500 条（见后端
///    `api.py` 的 `cfg_ids`），而原版 TalkCfg 约 9.8 万行。真拿它给
///    nextTalk / nextTalk2 / option / talkId / talkId2 当数据源，舞台内的下一句
///    会「静默」查无候选——用户看到的是下拉变空，而不是报错。
/// 3. **只有舞台外引用才走加载器**：选项的 nextEvtId（EvtCfg）、miniGame
///    （MinigameCfg）这类跨事件引用没有内存表可用，才走
///    [FlowSuggestDeps.offStageIds]（那条链路自带缓存）。
///
/// 候选文本匹配是本地来源自己做的事（后端 effect_suggest 自己做模糊匹配，
/// 所以 [httpEffectSource] 只把 token 原样当 `q` 传过去）。
library;

import '../../core/api_client.dart';
import '../../core/models.dart';
import '../editor/field_meta.dart';
import '../editor/field_utils.dart';
import '../editor/suggestion_text_field.dart';
import 'story_logic.dart';

/// 本地候选上限：真实表动辄上万行，全量塞进浮层既没必要也看不清。
const int kFlowSuggestLimit = 50;

/// 效果码表超时：比 ApiClient 默认的 60s 短得多——补全在按键路径上，
/// 后端没起来时宁可这一轮没候选，也不要把浮层挂住。
const Duration kFlowEffectSuggestTimeout = Duration(seconds: 5);

/// 舞台内宿主表：只有对白/选项节点活在「当前事件舞台」里。
const Set<String> kInStageHostCfgs = {'TalkCfg', 'OptionCfg'};

/// 舞台内目标表：对白/选项互相引用，候选必然落在舞台内存表中。
const Set<String> kInStageRefCfgs = {'TalkCfg', 'OptionCfg'};

/// 名称字典 → MOD 侧同类表：`state.gameDicts` 只有原版名，
/// 工作区已加载的这几张表要能覆盖同名 id（不覆盖就得为补全再发请求）。
const Map<String, String> kDictModTable = {
  'roles': 'PersonCfg',
  'bgs': 'BgCfg',
  'audios': 'AudioCfg',
  'evt_types': 'EvtTypeCfg',
  'items': 'ItemCfg',
  'maps': 'MapCfg',
  'jobs': 'JobCfg',
  'attrs': 'AttrCfg',
  'icons': 'IconCfg',
};

/// 原版 roles 字典里的「无角色」哨兵 key：它们不是可选对象。
const Set<String> _roleSentinels = {'-1', '0', '00', '000'};

/// 依赖注入包：避免把整个 workspace 传进来源函数。
class FlowSuggestDeps {
  FlowSuggestDeps({
    required this.state,
    required this.stageTalks,
    required this.stageOptions,
    required this.offStageIds,
    this.modTable,
  });

  final AppState state;

  /// 当前事件舞台内的对白记录（内存，每条须自带 `id`）。
  final List<Map<String, dynamic>> Function() stageTalks;

  /// 当前事件舞台内的选项记录（内存，每条须自带 `id`）。
  final List<Map<String, dynamic>> Function() stageOptions;

  /// 舞台外表的 `(id, preview)`，带缓存（宿主负责懒加载 `/api/cfg_ids`）。
  final Future<List<(String, String)>> Function(String cfg) offStageIds;

  /// 工作区已加载的 MOD 表读取器（同步、零请求）：cfg → 该表记录。
  ///
  /// 只用于「原版字典 + Mod 记录」的名称合并；省略时退化为只用原版字典，
  /// 不会因此丢候选，只是 MOD 新增条目没有名字。
  final Map<String, dynamic>? Function(String cfg)? modTable;

  /// 已解析来源的缓存：`'$cfg:${meta.key}'` → 来源（null 也缓存，用
  /// [Map.containsKey] 判断，不能靠非空）。
  ///
  /// 为什么必须记忆化：`SuggestionTextField.didUpdateWidget` 用
  /// `!identical(old, current)` 判断来源换没换，换就 `clearCandidates()`。
  /// 解析体每个分支返回的都是新建闭包，不记忆化的话宿主一次 setState 重建
  /// 就全部「换了」——用户正开着的候选浮层在拖拽画布中悄悄消失。
  final Map<String, SuggestionSource?> _memo = {};

  /// 该字段的候选来源（记忆化版）：同一 (cfg, meta) 在本 deps 生命周期内
  /// 恒返回同一实例；不需要补全的字段返回 null（同样被缓存）。
  ///
  /// 记忆化是安全的：解析体 [_resolveFlowSource] 的输入只有 (cfg, meta) 与
  /// 本类构造期注入的 final 字段，各来源闭包都在**每次查询时**才读舞台、
  /// 字典与网络——缓存的是来源实例，不是查询结果。缓存键只取 `cfg` 与
  /// `meta.key`：同名 key 的 rule 由 field_meta 单一真源给出，同一 deps
  /// 生命周期内对同 key 手搓不同 meta 属病态用法，不为其放大缓存键。
  SuggestionSource? sourceForField(String cfg, FieldMeta meta) {
    final key = '$cfg:${meta.key}';
    if (_memo.containsKey(key)) return _memo[key];
    return _memo[key] = _resolveFlowSource(cfg, meta, this);
  }
}

/// 该字段的候选来源；不需要补全的字段返回 null（调用方据此退化为普通输入框）。
///
/// 取舍次序（有冲突时按此优先）：
/// 1. `effectLike` 字段只能走后端码表——那是唯一认识指令语法的一方；
/// 2. 固定枚举（[FieldRule.fixed]）纯本地；
/// 3. 名称字典（[FieldRule.dictName]）本地合并；字典为空的 `'actions'`
///    实际是码表（mode=action），改走 [httpEffectSource]（与经典编辑器
///    `_options()` 跳过 `'actions'` 同一判断）；
/// 4. ID 引用（[FieldRule.idRefCfg]）：舞台内扫内存、舞台外走加载器；
/// 5. 剩下的 2D Array 指令字段（没规则也没被判成 effectLike，如 stateCond）
///    仍走码表，绝不退化成裸文本框。
///
/// 既有字典又有 `idRefCfg` 的字段（如 `TalkCfg:audio`）只用字典：合并后的字典
/// 已含「原版 + Mod」全量 id→名称，再打一次 `/api/cfg_ids` 属于多余请求。
///
/// [cfg] 是宿主节点所属表：舞台内外判定要用它——同一个 `idRefCfg: TalkCfg`
/// 挂在舞台内节点上是「下一句」，挂在别的表上就完全不在本舞台内存里。
///
/// 解析结果按 (cfg, meta.key) 记忆化在 [deps] 上（见
/// [FlowSuggestDeps.sourceForField]）：同一 deps 实例对同一字段恒返回同一
/// 来源实例。不做记忆化的话，每个分支新建的闭包会让
/// `SuggestionTextField.didUpdateWidget` 的 `identical` 判断恒真，
/// 宿主每次重建都清掉用户正开着的候选浮层。
SuggestionSource? sourceForField(
  String cfg,
  FieldMeta meta,
  FlowSuggestDeps deps,
) => deps.sourceForField(cfg, meta);

/// [sourceForField] 的分支解析体：输入只有 (cfg, meta) 与 deps 构造期注入的
/// final 字段；各来源闭包都在每次查询时才读舞台/字典/网络，因此本函数是
/// (cfg, meta) 上的纯函数——这是可被记忆化的前提。
SuggestionSource? _resolveFlowSource(
  String cfg,
  FieldMeta meta,
  FlowSuggestDeps deps,
) {
  if (meta.effectLike) {
    return httpEffectSource(meta.suggestMode ?? 'effect');
  }

  final rule = meta.rule;
  final sources = <SuggestionSource>[];

  if (rule != null) {
    final fixed = rule.fixed;
    if (fixed != null && fixed.isNotEmpty) {
      sources.add(fixedSource(fixed));
    }

    final dictName = rule.dictName;
    var dictCoversIds = false;
    if (dictName != null) {
      if (dictName == 'actions') {
        sources.add(httpEffectSource('action'));
      } else {
        sources.add(dictSource(deps.state, dictName, modTable: deps.modTable));
        dictCoversIds = true;
      }
    }

    final refCfg = rule.idRefCfg;
    if (refCfg != null) {
      if (isInStageRef(cfg, refCfg)) {
        sources.add(
          refIdSource(
            state: deps.state,
            records: refCfg == 'OptionCfg'
                ? deps.stageOptions
                : deps.stageTalks,
          ),
        );
      } else if (!dictCoversIds) {
        sources.add(offStageRefSource(cfg: refCfg, loader: deps.offStageIds));
      }
    }
  }

  // 2D 指令字段兜底：`isEffectLikeField` 按 key 猜，猜不到的（OptionCfg.stateCond
  // 就是漏网的一条，schema 里它是 2D Array 且没有规则）若退化成裸文本框，
  // 全角逗号能绕过校验直接进存档。
  // 经典编辑器同理——无字典项的 2D Array 一律走 EffectHintField（见 _FieldInput.build）。
  if (sources.isEmpty && meta.type == '2D Array') {
    sources.add(httpEffectSource(meta.suggestMode ?? 'effect'));
  }

  if (sources.isEmpty) return null;
  return sources.length == 1 ? sources.first : composeSources(sources);
}

/// 引用目标是否落在当前舞台的内存表里。
bool isInStageRef(String hostCfg, String refCfg) =>
    kInStageHostCfgs.contains(hostCfg) && kInStageRefCfgs.contains(refCfg);

/// 多路来源合并（按 code 去重，先到先得）。
///
/// 各来源并发发起、单个来源抛错不影响其余来源——一个字典读歪了不该让整条
/// 字段失去候选。
SuggestionSource composeSources(List<SuggestionSource> sources) {
  if (sources.isEmpty) return (_) async => const [];
  if (sources.length == 1) return sources.first;
  return (query) async {
    final groups = await Future.wait(
      sources.map((s) async {
        try {
          return await s(query);
        } catch (_) {
          return const <Suggestion>[];
        }
      }),
    );
    final seen = <String>{};
    final out = <Suggestion>[];
    for (final group in groups) {
      for (final item in group) {
        if (item.code.isEmpty || !seen.add(item.code)) continue;
        out.add(item);
      }
    }
    return out;
  };
}

/// 固定选项（[FieldRule.fixed]）：id → 名称，零请求、零依赖。
SuggestionSource fixedSource(Map<String, String> options) {
  final items = [
    for (final e in options.entries)
      if (cln(e.key).isNotEmpty) Suggestion(cln(e.key), e.value),
  ]..sort((a, b) => compareFlowIds(a.code, b.code));
  return (query) async => filterSuggestions(items, query.token);
}

/// 本地名称字典（零请求）：原版 [AppState.gameDicts] 打底 + MOD 表记录覆盖。
///
/// [modTable] 由宿主提供（工作区已加载的表），字典名 → MOD 表的映射见
/// [kDictModTable]；传 null 时只有原版名。
SuggestionSource dictSource(
  AppState state,
  String dictName, {
  Map<String, dynamic>? Function(String cfg)? modTable,
}) {
  final tableName = kDictModTable[dictName];
  return (query) async {
    // 每次查询重算合并：Mod 表在编辑中会长出新条目，构建时冻结就把新条目漏了。
    final entries = mergeNameDict(
      state: state,
      dictName: dictName,
      modRecords: modTable == null || tableName == null
          ? null
          : modTable(tableName),
    );
    final items = [for (final e in entries.entries) Suggestion(e.key, e.value)]
      ..sort((a, b) => compareFlowIds(a.code, b.code));
    return filterSuggestions(items, query.token);
  };
}

/// 名称合并：原版在前、Mod 记录赢。
///
/// 合并次序与 `story_director_view` 的 `_allBgs` / `_allAudios` / `_allRoles`
/// 一致：先用 `gameDicts[name]` 铺一层，再用 MOD 表逐条覆盖同 id。
/// 字典值本身可能是 List（首元素才是展示名，见 `schema_editor_view` 的
/// `_options()`）；MOD 记录取 `name`，缺名的角色退回「角色 N」，其余缺名条目
/// 不覆盖、也不凭空塞一个没有名字的候选。
Map<String, String> mergeNameDict({
  required AppState state,
  required String dictName,
  Map<String, dynamic>? modRecords,
}) {
  final out = <String, String>{};
  final base = state.gameDicts[dictName];
  if (base is Map) {
    for (final e in base.entries) {
      final id = cln(e.key);
      if (id.isEmpty) continue;
      if (dictName == 'roles' && _roleSentinels.contains(id)) continue;
      out[id] = dictValueLabel(e.value);
    }
  }
  if (modRecords != null) {
    for (final e in modRecords.entries) {
      final id = cln(e.key);
      if (id.isEmpty) continue;
      if (dictName == 'roles' && _roleSentinels.contains(id)) continue;
      final rec = e.value;
      final name = rec is Map ? cln(rec['name']) : cln(rec);
      if (name.isNotEmpty) {
        out[id] = name;
      } else if (!out.containsKey(id) && dictName == 'roles') {
        out[id] = '角色 $id';
      }
    }
  }
  return out;
}

/// 字典值 → 展示名：List 取首元素（原版 roles 即形如 `[名称, 立绘]`）。
String dictValueLabel(dynamic v) {
  if (v is List) return v.isEmpty ? '' : cln(v.first);
  return cln(v);
}

/// 引用 ID 候选：舞台内本地扫表（零请求）。
///
/// [records] 每次查询都重新取（舞台内容正在变，缓存住就把新节点漏掉）。
/// id 与展示名都做成可注入：默认 `rec['id']` + [KeyTranslator.entryName]
/// （name/title/content/desc/text 顺序，与后端预览同一套偏好），
/// 特殊表可由调用方替换。
SuggestionSource refIdSource({
  required AppState state,
  required List<Map<String, dynamic>> Function() records,
  String Function(Map<String, dynamic> rec)? idOf,
  String Function(String id, Map<String, dynamic> rec)? labelOf,
}) {
  final translator = KeyTranslator(state);
  return (query) async {
    final seen = <String>{};
    final items = <Suggestion>[];
    for (final rec in records()) {
      final id = idOf == null ? cln(rec['id']) : idOf(rec);
      if (id.isEmpty || !seen.add(id)) continue;
      final label = labelOf != null
          ? labelOf(id, rec)
          : clipFlowPreview(entryPreview(translator, id, rec));
      items.add(Suggestion(id, label));
    }
    items.sort((a, b) => compareFlowIds(a.code, b.code));
    return filterSuggestions(items, query.token);
  };
}

/// 记录的展示名：[KeyTranslator.entryName] 的「查无此名」返回值是 `#id`，
/// 那不是预览文本，得还原成空串（否则候选里会冒出 `#1000001000`）。
String entryPreview(
  KeyTranslator translator,
  String id,
  Map<String, dynamic> rec,
) {
  final name = translator.entryName(id, rec);
  return name == '#$id' ? '' : name;
}

/// 舞台外 ID 候选：走宿主带缓存的 `(id, preview)` 加载器。
///
/// 加载器抛错（离线、表不存在）按「这一轮没候选」处理，绝不把异常抛进浮层。
SuggestionSource offStageRefSource({
  required String cfg,
  required Future<List<(String, String)>> Function(String cfg) loader,
}) {
  return (query) async {
    final List<(String, String)> rows;
    try {
      rows = await loader(cfg);
    } catch (_) {
      return const <Suggestion>[];
    }
    final items = [
      for (final row in rows)
        if (cln(row.$1).isNotEmpty) Suggestion(cln(row.$1), row.$2),
    ];
    return filterSuggestions(items, query.token);
  };
}

/// 后端码表 `/api/effect_suggest`（指令/条件/消耗/屏幕效果）。
///
/// 后端自己做模糊匹配，这里只把 token 原样当 `q` 传；失败与超时一律空候选
/// （与 `effect_hint_field.dart` 同样的容错：补全框不该因为后端而报错）。
SuggestionSource httpEffectSource(String mode) {
  return (query) async {
    final token = query.token.trim();
    if (token.isEmpty) return const <Suggestion>[];
    try {
      final resp = await ApiClient.instance
          .get('/api/effect_suggest', query: {'q': token, 'mode': mode})
          .timeout(kFlowEffectSuggestTimeout);
      final items = resp is Map ? resp['items'] : null;
      if (items is! List) return const <Suggestion>[];
      final out = <Suggestion>[];
      for (final e in items) {
        if (e is! Map) continue;
        final code = cln(e['code']);
        if (code.isEmpty) continue;
        out.add(Suggestion(code, cln(e['desc'])));
        if (out.length >= kFlowSuggestLimit) break;
      }
      return out;
    } catch (_) {
      return const <Suggestion>[];
    }
  };
}

/// 本地候选的文本匹配：code 或 desc 命中即算（打中文名字或打数字 ID 都要有）。
///
/// token 为空时给前 [limit] 条，让宿主可以「不打字也先看一眼有什么」。
List<Suggestion> filterSuggestions(
  Iterable<Suggestion> items,
  String token, {
  int limit = kFlowSuggestLimit,
}) {
  final needle = token.trim().toLowerCase();
  final out = <Suggestion>[];
  for (final item in items) {
    if (out.length >= limit) break;
    if (needle.isEmpty ||
        item.code.toLowerCase().contains(needle) ||
        item.desc.toLowerCase().contains(needle)) {
      out.add(item);
    }
  }
  return out;
}

/// 预览裁剪：去换行 + 截 20 字，与后端 `cfg_ids` 的 preview 规则一致。
String clipFlowPreview(String raw) {
  final s = raw.replaceAll('\r', '').replaceAll('\n', '').trim();
  return s.length > 20 ? s.substring(0, 20) : s;
}

/// ID 排序：数字 ID 按数值升序，混排的字符串 ID 按字典序（同 `_options()`）。
int compareFlowIds(String a, String b) {
  final an = int.tryParse(a);
  final bn = int.tryParse(b);
  if (an != null && bn != null) return an.compareTo(bn);
  return a.compareTo(b);
}
