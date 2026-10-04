// 「开启无代码模式后，不再有任何输入代码的地方」的守护测试。
//
// 三条断言链：
//   1) NoCodeEffectField 内嵌形态：没有原始文本通道（raw-toggle/raw-input）——
//      代码字段上唯一的整串编辑入口被摘掉，只剩积木行；
//   2) 解析失败时只读展示原文、绝不写回（数据安全边界）；
//   3) 经典 schema 编辑器端到端：开启态用 NoCodeEffectField 顶掉 EffectHintField，
//      并给出「选人物 / 选背景」这类纯选择入口；关闭态行为与旧版一致。
import 'dart:convert';

import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:student_age_editor/core/api_client.dart';
import 'package:student_age_editor/core/models.dart';
import 'package:student_age_editor/features/editor/effect_hint_field.dart';
import 'package:student_age_editor/features/editor/field_meta.dart';
import 'package:student_age_editor/features/editor/schema_editor_view.dart';
import 'package:student_age_editor/features/nocode/effect_block_editor.dart';
import 'package:student_age_editor/features/nocode/no_code_ref_field.dart';
import 'package:student_age_editor/features/nocode/nocode_effect_field.dart';

http.Response _json(Object body, [int code = 200]) => http.Response(
      jsonEncode(body),
      code,
      headers: {'content-type': 'application/json'},
    );

/// 一条解析成功的积木行：属性 3 +5 → [1, 1, 3, 5]。
Map<String, dynamic> _rowA() => {
      'line': 1,
      'negate': false,
      'primary': 1,
      'secondary': 1,
      'args': const [],
      'display': '[1, 1, 3, 5]',
      'template': {'code': '[1, 1, @ATTR@, V]', 'desc': '属性 @ATTR@ 增加 V'},
      'slots': [
        {
          'name': 'ATTR',
          'kind': 'dict',
          'dict': 'ATTR',
          'label': '属性',
          'value': '3',
        },
        {'name': 'V', 'kind': 'number', 'dict': null, 'label': '数值', 'value': '5'},
      ],
      'nested': null,
      'error': null,
    };

/// 打桩 /api/effect/parse：含 BAD 的文本解析失败（与后端契约一致）。
void _mockParse() {
  ApiClient.instance.client = MockClient((req) async {
    switch (req.url.path) {
      case '/api/effect/parse':
        final t = (jsonDecode(req.body)['text'] ?? '').toString();
        if (t.contains('BAD')) {
          return _json({
            'ok': false,
            'status': 'json_error',
            'message': '坏文本',
            'translations': [],
            'rows': [],
          });
        }
        return _json({
          'ok': true,
          'status': 'ok',
          'translations': [],
          'rows': [_rowA()],
        });
      case '/api/effect_suggest':
        return _json({
          'items': [
            {'code': '[9, 9]', 'desc': '目录行', 'raw_code': '[9, 9]', 'slots': []},
          ]
        });
      case '/api/cfg/TalkCfg':
        return _json({
          'data': {
            '1': {
              'id': 1,
              'content': '你来了',
              'effect': [
                [1, 1, 3, 5]
              ],
              'roleIds': [101],
              'bg': 10,
            },
          },
          'exists': true,
        });
      default:
        return _json({'ok': true});
    }
  });
}

/// 挂一个内嵌积木字段（无代码模式开启时的代码字段形态）。
Future<int> _mountField(WidgetTester t, {required String text}) async {
  var writes = 0;
  t.view.physicalSize = const Size(1200, 1000);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
  await t.pumpWidget(fluent.FluentApp(
    debugShowCheckedModeBanner: false,
    home: Scaffold(
      body: SingleChildScrollView(
        child: SizedBox(
          width: 640,
          child: NoCodeEffectField(
            value: text,
            type: '2D Array',
            cfg: 'TalkCfg',
            fieldKey: 'effect',
            gameDicts: const {},
            onChanged: (_) => writes++,
            onDisableNoCode: () {},
          ),
        ),
      ),
    ),
  ));
  await t.pump();
  await t.pump(const Duration(milliseconds: 400));
  await t.pumpAndSettle();
  return writes;
}

