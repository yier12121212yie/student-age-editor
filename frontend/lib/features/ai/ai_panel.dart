import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter/services.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/api_client.dart';
import '../../core/models.dart';
import '../settings/settings_page.dart';
import 'ai_client.dart';
import '../../core/app_theme.dart';

/// 插件声明的 AI 工具：OpenAI function 格式（name/description/parameters），
/// 附带 confirm 标记（true 时执行前需用户确认）。
class _PluginAiTool extends AiToolDef {
  _PluginAiTool({
    required super.name,
    required super.description,
    super.parameters,
    this.confirm = false,
  });

  final bool confirm;
}

/// 上传的附件（docx/txt/md/xlsx → 文本；png/jpg → 图片）。
/// 文本内容与图片 base64 仅保留在内存（发送时使用），
/// 消息持久化时只保存元数据（名称/类型/大小），避免撑爆本地配置。
class AiAttachment {
  AiAttachment({
    required this.name,
    required this.kind,
    this.size = 0,
    this.text,
    this.mime,
    this.dataB64,
  });
  final String name;
  final String kind; // text | image
  final int size;
  final String? text; // kind==text：解析出的文本内容
  final String? mime; // kind==image：如 image/png
  final String? dataB64; // kind==image：base64 数据

  Map<String, dynamic> toMetaJson() => {'name': name, 'kind': kind, 'size': size};

  static AiAttachment fromMetaJson(Map<String, dynamic> j) => AiAttachment(
        name: j['name'] as String? ?? '',
        kind: j['kind'] as String? ?? 'text',
        size: (j['size'] as num?)?.toInt() ?? 0,
      );

  static String fmtSize(int bytes) {
    if (bytes >= 1048576) return '${(bytes / 1048576).toStringAsFixed(1)}MB';
    if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(1)}KB';
    return '$bytes B';
  }
}

/// 聊天消息。
class AiChatMessage {
  AiChatMessage(
      {required this.role,
      this.text = '',
      List<ToolRecord>? toolRecords,
      List<String>? toolRoundTexts,
      List<AiAttachment>? attachments,
      this.error,
      DateTime? time})
      : toolRecords = toolRecords ?? [],
        toolRoundTexts = toolRoundTexts ?? [],
        attachments = attachments ?? [],
        time = time ?? DateTime.now();
  final String role; // user | assistant | system
  /// 最终回复文本（不含以工具调用结束的轮次过渡文本）。
  String text;
  List<ToolRecord> toolRecords;
  /// 以工具调用结束的轮次所输出的过渡文本（按轮次顺序）。
  /// 第 i 条对应 round == i+1 的工具记录；round == 0 的工具记录
  /// 没有前置过渡文本（该轮直接调工具，未输出文字）。
  List<String> toolRoundTexts;
  List<AiAttachment> attachments;
  String? error;
  final DateTime time;

  Map<String, dynamic> toJson() => {
        'role': role,
        'text': text,
        'time': time.millisecondsSinceEpoch,
        'tools': [for (final t in toolRecords) t.toJson()],
        'toolRoundTexts': toolRoundTexts,
        'attachments': [for (final a in attachments) a.toMetaJson()],
        if (error != null) 'error': error,
      };

  static AiChatMessage? fromJson(Map<String, dynamic> j) {
    final role = j['role'] as String?;
    if (role == null) return null;
    return AiChatMessage(
      role: role,
      text: j['text'] as String? ?? '',
      toolRecords: [
        for (final t in (j['tools'] as List? ?? []))
          if (t is Map) ToolRecord.fromJson(t.cast<String, dynamic>()),
      ],
      toolRoundTexts: [
        for (final t in (j['toolRoundTexts'] as List? ?? []))
          if (t is String) t,
      ],
      attachments: [
        for (final a in (j['attachments'] as List? ?? []))
          if (a is Map) AiAttachment.fromMetaJson(a.cast<String, dynamic>()),
      ],
      error: j['error'] as String?,
      time: DateTime.fromMillisecondsSinceEpoch(
          (j['time'] as num?)?.toInt() ?? DateTime.now().millisecondsSinceEpoch),
    );
  }
}

/// 一次工具调用记录。
class ToolRecord {
  ToolRecord(
      {required this.name,
      required this.arguments,
      this.result,
      this.approved = true,
      this.round = 0,
      List<String>? images})
      : images = images ?? [];
  final String name;
  final Map<String, dynamic> arguments;
  String? result;
  bool approved;
  /// 所属工具轮次：0 表示没有前置过渡文本；否则对应
  /// AiChatMessage.toolRoundTexts 中下标 round-1 的过渡文本。
  final int round;
  /// 生图/改图工具保存到模组内的图片相对路径（用于卡片缩略图预览）。
  final List<String> images;

  Map<String, dynamic> toJson() => {
        'name': name,
        'args': arguments,
        'result': result,
        'approved': approved,
        'round': round,
        if (images.isNotEmpty) 'images': images,
      };

  static ToolRecord fromJson(Map<String, dynamic> j) => ToolRecord(
        name: j['name'] as String? ?? '',
        arguments: (j['args'] as Map?)?.cast<String, dynamic>() ?? {},
        result: j['result'] as String?,
        approved: j['approved'] as bool? ?? true,
        round: (j['round'] as num?)?.toInt() ?? 0,
        images: [
          for (final p in (j['images'] as List? ?? []))
            if (p is String) p,
        ],
      );
}

/// 一个对话会话：完整消息列表 + 结构化历史 + 元信息。
/// 会话的 messages/history 与面板当前视图共享同一引用：
/// 切换会话时面板直接把当前视图绑定到目标会话的列表上。
class AiSession {
  AiSession({
    required this.id,
    String? title,
    DateTime? createdAt,
    DateTime? updatedAt,
    List<AiChatMessage>? messages,
    List<Map<String, dynamic>>? history,
  })  : title = title ?? '新对话',
        createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now(),
        messages = messages ?? [],
        history = history ?? [];

  final String id;
  String title;
  final DateTime createdAt;
  DateTime updatedAt;
  final List<AiChatMessage> messages;
  final List<Map<String, dynamic>> history;

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'createdAt': createdAt.millisecondsSinceEpoch,
        'updatedAt': updatedAt.millisecondsSinceEpoch,
        'messages': [for (final m in messages) m.toJson()],
        'history': history,
      };

  static AiSession? fromJson(Map<String, dynamic> j) {
    final id = j['id'] as String?;
    if (id == null) return null;
    final msgs = <AiChatMessage>[];
    for (final m in (j['messages'] as List? ?? [])) {
      if (m is Map) {
        final msg = AiChatMessage.fromJson(m.cast<String, dynamic>());
        if (msg != null) msgs.add(msg);
      }
    }
    return AiSession(
      id: id,
      title: j['title'] as String?,
      createdAt: DateTime.fromMillisecondsSinceEpoch(
          (j['createdAt'] as num?)?.toInt() ?? DateTime.now().millisecondsSinceEpoch),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(
          (j['updatedAt'] as num?)?.toInt() ?? DateTime.now().millisecondsSinceEpoch),
      messages: msgs,
      history: [
        for (final h in (j['history'] as List? ?? []))
          if (h is Map) h.cast<String, dynamic>(),
      ],
    );
  }
}

/// AI 侧栏（Cursor 风格聊天面板）。
class AiPanel extends StatefulWidget {
  const AiPanel({super.key, required this.state, required this.settings,
      required this.onChanged, this.onOpenSettings});
  final AppState state;
  final AiSettings settings;
  final ValueChanged<AiSettings> onChanged;
  final VoidCallback? onOpenSettings;
  @override
  State<AiPanel> createState() => AiPanelState();
}

class AiPanelState extends State<AiPanel> {
  /// 全部会话（含当前会话），按 updatedAt 排序后展示。
  final List<AiSession> _sessions = [];
  /// 当前活动会话；其 messages/history 与 _messages/_history 共享引用。
  AiSession? _active;
  /// 是否显示历史会话列表视图（覆盖聊天视图）。
  bool _showHistory = false;
  /// 当前活动会话的消息列表（始终等于 _active.messages）。
  List<AiChatMessage> _messages = [];
  /// 结构化消息历史（OpenAI 风格），由 AiClient 在工具轮次中追加，
  /// 跨轮次发送保留完整上下文；与 _messages 一起持久化。
  List<Map<String, dynamic>> _history = [];
  final TextEditingController _input = TextEditingController();
  final FocusNode _focusInput = FocusNode();
  final ScrollController _scroll = ScrollController();
  final TextEditingController _historySearch = TextEditingController();
  AiClient? _client;
  bool _busy = false;
  AiChatMessage? _streamingMsg;
  bool _loaded = false;
  /// 聊天列表是否自动跟随最新内容；用户向上翻阅时暂停，点「回到最新」恢复。
  bool _followBottom = true;
  /// 流式输出 UI 刷新定时器（节流）。
  Timer? _uiFlush;
  /// 历史会话搜索关键词。
  String _historyQuery = '';
  /// 本轮用户消息在 _history 中的起始下标，用于失败重试时回退。
  int _lastUserHistStart = 0;
  /// 当前流中已累积、但尚未确定归属（最终回复或工具轮次过渡文本）的文本。
  /// 当一轮以工具调用结束时，onToolRoundText 会把这部分文本从
  /// _streamingMsg.text 中拆出，移入 toolRoundTexts。
  String _pendingRoundBuf = '';
  /// 当前工具轮次号（= 已拆出的过渡文本条数）；ToolRecord.round 据此赋值，
  /// 使工具卡片能插到对应过渡文本之后。
  int _toolRound = 0;
  /// 插件声明的 AI 工具（GET /api/plugins/agent/tools，OpenAI function 格式
  /// name/description/parameters + 附加 confirm 标记）。
  final List<_PluginAiTool> _pluginTools = [];

  /// 完全访问模式（AI 权限 = full）：写操作直接执行，不再弹出审批框。
  bool get _fullAccess => widget.settings.isFullAccess;

  /// 快速开关是否可用：AI 尚未配置（或外壳还没加载完设置）时不允许切换，
  /// 防止把占位的空设置写穿三端共享的 .editor_ai.json。
  bool get _canTogglePermission =>
      widget.settings.apiKey.isNotEmpty || widget.settings.model.isNotEmpty;

  /// 切换 AI 权限模式（变更前确认 ↔ 完全访问）：持久化并通知外壳刷新。
  Future<void> _togglePermissionMode() async {
    if (!_canTogglePermission) return;
    final s = AiSettings.fromJson(widget.settings.toJson())
      ..permissionMode = _fullAccess ? 'confirm' : 'full';
    await s.save();
    widget.onChanged(s);
  }

  /// 旧版单会话存储 key（v1，启动时迁移到多会话后清理）。
  static const _historyKey = 'ai_chat_messages_v1';
  static const _structuredKey = 'ai_chat_history_v1';
  /// 多会话存储 key。
  static const _sessionsKey = 'ai_sessions_v1';
  static const _activeKey = 'ai_active_session_v1';
  static const _maxSessions = 50;
  static const _maxPersistMessages = 100;
  static const _maxPersistItems = 300;
  static const _maxUploadBytes = 10 * 1024 * 1024;
  /// 距底部小于该距离视为"在最新位置"，恢复自动跟随。
  static const double _bottomThreshold = 140;
  /// 流式输出的 UI 刷新间隔（毫秒）：数据即时累加，界面按此节流重建。
  static const int _streamFlushMs = 90;

  /// 待发送附件（上传解析成功、尚未随消息发出）。
  final List<AiAttachment> _pendingAttachments = [];
  bool _uploading = false;

