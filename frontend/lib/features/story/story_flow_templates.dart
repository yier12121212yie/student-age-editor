/// 场景模板库：把「一组带连线的对白/选项节点」打包成一键可创建的模板，
/// 是 M6「剧情图无代码主入口」的数据层与纯函数层。
///
/// 设计约束（与既有代码对齐）：
/// - 复用 [FlowNodePreset] 的字段口径：节点记录里出现的都是引擎真字段
///   （TalkCfg / OptionCfg 列名，见 native/assets/schema.json），
///   content 提示文案统一用【】风格，效果/条件码取 semantic EFFECT_DB /
///   CONDITION_DB 的合法结构，数值槽一律填 0 并由用户在展开节点里补全。
/// - ID 分配与前缀守卫**完全委托**给粘贴子图那条链路
///   （[cloneSubgraphInto] + story_logic 的 appendTalkId / allocOptionId），
///   不另起炉灶：模板先按「占位 ID」摆进两张源表，再走一遍克隆重编号，
///   于是与现网数据永不撞号、跨事件越界等保护自动继承。
/// - 落盘走后端已有的 `GET/PUT /api/tools/*`（mod 作用域的
///   `.editor_flow_templates.json`），不新增后端。文件读写只在 workspace
///   里做网络粘合，本文件只提供**纯字符串↔模板**的编解码，可离线单测。
library;

import 'dart:convert';

import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:flutter/material.dart';

import '../../core/app_theme.dart';
import 'story_flow_clipboard.dart';
import 'story_flow_models.dart';
import 'story_logic.dart';
import '../../core/app_dialogs.dart';

// ============================ 数据模型 ============================

/// 一个模板节点：载体记录类型 + 相对落点坐标 + 字段 + 出边。
///
/// [record] 只放**非连线**字段（content / roleName / check / effect /
/// screenEffect / precondition / nextEvtId / bg / audio / time / miniGame …），
/// 连线一律走 [links]（字段名 → 目标节点 [ref] 列表）。这样「重编号 + 边写回」
/// 与字段解耦，序列化稳定、单测清晰。记录里**不含 id**：id 由应用时现算。
class TemplateNode {
  const TemplateNode({
    required this.ref,
    required this.appliesTo,
    required this.relativePos,
    this.record = const {},
    this.links = const {},
  });

  /// 模板内唯一引用键（不是配置表 ID！），供 [links] 指向彼此。
  final String ref;

  /// 载体记录类型：'talk' | 'option'。
  final String appliesTo;

  /// 相对「应用落点」的偏移：应用时 `落点 + relativePos` 即节点画布坐标。
  final Offset relativePos;

  /// 非连线字段（不含 id）。
  final Map<String, dynamic> record;

  /// 出边：连线字段名（nextTalk/nextTalk2/option 或 talkId/talkId2）→ 目标 ref 列表。
  final Map<String, List<String>> links;

  bool get isTalk => appliesTo != 'option';
}

/// 场景模板：一组带内部连线的节点 + 一个入口节点。
class FlowSceneTemplate {
  const FlowSceneTemplate({
    required this.id,
    required this.name,
    required this.category,
    required this.nodes,
    required this.entry,
    this.description = '',
  });

  final String id;
  final String name;

  /// 菜单分组：'剧情' | '冲突' | '约会' | '送礼' | '检定' | '我的模板'。
  final String category;
  final String description;

  final List<TemplateNode> nodes;

  /// 入口节点的 [TemplateNode.ref]（恒为 talk）。
  final String entry;

  bool get isUser => category == kCategoryUser;

  TemplateNode? nodeByRef(String ref) {
    for (final n in nodes) {
      if (n.ref == ref) return n;
    }
    return null;
  }

  /// 是否可作为「我的模板」删除（内置库不可删）。
  bool get deletable => isUser;
}

/// 「我的模板」分类名（用户模板持久化文件里的固定分组）。
const String kCategoryUser = '我的模板';

/// 对白连线字段 / 选项连线字段（与 story_flow_clipboard 的读写口径一致）。
const List<String> kTalkLinkFields = ['nextTalk', 'nextTalk2', 'option'];
const List<String> kOptionLinkFields = ['talkId', 'talkId2'];

/// 节点间距（列宽/行高，与 layoutFlow 的 colW/rowH 同量级；
/// 独立于 story_flow_graph.dart，避免纯函数层反向依赖画布）。
const double kTemplateColW = 260;
const double kTemplateRowH = 150;

