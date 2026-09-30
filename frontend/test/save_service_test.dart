// save_service 单测（阶段 2d：此前零覆盖）。用 MockClient 注入
// ApiClient.client，纯离线覆盖：revision 携带/采用（双表假冲突回归）、
// 409 冲突信封解析（body 结构化 / 非 JSON 容错）、非-utf8 409 不误判、
// deleteRecord 成功采用指纹与失败向上抛。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:student_age_editor/core/api_client.dart';
import 'package:student_age_editor/core/save_service.dart';

void main() {
  final svc = SaveService.instance;
  late List<http.Request> reqs;
  late http.Response Function(http.Request req) handler;

  http.Response json(int status, Map<String, dynamic> body) =>
      http.Response(jsonEncode(body), status,
          headers: {'content-type': 'application/json'});

  setUp(() {
    reqs = [];
    svc.invalidateCache();
    ApiClient.instance.baseUrl = 'http://127.0.0.1:9';
    ApiClient.instance.client = MockClient((req) async {
      reqs.add(req);
      return handler(req);
    });
  });

  tearDown(() {
    ApiClient.instance.client = http.Client();
  });

  Map<String, dynamic> bodyOf(http.Request req) =>
      jsonDecode(req.body) as Map<String, dynamic>;

  test('refreshRevision 拉取并缓存指纹', () async {
    handler = (req) => json(200, {'revision': 'R1', 'computed_at_ms': 3});
    await svc.refreshRevision();
    expect(svc.currentRevision, 'R1');
  });

  test('saveTable 携带缓存 revision，成功后采用响应新指纹（双表假冲突回归）', () async {
    handler = (req) => json(200, {'revision': 'R1111111'});
    await svc.refreshRevision();
    handler = (req) => json(200, {
          'ok': true,
          'cfg': 'TalkCfg',
          'mtime_ns': 111,
          'revision': 'R2222222',
        });
    final r = await svc.saveTable(cfgName: 'TalkCfg', data: {'1': {'id': '1'}});
    expect(r.isSuccess, isTrue);
    expect(bodyOf(reqs.last)['revision'], 'R1111111',
        reason: 'PUT 应携带批次开始时的指纹');
    expect(svc.currentRevision, 'R2222222',
        reason: '写成功后必须采用后端回传的新指纹');
    // 同批第二张表：携带的必须是 R2，而不是必然被 verify 拒绝的 R1。
    handler = (req) =>
        json(200, {'ok': true, 'cfg': 'EvtCfg', 'revision': 'R3333333'});
    final r2 = await svc.saveTable(cfgName: 'EvtCfg', data: {});
    expect(r2.isSuccess, isTrue);
    expect(bodyOf(reqs.last)['revision'], 'R2222222');
    expect(svc.currentRevision, 'R3333333');
  });

  test('applyPatch 同样采用响应指纹', () async {
    handler = (req) => json(200, {'ok': true, 'cfg': 'TalkCfg', 'revision': 'P2'});
    final r = await svc.applyPatch(
        cfgName: 'TalkCfg', patchSet: {'1': {'id': '1'}}, patchRemove: const []);
    expect(r.isSuccess, isTrue);
    expect(bodyOf(reqs.first).containsKey('patch'), isTrue);
    expect(svc.currentRevision, 'P2');
  });

  test('409 冲突信封：结构化字段全部透传给上层（旧判定永假回归）', () async {
    handler = (req) => json(409, {
          'error': 'conflict',
          'cfg': 'TalkCfg',
          'reason': 'rows',
          'conflicting_keys': ['7'],
          'current_revision': 'R9',
          'mtime_ns': 123,
        });
    final r = await svc.saveTable(cfgName: 'TalkCfg', data: {});
    expect(r.isConflict, isTrue, reason: 'e.code 从未存在过，旧判定把冲突全掉进 error');
    expect(r.reason, 'rows');
    expect(r.currentRevision, 'R9');
    expect(r.mtimeNs, 123);
  });

  test('409 错误体非 JSON：容错降级为冲突，不抛 FormatException', () async {
    var put = true;
    handler = (req) {
      if (req.method == 'PUT') {
        return http.Response('upstream said: conflict (current_revision lost)', 409);
      }
      // _conflictResult 的补拉指纹
      put = false;
      return json(200, {'revision': 'R5'});
    };
    final r = await svc.saveTable(cfgName: 'TalkCfg', data: {});
    expect(r.isConflict, isTrue);
    expect(r.currentRevision, 'R5');
    expect(put, isFalse);
  });

  test('非-utf8 源的 409 是错误不是冲突', () async {
    handler = (req) => json(409, {
          'error': 'non-utf8-source',
          'cfg': 'TalkCfg',
          'detail': '源文件不是合法 UTF-8',
        });
    final r = await svc.saveTable(cfgName: 'TalkCfg', data: {});
    expect(r.isError, isTrue);
    expect(r.isConflict, isFalse);
  });

  test('deleteRecord 成功采用指纹', () async {
    handler = (req) => json(200, {
          'ok': true,
          'cfg': 'TalkCfg',
          'id': '3',
          'tombstone_created': true,
          'replacement_ids': [],
          'revision': 'D2',
        });
    final ok = await svc.deleteRecord(cfgName: 'TalkCfg', id: '3');
    expect(ok, isTrue);
    expect(svc.currentRevision, 'D2');
  });

  test('deleteRecord 失败向上抛（不再静默 false）', () async {
    handler = (req) => json(500, {'error': '删除失败'});
    await expectLater(
      svc.deleteRecord(cfgName: 'TalkCfg', id: '3'),
      throwsA(isA<ApiException>()),
    );
  });
}
