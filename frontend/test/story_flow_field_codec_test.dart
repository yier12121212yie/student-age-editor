// 剧情图字段编解码回归：类型驱动读写，解析不动就必须「拒写而不是清空」。
//
// 本文件锁的三条底线（任意一条破功都是存档级事故）：
//   1. encode/decode 互为逆运算：内联编辑框里显示什么文本，回填后就得到什么值；
//   2. 半截输入（数字打到 `-`、JSON 打到 `[[1,2`）→ ok=false 且记录**原封不动**，
//      旧实现 `default: rec[field] = text` 会把 bg 当场删掉再落盘；
//   3. 只有 schema 里存在且非主键的字段才允许写回，插件扩表带来的未知类型一律拒写。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:student_age_editor/features/story/story_flow_field_codec.dart';

/// 与后端 game_schema.py 的 TalkCfg / EvtCfg 保持一致（四种类型 + id 主键）。
///
/// 末尾两个 `autoXxx` 字段模拟「schema 刚新增的列」：下面的往返用例按
/// `gameSchema[cfg]` 的键遍历，新增字段会自动进入覆盖范围，不需要改测试。
const Map<String, dynamic> _schema = <String, dynamic>{
  'TalkCfg': <String, dynamic>{
    'id': 'Number',
    'bg': 'Number',
    'audio': 'Number',
    'time': 'Number',
    'content': 'String',
    'roleName': 'String',
    'showTxt': 'String',
    'nextTalk': '1D Array',
    'roleIds': '1D Array',
    'screenEffect': '1D Array',
    'check': '2D Array',
    'effect': '2D Array',
    'roles': '2D Array',
    'autoNewNumber': 'Number',
    'autoNewString': 'String',
    'autoNewFlat': '1D Array',
    'autoNewMatrix': '2D Array',
  },
  'EvtCfg': <String, dynamic>{
    'id': 'Number',
    'title': 'String',
    'type': 'Number',
    'talkId': '1D Array',
    'effect': '2D Array',
    'condition': '2D Array',
    'weight': 'Number',
  },
};

/// 每种类型的全自动样本：schema 里没在 [_samples] 中登记的键用它兜底，
/// 这样「新加一列」也会被自动往返一次，而不是静默漏测。
const Map<String, dynamic> _typeDefaults = <String, dynamic>{
  'Number': 42,
  'String': '自动样本',
  '1D Array': <dynamic>[7, 8],
  '2D Array': <dynamic>[
    [7, 8],
    <dynamic>[9],
  ],
};

/// 更贴近真实存档的样本（按 `cfg.field` 登记）。
const Map<String, dynamic> _samples = <String, dynamic>{
  'TalkCfg.id': 1000001000,
  'TalkCfg.bg': -1,
  'TalkCfg.audio': 0,
  'TalkCfg.time': 1500,
  'TalkCfg.content': '你好，世界',
  'TalkCfg.roleName': '学长',
  'TalkCfg.showTxt': '选择：留下',
  'TalkCfg.nextTalk': <dynamic>[1000001000, 1000001001],
  'TalkCfg.roleIds': <dynamic>[101],
  'TalkCfg.screenEffect': <dynamic>[4015],
  'TalkCfg.check': <dynamic>[
    [10001, 1],
    [10002, 0, 5],
  ],
  'TalkCfg.effect': <dynamic>[
    [3, 10],
    <dynamic>[],
  ],
  'TalkCfg.roles': <dynamic>[
    [1001, '甲'],
    [1002, '乙'],
  ],
  'EvtCfg.id': 1000001,
  'EvtCfg.title': '校门口',
  'EvtCfg.type': 3,
  'EvtCfg.talkId': <dynamic>[1000001000],
  'EvtCfg.effect': <dynamic>[
    [10001, 10],
  ],
  'EvtCfg.condition': <dynamic>[
    [20001, 0],
    [20002, 1],
  ],
  'EvtCfg.weight': 100,
};

dynamic _valueOf(String cfg, String field, String type) {
  final explicit = _samples['$cfg.$field'];
  if (explicit != null) return explicit;
  final fallback = _typeDefaults[type];
  expect(
    fallback,
    isNotNull,
    reason: '$cfg.$field 的类型「$type」不在测试的类型样本表里，请补充',
  );
  return fallback;
}

/// 往返一次：记录值 → 文本 → 记录值，要求值恒等且 applyFieldText 不改变记录。
void _expectRoundTrip(String cfg, String field, String type) {
  final original = _valueOf(cfg, field, type);
  final rec = <String, dynamic>{field: original};

  final text = encodeFieldValue(rec, field, type);
  expect(text, isNotEmpty, reason: '$cfg.$field 的展示文本不应为空');

  final back = decodeFieldValue(text, type);
  expect(back.ok, isTrue, reason: '$cfg.$field 自产自销必须可解析：$text');
  expect(back.cleared, isFalse, reason: '$cfg.$field 非空文本不得被判成清空');
  expect(
    back.value,
    equals(original),
    reason: '$cfg.$field($type) 往返后值应恒等，文本「$text」',
  );

  // 往返写回记录后，内容仍应与原始值恒等（而不是被原地改掉）。
  final target = <String, dynamic>{field: original};
  expect(applyFieldText(target, field, type, text), isTrue);
  expect(target[field], equals(original));
  expect(target.containsKey(field), isTrue);
}