  /// 会话提示语随 AI 权限模式变化（完全访问时不承诺逐项确认）。
  String get _systemHint => 'AI 助手已就绪。我可以直接读取并修改当前模组内容（剧情/背景/人物/社交/恋爱等细分领域），例如：\n'
      '「帮我看看剧情里有哪些事件」\n'
      '「把事件 320101 的标题改成 xxx」\n'
      '「给人物 102 换一句自我介绍」\n'
      '「把背景 5 换成另一张图」\n'
      '「让薛诗蕾滑动入场到左侧，表情开心，然后滑动退场」\n'
      '「生成一张夏日校园操场背景图」「把这张图改成夜晚场景」\n'
      '${_fullAccess ? '当前为完全访问模式：修改会直接执行，不再弹出确认框。'
          : '修改会先展示改动并等你确认，不会直接写入；生图/改图也会先经你审批后再调用图片服务。'}';

  /// 细分领域工具集：AI 以「领域 + 条目」粒度读写模组内容，
  /// 不再直接整文件覆盖（领域见 list_domains，写操作需用户确认）。
  List<AiToolDef> get _tools => [
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
              'name': {'type': 'string', 'description': '字典 id，如 roles/items/maps/jobs/attrs/relations/bgs/turns/evt_types/badminton_models；留空列出全部'},
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
              'domain': {'type': 'string', 'description': '领域 id（先调 list_domains 获取，如 story=剧情、background=背景）'},
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
              'cfg': {'type': 'string', 'description': '配置表名，如 EvtCfg/TalkCfg/BgCfg/PersonCfg'},
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
              'patch': {'type': 'object', 'description': '要修改的字段，如 {"title": "新标题"}；修改对白（TalkCfg）的说话人时 roleIds（说话人群组）必填、短信/动态（PhoneMsgCfg/KZoneContentCfg）的 role（发送者）必填，roleName 只是可选显示名，不能替代 roleIds'},
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
              'data': {'type': 'object', 'description': '新条目内容，如 {"id": 101, "name": "新角色"}；创建对白（TalkCfg）时 roleIds（说话人群组）必填、短信/动态（PhoneMsgCfg/KZoneContentCfg）的 role（发送者）必填，roleName 只是可选显示名，不能替代 roleIds'},
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
          description: '列出模组或工作区目录下的文件（只读探索用；scope: mod=当前模组, workspace=工作区；path 为相对路径，空为根目录）',
          parameters: {
            'type': 'object',
            'properties': {
              'path': {'type': 'string', 'description': '相对路径，默认根目录'},
              'scope': {'type': 'string', 'enum': ['mod', 'workspace'], 'description': 'mod=当前模组目录, workspace=工作区'},
            },
          },
        ),
        AiToolDef(
          name: 'read_file',
          description: '读取模组文件内容（只读探索用，修改内容请使用领域工具 update_domain_item）。path 为相对模组根目录的路径',
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
              'talk_id': {'type': 'string', 'description': '对白ID（TalkCfg 条目 id，来自 list_domain_items）'},
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
              'commands': {'type': 'array', 'description': '舞台指令数组，每项为对象，字段见 description 示例（action/role/mode/pos/expr/type/value/axis）'},
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
              'prompt': {'type': 'string', 'description': '图片内容描述（英文效果更佳），可包含风格、构图、氛围等要求'},
              'n': {'type': 'integer', 'description': '一次生成的图片数量，1-10，默认 1'},
              'size': {'type': 'string', 'description': '尺寸，如 1024x1024（默认）；gpt-image 系列支持任意「宽x高」（宽高为 64 的整数倍、不超过 8192，如 2048x2048）或 auto；dall-e 系列限 256x256/512x512/1024x1024/1024x1792/1792x1024'},
              'quality': {'type': 'string', 'description': '质量，可选 auto/high/medium/low（gpt-image 系列支持）'},
              'style': {'type': 'string', 'description': '风格，可选 vivid（生动）/natural（自然），dall-e-3 支持'},
              'background': {'type': 'string', 'description': '背景，可选 transparent（透明）/opaque（不透明），gpt-image 系列支持'},
              'model': {'type': 'string', 'description': '图片模型，可选，默认使用设置中的图片模型（gpt-image-2）'},
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
              'mask': {'type': 'string', 'description': '可选，蒙版图片相对路径（PNG，白色区域为可修改区域）'},
              'n': {'type': 'integer', 'description': '一次生成的图片数量，1-10，默认 1'},
              'size': {'type': 'string', 'description': '尺寸，可选 1024x1024（默认）等'},
              'model': {'type': 'string', 'description': '图片模型，可选，默认使用设置中的图片模型'},
            },
          },
        ),
      ];

  @override
  void initState() {
    super.initState();
    _restore();
    unawaited(_loadPluginTools());
  }

  @override
  void dispose() {
    _uiFlush?.cancel();
    _client?.cancel();
    _input.dispose();
    _focusInput.dispose();
    _historySearch.dispose();
    _scroll.dispose();
    super.dispose();
  }

  // ---------------- 会话与持久化 ----------------

  /// 创建新会话（空的 messages/history 列表与面板共享）。
  AiSession _newSession() {
    final id =
        's${DateTime.now().millisecondsSinceEpoch}_${Random().nextInt(0xFFFFFF)}';
    return AiSession(id: id, messages: [], history: []);
  }

  /// 把面板当前视图绑定到指定会话（共享其 messages/history 引用），
  /// 回到聊天视图并重算重试起点。
  void _activate(AiSession s) {
    _active = s;
    _messages = s.messages;
    _history = s.history;
    _showHistory = false;
    _followBottom = true;
    _lastUserHistStart = 0;
    for (var idx = 0; idx < _history.length; idx++) {
      if (_history[idx]['role'] == 'user') _lastUserHistStart = idx;
    }
  }

  /// 会话标题：第一条用户消息（或首条非空消息）的前 30 字符。
  void _updateTitle(AiSession s) {
    if (s.title != '新对话') return;
    String? first;
    for (final m in s.messages) {
      if (m.role == 'user' && m.text.trim().isNotEmpty) {
        first = m.text;
        break;
      }
    }
    first ??= s.messages.isEmpty
        ? null
        : s.messages.firstWhere((m) => m.text.trim().isNotEmpty,
            orElse: () => s.messages.first).text;
    if (first == null) return;
    final t = first.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (t.isNotEmpty) {
      s.title = t.length > 30 ? '${t.substring(0, 30)}…' : t;
    }
  }

  /// 从旧版单会话存储（v1）构建会话；无有效数据返回 null。
  AiSession? _legacySession(String msgsRaw, String? histRaw) {
    try {
      final msgs = <AiChatMessage>[];
      final list = jsonDecode(msgsRaw) as List;
      for (final m in list) {
        if (m is Map) {
          final msg = AiChatMessage.fromJson(m.cast<String, dynamic>());
          if (msg != null) msgs.add(msg);
        }
      }
      final history = <Map<String, dynamic>>[];
      if (histRaw != null) {
        final hlist = jsonDecode(histRaw) as List;
        history.addAll(hlist.cast<Map<String, dynamic>>());
      }
      if (msgs.isEmpty && history.isEmpty) return null;
      final s = AiSession(id: 'legacy', messages: msgs, history: history);
      _updateTitle(s);
      return s;
    } catch (_) {
      return null;
    }
  }

  Future<void> _restore() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    final msgsRaw = prefs.getString(_historyKey);
    final histRaw = prefs.getString(_structuredKey);
    final sessionsRaw = prefs.getString(_sessionsKey);
    setState(() {
      _sessions.clear();
      if (sessionsRaw != null) {
        try {
          final list = jsonDecode(sessionsRaw) as List;
          for (final s in list) {
            if (s is Map) {
              final session = AiSession.fromJson(s.cast<String, dynamic>());
              if (session != null) _sessions.add(session);
            }
          }
        } catch (_) {}
      }
      AiSession? active;
      final activeId = prefs.getString(_activeKey);
      if (activeId != null) {
        for (final s in _sessions) {
          if (s.id == activeId) {
            active = s;
            break;
          }
        }
      }
      // 首次升级：旧版单会话数据迁移为第一个历史会话
      if (_sessions.isEmpty && msgsRaw != null) {
        final legacy = _legacySession(msgsRaw, histRaw);
        if (legacy != null) {
          _sessions.add(legacy);
          active = legacy;
        }
      }
      // 兜底：总是保证存在一个可用的当前会话
      active ??= _sessions.isNotEmpty ? _sessions.last : _newSession();
      if (!_sessions.contains(active)) _sessions.add(active);
      _activate(active);
      _loaded = true;
    });
    // 迁移完成后清理旧版 key（保留持久化结果）
    if (msgsRaw != null) {
      await prefs.remove(_historyKey);
      await prefs.remove(_structuredKey);
    }
    await _persist();
  }

  Future<void> _persist() async {
    if (!_loaded) return;
    final prefs = await SharedPreferences.getInstance();
    final active = _active;
    if (active != null) {
      active.updatedAt = DateTime.now();
      _updateTitle(active);
    }
    // 会话数上限：保留最近更新的会话（不删除当前会话）
    while (_sessions.length > _maxSessions) {
      AiSession? oldest;
      for (final s in _sessions) {
        if (oldest == null || s.updatedAt.isBefore(oldest.updatedAt)) {
          oldest = s;
        }
      }
      if (oldest == null || oldest == active) break;
      _sessions.remove(oldest);
    }
    // 逐会话截断后序列化（避免单条超大内容撑爆本地配置）
    final list = [
      for (final s in _sessions) _sessionToPersistedJson(s),
    ];
    await prefs.setString(_sessionsKey, jsonEncode(list));
    await prefs.setString(_activeKey, active?.id ?? '');
  }

  /// 将会话序列化为持久化 JSON：单条文本/工具结果/结构化内容截断，
  /// 消息与历史条目数量上限，结构化历史以 user 开头对齐。
  Map<String, dynamic> _sessionToPersistedJson(AiSession s) {
    final msgs = s.messages.map((m) {
      final j = m.toJson();
      final t = j['text'];
      if (t is String && t.length > 20000) j['text'] = t.substring(0, 20000);
      final tools = j['tools'];
      if (tools is List) {
        for (final t2 in tools) {
          if (t2 is Map) {
            final r = t2['result'];
            if (r is String && r.length > 5000) {
              t2['result'] = r.substring(0, 5000);
            }
          }
        }
      }
      return j;
    }).toList();
    if (msgs.length > _maxPersistMessages) {
      msgs.removeRange(0, msgs.length - _maxPersistMessages);
    }
    final hist = <Map<String, dynamic>>[];
    for (final m in s.history) {
      final j = Map<String, dynamic>.from(m);
      final c = j['content'];
      if (c is String) {
        if (c.length > 20000) j['content'] = c.substring(0, 20000);
      } else if (c is List) {
        // 图片 base64 数据不持久化：image_url 块降级为文本占位，
        // 避免历史记录被大字符串撑爆；恢复后仅保留可读说明。
        final blocks = <Map<String, dynamic>>[];
        for (final b in c) {
          if (b is! Map<String, dynamic>) continue;
          if (b['type'] == 'image_url') {
            blocks.add({
              'type': 'text',
              'text': '（图片附件：${b['attachment_name'] ?? ''}）',
            });
          } else {
            final copy = Map<String, dynamic>.from(b);
            final t = copy['text'];
            if (t is String && t.length > 20000) {
              copy['text'] = t.substring(0, 20000);
            }
            blocks.add(copy);
          }
        }
        j['content'] = blocks;
      }
      hist.add(j);
    }
    if (hist.length > _maxPersistItems) {
      hist.removeRange(0, hist.length - _maxPersistItems);
    }
    // 对齐：结构化消息必须以 user 开头（避免恢复后以孤立 tool/tool_calls 消息
    // 开头导致 API 400；同时保证 _lastUserHistStart 恢复后指向有效 user 条目）
    while (hist.isNotEmpty && hist.first['role'] != 'user') {
      hist.removeAt(0);
    }
    return {
      'id': s.id,
      'title': s.title,
      'createdAt': s.createdAt.millisecondsSinceEpoch,
      'updatedAt': s.updatedAt.millisecondsSinceEpoch,
      'messages': msgs,
      'history': hist,
    };
  }

  // ---------------- 发送 / 重试 / 清空 ----------------

  /// 公开注入接口：把外部构造好的文本（如预览画笔圈选上下文）作为
  /// 用户消息发送给 AI。返回是否成功进入发送流程；未就绪 / 忙时返回 false。
  Future<bool> sendText(String text) async {
    final t = text.trim();
    if (t.isEmpty || _busy || _uploading || !_loaded) return false;
    if (widget.state.modName.isEmpty) {
      _toast('请先在「模组」列表中选择一个模组，AI 才能修改模组内容');
      return false;
    }
    await _sendText(t);
    return true;
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if ((text.isEmpty && _pendingAttachments.isEmpty) ||
        _busy || _uploading || !_loaded) {
      return;
    }
    // 未选 mod 时提前拦截（避免清空输入后才发现无法操作）；
    // 完整的前后端同步由 _sendText 内的 _ensureModSynced 负责。
    if (widget.state.modName.isEmpty) {
      _toast('请先在「模组」列表中选择一个模组，AI 才能修改模组内容');
      return;
    }
    final attachments = List<AiAttachment>.of(_pendingAttachments);
    _input.clear();
    _followBottom = true;
    _focusInput.requestFocus();
    setState(() {
      _pendingAttachments.clear();
    });
    await _sendText(text, attachments: attachments);
  }

  Future<void> _sendText(String text,
      {bool appendUser = true,
      List<AiAttachment> attachments = const [],
      AiChatMessage? retryInto}) async {
    if (_busy || !_loaded) return;
    // 默认只修改「当前选定的 mod」：未选 mod 时阻止操作；
    // 后端与前端不一致时先同步，避免 AI 改到其他模组。
    if (!await _ensureModSynced()) return;
    final client = AiClient(widget.settings,
        modContext: '当前模组：${widget.state.modName}。默认只修改这个模组，'
            '不要读取或修改其他模组的内容。');
    final content = _buildContent(text, attachments);
    setState(() {
      if (appendUser) {
        _messages.add(AiChatMessage(
            role: 'user', text: text, attachments: attachments));
        _lastUserHistStart = _history.length; // 用户消息在 _history 中的下标
        _history.add({'role': 'user', 'content': content});
      }
      if (retryInto != null) {
        // 重试复用失败的气泡：已流出的部分文本保留，追加重连提示后继续流式输出，
        // 不清空该消息；工具卡片/过渡文本归属已回滚的那次尝试，随重试从 0 轮重来。
        retryInto
          ..error = null
          ..toolRecords.clear()
          ..toolRoundTexts.clear();
        final sep = retryInto.text.isEmpty ? '' : '\n\n';
        retryInto.text = '${retryInto.text}$sep⚠ 连接中断，正在重试…\n';
        _streamingMsg = retryInto;
      } else {
        _streamingMsg = AiChatMessage(role: 'assistant');
        _messages.add(_streamingMsg!);
      }
      _busy = true;
      _pendingRoundBuf = '';
      _toolRound = 0;
    });
    unawaited(_persist());
    _scrollDown();
    _client = client;
    try {
      await client.send(
        history: _history,
        tools: [..._tools, ..._pluginTools],
        callbacks: AiCallbacks(
          onText: (delta) {
            if (!mounted || _streamingMsg == null) return;
            if (!identical(_client, client)) return; // 旧流回调，已停止
            // 数据层即时累加，界面按 _streamFlushMs 节流刷新，
            // 避免长回复时每个 delta 都重建整个消息列表导致卡顿。
            _streamingMsg!.text += delta;
            _pendingRoundBuf += delta;
            _scheduleStreamFlush();
          },
          onToolRoundText: (roundText) {
            if (!mounted || _streamingMsg == null) return;
            if (!identical(_client, client)) return; // 旧流回调，已停止
            setState(() {
              // 把本轮的过渡文本从流式 text 中拆出（它们已作为 delta
              // 追加在 text 末尾），避免与最终回复混在同一个气泡里。
              final t = _streamingMsg!.text;
              if (_pendingRoundBuf.isNotEmpty &&
                  t.length >= _pendingRoundBuf.length &&
                  t.endsWith(_pendingRoundBuf)) {
                _streamingMsg!.text =
                    t.substring(0, t.length - _pendingRoundBuf.length);
              }
              _pendingRoundBuf = '';
              if (roundText.trim().isNotEmpty) {
                _streamingMsg!.toolRoundTexts.add(roundText);
              }
              // 轮次推进：后续工具卡片按当前轮次标记
              _toolRound = _streamingMsg!.toolRoundTexts.length;
            });
            _scrollFollow();
          },
          onToolCall: (call) => _runTool(call),
          onToolResult: (name, result) {
            if (!mounted || _streamingMsg == null) return;
            if (!identical(_client, client)) return; // 旧流回调，已停止
            setState(() {
              final rec = _streamingMsg!.toolRecords.isNotEmpty
                  ? _streamingMsg!.toolRecords.last
                  : null;
              if (rec != null && rec.name == name) rec.result = result;
            });
          },
          onDone: () {
            if (!mounted) return;
            if (!identical(_client, client)) return; // 已被停止/新会话接管
            setState(() {
              _busy = false; _streamingMsg = null; _client = null;
              _pendingRoundBuf = '';
            });
            unawaited(_persist());
          },
        ),
      );
    } catch (e) {
      if (!mounted) return;
      if (!identical(_client, client)) return; // 已被停止/新会话接管
      setState(() {
        _streamingMsg!.error = e.toString();
        _busy = false;
        _streamingMsg = null;
        _client = null;
        _pendingRoundBuf = '';
      });
      unawaited(_persist());
    }
  }

  // ---------------- 会话管理 ----------------

  /// 新建对话：当前会话已有内容时先保存（含在持久化中），再创建空会话。
  Future<void> _newChat() async {
    if (_busy || !_loaded) return;
    final active = _active;
    if (active != null && active.messages.isEmpty) return; // 当前已是空会话
    await _persist();
    if (!mounted) return;
    final s = _newSession();
    setState(() {
      _sessions.add(s);
      _activate(s);
    });
    await _persist();
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollDown());
  }

  /// 打开历史会话列表视图。
  void _openHistory() {
    if (_busy || !_loaded) return;
    setState(() => _showHistory = true);
  }

  /// 返回聊天视图（不切换会话）。
  void _closeHistory() {
    setState(() => _showHistory = false);
  }

  /// 切换/恢复会话：把面板绑定到该会话并回到聊天视图。
  void _switchSession(AiSession s) {
    if (_busy || !_loaded) return;
    if (s == _active) {
      setState(() => _showHistory = false);
      return;
    }
    setState(() => _activate(s));
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollDown());
  }

  /// 删除会话；删除的是当前会话时，激活最近更新的另一个会话。
  Future<void> _deleteSession(AiSession s) async {
    if (_busy) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => fluent.ContentDialog(
        title: const Text('删除该历史对话？'),
        content: Text('将删除「${s.title}」的全部消息与工具调用记录，且无法恢复。'),
        actions: [
          fluent.Button(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          fluent.FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() {
      _sessions.remove(s);
      if (_active == s) {
        final sorted = List.of(_sessions)
          ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
        final next = sorted.isNotEmpty ? sorted.first : _newSession();
        _activate(next);
        if (!_sessions.contains(next)) _sessions.add(next);
      }
    });
    await _persist();
  }

  /// 重试：回滚结构化历史（保留用户消息及其 user 条目），在同一失败气泡内
  /// 续写——已流出的部分文本保留，追加重连提示后重新流式生成，不清空该消息。
  Future<void> _retry() async {
    if (_busy || _messages.isEmpty) return;
    final lastUser = _messages.lastWhere((m) => m.role == 'user', orElse: () => _messages.first);
    if (lastUser.role != 'user') return;
    final failed = _messages.last;
    if (failed.role != 'assistant' || failed.error == null) return; // 只有失败气泡可重试
    setState(() {
      // 只回退结构化历史到该轮起点之后（保留用户消息本身）；
      // 失败气泡不删除，重试在同一气泡续写
      if (_lastUserHistStart < _history.length) {
        _history.removeRange(_lastUserHistStart + 1, _history.length);
      }
    });
    await _sendText(lastUser.text, appendUser: false, retryInto: failed);
  }

  Future<void> _clearChat() async {
    if (_messages.length <= 1) return; // 只有 system 提示
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => fluent.ContentDialog(
        title: const Text('清空聊天记录？'),
        content: const Text('将删除当前会话的全部消息与工具调用记录，且无法恢复。'),
        actions: [
          fluent.Button(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          fluent.FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() {
      _messages
        ..clear()
        ..add(AiChatMessage(role: 'system', text: _systemHint));
      _history.clear();
      _active?.title = '新对话';
    });
    unawaited(_persist());
  }

  void _stop() {
    _client?.cancel();
    setState(() {
      _busy = false;
      _streamingMsg = null;
      _client = null;
      _pendingRoundBuf = '';
    });
  }

  Future<void> _copyText(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    fluent.displayInfoBar(context, builder: (ctx, close) =>
        fluent.InfoBar(title: const Text('已复制到剪贴板'),
            severity: fluent.InfoBarSeverity.success),
        duration: const Duration(seconds: 2));
  }

  // ---------------- 附件上传 ----------------

  /// 组装发送给模型的内容：文本附件拼入正文；图片附件转为多模态 image_url 块。
  Object _buildContent(String text, List<AiAttachment> attachments) {
    final textParts = <String>[
      for (final a in attachments)
        if (a.kind == 'text' && (a.text ?? '').isNotEmpty)
          '【附件：${a.name}】\n${a.text}',
    ];
    final images = attachments.where((a) => a.kind == 'image').toList();
    final fullText = [
      if (textParts.isNotEmpty) textParts.join('\n\n'),
      text,
    ].where((s) => s.isNotEmpty).join('\n\n');
    if (images.isEmpty) return fullText;
    return [
      {'type': 'text', 'text': fullText},
      for (final img in images)
        {
          'type': 'image_url',
          'image_url': {'url': 'data:${img.mime};base64,${img.dataB64}'},
          // 持久化降级时用作图片占位说明
          'attachment_name': img.name,
        },
    ];
  }

  Future<void> _pickFiles() async {
    if (_busy || _uploading || !mounted) return;
    const groups = [
      XTypeGroup(label: '文档', extensions: ['docx', 'txt', 'md', 'xlsx']),
      XTypeGroup(label: '图片', extensions: ['png', 'jpg', 'jpeg']),
    ];
    final files = await openFiles(acceptedTypeGroups: groups);
    if (files.isEmpty || !mounted) return;
    for (final f in files) {
      await _uploadFile(f);
    }
  }

  Future<void> _uploadFile(XFile f) async {
    try {
      final bytes = await f.readAsBytes();
      if (bytes.length > _maxUploadBytes) {
        _toast('「${f.name}」超过 10MB 上限，已跳过');
        return;
      }
      if (mounted) setState(() => _uploading = true);
      final r = await ApiClient.instance.post('/api/ai/upload', body: {
        'name': f.name,
        'data': base64Encode(bytes),
      });
      final kind = r['kind'] as String? ?? 'text';
      final att = AiAttachment(
        name: r['name'] as String? ?? f.name,
        kind: kind,
        size: (r['size'] as num?)?.toInt() ?? bytes.length,
        text: kind == 'text' ? (r['text'] as String? ?? '') : null,
        mime: r['mime'] as String?,
        dataB64: kind == 'image' ? (r['data'] as String?) : null,
      );
      if (!mounted) return;
      setState(() {
        _pendingAttachments.add(att);
        _uploading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _uploading = false);
      _toast('上传「${f.name}」失败：$e');
    }
  }

  void _toast(String message) {
    fluent.displayInfoBar(context, builder: (ctx, close) =>
        fluent.InfoBar(title: Text(message),
            severity: fluent.InfoBarSeverity.error),
        duration: const Duration(seconds: 3));
  }

  // ---------------- 工具执行 ----------------

  /// 确保 AI 只作用于「当前选定的 mod」：
  /// - 未选 mod 时返回 false 并提示（不静默回退到后端默认模组）；
  /// - 后端当前模组与前端不一致时先同步 select，再继续。
  Future<bool> _ensureModSynced() async {
    final modName = widget.state.modName;
    if (modName.isEmpty) {
      _toast('请先在「模组」列表中选择一个模组，AI 才能修改模组内容');
      return false;
    }
    try {
      final st = await ApiClient.instance.get('/api/state');
      if ((st['mod_name'] as String? ?? '') != modName) {
        await ApiClient.instance.post('/api/mods/select', body: {'name': modName});
      }
      return true;
    } catch (e) {
      _toast('同步当前模组失败：$e');
      return false;
    }
  }

  /// 拉取插件声明的 AI 工具，追加到发送给模型的 tools 列表；
  /// 失败静默（后端暂不支持插件工具时不阻塞聊天）。
  Future<void> _loadPluginTools() async {
    try {
      final r = await ApiClient.instance.get('/api/plugins/agent/tools');
      if (!mounted) return;
      final list = r is Map ? (r['tools'] as List? ?? const []) : const [];
      final tools = <_PluginAiTool>[];
      for (final e in list) {
        if (e is! Map) continue;
        final m = Map<String, dynamic>.from(e);
        final name = (m['name'] as String? ?? '').trim();
        if (name.isEmpty) continue;
        tools.add(_PluginAiTool(
          name: name,
          description: m['description'] as String? ?? '',
          parameters: m['parameters'] is Map
              ? Map<String, dynamic>.from(m['parameters'] as Map)
              : const {},
          confirm: m['confirm'] == true,
        ));
      }
      setState(() {
        _pluginTools
          ..clear()
          ..addAll(tools);
      });
    } catch (_) {
      // 静默：插件工具不可用时不打断聊天
    }
  }

  /// 执行工具：映射到后端 API。
  Future<String> _runTool(AiToolCall call) async {
    final rec =
        ToolRecord(name: call.name, arguments: call.arguments, round: _toolRound);
    if (!mounted || _streamingMsg == null) return '错误：面板已关闭';
    setState(() => _streamingMsg!.toolRecords.add(rec));

    try {
      switch (call.name) {
        case 'list_domains':
          final r = await ApiClient.instance.get('/api/ai/domains');
          final domains = (r['domains'] as List).map((d) {
            final m = d as Map<String, dynamic>;
            final tables = (m['tables'] as Map<String, dynamic>).keys.join('、');
            return '${m['id']}（${m['name']}）：${m['desc']}\n  包含表：$tables';
          }).join('\n\n');
          return domains.isEmpty ? '(无领域)' : domains;
        case 'get_game_dicts':
          final name = (call.arguments['name'] as String?) ?? '';
          final q = (call.arguments['q'] as String?) ?? '';
          final limit = (call.arguments['limit'] as num?)?.toInt();
          final r = await ApiClient.instance.get('/api/ai/dicts',
              query: {
                if (name.isNotEmpty) 'name': name,
                if (q.isNotEmpty) 'q': q,
                if (limit != null) 'limit': '$limit',
              });
          if (r['dicts'] != null) {
            // 列出可用字典
            final dicts = (r['dicts'] as List).map((d) {
              final m = d as Map<String, dynamic>;
              return '${m['id']}（${m['name']}）：${m['count']} 项';
            }).join('\n');
            return '可用字典：\n$dicts';
          }
          final items = (r['items'] as List).map((e) {
            final m = e as Map<String, dynamic>;
            return '${m['id']} · ${m['name']}';
          }).join('\n');
          return '[${r['cn']}] 共 ${r['total']} 条匹配：\n$items';
        case 'list_domain_items':
          final domain = (call.arguments['domain'] as String?) ?? '';
          if (domain.isEmpty) return '错误：缺少 domain 参数';
          final q = (call.arguments['q'] as String?) ?? '';
          final table = (call.arguments['table'] as String?) ?? '';
          final limit = (call.arguments['limit'] as num?)?.toInt();
          final r = await ApiClient.instance.get('/api/ai/domain/items',
              query: {
                'domain': domain,
                if (q.isNotEmpty) 'q': q,
                if (table.isNotEmpty) 'table': table,
                if (limit != null) 'limit': '$limit',
              });
          final items = (r['items'] as List).map((e) {
            final m = e as Map<String, dynamic>;
            final name = (m['name'] as String? ?? '').trim();
            final summary = (m['summary'] as String? ?? '').trim();
            final label = name.isEmpty ? 'id=${m['id']}' : '「$name」(id=${m['id']})';
            final extra = summary.isEmpty ? '' : ' — $summary';
            return '[${m['cfg']}] $label$extra';
          }).join('\n');
          return items.isEmpty ? '(该领域暂无条目，或关键词无匹配)' : items;
        case 'get_domain_item':
          final domain = (call.arguments['domain'] as String?) ?? '';
          final cfg = (call.arguments['cfg'] as String?) ?? '';
          final id = (call.arguments['id'] as String?) ?? '';
          if (domain.isEmpty || cfg.isEmpty || id.isEmpty) {
            return '错误：缺少 domain/cfg/id 参数';
          }
          final r = await ApiClient.instance.get('/api/ai/domain/item',
              query: {'domain': domain, 'cfg': cfg, 'id': id});
          final data = r['data'];
          return '[${r['cfg_cn'] ?? cfg}] id=$id\n${jsonEncode(data)}';
        case 'update_domain_item':
          final domain = (call.arguments['domain'] as String?) ?? '';
          final cfg = (call.arguments['cfg'] as String?) ?? '';
          final id = (call.arguments['id'] as String?) ?? '';
          final patch = call.arguments['patch'];
          if (domain.isEmpty || cfg.isEmpty || id.isEmpty) {
            return '错误：缺少 domain/cfg/id 参数';
          }
          if (patch is! Map<String, dynamic> || patch.isEmpty) {
            return '错误：patch 必须是非空对象';
          }
          // 先读取原条目用于 diff 预览
          final old = await ApiClient.instance.get('/api/ai/domain/item',
              query: {'domain': domain, 'cfg': cfg, 'id': id});
          final rawOld = old['data'];
          final oldData = rawOld is Map
              ? rawOld.map((k, v) => MapEntry(k.toString(), v))
              : <String, dynamic>{};
          final newData = Map<String, dynamic>.from(oldData)..addAll(patch);
          final approved = await _confirmDomainChange(
            'AI 请求修改「${old['cfg_cn'] ?? cfg}」id=$id',
            _diffJson(oldData, newData),
          );
          if (!approved) {
            rec.approved = false;
            if (mounted) setState(() {});
            return '用户拒绝修改。请停止该操作并向用户说明。';
          }
          final r2 = await ApiClient.instance.put('/api/ai/domain/item', body: {
            'domain': domain,
            'cfg': cfg,
            'id': id,
            'patch': patch,
          });
          if (r2['changed'] == true) {
            return '已修改字段：${(r2['patched_fields'] as List).join('、')}\n'
                '新内容：${jsonEncode(r2['data'])}';
          }
          return '未改动（${r2['note'] ?? 'patch 与原内容一致'}）';
        case 'create_domain_item':
          final domain = (call.arguments['domain'] as String?) ?? '';
          final cfg = (call.arguments['cfg'] as String?) ?? '';
          final data = call.arguments['data'];
          if (domain.isEmpty || cfg.isEmpty) {
            return '错误：缺少 domain/cfg 参数';
          }
          if (data is! Map<String, dynamic> || data.isEmpty) {
            return '错误：data 必须是非空对象';
          }
          final approved = await _confirmDomainChange(
            'AI 请求在「$cfg」新建条目',
            '(新条目)\n\n${jsonEncode(data)}',
          );
          if (!approved) {
            rec.approved = false;
            if (mounted) setState(() {});
            return '用户拒绝新建。请停止该操作并向用户说明。';
          }
          final r2 = await ApiClient.instance.post('/api/ai/domain/item', body: {
            'domain': domain,
            'cfg': cfg,
            'data': data,
          });
          return '已新建 id=${r2['id']}：${jsonEncode(r2['data'])}';
        case 'delete_domain_item':
          final domain = (call.arguments['domain'] as String?) ?? '';
          final cfg = (call.arguments['cfg'] as String?) ?? '';
          final id = (call.arguments['id'] as String?) ?? '';
          if (domain.isEmpty || cfg.isEmpty || id.isEmpty) {
            return '错误：缺少 domain/cfg/id 参数';
          }
          final old = await ApiClient.instance.get('/api/ai/domain/item',
              query: {'domain': domain, 'cfg': cfg, 'id': id});
          final approved = await _confirmDomainChange(
            'AI 请求删除「${old['cfg_cn'] ?? cfg}」id=$id',
            '(被删除内容)\n\n${jsonEncode(old['data'])}',
          );
          if (!approved) {
            rec.approved = false;
            if (mounted) setState(() {});
            return '用户拒绝删除。请停止该操作并向用户说明。';
          }
          await ApiClient.instance.delete('/api/ai/domain/item',
              query: {'domain': domain, 'cfg': cfg, 'id': id});
          return '已删除：$cfg id=$id';
        case 'list_files':
          final path = (call.arguments['path'] as String?) ?? '';
          final scope = (call.arguments['scope'] as String?) ?? 'mod';
          final r = await ApiClient.instance.get('/api/tools/list',
              query: {'scope': scope, 'path': path, 'deep': '1'});
          final entries = (r['entries'] as List).take(300).map((e) {
            final m = e as Map<String, dynamic>;
            final p = m['name'];
            final isDir = m['type'] == 'dir';
            return (isDir ? '[目录] ' : '[文件] ') + p.toString();
          }).join('\n');
          return entries.isEmpty ? '(空目录)' : entries;
        case 'read_file':
          final path = (call.arguments['path'] as String?) ?? '';
          if (path.isEmpty) return '错误：缺少 path 参数';
          final r = await ApiClient.instance.get('/api/tools/read',
              query: {'scope': 'mod', 'path': path});
          final text = r['text'] as String?;
          if (text == null) return '错误：二进制文件或读取失败';
          return text;
        case 'list_mods':
          final r = await ApiClient.instance.get('/api/mods');
          final mods = (r['mods'] as List)
              .map((e) => (e as Map<String, dynamic>)['name'].toString())
              .join('\n');
          return mods.isEmpty ? '(无模组)' : mods;
        case 'get_stage_dicts':
          final sr = await ApiClient.instance.get('/api/ai/stage/dicts');
          final exprs = (sr['expressions'] as List)
              .map((e) {
                final m = e as Map<String, dynamic>;
                return '${m['id']}=${m['name']}';
              })
              .join(' ');
          final actions = (sr['actions'] as List).map((e) {
            final m = e as Map<String, dynamic>;
            final target = m['role'] == true ? '作用于角色' : '屏幕特效';
            return '[${m['type']}] ${m['name']}（${m['category']}/$target）：${m['params']}';
          }).join('\n');
          final poses = (sr['positions'] as List)
              .map((e) {
                final m = e as Map<String, dynamic>;
                return '${m['id']}=${m['name']}';
              })
              .join(' ');
          final roles = (sr['roles'] as List)
              .take(80)
              .map((e) {
                final m = e as Map<String, dynamic>;
                return '${m['id']}=${m['name']}';
              })
              .join(' ');
          return '人物表情：$exprs\n\n动作类型：\n$actions\n\n站位：$poses\n\n'
              '角色（前 80 个，完整列表可用 get_game_dicts(name=roles)）：\n$roles';
        case 'get_talk_stage':
          final talkId = (call.arguments['talk_id'] as String?) ?? '';
          if (talkId.isEmpty) return '错误：缺少 talk_id 参数';
          final sr2 = await ApiClient.instance.get('/api/ai/stage/roles',
              query: {'talk_id': talkId});
          return '对白 $talkId 当前人物舞台：\n${sr2['desc']}';
        case 'set_talk_stage':
          final talkId = (call.arguments['talk_id'] as String?) ?? '';
          final commands = call.arguments['commands'];
          final clear = call.arguments['clear'] == true;
          if (talkId.isEmpty) return '错误：缺少 talk_id 参数';
          if (commands is! List || commands.isEmpty) {
            return '错误：commands 必须是非空数组';
          }
          // 先编码预览（后端校验并合并原有指令，不写盘）
          final sr3 = await ApiClient.instance.post('/api/ai/stage/encode', body: {
            'talk_id': talkId,
            'commands': commands,
            'clear': clear,
          });
          final oldDesc = (sr3['old_desc'] as String? ?? '').trim();
          final newDesc = (sr3['new_desc'] as String? ?? '').trim();
          final newRoles = sr3['new_roles'];
          final approved = await _confirmDomainChange(
            'AI 请求修改对白 $talkId 的人物舞台',
            '修改前：\n$oldDesc\n\n修改后：\n$newDesc\n\n'
                '编码结果（roles 字段）：\n${jsonEncode(newRoles)}',
          );
          if (!approved) {
            rec.approved = false;
            if (mounted) setState(() {});
            return '用户拒绝修改舞台。请停止该操作并向用户说明。';
          }
          await ApiClient.instance.put('/api/ai/domain/item', body: {
            'domain': 'story',
            'cfg': 'TalkCfg',
            'id': talkId,
            'patch': {'roles': newRoles},
          });
          return '已更新对白 $talkId 的人物舞台：\n$newDesc';
        case 'generate_image':
          return await _runGenerateImage(call, rec);
        case 'edit_image':
          return await _runEditImage(call, rec);
        default:
          // 插件工具兜底分支（置于内置工具之后）
          for (final pt in _pluginTools) {
            if (pt.name == call.name) {
              return await _runPluginTool(pt, call, rec);
            }
          }
          return '错误：未知工具 ${call.name}';
      }
    } catch (e) {
      return '工具执行失败: $e';
    }
  }

  // ---------------- 插件工具 ----------------

  /// 插件工具兜底分支：confirm 标记为 true 时先请求用户确认（复用图片审批框模式），
  /// 确认后 POST /api/plugins/agent/exec {"name": 全名, "args"}；
  /// 异常由 _runTool 外层 catch 折算为「工具执行失败: …」。
  Future<String> _runPluginTool(_PluginAiTool tool, AiToolCall call, ToolRecord rec) async {
    if (tool.confirm) {
      final approved = await _confirmPluginTool(tool.name, call.arguments);
      if (!approved) {
        rec.approved = false;
        if (mounted) setState(() {});
        return '用户拒绝了插件工具 ${tool.name} 的调用。请停止该操作并向用户说明。';
      }
    }
    final r = await ApiClient.instance.post('/api/plugins/agent/exec', body: {
      'name': tool.name,
      'args': call.arguments,
    });
    final result = r is Map ? r['result'] : r;
    if (result == null) return '';
    return result.toString();
  }

  /// 插件工具确认对话框（对齐 _confirmImageAction：不可点背景关闭）。
  /// 完全访问模式下直接放行，不弹审批框。
  Future<bool> _confirmPluginTool(String toolName, Map<String, dynamic> args) async {
    if (_fullAccess) return true;
    final completer = Completer<bool>();
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        final size = MediaQuery.sizeOf(ctx);
        return fluent.ContentDialog(
          title: const Text('确认调用插件工具'),
          content: SizedBox(
            width: min(520, size.width - 48),
            height: min(320, size.height * 0.6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: const Color(0x1AE5484D),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: const Color(0x55E5484D)),
                  ),
                  child: Text(
                    '⚠ 将调用第三方插件工具 $toolName。插件以与编辑器相同的用户权限在本机运行，'
                    '可读写文件、访问网络，请确认工具与参数无误后再允许。',
                    style: TextStyle(
                        fontSize: 11, color: palette.statusDanger, height: 1.5),
                  ),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      color: palette.bgDeep,
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: palette.border),
                    ),
                    padding: const EdgeInsets.all(8),
                    child: SingleChildScrollView(
                      child: SelectableText(
                        '【工具】$toolName\n\n【参数】\n${jsonEncode(args)}',
                        style: const TextStyle(fontSize: 12, height: 1.5),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            fluent.Button(
              onPressed: () {
                completer.complete(false);
                Navigator.pop(ctx);
              },
              child: const Text('拒绝'),
            ),
            fluent.FilledButton(
              onPressed: () {
                completer.complete(true);
                Navigator.pop(ctx);
              },
              child: const Text('允许'),
            ),
          ],
        );
      },
    );
    return completer.future;
  }

  // ---------------- 图片生成（openai-image-api） ----------------

  /// generate_image 工具：审批 → 调 OpenAI images/generations → 保存到模组 Art/ai/。
  Future<String> _runGenerateImage(AiToolCall call, ToolRecord rec) async {
    final prompt = (call.arguments['prompt'] as String?)?.trim() ?? '';
    if (prompt.isEmpty) return '错误：缺少 prompt（图片内容描述）参数';
    final n = _clampInt(call.arguments['n'], 1, 10, 1);
    final size = (call.arguments['size'] as String?)?.trim() ?? '';
    final quality = (call.arguments['quality'] as String?)?.trim() ?? '';
    final style = (call.arguments['style'] as String?)?.trim() ?? '';
    final background = (call.arguments['background'] as String?)?.trim() ?? '';
    final model = (call.arguments['model'] as String?)?.trim() ?? '';

    final detail = StringBuffer('【生成内容】\n$prompt\n\n');
    detail.writeln('【数量】$n 张');
    if (size.isNotEmpty) detail.writeln('【尺寸】$size');
    if (quality.isNotEmpty) detail.writeln('【质量】$quality');
    if (style.isNotEmpty) detail.writeln('【风格】$style');
    if (background.isNotEmpty) detail.writeln('【背景】$background');
    detail.writeln('【模型】${model.isEmpty ? widget.settings.effectiveImageModel : model}');
    detail.writeln('\n将调用 OpenAI Images API（images/generations）生成图片，'
        '完成后自动保存到当前模组的 Art/ai/ 目录。注意：调用图片服务会消耗 API 额度（产生费用），请确认内容无误后再允许。');

    final approved = await _confirmImageAction('AI 请求生成图片', detail.toString());
    if (!approved) {
      rec.approved = false;
      if (mounted) setState(() {});
      return '用户拒绝了图片生成请求。请停止该操作并向用户说明。';
    }

    try {
      final r = await ApiClient.instance.post('/api/ai/image/generate',
          body: {
            'api_key': widget.settings.effectiveImageApiKey,
            'base_url': widget.settings.effectiveImageBaseUrl,
            'model': model.isEmpty ? widget.settings.effectiveImageModel : model,
            'prompt': prompt,
            'n': n,
            if (size.isNotEmpty) 'size': size,
            if (quality.isNotEmpty) 'quality': quality,
            if (style.isNotEmpty) 'style': style,
            if (background.isNotEmpty) 'background': background,
          },
          timeout: const Duration(seconds: 300));
      final images = r['images'] as List? ?? [];
      if (images.isEmpty) return '图片服务未返回任何图片';
      final paths = <String>[];
      final saved = <String>[];
      final ts = _aiImageTs();
      for (var i = 0; i < images.length; i++) {
        final img = images[i] as Map<String, dynamic>;
        final b64 = img['b64'] as String? ?? '';
        if (b64.isEmpty) continue;
        final rel = 'Art/ai/${ts}_${i + 1}.png';
        final write = await ApiClient.instance.put('/api/tools/write', body: {
          'scope': 'mod',
          'path': rel,
          'content': b64,
          'base64': true,
        });
        final savedPath = (write['path'] as String?) ?? rel;
        paths.add(savedPath);
        saved.add(savedPath);
      }
      if (saved.isEmpty) return '图片生成成功但保存失败（无有效图片数据）';
      rec.images.addAll(saved);
      if (mounted) setState(() {});
      return '已生成并保存 ${saved.length} 张图片到模组：\n'
          '${saved.join('\n')}\n'
          '（路径可用于 update_domain_item 写入配置，如 BgCfg 的 url 字段）';
    } catch (e) {
      return '图片生成失败: $e';
    }
  }

  /// edit_image 工具：读取模组图片 → 审批 → 调 OpenAI images/edits → 保存。
  Future<String> _runEditImage(AiToolCall call, ToolRecord rec) async {
    final image = (call.arguments['image'] as String?)?.trim() ?? '';
    final prompt = (call.arguments['prompt'] as String?)?.trim() ?? '';
    final mask = (call.arguments['mask'] as String?)?.trim() ?? '';
    final n = _clampInt(call.arguments['n'], 1, 10, 1);
    final size = (call.arguments['size'] as String?)?.trim() ?? '';
    final model = (call.arguments['model'] as String?)?.trim() ?? '';
    if (image.isEmpty) return '错误：缺少 image（要修改的图片路径）参数';
    if (prompt.isEmpty) return '错误：缺少 prompt（修改指令）参数';

    // 读取要修改的图片与可选蒙版（均为模组内相对路径）
    Map<String, dynamic>? imgData;
    Map<String, dynamic>? maskData;
    try {
      imgData = await ApiClient.instance.get('/api/tools/read',
          query: {'scope': 'mod', 'path': image});
      if (mask.isNotEmpty) {
        maskData = await ApiClient.instance.get('/api/tools/read',
            query: {'scope': 'mod', 'path': mask});
      }
    } catch (e) {
      return '读取图片失败（$image）：$e';
    }
    final imageB64 = imgData?['base64'] as String?;
    if (imageB64 == null || imageB64.isEmpty) {
      return '错误：$image 不是可读取的图片文件（需要 png/jpg 等二进制图片）';
    }
    final maskB64 = (maskData?['base64'] as String?)?.isNotEmpty == true
        ? maskData!['base64'] as String
        : null;

    final detail = StringBuffer('【修改对象】$image\n');
    if (mask.isNotEmpty) detail.writeln('【蒙版】$mask');
    detail.writeln('【修改指令】\n$prompt\n');
    detail.writeln('【数量】$n 张');
    if (size.isNotEmpty) detail.writeln('【尺寸】$size');
    detail.writeln('【模型】${model.isEmpty ? widget.settings.effectiveImageModel : model}');
    detail.writeln('\n将调用 OpenAI Images API（images/edits）修改图片，'
        '完成后自动保存到当前模组的 Art/ai/ 目录。注意：调用图片服务会消耗 API 额度（产生费用），请确认内容无误后再允许。');

    final approved = await _confirmImageAction('AI 请求修改图片', detail.toString());
    if (!approved) {
      rec.approved = false;
      if (mounted) setState(() {});
      return '用户拒绝了图片修改请求。请停止该操作并向用户说明。';
    }

    try {
      final r = await ApiClient.instance.post('/api/ai/image/edit',
          body: {
            'api_key': widget.settings.effectiveImageApiKey,
            'base_url': widget.settings.effectiveImageBaseUrl,
            'model': model.isEmpty ? widget.settings.effectiveImageModel : model,
            'prompt': prompt,
            'image_base64': imageB64,
            'mask_base64': ?maskB64,
            'n': n,
            if (size.isNotEmpty) 'size': size,
          },
          timeout: const Duration(seconds: 300));
      final images = r['images'] as List? ?? [];
      if (images.isEmpty) return '图片服务未返回任何图片';
      final saved = <String>[];
      final ts = _aiImageTs();
      for (var i = 0; i < images.length; i++) {
        final img = images[i] as Map<String, dynamic>;
        final b64 = img['b64'] as String? ?? '';
        if (b64.isEmpty) continue;
        final rel = 'Art/ai/${ts}_edit_${i + 1}.png';
        final write = await ApiClient.instance.put('/api/tools/write', body: {
          'scope': 'mod',
          'path': rel,
          'content': b64,
          'base64': true,
        });
        saved.add((write['path'] as String?) ?? rel);
      }
      if (saved.isEmpty) return '图片修改成功但保存失败（无有效图片数据）';
      rec.images.addAll(saved);
      if (mounted) setState(() {});
      return '已修改并保存 ${saved.length} 张图片到模组：\n${saved.join('\n')}';
    } catch (e) {
      return '图片修改失败: $e';
    }
  }

  /// 图片操作确认对话框：生图/改图前必须经过用户审批。
  /// 完全访问模式下直接放行，不弹审批框。
  Future<bool> _confirmImageAction(String title, String detailText) async {
    if (_fullAccess) return true;
    final completer = Completer<bool>();
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        final size = MediaQuery.sizeOf(ctx);
        return fluent.ContentDialog(
        title: Text(title),
        content: SizedBox(
          width: min(520, size.width - 48),
          height: min(340, size.height * 0.6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: const Color(0x1A4C6EF5),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: const Color(0x3357A0FF)),
                ),
                child: Text('⚠ 将调用 OpenAI Images API（产生费用），且生成的图片会写入当前模组。',
                    style: TextStyle(fontSize: 11, color: palette.statusInfo)),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    color: palette.bgDeep,
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: palette.border),
                  ),
                  padding: const EdgeInsets.all(8),
                  child: SingleChildScrollView(
                    child: SelectableText(
                      detailText,
                      style: const TextStyle(fontSize: 12, height: 1.5),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          fluent.Button(
            onPressed: () {
              completer.complete(false);
              Navigator.pop(ctx);
            },
            child: const Text('拒绝'),
          ),
          fluent.FilledButton(
            onPressed: () {
              completer.complete(true);
              Navigator.pop(ctx);
            },
            child: const Text('允许生成'),
          ),
        ],
      );
    });
    return completer.future;
  }

  /// 整数参数规整：空/非法用 [def]，否则 clamp 到 [min, max]。
  int _clampInt(dynamic v, int min, int max, int def) {
    if (v is num) {
      return (v.toInt()).clamp(min, max);
    }
    if (v is String) {
      final i = int.tryParse(v.trim());
      if (i != null) return i.clamp(min, max);
    }
    return def;
  }

  /// 生成时间戳文件名前缀（本地时间，秒级 + 随机避免并发冲突）。
  String _aiImageTs() {
    final now = DateTime.now();
    String two(int x) => x.toString().padLeft(2, '0');
    return 'ai_${now.year}${two(now.month)}${two(now.day)}_'
        '${two(now.hour)}${two(now.minute)}${two(now.second)}'
        '${Random().nextInt(900) + 100}';
  }

  /// 领域写操作确认对话框（展示 JSON diff）。
  /// 完全访问模式下直接放行，不弹审批框。
  Future<bool> _confirmDomainChange(String title, String diffText) async {
    if (_fullAccess) return true;
    final completer = Completer<bool>();
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        final size = MediaQuery.sizeOf(ctx);
        return fluent.ContentDialog(
        title: Text(title),
        content: SizedBox(
          width: min(520, size.width - 48),
          height: min(320, size.height * 0.6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('（预览基于原始 patch，实际写入以服务器校验与规整结果为准）',
                  style: TextStyle(fontSize: 11, color: palette.textMuted)),
              const SizedBox(height: 8),
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    color: palette.bgDeep,
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: palette.border),
                  ),
                  padding: const EdgeInsets.all(8),
                  child: SingleChildScrollView(
                    child: SelectableText(
                      diffText,
                      style: const TextStyle(
                          fontFamily: 'Consolas', fontSize: 11.5, height: 1.4),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          fluent.Button(
            onPressed: () {
              completer.complete(false);
              Navigator.pop(ctx);
            },
            child: const Text('拒绝'),
          ),
          fluent.FilledButton(
            onPressed: () {
              completer.complete(true);
              Navigator.pop(ctx);
            },
            child: const Text('允许修改'),
          ),
        ],
      );
    });
    return completer.future;
  }

  /// 两个 JSON 对象的行级 diff（- 删除行 / + 新增行 / 相同行保留）。
  String _diffJson(Map<String, dynamic> oldData, Map<String, dynamic> newData) {
    final keys = <String>{...oldData.keys, ...newData.keys};
    final buf = StringBuffer();
    for (final k in keys.toList()..sort()) {
      final ov = jsonEncode(oldData[k]);
      final nv = jsonEncode(newData[k]);
      if (oldData.containsKey(k) && newData.containsKey(k) && ov == nv) {
        buf.writeln('  "$k": $ov,');
      } else {
        if (oldData.containsKey(k)) buf.writeln('- "$k": $ov,');
        if (newData.containsKey(k)) buf.writeln('+ "$k": $nv,');
      }
    }
    return buf.toString();
  }

  // ---------------- 流式滚动与节流 ----------------

  /// 流式输出按 [_streamFlushMs] 节流刷新 UI：数据已即时写入消息，
  /// 这里只是把重建合并到定时器里，避免高频 setState 卡顿。
  void _scheduleStreamFlush() {
    if (_uiFlush != null) return;
    _uiFlush = Timer(Duration(milliseconds: _streamFlushMs), () {
      _uiFlush = null;
      _streamChanged();
    });
  }

  void _streamChanged() {
    if (!mounted || _streamingMsg == null) return;
    setState(() {});
    _scrollFollow();
  }

  bool _isNearBottom() {
    if (!_scroll.hasClients) return true;
    return _scroll.position.maxScrollExtent - _scroll.position.pixels <=
        _bottomThreshold;
  }

  /// 用户手动滚动的方向变化：向上翻阅时暂停自动跟随，向下回到最新位置时恢复。
  bool _handleUserScroll(UserScrollNotification n) {
    switch (n.direction) {
      case ScrollDirection.forward:
        if (_followBottom && mounted) setState(() => _followBottom = false);
        break;
      case ScrollDirection.reverse:
        if (!_followBottom && _isNearBottom() && mounted) {
          setState(() => _followBottom = true);
        }
        break;
      default:
        break;
    }
    return false;
  }

  /// 跟随模式下滚动到底部；用户翻阅时静默跳过，不抢滚动位置。
  void _scrollFollow() {
    if (_followBottom) _scrollDown();
  }

  void _scrollDown() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(_scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 150), curve: Curves.easeOut);
      }
    });
  }

  // ---------------- 构建 ----------------

  @override
  Widget build(BuildContext context) {
    if (_showHistory) return _buildHistoryView();
    // 空会话（只有系统提示或完全为空）时展示欢迎引导。
    final showWelcome = _messages.every((m) => m.role == 'system');
    return Column(
      children: [
        Container(
          height: 38,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: ListenableBuilder(
            listenable: widget.state,
            builder: (context, _) => Row(
              children: [
                const Icon(FluentIcons.bot_24_regular, size: 15, color: Color(0xFF6C5CE7)),
                const SizedBox(width: 8),
                Text('AI 助手',
                    style: TextStyle(fontSize: 12, color: palette.textPrimary, fontWeight: FontWeight.w600)),
                const SizedBox(width: 8),
                Expanded(
                  child: _ModBadge(name: widget.state.modName),
                ),
                const SizedBox(width: 6),
                _HoverIconBtn(
                  icon: FluentIcons.chat_history_24_regular,
                  tip: '历史对话',
                  onTap: _busy ? null : _openHistory,
                  size: 15,
                ),
                const SizedBox(width: 2),
                _HoverIconBtn(
                  icon: FluentIcons.add_24_regular,
                  tip: '新建对话',
                  onTap: _busy ? null : _newChat,
                  size: 15,
                ),
                const SizedBox(width: 2),
                _HoverIconBtn(
                  icon: _fullAccess
                      ? FluentIcons.shield_dismiss_24_regular
                      : FluentIcons.shield_24_regular,
                  tip: !_canTogglePermission
                      ? 'AI 权限：先在 AI 设置中完成配置后可切换'
                      : _fullAccess
                          ? 'AI 权限：完全访问（修改不再弹确认框）· 点击切回变更前确认'
                          : 'AI 权限：变更前确认 · 点击切换为完全访问（不再弹确认框）',
                  onTap: _canTogglePermission ? _togglePermissionMode : null,
                  size: 15,
                ),
                const SizedBox(width: 2),
                _HoverIconBtn(
                  icon: FluentIcons.settings_24_regular,
                  tip: 'AI 设置',
                  onTap: widget.onOpenSettings,
                  size: 15,
                ),
                const SizedBox(width: 2),
                _HoverIconBtn(
                  icon: FluentIcons.delete_24_regular,
                  tip: '清空当前对话',
                  onTap: _clearChat,
                  size: 15,
                ),
              ],
            ),
          ),
        ),
        Divider(height: 1, color: palette.border),
        Expanded(
          child: Stack(
            children: [
              Positioned.fill(
                child: showWelcome
                    ? _WelcomeView(
                        fullAccess: _fullAccess,
                        onPick: (t) {
                          setState(() => _input.text = t);
                          _focusInput.requestFocus();
                        },
                      )
                    : NotificationListener<UserScrollNotification>(
                        onNotification: _handleUserScroll,
                        child: ListView.builder(
                          controller: _scroll,
                          padding: const EdgeInsets.all(12),
                          itemCount: _messages.length,
                          itemBuilder: (context, i) => _MessageBubble(
                            msg: _messages[i],
                            busy: _busy && i == _messages.length - 1,
                            onCopy: () => _copyText(_messages[i].text),
                            onRetry: _retry,
                          ),
                        ),
                      ),
              ),
              if (!showWelcome && !_followBottom)
                Positioned(
                  right: 16,
                  bottom: 10,
                  child: _JumpLatestButton(
                    onTap: () {
                      setState(() => _followBottom = true);
                      _scrollDown();
                    },
                  ),
                ),
            ],
          ),
        ),
        Divider(height: 1, color: palette.border),
        Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: Text('对话输入框：向 AI 提问或下达修改模组文件的指令，可附带 docx/txt/md/xlsx/png/jpg 附件',
                    style: TextStyle(fontSize: 11, color: palette.textMuted)),
              ),
              const SizedBox(height: 4),
              _buildInput(),
              if (_pendingAttachments.isNotEmpty || _uploading) ...[
                const SizedBox(height: 6),
                _buildPendingAttachments(),
              ],
              const SizedBox(height: 8),
              Row(
                children: [
                  _HoverIconBtn(
                    icon: FluentIcons.attach_24_regular,
                    tip: '上传附件（docx / txt / md / xlsx / png / jpg）',
                    onTap: _busy || _uploading ? null : _pickFiles,
                    size: 15,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(widget.settings.model.isEmpty
                        ? '未配置模型'
                        : '$_providerLabel · ${widget.settings.model}'
                            '${_fullAccess ? ' · 完全访问' : ''}',
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 11,
                            color: _fullAccess
                                ? palette.statusWarn
                                : palette.textHint)),
                  ),
                  if (_busy)
                    fluent.Button(
                      onPressed: _stop,
                      child: const Row(mainAxisSize: MainAxisSize.min, children: [
                        Icon(FluentIcons.stop_24_regular, size: 13),
                        SizedBox(width: 4),
                        Text('停止', style: TextStyle(fontSize: 12)),
                      ]),
                    )
                  else
                    ListenableBuilder(
                      listenable: _input,
                      builder: (context, _) {
                        final canSend = _input.text.trim().isNotEmpty ||
                            _pendingAttachments.isNotEmpty;
                        return fluent.FilledButton(
                          onPressed: canSend ? _send : null,
                          child: const Row(mainAxisSize: MainAxisSize.min, children: [
                            Icon(FluentIcons.send_24_regular, size: 13),
                            SizedBox(width: 4),
                            Text('发送', style: TextStyle(fontSize: 12)),
                          ]),
                        );
                      },
                    ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 历史会话列表视图：按更新时间降序，点击恢复、可删除、可新建、可搜索。
  Widget _buildHistoryView() {
    var sessions = List.of(_sessions)
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    final q = _historyQuery.trim().toLowerCase();
    if (q.isNotEmpty) {
      sessions = [
        for (final s in sessions)
          if (s.title.toLowerCase().contains(q) ||
              _HistoryTile._preview(s).toLowerCase().contains(q))
            s,
      ];
    }
    return Column(
      children: [
        Container(
          height: 38,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  onTap: _closeHistory,
                  child: Icon(FluentIcons.arrow_left_24_regular,
                      size: 15, color: palette.textPrimary),
                ),
              ),
              const SizedBox(width: 8),
              const Icon(FluentIcons.chat_history_24_regular,
                  size: 15, color: Color(0xFF6C5CE7)),
              const SizedBox(width: 8),
              Text('历史对话',
                  style: TextStyle(fontSize: 12, color: palette.textPrimary,
                      fontWeight: FontWeight.w600)),
              const Spacer(),
              MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  onTap: _newChat,
                  child: fluent.Tooltip(
                    message: '新建对话',
                    child: Padding(
                      padding: EdgeInsets.all(4),
                      child: Icon(FluentIcons.add_24_regular,
                          size: 14, color: palette.textMuted),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        Divider(height: 1, color: palette.border),
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 10, 10, 6),
          child: fluent.TextBox(
            controller: _historySearch,
            onChanged: (v) => setState(() => _historyQuery = v),
            placeholder: '搜索对话标题或内容关键词…',
          ),
        ),
        Expanded(
          child: sessions.isEmpty
              ? Center(
                  child: Text(
                      _historyQuery.trim().isEmpty ? '暂无历史对话' : '没有匹配的对话',
                      style: TextStyle(fontSize: 12, color: palette.textMuted)))
              : ListView.builder(
                  padding: const EdgeInsets.all(8),
                  itemCount: sessions.length,
                  itemBuilder: (context, i) => _HistoryTile(
                    session: sessions[i],
                    active: sessions[i] == _active,
                    onOpen: () => _switchSession(sessions[i]),
                    onDelete: () => _deleteSession(sessions[i]),
                  ),
                ),
        ),
      ],
    );
  }

  /// 待发送附件列表（横向排布，可逐个删除）。
  Widget _buildPendingAttachments() {
    return Align(
      alignment: Alignment.centerLeft,
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (final a in _pendingAttachments)
            _AttachmentChip(
              attachment: a,
              onRemove: () => setState(() => _pendingAttachments.remove(a)),
            ),
          if (_uploading)
            Padding(
              padding: EdgeInsets.symmetric(vertical: 4),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                SizedBox(width: 12, height: 12,
                    child: CircularProgressIndicator(strokeWidth: 1.5)),
                SizedBox(width: 6),
                Text('解析中…',
                    style: TextStyle(fontSize: 11, color: palette.textMuted)),
              ]),
            ),
        ],
      ),
    );
  }

  /// 多行输入框：Enter / 小键盘 Enter 发送，Shift+Enter 换行。
  Widget _buildInput() {
    return Focus(
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent &&
            (event.logicalKey == LogicalKeyboardKey.enter ||
                event.logicalKey == LogicalKeyboardKey.numpadEnter)) {
          if (!HardwareKeyboard.instance.isShiftPressed) {
            _send();
            return KeyEventResult.handled;
          }
        }
        return KeyEventResult.ignored;
      },
      child: fluent.TextBox(
        controller: _input,
        focusNode: _focusInput,
        minLines: 1,
        maxLines: 6,
        placeholder: '询问 AI，或让它修改模组文件…（Enter 发送，Shift+Enter 换行）',
      ),
    );
  }

  String get _providerLabel => switch (widget.settings.provider) {
        'anthropic' => 'Anthropic',
        'openai_responses' => 'OpenAI Responses',
        _ => 'OpenAI Compatible',
      };
}

