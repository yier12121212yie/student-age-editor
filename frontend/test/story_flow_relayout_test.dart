/// 阶段 7「局部重排」纯函数回归。
///
/// 这个功能的风险不在「排得齐不齐」（网格算法复用全图布局，早已验证），而在
/// **越界**：把没选中的节点顺手拖走、把选中块瞬移到画布原点、让孤儿节点从结果
/// 里消失（宿主 addAll 后节点会叠在 (0,0) 上）。所以断言基本都围绕 key 集合与
/// 包围盒左上角，而不是某个像素值——像素只在少数几例里做精确校验，用来钉死
/// 「同输入必同输出」。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:student_age_editor/features/story/story_flow_models.dart';
import 'package:student_age_editor/features/story/story_flow_relayout.dart';

FlowNode _talk(String id) =>
    FlowNode(kind: FlowNodeKind.talk, id: id, content: '对白 $id');
FlowNode _opt(String id) =>
    FlowNode(kind: FlowNodeKind.option, id: id, content: '选项 $id');
FlowNode _missing(String id) =>
    FlowNode(kind: FlowNodeKind.missing, id: id, content: '缺失 $id');

FlowEdge _next(String from, String to) =>
    FlowEdge(from: from, to: to, kind: FlowEdgeKind.next);

FlowGraph _g(List<FlowNode> nodes, List<FlowEdge> edges) =>
    FlowGraph(nodes: nodes, edges: edges, starts: [nodes.first.id]);

/// 一批坐标的包围盒左上角（测试自己算一份，别用被测函数的私有实现）。
Offset _boxLeftTop(Iterable<Offset> pts) {
  double? x;
  double? y;
  for (final p in pts) {
    if (x == null || p.dx < x) x = p.dx;
    if (y == null || p.dy < y) y = p.dy;
  }
  return Offset(x!, y!);
}

