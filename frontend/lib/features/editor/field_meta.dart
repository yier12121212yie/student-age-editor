/// 字段语义的单一真源：下拉/候选规则、指南标签与必选项、剧情图字段元数据。
///
/// 原本这些规则只活在 schema_editor_view.dart 的私有常量里，剧情图要用就得
/// 复制一份，两份从此各说各话。这里统一搬出来供两侧共用。
library;

import '../../core/models.dart';
import 'field_help_data.dart';
import 'field_ref_data.dart';
import 'field_utils.dart';

/// [dictName] 指向 /api/dicts 返回的 game_dicts 字典名；[fixed] 为固定选项（id → 名称）；
/// [singleArray] 为 true 时 1D Array 字段按单选处理（显示下拉），否则多值文本框 + 名称预览。
class FieldRule {
  const FieldRule({
    this.dictName,
    this.fixed,
    this.singleArray = false,
    this.idRefCfg,
  });
  final String? dictName;
  final Map<String, String>? fixed;
  final bool singleArray;

  /// ID 引用字段：指向的配置表名（如 TalkCfg），候选为「ID · 预览」。
  final String? idRefCfg;
}

/// 按 `cfgName:key` 精确匹配的下拉框规则（优先于全局 key 匹配，按配置表逐项处理）。
const kRuleByCfgField = <String, FieldRule>{
  // EvtCfg 事件编辑：事件类型 / 事件表现形式
  'EvtCfg:type': FieldRule(dictName: 'evt_types'),
  'EvtCfg:displayType': FieldRule(fixed: {'0': '默认形式', '1': '弹窗形式'}),
  // ActionCfg 行动类型
  'ActionCfg:type': FieldRule(
    fixed: {'0': '普通', '1': '场景(禁用)', '2': '功能(禁用)', '3': '恋爱', '4': '兼职'},
  ),
  // ShopCfg 商店物品类型
  'ShopCfg:type': FieldRule(
    fixed: {'1': '消耗品', '2': '珍视物品', '3': '书籍', '4': '工具'},
  ),
  // PaperCfg 纸条类型
  'PaperCfg:type': FieldRule(fixed: {'0': '收到纸条', '1': '玩家写的'}),
  // GiftEvtCfg 送礼：收下/拒收（1D Array）
  'GiftEvtCfg:type': FieldRule(fixed: {'0': '收下', '1': '拒收'}),
  // EndingDatingCfg 约会对象性别要求
  'EndingDatingCfg:gender': FieldRule(fixed: {'1': '要求男生', '2': '要求女生'}),
  // ExploreCfg 探索等级
  'ExploreCfg:lv': FieldRule(fixed: {'1': '一级探索', '2': '二级探索', '3': '三级探索'}),
  // PersonStateCfg 状态可见性
  'PersonStateCfg:hide': FieldRule(fixed: {'0': '状态', '1': '不可见', '2': '性格'}),
  // PersonAttrCfg 属性
  'PersonAttrCfg:tag': FieldRule(fixed: {'10': '普通属性', '13': '性格关联属性'}),
  'PersonAttrCfg:consume': FieldRule(
    fixed: {'0': '不能', '1': '能', '2': '能且在最终结算展示'},
  ),
  'PersonAttrCfg:valueInUI': FieldRule(
    fixed: {'null': '保留一位小数', 'int': '整数', '{0:0.#%}': '百分比'},
  ),
  // MinigameActionCfg 小游戏动作：需要的关系
  'MinigameActionCfg:needRelation': FieldRule(dictName: 'relations'),
  // MinigameCfg 小游戏：背景音乐
  'MinigameCfg:bgm': FieldRule(dictName: 'audios'),
  // BadmintonModelCfg 羽毛球模型：url 为模型名数组，单选
  'BadmintonModelCfg:url': FieldRule(
    dictName: 'badminton_models',
    singleArray: true,
  ),
  // ID 引用字段：候选来自对应配置表（「ID · 预览」，懒加载 /api/cfg_ids）
  'EvtCfg:talkId': FieldRule(idRefCfg: 'TalkCfg'),
  'TalkCfg:nextTalk': FieldRule(idRefCfg: 'TalkCfg'),
  'TalkCfg:nextTalk2': FieldRule(idRefCfg: 'TalkCfg'),
  'TalkCfg:option': FieldRule(idRefCfg: 'OptionCfg'),
  'OptionCfg:talkId': FieldRule(idRefCfg: 'TalkCfg'),
  'OptionCfg:talkId2': FieldRule(idRefCfg: 'TalkCfg'),
  'OptionCfg:nextEvtId': FieldRule(idRefCfg: 'EvtCfg'), // Number 字段，下拉单选
  // 剧情图要用的对白字段：后端 key_map 有名目但这里缺规则，补上才有候选下拉
  'TalkCfg:audio': FieldRule(dictName: 'audios', idRefCfg: 'AudioCfg'),
  'TalkCfg:highlights': FieldRule(dictName: 'roles'),
  'TalkCfg:miniGame': FieldRule(idRefCfg: 'MinigameCfg'),
  'OptionCfg:miniGame': FieldRule(idRefCfg: 'MinigameCfg'),
  // 以下为新纳入编辑页的玩法表补充的跨表引用 / 枚举下拉。
  // 新闻：栏目类型、关联评论
  'NewsCfg:type': FieldRule(idRefCfg: 'NewsTypeCfg'),
  'NewsCfg:comments': FieldRule(idRefCfg: 'NewsCommentCfg'),
  // 钓鱼：鱼种、适用鱼种、对应物品
  'FishCfg:type': FieldRule(idRefCfg: 'FishTypeCfg'),
  'FishBaitCfg:fishType': FieldRule(idRefCfg: 'FishTypeCfg'),
  'FishCfg:item': FieldRule(dictName: 'items', idRefCfg: 'ItemCfg'),
  // 旅游：景点类型
  'TripSpotCfg:type': FieldRule(idRefCfg: 'TripTypeCfg'),
  // 看番：番剧类型
  'AnimationCfg:type': FieldRule(idRefCfg: 'AnimationTypeCfg'),
  // 侦探社：所属部门
  'ClubActivityCfg:department': FieldRule(idRefCfg: 'ClubDepartmentCfg'),
  // 辩论交涉：牌组 / 状态 / 技能引用
  'NegotiationPlayerCfg:card': FieldRule(idRefCfg: 'NegotiationMiniGameCardCfg'),
  'NegotiationPlayerCfg:buff': FieldRule(idRefCfg: 'NegotiationBuffCfg'),
  'NegotiationPlayerCfg:skill': FieldRule(idRefCfg: 'NegotiationSkillCfg'),
  'NegotiationTeammateCfg:skills': FieldRule(idRefCfg: 'NegotiationSkillCfg'),
  'NegotiationTopicCfg:buff1': FieldRule(idRefCfg: 'NegotiationBuffCfg'),
  'NegotiationTopicCfg:buff2': FieldRule(idRefCfg: 'NegotiationBuffCfg'),
  // 目标：前置 / 下一目标自引用。
  // 注意 `reward` 不是物品 ID 而是效果码（帮助文档：「见文档中的“效果”格式」），
  // 故不在此列规则；它归 kCodeFieldByCfg（无代码模式走积木编辑器）。
  'IntentCfg:before': FieldRule(idRefCfg: 'IntentCfg'),
  'IntentCfg:next': FieldRule(idRefCfg: 'IntentCfg'),
  // 生日派对：连线题目左右列无需引用规则（自由文本）
  // 角色 id 列表（1D，非指令行）：原先没有规则，被 isEffectLikeField 的
  // 'roles' 猜中而误走效果补全框；补规则后回到「多值 + 角色候选」，
  // 无代码模式下接入实体浏览面板。
  'ClothTypeCfg:roles': FieldRule(dictName: 'roles'),
  'HairTypeCfg:roles': FieldRule(dictName: 'roles'),
  'KZoneCommentCfg:roles': FieldRule(dictName: 'roles'),
  'KZoneMessageBoardCfg:roles': FieldRule(dictName: 'roles'),
  // 跨表引用补齐（来源：后端权威引用表 native/server/services/semantic_core.cpp
  // 的 kRules —— 跳转/关联 ID 手写最易错，无代码模式下列为只读 + 浏览选择；
  // 关闭无代码模式时也让这些字段拿到「ID · 预览」候选）。
  'ActionCfg:evtId': FieldRule(idRefCfg: 'EvtCfg'),
  'ActionCfg:next': FieldRule(idRefCfg: 'ActionCfg'),
  'ItemCfg:talkId': FieldRule(idRefCfg: 'TalkCfg'),
  'GiftEvtCfg:talkId': FieldRule(idRefCfg: 'TalkCfg'),
  'InteractCfg:talkId': FieldRule(idRefCfg: 'TalkCfg'),
  'LoveGreetingCfg:talkId': FieldRule(idRefCfg: 'TalkCfg'),
  'LoveDrawCfg:talkId': FieldRule(idRefCfg: 'TalkCfg'),
  'NpcActivityCfg:talkId': FieldRule(idRefCfg: 'TalkCfg'),
  'TalkInputMinigameCfg:talkId': FieldRule(idRefCfg: 'TalkCfg'),
  'TripSpotCfg:evtId': FieldRule(idRefCfg: 'EvtCfg'),
  'ExpoEvtCfg:evtId': FieldRule(idRefCfg: 'EvtCfg'),
  'AnimeConCfg:evtId': FieldRule(idRefCfg: 'EvtCfg'),
  'MovieCfg:talks': FieldRule(idRefCfg: 'TalkCfg'),
  'NegotiationCfg:talks': FieldRule(idRefCfg: 'TalkCfg'),
  // 第三方权威 schema 有说明但未标 range（或 range 是复合目标）的引用/枚举：
  // 无代码模式下列为「只选不敲」，关闭时也走候选下拉。
  'EndingOptionCfg:part': FieldRule(idRefCfg: 'EndingPartCfg'),
  'EndingPartCfg:options': FieldRule(idRefCfg: 'EndingOptionCfg'),
  'EndingPartCfg:evt': FieldRule(idRefCfg: 'EvtCfg'),
  'PersonAttrCfg:order': FieldRule(idRefCfg: 'TraitsCfg'),
  // 说明文明确是「某某 ID 列表」、但第三方 schema 未标 range.table 的数组字段：
  // 补齐后不再落进效果积木编辑器（它们本就不是效果码）。
  'ActionCfg:attrs': FieldRule(dictName: 'attrs'),
  'ActionEvtCfg:evts': FieldRule(idRefCfg: 'EvtCfg'),
  'CGCfg:startTalks': FieldRule(idRefCfg: 'TalkCfg'),
  'EvtCfg:miniGame': FieldRule(idRefCfg: 'MinigameCfg'),
  'IntentCfg:failTalk': FieldRule(idRefCfg: 'TalkCfg'),
  'IntentCfg:finishTalk': FieldRule(idRefCfg: 'TalkCfg'),
  'PhoneMsgCfg:next': FieldRule(idRefCfg: 'PhoneMsgCfg'),
  'TVCfg:talks': FieldRule(idRefCfg: 'TalkCfg'),
  // BookCfg.themes：固定主题编号（第三方 schema 说明 1/2/4/5/6/7/9/11）。
  'BookCfg:themes': FieldRule(fixed: {
    '1': '益智',
    '2': '现实',
    '4': '励志',
    '5': '少儿',
    '6': '科普',
    '7': '幻想',
    '9': '历史',
    '11': '古典',
  }),
};

