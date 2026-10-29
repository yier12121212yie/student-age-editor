// P1 回归：大响应判定与 isolate 解码入口。
//
// 不在单测里真的启动 isolate：flutter_tester 在部分环境会因残留 isolate
// 无法退出（测试本身已 All tests passed，但进程不结束）。这里验证两段
// 纯逻辑：阈值判定 + isolate 内使用的解码函数（同一实现）。
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:student_age_editor/core/api_client.dart';

void main() {
  tearDown(() {
    ApiClient.bigIsolateThreshold = 2 * 1024 * 1024;
  });

  test('阈值判定：超过阈值才 offload', () {
    ApiClient.bigIsolateThreshold = 1024;
    expect(ApiClient.shouldOffloadForTest(1024), isFalse);
    expect(ApiClient.shouldOffloadForTest(1025), isTrue);
    ApiClient.bigIsolateThreshold = 2 * 1024 * 1024;
    expect(ApiClient.shouldOffloadForTest(3 * 1024 * 1024), isTrue);
  });

  test('isolate 解码入口保留完整 JSON 结构', () {
    final bytes = Uint8List.fromList(utf8.encode(jsonEncode({
      'cfg': 'BigCfg',
      'data': {
        '1': {'id': 1, 'name': 'ok'},
      },
      'blob': 'x' * 4096,
    })));
    final out = ApiClient.decodeAnyForTest(bytes);
    expect(out['ok'], isTrue);
    final payload = out['data'] as Map;
    expect(payload['cfg'], 'BigCfg');
    expect(payload['data']['1']['name'], 'ok');
    expect((payload['blob'] as String).length, 4096);
  });

  test('非法 JSON 走失败信封而不是在 isolate 里抛出', () {
    final out = ApiClient.decodeAnyForTest(
      Uint8List.fromList(utf8.encode('{not json')),
    );
    expect(out['ok'], isFalse);
    expect(out['error'], isNotNull);
  });
}
