// 人物工作台（导演布局的人物专属界面）冒烟测试：三栏渲染、标签切换、
// 窄窗不溢出，以及从导演主页卡片进入。
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_age_editor/core/api_client.dart';
import 'package:student_age_editor/core/models.dart';
import 'package:student_age_editor/core/plugin_state.dart';
import 'package:student_age_editor/core/ui_mode.dart';
import 'package:student_age_editor/features/person/person_workbench.dart';
import 'package:student_age_editor/features/shell/director_shell.dart';
import 'package:student_age_editor/features/shell/shell_state.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ApiClient.instance.client = MockClient((req) async {
      final path = req.url.path;
      if (path.startsWith('/api/cfg/')) {
        final cfg = path.substring('/api/cfg/'.length);
        Map<String, dynamic> data;
        switch (cfg) {
          case 'PersonCfg':
            data = {
              '10': {
                'id': 10,
                'name': '测试人物',
                'gender': 2,
                'birthday': [1995, 3, 15],
                'url': ['role_full/p1.png'],
                'url2': ['role_full/p2.png'],
              },
            };
            break;
          case 'PersonGrowCfg':
            data = {
              '10': {
                'id': 10,
                'attr': [5, 6, 7],
                'grow': [
                  [1, 1, 1],
                ],
                'ItemPref': [
                  [1, 3],
                ],
                'personalitys': [10, 0, 0, 10, 10, 0, 0, 10],
              },
            };
            break;
          case 'ModFaceCfg':
            data = {
              '10000': {
                'id': 10000,
                'name': '默认',
                'icon': 'face/i.png',
                'icon_xx': 'face/i.png',
              },
            };
            break;
          case 'PersonAttrCfg':
            data = {
              '1': {'id': 1, 'name': ['智力']},
            };
            break;
          case 'TraitsCfg':
            data = {
              '1': {'id': 1, 'name': '开朗'},
            };
            break;
          case 'PersonStateCfg':
            data = {
              '1': {'id': 1, 'name': '生病'},
            };
            break;
          case 'ItemTagCfg':
            data = {
              '1': {'id': 1, 'name': '食物'},
            };
            break;
          default:
            data = {};
        }
        return http.Response(
          jsonEncode({'data': data, 'exists': true, 'mtime_ns': 1}),
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
                'name': '测试人物',
                'portrait1': 'role_full/p1.png',
                'portrait2': 'role_full/p2.png',
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
  });

  tearDown(() {
    ApiClient.instance.client = http.Client();
  });

  Future<void> pumpWorkbench(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      fluent.FluentApp(
        debugShowCheckedModeBanner: false,
        home: PersonWorkbench(state: AppState()..modName = '测试模组'),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('人物工作台：三栏渲染 + 四个标签', (tester) async {
    await pumpWorkbench(tester, const Size(1600, 1000));

    expect(tester.takeException(), isNull, reason: '人物工作台渲染不应异常');
    // 左栏人物 + 中栏标题 + 右栏预览名
    expect(find.text('测试人物'), findsWidgets);
    // 四个标签都在
    expect(find.text('人物资料'), findsOneWidget);
    expect(find.text('成长与喜好'), findsOneWidget);
    expect(find.text('表情与服装'), findsOneWidget);
    expect(find.text('图片与大小'), findsOneWidget);
    // 资料页基础字段
    expect(find.text('基础资料'), findsOneWidget);
    expect(find.text('立绘'), findsWidgets);
  });

  testWidgets('人物工作台：标签切换无异常', (tester) async {
    await pumpWorkbench(tester, const Size(1600, 1000));

    await tester.tap(find.text('成长与喜好'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('初始属性'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('表情与服装'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('服装'), findsWidgets);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('图片与大小'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('立绘排版参数'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('人物工作台：800x600 无像素溢出', (tester) async {
    await pumpWorkbench(tester, const Size(800, 600));
    expect(tester.takeException(), isNull, reason: '窄窗不应溢出');
  });

  testWidgets('导演主页「人物」卡片进入人物工作台', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(
      fluent.FluentApp(
        debugShowCheckedModeBanner: false,
        home: DirectorShell(
          state: AppState()..modName = '测试模组',
          shell: ShellState()..setAiOpen(false),
          pluginState: PluginState(),
          uiMode: UiMode.director,
          onUiModeChanged: (_) {},
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // 主页卡片「人物」→ 人物工作台（出现四个标签）。
    await tester.tap(find.text('人物').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('人物资料'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('人物工作台：删除角色需确认', (tester) async {
    await pumpWorkbench(tester, const Size(1600, 1000));

    // 新增一个人物：数据变脏、删除按钮可用。
    await tester.tap(find.text('＋ 添加角色'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    await tester.tap(find.text('删除角色'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('确认删除'), findsOneWidget, reason: '删除前应弹确认');

    // 取消：人物仍在。
    await tester.tap(find.text('取消'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('确认删除'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('人物工作台：脏数据注册离开守卫，取消则中止', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    final state = AppState()..modName = '测试模组';
    await tester.pumpWidget(
      fluent.FluentApp(
        debugShowCheckedModeBanner: false,
        home: PersonWorkbench(state: state),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    await tester.tap(find.text('＋ 添加角色'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    final leave = state.runLeaveGuards();
    await tester.pump();
    expect(find.text('有未保存的修改'), findsWidgets, reason: '脏数据应触发离开确认');
    await tester.tap(find.text('取消').first);
    await tester.pump();
    expect(await leave, isFalse, reason: '取消后应中止离开');
    await tester.pumpAndSettle(const Duration(milliseconds: 400));
  });
}
