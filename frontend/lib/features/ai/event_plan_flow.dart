/// M6「AI 融入无代码流：生成整段事件」。
///
/// 流程：自然语言描述 → AI 产出结构化提案 → diff 卡片（每张卡 = 一条 Cfg
/// 行计划，效果字段带中文翻译）→ 勾选/一键全应用（增量写盘，产出普通
/// Cfg 行，既有 M1/M2 表单可直接编辑）。
///
/// 产出途径（读码结论，见 M6 计划评审）：**前端编排，不加新后端端点**——
///   * 结构化提案走既有 [AiClient] 管线：定义单工具 `emit_event_plan`，
///     模型把提案 JSON 作为工具参数提交（三协议的 tool_calls 解析已在
///     AiClient 统一）；自由文本里的 JSON 仅作兜底提取。桌面直连流式 /
///     web 平台网关 relay 双通道语义与聊天面板一致（ai_relay_routes.cpp
///     的契约是「tool loop stays client-side」，后端不感知对话内容）。
///   * 效果码自修循环用既有只读端点 `/api/effect_validate`（最多
///     [EventPlanGenerator.maxRepairRounds] 轮，修不好降级为卡片警告）。
///   * 效果字段中文翻译用既有只读端点 `/api/effect/parse`（复用
///     effect_block_editor 的行模型与槽代入）。
///   * 落盘走既有 [SaveService.applyPatch]（`PUT /api/cfg/<name>` 的 patch
///     分支 + workspace revision 乐观锁），行形状对齐 story_flow_workspace
///     的新建记录（EvtCfg/TalkCfg/OptionCfg）。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../../core/api_client.dart';
import '../../core/app_theme.dart';
import '../../core/save_service.dart';
import '../nocode/effect_block_editor.dart' show parseEffectText;
import '../settings/settings_page.dart';
import 'ai_client.dart';
import 'ai_policy.dart';

/// 提案工具名：模型必须调用它把结构化提案作为工具参数提交。
const String kEventPlanToolName = 'emit_event_plan';

/// 事件 ID 起点（ID 规范：7 位、首位 1；已用满时向上找空位）。
const int kFirstEventId = 1200001;

/// 提案未走工具调用、从回复文本兜底提取到 JSON 时的警告文案。
const String kFallbackWarning = '模型未通过工具提交提案，已从回复文本中提取 JSON（建议检查字段完整性）';

/// 单工具定义：参数 schema 即提案 schema。
AiToolDef eventPlanToolDef() {
  return const AiToolDef(
    name: kEventPlanToolName,
    description:
        '提交生成完毕的整段事件提案（事件 + 按序对白 + 选项）。必须在生成完成后调用一次本工具，把完整提案作为参数提交',
    parameters: {
      'type': 'object',
      'required': ['evt', 'talks'],
      'properties': {
        'evt': {
          'type': 'object',
          'required': ['title'],
          'properties': {
            'title': {'type': 'string', 'description': '事件标题'},
            'type': {
              'type': 'integer',
              'description': '事件类型 id（evt_types 字典），不确定填 0',
            },
            'npc': {'type': 'integer', 'description': '关联 NPC 角色 id，无则 0'},
            'mapId': {'type': 'integer', 'description': '发生地图 id，无则 0'},
            'condition': {
              'type': 'string',
              'description':
                  '出现条件码（文本格式，如 "[[7, 1, 105, 70]]"，多行以逗号分隔）；无则空串',
            },
            'effect': {
              'type': 'string',
              'description': '事件效果码（同上格式）；无则空串',
            },
          },
        },
        'talks': {
          'type': 'array',
          'description': '按剧情顺序排列的对白列表（至少 1 句）',
          'items': {
            'type': 'object',
            'required': ['content'],
            'properties': {
              'content': {'type': 'string', 'description': '对白内容'},
              'roleName': {'type': 'string', 'description': '说话人显示名，可空'},
              'roleIds': {
                'type': 'array',
                'items': {'type': 'integer'},
                'description': '说话人角色 id 数组，无则空',
              },
              'audio': {'type': 'integer', 'description': 'AudioCfg 音频 id，无则 0'},
              'bg': {'type': 'integer', 'description': '背景 BgCfg id，无则 0'},
              'effect': {'type': 'string', 'description': '对白效果码；无则空串'},
              'next': {
                'type': 'integer',
                'description': '下一句在 talks 中的序号（0 起）；省略或 -1 表示剧情结束',
              },
              'options': {
                'type': 'array',
                'description': '本句给出的选项，可空数组',
                'items': {
                  'type': 'object',
                  'required': ['content'],
                  'properties': {
                    'content': {'type': 'string', 'description': '选项文案'},
                    'next': {
                      'type': 'integer',
                      'description': '选中后跳转的对白序号（0 起）；省略或 -1 表示结束',
                    },
                  },
                },
              },
            },
          },
        },
      },
    },
  );
}

/// 生成提示词：约束提案形态、ID 不由模型编造、效果码语法。
String buildEventPlanPrompt(String description, String modName) {
  final buf = StringBuffer();
  buf
    ..writeln('请把下面的需求整理成一个完整的剧情事件提案，并调用 $kEventPlanToolName 工具提交（不要调用其他工具）。')
    ..writeln('要求：')
    ..writeln('- talks 按剧情顺序排列，第 0 句是事件开场；需要分支就在对应句的 options 里给选项。')
    ..writeln('- next / options[].next 用 talks 序号（0 起）指向跳转目标，结束用 -1 或省略。')
    ..writeln('- 效果/条件码必须符合效果码语法（形如 [[1, 1, 3, 5]]），查不到的码宁可留空。')
    ..writeln('- 一律不要编造或填写 id 字段：事件/对白/选项的 ID 由编辑器统一分配，提案里不要出现任何 id。')
    ..writeln('- 音频/背景只填已存在的资源 id，没有就 0。');
  if (modName.isNotEmpty) {
    buf.writeln('当前模组：$modName（提案将写入这个模组）。');
  }
  buf.write('需求：$description');
  return buf.toString();
}

