import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;

import '../../core/api_client.dart';
import '../settings/settings_page.dart';
import 'ai_policy.dart';
import 'ai_prompts.dart';

/// web 双通道传输选择（桌面端恒 [direct]，且仍走原流式路径）。
enum AiTransportChannel {
  /// 浏览器直连服务商（package:http 在 web 即 fetch；非流式）。
  direct,

  /// 平台网关：POST /api/ai/relay/chat（非流式，密钥在服务端）。
  relay,
}

/// AI 工具定义（OpenAI function / Anthropic tool 的公共形态）。
class AiToolDef {
  const AiToolDef({
    required this.name,
    required this.description,
    this.parameters = const {},
  });
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
  AiCallbacks({
    this.onText,
    this.onToolRoundText,
    this.onToolCall,
    this.onToolResult,
    this.onDone,
  });

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
///
/// 传输通道（M0.4 网页版双通道）：
/// - 桌面（非 web）：[channel] 恒 [AiTransportChannel.direct]、流式 SSE，
///   与此前行为完全一致；
/// - web 自带 key（[AiTransportChannel.direct]）：同一套 provider 请求体，
///   但一律非流式（浏览器 fetch 流式不可靠），按各协议非流式响应格式解析；
/// - web 平台 AI（[AiTransportChannel.relay]）：把同一份请求体 POST 到后端
///   `/api/ai/relay/chat`，协议以服务端 policy.provider 为准（[_protocol]）。
class AiClient {
  AiClient(
    this.settings, {
    this.modContext = '',
    this.channel = AiTransportChannel.direct,
    this.relayProvider = '',
    this.relayModel = '',
    this.relayModels = const [],
    bool? forceNonStream,
    http.Client Function()? clientFactory,
  }) : _nonStream = kIsWeb || (forceNonStream ?? false),
       _clientFactory = clientFactory ?? http.Client.new;

  final AiSettings settings;

  /// 当前工作范围提示（如「当前模组：xxx」），非空时追加到系统提示，
  /// 用于约束 AI 默认只修改当前选定的模组。
  final String modContext;

  /// 传输通道（仅 web 有 relay 语义；桌面恒 direct）。
  final AiTransportChannel channel;

  /// 平台网关协议（policy.provider）：relay 通道下请求体按它构造。
  final String relayProvider;

  /// 平台网关默认模型（policy.model）：relay 且本地未选模型时回填。
  final String relayModel;

  /// 平台网关允许的模型清单（policy.models）：本地模型不在清单内时
  /// 退回 [relayModel]（可为空——网关对空 model 会回填服务端配置）。
  final List<String> relayModels;

  /// 非流式模式：web 一律 true（浏览器流式不可靠）；测试用
  /// [forceNonStream] 在 VM 上驱动同一路径。桌面默认 false → 流式 SSE。
  final bool _nonStream;

  /// 直连用的 http.Client 工厂（测试注入 MockClient）。
  final http.Client Function() _clientFactory;

  /// 本轮实际使用的协议：relay 通道以服务端配置为准。
  String get _protocol =>
      channel == AiTransportChannel.relay && relayProvider.isNotEmpty
      ? relayProvider
      : settings.provider;

  /// 请求体里的 model：relay 模式下本地值不在允许清单时退回网关默认。
  String get _bodyModel {
    final m = settings.model.trim();
    if (channel != AiTransportChannel.relay) return settings.model;
    if (m.isNotEmpty && (relayModels.isEmpty || relayModels.contains(m))) {
      return m;
    }
    return relayModel;
  }

  /// 基础系统提示 + 工具参数速查 + 可选的当前模组范围约束。
  ///
  /// 正文与参数速查拼接逻辑单源在 ai_prompts.dart；
  /// 关键句式受 frontend/test/ai_client_test.dart 断言约束，改句式先同步测试。
  String _systemPrompt(List<AiToolDef> tools) => buildSystemPrompt(
    tools: tools,
    modContext: modContext,
    customInstructions: settings.customInstructions,
  );

  /// 把 dynamic 值安全转成 `Map<String, dynamic>`（键统一转 String）；
  /// 非 Map 返回 null。避免运行时 `_Map<dynamic, dynamic>` 被
  /// `as Map<String, dynamic>` 强转抛类型错误。
  static Map<String, dynamic>? _asStrMap(dynamic v) {
    if (v is! Map) return null;
    return v.map((k, val) => MapEntry(k.toString(), val));
  }

