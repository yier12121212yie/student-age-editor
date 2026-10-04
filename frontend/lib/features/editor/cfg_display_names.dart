// 配置表显示名注册表（单一来源）。
//
// 经典布局（frontend/lib/features/pages/classic_page_layouts.dart）此前在各下拉框
// 里内联维护「中文名 (CfgName)」式名称，创作布局 / 剧情图布局却只显示裸 CfgName，
// 同名配置表在不同布局下叫法不一致。此文件把经典布局的名称收敛为唯一来源，
// 供所有布局的配置表选择器与编辑器标题复用，避免各处各写一份、名称漂移。
library;

/// 配置表 → 中文名（不含 `CfgName` 后缀）。
///
/// 经典布局已收录的以经典布局的现有叫法为准（如 `KZoneContentCfg` = 「空间动态配置」）；
/// 其余配置表按页面目录（pages_catalog.dart）补齐，便于所有布局统一显示。
const kCfgLabels = <String, String>{
  // 故事
  'TalkCfg': '对话',
  'OptionCfg': '对话选项',
  'EvtCfg': '事件',
  'EvtTypeCfg': '事件类型',
  'BgCfg': '背景图',
  // 人物
  'PersonCfg': '人物属性',
  'PersonGrowCfg': '成长曲线',
  'PersonAttrCfg': '基础属性',
  'PersonStateCfg': '人物状态',
  'TraitsCfg': '特质设定',
  'ModFaceCfg': '自定义表情',
  // 事件
  'ActionEvtCfg': '行动事件',
  'InteractCfg': '闲聊',
  // 社交与结局
  'KZoneContentCfg': '空间动态配置',
  'KZoneCommentCfg': '空间评论',
  'KZoneProfileCfg': '空间个人档',
  'KZoneAvatarCfg': '空间头像配置',
  'PhoneMsgCfg': '手机短信配置',
  'EndingPartCfg': '结局部件配置',
  'EndingOptionCfg': '结局选项配置',
  'RenshengguanMemoryCfg': '珍贵记忆',
  'FriendRequestCfg': '帮助同学',
  // 礼物
  'GiftEvtCfg': '送礼事件',
  'ItemCfg': '物品',
  'PaperCfg': '纸条',
  // 恋爱
  'BadmintonModelCfg': '羽毛球小游戏',
  'LoveVindicateRateCfg': '表白概率',
  'LoveBadmintonCfg': '羽毛球事件',
  'LoveRibbonCfg': '丝带玩法',
  'LoveDrawCfg': '抽奖玩法',
  'LoveBreakfastCfg': '早餐事件',
  'EndingDatingCfg': '相亲',
  // 功能
  'MinigameCfg': '小游戏',
  'MinigameActionCfg': '小游戏行动',
  'ActionCfg': '行动',
  'ActionTypeCfg': '行动类型',
  'JobCfg': '打工与社团',
  'JobUnlockCfg': '职业解锁',
  'ShopCfg': '商店',
  'BookCfg': '书籍',
  'MovieCfg': '影视',
  'TVCfg': '电视',
  'IntentCfg': '目标',
  'ToggleCfg': '开关',
  'TextCfg': '全局文本',
  'ExploreCfg': '探索',
  // 新闻
  'NewsCfg': '新闻',
  'NewsCommentCfg': '新闻评论',
  'NewsTypeCfg': '新闻分类',
  // 钓鱼
  'FishCfg': '鱼类',
  'FishBaitCfg': '鱼饵',
  'FishTypeCfg': '鱼类等级',
  'FishDiffCfg': '钓鱼手感',
  // 旅游
  'TripSpotCfg': '旅游景点',
  'TripTypeCfg': '景点类型',
  'TripLevelCfg': '旅游等级',
  'TripEffectCfg': '旅游奖励',
  // 看番与漫展
  'AnimationCfg': '番剧',
  'AnimeConCfg': '漫展活动',
  'AnimationTypeCfg': '番剧类型',
  'AnimationWifeCfg': '本命角色',
  'AnimationRankCfg': '追番等级',
  'AnimationCostCfg': '搜番消耗',
  'AnimeConExpCfg': '漫展等级',
  'AnimeKzoneContentCfg': '追番动态',
  'AnimeMarkCntCfg': '追番标记',
  'TalkAnimeCfg': '聊番话题',
  // 世博会
  'ExpoSiteCfg': '世博展馆',
  'ExpoAttrCfg': '世博积分',
  'ExpoEvtCfg': '世博事件',
  // 侦探社
  'ClubActivityCfg': '社团活动',
  'ClubMemberCfg': '社团成员',
  'ClubDepartmentCfg': '社团部门',
  'ClubDailyCfg': '社团日常',
  'ClueRumorCfg': '线索与传闻',
  'ClubMemeberCntCfg': '社团人数',
  'ClubFundsCfg': '社团经费',
  // 手工
  'DIYCfg': '手工作品',
  'DIYRankCfg': '手工评级',
  'HandicraftMiniGameCfg': '手工拼装',
  // 生日派对
  'BirthdayPaintCfg': '生日猜画',
  'LineMatchMinigameCfg': '生日连线',
  'BirthdayPaintGuessCfg': '猜画人物反应',
  'BirthdayRewardCfg': '生日奖励',
  'BirthdayLvCfg': '派对等级',
  'BirthdayScoreCfg': '派对加分',
  // 辩论交涉
  'NegotiationPlayerCfg': '辩论对手',
  'NegotiationTeamCfg': '交涉队伍',
  'NegotiationTeammateCfg': '可招募队友',
  'NegotiationTopicCfg': '辩论话题',
  'NegotiationCfg': '交涉行动',
  'NegotiationTalkCfg': '交涉用语',
  'NegotiationChatCfg': '交涉闲聊',
  'NegotiationInvolvedCfg': '交涉投入',
  'NegotiationMiniGameCardCfg': '普通牌组',
  'NegotiationUniqueCardCfg': '特殊卡牌',
  'NegotiationMiniGameCardTypeCfg': '牌型与克制',
  'NegotiationSkillCfg': '交涉技能',
  'NegotiationBuffCfg': '交涉状态',
  'NegotiationMiniGameCfg': '对局规则',
  'MomPowerCfg': '妈妈的牌组',
  // 资源
  'AudioCfg': '音频',
  'CGCfg': 'CG相册',
  // 官方工具
  'ManifestCfg': '模组清单',
};

/// 配置表的中文名；未收录时回退裸 `CfgName`。
String cfgLabel(String cfg) {
  final label = kCfgLabels[cfg];
  return (label == null || label.isEmpty) ? cfg : label;
}

/// 配置表显示名：`中文名 (CfgName)`；未收录时回退裸 `CfgName`。
///
/// 与经典布局下拉框原有的文案格式保持一致。
String cfgDisplayName(String cfg) {
  final label = kCfgLabels[cfg];
  return (label == null || label.isEmpty) ? cfg : '$label ($cfg)';
}