// ---------------- 历史会话条目 ----------------

/// 历史会话列表条目：标题 + 最后消息预览 + 更新时间；点击恢复，可删除。
class _HistoryTile extends StatelessWidget {
  const _HistoryTile(
      {required this.session, required this.active,
      required this.onOpen, required this.onDelete});
  final AiSession session;
  final bool active;
  final VoidCallback onOpen;
  final VoidCallback onDelete;

  /// 最后一条非 system 消息的文本（附件优先显示文件名）作为预览。
  static String _preview(AiSession s) {
    for (var i = s.messages.length - 1; i >= 0; i--) {
      final m = s.messages[i];
      if (m.role == 'system') continue;
      if (m.attachments.isNotEmpty) {
        return '【附件】${m.attachments.map((a) => a.name).join('、')}';
      }
      final t = m.text.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (t.isNotEmpty) return t;
    }
    return '（空对话）';
  }

  static String _fmtTime(DateTime t) {
    final now = DateTime.now();
    final h = t.hour.toString().padLeft(2, '0');
    final min = t.minute.toString().padLeft(2, '0');
    if (t.year == now.year && t.month == now.month && t.day == now.day) {
      return '今天 $h:$min';
    }
    if (t.year == now.year) {
      final md = '${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
      return '$md $h:$min';
    }
    return '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        color: active ? palette.panel : palette.bgDeep,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
            color: active ? const Color(0xFF6C5CE7) : palette.border),
      ),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onOpen,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
            child: Row(
              children: [
                Icon(FluentIcons.chat_24_regular,
                    size: 14, color: palette.textMuted),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(session.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    fontSize: 12.5, color: palette.textPrimary,
                                    fontWeight: FontWeight.w600)),
                          ),
                          if (active) ...[
                            const SizedBox(width: 6),
                            const Text('当前',
                                style: TextStyle(
                                    fontSize: 10, color: Color(0xFF6C5CE7))),
                          ],
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(_preview(session),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 11, color: palette.textMuted)),
                      const SizedBox(height: 2),
                      Text(_fmtTime(session.updatedAt),
                          style: TextStyle(
                              fontSize: 10, color: palette.textHint)),
                    ],
                  ),
                ),
                const SizedBox(width: 4),
                MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    onTap: onDelete,
                    child: fluent.Tooltip(
                      message: '删除该对话',
                      child: Padding(
                        padding: EdgeInsets.all(4),
                        child: Icon(FluentIcons.delete_24_regular,
                            size: 13, color: palette.textMuted),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------- 当前目标模组指示 ----------------

/// 当前目标模组徽标：显示 AI 默认只修改哪个模组；未选择时给出醒目提示。
class _ModBadge extends StatelessWidget {
  const _ModBadge({required this.name});
  final String name;

  @override
  Widget build(BuildContext context) {
    final empty = name.isEmpty;
    return Container(
      height: 24,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: empty ? palette.tintWarn : palette.tintOk,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(
            color: empty ? const Color(0xFF6B4A2A) : palette.tintOk),
      ),
      child: Row(
        children: [
          Icon(empty ? FluentIcons.error_circle_24_regular : FluentIcons.box_24_regular,
              size: 11,
              color: empty ? palette.warning : palette.statusOk),
          const SizedBox(width: 5),
          Expanded(
            child: Text(
              empty ? '未选择模组（AI 无法修改）' : '目标模组：$name',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 11,
                  color: empty ? palette.warning : palette.statusOk),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------- 附件 chip ----------------

/// 附件标识 chip：类型图标 + 文件名 + 大小，可选删除按钮。
class _AttachmentChip extends StatelessWidget {
  const _AttachmentChip({required this.attachment, this.onRemove});
  final AiAttachment attachment;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final a = attachment;
    final isImage = a.kind == 'image';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: palette.bgDeep,
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: palette.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(isImage ? FluentIcons.image_24_regular : FluentIcons.document_24_regular,
              size: 12, color: const Color(0xFF6C5CE7)),
          const SizedBox(width: 5),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 160),
            child: Text(a.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: palette.textPrimary)),
          ),
          if (a.size > 0) ...[
            const SizedBox(width: 5),
            Text(AiAttachment.fmtSize(a.size),
                style: TextStyle(fontSize: 10, color: palette.textHint)),
          ],
          if (onRemove != null) ...[
            const SizedBox(width: 4),
            MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                onTap: onRemove,
                child: Icon(FluentIcons.dismiss_24_regular,
                    size: 11, color: palette.textMuted),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ---------------- 消息气泡 ----------------

class _MessageBubble extends StatelessWidget {
  const _MessageBubble(
      {required this.msg, required this.busy, required this.onCopy, required this.onRetry});
  final AiChatMessage msg;
  final bool busy;
  final VoidCallback onCopy;
  final VoidCallback onRetry;

  static String _fmtTime(DateTime t) {
    final h = t.hour.toString().padLeft(2, '0');
    final m = t.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  @override
  Widget build(BuildContext context) {
    if (msg.role == 'system') {
      return Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: palette.bgDeep,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: palette.border),
        ),
        child: Text(msg.text,
            style: TextStyle(fontSize: 12, color: palette.textMuted, height: 1.5)),
      );
    }
    final isUser = msg.role == 'user';
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Column(
        crossAxisAlignment: isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          if (isUser)
            // 只有用户发送的话需要气泡
            Container(
              constraints: BoxConstraints(
                  maxWidth: MediaQuery.of(context).size.width * 0.8),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xFF6C5CE7),
                borderRadius: BorderRadius.circular(8),
              ),
              child: SelectableText(msg.text,
                  style: TextStyle(
                      fontSize: 13, color: palette.textHigh, height: 1.5)),
            )
          else ...[
            // AI 回复/工具调用情况：无气泡
            // round==0 的工具调用没有前置过渡文本，先展示卡片
            for (final t in msg.toolRecords.where((r) => r.round == 0))
              _ToolCard(rec: t),
            // 按轮次交错：过渡文本（工具调用情况，弱化显示）→ 该轮工具卡片
            for (var i = 0; i < msg.toolRoundTexts.length; i++) ...[
              if (msg.toolRoundTexts[i].trim().isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(msg.toolRoundTexts[i],
                      style: TextStyle(
                          fontSize: 12, color: palette.textMuted, height: 1.5)),
                ),
              for (final t in msg.toolRecords.where((r) => r.round == i + 1))
                _ToolCard(rec: t),
            ],
            // 最终回复：直接渲染 markdown，不带气泡背景
            Padding(
              padding: const EdgeInsets.only(top: 2, right: 8),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                    maxWidth: MediaQuery.of(context).size.width * 0.9),
                child: _MdView(data: msg.text, busy: busy),
              ),
            ),
          ],
          // 附件标识（文本内容已并入消息；图片仅展示文件名）
          if (msg.attachments.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  for (final a in msg.attachments)
                    _AttachmentChip(attachment: a),
                ],
              ),
            ),
          // 元信息：时间戳 + 复制
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(_fmtTime(msg.time),
                    style: TextStyle(fontSize: 10.5, color: palette.textHint)),
                const SizedBox(width: 8),
                MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    onTap: onCopy,
                    child: Icon(FluentIcons.copy_24_regular,
                        size: 12, color: palette.textHint),
                  ),
                ),
              ],
            ),
          ),
          if (msg.error != null)
            Container(
              margin: const EdgeInsets.only(top: 6),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: palette.tintDanger,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text('⚠ ${msg.error}',
                        style: TextStyle(fontSize: 12, color: palette.statusDanger)),
                  ),
                  const SizedBox(width: 8),
                  MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: GestureDetector(
                      onTap: onRetry,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: palette.tintDanger,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text('重试',
                            style: TextStyle(fontSize: 11, color: palette.statusDanger)),
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

// ---------------- Markdown 渲染 ----------------

MarkdownStyleSheet _mdStyle() => MarkdownStyleSheet(
  p: TextStyle(fontSize: 13, color: palette.textBody, height: 1.55),
  h1: TextStyle(fontSize: 16, color: palette.textHigh, fontWeight: FontWeight.w700),
  h2: TextStyle(fontSize: 15, color: palette.textHigh, fontWeight: FontWeight.w700),
  h3: TextStyle(fontSize: 14, color: palette.textHigh, fontWeight: FontWeight.w600),
  h4: TextStyle(fontSize: 13.5, color: palette.textHigh, fontWeight: FontWeight.w600),
  strong: TextStyle(fontWeight: FontWeight.w700, color: palette.textHigh),
  em: const TextStyle(fontStyle: FontStyle.italic),
  code: TextStyle(
      fontFamily: 'Consolas', fontSize: 12, color: palette.statusTan,
      backgroundColor: palette.bgDeep),
  codeblockPadding: EdgeInsets.zero,
  codeblockDecoration: const BoxDecoration(),
  blockSpacing: 8,
  listBullet: TextStyle(fontSize: 13, color: palette.textSecondary),
  listIndent: 18,
  blockquote: TextStyle(fontSize: 13, color: palette.textSecondary, height: 1.5),
  blockquoteDecoration: BoxDecoration(
    color: palette.panel,
    border: Border(left: BorderSide(color: Color(0xFF6C5CE7), width: 3)),
  ),
  horizontalRuleDecoration: BoxDecoration(
      border: Border(top: BorderSide(color: palette.border))),
  tableHead: TextStyle(fontSize: 12, color: palette.textBody, fontWeight: FontWeight.w600),
  tableBody: TextStyle(fontSize: 12, color: palette.textMid),
  tableBorder: TableBorder(
    horizontalInside: BorderSide(color: palette.border),
    verticalInside: BorderSide(color: palette.border),
    top: BorderSide(color: palette.border),
    bottom: BorderSide(color: palette.border),
    left: BorderSide(color: palette.border),
    right: BorderSide(color: palette.border),
  ),
);

/// Markdown 渲染视图：支持代码块（带语言标签与复制按钮）与流式"思考中"动画。
///
/// 不依赖 flutter_markdown 的自定义 builder（0.7.7 对覆盖内建 block tag 存在断言缺陷），
/// 而是预处理拆分 fenced code block，代码块用 [_CodeBlockCard] 渲染，
/// 其余段落交给 MarkdownBody 默认渲染。
class _MdView extends StatelessWidget {
  const _MdView({required this.data, required this.busy});
  final String data;
  final bool busy;

  static final _fenceRe =
      RegExp(r'```([\w+#-]*)[ \t]*\n?([\s\S]*?)```', multiLine: true);
  static final _openFenceRe =
      RegExp(r'```([\w+#-]*)[ \t]*\n?([\s\S]*)$', multiLine: true);

  @override
  Widget build(BuildContext context) {
    final text = data.trim();
    if (text.isEmpty) {
      return busy ? const _TypingDots() : const SizedBox.shrink();
    }
    final segments = _split(text);
    if (segments.length == 1) {
      return MarkdownBody(
          data: text, selectable: true, styleSheet: _mdStyle());
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final seg in segments)
          if (seg is _CodeSeg)
            _CodeBlockCard(code: seg.code, lang: seg.lang)
          else
            MarkdownBody(
                data: (seg as String).trim().isEmpty ? ' ' : seg,
                selectable: true,
                styleSheet: _mdStyle()),
      ],
    );
  }

  /// 将文本拆分为 [markdown 文本段, 代码块段] 交替序列；未闭合的 fence 视为代码块预览。
  List<Object> _split(String text) {
    final out = <Object>[];
    var last = 0;
    for (final m in _fenceRe.allMatches(text)) {
      if (m.start > last) out.add(text.substring(last, m.start));
      out.add(_CodeSeg(m.group(2) ?? '', m.group(1) ?? ''));
      last = m.end;
    }
    if (last < text.length) {
      final rest = text.substring(last);
      final open = _openFenceRe.firstMatch(rest);
      if (open != null) {
        out.add(_CodeSeg(open.group(2) ?? '', open.group(1) ?? ''));
      } else if (rest.trim().isNotEmpty) {
        out.add(rest);
      }
    }
    return out;
  }
}