void main() {
  group('2D Array', () {
    test('JSON 写法与分隔符写法解析等价', () {
      final json = decodeFieldValue('[[1,2],[3,4]]', '2D Array');
      final sep = decodeFieldValue('1,2;3,4', '2D Array');
      expect(json.ok, isTrue);
      expect(sep.ok, isTrue);
      expect(
        json.value,
        sep.value,
        reason: '指南写 `1,2;3,4`，内联编辑器显示 JSON，两者必须是同一个值',
      );
      expect(json.value, <dynamic>[
        <dynamic>[1, 2],
        <dynamic>[3, 4],
      ]);
    });

    test('半截 JSON `[[1,2` 拒写，且 applyFieldText 不得动记录', () {
      final r = decodeFieldValue('[[1,2', '2D Array');
      expect(r.ok, isFalse, reason: '方括号开头却解不动 = 用户还在打，不能猜');
      expect(r.cleared, isFalse);
      expect(r.value, isNull);

      final rec = <String, dynamic>{
        'effect': <dynamic>[
          <dynamic>[10001, 1],
        ],
      };
      final snapshot = jsonEncode(rec);
      expect(applyFieldText(rec, 'effect', '2D Array', '[[1,2'), isFalse);
      expect(
        jsonEncode(rec),
        snapshot,
        reason: '解析失败时记录必须原封不动（旧实现会退化成垃圾行）',
      );
    });

    test('空文本判为清空：applyFieldText 移除该键', () {
      final rec = <String, dynamic>{'effect': <dynamic>[]};
      expect(applyFieldText(rec, 'effect', '2D Array', ''), isTrue);
      expect(rec.containsKey('effect'), isFalse);
    });

    test('带字符串单元格的 2D 也走 JSON 往返', () {
      const value = <dynamic>[
        <dynamic>[1001, '甲'],
      ];
      final text = encodeFieldValue(<String, dynamic>{'roles': value}, 'roles', '2D Array');
      expect(text, '[[1001,"甲"]]');
      expect(decodeFieldValue(text, '2D Array').value, value);
    });
  });

  group('Number：手滑半个符号不得吃掉已有值', () {
    test('空文本 = cleared', () {
      final r = decodeFieldValue('', 'Number');
      expect(r.ok, isTrue);
      expect(r.cleared, isTrue);
    });

    test('`-` 解析失败 → ok=false 且原值存活（本文件存在的理由）', () {
      final r = decodeFieldValue('-', 'Number');
      expect(r.ok, isFalse, reason: '正在打负号不是想清空 bg');
      expect(r.cleared, isFalse);

      final rec = <String, dynamic>{'bg': -1};
      expect(applyFieldText(rec, 'bg', 'Number', '-'), isFalse);
      expect(rec.containsKey('bg'), isTrue, reason: '记录被改 = 存档里 bg 当场消失');
      expect(rec['bg'], -1);

      // 同一条路径覆盖「只有空格」以外的半截输入。
      for (final bad in <String>['-', '-', '.', '-.', '1-', 'abc']) {
        expect(decodeFieldValue(bad, 'Number').ok, isFalse, reason: '「$bad」不是数字');
      }
      expect(applyFieldText(rec, 'bg', 'Number', '.'), isFalse);
      expect(rec['bg'], -1);
    });

    test('`12` → 12', () {
      final r = decodeFieldValue('12', 'Number');
      expect(r.ok, isTrue);
      expect(r.value, 12);
      expect(r.value, isA<int>());
      expect(applyFieldText(<String, dynamic>{}, 'bg', 'Number', '12'), isTrue);
    });

    test('小数与千分位', () {
      expect(decodeFieldValue('0.5', 'Number').value, 0.5);
      expect(decodeFieldValue('-7', 'Number').value, -7);
      expect(decodeFieldValue('1,000', 'Number').value, 1000);
    });
  });

  group('String', () {
    test('非空原样保留，空白判为清空', () {
      expect(decodeFieldValue('甲 乙', 'String').value, '甲 乙');
      expect(decodeFieldValue('', 'String').cleared, isTrue);
      expect(decodeFieldValue('   ', 'String').cleared, isTrue);
    });
  });

  group('可写字段判定', () {
    test('id 主键不可写', () {
      expect(flowFieldWritable(_schema, 'TalkCfg', 'id'), isFalse);
      expect(cfgTypeOf(_schema, 'TalkCfg', 'id'), 'Number', reason: '类型仍要能查到（只读展示）');
    });

    test('schema 里没有的字段不可写', () {
      expect(flowFieldWritable(_schema, 'TalkCfg', 'notInSchema'), isFalse);
      expect(cfgTypeOf(_schema, 'TalkCfg', 'notInSchema'), isNull);
    });

    test('整张表不存在 / 字段名为空都不放行', () {
      expect(flowFieldWritable(_schema, 'NopeCfg', 'bg'), isFalse);
      expect(cfgTypeOf(_schema, 'NopeCfg', 'bg'), isNull);
      expect(flowFieldWritable(_schema, 'TalkCfg', ''), isFalse);
    });

    test('插件扩表带来的非字符串类型一律拒写', () {
      final schema = <String, dynamic>{
        'TalkCfg': <String, dynamic>{
          'weird': <String, dynamic>{},
          'nil': null,
          'bg': 'Number',
        },
      };
      expect(flowFieldWritable(schema, 'TalkCfg', 'weird'), isFalse);
      expect(flowFieldWritable(schema, 'TalkCfg', 'nil'), isFalse);
      expect(flowFieldWritable(schema, 'TalkCfg', 'bg'), isTrue);
    });

    test('schema 内的普通字段放行', () {
      for (final field in <String>['bg', 'content', 'effect', 'nextTalk']) {
        expect(flowFieldWritable(_schema, 'TalkCfg', field), isTrue, reason: field);
      }
    });
  });

  group('未知类型', () {
    test('decode 拒写，encode 兜底成可读文本', () {
      expect(decodeFieldValue('12', null).ok, isFalse);
      expect(decodeFieldValue('12', 'Dictionary').ok, isFalse);
      final rec = <String, dynamic>{'x': 12};
      expect(applyFieldText(rec, 'x', 'Dictionary', '13'), isFalse);
      expect(rec['x'], 12);
      expect(encodeFieldValue(rec, 'x', 'Dictionary'), '12');
      expect(encodeFieldValue(rec, 'missing', 'Number'), '');
    });
  });

  group('表驱动往返：gameSchema[cfg] 的每个键都自动覆盖', () {
    test('Number / String / 2D Array 值恒等', () {
      var covered = 0;
      _schema.forEach((cfg, table) {
        (table as Map<String, dynamic>).forEach((field, type) {
          if (type == '1D Array') return; // 1D 见下面 KNOWN BUG 用例（同一张表驱动）
          covered++;
          _expectRoundTrip(cfg, field, type as String);
        });
      });
      expect(covered, greaterThan(10), reason: '遍历不应为空转');
    });

    test('1D Array 单元素往返一致', () {
      var covered = 0;
      _schema.forEach((cfg, table) {
        (table as Map<String, dynamic>).forEach((field, type) {
          if (type != '1D Array') return;
          final value = _valueOf(cfg, field, '1D Array');
          if ((value as List).length > 1) return;
          covered++;
          _expectRoundTrip(cfg, field, '1D Array');
        });
      });
      expect(covered, greaterThan(0), reason: '至少要有一个单元素 1D 样本');
    });
  });

  test('1D 多元素 encode→decode 往返丢结构', () {
    // encode 明确用 `, ` 连接（与指南 `4015,0.5` 写法一致），decode 却把整段
    // 文本当成一个元素：normalizeStoryIdList 对 String 入参不拆分隔符。
    // 后果有两层：往返不闭合；用户在框里敲 `1000001000,1000001001` 按回车，
    // 存档里会写成 `["1000001000,1000001001"]` —— 游戏侧永远找不到这个跳转目标。
    var checked = 0;
    _schema.forEach((cfg, table) {
      (table as Map<String, dynamic>).forEach((field, type) {
        if (type != '1D Array') return;
        final value = _valueOf(cfg, field, '1D Array');
        if ((value as List).length < 2) return;
        checked++;
        final text = encodeFieldValue(<String, dynamic>{field: value}, field, '1D Array');
        expect(text, contains(','), reason: '$cfg.$field 多值应渲染成逗号文本');
        final back = decodeFieldValue(text, '1D Array');
        expect(back.ok, isTrue);
        expect(
          back.value,
          equals(value),
          reason: '$cfg.$field(1D Array) 往返后值应恒等，文本「$text」实得 ${back.value}',
        );
      });
    });
    expect(checked, greaterThan(0), reason: '样本表里必须有多元素 1D 字段');
  });

  test('1D 用户手敲的分隔文本应拆成多个 ID', () {
    final r = decodeFieldValue('4015,0.5', '1D Array');
    expect(r.ok, isTrue);
    expect(
      r.value,
      <dynamic>[4015, 0.5],
      reason: '指南写法 `4015,0.5` 是一条效果的两个参数，不是一个大字符串；'
          '时长必须留在数值型，落成 "0.5" 同样是脏存档',
    );
  });

  test('1D 非数字文本仍按代码原样保留（这是有意为之，不是 bug）', () {
    final r = decodeFieldValue('abc', '1D Array');
    expect(r.ok, isTrue);
    expect(r.value, <dynamic>['abc']);
    expect(decodeFieldValue('', '1D Array').cleared, isTrue);
  });
}
