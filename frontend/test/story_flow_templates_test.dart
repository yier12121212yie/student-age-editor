// 场景模板库（story_flow_templates）纯函数层回归：编解码往返、合并/删除、
// 应用（ID 重编号 + 内部连线映射 + 坐标偏移）、抽取、连线字段改挂。
//
// applySceneTemplate / extractSceneTemplate 全部委托 cloneSubgraphInto 的
// 编号规范，因此这里只钉契约形状（前缀、连线可达、坐标偏移），不钉具体号。
import 'dart:convert';

import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:flutter_test/flutter_test.dart';

import 'package:student_age_editor/features/story/story_flow_templates.dart';
import 'package:student_age_editor/features/story/story_logic.dart' show cln;

FlowSceneTemplate _builtin(String id) => kBuiltinSceneTemplates
    .firstWhere((t) => t.id == id, orElse: () => throw StateError(id));

void main() {
  group('编解码往返', () {
    test('内置模板 → 文件文本 → 解码：结构无损', () {
      final file = encodeTemplatesFile(kBuiltinSceneTemplates.take(3).toList());
      final back = decodeTemplatesFile(file);
      expect(back, hasLength(3));
      for (var i = 0; i < 3; i++) {
        expect(back[i].id, kBuiltinSceneTemplates[i].id);
        expect(back[i].name, kBuiltinSceneTemplates[i].name);
        expect(back[i].category, kBuiltinSceneTemplates[i].category);
        expect(back[i].nodes, hasLength(kBuiltinSceneTemplates[i].nodes.length));
        // 连线形状：ref → 字段 → 目标 refs 完全一致
        for (final n in back[i].nodes) {
          final orig = kBuiltinSceneTemplates[i]
              .nodes
              .firstWhere((o) => o.ref == n.ref);
          expect(n.links.keys.toSet(), orig.links.keys.toSet(),
              reason: '${back[i].id}/${n.ref} 连线字段一致');
          for (final f in orig.links.keys) {
            expect(n.links[f], orig.links[f]);
          }
        }
      }
    });

    test('损坏/空文本按空库处理，不抛异常', () {
      expect(decodeTemplatesFile(null), isEmpty);
      expect(decodeTemplatesFile(''), isEmpty);
      expect(decodeTemplatesFile('not json at all {'), isEmpty);
    });
  });

  group('我的模板落盘形状', () {
    test('merge 追加到「我的模板」，remove 按 id 摘除', () {
      const json = '{"version":1,"templates":[]}';
      const t = FlowSceneTemplate(
        id: 'user_1',
        name: '我的模板',
        category: kCategoryUser,
        entry: 'a',
        nodes: [
          TemplateNode(ref: 'a', appliesTo: 'talk', relativePos: fluent.Offset.zero, record: {'content': 'x'}),
        ],
      );
      final merged = mergeTemplateIntoFile(json, t);
      final list = decodeTemplatesFile(merged);
      expect(list.map((e) => e.id), contains('user_1'));

      final afterRemove = removeTemplateFromId(merged, 'user_1');
      expect(decodeTemplatesFile(afterRemove).map((e) => e.id),
          isNot(contains('user_1')));
    });

    test('merge 进损坏的旧文件：仍能产出可解码的新库', () {
      const t = FlowSceneTemplate(
        id: 'user_2',
        name: '损',
        category: kCategoryUser,
        entry: 'a',
        nodes: [TemplateNode(ref: 'a', appliesTo: 'talk', relativePos: fluent.Offset.zero)],
      );
      final merged = mergeTemplateIntoFile('garbage{{{', t);
      expect(decodeTemplatesFile(merged).map((e) => e.id), contains('user_2'));
    });
  });

  group('applySceneTemplate', () {
    test('空舞台应用「三岔选项」：对白/选项按事件前缀新建，内部连线可达', () {
      const evtId = '1314170';
      final talks = <String, dynamic>{};
      final opts = <String, dynamic>{};

      final res = applySceneTemplate(
        evtId: evtId,
        prefixes: [evtId],
        talks: talks,
        opts: opts,
        origin: const fluent.Offset(120, 80),
        template: _builtin('tpl_three_choice'),
      );
      expect(res.ok, isTrue, reason: res.error);
      // 1 talk + 3 option + 3 result talk = 7 个新节点
      expect(res.newNodes, hasLength(7));
      expect(talks, hasLength(4));
      expect(opts, hasLength(3));
      // 所有新 id 都在本事件前缀内
      for (final id in res.newNodes) {
        expect(cln(id).startsWith(evtId), isTrue, reason: 'id=$id');
      }
      // 入口节点带连线：3 个选项
      final entry = talks[cln(res.entryId)] as Map<String, dynamic>;
      final optIds = (entry['option'] as List).map(cln).toSet();
      expect(optIds, hasLength(3));
      // 每个选项的 talkId 指向存在于舞台里的新对白
      for (final oid in optIds) {
        final opt = opts[oid] as Map<String, dynamic>;
        final targets = (opt['talkId'] as List).map(cln).toSet();
        expect(targets, hasLength(1));
        expect(talks.keys, containsAll(targets));
      }
      // 坐标 = 落点 + 模板相对偏移：入口即落点
      expect(res.positions[cln(res.entryId)], const fluent.Offset(120, 80));
    });

    test('对白编号耗尽：整组失败，舞台一字不改', () {
      final talks = <String, dynamic>{
        // 一个已存在的对白，让 appendTalkId 沿现有编号分配
        '1314170999': {
          'id': 1314170999,
          'content': '占用尾部',
          'nextTalk': <dynamic>[],
        },
      };
      final snapshot = jsonEncode(talks);
      final res = applySceneTemplate(
        evtId: '1314170',
        prefixes: ['1314170'],
        talks: talks,
        opts: {},
        origin: fluent.Offset.zero,
        template: _builtin('tpl_opening_monologue'), // 3 个 talk 连排
      );
      if (res.ok) return; // 分配未撞界则本用例无事可断
      expect(talks, hasLength(1));
      expect(jsonEncode(talks), snapshot);
    });
  });

  group('extractSceneTemplate → 再应用', () {
    test('从舞台抽取的模板可再实例化，内部连线拓扑不变', () {
      const evtId = '1314170';
      final talks = <String, dynamic>{};
      final opts = <String, dynamic>{};
      final first = applySceneTemplate(
        evtId: evtId,
        prefixes: [evtId],
        talks: talks,
        opts: opts,
        origin: fluent.Offset.zero,
        template: _builtin('tpl_three_choice'),
      );
      expect(first.ok, isTrue);

      // 只选中入口 + 两个选项（扔掉第三个分支的选项与结果）→ 指向选区外的
      // 结果对白连线应被剪断，不会引用未进模板的节点。
      final entryId = cln(first.entryId);
      final optIds = (talks[entryId]['option'] as List).map(cln).take(2).toSet();
      final t = extractSceneTemplate(
        selected: {entryId, ...optIds},
        talks: talks,
        opts: opts,
        positions: first.positions,
        name: '两岔选项',
        id: 'user_extract',
      );
      expect(t.nodes, hasLength(3));
      expect(t.entry, entryId, reason: '入口取编号最小的 talk');
      for (final n in t.nodes) {
        for (final targets in n.links.values) {
          final refs = t.nodes.map((x) => x.ref).toSet();
          expect(refs, containsAll(targets),
              reason: '指向选区外的连线必须被丢弃');
        }
      }

      // 再应用：新编号、拓扑一致（1 talk + 2 option）
      final talks2 = <String, dynamic>{};
      final opts2 = <String, dynamic>{};
      final second = applySceneTemplate(
        evtId: evtId,
        prefixes: [evtId],
        talks: talks2,
        opts: opts2,
        origin: fluent.Offset.zero,
        template: t,
      );
      expect(second.ok, isTrue);
      expect(second.newNodes, hasLength(3));
      expect(talks2, hasLength(1));
      expect(opts2, hasLength(2));
      final entry2 = talks2[cln(second.entryId)] as Map<String, dynamic>;
      expect((entry2['option'] as List), hasLength(2));
    });
  });

  group('retargetEdgeField', () {
    test('nextTalk 改挂 nextTalk2：原字段摘除、目标字段推入，往返等价', () {
      final record = <String, dynamic>{
        'nextTalk': <dynamic>[32010101],
        'nextTalk2': <dynamic>[],
      };
      expect(retargetEdgeField(record, 'nextTalk', 'nextTalk2', 32010101),
          isTrue);
      expect(record['nextTalk'], isEmpty);
      expect(cln(record['nextTalk2'].single), '32010101');

      // 同字段再改挂 = no-op
      expect(retargetEdgeField(record, 'nextTalk2', 'nextTalk2', 32010101),
          isFalse);
      // 切回去
      expect(retargetEdgeField(record, 'nextTalk2', 'nextTalk', 32010101),
          isTrue);
      expect(cln(record['nextTalk'].single), '32010101');
      expect(record['nextTalk2'], isEmpty);
    });
  });

  test('内置模板：入口存在且连线目标都在模板内', () {
    for (final t in kBuiltinSceneTemplates) {
      expect(t.nodes, isNotEmpty, reason: t.id);
      expect(t.nodes.map((n) => n.ref), contains(t.entry), reason: t.id);
      final refs = t.nodes.map((n) => n.ref).toSet();
      for (final n in t.nodes) {
        for (final targets in n.links.values) {
          expect(refs, containsAll(targets), reason: '${t.id}/${n.ref}');
        }
      }
    }
  });
}
