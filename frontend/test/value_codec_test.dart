// ValueCodec 编解码测试：2D/1D/Number/String 往返一致性。
import 'package:flutter_test/flutter_test.dart';
import 'package:student_age_editor/features/editor/field_utils.dart';

void main() {
  test('2D Array 编解码往返一致', () {
    const value = [
      [1, 2],
      [3, 4, 5],
    ];
    final text = ValueCodec.encode(value);
    expect(text, '1, 2; 3, 4, 5');
    final decoded = ValueCodec.decode(text, '2D Array');
    expect(decoded, value);
  });

  test('2D Array 空值', () {
    expect(ValueCodec.decode('', '2D Array'), <dynamic>[]);
  });

  test('1D Array 编解码', () {
    const value = [10, 20, 30];
    final text = ValueCodec.encode(value);
    expect(text, '10, 20, 30');
    expect(ValueCodec.decode(text, '1D Array'), value);
  });

  test('1D Array 支持中文分隔符与换行', () {
    expect(ValueCodec.decode('1，2\n3、4', '1D Array'), [1, 2, 3, 4]);
  });

  test('Number 空值返回 0（不再返回数组）', () {
    expect(ValueCodec.decode('', 'Number'), 0);
  });

  test('Number 千分位/中文逗号容错', () {
    expect(ValueCodec.decode('1,000', 'Number'), 1000);
  });

  test('String 原样往返', () {
    expect(ValueCodec.encode('你好 world'), '你好 world');
    expect(ValueCodec.decode('   ', 'String'), '');
  });
}