// ============================ 内置模板库 ============================
//
// 效果/条件码格式对照 native semantic EFFECT_DB / CONDITION_DB：
//  - 属性增加  effect      [[1, 1, @ATTR@, V]]      —— 末两位是「属性/数值」槽，留 0
//  - 花费物品  effect      [[60, -1, @ITEM@]]        —— 送礼：失去物品，槽留 0
//  - 检定条件  check       [[4, 1, @ATTR@, V]]      —— 属性 >= V，槽留 0
//  - 好感门槛  precondition [[7, 1, @ROLE@, V]]      —— @ROLE@ 好感 >= V，槽留 0
//  - 黑屏引入  screenEffect [4006]
// 所有数值槽为 0 处都需在展开节点里补全（详见各节点 content 的【】提示）。
final List<FlowSceneTemplate> kBuiltinSceneTemplates = [
  // ---------- 剧情 ----------
  FlowSceneTemplate(
    id: 'tpl_opening_monologue',
    name: '开场三句独白',
    category: '剧情',
    description: '黑屏引入 → 两句旁白铺陈 → 引出首次互动，纯线性。',
    entry: 'a',
    nodes: const [
      TemplateNode(
        ref: 'a',
        appliesTo: 'talk',
        relativePos: Offset(0, 0),
        record: {
          'roleName': '旁白',
          'content': '【开场黑屏引入：可改成主角独白】',
          'screenEffect': [4006],
        },
        links: {'nextTalk': ['b']},
      ),
      TemplateNode(
        ref: 'b',
        appliesTo: 'talk',
        relativePos: Offset(kTemplateColW, 0),
        record: {
          'roleName': '旁白',
          'content': '【第二句：交代时间地点与在场人物】',
        },
        links: {'nextTalk': ['c']},
      ),
      TemplateNode(
        ref: 'c',
        appliesTo: 'talk',
        relativePos: Offset(kTemplateColW * 2, 0),
        record: {
          'roleName': '旁白',
          'content': '【第三句：抛出钩子，接选项或下一场】',
        },
      ),
    ],
  ),
  FlowSceneTemplate(
    id: 'tpl_three_choice',
    name: '三岔选项',
    category: '剧情',
    description: '一句对白挂三个选项，各通向一段独立结果，最常用的分支骨架。',
    entry: 'a',
    nodes: const [
      TemplateNode(
        ref: 'a',
        appliesTo: 'talk',
        relativePos: Offset(0, 0),
        record: {'roleName': '同学', 'content': '【面对选择：填对方台词】'},
        links: {
          'option': ['o1', 'o2', 'o3'],
        },
      ),
      TemplateNode(
        ref: 'o1',
        appliesTo: 'option',
        relativePos: Offset(kTemplateColW, -kTemplateRowH),
        record: {'content': '选项一（改文案）'},
        links: {
          'talkId': ['t1'],
        },
      ),
      TemplateNode(
        ref: 'o2',
        appliesTo: 'option',
        relativePos: Offset(kTemplateColW, 0),
        record: {'content': '选项二（改文案）'},
        links: {
          'talkId': ['t2'],
        },
      ),
      TemplateNode(
        ref: 'o3',
        appliesTo: 'option',
        relativePos: Offset(kTemplateColW, kTemplateRowH),
        record: {'content': '选项三（改文案）'},
        links: {
          'talkId': ['t3'],
        },
      ),
      TemplateNode(
        ref: 't1',
        appliesTo: 'talk',
        relativePos: Offset(kTemplateColW * 2, -kTemplateRowH),
        record: {'roleName': '旁白', 'content': '【选项一的结果】'},
      ),
      TemplateNode(
        ref: 't2',
        appliesTo: 'talk',
        relativePos: Offset(kTemplateColW * 2, 0),
        record: {'roleName': '旁白', 'content': '【选项二的结果】'},
      ),
      TemplateNode(
        ref: 't3',
        appliesTo: 'talk',
        relativePos: Offset(kTemplateColW * 2, kTemplateRowH),
        record: {'roleName': '旁白', 'content': '【选项三的结果】'},
      ),
    ],
  ),
  // ---------- 冲突 ----------
  FlowSceneTemplate(
    id: 'tpl_conflict',
    name: '争执：顶撞或忍让',
    category: '冲突',
    description: '对方质问 → 二选一（硬刚 / 忍住）→ 各自结算属性变化。',
    entry: 'a',
    nodes: const [
      TemplateNode(
        ref: 'a',
        appliesTo: 'talk',
        relativePos: Offset(0, 0),
        record: {'roleName': '同学', 'content': '【冲突：填对方挑衅台词】'},
        links: {
          'option': ['o_hard', 'o_hold'],
        },
      ),
      TemplateNode(
        ref: 'o_hard',
        appliesTo: 'option',
        relativePos: Offset(kTemplateColW, -kTemplateRowH),
        record: {'content': '硬刚回去'},
        links: {
          'talkId': ['t_hard'],
        },
      ),
      TemplateNode(
        ref: 't_hard',
        appliesTo: 'talk',
        relativePos: Offset(kTemplateColW * 2, -kTemplateRowH),
        record: {
          'roleName': '同学',
          'content': '【顶撞：火药味升级，在 effect 补属性增减 [[1,1,槽,槽]]】',
          'effect': [
            [1, 1, 0, 0],
          ],
        },
      ),
      TemplateNode(
        ref: 'o_hold',
        appliesTo: 'option',
        relativePos: Offset(kTemplateColW, kTemplateRowH),
        record: {'content': '忍住不发'},
        links: {
          'talkId': ['t_hold'],
        },
      ),
      TemplateNode(
        ref: 't_hold',
        appliesTo: 'talk',
        relativePos: Offset(kTemplateColW * 2, kTemplateRowH),
        record: {
          'roleName': '旁白',
          'content': '【忍耐：压力上升，在 effect 补属性增减 [[1,1,槽,槽]]】',
          'effect': [
            [1, 1, 0, 0],
          ],
        },
      ),
    ],
  ),
  // ---------- 约会 ----------
  FlowSceneTemplate(
    id: 'tpl_date',
    name: '约会邀约（好感门槛）',
    category: '约会',
    description: '邀约发起 → 带好感度前置条件的选项 → 达成后结算。',
    entry: 'a',
    nodes: const [
      TemplateNode(
        ref: 'a',
        appliesTo: 'talk',
        relativePos: Offset(0, 0),
        record: {'roleName': '女主角', 'content': '【邀约发起：填角色名与台词】'},
        links: {
          'option': ['o'],
        },
      ),
      TemplateNode(
        ref: 'o',
        appliesTo: 'option',
        relativePos: Offset(kTemplateColW, 0),
        record: {
          'content': '一起去游乐园（好感达标才出现）',
          'precondition': [
            [7, 1, 0, 0],
          ],
        },
        links: {
          'talkId': ['b'],
        },
      ),
      TemplateNode(
        ref: 'b',
        appliesTo: 'talk',
        relativePos: Offset(kTemplateColW * 2, 0),
        record: {
          'roleName': '女主角',
          'content': '【约会达成：在 effect 补好感/属性 [[1,1,槽,槽]]】',
          'effect': [
            [1, 1, 0, 0],
          ],
        },
      ),
    ],
  ),
  // ---------- 送礼 ----------
  FlowSceneTemplate(
    id: 'tpl_gift',
    name: '送礼反应',
    category: '送礼',
    description: '挑选礼物 → 送出（消耗物品）→ 对方反应。',
    entry: 'a',
    nodes: const [
      TemplateNode(
        ref: 'a',
        appliesTo: 'talk',
        relativePos: Offset(0, 0),
        record: {'roleName': '同学', 'content': '【送礼：选一件东西送出】'},
        links: {
          'option': ['o'],
        },
      ),
      TemplateNode(
        ref: 'o',
        appliesTo: 'option',
        relativePos: Offset(kTemplateColW, 0),
        record: {
          'content': '送出礼物（在 effect 填花费 [[60,-1,物品id]]）',
          'effect': [
            [60, -1, 0],
          ],
        },
        links: {
          'talkId': ['b'],
        },
      ),
      TemplateNode(
        ref: 'b',
        appliesTo: 'talk',
        relativePos: Offset(kTemplateColW * 2, 0),
        record: {
          'roleName': '同学',
          'content': '【对方反应：在 effect 补好感/属性 [[1,1,槽,槽]]】',
          'effect': [
            [1, 1, 0, 0],
          ],
        },
      ),
    ],
  ),
  // ---------- 检定 ----------
  FlowSceneTemplate(
    id: 'tpl_check',
    name: '技能检定（成功/失败）',
    category: '检定',
    description: 'check 非空即自动出 成功/失败 双支：nextTalk=成功、nextTalk2=失败。',
    entry: 'a',
    nodes: const [
      TemplateNode(
        ref: 'a',
        appliesTo: 'talk',
        relativePos: Offset(0, 0),
        record: {
          'roleName': '旁白',
          'content': '【检定：展开补 check 条件 [[4,1,属性槽,数值槽]]，出双支】',
          'check': [
            [4, 1, 0, 0],
          ],
        },
        links: {
          'nextTalk': ['ok'],
          'nextTalk2': ['fail'],
        },
      ),
      TemplateNode(
        ref: 'ok',
        appliesTo: 'talk',
        relativePos: Offset(kTemplateColW, -kTemplateRowH),
        record: {
          'roleName': '旁白',
          'content': '【检定成功：在 effect 补奖励 [[1,1,槽,槽]]】',
          'effect': [
            [1, 1, 0, 0],
          ],
        },
      ),
      TemplateNode(
        ref: 'fail',
        appliesTo: 'talk',
        relativePos: Offset(kTemplateColW, kTemplateRowH),
        record: {'roleName': '旁白', 'content': '【检定失败：接惩罚或重试】'},
      ),
    ],
  ),
];

