/// 编辑页面的目录定义（对应原 PyQt 版 editor/ui/pages/*）。
///
/// 表清单对齐友商功能面：每页 cfgNames 里的表名必须在
/// `native/assets/schema.json` 有定义，否则编辑器只能按数据扫键渲染
/// （由 test/pages_catalog_coverage_test.dart 断言）。
class EditorPageDef {
  const EditorPageDef({
    required this.id,
    required this.title,
    required this.description,
    required this.cfgNames,
    this.primaryCfg,
  });
  final String id;
  final String title;
  final String description;
  final List<String> cfgNames;
  final String? primaryCfg;

  String get defaultCfg => primaryCfg ?? (cfgNames.isNotEmpty ? cfgNames.first : '');
}

const editorPages = <EditorPageDef>[
  EditorPageDef(
    id: 'story',
    title: '故事',
    description: '剧情编排：TalkCfg 对白 / OptionCfg 选项 / EvtCfg 事件绑定',
    cfgNames: ['TalkCfg', 'OptionCfg', 'EvtCfg', 'EvtTypeCfg', 'BgCfg', 'CGCfg'],
    primaryCfg: 'TalkCfg',
  ),
  EditorPageDef(
    id: 'person',
    title: '人物',
    description: '角色与成长：PersonCfg 人物 / PersonGrowCfg 成长曲线',
    cfgNames: ['PersonCfg', 'PersonGrowCfg', 'PersonAttrCfg', 'PersonStateCfg', 'TraitsCfg', 'ModFaceCfg'],
    primaryCfg: 'PersonCfg',
  ),
  EditorPageDef(
    id: 'evt',
    title: '事件',
    description: '事件系统：EvtCfg 事件定义与触发条件 / InteractCfg 人物闲聊',
    cfgNames: ['EvtCfg', 'EvtTypeCfg', 'ActionEvtCfg', 'InteractCfg'],
    primaryCfg: 'EvtCfg',
  ),
  EditorPageDef(
    id: 'social',
    title: '社交',
    description: '朋友圈、短信与结局：动态 / 头像 / 珍贵记忆 / 帮助同学',
    cfgNames: [
      'KZoneContentCfg',
      'KZoneCommentCfg',
      'KZoneProfileCfg',
      'KZoneAvatarCfg',
      'PhoneMsgCfg',
      'EndingPartCfg',
      'EndingOptionCfg',
      'RenshengguanMemoryCfg',
      'FriendRequestCfg',
    ],
    primaryCfg: 'KZoneContentCfg',
  ),
  EditorPageDef(
    id: 'gift',
    title: '礼物',
    description: '礼物系统：GiftEvtCfg 送礼事件 / ItemCfg 物品 / PaperCfg 纸条',
    cfgNames: ['GiftEvtCfg', 'ItemCfg', 'PaperCfg'],
    primaryCfg: 'GiftEvtCfg',
  ),
  EditorPageDef(
    id: 'love',
    title: '恋爱',
    description: '恋爱玩法：BadmintonModelCfg 羽毛球等小游戏 / EndingDatingCfg 相亲',
    cfgNames: ['BadmintonModelCfg', 'LoveVindicateRateCfg', 'LoveBadmintonCfg', 'LoveRibbonCfg', 'LoveDrawCfg', 'LoveBreakfastCfg', 'EndingDatingCfg'],
    primaryCfg: 'BadmintonModelCfg',
  ),
  EditorPageDef(
    id: 'function',
    title: '功能',
    description: '玩法功能：小游戏 / 行动 / 打工 / 目标 / 开关 / 全局文本 / 探索',
    cfgNames: [
      'MinigameCfg',
      'MinigameActionCfg',
      'ActionCfg',
      'ActionTypeCfg',
      'JobCfg',
      'JobUnlockCfg',
      'ShopCfg',
      'BookCfg',
      'MovieCfg',
      'TVCfg',
      'IntentCfg',
      'ToggleCfg',
      'TextCfg',
      'ExploreCfg',
    ],
    primaryCfg: 'MinigameCfg',
  ),
  EditorPageDef(
    id: 'news',
    title: '新闻',
    description: '新闻与评论：NewsCfg 正文配图 / NewsCommentCfg 读者评论 / NewsTypeCfg 栏目',
    cfgNames: ['NewsCfg', 'NewsCommentCfg', 'NewsTypeCfg'],
    primaryCfg: 'NewsCfg',
  ),
  EditorPageDef(
    id: 'fishing',
    title: '钓鱼',
    description: '钓鱼玩法：FishCfg 鱼类 / FishBaitCfg 鱼饵 / FishTypeCfg 鱼种 / FishDiffCfg 手感',
    cfgNames: ['FishCfg', 'FishBaitCfg', 'FishTypeCfg', 'FishDiffCfg'],
    primaryCfg: 'FishCfg',
  ),
  EditorPageDef(
    id: 'travel',
    title: '旅游',
    description: '旅游玩法：TripSpotCfg 景点 / TripTypeCfg 类型 / TripLevelCfg 成长 / TripEffectCfg 效果',
    cfgNames: ['TripSpotCfg', 'TripTypeCfg', 'TripLevelCfg', 'TripEffectCfg'],
    primaryCfg: 'TripSpotCfg',
  ),
  EditorPageDef(
    id: 'anime',
    title: '看番与漫展',
    description: '追番成长：番剧 / 本命 / 漫展活动 / 追番动态',
    cfgNames: [
      'AnimationCfg',
      'AnimeConCfg',
      'AnimationTypeCfg',
      'AnimationWifeCfg',
      'AnimationRankCfg',
      'AnimationCostCfg',
      'AnimeConExpCfg',
      'AnimeKzoneContentCfg',
      'AnimeMarkCntCfg',
      'TalkAnimeCfg',
    ],
    primaryCfg: 'AnimationCfg',
  ),
  EditorPageDef(
    id: 'expo',
    title: '世博会',
    description: '世博会：ExpoSiteCfg 展馆 / ExpoAttrCfg 积分属性 / ExpoEvtCfg 游览事件',
    cfgNames: ['ExpoSiteCfg', 'ExpoAttrCfg', 'ExpoEvtCfg'],
    primaryCfg: 'ExpoSiteCfg',
  ),
  EditorPageDef(
    id: 'club',
    title: '侦探社',
    description: '侦探社：活动 / 成员 / 部门 / 日常 / 线索 / 经费',
    cfgNames: [
      'ClubActivityCfg',
      'ClubMemberCfg',
      'ClubDepartmentCfg',
      'ClubDailyCfg',
      'ClueRumorCfg',
      'ClubMemeberCntCfg',
      'ClubFundsCfg',
    ],
    primaryCfg: 'ClubActivityCfg',
  ),
  EditorPageDef(
    id: 'crafts',
    title: '手工',
    description: '手工玩法：DIYCfg 作品 / DIYRankCfg 评级 / HandicraftMiniGameCfg 拼装',
    cfgNames: ['DIYCfg', 'DIYRankCfg', 'HandicraftMiniGameCfg'],
    primaryCfg: 'DIYCfg',
  ),
  EditorPageDef(
    id: 'birthday',
    title: '生日派对',
    description: '生日派对：猜画 / 连线小游戏 / 奖励与等级',
    cfgNames: [
      'BirthdayPaintCfg',
      'LineMatchMinigameCfg',
      'BirthdayPaintGuessCfg',
      'BirthdayRewardCfg',
      'BirthdayLvCfg',
      'BirthdayScoreCfg',
    ],
    primaryCfg: 'BirthdayPaintCfg',
  ),
  EditorPageDef(
    id: 'negotiation',
    title: '辩论交涉',
    description: '辩论与交涉：对手 / 队伍 / 话题 / 交涉牌组 / 技能与状态',
    cfgNames: [
      'NegotiationPlayerCfg',
      'NegotiationTeamCfg',
      'NegotiationTeammateCfg',
      'NegotiationTopicCfg',
      'NegotiationCfg',
      'NegotiationTalkCfg',
      'NegotiationChatCfg',
      'NegotiationInvolvedCfg',
      'NegotiationMiniGameCardCfg',
      'NegotiationUniqueCardCfg',
      'NegotiationMiniGameCardTypeCfg',
      'NegotiationSkillCfg',
      'NegotiationBuffCfg',
      'NegotiationMiniGameCfg',
      'MomPowerCfg',
    ],
    primaryCfg: 'NegotiationPlayerCfg',
  ),
  EditorPageDef(
    id: 'resource',
    title: '资源',
    description: '资源管理：贴图 / 音频 / 文本的索引与导出（见左侧「资源」面板）',
    cfgNames: ['AudioCfg', 'CGCfg'],
    primaryCfg: 'AudioCfg',
  ),
  EditorPageDef(
    id: 'official',
    title: '官方工具',
    description: '官方模组工具：manifest 校验与创意工坊发布（配套 Python 核心引擎）',
    cfgNames: ['ManifestCfg'],
    primaryCfg: 'ManifestCfg',
  ),
];

EditorPageDef? pageById(String id) {
  for (final p in editorPages) {
    if (p.id == id) return p;
  }
  return null;
}
