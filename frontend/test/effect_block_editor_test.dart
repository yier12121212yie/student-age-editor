// 效果/条件可视化搭建器（M2 前端）测试：
//   1) 纯序列化（rowsFromParse → serializeBlockRows）稳定：改槽/取反/移序/复制/删除/嵌套；
//   2) EffectBlockEditor 组件：parse 渲染、行操作→确定整串、空文本直加、原始文本兜底、单行约束；
//   3) EffectHintField 接入：noCodeMode 才出「积木编辑」按钮。
// 走 MockClient 打桩 /api/effect/parse（后端并行开发中，契约已锁定）。
import 'dart:convert';

import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:student_age_editor/core/api_client.dart';
import 'package:student_age_editor/features/editor/effect_hint_field.dart';
import 'package:student_age_editor/features/nocode/effect_block_editor.dart';

// ---------- 契约行构造 ----------

Map<String, dynamic> _dictSlot(String name, String dict, String label, String value) =>
    {'name': name, 'kind': 'dict', 'dict': dict, 'label': label, 'value': value};
Map<String, dynamic> _numSlot(String name, String label, String value) =>
    {'name': name, 'kind': 'number', 'dict': null, 'label': label, 'value': value};

Map<String, dynamic> _row({
  int line = 1,
  bool negate = false,
  int? primary = 1,
  int? secondary = 1,
  List args = const [],
  String? display,
  String? code,
  String? desc,
  List<Map<String, dynamic>> slots = const [],
  List<Map<String, dynamic>>? nested,
  String? error,
}) {
  final head = <dynamic>[?primary, ?secondary, ...args];
  return {
    'line': line,
    'negate': negate,
    'primary': primary,
    'secondary': secondary,
    'args': args,
    'display': display ?? '[${head.join(', ')}]',
    'template': code == null ? null : {'code': code, 'desc': desc ?? ''},
    'slots': slots,
    'nested': nested,
    'error': error,
  };
}

/// 标准效果行：属性 3(魅力) +5 → `[1, 1, 3, 5]` / 人话「属性 魅力 增加 5」。
Map<String, dynamic> _rowA() => _row(
      code: '[1, 1, @ATTR@, V]',
      desc: '属性 @ATTR@ 增加 V',
      slots: [_dictSlot('ATTR', 'ATTR', '属性', '3'), _numSlot('V', '数值', '5')],
    );

/// 第二条：给予物品 101 ×50 → `[7, 1, 101, 50]`。
Map<String, dynamic> _rowB() => _row(
      line: 2,
      primary: 7,
      code: '[7, 1, @ITEM@, V]',
      desc: '给予物品 @ITEM@ V个',
      slots: [_dictSlot('ITEM', 'ITEM', '物品', '101'), _numSlot('V', '数量', '50')],
    );

http.Response _resp(Map<String, dynamic> m) =>
    http.Response(jsonEncode(m), 200, headers: {'content-type': 'application/json'});

/// 打桩 parse：非 `BAD` 文本走 [build]，含 `BAD` 返回 ok:false（模拟解析失败）。
/// catalog 走 /api/effect_suggest 返回一条无槽行（点选即成行）。
void _mockParse(Map<String, dynamic> Function(String text, String mode) build) {
  ApiClient.instance.client = MockClient((req) async {
    switch (req.url.path) {
      case '/api/effect/parse':
        final t = (jsonDecode(req.body)['text'] ?? '').toString();
        if (t.contains('BAD')) {
          return _resp({'ok': false, 'status': 'json_error', 'message': '坏文本', 'translations': [], 'rows': []});
        }
        return _resp(build(t, (jsonDecode(req.body)['mode'] ?? '').toString()));
      case '/api/effect_suggest':
        return _resp({
          'items': [
            {'code': '[9, 9]', 'desc': '目录行', 'raw_code': '[9, 9]', 'slots': []},
          ]
        });
      case '/api/effect_validate':
        return _resp({'valid': true, 'translations': ['ok'], 'errors': []});
      default:
        return _resp({'ok': true});
    }
  });
}