/// 一个 fenced code block 片段。
class _CodeSeg {
  const _CodeSeg(this.code, this.lang);
  final String code;
  final String lang;
}

/// 代码块卡片：深色背景 + 语言标签 + 复制按钮 + 横向滚动。
class _CodeBlockCard extends StatelessWidget {
  const _CodeBlockCard({required this.code, required this.lang});
  final String code;
  final String lang;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        color: palette.bgDeep,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: palette.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (lang.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 6, 6, 0),
              child: Row(
                children: [
                  Text(lang,
                      style: TextStyle(
                          fontSize: 10.5, color: palette.textMuted,
                          fontFamily: 'Consolas')),
                  const Spacer(),
                  MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: GestureDetector(
                      onTap: () =>
                          Clipboard.setData(ClipboardData(text: code)),
                      child: Padding(
                        padding: EdgeInsets.all(4),
                        child: Icon(FluentIcons.copy_24_regular,
                            size: 12, color: palette.textMuted),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: SelectableText(code,
                  style: TextStyle(
                      fontFamily: 'Consolas', fontSize: 11.5, height: 1.45,
                      color: palette.textPrimary)),
            ),
          ),
        ],
      ),
    );
  }
}

/// 流式"思考中"三点动画。
class _TypingDots extends StatefulWidget {
  const _TypingDots();
  @override
  State<_TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<_TypingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 900))
    ..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 22,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('思考中',
              style: TextStyle(fontSize: 12, color: palette.textMuted)),
          const SizedBox(width: 6),
          for (var i = 0; i < 3; i++)
            AnimatedBuilder(
              animation: _c,
              builder: (context, _) {
                final phase = ((_c.value * 3 - i) % 3 + 3) % 3;
                final opacity = 0.25 + 0.75 * (1 - phase).clamp(0.0, 1.0);
                return Padding(
                  padding: const EdgeInsets.only(right: 3),
                  child: Opacity(
                    opacity: opacity,
                    child: Container(
                      width: 5,
                      height: 5,
                      decoration: BoxDecoration(
                        color: palette.textSecondary,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                );
              },
            ),
        ],
      ),
    );
  }
}

