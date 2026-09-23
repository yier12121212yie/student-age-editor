/// 字段语义的单一真源：下拉/候选规则、指南标签与必选项、剧情图字段元数据。
///
/// 原本这些规则只活在 schema_editor_view.dart 的私有常量里，剧情图要用就得
/// 复制一份，两份从此各说各话。这里统一搬出来供两侧共用。
library;

import '../../core/models.dart';
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
  // 目标：前置 / 下一目标自引用，奖励物品
  'IntentCfg:before': FieldRule(idRefCfg: 'IntentCfg'),
  'IntentCfg:next': FieldRule(idRefCfg: 'IntentCfg'),
  'IntentCfg:reward': FieldRule(dictName: 'items', idRefCfg: 'ItemCfg'),
  // 生日派对：连线题目左右列无需引用规则（自由文本）
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

/// 取字段对应的下拉框规则：cfg 限定优先，其次全局 key。
FieldRule? fieldRuleFor(String cfgName, String key) =>
    kRuleByCfgField['$cfgName:$key'] ?? kRuleByField[key];

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
    this.required = false,
    this.effectLike = false,
    this.suggestMode,
    this.multivalued = false,
    this.replaceWholeOnAccept = false,
    this.editable = true,
    this.rule,
  });

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

/// 该字段是否「效果/条件/指令」类：合并原先散在 schema_editor_view 与
/// EffectHintField 里的两份相似但不相同的猜测规则。
bool isEffectLikeField(String cfg, String key, String type) {
  final k = key.toLowerCase();
  final known =
      k == 'roles' ||
      k == 'screeneffect' ||
      k == 'condition' ||
      k == 'cond' ||
      k == 'precondition' ||
      k == 'statecond' ||
      k == 'check' ||
      k == 'cost' ||
      k == 'effect2' ||
      k == 'hideeffect' ||
      k == 'usingeffect' ||
      k == 'pressure' ||
      k == 'grow' ||
      k.contains('effect');
  if (!known) return false;
  return type == '2D Array' || type == '1D Array';
}

/// 补全模式：与 /api/effect_suggest 的 mode 参数一致。
String? effectSuggestMode(String key) {
  final k = key.toLowerCase();
  if (k == 'roles') return 'action';
  if (k == 'screeneffect') return 'screen';
  if (k == 'cost') return 'cost';
  if (k == 'condition' || k == 'cond' || k == 'precondition' || k == 'check') {
    return 'condition';
  }
  if (k == 'pressure' || k == 'grow') return 'effect';
  if (k.contains('effect')) return 'effect';
  return null;
}

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
        label: flowFieldLabel(state, cfg, key),
        section: common.contains(key) ? 'common' : 'advanced',
        required: required.contains(key),
        effectLike: effectLike,
        suggestMode: effectLike ? effectSuggestMode(key) : null,
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
