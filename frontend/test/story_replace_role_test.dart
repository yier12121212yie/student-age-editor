// 「点击人物更换角色」测试：
//  1. 纯函数 replaceStageRole：显式在场改写角色 ID；继承在场生成旧角色退场 +
//     新角色同站位/表情入场；可选站位/表情/镜像补齐。
//  2. 纯函数 replaceRoleRef：说话人（roleIds）与高亮（highlights）联动替换。
//  3. 剧情舞台工作台：点击在场立绘弹出「更换人物」对话框，确认后舞台与说话人同步。
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
import 'package:student_age_editor/features/resources/image_asset_picker.dart'
    show TexBytesCache, TexThumb, debugResetMergedMetaCache;
import 'package:student_age_editor/features/story/story_logic.dart';

void main() {
  group('replaceStageRole · 显式在场', () {
    test('改写角色 ID，入场/表情等指令随角色迁移', () {
      final out = replaceStageRole([
        [10, 1001, 1, 1],
        [10, 3000, 5],
        [20, 1002, 1, 3],
      ], '10', '101');
      expect(out, [
        [101, 1001, 1, 1],
        [101, 3000, 5],
        [20, 1002, 1, 3],
      ]);
    });

    test('显式传入 pos/expr 时更新为新值，flip=false 移除镜像', () {
      final out = replaceStageRole([
        [10, 1001, 1, 1],
        [10, 3000, 5],
        [10, 3007],
      ], '10', '101', pos: 2, expr: 8, flip: false);
      expect(out, [
        [101, 1001, 1, 2],
        [101, 3000, 8],
      ]);
    });

    test('flip=true 时补一条镜像指令', () {
      final out = replaceStageRole([
        [10, 1001, 1, 3],
      ], '10', '101', flip: true);
      expect(out, [
        [101, 1001, 1, 3],
        [101, 3007],
      ]);
    });

    test('新旧角色相同或空 ID 时原样返回（不修改入参）', () {
      final roles = <dynamic>[
        [10, 1001, 1, 1],
      ];
      expect(replaceStageRole(roles, '10', '10'), roles);
      expect(replaceStageRole(roles, '', '20'), roles);
      expect(roles, [
        [10, 1001, 1, 1],
      ], reason: '纯函数不得原地修改入参');
    });
  });

  group('replaceStageRole · 继承在场', () {
    test('旧角色退场 + 新角色按相同站位与表情入场', () {
      final out = replaceStageRole([
        [20, 1001, 1, 2],
      ], '10', '101', pos: 1, expr: 3);
      expect(out, [
        [20, 1001, 1, 2],
        [10, 2001],
        [101, 1001, 1, 1],
        [101, 3000, 3],
      ]);
    });

    test('继承且 flip=true 追加镜像指令', () {
      final out = replaceStageRole(<dynamic>[], '10', '101', pos: 3, flip: true);
      expect(out, [
        [10, 2001],
        [101, 1001, 1, 3],
        [101, 3007],
      ]);
    });
  });

  group('replaceRoleRef · 说话人/高亮联动', () {
    test('命中时替换，保持数值口径并去重', () {
      expect(replaceRoleRef([10, 20], '10', '101'), [101, 20]);
      expect(replaceRoleRef([10, 10, 20], '10', '101'), [101, 20]);
      expect(replaceRoleRef('10', '10', '101'), [101]);
    });

    test('未命中或空值时安全返回', () {
      expect(replaceRoleRef([10, 20], '99', '101'), [10, 20]);
      expect(replaceRoleRef(null, '10', '101'), isEmpty);
    });
  });

  group('剧情舞台 · 点击立绘更换角色', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      TexBytesCache.clear();
      debugResetMergedMetaCache();
      ApiClient.instance.client = MockClient((req) async {
        final path = req.url.path;
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
                  'highlights': [10],
                  'roles': [
                    [10, 1001, 1, 1],
                    [10, 3000, 0],
                  ],
                  'content': '测试台词',
                },
              },
            'PersonCfg' => {
                '10': {'id': 10, 'name': '主角'},
                '20': {'id': 20, 'name': '同伴'},
              },
            _ => <String, dynamic>{},
          };
          return http.Response(
            jsonEncode({'data': data, 'exists': true, 'mtime_ns': 1}),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (path == '/api/preview/meta') {
          return http.Response(
            jsonEncode({
              'bgKeys': {'100': 'bg_classroom'},
              'charKeys': {
                '10': {'base': 'role_hero'},
                '20': {'base': 'role_mate'},
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

    testWidgets('点击在场立绘 → 更换人物 → 舞台与说话人同步为新角色', (tester) async {
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

      // 初始：舞台立绘浮标为「主角 · 默认」，说话人为主角。
      expect(find.text('主角 · 默认'), findsOneWidget);
      expect(find.text('主角 ▸'), findsOneWidget);

      // 点击立绘上半部（避免被沉底对白框遮挡测试命中的中心点）直接呼出「更换人物」。
      final rect = tester.getRect(find.byTooltip('点击更换人物 ([10] 主角)'));
      await tester.tapAt(Offset(rect.center.dx, rect.top + 30));
      await tester.pumpAndSettle();
      expect(find.text('更换人物：[10] 主角'), findsOneWidget);
      expect(find.text('确定更换'), findsOneWidget);

      // 选择「同伴」并确认更换（等待 350ms 决出单选，避开 doubleTap 探测锁）。
      await tester.tap(find.text('同伴').last);
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确定更换'));
      await tester.pumpAndSettle();

      // 舞台立绘浮标与说话人 chip 都应切换为「同伴」。
      expect(find.text('同伴 · 默认'), findsOneWidget);
      expect(find.text('主角 · 默认'), findsNothing);
      expect(find.text('同伴 ▸'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('人物登场弹窗：0（白雨）按立绘渲染，且无立绘角色排在立绘角色之后',
        (tester) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      ApiClient.instance.client = MockClient((req) async {
        final path = req.url.path;
        if (path == '/api/roles') {
          return http.Response(
            jsonEncode({
              'roles': [
                {'id': '-1', 'name': '旁白'},
                {'id': '0', 'name': '白雨', 'portrait': 'role_0'},
                {'id': '10', 'name': '主角', 'portrait': 'role_10'},
              ],
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
                  'highlights': [10],
                  'roles': [
                    [10, 1001, 1, 1],
                    [10, 3000, 0],
                  ],
                  'content': '测试台词',
                },
              },
            // 三人均无 url：宿主侧立绘候选为空，立绘只能来自角色目录。
            'PersonCfg' => {
                '-1': {'id': -1, 'name': '旁白'},
                '0': {'id': 0, 'name': '白雨'},
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
        if (path == '/api/preview/meta') {
          return http.Response(
            jsonEncode({
              'bgKeys': {'100': 'bg_classroom'},
              'charKeys': <String, dynamic>{},
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

      // 经「👤 人物登场」按钮打开弹窗。
      await tester.tap(find.widgetWithText(fluent.Button, '👤 人物登场').first);
      await tester.pump();
      await tester.pumpAndSettle();

      // 历史 bug：把主角 0 误当旁白显示喇叭，导致白雨立绘永不加载。
      expect(
        find.byWidgetPredicate((w) => w is TexThumb && w.keyName == 'role_0'),
        findsOneWidget,
        reason: '0（白雨）应走立绘，而不是旁白喇叭图标',
      );
      // 排序：有立绘的 0 / 10 在前，无立绘的 -1（旁白）在最后一行之后。
      expect(
        tester.getTopLeft(find.text('ID 0')).dx <
            tester.getTopLeft(find.text('ID -1')).dx,
        isTrue,
        reason: '无立绘的伪角色应排在立绘角色之后',
      );
      expect(tester.takeException(), isNull);
    });
  });
}