  /// 流式 SSE data 行的容错解码：返回 null 表示该行不是 JSON 对象
  /// （网关夹杂的 HTML/文本提示），调用方应跳过而不是让整条流报错。
  static Map<String, dynamic>? _tryDecodeEvent(String event) {
    try {
      final v = jsonDecode(event);
      return _asStrMap(v);
    } catch (_) {
      return null;
    }
  }

  static const _maxToolRounds = 20;
  http.Client? _client;

  /// 全部在途轮次的 client（阶段 2g）：单槽 _client 只记最新一轮，
  /// cancel() 需要关掉所有未终结的连接，不然旧轮泄漏的 socket 无人回收。
  final Set<http.Client> _openClients = {};
  bool _cancelled = false;

  void cancel() {
    _cancelled = true;
    // 关闭底层连接以中断正在进行的 SSE 流（含全部在途轮次）
    for (final c in _openClients.toList()) {
      c.close();
    }
    _openClients.clear();
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
      'Accept': _nonStream ? 'application/json' : 'text/event-stream',
    };
    if (_protocol == 'anthropic') {
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
    // relay 通道密钥在服务端，无需本地 key；直连（桌面流式 / web 自带 key）仍需配置。
    if (settings.apiKey.isEmpty && channel != AiTransportChannel.relay) {
      throw AiClientException('未配置 API Key，请先在「设置」中配置');
    }
    // 本轮实际协议：relay 通道以服务端 policy.provider 为准。
    final protocol = _protocol;
    // 直接复用调用方持有的历史列表：工具轮次消息会追加进去，跨轮次保留上下文。
    final messages = history;

    var round = 0;
    while (true) {
      if (_cancelled) return;
      round++;
      if (round > _maxToolRounds) {
        callbacks.onToolResult?.call(
          '_loop_limit',
          '工具调用轮次超过上限（$_maxToolRounds），已终止',
        );
        callbacks.onDone?.call();
        return;
      }
      final (toolCallsRound, text) = await switch (protocol) {
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
      if (protocol == 'anthropic') {
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
    List<Map<String, dynamic>> messages,
    List<AiToolDef> tools,
    AiCallbacks cb,
  ) async {
    final body = {
      'model': _bodyModel,
      'temperature': settings.temperature,
      'stream': !_nonStream,
      'messages': [
        {'role': 'system', 'content': _systemPrompt(tools)},
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
          },
      ],
    };
    if (_nonStream) {
      final json = await _postJson('/chat/completions', body);
      final (calls, text) = parseOpenaiJson(json);
      if (text.isNotEmpty) cb.onText?.call(text);
      return (calls, text);
    }
    final resp = await _postStream(_uri('/chat/completions'), body);
    final calls = <int, Map<String, dynamic>>{};
    final textBuf = StringBuffer();

    await for (final event in resp) {
      if (event.isEmpty || event == '[DONE]') continue;
      // 网关可能夹杂非 JSON data 行（HTML 错误页/代理提示）：跳过而不是
      // 让 FormatException 炸掉整条流。
      final json = _tryDecodeEvent(event);
      if (json == null) continue;
      final choices = json['choices'] as List?;
      if (choices == null || choices.isEmpty) continue;
      final delta =
          _asStrMap((choices[0] as Map<String, dynamic>)['delta']) ?? {};
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
          final slot = calls.putIfAbsent(
            idx,
            () => {
              'id': item['id'] as String? ?? 'call_$idx',
              'name': fn['name'] as String? ?? '',
              'arguments': '',
            },
          );
          if (fn['name'] != null) slot['name'] = fn['name'];
          if (fn['arguments'] != null) {
            slot['arguments'] =
                (slot['arguments'] as String) + (fn['arguments'] as String);
          }
        }
      }
      final finish = (choices[0] as Map<String, dynamic>)['finish_reason'];
      if (finish == 'tool_calls') break;
      if (finish == 'stop') break;
      if (finish == 'length') {
        // 上下文/输出长度截断：向用户明示，而不是让回复无声缺尾。
        const tail = '\n\n⚠ 回复因达到长度上限被截断。';
        textBuf.write(tail);
        cb.onText?.call(tail);
        break;
      }
    }
    return (_parseCalls(calls), textBuf.toString());
  }

