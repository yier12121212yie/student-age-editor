// Inspector（右侧全字段面板）回归。
//
// 钉住四件容易在后续改动里丢掉的事：
//   1. 字段全集由 metas 驱动：schema 里新增一个字段，收起的高级段一展开就必须
//      出现，不需要在面板里加任何字段名清单；
//   2. Tab 环只覆盖**当前可见**字段并回环，绝不落到面板外的输入框上
//      （`FocusScope.nextFocus()` 与 `Actions.invoke(NextFocusIntent())` 都会逃出去）；
//   3. 「必填未填」与「写回失败」两条小结必须各列各的，混起来用户就会把
//      「还没填」读成「填坏了」；
//   4. 按键路径上一个请求都不发：整表校验接口（/api/validate，约 9.8 万行）
//      只要出现在这里就是回归。
//
// 可见性（多选 / missing / 无选中不出现）归宿主，这里按「不同入参渲染面板」
// 的方式验面板自己的兜底：无目标时只出空态，不铺无主输入框。
// 宿主桩（控制器/焦点/写回/无效标记）与 story_flow_workspace 的同名实现同构，
// 候选源直接复用生产链路 sourceForField，免得测一套只存在于测试里的取数规则。
import 'dart:convert';

import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:student_age_editor/core/api_client.dart';
import 'package:student_age_editor/core/models.dart';
import 'package:student_age_editor/features/editor/field_meta.dart';
import 'package:student_age_editor/features/editor/suggestion_text_field.dart';
import 'package:student_age_editor/features/story/story_flow_field_codec.dart';
import 'package:student_age_editor/features/story/story_flow_inspector.dart';
import 'package:student_age_editor/features/story/story_flow_suggest.dart';

const _evt = '1000001';
const _node = '1000001000';

/// 假 schema：常用段 10 项 + 高级段 5 项（含只读主键与一个插件扩表字段）。
Map<String, dynamic> fakeSchema() => <String, dynamic>{
  'TalkCfg': <String, dynamic>{
    'id': 'Number',
    'content': 'String',
    'roleName': 'String',
    'roleIds': '1D Array',
    'bg': 'Number',
    'audio': 'Number',
    'time': 'Number',
    'screenEffect': '1D Array',
    'check': '1D Array',
    'nextTalk': '1D Array',
    'highlights': '1D Array',
    'tag': 'Number',
    'nextTalk2': '1D Array',
    'option': '1D Array',
  },
};

