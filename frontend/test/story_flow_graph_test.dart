import 'package:flutter_test/flutter_test.dart';

import 'package:student_age_editor/features/story/story_flow_models.dart';
import 'package:student_age_editor/features/story/story_flow_node_presets.dart';

void main() {
  group('buildFlowGraph 线性链', () {
    test('nextTalk 逐条出边', () {
      final talks = <String, dynamic>{
        '1000001001': {
          'roleName': '旁白', 'content': 'a', 'nextTalk': [1000001002],
        },
        '1000001002': {'roleName': '旁白', 'content': 'b', 'nextTalk': []},
      };
      final g = buildFlowGraph(
          talks: talks, options: {}, prefixes: ['1000001'],
          starts: ['1000001001']);
      expect(g.nodes.where((n) => n.kind == FlowNodeKind.talk).length, 2);
      expect(g.nodes.every((n) => n.isNarrator), isTrue);
      expect(g.edges.length, 1);
      expect(g.edges.first.kind, FlowEdgeKind.next);
      expect(g.edges.first.from, '1000001001');
      expect(g.edges.first.to, '1000001002');
    });

    test('浮点 id 归一与去尾', () {
      final talks = <String, dynamic>{
        '1000001001': {'content': 'a', 'nextTalk': [1000001002.0]},
        '1000001002': {'content': 'b', 'nextTalk': []},
      };
      final g = buildFlowGraph(
          talks: talks, options: {}, prefixes: ['1000001'],
          starts: ['1000001001']);
      expect(g.edges.first.to, '1000001002');
    });

    test('nextTalk 多目标逐条出边', () {
      final talks = <String, dynamic>{
        '1000001001': {
          'content': 'a', 'nextTalk': [1000001002, 1000001003],
        },
        '1000001002': {'content': 'b'},
        '1000001003': {'content': 'c'},
      };
      final g = buildFlowGraph(
          talks: talks, options: {}, prefixes: ['1000001'],
          starts: ['1000001001']);
      expect(g.edges.where((e) => e.kind == FlowEdgeKind.next).length, 2);
    });
  });

  group('检定双支', () {
    test('check + nextTalk + nextTalk2 → checkPass/checkFail', () {
      final talks = <String, dynamic>{
        '1000001001': {
          'content': '检定', 'check': [[80301, 1]],
          'nextTalk': [1000001002], 'nextTalk2': [1000001003],
        },
        '1000001002': {'content': '成功'},
        '1000001003': {'content': '失败'},
      };
      final g = buildFlowGraph(
          talks: talks, options: {}, prefixes: ['1000001'],
          starts: ['1000001001']);
      final talk = g.nodeById('1000001001')!;
      expect(talk.hasCheck, isTrue);
      final kinds = g.edges.map((e) => e.kind).toSet();
      expect(kinds, {FlowEdgeKind.checkPass, FlowEdgeKind.checkFail});
    });

    test('有检定但失败支暂空 → nextTalk 记为 checkPass，无失败支边', () {
      final talks = <String, dynamic>{
        '1000001001': {
          'content': 'x', 'check': [[80301, 1]], 'nextTalk': [1000001002],
        },
        '1000001002': {'content': 'y'},
      };
      final g = buildFlowGraph(
          talks: talks, options: {}, prefixes: ['1000001'],
          starts: ['1000001001']);
      expect(g.nodeById('1000001001')!.hasCheck, isTrue);
      // 双支节点：成功支连线恒为 checkPass（画布「检定成功」端口命中）
      expect(g.edges.map((e) => e.kind).toSet(), {FlowEdgeKind.checkPass});
      expect(g.edges.any((e) => e.kind == FlowEdgeKind.checkFail), isFalse);
    });
  });

  group('flowPortKinds 端口规则', () {
    test('无检定对白：下一句 + 选项', () {
      final n = const FlowNode(kind: FlowNodeKind.talk, id: 'a');
      expect(flowPortKinds(n),
          [FlowEdgeKind.next, FlowEdgeKind.option]);
    });

    test('有检定对白：成功/失败双端口 + 选项（失败支可暂空）', () {
      final n = const FlowNode(
          kind: FlowNodeKind.talk, id: 'a', hasCheck: true);
      expect(flowPortKinds(n), [
        FlowEdgeKind.checkPass,
        FlowEdgeKind.checkFail,
        FlowEdgeKind.option,
      ]);
    });

    test('选项节点：主支/支线，缺失节点：无输出端口', () {
      expect(flowPortKinds(const FlowNode(kind: FlowNodeKind.option, id: 'o')),
          [FlowEdgeKind.optionMain, FlowEdgeKind.optionSide]);
      expect(flowPortKinds(const FlowNode(kind: FlowNodeKind.missing, id: 'm')),
          isEmpty);
    });

    test('端口类型经 fieldForEdge 均可写回（nextEvt 除外，其不进端口）', () {
      for (final n in [
        const FlowNode(kind: FlowNodeKind.talk, id: 'a'),
        const FlowNode(kind: FlowNodeKind.talk, id: 'b', hasCheck: true),
        const FlowNode(kind: FlowNodeKind.option, id: 'o'),
      ]) {
        for (final k in flowPortKinds(n)) {
          expect(fieldForEdge(k), isNotNull);
        }
      }
    });
  });

  group('选项分支', () {
    test('选项节点与主支/支线', () {
      final talks = <String, dynamic>{
        '1000001001': {
          'content': '问', 'nextTalk': [], 'option': [100000101],
        },
      };
      final opts = <String, dynamic>{
        '100000101': {
          'content': '选 A', 'talkId': [1000001002], 'talkId2': [1000001003],
        },
      };
      final g = buildFlowGraph(
          talks: talks, options: opts, prefixes: ['1000001'],
          starts: ['1000001001']);
      expect(g.nodeById('100000101')!.kind, FlowNodeKind.option);
      final kinds = g.edges.map((e) => e.kind).toSet();
      expect(kinds, {
        FlowEdgeKind.option, // 对白 → 选项
        FlowEdgeKind.optionMain, // 选项主支 → 对白
        FlowEdgeKind.optionSide, // 选项支线 → 对白
      });
      expect(g.nodeById('1000001002'), isNotNull);
      expect(g.nodeById('1000001003'), isNotNull);
    });

    test('缺失选项 → 终端缺失节点', () {
      final talks = <String, dynamic>{
        '1000001001': {
          'content': 'x', 'nextTalk': [], 'option': [100000105],
        },
      };
      final g = buildFlowGraph(
          talks: talks, options: {}, prefixes: ['1000001'],
          starts: ['1000001001']);
      final n = g.nodeById('100000105')!;
      expect(n.kind, FlowNodeKind.missing);
      expect(n.title, contains('缺失选项'));
    });

    test('nextEvtId → 终端跳转边（不参与布局出边）', () {
      final talks = <String, dynamic>{
        '1000001001': {'content': 'a', 'nextTalk': [1000001002]},
        '1000001002': {'content': 'b'},
      };
      final opts = <String, dynamic>{
        '100000101': {'content': '跳', 'nextEvtId': 2000001},
      };
      final g = buildFlowGraph(
          talks: talks, options: opts, prefixes: ['1000001'],
          starts: ['1000001001']);
      final ev = g.edges
          .firstWhere((e) => e.kind == FlowEdgeKind.nextEvt);
      expect(ev.to, '2000001');
      expect(g.nodeById('2000001')!.kind, FlowNodeKind.missing);
      // 终端边不出现在布局出边集合
      expect(g.edgesFrom('100000101'), isEmpty);
    });
  });

  group('跨事件截断', () {
    test('指向他事件对白 → 缺失节点 + 事件标题', () {
      final talks = <String, dynamic>{
        '1000001001': {
          'content': 'a', 'nextTalk': [2000001001],
        },
      };
      final g = buildFlowGraph(
        talks: talks,
        options: {},
        prefixes: ['1000001'],
        starts: ['1000001001'],
        evtTitles: {'2000001': '毕业旅行'},
      );
      final n = g.nodeById('2000001001')!;
      expect(n.kind, FlowNodeKind.missing);
      expect(n.title, contains('毕业旅行'));
      expect(n.title, contains('2000001'));
    });
  });

  group('layoutFlow 分层 DAG + 防环', () {
    test('环不造成死循环且分层正确', () {
      final talks = <String, dynamic>{
        '1000001001': {'content': 'a', 'nextTalk': [1000001002]},
        '1000001002': {'content': 'b', 'nextTalk': [1000001001]},
      };
      final g = buildFlowGraph(
          talks: talks, options: {}, prefixes: ['1000001'],
          starts: ['1000001001']);
      final pos = layoutFlow(graph: g);
      expect(pos.containsKey('1000001001'), isTrue);
      expect(pos.containsKey('1000001002'), isTrue);
      final a = pos['1000001001']!;
      final b = pos['1000001002']!;
      expect((b.dx - a.dx).abs(), greaterThan(0.0)); // 不同列
    });

    test('分支节点同行不同列', () {
      final talks = <String, dynamic>{
        '1000001001': {
          'content': 'x', 'check': [[80301, 1]],
          'nextTalk': [1000001002], 'nextTalk2': [1000001003],
        },
        '1000001002': {'content': 'y'},
        '1000001003': {'content': 'z'},
      };
      final g = buildFlowGraph(
          talks: talks, options: {}, prefixes: ['1000001'],
          starts: ['1000001001']);
      final pos = layoutFlow(graph: g);
      expect(pos['1000001002']!.dy, isNot(pos['1000001003']!.dy));
    });
  });

  group('插件流程卡片', () {
    test('match 命中 → 对白节点带卡型标注', () {
      final talks = <String, dynamic>{
        '1000001001': {'content': 'x', 'screenEffect': [[4007]]},
        '1000001002': {'content': 'y'},
      };
      final cards = <Map<String, dynamic>>[
        {
          'type_id': 'phone',
          'name': '打电话',
          'applies_to': 'talk',
          'color': '#3498DB',
          'match': {'field': 'screenEffect', 'equals': [4007]},
        },
      ];
      final g = buildFlowGraph(
          talks: talks, options: {}, prefixes: ['1000001'],
          starts: ['1000001001'], cardStyles: cards);
      final a = g.nodeById('1000001001')!;
      expect(a.cardKey, 'phone');
      expect(a.cardLabel, '打电话');
      expect(a.cardColor, '#3498DB');
      expect(g.nodeById('1000001002')!.cardKey, isEmpty);
    });

    test('选项卡型标注 option 节点且不影响缺失节点', () {
      final talks = <String, dynamic>{
        '1000001001': {
          'content': '问', 'nextTalk': [], 'option': [100000101],
        },
      };
      final opts = <String, dynamic>{
        '100000101': {'content': '表白', 'talkId': [], 'talkId2': []},
      };
      final cards = <Map<String, dynamic>>[
        {
          'type_id': 'confess',
          'name': '告白选项',
          'applies_to': 'option',
          'color': '#E91E63',
          'match': {'field': 'content', 'equals': '表白'},
        },
      ];
      final g = buildFlowGraph(
          talks: talks, options: opts, prefixes: ['1000001'],
          starts: ['1000001001'], cardStyles: cards);
      expect(g.nodeById('100000101')!.cardKey, 'confess');
      expect(g.nodeById('100000101')!.cardColor, '#E91E63');
    });
  });

  group('内置节点预设', () {
    final builtin = builtinFlowCardSpecs();

    test('cg_play：screenEffect [4015,id] 与 [[4015,id]] 均命中', () {
      final talks = <String, dynamic>{
        '1000001001': {'content': 'a', 'screenEffect': [4015, 2]},
        '1000001002': {'content': 'b', 'screenEffect': [[4015, 3]]},
      };
      final g = buildFlowGraph(
          talks: talks, options: {}, prefixes: ['1000001'],
          starts: ['1000001001'], cardStyles: builtin);
      expect(g.nodeById('1000001001')!.cardKey, 'cg_play');
      expect(g.nodeById('1000001002')!.cardKey, 'cg_play');
      expect(g.nodeById('1000001001')!.cardLabel, '播放CG');
    });

    test('cg_end / transition 按码区分（4017 vs 4006）', () {
      final talks = <String, dynamic>{
        '1000001001': {'content': 'a', 'screenEffect': [4017]},
        '1000001002': {'content': 'b', 'screenEffect': [4006]},
        '1000001003': {'content': 'c', 'screenEffect': [4010]},
      };
      final g = buildFlowGraph(
          talks: talks, options: {}, prefixes: ['1000001'],
          starts: ['1000001001'], cardStyles: builtin);
      expect(g.nodeById('1000001001')!.cardKey, 'cg_end');
      expect(g.nodeById('1000001002')!.cardKey, 'transition');
      expect(g.nodeById('1000001003')!.cardKey, 'transition');
    });

    test('未识别码（4007 电话）不命中任何内置预设', () {
      final talks = <String, dynamic>{
        '1000001001': {'content': 'a', 'screenEffect': [4007, 1, 2]},
      };
      final g = buildFlowGraph(
          talks: talks, options: {}, prefixes: ['1000001'],
          starts: ['1000001001'], cardStyles: builtin);
      expect(g.nodeById('1000001001')!.cardKey, isEmpty);
    });

    test('evt_goto：选项 nextEvtId 非空命中', () {
      final opts = <String, dynamic>{
        '100000101': {'content': 'x', 'nextEvtId': 1000002},
        '100000102': {'content': 'y', 'nextEvtId': 0},
      };
      final g = buildFlowGraph(
          talks: {}, options: opts, prefixes: ['1000001'],
          starts: const [], cardStyles: builtin);
      expect(g.nodeById('100000101')!.cardKey, 'evt_goto');
      expect(g.nodeById('100000102')!.cardKey, isEmpty);
    });

    test('插件卡优先于内置预设（first-match）', () {
      final talks = <String, dynamic>{
        '1000001001': {'content': '表白', 'screenEffect': [4017]},
      };
      final plugin = <Map<String, dynamic>>[
        {
          'type_id': 'confess_end',
          'name': '告白结局',
          'applies_to': 'talk',
          'color': '#111111',
          'match': {'field': 'content', 'equals': '表白'},
        },
      ];
      // 插件在前 → 命中插件卡；否则命中内置 cg_end
      final a = buildFlowGraph(
          talks: talks, options: {}, prefixes: ['1000001'],
          starts: ['1000001001'], cardStyles: [...plugin, ...builtin]);
      expect(a.nodeById('1000001001')!.cardKey, 'confess_end');
      final b = buildFlowGraph(
          talks: talks, options: {}, prefixes: ['1000001'],
          starts: ['1000001001'], cardStyles: builtin);
      expect(b.nodeById('1000001001')!.cardKey, 'cg_end');
    });

    test('fxSummary 摘要：CG 带 id/未选、转场名、多效果拼接', () {
      final talks = <String, dynamic>{
        '1000001001': {'content': 'a', 'screenEffect': [4015, 12]},
        '1000001002': {'content': 'b', 'screenEffect': [4015, 0]},
        '1000001003': {'content': 'c', 'screenEffect': [4006]},
        '1000001004': {
          'content': 'd',
          'screenEffect': [
            [4012],
            [4001],
          ],
        },
        '1000001005': {'content': 'e'},
      };
      final g = buildFlowGraph(
          talks: talks, options: {}, prefixes: ['1000001'],
          starts: ['1000001001']);
      expect(g.nodeById('1000001001')!.fxSummary, 'CG·12');
      expect(g.nodeById('1000001002')!.fxSummary, 'CG·未选');
      expect(g.nodeById('1000001003')!.fxSummary, '黑屏');
      expect(g.nodeById('1000001004')!.fxSummary, '闪白+抖动');
      expect(g.nodeById('1000001005')!.fxSummary, isEmpty);
    });

    test('hasParamBadges 计入 fxSummary', () {
      final talks = <String, dynamic>{
        '1000001001': {'content': 'a', 'screenEffect': [4002]},
      };
      final g = buildFlowGraph(
          talks: talks, options: {}, prefixes: ['1000001'],
          starts: ['1000001001']);
      expect(g.nodeById('1000001001')!.hasParamBadges, isTrue);
    });
  });

  group('建边/断边', () {
    test('pushEdgeTarget 追加与去重', () {
      final rec = <String, dynamic>{'nextTalk': [1]};
      pushEdgeTarget(rec, 'nextTalk', 2);
      expect(rec['nextTalk'], [1, 2]);
      pushEdgeTarget(rec, 'nextTalk', 2);
      expect(rec['nextTalk'], [1, 2]);
      // 浮点字符串归一
      pushEdgeTarget(rec, 'nextTalk', '3.0');
      expect(rec['nextTalk'], [1, 2, 3]);
    });

    test('removeEdgeTarget 移除指定目标', () {
      final rec = <String, dynamic>{'option': [101, 102]};
      removeEdgeTarget(rec, 'option', 101);
      expect(rec['option'], [102]);
    });

    test('fieldForEdge 映射', () {
      expect(fieldForEdge(FlowEdgeKind.next), 'nextTalk');
      expect(fieldForEdge(FlowEdgeKind.checkPass), 'nextTalk');
      expect(fieldForEdge(FlowEdgeKind.checkFail), 'nextTalk2');
      expect(fieldForEdge(FlowEdgeKind.option), 'option');
      expect(fieldForEdge(FlowEdgeKind.optionMain), 'talkId');
      expect(fieldForEdge(FlowEdgeKind.optionSide), 'talkId2');
      expect(fieldForEdge(FlowEdgeKind.nextEvt), isNull);
    });
  });
}