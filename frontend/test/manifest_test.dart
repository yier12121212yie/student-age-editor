// manifest API 验证：连真实后端（127.0.0.1:8765）。
import 'package:flutter_test/flutter_test.dart';
import 'package:student_age_editor/core/api_client.dart';

void main() {
  setUpAll(() {
    ApiClient.instance.baseUrl = 'http://127.0.0.1:8765';
  });

  test('manifest/status 返回检查项', () async {
    final r = await ApiClient.instance.get('/api/manifest/status');
    expect(r['selected'], isA<bool>());
    expect(r['checks'], isA<List>());
    if (r['selected'] == true && r['has_manifest'] == true) {
      expect(r['manifest'], isA<Map>());
    }
  });
}
