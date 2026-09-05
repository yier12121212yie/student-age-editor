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

  group('needsResync（didUpdateWidget 回写前判断，保护半截输入与光标）', () {
    test('1D Array 半截输入 "1," 与 [1] 等价 → 不回写', () {
      expect(ValueCodec.needsResync('1,', [1], '1D Array'), isFalse);
    });

    test('1D Array 空文本与 [5] 不等价 → 需要回写', () {
      expect(ValueCodec.needsResync('', [5], '1D Array'), isTrue);
    });

    test('Number "5" 与 5 等价 → 不回写', () {
      expect(ValueCodec.needsResync('5', 5, 'Number'), isFalse);
    });

    test('Number 空文本与 0 等价 → 不回写（允许清空输入）', () {
      expect(ValueCodec.needsResync('', 0, 'Number'), isFalse);
    });

    test('数值允许 int/double 相等', () {
      expect(ValueCodec.needsResync('1', 1.0, 'Number'), isFalse);
      expect(ValueCodec.needsResync('1.0', [1], '1D Array'), isFalse);
    });

    test('外部改值时仍需回写（"2" vs [1] 不等价）', () {
      expect(ValueCodec.needsResync('2', [1], '1D Array'), isTrue);
    });

    test('2D Array 多行文本等价判断', () {
      expect(ValueCodec.needsResync('1, 2; 3', [
        [1, 2],
        [3],
      ], '2D Array'), isFalse);
      expect(ValueCodec.needsResync('1, 2', [
        [1, 2],
        [3],
      ], '2D Array'), isTrue);
    });

    test('String 空文本与空串等价', () {
      expect(ValueCodec.needsResync('', '', 'String'), isFalse);
      expect(ValueCodec.needsResync('abc', '', 'String'), isTrue);
    });
  });

  group('valueCodecNeedsResync（顶层入口，与 ValueCodec.needsResync 等价）', () {
    test('1D Array "1,2" 与 [1,2] 等价 → 不回写', () {
      expect(valueCodecNeedsResync('1,2', [1, 2], '1D Array'), isFalse);
    });

    test('文本与值的类型不匹配 → 需要回写', () {
      expect(valueCodecNeedsResync('abc', 5, 'Number'), isTrue);
      expect(valueCodecNeedsResync('', [5], '1D Array'), isTrue);
    });
  });
}