class EventPlanException implements Exception {
  EventPlanException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 一次生成的产出：提案 + 非致命警告（兜底提取/校验未过等）。
class EventPlanResult {
  EventPlanResult({required this.proposal, this.warnings = const []});
  final Map<String, dynamic> proposal;
  final List<String> warnings;
}

/// 提案生成器：封装「单工具调用 → 效果码校验 → 自修循环」。
///
/// [web]/[channelChoice]/[policy] 仅为 web 双通道语义（与聊天面板一致）；
/// 测试用 [clientFactory] 注入假 AiClient，不发真网。
class EventPlanGenerator {
  EventPlanGenerator({
    required this.settings,
    this.modName = '',
    this.web,
    this.channelChoice,
    this.policy,
    this.maxRepairRounds = 2,
    this.clientFactory,
  });

  final AiSettings settings;
  final String modName;

  /// null → 按 kIsWeb 判定；桌面恒直连。
  final bool? web;
  final AiChannelChoice? channelChoice;
  final AiPolicy? policy;

  /// 效果码自修循环上限。
  final int maxRepairRounds;

  /// 测试注入假 AiClient 的工厂；null 时按设置与通道现场构建。
  final AiClient Function()? clientFactory;

  AiClient? _active;

  /// 取消在途生成（关流；下一次回调后 generate 抛「已取消」或正常返回）。
  void cancel() => _active?.cancel();

  Future<AiClient> _buildClient() async {
    final isWeb = web ?? kIsWeb;
    var useRelay = false;
    var relayProvider = '';
    var relayModel = '';
    var relayModels = const <String>[];
    if (isWeb) {
      final policy = this.policy ?? AiPolicyStore.instance.policy;
      final choice = channelChoice ?? await AiChannelPrefs.load();
      useRelay = resolveUseRelay(
        web: true,
        choice: choice,
        policy: policy,
        hasOwnKey: settings.apiKey.isNotEmpty,
      );
      if (useRelay) {
        relayProvider = policy.provider;
        relayModel = policy.model;
        relayModels = policy.models;
      }
    }
    return AiClient(
      settings,
      modContext: modName.isEmpty
          ? ''
          : '当前模组：$modName。生成的提案只会写入这个模组。',
      channel: useRelay ? AiTransportChannel.relay : AiTransportChannel.direct,
      relayProvider: relayProvider,
      relayModel: relayModel,
      relayModels: relayModels,
    );
  }

  /// 生成提案。AI 上游与校验端点都可能抛异常（EventPlanException /
  /// AiClientException / ApiException），由调用方呈现。
  Future<EventPlanResult> generate(
    String description, {
    void Function(String progress)? onProgress,
  }) async {
    final client = clientFactory != null ? clientFactory!() : await _buildClient();
    _active = client;
    try {
      return await _run(client, description, onProgress: onProgress);
    } finally {
      if (identical(_active, client)) _active = null;
    }
  }

  Future<EventPlanResult> _run(
    AiClient client,
    String description, {
    void Function(String progress)? onProgress,
  }) async {
    final tool = eventPlanToolDef();
    final history = <Map<String, dynamic>>[
      {'role': 'user', 'content': buildEventPlanPrompt(description, modName)},
    ];
    final warnings = <String>[];
    Map<String, dynamic>? proposal;

    // 一轮：模型要么调 emit_event_plan（参数即提案），要么输出自由文本。
    Future<void> round() async {
      final textBuf = StringBuffer();
      Map<String, dynamic>? got;
      await client.send(
        history: history,
        tools: [tool],
        callbacks: AiCallbacks(
          onText: textBuf.write,
          onToolCall: (call) async {
            if (call.name == kEventPlanToolName && call.arguments.isNotEmpty) {
              got = call.arguments;
              return '已收到提案。';
            }
            return '本流程只接受 $kEventPlanToolName 工具调用，请用它提交完整提案。';
          },
        ),
      );
      if (got != null) {
        proposal = got;
      } else {
        final fallback = extractProposalJson(textBuf.toString());
        if (fallback != null) {
          proposal = fallback;
          if (!warnings.contains(kFallbackWarning)) warnings.add(kFallbackWarning);
        }
      }
    }

    onProgress?.call('正在生成结构化提案…');
    await round();
    final first = proposal;
    if (first == null) {
      throw EventPlanException(
        '模型没有返回结构化提案（既未调用 $kEventPlanToolName，回复中也提取不到 JSON）。请换个说法重试。',
      );
    }
    // 自修循环：校验不过 → 把错误回喂给模型重出提案（有界）。
    for (var i = 0; i < maxRepairRounds; i++) {
      onProgress?.call('正在校验效果码（第 ${i + 1} 轮）…');
      final (problems, unavailable) = await collectEffectProblems(proposal!);
      for (final w in unavailable) {
        if (!warnings.contains(w)) warnings.add(w);
      }
      if (problems.isEmpty) break;
      history.add({
        'role': 'user',
        'content': '效果/条件码校验未通过：\n'
            '${problems.map((p) => '- $p').join('\n')}\n'
            '请只修正这些问题（效果码语法形如 [[1, 1, 3, 5]]，查不到的码留空），'
            '并重新调用 $kEventPlanToolName 提交完整提案。',
      });
      onProgress?.call('效果码有误，正在让模型自修（第 ${i + 1} 轮）…');
      await round();
      if (identical(proposal, first)) {
        // 模型没有重发提案：放弃自修，余下问题降级为警告。
        break;
      }
    }
    onProgress?.call('校验完成。');
    final (remaining, unavailable2) = await collectEffectProblems(proposal!);
    for (final w in unavailable2) {
      if (!warnings.contains(w)) warnings.add(w);
    }
    if (remaining.isNotEmpty) {
      warnings.add(
        '效果码仍有校验问题（原样展示，可在应用前自行斟酌）：\n'
        '${remaining.map((p) => '- $p').join('\n')}',
      );
    }
    return EventPlanResult(proposal: proposal!, warnings: List.unmodifiable(warnings));
  }