void main() {
  late AppState state;
  late _Host host;
  late List<String> requested;

  setUp(() {
    state = AppState()
      ..modName = 'Inspector'
      ..modRoot = r'C:\mods\inspector'
      ..gameSchema = fakeSchema()
      ..gameDicts = <String, dynamic>{
        'bgs': <String, dynamic>{'7': '教室'},
        'roles': <String, dynamic>{'3': '小明'},
        'audios': <String, dynamic>{'11': '上课铃'},
      };
    host = _Host(state);
    requested = <String>[];
    // 任何一次网络访问都会被记下来：面板在按键路径上必须零请求。
    ApiClient.instance.client = MockClient((request) async {
      requested.add(request.url.path);
      return http.Response(
        jsonEncode({'ok': true}),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
  });

  tearDown(() {
    host.dispose();
    ApiClient.instance.client = http.Client();
  });

  List<FieldMeta> metas() => flowFieldMetas(state, 'TalkCfg');

  FieldMeta metaOf(String key) => metas().firstWhere((m) => m.key == key);

  /// 重挂同一棵树（面板 State 就地更新，不重建）：宿主的 invalid/dirty 只在
  /// build 期取，测试里改完标记必须走这一次刷新。
  Widget tree({
    String nodeId = _node,
    Map<String, dynamic>? record,
    List<FieldMeta>? fieldMetas,
    bool showAdvanced = false,
    List<Widget> before = const [],
    List<Widget> after = const [],
  }) {
    return fluent.FluentApp(
      home: Scaffold(
        body: SizedBox(
          width: 800,
          height: 600,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ...before,
              Expanded(
                child: Align(
                  alignment: Alignment.topRight,
                  child: FlowInspectorPanel(
                    nodeId: nodeId,
                    cfgName: 'TalkCfg',
                    record: record ?? host.record,
                    metas: fieldMetas ?? metas(),
                    fieldController: host.fieldController,
                    fieldFocus: host.fieldFocus,
                    onFieldChanged: host.onFieldChanged,
                    suggestFor: host.suggestFor,
                    fieldInvalid: host.fieldInvalid,
                    fieldDirty: host.fieldDirty,
                    showAdvanced: showAdvanced,
                    onToggleAdvanced: host.toggleAdvanced,
                    onClose: () => host.closed = true,
                  ),
                ),
              ),
              ...after,
            ],
          ),
        ),
      ),
    );
  }

  Future<FlowInspectorPanelState> mount(
    WidgetTester tester, {
    String nodeId = _node,
    Map<String, dynamic>? record,
    List<FieldMeta>? metas,
    bool showAdvanced = false,
    List<Widget> before = const [],
    List<Widget> after = const [],
  }) async {
    await tester.pumpWidget(
      tree(
        nodeId: nodeId,
        record: record,
        fieldMetas: metas,
        showAdvanced: showAdvanced,
        before: before,
        after: after,
      ),
    );
    await tester.pumpAndSettle();
    return tester.state<FlowInspectorPanelState>(
      find.byType(FlowInspectorPanel),
    );
  }

  Future<void> refresh(
    WidgetTester tester, {
    String nodeId = _node,
    Map<String, dynamic>? record,
    List<FieldMeta>? metas,
    bool showAdvanced = false,
    List<Widget> before = const [],
    List<Widget> after = const [],
  }) async {
    await tester.pumpWidget(
      tree(
        nodeId: nodeId,
        record: record,
        fieldMetas: metas,
        showAdvanced: showAdvanced,
        before: before,
        after: after,
      ),
    );
    await tester.pumpAndSettle();
  }

  /// 名称回显/防抖都要让计时器走完再断言。
  Future<void> settle(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
  }

  /// 展开高级段：`showAdvanced` 只是初值（fluent.Expander 的语义），改它不会
  /// 让已挂载的段重新展开，所以按用户的方式来一次点标题。
  /// 常用段有 10 行，「高级」标题往往已滚出视口——先 ensureVisible 再点，
  /// 否则 tap 落空（hit test miss）段落不会展开。
  Future<void> openAdvanced(WidgetTester tester) async {
    await tester.ensureVisible(find.text('高级'));
    await settle(tester);
    await tester.tap(find.text('高级'));
    await settle(tester);
    await refresh(tester, showAdvanced: host.showAdvanced);
  }

  Finder rowOf(String field) => find.byKey(ValueKey('inspector-row:$field'));

  Finder badge(String prefix) => find.byWidgetPredicate((w) {
    final k = w.key;
    return k is ValueKey<String> && k.value.startsWith(prefix);
  });

  Finder summaryLine(String key) => find.byKey(ValueKey(key));

  String plainText(WidgetTester tester, Finder finder) =>
      tester.widget<RichText>(finder).text.toPlainText();

  testWidgets('单选非缺失节点：metas 里的字段逐个铺开，一个都不落', (tester) async {
    host.record
      ..['id'] = int.parse(_node)
      ..['content'] = '甲'
      ..['roleName'] = '小明'
      ..['bg'] = 7
      ..['audio'] = 11
      ..['time'] = 3
      ..['nextTalk'] = <dynamic>['1000001001']
      ..['tag'] = 0;
    await mount(tester, showAdvanced: true);

    expect(find.byType(FlowInspectorPanel), findsOneWidget);
    expect(find.text('常用'), findsOneWidget);
    expect(find.text('高级'), findsOneWidget);
    for (final meta in metas()) {
      expect(
        rowOf(meta.key),
        findsOneWidget,
        reason: '${meta.key} 是 schema 声明字段，必须出现在面板里',
      );
    }
  });

  testWidgets('主键只读、效果与规则字段走补全框，纯文本才是裸 TextBox', (tester) async {
    host.record['id'] = int.parse(_node);
    await mount(tester, showAdvanced: true);

    // id：editable=false → 永远不给可编辑框。
    expect(
      find.descendant(of: rowOf('id'), matching: find.byType(EditableText)),
      findsNothing,
    );
    expect(find.descendant(of: rowOf('id'), matching: find.text(_node)), findsOneWidget);
    // screenEffect / check（effectLike）与 bg / nextTalk（rule）必须是补全框：
    // 裸 TextBox 里一个全角逗号就能绕过校验进存档。
    for (final key in ['screenEffect', 'check', 'bg', 'nextTalk', 'audio']) {
      expect(
        find.descendant(
          of: rowOf(key),
          matching: find.byType(SuggestionTextField),
        ),
        findsOneWidget,
        reason: '$key 必须走带校验的补全框',
      );
    }
    for (final key in ['content', 'roleName', 'time', 'tag']) {
      expect(
        find.descendant(of: rowOf(key), matching: find.byType(fluent.TextBox)),
        findsOneWidget,
        reason: '$key 无规则无候选，按普通文本框处理',
      );
    }
  });

  testWidgets('schema 新增字段自动进高级段，不用改面板一行代码', (tester) async {
    // 面板契约：record 非空（已选中节点）才渲染分区，否则是「请先单选」空态
    host.record['id'] = int.parse(_node);
    await mount(tester);
    // 先在收起态：新字段不该出现在可见区。
    (state.gameSchema['TalkCfg'] as Map<String, dynamic>)['showTxt'] = 'String';
    await refresh(tester);
    expect(rowOf('showTxt'), findsNothing, reason: '高级段收起时不该建出字段');
    expect(metaOf('showTxt').inCommon, isFalse);

    await openAdvanced(tester);
    expect(rowOf('showTxt'), findsOneWidget);
    expect(host.showAdvanced, isTrue, reason: '点段标题必须把展开态回报给宿主持久化');
    expect(
      find.descendant(
        of: rowOf('showTxt'),
        matching: find.byType(fluent.TextBox),
      ),
      findsOneWidget,
    );
  });

  testWidgets('必填星号只挂 content；空着进「必填未填」，与写回失败分开列', (tester) async {
    host.record
      ..['id'] = int.parse(_node)
      ..['content'] = '甲'
      ..['roleName'] = '小明';
    await mount(tester);

    final required = metas().where((m) => m.required).toList();
    expect(
      required.map((m) => m.key),
      ['content'],
      reason: '指南未标注必填、本体数据大面积为空的字段不得挂必填星号',
    );
    // content 已填：只挂「必填已填」星号，没有「必填未填」，小结落到 OK 行。
    expect(badge('req:').evaluate().length, 1);
    expect(badge('req-missing:'), findsNothing);
    expect(summaryLine('inspector-ok'), findsOneWidget);
    expect(summaryLine('inspector-missing'), findsNothing);
    expect(summaryLine('inspector-invalid'), findsNothing);

    // content 清空 → 「必填未填 1」；同时填坏 time，两条小结各说各的。
    host.record.remove('content');
    host.invalid.add('time');
    await refresh(tester);
    expect(badge('req-missing:'), findsOneWidget);
    expect(summaryLine('inspector-missing'), findsOneWidget);
    expect(plainText(tester, summaryLine('inspector-missing')), contains('必填未填 1'));
    expect(
      plainText(tester, summaryLine('inspector-missing')),
      contains(metaOf('content').label),
    );
    expect(summaryLine('inspector-invalid'), findsOneWidget);
    expect(plainText(tester, summaryLine('inspector-invalid')), contains('写回失败 1'));
    expect(plainText(tester, summaryLine('inspector-invalid')), contains(metaOf('time').label));
  });

  testWidgets('写回失败：标出错误行、record 一字不动', (tester) async {
    host.record
      ..['id'] = int.parse(_node)
      ..['content'] = '甲'
      ..['time'] = 3;
    await mount(tester);

    await tester.tap(find.descendant(of: rowOf('time'), matching: find.byType(EditableText)));
    await settle(tester);
    await tester.enterText(
      find.descendant(of: rowOf('time'), matching: find.byType(EditableText)),
      '三秒',
    );
    await settle(tester);
    // 宿主（与 workspace 同构）解析失败只标记不写回，面板要刷一次才看得到。
    await refresh(tester);

    expect(host.invalid, contains('time'));
    expect(host.record['time'], 3, reason: '解析被拒时记录必须保持原值');
    expect(find.byKey(const ValueKey('invalid:time')), findsOneWidget);
    expect(
      plainText(tester, summaryLine('inspector-invalid')),
      contains('写回失败 1'),
    );
    expect(requested, isEmpty, reason: '按键路径上绝不发请求（整表校验一次 9.8 万行）');
  });

  testWidgets('有效输入：文本原样交给宿主 onFieldChanged，面板自己不写记录', (tester) async {
    host.record['id'] = int.parse(_node);
    await mount(tester);

    await tester.tap(find.descendant(of: rowOf('content'), matching: find.byType(EditableText)));
    await settle(tester);
    await tester.enterText(
      find.descendant(of: rowOf('content'), matching: find.byType(EditableText)),
      '下课见',
    );
    await settle(tester);

    expect(host.changed, contains('content=下课见'));
    expect(host.record['content'], '下课见', reason: '写回只能由宿主完成');
    expect(host.ctls[host.key(_node, 'content')]!.text, '下课见');
    // 脏标记由宿主在写回回调里 setState 带出来，这里等价地重挂一次。
    await refresh(tester);
    expect(find.byKey(const ValueKey('dirty:content')), findsOneWidget);
    expect(requested, isEmpty);
  });

  testWidgets('内联卡片同键：共享控制器双向同步，共享焦点被检出并提示', (tester) async {
    host.record
      ..['id'] = int.parse(_node)
      ..['content'] = '甲';
    // 先建好控制器与焦点节点，再让「内联卡片」在面板之外把它们挂上树。
    final ctl = host.fieldController(_node, 'content')!;
    final inlineNode = host.fieldFocus(_node, 'roleName')!;

    await mount(
      tester,
      before: [
        // 卡片的两处：content 只共享控制器（安全），roleName 连焦点都共享。
        SizedBox(
          width: 160,
          child: Column(
            children: [
              fluent.TextBox(controller: ctl),
              SuggestionTextField(controller: ctl, focusNode: inlineNode),
            ],
          ),
        ),
      ],
    );
    final st = tester.state<FlowInspectorPanelState>(
      find.byType(FlowInspectorPanel),
    );

    // 一个控制器同时被两处使用是安全的（ValueListenable 多监听），
    // 两处渲染的都是同一份文本。
    final attached = tester
        .widgetList<EditableText>(find.byType(EditableText))
        .where((e) => identical(e.controller, ctl))
        .toList();
    expect(attached.length, greaterThanOrEqualTo(2), reason: '卡片与面板共用同一控制器');
    expect(
      attached.every((e) => e.controller.text == '甲'),
      isTrue,
      reason: '共用控制器就是双向同步的全部机制，不该再有第二份文本',
    );

    // 同一 FocusNode 被面板外部挂上：FocusNode.attach 会让两处互相抢归属，
    // 分流是宿主的决定，面板只检出、提示，不自作主张另造一套键。
    expect(st.focusConflicts, contains('$_node|roleName'));
    expect(summaryLine('inspector-focus-conflict'), findsOneWidget);
    expect(
      plainText(tester, summaryLine('inspector-focus-conflict')),
      contains('焦点冲突 1'),
    );
    // 冲突不让字段失去编辑能力。
    expect(
      find.descendant(of: rowOf('roleName'), matching: find.byType(EditableText)),
      findsOneWidget,
    );
  });

  testWidgets('共享 FocusNode 的 context 指向已失效 element：面板重建不再崩成 ErrorWidget', (
    tester,
  ) async {
    // 回归：卡片字段在面板字段**之后** initState（内联展开 → attach 抢走
    // context）再被移除时，FocusNode.context 残留已失效的卡片 element；
    // 面板 build 期的冲突检测对它做祖先查找就抛
    // 「Looking up a deactivated widget's ancestor is unsafe」，整个面板被
    // ErrorWidget（红底黄字）顶掉。
    host.record['id'] = int.parse(_node);
    final inlineNode = host.fieldFocus(_node, 'roleName')!;
    final ctl = host.fieldController(_node, 'content')!;
    // 1) 先挂面板：面板字段首次 attach，context 归面板。
    await mount(tester);
    // 2) 再挂内联卡片：卡片字段 initState 重新 attach，context 归卡片，
    //    冲突被检出并提示。
    await refresh(tester, before: [
      SizedBox(
        width: 160,
        child: SuggestionTextField(controller: ctl, focusNode: inlineNode),
      ),
    ]);
    expect(summaryLine('inspector-focus-conflict'), findsOneWidget);
    // 3) 移除卡片（收起/卸载的真实路径）。Row 从尾部同步更新：面板先重建
    //    （卡片 element 仍 active，检出冲突），卡片随后 deactivated，帧末 defunct。
    await refresh(tester);
    // 4) 面板再重建：此刻 context 已失效——旧实现此刻就抛。
    await refresh(tester);
    expect(find.byType(ErrorWidget), findsNothing);
    expect(find.byType(FlowInspectorPanel), findsOneWidget);
    // 卡片没了 = 面板独占焦点节点，冲突提示也随之消失。
    expect(summaryLine('inspector-focus-conflict'), findsNothing);
  });

  testWidgets('Tab 在最后一个可见字段回环到第一个，焦点不出面板', (tester) async {
    host.record['id'] = int.parse(_node);
    final outside = FocusNode(debugLabel: 'outsidePanel');
    await mount(
      tester,
      after: [
        // 面板之后还有一个输入框：按系统树序 nextFocus 一定会落在这里。
        SizedBox(
          width: 160,
          child: Builder(
            builder: (context) => fluent.TextBox(focusNode: outside),
          ),
        ),
      ],
    );
    final st = tester.state<FlowInspectorPanelState>(
      find.byType(FlowInspectorPanel),
    );
    final order = st.focusOrder;
    expect(order.length, metas().where((m) => m.inCommon).length);

    order.last.requestFocus();
    await tester.pump();
    expect(FocusManager.instance.primaryFocus, same(order.last));

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(
      FocusManager.instance.primaryFocus,
      same(order.first),
      reason: '末项 Tab 必须回环到首项',
    );
    expect(
      FocusManager.instance.primaryFocus,
      isNot(same(outside)),
      reason: '任何时候都不许落到面板外的输入框上',
    );

    // 纯文本框（无补全那层按键接管）也得留在环里。
    order.first.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(FocusManager.instance.primaryFocus, same(order[1]));
    outside.dispose();
  });

  testWidgets('展开高级段后 Tab 环跟着变长，折叠段字段一律不在环里', (tester) async {
    host.record['id'] = int.parse(_node);
    final collapsed = await mount(tester);
    final commonCount = collapsed.focusOrder.length;

    await openAdvanced(tester);
    final total = collapsed.focusOrder.length;
    expect(
      total,
      greaterThan(commonCount),
      reason: '高级段展开后其字段必须进环，否则键盘改不到它们',
    );
    // id 只读、不参与跳焦；折叠/展开两态的差值就是高级段里的可编辑字段数。
    final advancedEditable = metas()
        .where((m) => !m.inCommon && m.editable)
        .length;
    expect(total - commonCount, advancedEditable);
    expect(collapsed.focusOrder.every((n) => n.canRequestFocus), isTrue);
  });

  testWidgets('规则字段回显解析到的名称（123 → 教室 / 未找到）', (tester) async {
    host.record
      ..['id'] = int.parse(_node)
      ..['bg'] = 7
      ..['audio'] = 999;
    await mount(tester);
    await settle(tester);

    expect(find.text('7 → 教室'), findsOneWidget);
    expect(find.text('999 未找到'), findsOneWidget);
    expect(requested, isEmpty, reason: '名称回显只用内存字典，不为补全再发请求');
  });

  testWidgets('无选中 / missing 节点：只出空态，不铺无主输入框', (tester) async {
    host.record['id'] = int.parse(_node);
    await mount(tester, nodeId: '');
    expect(
      find.descendant(
        of: find.byType(FlowInspectorPanel),
        matching: find.byType(EditableText),
      ),
      findsNothing,
    );
    expect(find.textContaining('请先单选一个节点'), findsOneWidget);
    expect(summaryLine('inspector-summary'), findsNothing);

    // 空记录 = missing 节点的舞台记录，同样不展开编辑器。
    await mount(tester, record: <String, dynamic>{});
    expect(
      find.descendant(
        of: find.byType(FlowInspectorPanel),
        matching: find.byType(EditableText),
      ),
      findsNothing,
    );

    // 空 metas（表未在 schema 里）走另一条空态文案。
    await mount(tester, metas: const []);
    expect(find.textContaining('没有可编辑的字段'), findsOneWidget);
  });

  testWidgets('关闭按钮只回调宿主，面板自己不改可见性', (tester) async {
    host.record['id'] = int.parse(_node);
    await mount(tester);
    expect(host.closed, isFalse);
    await tester.tap(find.byIcon(Icons.close));
    await settle(tester);
    expect(host.closed, isTrue);
    expect(find.byType(FlowInspectorPanel), findsOneWidget);
  });
}

/// 宿主桩：与 story_flow_workspace 的 Inspector 接线同构（控制器/焦点按
/// `事件|节点|字段` 同键缓存，写回走类型解码、失败只标记不动记录）。
class _Host {
  _Host(this.state);

  final AppState state;
  final Map<String, TextEditingController> ctls = <String, TextEditingController>{};
  final Map<String, FocusNode> focuses = <String, FocusNode>{};
  final Map<String, dynamic> record = <String, dynamic>{};
  final List<String> changed = <String>[];
  final Set<String> invalid = <String>{};
  final Set<String> dirty = <String>{};
  bool showAdvanced = false;
  bool closed = false;

  String key(String nodeId, String field) => '$_evt|$nodeId|$field';

  String? typeOf(String field) =>
      cfgTypeOf(state.gameSchema, 'TalkCfg', field);

  TextEditingController? fieldController(String nodeId, String field) {
    final type = typeOf(field);
    if (type == null) return null;
    return ctls.putIfAbsent(
      key(nodeId, field),
      () => TextEditingController(text: encodeFieldValue(record, field, type)),
    );
  }

  FocusNode? fieldFocus(String nodeId, String field) {
    if (typeOf(field) == null) return null;
    return focuses.putIfAbsent(key(nodeId, field), FocusNode.new);
  }

  void onFieldChanged(String nodeId, String field, String text) {
    changed.add('$field=$text');
    final r = decodeFieldValue(text, typeOf(field));
    if (!r.ok) {
      invalid.add(field);
      return;
    }
    invalid.remove(field);
    if (r.cleared) {
      record.remove(field);
      dirty.remove(field);
    } else {
      record[field] = r.value;
      dirty.add(field);
    }
  }

  bool fieldInvalid(String nodeId, String field) => invalid.contains(field);

  bool fieldDirty(String nodeId, String field) => dirty.contains(field);

  SuggestionSource? suggestFor(String cfg, FieldMeta meta) =>
      sourceForField(cfg, meta, deps);

  FlowSuggestDeps get deps => FlowSuggestDeps(
    state: state,
    stageTalks: () => const <Map<String, dynamic>>[],
    stageOptions: () => const <Map<String, dynamic>>[],
    offStageIds: (cfg) async => const <(String, String)>[],
  );

  void toggleAdvanced() => showAdvanced = !showAdvanced;

  void dispose() {
    for (final c in ctls.values) {
      c.dispose();
    }
    for (final f in focuses.values) {
      f.dispose();
    }
  }
}
