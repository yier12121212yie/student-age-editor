// M6「生成整段事件」冒烟：提案 JSON → diff 卡片渲染（含效果中文翻译）、
// 勾选/全选、应用 → 写请求路径与载荷断言、失败卡标红。
// AI 上游一律 mock（forceNonStream + MockClient），不发真网；
// 后端端点（cfg 读写 / effect_validate / effect parse / revision）走
// ApiClient MockClient 捕获。
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:student_age_editor/core/api_client.dart';
import 'package:student_age_editor/features/ai/ai_client.dart';
import 'package:student_age_editor/features/ai/event_plan_flow.dart';
import 'package:student_age_editor/features/settings/settings_page.dart';

http.Response _json(Object body, [int code = 200]) => http.Response(
      jsonEncode(body), code,
      headers: {'content-type': 'application/json'},
    );

/// 提案 fixture：1 事件 + 3 对白 + 2 选项（talks[1] 带分支）。
Map<String, dynamic> _proposal() => {
      'evt': {
        'title': '开学日的教室',
        'type': 2,
        'mapId': 0,
        'condition': '[[7, 1, 105, 70]]',
        'effect': '[[1, 1, 3, 10]]',
      },
      'talks': [
        {
          'content': '开学第一天，教室里传来熟悉的声音。',
          'roleName': '旁白',
          'next': 1,
        },
        {
          'content': '青梅竹马转过身来。',
          'roleIds': [102],
          'effect': '[[1, 1, 3, 5]]',
          'options': [
            {'content': '打招呼', 'next': 2},
            {'content': '装作没看见'},
          ],
        },
        {'content': '你们聊了很久。'},
      ],
    };

/// 既有 EvtCfg（用于事件 ID 分配：1200001 已占 → 新事件应为 1200002）。
final Map<String, dynamic> _evtTable = {
  '1200001': {
    'id': 1200001,
    'title': '既有事件',
    'talkId': [1200001001],
  },
};

