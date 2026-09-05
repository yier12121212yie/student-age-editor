/// 阶段 6「复制/粘贴子图」的数据层回归：ID 分配、引用重映射、剪断外链。
///
/// 全部是纯函数用例，不起 widget：粘贴的风险在 TalkCfg/OptionCfg 的主键上
/// （撞号会静默覆盖另一条剧情线），断言只看两张舞台表和返回的 旧→新 映射，
/// 不碰实现细节。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:student_age_editor/features/story/story_flow_clipboard.dart';
import 'package:student_age_editor/features/story/story_logic.dart';

const _prefixes = ['1000'];

/// 舞台上的第 N 句对白（前缀 1000 + 3 位序号）。
String _t(int n) => '1000${n.toString().padLeft(3, '0')}';

/// 舞台上的第 N 个选项（前缀 1000 + 2 位序号）。
String _o(int n) => '1000${n.toString().padLeft(2, '0')}';

Map<String, dynamic> _talk(
  String id, {
  dynamic next,
  dynamic next2,
  dynamic option,
}) => <String, dynamic>{
  'id': int.parse(id),
  'content': '对白 $id',
  'roleIds': <dynamic>[1],
  'nextTalk': ?next,
  'nextTalk2': ?next2,
  'option': ?option,
};

Map<String, dynamic> _opt(String id, {dynamic talkId, int nextEvt = 0}) =>
    <String, dynamic>{
      'id': int.parse(id),
      'content': '选项 $id',
      'talkId': ?talkId,
      'talkId2': <dynamic>[],
      'nextEvtId': nextEvt,
    };

