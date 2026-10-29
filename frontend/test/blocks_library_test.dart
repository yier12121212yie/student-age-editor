// 条件 / 效果积木库（导演布局「积木库」专属界面 + 无代码模式入口）冒烟测试：
// 目录分类、点击入库生成代码、分类筛选、窄窗不溢出、导演主页卡片进入，
// 以及无代码字段的「打开积木库」入口。
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_age_editor/core/api_client.dart';
import 'package:student_age_editor/core/models.dart';
import 'package:student_age_editor/core/plugin_state.dart';
import 'package:student_age_editor/core/ui_mode.dart';
import 'package:student_age_editor/features/blocks/blocks_workbench.dart';
import 'package:student_age_editor/features/nocode/nocode_effect_field.dart';
import 'package:student_age_editor/features/shell/director_shell.dart';
import 'package:student_age_editor/features/shell/shell_state.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ApiClient.instance.client = MockClient((req) async {
      final path = req.url.path;
      if (path == '/api/effect_suggest') {
        final mode = req.url.queryParameters['mode'] ?? 'effect';
        final items = mode == 'condition'
            ? [
                {
                  'code': '[1, 97, 1]',
                  'desc': '已经文理分班',
                  'raw_code': '[1, 97, 1]',
                  'slots': <dynamic>[],
                },
                {
                  'code': '[7, 0, 0, 1]',
                  'desc': '和某人是朋友',
                  'raw_code': '[7, 0, 0, 1]',
                  'slots': <dynamic>[],
                },
              ]
            : [
                {
                  'code': '[1, 1, @ATTR@, V]',
                  'desc': '属性 @ATTR@ 增加 V',
                  'raw_code': '[1, 1, @ATTR@, V]',
                  'slots': [
                    {
                      'kind': 'dict',
                      'name': 'ATTR',
                      'dict': 'ATTR',
                      'label': '属性',
                      'count': 1,
                    },
                    {'kind': 'number', 'name': 'V', 'count': 1},
                  ],
                },
              ];
        return http.Response(
          jsonEncode({'items': items, 'mode': mode, 'q': ''}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (path == '/api/effect/parse') {
        final body = jsonDecode(req.body) as Map;
        final text = body['text']?.toString() ?? '';
        return http.Response(
          jsonEncode({
            'ok': true,
            'rows': [
              {
                'primary': 1,
                'secondary': 97,
                'negate': false,
                'display': text,
                'template': {'code': text, 'desc': '测试积木'},
                'slots': <dynamic>[],
                'nested': <dynamic>[],
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (path.startsWith('/api/cfg/')) {
        final cfg = path.substring('/api/cfg/'.length);
        Map<String, dynamic> data;
        switch (cfg) {
          case 'ConditionTypeCfg':
            data = {
              '1': {'id': 1, 'name': '年龄限制'},
              '7': {'id': 7, 'name': '社交'},
            };
            break;
          case 'EffectTypeCfg':
            data = {
              '1': {'id': 1, 'name': '改变属性'},
            };
            break;
          default:
            data = {};
        }
        return http.Response(
          jsonEncode({'data': data, 'exists': true, 'mtime_ns': 1}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (path == '/api/state') {
        return http.Response(
          jsonEncode({'mod_name': '测试模组', 'ok': true}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response(
        jsonEncode({'data': {}}),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
  });

  tearDown(() {
    ApiClient.instance.client = http.Client();
  });

  Future<void> pumpWorkbench(WidgetTester tester, Size size,
      {AppState? state}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      fluent.FluentApp(
        debugShowCheckedModeBanner: false,
        home: BlocksWorkbench(state: state ?? (AppState()..modName = '测试模组')),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  /// A2/A3 用例用：只换掉目录/解析回包，其余（cfg 表、状态）返回空表。
  void mockLibrary({
    required List<Map<String, dynamic>> effectItems,
    required List<Map<String, dynamic>> Function(String text) parseRows,
  }) {
    ApiClient.instance.client = MockClient((req) async {
      final path = req.url.path;
      if (path == '/api/effect_suggest') {
        final mode = req.url.queryParameters['mode'] ?? 'effect';
        return _respJson({
          'items': mode == 'effect' ? effectItems : <dynamic>[],
          'mode': mode,
          'q': '',
        });
      }
      if (path == '/api/effect/parse') {
        final text =
            (jsonDecode(req.body) as Map)['text']?.toString() ?? '';
        return _respJson({
          'ok': true,
          'status': 'ok',
          'translations': <dynamic>[],
          'rows': parseRows(text),
        });
      }
      if (path.startsWith('/api/cfg/')) {
        return _respJson({'data': const {}, 'exists': false, 'mtime_ns': 0});
      }
      return _respJson({'ok': true, 'data': const {}});
    });
  }

  Finder inDialog(String text) =>
      find.descendant(of: find.byType(AlertDialog), matching: find.text(text));

  Future<void> fillSlot(WidgetTester tester, String name, String value) async {
    await tester.enterText(
        find.descendant(
            of: find.byKey(ValueKey('slot-$name')),
            matching: find.byType(EditableText)),
        value);
    await tester.pumpAndSettle();
  }

  testWidgets('积木库工作台：目录 + 构建清单渲染', (tester) async {
    await pumpWorkbench(tester, const Size(1400, 900));

    expect(tester.takeException(), isNull, reason: '积木库渲染不应异常');
    expect(find.text('积木目录'), findsOneWidget);
    expect(find.text('构建清单'), findsOneWidget);
    // 默认效果模式：候选来自 mock，目录卡片只显示人话标题（无占位符/原始代码）。
    expect(find.text('属性 增加 数值'), findsWidgets);
  });

  testWidgets('积木库工作台：切换条件模式并按分类入库生成代码', (tester) async {
    await pumpWorkbench(tester, const Size(1400, 900));

    // 切到条件模式。
    await tester.tap(find.text('条件'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // 分类来自 ConditionTypeCfg。
    expect(find.text('年龄限制'), findsWidgets);
    expect(find.text('社交'), findsWidgets);

    // 无参候选：点击直接入库。
    await tester.tap(find.text('已经文理分班'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('已添加 1 条'), findsOneWidget);
    expect(find.text('[1, 97, 1]'), findsWidgets);

    // 按分类筛选：只看社交。
    await tester.tap(find.text('社交').first);
    await tester.pump();
    expect(find.text('和某人是朋友'), findsOneWidget);

    await tester.tap(find.text('和某人是朋友'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('已添加 2 条'), findsOneWidget);
    expect(find.textContaining('[7, 0, 0, 1]'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('积木库工作台：窄窗（隐藏说明栏）无像素溢出', (tester) async {
    await pumpWorkbench(tester, const Size(820, 620));
    expect(tester.takeException(), isNull, reason: '窄窗不应溢出');
  });

  testWidgets('导演工程栏「积木库」进入积木库工作台', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(
      fluent.FluentApp(
        debugShowCheckedModeBanner: false,
        home: DirectorShell(
          state: AppState()..modName = '测试模组',
          shell: ShellState()..setAiOpen(false),
          pluginState: PluginState(),
          uiMode: UiMode.director,
          onUiModeChanged: (_) {},
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    await tester.ensureVisible(find.text('积木库').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('积木库').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('积木目录'), findsOneWidget);
    expect(find.text('构建清单'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('无代码字段：显示「打开积木库」入口', (tester) async {
    await tester.pumpWidget(
      fluent.FluentApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          body: SingleChildScrollView(
            child: NoCodeEffectField(
              value: [
                [1, 1, 3, 5],
              ],
              type: '2D Array',
              cfg: 'TalkCfg',
              fieldKey: 'effect',
              mode: 'effect',
              onChanged: (_) {},
              onDisableNoCode: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('打开积木库'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('A2：目录按概念折叠，行内点算符后用该变体代码入库', (tester) async {
    // 无槽 family：每条变体的 code 本身就是成品代码（与源表「已收录规则」一致）。
    final ageOps = <Map<String, dynamic>>[
      {'op': '≥', 'code': '[1, 1, 5]', 'value_index': 2, 'upper_index': null, 'slots': <dynamic>[]},
      {'op': '≤', 'code': '[1, 2, 5]', 'value_index': 2, 'upper_index': null, 'slots': <dynamic>[]},
      {'op': '范围', 'code': '[1, 3, 3, 5]', 'value_index': 2, 'upper_index': 3, 'slots': <dynamic>[]},
    ];
    mockLibrary(
      effectItems: [
        for (final o in ageOps)
          _item(
            code: o['code'] as String,
            desc: '年龄 ${o['op']} 5',
            family: '1|年龄',
            familyLabel: '年龄',
            op: o['op'] as String,
            ops: ageOps,
          ),
      ],
      parseRows: (text) => [_parseRow(code: text, desc: '测试积木')],
    );
    await pumpWorkbench(tester, const Size(1400, 900));

    // 三条同族候选折成一条「年龄」；算符收进行内按钮。
    expect(find.text('年龄'), findsOneWidget);
    expect(find.text('1 项 · 1/1'), findsOneWidget);
    for (final op in const ['≥', '≤', '范围']) {
      expect(find.byKey(ValueKey('catop-1|年龄-$op')), findsOneWidget,
          reason: '算符 $op 是行内按钮');
    }

    await tester.tap(find.byKey(const ValueKey('catop-1|年龄-≤')));
    await tester.pump();
    await tester.tap(find.text('年龄'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('已添加 1 条'), findsOneWidget);
    expect(find.text('[1, 2, 5]'), findsWidgets,
        reason: '入库用的是选中变体的代码');
    expect(tester.takeException(), isNull);
  });

  testWidgets('A2：构建清单行内切算符改写代码并保留已填值', (tester) async {
    final ageOps = _ageOps();
    mockLibrary(
      effectItems: [
        for (final o in ageOps)
          _item(
            code: o['code'] as String,
            desc: '年龄 ${o['op']} V',
            family: '1|年龄',
            familyLabel: '年龄',
            op: o['op'] as String,
            ops: ageOps,
            slots: o['slots'] as List<Map<String, dynamic>>,
          ),
      ],
      parseRows: (text) => [
        switch (text) {
          '[1, 1, 5]' => _parseRow(
              code: '[1, 1, V]',
              desc: '年龄 >= V',
              slots: [_numSlotMap('V', '年龄', '5')],
              op: '≥',
              ops: ageOps),
          _ => _parseRow(code: text, desc: '测试积木'),
        }
      ],
    );
    await pumpWorkbench(tester, const Size(1400, 900));

    await tester.tap(find.text('年龄'));
    await tester.pumpAndSettle();
    await fillSlot(tester, 'V', '5');
    await tester.tap(inDialog('确定'));
    await tester.pumpAndSettle();
    expect(find.text('[1, 1, 5]'), findsWidgets);

    // 清单里点「≤」：同一行代码改写、V=5 不丢。
    await tester.tap(find.byKey(const ValueKey('blop-0-≤')));
    await tester.pump();
    expect(find.text('[1, 2, 5]'), findsWidgets, reason: '切算符保留已填值');
    expect(tester.takeException(), isNull);
  });

  testWidgets('A2：范围算符补填上下限生成 [1, 3, X, Y]；记忆值跨次带出', (tester) async {
    final ageOps = _ageOps();
    mockLibrary(
      effectItems: [
        for (final o in ageOps)
          _item(
            code: o['code'] as String,
            desc: '年龄 ${o['op']} V',
            family: '1|年龄',
            familyLabel: '年龄',
            op: o['op'] as String,
            ops: ageOps,
            slots: o['slots'] as List<Map<String, dynamic>>,
          ),
      ],
      parseRows: (text) => [_parseRow(code: text, desc: '测试积木')],
    );
    await pumpWorkbench(tester, const Size(1400, 900));

    // 第一次：默认 ≥，填 V=5。
    await tester.tap(find.text('年龄'));
    await tester.pumpAndSettle();
    await fillSlot(tester, 'V', '5');
    await tester.tap(inDialog('确定'));
    await tester.pumpAndSettle();
    expect(find.text('[1, 1, 5]'), findsWidgets);

    // 再入场（仍 ≥）：目录记住的 V=5 自动带出，不必重填。
    await tester.tap(find.text('年龄'));
    await tester.pumpAndSettle();
    expect(find.text('代码：[1, 1, 5]'), findsOneWidget, reason: '记忆值自动带出');
    await tester.tap(inDialog('确定'));
    await tester.pumpAndSettle();
    expect(find.text('已添加 2 条'), findsOneWidget);

    // 切「范围」：补 X/Y 后生成 [1, 3, 3, 5]。
    await tester.tap(find.byKey(const ValueKey('catop-1|年龄-范围')));
    await tester.pump();
    await tester.tap(find.text('年龄'));
    await tester.pumpAndSettle();
    await fillSlot(tester, 'X', '3');
    await fillSlot(tester, 'Y', '5');
    await tester.tap(inDialog('确定'));
    await tester.pumpAndSettle();
    expect(find.text('已添加 3 条'), findsOneWidget);
    expect(find.text('[1, 3, 3, 5]'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('A3：清单摘要是成句人话（引用名 + 「，且」连接）', (tester) async {
    mockLibrary(
      effectItems: [
        _item(
          code: '[1, 1, @ATTR@, V]',
          desc: '属性 @ATTR@ 增加 V',
          slots: [_dictSlotMap('ATTR', 'ATTR', '属性', ''), _numSlotMap('V', '数值', '')],
        ),
        _item(
          code: '[7, 1, @ITEM@, V]',
          desc: '物品 @ITEM@ 增加 V',
          slots: [_dictSlotMap('ITEM', 'ITEM', '物品', ''), _numSlotMap('V', '数量', '')],
        ),
      ],
      parseRows: (text) => [
        switch (text) {
          '[1, 1, 3, 5]' => _parseRow(
              code: '[1, 1, @ATTR@, V]',
              desc: '属性 @ATTR@ 增加 V',
              slots: [_dictSlotMap('ATTR', 'ATTR', '属性', '3'), _numSlotMap('V', '数值', '5')]),
          '[7, 1, 101, 50]' => _parseRow(
              code: '[7, 1, @ITEM@, V]',
              desc: '物品 @ITEM@ 增加 V',
              slots: [_dictSlotMap('ITEM', 'ITEM', '物品', '101'), _numSlotMap('V', '数量', '50')]),
          _ => _parseRow(code: text, desc: '测试积木'),
        }
      ],
    );
    final state = AppState()..modName = '测试模组';
    state.gameDicts = {
      'attrs': {'3': '魅力'},
      'items': {'101': '苹果'},
    };
    await pumpWorkbench(tester, const Size(1400, 900), state: state);

    await tester.tap(find.text('属性 增加 数值'));
    await tester.pumpAndSettle();
    await fillSlot(tester, 'V', '5');
    await tester.tap(inDialog('确定'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('物品 增加 数量'));
    await tester.pumpAndSettle();
    await fillSlot(tester, 'V', '50');
    await tester.tap(inDialog('确定'));
    await tester.pumpAndSettle();

    expect(find.text('已添加 2 条'), findsOneWidget);
    expect(
        find.text('属性 魅力 增加 5，且 物品 苹果 增加 50'), findsOneWidget,
        reason: '摘要含引用名（魅力/苹果）且用「，且」连接');
    expect(tester.takeException(), isNull);
  });
}

http.Response _respJson(Map<String, dynamic> m) => http.Response(
      jsonEncode(m),
      200,
      headers: {'content-type': 'application/json'},
    );

Map<String, dynamic> _dictSlotMap(String name, String dict, String label, String value) =>
    {'name': name, 'kind': 'dict', 'dict': dict, 'label': label, 'value': value};

Map<String, dynamic> _numSlotMap(String name, String label, String value) =>
    {'name': name, 'kind': 'number', 'dict': null, 'label': label, 'value': value};

/// 目录候选（带 A1 的 family/op/ops 元数据）。
Map<String, dynamic> _item({
  required String code,
  required String desc,
  String family = '',
  String familyLabel = '',
  String op = '',
  List<Map<String, dynamic>> slots = const [],
  List<Map<String, dynamic>> ops = const [],
}) =>
    {
      'code': code,
      'desc': desc,
      'raw_code': code,
      'slots': slots,
      'family': family,
      'family_label': familyLabel,
      'op': op,
      'ops': ops,
    };

/// parse 回包行：`display` 与模板同码；槽值写进 `slots[i].value`。
Map<String, dynamic> _parseRow({
  required String code,
  required String desc,
  List<Map<String, dynamic>> slots = const [],
  String op = '',
  List<Map<String, dynamic>> ops = const [],
}) =>
    {
      'primary': 1,
      'secondary': 1,
      'negate': false,
      'display': code,
      'template': {'code': code, 'desc': desc, 'op': op, 'ops': ops},
      'slots': slots,
      'nested': <dynamic>[],
    };

/// 年龄概念的三个算符变体（A1 契约：`op` + `code` + `value_index` + `slots`）。
List<Map<String, dynamic>> _ageOps() => [
      {
        'op': '≥',
        'code': '[1, 1, V]',
        'value_index': 2,
        'upper_index': null,
        'slots': [_numSlotMap('V', '年龄', '')],
      },
      {
        'op': '≤',
        'code': '[1, 2, V]',
        'value_index': 2,
        'upper_index': null,
        'slots': [_numSlotMap('V', '年龄', '')],
      },
      {
        'op': '范围',
        'code': '[1, 3, X, Y]',
        'value_index': 2,
        'upper_index': 3,
        'slots': [_numSlotMap('X', '下限', ''), _numSlotMap('Y', '上限', '')],
      },
    ];