  /// 汇总提案中所有效果/条件字段的校验问题。
  /// 返回 (problems=校验未过, unavailable=校验服务不可达)。
  static Future<(List<String>, List<String>)> collectEffectProblems(
    Map<String, dynamic> proposal,
  ) async {
    final problems = <String>[];
    final unavailable = <String>[];
    Future<void> check(String where, String field, dynamic value) async {
      final text = effectTextFromValue(value);
      if (text.isEmpty) return;
      try {
        final resp = await ApiClient.instance.post(
          '/api/effect_validate',
          body: {'text': text, 'mode': effectModeForField(field)},
        );
        if (resp is Map && resp['valid'] != true) {
          final errs = resp['errors'];
          final detail = errs is List && errs.isNotEmpty ? errs.join('；') : '校验未通过';
          problems.add('$where.$field：$detail');
        }
      } catch (e) {
        unavailable.add('效果码校验服务不可达（$where.$field 未校验）：$e');
      }
    }

    final evt = asStrMap(proposal['evt']) ?? const {};
    await check('evt', 'condition', evt['condition']);
    await check('evt', 'effect', evt['effect']);
    final talks = proposal['talks'];
    if (talks is List) {
      for (var i = 0; i < talks.length; i++) {
        final t = asStrMap(talks[i]);
        if (t == null) continue;
        await check('talks[$i]', 'effect', t['effect']);
      }
    }
    return (problems, unavailable);
  }
}

/// 从模型自由文本里兜底提取提案 JSON（剥代码栅栏 → 首个 { 到末个 }）。
Map<String, dynamic>? extractProposalJson(String text) {
  var t = text.trim();
  final fence = RegExp(r'```(?:json)?\s*([\s\S]*?)```').firstMatch(t);
  if (fence != null) t = fence.group(1)!.trim();
  final start = t.indexOf('{');
  final end = t.lastIndexOf('}');
  if (start < 0 || end <= start) return null;
  try {
    final v = jsonDecode(t.substring(start, end + 1));
    if (v is! Map) return null;
    return v.map((k, x) => MapEntry(k.toString(), x));
  } catch (_) {
    return null;
  }
}

// ---------------- 提案 → 行计划（纯函数，可单测） ----------------

/// dynamic → `Map<String, dynamic>`（键转 String；非 Map 返回 null）。
Map<String, dynamic>? asStrMap(dynamic v) {
  if (v is! Map) return null;
  return v.map((k, x) => MapEntry(k.toString(), x));
}

int? asPlanInt(dynamic v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v.trim());
  return null;
}

int asPlanIntOr(dynamic v, [int fallback = 0]) => asPlanInt(v) ?? fallback;

/// ID 列表规范化：字符串数字 → int；单值升维；null → []。
List<int> asPlanIdList(dynamic v) {
  if (v == null || v == '') return const [];
  final items = v is List ? v : [v];
  final out = <int>[];
  for (final item in items) {
    final n = asPlanInt(item);
    if (n != null) out.add(n);
  }
  return out;
}

/// 提案里效果/条件字段的原文 → 校验/解析用文本（行间 ", "）。
/// 数组形态自动转文本；字符串原样返回。
String effectTextFromValue(dynamic v) {
  if (v == null) return '';
  if (v is String) return v.trim();
  if (v is List) {
    if (v.isEmpty) return '';
    if (v.first is List) {
      return [
        for (final row in v)
          if (row is List) '[${row.join(', ')}]',
      ].join(', ');
    }
    return '[${v.join(', ')}]';
  }
  return '';
}

/// 提案里效果/条件字段 → 行内存储值（2D int 数组）；解析失败返回 []。
/// [errors] 非空时收集解析失败说明。
List<List<int>> effectValueFromProposal(dynamic v, {void Function(String)? onError}) {
  final text = effectTextFromValue(v);
  if (text.isEmpty) return const [];
  try {
    final decoded = jsonDecode(text);
    if (decoded is List) {
      return [
        for (final row in decoded)
          row is List ? [for (final x in row) asPlanIntOr(x)] : <int>[asPlanIntOr(row)],
      ];
    }
  } catch (_) {}
  onError?.call('效果码不是合法的 JSON 数组，已按空写入');
  return const [];
}

/// 字段名 → /api/effect_validate 与 /api/effect/parse 的 mode。
String effectModeForField(String field) => switch (field) {
  'condition' => 'condition',
  'probability' => 'cost',
  _ => 'effect',
};

/// 卡片字段中文标签（渲染与编辑共用）。
const Map<String, String> kEventPlanFieldLabels = {
  'title': '标题',
  'type': '类型',
  'npc': 'NPC',
  'mapId': '地图',
  'talkId': '跳转对白',
  'condition': '出现条件',
  'effect': '效果',
  'content': '内容',
  'roleName': '说话人',
  'roleIds': '说话人群组',
  'audio': '音频',
  'bg': '背景',
  'nextTalk': '下一句',
  'option': '选项',
};

