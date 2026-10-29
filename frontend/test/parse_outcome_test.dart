// D1 拆解结果结构化消费：parseEffectOutcome 的状态映射测试。
//
// 覆盖：
//   * ok / empty / logic_error / partial 均返回 rows（不再「有错即整段判死」）；
//   * partial 的坏行 unrecognized=true、toLine() 逐字节保留原文；
//   * missing_outer_bracket 自动补 `[ … ]` 重试一次、回传 fixedText；
//   * json_error / 网络异常不再是 null 而是带 message 的 error 状态。
// 走 MockClient 打桩 /api/effect/parse（契约：{ok,status,message,translations,rows}）。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:student_age_editor/core/api_client.dart';
import 'package:student_age_editor/features/nocode/effect_block_editor.dart';

Map<String, dynamic> _resp(Map<String, dynamic> m) =>
    jsonDecode(jsonEncode(m)) as Map<String, dynamic>;

/// 一条正常行：[1, 1, 3, 5]。
Map<String, dynamic> _goodRow() => {
      'line': 1,
      'negate': false,
      'primary': 1,
      'secondary': 1,
      'args': [3, 5],
      'display': '[1, 1, 3, 5]',
      'template': {'code': '[1, 1, @ATTR@, V]', 'desc': '属性 @ATTR@ 增加 V'},
      'slots': [
        {'name': 'ATTR', 'kind': 'dict', 'dict': 'ATTR', 'label': '属性', 'value': '3'},
        {'name': 'V', 'kind': 'number', 'dict': null, 'label': '数值', 'value': '5'},
      ],
      'nested': null,
      'error': null,
    };

/// 一条未识别坏行（D3 partial 回退产物）。
Map<String, dynamic> _badRow(String display) => {
      'line': 2,
      'negate': false,
      'primary': null,
      'secondary': null,
      'args': [],
      'display': display,
      'template': null,
      'slots': [],
      'nested': null,
      'error': '未识别的行（括号或逗号不匹配）',
      'unrecognized': true,
    };

void _mock(Map<String, dynamic> Function(String text) handler) {
  ApiClient.instance.client = MockClient((req) async {
    final body = jsonDecode(req.body) as Map<String, dynamic>;
    return http.Response(
      jsonEncode(handler((body['text'] ?? '').toString())),
      200,
      headers: {'content-type': 'application/json'},
    );
  });
}

void main() {
  test('ok：全部行拆解成功', () async {
    _mock((_) => _resp({
          'ok': true,
          'status': 'ok',
          'translations': [],
          'rows': [_goodRow()],
        }));

    final o = await parseEffectOutcome('[1, 1, 3, 5]', 'effect');
    expect(o.status, kParseStatusOk);
    expect(o.ok, isTrue);
    expect(o.rows, hasLength(1));
    expect(o.errorRowCount, 0);
  });

  test('logic_error：仍返回 rows（行级红标不锁死整段）', () async {
    _mock((_) => _resp({
          'ok': false,
          'status': 'logic_error',
          'message': '部分行有问题',
          'translations': [],
          'rows': [
            _goodRow(),
            {..._goodRow(), 'line': 2, 'error': '第 1 项不是有效的属性 ID。'},
          ],
        }));

    final o = await parseEffectOutcome('x', 'effect');
    expect(o.status, kParseStatusLogicError);
    expect(o.ok, isFalse);
    expect(o.rows, hasLength(2), reason: '有行级错误也必须把行交出来供修改');
    expect(o.errorRowCount, 1);
  });

  test('partial：坏行 unrecognized、toLine() 逐字节保留原文、保序', () async {
    _mock((_) => _resp({
          'ok': false,
          'status': 'partial',
          'message': '部分行无法解析，已按原样保留',
          'translations': [],
          'rows': [_goodRow(), _badRow('[999, x]')],
        }));

    final o = await parseEffectOutcome('[1, 1, 3, 5]; [999, x]', 'effect');
    expect(o.status, kParseStatusPartial);
    expect(o.ok, isFalse);
    expect(o.rows, hasLength(2));
    expect(o.rows[0].unrecognized, isFalse);
    expect(o.rows[1].unrecognized, isTrue);
    expect(o.rows[1].hasError, isTrue);
    expect(o.rows[1].toLine(), '[999, x]', reason: '未识别行不做任何归一/改写');
    expect(o.rows[1].editable, isFalse, reason: '未识别行不可编辑');
    expect(o.errorRowCount, 1);
  });

  test('missing_outer_bracket：自动补全重试一次并回传 fixedText', () async {
    _mock((text) {
      if (text.startsWith('[[')) {
        return _resp({
          'ok': true,
          'status': 'ok',
          'translations': [],
          'rows': [_goodRow()],
        });
      }
      return _resp({
        'ok': false,
        'status': 'missing_outer_bracket',
        'message': '缺少外层方括号，请改为: [ [1, 1, 3, 5] ]',
        'translations': [],
        'rows': [],
      });
    });

    final o = await parseEffectOutcome('1, 1, 3, 5', 'effect');
    expect(o.status, kParseStatusOk);
    expect(o.ok, isTrue);
    expect(o.fixedText, '[[1, 1, 3, 5]]');
    expect(o.message, contains('自动补全'));
    expect(o.rows, hasLength(1));
  });

  test('json_error：失败原因来自后端 message', () async {
    _mock((_) => _resp({
          'ok': false,
          'status': 'json_error',
          'message': '括号或逗号不匹配',
          'translations': [],
          'rows': [],
        }));

    final o = await parseEffectOutcome('[[[', 'effect');
    expect(o.status, kParseStatusJsonError);
    expect(o.ok, isFalse);
    expect(o.message, '括号或逗号不匹配');
    expect(o.rows, isEmpty);
    // 无定位字段时 jsonErrorText 退化为 message 本身。
    expect(o.jsonErrorText, '括号或逗号不匹配');
  });

  test('json_error 定位（D4）：显示「第 N 个字符附近」', () async {
    _mock((_) => _resp({
          'ok': false,
          'status': 'json_error',
          'message': '括号或逗号不匹配',
          'error_offset': 4,
          'error_line': 1,
          'error_col': 5,
          'translations': [],
          'rows': [],
        }));

    final o = await parseEffectOutcome('[1, 1, x]', 'effect');
    expect(o.status, kParseStatusJsonError);
    expect(o.errorOffset, 4);
    expect(o.errorLine, 1);
    expect(o.errorCol, 5);
    // offset 0-based → 用户可见的「第 5 个字符」（1-based）。
    expect(o.locationSuffix, '（第 5 个字符附近）');
    expect(o.jsonErrorText, '括号或逗号不匹配（第 5 个字符附近）');
  });

  test('json_error 定位：多行时同时给出行列', () async {
    _mock((_) => _resp({
          'ok': false,
          'status': 'json_error',
          'message': '括号或逗号不匹配',
          'error_offset': 12,
          'error_line': 2,
          'error_col': 3,
          'translations': [],
          'rows': [],
        }));

    final o = await parseEffectOutcome('x', 'effect');
    expect(o.errorLine, 2);
    expect(o.locationSuffix, '（第 13 个字符附近，第 2 行第 3 列）');
  });

  test('网络异常：error 状态 + 人性化 message（不再抛给调用方）', () async {
    ApiClient.instance.client = MockClient((req) async {
      throw Exception('boom');
    });

    final o = await parseEffectOutcome('[1, 1, 3, 5]', 'effect');
    expect(o.status, kParseStatusError);
    expect(o.ok, isFalse);
    expect(o.message, isNotNull);
    expect(o.message, startsWith('解析失败'));
  });
}
