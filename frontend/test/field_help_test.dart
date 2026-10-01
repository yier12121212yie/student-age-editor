// 字段帮助文本守护：全量 schema 审计 + 关键样例。
//
// 目标（对齐「优化所有输入内容的描述」）：
//   1. 每张表的每个字段都能拿到一句非空说明；
//   2. 任何字段都不再出现旧的占位模板
//      「「X」字段的值：类型为 [Y]，按编码格式输入」；
//   3. 图片里那些「旁边就是中文标签」的字段有可读的游戏向说明。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_age_editor/core/api_client.dart';
import 'package:student_age_editor/core/models.dart';
import 'package:student_age_editor/features/editor/field_meta.dart';
import 'package:student_age_editor/features/editor/schema_editor_view.dart';

File _resolveAsset(String name) {
  for (final base in ['../native/assets', 'native/assets']) {
    final f = File('$base/$name');
    if (f.existsSync()) return f;
  }
  throw StateError('找不到 native/assets/$name（cwd=${Directory.current.path}）');
}

void main() {
  final schema = jsonDecode(
    _resolveAsset('schema.json').readAsStringSync(),
  ) as Map<String, dynamic>;

  String helpFor(String cfg, String key, String type) =>
      fieldHelpText(cfg, key, type, rule: fieldRuleFor(cfg, key));

  test('全量审计：每个字段都有非空说明，且不再出现旧的占位模板', () {
    final empty = <String>[];
    final legacy = <String>[];
    for (final e in schema.entries) {
      final cfg = e.key;
      final table = e.value as Map<String, dynamic>;
      for (final f in table.entries) {
        final key = f.key;
        final type = f.value.toString();
        final text = helpFor(cfg, key, type);
        if (text.trim().isEmpty) empty.add('$cfg:$key');
        if (text.contains('字段的值') || text.contains('按编码格式输入')) {
          legacy.add('$cfg:$key');
        }
      }
    }
    expect(empty, isEmpty, reason: '以下字段没有帮助文本：$empty');
    expect(legacy, isEmpty, reason: '以下字段仍在用旧模板：$legacy');
  });

  test('图片样例：看番页的字段有游戏向说明', () {
    expect(helpFor('AnimationCfg', 'id', 'Number'), contains('编号'));
    expect(helpFor('AnimationCfg', 'name', 'String'), contains('名称'));
    expect(helpFor('AnimationCfg', 'level', 'Number'), contains('神作'));
    expect(helpFor('AnimationCfg', 'time', 'Number'), contains('年份'));
    // type 有跨表引用规则：说明里应点名目标表的中文名。
    expect(helpFor('AnimationCfg', 'type', 'Number'), contains('番剧类型'));
  });

  test('引用字段：说明里点名目标配置表', () {
    expect(helpFor('EvtCfg', 'talkId', '1D Array'), contains('对话'));
    expect(helpFor('TalkCfg', 'nextTalk', 'Number'), contains('对话'));
  });

  test('效果/条件类：给出指令格式说明', () {
    final text = helpFor('TalkCfg', 'effect', '2D Array');
    expect(text, contains('指令'));
  });

  test('数值区间提示：命中 kFieldNumericHints 的字段带范围', () {
    expect(helpFor('FriendRequestCfg', 'weight', 'Number'), contains('0'));
  });

  testWidgets('经典布局（所有经典页共用）：字段描述真的渲染出来', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    ApiClient.instance.client = MockClient((req) async {
      if (req.url.path == '/api/cfg/EvtCfg') {
        return http.Response(
          '{"data":{"1":{"id":1,"title":"事件一","type":0,"content":"内容"}},'
          '"exists":true}',
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response(
        '{"ok":true}',
        200,
        headers: {'content-type': 'application/json'},
      );
    });

    final state = AppState()
      ..gameSchema = {
        'EvtCfg': {'id': 'Number', 'title': 'String', 'type': 'Number'},
      }
      ..keyMaps = {
        'EvtCfg': {'title': '标题', 'type': '类型'},
      }
      ..gameDicts = {};

    await tester.pumpWidget(
      fluent.FluentApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          body: SchemaEditorView(
            state: state,
            cfgName: 'EvtCfg',
            classic: true,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull, reason: '经典布局不应渲染异常');
    // 旧的占位模板必须绝迹，字段描述要真的出现在表里。
    expect(find.textContaining('按编码格式输入'), findsNothing);
    expect(find.text('标题文字'), findsOneWidget);
  });
}
