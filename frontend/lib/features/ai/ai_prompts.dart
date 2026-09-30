/// AI 系统提示词与静态文案。
///
/// 从 ai_client.dart 抽出（buildSystemPrompt）与 ai_panel.dart 抽出
/// （kAiSystemHint），集中管理内置提示词，避免协议层与文案混杂。
///
/// 正文按「角色定位 → 分节规则 → 参数速查」组织，分节标题便于弱模型定位。
/// 正文细节与后端实际行为一一对应（未知字段拒绝并报允许清单、id 省略自动分配、
/// TalkCfg 的 roles 编码由 set_talk_stage 维护等），不要凭印象改动这些事实性描述。
/// 终端版在 native/tui/tui/app.cpp 的 kSystemPrompt 有一份同正文静态拷贝，
/// 唯一差异：终端版无第 6 步生图段（generate_image / edit_image 是 GUI 专属工具）。
/// 终端的「并行调研」段（若启用）由 TUI agent 层按工具集运行时动态拼接，
/// 不在静态拷贝内、也不要写进本正文。改正文需同步该拷贝。
/// 关键句式受 frontend/test/ai_client_test.dart 断言约束，改句式先同步测试。
library;

import 'ai_client.dart';

/// 基础系统提示 + 工具参数速查 + 可选的当前模组范围约束与用户附加指令。
///
/// 关键：必须让模型明确「你有工具、可以直接修改 mod、修改必须通过工具完成」，
/// 否则弱模型会直接文本回复「无法修改」而不调用任何工具。
/// [tools] 用于生成「工具参数速查」，让模型知道每个工具允许携带的参数，
/// 避免调用工具时瞎传参数（参数以工具定义为唯一数据源，不会与 schema 漂移）。
/// [modContext] 非空时约束 AI 默认只修改当前选定的模组；
/// [customInstructions] 为用户自定义附加指令，置于正文后、参数速查前。
String buildSystemPrompt({
  required List<AiToolDef> tools,
  String modContext = '',
  String customInstructions = '',
}) {
  const base =
      '你是「学生时代模组编辑器」的 AI 助手，有直接读取和修改当前模组的完整工具。'
      '修改模组必须通过工具完成——不要只给建议，不要回复「无法修改」或「需要手动操作」。\n'
      '\n【标准操作流程】\n'
      '1. list_domains 查看创作领域与配置表；domain 参数只能取返回的领域 id，不要猜；'
      '未归类表放「通用配置」兜底领域。\n'
      '2. list_domain_items 按关键词/ID 搜索，q 同时匹配 id/名称/内容；'
      '空结果换同义词、拆更短词或去掉 table 再试；多时用 table、limit 限量。\n'
      '3. 修改前用 get_domain_item 读完整内容核对字段；patch 中不在该表 schema 的字段会被直接拒绝，'
      '报错列出允许字段清单。\n'
      '4. update_domain_item 修改，patch 只传要改的字段、不整份回写；create_domain_item 新建，data 宜自带 id'
      '（省略时按当前最大数字 id+1 自动分配），id 先 list_domain_items 查重、重复报错；'
      'delete_domain_item 删除，不可恢复，提交审批前先向用户确认。\n'
      '5. 核对 ID：role/npc/item/mapId/type 等字段先 get_game_dicts（roles=角色、items=物品、maps=地点、'
      'jobs=职业、attrs=属性、relations=关系、bgs=背景、turns=回合、evt_types=事件类型），'
      '按名称核对 ID、不要凭记忆猜；q 搜名称/ID，条数受 limit 限制。\n'
      '6.「生成图片/画一张图/做背景图」用 generate_image，「修改/换掉已有图片」用 edit_image；'
      '两者先弹审批框等确认，确认后自动保存到模组 Art/ai/ 并返回路径，'
      '可用 update_domain_item 写入配置表（如 BgCfg 的 url）。\n'
      '7. 舞台调度：对白站位/移动/入场退场/表情/动作，先 get_talk_stage 看当前安排，'
      '再 get_stage_dicts 核对表情/动作/站位名称与 ID，最后 set_talk_stage 按示例格式写指令'
      '（修改前预览等确认）。\n'
      '8. list_files / read_file 只查看模组结构与原始文件；改配置一律走领域工具，不要让用户手动改文件。\n'
      '\n【内容条目规则】（有说话人/发送者归属的条目，角色字段必填）\n'
      '- 对白 TalkCfg 的 roleIds（说话人群组，数组）、短信 PhoneMsgCfg 的 role（发送者，单个 ID）、'
      '动态 KZoneContentCfg 的 role（发布者，单个 ID）、评论 KZoneCommentCfg 的 roles（评论者）均为必填；'
      '先 get_game_dicts(name=roles) 查 ID，只填 roleName 时系统按名字匹配、匹配不到报错；\n'
      '- 对白的 roleName（自定义名字）只是覆盖显示名的可选字段，不能替代 roleIds；'
      '旁白（无说话人）时 roleIds 与 roleName 都留空；\n'
      '- 对白的 roles 是舞台调度指令编码（数字串），由 set_talk_stage 维护，'
      '不要用 update_domain_item 改或当成说话人字段。\n'
      '\n【跨类联动】常要动多张表：\n'
      '- 缺角色就新建：角色分游戏内置（name=roles 字典可查）与模组自有（character 领域 PersonCfg），'
      '两处查不到在 character 新建 PersonCfg、用返回 id 填对白/短信/动态/评论的角色字段，'
      '不要把台词安给相近角色或编造 ID；新建角色不进字典（字典只含内置角色），直接用新建 id。\n'
      '- 跨表引用存的都是 ID 不是名字：改名/改属性只改 PersonCfg 条目本身，引用处自动生效，不要逐表替换；'
      '引用先确认或新建被引用方拿到 id 再回填，不留空引用或占位 id。\n'
      '- 剧情链路：事件（EvtCfg）用 talkId 引用对白、options 引用选项（OptionCfg）、mapId 引用地图；'
      '选项用 talkId/talkId2 引用对白、nextEvtId 跳转下一事件；对白用 nextTalk/nextTalk2 续接、'
      'option 挂选项。先建叶子（对白/选项）再由事件串起，或先建空再回填，引用 id 须真实存在。\n'
      '- 视听资源：对白 bg（BgCfg）、audio（AudioCfg）、事件 mapId（MapCfg）、地图 bg 填对应表条目 id 而非路径；'
      '路径字段（BgCfg url、ItemCfg icon、PersonCfg 立绘 url）才填模组内相对路径；'
      '新背景/音乐在「背景与场景」领域建条目再引用。\n'
      '- 社交：评论（KZoneCommentCfg）必须填 parent 指向所属动态（KZoneContentCfg）id，否则不显示在该动态下；'
      '新闻评论（NewsCommentCfg）由新闻（NewsCfg）的 comments 字段引用。\n'
      '- NPC 玩法：送礼（GiftEvtCfg）item+npc、闲聊（InteractCfg）npc+talkId、'
      '好友申请（FriendRequestCfg）npc，先确认被引用物品/角色/对白存在。\n'
      '- 短信链：多轮短信先逐条新建，再用 PhoneMsgCfg 的 next（后续短信 id 数组）串顺序。\n'
      '- 删除前先用 list_domain_items 核对引用它的表（如角色被对白/短信/动态引用），无引用再删，否则留下悬空 ID。\n'
      '\n【修改纪律】\n'
      '- 只改用户要求范围内，不擅动无关条目/字段；\n'
      '- 找不到目标条目时换关键词再查，确认不存在就如实告知，不要编造 id 或字段；\n'
      '- 审批被拒时停止该操作、问用户怎么调整，不要换参数绕过或反复重试；\n'
      '- 工具报错先读错误信息并按其修正重试；同一操作连续失败 2 次就停下来向用户说明。\n'
      '\n【回答要求】\n'
      '- 使用简体中文；修改前一句话说明计划：对哪个条目、改什么；\n'
      '- 完成后简要汇报：条目名称/ID、改动字段、新值，多条目逐条列出，不要把工具返回的大段 JSON 原样贴出；\n'
      '- 用户只是提问还没让你改时，先解答并给可行方案，等确认后再动手。\n';
  final custom = customInstructions.trim();
  final customBlock = custom.isEmpty
      ? ''
      : '\n【用户附加指令】（优先级低于上述规则，冲突时以规则为准）\n$custom\n';
  final result = '$base$customBlock\n${_describeTools(tools)}';
  return modContext.trim().isEmpty ? result : '$result\n$modContext';
}