/// 各表的卡片展示字段（按序）。
const Map<String, List<String>> kEventPlanDisplayFields = {
  'EvtCfg': ['title', 'type', 'npc', 'mapId', 'talkId', 'condition', 'effect'],
  'TalkCfg': ['roleName', 'roleIds', 'audio', 'bg', 'effect', 'nextTalk', 'option'],
  'OptionCfg': ['talkId'],
};

/// 行内可内联编辑的字段（EvtCfg 编辑 title，其余编辑 content）。
String editableFieldFor(String cfg) => cfg == 'EvtCfg' ? 'title' : 'content';

/// 卡片状态：pending → applying → done / failed。
enum EventPlanCardStatus { pending, applying, done, failed }

/// 一张待应用的行计划卡（= 一条 Cfg 行）。
class EventPlanCard {
  EventPlanCard({
    required this.cfg,
    required this.id,
    required this.row,
    required this.label,
  });

  /// 配置表名（EvtCfg / TalkCfg / OptionCfg）。
  final String cfg;

  /// 分配后的行 ID（字符串形态；行内 id 字段保持 int）。
  final String id;

  /// 将写入的完整行（应用时可再被内联编辑修改）。
  final Map<String, dynamic> row;

  /// 卡片主文本（事件标题 / 对白内容 / 选项内容），可内联编辑。
  String label;

  /// 是否勾选待应用（done 状态后置灰恒真）。
  bool checked = true;

  EventPlanCardStatus status = EventPlanCardStatus.pending;
  String? error;

  /// 字段名 → 效果/条件码原文（渲染时请求 /api/effect/parse 出中文）。
  final Map<String, String> effectTexts = {};

  /// 字段名 → 中文翻译（parse 完成后回填）。
  final Map<String, String> effectDescs = {};

  /// 字段名 → 解析失败说明。
  final Map<String, String> effectErrors = {};

  /// 主文本对应的行内字段名（内联编辑写回目标）。
  String get labelField => editableFieldFor(cfg);
}

/// 从既有 EvtCfg 表分配下一个事件 ID（7 位首位 1；与现有行不冲突）。
/// 无既有行时从 [kFirstEventId] 起。ID 用尽抛 [EventPlanException]。
int allocateEventId(Map<String, dynamic> evtTable) {
  var maxUsed = kFirstEventId - 1;
  evtTable.forEach((k, _) {
    final n = int.tryParse(k.toString().trim());
    if (n != null && n >= 1000000 && n <= 1999999 && n > maxUsed) maxUsed = n;
  });
  var id = maxUsed + 1;
  while (evtTable.containsKey(id.toString())) {
    id++;
  }
  if (id > 1999999) {
    throw EventPlanException('事件 ID 已用尽（1200001~1999999），无法再新建事件');
  }
  return id;
}