// ============================ 应用模板（纯函数）============================

/// [applySceneTemplate] 的结果：新节点集合 + 落位坐标 + 选中集，或失败原因。
class TemplateApplyResult {
  const TemplateApplyResult._({
    required this.ok,
    required this.idMap,
    required this.positions,
    required this.newNodes,
    this.entryId,
    this.error,
  });

  factory TemplateApplyResult.fail(String error) => TemplateApplyResult._(
    ok: false,
    idMap: const {},
    positions: const {},
    newNodes: const {},
    error: error,
  );

  factory TemplateApplyResult.success({
    required Map<String, String> idMap,
    required Map<String, Offset> positions,
    required Set<String> newNodes,
    String? entryId,
  }) => TemplateApplyResult._(
    ok: true,
    idMap: idMap,
    positions: positions,
    newNodes: newNodes,
    entryId: entryId,
  );

  final bool ok;

  /// 占位 ID → 现网新 ID（与 cloneSubgraphInto 返回同语义）。
  final Map<String, String> idMap;

  /// 新 ID → 画布坐标（`origin + relativePos`）。
  final Map<String, Offset> positions;

  /// 需要选中的新节点 id 全集。
  final Set<String> newNodes;

  /// 入口节点的新 id（供上层把外部连线接过来；本次不自动接，故仅返回备用）。
  final String? entryId;
  final String? error;
}

