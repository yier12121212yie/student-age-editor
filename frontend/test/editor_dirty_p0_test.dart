// 性能 P0-1 / P0-3 的两个 Widget 回归测试（离线，MockClient 注入）：
//
// 1. Dirty 期间连续编辑不再逐键触发 SchemaEditorView 全视图重建：
//    _markDirty 在已脏时只推进编辑代数、不再 setState（首帧 clean→dirty
//    的那次重建保留）。用 debugBuildCount 探针断言重建只前进一次。
// 2. 在途异步保存期间继续编辑，保存响应不得误清 dirty：
//    _saveInner 以发送时的编辑代数为快照，响应回来时代数已前进就保持
//    dirty，由下一次保存带走。用 Completer 控制 PUT 响应时序。
//
// 注：putRaw/postRaw 在后台 isolate 做 jsonEncode（compute/Isolate.run），
// 其结果经真实事件循环送达，testWidgets 的 FakeAsync 不接管 —— 因此保存
// 链路的推进用 tester.runAsync 短真实延时轮询放行，再 pump 冲刷微任务。
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_age_editor/core/api_client.dart';
import 'package:student_age_editor/core/models.dart';
import 'package:student_age_editor/features/editor/schema_editor_view.dart';

http.Response _json(Object body, [int code = 200]) => http.Response(
      jsonEncode(body), code,
      headers: {'content-type': 'application/json'},
    );

const String _cfg = 'DemoCfg';

AppState _st(Map<String, dynamic> schema) => AppState()
  ..gameSchema = schema
  ..keyMaps = {}
  ..gameDicts = const {};

Map<String, dynamic> _demoTable() => {
      '1': {'id': 1, 'name': '初始'},
    };