/// 全局字段 key → 下拉框规则（兜底）。
const kRuleByField = <String, FieldRule>{
  'role': FieldRule(dictName: 'roles'), // 发布者ID / 发送者ID
  'roleIds': FieldRule(dictName: 'roles'), // 说话人（群组，可多值）
  'npc': FieldRule(dictName: 'roles'), // 指定对象
  'roleId': FieldRule(dictName: 'roles'),
  'npcId': FieldRule(dictName: 'roles'),
  'item': FieldRule(dictName: 'items'),
  'itemId': FieldRule(dictName: 'items'),
  'reward': FieldRule(dictName: 'items'),
  'bgm': FieldRule(dictName: 'audios'),
  'sound': FieldRule(dictName: 'sound'),
  'bg': FieldRule(dictName: 'bgs'), // 背景图
  'icon': FieldRule(dictName: 'icons'),
  'face': FieldRule(dictName: 'icons'),
  'map': FieldRule(dictName: 'maps'),
  'mapId': FieldRule(dictName: 'maps'),
  'job': FieldRule(dictName: 'jobs'),
  'jobId': FieldRule(dictName: 'jobs'),
  'attr': FieldRule(dictName: 'attrs'),
  'attrId': FieldRule(dictName: 'attrs'),
  'disappearTime': FieldRule(dictName: 'turns'), // 消失回合
  'action': FieldRule(dictName: 'actions'),
  // 新纳入玩法表的通用兜底：成员列表按人物、evt/evtId 按事件表引用
  'npcIds': FieldRule(dictName: 'roles'), // 队伍成员（可多值）
  'evtId': FieldRule(idRefCfg: 'EvtCfg'), // 关联事件（漫展/景点/世博）
  'evt': FieldRule(idRefCfg: 'EvtCfg'), // 关联事件（世博展馆）
};