void main() {
  group('选取范围', () {
    test('单选一句对白：新增一个 ID，原记录一字不改', () {
      final talks = <String, dynamic>{_t(1): _talk(_t(1))};
      final before = copyRecords(talks);
      final opts = <String, dynamic>{};

      final map = cloneSubgraphInto(
        selected: {_t(1)},
        talks: talks,
        opts: opts,
        prefixes: _prefixes,
      );

      expect(map, {_t(1): _t(2)}, reason: '1000001 已占用，新 ID 顺延到 1000002');
      expect(talks.keys, [_t(1), _t(2)]);
      expect(talks[_t(1)], before[_t(1)], reason: '原件必须原样留着');
      expect(opts, isEmpty, reason: '没有选项被选中');
    });

    test('只复制既在选中集又在舞台里的记录', () {
      final talks = <String, dynamic>{
        _t(1): _talk(_t(1), next: <dynamic>[int.parse(_t(2))]),
        _t(2): _talk(_t(2)),
      };
      final before = copyRecords(talks);

      final map = cloneSubgraphInto(
        // 选中里混了一个舞台上不存在的 ID（图上缺失节点）
        selected: {_t(1), _t(9), '  '},
        talks: talks,
        opts: <String, dynamic>{},
        prefixes: _prefixes,
      );

      expect(map.keys, [_t(1)]);
      expect(talks.length, 3, reason: '选内一条 → 只多一条副本');
      expect(talks.containsKey(_t(9)), isFalse, reason: '舞台上不存在的 ID 不能凭空造出来');
      expect(normalizeStoryIdList(talks[_t(1)]['nextTalk']), [
        int.parse(_t(2)),
      ], reason: '这条是原件，它的连线不该被动');
      expect(copyRecords(talks)[_t(2)], before[_t(2)], reason: '未选中节点不该被牵连');
    });

    test('空选中集：返回空映射且两张表零改动', () {
      final talks = <String, dynamic>{
        _t(1): _talk(
          _t(1),
          next: <dynamic>[int.parse(_t(2))],
          option: <dynamic>[int.parse(_o(1))],
        ),
      };
      final opts = <String, dynamic>{
        _o(1): _opt(_o(1), talkId: <dynamic>[int.parse(_t(1))]),
      };
      final talkBefore = copyRecords(talks);
      final optBefore = copyRecords(opts);

      expect(
        cloneSubgraphInto(
          selected: <String>{},
          talks: talks,
          opts: opts,
          prefixes: _prefixes,
        ),
        isEmpty,
      );
      expect(talks, talkBefore);
      expect(opts, optBefore);
    });

    test('记录值不是 Map 的脏行跳过，不产生副本', () {
      final talks = <String, dynamic>{_t(1): '脏数据', _t(2): _talk(_t(2))};

      final map = cloneSubgraphInto(
        selected: {_t(1), _t(2)},
        talks: talks,
        opts: <String, dynamic>{},
        prefixes: _prefixes,
      );

      expect(map.keys, [_t(2)]);
      expect(talks.length, 3);
    });
  });

  group('类型判定（前缀匹配，不按 ID 长度猜）', () {
    test('选项 ID 与对白 ID 形状可混淆时，两张表各认各的', () {
      // 1000001 按选项规则（去后 2 位 → 1000）也命中前缀：只能靠所在表 + 前缀规则判定
      final talks = <String, dynamic>{_t(1): _talk(_t(1))};
      final opts = <String, dynamic>{_o(1): _opt(_o(1))};

      final map = cloneSubgraphInto(
        selected: {_t(1), _o(1)},
        talks: talks,
        opts: opts,
        prefixes: _prefixes,
      );

      expect(map[_t(1)], _t(2));
      expect(map[_o(1)], _o(2));
      expect(talks.keys, [_t(1), _t(2)]);
      expect(opts.keys, [_o(1), _o(2)]);
      expect(talks.containsKey(_o(2)), isFalse, reason: '选项副本不该落进对白表');
      expect(opts.containsKey(_t(2)), isFalse);
    });

    test('挂错表的 ID 按前缀规则纠正：对白表里的选项 ID 不被当对白复制', () {
      final talks = <String, dynamic>{
        _t(1): _talk(_t(1)),
        _o(1): _opt(_o(1)), // 脏：选项 ID 出现在对白表里（1000 去后 3 位是 100，不属本事件）
      };
      final opts = <String, dynamic>{_o(1): _opt(_o(1))};
      final optBefore = opts[_o(1)];

      final map = cloneSubgraphInto(
        selected: {_o(1)},
        talks: talks,
        opts: opts,
        prefixes: _prefixes,
      );

      expect(map, {_o(1): _o(2)});
      expect(talks.length, 2, reason: '对白表不该多出副本');
      expect(opts.keys, [_o(1), _o(2)]);
      expect(opts[_o(1)], optBefore);
    });

    test('同一 ID 同时挂在两张表时以对白为准', () {
      final talks = <String, dynamic>{_t(1): _talk(_t(1))};
      final opts = <String, dynamic>{_t(1): _opt(_t(1))};

      final map = cloneSubgraphInto(
        selected: {_t(1)},
        talks: talks,
        opts: opts,
        prefixes: _prefixes,
      );

      expect(map.length, 1);
      expect(talks.length, 2);
      expect(opts.length, 1);
    });
  });

  group('新 ID 分配', () {
    test('批量克隆连续取号，本轮已分配的新 ID 也算占用', () {
      final talks = <String, dynamic>{
        _t(1): _talk(_t(1)),
        _t(2): _talk(_t(2)),
        _t(3): _talk(_t(3)),
      };

      final map = cloneSubgraphInto(
        selected: {_t(1), _t(2), _t(3)},
        talks: talks,
        opts: <String, dynamic>{},
        prefixes: _prefixes,
      );

      expect(map.values, [
        _t(4),
        _t(5),
        _t(6),
      ], reason: '舞台已用 001..003，且不许自我撞号');
      expect(map.values.toSet().length, 3);
    });

    test('选项编号从 {前缀}01 起跳过在用 ID', () {
      final opts = <String, dynamic>{_o(1): _opt(_o(1)), _o(2): _opt(_o(2))};
      // 只选选项：前缀从首个选中选项 ID 反推（去后 2 位）
      final map = cloneSubgraphInto(
        selected: {_o(2)},
        talks: <String, dynamic>{},
        opts: opts,
        prefixes: _prefixes,
      );

      expect(map, {_o(2): _o(3)});
      expect(opts.keys, [_o(1), _o(2), _o(3)]);
    });

    test('副本的 id 字段与主键同步换成新 ID', () {
      final talks = <String, dynamic>{_t(1): _talk(_t(1))};

      final map = cloneSubgraphInto(
        selected: {_t(1)},
        talks: talks,
        opts: <String, dynamic>{},
        prefixes: _prefixes,
      );

      final rec = talks[map[_t(1)]!] as Map<String, dynamic>;
      expect(rec['id'], int.parse(map[_t(1)]!), reason: '主键与 id 字段不一致会在存表时错位');
    });

    test('对白编号用尽会跨进下一事件时整体放弃，舞台零改动', () {
      final talks = <String, dynamic>{
        for (var i = 1; i <= 999; i++) _t(i): _talk(_t(i)),
      };
      final before = copyRecords(talks);

      final map = cloneSubgraphInto(
        selected: {_t(999)},
        talks: talks,
        opts: <String, dynamic>{},
        prefixes: _prefixes,
      );

      expect(map, isEmpty, reason: '1000999 的下一个是 1001000，前缀已变成 1001');
      expect(talks, before);
      expect(storyIsInPrefixes(_prefixes, '1001000'), isFalse);
    });

    test('选项 01..99 用尽时整体放弃，不留半份粘贴', () {
      final opts = <String, dynamic>{
        for (var i = 1; i <= 99; i++) _o(i): _opt(_o(i)),
      };
      final talks = <String, dynamic>{
        _t(1): _talk(_t(1), option: <dynamic>[int.parse(_o(1))]),
      };
      final optBefore = copyRecords(opts);
      final talkBefore = copyRecords(talks);

      final map = cloneSubgraphInto(
        selected: {_t(1), _o(1)},
        talks: talks,
        opts: opts,
        prefixes: _prefixes,
      );

      expect(map, isEmpty);
      expect(talks, talkBefore, reason: '对白副本单独落盘会变成没有选项的孤儿');
      expect(opts, optBefore);
    });

    test('舞台上写成 1000001.0 的脏 key 也算占用，不会被再分配', () {
      final opts = <String, dynamic>{
        '${_o(1)}.0': _opt(_o(1)),
        _o(2): _opt(_o(2)),
      };

      final map = cloneSubgraphInto(
        selected: {_o(2)},
        talks: <String, dynamic>{},
        opts: opts,
        prefixes: _prefixes,
      );

      expect(
        map[_o(2)],
        isNot(_o(1)),
        reason: 'allocOptionId 是精确串比对，used 必须先 cln 归一',
      );
      expect(cln(map[_o(2)]!), _o(3));
    });
  });

  group('引用重映射', () {
    test('对白与它的选项一起选中：副本互指新 ID', () {
      final talks = <String, dynamic>{
        _t(1): _talk(_t(1), option: <dynamic>[int.parse(_o(1))]),
      };
      final opts = <String, dynamic>{
        _o(1): _opt(_o(1), talkId: <dynamic>[int.parse(_t(1))]),
      };
      final talkBefore = copyRecords(talks);
      final optBefore = copyRecords(opts);

      final map = cloneSubgraphInto(
        selected: {_t(1), _o(1)},
        talks: talks,
        opts: opts,
        prefixes: _prefixes,
      );

      final newTalk = map[_t(1)]!;
      final newOpt = map[_o(1)]!;
      expect(newTalk, isNot(_t(1)));
      expect(newOpt, isNot(_o(1)));
      expect(normalizeStoryIdList((talks[newTalk] as Map)['option']), [
        int.parse(newOpt),
      ], reason: '副本对白必须指向副本选项');
      expect(normalizeStoryIdList((opts[newOpt] as Map)['talkId']), [
        int.parse(newTalk),
      ]);
      // 原件的连线维持原样
      expect(talks[_t(1)], talkBefore[_t(1)]);
      expect(opts[_o(1)], optBefore[_o(1)]);
    });

    test('nextTalk 目标未选中：副本里没有指向它的条目', () {
      final talks = <String, dynamic>{
        _t(1): _talk(_t(1), next: <dynamic>[int.parse(_t(2))]),
        _t(2): _talk(_t(2)),
      };

      final map = cloneSubgraphInto(
        selected: {_t(1)},
        talks: talks,
        opts: <String, dynamic>{},
        prefixes: _prefixes,
      );

      final copy = talks[map[_t(1)]!] as Map<String, dynamic>;
      expect(normalizeStoryIdList(copy['nextTalk']), isEmpty);
      expect(
        normalizeStoryIdList(copy['nextTalk']).map(cln),
        isNot(contains(_t(2))),
        reason: '粘贴不能给未选中节点接第二条入边',
      );
      expect(normalizeStoryIdList(talks[_t(1)]['nextTalk']), [
        int.parse(_t(2)),
      ]);
    });

    test('nextTalk2 / option 上的外链同样剪断，选内与选外混排时只留选内', () {
      final talks = <String, dynamic>{
        _t(1): _talk(
          _t(1),
          next: <dynamic>[int.parse(_t(2)), int.parse(_t(9))],
          next2: <dynamic>[int.parse(_t(9)), int.parse(_t(2))],
          option: <dynamic>[int.parse(_o(1))],
        ),
        _t(2): _talk(_t(2)),
        _t(9): _talk(_t(9)),
      };
      final opts = <String, dynamic>{
        _o(1): _opt(_o(1), talkId: <dynamic>[int.parse(_t(9))]),
        _o(2): _opt(_o(2)),
      };

      final map = cloneSubgraphInto(
        selected: {_t(1), _t(2), _o(1)},
        talks: talks,
        opts: opts,
        prefixes: _prefixes,
      );

      final copy = talks[map[_t(1)]!] as Map<String, dynamic>;
      expect(normalizeStoryIdList(copy['nextTalk']), [int.parse(map[_t(2)]!)]);
      expect(normalizeStoryIdList(copy['nextTalk2']), [
        int.parse(map[_t(2)]!),
      ], reason: '检定失败支同样只留选内目标');
      expect(normalizeStoryIdList(copy['option']), [
        int.parse(map[_o(1)]!),
      ], reason: '选内的选项照常带上');
      expect(
        normalizeStoryIdList((opts[map[_o(1)]!] as Map)['talkId']),
        isEmpty,
        reason: '选项指向未选中对白（1000009）→ 剪断',
      );
      expect(map.containsKey(_o(2)), isFalse, reason: '未选中的选项不该被复制');
      expect(opts.length, 3);
    });

    test('源里重复的目标在副本里只留一条边', () {
      final talks = <String, dynamic>{
        _t(1): _talk(_t(1), next: <dynamic>[int.parse(_t(2)), _t(2)]),
        _t(2): _talk(_t(2)),
      };

      final map = cloneSubgraphInto(
        selected: {_t(1), _t(2)},
        talks: talks,
        opts: <String, dynamic>{},
        prefixes: _prefixes,
      );

      expect(normalizeStoryIdList((talks[map[_t(1)]!] as Map)['nextTalk']), [
        int.parse(map[_t(2)]!),
      ]);
    });

    test('nextEvtId 是实义字段：跨事件跳转原样保留', () {
      final talks = <String, dynamic>{_t(1): _talk(_t(1))};
      final opts = <String, dynamic>{
        _o(1): _opt(_o(1), talkId: <dynamic>[int.parse(_t(1))], nextEvt: 2000),
        _o(2): _opt(_o(2), nextEvt: 0),
      };

      final map = cloneSubgraphInto(
        selected: {_o(1), _o(2)},
        talks: talks,
        opts: opts,
        prefixes: _prefixes,
      );

      expect((opts[map[_o(1)]!] as Map)['nextEvtId'], 2000);
      expect((opts[map[_o(2)]!] as Map)['nextEvtId'], 0);
      expect(
        normalizeStoryIdList((opts[map[_o(1)]!] as Map)['talkId']),
        isEmpty,
        reason: 'talkId 仍按选中集规则处理：1000001 未被选中 → 剪断',
      );
    });

    test('nextEvtId 写成字符串也不被归一化（verbatim）', () {
      final opts = <String, dynamic>{
        _o(1): <String, dynamic>{'id': int.parse(_o(1)), 'nextEvtId': '2000'},
      };

      final map = cloneSubgraphInto(
        selected: {_o(1)},
        talks: <String, dynamic>{},
        opts: opts,
        prefixes: _prefixes,
      );

      expect((opts[map[_o(1)]!] as Map)['nextEvtId'], '2000');
    });
  });

  group('副本独立性与职责边界', () {
    test('深拷贝：之后改原记录的嵌套列表不影响副本', () {
      final origin = _talk(_t(1), next: <dynamic>[int.parse(_t(2))]);
      origin['roleIds'] = <dynamic>[1, 2];
      origin['screenEffect'] = <dynamic>[
        <dynamic>[4015, 12],
      ];
      final talks = <String, dynamic>{origin['id'].toString(): origin};

      final map = cloneSubgraphInto(
        selected: {_t(1)},
        talks: talks,
        opts: <String, dynamic>{},
        prefixes: _prefixes,
      );
      final copy = talks[map[_t(1)]!] as Map<String, dynamic>;

      (origin['roleIds'] as List).add(99);
      ((origin['screenEffect'] as List).first as List)[1] = 77;
      origin['content'] = '改过了';

      expect(copy['roleIds'], [1, 2]);
      expect(copy['screenEffect'], [
        [4015, 12],
      ]);
      expect(copy['content'], '对白 ${_t(1)}');
    });

    test('坐标不归本函数：副本不新增任何位置字段', () {
      final talks = <String, dynamic>{_t(1): _talk(_t(1))};

      final map = cloneSubgraphInto(
        selected: {_t(1)},
        talks: talks,
        opts: <String, dynamic>{},
        prefixes: _prefixes,
      );

      final copy = talks[map[_t(1)]!] as Map<String, dynamic>;
      expect(copy.keys.toSet(), talks[_t(1)]!.keys.toSet());
      expect(
        copy.keys.where((k) => ['x', 'y', 'pos', 'position'].contains(k)),
        isEmpty,
      );
      expect(map[_t(1)], isNotNull, reason: '调用方拿这条映射去摆 _positions');
    });
  });

  group('端到端与重复粘贴', () {
    test('整条三节点链复制出三个互不相同的新 ID，链式关系保持', () {
      final talks = <String, dynamic>{
        _t(1): _talk(_t(1), next: <dynamic>[int.parse(_t(2))]),
        _t(2): _talk(_t(2), next: <dynamic>[int.parse(_t(3))]),
        _t(3): _talk(_t(3), next: <dynamic>[]),
      };

      final map = cloneSubgraphInto(
        selected: {_t(1), _t(2), _t(3)},
        talks: talks,
        opts: <String, dynamic>{},
        prefixes: _prefixes,
      );

      final ids = map.values.toSet();
      expect(ids.length, 3);
      expect(
        ids.intersection({_t(1), _t(2), _t(3)}),
        isEmpty,
        reason: '新 ID 复用原件号段会当场把原件吃掉',
      );
      expect(normalizeStoryIdList((talks[map[_t(1)]!] as Map)['nextTalk']), [
        int.parse(map[_t(2)]!),
      ]);
      expect(normalizeStoryIdList((talks[map[_t(2)]!] as Map)['nextTalk']), [
        int.parse(map[_t(3)]!),
      ]);
      expect(
        normalizeStoryIdList((talks[map[_t(3)]!] as Map)['nextTalk']),
        isEmpty,
      );
      expect(talks.length, 6);
    });

    test('连着粘两次：两次的新 ID 互不相交', () {
      final talks = <String, dynamic>{
        _t(1): _talk(
          _t(1),
          next: <dynamic>[int.parse(_t(2))],
          option: <dynamic>[int.parse(_o(1))],
        ),
        _t(2): _talk(_t(2)),
      };
      final opts = <String, dynamic>{
        _o(1): _opt(_o(1), talkId: <dynamic>[int.parse(_t(2))]),
      };
      final selected = {_t(1), _t(2), _o(1)};

      final first = cloneSubgraphInto(
        selected: selected,
        talks: talks,
        opts: opts,
        prefixes: _prefixes,
      );
      final second = cloneSubgraphInto(
        selected: selected,
        talks: talks,
        opts: opts,
        prefixes: _prefixes,
      );

      expect(first, hasLength(3));
      expect(second, hasLength(3));
      expect(
        first.values.toSet().intersection(second.values.toSet()),
        isEmpty,
        reason: '复用号段会让第二次粘贴整条覆盖第一次',
      );
      expect(talks.length, 6);
      expect(opts.length, 3);
      // 两批副本各自成链，互不串线
      expect(normalizeStoryIdList((talks[first[_t(1)]!] as Map)['nextTalk']), [
        int.parse(first[_t(2)]!),
      ]);
      expect(normalizeStoryIdList((talks[second[_t(1)]!] as Map)['nextTalk']), [
        int.parse(second[_t(2)]!),
      ]);
    });
  });

  group('从剪贴板粘贴（source 表与舞台分开）', () {
    test('原件仍在舞台上：新 ID 必须跳过原件，内部连线改指副本', () {
      // 复制 → 粘贴的典型顺序里原件根本不会被删，占用判定只看舞台；
      // 若误把剪贴板 key 当空闲，粘贴会整行覆盖原件（剧情线凭空少一条）。
      final clipTalks = <String, dynamic>{
        _t(1): _talk(_t(1), option: [_o(1)]),
      };
      final clipOpts = <String, dynamic>{
        _o(1): _opt(_o(1), talkId: [_t(1)]),
      };
      final talks = <String, dynamic>{
        _t(1): _talk(_t(1), option: [_o(1)]),
      };
      final opts = <String, dynamic>{
        _o(1): _opt(_o(1), talkId: [_t(1)]),
      };
      final before = copyRecords(talks);

      final map = cloneSubgraphInto(
        selected: {_t(1), _o(1)},
        talks: talks,
        opts: opts,
        prefixes: _prefixes,
        sourceTalks: clipTalks,
        sourceOpts: clipOpts,
      );

      expect(map, {_t(1): _t(2), _o(1): _o(2)});
      expect(talks[_t(1)], before[_t(1)], reason: '原件必须原样留着');
      // normalizeStoryIdList 写回的是 int 元素，比较前一律 cln 成字符串。
      expect(
        [for (final e in normalizeStoryIdList(talks[_t(2)]['option'])) cln(e)],
        [_o(2)],
        reason: '副本的 option 要指向副本选项，不是原选项',
      );
      expect(
        [for (final e in normalizeStoryIdList(opts[_o(2)]['talkId'])) cln(e)],
        [_t(2)],
      );
      expect(int.parse(talks[_t(2)]['id'].toString()), int.parse(_t(2)));
    });

    test('剪贴板为空集合：舞台一字不改', () {
      final talks = <String, dynamic>{_t(1): _talk(_t(1))};
      final map = cloneSubgraphInto(
        selected: const <String>{},
        talks: talks,
        opts: <String, dynamic>{},
        prefixes: _prefixes,
        sourceTalks: <String, dynamic>{},
        sourceOpts: <String, dynamic>{},
      );
      expect(map, isEmpty);
      expect(talks.keys, [_t(1)]);
    });
  });
}
