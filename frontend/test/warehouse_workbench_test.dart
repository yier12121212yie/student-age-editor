// 物品仓库工作台（导演布局「物品仓库」专属界面）冒烟测试：三栏渲染、物品/商店
// 模式切换、标签切换置脏、效果指令打开积木库、保存写表、窄窗不溢出、
// 导演主页卡片进入。
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
import 'package:student_age_editor/features/warehouse/warehouse_workbench.dart';

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
          case 'ItemCfg':
            data = {
              '1': {
                'id': 1,
                'name': '苹果',
                'icon': 'item_apple',
                'type': 1,
                'itemTag': [5],
                'effect': <dynamic>[],
                'usingEffect': <dynamic>[],
                'value': 5,
                'sell': 3,
                'desc': '一个苹果',
                'talkId': 0,
                'maxcount': 99,
                'btn': '吃',
                'clothType': 0,
                'needDLC': 0,
                'precondition': <dynamic>[],
                'rarity': 1,
                'sex': 0,
                'subType': 0,
              },
            };
            break;
          case 'BookCfg':
            data = {
              '300': {
                'id': 300,
                'name': '语文书',
                'type': 3001,
                'icon': '',
                'itemTag': <dynamic>[],
                'capacity': 10,
                'effect': <dynamic>[],
                'value': -1,
                'sell': -1,
                'desc': '课本书',
                'themes': <dynamic>[],
                'need': <dynamic>[],
                'precondition': <dynamic>[],
                'talk': '',
                'usingEffect': <dynamic>[],
              },
            };
            break;
          case 'ShopCfg':
            data = {
              '1': {
                'id': 1,
                'group': 0,
                'price': 10,
                'next': 0,
                'time': 0,
                'discountRound': 0,
                'type': 1,
                'maxcount': 0,
                'precondition': <dynamic>[],
                'probability': 1,
                'buyTalk': '欢迎光临',
                'disappearTime': 0,
                'limcount': 0,
              },
            };
            break;
          case 'ItemTypeCfg':
            data = {
              '1': {'id': 1, 'name': '消耗品'},
              '2': {'id': 2, 'name': '珍视物品'},
              '3': {'id': 3, 'name': '书籍'},
              '3001': {'id': 3001, 'name': '故事书'},
            };
            break;
          case 'ItemTagCfg':
            data = {
              '5': {'id': 5, 'name': '食物'},
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
      if (path == '/api/effect_suggest') {
        return http.Response(
          jsonEncode({
            'items': [
              {
                'code': '[1, 1, V]',
                'desc': '年龄 >= V',
                'raw_code': '[1, 1, V]',
                'slots': [
                  {'kind': 'number', 'name': 'V', 'count': 1}
                ],
              },
            ],
            'mode': 'effect',
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (path == '/api/effect/parse') {
        final body = jsonDecode(req.body) as Map;
        return http.Response(
          jsonEncode({
            'ok': true,
            'rows': [
              {
                'primary': 1,
                'secondary': 1,
                'negate': false,
                'display': body['text'],
                'template': {'code': body['text'], 'desc': '测试效果'},
                'slots': <dynamic>[],
                'nested': <dynamic>[],
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
        home: WarehouseWorkbench(state: AppState()..modName = '测试模组'),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  testWidgets('物品仓库：三栏渲染 + 物品列表', (tester) async {
    await pumpWorkbench(tester, const Size(1500, 950));

    expect(tester.takeException(), isNull, reason: '物品仓库渲染不应异常');
    expect(find.text('＋ 新建物品'), findsOneWidget);
    expect(find.text('物品信息'), findsWidgets);
    expect(find.text('苹果'), findsWidgets);
    expect(find.text('语文书'), findsWidgets);
    expect(find.text('游戏内预览'), findsOneWidget);
    expect(find.text('共 2 项'), findsOneWidget);
  });

  testWidgets('物品仓库：切换到商店模式', (tester) async {
    await pumpWorkbench(tester, const Size(1500, 950));

    await tester.tap(find.text('商店'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('＋ 上架商品'), findsOneWidget);
    expect(find.text('¥ 10'), findsWidgets);
    expect(find.text('店员台词'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('物品仓库：标签页切换标签置脏', (tester) async {
    await pumpWorkbench(tester, const Size(1500, 950));

    await tester.tap(find.text('标签').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('物品标签'), findsOneWidget);

    await tester.tap(find.text('食物').first);
    await tester.pump();
    expect(find.text('有未保存的修改'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('物品仓库：效果指令打开积木库', (tester) async {
    await pumpWorkbench(tester, const Size(1500, 950));

    await tester.tap(find.text('效果指令'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    await tester.tap(find.text('打开积木库').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('积木库 · 获得 / 阅读效果'), findsWidgets);
    expect(find.text('应用'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('物品仓库：保存写回 ItemCfg', (tester) async {
    await pumpWorkbench(tester, const Size(1500, 950));

    await tester.tap(find.text('标签').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.text('食物').first);
    await tester.pump();
    await tester.tap(find.text('保存修改'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(putPaths, contains('ItemCfg'));
    // 等 InfoBar 自动关闭，避免遗留定时器。
    await tester.pump(const Duration(seconds: 4));
    expect(tester.takeException(), isNull);
  });

  testWidgets('物品仓库：800x600 无像素溢出', (tester) async {
    await pumpWorkbench(tester, const Size(800, 600));
    expect(tester.takeException(), isNull, reason: '窄窗不应溢出');
  });

  testWidgets('导演主页「物品仓库」卡片进入', (tester) async {
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

    await tester.tap(find.text('物品仓库').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('＋ 新建物品'), findsOneWidget);
    expect(find.text('游戏内预览'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
