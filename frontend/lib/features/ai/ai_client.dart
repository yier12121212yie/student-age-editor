import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../settings/settings_page.dart';

/// AI 工具定义（OpenAI function / Anthropic tool 的公共形态）。
class AiToolDef {
  const AiToolDef({required this.name, required this.description, this.parameters = const {}});
  final String name;
  final String description;
  final Map<String, dynamic> parameters;
}

/// 一次工具调用（由模型发起）。
class AiToolCall {
  AiToolCall({required this.id, required this.name, required this.arguments});
  final String id;
  final String name;
  final Map<String, dynamic> arguments;
}

/// 流式回调集合。
class AiCallbacks {
  AiCallbacks({this.onText, this.onToolRoundText, this.onToolCall, this.onToolResult, this.onDone});
  /// 流式文本增量（所有轮次都会实时上报，包括以工具调用结束的轮次；
  /// UI 依赖 onToolRoundText 把这些轮次的文本从最终回复中拆出）。
  final void Function(String delta)? onText;
  /// 以工具调用结束的轮次所输出的整段过渡文本（执行工具前一次性上报；
  /// 该轮没有文本时传空字符串，用于标记轮次边界）。
  final void Function(String text)? onToolRoundText;
  /// 返回工具执行结果（字符串）。
  final Future<String> Function(AiToolCall call)? onToolCall;
  final void Function(String name, String result)? onToolResult;
  final void Function()? onDone;
}

class AiClientException implements Exception {
  AiClientException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 三协议 AI 客户端（OpenAI Compatible / OpenAI Responses / Anthropic Compatible）。
/// 统一接口：一次 send 完成「模型生成 → 工具调用 → 继续生成」的循环。
class AiClient {
  AiClient(this.settings, {this.modContext = ''});
  final AiSettings settings;
  /// 当前工作范围提示（如「当前模组：xxx」），非空时追加到系统提示，
  /// 用于约束 AI 默认只修改当前选定的模组。
  final String modContext;

