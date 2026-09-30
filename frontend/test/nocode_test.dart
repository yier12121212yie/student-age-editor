// 无代码模式的纯函数：代码模板拼装、字典池解析、后端 JSON 反序列化。
import 'package:flutter_test/flutter_test.dart';

import 'package:student_age_editor/features/editor/suggestion_text_field.dart';
import 'package:student_age_editor/features/nocode/effect_slot_form.dart';
import 'package:student_age_editor/features/nocode/role_picker.dart';

const _attrSlot =
    SuggestionSlot(kind: 'dict', name: 'ATTR', dict: 'ATTR', label: '属性');
const _vSlot = SuggestionSlot(kind: 'number', name: 'V', label: '数值');

void main() {
  group('assembleEffectCode', () {
    test('dict 槽替换 @NAME@ 占位符，number 槽替换裸字母', () {
      final code = assembleEffectCode(
        '[1,1,@ATTR@,V]',
        const [_attrSlot, _vSlot],
        {'ATTR': '7', 'V': '3'},
      );
      expect(code, '[1,1,7,3]');
    });

    test('同字母槽的所有出现共享同一值', () {
      final code = assembleEffectCode(
        '[4001,V,0,V]',
        const [_vSlot],
        {'V': '0.5'},
      );
      expect(code, '[4001,0.5,0,0.5]');
    });

    test('裸字母替换不吃掉单词内字母与数字串', () {
      // 'AVG' 里的 V 前面是字母 A → 不是独立数值槽；'1001' 不受 N/S 影响。
      final code = assembleEffectCode(
        '[N,1001,0,S,VG]',
        const [
          SuggestionSlot(kind: 'number', name: 'N'),
          SuggestionSlot(kind: 'number', name: 'S'),
          SuggestionSlot(kind: 'number', name: 'V'),
        ],
        {'N': '2', 'S': '9', 'V': '3'},
      );
      expect(code, '[2,1001,0,9,VG]');
    });

    test('缺值的槽保留原文本，不产出坏码', () {
      expect(
        assembleEffectCode('[1,1,@ATTR@,V]', const [_attrSlot, _vSlot], {'V': '3'}),
        '[1,1,@ATTR@,3]',
      );
      expect(
        assembleEffectCode('[1,1,@ATTR@,V]', const [_attrSlot, _vSlot], {}),
        '[1,1,@ATTR@,V]',
      );
    });
  });

  group('assembleEffectDesc', () {
    test('中文预览用显示名（下拉选中名称而非裸 ID）', () {
      final desc = assembleEffectDesc(
        '将@ATTR@增加V点',
        const [_attrSlot, _vSlot],
        {'ATTR': '7', 'V': '3'},
        {'ATTR': '魅力'},
      );
      expect(desc, '将魅力增加3点');
    });
  });

  group('slotDictEntries', () {
    final dicts = <String, dynamic>{
      'attrs': {'1': '智力', '7': '魅力'},
    };

    test('池名大小写不敏感映射到 game_dicts 键', () {
      expect(slotDictEntries(_attrSlot, dicts), {'1': '智力', '7': '魅力'});
      const lower = SuggestionSlot(kind: 'dict', name: 'ATTR', dict: 'attr');
      expect(slotDictEntries(lower, dicts), isNotNull);
    });

    test('未知池 / 字典缺失 / number 槽 → null（表单退化为手输）', () {
      const unknown = SuggestionSlot(kind: 'dict', name: 'FOO', dict: 'FOO');
      expect(slotDictEntries(unknown, dicts), isNull);
      const noData = SuggestionSlot(kind: 'dict', name: 'ITEM', dict: 'ITEM');
      expect(slotDictEntries(noData, dicts), isNull);
      expect(slotDictEntries(_vSlot, dicts), isNull);
    });
  });

  group('后端 JSON 反序列化', () {
    test('SuggestionSlot.fromJson 缺字段回落默认值', () {
      final s = SuggestionSlot.fromJson(const {});
      expect(s.kind, 'number');
      expect(s.name, '');
      expect(s.dict, '');
      expect(s.count, 1);
    });

    test('SuggestionSlot.fromJson 全字段', () {
      final s = SuggestionSlot.fromJson(const {
        'kind': 'dict',
        'name': 'ATTR',
        'dict': 'ATTR',
        'label': '属性',
        'count': 2,
      });
      expect(s.kind, 'dict');
      expect(s.name, 'ATTR');
      expect(s.count, 2);
    });

    test('RoleEntry.fromJson 容忍缺字段与字符串 id', () {
      final r = RoleEntry.fromJson(const {'id': 10, 'name': '林晓'});
      expect(r.id, '10');
      expect(r.name, '林晓');
      expect(r.gender, isNull);
      expect(r.portrait, '');
      final f = RoleEntry.fromJson(const {
        'id': '-1',
        'gender': 2,
        'portrait': 'role_girl_01',
      });
      expect(f.gender, 2);
      expect(f.portrait, 'role_girl_01');
    });
  });
}