// ---------------- 工具卡片 ----------------

class _ToolCard extends StatefulWidget {
  const _ToolCard({required this.rec});
  final ToolRecord rec;
  @override
  State<_ToolCard> createState() => _ToolCardState();
}

class _ToolCardState extends State<_ToolCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final rec = widget.rec;
    final args = jsonEncode(rec.arguments);
    // 自适应宽度：填充可用宽度并设上限，窄侧栏（最小 280）不再溢出。
    return Container(
      margin: const EdgeInsets.only(top: 6),
      width: double.infinity,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: palette.bgDeep,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: rec.approved ? palette.border : const Color(0xFF7A4A2A)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                rec.name.startsWith('update_') ||
                        rec.name.startsWith('create_') ||
                        rec.name.startsWith('delete_')
                    ? FluentIcons.edit_24_regular
                    : rec.name == 'get_domain_item'
                        ? FluentIcons.document_search_24_regular
                        : rec.name == 'list_domain_items'
                            ? FluentIcons.list_24_regular
                            : rec.name == 'list_domains'
                                ? FluentIcons.apps_24_regular
                                : FluentIcons.folder_open_24_regular,
                size: 13,
                color: rec.approved ? const Color(0xFF6C5CE7) : palette.warning,
              ),
              const SizedBox(width: 6),
              Text(rec.name,
                  style: TextStyle(fontSize: 12, color: palette.textPrimary,
                      fontWeight: FontWeight.w600)),
              const Spacer(),
              if (!rec.approved)
                Text('已拒绝', style: TextStyle(fontSize: 11, color: palette.warning)),
              if (rec.result != null || args.isNotEmpty) ...[
                const SizedBox(width: 6),
                MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    onTap: () => setState(() => _expanded = !_expanded),
                    child: Icon(_expanded
                            ? FluentIcons.chevron_up_24_regular
                            : FluentIcons.chevron_down_24_regular,
                        size: 12, color: palette.textMuted),
                  ),
                ),
              ],
            ],
          ),
          // 默认只展示工具名称；展开后才显示参数与结果
          if (_expanded) ...[
            const SizedBox(height: 4),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Text(args,
                  style: TextStyle(
                      fontFamily: 'Consolas', fontSize: 11, color: palette.textMuted)),
            ),
            if (rec.images.isNotEmpty) ...[
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final p in rec.images) _ModImageThumb(path: p),
                ],
              ),
            ],
            if (rec.result != null)
              Container(
                margin: const EdgeInsets.only(top: 6),
                padding: const EdgeInsets.all(6),
                width: double.infinity,
                decoration: BoxDecoration(
                  color: palette.bgDeep,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Text(rec.result!,
                      style: TextStyle(
                          fontFamily: 'Consolas', fontSize: 11,
                          color: palette.textSecondary)),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

/// 模组内图片缩略图：按相对路径从后端读取 base64 后展示，点击可查看大图。
class _ModImageThumb extends StatefulWidget {
  const _ModImageThumb({required this.path});
  final String path;
  @override
  State<_ModImageThumb> createState() => _ModImageThumbState();
}

class _ModImageThumbState extends State<_ModImageThumb> {
  Uint8List? _bytes;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await ApiClient.instance.get('/api/tools/read',
          query: {'scope': 'mod', 'path': widget.path});
      final b64 = r['base64'] as String?;
      if (b64 == null || b64.isEmpty) throw Exception('not an image');
      if (!mounted) return;
      setState(() => _bytes = base64Decode(b64));
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    if (bytes == null) {
      return Container(
        width: 88,
        height: 88,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: palette.bgDeep,
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: palette.border),
        ),
        child: _failed
            ? Icon(FluentIcons.image_off_24_regular,
                size: 16, color: palette.textHint)
            : const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 1.5)),
      );
    }
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => _preview(context, bytes),
        child: Tooltip(
          message: '${widget.path}（点击放大）',
          child: Container(
            width: 88,
            height: 88,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: palette.border),
              image: DecorationImage(
                image: MemoryImage(bytes),
                fit: BoxFit.cover,
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 点击缩略图弹出大图预览。
  void _preview(BuildContext context, Uint8List bytes) {
    showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) {
        final size = MediaQuery.sizeOf(ctx);
        return fluent.ContentDialog(
        title: Text(widget.path),
        content: SizedBox(
          width: min(640, size.width - 48),
          height: min(480, size.height * 0.72),
          child: Center(
            child: InteractiveViewer(
              minScale: 0.2,
              maxScale: 6,
              child: Image.memory(bytes),
            ),
          ),
        ),
        actions: [
          fluent.Button(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭'),
          ),
        ],
      );
    });
  }
}