/// 生成引用规则的稳定实例缓存。
///
/// `_options()` 等处以 `rule` 的 identical 作为缓存键（见 schema 编辑器的
/// `_optCacheKey`），每次 build 都 new 一个 FieldRule 会让缓存恒失效，故按
/// `cfg:key` 记忆化。
final Map<String, FieldRule> _generatedRules = {};

/// 第三方权威 schema 声明的引用目标 → idRef 规则（仅 `cfg:key` 精确匹配）。
FieldRule? _generatedRuleFor(String cfgName, String key) {
  final id = '$cfgName:$key';
  final target = kFieldRefTargets[id];
  if (target == null) return null;
  return _generatedRules.putIfAbsent(id, () => FieldRule(idRefCfg: target));
}

/// 取字段对应的下拉框规则：手写 cfg 限定优先 → 手写全局 key → 生成引用兜底。
///
/// 生成兜底来自第三方权威 schema 的 `range.table`（见 field_ref_data.dart），
/// 覆盖那些「本体 schema 里是裸 Number/数组、但语义是另一张表记录 ID」的字段，
/// 让无代码模式在所有编辑页都能把它们收敛为「只选不敲」的引用形态。
///
/// [kCodeFieldByCfg] 显式登记的效果码**永不**是引用：`reward` 这类全局 key 规则
/// 会把 IntentCfg 的效果码误当物品 ID，命中即短路成 null，交回效果补全/积木。
FieldRule? fieldRuleFor(String cfgName, String key) {
  final id = '$cfgName:$key';
  if (kCodeFieldByCfg.contains(id)) return null;
  return kRuleByCfgField[id] ??
      kRuleByField[key] ??
      _generatedRuleFor(cfgName, key);
}

/// 后端 `DEFAULT_TALK_KEY_MAP` / `DEFAULT_OPT_KEY_MAP` 缺标签的字段。
///
/// KeyTranslator 的 camelCase 兜底对 `effect2` / `maxoptions` / `showTxt` 这类
/// key 会原样吐英文，指南里它们又确有名目，所以在前端补一层覆盖表。
const kGuideFieldLabels = <String, String>{
  'highlights': '高亮词语',
  'audio': '配音',
  'time': '显示时间',
  'showTxt': '悬浮提示文本',
  'replace': '替换对白',
  'maxoptions': '最大选项数',
  'miniGame': '小游戏',
  'effect': '效果代码',
  'effect2': '效果代码(失败)',
  'vocals': '配音(遗留)',
  'roleIds': '说话人',
  'roleName': '自定义名字',
  'content': '台词内容',
  'nextTalk': '下一句',
  'nextTalk2': '失败跳转',
  'option': '选项列表',
  'stateCond': '状态要求',
  'pressure': '压力要求',
  'tag': '特殊标签',
  'talkId': '主支对白',
  'talkId2': '支线对白',
};

/// 剧情图认定的对白必填项。
///
/// Mod 指南「d. 新建对话 / f. 设置对白 / g. 添加选项」对每个参数都只讲用途，
/// 从未标注必填（效果甚至明说「可不填」、背景 0 即沿用上一句）；本体数据同样
/// 大面积留空：bg 94%、roleName 95%、audio 99.6%、time 99.9% 为空，nextTalk
/// 也有 7.5% 合法为空（每段对话的最后一句）。把这些挂上「必填」星号，剧情图
/// 里每句正常收尾的对白都会被误报「必填未填」。
///
/// 唯一在本体数据里几乎不为空的是 content（98963 条仅 0.7% 为空）——没有正文
/// 的对白无法成立，这才是真正的必填项。
const kGuideTalkRequired = <String>{'content'};

/// 选项的必填项：同上，仅 content（选项文本，4381 条本体记录 0 条为空）。
/// precondition 97% 为空（无前提 = 恒可选），talkId 也有 152 条合法缺省。
const kGuideOptionRequired = <String>{'content'};

/// 内联展开卡片（约 200px 宽、高度固定）直接铺出的字段。
///
/// 2D 指令类字段（roles/effect/replace/precondition…）需要成规模的编辑区，
/// 内联放不下的一律留给 Inspector，这里只放「改一句话最常碰」的项。
const kFlowInlineTalk = <String>[
  'roleName',
  'content',
  'check',
  'screenEffect',
  'bg',
  'audio',
  'time',
  'highlights',
  'nextTalk',
];

/// 内联展开卡片的选项字段。
const kFlowInlineOption = <String>[
  'content',
  'precondition',
  'check',
  'talkId',
  'talkId2',
  'nextEvtId',
];

/// 内联清单：按节点类型取字段 key 列表。
///
/// TODO(插件声明)：后端 `plugin_system` 的 `body_fields` / `hidden_ports` 至今
/// 没有生产者（内置预设的 `toCardSpec()` 不输出这两个键），本期不消费。
/// `hidden_ports` 的风险更不对称 —— 藏起端口会造出「记录有值、图上无边、
/// 端口不存在」的三态不一致，用户既看不见也删不掉那根线。见
/// `story_flow_node_presets.dart` 的 `toCardSpec()`。
List<String> flowInlineFields(bool isOption) =>
    isOption ? kFlowInlineOption : kFlowInlineTalk;

/// Inspector 的「常用」段；不在常用清单里的字段自动落到「高级」。
const kFlowCommonTalk = <String>[
  'content',
  'roleName',
  'roleIds',
  'bg',
  'audio',
  'time',
  'screenEffect',
  'check',
  'nextTalk',
  'highlights',
];

