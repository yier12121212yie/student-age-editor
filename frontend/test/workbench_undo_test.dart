// N12 工作台级撤销/重做：有界快照栈（≤50 步）+ 600ms 编辑窗口（去抖合并）。
//
// 撤销回放不经过真实网络：控制器数据用内置跟踪视图直接改，save 之外无 IO。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:student_age_editor/core/api_client.dart';
import 'package:student_age_editor/core/workbench_controller.dart';

void main() {
  setUp(() {
    ApiClient.instance.client = MockClient((req) async {
      final path = req.url.path;
      final data = path == '/api/cfg/ATable'
          ? {
              '1': {'name': '甲'},
            }
          : <String, dynamic>{};
      return http.Response(
        jsonEncode({'data': data, 'mtime_ns': 1}),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
  });

  tearDown(() {
    ApiClient.instance.client = http.Client();
  });

  Future<WorkbenchController> loaded(WidgetTester tester) async {
    final ctl = WorkbenchController(cfgs: const ['ATable', 'BTable']);
    await ctl.load();
    addTearDown(ctl.dispose);
    return ctl;
  }

  testWidgets('放弃修改后仍可撤销找回（U2）', (tester) async {
    final ctl = await loaded(tester);
    final a = ctl.table('ATable');
    a.data['1'] = {'name': '乙'};
    expect(ctl.dirty, isTrue);

    ctl.discard();
    expect((a.data['1'] as Map)['name'], '甲');
    expect(ctl.dirty, isFalse);

    // 误点「放弃修改」后 Ctrl+Z 应整批找回，而不是历史被清空。
    expect(ctl.canUndo, isTrue);
    ctl.undo();
    expect((a.data['1'] as Map)['name'], '乙');
    expect(ctl.dirty, isTrue);
  });

  testWidgets('编辑后撤销还原数据，重做再应用；撤销回磁盘态时 dirty 归位', (tester) async {
    final ctl = await loaded(tester);
    final a = ctl.table('ATable');
    expect(ctl.canUndo, isFalse);
    expect(ctl.canRedo, isFalse);

    a.data['1'] = {'name': '乙'};
    expect(ctl.dirty, isTrue);
    expect(ctl.canUndo, isTrue, reason: '进行中的编辑窗口也应可撤销（先封口再退）');

    ctl.undo();
    expect((a.data['1'] as Map)['name'], '甲');
    expect(ctl.dirty, isFalse, reason: '撤销回磁盘内容后应视为已同步');
    expect(ctl.canRedo, isTrue);

    ctl.redo();
    expect((a.data['1'] as Map)['name'], '乙');
    expect(ctl.dirty, isTrue);
    expect(ctl.canRedo, isFalse);
  });

  testWidgets('编辑窗口内连续改动合并为一步，跨窗口分成两步', (tester) async {
    final ctl = await loaded(tester);
    final a = ctl.table('ATable');

    a.data['x'] = 1;
    await tester.pump(const Duration(milliseconds: 300)); // 同一窗口内
    a.data['x'] = 2;
    await tester.pump(const Duration(milliseconds: 700)); // 封口

    ctl.undo();
    expect(a.data.containsKey('x'), isFalse, reason: '一步撤销回到两次改动之前');
    expect(ctl.canUndo, isFalse, reason: '窗口内两次改动只算一步');
  });

  testWidgets('一步内跨表改动一并还原', (tester) async {
    final ctl = await loaded(tester);
    final a = ctl.table('ATable');
    final b = ctl.table('BTable');

    a.data['x'] = 1;
    b.data['y'] = 2;
    await tester.pump(const Duration(milliseconds: 700));

    ctl.undo();
    expect(a.data.containsKey('x'), isFalse);
    expect(b.data.containsKey('y'), isFalse);
  });

  testWidgets('新编辑清空重做链', (tester) async {
    final ctl = await loaded(tester);
    final a = ctl.table('ATable');

    a.data['x'] = 1;
    await tester.pump(const Duration(milliseconds: 700));
    ctl.undo();
    expect(ctl.canRedo, isTrue);

    a.data['z'] = 3; // 新分叉
    expect(ctl.canRedo, isFalse, reason: '新编辑后重做链应失效');
    ctl.undo();
    expect(a.data.containsKey('z'), isFalse);
    expect(a.data.containsKey('x'), isFalse, reason: '栈上仍是第一次编辑前的那一步');
  });

  testWidgets('撤销栈有界：超过 50 步只保留最近 50 步', (tester) async {
    final ctl = await loaded(tester);
    final a = ctl.table('ATable');

    for (var i = 0; i < 55; i++) {
      a.data['n'] = i;
      await tester.pump(const Duration(milliseconds: 700));
    }

    var steps = 0;
    while (ctl.undo()) {
      steps++;
    }
    expect(steps, WorkbenchController.maxUndoSteps);
  });

  testWidgets('重载作废历史', (tester) async {
    final ctl = await loaded(tester);
    ctl.table('ATable').data['x'] = 1;
    await tester.pump(const Duration(milliseconds: 700));

    await ctl.load();
    expect(ctl.canUndo, isFalse);
    expect(ctl.canRedo, isFalse);
  });
}