// ---------------- 顶栏悬停图标按钮 ----------------

/// 顶栏小图标：悬停高亮背景 + 变亮，禁用时置灰；统一尺寸与提示样式。
class _HoverIconBtn extends StatefulWidget {
  const _HoverIconBtn({
    required this.icon,
    required this.tip,
    this.onTap,
    this.size = 15.0,
  });
  final IconData icon;
  final String tip;
  final VoidCallback? onTap;
  final double size;

  @override
  State<_HoverIconBtn> createState() => _HoverIconBtnState();
}

class _HoverIconBtnState extends State<_HoverIconBtn> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    final color = !enabled
        ? palette.textFaint
        : (_hover ? palette.textBody : palette.textMuted);
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          padding: const EdgeInsets.all(5),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(5),
            color: _hover && enabled ? palette.card : Colors.transparent,
          ),
          child: fluent.Tooltip(
            message: widget.tip,
            child: Icon(widget.icon, size: widget.size, color: color),
          ),
        ),
      ),
    );
  }
}

// ---------------- 回到最新 ----------------

/// 流式输出期间用户上翻后出现的悬浮胶囊，点击回到最新内容并恢复自动跟随。
class _JumpLatestButton extends StatefulWidget {
  const _JumpLatestButton({required this.onTap});
  final VoidCallback onTap;

