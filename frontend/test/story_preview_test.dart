// 故事页（StoryDirectorView）事件预览入口测试。
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
      if (m != null) {
        final name = m.group(1)!;
        final data = switch (name) {
          'EvtCfg' => {
              '101': {'id': 101, 'title': '测试事件', 'talkId': [101001]},
              '102': {'id': 102, 'title': '第二个事件'},
            },
          _ => <String, dynamic>{},
        };
        return http.Response.bytes(
            utf8.encode(jsonEncode({'data': data, 'keys': data.keys.toList()})),
            200,
            headers: {'content-type': 'application/json'});
      }
      return http.Response.bytes(
          utf8.encode(jsonEncode({'error': 'mock 404: $path'})), 404,
          headers: {'content-type': 'application/json'});
    });
  });
  tearDown(() {
    ApiClient.instance.client = http.Client();
  });

  testWidgets('故事页事件列表项显示「预览」按钮，点击触发 onPreview', (tester) async {
    String? previewedId;
    final state = AppState();
    await tester.pumpWidget(fluent.FluentApp(
      theme: fluent.FluentThemeData(brightness: Brightness.dark),
      home: Scaffold(
        body: StoryDirectorView(
          state: state,
          onPreview: (id) => previewedId = id,
        ),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // 事件列表加载并显示「预览」按钮
    expect(find.text('[101] 测试事件'), findsOneWidget);
    expect(find.text('预览'), findsNWidgets(2)); // 两个事件各一个

    // 点击第一个事件的预览按钮
    await tester.tap(find.text('预览').first);
    await tester.pump();
    expect(previewedId, '101');
  });

  testWidgets('onPreview 为空时不显示预览按钮', (tester) async {
    final state = AppState();
    await tester.pumpWidget(fluent.FluentApp(
      theme: fluent.FluentThemeData(brightness: Brightness.dark),
      home: Scaffold(body: StoryDirectorView(state: state)),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('预览'), findsNothing);
  });
}