Future<void> _mount(
  WidgetTester tester, {
  void Function(bool dirty)? onDirtyChanged,
}) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = const Size(1400, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(fluent.FluentApp(
    debugShowCheckedModeBanner: false,
    home: Scaffold(
      body: SchemaEditorView(
        state: _st({_cfg: {'name': 'String'}}),
        cfgName: _cfg,
        classic: true,
        onDirtyChanged: onDirtyChanged,
      ),
    ),
  ));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

/// 放行保存链路：putRaw 的后台 isolate 结果只能经真实事件循环送达
/// （FakeAsync 不接管 ReceivePort），每轮 runAsync 给真实事件机会，
/// 再 pump 冲刷 faked-zone 微任务推进保存流程，直到 [done] 成立。
Future<void> _pumpUntilReal(
  WidgetTester tester,
  bool Function() done,
) async {
  var rounds = 0;
  for (; rounds < 60 && !done(); rounds++) {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump();
  }
  expect(done(), isTrue,
      reason: '保存链路 60 轮 runAsync 轮询内未推进到位（putRaw/compute 未回包）');
}

void main() {
  setUp(() {
    ApiClient.instance.baseUrl = 'http://127.0.0.1:9';
  });

  tearDown(() {
    ApiClient.instance.client = http.Client();
  });

  testWidgets('Dirty 期间连续编辑不二次触发生命周期重建（P0-1）', (tester) async {
    SchemaEditorView.debugBuildCount = 0;
    final dirtyCalls = <bool>[];
    ApiClient.instance.client = MockClient((req) async {
      final p = req.url.path;
      if (req.method == 'GET' && p == '/api/cfg/$_cfg') {
        return _json({'data': _demoTable(), 'exists': true});
      }
      return _json({'ok': true});
    });
    await _mount(tester, onDirtyChanged: dirtyCalls.add);
    expect(tester.takeException(), isNull);
    final baseBuilds = SchemaEditorView.debugBuildCount;
    expect(baseBuilds, greaterThan(0));
    expect(dirtyCalls, isEmpty);

    // 第一次编辑：clean → dirty，应当恰好触发一次全视图重建。
    await tester.enterText(find.byType(EditableText).first, '第一次编辑');
    await tester.pump();
    expect(dirtyCalls, [true], reason: 'clean→dirty 转变上报一次');
    expect(SchemaEditorView.debugBuildCount, baseBuilds + 1,
        reason: '首次置脏触发一次重建（脏标记 UI 依赖它）');
    expect(find.text('有未保存修改'), findsOneWidget);

    // 已脏状态下连续编辑：只推进编辑代数，不再触发重建与重复上报。
    for (var i = 2; i <= 5; i++) {
      await tester.enterText(find.byType(EditableText).first, '第$i次编辑');
      await tester.pump();
      expect(SchemaEditorView.debugBuildCount, baseBuilds + 1,
          reason: 'dirty 期间第 $i 次编辑不应再触发全视图重建');
      expect(dirtyCalls, [true], reason: 'dirty 期间不再重复上报');
    }
    // 真实编辑仍然生效：文本已写入、脏标记仍在。
    expect(find.text('第5次编辑'), findsOneWidget);
    expect(find.text('有未保存修改'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('在途异步保存期间继续编辑：响应不误清 dirty，下次保存才清（P0-3）',
      (tester) async {
    SchemaEditorView.debugBuildCount = 0;
    final dirtyCalls = <bool>[];
    final putBodies = <Map<String, dynamic>>[];
    final putGate = Completer<void>(); // 控制首个 PUT 的响应时序
    ApiClient.instance.client = MockClient((req) async {
      final p = req.url.path;
      if (req.method == 'GET' && p == '/api/cfg/$_cfg') {
        return _json({'data': _demoTable(), 'exists': true});
      }
      if (req.method == 'POST' && p == '/api/validate') {
        return _json({'issues': <dynamic>[]});
      }
      if (req.method == 'PUT' && p == '/api/cfg/$_cfg') {
        putBodies.add(jsonDecode(req.body) as Map<String, dynamic>);
        // 首个 PUT 挂起，模拟慢网络在途；之后立即返回成功。
        if (!putGate.isCompleted) await putGate.future;
        return _json({'mtime_ns': 424242});
      }
      return _json({'ok': true});
    });
    await _mount(tester, onDirtyChanged: dirtyCalls.add);
    expect(tester.takeException(), isNull);

    // 保存前编辑一次 → dirty（代数 1）。
    await tester.enterText(find.byType(EditableText).first, '在途前的编辑');
    await tester.pump();
    expect(dirtyCalls, [true]);

    // 发起保存：校验 + putRaw 都进后台 isolate 编码，轮询至 PUT 真正发出。
    await tester.tap(find.text('💾 保存修改至 $_cfg'));
    await _pumpUntilReal(tester, () => putBodies.isNotEmpty);
    expect(putBodies, hasLength(1));
    expect(((putBodies.first['data'] as Map)['1'] as Map)['name'],
        '在途前的编辑');

    // 在途期间继续编辑：dirty 必须保持（代数推进到 2）。
    await tester.enterText(find.byType(EditableText).first, '在途中的编辑');
    await tester.pump();
    expect(dirtyCalls, [true], reason: '在途期间的新编辑不得被误标为已落盘');
    expect(find.text('有未保存修改'), findsOneWidget);

    // 保存响应回来：代数快照(1) != 当前(2) → dirty 保持，等待下次保存。
    putGate.complete();
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(dirtyCalls, [true], reason: '保存响应时存在在途新编辑，dirty 保持 true');
    expect(find.text('有未保存修改'), findsOneWidget);

    // 第二次保存：无新编辑，响应后清 dirty（成功路径）。
    await tester.tap(find.text('💾 保存修改至 $_cfg'));
    await _pumpUntilReal(tester, () => putBodies.length >= 2);
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(((putBodies[1]['data'] as Map)['1'] as Map)['name'], '在途中的编辑',
        reason: '第二次保存带走在途期间的新编辑');
    expect(dirtyCalls, [true, false], reason: '无在途新编辑的保存成功后清 dirty 一次');
    expect(find.text('有未保存修改'), findsNothing);
    expect(tester.takeException(), isNull);

    // 让「已保存」InfoBar 的自动关闭延时走完，避免测试收尾残留 pending 定时。
    await tester.pump(const Duration(seconds: 4));
    await tester.pump(const Duration(seconds: 4));
    await tester.pump();
  });
}