/// Inspector 选项的「常用」段。
const kFlowCommonOption = <String>[
  'content',
  'precondition',
  'check',
  'talkId',
  'nextEvtId',
  'effect',
];

/// 单个字段的展示与编辑元数据（剧情图内联区与 Inspector 共用）。
class FieldMeta {
  const FieldMeta({
    required this.key,
    required this.type,
    required this.label,
    required this.section,
    this.cfg = '',
    this.required = false,
    this.effectLike = false,
    this.suggestMode,
    this.multivalued = false,
    this.replaceWholeOnAccept = false,
    this.editable = true,
    this.rule,
  });

  /// 字段所属配置表。用于无代码模式的渲染分流（[noCodeShapeFor]）；
  /// 手搓 meta 的调用方（测试）可留空，空串只影响 cfg 限定的少数判定。
  final String cfg;

  final String key;

  /// schema 声明的类型：Number / String / 1D Array / 2D Array。
  final String type;
  final String label;

  /// 'common' | 'advanced'
  final String section;

  /// 剧情图认定的必填项：仅 content（考证见 [kGuideTalkRequired]）。
  final bool required;

  /// 效果/条件/指令类字段：必须走带校验的补全框，禁止裸 TextBox，
  /// 否则全角逗号能绕过校验直接进存档。
  final bool effectLike;

  /// 传给补全接口的 mode（action/screen/cost/condition/effect）。
  final String? suggestMode;

  /// 多值字段：接受候选后补分隔符。
  final bool multivalued;

  /// 接受候选时整串替换（指南：一句话只能填一个屏幕效果）。
  final bool replaceWholeOnAccept;

  /// false = 只读展示（主键 id、schema 未声明的扩表字段）。
  final bool editable;

  /// 候选来源规则（字典 / 固定项 / ID 引用）。
  final FieldRule? rule;

  bool get inCommon => section == 'common';
}

/// 显式认定为「效果/条件/指令码」的字段（cfg:key）：优先于规则否决与家族匹配。
///
/// 与后端权威表对齐（`native/server/services/semantic_graph.cpp:751-761` 的
/// TableSpec —— 哪些表的哪些字段是真码数组），再加 GUI 既有的指令行字段。
/// 列在这里的字段即使命中下拉规则也仍按码处理（如 TalkCfg:roles 是人物指令行）。
const kCodeFieldByCfg = <String>{
  // EvtCfg 事件：条件 / 效果
  'EvtCfg:condition', 'EvtCfg:effect',
  // TalkCfg 对白：判定 / 效果 / 失败效果 / 人物指令行 / 屏幕效果
  'TalkCfg:check', 'TalkCfg:effect', 'TalkCfg:effect2',
  'TalkCfg:roles', 'TalkCfg:screenEffect',
  // OptionCfg 选项：判定 / 前提 / 效果 / 失败效果 / 状态要求 / 压力要求
  'OptionCfg:check', 'OptionCfg:precondition', 'OptionCfg:effect',
  'OptionCfg:effect2', 'OptionCfg:stateCond', 'OptionCfg:pressure',
  // InteractCfg 互动：条件 / 效果
  'InteractCfg:cond', 'InteractCfg:effect',
  // 邀约：出现条件 / 互动条件
  'FriendRequestCfg:appearCond', 'FriendRequestCfg:interactCond',
  // 恋爱事件条件
  'LoveGreetingCfg:cond', 'LoveBreakfastCfg:cond', 'LoveRibbonCfg:cond',
  // 小游戏动作效果
  'MinigameActionCfg:effect',
  // 成长码
  'PersonGrowCfg:grow',
  // 目标奖励：帮助文档明确是「效果」格式（第三方 schema 亦标 Effect）；
  // key 不含任何码家族词，必须显式登记，否则会被误当物品引用而无法积木化。
  'IntentCfg:reward',
};

/// 显式排除：key 命中码家族、但语义不是码的数组字段。
///
/// 这些字段有的是成对数值、有的是角色 id 列表——若走效果补全框，用户会看到
/// 一片红色语法提示且关不掉。`AnimationCostCfg:costs` 是纯数值对；
/// 四条 `roles` 已在上方 kRuleByCfgField 补了角色规则，走多值候选。
const kNonCodeArrayFields = <String>{
  'AnimationCostCfg:costs',
  'ClothTypeCfg:roles',
  'HairTypeCfg:roles',
  'KZoneCommentCfg:roles',
  'KZoneMessageBoardCfg:roles',
};

/// 码字段的 key 家族（小写包含匹配）。扩展自原先的单点枚举：
/// `appearCond`/`unlockCond`/`gaozhongCond`/`conds` 这类以 "cond" 结尾的
/// 字段原先整体漏网，现在统一命中条件语境。
const _kCodeKeyFamilies = <String>[
  'effect',
  'cond',
  'check',
  'precondition',
  'cost',
  'pressure',
  'grow',
  'unlock',
  'demand',
  'impossible',
  'interactable',
];

bool _isCodeKeyFamily(String key) {
  final k = key.toLowerCase();
  if (k == 'roles' || k == 'screeneffect') return true;
  for (final f in _kCodeKeyFamilies) {
    if (k.contains(f)) return true;
  }
  return false;
}

/// 该字段是否「效果/条件/指令」类。
///
/// 判定序（单一真源，schema 编辑器 / 剧情图内联 / Inspector 共用）：
///   1. 类型门：只有 1D/2D Array 可能是码；
///   2. [kNonCodeArrayFields] 显式否决；
///   3. [kCodeFieldByCfg] 显式允许（压过第 4 步的规则否决）；
///   4. 有下拉/引用规则 = ID/枚举值，不是码；
///   5. key 命中 [_kCodeKeyFamilies] 家族。
bool isEffectLikeField(String cfg, String key, String type) {
  if (type != '1D Array' && type != '2D Array') return false;
  final id = '$cfg:$key';
  if (kNonCodeArrayFields.contains(id)) return false;
  if (kCodeFieldByCfg.contains(id)) return true;
  if (fieldRuleFor(cfg, key) != null) return false;
  return _isCodeKeyFamily(key);
}

