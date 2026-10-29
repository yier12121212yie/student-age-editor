import 'package:flutter_test/flutter_test.dart';
import 'package:student_age_editor/core/pinyin_search.dart';

void main() {
  group('PinyinSearch Tests', () {
    test('Direct Chinese text match', () {
      expect(PinyinSearch.match('萧', '萧逸'), isTrue);
      expect(PinyinSearch.match('逸', '萧逸'), isTrue);
      expect(PinyinSearch.match('萧逸', '萧逸'), isTrue);
      expect(PinyinSearch.match('白', '萧逸'), isFalse);
    });

    test('Pinyin initials match', () {
      expect(PinyinSearch.match('xy', '萧逸'), isTrue);
      expect(PinyinSearch.match('x', '萧逸'), isTrue);
      expect(PinyinSearch.match('y', '萧逸'), isTrue);
      expect(PinyinSearch.match('by', '白雨'), isTrue);
      expect(PinyinSearch.match('sq', '苏青'), isTrue);
      expect(PinyinSearch.match('lw', '李王'), isTrue);
      expect(PinyinSearch.match('zz', '萧逸'), isFalse);
    });

    test('Full pinyin match', () {
      expect(PinyinSearch.match('xiaoyi', '萧逸'), isTrue);
      expect(PinyinSearch.match('xiao', '萧逸'), isTrue);
      expect(PinyinSearch.match('yi', '萧逸'), isTrue);
      expect(PinyinSearch.match('baiyu', '白雨'), isTrue);
      expect(PinyinSearch.match('suqing', '苏青'), isTrue);
      expect(PinyinSearch.match('zhangsan', '萧逸'), isFalse);
    });

    test('Filter helper', () {
      final list = ['萧逸', '白雨', '林晓', '苏青', '叶夏'];
      final resXY = PinyinSearch.filter(
        items: list,
        query: 'xy',
        label: (e) => e,
      );
      expect(resXY, equals(['萧逸']));

      final resXiao = PinyinSearch.filter(
        items: list,
        query: 'xiao',
        label: (e) => e,
      );
      expect(resXiao, containsAll(['萧逸', '林晓']));
    });
  });
}
