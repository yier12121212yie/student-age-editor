// 画布未保存改动的撤销栈回归：FlowEditHistory 是「改了还没存表」这段区间里
// Ctrl+Z / Ctrl+Y 唯一的依据——后端 /api/history 由 cfg_store 在存表时打点，
// 粒度是单张 cfg 表且各表互相独立，看不见画布上的未保存态。这里锁的每一条
// 都对应一个用户可直接看到的故障：
//   · 快照必须深拷贝（含嵌套的 talkId / nextTalk 列表）：宿主是原地改
//     _talks 的，浅拷贝会让 undo 交出「当前内容」，表现为按 Ctrl+Z 画面一动不动。
//   · 位置必须入栈：删节点会连坐标一起清掉，撤销不带位置，复活的节点会掉到
//     (0, 0) 跟别的卡片叠在一起。
//   · mergeKey 合并：内联输入框每敲一个字就是一次变更，不合并的话 60 步栈会被
//     一个词吃光，而且撤销要按字退。
//   · 溢出只淘汰最旧的一步，初始态 _states[0] 永不淘汰：否则再也退不回载入时。
//   · seed 清栈：切事件时留着上一个事件的栈，撤销会把旧内容灌进新事件。
// 纯单元测试：不起 widget、不接 MockClient、不打后端。
import 'package:flutter_test/flutter_test.dart';
import 'package:student_age_editor/features/story/story_flow_history.dart';

const _t1 = '1000001000';
const _t2 = '1000001001';
const _o1 = '100000100001';

/// 造一份形如真实舞台的记录：内层显式动态类型，值里带嵌套 ID 列表。
Map<String, dynamic> _talksA() => <String, dynamic>{
  _t1: <String, dynamic>{
    'id': 1000001000,
    'content': '甲',
    'talkId': <dynamic>['1', '2'],
    'nextTalk': <dynamic>[_t2],
  },
  _t2: <String, dynamic>{
    'id': 1000001001,
    'content': '乙',
    'talkId': <dynamic>[],
  },
};

Map<String, dynamic> _optsA() => <String, dynamic>{
  _o1: <String, dynamic>{
    'id': 100000100001,
    'content': '选项甲',
    'gotoTalk': <dynamic>[_t2],
  },
};

Map<String, Offset> _posA() => <String, Offset>{
  _t1: const Offset(10, 20),
  _t2: const Offset(30, 40),
};

/// 只放一条对白的可变内容表，用来按步写内容 v0/v1/...。
Map<String, dynamic> _oneTalk(String content) => <String, dynamic>{
  _t1: <String, dynamic>{'content': content},
};