/// 补全模式：与 /api/effect_suggest 的 mode 参数一致。
///
/// 返回 null = 该 key 不属任何码家族（调用方按需回退 'effect'）。
/// [cfg] 目前只用于 cfg 限定的 roles（其他表里的 roles 是 id 列表，已被
/// [kNonCodeArrayFields] 挡在码判定之外）。
String? effectSuggestMode(String cfg, String key) {
  final k = key.toLowerCase();
  if (k == 'screeneffect') return 'screen';
  if (k == 'cost') return 'cost';
  if (k == 'roles') return 'action';
  if (k.contains('cond') ||
      k == 'check' ||
      k.contains('precondition') ||
      k.contains('unlock') ||
      k.contains('demand') ||
      k.contains('impossible')) {
    return 'condition';
  }
  if (k.contains('effect') ||
      k.contains('pressure') ||
      k.contains('grow') ||
      k.contains('interactable')) {
    return 'effect';
  }
  return null;
}

// ─────────────────────────────────────────────────────────────────────────────
// 全字段可视化输入（M1）：按 schema 类型 + 规则派生「视觉控件」。
// 效果类字段一律返回 null（走 EffectHintField/搭建器），String 不升级
// （纯文本与贴图路径另成体系，现有缩略图/选图控件已覆盖）。
// ─────────────────────────────────────────────────────────────────────────────

/// 字段的可视化输入形态；null = 维持原 文本框/下拉 路径。
enum FieldVisual {
  /// 无候选的 Number → 步进输入框（数字框自带加减，仍可手输精确值）。
  numberBox,

  /// 命中 [kFieldNumericHints] 区间的 Number → 步进框 + 区间滑杆。
  numberSlider,

  /// 音频引用（值为 AudioCfg id）→ 行内试听（可播 BGM/音效/配音字节）。
  audioPick,

  /// 对白/选项/事件跳转目标 → 「ID · 内容预览」浏览对话框。
  jumpTarget,

  /// 其余单值 Number ID 引用 → 带预览的浏览对话框（与下拉并存）。
  idBrowse,

  /// 带字典/ID 候选的 1D Array → 文本框下按序展示「ID·名称」chips，
  /// 可移除、可左右移序。
  multiIdChips,
}

/// 跳转目标字段（cfg:key）：这些 ID 手写最易错（前缀归属强校验），
/// 统一升级浏览式选择；数组按序多选，Number 单选。
const _kJumpTargetFields = <String>{
  'EvtCfg:talkId',
  'TalkCfg:nextTalk',
  'TalkCfg:nextTalk2',
  'TalkCfg:option',
  'OptionCfg:talkId',
  'OptionCfg:talkId2',
  'OptionCfg:nextEvtId',
};

/// 音频引用字段的全局 key（忽略大小写）：值都是 AudioCfg 表 id。
const _kAudioFieldKeys = <String>{
  'audio',
  'bgm',
  'sound',
  'clickaudio',
  'entersound',
  'music',
};

/// 数值字段的游戏语义区间提示：cfg:key → (min, max, step)。
/// 只约束滑杆默认显示区间与步进值——步进框不受限；当前值越界时滑杆
/// 轨道自动扩展包含它（永不钳制/覆盖用户数据）。区间依据本体口径：
/// 好感阈值 ±999、概率权重 0~100、出现概率 0~1 等。
const kFieldNumericHints = <String, (double, double, double)>{
  'RelationCfg:condition': (-999, 999, 1),
  'RelationCfg:upgradeCost': (0, 100, 1),
  'RelationCfg:socialCapacity': (0, 50, 1),
  'FriendRequestCfg:weight': (0, 100, 1),
  'LoveBreakfastCfg:weight': (0, 100, 1),
  'LoveRibbonCfg:weight': (0, 100, 1),
  'NpcActivityCfg:appearRate': (0, 1, 0.05),
  'NpcActivityCfg:cnt': (0, 10, 1),
  'FishCfg:weight': (0, 100, 1),
};

bool _isAudioRef(String cfg, String key, FieldRule? rule) =>
    rule?.idRefCfg == 'AudioCfg' ||
    rule?.dictName == 'audios' ||
    _kAudioFieldKeys.contains(key.toLowerCase());

/// 派生字段的可视化输入形态（schema 编辑器与剧情图共用同一判定）。
///
/// 判定序与 `_FieldInput.build` 的分支序对齐：效果类 → 跳转 → 按类型分派。
FieldVisual? fieldVisualFor(
  String cfg,
  String key,
  String type,
  FieldRule? rule,
) {
  if (type == 'String') return null;
  if (isEffectLikeField(cfg, key, type)) return null;
  final id = '$cfg:$key';
  if (_kJumpTargetFields.contains(id)) return FieldVisual.jumpTarget;
  switch (type) {
    case 'Number':
      if (_isAudioRef(cfg, key, rule)) return FieldVisual.audioPick;
      if (kFieldNumericHints.containsKey(id)) return FieldVisual.numberSlider;
      if (rule?.idRefCfg != null) return FieldVisual.idBrowse;
      return FieldVisual.numberBox;
    case '1D Array':
      // vocals 是 [声ID, 音量] 的遗留扁平对：只升级试听，不做多选 chips。
      if (key.toLowerCase() == 'vocals') return FieldVisual.audioPick;
      final multiRef = rule != null &&
          !rule.singleArray &&
          (rule.idRefCfg != null || rule.dictName != null);
      return multiRef ? FieldVisual.multiIdChips : null;
    default:
      return null;
  }
}

/// 无代码模式开启时该字段的渲染形态（三面共用的唯一分流表）。
enum NoCodeShape {
  /// 普通文本/数值字段：无代码模式不改变渲染（对白正文、名称、描述、数值
  /// 不是"代码"，禁掉它们编辑器就没法用了）。
  untouched,

  /// 专用视觉控件（音频试听 / 多值 chips / 跳转浏览…）：控件照旧，
  /// 但其伴随文本框不再渲染。
  visual,

  /// 引用/枚举字段（dict / fixed / idRef）：只留下拉或实体浏览面板。
  reference,

  /// 效果/条件/指令类：内联积木编辑器，**没有任何文本输入**。
  blocks,
}

