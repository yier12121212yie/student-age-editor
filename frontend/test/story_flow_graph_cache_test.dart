// 图缓存失效回归：宿主 _graph 从「每次 build 全量重算」改为缓存后，
// 必须同时满足两件事，缺一即为用户可见的 bug：
//   1. 改了舞台内容（字段、连线、删节点）→ 画布必须看到新图（缓存要失效）；
//   2. 只动位置（拖拽）→ 画布不得重算图（缓存要生效），但连线要跟着重绘。
// 第 1 条若漏掉某个写入点，表现为「改了字段卡片不更新」；第 2 条若失效
// 判定接错，表现为「拖拽时连线静止在旧位置」——positions/graph 都是原地改、
// 身份不变，只能靠显式版本号，见 story_flow_workspace 的 _dirty setter。
// 阶段 5 之后本文件还锁两件事：多选批量删除由宿主一次处理；拖未选中节点
// 必须实时重绘（选中集在画布、位置在宿主，两边都容易只刷一半）。
import 'dart:convert';

import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:student_age_editor/core/api_client.dart';
import 'package:student_age_editor/core/models.dart';
import 'package:student_age_editor/features/story/story_flow_graph.dart';
import 'package:student_age_editor/features/story/story_flow_models.dart';
import 'package:student_age_editor/features/story/story_flow_workspace.dart';

const _evt = '1000001';
const _t1 = '1000001000';
const _t2 = '1000001001';
const _t3 = '1000001002';

