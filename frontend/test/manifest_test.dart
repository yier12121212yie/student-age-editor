// manifest API 验证：连真实后端（127.0.0.1:8765）。
// 后端未启动时优雅跳过（S7，与 backend_integration_test 同一策略）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:student_age_editor/core/api_client.dart';
import 'package:student_age_editor/features/plugins/plugin_pane.dart'
    show buildPluginScopedUrl;

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

  // 阶段 1d：manifest actions/form 声明的 url 属外部输入，拼全后必须仍在
  // `/api/plugins/<id>/` 命名空间内（纯函数守卫用例，不依赖后端）。
  group('plugin url 命名空间守卫（buildPluginScopedUrl）', () {
    test('合法相对 url 拼入插件命名空间', () {
      expect(buildPluginScopedUrl('p1', 'do'), '/api/plugins/p1/do');
      expect(buildPluginScopedUrl('p1', '/do'), '/api/plugins/p1/do');
      expect(buildPluginScopedUrl('p1', 'sub/dir'), '/api/plugins/p1/sub/dir');
      // 中文/空格 id 被编码后前缀仍自洽。
      expect(buildPluginScopedUrl('中文 mod', 'x'),
          '/api/plugins/%E4%B8%AD%E6%96%87%20mod/x');
    });

    test('穿越命名空间的 `..` 声明一律拒绝', () {
      expect(() => buildPluginScopedUrl('p1', '../../mods/delete'),
          throwsStateError);
      expect(() => buildPluginScopedUrl('p1', 'a/../../b'), throwsStateError);
      expect(() => buildPluginScopedUrl('p1', '/../p1b/x'), throwsStateError);
      expect(() => buildPluginScopedUrl('p1', '../../../etc/passwd'),
          throwsStateError);
      // 前缀相近的其它插件命名空间同样算越界。
      expect(() => buildPluginScopedUrl('p1', '../p1admin/x'),
          throwsStateError);
    });
  });
}
