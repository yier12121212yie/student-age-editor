// 剧情图画布 Ctrl+Z / Ctrl+Y 的宿主层回归。
//
// 快照栈本身（深拷贝、mergeKey 合并、limit 淘汰、seed 清栈）已由
// test/story_flow_history_test.dart 纯单元测试锁死，这里**不重复**那些用例，
// 只补「接上真宿主以后才会暴露」的那一段：
//   · 撤销删节点必须把坐标一起带回来 —— 宿主 `_positions.remove(id)` 与
//     `_history.record` 的先后、`_historyStep` 里 `_positions = step.positions`
//     任一接错，复活的节点就掉到 (0,0) 跟甲叠在一起，而纯单元测试看不出来。
//   · 上游重连（remapDeletedTarget 把 甲→乙 改写成 甲→丙）必须整段回滚。
//   · mergeKey 合成必须在**控件回调链**上生效：`_applyFieldText` 每次都以
//     `field:$nodeId:$field` 记一步，键拼错就会一次输入吃掉整条栈。
//   · 退到基线后 `_dirty` 必须重算为 false：否则撤销干净了仍被要求「保存」，
//     切事件还弹「未保存的修改」。
//   · 撤销栈按事件 seed：切事件留着上一个事件的栈，Ctrl+Z 会把旧内容灌进新事件。
//
// 驱动方式与 test/story_flow_graph_cache_test.dart 一致：起真宿主
// StoryFlowWorkspace，通过画布暴露的回调注入用户动作，断言落在画布内容上。
// 键盘路径（Ctrl+Z / Ctrl+Y）真按按键走，以便覆盖 `_onKey` → `historyKeyOp`。
import 'dart:convert';

import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:student_age_editor/core/api_client.dart';
import 'package:student_age_editor/core/models.dart';
import 'package:student_age_editor/features/story/story_flow_graph.dart';
import 'package:student_age_editor/features/story/story_flow_models.dart';
import 'package:student_age_editor/features/story/story_flow_workspace.dart';

const _evt = '1000001';
const _evtTitle = '缓存事件';
const _evt2 = '1000002';
const _evt2Title = '第二事件';

const _t1 = '1000001000';
const _t2 = '1000001001';
const _t3 = '1000001002';
const _t21 = '1000002000';

/// 空白处（世界=屏幕，初始视口 scale 1 / pan 0）。
/// 测试窗口默认 800x600，故这个点必须在窗口内：三张卡占 y∈[40,152]
/// （展开时到 356）、x∈[40,740]，操作簇与芯片都在顶部，(770,560) 恒空。
const _blank = Offset(770, 560);