void main() {
  late AppState state;

  Map<String, dynamic> talks() => {
    _t1: {
      'id': int.parse(_t1),
      'content': '甲',
      'nextTalk': [_t2],
    },
    _t2: {'id': int.parse(_t2), 'content': '乙', 'nextTalk': <String>[]},
    _t3: {'id': int.parse(_t3), 'content': '丙', 'nextTalk': <String>[]},
  };

  setUp(() {
    state = AppState()
      ..modName = 'Cache'
      ..modRoot = r'C:\mods\cache';
    // 真实启动流程里 app.dart 会把 /api/schema 缓存进 AppState.gameSchema；
    // 字段写回按类型解析、未知类型拒写，所以缺了它内联编辑什么都不做。
    state.gameSchema = {
      'TalkCfg': {
        'id': 'Number',
        'roleName': 'String',
        'content': 'String',
        'check': '2D Array',
        'screenEffect': '1D Array',
        'bg': 'Number',
        'audio': 'Number',
        'time': 'Number',
        'highlights': '1D Array',
        'nextTalk': '1D Array',
      },
      'OptionCfg': {
        'id': 'Number',
        'content': 'String',
        'precondition': '2D Array',
        'check': '2D Array',
        'talkId': '1D Array',
        'talkId2': '1D Array',
        'nextEvtId': 'Number',
      },
    };
    final evtCfg = <String, dynamic>{
      _evt: {
        'id': int.parse(_evt),
        'title': '缓存事件',
        'talkId': [_t1],
      },
    };
    ApiClient.instance.client = MockClient((request) async {
      final path = request.url.path;
      var data = <String, dynamic>{};
      if (path.startsWith('/api/cfg/')) {
        final name = path.split('/').last;
        if (name == 'EvtCfg') data = evtCfg;
        if (name == 'TalkCfg') data = talks();
        return http.Response(
          jsonEncode({
            'cfg': name,
            'data': data,
            'keys': data.keys.toList(),
            'exists': true,
            'mtime_ns': 1,
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (path == '/api/plugins/ui/flow_cards') {
        return http.Response(
          '{"flow_cards": []}',
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (path == '/api/tools/read') {
        return http.Response(
          '{"error": "not a file"}',
          400,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response(
        '{"ok": true}',
        200,
        headers: {'content-type': 'application/json'},
      );
    });
  });

  tearDown(() {
    ApiClient.instance.client = http.Client();
  });

  Future<void> pumpHost(WidgetTester tester) async {
    await tester.pumpWidget(
      fluent.FluentApp(
        home: Scaffold(
          body: SizedBox(
            width: 1200,
            height: 800,
            child: StoryFlowWorkspace(
              state: state,
              onPreview: (_) {},
              onOpenPlugins: () {},
              onOpenSettings: () {},
            ),
          ),
        ),
      ),
    );
  }

  Future<StoryFlowGraph> mount(WidgetTester tester) async {
    await pumpHost(tester);
    await tester.pumpAndSettle();
    expect(find.byType(StoryFlowGraph), findsOneWidget);
    return tester.widget<StoryFlowGraph>(find.byType(StoryFlowGraph));
  }

  FlowGraph graphOf(WidgetTester tester) =>
      tester.widget<StoryFlowGraph>(find.byType(StoryFlowGraph)).graph;

  /// 卡片正文是 TextSpan，`find.text` 只认 Text.data；这里匹配 RichText 纯文本。
  /// 限定在画布子树内：Inspector 打开后，ID 字段的名称回显里也会出现同一句台词。
  Finder nodeText(String s) => find.descendant(
    of: find.byType(StoryFlowGraph),
    matching: find.byWidgetPredicate(
      (w) => w is RichText && w.text.toPlainText().contains(s),
    ),
  );

  Future<void> settle(WidgetTester tester) async {
    // 布局回写防抖 800ms：让其落地，避免测试结束残留 pending timer。
    await tester.pump();
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 1000));
    await tester.pumpAndSettle();
  }

  testWidgets('拖拽只改位置：graph 对象保持同一实例（缓存生效）', (tester) async {
    final w = await mount(tester);
    final before = graphOf(tester);
    final edges = before.edges.length;

    // 先选中：与真实拖拽路径一致（拖一个已选中的节点）。
    w.onSelectionChanged(FlowSelection.ofNode(_t1));
    await settle(tester);
    final selected = graphOf(tester);
    expect(identical(selected, before), isTrue, reason: '选中不是内容变更，不应作废图缓存');

    w.onMoveNode(_t1, const Offset(400, 400));
    await settle(tester);
    final moved = graphOf(tester);
    expect(
      identical(moved, before),
      isTrue,
      reason: '移动节点不属于图数据，缓存必须生效（否则每帧重建整张图）',
    );
    expect(moved.edges.length, edges);
  });

  testWidgets('编辑字段：画布立即看到新内容（缓存已失效）', (tester) async {
    final w = await mount(tester);
    final before = graphOf(tester);

    w.onFieldChanged(_t1, 'content', '改后文本');
    await settle(tester);

    expect(nodeText('改后文本'), findsOneWidget, reason: '缓存未失效 → 卡片仍显示旧内容');
    expect(
      graphOf(tester).nodes.firstWhere((n) => n.id == _t1).content,
      '改后文本',
    );
    expect(identical(graphOf(tester), before), isFalse, reason: '内容变了必须重算图');
  });

  testWidgets('新增连线：graph 边数增加且对象更换', (tester) async {
    final w = await mount(tester);
    final before = graphOf(tester);
    expect(before.edges.length, 1, reason: '初始只有 甲→乙 一条边');

    w.onAddEdge(_t3, 'nextTalk', _t1);
    await settle(tester);

    final after = graphOf(tester);
    expect(identical(after, before), isFalse);
    expect(after.edges.length, 2, reason: '缓存未失效 → 新连线不出现');
  });

  testWidgets('删除节点：卡片消失且 graph 更新', (tester) async {
    final w = await mount(tester);
    final before = graphOf(tester);
    expect(before.nodes.length, 3, reason: '甲/乙/丙 三个对白节点');
    expect(nodeText('乙'), findsOneWidget);

    w.onDeleteNode(_t2);
    await settle(tester);

    expect(nodeText('乙'), findsNothing);
    expect(
      graphOf(tester).nodes.map((n) => n.id),
      isNot(contains(_t2)),
      reason: '删节点后仍是旧缓存 → 画布保留幽灵节点',
    );
    expect(graphOf(tester).nodes.length, 2);
  });

  testWidgets('位置版本号随拖拽递增（连线重绘的唯一信号）', (tester) async {
    final w = await mount(tester);
    final v0 = w.positionsVersion;

    w.onSelectionChanged(FlowSelection.ofNode(_t2));
    await settle(tester);
    final w2 = tester.widget<StoryFlowGraph>(find.byType(StoryFlowGraph));
    w2.onMoveNode(_t2, const Offset(30, 900));
    await settle(tester);

    final v1 = tester
        .widget<StoryFlowGraph>(find.byType(StoryFlowGraph))
        .positionsVersion;
    expect(
      v1,
      greaterThan(v0),
      reason:
          '_positions 原地修改、身份不变，_positionsRev 是唯一的位置变更信号；'
          '它不涨则拖拽时连线不会重绘',
    );
  });

  testWidgets('多选批量删除：宿主一次清掉整批', (tester) async {
    final w = await mount(tester);
    w.onSelectionChanged(FlowSelection(nodes: {_t2, _t3}));
    await settle(tester);

    // 画布侧已保证多选只发一次 onRequestDelete，这里验宿主真的把整批删掉：
    // 逐项回调会让每次删除都重建一次图并重画一遍，多选删 20 个节点即卡死。
    tester
        .widget<StoryFlowGraph>(find.byType(StoryFlowGraph))
        .onRequestDelete();
    await settle(tester);

    expect(nodeText('乙'), findsNothing);
    expect(nodeText('丙'), findsNothing);
    final ids = graphOf(tester).nodes.map((n) => n.id).toList();
    expect(ids, isNot(anyOf(contains(_t2), contains(_t3))));
    expect(ids.length, 1, reason: '只剩甲');
  });

  testWidgets('拖未选中节点：卡片当场跟随，不等松手', (tester) async {
    final w = await mount(tester);
    w.onSelectionChanged(FlowSelection.ofNode(_t1));
    await settle(tester);

    expect(nodeText('乙'), findsOneWidget);
    final before = tester.getTopLeft(nodeText('乙'));
    final w2 = tester.widget<StoryFlowGraph>(find.byType(StoryFlowGraph));
    final to = w2.positions[_t2]! + const Offset(120, 60);
    w2.onMoveNode(_t2, to);
    // 只推一帧，故意不吃布局回写防抖：这就是拖拽过程中的那一帧。
    await tester.pump();

    expect(
      tester.getTopLeft(nodeText('乙')) - before,
      const Offset(120, 60),
      reason: '_onMoveNode 若只对选中节点 setState，未选中节点会静止到松手',
    );
    // 断言已拿到「拖拽中那一帧」，再把布局回写防抖排干净。
    await settle(tester);
  });

  // ---------- 内联字段编辑：刷新 + 平移不重建 ----------
  testWidgets('内联编辑字段：卡片文本刷新，随后纯平移仍 0 次卡片 build', (tester) async {
    var w = await mount(tester);
    w.onToggleExpand(_t1);
    await settle(tester);
    w = tester.widget<StoryFlowGraph>(find.byType(StoryFlowGraph));

    final ctl = w.fieldController(_t1, 'content');
    expect(ctl, isNotNull, reason: 'schema 有 content 字段就该给内联区一个控制器');
    ctl!.text = '改后的台词';
    w.onFieldChanged(_t1, 'content', '改后的台词');
    await settle(tester);

    w = tester.widget<StoryFlowGraph>(find.byType(StoryFlowGraph));
    expect(
      w.fieldController(_t1, 'content')!.text,
      '改后的台词',
      reason: '控制器被回收重建 → 输入框文本回弹，用户看到的是「我打的字没了」',
    );
    expect(nodeText('改后的台词'), findsOneWidget);
    expect(
      w.fieldInvalid(_t1, 'content'),
      isFalse,
      reason: '合法文本不该被标成写回失败',
    );

    // 性能底线：平移只换视口矩阵，一张卡片都不许重建。
    final vp = tester
        .state<StoryFlowGraphState>(find.byType(StoryFlowGraph))
        .viewportListenable;
    final at = blankSpot(
      tester.state<StoryFlowGraphState>(find.byType(StoryFlowGraph)),
    );
    final g = await tester.startGesture(at);
    await tester.pump();
    final card0 = debugNodeCardBuilds;
    final pan0 = vp.value.pan;
    await g.moveTo(at + const Offset(-140, -90));
    await tester.pump();
    await g.up();
    await tester.pump();

    expect(
      vp.value.pan,
      isNot(pan0),
      reason: '手势没落在空白处：起点点到了节点，测的就不是平移',
    );
    expect(
      debugNodeCardBuilds - card0,
      0,
      reason: '平移重建了卡片：视口改动必须只换矩阵，不得走 setState',
    );
    await settle(tester);
  });

  // ---------- S4 C2：卡片实例缓存门控 ----------
  // 旧实现 didUpdateWidget 无条件 _slotsTier=-1：宿主每次重建都为全部节点
  // 新建卡片+端口表+世界足迹（~2,500 分配/帧），bench 的 debugNodeCardBuilds
  // 只数「已挂载卡片」的 build，掩盖了分配本身。新门控：
  //   纯宿主重泵 → _buildSlots 0 次；内容签名变化 → 恰 1 次；拖拽帧 → 只
  //   重建 Positioned 包装（debugSlotCardsBuilt == 0）且节点跟手。
  group('C2 槽位门控：重泵 0 次 + 负向对照各 1 次', () {
    testWidgets('同 graph 宿主重泵 30 次：_buildSlots 一次都不调', (tester) async {
      await mount(tester);
      final slots0 = debugBuildSlotsCalls;
      final built0 = debugSlotCardsBuilt;
      for (var i = 0; i < 30; i++) {
        await pumpHost(tester);
        await tester.pump();
      }
      expect(
        debugBuildSlotsCalls - slots0,
        0,
        reason:
            '纯宿主重泵改不了内容签名（graph/展开/选中/高亮全不变）也不改 '
            'positionsVersion —— 若仍在重算槽位，说明门控退化回「每次重建全作废」',
      );
      expect(debugSlotCardsBuilt - built0, 0, reason: '重泵不得新建任何卡片实例');
      await settle(tester);
    });

    testWidgets('负向对照：展开/收起 → _buildSlots 恰 1 次/次', (tester) async {
      await mount(tester);
      final slots0 = debugBuildSlotsCalls;
      final dash0 = debugDashCacheClears;
      tester
          .widget<StoryFlowGraph>(find.byType(StoryFlowGraph))
          .onToggleExpand(_t1);
      await settle(tester);
      expect(
        debugBuildSlotsCalls - slots0,
        1,
        reason: 'expandedNodes 内容变了必须恰好重建一次（计数器若仍为 0 就是写坏了）',
      );
      expect(
        debugDashCacheClears - dash0,
        1,
        reason: '展开态影响端口锚点 → 虚线缓存必须作废一次（C4 探针负向对照）',
      );
      final slots1 = debugBuildSlotsCalls;
      tester
          .widget<StoryFlowGraph>(find.byType(StoryFlowGraph))
          .onToggleExpand(_t1);
      await settle(tester);
      expect(debugBuildSlotsCalls - slots1, 1, reason: '收起同样恰好重建一次');
    });

    testWidgets('负向对照：跨 LOD 档 → _buildSlots 恰 1 次', (tester) async {
      await mount(tester);
      final gs = tester.state<StoryFlowGraphState>(find.byType(StoryFlowGraph));
      final at = blankSpot(gs);
      final slots0 = debugBuildSlotsCalls;
      // 6 tick ×0.9 ≈ 0.53：完整档(≥0.58) → 标题档，恰跨一档；
      // 中间各 tick 档位不变，多重建一次都说明签名把无关输入算了进去。
      for (var i = 0; i < 6; i++) {
        await tester.sendEventToBinding(
          PointerScrollEvent(position: at, scrollDelta: const Offset(0, 120)),
        );
        await tester.pump();
      }
      await tester.pumpAndSettle();
      final scale = gs.viewportListenable.value.scale;
      expect(scale, lessThan(kLodFullDown), reason: '没缩到标题档，测的不是换档');
      expect(scale, greaterThanOrEqualTo(kLodTitleDown));
      expect(
        debugBuildSlotsCalls - slots0,
        1,
        reason: '换档必须恰好重建一次（tier 必须在内容签名里）',
      );
      await settle(tester);
    });

    testWidgets('拖拽 30 帧：0 次卡片构建、30 次包装重建、节点跟手', (tester) async {
      await mount(tester);
      // 首个节点世界 (40,40)，scale=1/pan=0；卡片中部 (120,70) 避开端口/箭头。
      final origin = tester.getTopLeft(find.byType(StoryFlowGraph));
      final g = await tester.startGesture(origin + const Offset(120, 70));
      await tester.pump(); // 按下选中的那次重建不记入帧成本
      final slots0 = debugBuildSlotsCalls;
      final built0 = debugSlotCardsBuilt;
      final builds0 = debugNodeCardBuilds;
      final before = tester.getTopLeft(nodeText('甲'));
      for (var i = 0; i < 30; i++) {
        await g.moveBy(const Offset(6, 4));
        await tester.pump();
      }
      await g.up();
      await tester.pump();

      expect(debugSlotCardsBuilt - built0, 0, reason: '拖拽帧不得新建卡片实例');
      expect(debugNodeCardBuilds - builds0, 0, reason: 'identical child 短路：卡片连 build 都不该进');
      expect(
        debugBuildSlotsCalls - slots0,
        30,
        reason: '每帧 positionsVersion+1 → 恰一次便宜的包装重建（Positioned left/top）',
      );
      final rendered = tester.getTopLeft(nodeText('甲')) - before;
      expect(
        (rendered - const Offset(180, 120)).distance,
        lessThanOrEqualTo(6),
        reason: '30 帧 ×(6,4) 后卡片必须跟手（±吸附容差），否则缓存把位置拖没了',
      );
      await settle(tester);
    });
  });
}

/// 画布上真正空白的点：用画布自己的屏幕空间命中测试挑，
/// 手势才不会压在卡片上（压到就变成拖节点，测不到平移）。
/// 只用画布中部：下缘（y>=620）被工作区浮动层盖住，手势落在那里推不动视口。
Offset blankSpot(StoryFlowGraphState gs) {
  for (final c in const [
    Offset(600, 400),
    Offset(760, 460),
    Offset(240, 500),
    Offset(420, 380),
  ]) {
    if (gs.hitNodeAt(c) == null) return c;
  }
  return const Offset(600, 400);
}
