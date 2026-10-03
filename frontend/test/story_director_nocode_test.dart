// 导演视图无代码模式的引用字段名称回显回归：
// bg/audio/roleIds 只读现值时必须显示「ID · 名称」，不能只剩裸 ID。
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_age_editor/core/api_client.dart';
import 'package:student_age_editor/core/models.dart';
import 'package:student_age_editor/features/story/story_director_view.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ApiClient.instance.client = MockClient((req) async {
      final path = req.url.path;
      final m = RegExp(r'^/api/cfg/(.+)$').firstMatch(path);
      Object body;
      if (m != null) {
        final name = m.group(1)!;
        final data = switch (name) {
          'EvtCfg' => {
              '101': {'id': 101, 'title': '测试事件', 'talkId': [101001]},
            },
          'TalkCfg' => {
              '101001': {
                'id': 101001,
                'content': '你好，世界',
                'bg': 109,
                'roleIds': [102],
              },
            },
          'PersonCfg' => {
              '102': {'id': 102, 'name': '小明'},
            },
          'BgCfg' => {
              '109': {'id': 109, 'name': '雨天教室'},
            },
          _ => <String, dynamic>{},
        };
        body = {'data': data, 'keys': data.keys.toList()};
      } else {
        body = <String, dynamic>{};
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

  testWidgets('无代码模式：引用字段回显「ID · 名称」而非裸 ID', (t) async {
    t.view.physicalSize = const Size(1600, 1000);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);

    final state = AppState()..setNoCodeMode(true);
    await t.pumpWidget(fluent.FluentApp(
      theme: fluent.FluentThemeData(brightness: Brightness.dark),
      home: Scaffold(body: StoryDirectorView(state: state)),
    ));
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    await t.pump(const Duration(milliseconds: 400));

    expect(t.takeException(), isNull);
    // 背景 109 → 雨天教室；说话人 102 → 小明。
    expect(find.textContaining('109 · 雨天教室'), findsOneWidget);
    expect(find.textContaining('102 · 小明'), findsOneWidget);
  });
}