/// 把提案转换为行计划卡。
///
/// [evtTable]/[talkTable]/[optTable] 为既有表数据（`{id字符串: 行}`），用于
/// ID 碰撞检查；[talkTable]/[optTable] 建议只传当前事件前缀下的增量
/// （生产里走 `GET /api/cfg/<name>?prefix=<evtId>`，测试可传全表）。
/// [evtId] 已由调用方用 [allocateEventId] 预分配时可显式传入。
List<EventPlanCard> buildEventPlanCards({
  required Map<String, dynamic> proposal,
  Map<String, dynamic> evtTable = const {},
  Map<String, dynamic> talkTable = const {},
  Map<String, dynamic> optTable = const {},
  int? evtId,
}) {
  final evtRaw = asStrMap(proposal['evt']);
  if (evtRaw == null) {
    throw EventPlanException('提案缺少 evt 对象');
  }
  final talksRaw = proposal['talks'];
  if (talksRaw is! List || talksRaw.isEmpty) {
    throw EventPlanException('提案没有对白（talks 为空），至少需要 1 句开场');
  }
  final evt = evtId ?? allocateEventId(evtTable);
  final evtPrefix = evt.toString();

  // 对白 ID = 事件 ID + 001..（跳过已占用；号码用尽报错）
  var talkSeq = 1;
  String allocTalkId() {
    while (talkSeq <= 999) {
      final cand = '$evtPrefix${talkSeq.toString().padLeft(3, '0')}';
      talkSeq++;
      if (!talkTable.containsKey(cand)) return cand;
    }
    throw EventPlanException('事件 $evtPrefix 的对白 ID 已用尽（001~999）');
  }

  // 选项 ID 参考 story_logic.allocOptionId：{对白 ID 去尾 3 位}{01..99}。
  String allocOptionId(String prefix, Set<String> used) {
    for (var i = 1; i < 100; i++) {
      final cand = '$prefix${i.toString().padLeft(2, '0')}';
      if (!used.contains(cand)) return cand;
    }
    return '';
  }

  // 两遍法：先给全部对白分配 ID（提案用序号连线），再构建行。
  final talkIds = [for (var i = 0; i < talksRaw.length; i++) allocTalkId()];

  /// 序号（0 起）→ 对白 ID；越界/未给 → null（剧情结束）。
  String? resolveNext(dynamic next) {
    final n = asPlanInt(next);
    if (n == null || n < 0 || n >= talkIds.length) return null;
    return talkIds[n];
  }

  final cards = <EventPlanCard>[];

  // ---- EvtCfg 卡 ----
  final firstTalk = talkIds.first;
  final evtRow = <String, dynamic>{
    'id': evt,
    'title': (evtRaw['title'] ?? '未命名事件').toString(),
    'type': asPlanIntOr(evtRaw['type']),
    'npc': asPlanIntOr(evtRaw['npc']),
    'mapId': asPlanIntOr(evtRaw['mapId']),
    'talkId': [asPlanIntOr(firstTalk)],
    'maxcount': asPlanIntOr(evtRaw['maxcount'], 1),
    'probability': _probabilityValue(evtRaw['probability']),
    'condition': effectValueFromProposal(evtRaw['condition']),
    'effect': effectValueFromProposal(evtRaw['effect']),
    'maxoptions': asPlanIntOr(evtRaw['maxoptions']),
    'displayType': asPlanIntOr(evtRaw['displayType']),
    'rate': asPlanIntOr(evtRaw['rate']),
    'weight': asPlanIntOr(evtRaw['weight']),
  };
  final evtCard = EventPlanCard(
    cfg: 'EvtCfg',
    id: evtPrefix,
    row: evtRow,
    label: evtRow['title'] as String,
  );
  _attachEffectField(evtCard, 'condition', evtRaw['condition']);
  _attachEffectField(evtCard, 'effect', evtRaw['effect']);
  cards.add(evtCard);

  // ---- TalkCfg / OptionCfg 卡 ----
  final usedOptionIds = <String>{for (final k in optTable.keys) k.toString().trim()};
  for (var i = 0; i < talksRaw.length; i++) {
    final t = asStrMap(talksRaw[i]);
    if (t == null) continue;
    final talkId = talkIds[i];
    final content = (t['content'] ?? '').toString();
    final nextId = resolveNext(t['next']);

    final optionTargets = <String>[]; // 选项 ID → 跳转对白 ID
    final optionPlans = <Map<String, String>>[]; // id / content / next
    final optionsRaw = t['options'];
    if (optionsRaw is List && optionsRaw.isNotEmpty) {
      final prefix = talkId.length > 3 ? talkId.substring(0, talkId.length - 3) : talkId;
      for (final o in optionsRaw) {
        final om = asStrMap(o);
        if (om == null) continue;
        final oid = allocOptionId(prefix, usedOptionIds);
        if (oid.isEmpty) {
          throw EventPlanException('对白 $talkId 的选项 ID 已用尽（01~99）');
        }
        usedOptionIds.add(oid);
        optionPlans.add({
          'id': oid,
          'content': (om['content'] ?? '').toString(),
          'next': resolveNext(om['next']) ?? '',
        });
        optionTargets.add(oid);
      }
    }

    final talkRow = <String, dynamic>{
      'id': asPlanIntOr(talkId),
      'content': content,
      'nextTalk': nextId == null ? <int>[] : <int>[asPlanIntOr(nextId)],
      'nextTalk2': <int>[],
      'option': [for (final oid in optionTargets) asPlanIntOr(oid)],
    };
    final roleName = (t['roleName'] ?? '').toString().trim();
    if (roleName.isNotEmpty) talkRow['roleName'] = roleName;
    final roleIds = asPlanIdList(t['roleIds']);
    if (roleIds.isNotEmpty) talkRow['roleIds'] = roleIds;
    final audio = asPlanIntOr(t['audio']);
    if (audio > 0) talkRow['audio'] = audio;
    final bg = asPlanIntOr(t['bg']);
    if (bg > 0) talkRow['bg'] = bg;
    final effectErrs = <String>[];
    final effectValue = effectValueFromProposal(t['effect'], onError: (m) => effectErrs.add(m));
    if (effectTextFromValue(t['effect']).isNotEmpty) {
      talkRow['effect'] = effectValue;
    }

    final talkCard = EventPlanCard(
      cfg: 'TalkCfg',
      id: talkId,
      row: talkRow,
      label: content,
    );
    _attachEffectField(talkCard, 'effect', t['effect']);
    for (final m in effectErrs) {
      talkCard.effectErrors['effect'] = m;
    }
    cards.add(talkCard);

    for (final plan in optionPlans) {
      final optRow = <String, dynamic>{
        'id': asPlanIntOr(plan['id']),
        'content': plan['content'] ?? '',
        'talkId': (plan['next'] ?? '').isEmpty ? <int>[] : <int>[asPlanIntOr(plan['next'])],
        'talkId2': <int>[],
      };
      cards.add(EventPlanCard(
        cfg: 'OptionCfg',
        id: plan['id']!,
        row: optRow,
        label: optRow['content'] as String,
      ));
    }
  }
  return cards;
}

  /// 概率字段：数组原样保留（1D）；字符串尝试解析；缺省 [1]（对齐既有行）。
  dynamic _probabilityValue(dynamic v) {
    if (v is List) return v;
    final text = effectTextFromValue(v);
    if (text.isEmpty) return <int>[1];
    try {
      final decoded = jsonDecode(text);
      if (decoded is List) return decoded;
    } catch (_) {}
    return <int>[1];
  }

void _attachEffectField(EventPlanCard card, String field, dynamic value) {
  final text = effectTextFromValue(value);
  if (text.isNotEmpty) card.effectTexts[field] = text;
}

/// 卡片摘要值渲染（列表逐层 join）。
String eventPlanDisplayValue(dynamic v) {
  if (v == null) return '';
  if (v is List) {
    if (v.isNotEmpty && v.first is List) {
      return [for (final row in v) eventPlanDisplayValue(row)].join('; ');
    }
    return v.join(', ');
  }
  return v.toString();
}