/// 按优先级表派生渲染形态：
///   1. 有专用视觉控件 → [NoCodeShape.visual]
///   2. 效果/条件/指令类 → [NoCodeShape.blocks]
///   3. 有下拉/引用规则 → [NoCodeShape.reference]
///   4. 其余 1D/2D 数组 → [NoCodeShape.blocks]
///   5. 其余 → [NoCodeShape.untouched]
///
/// 第 2 步压过第 3 步：[kCodeFieldByCfg] 显式登记的效果码是唯一真源，即使它
/// 同时也命中某条 range/引用规则，也必须积木化——否则开启无代码后就只剩一个
/// "选 ID"的下拉，用户改不了效果（`IntentCfg:reward` 曾被物品引用规则误降级）。
/// 判定表只决定积木编辑器的 mode（effect/condition/cost/action/screen），
/// 不再决定"要不要出现"。
NoCodeShape noCodeShapeFor(
  String cfg,
  String key,
  String type,
  FieldRule? rule,
) {
  final visual = fieldVisualFor(cfg, key, type, rule);
  // 步进框/滑杆是"填数值"，不是"输代码"：无代码模式不改变它们。
  if (visual != null &&
      visual != FieldVisual.numberBox &&
      visual != FieldVisual.numberSlider) {
    return NoCodeShape.visual;
  }
  if (isEffectLikeField(cfg, key, type)) return NoCodeShape.blocks;
  if (rule != null) return NoCodeShape.reference;
  if (type == '1D Array' || type == '2D Array') return NoCodeShape.blocks;
  return NoCodeShape.untouched;
}

/// 1D 文本层 token 拆分：与既有 `_namePreview`/多选合并共用一套分隔符约定
/// （逗号/分号/顿号/换行），保证 chips 展示与写回文本完全等价。
List<String> fieldTextTokens(String text) => text
    .split(RegExp(r'[;，、,\n]'))
    .map((e) => e.trim())
    .where((e) => e.isNotEmpty)
    .toList();

/// 字段标签：覆盖表 → keyMaps[cfg][key] → KeyTranslator 兜底。
String flowFieldLabel(AppState state, String cfg, String key) {
  final guide = kGuideFieldLabels[key];
  if (guide != null && guide.isNotEmpty) return guide;
  final maps = state.keyMaps[cfg];
  if (maps is Map) {
    final v = maps[key];
    if (v is String && v.isNotEmpty) return v;
  }
  return KeyTranslator(state).translate(key, cfg);
}

/// 某张表的全字段元数据，字段全集取自 `gameSchema[cfg]`（schema 新增字段会自动出现）。
///
/// 注意必须取 `gameSchema[cfgName][field]`：/api/schema 的 `field_types` 是跨表
/// 拍平的，同名字段会互相覆盖。
List<FieldMeta> flowFieldMetas(AppState state, String cfg) {
  final table = state.gameSchema[cfg];
  if (table is! Map) return const [];
  final common = cfg == 'OptionCfg' ? kFlowCommonOption : kFlowCommonTalk;
  final required = cfg == 'OptionCfg'
      ? kGuideOptionRequired
      : kGuideTalkRequired;
  final out = <FieldMeta>[];
  final order = <String, int>{};
  var i = 0;
  for (final entry in table.entries) {
    final key = entry.key.toString();
    order[key] = i++;
    final type = entry.value is String
        ? entry.value as String
        : (key == 'id' ? 'Number' : '');
    final effectLike = isEffectLikeField(cfg, key, type);
    out.add(
      FieldMeta(
        key: key,
        type: type,
        cfg: cfg,
        label: flowFieldLabel(state, cfg, key),
        section: common.contains(key) ? 'common' : 'advanced',
        required: required.contains(key),
        effectLike: effectLike,
        suggestMode: effectLike ? effectSuggestMode(cfg, key) : null,
        multivalued: type == '1D Array' || type == '2D Array',
        replaceWholeOnAccept: key == 'screenEffect',
        editable: key != 'id',
        rule: fieldRuleFor(cfg, key),
      ),
    );
  }
  // 常用段在前、段内按 schema 声明序，保证 Tab 跳焦次序与肉眼浏览次序一致。
  out.sort((a, b) {
    final d = (a.inCommon ? 0 : 1).compareTo(b.inCommon ? 0 : 1);
    return d != 0 ? d : order[a.key]!.compareTo(order[b.key]!);
  });
  return out;
}

/// 剧情图内联区需要的字段元数据（按 [flowInlineFields] 清单顺序）。
List<FieldMeta> flowInlineMetas(AppState state, String cfg, bool isOption) {
  final metas = {for (final m in flowFieldMetas(state, cfg)) m.key: m};
  return [
    for (final key in flowInlineFields(isOption))
      if (metas[key] != null) metas[key]!,
  ];
}