void main() {
  // 每例可配置：效果码校验结果、失败的写路径。
  final apiReqs = <String>[]; // 'METHOD path'
  final apiBodies = <Map<String, dynamic>>[]; // 与 apiReqs 对齐（body 已解码）
  final aiReqs = <Map<String, dynamic>>[];
  Set<String> failPutPaths = {};

  setUp(() {
    apiReqs.clear();
    apiBodies.clear();
    aiReqs.clear();
    failPutPaths = {};
  });

  Future<void> mountPage(
    WidgetTester tester, {
    Map<String, dynamic> Function()? proposal,
    Map<String, dynamic>? validateResp,
    bool fallbackText = false,
  }) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    ApiClient.instance.client = MockClient((req) async {
      final p = req.url.path;
      final body =
          req.body.isEmpty ? null : jsonDecode(req.body) as Map<String, dynamic>;
      apiReqs.add('${req.method} $p');
      apiBodies.add({'method': req.method, 'path': p, 'body': body});
      if (p == '/api/workspace/revision') {
        return _json({'revision': 'aaa111bbb222ccc'});
      }
      if (req.method == 'GET' && p == '/api/cfg/EvtCfg') {
        return _json({'cfg': 'EvtCfg', 'data': _evtTable, 'exists': true});
      }
      if (req.method == 'GET' &&
          (p == '/api/cfg/TalkCfg' || p == '/api/cfg/OptionCfg')) {
        return _json({'cfg': p.split('/').last, 'data': {}, 'exists': true});
      }
      if (p == '/api/effect_validate') {
        return _json(
            validateResp ??
                {'valid': true, 'translations': [], 'errors': [], 'status': 'ok'});
      }
      if (p == '/api/effect/parse') {
        // 效果/条件文本是嵌套列表（如 [[1, 1, 3, 10]]）：取末尾数字做 V 槽。
        final text = (body?['text'] ?? '').toString();
        final m = RegExp(r'(\d+)\s*\]*$').firstMatch(text);
        final v = m?.group(1) ?? '0';
        return _json({
          'ok': true,
          'status': 'ok',
          'rows': [
            {
              'primary': 1,
              'secondary': 1,
              'display': text,
              'template': {'code': '[1, 1, @ATTR@, V]', 'desc': '增加 @ATTR@ 数量 V'},
              'slots': [
                {'name': 'ATTR', 'value': '好感', 'kind': 'dict', 'label': '属性'},
                {'name': 'V', 'value': v},
              ],
            },
          ],
        });
      }
      if (req.method == 'PUT' && p.startsWith('/api/cfg/')) {
        if (failPutPaths.contains(p)) return _json({'error': '磁盘写入失败'}, 500);
        return _json({
          'cfg': p.split('/').last,
          'mtime_ns': 1,
          'snapshot': 'snap',
          'applied_set': 1,
          'applied_remove': 0,
          'revision': 'rev${apiReqs.length}',
        });
      }
      return _json({'ok': true});
    });

    final settings = AiSettings(
      provider: 'openai_compatible',
      baseUrl: 'http://ai.test',
      apiKey: 'test-key',
      model: 'mock-model',
    );
    final gen = EventPlanGenerator(
      settings: settings,
      modName: 'test_mod',
      // 注入假 AiClient（非流式 + MockClient 上游），不发真网。
      clientFactory: () => AiClient(
        settings,
        forceNonStream: true,
        clientFactory: () => MockClient((req) async {
        aiReqs.add(jsonDecode(req.body) as Map<String, dynamic>);
        final messages =
            (aiReqs.last['messages'] as List).cast<Map<String, dynamic>>();
        final hasToolResult = messages.any((m) => m['role'] == 'tool');
        if (!hasToolResult) {
          // fallbackText=true：模型不调工具，把提案 JSON 放在回复文本里。
          if (fallbackText) {
            return _json({
              'choices': [
                {
                  'message': {
                    'content': '好的，提案如下：\n```json\n'
                        '${jsonEncode(proposal?.call() ?? _proposal())}\n```\n请查收',
                  },
                  'finish_reason': 'stop',
                },
              ],
            });
          }
          return _json({
            'choices': [
              {
                'message': {
                  'content': '',
                  'tool_calls': [
                    {
                      'id': 'call_1',
                      'type': 'function',
                      'function': {
                        'name': kEventPlanToolName,
                        'arguments': jsonEncode(proposal?.call() ?? _proposal()),
                      },
                    },
                  ],
                },
                'finish_reason': 'tool_calls',
              },
            ],
          });
        }
        return _json({
          'choices': [
            {
              'message': {'content': '提案已提交。'},
              'finish_reason': 'stop',
            },
          ],
        });
        }),
      ),
    );

    await tester.pumpWidget(
      fluent.FluentApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          body: EventPlanFlowPage(
            modName: 'test_mod',
            settings: settings,
            generator: gen,
          ),
        ),
      ),
    );
    await tester.pump();
  }

  /// 输入描述并生成，推进到审阅步（生成中有 spinner，不能 pumpAndSettle）。
  Future<void> generateAndReview(WidgetTester tester) async {
    await tester.enterText(find.byType(fluent.TextBox), '开学日教室相遇');
    await tester.pump();
    await tester.tap(find.text('生成提案'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
  }

  List<Map<String, dynamic>> putsOf() => [
        for (final b in apiBodies)
          if (b['method'] == 'PUT') b,
      ];

  testWidgets('提案 JSON → diff 卡片渲染（含效果中文翻译与 ID 分配）', (tester) async {
    await mountPage(tester);
    expect(find.text('生成整段事件'), findsOneWidget);
    await generateAndReview(tester);

    // 卡片：1 事件（1200002）+ 3 对白（1200002001..003）+ 2 选项（120000201/02）。
    expect(find.text('EvtCfg'), findsOneWidget);
    expect(find.text('ID 1200002'), findsOneWidget);
    expect(find.text('ID 1200002001'), findsOneWidget);
    expect(find.text('ID 1200002002'), findsOneWidget);
    expect(find.text('ID 1200002003'), findsOneWidget);
    expect(find.text('ID 120000201'), findsOneWidget);
    expect(find.text('ID 120000202'), findsOneWidget);
    expect(find.text('TalkCfg'), findsNWidgets(3));
    expect(find.text('OptionCfg'), findsNWidgets(2));
    // 对白/选项内容上卡。
    expect(find.text('开学第一天，教室里传来熟悉的声音。'), findsOneWidget);
    expect(find.text('打招呼'), findsOneWidget);
    // 效果字段中文翻译：/api/effect/parse 的 templateDesc 代入槽值
    //（事件效果 V=10、对白效果 V=5）。
    expect(find.text('⇒ 增加 好感 数量 10'), findsOneWidget);
    expect(find.text('⇒ 增加 好感 数量 5'), findsOneWidget);
    // 生成阶段调用过效果码校验（evt.condition/effect + talk.effect，每字段
    // 生成与回填各一轮 → 6 次）。
    expect(apiReqs.where((r) => r == 'POST /api/effect_validate'), hasLength(6));
    // ID 分配读过既有表：EvtCfg 全量 + Talk/Option 前缀增量。
    expect(apiReqs, contains('GET /api/cfg/EvtCfg'));
    expect(
      apiReqs.where((r) => r.startsWith('GET /api/cfg/TalkCfg')),
      hasLength(1),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('提案未走工具调用时从回复文本兜底提取 JSON 并给出警告', (tester) async {
    await mountPage(
      tester,
      proposal: () => {
        'evt': {'title': '兜底事件'},
        'talks': [
          {'content': '兜底对白'},
        ],
      },
      fallbackText: true,
    );
    await generateAndReview(tester);
    // 兜底路径同样出卡，但顶部 InfoBar 有警告。
    expect(find.text('ID 1200002'), findsOneWidget);
    expect(find.text('兜底事件'), findsOneWidget);
    expect(find.text('生成完成，有提示'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('勾选/全选联动计数', (tester) async {
    await mountPage(tester);
    await generateAndReview(tester);
    expect(find.text('已勾选 6 / 6'), findsOneWidget);
    // 取消第一张卡（事件卡）→ 计数 5。
    await tester.tap(find.byType(fluent.Checkbox).first);
    await tester.pump();
    expect(find.text('已勾选 5 / 6'), findsOneWidget);
    // 全选恢复 → 6。
    await tester.tap(find.byType(fluent.Checkbox).last);
    await tester.pump();
    expect(find.text('已勾选 6 / 6'), findsOneWidget);
    // 烧掉残留的短时定时器（组件层防抖/动画），避免 teardown 报 pending timer。
    await tester.pump(const Duration(seconds: 5));
    expect(tester.takeException(), isNull);
  });

  testWidgets('应用 → 写请求路径与载荷断言（按 ID 规范落普通 Cfg 行）', (tester) async {
    await mountPage(tester);
    await generateAndReview(tester);
    // putRaw 经 compute 在真 isolate 里编码，FakeAsync 区内永不完成：
    // 用 runAsync 放行真实异步并轮询到 6 张卡全部发出。
    await tester.runAsync(() async {
      await tester.tap(find.text('应用勾选卡片（6）'));
      for (var i = 0; i < 200 && putsOf().length < 6; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    final puts = putsOf();
    expect(puts, hasLength(6));
    // 每张卡一次单行 patch PUT（乐观锁：首次带刷新到的 workspace revision）。
    // 写入顺序 = 卡片顺序：事件 → 对白1 → 对白2 → 选项1 → 选项2 → 对白3
    //（选项卡紧跟其父对白落卡）。
    expect(puts[0]['path'], '/api/cfg/EvtCfg');
    expect(puts[0]['body']['revision'], 'aaa111bbb222ccc');
    final evtRow = puts[0]['body']['patch']['set']['1200002'] as Map;
    expect(evtRow['id'], 1200002);
    expect(evtRow['title'], '开学日的教室');
    expect(evtRow['talkId'], [1200002001]);
    expect(evtRow['condition'], [
      [7, 1, 105, 70]
    ]);
    expect(evtRow['effect'], [
      [1, 1, 3, 10]
    ]);
    expect(evtRow['maxcount'], 1);
    expect(evtRow['probability'], [1]);

    // 对白行：id int、nextTalk 连线、option 汇总。
    final talk1 =
        puts[1]['body']['patch']['set']['1200002001'] as Map;
    expect(puts[1]['path'], '/api/cfg/TalkCfg');
    expect(talk1['id'], 1200002001);
    expect(talk1['nextTalk'], [1200002002]);
    expect(talk1['nextTalk2'], isEmpty);
    expect(talk1['roleName'], '旁白');
    final talk2 =
        puts[2]['body']['patch']['set']['1200002002'] as Map;
    expect(talk2['roleIds'], [102]);
    expect(talk2['option'], [120000201, 120000202]);
    expect(talk2['effect'], [
      [1, 1, 3, 5]
    ]);
    // 选项行：talkId 指向跳转对白（next=-1/缺省 → 空数组）。
    final opt1 = puts[3]['body']['patch']['set']['120000201'] as Map;
    expect(puts[3]['path'], '/api/cfg/OptionCfg');
    expect(opt1['content'], '打招呼');
    expect(opt1['talkId'], [1200002003]);
    final opt2 = puts[4]['body']['patch']['set']['120000202'] as Map;
    expect(opt2['content'], '装作没看见');
    expect(opt2['talkId'], isEmpty);
    // 末位对白行：无下家。
    final talk3 = puts[5]['body']['patch']['set']['1200002003'] as Map;
    expect(puts[5]['path'], '/api/cfg/TalkCfg');
    expect(talk3['nextTalk'], isEmpty);

    // 成功收尾：全部卡片标记已写入。
    expect(find.text('✓ 已写入'), findsNWidgets(6));
    expect(find.textContaining('已写入 6 张卡片'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('失败卡标红保留，成功卡不受影响', (tester) async {
    await mountPage(tester);
    await generateAndReview(tester);
    failPutPaths = {'/api/cfg/OptionCfg'};
    // 同上：runAsync 放行 compute isolate，等 6 张卡全部发出后回 fake 区断言。
    await tester.runAsync(() async {
      await tester.tap(find.text('应用勾选卡片（6）'));
      for (var i = 0; i < 200 && putsOf().length < 6; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // 4 成功 + 2 失败；失败卡保留红色错误文案，可重新应用。
    expect(find.text('✓ 已写入'), findsNWidgets(4));
    expect(find.text('✗ 失败'), findsNWidgets(2));
    expect(find.textContaining('写入失败'), findsWidgets);
    expect(find.textContaining('2 失败'), findsOneWidget);
    // 成功路径仍然写入了 EvtCfg/TalkCfg。
    final puts = putsOf();
    expect(puts.length, 6);
    expect(
      puts.where((p) => p['path'] == '/api/cfg/TalkCfg'),
      hasLength(3),
    );
    expect(tester.takeException(), isNull);
  });

  test('allocateEventId / extractProposalJson / effect 文本互转（纯函数）', () {
    expect(allocateEventId({}), 1200001);
    expect(allocateEventId(_evtTable), 1200002);
    expect(
      allocateEventId({
        for (var i = 1200001; i < 1200005; i++) '$i': {'id': i},
      }),
      1200005,
    );
    // 兜底提取：代码栅栏包裹的 JSON。
    final p = _proposal();
    final extracted = extractProposalJson('好的，提案如下：\n```json\n${jsonEncode(p)}\n```\n请查收');
    expect(extracted, isNotNull);
    expect(extracted!['evt']['title'], '开学日的教室');
    expect(extractProposalJson('没有 JSON'), isNull);
    // 效果码：文本 ⇄ 行存储。
    expect(effectTextFromValue([
      [1, 1, 3, 5]
    ]), '[1, 1, 3, 5]');
    expect(
      effectValueFromProposal('[[7, 1, 105, 70]]'),
      [
        [7, 1, 105, 70]
      ],
    );
    expect(effectValueFromProposal('不是 JSON'), isEmpty);
    expect(effectModeForField('condition'), 'condition');
    expect(effectModeForField('effect'), 'effect');
  });
}