/// 把模板实例化成两张「源表」（占位 ID）：talk 占位 `{evt}{3位}`、
/// option 占位 `{evt}{2位}`。占位值本身不参与最终落库，只用于喂给
/// [cloneSubgraphInto] 让它按现网规则重编号 + 重映射内部连线。
class _InstantiatedTemplate {
  _InstantiatedTemplate({
    required this.srcTalks,
    required this.srcOpts,
    required this.refToPlaceholder,
    required this.relativePosByPlaceholder,
  });
  final Map<String, dynamic> srcTalks;
  final Map<String, dynamic> srcOpts;
  final Map<String, String> refToPlaceholder;
  final Map<String, Offset> relativePosByPlaceholder;
}

_InstantiatedTemplate _instantiate(
  FlowSceneTemplate template,
  String evtId,
) {
  final srcTalks = <String, dynamic>{};
  final srcOpts = <String, dynamic>{};
  final refToPlaceholder = <String, String>{};
  final posByPlaceholder = <String, Offset>{};

  var talkSeq = 0;
  var optSeq = 0;
  String placeholderFor(TemplateNode n) {
    final existing = refToPlaceholder[n.ref];
    if (existing != null) return existing;
    final ph = n.isTalk
        ? '$evtId${(++talkSeq).toString().padLeft(3, '0')}'
        : '$evtId${(++optSeq).toString().padLeft(2, '0')}';
    refToPlaceholder[n.ref] = ph;
    return ph;
  }

  // 先给全部节点分配占位 ID（连线的目标可能在源记录之后出现，需先建表）。
  for (final n in template.nodes) {
    placeholderFor(n);
  }

  for (final n in template.nodes) {
    final ph = refToPlaceholder[n.ref]!;
    // 深拷贝字段：模板是 const 共享对象，绝不能把它的 List 直接塞进舞台。
    final rec = copyRecords(n.record);
    rec.remove('id'); // 模板字段本不含 id；防御式再删一次
    final linkFields = n.isTalk ? kTalkLinkFields : kOptionLinkFields;
    for (final field in linkFields) {
      final targets = n.links[field] ?? const <String>[];
      rec[field] = normalizeStoryIdList([
        for (final ref in targets)
          if (refToPlaceholder[ref] != null) refToPlaceholder[ref]!,
      ]);
    }
    if (n.isTalk) {
      rec['id'] = int.tryParse(ph) ?? 0;
      srcTalks[ph] = rec;
    } else {
      rec['id'] = int.tryParse(ph) ?? 0;
      srcOpts[ph] = rec;
    }
    posByPlaceholder[ph] = n.relativePos;
  }
  return _InstantiatedTemplate(
    srcTalks: srcTalks,
    srcOpts: srcOpts,
    refToPlaceholder: refToPlaceholder,
    relativePosByPlaceholder: posByPlaceholder,
  );
}

