/// 剧情图内置节点预设库：「添加节点」菜单的扩充项。
///
/// 引擎只认 TalkCfg/OptionCfg 的字段，因此每个预设本质是把演出语义
/// 编译进现有字段（screenEffect / nextEvtId / check / time / miniGame…），
/// 并用与插件流程卡片一致的 match 规则着色/命名（见 story_flow_models.dart
/// applyCardStyle），与 /api/plugins/ui/flow_cards 的插件卡共存（插件优先）。
library;

/// 屏幕效果码 → 中文名（SCREEN_EFFECT_DB 常用子集，节点参数摘要用）。
const Map<int, String> kScreenEffectNames = {
  4001: '抖动',
  4002: '模糊',
  4003: '还原',
  4006: '黑屏',
  4007: '电话',
  4009: '做旧',
  4010: '反色',
  4011: '闭眼',
  4012: '闪白',
  4015: '播CG',
  4017: '停CG',
};

/// CG 播放/结束指令码（screenEffect 行首值）。
const int kFxPlayCg = 4015;
const int kFxStopCg = 4017;

/// 内置节点预设（typeId 唯一，卡型着色 + 新建时预置字段）。
class FlowNodePreset {
  const FlowNodePreset({
    required this.typeId,
    required this.name,
    required this.appliesTo,
    required this.category,
    this.color = '',
    this.match,
    this.initial = const {},
    this.description = '',
  });

  final String typeId;
  final String name;

  /// 载体记录类型：'talk' | 'option'（与插件卡协议一致）。
  final String appliesTo;

  /// 菜单分组：'演出' | '分支' | '玩法'。
  final String category;

  /// 卡型颜色 #RRGGBB；空=不着色（纯文案模板，避免大面积改色）。
  final String color;

  /// 卡型匹配谓词（{field, equals|code/codes|nonEmpty}）；null=不着色。
  final Map<String, dynamic>? match;

  /// 新建节点时整体合并进记录的预置字段。
  final Map<String, dynamic> initial;
  final String description;

  /// 转成与 flow_cards 响应一致的 Map 形状（buildFlowGraph/菜单共用）。
  Map<String, dynamic> toCardSpec() => {
    'type_id': typeId,
    'name': name,
    'applies_to': appliesTo,
    'color': color,
    'builtin': true,
    'category': category,
    if (match != null) 'match': match,
    if (initial.isNotEmpty) 'initial': initial,
    if (description.isNotEmpty) 'description': description,
  };
}

/// 全部内置预设（按菜单分组顺序排列）。
final List<FlowNodePreset> kFlowNodePresets = [
  // ---------- 视听演出 ----------
  FlowNodePreset(
    typeId: 'cg_play',
    name: '播放CG',
    appliesTo: 'talk',
    category: '演出',
    color: '#E91E63',
    match: const {'field': 'screenEffect', 'code': kFxPlayCg},
    initial: const {
      'roleName': '旁白',
      'content': '【播放CG：在本节点 screenEffect 填 CG id → [4015, id]】',
      'screenEffect': [kFxPlayCg, 0],
    },
    description: '全屏演出图；参数为 CGCfg 条目 id，可拖相册 CG 快速填充',
  ),
  FlowNodePreset(
    typeId: 'cg_end',
    name: '结束CG',
    appliesTo: 'talk',
    category: '演出',
    color: '#AD1457',
    match: const {'field': 'screenEffect', 'code': kFxStopCg},
    initial: const {
      'roleName': '旁白',
      'content': '【结束CG】',
      'screenEffect': [kFxStopCg],
    },
  ),
  FlowNodePreset(
    typeId: 'transition',
    name: '转场特效',
    appliesTo: 'talk',
    category: '演出',
    color: '#607D8B',
    match: const {
      'field': 'screenEffect',
      'codes': [4001, 4002, 4003, 4006, 4009, 4010, 4011, 4012],
    },
    initial: const {
      'roleName': '旁白',
      'content': '【转场：黑屏】',
      'screenEffect': [4006],
    },
    description: '黑屏/闪白/抖动/模糊/反色/做旧等屏幕效果',
  ),
  const FlowNodePreset(
    typeId: 'bg_set',
    name: '切换背景',
    appliesTo: 'talk',
    category: '演出',
    initial: {'roleName': '旁白', 'content': '【切换背景：把 CG 图片拖到本节点】'},
    description: '不单独着色：填 bg 后即带背景徽标的旁白白',
  ),
  const FlowNodePreset(
    typeId: 'music_set',
    name: '切换音乐',
    appliesTo: 'talk',
    category: '演出',
    initial: {'roleName': '旁白', 'content': '【切换音乐：把音频拖到本节点】'},
  ),
  // ---------- 分支逻辑 ----------
  FlowNodePreset(
    typeId: 'talk_check',
    name: '检定',
    appliesTo: 'talk',
    category: '分支',
    color: '#E67E22',
    match: const {'field': 'check', 'nonEmpty': true},
    initial: const {'roleName': '旁白', 'content': '【技能检定：展开节点填 check，出成功/失败双支】'},
    description: 'check 非空后端口自动变为 成功/失败 双支',
  ),
  const FlowNodePreset(
    typeId: 'evt_goto',
    name: '事件跳转',
    appliesTo: 'option',
    category: '分支',
    color: '#00897B',
    match: {'field': 'nextEvtId', 'nonEmpty': true},
    initial: {'content': '【跳转到事件：填 nextEvtId】'},
    description: '选中该对白后添加；连线终端即跨事件跳转',
  ),
  const FlowNodePreset(
    typeId: 'cond_opt',
    name: '条件选项',
    appliesTo: 'option',
    category: '分支',
    color: '#7E57C2',
    match: {'field': 'precondition', 'nonEmpty': true},
    initial: {'content': '【条件选项：填 precondition】'},
    description: '仅在条件满足时出现的选项',
  ),
  // ---------- 玩法与其他 ----------
  const FlowNodePreset(
    typeId: 'mini_game',
    name: '小游戏',
    appliesTo: 'talk',
    category: '玩法',
    color: '#0288D1',
    match: {'field': 'miniGame', 'nonEmpty': true},
    initial: {'roleName': '旁白', 'content': '【小游戏：填 miniGame 指令】'},
  ),
  const FlowNodePreset(
    typeId: 'time_pass',
    name: '时间流逝',
    appliesTo: 'talk',
    category: '玩法',
    color: '#F9A825',
    match: {'field': 'time', 'nonEmpty': true},
    initial: {'roleName': '旁白', 'content': '【时间流逝】', 'time': 60},
  ),
];

/// 预设库 → flow_cards 同形状列表（追加在插件卡之后，插件优先）。
List<Map<String, dynamic>> builtinFlowCardSpecs() => [
  for (final p in kFlowNodePresets) p.toCardSpec(),
];