  // ---------------- OpenAI Responses API ----------------
  Future<(List<AiToolCall>, String)> _responsesRound(
    List<Map<String, dynamic>> messages,
    List<AiToolDef> tools,
    AiCallbacks cb,
  ) async {
    final body = {
      'model': _bodyModel,
      'temperature': settings.temperature,
      'stream': !_nonStream,
      'input': [
        {'role': 'system', 'content': _systemPrompt(tools)},
        ..._toResponsesInput(messages),
      ],
      'tools': [
        for (final t in tools)
          {
            'type': 'function',
            'name': t.name,
            'description': t.description,
            'parameters': t.parameters,
          },
      ],
    };
    if (_nonStream) {
      final json = await _postJson('/responses', body);
      final (calls, text) = parseResponsesJson(json);
      if (text.isNotEmpty) cb.onText?.call(text);
      return (calls, text);
    }
    final resp = await _postStream(_uri('/responses'), body);
    final calls = <int, Map<String, dynamic>>{};
    final textBuf = StringBuffer();
    var callIdx = 0;

    await for (final event in resp) {
      if (event.isEmpty || event == '[DONE]') continue;
      final json = _tryDecodeEvent(event);
      if (json == null) continue;
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
    List<Map<String, dynamic>> messages,
    List<AiToolDef> tools,
    AiCallbacks cb,
  ) async {
    final body = {
      'model': _bodyModel,
      'temperature': settings.temperature,
      'max_tokens': 8192,
      'stream': !_nonStream,
      'system': _systemPrompt(tools),
      'messages': _toAnthropicMessages(messages),
      'tools': [
        for (final t in tools)
          {
            'name': t.name,
            'description': t.description,
            'input_schema': t.parameters,
          },
      ],
    };
    if (_nonStream) {
      final json = await _postJson('/messages', body);
      final (calls, text) = parseAnthropicJson(json);
      if (text.isNotEmpty) cb.onText?.call(text);
      return (calls, text);
    }
    final resp = await _postStream(_uri('/messages'), body);
    final calls = <String, Map<String, dynamic>>{}; // id -> {name, arguments}
    final textBuf = StringBuffer();
    String? currentToolId;
    String? currentToolName;

    await for (final event in resp) {
      if (event.isEmpty) continue;
      final json = _tryDecodeEvent(event);
      if (json == null) continue;
      final type = json['type'] as String? ?? '';
      // 中途错误事件（overloaded / authentication / …）：抛出而不是被当成
      // “最终回复”静默结束——否则用户看到的是一条空回复。
      if (type == 'error') {
        final err = _asStrMap(json['error']) ?? const {};
        throw AiClientException(
          'Anthropic 错误: ${err['type'] ?? 'error'} ${err['message'] ?? event}',
        );
      }
      if (type == 'message_delta') {
        // stop_reason: max_tokens => 输出被截断，向用户明示。
        final stop = json['stop_reason']?.toString();
        if (stop == 'max_tokens') {
          const tail = '\n\n⚠ 回复因达到长度上限被截断。';
          textBuf.write(tail);
          cb.onText?.call(tail);
        }
      }
      if (type == 'content_block_start') {
        final block = _asStrMap(json['content_block']) ?? {};
        if (block['type'] == 'tool_use') {
          currentToolId = block['id'] as String?;
          currentToolName = block['name'] as String?;
          if (currentToolId != null && currentToolName != null) {
            calls[currentToolId] = {
              'id': currentToolId,
              'name': currentToolName,
              'arguments': '',
            };
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
        if (partial is String &&
            currentToolId != null &&
            calls.containsKey(currentToolId)) {
          final slot = calls[currentToolId]!;
          slot['arguments'] = (slot['arguments'] as String) + partial;
        }
      }
    }
    final parsed = <AiToolCall>[];
    for (final slot in calls.values) {
      parsed.add(
        AiToolCall(
          id: slot['id'] as String,
          name: slot['name'] as String,
          arguments: _tryParseJson(slot['arguments'] as String? ?? ''),
        ),
      );
    }
    return (parsed, textBuf.toString());
  }

  // ---------------- 工具 ----------------
  /// OpenAI 风格结构化消息 → Anthropic messages（content 为 blocks 或字符串）。
  List<Map<String, dynamic>> _toAnthropicMessages(
    List<Map<String, dynamic>> messages,
  ) {
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
              'source': {
                'type': 'base64',
                'media_type': mediaType,
                'data': data,
              },
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
  List<Map<String, dynamic>> _toResponsesInput(
    List<Map<String, dynamic>> messages,
  ) {
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
                final url =
                    (block['image_url'] as Map?)?['url'] as String? ?? '';
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
      out.add(
        AiToolCall(
          id: slot['id'] as String,
          name: slot['name'] as String,
          arguments: _tryParseJson(slot['arguments'] as String? ?? ''),
        ),
      );
    }
    return out;
  }

  static Map<String, dynamic> _tryParseJson(String raw) {
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
        return (
          media.isNotEmpty ? media : 'image/png',
          url.substring(comma + 1),
        );
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
    _openClients.add(client);
    void closeClient() {
      if (_openClients.remove(client)) client.close();
      if (_client == client) _client = null;
    }

    final http.StreamedResponse streamed;
    try {
      streamed = await req.send().timeout(const Duration(seconds: 30));
    } catch (_) {
      // 连接/超时异常：本轮 client 若不关就永久泄漏（阶段 2g）。
      closeClient();
      rethrow;
    }
    if (streamed.statusCode >= 400) {
      final errBody = await streamed.stream.bytesToString();
      closeClient();
      throw AiClientException(
        'HTTP ${streamed.statusCode}: ${_trimErr(errBody)}',
      );
    }
    // 用 controller 包一层：旧实现是 lazy transform 链，消费者 break（如收到
    // [DONE] 但 provider 不关连接）时既无 done 也无 error，client 永远不关。
    // 现在 done/error/取消三条退出路径统一收口 closeClient。
    final controller = StreamController<String>();
    StreamSubscription<String>? sub;
    controller.onListen = () {
      sub = streamed.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .where((line) => line.startsWith('data:'))
          .map((line) => line.substring(5).trim())
          .listen(
            controller.add,
            onError: (Object e, StackTrace st) {
              closeClient();
              // 取消导致的流中断：静默结束
              if (_cancelled) {
                controller.close();
              } else {
                controller.addError(e, st);
              }
            },
            onDone: () {
              closeClient();
              controller.close();
            },
            cancelOnError: false,
          );
    };
    controller.onCancel = () {
      final pending = sub?.cancel();
      closeClient();
      return pending;
    };
    controller.onPause = () => sub?.pause();
    controller.onResume = () => sub?.resume();
    return controller.stream;
  }

  // ---------------- 非流式传输与解析（web 双通道，M0.4） ----------------

  static const _truncatedNote = '\n\n⚠ 回复因达到长度上限被截断。';

  /// 一轮非流式 JSON 请求：
  /// - [AiTransportChannel.relay]：把 provider 请求体 POST 到后端
  ///   `/api/ai/relay/chat`（鉴权与 401 钩子走 ApiClient；上游 status/JSON
  ///   由服务端原样透传，网关信封错误 `{"error": "..."}` 映射为异常文案）；
  /// - [AiTransportChannel.direct]：直连服务商原地址（web 上即 fetch）。
  ///   网络/CORS 失败统一给出 [kAiBrowserCorsHint] 可操作文案。
  Future<Map<String, dynamic>> _postJson(
    String protocolPath,
    Map<String, dynamic> body,
  ) async {
    if (_cancelled) throw AiClientException('已取消');
    if (channel == AiTransportChannel.relay) {
      try {
        // relay 是后端长任务端点：async=1 走 202+轮询（runLongTask），
        // 上游错误仍以 ApiException 透出，由 _describeRelayError 人话化。
        final r = await ApiClient.instance.runLongTask(
          '/api/ai/relay/chat',
          body: body,
          timeout: const Duration(minutes: 5),
          maxWait: const Duration(seconds: 600),
        );
        if (r is! Map) {
          throw AiClientException('relay 网关响应不是 JSON 对象');
        }
        return Map<String, dynamic>.from(r);
      } on AiClientException {
        rethrow;
      } catch (e) {
        throw AiClientException(_describeRelayError(e));
      }
    }
    final client = _clientFactory();
    _openClients.add(client);
    try {
      final resp = await client
          .post(
            _uri(protocolPath),
            headers: await _headers(),
            body: jsonEncode(body),
          )
          .timeout(const Duration(minutes: 5));
      if (resp.statusCode >= 400) {
        throw AiClientException(
          'HTTP ${resp.statusCode}: ${_trimErr(resp.body)}',
        );
      }
      final decoded = jsonDecode(resp.body);
      if (decoded is! Map) {
        throw AiClientException('服务商响应不是 JSON 对象');
      }
      return Map<String, dynamic>.from(decoded);
    } on AiClientException {
      rethrow;
    } catch (e) {
      if (_cancelled) throw AiClientException('已取消');
      // 浏览器 fetch 失败（CORS 封锁/DNS/断网）在 package:http 里统一抛
      // ClientException：给出可操作文案而不是裸异常。
      throw AiClientException(
        _nonStream ? kAiBrowserCorsHint : '请求失败: $e',
      );
    } finally {
      _openClients.remove(client);
      client.close();
    }
  }

  /// relay 错误人话化：网关信封 `{"error": "..."}`、provider 标准
  /// `{"error": {"message": "..."}}` 与其余字段兜底逐级提取。
  static String _describeRelayError(Object e) {
    if (e is ApiException) {
      final body = e.body;
      String msg = e.message;
      if (body != null) {
        final err = body['error'];
        if (err is Map) {
          msg = (err['message'] ?? err.toString()).toString();
        } else if (err != null) {
          msg = err.toString();
        }
      }
      return 'relay 网关 HTTP ${e.statusCode}: $msg';
    }
    return 'relay 请求失败: $e';
  }

  /// OpenAI chat.completions 非流式响应：
  /// `choices[0].message.{content, tool_calls}`；finish_reason=length 补截断注。
  static (List<AiToolCall>, String) parseOpenaiJson(Map<String, dynamic> json) {
    final choices = json['choices'] as List?;
    if (choices == null || choices.isEmpty) {
      throw AiClientException('非流式响应缺少 choices 字段');
    }
    final choice = _asStrMap(choices.first) ?? const {};
    final msg = _asStrMap(choice['message']) ?? const {};
    var text = msg['content'] is String ? msg['content'] as String : '';
    if (choice['finish_reason']?.toString() == 'length') text += _truncatedNote;
    final calls = <AiToolCall>[];
    for (final raw in (msg['tool_calls'] as List? ?? const [])) {
      final item = _asStrMap(raw) ?? const {};
      final fn = _asStrMap(item['function']) ?? const {};
      calls.add(
        AiToolCall(
          id: item['id'] as String? ?? 'call_${calls.length}',
          name: fn['name'] as String? ?? '',
          arguments: _tryParseJson(fn['arguments'] as String? ?? ''),
        ),
      );
    }
    return (calls, text);
  }

  /// OpenAI Responses 非流式响应：`output` 项数组——message 的
  /// `content[].output_text/text` 拼文本；function_call → 工具调用；
  /// status=incomplete 补截断注。
  static (List<AiToolCall>, String) parseResponsesJson(
    Map<String, dynamic> json,
  ) {
    final output = json['output'] as List?;
    if (output == null) {
      throw AiClientException('非流式响应缺少 output 字段');
    }
    final textBuf = StringBuffer();
    final calls = <AiToolCall>[];
    for (final raw in output) {
      final item = _asStrMap(raw);
      if (item == null) continue;
      switch (item['type']) {
        case 'message':
          for (final c in (item['content'] as List? ?? const [])) {
            final block = _asStrMap(c);
            final t = block?['text'];
            if (block != null && t is String) textBuf.write(t);
          }
        case 'function_call':
          calls.add(
            AiToolCall(
              id:
                  item['call_id'] as String? ??
                  item['id'] as String? ??
                  'fc_${calls.length}',
              name: item['name'] as String? ?? '',
              arguments: _tryParseJson(item['arguments'] as String? ?? ''),
            ),
          );
      }
    }
    var text = textBuf.toString();
    if (json['status']?.toString() == 'incomplete') text += _truncatedNote;
    return (calls, text);
  }

  /// Anthropic 非流式响应：`content` 块数组——text 块拼文本、
  /// tool_use 块 → 工具调用；stop_reason=max_tokens 补截断注。
  static (List<AiToolCall>, String) parseAnthropicJson(
    Map<String, dynamic> json,
  ) {
    if (json['type'] == 'error') {
      final err = _asStrMap(json['error']) ?? const {};
      throw AiClientException(
        'Anthropic 错误: ${err['type'] ?? 'error'} ${err['message'] ?? ''}',
      );
    }
    final blocks = json['content'] as List?;
    if (blocks == null) {
      throw AiClientException('非流式响应缺少 content 字段');
    }
    final textBuf = StringBuffer();
    final calls = <AiToolCall>[];
    for (final raw in blocks) {
      final block = _asStrMap(raw);
      if (block == null) continue;
      if (block['type'] == 'text') {
        final t = block['text'];
        if (t is String) textBuf.write(t);
      } else if (block['type'] == 'tool_use') {
        calls.add(
          AiToolCall(
            id: block['id'] as String? ?? 'toolu_${calls.length}',
            name: block['name'] as String? ?? '',
            arguments: _asStrMap(block['input']) ?? const {},
          ),
        );
      }
    }
    var text = textBuf.toString();
    if (json['stop_reason']?.toString() == 'max_tokens') text += _truncatedNote;
    return (calls, text);
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
