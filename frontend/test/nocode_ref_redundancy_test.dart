// 回归：无代码模式下，引用字段若下拉框已完整列出候选、实体浏览面板又给不出
// 下拉没有的东西（事件类型/地图等小字典），就不能再挂一个「选 X」按钮——那
// 是同一份选项的第二个入口。人物（立绘网格）/背景（缩略图）或候选多到被下拉
// 上限截断时才保留面板按钮。
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_age_editor/core/api_client.dart';
import 'package:student_age_editor/core/models.dart';
import 'package:student_age_editor/features/editor/schema_editor_view.dart';

AppState _state() {
  final state = AppState()
    ..gameSchema = {
      'EvtCfg': {
        'id': 'Number',
        'type': 'Number',
        'npc': 'Number',
      },
    }
    ..keyMaps = {}
    ..gameDicts = {
      // 小字典：下拉能完整列出 → 不应再有「选事件类型」按钮。
      'evt_types': {for (var i = 0; i < 8; i++) '$i': '类型$i'},
      // 人物有立绘 → 实体面板按钮保留。
      'roles': {'101': '小明', '102': '小红'},
      // 超出下拉上限（200）→ 需要面板的搜索，按钮保留。
      'items': {for (var i = 0; i < 260; i++) '$i': '物品$i'},
    };
  state.setNoCodeMode(true);
  return state;
}

Future<void> _mount(WidgetTester tester, AppState state) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = const Size(1400, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  ApiClient.instance.client = MockClient((req) async {
    if (req.url.path == '/api/cfg/EvtCfg') {
      return http.Response.bytes(
        utf8.encode(jsonEncode({
          'data': {
            '1': {
              'id': 1,
              'type': 0,
              'npc': 101,
            },
          },
          'exists': true,
        })),
        200,
        headers: {'content-type': 'application/json'},
      );
    }
    return http.Response.bytes(
      utf8.encode(jsonEncode({'data': {}, 'exists': true})),
      200,
      headers: {'content-type': 'application/json'},
    );
  });
  addTearDown(() => ApiClient.instance.client = http.Client());

  await tester.pumpWidget(fluent.FluentApp(
    debugShowCheckedModeBanner: false,
    home: Scaffold(
      body: SchemaEditorView(state: state, cfgName: 'EvtCfg', classic: true),
    ),
  ));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  testWidgets('小字典引用字段：下拉已含全部候选，不再并发「选事件类型」', (tester) async {
    await _mount(tester, _state());
    expect(tester.takeException(), isNull);
    // 事件类型（evt_types 小字典、无缩略图）：下拉即完整候选，无第二个入口。
    expect(find.text('选事件类型'), findsNothing);
    // 人物（roles 有立绘网格）：面板按钮保留。
    expect(find.text('选人物'), findsOneWidget);
  });
}