/// 应用模板：把 [template] 的一组节点以 [origin] 为落点铺进舞台 [talks]/[opts]。
///
/// 纯函数：只改传入的 [talks]/[opts]（写回新行），返回重编号结果、坐标、选中集。
/// **要么整组落盘、要么舞台一字不改**——分配失败（本事件编号越界）返回失败。
/// ID 与前缀守卫全部委托 [cloneSubgraphInto]，因此与「粘贴子图」同一套编号规范、
/// 同一套越界保护，撤销粒度也天然一致（一次应用 = 舞台的一次内容变更）。
TemplateApplyResult applySceneTemplate({
  required String evtId,
  required List<String> prefixes,
  required Map<String, dynamic> talks,
  required Map<String, dynamic> opts,
  required Offset origin,
  required FlowSceneTemplate template,
}) {
  if (cln(evtId).isEmpty) {
    return TemplateApplyResult.fail('未选择事件，无法确定编号前缀');
  }
  final inst = _instantiate(template, cln(evtId));
  final selected = {...inst.srcTalks.keys, ...inst.srcOpts.keys};
  final mapping = cloneSubgraphInto(
    selected: selected,
    talks: talks,
    opts: opts,
    prefixes: prefixes,
    sourceTalks: inst.srcTalks,
    sourceOpts: inst.srcOpts,
  );
  if (mapping.isEmpty) {
    return TemplateApplyResult.fail('本事件的对白/选项编号已用尽，无法创建该模板');
  }
  final positions = <String, Offset>{};
  final newNodes = <String>{};
  inst.refToPlaceholder.forEach((ref, ph) {
    final newId = mapping[ph];
    if (newId == null) return; // 该节点越界未落盘（理论上 mapping 非空即全落）
    final rel = inst.relativePosByPlaceholder[ph] ?? Offset.zero;
    positions[newId] = origin + rel;
    newNodes.add(newId);
  });
  final entryPh = inst.refToPlaceholder[template.entry];
  return TemplateApplyResult.success(
    idMap: mapping,
    positions: positions,
    newNodes: newNodes,
    entryId: entryPh == null ? null : mapping[entryPh],
  );
}

// ============================ 存为模板（纯函数）============================

/// 从舞台多选子图抽取「我的模板」：记录去 id、坐标相对化、连线换成模板内 ref。
///
/// 指向选区**外**的连线会被丢弃（模板要能独立复用）；`nextEvtId` 是实义跨事件值，
/// 原样保留进 record。[name]/[id] 由调用方给定。入口取选区内编号最小的 talk。
FlowSceneTemplate extractSceneTemplate({
  required Set<String> selected,
  required Map<String, dynamic> talks,
  required Map<String, dynamic> opts,
  required Map<String, Offset> positions,
  required String name,
  required String id,
  String description = '',
}) {
  final selTalks = <String>{for (final k in selected) cln(k)};
  // ref 直接沿用舞台 id（字符串），保证 links 与记录 key 一一对应。
  final nodes = <TemplateNode>[];
  final orderedTalks = (selTalks
      .where((k) => talks[k] is Map)
      .toList()
        ..sort(compareIds));
  // 脏数据里同一 id 同时挂两张表时以对白为准：选项侧跳过已被 talk 认领的 key，
  // 否则会产生两个同 ref 节点，cloneSubgraphInto 与 links 都会歧义。
  final claimedAsTalk = selTalks.where((k) => talks[k] is Map).toSet();
  final orderedOpts = (selTalks
      .where((k) => opts[k] is Map && !claimedAsTalk.contains(k))
      .toList()
        ..sort(compareIds));

  for (final k in orderedTalks) {
    nodes.add(
      _extractNode(
        id: k,
        appliesTo: 'talk',
        src: talks[k] as Map,
        selected: selTalks,
        positions: positions,
      ),
    );
  }
  for (final k in orderedOpts) {
    nodes.add(
      _extractNode(
        id: k,
        appliesTo: 'option',
        src: opts[k] as Map,
        selected: selTalks,
        positions: positions,
      ),
    );
  }
  final entry = orderedTalks.isNotEmpty
      ? orderedTalks.first
      : (nodes.isNotEmpty ? nodes.first.ref : '');
  // 相对化坐标：以最左上 (min x, min y) 为原点，避免落点偏出可视区。
  var minX = double.infinity, minY = double.infinity;
  for (final n in nodes) {
    if (n.relativePos.dx < minX) minX = n.relativePos.dx;
    if (n.relativePos.dy < minY) minY = n.relativePos.dy;
  }
  if (!minX.isFinite) {
    minX = 0;
    minY = 0;
  }
  final normalized = [
    for (final n in nodes)
      TemplateNode(
        ref: n.ref,
        appliesTo: n.appliesTo,
        relativePos: n.relativePos - Offset(minX, minY),
        record: n.record,
        links: n.links,
      ),
  ];
  return FlowSceneTemplate(
    id: id,
    name: name,
    category: kCategoryUser,
    description: description,
    entry: entry,
    nodes: normalized,
  );
}

