// A3.2 · WorkbenchController 单元测试：load / dirty / save / 乐观锁 409。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:student_age_editor/core/api_client.dart';
import 'package:student_age_editor/core/workbench_controller.dart';

void main() {
  late List<http.Request> log;

  setUp(() {
    log = [];
    ApiClient.instance.client = MockClient((req) async {
      log.add(req);
      final path = req.url.path;
      if (req.method == 'GET' && path.startsWith('/api/cfg/')) {
        final cfg = path.substring('/api/cfg/'.length);
        return http.Response(
          jsonEncode({
            'data': {
              '1': {'id': 1, 'name': '$cfg-row'},
            },
            'mtime_ns': 10,
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (req.method == 'PUT' && path.startsWith('/api/cfg/')) {
        return http.Response(
          jsonEncode({'ok': true, 'mtime_ns': 11}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response('{}', 404);
    });
  });

  test('load：填充各表数据与 mtime，dirty=false', () async {
    final c = WorkbenchController(cfgs: ['A', 'B']);
    await c.load();
    expect(c.loading, isFalse);
    expect(c.error, isNull);
    expect(c.dirty, isFalse);
    expect(c.table('A').data['1']['name'], 'A-row');
    expect(c.table('B').data['1']['name'], 'B-row');
    expect(c.table('A').mtime, 10);
  });

  test('改 data 后 dirty=true；discard 后回到 false', () async {
    final c = WorkbenchController(cfgs: ['A']);
    await c.load();
    c.table('A').data['2'] = {'id': 2};
    expect(c.dirty, isTrue);
    c.discard();
    expect(c.dirty, isFalse);
    expect(c.table('A').data.containsKey('2'), isFalse);
  });

  test('save：PUT 带 expect_mtime_ns，成功后 dirty=false 且 mtime 更新', () async {
    final c = WorkbenchController(cfgs: ['A']);
    await c.load();
    c.table('A').data['1']['name'] = 'changed';
    final ok = await c.save();
    expect(ok, isTrue);
    expect(c.dirty, isFalse);
    expect(c.table('A').mtime, 11);
    final put = log.firstWhere((r) => r.method == 'PUT');
    final body = jsonDecode(put.body) as Map<String, dynamic>;
    expect(body['expect_mtime_ns'], 10);
    expect((body['data'] as Map)['1']['name'], 'changed');
  });

  test('save：409 时走 onConflict；选 force 后带 force 重试成功', () async {
    var attempt = 0;
    ApiClient.instance.client = MockClient((req) async {
      final path = req.url.path;
      if (req.method == 'GET') {
        return http.Response(
          jsonEncode({'data': {'1': {'name': 'x'}}, 'mtime_ns': 10}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      attempt++;
      if (attempt == 1) return http.Response('conflict', 409);
      return http.Response(
        jsonEncode({'ok': true, 'mtime_ns': 12}),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final c = WorkbenchController(
      cfgs: ['A'],
      onConflict: (_) async => WorkbenchConflictChoice.force,
    );
    await c.load();
    c.table('A').data['1']['name'] = 'y';
    final ok = await c.save();
    expect(ok, isTrue);
    expect(attempt, 2); // 第一次 409，第二次带 force 成功
    expect(c.table('A').mtime, 12);
  });

  test('save：409 选 cancel → 返回 false，仍 dirty', () async {
    ApiClient.instance.client = MockClient((req) async {
      if (req.method == 'GET') {
        return http.Response(
          jsonEncode({'data': {}, 'mtime_ns': 1}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response('conflict', 409);
    });
    final c = WorkbenchController(
      cfgs: ['A'],
      onConflict: (_) async => WorkbenchConflictChoice.cancel,
    );
    await c.load();
    c.table('A').data['x'] = 1;
    expect(await c.save(), isFalse);
    expect(c.dirty, isTrue);
  });

  test('save：非 409 错误经 onError 上报并返回 false', () async {
    ApiClient.instance.client = MockClient((req) async {
      if (req.method == 'GET') {
        return http.Response(jsonEncode({'data': {}}), 200,
            headers: {'content-type': 'application/json'});
      }
      return http.Response('boom', 500);
    });
    Object? reported;
    final c = WorkbenchController(
      cfgs: ['A'],
      onError: (e) => reported = e,
    );
    await c.load();
    c.table('A').data['x'] = 1;
    expect(await c.save(), isFalse);
    expect(reported, isNotNull);
  });

  test('任表脏即整体 dirty；逐表独立 mtime', () async {
    final c = WorkbenchController(cfgs: ['A', 'B']);
    await c.load();
    c.table('B').data['z'] = 1;
    expect(c.dirty, isTrue);
    expect(c.table('A').dirty, isFalse);
    expect(c.table('B').dirty, isTrue);
  });

  group('嵌套写入置脏（回归：新增行的子字段改动不得静默丢失）', () {
    test('新增行内的嵌套 Map/List 修改仍要置脏', () async {
      final c = WorkbenchController(cfgs: ['A']);
      await c.load();
      final t = c.table('A');
      // 各工作台新增行的写法：直接塞一个含嵌套容器的裸 Map。
      t.data['2'] = {
        'id': 2,
        'roles': <dynamic>[],
        'next': {'talk': <dynamic>[]},
      };
      expect(t.dirty, isTrue);
      // 模拟一次保存：快照固化、dirty 复位。
      t.markSaved({'mtime_ns': 11});
      expect(t.dirty, isFalse);

      // 修复前：该行内部仍是裸容器，写它不推进版本号 → dirty 静默为 false。
      (t.data['2']['roles'] as List).add(10);
      expect(t.dirty, isTrue, reason: '嵌套 List 的写入必须置脏');
      expect(t.checkDirtyDeep(), isTrue);

      // 再深一层同样要置脏。
      t.markSaved({'mtime_ns': 12});
      expect(t.dirty, isFalse);
      ((t.data['2']['next'] as Map)['talk'] as List).add(3);
      expect(t.dirty, isTrue, reason: '两层嵌套的写入必须置脏');

      // discard 从纯 Dart 快照恢复（不再走 jsonEncode/jsonDecode 往返）。
      c.discard();
      expect(t.dirty, isFalse);
      expect((t.data['2']['roles'] as List), <dynamic>[10]);
      expect(((t.data['2']['next'] as Map)['talk'] as List), isEmpty);
    });

    test('列表元素内的嵌套写入同样置脏', () async {
      final c = WorkbenchController(cfgs: ['A']);
      await c.load();
      final t = c.table('A');
      t.data['list'] = <dynamic>[
        {'k': <dynamic>[]},
      ];
      t.markSaved({});
      expect(t.dirty, isFalse);
      ((t.data['list'] as List).first as Map)['k'].add(1);
      expect(t.dirty, isTrue);
    });

    test('相同标量重复写不翻转 dirty', () async {
      final c = WorkbenchController(cfgs: ['A']);
      await c.load();
      final t = c.table('A');
      t.data['x'] = 1;
      t.markSaved({});
      expect(t.dirty, isFalse);
      t.data['x'] = 1; // 同值重写：不产生无意义的 dirty
      expect(t.dirty, isFalse);
    });
  });
}