/// 游戏友好型字段描述映射 (cfgName → key → friendly description)
/// 
/// 用于替代默认的技术化提示文本 "类型为 [String]，按编码格式输入"
/// 提供更直观、更贴合游戏内容的说明
const kGameFriendlyHints = <String, Map<String, String>>{
  // FishCfg - 鱼类配置
  'FishCfg': {
    'btn': '触发言语\n（例如："太棒了！"）',
    'name': '鱼的中文名\n（例如："鲫鱼"、"鲤鱼"）',
    'weight': '出现概率\n（数字越大越容易被钓起）',
    'item': '获得道具编号\n（如果没有奖励就填 0）',
    'weights': '重量范围 [最小 g, 最大 g]\n（例如：[200.0, 400.0]）',
    'type': '鱼种分类\n（1=淡水鱼，2=海水鱼，3=未知）',
    'icon': '图标图片路径\n（留空使用默认图标）',
  },
  
  // BookCfg - 书籍配置
  'BookCfg': {
    'name': '书名',
    'themes': '书籍主题标签\n（逗号分隔的数组，如：科学，文学，历史）',
    'type': '书籍分类\n（1=教材，2=小说，3=科普）',
    'capacity': '阅读容量/页数',
    'value': '购买价格',
    'sellPrice': '出售价格',
    'description': '书籍简介',
    'talkReaction': '谈论此书时他人的反应',
  },
  
  // JobCfg - 职业路径
  'JobCfg': {
    'id': '职业编号',
    'name': '职业名称\n（企业家、医生、教师等）',
    'unlock': '解锁条件\n（需要先达到什么等级或属性）',
    'weight': '选择概率',
    'scoreRate': '评分标准倍数',
    'needAttrs': '需要的属性要求',
  },
  
  // PersonAttrCfg - 主角属性
  'PersonAttrCfg': {
    'mood': '心情值',
    'intelligence': '智商',
    'trust': '信任度/EQ',
    'physique': '体质',
    'energy': '精力值',
    'experience': '经验值',
    'allowance': '零花钱',
  },
  
  // RelationCfg - 人际关系
  'RelationCfg': {
    'name': '关系等级名称\n（路人、朋友、好友、密友、恋人）',
    'condition': '升级所需的亲密度阈值',
    'socialCapacity': '此等级能拥有的最大人数',
    'upgradeCost': '升级所需消耗的积分',
  },
  
  // MinigameCfg - 小游戏定义
  'MinigameCfg': {
    'id': '小游戏编号',
    'name': '小游戏名称\n（钓鱼、篮球、答题等）',
    'bgm': '背景音乐编号',
    'tips': '玩法说明\n（告诉玩家怎么操作）',
  },
  
  // AchievementCfg - 成就系统
  'AchievementCfg': {
    'id': '成就编号',
    'name': '成就名称',
    'cost': '达成所需的时间或次数',
    'group': '所属成就组别',
    'lv': '成就等级',
    'attrId': '关联的属性 ID',
  },
  
  // SkillCfg - 技能配置
  'SkillCfg': {
    'id': '技能编号',
    'name': '技能名称\n（篮球、钓鱼、手工等）',
    'desc': '技能详细描述',
    'action': '关联的行动 ID',
  },
  
  // MapCfg - 地图地点
  'MapCfg': {
    'id': '地点编号',
    'name': '地点名称\n（教学楼、操场、图书馆）',
    'shortName': '简称\n（可选，如"操场"）',
    'floorName': '楼层名称',
    'type': '区域类型\n（室内/室外/半开放）',
  },

  // AnimationCfg - 番剧（追番系统）
  // 语义经 GameSources/Assembly-CSharp/AnimeData.cs 校验：
  //   time 与当年年份比较（game 年份 >= time 才可能搜到）→ 上映年份；
  //   weight 参与搜索随机抽取 → 发现权重；
  //   level == 3 判定为「神作」，可看 3 次，其余 2 次。
  'AnimationCfg': {
    'level': '品质等级\n（3 为神作，可看 3 次；其余看 2 次）',
    'time': '上映年份\n（游戏年份到达此年份后才可能被搜到）',
    'weight': '发现权重\n（搜索时按权重随机抽中，越大越容易被搜到）',
  },
};

/// 取游戏友好型字段描述。
///
/// [fieldKey] 必须是**字段键**（schema 里的原始 key，如 `sellPrice`），不是
/// 翻译后的中文显示名——调用方曾传显示名导致整张表基本查不中。查表先精确、
/// 再忽略大小写，兼容 schema 里的大小写差异。
String? getGameFriendlyHint(String cfgName, String fieldKey) {
  final hints = kGameFriendlyHints[cfgName];
  if (hints == null) return null;
  final direct = hints[fieldKey];
  if (direct != null) return direct;
  final lower = fieldKey.toLowerCase();
  for (final entry in hints.entries) {
    if (entry.key.toLowerCase() == lower) return entry.value;
  }
  return null;
}

/// 跨表通用的字段键说明（忽略大小写）。
///
/// 与 [kRuleByField] 的定位一致：cfg 专属说明（[kGameFriendlyHints]、
/// [kFieldDescriptions]）缺位时按 key 兜底，覆盖那些「换个表意思也一样」的
/// 字段——名称、图标、权重、人物/物品/地点引用……语义随表漂移较大的 key
/// （effect/cond/cost 这类走到码判定或类型兜底）不在此列。
const kFieldHelpByKey = <String, String>{
  // 通用标识与文本
  'id': '记录编号（主键）：新建时自动分配，改动前先确认没有别的记录引用它',
  'name': '游戏内显示的名称',
  'name2': '副名称 / 别名',
  'title': '标题文字',
  'desc': '说明文字，展示给玩家看',
  'dsc': '说明文字，展示给玩家看',
  'description': '说明文字，展示给玩家看',
  'desc1': '说明文字（第一段）',
  'desc2': '说明文字（第二段）',
  'content': '正文内容，展示给玩家看',
  'content2': '正文内容（第二种情况）',
  'text': '文本内容，展示给玩家看',
  'txt': '文本内容，展示给玩家看',
  'btn': '按钮上的文字',
  'tips': '提示文字',
  'note': '备注：只给自己看，不影响游戏',
  'answer': '正确答案',
  'grade': '评级 / 等级',
  'rank': '排名 / 档位',
  // 资源
  'icon': '图标 / 立绘资源名（相对游戏资源目录）',
  'icon2': '副图标资源名',
  'icon_xx': '小尺寸图标资源名',
  'img': '图片资源名',
  'imgs': '图片资源名列表，用逗号分隔',
  'url': '资源文件名 / 路径',
  'urls': '资源文件名列表，用逗号分隔',
  'bg': '背景图编号（引用 BgCfg）',
  'bgUrl': '背景图片资源名',
  'bgUrl2': '背景图片资源名（第二套）',
  'texture': '贴图资源名',
  'thumb': '配图资源名',
  'audio': '音频编号（引用 AudioCfg）',
  'bgm': '背景音乐编号（引用 AudioCfg，可试听）',
  'sound': '音效编号（引用 AudioCfg）',
  'music': '音乐编号（引用 AudioCfg）',
  'clickAudio': '点击音效编号（引用 AudioCfg）',
  'enterSound': '进入音效编号（引用 AudioCfg）',
  // 枚举与数值
  'type': '类型：按对应玩法的编号填写；有候选项时从下拉里选',
  'type2': '第二类型 / 子类型',
  'level': '等级：数字越大通常越高档',
  'lv': '等级',
  'weight': '权重 / 概率：数字越大越容易被抽中',
  'weights': '权重列表，依次对应各个档位',
  'rate': '概率 / 比例',
  'rateType': '概率类型',
  'probability': '出现概率（0.0~1.0）',
  'value': '数值',
  'values': '数值列表，用逗号分隔',
  'min': '最小值',
  'max': '最大值',
  'target': '目标值 / 目标编号',
  'exp': '经验值',
  'score': '分数',
  'scores': '分数列表，用逗号分隔',
  'add': '增量',
  'freq': '频率',
  'speed': '速度',
  'width': '宽度',
  'height': '高度',
  'offset': '偏移量',
  'scale': '缩放比例',
  'time': '时间 / 时长',
  'cnt': '次数 / 数量',
  'count': '数量',
  'num': '序号 / 数量',
  'round': '回合数：0 常表示不限 / 永久',
  'duration': '持续的回合数',
  'group': '分组：同组通常互斥或同类聚合',
  'order': '排序序号：数字越小越靠前',
  'tag': '分类标签',
  'tags': '分类标签列表，用逗号分隔',
  'state': '状态',
  'hide': '是否隐藏：0 显示，非 0 隐藏',
  'disable': '是否禁用',
  'isShow': '是否显示',
  'redpoint': '是否显示红点提示',
  'color': '颜色值',
  'color1': '颜色值',
  'color2': '颜色值',
  'bgColor': '背景颜色',
  'colors': '颜色值列表，用逗号分隔',
  'gender': '性别要求',
  'sex': '性别',
  'birthday': '生日',
  'school': '学校 / 学院',
  'class': '班级',
  'lesson': '课程编号',
  'scoreRate': '评分倍率',
  // 跨表引用
  'role': '人物编号（引用角色表）',
  'roleId': '人物编号（引用角色表）',
  'roles': '人物编号列表，用逗号分隔',
  'roleName': '自定义的说话人名字（留空用默认名）',
  'npc': '指定人物编号',
  'npcId': '指定人物编号',
  'npcIds': '人物编号列表，用逗号分隔',
  'item': '物品编号（引用 ItemCfg）',
  'itemId': '物品编号（引用 ItemCfg）',
  'items': '物品编号列表，用逗号分隔',
  'itemTag': '物品分类标签，可填多个',
  'prize': '奖励物品编号',
  'reward': '奖励物品编号 / 奖励效果',
  'map': '地点编号（引用 MapCfg）',
  'mapId': '地点编号（引用 MapCfg）',
  'talk': '关联的对白编号（引用 TalkCfg）',
  'talkId': '关联的对白编号（引用 TalkCfg）',
  'talks': '关联的对白编号列表，用逗号分隔',
  'evt': '关联的事件编号（引用 EvtCfg）',
  'evtId': '关联的事件编号（引用 EvtCfg）',
  'next': '下一项编号：留空或 0 表示结束',
  'nextTalk': '下一句对白编号（引用 TalkCfg）',
  'nextTalk2': '失败 / 分支后的对白编号（引用 TalkCfg）',
  'option': '选项 / 分支列表',
  'options': '选项 / 分支编号列表',
  'attr': '属性编号（引用属性表）',
  'attrId': '属性编号（引用属性表）',
  'attrs': '属性编号列表，用逗号分隔',
  'job': '职业编号（引用 JobCfg）',
  'skill': '技能编号（引用技能表）',
  'skills': '技能编号列表，用逗号分隔',
  'buff': '状态编号（引用状态表）',
  'buff1': '状态编号',
  'buff2': '状态编号',
  'card': '卡牌编号',
  'funcId': '功能编号（引用 FuncCfg）',
  'audioId': '音频编号（引用 AudioCfg）',
  'hp': '血量',
  'mp': '精力',
  'power': '威力 / 力量',
};

