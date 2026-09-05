// manifest API 验证：连真实后端（127.0.0.1:8765）。
// 后端未启动时优雅跳过（S7，与 backend_integration_test 同一策略）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:student_age_editor/core/api_client.dart';

bool _backendUp = false;

void main() {
  setUpAll(() async {
    ApiClient.instance.baseUrl = 'http://127.0.0.1:8765';
    try {
      final socket = await Socket.connect('127.0.0.1', 8765,
          timeout: const Duration(milliseconds: 300));
      socket.destroy();
      _backendUp = true;
    } catch (_) {
      _backendUp = false;
    }
  });

  test('manifest/status 返回检查项', () async {
    // markTestSkipped 只打标不中断，必须立即 return
    if (!_backendUp) {
      markTestSkipped('后端未启动（127.0.0.1:8765），跳过集成用例');
      return;
    }
    final r = await ApiClient.instance.get('/api/manifest/status');
    expect(r['selected'], isA<bool>());
    expect(r['checks'], isA<List>());
    if (r['selected'] == true && r['has_manifest'] == true) {
      expect(r['manifest'], isA<Map>());
    }
  });
}
