import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:student_age_editor/core/api_client.dart';
import 'package:student_age_editor/core/models.dart';
import 'package:student_age_editor/features/editor/field_meta.dart';
import 'package:student_age_editor/features/story/story_director_view.dart';
import 'package:student_age_editor/features/story/story_flow_graph.dart';
import 'package:student_age_editor/features/story/story_flow_models.dart';
import 'package:student_age_editor/features/story/story_logic.dart';

/// 内联展开区要渲染的字段：与 workspace 交给画布的同一份清单同形。
/// 渲染出来是「label key」，所以断言里的中文名就是这里的 label。
const _talkMetas = <FieldMeta>[
  FieldMeta(key: 'roleName', type: 'String', label: '说话人', section: 'common'),
  FieldMeta(key: 'content', type: 'String', label: '台词', section: 'common'),
  FieldMeta(
    key: 'check',
    type: '2D Array',
    label: '检定',
    section: 'common',
    effectLike: true,
    suggestMode: 'condition',
    multivalued: true,
  ),
  FieldMeta(
    key: 'screenEffect',
    type: '1D Array',
    label: '屏幕效果',
    section: 'common',
    effectLike: true,
    suggestMode: 'screen',
    multivalued: true,
    replaceWholeOnAccept: true,
  ),
  FieldMeta(
    key: 'bg',
    type: 'Number',
    label: '背景',
    section: 'common',
    rule: FieldRule(dictName: 'bgs'),
  ),
  FieldMeta(
    key: 'audio',
    type: 'Number',
    label: '音频',
    section: 'common',
    rule: FieldRule(dictName: 'audios'),
  ),
  FieldMeta(key: 'time', type: 'Number', label: '时间', section: 'common'),
];