Future<void> _mountEditor(WidgetTester t, AppState state, String cfg) async {
  SharedPreferences.setMockInitialValues({});
  t.view.physicalSize = const Size(1400, 1000);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
  await t.pumpWidget(fluent.FluentApp(
    debugShowCheckedModeBanner: false,
    home: Scaffold(body: SchemaEditorView(state: state, cfgName: cfg, classic: true)),
  ));
  await t.pump();
  await t.pump(const Duration(milliseconds: 400));
  await t.pump(const Duration(milliseconds: 400));
}

AppState _state(bool noCode) {
  final s = AppState()
    ..gameSchema = {
      'TalkCfg': {
        'id': 'Number',
        'content': 'String',
        'effect': '2D Array',
        'roleIds': '1D Array',
        'bg': 'Number',
      },
    }
    ..keyMaps = {}
    ..gameDicts = {
      'roles': {'101': '林晓'},
      'bgs': {'10': '教室'},
    };
  s.setNoCodeMode(noCode);
  return s;
}

void main() {
  group('内嵌积木字段：零代码输入通道', () {
    testWidgets('解析成功：无原始文本通道、无对话框按钮，只有积木行', (t) async {
      _mockParse();
      await _mountField(t, text: '[[1,1,3,5]]');
      expect(find.byKey(const ValueKey('add-row')), findsOneWidget);
      // 唯一的整串编辑入口必须不存在：这就是「零代码输入」的落点。
      expect(find.byKey(const ValueKey('raw-toggle')), findsNothing);
      expect(find.byKey(const ValueKey('raw-input')), findsNothing);
      expect(find.text('原始文本'), findsNothing);
      expect(find.text('应用解析'), findsNothing);
      expect(find.text('取消'), findsNothing);
      expect(find.text('确定'), findsNothing);
      expect(t.takeException(), isNull);
    });

    testWidgets('逃生口按钮存在（关闭无代码模式以手动编辑）', (t) async {
      _mockParse();
      await _mountField(t, text: '[[1,1,3,5]]');
      expect(find.text('关闭无代码模式以手动编辑'), findsOneWidget);
    });

    testWidgets('解析失败：只读展示原文、不给加行按钮、绝不写回', (t) async {
      _mockParse();
      final writes = await _mountField(t, text: 'BAD[[1,1,3,5]]');
      expect(find.byType(SelectableText), findsOneWidget);
      expect(find.textContaining('如需手改'), findsOneWidget);
      expect(find.byKey(const ValueKey('add-row')), findsNothing);
      expect(find.byKey(const ValueKey('raw-toggle')), findsNothing);
      expect(find.byKey(const ValueKey('raw-input')), findsNothing);
      expect(writes, 0, reason: '只读态不得触发任何写回');
      expect(t.takeException(), isNull);
    });
  });

  group('EffectBlockEditor：对话框形态保留原始文本通道（回归）', () {
    testWidgets('embedded=false 仍有 raw-toggle', (t) async {
      _mockParse();
      t.view.physicalSize = const Size(1200, 1000);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);
      await t.pumpWidget(fluent.FluentApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          body: SizedBox(
            width: 700,
            height: 700,
            child: EffectBlockEditor(
              initialText: '[[1,1,3,5]]',
              mode: 'effect',
              gameDicts: const {},
              onResult: (_) {},
            ),
          ),
        ),
      ));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('raw-toggle')), findsOneWidget);
    });
  });

  group('经典 schema 编辑器端到端', () {
    testWidgets('开启态：效果字段换成内嵌积木，引用字段只给选择入口', (t) async {
      _mockParse();
      await _mountEditor(t, _state(true), 'TalkCfg');
      expect(find.byType(NoCodeEffectField), findsWidgets);
      expect(find.byType(EffectHintField), findsNothing);
      expect(find.byKey(const ValueKey('raw-toggle')), findsNothing);
      expect(find.byKey(const ValueKey('raw-input')), findsNothing);
      expect(find.text('原始文本'), findsNothing);
      // 引用字段的纯选择入口（没有伴随文本框）。
      expect(find.text('选人物'), findsWidgets);
      // TalkCfg.bg 自带「选背景图」（缩略图 + 单一入口），不再并发通用实体
      // 选择按钮，避免同一字段出现两个入口。
      expect(find.text('选背景'), findsNothing);
      expect(find.text('选背景图'), findsWidgets);
      expect(t.takeException(), isNull);
    });

    testWidgets('关闭态：行为与旧版一致（补全框 + 无内嵌积木）', (t) async {
      _mockParse();
      await _mountEditor(t, _state(false), 'TalkCfg');
      expect(find.byType(NoCodeEffectField), findsNothing);
      expect(find.byType(EffectHintField), findsWidgets);
      expect(find.text('选背景'), findsNothing);
      expect(t.takeException(), isNull);
    });
  });

  group('NoCodeRefField：引用字段只选不敲', () {
    testWidgets('渲染只读现值 + 选择按钮，绝不出现文本输入框', (t) async {
      var picked = 0;
      await t.pumpWidget(fluent.FluentApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          body: SizedBox(
            width: 420,
            child: NoCodeRefField(
              value: '101, 102',
              pickLabel: '选人物…',
              onPick: () async => picked++,
              onDisableNoCode: () {},
            ),
          ),
        ),
      ));
      await t.pump();
      expect(find.byType(fluent.TextBox), findsNothing);
      expect(find.byType(TextField), findsNothing);
      expect(find.text('101, 102'), findsOneWidget);
      await t.tap(find.text('选人物…'));
      await t.pumpAndSettle();
      expect(picked, 1);
      expect(t.takeException(), isNull);
    });

    testWidgets('nameOf：现值回显「ID · 名称」，查不到回退裸 ID', (t) async {
      await t.pumpWidget(fluent.FluentApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          body: SizedBox(
            width: 420,
            child: NoCodeRefField(
              value: '109, 200',
              pickLabel: '选背景…',
              nameOf: (id) => id == '109' ? '雨天教室' : null,
              onPick: () async {},
              onDisableNoCode: () {},
            ),
          ),
        ),
      ));
      await t.pump();
      expect(find.text('109 · 雨天教室、200'), findsOneWidget);
      expect(t.takeException(), isNull);
    });

    testWidgets('无候选通道：只读提示 + 逃生口，仍无文本输入框', (t) async {
      await t.pumpWidget(fluent.FluentApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          body: SizedBox(
            width: 420,
            child: NoCodeRefField(
              value: '',
              pickLabel: '选择…',
              onDisableNoCode: () {},
            ),
          ),
        ),
      ));
      await t.pump();
      expect(find.byType(fluent.TextBox), findsNothing);
      expect(find.byType(TextField), findsNothing);
      expect(find.textContaining('关闭无代码模式'), findsWidgets);
      expect(t.takeException(), isNull);
    });
  });

  group('跳转/引用字段覆盖（A：GUI 字段覆盖）', () {
    test('权威引用表内的跳转字段在无代码模式下是 reference（不给文本输入）', () {
      for (final id in const [
        'ActionCfg:next',
        'ActionCfg:evtId',
        'ItemCfg:talkId',
        'GiftEvtCfg:talkId',
        'InteractCfg:talkId',
        'LoveGreetingCfg:talkId',
        'LoveDrawCfg:talkId',
        'NpcActivityCfg:talkId',
        'TalkInputMinigameCfg:talkId',
        'TripSpotCfg:evtId',
        'ExpoEvtCfg:evtId',
        'AnimeConCfg:evtId',
        'MovieCfg:talks',
        'NegotiationCfg:talks',
      ]) {
        final parts = id.split(':');
        final rule = fieldRuleFor(parts[0], parts[1]);
        expect(rule, isNotNull, reason: '$id 应有引用规则');
        expect(noCodeShapeFor(parts[0], parts[1], 'Number', rule),
            isNot(NoCodeShape.untouched),
            reason: '$id 不应再是文本输入（untouched）');
      }
    });

    test('ActionCfg:next 指向自身表（权威引用表 kRules）', () {
      expect(fieldRuleFor('ActionCfg', 'next')?.idRefCfg, 'ActionCfg');
      expect(fieldRuleFor('ItemCfg', 'talkId')?.idRefCfg, 'TalkCfg');
    });
  });
}