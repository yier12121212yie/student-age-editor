// 回归：编辑页面切换后配置表必须跟随页面（「所有页面长得一模一样」的根因）。
//
// _StoryFlowPagesView 曾以不带 key 的方式挂载 EditorPageView，同位置同类型
// 组件 State 被复用，_cfg 停在首个页面的 defaultCfg —— 人物/事件/社交……
// 每个页面渲染的都是同一张表。本测试用同样的「无 key 换 page」挂载方式，
// 钉住 _PageViewState.didUpdateWidget 的重置行为。
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
import 'package:student_age_editor/features/pages/pages_catalog.dart';
import 'package:student_age_editor/features/pages/page_view.dart';

void main() {
  late AppState state;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    state = AppState()
      ..gameSchema = {
        'PersonCfg': {
          'id': 'Number', 'name': 'String', 'gender': 'Number',
        },
        'EvtCfg': {
          'id': 'Number', 'title': 'String', 'type': 'Number',
        },
      }
      ..gameDicts = {
        'roles': {'100': '角色A'},
      };
    ApiClient.instance.client = MockClient((req) async {
      final path = req.url.path;
      if (req.method == 'GET' && path.startsWith('/api/cfg/')) {
        return http.Response.bytes(
          utf8.encode(jsonEncode({'data': <String, dynamic>{}, 'exists': true})),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response.bytes(
        utf8.encode(jsonEncode({'error': 'mock 404'})),
        404,
        headers: {'content-type': 'application/json'},
      );
    });
  });

  tearDown(() {
    ApiClient.instance.client = http.Client();
  });

  String currentEditorCfg(WidgetTester tester) {
    final editors =
        tester.widgetList<SchemaEditorView>(find.byType(SchemaEditorView));
    return editors.map((e) => e.cfgName).join(',');
  }

  Future<void> pumpPage(WidgetTester tester, EditorPageDef page) async {
    // 刻意不带 key：复刻 _StoryFlowPagesView 的旧挂载方式，让 State 被复用。
    await tester.pumpWidget(fluent.FluentApp(
      home: Scaffold(
        body: SizedBox(
          width: 1600,
          height: 1000,
          child: EditorPageView(state: state, page: page),
        ),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('无 key 切页：配置表跟随页面重置（didUpdateWidget 兜底）',
      (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await pumpPage(tester, pageById('person')!);
    expect(currentEditorCfg(tester), 'PersonCfg',
        reason: '人物页默认编辑 PersonCfg');

    // 同一位置直接换 page（旧 _StoryFlowPagesView 的挂载形态）：State 复用，
    // didUpdateWidget 必须把 _cfg 重置为新页面的 defaultCfg。
    await pumpPage(tester, pageById('evt')!);
    expect(currentEditorCfg(tester), 'EvtCfg',
        reason: '切到事件页后必须编辑 EvtCfg，而不是沿用人物页的表');

    await pumpPage(tester, pageById('social')!);
    expect(currentEditorCfg(tester), 'KZoneContentCfg',
        reason: '再切到社交页同理');
  });

  testWidgets('带 key 挂载（story_flow_shell 修复后的形态）：切页重建出正确配置表',
      (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    Future<void> pumpKeyed(EditorPageDef page) async {
      await tester.pumpWidget(fluent.FluentApp(
        home: Scaffold(
          body: SizedBox(
            width: 1600,
            height: 1000,
            child: EditorPageView(
              key: ValueKey(page.id),
              state: state,
              page: page,
            ),
          ),
        ),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }

    await pumpKeyed(pageById('person')!);
    expect(currentEditorCfg(tester), 'PersonCfg');

    await pumpKeyed(pageById('evt')!);
    expect(currentEditorCfg(tester), 'EvtCfg');
  });
}
