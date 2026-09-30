/// AI 聊天的纯数据模型：附件、消息、工具调用记录、会话。
///
/// 从 ai_panel.dart 拆出；序列化格式与 SharedPreferences 存储 key 保持兼容。
library;

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

  Map<String, dynamic> toMetaJson() => {
    'name': name,
    'kind': kind,
    'size': size,
  };

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
  AiChatMessage({
    required this.role,
    this.text = '',
    List<ToolRecord>? toolRecords,
    List<String>? toolRoundTexts,
    List<AiAttachment>? attachments,
    this.error,
    DateTime? time,
  }) : toolRecords = toolRecords ?? [],
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
        (j['time'] as num?)?.toInt() ?? DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }
}

/// 一次工具调用记录。
class ToolRecord {
  ToolRecord({
    required this.name,
    required this.arguments,
    this.result,
    this.approved = true,
    this.round = 0,
    List<String>? images,
  }) : images = images ?? [];
  final String name;
  final Map<String, dynamic> arguments;
  String? result;
  bool approved;

  /// 所属工具轮次：0 表示没有前置过渡文本；否则对应
  /// AiChatMessage.toolRoundTexts 中下标 round-1 的过渡文本。
  final int round;

  /// 生图/改图工具保存到模组内的图片相对路径（用于卡片缩略图预览）。
  final List<String> images;

  /// 执行开始时刻与耗时（毫秒）。仅存内存、不参与序列化：
  /// 恢复的历史消息无计时（工具卡不显示耗时），阶段 3d 运行态/耗时展示用。
  DateTime? startedAt;
  int? durationMs;

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
/// 会话的 messages/history 与控制器当前视图共享引用：
/// 切换会话时控制器直接把当前视图绑定到目标会话的列表上。
class AiSession {
  AiSession({
    required this.id,
    String? title,
    DateTime? createdAt,
    DateTime? updatedAt,
    List<AiChatMessage>? messages,
    List<Map<String, dynamic>>? history,
  }) : title = title ?? '新对话',
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
        (j['createdAt'] as num?)?.toInt() ??
            DateTime.now().millisecondsSinceEpoch,
      ),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(
        (j['updatedAt'] as num?)?.toInt() ??
            DateTime.now().millisecondsSinceEpoch,
      ),
      messages: msgs,
      history: [
        for (final h in (j['history'] as List? ?? []))
          if (h is Map) h.cast<String, dynamic>(),
      ],
    );
  }
}