/// 画布交互回归测试：内联编辑区的滚轮隔离、删除入口（按钮/键盘）、
/// 缩放状态下的节点命中。
void main() {
  const nodeId = '1000001001';

  late FlowGraph graph;
  late Map<String, TextEditingController> ctls;
  late Set<String> expanded;
  late List<String> deletedNodes;
  late int requestDeleteCalls;
  late List<String> toggleExpandCalls;
  late FlowSelection selection;

  setUp(() {
    final talks = <String, dynamic>{
      nodeId: {'roleName': '旁白', 'content': 'a', 'nextTalk': []},
    };
    graph = buildFlowGraph(
      talks: talks,
      options: {},
      prefixes: ['1000001'],
      starts: [nodeId],
    );
    ctls = {};
    expanded = {};
    deletedNodes = [];
    requestDeleteCalls = 0;
    toggleExpandCalls = [];
    selection = FlowSelection.none;
  });

  TextEditingController ctlFor(String id, String field) =>
      ctls.putIfAbsent('$id|$field', () => TextEditingController(text: ''));

  // 回调触发后需以新的 selected/expanded 重建（模拟宿主 setState）。
  Future<void> pump(
    WidgetTester tester, {
    Map<String, Offset>? positions,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: fluent.FluentTheme(
          data: fluent.FluentThemeData(brightness: Brightness.dark),
          child: Scaffold(
            body: SizedBox(
              width: 900,
              height: 700,
              child: StoryFlowGraph(
                graph: graph,
                positions: positions ?? const {nodeId: Offset(100, 100)},
                selection: selection,
                expandedNodes: expanded,
                onSelectionChanged: (s) => selection = s,
                onMoveNode: (_, _) {},
                onAddEdge: (_, _, _) {},
                onDeleteEdge: (_, _, _) {},
                onRequestDelete: () => requestDeleteCalls++,
                onToggleExpand: (id) => toggleExpandCalls.add(id),
                fieldController: ctlFor,
                inlineMetas: (_) => _talkMetas,
                onFieldChanged: (_, _, _) {},
                onDeleteNode: deletedNodes.add,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// 发送滚轮信号（PointerSignalEvent 按事件位置逐次命中测试，无需注册指针）。
  Future<void> wheel(WidgetTester tester, Offset pos, double dy) async {
    await tester.sendEventToBinding(
      PointerScrollEvent(position: pos, scrollDelta: Offset(0, dy)),
    );
    await tester.pumpAndSettle();
  }

  double editorScrollOffset(WidgetTester tester) {
    final scrollable = find.descendant(
      of: find.byType(StoryFlowGraph),
      matching: find.byType(Scrollable),
    );
    return tester.state<ScrollableState>(scrollable.first).position.pixels;
  }

  /// 视口缩放：阶段 4 后卡片按世界像素布局，缩放只体现在 FlowViewport 上，
  /// 控件 layout size 恒定不变，所以直接读画布状态暴露的视口。
  double viewScale(WidgetTester tester) => tester
      .state<StoryFlowGraphState>(find.byType(StoryFlowGraph))
      .viewportListenable
      .value
      .scale;

  group('展开内联编辑器', () {
    testWidgets('点击删除按钮调用 onDeleteNode', (tester) async {
      expanded.add(nodeId);
      await pump(tester);
      expect(find.text('参数'), findsOneWidget);
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      expect(deletedNodes, [nodeId]);
    });

    testWidgets('展开对白节点含 screenEffect 编辑行', (tester) async {
      expanded.add(nodeId);
      await pump(tester);
      expect(find.textContaining('屏幕效果 screenEffect'), findsOneWidget);
      // 选项类字段不应出现在对白编辑区
      expect(find.textContaining('主支对白'), findsNothing);
    });

    testWidgets('编辑区内的滚轮只滚编辑区，不缩放画布', (tester) async {
      expanded.add(nodeId);
      await pump(tester);
      final before = viewScale(tester);
      await wheel(tester, const Offset(200, 300), 120);
      expect(viewScale(tester), before, reason: '画布被缩放：滚轮穿透到了画布 zoom');
      expect(editorScrollOffset(tester), greaterThan(0.0), reason: '编辑区自身应可滚动');
    });

    testWidgets('空白画布上的滚轮仍然缩放', (tester) async {
      expanded.add(nodeId);
      await pump(tester);
      final before = viewScale(tester);
      await wheel(tester, const Offset(600, 500), -120);
      expect(viewScale(tester), isNot(before), reason: '画布空白处滚轮应缩放视图');
    });
  });

  group('删除入口', () {
    testWidgets('选中节点后按 Delete 键触发 onRequestDelete', (tester) async {
      await pump(tester);
      // 点击底座卡片选中节点（不落在端口/箭头上）
      await tester.tapAt(const Offset(150, 130));
      await tester.pumpAndSettle();
      await pump(tester); // 以 selected 重建，模拟宿主 setState
      expect(selection.onlyNode, nodeId);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.delete);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.delete);
      await tester.pumpAndSettle();
      expect(requestDeleteCalls, 1);
    });

    testWidgets('缩放状态下点击卡片实际足迹仍能选中节点', (tester) async {
      await pump(tester);
      // 在空白处 (600,500) 放大 1.1 倍：pan = (600,500)*(-0.1) = (-60,-50)，
      // 节点 (100,100) → 屏幕 (50,60)，卡片足迹 x∈[50,270]、y∈[60,183]。
      // 旧命中矩形宽未乘 scale（右缘 250+4），260 处落空 → 复现该 bug。
      await wheel(tester, const Offset(600, 500), -120);
      await tester.tapAt(const Offset(260, 120));
      await tester.pumpAndSettle();
      expect(
        selection.onlyNode,
        nodeId,
        reason: '_nodeScreenRect 宽未乘 scale，缩放后命中区与卡片错位',
      );
    });

    testWidgets('焦点在外部输入框时，点选节点后 Delete 仍可删除', (tester) async {
      // 复现真实应用情形：AI 输入框等拿走过焦点后，点画布节点应把
      // 键盘焦点收回画布，否则 Delete/Backspace 永远传不进 onRequestDelete。
      final fieldFocus = FocusNode();
      Future<void> pumpWithField() async {
        await tester.pumpWidget(
          MaterialApp(
            home: fluent.FluentTheme(
              data: fluent.FluentThemeData(brightness: Brightness.dark),
              child: Scaffold(
                body: Column(
                  children: [
                    SizedBox(
                      height: 30,
                      child: TextField(focusNode: fieldFocus),
                    ),
                    Expanded(
                      child: StoryFlowGraph(
                        graph: graph,
                        positions: const {nodeId: Offset(100, 100)},
                        selection: selection,
                        expandedNodes: expanded,
                        onSelectionChanged: (s) => selection = s,
                        onMoveNode: (_, _) {},
                        onAddEdge: (_, _, _) {},
                        onDeleteEdge: (_, _, _) {},
                        onRequestDelete: () => requestDeleteCalls++,
                        onToggleExpand: (id) => toggleExpandCalls.add(id),
                        fieldController: ctlFor,
                        inlineMetas: (_) => _talkMetas,
                        onFieldChanged: (_, _, _) {},
                        onDeleteNode: deletedNodes.add,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
      }

      await pumpWithField();
      await tester.tapAt(const Offset(20, 15)); // 点外部文本框，焦点离开画布
      await tester.pumpAndSettle();
      expect(fieldFocus.hasFocus, isTrue);
      await tester.tapAt(const Offset(150, 130)); // 点选节点
      await tester.pumpAndSettle();
      await pumpWithField(); // 以 selected 重建，模拟宿主 setState
      expect(selection.onlyNode, nodeId);
      expect(fieldFocus.hasFocus, isFalse, reason: '点选画布节点后画布应收回键盘焦点');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.delete);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.delete);
      await tester.pumpAndSettle();
      expect(requestDeleteCalls, 1);
      fieldFocus.dispose();
    });
  });

  group('指针按键门控与徽章行', () {
    testWidgets('右键按下画布不被接管：不会选中节点/平移', (tester) async {
      await pump(tester);
      final g = await tester.startGesture(
        const Offset(150, 130),
        buttons: kSecondaryButton,
      );
      await g.moveTo(const Offset(400, 400));
      await g.up();
      await tester.pumpAndSettle();
      expect(selection.isEmpty, isTrue, reason: '右键此前被当左键接管，还会连带平移画布');
    });

    testWidgets('左键按下卡片仍可选中（门控不误伤正常操作）', (tester) async {
      await pump(tester);
      final g = await tester.startGesture(const Offset(150, 130));
      await g.up();
      await tester.pumpAndSettle();
      expect(selection.onlyNode, nodeId);
    });

    testWidgets('对白 5 徽章（bg+audio+time+特效+检定）不再溢出卡片', (tester) async {
      graph = buildFlowGraph(
        talks: {
          nodeId: {
            'content': 'a',
            'nextTalk': [],
            'bg': 5,
            'audio': 6,
            'time': 7,
            'screenEffect': [
              [4001],
              [4014],
            ],
            'check': [
              [1, 3, 2],
            ],
          },
        },
        options: {},
        prefixes: ['1000001'],
        starts: [nodeId],
      );
      await pump(tester);
      expect(
        tester.takeException(),
        isNull,
        reason: '徽章行无收缩时 RenderFlex overflow',
      );
    });
  });

  group('视口裁剪与 LOD 档位', () {
    /// 画布里挂载的卡片数：每张卡片恰有一个 RepaintBoundary。
    int mountedCards(WidgetTester tester) => find
        .descendant(
          of: find.byType(StoryFlowGraph),
          matching: find.byType(RepaintBoundary),
        )
        .evaluate()
        .length;

    FlowViewport viewport(WidgetTester tester) => tester
        .state<StoryFlowGraphState>(find.byType(StoryFlowGraph))
        .viewportListenable
        .value;

    /// 节点底座中部的屏幕坐标：与绘制同一套换算（screen = pan + scale·world）。
    Offset screenOf(WidgetTester tester, Offset world) =>
        world * viewport(tester).scale +
        viewport(tester).pan +
        tester.getTopLeft(find.byType(StoryFlowGraph)) +
        const Offset(60, 40);

    testWidgets('视口外节点不挂卡片；平移进来后可点选', (tester) async {
      // 画布 900x700：世界 (1200,900) 在视口外，一次平移即可送进可见区。
      const far = Offset(1200, 900);
      await pump(tester, positions: {nodeId: far});
      expect(mountedCards(tester), 0, reason: '裁剪未生效：视口外仍挂了卡片');
      final g = await tester.startGesture(const Offset(700, 550));
      await g.moveTo(const Offset(100, 100));
      await g.up();
      await tester.pumpAndSettle();
      expect(
        viewport(tester).pan,
        const Offset(-600, -450),
        reason: '平移本身没发生：后面的断言无从判断',
      );
      expect(mountedCards(tester), greaterThan(0), reason: '平移进视口后卡片没挂回来');
      await tester.tapAt(screenOf(tester, far));
      await tester.pumpAndSettle();
      expect(selection.onlyNode, nodeId, reason: '裁剪后的命中换算与绘制位置不一致');
    });

    testWidgets('缩到色块档再回到完整档，卡片仍可点选', (tester) async {
      await pump(tester);
      // 0.9^9 ≈ 0.39 < 0.43 → 色块档：一张卡片都不挂，节点由 painter 画色块。
      for (var i = 0; i < 9; i++) {
        await wheel(tester, const Offset(600, 500), 120);
      }
      expect(viewport(tester).scale, lessThan(kLodTitleDown));
      expect(mountedCards(tester), 0, reason: '色块档仍挂着卡片');
      // fitView 会跳回最大缩放：档位缓存必须重建卡片。
      tester.state<StoryFlowGraphState>(find.byType(StoryFlowGraph)).fitView();
      await tester.pumpAndSettle();
      expect(viewport(tester).scale, greaterThan(kLodFullUp));
      expect(mountedCards(tester), greaterThan(0), reason: '换回完整档后档位缓存没重建卡片');
      await tester.tapAt(screenOf(tester, const Offset(100, 100)));
      await tester.pumpAndSettle();
      expect(selection.onlyNode, nodeId);
    });
  });

/// ─────────────────────────────────────────────────────────────────────────
/// C1：事件列表「对白 N」的桶派生（story_director_view.dart）。
///
/// 旧实现 `_eventTalkCount` 每行新建 PrefixMatcher 并扫描整张 TalkCfg
/// （真实 ~9.9 万行），一屏 20 行 ≈ 每帧数百万次 match。新实现只在表内容
/// 变化时派生 `前缀 → 对白数` 桶表，行 build 只查表。这里锁两件事：
///   1. 桶口径与 PrefixMatcher.match 逐行判定严格等价（行为不变）；
///   2. 派生扫描每张新表恰好 1 次，重泵/切事件 0 次（性能不变差）。
/// ─────────────────────────────────────────────────────────────────────────
group('C1 事件对白数：桶派生等价 + 派生扫描探针', () {
  /// 故意覆盖边界：4 位 id（去 1 位）、7 位 id（去 3 位）、3 位以下短 id
  /// （归自身桶）、`.0` 尾巴（cln）、空白键（空 id 永不命中）。
  final evtCfg = <String, dynamic>{
    '3': {'id': 3, 'title': '短号', 'type': 0, 'talkId': <dynamic>[]},
    '35': {'id': 35, 'title': '两位', 'type': 0, 'talkId': <dynamic>[]},
    '3001': {'id': 3001, 'title': '千号', 'type': 0, 'talkId': <dynamic>['3001001']},
    '3005': {'id': 3005, 'title': '空事件', 'type': 0, 'talkId': <dynamic>[]},
    'abc': {'id': 0, 'title': '非数字', 'type': 0, 'talkId': <dynamic>[]},
  };
  final talkCfg = <String, dynamic>{
    '3001001': {'id': 3001001, 'content': 'a'},
    '3001002': {'id': 3001002, 'content': 'b'},
    '3002': {'id': 3002, 'content': 'c'}, // 4 位 → 前缀 '3'
    ' 3004.0 ': {'id': 3004, 'content': 'd'}, // cln → '3004' → 前缀 '3'
    '35': {'id': 35, 'content': 'e'}, // 短 id 归自身桶
    'abc': {'id': 0, 'content': 'f'}, // 3 位 → 自身桶
    '': {'id': 0, 'content': 'g'}, // 空 id：match 恒 false，桶跳过
    '   ': {'id': 0, 'content': 'h'}, // 空白 id：同上
  };

  /// 旧口径逐字复刻：对整表逐行跑 PrefixMatcher.match（isOption 默认 false）。
  int legacyCount(String evt) {
    final m = PrefixMatcher(storyRelatedPrefixes(evt, evtCfg));
    return talkCfg.keys.where((k) => m.match(k)).length;
  }

  test('桶求和与 PrefixMatcher 逐行计数逐事件相等', () {
    // 与 _rederiveTalkPrefixCounts 同式的桶表（getTalkPrefix 计数）。
    final buckets = <String, int>{};
    for (final k in talkCfg.keys) {
      final p = getTalkPrefix(k);
      if (p.isEmpty) continue;
      buckets[p] = (buckets[p] ?? 0) + 1;
    }
    for (final evt in evtCfg.keys) {
      var byBucket = 0;
      for (final p in storyRelatedPrefixes(evt, evtCfg)) {
        byBucket += buckets[p] ?? 0;
      }
      expect(byBucket, legacyCount(evt), reason: '事件 $evt 的对白数两种口径不一致');
    }
    // 字面值钉底：防止两套实现一起错（同错对照不出等价性破绽）。
    expect(legacyCount('3'), 2, reason: "'3002' 与 ' 3004.0 ' 都派生到前缀 3");
    expect(legacyCount('3001'), 2, reason: "7 位 id 去末尾 3 位得 '3001'");
    expect(legacyCount('35'), 1, reason: '2 位短 id 归自身桶');
    expect(legacyCount('abc'), 1, reason: '3 位短 id 归自身桶');
    expect(legacyCount('3005'), 0, reason: '空事件对白数为 0，空/空白键永不计数');
  });

  testWidgets('探针：表换新派生恰 1 次；重泵/切事件 0 次；行内数字=旧口径', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    ApiClient.instance.client = MockClient((req) async {
      final name = req.url.path.split('/').last;
      final data = switch (name) {
        'EvtCfg' => evtCfg,
        'TalkCfg' => talkCfg,
        _ => <String, dynamic>{},
      };
      return http.Response(
        jsonEncode({'cfg': name, 'data': data, 'exists': true}),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    addTearDown(() => ApiClient.instance.client = http.Client());

    Future<void> pumpHost() => tester.pumpWidget(
      fluent.FluentApp(
        home: Scaffold(body: StoryDirectorView(state: AppState())),
      ),
    );

    await pumpHost();
    await tester.pumpAndSettle();
    expect(
      debugTalkDerivedScans,
      1,
      reason: 'TalkCfg 整表换新应恰好派生扫描 1 次',
    );

    // 行内「对白 N」与旧口径一致：['$id] 标题 Text 的最近 Column 祖先即行容器。
    int rowTalkCount(String evt) {
      final title = find.textContaining('[$evt]').first;
      final row = find
          .ancestor(of: title, matching: find.byType(Column))
          .first;
      final countText = tester.widget<Text>(
        find.descendant(
          of: row,
          matching: find.textContaining(RegExp(r'^对白 \d+')),
        ),
      );
      return int.parse(
        RegExp(r'对白 (\d+)').firstMatch(countText.data!)!.group(1)!,
      );
    }

    for (final evt in evtCfg.keys) {
      expect(rowTalkCount(evt), legacyCount(evt), reason: '事件 $evt 行内显示的对白数');
    }

    // 切换事件：表内容没变，不得重派生。
    await tester.tap(find.textContaining('[3001]').first);
    await tester.pumpAndSettle();
    expect(debugTalkDerivedScans, 1, reason: '切事件只是查桶，不该再全表扫描');

    // 纯宿主重泵 30 次：行 build 只查桶表。
    for (var i = 0; i < 30; i++) {
      await pumpHost();
      await tester.pump();
    }
    expect(
      debugTalkDerivedScans,
      1,
      reason: '重建期间出现重派生 → 等价于退回「每行全表扫描」',
    );
  });
});

}