TemplateNode _extractNode({
  required String id,
  required String appliesTo,
  required Map src,
  required Set<String> selected,
  required Map<String, Offset> positions,
}) {
  final record = <String, dynamic>{};
  final links = <String, List<String>>{};
  final linkFields = appliesTo == 'option' ? kOptionLinkFields : kTalkLinkFields;
  src.forEach((k, v) {
    final key = k.toString();
    if (key == 'id') return;
    if (linkFields.contains(key)) {
      // 连线：只保留落在选区内的目标，剪成模板内 ref；外链丢弃。
      final kept = [
        for (final t in normalizeStoryIdList(v))
          if (selected.contains(cln(t))) cln(t),
      ];
      if (kept.isNotEmpty) links[key] = kept;
      return;
    }
    record[key] = copyRecordValue(v);
  });
  final pos = positions[id] ?? Offset.zero;
  return TemplateNode(
    ref: id,
    appliesTo: appliesTo,
    relativePos: Offset(pos.dx, pos.dy),
    record: record,
    links: links,
  );
}

// ============================ 序列化 / 持久化（纯函数）============================

/// 单模板 → JSON-able Map。Offset 拆成 dx/dy，links 原样（值都是 ref 字符串）。
Map<String, dynamic> flowSceneTemplateToJson(FlowSceneTemplate t) => {
  'id': t.id,
  'name': t.name,
  'category': t.category,
  'description': t.description,
  'entry': t.entry,
  'nodes': [
    for (final n in t.nodes)
      {
        'ref': n.ref,
        'appliesTo': n.appliesTo,
        'dx': n.relativePos.dx,
        'dy': n.relativePos.dy,
        'record': n.record,
        'links': {for (final e in n.links.entries) e.key: [...e.value]},
      },
  ],
};

/// JSON Map → 模板。结构不符返回 null（解码时跳过坏条目而非整体失败）。
FlowSceneTemplate? flowSceneTemplateFromJson(dynamic raw) {
  if (raw is! Map) return null;
  final id = cln(raw['id']);
  final name = cln(raw['name']);
  if (id.isEmpty || name.isEmpty) return null;
  final nodes = <TemplateNode>[];
  final rawNodes = raw['nodes'];
  if (rawNodes is! List) return null;
  for (final n in rawNodes) {
    if (n is! Map) continue;
    final ref = cln(n['ref']);
    if (ref.isEmpty) continue;
    final links = <String, List<String>>{};
    final rl = n['links'];
    if (rl is Map) {
      rl.forEach((k, v) {
        final vals = <String>[
          for (final e in ensureList(v)) e,
        ].where((e) => e.isNotEmpty).toList();
        if (vals.isNotEmpty) links[cln(k)] = vals;
      });
    }
    final rec = n['record'];
    nodes.add(
      TemplateNode(
        ref: ref,
        appliesTo: cln(n['appliesTo']) == 'option' ? 'option' : 'talk',
        relativePos: Offset(
          (n['dx'] as num?)?.toDouble() ?? 0,
          (n['dy'] as num?)?.toDouble() ?? 0,
        ),
        record: rec is Map
            ? rec.map((k, v) => MapEntry(k.toString(), v))
            : const {},
        links: links,
      ),
    );
  }
  if (nodes.isEmpty) return null;
  return FlowSceneTemplate(
    id: id,
    name: name,
    category: cln(raw['category']).isEmpty ? kCategoryUser : cln(raw['category']),
    description: cln(raw['description']),
    entry: cln(raw['entry']),
    nodes: nodes,
  );
}

/// 编码「我的模板」持久文件内容（`.editor_flow_templates.json`）。
String encodeTemplatesFile(List<FlowSceneTemplate> templates) => jsonEncode({
  'version': 1,
  'templates': [for (final t in templates) flowSceneTemplateToJson(t)],
});

