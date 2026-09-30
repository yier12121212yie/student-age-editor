/// 内置 AI 工具定义（细分领域读写 + 舞台调度 + 生图 + 提问）。
///
/// 从 ai_panel.dart 的 `_tools` getter 拆出：原来每次访问都重建整个
/// List（16 个对象 + 百行字符串），现为编译期常量，零分配。
/// 注意：`update_domain_item`/`create_domain_item` 的参数描述与
/// ai_prompts.dart 系统提示词中的说话人规则互为补充，改动需同步。
library;

import 'ai_client.dart';

/// 插件声明的 AI 工具：OpenAI function 格式（name/description/parameters），
/// 附带 confirm 标记（true 时执行前需用户确认）。
class PluginAiTool extends AiToolDef {
  const PluginAiTool({
    required super.name,
    required super.description,
    super.parameters,
    this.confirm = false,
  });

  final bool confirm;
}

/// 细分领域工具集：AI 以「领域 + 条目」粒度读写模组内容，
/// 不再直接整文件覆盖（领域见 list_domains，写操作需用户确认）。
const List<AiToolDef> kBuiltinTools = [
  AiToolDef(
    name: 'list_domains',
    description: '修改 mod 的第一步：列出所有可修改的创作领域（剧情、背景、人物、社交、恋爱等）及各领域包含的配置表。其他领域工具的参数 domain 从这里取值，用户要求改内容时先调用它',
    parameters: {'type': 'object', 'properties': {}},
  ),
  AiToolDef(
    name: 'get_game_dicts',
    description: '查询游戏内置字典（角色/物品/地点/职业/属性/关系/背景/回合/事件类型/羽毛球模型等）的 id→名称对照。填写 role/npc/item/mapId/type 等 ID 字段前，先用它核对名称避免填错 ID。name 为空时列出可用字典；q 为关键词（匹配 id 或名称，可留空）',
    parameters: {
      'type': 'object',
      'properties': {
        'name': {
          'type': 'string',
          'description': '字典 id，如 roles/items/maps/jobs/attrs/relations/bgs/turns/evt_types/badminton_models；留空列出全部',
        },
        'q': {'type': 'string', 'description': '关键词，可选，如角色名'},
        'limit': {'type': 'integer', 'description': '返回条数上限，默认 30 最大 100'},
      },
    },
  ),
  AiToolDef(
    name: 'list_domain_items',
    description: '列出某领域下的条目（如剧情领域列出所有事件/对话/选项）。domain 见 list_domains；q 为关键词（匹配 id/名称/内容，可留空）；table 可限定单表；limit 默认 50 最大 200',
    parameters: {
      'type': 'object',
      'required': ['domain'],
      'properties': {
        'domain': {
          'type': 'string',
          'description': '领域 id（先调 list_domains 获取，如 story=剧情、background=背景）',
        },
        'q': {'type': 'string', 'description': '关键词，可选'},
        'table': {'type': 'string', 'description': '限定单表名（如 EvtCfg），可选'},
        'limit': {'type': 'integer', 'description': '返回条数上限，可选'},
      },
    },
  ),
  AiToolDef(
    name: 'get_domain_item',
    description: '读取某领域单个条目的完整内容（含全部字段）。修改前务必先读取，确认理解后再改',
    parameters: {
      'type': 'object',
      'required': ['domain', 'cfg', 'id'],
      'properties': {
        'domain': {'type': 'string', 'description': '领域 id（见 list_domains）'},
        'cfg': {
          'type': 'string',
          'description': '配置表名，如 EvtCfg/TalkCfg/BgCfg/PersonCfg',
        },
        'id': {'type': 'string', 'description': '条目 id（来自 list_domain_items）'},
      },
    },
  ),
  AiToolDef(
    name: 'update_domain_item',
    description: '修改某领域条目的字段（patch 为要改的字段集合，只改给出的字段，其余保持不动）。会先展示改动并等待用户确认',
    parameters: {
      'type': 'object',
      'required': ['domain', 'cfg', 'id', 'patch'],
      'properties': {
        'domain': {'type': 'string', 'description': '领域 id（见 list_domains）'},
        'cfg': {'type': 'string', 'description': '配置表名'},
        'id': {'type': 'string', 'description': '条目 id'},
        'patch': {
          'type': 'object',
          'description': '要修改的字段，如 {"title": "新标题"}；修改对白（TalkCfg）的说话人时 roleIds（说话人群组）必填、短信/动态（PhoneMsgCfg/KZoneContentCfg）的 role（发送者）必填，roleName 只是可选显示名，不能替代 roleIds',
        },
      },
    },
  ),
  AiToolDef(
    name: 'create_domain_item',
    description: '在某领域配置表新建条目。data 需包含 id 及至少一个字段；id 与现有条目重复会失败',
    parameters: {
      'type': 'object',
      'required': ['domain', 'cfg', 'data'],
      'properties': {
        'domain': {'type': 'string', 'description': '领域 id（见 list_domains）'},
        'cfg': {'type': 'string', 'description': '配置表名'},
        'data': {
          'type': 'object',
          'description': '新条目内容，如 {"id": 101, "name": "新角色"}；创建对白（TalkCfg）时 roleIds（说话人群组）必填、短信/动态（PhoneMsgCfg/KZoneContentCfg）的 role（发送者）必填，roleName 只是可选显示名，不能替代 roleIds',
        },
      },
    },
  ),
  AiToolDef(
    name: 'delete_domain_item',
    description: '删除某领域配置表的条目（不可恢复，需用户确认）',
    parameters: {
      'type': 'object',
      'required': ['domain', 'cfg', 'id'],
      'properties': {
        'domain': {'type': 'string', 'description': '领域 id（见 list_domains）'},
        'cfg': {'type': 'string', 'description': '配置表名'},
        'id': {'type': 'string', 'description': '条目 id'},
      },
    },
  ),
  AiToolDef(
    name: 'list_files',
    description:
        '列出模组或工作区目录下的文件（只读探索用；scope: mod=当前模组, workspace=工作区；path 为相对路径，空为根目录）',
    parameters: {
      'type': 'object',
      'properties': {
        'path': {'type': 'string', 'description': '相对路径，默认根目录'},
        'scope': {
          'type': 'string',
          'enum': ['mod', 'workspace'],
          'description': 'mod=当前模组目录, workspace=工作区',
        },
      },
    },
  ),
  AiToolDef(
    name: 'read_file',
    description:
        '读取模组文件内容（只读探索用，修改内容请使用领域工具 update_domain_item）。path 为相对模组根目录的路径',
    parameters: {
      'type': 'object',
      'required': ['path'],
      'properties': {
        'path': {'type': 'string'},
      },
    },
  ),
  AiToolDef(
    name: 'list_mods',
    description: '列出所有可用模组',
    parameters: {'type': 'object', 'properties': {}},
  ),
  AiToolDef(
    name: 'get_stage_dicts',
    description: '查询剧情对白的「舞台调度」字典：人物表情（0-26）、人物动作/入场退场/移动类型、站位（左/中/右）、角色列表。修改人物站位、移动、入场退场、表情、动作前先调用它核对名称与ID',
    parameters: {'type': 'object', 'properties': {}},
  ),
  AiToolDef(
    name: 'get_talk_stage',
    description: '读取某条对白（TalkCfg 条目）当前的人物舞台安排（站位/移动/入场退场/表情/动作），返回中文描述。修改舞台前先调用，确认理解当前状态',
    parameters: {
      'type': 'object',
      'required': ['talk_id'],
      'properties': {
        'talk_id': {
          'type': 'string',
          'description': '对白ID（TalkCfg 条目 id，来自 list_domain_items）',
        },
      },
    },
  ),
  AiToolDef(
    name: 'set_talk_stage',
    description: '修改某条对白的人物舞台：人物站位（入场到左/中/右）、移动、入场退场、人物表情、人物动作。commands 为语义化指令数组，每条含 action（入场/退场/移动/表情/动作/屏幕特效），role 用角色名或ID，其余按动作类型补参数。示例：[{"action":"入场","role":"薛诗蕾","mode":"滑动","pos":"左"},{"action":"表情","role":"102","expr":"开心"},{"action":"移动","role":"102","value":-80},{"action":"退场","role":"102","mode":"滑动"},{"action":"动作","role":"102","type":"转身"},{"action":"屏幕特效","type":"屏幕抖动","value":2}]。clear 为 true 时先清空该对白原有舞台指令，默认保留并追加。写前先 get_talk_stage 查看当前安排、get_stage_dicts 核对动作/表情/站位名称；修改会先展示改动并等待用户确认',
    parameters: {
      'type': 'object',
      'required': ['talk_id', 'commands'],
      'properties': {
        'talk_id': {'type': 'string', 'description': '对白ID（TalkCfg 条目）'},
        'commands': {
          'type': 'array',
          'description': '舞台指令数组，每项为对象，字段见 description 示例（action/role/mode/pos/expr/type/value/axis）',
        },
        'clear': {'type': 'boolean', 'description': '是否先清空原有舞台指令，默认 false'},
      },
    },
  ),
  AiToolDef(
    name: 'generate_image',
    description: '用 OpenAI Images API 生成新图片（遵循 openai-image-api 标准，调用 /images/generations）。生成前会弹出审批框等待用户确认；生成结果自动保存到当前模组的 Art/ai/ 目录，返回保存路径，之后可用 update_domain_item 把路径写入配置表（如 BgCfg 的 url 字段）。一次可生成多张（n 最大 10，dall-e-3 通常仅支持 n=1）。用户要求「画一张/生成图片/做一张背景」时调用它',
    parameters: {
      'type': 'object',
      'required': ['prompt'],
      'properties': {
        'prompt': {
          'type': 'string',
          'description': '图片内容描述（英文效果更佳），可包含风格、构图、氛围等要求',
        },
        'n': {'type': 'integer', 'description': '一次生成的图片数量，1-10，默认 1'},
        'size': {
          'type': 'string',
          'description': '尺寸，如 1024x1024（默认）；gpt-image 系列支持任意「宽x高」（宽高为 64 的整数倍、不超过 8192，如 2048x2048）或 auto；dall-e 系列限 256x256/512x512/1024x1024/1024x1792/1792x1024',
        },
        'quality': {
          'type': 'string',
          'description': '质量，可选 auto/high/medium/low（gpt-image 系列支持）',
        },
        'style': {
          'type': 'string',
          'description': '风格，可选 vivid（生动）/natural（自然），dall-e-3 支持',
        },
        'background': {
          'type': 'string',
          'description': '背景，可选 transparent（透明）/opaque（不透明），gpt-image 系列支持',
        },
        'model': {
          'type': 'string',
          'description': '图片模型，可选，默认使用设置中的图片模型（gpt-image-2）',
        },
      },
    },
  ),
  AiToolDef(
    name: 'edit_image',
    description: '用 OpenAI Images API 修改已有图片（遵循 openai-image-api 标准，调用 /images/edits）。image 为当前模组内图片相对路径（可用 list_files 查找，如 Art/ai/xxx.png）；生成前会弹出审批框等待用户确认；结果自动保存到当前模组的 Art/ai/ 目录。用户要求「把某张图改成…」时调用它',
    parameters: {
      'type': 'object',
      'required': ['image', 'prompt'],
      'properties': {
        'image': {'type': 'string', 'description': '要修改的图片在模组内的相对路径（PNG 最佳）'},
        'prompt': {'type': 'string', 'description': '修改指令，描述希望图片发生什么变化'},
        'mask': {
          'type': 'string',
          'description': '可选，蒙版图片相对路径（PNG，白色区域为可修改区域）',
        },
        'n': {'type': 'integer', 'description': '一次生成的图片数量，1-10，默认 1'},
        'size': {'type': 'string', 'description': '尺寸，可选 1024x1024（默认）等'},
        'model': {'type': 'string', 'description': '图片模型，可选，默认使用设置中的图片模型'},
      },
    },
  ),
  AiToolDef(
    name: 'ask_user',
    description: '向用户提问并等待回答。当任务信息不足、或存在多种合理做法需要用户决策时使用；不要用它闲聊或问已知道的信息。',
    parameters: {
      'type': 'object',
      'required': ['question'],
      'properties': {
        'question': {'type': 'string', 'description': '要问用户的问题，一句话说清楚'},
        'options': {
          'type': 'array',
          'items': {'type': 'string'},
          'description': '可选：给用户的候选项（2-4 个）；不给则用户自由输入',
        },
      },
    },
  ),
];
