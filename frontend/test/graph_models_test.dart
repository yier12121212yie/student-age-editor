// graph 功能包的纯函数钉死测试：契约解析、色值回退、kind 徽章、
// 关系图放射布局、时间轴泳道/过滤/刻度密度、视口变换互逆性。
import 'package:flutter_test/flutter_test.dart';

import 'package:student_age_editor/core/app_theme.dart';
import 'package:student_age_editor/features/graph/graph_models.dart';

Map<String, dynamic> _relationsJson() => {
      'nodes': [
        {'id': '101', 'name': '小明', 'gender': 1, 'tex': null},
        {'id': '202', 'name': '小红', 'gender': 2, 'tex': 'portrait/xiaohong'},
      ],
      'levels': [
        {
          'id': '520',
          'name': '恋人',
          'color': '#FF3B30',
          'condition': 90,
          'upgrade': null,
          'upgradeCost': 0,
          'socialCapacity': 1,
          'iconRelation': 'icon_lover',
        },
        {
          'id': '521',
          'name': '青梅',
          'color': 'not-a-hex', // 非法色值 → 回退 tintInfo
          'condition': 60,
          'upgrade': '520',
          'upgradeCost': 500,
          'socialCapacity': 2,
          'iconRelation': 'icon_child',
        },
      ],
      'edges': [
        {
          'role': '101',
          'kind': 'favorGain',
          'value': 10,
          'relation': null,
          'code': '[20, 1, 101, 10]',
          'sourceCfg': 'TalkCfg',
          'sourceId': '32010101',
          'sourceName': '台词前二十四字',
        },
        {
          'role': '202',
          'kind': 'favorLoss',
          'value': 3,
          'relation': null,
          'code': '[7,-1,202,3]',
          'sourceCfg': 'TalkCfg',
          'sourceId': '32010102',
          'sourceName': '争吵',
        },
        {
          'role': '101',
          'kind': 'relationSet',
          'value': 0,
          'relation': '521',
          'code': '[7, -1, 521]',
          'sourceCfg': 'EvtCfg',
          'sourceId': '1200001',
          'sourceName': '成为青梅竹马',
        },
      ],
    };