Future<void> _mountEditor(
  WidgetTester t, {
  required String text,
  String mode = 'effect',
  Map<String, dynamic> dicts = const {},
  bool singleRow = false,
  void Function(String?)? onResult,
}) async {
  t.view.physicalSize = const Size(1200, 1000);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
  await t.pumpWidget(fluent.FluentApp(
    debugShowCheckedModeBanner: false,
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: 700,
          height: 720,
          child: EffectBlockEditor(
            initialText: text,
            mode: mode,
            gameDicts: dicts,
            singleRow: singleRow,
            onResult: onResult ?? (_) {},
          ),
        ),
      ),
    ),
  ));
  await t.pumpAndSettle();
}

void main() {
  group('纯序列化 serializeBlockRows', () {
    test('parse→整串稳定：行内 ", "、行间 "; "', () {
      final rows = rowsFromParse({'rows': [_rowA(), _rowB()]});
      expect(serializeBlockRows(rows), '[1, 1, 3, 5]; [7, 1, 101, 50]');
    });

    test('改槽值→assembleEffectCode 输出正确整串', () {
      final rows = rowsFromParse({'rows': [_rowA(), _rowB()]});
      rows[0].values['V'] = '9';
      expect(serializeBlockRows(rows), '[1, 1, 3, 9]; [7, 1, 101, 50]');
      // dict 槽改动同样落到代码位
      rows[0].values['ATTR'] = '1';
      expect(serializeBlockRows(rows), '[1, 1, 1, 9]; [7, 1, 101, 50]');
    });

    test('槽值缺失保留原槽文本，不产出坏码', () {
      final rows = rowsFromParse({'rows': [_rowA()]});
      rows[0].values.remove('ATTR');
      expect(serializeBlockRows(rows), '[1, 1, @ATTR@, 5]');
    });

    test('取反徽章→secondary 负号写回', () {
      final rows = rowsFromParse({'rows': [_rowA()]});
      expect(rows[0].toLine(), '[1, 1, 3, 5]');
      rows[0].negate = true;
      expect(rows[0].toLine(), '[1, -1, 3, 5]');
      // 后端已置 negate 的行，初解析即写出负号
      final neg = rowsFromParse({'rows': [_row(negate: true, code: '[1, 1, @ATTR@, V]', desc: '属性 @ATTR@ 增加 V', slots: [_dictSlot('ATTR', 'ATTR', '属性', '3'), _numSlot('V', '数值', '5')])]});
      expect(neg[0].toLine(), '[1, -1, 3, 5]');
      expect(serializeBlockRows(neg), '[1, -1, 3, 5]');
    });

    test('上移下移/删除/复制后文本序列化稳定', () {
      final rows = rowsFromParse({'rows': [_rowA(), _rowB()]});
      rows.insert(1, rows[0].copy());
      expect(serializeBlockRows(rows), '[1, 1, 3, 5]; [1, 1, 3, 5]; [7, 1, 101, 50]');
      final last = rows.removeLast();
      rows.insert(0, last);
      expect(serializeBlockRows(rows), '[7, 1, 101, 50]; [1, 1, 3, 5]; [1, 1, 3, 5]');
      rows.removeAt(0);
      expect(serializeBlockRows(rows), '[1, 1, 3, 5]; [1, 1, 3, 5]');
    });

    test('嵌套 998：父行紧跟子行；改子行槽值就地反映', () {
      final parent = _row(
        primary: 998,
        display: '[998, 1, 0]',
        code: '[998, 1, 0]',
        desc: '嵌套组',
        nested: [_row(line: 2, code: '[1, 1, @ATTR@, V]', desc: '属性 @ATTR@ 增加 V', slots: [_dictSlot('ATTR', 'ATTR', '属性', '3'), _numSlot('V', '数值', '5')])],
      );
      final rows = rowsFromParse({'rows': [parent]});
      expect(serializeBlockRows(rows), '[998, 1, 0]; [1, 1, 3, 5]');
      rows[0].nested[0].values['V'] = '7';
      expect(serializeBlockRows(rows), '[998, 1, 0]; [1, 1, 3, 7]');
      // 子行取反
      rows[0].nested[0].negate = true;
      expect(serializeBlockRows(rows), '[998, 1, 0]; [1, -1, 3, 7]');
    });
  });

  group('EffectBlockEditor 组件', () {
    testWidgets('parse→行卡片渲染：中文人话 + 错误红标 + 取反徽章', (t) async {
      _mockParse((text, mode) => {
            'ok': true,
            'status': 'ok',
            'translations': [],
            'rows': [
              _rowA(),
              _row(
                line: 2,
                primary: 2,
                negate: true,
                code: '[2, 1, V]',
                desc: '金钱增加 V',
                slots: [_numSlot('V', '数值', '100')],
                error: '该行逻辑错误',
              ),
            ],
          });
      await _mountEditor(t, text: 'X', dicts: {'attrs': {'3': '魅力'}, 'items': {}});
      await t.pumpAndSettle();

      // 人话（dict 槽显示名称）
      expect(find.text('属性 魅力 增加 5'), findsOneWidget);
      // 取反徽章 + 异常徽章 + 错误正文
      expect(find.text('取反'), findsOneWidget);
      expect(find.text('异常'), findsOneWidget);
      expect(find.text('该行逻辑错误'), findsOneWidget);
      // negate 行码已带负号
      expect(find.text('[2, -1, 100]'), findsOneWidget);
      expect(t.takeException(), isNull);
    });

    testWidgets('点取反按钮→负号写回；确定输出整串', (t) async {
      _mockParse((text, mode) => {'ok': true, 'status': 'ok', 'translations': [], 'rows': [_rowA()]});
      String? result;
      await _mountEditor(t, text: 'X', onResult: (v) => result = v);
      expect(find.text('[1, 1, 3, 5]'), findsOneWidget);

      await t.tap(find.byKey(const ValueKey('neg-0')));
      await t.pumpAndSettle();
      expect(find.text('[1, -1, 3, 5]'), findsOneWidget);
      expect(find.text('取反'), findsOneWidget);

      await t.tap(find.text('确定'));
      await t.pumpAndSettle();
      expect(result, '[1, -1, 3, 5]');
    });

    testWidgets('复制首行→确定整串含重复', (t) async {
      _mockParse((text, mode) => {'ok': true, 'status': 'ok', 'translations': [], 'rows': [_rowA(), _rowB()]});
      String? result;
      await _mountEditor(t, text: 'X', onResult: (v) => result = v);
      await t.tap(find.byKey(const ValueKey('copy-0')));
      await t.pumpAndSettle();
      await t.tap(find.text('确定'));
      await t.pumpAndSettle();
      expect(result, '[1, 1, 3, 5]; [1, 1, 3, 5]; [7, 1, 101, 50]');
    });

    testWidgets('下移首行→确定顺序交换', (t) async {
      _mockParse((text, mode) => {'ok': true, 'status': 'ok', 'translations': [], 'rows': [_rowA(), _rowB()]});
      String? result;
      await _mountEditor(t, text: 'X', onResult: (v) => result = v);
      await t.tap(find.byKey(const ValueKey('down-0')));
      await t.pumpAndSettle();
      await t.tap(find.text('确定'));
      await t.pumpAndSettle();
      expect(result, '[7, 1, 101, 50]; [1, 1, 3, 5]');
    });

    testWidgets('删除首行→确定仅剩次行', (t) async {
      _mockParse((text, mode) => {'ok': true, 'status': 'ok', 'translations': [], 'rows': [_rowA(), _rowB()]});
      String? result;
      await _mountEditor(t, text: 'X', onResult: (v) => result = v);
      await t.tap(find.byKey(const ValueKey('del-0')));
      await t.pumpAndSettle();
      await t.tap(find.text('确定'));
      await t.pumpAndSettle();
      expect(result, '[7, 1, 101, 50]');
    });

    testWidgets('嵌套子行以缩进卡渲染、人话可见', (t) async {
      _mockParse((text, mode) => {
            'ok': true,
            'status': 'ok',
            'translations': [],
            'rows': [
              _row(
                primary: 998,
                display: '[998, 1, 0]',
                code: '[998, 1, 0]',
                desc: '嵌套组',
                nested: [_row(line: 2, code: '[1, 1, @ATTR@, V]', desc: '属性 @ATTR@ 增加 V', slots: [_dictSlot('ATTR', 'ATTR', '属性', '3'), _numSlot('V', '数值', '5')])],
              ),
            ],
          });
      await _mountEditor(t, text: 'X', dicts: {'attrs': {'3': '魅力'}});
      await t.pumpAndSettle();
      expect(find.text('嵌套组'), findsOneWidget); // 父行人话
      expect(find.text('属性 魅力 增加 5'), findsOneWidget); // 子行人话
      expect(find.byKey(const ValueKey('neg-0-child')), findsOneWidget,
          reason: '子行可编辑：有取反入口'); // 子行 secondary=1 → 出取反
      expect(find.byKey(const ValueKey('del-0')), findsOneWidget); // 顶层删除存在
    });

    testWidgets('空文本进入不 parse，可直接加行（走目录）', (t) async {
      var parseCalls = 0;
      ApiClient.instance.client = MockClient((req) async {
        if (req.url.path == '/api/effect/parse') {
          parseCalls++;
          final t = (jsonDecode(req.body)['text'] ?? '').toString();
          if (t.contains('9')) {
            return _resp({'ok': true, 'status': 'ok', 'translations': [], 'rows': [_row(primary: 9, secondary: 9, args: [], display: '[9, 9]', code: '[9, 9]', desc: '目录行')]});
          }
          return _resp({'ok': true, 'status': 'empty', 'translations': [], 'rows': []});
        }
        if (req.url.path == '/api/effect_suggest') {
          return _resp({'items': [{'code': '[9, 9]', 'desc': '目录行', 'raw_code': '[9, 9]', 'slots': []}]});
        }
        return _resp({'ok': true});
      });
      String? result;
      await _mountEditor(t, text: '', onResult: (v) => result = v);
      await t.pumpAndSettle();
      expect(parseCalls, 0, reason: '空文本不应触发解析');
      expect(find.textContaining('＋ 添加效果'), findsOneWidget);

      // 点加行 → 目录浏览打开
      await t.tap(find.byKey(const ValueKey('add-row')));
      await t.pumpAndSettle();
      expect(find.text('浏览效果'), findsOneWidget);
      await t.tap(find.text('目录行'));
      await t.pumpAndSettle();
      expect(parseCalls, greaterThanOrEqualTo(1), reason: '成行回填要再 parse 拿回模板/槽');
      expect(find.text('[9, 9]'), findsOneWidget);

      await t.tap(find.text('确定'));
      await t.pumpAndSettle();
      expect(result, '[9, 9]');
    });

    testWidgets('原始文本通道：parse 失败保留积木、确定输出原行', (t) async {
      _mockParse((text, mode) => {'ok': true, 'status': 'ok', 'translations': [], 'rows': [_rowA()]});
      String? result;
      await _mountEditor(t, text: 'X', dicts: {'attrs': {'3': '魅力'}}, onResult: (v) => result = v);
      expect(find.text('属性 魅力 增加 5'), findsOneWidget);

      await t.tap(find.byKey(const ValueKey('raw-toggle')));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const ValueKey('raw-input')), '[1, BAD');
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('raw-apply')));
      await t.pumpAndSettle();

      expect(find.textContaining('解析失败'), findsOneWidget);
      expect(find.text('属性 魅力 增加 5'), findsOneWidget, reason: 'parse 失败不采纳，保留原积木');
      await t.tap(find.text('确定'));
      await t.pumpAndSettle();
      expect(result, '[1, 1, 3, 5]', reason: '坏文本未被采纳');
    });

    testWidgets('原始文本通道：应用成功回填积木', (t) async {
      _mockParse((text, mode) => {
            'ok': true,
            'status': 'ok',
            'translations': [],
            'rows': text.contains('200')
                ? [_row(primary: 7, secondary: 2, display: '[7, 2, 200]', code: '[7, 2, V]', desc: '奖励 V', slots: [_numSlot('V', '数值', '200')])]
                : [_rowA()],
          });
      String? result;
      await _mountEditor(t, text: 'X', onResult: (v) => result = v);
      await t.tap(find.byKey(const ValueKey('raw-toggle')));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const ValueKey('raw-input')), '[7, 2, 200]');
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('raw-apply')));
      await t.pumpAndSettle();
      expect(find.text('奖励 200'), findsOneWidget);
      await t.tap(find.text('确定'));
      await t.pumpAndSettle();
      expect(result, '[7, 2, 200]');
    });

    testWidgets('screenEffect 单行约束：加行禁用并提示', (t) async {
      _mockParse((text, mode) => {
            'ok': true,
            'status': 'ok',
            'translations': [],
            'rows': [_row(primary: 4001, secondary: null, args: [0], display: '[4001, 0]', code: '[4001, 0]', desc: '屏幕抖动', slots: [])],
          });
      String? result;
      await _mountEditor(t, text: 'X', mode: 'screen', singleRow: true, onResult: (v) => result = v);
      expect(find.textContaining('一句话只能一个屏幕效果'), findsOneWidget);
      // 已有一行 → 加行按钮禁用；点击无效
      await t.tap(find.byKey(const ValueKey('add-row')));
      await t.pumpAndSettle();
      expect(result, isNull);
      expect(find.text('屏幕抖动'), findsOneWidget);
    });

    testWidgets('取消→onResult 为 null', (t) async {
      _mockParse((text, mode) => {'ok': true, 'status': 'ok', 'translations': [], 'rows': [_rowA()]});
      String? result = 'sentinel';
      await _mountEditor(t, text: 'X', onResult: (v) => result = v);
      await t.tap(find.text('取消'));
      await t.pumpAndSettle();
      expect(result, isNull);
    });

    testWidgets('空文本无有效行时解析失败给出提示仍可用', (t) async {
      _mockParse((text, mode) => {'ok': true, 'status': 'ok', 'translations': [], 'rows': []});
      await _mountEditor(t, text: '[坏的东西]');
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('add-row')), findsOneWidget);
      expect(t.takeException(), isNull);
    });
  });

  group('showEffectBlockEditor 对话框路径', () {
    Future<void> open(WidgetTester t, void Function(String?) done) async {
      t.view.physicalSize = const Size(1200, 1000);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);
      await t.pumpWidget(fluent.FluentApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          body: Builder(builder: (ctx) => Center(
                child: ElevatedButton(
                  onPressed: () async =>
                      done(await showEffectBlockEditor(ctx, text: 'X', mode: 'effect')),
                  child: const Text('open'),
                ),
              )),
        ),
      ));
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
    }

    testWidgets('确定→返回整串；ContentDialog 内可取反', (t) async {
      _mockParse((text, mode) => {'ok': true, 'status': 'ok', 'translations': [], 'rows': [_rowA()]});
      String? returned = 'sentinel';
      await open(t, (v) => returned = v);
      expect(find.byKey(const ValueKey('neg-0')), findsOneWidget); // 编辑器已打开
      await t.tap(find.byKey(const ValueKey('neg-0')));
      await t.pumpAndSettle();
      await t.tap(find.text('确定'));
      await t.pumpAndSettle();
      expect(returned, '[1, -1, 3, 5]');
    });

    testWidgets('取消→返回 null', (t) async {
      _mockParse((text, mode) => {'ok': true, 'status': 'ok', 'translations': [], 'rows': [_rowA()]});
      String? returned = 'sentinel';
      await open(t, (v) => returned = v);
      await t.tap(find.text('取消'));
      await t.pumpAndSettle();
      expect(returned, isNull);
    });
  });

  group('EffectHintField 接入', () {
    Widget field(bool noCode) => EffectHintField(
          value: const [
            [1, 1, 3, 5]
          ],
          type: '2D Array',
          fieldKey: 'effect',
          mode: 'effect',
          noCodeMode: noCode,
          gameDicts: const {},
          onChanged: (_) {},
        );

    Future<void> mount(WidgetTester t, bool noCode) async {
      t.view.physicalSize = const Size(1200, 1000);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);
      await t.pumpWidget(fluent.FluentApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          body: SingleChildScrollView(
            child: SizedBox(width: 900, child: field(noCode)),
          ),
        ),
      ));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400)); // 越过校验防抖 350ms
      await t.pumpAndSettle();
    }

    testWidgets('noCodeMode=true 出现积木编辑按钮', (t) async {
      _mockParse((text, mode) => {'ok': true, 'status': 'ok', 'translations': [], 'rows': []});
      await mount(t, true);
      expect(find.text('积木编辑'), findsOneWidget);
      expect(find.text('浏览效果目录…'), findsOneWidget);
    });

    testWidgets('noCodeMode=false 不出现积木编辑按钮（对外行为不变）', (t) async {
      _mockParse((text, mode) => {'ok': true, 'status': 'ok', 'translations': [], 'rows': []});
      await mount(t, false);
      expect(find.text('积木编辑'), findsNothing);
      expect(find.text('浏览效果目录…'), findsNothing);
    });
  });
}
