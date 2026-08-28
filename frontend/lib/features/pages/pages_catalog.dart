/// 9 个编辑页面的目录定义（对应原 PyQt 版 editor/ui/pages/*）。
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
    cfgNames: ['PersonCfg', 'PersonGrowCfg', 'PersonAttrCfg', 'PersonStateCfg', 'TraitsCfg'],
    primaryCfg: 'PersonCfg',
  ),
  EditorPageDef(
    id: 'evt',
    title: '事件',
    description: '事件系统：EvtCfg 事件定义与触发条件',
    cfgNames: ['EvtCfg', 'EvtTypeCfg', 'ActionEvtCfg'],
    primaryCfg: 'EvtCfg',
  ),
  EditorPageDef(
    id: 'social',
    title: '社交',
    description: '朋友圈与短信：KZoneContentCfg 动态 / PhoneMsgCfg 短信 / 结局选项',
    cfgNames: ['KZoneContentCfg', 'KZoneCommentCfg', 'KZoneProfileCfg', 'PhoneMsgCfg', 'EndingPartCfg', 'EndingOptionCfg'],
    primaryCfg: 'KZoneContentCfg',
  ),
  EditorPageDef(
    id: 'gift',
    title: '礼物',
    description: '礼物系统：GiftEvtCfg 送礼事件 / ItemCfg 物品',
    cfgNames: ['GiftEvtCfg', 'ItemCfg'],
    primaryCfg: 'GiftEvtCfg',
  ),
  EditorPageDef(
    id: 'love',
    title: '恋爱',
    description: '恋爱玩法：BadmintonModelCfg 羽毛球等小游戏配置',
    cfgNames: ['BadmintonModelCfg', 'LoveVindicateRateCfg', 'LoveBadmintonCfg', 'LoveRibbonCfg', 'LoveDrawCfg', 'LoveBreakfastCfg'],
    primaryCfg: 'BadmintonModelCfg',
  ),
  EditorPageDef(
    id: 'function',
    title: '功能',
    description: '玩法功能：MinigameCfg 小游戏 / ActionCfg 行动 / 打工与社团',
    cfgNames: ['MinigameCfg', 'MinigameActionCfg', 'ActionCfg', 'ActionTypeCfg', 'JobCfg', 'ShopCfg', 'BookCfg', 'MovieCfg', 'TvCfg'],
    primaryCfg: 'MinigameCfg',
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