void main() {
  group('诱导子图：只动选中的', () {
    test('选中链中段：未选中的父/子节点不进结果，也不被改坐标', () {
      final graph = _g(
        [_talk('t1'), _talk('t2'), _talk('t3'), _talk('t4')],
        [_next('t1', 't2'), _next('t2', 't3'), _next('t3', 't4')],
      );
      final positions = <String, Offset>{
        't1': const Offset(40, 40),
        't2': const Offset(400, 400),
        't3': const Offset(900, 60),
        't4': const Offset(10, 10),
      };

      final out = relayoutSelection(
        graph: graph,
        positions: positions,
        selected: {'t2', 't3'},
      );

      expect(out.keys.toSet(), {'t2', 't3'});
      expect(
        out.keys.toSet().difference({'t2', 't3'}),
        isEmpty,
        reason: '返回集越界即宿主越界写，最严重的一种违约',
      );
      expect(out, {'t2': const Offset(400, 60), 't3': const Offset(650, 60)});
      expect(positions['t1'], const Offset(40, 40));
      expect(positions['t4'], const Offset(10, 10));
    });

    test('真实建图：只选中分叉的一半，另一半与兄弟分支都不动', () {
      final graph = buildFlowGraph(
        talks: <String, dynamic>{
          '1000001001': {
            'roleName': '旁白',
            'content': 'a',
            'nextTalk': [1000001002],
          },
          '1000001002': {
            'content': 'b',
            'nextTalk': [1000001003, 1000001004],
          },
          '1000001003': {'content': 'c'},
          '1000001004': {'content': 'd'},
        },
        options: const <String, dynamic>{},
        prefixes: const ['1000001'],
        starts: const ['1000001001'],
      );
      final positions = <String, Offset>{
        '1000001001': const Offset(40, 40),
        '1000001002': const Offset(500, 500),
        '1000001003': const Offset(900, 900),
        '1000001004': const Offset(1400, 40),
      };
      final selected = {'1000001002', '1000001003'};

      final out = relayoutSelection(
        graph: graph,
        positions: positions,
        selected: selected,
      );

      expect(out.keys.toSet(), selected);
      expect(out, {
        '1000001002': const Offset(500, 500),
        '1000001003': const Offset(750, 500),
      });
      expect(positions['1000001004'], const Offset(1400, 40));
    });
  });

  group('锚点：原地理齐，不瞬移', () {
    test('新包围盒左上角 == 选中块当前包围盒左上角', () {
      final graph = _g(
        [_talk('a'), _talk('b'), _talk('c')],
        [_next('a', 'b'), _next('a', 'c')],
      );
      final positions = <String, Offset>{
        'a': const Offset(1200, 800),
        'b': const Offset(1500, 300),
        'c': const Offset(900, 1100),
      };

      final out = relayoutSelection(
        graph: graph,
        positions: positions,
        selected: {'a', 'b', 'c'},
      );

      expect(out.values.length, 3);
      expect(
        _boxLeftTop(out.values),
        _boxLeftTop([
          for (final id in ['a', 'b', 'c']) positions[id]!,
        ]),
        reason: '选中块整体留在手摆的那片区域里（900,300 这个角本身可能是空的）',
      );
      expect(out, {
        'a': const Offset(900, 300),
        'b': const Offset(1150, 300),
        'c': const Offset(1150, 430),
      });
      expect(
        out.containsValue(const Offset(40, 40)),
        isFalse,
        reason: '出现 (40,40) 就说明退成了全图布局的原点',
      );
    });

    test('选中节点全都还没有坐标：用 layoutFlow 的自然原点，不抛', () {
      final graph = _g([_talk('a'), _talk('b')], [_next('a', 'b')]);

      final out = relayoutSelection(
        graph: graph,
        positions: const <String, Offset>{},
        selected: {'a', 'b'},
      );

      expect(out, {'a': const Offset(40, 40), 'b': const Offset(290, 40)});
    });
  });

  group('根顺序与确定性', () {
    test('选区内入度为 0 的根按当前 y 从上到下排', () {
      final graph = _g(
        [_talk('r1'), _talk('r2'), _talk('r3'), _talk('a')],
        [_next('r1', 'a')],
      );
      final positions = <String, Offset>{
        'r1': const Offset(500, 500),
        'r2': const Offset(500, 100),
        'r3': const Offset(500, 900),
        'a': const Offset(500, 700),
      };

      final out = relayoutSelection(
        graph: graph,
        positions: positions,
        selected: {'r1', 'r2', 'r3', 'a'},
      );

      expect(out, {
        'r2': const Offset(500, 100),
        'r1': const Offset(500, 230),
        'r3': const Offset(500, 360),
        'a': const Offset(750, 100),
      });
    });

    test('同 y、缺坐标时用 id 兜底，且与 selected 的插入顺序无关', () {
      final graph = _g([_talk('x1'), _talk('x2'), _talk('x3')], const []);
      // x1/x2 完全同位、x3 连坐标都没有 → 只能靠 id 定序
      final positions = <String, Offset>{
        'x1': const Offset(300, 300),
        'x2': const Offset(300, 300),
      };

      final a = relayoutSelection(
        graph: graph,
        positions: positions,
        selected: {'x1', 'x2', 'x3'},
      );
      final b = relayoutSelection(
        graph: graph,
        positions: positions,
        selected: {'x3', 'x2', 'x1'},
      );

      expect(a, b, reason: '同一份输入两次调用必须逐键相等');
      expect(a, {
        'x1': const Offset(300, 300),
        'x2': const Offset(300, 430),
        'x3': const Offset(300, 560),
      });
    });

    test('与选区内任何节点都不相连的孤立节点照样拿到坐标', () {
      final graph = _g(
        [_talk('h'), _talk('kid'), _talk('iso1'), _talk('iso2')],
        [_next('h', 'kid')],
      );
      final positions = <String, Offset>{
        'h': const Offset(100, 100),
        'kid': const Offset(400, 100),
        'iso1': const Offset(900, 20),
        'iso2': const Offset(950, 800),
      };

      final out = relayoutSelection(
        graph: graph,
        positions: positions,
        selected: {'h', 'kid', 'iso1', 'iso2'},
      );

      expect(out.length, 4, reason: '少一个键 = 宿主 addAll 后节点叠在原点上');
      expect(out.containsKey('iso1') && out.containsKey('iso2'), isTrue);
      // 四个都是入度 0 的根：iso1(20) < h(100) < iso2(800) < kid 是子节点
      expect(out['iso1']!.dy, 20);
      expect(out['h']!.dy, 150);
      expect(out['iso2']!.dy, 280);
      expect(out['kid']!.dy, 20, reason: 'kid 挂在 h 那一列的右侧首行');
      expect(out['iso1']!.dx, 100, reason: '三个孤立根同在第 0 列');
      expect(out['iso2']!.dx, 100);
      expect(out['kid']!.dx, 350, reason: 'kid 在 h 右边一列：100 + colW');
    });
  });

  group('脏输入不抛', () {
    test('缺失节点 + 图上不存在的 id + positions 缺项', () {
      final graph = _g([_talk('t1'), _missing('ms')], [_next('t1', 'ms')]);

      final out = relayoutSelection(
        graph: graph,
        positions: {'t1': const Offset(300, 300)},
        selected: {'t1', 'ms', 'ghost'},
      );

      expect(out.keys.toSet(), {'t1', 'ms'}, reason: 'ghost 不是节点，不该冒出来');
      expect(out, {'t1': const Offset(300, 300), 'ms': const Offset(550, 300)});
    });

    test('空选中 → 空图；只选中不存在的 id → 空图', () {
      final graph = _g([_talk('a')], const []);
      expect(
        relayoutSelection(
          graph: graph,
          positions: const {'a': Offset(1, 1)},
          selected: const <String>{},
        ),
        isEmpty,
      );
      expect(
        relayoutSelection(
          graph: graph,
          positions: const {'a': Offset(1, 1)},
          selected: const {'nope'},
        ),
        isEmpty,
      );
    });
  });

  group('纯函数', () {
    test('graph / positions / selected 都不被改动', () {
      final graph = _g(
        [_talk('t1'), _talk('t2'), _talk('t3')],
        [_next('t1', 't2'), _next('t2', 't3')],
      );
      final positions = <String, Offset>{
        't1': const Offset(800, 600),
        't2': const Offset(100, 50),
        't3': const Offset(30, 900),
      };
      final posSnapshot = Map<String, Offset>.of(positions);
      final edgesSnapshot = [...graph.edges];
      final startsSnapshot = [...graph.starts];
      final outEdgesSnapshot = [...graph.edgesFrom('t1')];
      final selected = {'t1', 't2', 't3'};
      final globalBefore = layoutFlow(graph: graph);

      final out = relayoutSelection(
        graph: graph,
        positions: positions,
        selected: selected,
      );

      expect(positions, posSnapshot);
      expect(graph.edges, edgesSnapshot);
      expect(graph.starts, startsSnapshot);
      expect(
        graph.edgesFrom('t1'),
        outEdgesSnapshot,
        reason: 'edgesFrom 返回的是内部列表，写它就是污染整张图',
      );
      expect(selected, {'t1', 't2', 't3'});
      expect(layoutFlow(graph: graph), globalBefore, reason: '全图布局口径不能被局部重排带偏');
      expect(identical(out, positions), isFalse);

      out['tamper'] = Offset.zero;
      positions['t1'] = const Offset(-999, -999);
      expect(posSnapshot['t1'], const Offset(800, 600));
    });
  });

  group('边口径与环', () {
    test('nextEvt 终端边不把目标压深一列（与 edgesFrom 同口径）', () {
      final graph = FlowGraph(
        nodes: [_opt('o1'), _missing('t9')],
        edges: const [
          FlowEdge(from: 'o1', to: 't9', kind: FlowEdgeKind.nextEvt),
        ],
        starts: const ['o1'],
      );

      final out = relayoutSelection(
        graph: graph,
        positions: {'o1': const Offset(200, 200), 't9': const Offset(200, 600)},
        selected: {'o1', 't9'},
      );

      expect(out['o1']!.dx, out['t9']!.dx, reason: '两者都是根，同在第 0 列');
      expect(out['o1'], const Offset(200, 200));
      expect(out['t9'], const Offset(200, 330));
    });

    test('两个互不相干的 2-环：只占两列，不拉成一人一列的长带', () {
      final graph = _g(
        [_talk('a'), _talk('b'), _talk('c'), _talk('d')],
        [_next('a', 'b'), _next('b', 'a'), _next('c', 'd'), _next('d', 'c')],
      );
      final positions = <String, Offset>{
        'a': const Offset(100, 100),
        'b': const Offset(100, 200),
        'c': const Offset(100, 300),
        'd': const Offset(100, 400),
      };

      final out = relayoutSelection(
        graph: graph,
        positions: positions,
        selected: {'a', 'b', 'c', 'd'},
      );

      expect(out.keys.toSet(), {'a', 'b', 'c', 'd'});
      expect(out, {
        'a': const Offset(100, 100),
        'c': const Offset(100, 230),
        'b': const Offset(350, 100),
        'd': const Offset(350, 230),
      });
      final xs = out.values.map((p) => p.dx).toSet();
      expect(xs.length, 2, reason: '补破环点让 layoutFlow 的「不可达节点各自一列」兜底分支不触发');
    });

    test('自环单节点：重排后原地不动', () {
      final graph = _g([_talk('s')], [_next('s', 's')]);

      final out = relayoutSelection(
        graph: graph,
        positions: {'s': const Offset(700, 700)},
        selected: {'s'},
      );

      expect(out, {'s': const Offset(700, 700)});
    });
  });

  group('网格参数与一致性', () {
    test('colW / rowH 生效', () {
      final graph = _g(
        [_talk('r1'), _talk('r2'), _talk('k')],
        [_next('r1', 'k')],
      );
      final positions = <String, Offset>{
        'r1': const Offset(100, 100),
        'r2': const Offset(100, 500),
        'k': const Offset(800, 800),
      };

      final out = relayoutSelection(
        graph: graph,
        positions: positions,
        selected: {'r1', 'r2', 'k'},
        colW: 400,
        rowH: 200,
      );

      expect(out, {
        'r1': const Offset(100, 100),
        'r2': const Offset(100, 300),
        'k': const Offset(500, 100),
      });
    });

    test('全选且已在默认原点：与 layoutFlow 逐像素一致（幂等）', () {
      final graph = FlowGraph(
        nodes: [_talk('r'), _talk('a'), _talk('b'), _talk('c')],
        edges: [_next('r', 'a'), _next('a', 'b'), _next('r', 'c')],
        starts: const ['r'],
      );
      final full = layoutFlow(graph: graph);

      final out = relayoutSelection(
        graph: graph,
        positions: full,
        selected: {for (final n in graph.nodes) n.id},
      );

      expect(out, full, reason: '局部重排复用同一套网格算法，不该自成一派');
    });
  });
}
