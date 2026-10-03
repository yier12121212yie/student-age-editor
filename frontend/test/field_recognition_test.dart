// 无代码模式的字段分类守护（判定真源：field_meta 的优先级表）。
//
// schema.json 是 406 张表字段类型的权威来源，这里对它做全量审计，钉住三条
// 不变量 + 一张显式清单：
//   1. 只有 1D/2D Array 可能是码；
//   2. 有下拉/引用规则的数组字段一律不是码（kCodeFieldByCfg 显式允许除外）；
//   3. 显式否决表里的字段不是码。
// 家族扩展（appearCond / unlock / demand / conds…）用清单逐个钉住，改名即红。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:student_age_editor/features/editor/field_meta.dart';

/// 定位仓库根的 native/assets/schema.json：CI 与本地都在 frontend/ 下跑测试，
/// 但个别 IDE 配置可能以仓库根为 cwd，两种都试。
File _resolveAsset(String name) {
  for (final base in ['../native/assets', 'native/assets']) {
    final f = File('$base/$name');
    if (f.existsSync()) return f;
  }
  throw StateError('找不到 native/assets/$name（cwd=${Directory.current.path}）');
}

void main() {
  final schema = jsonDecode(_resolveAsset('schema.json').readAsStringSync())
      as Map<String, dynamic>;

  /// schema 里的字段类型；表或字段不存在返回 null。
  String? typeOf(String cfg, String key) {
    final table = schema[cfg];
    if (table is! Map) return null;
    final t = table[key];
    return t?.toString();
  }

  test('不变量：只有 1D/2D Array 可能是码字段', () {
    final bad = <String>[];
    for (final e in schema.entries) {
      final table = e.value as Map<String, dynamic>;
      for (final f in table.entries) {
        final type = f.value.toString();
        if (type == '1D Array' || type == '2D Array') continue;
        if (isEffectLikeField(e.key, f.key, type)) bad.add('${e.key}:${f.key}');
      }
    }
    expect(bad, isEmpty, reason: '非数组字段被判成码：$bad');
  });

  test('不变量：有下拉/引用规则的数组字段不是码（显式允许表除外）', () {
    final bad = <String>[];
    for (final e in schema.entries) {
      final table = e.value as Map<String, dynamic>;
      for (final f in table.entries) {
        final type = f.value.toString();
        if (type != '1D Array' && type != '2D Array') continue;
        final id = '${e.key}:${f.key}';
        if (kCodeFieldByCfg.contains(id)) continue;
        if (fieldRuleFor(e.key, f.key) == null) continue;
        if (isEffectLikeField(e.key, f.key, type)) bad.add(id);
      }
    }
    expect(bad, isEmpty,
        reason: '命中规则的数组字段被误判为码（补进 kNonCodeArrayFields 或改 key 家族）：$bad');
  });

  test('显式允许表内的字段一律按码处理', () {
    final missing = <String>[];
    for (final id in kCodeFieldByCfg) {
      final parts = id.split(':');
      final type = typeOf(parts[0], parts[1]);
      if (type == null) continue; // schema 里已没有该字段：忽略快照残留
      if (!isEffectLikeField(parts[0], parts[1], type)) missing.add(id);
    }
    expect(missing, isEmpty, reason: '显式允许的码字段没被识别：$missing');
  });

  test('显式否决表内的字段一律不是码（roles 是角色 id 列表）', () {
    final bad = <String>[];
    for (final id in kNonCodeArrayFields) {
      final parts = id.split(':');
      final type = typeOf(parts[0], parts[1]);
      if (type == null) continue;
      if (isEffectLikeField(parts[0], parts[1], type)) bad.add(id);
    }
    expect(bad, isEmpty, reason: '显式否决失效：$bad');
  });

  test('家族扩展新纳入的 14 个字段全部命中', () {
    const expected = <String>[
      'ActionCfg:interactable',
      'ActionCfg:unlock',
      'BgCfg:gaozhongCond',
      'DIYCfg:demand',
      'ExploreCfg:appearCond',
      'ExploreCfg:unlockCond',
      'FriendRequestCfg:appearCond',
      'FriendRequestCfg:interactCond',
      'GamePlatformCfg:unlock',
      'GlobalAchCfg:impossible',
      'IntentCfg:demand',
      'MottoCfg:demand',
      'StudySummaryCfg:conds',
      'WritingCfg:demand',
    ];
    for (final id in expected) {
      final parts = id.split(':');
      final type = typeOf(parts[0], parts[1]);
      expect(type, isNotNull, reason: '$id 不在 schema.json 里了（快照需同步）');
      expect(isEffectLikeField(parts[0], parts[1], type!), isTrue, reason: id);
    }
  });

  test('码字段总数快照：182（扩表或加家族时同步改这里）', () {
    var code = 0;
    for (final e in schema.entries) {
      final table = e.value as Map<String, dynamic>;
      for (final f in table.entries) {
        if (isEffectLikeField(e.key, f.key, f.value.toString())) code++;
      }
    }
    expect(code, 182);
  });

  test('effectSuggestMode 分流：cond/unlock/demand/impossible 走条件目录', () {
    expect(effectSuggestMode('TalkCfg', 'roles'), 'action');
    expect(effectSuggestMode('TalkCfg', 'screenEffect'), 'screen');
    expect(effectSuggestMode('OptionCfg', 'cost'), 'cost');
    expect(effectSuggestMode('BgCfg', 'gaozhongCond'), 'condition');
    expect(effectSuggestMode('ActionCfg', 'unlock'), 'condition');
    expect(effectSuggestMode('GlobalAchCfg', 'impossible'), 'condition');
    expect(effectSuggestMode('DIYCfg', 'demand'), 'condition');
    expect(effectSuggestMode('ActionCfg', 'interactable'), 'effect');
    expect(effectSuggestMode('TalkCfg', 'effect2'), 'effect');
    // 不属任何码家族：调用方按需回退 'effect'。
    expect(effectSuggestMode('TalkCfg', 'content'), isNull);
    expect(effectSuggestMode('TalkCfg', 'highlights'), isNull);
  });

  test('noCodeShapeFor：普通文本与数值不受无代码模式影响', () {
    expect(noCodeShapeFor('TalkCfg', 'content', 'String', null),
        NoCodeShape.untouched);
    expect(noCodeShapeFor('TalkCfg', 'time', 'Number', null),
        NoCodeShape.untouched);
    expect(noCodeShapeFor('TalkCfg', 'id', 'Number', null),
        NoCodeShape.untouched);
  });

  test('noCodeShapeFor：规则字段走引用/视觉形态（不给文本输入）', () {
    expect(noCodeShapeFor('TalkCfg', 'bg', 'Number', fieldRuleFor('TalkCfg', 'bg')),
        NoCodeShape.reference);
    expect(
      noCodeShapeFor('TalkCfg', 'roleIds', '1D Array',
          fieldRuleFor('TalkCfg', 'roleIds')),
      NoCodeShape.visual,
    );
    expect(
      noCodeShapeFor('TalkCfg', 'audio', 'Number', fieldRuleFor('TalkCfg', 'audio')),
      NoCodeShape.visual,
    );
  });

  test('noCodeShapeFor：数组一律积木化（不靠 key 猜中，规则字段除外）', () {
    expect(noCodeShapeFor('TalkCfg', 'effect', '2D Array', null),
        NoCodeShape.blocks);
    // 未被任何家族/规则命中的数组字段也进积木（mode 回退 effect）。
    expect(noCodeShapeFor('SomeCfg', 'unknownTable', '2D Array', null),
        NoCodeShape.blocks);
    expect(noCodeShapeFor('TalkCfg', 'highlights', '1D Array', null),
        NoCodeShape.blocks);
  });

  test('noCodeShapeFor：效果格式字段不被误判为引用（IntentCfg:reward）', () {
    // reward 帮助文档是「效果」格式（第三方 schema 亦标 Effect），不得因为
    // 被物品引用规则命中而丢掉积木编辑器。
    final type = typeOf('IntentCfg', 'reward');
    expect(type, isNotNull, reason: 'IntentCfg:reward 不在 schema 里了（快照需同步）');
    expect(fieldRuleFor('IntentCfg', 'reward'), isNull);
    expect(isEffectLikeField('IntentCfg', 'reward', type!), isTrue);
    expect(
      noCodeShapeFor('IntentCfg', 'reward', type, null),
      NoCodeShape.blocks,
    );
  });
}