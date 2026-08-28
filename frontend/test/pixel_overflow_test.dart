import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_age_editor/core/api_client.dart';
import 'package:student_age_editor/core/models.dart';
import 'package:student_age_editor/core/ui_mode.dart';
import 'package:student_age_editor/features/base/base_search_page.dart';
import 'package:student_age_editor/features/bugfix/bugfix_panel.dart';
import 'package:student_age_editor/features/editor/editor_controller.dart';
import 'package:student_age_editor/features/editor/schema_editor_view.dart';
import 'package:student_age_editor/features/pages/classic_page_layouts.dart';
import 'package:student_age_editor/features/pages/page_view.dart';
import 'package:student_age_editor/features/pages/pages_catalog.dart';
import 'package:student_age_editor/features/preview/event_preview_view.dart';
import 'package:student_age_editor/features/resources/pack_manager_page.dart';
import 'package:student_age_editor/features/settings/settings_page.dart';
import 'package:student_age_editor/features/shell/classic_shell.dart';
import 'package:student_age_editor/features/shell/mobile_shell.dart';
import 'package:student_age_editor/features/shell/shell_state.dart';
import 'package:student_age_editor/features/story/story_director_view.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ApiClient.instance.client = MockClient((req) async {
      final path = req.url.path;
      if (path.startsWith('/api/cfg/')) {
        final cfg = path.substring('/api/cfg/'.length);
        if (cfg == 'EvtCfg') {
          return http.Response(
            jsonEncode({
              'data': {
                '8000': {'id': '8000', 'title': '测试事件标题特别长很长的一段描述用于测试UI溢出表现', 'talkIds': ['800001']},
              },
              'exists': true,
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        } else if (cfg == 'TalkCfg') {
          return http.Response(
            jsonEncode({
              'data': {
                '800001': {
                  'id': 800001,
                  'roleIds': [10, 11],
                  'roleName': '神秘角色测试名称',
                  'content': '这是一句很长很长很长的台词内容用于测试对话框的折行与布局适应能力，看看会不会导致像素溢出',
                  'roles': ['0,10,3000', '2,11,3001'],
                  'highlights': [10],
                  'bg': 100,
                  'audio': 101,
                  'nextTalk': [800002],
                  'option': ['800001_1'],
                },
              },
              'exists': true,
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        } else if (cfg == 'OptionCfg') {
          return http.Response(
            jsonEncode({
              'data': {
                '800001_1': {'id': '800001_1', 'content': '这是一个测试选项文本特别长', 'talkId': [800002]},
              },
              'exists': true,
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        } else if (cfg == 'PersonCfg') {
          return http.Response(
            jsonEncode({
              'data': {
                '10': {'id': 10, 'name': '主角名称很长很长', 'desc': '主角描述'},
                '11': {'id': 11, 'name': '配角名称', 'desc': '配角描述'},
              },
              'exists': true,
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        } else if (cfg == 'BgCfg' || cfg == 'AudioCfg' || cfg == 'EvtTypeCfg') {
          return http.Response(
            jsonEncode({
              'data': {
                '100': {'name': '测试背景'},
                '101': {'name': '测试音频'},
              },
              'exists': true,
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response(
          jsonEncode({
            'data': {
              '100': {'id': 100, 'name': '通用测试条目名称非常长用来验证UI', 'desc': '描述信息'},
            },
            'exists': true,
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (path == '/api/state') {
        return http.Response(
          jsonEncode({'mod_name': '测试超长模组路径_TestMod_Very_Long_Name_Directory', 'ok': true}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (path == '/api/manifest/status') {
        return http.Response(
          jsonEncode({'items': [], 'ok': true}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response(jsonEncode({'data': {}}), 200, headers: {'content-type': 'application/json'});
    });
  });

  tearDown(() {
    ApiClient.instance.client = http.Client();
  });

  final testSizes = [
    const Size(1920, 1080),
    const Size(1366, 768),
    const Size(1280, 720),
    const Size(1024, 768),
    const Size(800, 600),
  ];

  for (final size in testSizes) {
    testWidgets('ClassicShell 在尺寸 ${size.width}x${size.height} 下无像素溢出', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      final state = AppState();
      state.modName = '测试超长模组路径_TestMod_Very_Long_Name_Directory';
      final shell = ShellState();

      await tester.pumpWidget(
        fluent.FluentApp(
          home: Scaffold(
            body: ClassicShell(
              state: state,
              shell: shell,
              uiMode: UiMode.classic,
              onUiModeChanged: (_) {},
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(tester.takeException(), isNull, reason: 'ClassicShell 在 ${size.width}x${size.height} 不应溢出');

      // 打开 AI 面板测试
      shell.toggleAi();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(tester.takeException(), isNull, reason: 'ClassicShell 打开 AI 面板在 ${size.width}x${size.height} 不应溢出');
    });

    testWidgets('StoryDirectorView (classic) 在尺寸 ${size.width}x${size.height} 下无像素溢出', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      final state = AppState();
      await tester.pumpWidget(
        fluent.FluentApp(
          home: Scaffold(
            body: StoryDirectorView(
              state: state,
              classic: true,
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.takeException(), isNull, reason: 'StoryDirectorView 在 ${size.width}x${size.height} 不应溢出');
    });

    testWidgets('ClassicPageLayouts 所有页面在尺寸 ${size.width}x${size.height} 下无像素溢出', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      final state = AppState();
      final pagesToTest = ['person', 'resource', 'function', 'story', 'social', 'love', 'official'];

      for (final pageId in pagesToTest) {
        final pageDef = pageById(pageId) ?? editorPages.first;
        await tester.pumpWidget(
          fluent.FluentApp(
            home: Scaffold(
              body: SizedBox(
                width: size.width - 200, // 减去左侧导航栏宽度
                height: size.height - 120, // 减去顶栏和状态栏
                child: ClassicPageLayouts(
                  state: state,
                  page: pageDef,
                  cfgName: pageDef.defaultCfg,
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));
        expect(tester.takeException(), isNull, reason: '页面 $pageId 在 ${size.width}x${size.height} 不应溢出');
      }
    });

    testWidgets('EventPreviewView 在尺寸 ${size.width}x${size.height} 下无像素溢出', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      final state = AppState();
      final controller = EditorController();
      await tester.pumpWidget(
        fluent.FluentApp(
          home: Scaffold(
            body: EventPreviewView(
              state: state,
              eventId: '8000',
              controller: controller,
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(tester.takeException(), isNull, reason: 'EventPreviewView 在 ${size.width}x${size.height} 不应溢出');
    });

    testWidgets('SettingsPage / BugfixPanel / BaseSearchPage 在尺寸 ${size.width}x${size.height} 下无像素溢出', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      final state = AppState();
      final shell = ShellState();

      await tester.pumpWidget(
        fluent.FluentApp(
          home: Scaffold(
            body: Column(
              children: [
                Expanded(
                  child: Row(
                    children: [
                      Expanded(child: SettingsPage(settings: shell.aiSettings, onChanged: (_) {}, uiMode: UiMode.classic, onUiModeChanged: (_) {})),
                      Expanded(child: BugfixPanel(state: state)),
                      Expanded(child: BaseSearchPage(state: state)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(tester.takeException(), isNull, reason: '辅助面板在 ${size.width}x${size.height} 不应溢出');
    });
  }

  // ---------- 移动端（宽 < 720） ----------
  const mobileSizes = [
    Size(390, 844),
    Size(360, 800),
    Size(414, 896),
  ];

  for (final size in mobileSizes) {
    testWidgets('MobileShell 全部 tab 在 ${size.width}x${size.height} 下无像素溢出', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      final state = AppState();
      state.modName = '测试模组';
      final shell = ShellState();

      await tester.pumpWidget(
        fluent.FluentApp(
          home: MobileShell(
            state: state,
            shell: shell,
            uiMode: UiMode.creation,
            onUiModeChanged: (_) {},
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.takeException(), isNull, reason: 'MobileShell 模组 tab 在 ${size.width}x${size.height} 不应溢出');
      for (final label in ['页面', '文件', '编辑', '更多']) {
        await tester.tap(find.text(label).last);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        expect(tester.takeException(), isNull, reason: 'MobileShell $label tab 在 ${size.width}x${size.height} 不应溢出');
      }
    });
  }

  testWidgets('SchemaEditorView 移动端列表→表单页在 390x844 下无像素溢出', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() => tester.view.resetPhysicalSize());

    final state = AppState();
    await tester.pumpWidget(
      fluent.FluentApp(
        home: Scaffold(body: SchemaEditorView(state: state, cfgName: 'EvtCfg')),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull, reason: '移动端条目列表不应溢出');
    // 点第一个条目 → 推入移动端表单页
    await tester.tap(find.textContaining('测试事件标题').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.takeException(), isNull, reason: '移动端表单页不应溢出');
    expect(find.text('保存'), findsWidgets, reason: '表单页 AppBar 应有保存按钮');
  });

  testWidgets('EditorPageView story 页在移动端显示桌面端占位（390x844）', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() => tester.view.resetPhysicalSize());

    final state = AppState();
    final page = pageById('story') ?? editorPages.first;
    await tester.pumpWidget(
      fluent.FluentApp(
        home: Scaffold(body: EditorPageView(state: state, page: page)),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.takeException(), isNull);
    expect(find.text('剧情导演请在桌面端使用'), findsOneWidget);
  });

  testWidgets('PackManagerPage 在移动端 390x844 下无像素溢出', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() => tester.view.resetPhysicalSize());

    final state = AppState();
    await tester.pumpWidget(
      fluent.FluentApp(
        home: Scaffold(body: PackManagerPage(state: state)),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
    expect(find.textContaining('未安装任何资源包'), findsOneWidget);
  });
}