  /// 基础系统提示 + 工具参数速查 + 可选的当前模组范围约束。
  ///
  /// 关键：必须让模型明确「你有工具、可以直接修改 mod、修改必须通过工具完成」，
  /// 否则弱模型会直接文本回复「无法修改」而不调用任何工具。
  /// [tools] 用于生成「工具参数速查」，让模型知道每个工具允许携带的参数，
  /// 避免调用工具时瞎传参数（参数以 _tools 定义为唯一数据源，不会与 schema 漂移）。
  ///
  /// 正文按「角色定位 → 分节规则 → 参数速查」组织，分节标题便于弱模型定位。
  /// 正文细节与后端实际行为一一对应（未知字段拒绝、id 自动分配、TalkCfg 的
  /// roles 编码由 set_talk_stage 维护等），不要凭印象改动这些事实性描述。
  /// 与 backend/editor/agent/prompt.py（终端/Android）逐字对齐，差异只有两处：
  /// 本端多第 6 步生图段落（generate_image / edit_image 是 GUI 专属工具）；
  /// 终端版多了按工具集动态拼入的「并行调研」段落（本端无 spawn_subagents）。
  /// 关键句式受 frontend/test/ai_client_test.dart 断言约束，改句式先同步测试。
  String _systemPrompt(List<AiToolDef> tools) {
    final base = '你是「学生时代模组编辑器」的 AI 助手，拥有直接读取和修改当前模组内容的完整工具。'
        '修改模组必须通过工具完成——不要只给建议，不要回复「无法修改」或「需要手动操作」。\n'
        '\n【标准操作流程】每一步都是先看清楚、再动手：\n'
        '1. 定位领域：先调用 list_domains 查看可修改的创作领域（剧情/背景/人物/社交/恋爱等）'
        '及各领域包含的配置表；后续所有工具的 domain 参数只能取这里返回的领域 id，不要猜；'
        '未归入其他领域的配置表统一放在「通用配置」兜底领域里。\n'
        '2. 找条目：用 list_domain_items 在目标领域按关键词/ID 找条目，q 会同时匹配 id/名称/内容；'
        '结果为空通常是关键词不合适——换同义词、拆成更短的词、或去掉 table 限定再试；'
        '条目很多时用 table 限定单表、limit 控制返回数量。\n'
        '3. 读原文：修改前必须先用 get_domain_item 读取条目完整内容，确认字段名与当前值；'
        'patch 里的字段名必须与读到的完全一致——不在该表 schema 里的字段会被直接拒绝，'
        '报错信息会列出允许的字段清单。\n'
        '4. 动手改：修改用 update_domain_item，patch 只传要改的字段，其余字段保持不动，'
        '不要把读到的整份内容原样回写；新建用 create_domain_item，data 建议自带 id'
        '（省略时系统按当前最大数字 id+1 自动分配），指定 id 前先 list_domain_items 查重，'
        '重复会报错；删除用 delete_domain_item，不可恢复，提交审批前先向用户确认清楚。\n'
        '5. 核对 ID：填写 role/npc/item/mapId/type 等 ID 字段前，先用 get_game_dicts 查询游戏字典'
        '（roles=角色、items=物品、maps=地点、jobs=职业、attrs=属性、relations=关系、bgs=背景、'
        'turns=回合、evt_types=事件类型），按名称核对出正确 ID 再填，不要凭记忆或猜测填数字；'
        '字典可用 q 按名称/ID 搜索，返回条数受 limit 限制。\n'
        '6. 用户要求「生成图片 / 画一张图 / 做背景图」时用 generate_image，要求「修改/换掉某张已有图片」时用 edit_image；'
        '两者都会先弹出审批框等待用户确认，确认后图片自动保存到模组 Art/ai/ 目录并返回路径，'
        '可用 update_domain_item 把路径写入配置表（如 BgCfg 的 url 字段）\n'
        '7. 舞台调度：需要调整对白的人物站位/移动/入场退场/表情/动作时，先 get_talk_stage 查看'
        '当前舞台安排，再用 get_stage_dicts 核对表情/动作/站位的名称与 ID，'
        '最后用 set_talk_stage 按其示例格式写指令（修改前会先展示改动预览等用户确认）。\n'
        '8. 文件只读：list_files / read_file 只用于查看模组目录结构和原始文件，不改文件；'
        '修改配置内容一律走领域工具，不要让用户手动改文件。\n'
        '\n【内容条目规则】（有说话人/发送者归属的条目，角色字段必填）\n'
        '- 对白 TalkCfg 的 roleIds（说话人群组）、短信 PhoneMsgCfg 的 role（发送者）、'
        '空间动态 KZoneContentCfg 的 role（发布者）、空间评论 KZoneCommentCfg 的 roles（评论者）'
        '均为必填，不能只填内容而漏掉角色；'
        '其中对白的 roleIds 是数组（可填多个说话人角色 ID），短信与动态的 role 是单个角色 ID；\n'
        '- 新建或修改这类条目时，先用 get_game_dicts(name=roles) 查角色名对应的 ID 并填上；'
        '只填 roleName 时系统会尝试按名字自动匹配角色，匹配不到会报错，所以最好主动查好 ID；\n'
        '- 对白的 roleName（自定义名字）只是覆盖显示名的可选字段，不能替代 roleIds；'
        '旁白（无说话人）时对白的 roleIds 与 roleName 都留空；\n'
        '- 注意区分：对白的 roles 字段是舞台调度的指令编码（数字串），由 set_talk_stage 维护，'
        '不要用 update_domain_item 直接改它，也不要把它当成说话人字段。\n'
        '\n【跨类联动】一个需求常常要动多个领域的表，记住这些联动关系：\n'
        '- 缺角色就新建，不要复用：角色分「游戏内置」（get_game_dicts(name=roles) 能查到）'
        '和「模组自有」（人物领域 character 的 PersonCfg 条目）两类。用户提到的角色两处都'
        '查不到时，先在 character 领域用 create_domain_item 新建 PersonCfg 条目，'
        '再用返回的 id 填对白/短信/动态/评论的角色字段；'
        '不要把台词安到相近的已有角色头上，也不要编造 ID。'
        '注意新建的角色不会出现在 get_game_dicts 里（字典只含内置角色），直接用新建返回的 id。\n'
        '- 跨表引用存的都是 ID 不是名字：修改角色的名字/属性等基础信息，只需改 PersonCfg '
        '条目本身，所有引用处自动生效，不要去逐表替换名字；反过来，改 role/roleIds 这类'
        '引用字段时填的也是 ID 而非名字（对白的 roleName 只是单条对白的显示名覆盖，'
        '不要用它当改名的手段）。\n'
        '- 先建被引用的一方：新建条目要引用其他条目（如对白/短信引用角色）时，'
        '先确认或新建被引用的条目拿到 id，再回填引用字段，不要留空引用或占位 id。\n'
        '- 剧情链路：事件（EvtCfg）用 talkId 引用对白、options 引用选项（OptionCfg）、'
        'mapId 引用地图；选项用 talkId/talkId2 引用对白、nextEvtId 跳转到下一个事件；'
        '对白用 nextTalk/nextTalk2 续接后续对白、option 挂选项。编排多段剧情时'
        '先建好叶子（对白/选项）再由事件串起来，或先建空条目再回填引用，'
        '保证每个引用的 id 都真实存在。\n'
        '- 场景与视听资源：对白的 bg（背景图 BgCfg）和 audio（音乐 AudioCfg）、'
        '事件的 mapId（地图 MapCfg）、地图的 bg 引用的都是对应表的条目 id，不是文件路径；'
        '路径类字段（如 BgCfg 的 url、ItemCfg 的 icon、PersonCfg 的 url 立绘）才填模组内'
        '相对路径。需要新背景/新音乐时先在「背景与场景」领域建好条目再引用。\n'
        '- 社交挂接：空间评论（KZoneCommentCfg）用 parent 指向所属动态（KZoneContentCfg）'
        '的 id，新建评论必须填 parent，否则不会出现在该动态下；'
        '新闻评论（NewsCommentCfg）由新闻（NewsCfg）的 comments 字段引用。\n'
        '- NPC 玩法跨表：送礼事件（GiftEvtCfg）用 item 引用物品、npc 引用角色；'
        '闲聊（InteractCfg）用 npc 引用角色、talkId 引用对白；'
        '好友申请（FriendRequestCfg）用 npc 引用角色——'
        '做这类玩法前先确认被引用的物品/角色/对白已存在。\n'
        '- 短信链：多轮短信用 PhoneMsgCfg 的 next（后续短信 id 数组）串接，'
        '先逐条新建短信，再用 next 把先后顺序串起来。\n'
        '- 删除前查引用：删除角色/物品/地图等可能被引用的条目前，先用 list_domain_items '
        '核对引用它的表（如角色会被对白/短信/动态引用），确认无引用再删，'
        '否则引用处会变成悬空 ID。\n'
        '\n【修改纪律】\n'
        '- 只改用户要求范围内的内容，不擅自改动无关条目或字段；\n'
        '- 找不到目标条目时换关键词再查，确认不存在就如实告知用户，不要编造 id 或字段；\n'
        '- 审批被拒绝时：停止该操作、询问用户想怎么调整，不要换参数绕过或反复重试；\n'
        '- 工具报错时先读错误信息（通常会指出原因和正确做法），按提示修正参数后重试；'
        '同一操作连续失败 2 次就停下来向用户说明，不要空转。\n'
        '\n【回答要求】\n'
        '- 使用简体中文；\n'
        '- 修改前用一句话说明计划：对哪个条目、改什么；\n'
        '- 完成后简要汇报：条目名称/ID、改动的字段、新值，涉及多个条目时逐条列出，'
        '不要把工具返回的大段 JSON 原样贴给用户；\n'
        '- 用户只是提问、还没让你改时，先解答问题并给出可行方案，等用户确认后再动手。\n\n'
        '${_describeTools(tools)}';
    return modContext.trim().isEmpty ? base : '$base\n$modContext';
  }

