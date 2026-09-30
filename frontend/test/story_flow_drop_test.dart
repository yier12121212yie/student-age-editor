// M6「剧情图深度融合」回归：画布 DragTarget 统一收 FlowDropRef 三类拖源，
// 空白落点建节点（模板整组 / 资产种子对白 / 效果行对白），命中节点保持
// 资产写字段旧语义。至少一条链路走真实手势管道（startGesture → moveTo → up）。
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:student_age_editor/core/api_client.dart';
import 'package:student_age_editor/core/models.dart';
import 'package:student_age_editor/features/story/story_flow_drop.dart';
import 'package:student_age_editor/features/story/story_flow_graph.dart';
import 'package:student_age_editor/features/story/story_flow_models.dart';
import 'package:student_age_editor/features/story/story_flow_workspace.dart';
import 'package:shared_preferences/shared_preferences.dart';

const aId = '1000001001';
const bId = '1000001002';

/// 每用例可覆写的 /api/effect_suggest 候选与观测点。
List<Map<String, dynamic>> effectItems = [];
List<Map<String, String>> effectQueries = [];
List<Map<String, dynamic>> putBodies = [];

/// true = EvtCfg 为空（未选事件的只读态）。
bool emptyEvt = false;

http.Response _json(Object body, [int code = 200]) => http.Response(
  jsonEncode(body),
  code,
  headers: {'content-type': 'application/json'},
);

/// MockClient 主处理器：workspace 启动全量 8 表 + 事件前缀两小批 +
/// 资产索引 / 效果码表 / 保存链路。
Future<http.Response> _mock(http.Request request) async {
  final method = request.method;
  final path = request.url.path;
  if (method == 'PUT' && path.startsWith('/api/cfg/')) {
    putBodies.add({
      'cfg': path.split('/').last,
      'body': jsonDecode(request.body) as Map<String, dynamic>,
    });
    return _json({
      'ok': true,
      'cfg': path.split('/').last,
      'applied_set': 1,
      'applied_remove': 0,
      'mtime_ns': 12346,
      'snapshot': null,
    });
  }
  if (method == 'PUT' && path == '/api/tools/write') {
    return _json({'ok': true});
  }
  if (path.startsWith('/api/cfg/')) {
    final name = path.split('/').last;
    final data = switch (name) {
      'EvtCfg' => emptyEvt
          ? <String, dynamic>{}
          : {
              '1000001': {
                'id': 1000001,
                'title': '事件甲',
                'type': 0,
                'talkId': [aId],
              },
            },
      'TalkCfg' => {
          aId: {'id': aId, 'content': '开场白', 'nextTalk': <dynamic>[]},
          // bId 无入边 → 自动布局排到第二列 (290,40)，卡片中心不被
          // 资产面板（left 62..362）遮住，可作「拖到已有节点」的落点
          bId: {'id': bId, 'content': '下一句', 'nextTalk': <dynamic>[]},
        },
      // 贴图 key 的 basename（sunset）按 url 匹配命中
      'BgCfg' => {
          '9': {'id': 9, 'name': '夕阳教室', 'url': 'BG/sunset.png'},
        },
      _ => <String, dynamic>{},
    };
    return _json({
      'cfg': name,
      'data': data,
      'keys': data.keys.toList(),
      'exists': true,
      'mtime_ns': 12345,
    });
  }
  if (path == '/api/plugins/ui/flow_cards') {
    return _json({'flow_cards': []});
  }
  if (path == '/api/tools/read') {
    // 布局文件 / 模板库文件均不存在 → 空布局空模板库
    return _json({'error': 'not a file'}, 400);
  }
  if (path == '/api/workspace/revision') {
    return _json({
      'revision': List<String>.filled(64, 'a').join(),
      'computed_at_ms': 1,
      'files_scanned': 1,
    });
  }
  if (path == '/api/effect_suggest') {
    final q = request.url.queryParameters['q'] ?? '';
    effectQueries.add(Map<String, String>.from(request.url.queryParameters));
    return _json({
      'items': [
        for (final e in effectItems)
          if (q.isEmpty ||
              (e['desc'] ?? '').toString().contains(q) ||
              (e['code'] ?? '').toString().contains(q))
          e,
      ],
    });
  }
  if (path == '/api/aa/keys') {
    return _json({'tex': ['BG/sunset.png'], 'aud': [], 'flow_filtered': true});
  }
  if (path == '/api/aa/preview') {
    // 测试环境无图片字节：TexThumb 容错显示占位
    return _json({'error': 'no bytes'}, 404);
  }
  return _json({'error': 'unexpected $path'}, 500);
}