void main() {
  group('未 seed 时不得凭空建栈', () {
    test('seed 前 record 是 no-op，undo/redo 返回 null', () {
      // 事件还没载入，宿主就可能收到内容变更回调；此时建栈会造出一个没有
      // 初始态的栈，undo 交出 null 就被误当成「已退到底」。
      final h = FlowEditHistory();
      expect(h.length, 0);
      expect(h.cursor, -1);
      expect(h.canUndo, isFalse);
      expect(h.canRedo, isFalse);
      expect(h.undo(), isNull);
      expect(h.redo(), isNull);

      h.record(_talksA(), _optsA(), _posA(), mergeKey: 'content:$_t1');

      expect(h.length, 0);
      expect(h.cursor, -1);
      expect(h.canUndo, isFalse);
      expect(h.canRedo, isFalse);
      expect(h.undo(), isNull);
      expect(h.redo(), isNull);
    });
  });

  group('快照必须深拷贝', () {
    test('原地改源 map 的字段与增删 key 都不影响已入栈的快照', () {
      final h = FlowEditHistory();
      final talks = _talksA();
      h.seed(talks, _optsA(), _posA());

      // 模拟宿主的真实写入方式：不新建 map，直接在自己的数据上动手。
      talks[_t1]['content'] = '改过的甲';
      talks.remove(_t2);
      h.record(talks, _optsA(), _posA());

      final base = h.undo()!;
      expect(base.talks[_t1]['content'], '甲');
      expect(base.talks.keys, containsAll(<String>[_t1, _t2]));
      expect(identical(base.talks, talks), isFalse);

      final after = h.redo()!;
      expect(after.talks[_t1]['content'], '改过的甲');
      expect(after.talks.containsKey(_t2), isFalse);
      expect(identical(after.talks, talks), isFalse);
    });

    test('嵌套 talkId 列表也是深拷贝：源列表 add/removeAt 不污染快照', () {
      // 这条是唯一能抓到「只拷了外层 map」的守卫：漏内层时快照与源共享同一个
      // List，撤销后 talkId 仍是新值，表现为卡片文字退回了但连线没退回。
      final h = FlowEditHistory();
      final talks = _talksA();
      final ids = talks[_t1]['talkId'] as List;
      h.seed(talks, _optsA(), _posA());

      ids.add('3');
      ids.removeAt(0); // ['2','3']
      h.record(talks, _optsA(), _posA());

      final baseIds = h.undo()!.talks[_t1]['talkId'] as List;
      expect(baseIds, ['1', '2']);
      expect(identical(baseIds, ids), isFalse);

      final afterIds = h.redo()!.talks[_t1]['talkId'] as List;
      expect(afterIds, ['2', '3']);
      afterIds.add('4'); // 栈里交出去的对象被调用方改动后，不得回流到源
      expect(ids, ['2', '3']);
    });

    test('opts 与其嵌套 gotoTalk 列表同样深拷贝', () {
      final h = FlowEditHistory();
      final opts = _optsA();
      h.seed(_talksA(), opts, _posA());

      opts[_o1]['content'] = '改过的选项';
      (opts[_o1]['gotoTalk'] as List).clear();
      h.record(_talksA(), opts, _posA());

      final base = h.undo()!;
      expect(base.opts[_o1]['content'], '选项甲');
      expect(base.opts[_o1]['gotoTalk'], [_t2]);
    });

    test('位置入栈且与源 map 脱钩：删节点抹掉的坐标能被 undo 找回', () {
      final h = FlowEditHistory();
      final pos = _posA();
      h.seed(_talksA(), _optsA(), pos);

      pos.remove(_t2); // 删除节点连坐标一起清
      h.record(_talksA(), _optsA(), pos);

      final base = h.undo()!;
      expect(base.positions[_t2], const Offset(30, 40));
      expect(base.positions[_t1], const Offset(10, 20));

      // 记录之后再拖动源 map，已入栈的快照不得跟着动。
      pos[_t1] = const Offset(77, 88);
      final after = h.redo()!;
      expect(after.positions[_t1], const Offset(10, 20));
      expect(after.positions.containsKey(_t2), isFalse);
    });
  });

  group('mergeKey 合并', () {
    test('同一 key 连续打字合成一步，一次撤销整段退回', () {
      final h = FlowEditHistory();
      final talks = _oneTalk('');
      h.seed(talks, _optsA(), _posA());

      for (final text in ['甲', '甲方', '甲方乙']) {
        talks[_t1]['content'] = text;
        h.record(talks, _optsA(), _posA(), mergeKey: 'content:$_t1');
      }

      expect(h.length, 2);
      expect(h.cursor, 1);
      expect(h.undo()!.talks[_t1]['content'], '');
      expect(h.canUndo, isFalse);
      expect(h.redo()!.talks[_t1]['content'], '甲方乙');
    });

    test('换 key 或 key 为 null 都另起一步', () {
      final h = FlowEditHistory();
      final talks = _oneTalk('v0');
      h.seed(talks, _optsA(), _posA());

      void step(String v, {Object? key}) {
        talks[_t1]['content'] = v;
        h.record(talks, _optsA(), _posA(), mergeKey: key);
      }

      step('v1', key: 'content:$_t1');
      step('v2', key: 'content:$_t1'); // 同 key → 合并进上一步
      step('v3', key: 'content:$_t2'); // 换字段 → 新一步
      step('v4'); // null key → 新一步
      step('v5'); // 连续 null 也不合并（null 视作「非打字变更」）
      step('v6', key: 'content:$_t2'); // 上一步 key 已是 null → 新一步

      expect(h.length, 6); // 6 次变更合成 5 步 + 初始态
      expect(h.cursor, 5);
      final back = <String>[];
      for (FlowEditSnapshot? s = h.undo(); s != null; s = h.undo()) {
        back.add(s.talks[_t1]['content'] as String);
      }
      expect(back, ['v5', 'v4', 'v3', 'v2', 'v0']);
      expect(h.canUndo, isFalse);
    });

    test('游标不在栈顶时同 key 也不合并，并截断 redo 尾', () {
      // 撤销后继续打字必须开新的一步：否则合并写会覆盖退回前的那一步，
      // redo 尾也就分叉了——线性栈不允许留分支。
      final h = FlowEditHistory();
      final talks = _talksA();
      const key = 'content:$_t1';
      h.seed(talks, _optsA(), _posA());

      talks[_t1]['content'] = '打字一';
      h.record(talks, _optsA(), _posA(), mergeKey: key);
      talks[_t1]['content'] = '打字二';
      h.record(talks, _optsA(), _posA(), mergeKey: key);
      expect(h.length, 2);

      expect(h.undo()!.talks[_t1]['content'], '甲');
      talks[_t1]['content'] = '分叉后的打字';
      h.record(talks, _optsA(), _posA(), mergeKey: key);

      expect(h.length, 2);
      expect(h.cursor, 1);
      expect(h.canRedo, isFalse);
      expect(h.redo(), isNull);
      expect(h.undo()!.talks[_t1]['content'], '甲');
      expect(h.redo()!.talks[_t1]['content'], '分叉后的打字');
    });
  });

  group('线性游标与端点', () {
    test('栈里只有初始态时两端都退不动', () {
      final h = FlowEditHistory();
      h.seed(_talksA(), _optsA(), _posA());
      expect(h.length, 1);
      expect(h.cursor, 0);
      expect(h.canUndo, isFalse);
      expect(h.canRedo, isFalse);
      expect(h.undo(), isNull);
      expect(h.redo(), isNull);
    });

    test('undo/redo 逐步移动游标，不越界', () {
      final h = FlowEditHistory();
      final talks = _oneTalk('v0');
      h.seed(talks, _optsA(), _posA());
      for (final v in ['v1', 'v2']) {
        talks[_t1]['content'] = v;
        h.record(talks, _optsA(), _posA());
      }
      expect(h.length, 3);
      expect(h.cursor, 2);
      expect(h.canRedo, isFalse);

      expect(h.undo()!.talks[_t1]['content'], 'v1');
      expect(h.cursor, 1);
      expect(h.canUndo, isTrue);
      expect(h.canRedo, isTrue);
      expect(h.undo()!.talks[_t1]['content'], 'v0');
      expect(h.canUndo, isFalse);
      expect(h.undo(), isNull);
      expect(h.cursor, 0);

      expect(h.redo()!.talks[_t1]['content'], 'v1');
      expect(h.redo()!.talks[_t1]['content'], 'v2');
      expect(h.canRedo, isFalse);
      expect(h.redo(), isNull);
      expect(h.cursor, 2);
    });

    test('seed 清空旧栈并把新内容作为初始态', () {
      // 切事件时留着上一个事件的栈，撤销会把旧事件内容灌进当前事件。
      final h = FlowEditHistory();
      final old = _oneTalk('上个事件');
      h.seed(old, _optsA(), _posA());
      old[_t1]['content'] = '上个事件改过';
      h.record(old, _optsA(), _posA());
      expect(h.length, 2);

      final fresh = _oneTalk('本事件');
      h.seed(fresh, _optsA(), _posA());
      expect(h.length, 1);
      expect(h.cursor, 0);
      expect(h.canUndo, isFalse);
      expect(h.undo(), isNull);

      fresh[_t1]['content'] = '本事件改过';
      h.record(fresh, _optsA(), _posA());
      expect(h.undo()!.talks[_t1]['content'], '本事件');
    });
  });

  group('limit 淘汰', () {
    test('limit:3 时栈深 4，一路退到底仍是 seed 的初始态', () {
      final h = FlowEditHistory(limit: 3);
      final talks = _oneTalk('v0');
      final pos = <String, Offset>{_t1: const Offset(0, 0)};
      h.seed(talks, _optsA(), pos);

      for (var i = 1; i <= 5; i++) {
        talks[_t1]['content'] = 'v$i';
        pos[_t1] = Offset(i * 10, i * 10);
        h.record(talks, _optsA(), pos);
      }

      // limit 是「编辑步数」上限，初始态另算，所以栈深是 limit + 1。
      expect(h.length, 4);
      expect(h.cursor, 3);
      expect(h.canRedo, isFalse);

      // 被淘汰的是最旧的两步（v1、v2），不是初始态。
      expect(h.undo()!.talks[_t1]['content'], 'v4');
      expect(h.undo()!.talks[_t1]['content'], 'v3');
      final base = h.undo()!;
      expect(base.talks[_t1]['content'], 'v0');
      expect(base.positions[_t1], const Offset(0, 0));
      expect(h.canUndo, isFalse);
      expect(h.undo(), isNull);
      expect(h.redo()!.talks[_t1]['content'], 'v3');
    });
  });
}
