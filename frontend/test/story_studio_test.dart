// 剧情舞台（剧情编辑页）测试：
//  1. buildStudioTree 纯函数：跳转链展开、对话夹嵌套、环收敛为引用、
//     缺失目标提示、游离对白收尾、折叠呈现；
//  2. story_studio 页冒烟：默认渲染剧情舞台（对话线树 + 舞台 + 人物与表情）。
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
import 'package:student_age_editor/features/story/story_studio_editor.dart';

void main() {
  group('buildStudioTree', () {
    Map<String, dynamic> talksBase() => {
          '800001': {
            'id': 800001,
            'content': '开场',
            'nextTalk': [800002],
            'option': ['80001'],
          },
          '800002': {'id': 800002, 'content': '甲线收尾'},
          '800003': {
            'id': 800003,
            'content': '乙线·选项后',
            'check': ['c>=1'],
            'nextTalk2': [800004],
          },
          '800004': {'id': 800004, 'content': '丙·判定失败'},
        };
    Map<String, dynamic> optsBase() => {
          '80001': {
            'id': 80001,
            'content': '去乙线',
            'talkId': [800003],
          },
        };
    final evtCfg = <String, dynamic>{
      '8000': {'id': 8000, 'title': '测试事件', 'talkId': [800001]},
    };

    test('选项长成语句下方的对话夹，条件失败嵌套在夹内', () {
      final items = buildStudioTree(
        evtId: '8000',
        evtCfg: evtCfg,
        talks: talksBase(),
        options: optsBase(),
      );
      // 主线：开场 → 甲线；选项夹：去乙线 → 800003 →（条件夹 800004）+ 两个 tail。
      final kinds = items.map((e) => e.kind).toList();
      expect(kinds, containsAllInOrder([
        StudioItemKind.talk, // 800001
        StudioItemKind.folder, // opt:80001
        StudioItemKind.talk, // 800003
        StudioItemKind.folder, // cond:800003
        StudioItemKind.talk, // 800004
      ]));
      // 深度嵌套递进
      final folder1 = items.firstWhere((e) => e.kind == StudioItemKind.folder);
      expect(folder1.id, 'opt:80001');
      expect(folder1.depth, 1);
      final talk3 = items.firstWhere((e) => e.kind == StudioItemKind.talk && e.id == '800003');
      expect(talk3.depth, 2);
      final folderCond = items
          .firstWhere((e) => e.kind == StudioItemKind.folder && e.id == 'cond:800003');
      expect(folderCond.depth, 3);
      // 夹底部接续条目
      final tails = items.where((e) => e.kind == StudioItemKind.tail).toList();
      expect(tails.map((e) => e.field), containsAll(['talkId', 'nextTalk2']));
      // 甲线在选项夹之后回到主线深度 0
      final talk2 = items.firstWhere((e) => e.kind == StudioItemKind.talk && e.id == '800002');
      expect(talk2.depth, 0);
    });

    test('环跳转收敛为引用条目，不再展开', () {
      final talks = talksBase();
      (talks['800002'] as Map)['nextTalk'] = [800001]; // 甲线跳回开场
      final items = buildStudioTree(
        evtId: '8000',
        evtCfg: evtCfg,
        talks: talks,
        options: optsBase(),
      );
      final refs = items.where((e) => e.kind == StudioItemKind.ref).toList();
      expect(refs.map((e) => e.id), contains('800001'));
      // 800001 只作为 talk 条目出现一次
      expect(
        items.where((e) => e.kind == StudioItemKind.talk && e.id == '800001').length,
        1,
      );
    });

    test('跳转目标缺失给出提示条目', () {
      final talks = talksBase();
      (talks['800002'] as Map)['nextTalk'] = [809999];
      final items = buildStudioTree(
        evtId: '8000',
        evtCfg: evtCfg,
        talks: talks,
        options: optsBase(),
      );
      final notes = items.where((e) => e.kind == StudioItemKind.note).toList();
      expect(notes.map((e) => e.id), contains('809999'));
    });

    test('未接入起始点的对白收进游离段', () {
      final talks = talksBase();
      talks['800099'] = {'id': 800099, 'content': '散句'};
      final items = buildStudioTree(
        evtId: '8000',
        evtCfg: evtCfg,
        talks: talks,
        options: optsBase(),
      );
      final headers = items.where((e) => e.kind == StudioItemKind.header).toList();
      expect(headers, hasLength(1));
      final orphans = items.where((e) => e.kind == StudioItemKind.talk && e.id == '800099');
      expect(orphans, hasLength(1));
      expect(orphans.first.depth, 0);
    });

    test('applyStudioCollapse 折叠夹时隐藏子树与底部接续', () {
      final items = buildStudioTree(
        evtId: '8000',
        evtCfg: evtCfg,
        talks: talksBase(),
        options: optsBase(),
      );
      final shown = applyStudioCollapse(items, {'opt:80001'});
      final ids = shown.map((e) => e.id).toList();
      expect(ids, isNot(contains('800003')));
      expect(ids, isNot(contains('800004')));
      expect(ids, contains('800001'));
      expect(ids, contains('800002'));
      // 夹标题保留，其子项（含 tail）被隐藏
      expect(ids, contains('opt:80001'));
      expect(
        shown.any((e) => e.kind == StudioItemKind.tail && e.id == 'opt:80001'),
        isFalse,
      );
    });
  });

  group('story_studio 页渲染剧情舞台', () {
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
                '8000': {
                  'id': '8000',
                  'title': '测试事件',
                  'talkId': ['800001'],
                },
              };
              break;
            case 'TalkCfg':
              data = {
                '800001': {
                  'id': 800001,
                  'roleIds': [10],
                  'content': '测试台词',
                  'nextTalk': [800002],
                  'option': ['80001'],
                },
                '800002': {'id': 800002, 'content': '第二句'},
              };
              break;
            case 'OptionCfg':
              data = {
                '80001': {'id': 80001, 'content': '测试选项', 'talkId': []},
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

    testWidgets('默认渲染：对话线树 / 选项区 / 人物与表情', (tester) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      final state = AppState();
      await tester.pumpWidget(
        fluent.FluentApp(
          home: Scaffold(
            body: ClassicPageLayouts(
              state: state,
              page: pageById('story_studio')!,
              cfgName: 'TalkCfg',
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('🎬 剧情编辑'), findsOneWidget);
      expect(find.text('剧情舞台'), findsOneWidget);
      expect(find.textContaining('对话线（'), findsOneWidget);
      expect(find.text('对话选项'), findsOneWidget);
      expect(find.text('人物与表情'), findsOneWidget);
      // 对话线卡片：两句对白 + 选项夹标题（台词同时出现在舞台编辑框与卡片预览）
      expect(find.text('测试台词'), findsAtLeastNWidgets(2));
      expect(find.text('第二句'), findsWidgets);
      expect(find.text('测试选项'), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('可切回三栏处理器形态', (tester) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      final state = AppState();
      await tester.pumpWidget(
        fluent.FluentApp(
          home: Scaffold(
            body: ClassicPageLayouts(
              state: state,
              page: pageById('story_studio')!,
              cfgName: 'TalkCfg',
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      await tester.tap(find.text('🎬 三栏处理器'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.textContaining('剧情处理器 - 正在编辑事件'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