void main() {
  late AppState state;

  Map<String, dynamic> evtCfg() => {
    _evt: {
      'id': int.parse(_evt),
      'title': _evtTitle,
      'talkId': [_t1],
    },
    _evt2: {
      'id': int.parse(_evt2),
      'title': _evt2Title,
      'talkId': [_t21],
    },
  };

  Map<String, dynamic> talks() => {
    _t1: {
      'id': int.parse(_t1),
      'content': '甲',
      'nextTalk': [_t2],
    },
    _t2: {'id': int.parse(_t2), 'content': '乙', 'nextTalk': <String>[]},
    _t3: {'id': int.parse(_t3), 'content': '丙', 'nextTalk': <String>[]},
    _t21: {'id': int.parse(_t21), 'content': '丁', 'nextTalk': <String>[]},
  };

  setUp(() {
    state = AppState()
      ..modName = 'Undo'
      ..modRoot = r'C:\mods\undo';
    // 与 graph_cache_test 同理：真实启动流程里 app.dart 会把 /api/schema 缓存进
    // AppState.gameSchema；内联字段按类型解析、未知类型拒写，缺了它打字
    // 不会标脏也不记历史（三步合成一步 / 重做 / 未保存守卫全都依赖这条链）。
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
    ApiClient.instance.client = MockClient((request) async {
      final path = request.url.path;
      var data = <String, dynamic>{};
      if (path.startsWith('/api/cfg/')) {
        final name = path.split('/').last;
        if (name == 'EvtCfg') data = evtCfg();
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
        // 400 = 文件不存在：合法的「空布局」，坐标由分层 DAG 自动布局给出。
        return http.Response(
          '{"error": "not a file"}',
          400,
          headers: {'content-type': 'application/json'},
        );
      }
      // 其余（/api/tools/write、/api/history/undo|redo）一律受理，
      // 保证不弹 InfoBar（它有 250ms 弹出 + 3s 自动收起两个裸 Timer）。
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

  Future<StoryFlowGraph> mount(WidgetTester tester) async {
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
    await tester.pumpAndSettle();
    expect(find.byType(StoryFlowGraph), findsOneWidget);
    return tester.widget<StoryFlowGraph>(find.byType(StoryFlowGraph));
  }

  StoryFlowGraph canvasOf(WidgetTester tester) =>
      tester.widget<StoryFlowGraph>(find.byType(StoryFlowGraph));

  FlowGraph graphOf(WidgetTester tester) => canvasOf(tester).graph;

  /// 卡片正文是 TextSpan，`find.text` 只认 Text.data；这里匹配 RichText 纯文本。
  Finder nodeText(String s) => find.byWidgetPredicate(
    (w) => w is RichText && w.text.toPlainText().contains(s),
  );

  Future<void> settle(WidgetTester tester) async {
    // 布局回写防抖 800ms：让其落地，避免测试结束残留 pending timer。
    await tester.pump();
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 1000));
    await tester.pumpAndSettle();
  }

  FlowNode? nodeOf(WidgetTester tester, String id) {
    for (final n in graphOf(tester).nodes) {
      if (n.id == id) return n;
    }
    return null;
  }

  /// 节点在宿主里的坐标（撤销是否带回位置就看这个）。
  Offset? posOf(WidgetTester tester, String id) =>
      canvasOf(tester).positions[id];

  Set<FlowEdge> edgesOf(WidgetTester tester) => graphOf(tester).edges.toSet();

  /// 空白处点一下：与真实用户一样把键盘焦点收回画布（`_takeCanvasFocus`），
  /// 否则按键进不了 `_onKey`。顺带清掉选中集。
  Future<void> focusCanvas(WidgetTester tester) async {
    await tester.tapAt(_blank);
    await tester.pumpAndSettle();
  }

  /// 按住 Ctrl 敲一个键。HardwareKeyboard 是全局单例，**必须**收尾，
  /// 否则后续用例全程跑在 Ctrl 态下（`historyKeyOp` 会认不住普通按键）。
  Future<void> withCtrl(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    try {
      await tester.sendKeyDownEvent(key);
      await tester.sendKeyUpEvent(key);
      await tester.pump();
    } finally {
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
    }
  }

  Future<void> pressUndo(WidgetTester tester) =>
      withCtrl(tester, LogicalKeyboardKey.keyZ);

  Future<void> pressRedo(WidgetTester tester) =>
      withCtrl(tester, LogicalKeyboardKey.keyY);

  /// 走真实用户路径切事件：点左上角事件芯片 → 面板里点目标事件行。
  /// `from` 是当前事件的标题（芯片只显示当前事件），`to` 是目标行标题。
  Future<void> switchEvent(
    WidgetTester tester, {
    required String from,
    required String to,
  }) async {
    await tester.tap(find.textContaining(from).first);
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining(to));
    await tester.pumpAndSettle();
  }

  testWidgets('撤销删节点：乙 的卡片与坐标一起回来（不掉到 0,0）', (tester) async {
    final w = await mount(tester);
    final posBefore = posOf(tester, _t2)!;
    expect(
      posBefore,
      isNot(Offset.zero),
      reason: '前置：自动布局应已给 乙 一个非零坐标，否则本用例测不出什么',
    );

    w.onSelectionChanged(FlowSelection.ofNode(_t2));
    await settle(tester);
    canvasOf(tester).onDeleteNode(_t2);
    await settle(tester);

    expect(nodeOf(tester, _t2), isNull, reason: '删除没生效，后面的撤销断言无从判断');
    expect(nodeText('乙'), findsNothing);
    expect(posOf(tester, _t2), isNull, reason: '删节点应当连坐标一起清掉');

    await focusCanvas(tester);
    await pressUndo(tester);
    await settle(tester);

    expect(nodeText('乙'), findsOneWidget, reason: 'Ctrl+Z 没把节点放回来');
    expect(
      posOf(tester, _t2),
      posBefore,
      reason: '复活的节点掉到 Offset.zero：快照没带 positions，'
          '或 _historyStep 忘了把 step.positions 交回宿主',
    );
    expect(
      nodeOf(tester, _t2)!.content,
      '乙',
      reason: '节点回来了但台词没回来',
    );
  });

  testWidgets('撤销删节点：上游 甲→乙 的重连也整段回滚', (tester) async {
    await mount(tester);
    const t1Tot2 = FlowEdge(from: _t1, to: _t2, kind: FlowEdgeKind.next);
    final edgesBefore = edgesOf(tester);
    expect(
      edgesBefore,
      {t1Tot2},
      reason: '前置：初始只有 甲→乙 一条边',
    );

    canvasOf(tester).onDeleteNode(_t2);
    await settle(tester);

    expect(
      edgesOf(tester),
      isNot(contains(t1Tot2)),
      reason: '前置：删 乙 时 甲 的 nextTalk 已被重映射',
    );
    expect(
      edgesOf(tester),
      {const FlowEdge(from: _t1, to: _t3, kind: FlowEdgeKind.next)},
      reason: '删 乙 后 甲 应被重连到同事件后续最近的 丙',
    );

    await focusCanvas(tester);
    await pressUndo(tester);
    await settle(tester);

    expect(
      edgesOf(tester),
      edgesBefore,
      reason: '撤销后边集必须与删除前逐条相等：卡片回来了但连线停在 甲→丙，'
          '就是快照与 _stageTalks 共享了嵌套列表',
    );
    expect(edgesOf(tester), contains(t1Tot2));
  });

  testWidgets('内联打字三步合成一步撤销（mergeKey 走通到宿主）', (tester) async {
    final w = await mount(tester);
    w.onSelectionChanged(FlowSelection.ofNode(_t2));
    await settle(tester);
    canvasOf(tester).onToggleExpand(_t2);
    await settle(tester);

    // 展开区已挂上 content 字段（标签与输入框同时存在，缺控制器就不渲染标签）。
    // 行标签 = kGuideFieldLabels['content']（台词内容）+ 字段 key。
    expect(
      find.descendant(
        of: find.byType(StoryFlowGraph),
        matching: find.text('台词内容 content'),
      ),
      findsOneWidget,
      reason: '前置：乙 未展开，内联 content 输入框不存在',
    );

    void type(String text) => canvasOf(
      tester,
    ).onFieldChanged(_t2, 'content', text);

    type('甲');
    await settle(tester);
    type('甲乙');
    await settle(tester);
    type('甲乙丙');
    await settle(tester);
    expect(nodeOf(tester, _t2)!.content, '甲乙丙');

    await focusCanvas(tester);
    await pressUndo(tester);
    await settle(tester);

    expect(
      nodeOf(tester, _t2)!.content,
      '乙',
      reason: '三次按键只退掉最后两个字：mergeKey 没合成，一步撤销应整段退回',
    );
    expect(
      nodeText('甲乙'),
      findsNothing,
      reason: '卡片仍显示 甲乙… → 打字被记成了三步',
    );
  });

  testWidgets('撤销回到基线后不再算未保存；真改了才弹「未保存的修改」', (tester) async {
    await mount(tester);

    canvasOf(tester).onFieldChanged(_t1, 'content', '甲改');
    await settle(tester);
    expect(
      find.text('未保存'),
      findsOneWidget,
      reason: '前置：改过内容必须标未保存，否则后面的断言是假通过',
    );

    await focusCanvas(tester);
    await pressUndo(tester);
    await settle(tester);
    expect(nodeOf(tester, _t1)!.content, '甲');
    expect(
      find.text('未保存'),
      findsNothing,
      reason: '退回到基线仍算未保存：_historyStep 没有用 sameStage 重算 _dirty，'
          '用户会看到一个撤销干净了却还逼他保存的画布',
    );

    // 干净画布：切事件不该弹确认。
    await switchEvent(tester, from: _evtTitle, to: _evt2Title);
    expect(
      find.text('未保存的修改'),
      findsNothing,
      reason: '画布已退回基线，切事件不该再弹未保存确认',
    );
    expect(nodeText('丁'), findsOneWidget, reason: '没真的切到事件 2');
    expect(nodeOf(tester, _t1), isNull, reason: '事件 1 的节点不该留在事件 2 画布上');

    // 脏画布：必须弹。
    canvasOf(tester).onFieldChanged(_t21, 'content', '丁改');
    await settle(tester);
    await switchEvent(tester, from: _evt2Title, to: _evtTitle);
    expect(
      find.text('未保存的修改'),
      findsOneWidget,
      reason: '有未保存修改时切事件必须经 _confirmDirtyGate 弹确认',
    );

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('未保存的修改'), findsNothing);
    expect(
      nodeText('丁改'),
      findsOneWidget,
      reason: '取消切换后应停在事件 2 且保留修改',
    );
    await settle(tester);
  });

  testWidgets('Ctrl+Y 重做把撤销掉的编辑放回来', (tester) async {
    await mount(tester);

    canvasOf(tester).onFieldChanged(_t1, 'content', '甲改');
    await settle(tester);
    await focusCanvas(tester);
    await pressUndo(tester);
    await settle(tester);
    expect(nodeOf(tester, _t1)!.content, '甲', reason: '前置：撤销没生效');
    expect(nodeText('甲改'), findsNothing);

    await pressRedo(tester);
    await settle(tester);

    expect(nodeOf(tester, _t1)!.content, '甲改');
    expect(nodeText('甲改'), findsOneWidget);
    expect(
      find.text('未保存'),
      findsOneWidget,
      reason: '重做后确实又改了内容，未保存标记必须跟着回来',
    );
  });

  testWidgets('撤销栈在切事件时作废：旧事件的删除不会被灌进新事件', (tester) async {
    await mount(tester);

    // 事件 1 删掉 乙（一步可撤销），不撤销，直接切走并选「放弃修改」。
    canvasOf(tester).onDeleteNode(_t2);
    await settle(tester);
    expect(nodeText('乙'), findsNothing);

    await switchEvent(tester, from: _evtTitle, to: _evt2Title);
    expect(
      find.text('未保存的修改'),
      findsOneWidget,
      reason: '前置：脏画布切事件应先弹确认',
    );
    await tester.tap(find.text('放弃修改'));
    await tester.pumpAndSettle();
    expect(nodeText('丁'), findsOneWidget, reason: '没切到事件 2');
    expect(nodeText('乙'), findsNothing, reason: '放弃修改后 乙 不该被带回');

    await focusCanvas(tester);
    await pressUndo(tester);
    await settle(tester);

    expect(
      nodeText('乙'),
      findsNothing,
      reason: '切事件后还能撤销出上一个事件的节点：_selectEventInner / '
          '_discardStage 没有重新 seed 栈',
    );
    expect(nodeOf(tester, _t1), isNull, reason: '事件 1 的对白出现在事件 2 画布上');
    expect(nodeOf(tester, _t3), isNull, reason: '事件 1 的对白出现在事件 2 画布上');
    expect(nodeText('丁'), findsOneWidget, reason: '新事件的内容被撤销栈吃掉了');
    await settle(tester);
  });
}
