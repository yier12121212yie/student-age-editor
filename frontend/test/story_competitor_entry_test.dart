// 剧情编辑（友商风格）页与「故事」页处理剧情入口的接线回归测试。
//
// 覆盖点：
//  1. 经典「故事」页的工具按钮「开始处理剧情」经 onOpenPage 跳到 story_competitor 页；
//  2. story_competitor 页渲染类友商#2 的三栏剧情编辑器（StoryDirectorView.classic）。
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_age_editor/core/api_client.dart';
import 'package:student_age_editor/core/models.dart';
import 'package:student_age_editor/features/pages/classic_page_layouts.dart';
import 'package:student_age_editor/features/pages/pages_catalog.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ApiClient.instance.client = MockClient((req) async {
      final path = req.url.path;
      if (path.startsWith('/api/cfg/')) {
        final cfg = path.substring('/api/cfg/'.length);
        Map<String, dynamic> data;
        switch (cfg) {
          case 'EvtCfg':
            data = {
              '8000': {'id': '8000', 'title': '测试事件', 'talkIds': ['800001']},
            };
            break;
          case 'TalkCfg':
            data = {
              '800001': {
                'id': 800001,
                'roleIds': [10],
                'content': '测试台词',
                'nextTalk': [800002],
                'option': ['800001_1'],
              },
            };
            break;
          case 'OptionCfg':
            data = {
              '800001_1': {'id': '800001_1', 'content': '测试选项'},
            };
            break;
          case 'PersonCfg':
            data = {
              '10': {'id': 10, 'name': '主角'},
            };
            break;
          default:
            data = {
              '100': {'name': '测试条目'},
            };
        }
        return http.Response(
          jsonEncode({'data': data, 'exists': true}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (path == '/api/state') {
        return http.Response(
          jsonEncode({'mod_name': '测试模组', 'ok': true}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response(
        jsonEncode({'data': {}}),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
  });

  tearDown(() {
    ApiClient.instance.client = http.Client();
  });

  testWidgets('「故事」页「开始处理剧情」经 onOpenPage 跳转到 story_competitor', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() => tester.view.resetPhysicalSize());

    String? opened;
    final state = AppState();
    await tester.pumpWidget(
      fluent.FluentApp(
        home: Scaffold(
          body: ClassicPageLayouts(
            state: state,
            page: pageById('story')!,
            cfgName: 'TalkCfg',
            onOpenPage: (id) => opened = id,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    await tester.tap(find.text('开始处理剧情 (TalkCfg_Option)'));
    await tester.pump();

    expect(opened, 'story_competitor');
  });

  testWidgets('story_competitor 页渲染类友商#2 三栏剧情编辑器', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() => tester.view.resetPhysicalSize());

    final state = AppState();
    await tester.pumpWidget(
      fluent.FluentApp(
        home: Scaffold(
          body: ClassicPageLayouts(
            state: state,
            page: pageById('story_competitor')!,
            cfgName: 'TalkCfg',
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('🎬 剧情编辑（友商风格）'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
