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

  group('allocEventId（无代码模式自动编号）', () {
    test('空家族从 min 起', () {
      expect(allocEventId(const []), '1000000');
    });

    test('取最大已用 + 1，忽略家族外 ID', () {
      expect(
        allocEventId(const ['999', '1000005', 'abc', 'l']),
        '1000006',
      );
    });

    test('取家族内最大已用 + 1', () {
      expect(
        allocEventId(const ['1000004', '1000006', '1000005', '1000007']),
        '1000008',
      );
    });

    test('家族全占返回 null', () {
      expect(allocEventId(const [], min: 1000000, max: 1000001), '1000000');
      expect(
        allocEventId(const ['1000000', '1000001'], min: 1000000, max: 1000001),
        isNull,
      );
    });

    test('导演视图 8000~8999 家族复用同一函数', () {
      expect(allocEventId(const ['8000', '8002'], min: 8000, max: 8999),
          '8003');
    });

    test('上界被占用时从 min 回绕取首个空闲 ID（不再误返 null）', () {
      // 家族内最大已用就是上界 → max+1 越界，应回绕扫描 [min, max]。
      expect(
        allocEventId(const ['1000000', '1000002'], min: 1000000, max: 1000002),
        '1000001',
      );
      // 只占用上界：回绕到 min。
      expect(
        allocEventId(const ['1000002'], min: 1000000, max: 1000002),
        '1000000',
      );
    });

    test('家族全占时按 fallbackStart 向上分配', () {
      expect(
        allocEventId(
          const ['8000', '8001'],
          min: 8000,
          max: 8001,
          fallbackStart: 9000,
        ),
        '9000',
      );
      // fallback 起点也被占用 → 继续上探。
      expect(
        allocEventId(
          const ['8000', '8001', '9000'],
          min: 8000,
          max: 8001,
          fallbackStart: 9000,
        ),
        '9001',
      );
      // 未给 fallbackStart：区间全占仍返回 null（旧行为不变）。
      expect(
        allocEventId(const ['8000', '8001'], min: 8000, max: 8001),
        isNull,
      );
    });
  });

  group('舞台指令（TalkCfg.roles）', () {
    test('parseStageChars：入场指令的第二项是指令码，不是角色', () {
      // [[角色, 1001(滑动入场), 1, pos=1(左)]] —— 角色是 0，不是 1001。
      final chars = parseStageChars([
        [0, 1001, 1, 1],
      ]);
      expect(chars, hasLength(1));
      expect(chars.first.roleId, '0');
      expect(chars.first.pos, 1);
    });

    test('parseStageChars：退场后不再在场，表情/镜像累积到该角色', () {
      final chars = parseStageChars([
        [100, 1002, 1, 3], // 直接入场 居中
        [100, 3000, 5], // 表情 5
        [200, 1001, 1, 2], // 另一角色 右
        [100, 2001], // 100 退场
      ]);
      expect(chars.map((c) => c.roleId), ['200']);
      expect(chars.first.pos, 2);

      final only100 = parseStageChars([
        [100, 1002, 1, 3],
        [100, 3000, 5],
        [100, 3007], // 镜像一次
      ]);
      expect(only100.first.expr, 5);
      expect(only100.first.flip, isTrue);
    });

    test('parseStageChars：单条表情/换装/镜像指令也保持在場（回归）', () {
      // 历史 bug：applyStageCommands 只对 1001/1002/1003 置 present=true，
      // 单句对白若只写了 [role, 3000, expr]，角色会被判定为不在场而整条丢弃。
      final onlyExpr = parseStageChars([
        [101, 3000, 2],
      ]);
      expect(onlyExpr, hasLength(1));
      expect(onlyExpr.first.roleId, '101');
      expect(onlyExpr.first.expr, 2);

      final onlyCloth = parseStageChars([
        [101, 3006],
      ]);
      expect(onlyCloth.map((c) => c.roleId), ['101']);

      final onlyFlip = parseStageChars([
        [101, 3007],
      ]);
      expect(onlyFlip.map((c) => c.roleId), ['101']);
      expect(onlyFlip.first.flip, isTrue);
    });

    test('effectiveStages：选项分支状态隔离，互不污染（回归）', () {
      // 800001 登场角色 10；选项分出 A(800002) / B(800003) 两条线。
      // 分支 A 改表情为 2，分支 B 不改——B 不得被 A 的表情串扰。
      final talks = <String, dynamic>{
        '800001': {
          'id': 800001,
          'roles': [
            [10, 1001, 1, 1],
          ],
          'option': ['80001'],
          'nextTalk': <dynamic>[],
        },
        '800002': {
          'id': 800002,
          'roles': [
            [10, 3000, 2],
          ],
          'nextTalk': <dynamic>[],
        },
        '800003': {
          'id': 800003,
          'content': '分支 B 保持默认表情',
          'nextTalk': <dynamic>[],
        },
      };
      final options = <String, dynamic>{
        '80001': {
          'id': 80001,
          'talkId': [800002],
          'talkId2': [800003],
        },
      };
      final evt = <String, dynamic>{
        '8000': {'id': 8000, 'talkId': [800001]},
      };
      final eff = effectiveStages(
        evtId: '8000',
        evtCfg: evt,
        talks: talks,
        options: options,
      );
      expect(eff['800002']!.single.expr, 2, reason: '分支 A 表情应为 2');
      expect(eff['800003']!.single.expr, 0,
          reason: '分支 B 不得继承分支 A 的表情（BFS 状态交叉污染回归）');
    });

    test('effectiveStages：跨对白继承出场角色', () {
      final talks = <String, dynamic>{
        '800001': {
          'id': 800001,
          'roles': [
            [0, 1001, 1, 1],
          ],
          'nextTalk': [800002],
        },
        '800002': {'id': 800002, 'content': '继承上一句'},
      };
      final evt = <String, dynamic>{
        '8000': {'talkId': [800001]},
      };
      final eff = effectiveStages(
        evtId: '8000',
        evtCfg: evt,
        talks: talks,
        options: const {},
      );
      expect(eff['800001']!.map((c) => c.roleId), ['0']);
      // 800002 没有自己的 roles，但继承 800001 的在场角色
      expect(eff['800002']!.map((c) => c.roleId), ['0']);
    });

    test('setStagePos：已有入场指令改 pos，否则追加', () {
      final out = setStagePos([
        [0, 1001, 1, 1],
      ], '0', 2);
      expect(out, [
        [0, 1001, 1, 2],
      ]);
      final added = setStagePos(const <dynamic>[], '10', 3);
      expect(added, [
        [10, 1001, 1, 3],
      ]);
    });

    test('setStageExpr / removeStageRole 写回指令行', () {
      final expr = setStageExpr([
        [10, 1001, 1, 3],
      ], '10', 8);
      expect(expr, [
        [10, 1001, 1, 3],
        [10, 3000, 8],
      ]);
      final removed = removeStageRole([
        [10, 1001, 1, 3],
        [10, 3000, 8],
      ], '10');
      expect(removed, [
        [10, 2001],
      ]);
      // 不影响其它角色
      final keep = removeStageRole([
        [10, 1001, 1, 3],
        [11, 1002, 1, 1],
      ], '10');
      expect(keep, [
        [11, 1002, 1, 1],
        [10, 2001],
      ]);
    });

    test('effectiveBackgrounds：跨对白继承背景并支持分支重置', () {
      final talks = <String, dynamic>{
        '800001': {
          'id': 800001,
          'bg': '100',
          'nextTalk': [800002],
          'option': ['8001'],
        },
        '800002': {
          'id': 800002,
          'content': '继承背景100',
          'nextTalk': [800003],
        },
        '800003': {
          'id': 800003,
          'bg': '200',
          'content': '切换到新背景200',
        },
        '800004': {
          'id': 800004,
          'content': '选项分支继承100',
        },
        '999999': {
          'id': 999999,
          'bg': '300',
          'content': '游离对白自带背景',
        },
      };
      final options = <String, dynamic>{
        '8001': {
          'id': 8001,
          'talkId': [800004],
        },
      };
      final evt = <String, dynamic>{
        '8000': {'talkId': [800001]},
      };
      final eff = effectiveBackgrounds(
        evtId: '8000',
        evtCfg: evt,
        talks: talks,
        options: options,
      );

      // 800001: 显式切换为 100
      expect(eff['800001']!.bgId, '100');
      expect(eff['800001']!.isInherited, isFalse);
      expect(eff['800001']!.sourceTalkId, '800001');

      // 800002: 留空，继承自 800001 的 100
      expect(eff['800002']!.bgId, '100');
      expect(eff['800002']!.isInherited, isTrue);
      expect(eff['800002']!.sourceTalkId, '800001');

      // 800003: 显式切换为 200
      expect(eff['800003']!.bgId, '200');
      expect(eff['800003']!.isInherited, isFalse);
      expect(eff['800003']!.sourceTalkId, '800003');

      // 800004: 选项分支继承自 800001 的 100
      expect(eff['800004']!.bgId, '100');
      expect(eff['800004']!.isInherited, isTrue);
      expect(eff['800004']!.sourceTalkId, '800001');

      // 999999: 游离显式背景
      expect(eff['999999']!.bgId, '300');
      expect(eff['999999']!.isInherited, isFalse);
    });
  });
}
