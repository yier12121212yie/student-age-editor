// S3 准出（cfg_patch_equivalence_test）：diffStage 生成补丁 == mergeStageBack 全量合并。
//
// 契约（still-stone-stickleback.md S3-3）：对同一张全量表，
//   applyPatch(table, diffStage(baseline, stage, prefixes)) 的结果
//   == mergeStageBack(table, baseline, stage, prefixes)
// 用 N 组随机 baseline/stage/prefix（含 int/str 键混排、删除、新增、原地改、
// 值含嵌套 list/map）硬校验；这是「剧情图静默少节点」赌注的第一道兜底。
//
// 另含 S3 准出断言：单字段编辑 patch 尺寸（set+remove == 1、JSON body < 2048B）。
import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:student_age_editor/features/story/story_logic.dart';

void main() {
  /// 把 patch 应用到全量表（模拟后端 cfg_store.apply_patch 的 set/remove 语义）
  void applyPatch(
    Map<String, dynamic> table,
    StagePatch patch,
  ) {
    for (final k in patch.remove) {
      table.remove(k); // JSON 解码后键恒为 String，与后端 str 键表一致
    }
    patch.set.forEach((k, v) => table[k] = copyRecordValue(v));
  }

  Map<String, dynamic> clone(Map<String, dynamic> src) => copyRecords(src);

  /// 生成一行对白记录
  Map<String, dynamic> talkRow(int seed, int contentLen) => {
        'id': seed,
        'content': '对白$seed-${'x' * contentLen}',
        'roleIds': [seed % 7 + 1, 'NPC${seed % 3}'],
        'nextTalk': seed % 2 == 0 ? [seed + 1] : <dynamic>[],
        'option': <dynamic>[],
        'audio': seed % 5 == 0 ? 'SE_$seed' : '',
      };

  group('cfg_patch_equivalence', () {
    test('随机 N 组：patch 应用结果 == mergeStageBack 结果', () {
      final rng = Random(20260905);
      for (var round = 0; round < 200; round++) {
        // ---- 随机事件前缀（真实形态：7 位事件 id）----
        final evtId = '1${rng.nextInt(1000000).toString().padLeft(6, '0')}';
        final secondPrefix = '${evtId}0'; // talkId 去后 3 位产生的次级前缀
        final prefixes = [secondPrefix, evtId];

        // ---- 随机全量表：本事件行 + 噪声行；键混用 String（JSON 解码形态）----
        final table = <String, dynamic>{};
        const noiseRows = 12;
        for (var i = 0; i < noiseRows; i++) {
          final k = '2${rng.nextInt(9000000) + 100000}${rng.nextInt(10)}';
          table[k] = talkRow(int.parse(k), rng.nextInt(40));
        }
        final eventRowCount = 4 + rng.nextInt(12);
        for (var i = 0; i < eventRowCount; i++) {
          final suffix = (rng.nextInt(3) + 1).toString().padLeft(3, '0');
          table['$evtId$suffix'] = talkRow(int.parse('$evtId$suffix'),
              rng.nextInt(400)); // 长度随机：拉开 patch 尺寸
        }
        final baseline = clone(table);

        // ---- 随机舞台：从基线取行（深拷贝）+ 随机删/改/增 ----
        final matcherKeys = baseline.keys
            .where((k) => PrefixMatcher(prefixes).match(k))
            .toList();
        final stage = <String, dynamic>{};
        for (final k in matcherKeys) {
          if (rng.nextBool()) continue; // 随机删除一部分（remove 路径）
          final row = copyRecordValue(baseline[k]);
          if (row is Map && rng.nextBool()) {
            // 随机改一个字段（set 路径）
            row['content'] = '改过的内容${rng.nextInt(9999)}';
          }
          stage[k] = row;
        }
        if (rng.nextBool()) {
          // 随机新增一行（set 新增路径）
          final newId = '$evtId${(rng.nextInt(3) + 4).toString().padLeft(3, '0')}';
          stage[newId] = talkRow(int.parse(newId), 30);
        }

        // ---- 两条路径分别应用到同一张表的副本 ----
        final patch = diffStage(baseline, stage, prefixes);
        final viaPatch = clone(table);
        applyPatch(viaPatch, patch);
        final viaMerge = clone(table);
        mergeStageBack(viaMerge, baseline, stage, prefixes);

        expect(
          jsonEncode(viaPatch),
          jsonEncode(viaMerge),
          reason: 'round $round ($evtId): patch 与 merge 逐字节不等',
        );
      }
    });

    test('选项表（isOption）同样逐 key 等价', () {
      const prefixes = ['1000'];
      // 选项 id = 事件 + 2 位后缀
      final table = <String, dynamic>{
        '100001': {'id': 100001, 'talkId': [1000002], 'text': '是'},
        '100002': {'id': 100002, 'talkId': [1000003], 'text': '否'},
        '200001': {'id': 200001, 'talkId': [2000001], 'text': '别的事件'},
      };
      final baseline = clone(table);
      final stage = clone(<String, dynamic>{
        '100001': {'id': 100001, 'talkId': [1000009], 'text': '是（改）'},
        // 100002 被删除
        '100003': {'id': 100003, 'talkId': <dynamic>[], 'text': '新增'},
      });
      final patch = diffStage(baseline, stage, prefixes, isOption: true);
      final viaPatch = clone(table);
      applyPatch(viaPatch, patch);
      final viaMerge = clone(table);
      mergeStageBack(viaMerge, baseline, stage, prefixes, isOption: true);
      expect(jsonEncode(viaPatch), jsonEncode(viaMerge));
      expect(patch.remove, ['100002']);
      expect(patch.set.keys, containsAll(['100001', '100003']));
    });

    test('ifMatch 携带被改行的基线值，未改行/新增行不进 ifMatch', () {
      const prefixes = ['1000'];
      final baseline = <String, dynamic>{
        '1000001': {'id': 1000001, 'content': '原内容'},
        '1000002': {'id': 1000002, 'content': '不变的行'},
      };
      final stage = <String, dynamic>{
        '1000001': {'id': 1000001, 'content': '新内容'},
        '1000002': {'id': 1000002, 'content': '不变的行'},
        '1000003': {'id': 1000003, 'content': '新增行'},
      };
      final patch = diffStage(baseline, stage, prefixes);
      expect(patch.set.keys, ['1000001', '1000003']);
      expect(patch.ifMatch.keys, ['1000001']);
      expect(patch.ifMatch['1000001'], {'id': 1000001, 'content': '原内容'});
      expect(patch.remove, isEmpty);
    });

    test('S3 准出：单字段编辑 set+remove 总数 == 1 且 patch body < 2048B', () {
      const prefixes = ['1000'];
      // 模拟真实 TalkCfg：一条基线行 ~400B × 舞台只改一个字段
      final baseline = <String, dynamic>{
        for (var i = 1; i <= 60; i++) '1000${i.toString().padLeft(3, '0')}': talkRow(i, 350),
      };
      final stage = clone(baseline);
      (stage.values.first as Map<String, dynamic>)['content'] = '只改这一句';
      final patch = diffStage(baseline, stage, prefixes);
      expect(patch.set.length + patch.remove.length, 1);

      final body = jsonEncode({
        'patch': {'set': patch.set, 'remove': patch.remove},
        'if_match': patch.ifMatch,
      });
      expect(body.length, lessThan(2048),
          reason: '保存单字段编辑的 PUT body 必须是小补丁而不是 40MB 全表');
    });

    test('舞台值经深拷贝进 set：改舞台引用不影响已生成的 patch', () {
      const prefixes = ['1000'];
      final baseline = <String, dynamic>{
        '1000001': {'id': 1000001, 'roleIds': [1]},
      };
      final stage = <String, dynamic>{
        '1000001': {'id': 1000001, 'roleIds': <dynamic>[1, 2]},
      };
      final patch = diffStage(baseline, stage, prefixes);
      (stage['1000001'] as Map<String, dynamic>)['roleIds'].add(999);
      expect((patch.set['1000001'] as Map)['roleIds'], [1, 2]);
    });
  });
}
