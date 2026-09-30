// M1 全字段可视化输入：fieldVisualFor 派生矩阵 + token 拆分 + 共享控件。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;

import 'package:student_age_editor/features/editor/field_meta.dart';
import 'package:student_age_editor/features/editor/visual_fields.dart';

void main() {
  group('fieldVisualFor 派生', () {
    test('效果类/String 不升级', () {
      expect(
          fieldVisualFor('TalkCfg', 'effect', '2D Array', null), isNull);
      expect(fieldVisualFor('TalkCfg', 'condition', '2D Array', null), isNull);
      expect(
          fieldVisualFor('TalkCfg', 'roles', '2D Array', null), isNull);
      // screenEffect 是效果类特例（1D 扁平）也不走 M1 控件。
      expect(
          fieldVisualFor('TalkCfg', 'screenEffect', '1D Array', null), isNull);
      expect(fieldVisualFor('TalkCfg', 'content', 'String', null), isNull);
      expect(
          fieldVisualFor('PersonCfg', 'url', 'String', null), isNull);
    });

    test('跳转目标优先', () {
      expect(
          fieldVisualFor('TalkCfg', 'nextTalk', '1D Array',
              FieldRule(idRefCfg: 'TalkCfg')),
          FieldVisual.jumpTarget);
      expect(
          fieldVisualFor('OptionCfg', 'nextEvtId', 'Number',
              FieldRule(idRefCfg: 'EvtCfg')),
          FieldVisual.jumpTarget);
      expect(
          fieldVisualFor('EvtCfg', 'talkId', '1D Array',
              FieldRule(idRefCfg: 'TalkCfg')),
          FieldVisual.jumpTarget);
    });

    test('音频引用三种来源都命中', () {
      expect(
          fieldVisualFor('TalkCfg', 'audio', 'Number',
              FieldRule(dictName: 'audios', idRefCfg: 'AudioCfg')),
          FieldVisual.audioPick);
      expect(
          fieldVisualFor('MinigameCfg', 'bgm', 'Number',
              FieldRule(dictName: 'audios')),
          FieldVisual.audioPick);
      // 全局 key 命中（PersonCfg.clickAudio 无规则也要试听）
      expect(
          fieldVisualFor('PersonCfg', 'clickAudio', 'Number', null),
          FieldVisual.audioPick);
      // vocals = [声ID, 音量] 对：试听但只走首 token
      expect(
          fieldVisualFor('TalkCfg', 'vocals', '1D Array', null),
          FieldVisual.audioPick);
    });

    test('Number 分档：滑杆提示 > ID 引用 > 步进', () {
      expect(
          fieldVisualFor('RelationCfg', 'condition', 'Number', null),
          FieldVisual.numberSlider);
      expect(
          fieldVisualFor('ItemCfg', 'price', 'Number',
              FieldRule(idRefCfg: 'ShopCfg')),
          FieldVisual.idBrowse);
      expect(fieldVisualFor('ItemCfg', 'price', 'Number', null),
          FieldVisual.numberBox);
    });

    test('1D Array 多选 chips 与单选数组区分', () {
      expect(
          fieldVisualFor('TalkCfg', 'roleIds', '1D Array',
              FieldRule(dictName: 'roles')),
          FieldVisual.multiIdChips);
      expect(
          fieldVisualFor('NegotiationTeammateCfg', 'skills', '1D Array',
              FieldRule(idRefCfg: 'NegotiationSkillCfg')),
          FieldVisual.multiIdChips);
      // singleArray 是下拉单选语义，不做 chips
      expect(
          fieldVisualFor('BadmintonModelCfg', 'url', '1D Array',
              FieldRule(dictName: 'badminton_models', singleArray: true)),
          isNull);
    });

    test('2D Array 非效果字段不升级（留给 EffectHintField/文本框）', () {
      expect(fieldVisualFor('MapCfg', 'exits', '2D Array', null), isNull);
    });
  });

  group('fieldTextTokens', () {
    test('四种分隔符混写等价拆分', () {
      expect(fieldTextTokens('1，2、3; 4\n5'), ['1', '2', '3', '4', '5']);
      expect(fieldTextTokens(' , ,, '), isEmpty);
    });
  });

  group('NumberStepField', () {
    Widget wrap(Widget child) =>
        fluent.FluentApp(home: Scaffold(body: child));

    testWidgets('无提示区间：只有步进框', (tester) async {
      await tester.pumpWidget(wrap(NumberStepField(
        value: 5,
        onChanged: (_) {},
      )));
      expect(find.byType(fluent.NumberBox), findsOneWidget);
      expect(find.byType(fluent.Slider), findsNothing);
    });

    testWidgets('有提示区间：步进框 + 滑杆', (tester) async {
      await tester.pumpWidget(wrap(NumberStepField(
        value: 90,
        hint: (-999, 999, 1),
        onChanged: (_) {},
      )));
      expect(find.byType(fluent.NumberBox), findsOneWidget);
      expect(find.byType(fluent.Slider), findsOneWidget);
    });

    testWidgets('滑杆轨随越界值扩展（不钳制数据）', (tester) async {
      await tester.pumpWidget(wrap(NumberStepField(
        value: 2500,
        hint: (0, 100, 1),
        onChanged: (_) {},
      )));
      final slider =
          tester.widget<fluent.Slider>(find.byType(fluent.Slider));
      expect(slider.max, 2500);
      expect(slider.value, 2500);
    });
  });

  group('ValueNameChips', () {
    Widget wrap(List<String> tokens, {required List<String> log}) =>
        fluent.FluentApp(
          home: Scaffold(
            body: ValueNameChips(
              tokens: tokens,
              nameOf: (t) => {'101': '小明', '102': '小红'}[t],
              onRemove: (i) => log.add('rm$i'),
              onMove: (f, to) => log.add('mv$f-$to'),
            ),
          ),
        );

    testWidgets('渲染 id·名称，无名回退裸 id；边界箭头禁用', (tester) async {
      final log = <String>[];
      await tester.pumpWidget(wrap(['101', '999'], log: log));
      expect(find.text('101 · 小明'), findsOneWidget);
      expect(find.text('999'), findsOneWidget);
      // 第一枚 chips 的 ◀ 禁用：点击无回调
      await tester.tap(find.text('◀').first);
      expect(log, isEmpty);
      await tester.tap(find.text('▶').first);
      expect(log, ['mv0-1']);
    });

    testWidgets('移除回调带索引', (tester) async {
      final log = <String>[];
      await tester.pumpWidget(wrap(['101', '102'], log: log));
      await tester.tap(find.text('✕').first);
      expect(log, ['rm0']);
    });
  });
}
