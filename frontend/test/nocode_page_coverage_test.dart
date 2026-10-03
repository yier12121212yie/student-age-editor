// 「扩大无代码模式到每一个编辑页面」的守护测试：
// 开启无代码模式后，17 个编辑页（pages_catalog 的全量表）里不能再出现任何
// 手写效果码 / ID 的输入通道。
//
// 两层断言：
//   1) 纯函数层：第三方权威 schema 声明的引用目标（field_ref_data 的
//      kFieldRefTargets）在字段分类里一律不是 untouched——即一定会被收敛为
//      下拉/浏览/积木，而不是裸文本框。
//   2) 组件层：逐张页面表挂载经典 SchemaEditorView（无代码开启），断言不抛异常，
//      且效果补全框（EffectHintField）与代码补全框（SuggestionTextField）一律不出现。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:student_age_editor/core/api_client.dart';
import 'package:student_age_editor/core/models.dart';
import 'package:student_age_editor/features/editor/effect_hint_field.dart';
import 'package:student_age_editor/features/editor/field_meta.dart';
import 'package:student_age_editor/features/editor/field_ref_data.dart';
import 'package:student_age_editor/features/editor/schema_editor_view.dart';
import 'package:student_age_editor/features/editor/suggestion_text_field.dart';
import 'package:student_age_editor/features/pages/pages_catalog.dart';

File _resolveAsset(String name) {
  for (final base in ['../native/assets', 'native/assets']) {
    final f = File('$base/$name');
    if (f.existsSync()) return f;
  }
  throw StateError('找不到 native/assets/$name（cwd=${Directory.current.path}）');
}

/// 页面目录里出现的全部配置表（去重、稳定序）。
List<String> _pageTables() {
  final seen = <String>{};
  final out = <String>[];
  for (final page in editorPages) {
    for (final cfg in page.cfgNames) {
      if (seen.add(cfg)) out.add(cfg);
    }
  }
  out.sort();
  return out;
}

void main() {
  final schema = jsonDecode(_resolveAsset('schema.json').readAsStringSync())
      as Map<String, dynamic>;
  final dicts = jsonDecode(_resolveAsset('dicts.json').readAsStringSync())
      as Map<String, dynamic>;

  late AppState state;

  setUp(() {
    state = AppState()
      ..gameSchema = schema
      ..keyMaps = dicts['key_maps'] as Map<String, dynamic>
      ..gameDicts = (dicts['game_dicts'] ?? {}) as Map<String, dynamic>;
    state.setNoCodeMode(true);
    // 各端点返回最小可用形状：Cfg 表给一条占位记录让字段表单渲染；effect/parse
    // 给空行让积木编辑器走「空态」；其余回 {}，任何补全失败都不阻塞渲染。
    ApiClient.instance.client = MockClient((req) async {
      Object body;
      switch (req.url.path) {
        case '/api/effect/parse':
          body = {
            'ok': true,
            'status': 'ok',
            'translations': const [],
            'rows': const [],
          };
          break;
        case '/api/effect_suggest':
          body = {'items': const []};
          break;
        case '/api/cfg_ids':
          body = {'items': const []};
          break;
        default:
          body = {'data': {'1': {'id': 1}}, 'exists': true, 'mtime_ns': 0};
      }
      return http.Response.bytes(
        utf8.encode(jsonEncode(body)),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
  });

  tearDown(() {
    ApiClient.instance.client = http.Client();
  });

  group('引用目标数据：无代码模式一律非 untouched', () {
    test('kFieldRefTargets 每条都命中规则且不给裸文本输入', () {
      for (final entry in kFieldRefTargets.entries) {
        final parts = entry.key.split(':');
        expect(parts.length, 2, reason: '键应为 cfg:key：${entry.key}');
        final cfg = parts[0];
        final key = parts[1];
        final table = schema[cfg];
        if (table is! Map || !table.containsKey(key)) continue;
        final type = table[key].toString();
        final rule = fieldRuleFor(cfg, key);
        expect(rule, isNotNull, reason: '${entry.key} 应有引用规则');
        // 手写规则优先（可能是 dictName 家族，如 bg→bgs / audio→audios），
        // 生成兜底才会把 idRefCfg 指向本例的 range.table；两者都接受。
        expect(
          rule!.idRefCfg != null || rule.dictName != null || rule.fixed != null,
          isTrue,
          reason: '${entry.key} 的规则应有候选来源',
        );
        expect(
          noCodeShapeFor(cfg, key, type, rule),
          isNot(NoCodeShape.untouched),
          reason: '${entry.key} 开启无代码后不应仍是文本输入',
        );
      }
    });

    test('页面表里所有 1D/2D Array 字段都不是 untouched（积分木/引用）', () {
      for (final cfg in _pageTables()) {
        final table = schema[cfg];
        if (table is! Map) continue;
        table.forEach((key, type) {
          final t = type.toString();
          if (t != '1D Array' && t != '2D Array') return;
          expect(
            noCodeShapeFor(cfg, key.toString(), t, fieldRuleFor(cfg, key.toString())),
            isNot(NoCodeShape.untouched),
            reason: '$cfg:$key（$t）开启无代码后不应是裸文本输入',
          );
        });
      }
    });

    test('第三方 schema 未标 range 的手写引用同样非 untouched', () {
      // 说明文明确是 ID 列表/引用、但 catalog 未标 range.table 的字段（见
      // field_meta.dart 末尾的手写补齐），无代码模式必须给选择入口。
      const manual = <String>[
        'EndingOptionCfg:part',
        'EndingPartCfg:options',
        'EndingPartCfg:evt',
        'PersonAttrCfg:order',
        'ActionCfg:attrs',
        'ActionEvtCfg:evts',
        'CGCfg:startTalks',
        'EvtCfg:miniGame',
        'IntentCfg:failTalk',
        'IntentCfg:finishTalk',
        'PhoneMsgCfg:next',
        'TVCfg:talks',
        'BookCfg:themes',
      ];
      for (final id in manual) {
        final parts = id.split(':');
        final table = schema[parts[0]];
        final type = (table is Map ? table[parts[1]] : null)?.toString();
        if (type == null) continue;
        final rule = fieldRuleFor(parts[0], parts[1]);
        expect(rule, isNotNull, reason: '$id 应有引用/枚举规则');
        expect(
          noCodeShapeFor(parts[0], parts[1], type, rule),
          isNot(NoCodeShape.untouched),
          reason: '$id 开启无代码后不应是文本输入',
        );
      }
    });
  });

  group('逐张页面表：无代码开启后不出现代码输入框', () {
    for (final cfg in _pageTables()) {
      testWidgets('$cfg 无异常且无 EffectHintField / SuggestionTextField', (t) async {
        t.view.physicalSize = const Size(1600, 1000);
        t.view.devicePixelRatio = 1.0;
        addTearDown(t.view.reset);

        await t.pumpWidget(fluent.FluentApp(
          debugShowCheckedModeBanner: false,
          home: Scaffold(
            body: SchemaEditorView(state: state, cfgName: cfg, classic: true),
          ),
        ));
        await t.pump();
        await t.pump(const Duration(milliseconds: 300));
        await t.pump(const Duration(milliseconds: 300));

        expect(t.takeException(), isNull, reason: '$cfg 渲染异常');
        // 无代码模式的核心承诺：没有手写效果码的补全框，也没有代码补全框。
        expect(find.byType(EffectHintField), findsNothing,
            reason: '$cfg 仍出现效果补全框');
        expect(find.byType(SuggestionTextField), findsNothing,
            reason: '$cfg 仍出现代码/ID 补全框');
      });
    }
  });
}