// ---------------- 页面 ----------------

enum _FlowStep { input, generating, review }

/// 「生成整段事件」流程页：输入 → 生成 → diff 卡片审阅/应用。
/// 由 ai_panel 的对话框承载（也可独立挂载，测试即直挂 FluentApp）。
class EventPlanFlowPage extends StatefulWidget {
  const EventPlanFlowPage({
    super.key,
    required this.modName,
    required this.settings,
    this.generator,
  });

  /// 当前模组名（提示词范围约束）。
  final String modName;
  final AiSettings settings;

  /// 测试注入；null 时按设置与通道现场构建。
  final EventPlanGenerator? generator;

  @override
  State<EventPlanFlowPage> createState() => _EventPlanFlowPageState();
}

class _EventPlanFlowPageState extends State<EventPlanFlowPage> {
  final TextEditingController _desc = TextEditingController();
  _FlowStep _step = _FlowStep.input;
  String _progress = '';
  String? _genError;
  List<String> _warnings = const [];
  List<EventPlanCard> _cards = const [];
  bool _applying = false;
  String? _applySummary;

  /// 在途生成器实例（dispose/关闭时 cancel 在途流）。
  EventPlanGenerator? _activeGen;

  EventPlanGenerator _buildGenerator() =>
      widget.generator ??
      EventPlanGenerator(settings: widget.settings, modName: widget.modName);

  @override
  void dispose() {
    if (_step == _FlowStep.generating) _activeGen?.cancel();
    _desc.dispose();
    super.dispose();
  }

  // ---------------- 生成 ----------------

