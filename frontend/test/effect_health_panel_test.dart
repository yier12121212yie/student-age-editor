// D6 拆解体检报告：批量扫全部码字段 → 汇总 + 分级列表 → 点击跳转。
//
// 契约：
//   * 从 gameSchema 枚举码字段（判定单一真源 isEffectLikeField），逐表 GET
//     /api/cfg/<name> 取文本；
//   * 一次 POST /api/effect/parse_batch 拿 summary + 逐项 status（不 N 次往返）；
//   * 列表按「无法拆解 → 含问题 → 正常」排序；
//   * 点击某条经 onJump 回传 EffectCodeField（宿主据此打开该字段所在表）。
// 走 MockClient 打桩，不起真后端。
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:student_age_editor/core/api_client.dart';
import 'package:student_age_editor/core/models.dart';
import 'package:student_age_editor/features/nocode/effect_health_panel.dart';

const kCfg = 'EvtCfg';
const kField = 'effect';
// EffectCodeField.key 用 \u0000 分隔。
String _key(String row) => '$kCfg\u0000$row\u0000$kField';

/// 构造一个只含码字段的表 schema。
///
/// `EvtCfg.effect` 是登记在 kCodeFieldByCfg 里的码字段；`name` 是普通文本字段
/// （不应被体检采集）。
Map<String, dynamic> _schema() => {
      kCfg: {
        kField: '2D Array',
        'name': 'string',
      },
    };

/// 打桩：GET /api/cfg/<cfg> 回两行；POST /api/effect/parse_batch 回给定结果。
void _mock({required List<Map<String, dynamic>> results}) {
  ApiClient.instance.client = MockClient((req) async {
    if (req.method == 'GET') {
      return http.Response(
        jsonEncode({
          'ok': true,
          'data': {
            '1': {
              kField: [
                [1, 1, 3, 5],
              ],
            },
            '2': {
              kField: [
                ['oops', 'x'],
              ],
            },
          },
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    }
    // POST /api/effect/parse_batch
    return http.Response(
      jsonEncode({
        'ok': true,
        'summary': {
          'total': results.length,
          'parsed': 1,
          'problem': 0,
          'unparseable': results.length - 1,
          'empty': 0,
        },
        'results': results,
      }),
      200,
      headers: {'content-type': 'application/json'},
    );
  });
}

/// 从 AppState 构造面板（测试里不依赖真实 mod 加载）。
Widget _wrap(AppState state, {void Function(EffectCodeField)? onJump}) {
  return fluent.FluentApp(
    debugShowCheckedModeBanner: false,
    home: Scaffold(
      body: EffectHealthPanel(state: state, onJump: onJump),
    ),
  );
}

void main() {
  testWidgets('扫描：汇总条 + 分级列表，坏字段排前面', (tester) async {
    final state = AppState();
    state.gameSchema = _schema();

    _mock(results: [
      {
        'id': _key('2'),
        'status': 'json_error',
        'ok': false,
        'message': '括号或逗号不匹配',
        'error_row_count': 0,
        'unrecognized_rows': 0,
      },
      {
        'id': _key('1'),
        'status': 'ok',
        'ok': true,
        'error_row_count': 0,
        'unrecognized_rows': 0,
      },
    ]);

    await tester.pumpWidget(_wrap(state));
    await tester.pump();

    // 初始态：提示未扫描。
    expect(find.textContaining('扫描当前 Mod'), findsOneWidget);

    await tester.tap(find.text('开始体检'));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));

    // 汇总条：总数 2、可拆解 1、无法拆解 1。
    expect(find.byKey(const ValueKey('effect-health-summary')), findsOneWidget);
    expect(
      find.textContaining('共 2 个码字段'),
      findsOneWidget,
      reason: '汇总应报出码字段总数',
    );
    // 汇总的统计 chip（「无法拆解 1」同时出现在摘要句与 chip 里，故用 findsWidgets）。
    expect(find.text('无法拆解 1'), findsOneWidget);

    // 两条结果都在列表里。
    expect(find.byKey(ValueKey('health-${_key('1')}')), findsOneWidget);
    expect(find.byKey(ValueKey('health-${_key('2')}')), findsOneWidget);

    // 坏字段带「无法拆解」标签，且显示定位串 cfg → rowId · field。
    expect(find.text('无法拆解'), findsWidgets);
    expect(find.textContaining('$kCfg → 2 · $kField'), findsOneWidget);

    expect(tester.takeException(), isNull);
  });

  testWidgets('点击结果经 onJump 回传该字段', (tester) async {
    final state = AppState();
    state.gameSchema = _schema();

    _mock(results: [
      {
        'id': _key('1'),
        'status': 'logic_error',
        'ok': false,
        'message': '部分行有问题',
        'error_row_count': 1,
        'unrecognized_rows': 0,
      },
    ]);

    EffectCodeField? jumped;
    await tester.pumpWidget(_wrap(state, onJump: (f) => jumped = f));
    await tester.pump();

    await tester.tap(find.text('开始体检'));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));

    await tester.tap(find.byKey(ValueKey('health-${_key('1')}')));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));

    expect(jumped, isNotNull);
    expect(jumped!.cfg, kCfg);
    expect(jumped!.rowId, '1');
    expect(jumped!.field, kField);
    expect(tester.takeException(), isNull);
  });

  testWidgets('无码字段的表不产生体检项', (tester) async {
    final state = AppState();
    // name 是普通字段，不应被采集。
    state.gameSchema = {
      'TextCfg': {'name': 'string'},
    };

    _mock(results: const []);

    await tester.pumpWidget(_wrap(state));
    await tester.pump();
    await tester.tap(find.text('开始体检'));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.textContaining('没有发现码字段'), findsOneWidget);
    expect(find.byKey(const ValueKey('effect-health-summary')), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
