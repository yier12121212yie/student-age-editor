// 空间工作台（导演布局「空间」专属界面）冒烟测试：三栏渲染、空间预览、留言板
// 添加留言置脏、空间设置切换置脏、双表保存、窄窗不溢出、导演主页卡片进入。
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
import 'package:student_age_editor/features/shell/director_shell.dart';
import 'package:student_age_editor/features/shell/shell_state.dart';
import 'package:student_age_editor/features/space/space_workbench.dart';

void main() {
  final putPaths = <String>[];

  setUp(() {
    putPaths.clear();
    SharedPreferences.setMockInitialValues({});
    ApiClient.instance.client = MockClient((req) async {
      final path = req.url.path;
      if (path.startsWith('/api/cfg/')) {
        if (req.method == 'PUT') {
          putPaths.add(path.substring('/api/cfg/'.length));
          final body = jsonDecode(req.body) as Map;
          return http.Response(
            jsonEncode({'data': body['data'], 'mtime_ns': 2}),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        final cfg = path.substring('/api/cfg/'.length);
        Map<String, dynamic> data;
        switch (cfg) {
          case 'KZoneProfileCfg':
            data = {
              '1': {
                'id': 1,
                'name': '小雨',
                'desc': '记录每一天',
                'marriage': [0],
                'hometown': '北京',
                'living': '上海',
                'job': '学生',
                'school': '希望中学',
                'isVip': 1,
                'theme': 1,
                'bgm': 0,
                'font': 101,
                'fontColor': 0,
                'fontSize': 40,
                'icon': 0,
              },
            };
            break;
          case 'KZoneMessageBoardCfg':
            data = {
              '1': {
                'id': 1,
                'roles': [10, 1],
                'content': '生日快乐！',
                'isPrivate': 0,
                'round': 0,
                'reply': 0,
                'cond': <dynamic>[],
              },
            };
            break;
          case 'KZoneAvatarCfg':
            data = {
              '1': {'id': 1, 'icon': 'avatar_1', 'state': 0, 'type': 0},
            };
            break;
          case 'KZoneColorCfg':
            data = {
              '1': {
                'id': 1,
                'name': '经典蓝',
                'bg': '#EAF6FF',
                'imgColor': '#4A90D9',
                'navBg': '#4A90D9',
                'nameTxt': '#FFFFFF',
              },
            };
            break;
          case 'KZoneFontCfg':
            data = {
              '101': {'id': 101, 'name': '默认字体'},
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
              {'id': '1', 'name': '林小雨', 'portrait1': '', 'portrait2': ''},
              {'id': '10', 'name': '白雨', 'portrait1': '', 'portrait2': ''},
              {'id': '20', 'name': '王小明', 'portrait1': '', 'portrait2': ''},
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
        home: SpaceWorkbench(state: AppState()..modName = '测试模组'),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  testWidgets('空间工作台：三栏渲染 + 空间预览', (tester) async {
    await pumpWorkbench(tester, const Size(1500, 950));

    expect(tester.takeException(), isNull, reason: '空间工作台渲染不应异常');
    expect(find.text('＋ 为人物添加空间'), findsOneWidget);
    expect(find.text('空间设置'), findsOneWidget);
    expect(find.text('林小雨'), findsWidgets);
    expect(find.text('小雨'), findsWidgets);
    expect(find.text('记录每一天'), findsWidgets);
    // 导航标签与右侧分段按钮都含「留言板」。
    expect(find.text('留言板'), findsWidgets);
    expect(find.text('个人档'), findsWidgets);
  });

  testWidgets('空间工作台：留言板添加留言并置脏', (tester) async {
    await pumpWorkbench(tester, const Size(1500, 950));

    await tester.tap(find.text('留言板').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.textContaining('留言板（1）'), findsOneWidget);

    await tester.tap(find.text('＋ 添加留言'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('选择留言人物'), findsOneWidget);

    await tester.tap(find.text('王小明'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.textContaining('留言板（2）'), findsOneWidget);
    expect(find.text('有未保存的修改'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('空间工作台：空间设置切换黄钻置脏', (tester) async {
    await pumpWorkbench(tester, const Size(1500, 950));

    await tester.tap(find.text('已开通'));
    await tester.pump();
    expect(find.text('未开通'), findsOneWidget);
    expect(find.text('有未保存的修改'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('空间工作台：保存同时写空间资料与留言板', (tester) async {
    await pumpWorkbench(tester, const Size(1500, 950));

    // 资料：切换黄钻；留言板：添加一条。
    await tester.tap(find.text('已开通'));
    await tester.pump();
    await tester.tap(find.text('留言板').last);
    await tester.pump();
    await tester.tap(find.text('＋ 添加留言'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('王小明'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.text('保存修改'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(putPaths, contains('KZoneProfileCfg'));
    expect(putPaths, contains('KZoneMessageBoardCfg'));
    // 等 InfoBar 自动关闭，避免遗留定时器。
    await tester.pump(const Duration(seconds: 4));
    expect(tester.takeException(), isNull);
  });

  testWidgets('空间工作台：800x600 无像素溢出', (tester) async {
    await pumpWorkbench(tester, const Size(800, 600));
    expect(tester.takeException(), isNull, reason: '窄窗不应溢出');
  });

  testWidgets('导演主页「空间」卡片进入空间工作台', (tester) async {
    tester.view.physicalSize = const Size(1500, 950);
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

    await tester.tap(find.text('空间').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('＋ 为人物添加空间'), findsOneWidget);
    expect(find.text('空间设置'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