Future<void> _mount(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = const Size(1400, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  putBodies = [];
  effectQueries = [];
  ApiClient.instance.client = MockClient(_mock);
  addTearDown(() => ApiClient.instance.client = http.Client());
  final state = AppState()
    ..modName = 'A'
    ..modRoot = r'C:\mods\A';
  await tester.pumpWidget(fluent.FluentApp(
    debugShowCheckedModeBanner: false,
    home: Scaffold(
      body: StoryFlowWorkspace(
        state: state,
        onPreview: (_) {},
        onOpenPlugins: () {},
        onOpenSettings: () {},
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

/// 真实手势管道：从 [press] 按下 → 拖到 [target] → 松手。
Future<void> _drag(WidgetTester tester, Offset press, Offset target) async {
  final g = await tester.startGesture(press);
  await g.moveTo(target);
  await g.up();
  await tester.pumpAndSettle();
}

/// 真实手势管道：从拖源 [source] 中心按下拖到 [target]。
Future<void> _dragFrom(
  WidgetTester tester,
  Finder source,
  Offset target,
) async {
  await _drag(tester, tester.getCenter(source), target);
}

/// 排干 displayInfoBar 自动关闭定时器 + 布局回写防抖，避免 pending timer。
Future<void> _drainTimers(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 7));
  await tester.pumpAndSettle();
}

StoryFlowGraph _graphWidget(WidgetTester tester) =>
    tester.widget<StoryFlowGraph>(find.byType(StoryFlowGraph));

List<FlowNode> _talks(WidgetTester tester) => _graphWidget(tester)
    .graph
    .nodes
    .where((n) => n.kind == FlowNodeKind.talk)
    .toList();

void main() {
  setUp(() {
    effectItems = [
      {
        'code': '[1, 1, 3, 5]',
        'desc': '好感上升',
        'raw_code': '[1, 1, @ATTR@, V]',
        'slots': [],
      },
    ];
    putBodies = [];
    effectQueries = [];
    emptyEvt = false;
  });

  testWidgets('① 空白落点拖入模板：整组生成、入口落在落点、位置已登记、标脏', (
    tester,
  ) async {
    await _mount(tester);
    // 打开「模板拖源」面板
    await tester.tap(find.byIcon(Icons.auto_awesome_motion));
    await tester.pumpAndSettle();
    expect(find.text('开场三句独白'), findsOneWidget);

    // 可编辑态：所有拖源都允许启动拖拽
    final sources = tester
        .widgetList<Draggable<FlowDropRef>>(find.byType(Draggable<FlowDropRef>));
    expect(sources, isNotEmpty);
    expect(sources.every((d) => d.maxSimultaneousDrags == 1), isTrue);

    // 真实手势：模板卡 → 画布空白处（原节点卡片在 (40,40) 附近，远离落点）
    const target = Offset(860, 640);
    // DragTargetDetails.offset 是拖影锚点 = 指针位置 − childDragAnchorStrategy
    // 的抓取偏移（按点相对 Draggable child），与 workspace 的 hitNodeAt 同一坐标系
    final press = tester.getCenter(find.text('开场三句独白'));
    final grab = press -
        tester.getTopLeft(
          find.ancestor(
            of: find.text('开场三句独白'),
            matching: find.byType(Draggable<FlowDropRef>),
          ).first,
        );
    await _drag(tester, press, target);
    await tester.pumpAndSettle();

    // 原 2 个对白 + 模板「开场三句独白」3 个对白 = 5
    expect(_talks(tester), hasLength(5),
        reason: '空白落点应按模板整组创建节点');

    // 入口节点（relativePos 0,0）世界坐标 ≈ 落点；graphW.positions 即宿主 _positions
    final st = tester.state<StoryFlowGraphState>(find.byType(StoryFlowGraph));
    final world = st.viewportListenable.value.toWorld(target - grab);
    final atDrop = _graphWidget(tester)
        .positions
        .values
        .where((p) => (p - world).distance < 1.0)
        .toList();
    expect(atDrop, hasLength(1), reason: '入口节点应落在拖放世界坐标');

    // 保存标志置位（操作簇从「已保存」变「保存修改」+「未保存」徽标）
    expect(find.text('保存修改'), findsOneWidget);
    expect(find.text('未保存'), findsOneWidget);

    await _drainTimers(tester);
  });

  testWidgets('② 空白落点放图片资产：新建对白节点并写入背景字段', (tester) async {
    await _mount(tester);
    await tester.tap(find.byIcon(Icons.image_outlined));
    await tester.pumpAndSettle();
    expect(find.text('BG/sunset.png'), findsOneWidget,
        reason: '资产索引应来自 /api/aa/keys 桩');

    await _dragFrom(tester, find.text('BG/sunset.png'), const Offset(700, 600));
    await tester.pumpAndSettle();

    final spawned =
        _talks(tester).where((n) => n.id != aId && n.id != bId).toList();
    expect(spawned, hasLength(1), reason: '空白落点应新建一个种子对白节点');
    expect(spawned.single.bgId, '9',
        reason: '贴图 key 按 BgCfg url 匹配后应写成 bg 字段（与拖到节点同语义）');
    expect(_graphWidget(tester).positions.keys, contains(spawned.single.id),
        reason: '新节点坐标应登记进 _positions');

    await _drainTimers(tester);
  });

  testWidgets('③ 空白落点放效果行：新建对白节点效果字段=该码', (tester) async {
    effectItems = [
      {
        'code': '[1, 1, 3, 5]',
        'desc': '好感上升',
        'raw_code': '[1, 1, @ATTR@, V]',
        'slots': [],
      },
    ];
    await _mount(tester);
    await tester.tap(find.byIcon(Icons.bolt));
    await tester.pumpAndSettle();
    expect(find.text('好感上升'), findsOneWidget);

    await _dragFrom(tester, find.text('好感上升'), const Offset(700, 600));
    await tester.pumpAndSettle();

    // 效果字段不直接渲染在卡片上：标脏后保存，从 PUT 补丁断言
    await tester.tap(find.text('保存修改'));
    await tester.pumpAndSettle();

    final talkPut = putBodies.where((p) => p['cfg'] == 'TalkCfg').toList();
    expect(talkPut, isNotEmpty, reason: '保存应发出 TalkCfg 补丁');
    final setPatch = (talkPut.last['body']['patch']
        as Map)['set'] as Map<String, dynamic>;
    final withEffect = [
      for (final v in setPatch.values)
        if (v is Map && v['effect'] != null) v,
    ];
    expect(withEffect, hasLength(1), reason: '新节点应带效果字段');
    expect(withEffect.single['effect'], [
      [1, 1, 3, 5],
    ], reason: '效果码应写成 2D 数组单行，数值槽转 num');

    await _drainTimers(tester);
  });

  testWidgets('④ 拖到已有节点上：资产写字段旧语义不变（不新建节点）', (tester) async {
    await _mount(tester);
    await tester.tap(find.byIcon(Icons.image_outlined));
    await tester.pumpAndSettle();

    // 拖源按点与拖影锚点：DragTargetDetails.offset = 指针 − 抓取偏移。
    // 让锚点恰好落在 bId 卡片中心（hitNodeAt 命中），指针须在面板右侧画布上。
    final item = find.ancestor(
      of: find.text('BG/sunset.png'),
      matching: find.byType(Draggable<FlowDropRef>),
    ).first;
    final press = tester.getCenter(find.text('BG/sunset.png'));
    final grab = press - tester.getTopLeft(item);
    final cardRect = tester.getRect(find.byKey(const ValueKey(bId)).first);
    final target = cardRect.center + grab;

    await _drag(tester, press, target);
    await tester.pumpAndSettle();

    expect(_talks(tester), hasLength(2), reason: '命中节点时不得新建节点');
    expect(_graphWidget(tester).graph.nodeById(bId)!.bgId, '9',
        reason: '旧语义：资产落到已有节点上写字段');
    expect(_graphWidget(tester).graph.nodeById(aId)!.bgId, '',
        reason: '未命中的节点不受影响');

    await _drainTimers(tester);
  });

  testWidgets('⑤ 工具栏效果搜索：候选渲染、q/mode 参数与过滤', (tester) async {
    effectItems = [
      {
        'code': '[1, 1, 3, 5]',
        'desc': '好感上升',
        'raw_code': '[1, 1, @ATTR@, V]',
        'slots': [],
      },
      {
        'code': '[60, -1, 12]',
        'desc': '消耗物品',
        'raw_code': '[60, -1, @ITEM@]',
        'slots': [],
      },
    ];
    await _mount(tester);
    await tester.tap(find.byIcon(Icons.bolt));
    await tester.pumpAndSettle();

    // 打开面板即拉码表（空 q），mode=effect
    expect(effectQueries, isNotEmpty);
    expect(effectQueries.last['mode'], 'effect');
    expect(effectQueries.last['q'], '');
    expect(find.text('好感上升'), findsOneWidget);
    expect(find.text('消耗物品'), findsOneWidget);

    // 搜索带 q= 重新拉取，桩按 desc 过滤
    await tester.enterText(find.byType(fluent.TextBox), '好感');
    await tester.pumpAndSettle();
    expect(effectQueries.last['q'], '好感');
    expect(effectQueries.last['mode'], 'effect');
    expect(find.text('好感上升'), findsOneWidget);
    expect(find.text('消耗物品'), findsNothing);

    await _drainTimers(tester);
  });

  testWidgets('⑥ 未选事件（只读态）：拖源 maxSimultaneousDrags 置 0 不启动拖拽', (
    tester,
  ) async {
    emptyEvt = true;
    await _mount(tester);
    // 无事件时画布是空态占位，拖源面板仍可打开查看
    await tester.tap(find.byIcon(Icons.auto_awesome_motion));
    await tester.pumpAndSettle();
    expect(find.text('开场三句独白'), findsOneWidget);

    final sources = tester
        .widgetList<Draggable<FlowDropRef>>(find.byType(Draggable<FlowDropRef>));
    expect(sources, isNotEmpty);
    expect(sources.every((d) => d.maxSimultaneousDrags == 0), isTrue,
        reason: 'enabled=false（只读态）时 Draggable 不应能启动拖拽');

    await _drainTimers(tester);
  });
}