  @override
  State<_JumpLatestButton> createState() => _JumpLatestButtonState();
}

class _JumpLatestButtonState extends State<_JumpLatestButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: _hover ? palette.surface : palette.card,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: palette.borderHover),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.35),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(FluentIcons.arrow_down_24_regular,
                size: 12, color: palette.accentLighter),
            SizedBox(width: 4),
            Text('回到最新',
                style: TextStyle(fontSize: 11, color: palette.textPrimary)),
          ]),
        ),
      ),
    );
  }
}

// ---------------- 空会话欢迎视图 ----------------

/// 新对话的欢迎引导：能力说明 + 可一键填入输入框的示例指令。
class _WelcomeView extends StatelessWidget {
  const _WelcomeView({required this.onPick, this.fullAccess = false});
  final ValueChanged<String> onPick;
  final bool fullAccess;

  static const _suggestions = <String>[
    '帮我看看剧情里有哪些事件',
    '把事件 320101 的标题改成 xxx',
    '给人物 102 换一句自我介绍',
    '把背景 5 换成另一张图',
    '让薛诗蕾滑动入场到左侧，表情开心，然后滑动退场',
    '生成一张夏日校园操场背景图',
  ];

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 340),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                width: 44,
                height: 44,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: const Color(0x296C5CE7),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0x556C5CE7)),
                ),
                child: Icon(FluentIcons.bot_24_regular,
                    size: 22, color: palette.accentLighter),
              ),
              const SizedBox(height: 12),
              Text('AI 助手已就绪',
                  style: TextStyle(fontSize: 15, color: palette.textHigh,
                      fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              Text(
                '我可以直接读取并修改当前模组内容（剧情、人物、舞台调度、配图等）。'
                '${fullAccess ? '当前为完全访问模式：修改会直接执行，不再弹出确认框。' : '所有修改都会先展示改动并等你确认。'}',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: palette.textMuted, height: 1.6),
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: [
                  for (final s in _suggestions) _SuggestChip(text: s, onTap: () => onPick(s)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 示例指令 chip：悬停高亮，点击把指令填入输入框。
class _SuggestChip extends StatefulWidget {
  const _SuggestChip({required this.text, required this.onTap});
  final String text;
  final VoidCallback onTap;

  @override
  State<_SuggestChip> createState() => _SuggestChipState();
}

class _SuggestChipState extends State<_SuggestChip> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: _hover ? palette.panel : Colors.transparent,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
                color: _hover ? const Color(0xFF6C5CE7) : palette.surface),
          ),
          child: Text(widget.text,
              style: TextStyle(fontSize: 11.5,
                  color: _hover ? palette.accentPale : palette.textMid)),
        ),
      ),
    );
  }
}