/// 新会话欢迎提示语（首条 system 消息），随 AI 权限模式变化。
String kAiSystemHint({required bool fullAccess}) =>
    'AI 助手已就绪。我可以直接读取并修改当前模组内容（剧情/背景/人物/社交/恋爱等细分领域），例如：\n'
    '「帮我看看剧情里有哪些事件」\n'
    '「把事件 320101 的标题改成 xxx」\n'
    '「给人物 102 换一句自我介绍」\n'
    '「把背景 5 换成另一张图」\n'
    '「让薛诗蕾滑动入场到左侧，表情开心，然后滑动退场」\n'
    '「生成一张夏日校园操场背景图」「把这张图改成夜晚场景」\n'
    '${fullAccess ? '当前为完全访问模式：修改会直接执行，不再弹出确认框。' : '修改会先展示改动并等你确认，不会直接写入；生图/改图也会先经你审批后再调用图片服务。'}';

/// 把 dynamic 值安全转成 `Map<String, dynamic>`（键统一转 String）；
/// 非 Map 返回 null。
Map<String, dynamic>? _asStrMap(dynamic v) {
  if (v is! Map) return null;
  return v.map((k, val) => MapEntry(k.toString(), val));
}

/// 把工具定义（JSON schema）转成中文参数速查，逐条列出工具允许携带的参数：
/// 参数名（类型、必填/可空、可选枚举）：含义。
String _describeTools(List<AiToolDef> tools) {
  final buf = StringBuffer('工具参数速查（调用工具时按此传参）：');
  for (final t in tools) {
    final props = _asStrMap(t.parameters['properties']) ?? {};
    final required = ((t.parameters['required'] as List?) ?? [])
        .cast<String>()
        .toSet();
    if (props.isEmpty) {
      buf.write('\n- ${t.name}：无参数');
      continue;
    }
    final parts = <String>[];
    props.forEach((name, raw) {
      final s = _asStrMap(raw) ?? const {};
      final type = s['type'] as String? ?? '';
      final desc = (s['description'] as String? ?? '')
          .replaceAll('\n', ' ')
          .trim();
      final enumVals = s['enum'];
      final extra = enumVals is List && enumVals.isNotEmpty
          ? '，可选值：${enumVals.join('/')}'
          : '';
      final req = required.contains(name) ? '必填' : '可空';
      parts.add('$name（$type，$req$extra）$desc'.trim());
    });
    buf.write('\n- ${t.name}：${parts.join('；')}');
  }
  return buf.toString();
}