/// 解码持久文件；容错：缺字段/坏条目都跳过，返回可解析出的部分。
List<FlowSceneTemplate> decodeTemplatesFile(String? text) {
  if (text == null || text.trim().isEmpty) return const [];
  Object? parsed;
  try {
    parsed = jsonDecode(text);
  } catch (_) {
    return const [];
  }
  final list = parsed is Map ? parsed['templates'] : parsed;
  if (list is! List) return const [];
  return [
    for (final item in list) ?flowSceneTemplateFromJson(item),
  ];
}

/// 往既有文件内容里并入一个模板（同 id 覆盖），返回新文件内容字符串。
String mergeTemplateIntoFile(String? existingJson, FlowSceneTemplate template) {
  final list = decodeTemplatesFile(existingJson)
      .where((t) => t.id != template.id)
      .toList()
    ..add(template);
  return encodeTemplatesFile(list);
}

/// 从既有文件内容里删除指定 id 的模板，返回新文件内容字符串。
String removeTemplateFromId(String? existingJson, String id) {
  final list = decodeTemplatesFile(existingJson)
      .where((t) => t.id != id)
      .toList();
  return encodeTemplatesFile(list);
}

// ============================ 边改挂（交付 3 纯函数）============================

/// 可改挂到「备选字段」的连线字段映射：主字段 ↔ 备选字段。
/// 对白 nextTalk↔nextTalk2；选项 talkId↔talkId2。
const Map<String, String> kEdgeFieldAlternates = {
  'nextTalk': 'nextTalk2',
  'nextTalk2': 'nextTalk',
  'talkId': 'talkId2',
  'talkId2': 'talkId',
};

/// 把 [target] 这条边从 [fromField] 改挂到 [toField]：先断原字段再推目标字段。
/// 复用 pushEdgeTarget / removeEdgeTarget 的语义（去重 + 数字归一），
/// 因此切过去再切回来完全等价。返回是否发生了字段变化。
bool retargetEdgeField(
  Map<String, dynamic> record,
  String fromField,
  String toField,
  dynamic target,
) {
  if (fromField == toField) return false;
  removeEdgeTarget(record, fromField, target);
  pushEdgeTarget(record, toField, target);
  return true;
}

// ============================ 缩略摘要（画廊卡片用，纯函数）============================

/// 生成模板节点的「几行字段摘要」文本（画廊迷你缩略）。每节点一行，
/// 优先显示角色/选项名 + content，并补上 check/effect/precondition/
/// screenEffect 等演出码的字段名，让用户不进编辑也能看出模板形状。
List<String> templateNodeSummaries(FlowSceneTemplate t) {
  final refToLine = <String, String>{};
  for (final n in t.nodes) {
    final who = n.isTalk
        ? (cln(n.record['roleName']).isEmpty ? '对白' : cln(n.record['roleName']))
        : '选项';
    final content = cln(n.record['content']);
    final brief = <String>[
      '$who｜${content.isEmpty ? '（无文案）' : content}',
    ];
    final tags = <String>[
      if (_hasVal(n.record['check'])) '检定',
      if (_hasVal(n.record['precondition'])) '条件',
      if (_hasVal(n.record['effect'])) '效果',
      if (_hasVal(n.record['screenEffect'])) '演出',
      if (_hasVal(n.record['nextEvtId'])) '跳转',
    ];
    if (tags.isNotEmpty) brief.add('  ‹${tags.join(' · ')}›');
    refToLine[n.ref] = brief.join('\n');
  }
  return [for (final n in t.nodes) refToLine[n.ref]!];
}

bool _hasVal(dynamic v) {
  if (v == null) return false;
  if (v is num) return v != 0;
  if (v is String) return v.trim().isNotEmpty;
  if (v is List) return v.any(_hasVal);
  return true;
}

// ============================ 画廊对话框（UI 粘合层）============================

/// 打开模板画廊：左分类、右卡片。点卡片「应用到画布」返回该模板；
/// 「我的模板」卡片带删除按钮，回调 [onDelete] 后即地从列表摘除。
Future<FlowSceneTemplate?> showFlowTemplateGallery(
  BuildContext context, {
  required List<FlowSceneTemplate> templates,
  Future<void> Function(String id)? onDelete,
}) {
  return fluent.showDialog<FlowSceneTemplate?>(
    context: context,
    builder: (ctx) => _FlowTemplateGallery(
      templates: templates,
      onDelete: onDelete,
    ),
  );
}

class _FlowTemplateGallery extends StatefulWidget {
  const _FlowTemplateGallery({required this.templates, this.onDelete});
  final List<FlowSceneTemplate> templates;
  final Future<void> Function(String id)? onDelete;

  @override
  State<_FlowTemplateGallery> createState() => _FlowTemplateGalleryState();
}