  Future<void> _generate() async {
    final description = _desc.text.trim();
    if (description.isEmpty || _step == _FlowStep.generating) return;
    setState(() {
      _step = _FlowStep.generating;
      _progress = '正在生成结构化提案…';
      _genError = null;
      _warnings = const [];
      _applySummary = null;
    });
    final gen = _buildGenerator();
    _activeGen = gen;
    try {
      final result = await gen.generate(
        description,
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        },
      );
      if (!mounted) return;
      setState(() => _progress = '正在分配 ID 并构建卡片…');
      // 读表：EvtCfg 全量（算 ID 上限），Talk/Option 只拉当前事件前缀增量
      // （S3 惯例：大表不做全量 GET）。
      final evtTable = await _loadCfg('EvtCfg');
      final newEvtId = allocateEventId(evtTable);
      final talkTable = await _loadCfg('TalkCfg', prefix: newEvtId.toString());
      final optTable = await _loadCfg('OptionCfg', prefix: newEvtId.toString());
      final cards = buildEventPlanCards(
        proposal: result.proposal,
        evtTable: evtTable,
        talkTable: talkTable,
        optTable: optTable,
        evtId: newEvtId,
      );
      await _loadEffectDescs(cards);
      if (!mounted) return;
      setState(() {
        _cards = cards;
        _warnings = result.warnings;
        _step = _FlowStep.review;
      });
    } on EventPlanException catch (e) {
      if (mounted) {
        setState(() {
          _genError = e.message;
          _step = _FlowStep.input;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _genError = '生成失败：$e';
          _step = _FlowStep.input;
        });
      }
    }
  }

  Future<Map<String, dynamic>> _loadCfg(String name, {String? prefix}) async {
    try {
      final r = await ApiClient.instance.get(
        '/api/cfg/$name',
        query: prefix != null ? {'prefix': prefix} : null,
      );
      final d = r is Map ? r['data'] : null;
      if (d is Map) return d.map((k, v) => MapEntry(k.toString(), v));
    } catch (_) {}
    return const {};
  }

  /// 逐卡逐字段请求 /api/effect/parse 回填中文翻译（失败降级为原文）。
  Future<void> _loadEffectDescs(List<EventPlanCard> cards) async {
    for (final c in cards) {
      for (final field in c.effectTexts.keys) {
        final text = c.effectTexts[field]!;
        try {
          final rows = await parseEffectText(text, effectModeForField(field));
          if (rows == null) {
            c.effectErrors[field] = '解析失败';
            continue;
          }
          final descs = <String>[];
          for (final r in rows) {
            final human = r.toHumanText(const {});
            descs.add(
              (r.error != null && r.error!.isNotEmpty) ? '$human（${r.error}）' : human,
            );
          }
          c.effectDescs[field] = descs.isEmpty ? text : descs.join('；');
        } catch (e) {
          c.effectErrors[field] = '解析请求失败：$e';
        }
      }
    }
  }

  // ---------------- 应用 ----------------

  List<EventPlanCard> get _checkedCards =>
      [for (final c in _cards) if (c.checked && c.status != EventPlanCardStatus.done) c];

  Future<void> _applyChecked() async {
    final targets = _checkedCards;
    if (targets.isEmpty || _applying) return;
    setState(() {
      _applying = true;
      _applySummary = null;
      for (final c in targets) {
        c.status = EventPlanCardStatus.applying;
        c.error = null;
      }
    });
    // 批前刷新 workspace 指纹（乐观锁）；每次成功写后 SaveService 会采纳新指纹。
    try {
      await SaveService.instance.refreshRevision();
    } catch (e) {
      if (mounted) {
        setState(() {
          _applying = false;
          for (final c in targets) {
            c.status = EventPlanCardStatus.failed;
            c.error = '无法获取文件指纹，未写入（请检查后端服务）：$e';
          }
        });
      }
      return;
    }
    var ok = 0;
    var fail = 0;
    for (final c in targets) {
      try {
        final result = await SaveService.instance.applyPatch(
          cfgName: c.cfg,
          patchSet: {c.id: c.row},
          patchRemove: const [],
        );
        if (result.isSuccess) {
          c.status = EventPlanCardStatus.done;
          ok++;
        } else {
          c.status = EventPlanCardStatus.failed;
          c.error = result.isConflict
              ? '保存冲突：文件已被外部修改，请重试'
              : (result.message ?? '写入失败');
          fail++;
        }
      } catch (e) {
        c.status = EventPlanCardStatus.failed;
        c.error = '写入失败：$e';
        fail++;
      }
      if (mounted) setState(() {});
    }
    if (mounted) {
      setState(() {
        _applying = false;
        _applySummary = fail == 0
            ? '已写入 $ok 张卡片，行数据可在编辑器中直接打开'
            : '写入完成：$ok 成功，$fail 失败（失败卡片已标红，可重新应用）';
      });
    }
  }

  void _toggleAll(bool? v) {
    final on = v ?? false;
    setState(() {
      for (final c in _cards) {
        if (c.status != EventPlanCardStatus.done) c.checked = on;
      }
    });
  }

  bool get _allChecked =>
      _cards.isNotEmpty &&
      _cards.every(
        (c) => c.checked || c.status == EventPlanCardStatus.done,
      );

  // ---------------- 构建 ----------------

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildHeader(),
        Divider(height: 1, color: palette.border),
        Expanded(
          child: switch (_step) {
            _FlowStep.input => _buildInput(),
            _FlowStep.generating => _buildGenerating(),
            _FlowStep.review => _buildReview(),
          },
        ),
      ],
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      child: Row(
        children: [
          Icon(FluentIcons.wand_24_regular, size: 15, color: accentColor),
          const SizedBox(width: 8),
          Text(
            switch (_step) {
              _FlowStep.input => '生成整段事件',
              _FlowStep.generating => '生成整段事件 · 生成中',
              _FlowStep.review => '生成整段事件 · 提案审阅',
            },
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: palette.textPrimary,
            ),
          ),
          const Spacer(),
          fluent.IconButton(
            icon: Icon(
              FluentIcons.dismiss_24_regular,
              size: 13,
              color: palette.textMuted,
            ),
            onPressed: () {
              if (_step == _FlowStep.generating) _activeGen?.cancel();
              Navigator.of(context).pop();
            },
          ),
        ],
      ),
    );
  }

  Widget _buildInput() {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '用一段自然语言描述想生成的剧情事件，AI 会产出「事件 + 对白 + 选项」的结构化提案，'
            '你逐卡确认后再写入当前模组。',
            style: TextStyle(fontSize: 11.5, color: palette.textHint, height: 1.5),
          ),
          const SizedBox(height: 8),
          fluent.TextBox(
            controller: _desc,
            placeholder: '例：开学日主角在教室遇到青梅竹马，好感+10，两个选项分支…',
            minLines: 4,
            maxLines: 8,
          ),
          if (_genError != null) ...[
            const SizedBox(height: 8),
            Text(
              _genError!,
              style: TextStyle(fontSize: 11.5, color: palette.statusDanger),
            ),
          ],
          const Spacer(),
          Align(
            alignment: Alignment.centerRight,
            child: ListenableBuilder(
              listenable: _desc,
              builder: (context, _) => fluent.FilledButton(
                onPressed: _desc.text.trim().isEmpty ? null : _generate,
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(FluentIcons.sparkle_24_regular, size: 13),
                    SizedBox(width: 6),
                    Text('生成提案', style: TextStyle(fontSize: 12)),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGenerating() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(height: 12),
          Text(
            _progress,
            style: TextStyle(fontSize: 12, color: palette.textHint),
          ),
        ],
      ),
    );
  }

  Widget _buildReview() {
    final checked = _checkedCards.length;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              '提案将写入 ${_cards.where((c) => c.cfg == 'EvtCfg').length} 个事件、'
              '${_cards.where((c) => c.cfg == 'TalkCfg').length} 条对白、'
              '${_cards.where((c) => c.cfg == 'OptionCfg').length} 个选项。'
              '勾选要写入的卡片，应用后即为普通配置行。',
              style: TextStyle(fontSize: 11, color: palette.textHint),
            ),
          ),
        ),
        if (_warnings.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: fluent.InfoBar(
              title: const Text('生成完成，有提示'),
              content: Text(
                _warnings.join('\n'),
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
              ),
              severity: fluent.InfoBarSeverity.warning,
              isLong: true,
            ),
          ),
        if (_applySummary != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: Text(
              _applySummary!,
              style: TextStyle(
                fontSize: 11.5,
                color: _cards.any((c) => c.status == EventPlanCardStatus.failed)
                    ? palette.statusDanger
                    : palette.statusOk,
              ),
            ),
          ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.all(12),
            itemCount: _cards.length,
            itemBuilder: (context, i) => Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _PlanCardTile(
                card: _cards[i],
                onToggle: (v) => setState(() => _cards[i].checked = v ?? false),
                onEdit: (text) => setState(() {
                  _cards[i].label = text;
                  _cards[i].row[_cards[i].labelField] = text;
                }),
              ),
            ),
          ),
        ),
        Divider(height: 1, color: palette.border),
        Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            children: [
              fluent.Checkbox(checked: _allChecked, onChanged: _toggleAll),
              const SizedBox(width: 6),
              Text('全选', style: TextStyle(fontSize: 11.5, color: palette.textHint)),
              const SizedBox(width: 12),
              Text(
                '已勾选 $checked / ${_cards.length}',
                style: TextStyle(fontSize: 11.5, color: palette.textHint),
              ),
              const Spacer(),
              if (_applying) ...[
                const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(strokeWidth: 1.5),
                ),
                const SizedBox(width: 6),
                Text('正在写入…', style: TextStyle(fontSize: 11.5, color: palette.textHint)),
                const SizedBox(width: 8),
              ],
              fluent.FilledButton(
                onPressed: _applying || checked == 0 ? null : _applyChecked,
                child: Text(
                  checked == 0 ? '应用勾选卡片' : '应用勾选卡片（$checked）',
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 单张计划卡：勾选框 + 表名徽章 + ID + 字段列表（效果字段附中文翻译）+
/// 主文本内联编辑 + 状态（失败标红）。
class _PlanCardTile extends StatefulWidget {
  const _PlanCardTile({required this.card, required this.onToggle, required this.onEdit});

  final EventPlanCard card;
  final ValueChanged<bool?> onToggle;
  final ValueChanged<String> onEdit;

  @override
  State<_PlanCardTile> createState() => _PlanCardTileState();
}

class _PlanCardTileState extends State<_PlanCardTile> {
  bool _editing = false;
  late final TextEditingController _ctrl = TextEditingController(text: widget.card.label);

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  EventPlanCard get _card => widget.card;
  bool get _failed => _card.status == EventPlanCardStatus.failed;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: _failed ? palette.tintDanger : palette.bgDeep,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: _failed
              ? palette.danger.withValues(alpha: 0.55)
              : _card.status == EventPlanCardStatus.done
                  ? palette.statusOk.withValues(alpha: 0.4)
                  : palette.border,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: fluent.Checkbox(
              checked: _card.status == EventPlanCardStatus.done ? true : _card.checked,
              onChanged:
                  _card.status == EventPlanCardStatus.done ? null : widget.onToggle,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                      decoration: BoxDecoration(
                        color: palette.tintInfo,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        _card.cfg,
                        style: TextStyle(fontSize: 10.5, color: palette.statusInfo),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'ID ${_card.id}',
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                        color: palette.textPrimary,
                      ),
                    ),
                    const SizedBox(width: 8),
                    _buildStatus(),
                  ],
                ),
                const SizedBox(height: 6),
                _buildLabel(),
                ..._buildFields(),
                if (_failed && _card.error != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    _card.error!,
                    style: TextStyle(fontSize: 11, color: palette.statusDanger),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatus() {
    return switch (_card.status) {
      EventPlanCardStatus.pending => const SizedBox.shrink(),
      EventPlanCardStatus.applying => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 10,
              height: 10,
              child: CircularProgressIndicator(strokeWidth: 1.2),
            ),
            const SizedBox(width: 4),
            Text('写入中…', style: TextStyle(fontSize: 10.5, color: palette.textHint)),
          ],
        ),
      EventPlanCardStatus.done => Text(
          '✓ 已写入',
          style: TextStyle(fontSize: 10.5, color: palette.statusOk),
        ),
      EventPlanCardStatus.failed => Text(
          '✗ 失败',
          style: TextStyle(fontSize: 10.5, color: palette.statusDanger),
        ),
    };
  }

  /// 主文本（标题/内容）：常态展示 + 编辑按钮；编辑态是 TextBox + 确定。
  Widget _buildLabel() {
    if (_editing) {
      return Row(
        children: [
          Expanded(
            child: fluent.TextBox(
              controller: _ctrl,
              autofocus: true,
              onSubmitted: (_) => _commitEdit(),
            ),
          ),
          const SizedBox(width: 6),
          fluent.FilledButton(
            onPressed: _commitEdit,
            child: const Text('确定', style: TextStyle(fontSize: 11)),
          ),
        ],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Text(
            _card.label,
            style: TextStyle(
              fontSize: 12,
              color: palette.textPrimary,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
        const SizedBox(width: 6),
        MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            onTap: () => setState(() => _editing = true),
            child: Text(
              '编辑',
              style: TextStyle(fontSize: 11, color: accentColor),
            ),
          ),
        ),
      ],
    );
  }

  void _commitEdit() {
    final text = _ctrl.text.trim();
    if (text.isNotEmpty) widget.onEdit(text);
    setState(() => _editing = false);
  }

  List<Widget> _buildFields() {
    final widgets = <Widget>[];
    for (final field in kEventPlanDisplayFields[_card.cfg] ?? const <String>[]) {
      final v = _card.row[field];
      final text = eventPlanDisplayValue(v);
      if (text.isEmpty) continue;
      widgets.add(
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: '${kEventPlanFieldLabels[field] ?? field}：',
                  style: TextStyle(fontSize: 11, color: palette.textMuted),
                ),
                TextSpan(
                  text: text,
                  style: TextStyle(fontSize: 11, color: palette.textBody),
                ),
              ],
            ),
          ),
        ),
      );
      // 效果/条件字段：中文翻译（/api/effect/parse 的 templateDesc 代入）。
      final desc = _card.effectDescs[field];
      if (desc != null && desc.isNotEmpty) {
        widgets.add(
          Padding(
            padding: const EdgeInsets.only(left: 8, top: 1),
            child: Text(
              '⇒ $desc',
              style: TextStyle(fontSize: 11, color: palette.statusInfo),
            ),
          ),
        );
      }
      final err = _card.effectErrors[field];
      if (err != null && err.isNotEmpty && desc == null) {
        widgets.add(
          Padding(
            padding: const EdgeInsets.only(left: 8, top: 1),
            child: Text(
              '⇒ $err',
              style: TextStyle(fontSize: 10.5, color: palette.statusWarn),
            ),
          ),
        );
      }
    }
    return widgets;
  }
}