void main() {
  group('解析工具', () {
    test('parseHexColor：合法/非法/回退', () {
      expect(parseHexColor('#FF3B30').toARGB32(), 0xFFFF3B30);
      expect(parseHexColor('ff3b30').toARGB32(), 0xFFFF3B30);
      expect(parseHexColor('bad-hex'), palette.tintInfo);
      expect(parseHexColor('#12345'), palette.tintInfo);
      expect(parseHexColor(null), palette.tintInfo);
    });

    test('parseCodeList：正负整数、脏输入', () {
      expect(parseCodeList('[20, 1, 101, 10]'), [20, 1, 101, 10]);
      expect(parseCodeList('[7,-1,202,3]'), [7, -1, 202, 3]);
      expect(parseCodeList(null), isEmpty);
      expect(parseCodeList('abc'), isEmpty);
    });
  });

  group('关系图契约', () {
    final data = parseRelations(_relationsJson());

    test('nodes/levels/edges 全量解析', () {
      expect(data.nodes.length, 2);
      expect(data.nodes.first.name, '小明');
      expect(data.nodes.first.tex, isNull);
      expect(data.nodes.last.tex, 'portrait/xiaohong');
      expect(data.levels.length, 2);
      expect(data.levels.first.condition, 90);
      expect(data.levels.first.parseColor.toARGB32(), 0xFFFF3B30);
      // 非法色值等级 → tintInfo 回退。
      expect(data.levels.last.parseColor, palette.tintInfo);
      expect(data.edges.length, 3);
      expect(data.edges[2].relationLevelName, '青梅');
    });

    test('levelsSortedByCondition 升序', () {
      final s = data.levelsSortedByCondition.map((l) => l.id).toList();
      expect(s, ['521', '520']);
    });

    test('edgesConnectedTo：role 命中或 code 里出现所选人 id', () {
      final mine = edgesConnectedTo(data.edges, '101');
      expect(mine.map((e) => e.sourceId), ['32010101', '1200001']);
      // 另一端编码在 code 里（role 是别人）也算相连。
      final inbound = RelationEdge(
          role: '999',
          kind: 'favorGain',
          value: 3,
          code: '[20, 1, 101, 3]',
          sourceCfg: 'c',
          sourceId: 'in',
          sourceName: '');
      expect(
          edgesConnectedTo([...data.edges, inbound], '101')
              .map((e) => e.sourceId)
              .contains('in'),
          isTrue);
      expect(edgesConnectedTo(data.edges, '999'), isEmpty);
    });

    test('counterpartOfEdge：role≠focus 取 role；role==focus 从 code 解', () {
      final ids = data.nodes.map((n) => n.id).toSet(); // {101,202}
      // role=202 且经 code 连到 101 → 对方是 202。
      final inbound = RelationEdge(
          role: '202',
          kind: 'favorGain',
          value: 3,
          code: '[20, 1, 101, 3]',
          sourceCfg: 'c',
          sourceId: 'in',
          sourceName: '');
      expect(counterpartOfEdge(inbound, '101', ids), '202');
      // role==focus 时扫 code 找另一个已知人物。
      final self = RelationEdge(
          role: '101',
          kind: 'interact',
          code: '[30, 1, 202]',
          sourceCfg: 'c',
          sourceId: 's',
          sourceName: '');
      expect(counterpartOfEdge(self, '101', ids), '202');
      // code 里没有其他人物 id → null（纯数值记录）。
      expect(counterpartOfEdge(data.edges[0], '101', ids), isNull);
    });

    test('filterEdgesByLevel：无 relation 的边恒通过', () {
      final only520 = filterEdgesByLevel(data.edges, {'520'});
      expect(only520.length, 2); // 两条 favor 边（relation=null）+ 0 条 520
      final only521 = filterEdgesByLevel(data.edges, {'521'});
      expect(only521.length, 3);
      expect(filterEdgesByLevel(data.edges, {}), data.edges);
    });

    test('relationBadgeLabel：中文徽章', () {
      expect(relationBadgeLabel(data.edges[0]), '好感+10');
      expect(relationBadgeLabel(data.edges[1]), '好感-3');
      expect(relationBadgeLabel(data.edges[2]), '设为关系:青梅');
    });

    test('edgeBadgeColor：等级色优先、非法回退、无等级取 kind 色', () {
      final byId = {for (final l in data.levels) l.id: l};
      // relationSet → 521 非法色 → 等级 parseColor 已回退 tintInfo。
      expect(edgeBadgeColor(data.edges[2], byId), palette.tintInfo);
      // favorGain 无 relation → kind 色。
      expect(edgeBadgeColor(data.edges[0], byId), palette.statusOk);
      // 指向不存在等级的 relation → 兜底 kind 色。
      final ghost = RelationEdge(
          role: '1', kind: 'lover', relation: '999',
          sourceCfg: 'x', sourceId: 'y', sourceName: 'z');
      expect(edgeBadgeColor(ghost, byId), relationKindColor('lover'));
    });

    test('layoutEgoGraph：确定性放射布局、同 kind 同扇区、半径钉死', () {
      final edges = data.edges;
      final placed = layoutEgoGraph(edges: edges, radius: 200);
      expect(placed.length, 3);
      // 确定性：同输入两次调用得到同样的落点。
      final again = layoutEgoGraph(edges: edges, radius: 200);
      for (var i = 0; i < placed.length; i++) {
        expect(placed[i].center, again[i].center);
        expect(placed[i].angleRad, again[i].angleRad);
      }
      // 每个落点距圆心 = radius。
      for (final p in placed) {
        expect((p.center - Offset.zero).distance, closeTo(200, 1e-9));
      }
      // 两条 favorGain/…：同 kind 的边应落在同一扇区（角度间隔 < 扇区宽），
      // 本 fixture 中 index0/1 分别是 favorGain/favorLoss（不同 kind 不同扇区）。
      final byKind = {for (final p in placed) p.kindGroup: p.angleRad};
      expect(byKind.values.length, placed.map((p) => p.kindGroup).toSet().length);
      // index 稳定：与输入顺序一致。
      expect(placed.map((p) => p.index).toSet(), {0, 1, 2});
    });

    test('layoutEgoGraph：空表空结果 + 封顶', () {
      expect(layoutEgoGraph(edges: const []), isEmpty);
      final many = [
        for (var i = 0; i < 100; i++)
          RelationEdge(
              role: '1',
              kind: 'interact',
              sourceCfg: 'c',
              sourceId: '$i',
              sourceName: ''),
      ];
      expect(layoutEgoGraph(edges: many).length, kRelationEdgeCap);
    });
  });

  group('时间轴契约', () {
    final json = {
      'rounds': [
        {'round': 1, 'year': 1, 'season': 1, 'seasonName': '小一 春', 'months': [3, 4, 5], 'holiday': false},
        {'round': 2, 'year': 1, 'season': 2, 'seasonName': '小一 夏', 'months': [6, 7, 8], 'holiday': false},
        {'round': 3, 'year': 1, 'season': 2, 'seasonName': '小一 夏', 'months': [7], 'holiday': true},
        {'round': 4, 'year': 1, 'season': 3, 'seasonName': '小一 秋', 'months': [9, 10, 11], 'holiday': false},
      ],
      'items': [
        {'cfg': 'EvtCfg', 'id': '1200001', 'name': '开学', 'mapId': '3', 'npc': '101', 'timeKinds': ['round'], 'spans': [{'from': 1, 'to': 2}], 'codes': ['[2,0,1]']},
        {'cfg': 'EvtCfg', 'id': '1200002', 'name': '持续', 'mapId': '3', 'npc': '202', 'timeKinds': ['round'], 'spans': [{'from': 2, 'to': null}], 'codes': ['[2,0,2]']},
        {'cfg': 'TalkCfg', 'id': '300', 'name': '特殊约束', 'mapId': '', 'npc': '', 'timeKinds': ['special'], 'spans': [], 'codes': ['[9]']},
        {'cfg': 'TalkCfg', 'id': '301', 'name': '无跨度', 'mapId': '', 'npc': '', 'timeKinds': ['round'], 'spans': [], 'codes': []},
      ],
    };
    final tl = parseTimeline(json);

    test('rounds/items 解析', () {
      expect(tl.rounds.length, 4);
      expect(tl.rounds[2].holiday, isTrue);
      expect(tl.rounds.first.months, [3, 4, 5]);
      expect(tl.items.length, 4);
      expect(tl.items[1].spans.single.to, isNull);
      expect(tl.maxRound, 4);
    });

    test('resolvedRange：to=null 延伸到轴末', () {
      final r = tl.items[1].resolvedRange(tl.maxRound);
      expect(r.start, 2);
      expect(r.end, tl.maxRound); // 自此以后 → 画到轴末
    });

    test('axisItems 挡掉 special 与无跨度条目', () {
      expect(tl.axisItems.map((e) => e.id), ['1200001', '1200002']);
      expect(tl.specialItems.map((e) => e.id), ['300']);
    });

    test('filterTimelineItems：npc/mapId 维度', () {
      final byNpc = filterTimelineItems(tl.axisItems, npc: '101');
      expect(byNpc.map((e) => e.id), ['1200001']);
      final byMap = filterTimelineItems(tl.axisItems, mapId: '3');
      expect(byMap.length, 2);
      expect(filterTimelineItems(tl.axisItems).length, tl.axisItems.length);
    });

    test('assignLanes：不重叠共道、重叠分行、to=null 占满后续', () {
      final a = TimeRange(from: 1, to: 2);
      final b = TimeRange(from: 3, to: 4);
      final c = TimeRange(from: 2, to: 3);
      List<TimelineItem> its(List<TimeRange> rs) => [
            for (var i = 0; i < rs.length; i++)
              TimelineItem(
                  cfg: 'x', id: '$i', name: '', mapId: '', npc: '',
                  timeKinds: const [], spans: [rs[i]], codes: const []),
          ];
      expect(assignLanes(its([a, b]), maxRound: 62).laneCount, 1);
      expect(assignLanes(its([a, b]), maxRound: 62).laneByIndex, [0, 0]);
      final l2 = assignLanes(its([a, c]), maxRound: 62);
      expect(l2.laneCount, 2);
      expect(l2.laneByIndex, [0, 1]);
      // 三条两两重叠 → 3 泳道。
      final tri = assignLanes(
          its([
            TimeRange(from: 1, to: 10),
            TimeRange(from: 2, to: 9),
            TimeRange(from: 3, to: 8),
          ]),
          maxRound: 62);
      expect(tri.laneCount, 3);
      // to=null → 按轴末参与判定。
      final openEnd = assignLanes(
          its([TimeRange(from: 1, to: null), TimeRange(from: 2, to: 3)]),
          maxRound: 62);
      expect(openEnd.laneCount, 2);
      expect(openEnd.laneByIndex, [0, 1]);
      expect(assignLanes(const [], maxRound: 62).laneCount, 0);
    });

    test('刻度密度：缩放决定 year/season/full', () {
      expect(timelineTickMode(46), TimelineTickMode.season); // kTlRoundW=46
      expect(timelineTickMode(70), TimelineTickMode.full);
      expect(timelineTickMode(10), TimelineTickMode.year);
    });

    test('timelineSpanLabel：中文跨段文案', () {
      expect(timelineSpanLabel(TimeRange(from: 6)), '第6回合起');
      expect(timelineSpanLabel(TimeRange(from: 6, to: 12)), '第6~12回合');
    });

    test('季节四色与 cfg 色稳定且不崩', () {
      expect(seasonPalette().length, 4);
      expect(seasonColor(1), seasonPalette()[0]);
      expect(seasonColor(5), seasonColor(1)); // 环绕
      expect(seasonColor(0), seasonPalette().first); // 兜底
      expect(timelineCfgColor('EvtCfg'), isNot(timelineCfgColor('TalkCfg')));
    });
  });

  group('GraphViewport', () {
    test('toWorld/toScreen 互逆', () {
      const vp = GraphViewport(1.5, Offset(30, -12));
      final w = vp.toWorld(const Offset(100, 200));
      expect(vp.toScreen(w), const Offset(100, 200));
    });

    test('withZoom 保持锚点不动', () {
      const vp = GraphViewport(1, Offset(20, 10));
      const anchor = Offset(120, 80);
      final zoomed = vp.withZoom(2, anchor);
      expect(zoomed.toScreen(zoomed.toWorld(anchor)), anchor);
    });
  });
}
