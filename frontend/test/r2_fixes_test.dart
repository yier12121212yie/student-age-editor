// R2 计划新增回归用例（对应 plan/bugfix_simplify_perf_plan_r2.md §7.1「新增用例」）。
//
//  1. P0-A/B：ModInfo 兜底分支构造（mods_page 的 orElse 路径形态）
//  2. P2-I2：字段改回原值后 dirtyDeep 应为 false（脏状态误报修复）
//  3. P2-I1：load() 并发触发时旧响应不得覆盖新响应
//  4. P2-H：后端响应缺字段 / 字段类型漂移不得抛 TypeError
//  5. §5.1-1：排序缓存——新增行后列表必须即时更新（缓存失效点正确）
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_age_editor/core/api_client.dart';
import 'package:student_age_editor/core/file_upload_client.dart';
import 'package:student_age_editor/core/models.dart';
import 'package:student_age_editor/core/workbench_controller.dart';
import 'package:student_age_editor/features/person/person_workbench.dart';

http.Response _json(Object body, [int status = 200]) => http.Response(
      jsonEncode(body),
      status,
      headers: {'content-type': 'application/json'},
    );

void main() {
  group('P2-H 响应形状漂移', () {
    test('UploadInitiateResponse.fromJson：缺字段 / 类型漂移不抛异常', () {
      final empty = UploadInitiateResponse.fromJson(const {});
      expect(empty.fileId, '');
      expect(empty.uploadMode, '');
      expect(empty.thresholdBytes, 0);
      expect(empty.method, '');
      expect(empty.uploadUrl, isNull);
      expect(empty.expiresInSeconds, isNull);

      final drifted = UploadInitiateResponse.fromJson(const {
        'file_id': 123, // 应为 String
        'threshold_bytes': '64', // 应为 num
        'expires_in': '600', // 应为 num
      });
      expect(drifted.fileId, '');
      expect(drifted.thresholdBytes, 0);
      expect(drifted.expiresInSeconds, isNull);
    });
  });

  group('P0-A/B ModInfo 兜底构造', () {
    test('orElse 形态构造可用且 displayName 回退目录名', () {
      // mods_page._publishWorkshop 的兜底分支即此形态（缺 cfgFiles 等 3 个
      // required 参数会导致编译失败）。
      final m = ModInfo(
        name: '123456',
        root: '',
        cfgFiles: const [],
        hasManifest: false,
        manifestTitle: '',
      );
      expect(m.displayName, '123456');
    });
  });

  group('P2-I1/I2 控制器', () {
    tearDown(() => ApiClient.instance.client = http.Client());

    test('改回原值后 dirtyDeep=false（dirty 快速预判仍为 true）', () async {
      ApiClient.instance.client = MockClient((req) async => _json({
            'data': {
              '1': {'id': 1, 'name': 'old'},
            },
            'mtime_ns': 10,
          }));
      final c = WorkbenchController(cfgs: ['A']);
      await c.load();
      final t = c.table('A');

      t.data['1']['name'] = 'new';
      expect(c.dirty, isTrue);
      expect(c.dirtyDeep, isTrue);

      // 改回原值：版本号已推进（dirty 仍 true），但内容 == 快照。
      t.data['1']['name'] = 'old';
      expect(t.dirty, isTrue, reason: '版本号预判仍是脏（O(1) 快路径）');
      expect(c.dirtyDeep, isFalse, reason: '深比较应判定为「未修改」');
      expect(c.table('A').checkDirtyDeep(), isFalse);
    });

    test('load() 并发触发：旧响应不得覆盖新响应', () async {
      final firstStarted = Completer<void>();
      final gate = Completer<void>();
      var calls = 0;
      ApiClient.instance.client = MockClient((req) async {
        calls++;
        if (calls == 1) {
          firstStarted.complete();
          await gate.future; // 挂住第一次响应，让第二次 load 先落地
          return _json({
            'data': {'v': 'OLD'},
            'mtime_ns': 1,
          });
        }
        return _json({
          'data': {'v': 'NEW'},
          'mtime_ns': 2,
        });
      });

      final c = WorkbenchController(cfgs: ['A']);
      final f1 = c.load();
      await firstStarted.future; // 确保首次请求已进入 mock（已被挂起）
      final f2 = c.load();
      await f2;
      expect(c.table('A').data['v'], 'NEW');

      gate.complete();
      await f1;
      expect(c.table('A').data['v'], 'NEW',
          reason: '被更新的 load 取代后，旧响应必须整段丢弃');
      expect(c.loading, isFalse);
    });
  });

  group('§5.1-1 排序缓存失效', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    testWidgets('新增角色后左栏列表即时出现新行（缓存不得陈旧）', (tester) async {
      ApiClient.instance.client = MockClient((req) async {
        final path = req.url.path;
        if (path.startsWith('/api/cfg/')) {
          final cfg = path.substring('/api/cfg/'.length);
          Map<String, dynamic> data;
          if (cfg == 'PersonCfg') {
            data = {
              '10': {'id': 10, 'name': '甲', 'gender': 1},
              '20': {'id': 20, 'name': '乙', 'gender': 1},
            };
          } else if (cfg == 'ModFaceCfg') {
            data = {};
          } else {
            data = {
              '10': {'id': 10},
            };
          }
          return _json({'data': data, 'exists': true, 'mtime_ns': 1});
        }
        if (path == '/api/roles') {
          return _json({
            'roles': [
              {'id': '10', 'name': '甲'},
            ],
          });
        }
        return _json({'data': {}});
      });

      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(() => ApiClient.instance.client = http.Client());

      await tester.pumpWidget(
        fluent.FluentApp(
          debugShowCheckedModeBanner: false,
          home: PersonWorkbench(state: AppState()..modName = '测试模组'),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('甲'), findsWidgets);
      expect(find.text('乙'), findsWidgets);

      // 新增角色：排序结果缓存的失效点若遗漏，这里就看不到新行。
      await tester.tap(find.text('＋ 添加角色'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('未命名人物'), findsWidgets,
          reason: '新增行必须立刻出现在列表（排序缓存需按表版本号失效）');
      expect(tester.takeException(), isNull);
    });
  });
}
