// 故事编排核心逻辑测试：前缀归属、ID 分配、删除重映射、合并写回。
import 'package:flutter_test/flutter_test.dart';
import 'package:student_age_editor/features/story/story_logic.dart';

void main() {
  group('storyIsInPrefixes', () {
    test('对白 ID 按事件前缀归属', () {
      const prefixes = ['1000'];
      expect(storyIsInPrefixes(prefixes, '1000001'), isTrue);
      expect(storyIsInPrefixes(prefixes, '1000002'), isTrue);
      expect(storyIsInPrefixes(prefixes, '2000001'), isFalse);
    });

    test('选项 ID 按后缀 2 位归属', () {
      const prefixes = ['1000'];
      expect(storyIsInPrefixes(prefixes, '100001', isOption: true), isTrue);
      expect(storyIsInPrefixes(prefixes, '100099', isOption: true), isTrue);
      expect(storyIsInPrefixes(prefixes, '200001', isOption: true), isFalse);
    });

    test('ID 长度不超过后缀时整体比对（与官方一致）', () {
      // talk 后缀 3 位：'52' 长度 2 ≤ 3 → 整体比对
      expect(storyIsInPrefixes(const ['52'], '52'), isTrue);
      // option 后缀 2 位：'52' 长度 2 ≤ 2 → 整体比对
      expect(storyIsInPrefixes(const ['52'], '52', isOption: true), isTrue);
      // 4 位 ID 超过 talk 后缀 3 位 → 截断前缀 '1'，不匹配
      expect(storyIsInPrefixes(const ['1000'], '1000'), isFalse);
    });

    test('数字带 .0 后缀可清理', () {
      const prefixes = ['1000'];
      expect(storyIsInPrefixes(prefixes, '1000001.0'), isTrue);
    });
  });

  group('storyRelatedPrefixes', () {
    test('由事件 ID 与首句对白推导前缀', () {
      final evtCfg = <String, dynamic>{
        '1000': {'talkId': [1000001]},
      };
      final prefixes = storyRelatedPrefixes('1000', evtCfg);
      expect(prefixes, contains('1000'));
    });

    test('talkId 起始对白推导额外前缀（跨事件复用对白段）', () {
      final evtCfg = <String, dynamic>{
        '8000': {'talkId': [520001]},
      };
      final prefixes = storyRelatedPrefixes('8000', evtCfg);
      // 520001 去掉后 3 位 → 520
      expect(prefixes, containsAll(['8000', '520']));
      expect(storyIsInPrefixes(prefixes, '520001'), isTrue);
      expect(storyIsInPrefixes(prefixes, '520099'), isTrue);
    });

    test('长前缀排在前面', () {
      final evtCfg = <String, dynamic>{
        '1000': {'talkId': [12345001]},
      };
      final prefixes = storyRelatedPrefixes('1000', evtCfg);
      expect(prefixes, ['12345', '1000']);
    });
  });

  group('normalizeStoryIdList', () {
    test('字符串数字转 int', () {
      expect(normalizeStoryIdList(['1', '2']), [1, 2]);
      expect(normalizeStoryIdList('5'), [5]);
    });

    test('嵌套列表拍平、空值剔除', () {
      expect(normalizeStoryIdList([[1, 2], 'x', '', 3]), [1, 2, 'x', 3]);
    });

    test('null/空串返回空列表', () {
      expect(normalizeStoryIdList(null), <dynamic>[]);
      expect(normalizeStoryIdList(''), <dynamic>[]);
    });
  });

  group('ID 分配', () {
    test('插入对话：当前 ID+1，跳过已占用', () {
      final talks = <String, dynamic>{
        '1000001': {},
        '1000002': {},
        '1000004': {},
      };
      expect(insertTalkId('1000001', talks), '1000003');
    });

    test('新建对话：当前 ID+1 的下一个空闲', () {
      final talks = <String, dynamic>{
        '1000001': {},
        '1000002': {},
      };
      expect(appendTalkId('1000001', '1000', talks), '1000003');
    });

    test('新建对话：无当前节点时用 {evtId}001 起', () {
      final talks = <String, dynamic>{'1000001': {}};
      expect(appendTalkId(null, '1000', talks), '1000002');
    });

    test('选项 ID：前缀+两位序号，跳过已占用', () {
      final used = {'100001', '100002', '100004'};
      expect(allocOptionId('1000', used), '100003');
    });

    test('选项 ID：超过 99 个返回 null', () {
      final used = {
        for (var i = 1; i < 100; i++) '1000${i.toString().padLeft(2, '0')}',
      };
      expect(allocOptionId('1000', used), isNull);
    });
  });

  group('remapDeletedTarget', () {
    test('删除对白后，指向它的 nextTalk 重定向到替代目标', () {
      final talks = <String, dynamic>{
        '1000001': {'nextTalk': <dynamic>[1000002]},
        '1000002': {'nextTalk': <dynamic>[1000003]},
        '1000003': {'nextTalk': <dynamic>[]},
      };
      final options = <String, dynamic>{};
      remapDeletedTarget(talks, options, const ['1000'], '1000002', [1000003]);
      expect(talks['1000001'], {'nextTalk': [1000003]});
      expect(talks['1000002'], {'nextTalk': [1000003]});
    });

    test('删除对白后，选项 talkId 同步重定向', () {
      final talks = <String, dynamic>{
        '1000001': {'nextTalk': <dynamic>[]},
        '1000002': {'nextTalk': <dynamic>[]},
      };
      final options = <String, dynamic>{
        '100001': {'talkId': <dynamic>[1000002]},
      };
      remapDeletedTarget(talks, options, const ['1000'], '1000002', [1000003]);
      expect(options['100001'], {'talkId': [1000003]});
    });

    test('删除不匹配事件的 key 不影响', () {
      final talks = <String, dynamic>{
        '1000001': {'nextTalk': <dynamic>[1000002]},
        '2000001': {'nextTalk': <dynamic>[1000002]},
      };
      final options = <String, dynamic>{};
      remapDeletedTarget(talks, options, const ['1000'], '1000002', <dynamic>[]);
      // 事件外对白保留原跳转
      expect(talks['2000001'], {'nextTalk': [1000002]});
      // 事件内对白跳到空替代时移除引用
      expect(talks['1000001'], {'nextTalk': <dynamic>[]});
    });

    test('重复跳转目标去重', () {
      final talks = <String, dynamic>{
        '1000001': {'nextTalk': <dynamic>[1000002, 1000002]},
        '1000002': {'nextTalk': <dynamic>[]},
      };
      final options = <String, dynamic>{};
      remapDeletedTarget(talks, options, const ['1000'], '1000002', [1000003]);
      expect(talks['1000001'], {'nextTalk': [1000003]});
    });
  });

  group('mergeStageBack', () {
    test('舞台新增与修改覆盖全表，事件内删除同步移除', () {
      final full = <String, dynamic>{
        '1000001': {'content': '旧'},
        '1000002': {'content': '保留'},
        '2000001': {'content': '其他事件'},
      };
      final baseline = stageOf(full, const ['1000']);
      final stage = <String, dynamic>{
        '1000001': {'content': '新'},
        '1000003': {'content': '新增'},
      };
      mergeStageBack(full, baseline, stage, const ['1000']);
      expect(full['1000001'], {'content': '新'});
      expect(full['1000003'], {'content': '新增'});
      expect(full.containsKey('1000002'), isFalse); // 事件内被删
      expect(full['2000001'], {'content': '其他事件'});
    });

    test('选项表合并同样生效', () {
      final full = <String, dynamic>{'100001': {'content': '旧'}};
      final baseline = stageOf(full, const ['1000'], isOption: true);
      final stage = <String, dynamic>{
        '100002': {'content': '新选项'},
      };
      mergeStageBack(full, baseline, stage, const ['1000'], isOption: true);
      expect(full.containsKey('100001'), isFalse);
      expect(full['100002'], {'content': '新选项'});
    });

    test('合并后舞台与全量表脱钩：改舞台嵌套字段不影响全量表', () {
      final target = <String, dynamic>{
        '1000001': <String, dynamic>{
          'content': '旧台词',
          'nextTalk': <dynamic>[1000002],
          'cond': <String, dynamic>{'lv': 2, 'items': <dynamic>[1]},
        },
        '2000001': <String, dynamic>{'content': '其他事件'},
      };
      final baseline = stageOf(target, const ['1000']);
      final stage = stageOf(target, const ['1000']); // 舞台 = 深拷贝（与工作区一致）
      mergeStageBack(target, baseline, stage, const ['1000']);

      // D3 核心断言：合并进全量表的必须是深拷贝，而非舞台活记录的引用。
      expect(target['1000001'], isNot(same(stage['1000001'])));
      expect(
        target['1000001']['nextTalk'],
        isNot(same(stage['1000001']['nextTalk'])),
      );
      expect(
        target['1000001']['cond'],
        isNot(same(stage['1000001']['cond'])),
      );

      // 舞台记录仍被 UI 持有并继续编辑：改嵌套字段（含嵌套 List 与嵌套 Map，
      // 以及 Map 里再嵌 List）全量表里对应的记录必须纹丝不动。
      stage['1000001']['content'] = '舞台上的新改动';
      (stage['1000001']['nextTalk'] as List).add(9999999);
      (stage['1000001']['cond'] as Map)['lv'] = 9;
      ((stage['1000001']['cond'] as Map)['items'] as List).add(99);
      expect(target['1000001']['content'], '旧台词');
      expect(target['1000001']['nextTalk'], [1000002]);
      expect(target['1000001']['cond'], {
        'lv': 2,
        'items': [1],
      });
      expect(target['2000001'], {'content': '其他事件'});
    });

    test('放弃修改不复活：全量表不再别名舞台活记录（端到端）', () {
      // 复现 D3 事故链：保存时 mergeStageBack 把舞台活记录放进全量表
      // （工作区 _save → _tablesData['TalkCfg'] = talks）→ 用户继续编辑舞台
      // → 放弃修改（_discardStage 用 baseline 重建舞台，产生新对象，被丢弃的
      // 旧对象仍被全量表别名持有）→ 切走再切回时 stageOf(全量表) 把它们深拷
      // 回舞台且 _dirty=false，已放弃的修改以"干净"状态复活并在下次保存落盘。
      final full = <String, dynamic>{
        '1000001': <String, dynamic>{'content': '旧台词'},
        '2000001': <String, dynamic>{'content': '其他事件'},
      };
      const prefixes = ['1000'];
      final fullBefore = copyRecords(full); // 修改前的全表快照
      final baseline = stageOf(full, prefixes);
      final stage = stageOf(full, prefixes); // 工作区舞台：深拷贝

      // 保存：舞台合并回全量表（此时全量表不得别名舞台活记录）。
      mergeStageBack(full, baseline, stage, prefixes);
      expect(full['1000001'], isNot(same(stage['1000001'])));

      // 保存后继续编辑舞台，随后这笔修改将被放弃：
      // 修复前 full['1000001'] 与 stage['1000001'] 是同一对象，改动直接漏进全量表。
      stage['1000001']['content'] = '被放弃的修改';
      expect(full['1000001']['content'], '旧台词');

      // 放弃修改：用修改前快照重建"干净舞台"（等价 _discardStage 的
      // copyRecords(baseline)），内容回到旧值。
      final rebuilt = stageOf(fullBefore, prefixes);
      expect(rebuilt['1000001']['content'], '旧台词');

      // 切走再切回：stageOf(全量表) 重建舞台 —— 被放弃的修改不得以干净状态出现。
      final reopened = stageOf(full, prefixes);
      expect(reopened['1000001']['content'], '旧台词');

      // 下次保存落盘：干净舞台合并回一个新 full 副本，落盘的是旧值，
      // 而不是舞台里被改的值；且同样不引入新的别名。
      final nextFull = copyRecords(full);
      mergeStageBack(nextFull, baseline, rebuilt, prefixes);
      expect(nextFull['1000001']['content'], '旧台词');
      expect(nextFull['1000001'], isNot(same(rebuilt['1000001'])));
      expect(nextFull['2000001'], {'content': '其他事件'});
    });
  });

  group('stageOf', () {
    test('只聚合事件相关的对白且深拷贝', () {
      final full = <String, dynamic>{
        '1000001': {'content': 'a', 'nextTalk': [1000002]},
        '9000001': {'content': 'b'},
      };
      final stage = stageOf(full, const ['1000']);
      expect(stage.keys, ['1000001']);
      stage['1000001']['content'] = '改';
      expect(full['1000001']['content'], 'a');
    });
  });

  group('nextTalkInEvent 删除回退', () {
    test('取同前缀后续最近对白，跳过越出前缀的 ID', () {
      final keys = ['1000001', '1000002', '1000004', '1001000'];
      expect(nextTalkInEvent(keys, '1000001'), '1000002');
      expect(nextTalkInEvent(keys, '1000002'), '1000004');
      // 1001000 前缀是 1001，不属于被删对白所在事件 → 无候选
      expect(nextTalkInEvent(keys, '1000004'), isNull);
    });

    test('非数字 ID 返回 null', () {
      expect(nextTalkInEvent(['1000002'], 'abc'), isNull);
    });

    test('删除 nextTalk 为空的中间节点：上游重连后续而非清空（端到端）', () {
      // 内层记录必须显式动态类型：真实数据来自 stageOf 深拷贝
      // （Map<String, dynamic> + List<dynamic>），字面量推断成
      // Map<String, List<int>> 会被 remap 写回 List<dynamic> 时炸掉
      final talks = <String, dynamic>{
        '1000001': <String, dynamic>{'nextTalk': <dynamic>[1000002]},
        '1000002': <String, dynamic>{'nextTalk': <dynamic>[]},
        '1000003': <String, dynamic>{'nextTalk': <dynamic>[1000004]},
        '1000004': <String, dynamic>{},
      };
      final replacement = normalizeStoryIdList(talks['1000002']['nextTalk']);
      final nxt = nextTalkInEvent(talks.keys, '1000002');
      remapDeletedTarget(talks, {}, const ['1000'], '1000002',
          nxt == null ? replacement : [int.parse(nxt)]);
      expect(talks['1000001']['nextTalk'], [1000003]);
    });
  });

  group('新分配 ID 的前缀越界校验', () {
    test('编号逼近上限时 +1 越出事件前缀，storyIsInPrefixes 拒绝', () {
      // 工作区 _talkIdUsable 的判据：insertTalkId 产出 1001000 前缀变 1001
      const prefixes = ['1000'];
      final id = insertTalkId('1000999', <String, dynamic>{});
      expect(id, '1001000');
      expect(storyIsInPrefixes(prefixes, id), isFalse);
    });
  });
}
