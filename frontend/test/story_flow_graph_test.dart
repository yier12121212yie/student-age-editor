import 'package:flutter_test/flutter_test.dart';

import '../lib/features/story/story_flow_models.dart';

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

    test('无 nextTalk2 时 check 不产生失败支', () {
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
      expect(
          g.edges.any((e) => e.kind == FlowEdgeKind.checkFail), isFalse);
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