  /// 把 dynamic 值安全转成 `Map<String, dynamic>`（键统一转 String）；
  /// 非 Map 返回 null。避免运行时 `_Map<dynamic, dynamic>` 被
  /// `as Map<String, dynamic>` 强转抛类型错误。
  static Map<String, dynamic>? _asStrMap(dynamic v) {
    if (v is! Map) return null;
    return v.map((k, val) => MapEntry(k.toString(), val));
  }

  /// 把工具定义（JSON schema）转成中文参数速查，逐条列出工具允许携带的参数：
  /// 参数名（类型、必填/可空、可选枚举）：含义。
  static String _describeTools(List<AiToolDef> tools) {
    final buf = StringBuffer('工具参数速查（调用工具时按此传参）：');
    for (final t in tools) {
      final props = _asStrMap(t.parameters['properties']) ?? {};
      final required =
          ((t.parameters['required'] as List?) ?? []).cast<String>().toSet();
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

  static const _maxToolRounds = 20;
  http.Client? _client;
  bool _cancelled = false;

  void cancel() {
    _cancelled = true;
    // 关闭底层连接以中断正在进行的 SSE 流
    _client?.close();
    _client = null;
  }

  Uri _uri(String path) {
    var base = settings.baseUrl.trim();
    if (base.isEmpty) {
      base = switch (settings.provider) {
        'anthropic' => 'https://api.anthropic.com/v1',
        'openai_responses' => 'https://api.openai.com/v1',
        _ => 'https://api.openai.com/v1',
      };
    }
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    return Uri.parse(base + path);
  }

  Future<Map<String, String>> _headers() async {
    final h = <String, String>{
      'Content-Type': 'application/json',
      'Accept': 'text/event-stream',
    };
    if (settings.provider == 'anthropic') {
      h['x-api-key'] = settings.apiKey;
      h['anthropic-version'] = '2023-06-01';
    } else {
      h['Authorization'] = 'Bearer ${settings.apiKey}';
    }
    return h;
  }

  /// 主入口：发送一条用户消息并处理工具循环。
  ///
  /// [history] 为结构化消息列表（OpenAI 风格：assistant 可带 tool_calls，tool 角色携带结果）。
  /// 本轮工具调用产生的消息会**追加到该列表**（引用），使后续 send 保留完整的工具调用上下文。
  Future<void> send({
    required List<Map<String, dynamic>> history,
    required List<AiToolDef> tools,
    required AiCallbacks callbacks,
  }) async {
    _cancelled = false;
    if (settings.apiKey.isEmpty) {
      throw AiClientException('未配置 API Key，请先在「设置」中配置');
    }
    // 直接复用调用方持有的历史列表：工具轮次消息会追加进去，跨轮次保留上下文。
    final messages = history;

    var round = 0;
    while (true) {
      if (_cancelled) return;
      round++;
      if (round > _maxToolRounds) {
        callbacks.onToolResult?.call('_loop_limit', '工具调用轮次超过上限（$_maxToolRounds），已终止');
        callbacks.onDone?.call();
        return;
      }
      final (toolCallsRound, text) = await switch (settings.provider) {
        'anthropic' => _anthropicRound(messages, tools, callbacks),
        'openai_responses' => _responsesRound(messages, tools, callbacks),
        _ => _openaiRound(messages, tools, callbacks),
      };

      if (toolCallsRound.isEmpty) {
        // 最终回复：把文本写入历史，保证后续轮次的对话连贯。
        if (text.isNotEmpty) {
          messages.add({'role': 'assistant', 'content': text});
        }
        callbacks.onDone?.call();
        return;
      }
      // 本轮以工具调用结束：过渡文本单独上报（执行工具前，便于 UI 区分
      // 「工具调用情况」与最终回复）；文本为空也调用以标记轮次边界。
      callbacks.onToolRoundText?.call(text);
      // 执行工具
      final results = <String>[];
      for (final call in toolCallsRound) {
        if (_cancelled) return;
        if (callbacks.onToolCall == null) {
          throw AiClientException('工具调用未处理: ${call.name}');
        }
        final result = await callbacks.onToolCall!(call);
        results.add(result);
        callbacks.onToolResult?.call(call.name, result);
      }
      // 把本轮工具调用与结果追加为结构化消息
      if (settings.provider == 'anthropic') {
        messages.add({
          'role': 'assistant',
          'content': [
            if (text.isNotEmpty) {'type': 'text', 'text': text},
            for (var i = 0; i < toolCallsRound.length; i++)
              {
                'type': 'tool_use',
                'id': toolCallsRound[i].id,
                'name': toolCallsRound[i].name,
                'input': toolCallsRound[i].arguments,
              },
          ],
        });
        messages.add({
          'role': 'user',
          'content': [
            for (var i = 0; i < toolCallsRound.length; i++)
              {
                'type': 'tool_result',
                'tool_use_id': toolCallsRound[i].id,
                'content': results[i],
              },
          ],
        });
      } else {
        messages.add({
          'role': 'assistant',
          'content': text.isEmpty ? null : text,
          'tool_calls': [
            for (var i = 0; i < toolCallsRound.length; i++)
              {
                'id': toolCallsRound[i].id,
                'type': 'function',
                'function': {
                  'name': toolCallsRound[i].name,
                  'arguments': jsonEncode(toolCallsRound[i].arguments),
                },
              },
          ],
        });
        for (var i = 0; i < toolCallsRound.length; i++) {
          messages.add({
            'role': 'tool',
            'tool_call_id': toolCallsRound[i].id,
            'content': results[i],
          });
        }
      }
    }
  }

  // ---------------- OpenAI Compatible (chat/completions) ----------------
  Future<(List<AiToolCall>, String)> _openaiRound(
      List<Map<String, dynamic>> messages, List<AiToolDef> tools, AiCallbacks cb) async {
    final body = {
      'model': settings.model,
      'temperature': settings.temperature,
      'stream': true,
      'messages': [
        {
          'role': 'system',
          'content': _systemPrompt(tools),
        },
        ...messages,
      ],
      'tools': [
        for (final t in tools)
          {
            'type': 'function',
            'function': {
              'name': t.name,
              'description': t.description,
              'parameters': t.parameters,
            },
          }
      ],
    };
    final resp = await _postStream(_uri('/chat/completions'), body);
    final calls = <int, Map<String, dynamic>>{};
    final textBuf = StringBuffer();

    await for (final event in resp) {
      if (event.isEmpty || event == '[DONE]') continue;
      final json = jsonDecode(event) as Map<String, dynamic>;
      final choices = json['choices'] as List?;
      if (choices == null || choices.isEmpty) continue;
      final delta = _asStrMap((choices[0] as Map<String, dynamic>)['delta']) ?? {};
      final content = delta['content'];
      if (content is String && content.isNotEmpty) {
        textBuf.write(content);
        cb.onText?.call(content);
      }
      final tc = delta['tool_calls'] as List?;
      if (tc != null) {
        for (final raw in tc) {
          final item = _asStrMap(raw) ?? const {};
          final idx = (item['index'] as num?)?.toInt() ?? 0;
          final fn = _asStrMap(item['function']) ?? {};
          final slot = calls.putIfAbsent(idx, () => {
                'id': item['id'] as String? ?? 'call_$idx',
                'name': fn['name'] as String? ?? '',
                'arguments': '',
              });
          if (fn['name'] != null) slot['name'] = fn['name'];
          if (fn['arguments'] != null) {
            slot['arguments'] = (slot['arguments'] as String) + (fn['arguments'] as String);
          }
        }
      }
      final finish = (choices[0] as Map<String, dynamic>)['finish_reason'];
      if (finish == 'tool_calls') break;
      if (finish == 'stop') break;
    }
    return (_parseCalls(calls), textBuf.toString());
  }

  // ---------------- OpenAI Responses API ----------------
  Future<(List<AiToolCall>, String)> _responsesRound(
      List<Map<String, dynamic>> messages, List<AiToolDef> tools, AiCallbacks cb) async {
    final body = {
      'model': settings.model,
      'temperature': settings.temperature,
      'stream': true,
      'input': [
        {
          'role': 'system',
          'content': _systemPrompt(tools),
        },
        ..._toResponsesInput(messages),
      ],
      'tools': [
        for (final t in tools)
          {
            'type': 'function',
            'name': t.name,
            'description': t.description,
            'parameters': t.parameters,
          }
      ],
    };
    final resp = await _postStream(_uri('/responses'), body);
    final calls = <int, Map<String, dynamic>>{};
    final textBuf = StringBuffer();
    var callIdx = 0;

    await for (final event in resp) {
      if (event.isEmpty || event == '[DONE]') continue;
      final json = jsonDecode(event) as Map<String, dynamic>;
      final type = json['type'] as String? ?? '';
      if (type == 'response.output_text.delta') {
        final delta = json['delta'] as String? ?? '';
        if (delta.isNotEmpty) {
          textBuf.write(delta);
          cb.onText?.call(delta);
        }
      } else if (type == 'response.output_item.added') {
        final item = _asStrMap(json['item']) ?? {};
        if (item['type'] == 'function_call') {
          calls[callIdx] = {
            'id': item['id'] as String? ?? 'fc_$callIdx',
            'name': item['name'] as String? ?? '',
            'arguments': item['arguments'] as String? ?? '',
          };
          callIdx++;
        }
      } else if (type == 'response.output_item.done') {
        // 部分网关在 done 事件携带完整 item
        final item = _asStrMap(json['item']) ?? {};
        if (item['type'] == 'function_call' && item['arguments'] is String) {
          final args = item['arguments'] as String;
          final id = item['id'] as String? ?? '';
          if (args.isNotEmpty) {
            // 按 call_id 匹配，避免依赖事件顺序
            Map<String, dynamic>? slot;
            for (final s in calls.values) {
              if (s['id'] == id) {
                slot = s;
                break;
              }
            }
            (slot ?? calls[callIdx - 1])?['arguments'] = args;
          }
        }
      } else if (type == 'response.function_call_arguments.delta') {
        final itemId = json['item_id'] as String? ?? '';
        final delta = json['delta'] as String? ?? '';
        for (final slot in calls.values) {
          if (slot['id'] == itemId) {
            slot['arguments'] = (slot['arguments'] as String) + delta;
          }
        }
      }
    }
    return (_parseCalls(calls), textBuf.toString());
  }

  // ---------------- Anthropic Compatible ----------------
  Future<(List<AiToolCall>, String)> _anthropicRound(
      List<Map<String, dynamic>> messages, List<AiToolDef> tools, AiCallbacks cb) async {
    final body = {
      'model': settings.model,
      'temperature': settings.temperature,
      'max_tokens': 8192,
      'stream': true,
      'system': _systemPrompt(tools),
      'messages': _toAnthropicMessages(messages),
      'tools': [
        for (final t in tools)
          {
            'name': t.name,
            'description': t.description,
            'input_schema': t.parameters,
          }
      ],
    };
    final resp = await _postStream(_uri('/messages'), body);
    final calls = <String, Map<String, dynamic>>{}; // id -> {name, arguments}
    final textBuf = StringBuffer();
    String? currentToolId;
    String? currentToolName;

    await for (final event in resp) {
      if (event.isEmpty) continue;
      final json = jsonDecode(event) as Map<String, dynamic>;
      final type = json['type'] as String? ?? '';
      if (type == 'content_block_start') {
        final block = _asStrMap(json['content_block']) ?? {};
        if (block['type'] == 'tool_use') {
          currentToolId = block['id'] as String?;
          currentToolName = block['name'] as String?;
          if (currentToolId != null && currentToolName != null) {
            calls[currentToolId] = {'id': currentToolId, 'name': currentToolName, 'arguments': ''};
          }
        }
      } else if (type == 'content_block_delta') {
        final delta = _asStrMap(json['delta']) ?? {};
        final text = delta['text'];
        if (text is String && text.isNotEmpty) {
          textBuf.write(text);
          cb.onText?.call(text);
        }
        final partial = delta['partial_json'];
        if (partial is String && currentToolId != null && calls.containsKey(currentToolId)) {
          final slot = calls[currentToolId]!;
          slot['arguments'] = (slot['arguments'] as String) + partial;
        }
      }
    }
    final parsed = <AiToolCall>[];
    for (final slot in calls.values) {
      parsed.add(AiToolCall(
        id: slot['id'] as String,
        name: slot['name'] as String,
        arguments: _tryParseJson(slot['arguments'] as String? ?? ''),
      ));
    }
    return (parsed, textBuf.toString());
  }

  // ---------------- 工具 ----------------
  /// OpenAI 风格结构化消息 → Anthropic messages（content 为 blocks 或字符串）。
  List<Map<String, dynamic>> _toAnthropicMessages(List<Map<String, dynamic>> messages) {
    final out = <Map<String, dynamic>>[];
    for (final m in messages) {
      final role = m['role'];
      if (role != 'user' && role != 'assistant') continue;
      final content = m['content'];
      if (content is List) {
        // blocks：tool_use / tool_result 原样保留，image_url（OpenAI 风格）转 image
        final blocks = <Map<String, dynamic>>[];
        for (final b in content) {
          final blk = _asStrMap(b);
          if (blk == null) continue;
          if (blk['type'] == 'image_url') {
            final url = (blk['image_url'] as Map?)?['url'] as String? ?? '';
            final (mediaType, data) = _splitDataUrl(url);
            if (data.isEmpty) continue;
            blocks.add({
              'type': 'image',
              'source': {'type': 'base64', 'media_type': mediaType, 'data': data},
            });
          } else {
            blocks.add(blk);
          }
        }
        out.add({'role': role, 'content': blocks});
        continue;
      }
      if (role == 'assistant' && m['tool_calls'] is List) {
        final blocks = <Map<String, dynamic>>[];
        if (content is String && content.isNotEmpty) {
          blocks.add({'type': 'text', 'text': content});
        }
        for (final tc in m['tool_calls'] as List) {
          final tcMap = _asStrMap(tc);
          if (tcMap == null) continue;
          final fn = _asStrMap(tcMap['function']) ?? {};
          blocks.add({
            'type': 'tool_use',
            'id': tcMap['id'] as String? ?? 'toolu_0',
            'name': fn['name'] ?? '',
            'input': _tryParseJson(fn['arguments'] as String? ?? ''),
          });
        }
        out.add({'role': 'assistant', 'content': blocks});
        continue;
      }
      out.add({'role': role, 'content': content ?? ''});
    }
    return out;
  }

  /// OpenAI 风格结构化消息 → Responses API input。
  List<Map<String, dynamic>> _toResponsesInput(List<Map<String, dynamic>> messages) {
    final out = <Map<String, dynamic>>[];
    for (final m in messages) {
      final role = m['role'];
      if (role == 'user' || role == 'assistant') {
        final content = m['content'];
        if (content is List) {
          // blocks：tool_result → function_call_output；text / image_url → input 块
          final blocks = <Map<String, dynamic>>[];
          for (final b in content) {
            final block = _asStrMap(b);
            if (block == null) continue;
            switch (block['type']) {
              case 'tool_result':
                blocks.add({
                  'type': 'function_call_output',
                  'call_id': block['tool_use_id'],
                  'output': block['content'],
                });
              case 'text':
                blocks.add({'type': 'input_text', 'text': block['text'] ?? ''});
              case 'image_url':
                final url = (block['image_url'] as Map?)?['url'] as String? ?? '';
                blocks.add({'type': 'input_image', 'image_url': url});
            }
          }
          if (blocks.isNotEmpty) out.addAll(blocks);
          continue;
        }
        if (role == 'assistant' && m['tool_calls'] is List) {
          for (final tc in m['tool_calls'] as List) {
            final tcMap = _asStrMap(tc);
            if (tcMap == null) continue;
            final fn = _asStrMap(tcMap['function']) ?? {};
            out.add({
              'type': 'function_call',
              'call_id': tcMap['id'] as String? ?? 'fc_0',
              'name': fn['name'],
              'arguments': fn['arguments'],
            });
          }
          continue;
        }
        out.add({'role': role, 'content': content ?? ''});
      } else if (role == 'tool') {
        out.add({
          'type': 'function_call_output',
          'call_id': m['tool_call_id'],
          'output': m['content'],
        });
      }
    }
    return out;
  }

  List<AiToolCall> _parseCalls(Map<int, Map<String, dynamic>> slots) {
    final out = <AiToolCall>[];
    final ids = slots.keys.toList()..sort();
    for (final idx in ids) {
      final slot = slots[idx]!;
      out.add(AiToolCall(
        id: slot['id'] as String,
        name: slot['name'] as String,
        arguments: _tryParseJson(slot['arguments'] as String? ?? ''),
      ));
    }
    return out;
  }

  Map<String, dynamic> _tryParseJson(String raw) {
    final t = raw.trim();
    if (t.isEmpty) return {};
    try {
      final v = jsonDecode(t);
      return v is Map<String, dynamic> ? v : {};
    } catch (_) {
      return {};
    }
  }

  /// 解析 data URL（"data:image/png;base64,xxxx"）→ (media_type, base64 数据)。
  /// 非 data URL 时原样返回，媒体类型默认 image/png。
  (String, String) _splitDataUrl(String url) {
    if (url.startsWith('data:')) {
      final comma = url.indexOf(',');
      if (comma > 5) {
        final meta = url.substring(5, comma);
        final semi = meta.indexOf(';');
        final media = (semi > 0 ? meta.substring(0, semi) : meta).trim();
        return (media.isNotEmpty ? media : 'image/png',
            url.substring(comma + 1));
      }
    }
    return ('image/png', url);
  }

  Future<Stream<String>> _postStream(Uri uri, Map<String, dynamic> body) async {
    if (_cancelled) throw AiClientException('已取消');
    final req = http.Request('POST', uri)
      ..headers.addAll(await _headers())
      ..body = jsonEncode(body);
    final client = http.Client();
    _client = client;
    final streamed = await req.send().timeout(const Duration(seconds: 30));
    if (streamed.statusCode >= 400) {
      final errBody = await streamed.stream.bytesToString();
      client.close();
      if (_client == client) _client = null;
      throw AiClientException('HTTP ${streamed.statusCode}: ${_trimErr(errBody)}');
    }
    return streamed.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .where((line) => line.startsWith('data:'))
        .map((line) => line.substring(5).trim())
        .transform(StreamTransformer<String, String>.fromHandlers(
          handleError: (Object e, StackTrace st, EventSink<String> sink) {
            // 取消导致的流中断：静默结束
            if (_cancelled) {
              sink.close();
            } else {
              sink.addError(e, st);
            }
          },
          handleDone: (EventSink<String> sink) {
            client.close();
            if (_client == client) _client = null;
            sink.close();
          },
        ));
  }

  String _trimErr(String raw) {
    final t = raw.trim();
    if (t.isEmpty) return 'empty response';
    try {
      final json = jsonDecode(t);
      if (json is Map) {
        final err = json['error'];
        if (err is Map) return (err['message'] ?? err.toString()).toString();
        return err?.toString() ?? t;
      }
    } catch (_) {}
    return t.length > 400 ? t.substring(0, 400) : t;
  }
}
