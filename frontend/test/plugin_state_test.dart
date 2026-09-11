// PluginSummary.fromJson 容错回归：后端 or_raw 会原样透传 manifest 值，
// `"version": 2` 之类非字符串字段不能抛 TypeError（否则一个坏 manifest
// 会被 refresh 的 catch 吞掉并清空整个插件列表）。
import 'package:flutter_test/flutter_test.dart';
import 'package:student_age_editor/core/plugin_state.dart';

void main() {
  test('PluginSummary.fromJson 容忍非字符串字段', () {
    final p = PluginSummary.fromJson(<String, dynamic>{
      'id': 'demo',
      'name': 123, // 数字
      'version': 2, // 数字
      'author': true, // 布尔
      'description': null,
      'entry': {'a': 1}, // 对象
      'enabled': 1, // 非 true 字面量
      'loaded': true,
      'error': null,
      'risk_ack_at': 456,
    });
    expect(p.id, 'demo');
    expect(p.name, '123');
    expect(p.version, '2');
    expect(p.author, 'true');
    expect(p.description, '');
    expect(p.entry, '{a: 1}');
    expect(p.enabled, isFalse);
    expect(p.loaded, isTrue);
    expect(p.error, '');
    expect(p.riskAckAt, '456');
  });

  test('PluginSummary.fromJson 缺失字段全部降级为空', () {
    final p = PluginSummary.fromJson(<String, dynamic>{});
    expect(p.id, '');
    expect(p.name, '');
    expect(p.version, '');
    expect(p.enabled, isFalse);
    expect(p.loaded, isFalse);
    expect(p.riskAckAt, '');
  });
}