class _FlowTemplateGalleryState extends State<_FlowTemplateGallery> {
  late final List<FlowSceneTemplate> _all = [...widget.templates];
  String? _category;

  List<String> get _categories {
    final seen = <String>{};
    for (final t in _all) {
      seen.add(t.category);
    }
    final order = ['剧情', '冲突', '约会', '送礼', '检定', kCategoryUser];
    final out = [for (final c in order) if (seen.contains(c)) c];
    for (final c in seen) {
      if (!out.contains(c)) out.add(c);
    }
    return out;
  }

  List<FlowSceneTemplate> get _visible {
    final c = _category;
    if (c == null) return _all;
    return _all.where((t) => t.category == c).toList();
  }

  @override
  Widget build(BuildContext context) {
    final cats = _categories;
    if (_category == null && cats.isNotEmpty) _category = cats.first;
    return AppContentDialog(
      title: Text('场景模板', style: TextStyle(fontSize: AppType.title)),
      constraints: const BoxConstraints(maxWidth: 720, maxHeight: 520),
      content: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 96,
            child: ListView(
              children: [
                for (final c in cats)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: fluent.Button(
                      onPressed: () => setState(() => _category = c),
                      child: Text(
                        c,
                        style: TextStyle(
                          fontSize: AppType.chip,
                          fontWeight: _category == c
                              ? FontWeight.w700
                              : FontWeight.w400,
                          color: _category == c
                              ? accentColor
                              : palette.textSecondary,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Container(width: 1, margin: const EdgeInsets.symmetric(vertical: 4), color: palette.border),
          const SizedBox(width: 10),
          Expanded(
            child: SingleChildScrollView(
              child: Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [for (final t in _visible) _card(t)],
              ),
            ),
          ),
        ],
      ),
      actions: [
        fluent.Button(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }

  Widget _card(FlowSceneTemplate t) {
    final lines = templateNodeSummaries(t);
    return SizedBox(
      width: 260,
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: palette.panel,
          borderRadius: BorderRadius.circular(AppRadius.l),
          border: Border.all(color: palette.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    t.name,
                    style: TextStyle(
                      fontSize: AppType.chip,
                      fontWeight: FontWeight.w600,
                      color: palette.textHigh,
                    ),
                  ),
                ),
                Text(
                  t.category,
                  style: TextStyle(fontSize: 10, color: palette.textHint),
                ),
                if (t.deletable)
                  MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: GestureDetector(
                      onTap: () async {
                        await widget.onDelete?.call(t.id);
                        if (!mounted) return;
                        setState(() => _all.removeWhere((x) => x.id == t.id));
                      },
                      child: Padding(
                        padding: const EdgeInsets.only(left: 4),
                        child: Icon(
                          Icons.delete_outline,
                          size: 14,
                          color: palette.textMuted,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            if (t.description.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2, bottom: 4),
                child: Text(
                  t.description,
                  style: TextStyle(fontSize: 10, color: palette.textSecondary),
                ),
              ),
            // 迷你缩略：几行字段摘要
            Flexible(
              child: SingleChildScrollView(
                child: Text(
                  lines.join('\n'),
                  style: TextStyle(
                    fontSize: 9.5,
                    height: 1.35,
                    color: palette.textMuted,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 6),
            // 卡片整体可拖到画布（Draggable<String>），下方按钮走「点击应用」。
            Draggable<String>(
              data: t.id,
              feedback: _dragFeedback(t),
              childWhenDragging: Opacity(opacity: 0.4, child: _applyButton(t)),
              child: _applyButton(t),
            ),
          ],
        ),
      ),
    );
  }

  Widget _applyButton(FlowSceneTemplate t) {
    return fluent.Button(
      // 主入口按钮用强调色底板（palette 取色，非硬编码），区别于分类/关闭按钮。
      style: fluent.ButtonStyle(
        backgroundColor: WidgetStatePropertyAll(accentColor),
        foregroundColor: WidgetStatePropertyAll(palette.onAccent),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        ),
      ),
      onPressed: () => Navigator.of(context).pop(t),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: const [
          Icon(Icons.playlist_add, size: 14),
          SizedBox(width: 4),
          Text('应用到画布'),
        ],
      ),
    );
  }

  Widget _dragFeedback(FlowSceneTemplate t) {
    return Material(
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: palette.card,
          borderRadius: BorderRadius.circular(AppRadius.l),
          border: Border.all(color: accentColor),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.dashboard_customize_outlined, size: 14, color: accentColor),
            const SizedBox(width: 6),
            Text(
              t.name,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                color: palette.textHigh,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
