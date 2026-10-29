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
import 'package:student_age_editor/core/app_theme.dart';
import 'package:student_age_editor/core/models.dart';
import 'package:student_age_editor/features/pages/classic_page_layouts.dart';
import 'package:student_age_editor/features/pages/pages_catalog.dart';
import 'package:student_age_editor/features/resources/image_asset_picker.dart'
    show
        TexThumb,
        TexBytesCache,
        bgIdKeyMapOrNull,
        debugResetMergedMetaCache,
        debugMetaRetryDelay,
        debugTexRetryDelay;
import 'package:student_age_editor/features/story/portrait_keys.dart';
import 'package:student_age_editor/features/story/story_director_view.dart';
import 'package:student_age_editor/features/story/story_studio_editor.dart';

/// 1x1 透明 PNG（base64）：用作 `/api/aa/preview` 的成功响应体。
const _kPng1x1 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==';

void main() {
  // 立绘候选链解析（剧情工作台与经典导演视图共用）。
  group('portraitKeyCandidates', () {
    test('表情差分排在基础立绘之前（回归：基础立绘不得抢跑截断表情）', () {
      // 官方角色：目录只给基础立绘 role_xiaochun，官方 faces[2] 才是真差分。
      final cands = portraitKeyCandidates(
        roleId: '3',
        expr: 2,
        stageIndex: 0,
        catalogPortrait1: 'role_xiaochun',
        charKeys: {
          'base': 'role_xiaochun',
          'faces': {
            '2': {'icon_xx': 'role_xiaochun_face2'},
          },
        },
      );
      expect(cands.first, isNot('role_xiaochun'),
          reason: '选了表情 2 时不得直接命中基础立绘');
      expect(
        cands.indexOf('role_xiaochun_face2'),
        lessThan(cands.indexOf('role_xiaochun')),
        reason: '官方 faces 差分必须排在基础立绘之前',
      );
    });

    test('charKeys.faces 差分优先于 charKeys.base', () {
      final cands = portraitKeyCandidates(
        roleId: '101',
        expr: 2,
        stageIndex: 1,
        charKeys: {
          'base': 'role_101',
          'base2': 'role_101_2',
          'faces': {
            '2': {'icon': 'role_101_face2'},
          },
        },
      );
      expect(cands.first, 'role_101_face2');
      expect(
        cands.indexOf('role_101_2'),
        lessThan(cands.indexOf('role_101')),
        reason: '中学阶段 base2 差分应排在 base 之前',
      );
    });

    test('自定义角色未配置该表情时回退 0 号默认脸，不穿透回原版', () {
      final cands = portraitKeyCandidates(
        roleId: '900',
        expr: 5,
        stageIndex: 0,
        faceCfg: {
          '900000': {'id': 900000, 'icon_xx': 'role_custom_base'},
        },
        catalogPortrait1: 'role_official_900',
      );
      expect(
        cands.indexOf('role_custom_base'),
        lessThan(cands.indexOf('role_official_900')),
        reason: '自定义角色的 0 号默认脸应压过官方基础立绘',
      );
    });

    test('expr == 0 时不注入表情差分，直接给基础立绘', () {
      final cands = portraitKeyCandidates(
        roleId: '101',
        expr: 0,
        stageIndex: 0,
        catalogPortrait1: 'role_101',
        charKeys: {
          'base': 'role_101',
          'faces': {
            '2': {'icon_xx': 'role_101_face2'},
          },
        },
      );
      expect(cands, ['role_101']);
    });
  });

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
      // 贴图字节缓存是进程级全局：不清会串味（上一用例的命中/负缓存影响本用例）。
      TexBytesCache.clear();
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
                  'roles': [
                    [10, 1001, 1, 1],
                  ],
                  'bg': 100,
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
        if (path == '/api/preview/meta') {
          return http.Response(
            jsonEncode({
              'bgKeys': {'100': 'bg_classroom'},
              'charKeys': {
                '10': {'base': 'role_hero', 'base2': 'role_hero2'},
              },
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (path == '/api/roles') {
          return http.Response(
            jsonEncode({
              'roles': [
                {'id': '10', 'name': '主角', 'portrait': 'role_hero'},
                {'id': '20', 'name': '同伴', 'portrait': 'role_mate'},
              ],
            }),
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

    testWidgets('点击说话人名称弹出「更改说话人」对话框，可清空为旁白 / 改显示名',
        (tester) async {
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

      // 说话人名称（roleIds=[10] → 主角）可点击，弹出对话框。
      expect(find.text('主角 ▸'), findsOneWidget);
      await tester.tap(find.text('主角 ▸'));
      await tester.pumpAndSettle();
      expect(find.text('更改说话人'), findsOneWidget);
      expect(find.text('旁白（清空）'), findsOneWidget);

      // 清空为旁白并确认。
      await tester.tap(find.text('旁白（清空）'));
      await tester.pump();
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(find.text('旁白 ▸'), findsOneWidget);

      // 再点一次，输入自定义显示名并确认。
      await tester.tap(find.text('旁白 ▸'));
      await tester.pumpAndSettle();
      final dialog = find.byType(fluent.ContentDialog);
      await tester.enterText(
        find.descendant(of: dialog, matching: find.byType(EditableText)),
        '神秘声音',
      );
      await tester.pump();
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(find.text('神秘声音 ▸'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('舞台背景与人物立绘经合并元数据（bgKeys / charKeys）渲染', (tester) async {
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

      // 背景：TalkCfg.bg=100 → /api/preview/meta.bgKeys[100]=bg_classroom
      expect(bgIdKeyMapOrNull?['100'], 'bg_classroom');
      expect(
        find.byWidgetPredicate(
            (w) => w is TexThumb && w.keyName == 'bg_classroom'),
        findsWidgets,
        reason: '舞台背景应经 bgKeys 解析出 tex key 并渲染缩略图',
      );
      // 人物：PersonCfg 只有 name 无 url，charKeys.base 兜底 → role_hero
      expect(
        find.byWidgetPredicate((w) => w is TexThumb && w.keyName == 'role_hero'),
        findsWidgets,
        reason: '基础人物立绘应经 charKeys 兜底解析',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('舞台元数据延迟到达后自动显示背景与立绘（无需切换对白）', (tester) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      // 首帧必须拿不到合并元数据，才能复现「进入页面人物/背景是占位图」。
      debugResetMergedMetaCache();
      ApiClient.instance.client = MockClient((req) async {
        final path = req.url.path;
        if (path == '/api/preview/meta') {
          await Future<void>.delayed(const Duration(seconds: 2));
          return http.Response(
            jsonEncode({
              'bgKeys': {'100': 'bg_classroom'},
              'charKeys': {
                '10': {'base': 'role_hero', 'base2': 'role_hero2'},
              },
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (path.startsWith('/api/cfg/')) {
          final cfg = path.substring('/api/cfg/'.length);
          final Map<String, dynamic> data = switch (cfg) {
            'EvtCfg' => {
                '8000': {'id': '8000', 'title': '测试事件', 'talkId': ['800001']},
              },
            'TalkCfg' => {
                '800001': {
                  'id': 800001,
                  'roleIds': [10],
                  'roles': [
                    [10, 1001, 1, 1],
                  ],
                  'bg': 100,
                  'content': '测试台词',
                },
              },
            'PersonCfg' => {
                '10': {'id': 10, 'name': '主角'},
              },
            _ => <String, dynamic>{},
          };
          return http.Response(
            jsonEncode({'data': data, 'exists': true, 'mtime_ns': 1}),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (path == '/api/roles') {
          // 角色目录为空 → 立绘必然走 charKeys 兜底。
          return http.Response(
            jsonEncode({'roles': []}),
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

      // 元数据未到达：背景与立绘都还解析不出 key。
      expect(
        find.byWidgetPredicate(
            (w) => w is TexThumb && w.keyName == 'bg_classroom'),
        findsNothing,
      );

      // 元数据到达后：不做任何点击/切换，舞台应自动补上背景与立绘。
      await tester.pump(const Duration(seconds: 3));
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        find.byWidgetPredicate(
            (w) => w is TexThumb && w.keyName == 'bg_classroom'),
        findsWidgets,
        reason: '合并元数据异步到达后舞台背景应自动出现，无需切换对白',
      );
      expect(
        find.byWidgetPredicate((w) => w is TexThumb && w.keyName == 'role_hero'),
        findsWidgets,
        reason: '合并元数据异步到达后人物立绘应自动出现，无需切换对白',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('首次元数据请求失败后自动重试，无需换页即补齐背景与立绘', (tester) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      debugResetMergedMetaCache();
      var metaCalls = 0;
      ApiClient.instance.client = MockClient((req) async {
        final path = req.url.path;
        if (path == '/api/preview/meta') {
          metaCalls++;
          // 后端冷启动：前两次请求失败，第三次才就绪。旧实现失败即止、且把
          // 「没有结果」当终态，舞台会一直停在占位图上，只能靠用户切页重拉。
          if (metaCalls <= 2) {
            return http.Response('{"error":"backend warming up"}', 500);
          }
          return http.Response(
            jsonEncode({
              'bgKeys': {'100': 'bg_classroom'},
              'charKeys': {
                '10': {'base': 'role_hero', 'base2': 'role_hero2'},
              },
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (path.startsWith('/api/cfg/')) {
          final cfg = path.substring('/api/cfg/'.length);
          final Map<String, dynamic> data = switch (cfg) {
            'EvtCfg' => {
                '8000': {'id': '8000', 'title': '测试事件', 'talkId': ['800001']},
              },
            'TalkCfg' => {
                '800001': {
                  'id': 800001,
                  'roleIds': [10],
                  'roles': [
                    [10, 1001, 1, 1],
                  ],
                  'bg': 100,
                  'content': '测试台词',
                },
              },
            'PersonCfg' => {
                '10': {'id': 10, 'name': '主角'},
              },
            _ => <String, dynamic>{},
          };
          return http.Response(
            jsonEncode({'data': data, 'exists': true, 'mtime_ns': 1}),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (path == '/api/roles') {
          return http.Response(
            jsonEncode({'roles': []}),
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

      // 前两次失败、第三次成功：全程不做任何点击/切换，舞台应已自动补齐。
      expect(metaCalls, greaterThan(1), reason: '请求失败后应自动重试');
      expect(
        find.byWidgetPredicate(
            (w) => w is TexThumb && w.keyName == 'bg_classroom'),
        findsWidgets,
        reason: '首次请求失败后应自动重试补齐背景，无需用户换页',
      );
      expect(
        find.byWidgetPredicate((w) => w is TexThumb && w.keyName == 'role_hero'),
        findsWidgets,
        reason: '首次请求失败后应自动重试补齐立绘',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('贴图瞬时失败后组件自行重试，无需切换对白即渲染出真实图片', (tester) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      // 零延迟：走微任务立即重试，不挂假时钟定时器。
      debugTexRetryDelay = Duration.zero;
      addTearDown(() {
        debugTexRetryDelay = const Duration(milliseconds: 800);
      });
      debugResetMergedMetaCache();

      var previewCalls = 0;
      ApiClient.instance.client = MockClient((req) async {
        final path = req.url.path;
        if (path == '/api/aa/preview') {
          previewCalls++;
          // 后端冷启动：最早的两次贴图请求 5xx —— 属**瞬时失败**，不进负缓存，
          // 因此重发是有效的。旧实现把「重试」寄托在宿主重建（didUpdateWidget）
          // 上，可元数据就绪后宿主就不再重建了：组件于是永远停在占位图上，用户
          // 必须切一次对白（换 ValueKey 把组件重挂）才看得到图。
          // 本用例要求：**不做任何点击/切换**，组件自己把图救回来。
          if (previewCalls <= 2) {
            return http.Response('{"error":"texture index warming up"}', 503);
          }
          return http.Response(
            jsonEncode({'kind': 'tex', 'data': _kPng1x1}),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (path == '/api/preview/meta') {
          return http.Response(
            jsonEncode({
              'bgKeys': {'100': 'bg_classroom'},
              'charKeys': {
                '10': {'base': 'role_hero', 'base2': 'role_hero2'},
              },
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (path.startsWith('/api/cfg/')) {
          final cfg = path.substring('/api/cfg/'.length);
          final Map<String, dynamic> data = switch (cfg) {
            'EvtCfg' => {
                '8000': {'id': '8000', 'title': '测试事件', 'talkId': ['800001']},
              },
            'TalkCfg' => {
                '800001': {
                  'id': 800001,
                  'roleIds': [10],
                  'roles': [
                    [10, 1001, 1, 1],
                  ],
                  'bg': 100,
                  'content': '测试台词',
                },
              },
            'PersonCfg' => {
                '10': {'id': 10, 'name': '主角'},
              },
            _ => <String, dynamic>{},
          };
          return http.Response(
            jsonEncode({'data': data, 'exists': true, 'mtime_ns': 1}),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (path == '/api/roles') {
          // 角色目录为空 → 立绘必然走 charKeys 兜底。
          return http.Response(
            jsonEncode({'roles': []}),
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
      // 零延迟重试走微任务：多 pump 几帧即可收敛（不涉及假时钟定时器）。
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }

      expect(previewCalls, greaterThan(2),
          reason: '贴图瞬时失败后应自动重发请求，而不是等用户切对白');
      expect(
        find.byWidgetPredicate((w) =>
            w is Image && (w.image is MemoryImage || w.image is ResizeImage)),
        findsWidgets,
        reason: '瞬时失败后应自行重试并渲染出真实图片，而不是停在占位图上',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('后端返回空表（未装载模组/本体）不算已就绪：自动重拉直到有数据，无需手动刷新',
        (tester) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      debugResetMergedMetaCache();
      // 零延迟：走微任务立即重试，避免测试里挂假时钟定时器。
      debugMetaRetryDelay = Duration.zero;
      addTearDown(() {
        debugMetaRetryDelay = const Duration(seconds: 2);
        debugResetMergedMetaCache();
      });

      var metaCalls = 0;
      ApiClient.instance.client = MockClient((req) async {
        final path = req.url.path;
        if (path == '/api/preview/meta') {
          metaCalls++;
          // 后端启动早期：模组与本体数据都还没装好 → HTTP 200 但**整表为空**。
          // 旧实现把空表当终态缓存（`_bgKeysCache = {}` 非 null），而
          // `loadBgIdKeyMap` 见缓存非 null 就直接返回 → 本进程内永不再拉，
          // 舞台只能停在占位图上，直到用户手动刷新/切换对白把工作台重挂。
          final ready = metaCalls >= 4;
          return http.Response(
            jsonEncode(ready
                ? {
                    'bgKeys': {'100': 'bg_classroom'},
                    'charKeys': {
                      '10': {'base': 'role_hero', 'base2': 'role_hero2'},
                    },
                  }
                : {
                    'bgKeys': <String, String>{},
                    'charKeys': <String, dynamic>{},
                  }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (path.startsWith('/api/cfg/')) {
          final cfg = path.substring('/api/cfg/'.length);
          final Map<String, dynamic> data = switch (cfg) {
            'EvtCfg' => {
                '8000': {'id': '8000', 'title': '测试事件', 'talkId': ['800001']},
              },
            'TalkCfg' => {
                '800001': {
                  'id': 800001,
                  'roleIds': [10],
                  'roles': [
                    [10, 1001, 1, 1],
                  ],
                  'bg': 100,
                  'content': '测试台词',
                },
              },
            'PersonCfg' => {
                '10': {'id': 10, 'name': '主角'},
              },
            _ => <String, dynamic>{},
          };
          return http.Response(
            jsonEncode({'data': data, 'exists': true, 'mtime_ns': 1}),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (path == '/api/roles') {
          return http.Response(
            jsonEncode({'roles': []}),
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
      // 全程不做任何点击/切换：空表应触发自动重拉，直到拿到数据。
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      expect(metaCalls, greaterThan(1), reason: '空表必须继续重拉，不能当终态');
      expect(
        find.byWidgetPredicate(
            (w) => w is TexThumb && w.keyName == 'bg_classroom'),
        findsWidgets,
        reason: '空表自动重拉到位后背景应自动出现，无需用户手动刷新',
      );
      expect(
        find.byWidgetPredicate((w) => w is TexThumb && w.keyName == 'role_hero'),
        findsWidgets,
        reason: '空表自动重拉到位后立绘应自动出现',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('自定义立绘优先于合并元数据的原版立绘（两套素材不再打架）', (tester) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      // PersonCfg.url 是工作区自定义立绘；charKeys.base 是合并元数据里的原版立绘。
      // 两者同时存在时，舞台/卡片必须稳定取自定义，不能中途翻转成原版。
      ApiClient.instance.client = MockClient((req) async {
        final path = req.url.path;
        if (path.startsWith('/api/cfg/')) {
          final cfg = path.substring('/api/cfg/'.length);
          Map<String, dynamic> data;
          switch (cfg) {
            case 'EvtCfg':
              data = {
                '8000': {'id': '8000', 'title': 'E', 'talkId': ['800001']},
              };
              break;
            case 'TalkCfg':
              data = {
                '800001': {
                  'id': 800001,
                  'roleIds': [10],
                  'roles': [
                    [10, 1001, 1, 1],
                  ],
                  'content': '自定义立绘句',
                },
              };
              break;
            case 'PersonCfg':
              data = {
                '10': {
                  'id': 10,
                  'name': '主角',
                  'url': ['role_custom_10'],
                },
              };
              break;
            default:
              data = {};
          }
          return http.Response(
            jsonEncode({'data': data, 'exists': true}),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (path == '/api/preview/meta') {
          // bgKeys 给一个非空表：空表会被判为「未就绪」而触发自动重拉（见
          // 「后端返回空表…」用例），本用例不考察背景，只需元数据可用。
          return http.Response(
            jsonEncode({
              'bgKeys': {'999': 'bg_unused'},
              'charKeys': {
                '10': {'base': 'role_official_10'},
              },
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (path == '/api/roles') {
          return http.Response(
            jsonEncode({
              'roles': [
                {
                  'id': '10',
                  'name': '主角',
                  'portrait1': 'role_custom_10',
                  'portrait2': '',
                },
              ],
            }),
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

      expect(
        find.byWidgetPredicate(
            (w) => w is TexThumb && w.keyName == 'role_custom_10'),
        findsWidgets,
        reason: '自定义立绘（PersonCfg.url / roles.portrait1）必须压过合并元数据的原版 base',
      );
      expect(
        find.byWidgetPredicate(
            (w) => w is TexThumb && w.keyName == 'role_official_10'),
        findsNothing,
        reason: '存在自定义立绘时不得回退到原版立绘（否则会先渲染原版再跳成自定义）',
      );
      expect(
        find.byWidgetPredicate((w) =>
            w is TexThumb &&
            w.keyCandidates != null &&
            w.keyCandidates!.isNotEmpty &&
            w.keyCandidates!.first == 'role_custom_10'),
        findsWidgets,
        reason: '候选链首项应是自定义 key，供舞台/卡片/弹窗一致复用',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('对白未显式设背景时继承前置背景，且立绘支持候选降级链与镜像翻转', (tester) async {
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

      // 切换到第二句对白 800002（该对白无 bg 字段）
      await tester.tap(find.text('第二句'));
      await tester.pumpAndSettle();

      // 验证第二句承袭了 800001 的背景 100 → bg_classroom
      expect(
        find.byWidgetPredicate(
            (w) => w is TexThumb && w.keyName == 'bg_classroom'),
        findsWidgets,
        reason: '后序对白无显式 bg 时应正确继承前置有效背景',
      );

      // 验证包含候选降级列表的 TexThumb 正常工作
      expect(
        find.byWidgetPredicate((w) =>
            w is TexThumb &&
            (w.keyCandidates != null && w.keyCandidates!.isNotEmpty)),
        findsWidgets,
        reason: '立绘应附带表情差分向基础立绘回退的 keyCandidates 候选链',
      );

      // 验证包含 Transform.flip 镜像翻转控件
      expect(find.byType(Transform), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('人物登场弹窗支持人物卡片网格选择、搜索与表情切换', (tester) async {
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

      // 点击工具栏的「👤 人物登场」
      final btn = find.text('👤 人物登场').first;
      await tester.tap(btn);
      await tester.pumpAndSettle();

      // 验证弹窗标题、搜索框与人物卡片网格呈现
      expect(find.text('人物登场'), findsOneWidget);
      expect(find.text('搜索人物（中文名或 ID）…'), findsOneWidget);
      expect(find.text('从电脑选择立绘…'), findsOneWidget);
      expect(find.text('登场'), findsOneWidget);
      expect(find.text('站位:'), findsOneWidget);
      expect(find.text('表情:'), findsOneWidget);
      expect(find.text('开心'), findsOneWidget);
      expect(find.text('生气'), findsOneWidget);

      // 验证人物卡片已渲染主角与同伴
      expect(find.text('ID 10'), findsWidgets);

      // 点击表情「开心」
      await tester.tap(find.text('开心'));
      await tester.pump();
      expect(find.text('开心'), findsWidgets);

      // 点击「登场」
      await tester.tap(find.text('登场'));
      await tester.pumpAndSettle();

      // 验证弹窗关闭无异常
      expect(find.text('人物登场'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    // 回归：表情胶囊**不再**按「差分探测结果」置灰。
    //
    // 修复前这里断言「生气 · 2」全部 onTap == null（置灰）。但那个置灰是判定
    // 逻辑错误导致的假阴性：本用例的 mock 里 charKeys['10'] 没有 expressions /
    // l2d，PersonCfg['10'] 也没有 l2d，于是"找不到证据"被当成"不支持"。
    // 参考实现（友商产品#1 story.py）从不禁用表情，只把「已知支持」的表情标色，
    // 其余照常可选；游戏侧对缺失差分本就会回退基础立绘。
    testWidgets('表情胶囊一律可选（回归：不得按差分探测置灰），点选后写入本句动作', (tester) async {
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

      // 速涂区每个表情胶囊都必须可点（默认 + 所有差分位置）。
      for (final label in <String>[
        '默认 · 0',
        '开心 · 1',
        '生气 · 2',
        '难过 · 14',
        '俏皮 · 25',
      ]) {
        final gestures = tester.widgetList<GestureDetector>(
          find.ancestor(of: find.text(label), matching: find.byType(GestureDetector)),
        );
        expect(
          gestures.any((g) => g.onTap != null),
          isTrue,
          reason: '「$label」应可选：检测不到差分不等于角色不支持该表情',
        );
      }

      // 角色徽标初始显示默认表情（'生气' 精确匹配只会命中徽标，胶囊文案是 '生气 · 2'）。
      expect(find.text('生气'), findsNothing);

      await tester.tap(find.text('生气 · 2'));
      await tester.pump();

      // 点选后徽标切到「生气」，说明动作确实写入了本句。
      expect(find.text('生气'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    // 「已知支持」只做高亮提示，不做禁用：charKeys.expressions 命中的表情文字取
    // accentPale，未命中的保持 textPrimary —— 两者都可点。
    testWidgets('charKeys.expressions 命中的表情仅高亮（仍可选），未命中不高亮', (tester) async {
      ApiClient.instance.client = MockClient((req) async {
        final path = req.url.path;
        if (path == '/api/preview/meta') {
          return http.Response(
            jsonEncode({
              'bgKeys': {'100': 'bg_classroom'},
              'charKeys': {
                // 只声明 0/1/2 支持 → 3（伤心）不在集合内，但仍必须可选。
                '10': {
                  'base': 'role_hero',
                  'base2': 'role_hero2',
                  'expressions': [0, 1, 2],
                },
              },
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (path == '/api/roles') {
          return http.Response(
            jsonEncode({'roles': []}),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (path.startsWith('/api/cfg/')) {
          final cfg = path.substring('/api/cfg/'.length);
          final Map<String, dynamic> data = switch (cfg) {
            'EvtCfg' => {
                '8000': {'id': '8000', 'title': '测试事件', 'talkId': ['800001']},
              },
            'TalkCfg' => {
                '800001': {
                  'id': 800001,
                  'roleIds': [10],
                  'roles': [
                    [10, 1001, 1, 1],
                  ],
                  'bg': 100,
                  'content': '测试台词',
                },
              },
            'PersonCfg' => {
                '10': {'id': 10, 'name': '主角'},
              },
            _ => <String, dynamic>{},
          };
          return http.Response(
            jsonEncode({'data': data, 'exists': true, 'mtime_ns': 1}),
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

      Color? pillTextColor(String label) {
        final t = tester
            .widgetList<Text>(find.byType(Text))
            .firstWhere((w) => w.data == label);
        return t.style?.color;
      }

      // 命中 expressions 的「开心 · 1」被高亮。
      expect(pillTextColor('开心 · 1'), AppTheme.palette.accentPale,
          reason: 'expressions 命中的表情应高亮为 accentPale');
      // 未命中的「伤心 · 3」保持正文色，但依然可点。
      expect(pillTextColor('伤心 · 3'), isNot(AppTheme.palette.accentPale),
          reason: '未命中的表情不应高亮（但仍可点）');
      final sadness = tester.widgetList<GestureDetector>(
        find.ancestor(of: find.text('伤心 · 3'), matching: find.byType(GestureDetector)),
      );
      expect(sadness.any((g) => g.onTap != null), isTrue);

      await tester.tap(find.text('伤心 · 3'));
      await tester.pump();
      expect(find.text('伤心'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  // 回归：合并元数据（bgKeys / charKeys）比整表慢，到达后舞台必须**自动**刷新出
  // 人物立绘与背景，而不是停在占位图上、等用户切换对白（换页）才显示。
  group('舞台元数据异步到达后自动刷新（无需切换对白）', () {
    testWidgets('剧情处理器：bgKeys/charKeys 延迟到达后背景与立绘自动出现', (tester) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      // 清掉跨用例的进程级缓存，保证「首帧拿不到映射」这一前提成立。
      debugResetMergedMetaCache();
      SharedPreferences.setMockInitialValues({});
      ApiClient.instance.client = MockClient((req) async {
        final path = req.url.path;
        if (path == '/api/preview/meta') {
          // 模拟合并元数据明显慢于整表加载。
          await Future<void>.delayed(const Duration(seconds: 2));
          return http.Response(
            jsonEncode({
              'bgKeys': {'100': 'bg_classroom'},
              'charKeys': {
                '10': {'base': 'role_hero', 'base2': 'role_hero2'},
              },
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (path == '/api/roles') {
          // 角色目录为空 → 立绘必然走 charKeys 兜底分支（回归字段读取类型错误）。
          return http.Response(
            jsonEncode({'roles': []}),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (path.startsWith('/api/cfg/')) {
          final cfg = path.substring('/api/cfg/'.length);
          final Map<String, dynamic> data = switch (cfg) {
            'EvtCfg' => {
                '8000': {
                  'id': 8000,
                  'title': '测试事件',
                  'type': 0,
                  'talkId': [800001],
                },
              },
            'TalkCfg' => {
                '800001': {
                  'id': 800001,
                  'roleIds': [10],
                  'roles': ['2,10,3000'],
                  'bg': 100,
                  'content': '舞台台词',
                },
              },
            _ => <String, dynamic>{},
          };
          return http.Response(
            jsonEncode({'data': data, 'exists': true, 'mtime_ns': 1}),
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
      addTearDown(() => ApiClient.instance.client = http.Client());

      final state = AppState();
      await tester.pumpWidget(
        fluent.FluentApp(
          home: Scaffold(
            body: StoryDirectorView(state: state, classic: true),
          ),
        ),
      );
      // 整表已到、元数据未到：此刻只有占位图，不应有任何异常。
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        find.byWidgetPredicate(
            (w) => w is TexThumb && w.keyName == 'bg_classroom'),
        findsNothing,
        reason: '合并元数据未到达前舞台只能显示占位图',
      );
      expect(tester.takeException(), isNull);

      // 元数据到达：不点任何按钮、不切换对白，舞台应自动重建出立绘与背景。
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();
      expect(
        find.byWidgetPredicate(
            (w) => w is TexThumb && w.keyName == 'bg_classroom'),
        findsWidgets,
        reason: '合并元数据到达后舞台应自动显示背景，无需用户切换对白',
      );
      expect(
        find.byWidgetPredicate((w) => w is TexThumb && w.keyName == 'role_hero'),
        findsWidgets,
        reason: 'charKeys.base 兜底立绘应可解析（字段类型读取错误会抛异常）',
      );
      expect(tester.takeException(), isNull);
    });
  });
}