/// 跨表键说明：精确 → 忽略大小写。
String? _crossKeyHelp(String key) {
  final direct = kFieldHelpByKey[key];
  if (direct != null) return direct;
  final lower = key.toLowerCase();
  for (final entry in kFieldHelpByKey.entries) {
    if (entry.key.toLowerCase() == lower) return entry.value;
  }
  return null;
}

/// 数字排版：整数不带小数点，小数保留原样。
String _fmtNum(double v) =>
    v == v.roundToDouble() ? v.toInt().toString() : v.toString();

/// 字段帮助文本（当前由 schema 编辑器渲染；其他面板可按需复用）。
///
/// 判定序（自具体到通用）：
///   1. 人工精修描述 [kGameFriendlyHints]；
///   2. 参考资料里的权威字段说明 [kFieldDescriptions]；
///   3. ID 引用规则 → 点名目标配置表；
///   4. 效果 / 条件 / 指令类 → 写清指令格式；
///   5. 数值区间提示 [kFieldNumericHints]；
///   6. 跨表通用键说明 [kFieldHelpByKey]；
///   7. 按类型兜底（数值 / 文本 / 一维 / 二维数组）。
///
/// 任何分支都不会再吐出「「X」字段的值：类型为 [Y]，按编码格式输入」这种
/// 复述标签、对玩家毫无帮助的占位文案。
String fieldHelpText(
  String cfgName,
  String key,
  String type, {
  FieldRule? rule,
}) {
  final friendly = getGameFriendlyHint(cfgName, key);
  if (friendly != null && friendly.isNotEmpty) return friendly;

  final described = kFieldDescriptions[cfgName]?[key];
  if (described != null && described.isNotEmpty) return described;

  final idRef = rule?.idRefCfg;
  if (idRef != null) {
    final label = kFieldCfgLabels[idRef];
    return label == null
        ? '引用「$idRef」表的记录编号：可从候选列表选择'
        : '引用「$label」：从候选列表选择对应记录的编号';
  }

  if (isEffectLikeField(cfgName, key, type)) {
    return '指令格式：每条指令一行，参数用逗号分隔，如 `指令ID,参数1,参数2`；'
        '可点「补全 / 查阅」按提示填写';
  }

  final hint = kFieldNumericHints['$cfgName:$key'];
  if (type == 'Number' && hint != null) {
    return '建议范围 ${_fmtNum(hint.$1)} ~ ${_fmtNum(hint.$2)}'
        '${hint.$3 != 1 ? '，步进 ${_fmtNum(hint.$3)}' : ''}';
  }

  final byKey = _crossKeyHelp(key);
  if (byKey != null) return byKey;

  switch (type) {
    case 'Number':
      return '填写数字（整数或小数按游戏口径）';
    case 'String':
      return rule?.dictName != null ? '从下拉候选里选择；也可直接填对应编号' : '填写文本';
    case '1D Array':
      return rule?.dictName != null || rule?.idRefCfg != null
          ? '多个编号用逗号分隔，如 `1,2,3`；可从候选里逐个添加'
          : '多个值用逗号分隔，如 `1,2,3`';
    case '2D Array':
      return '每行一条指令，行内参数用逗号分隔，如 `指令ID,参数1,参数2`';
    default:
      return '按游戏内的格式填写';
  }
}
