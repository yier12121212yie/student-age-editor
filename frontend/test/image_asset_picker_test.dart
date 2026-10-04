// 共享图片选择器：key 候选解析、网格画廊分类/搜索、单击预览、确认返回。
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:student_age_editor/core/api_client.dart';
import 'package:student_age_editor/features/resources/image_asset_picker.dart';
import 'package:student_age_editor/features/resources/local_import.dart';

/// 1x1 透明 PNG（base64）。
const _kPng1x1 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==';

void main() {
  setUp(() {
    TexBytesCache.clear();
  });

  tearDown(() {
    debugLocalFilePicker = null;
  });

  group('TexBytesCache.keyCandidates', () {
    test('原样 + 去 bg/ cg/ 前缀', () {
      expect(TexBytesCache.keyCandidates('bg/img_keting'),
          ['bg/img_keting', 'img_keting']);
      expect(TexBytesCache.keyCandidates('cg/cg_x'), ['cg/cg_x', 'cg_x']);
      expect(TexBytesCache.keyCandidates('role_male'), ['role_male']);
      expect(TexBytesCache.keyCandidates(''), isEmpty);
    });
  });

  group('ImageAssetPickerDialog', () {
    late List<String>? result;

    Future<void> pumpPicker(
      WidgetTester tester, {
      bool multiSelect = false,
      List<String> initial = const [],
    }) async {
      ApiClient.instance.client = MockClient((req) async {
        final url = req.url.toString();
        // ignore: avoid_print

        if (url.contains('/api/aa/keys')) {
          if (url.contains('scope=flow')) {
            return http.Response(
                jsonEncode({'tex': ['cg/cg_end_x']}), 200);
          }
          return http.Response(
              jsonEncode({
                'tex': ['bg/img_keting', 'cg/cg_end_x', 'role_male'],
                'meta': {
                  'bg/img_keting': [1920, 1080],
                },
              }),
              200);
        }
        if (url.contains('/api/aa/preview')) {
          final body = jsonDecode(req.body) as Map<String, dynamic>;
          if (body['key'] == 'role_male') {
            return http.Response(jsonEncode({'error': 'missing'}), 422);
          }
          return http.Response(jsonEncode({'data': _kPng1x1}), 200);
        }
        return http.Response('{}', 404);
      });
      // 初始预览窗格的字节直接注入缓存：假时钟下 http 栈不与 pumpAndSettle
      // 交错完成，网络栈路径在 widget 测试里不可靠。
      TexBytesCache.debugPut('bg/img_keting', base64Decode(_kPng1x1));
      result = null;
      await tester.pumpWidget(fluent.FluentApp(
        theme: fluent.FluentThemeData(brightness: Brightness.dark),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: fluent.Button(
                child: const Text('open'),
                onPressed: () async {
                  final r = await showImageAssetPicker(context,
                      multiSelect: multiSelect, initialSelected: initial);
                  result = r;
                },
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('网格渲染全部 key，单击即预览并选中，确认返回', (tester) async {
      await pumpPicker(tester);
      expect(find.text('bg/img_keting'), findsOneWidget);
      expect(find.text('role_male'), findsOneWidget);

      // 单击缩略图 → 预览区出现该图（右侧预览用同名文本）
      await tester.tap(find.text('bg/img_keting'));
      await tester.pumpAndSettle();

      // 确认按钮出现且可用 → 返回 [key]
      await tester.tap(find.text('使用所选'));
      await tester.pumpAndSettle();
      expect(result, ['bg/img_keting']);
    });

    testWidgets('背景页签只显示 bg/ 前缀，搜索过滤生效', (tester) async {
      await pumpPicker(tester);
      await tester.tap(find.text('背景'));
      await tester.pumpAndSettle();
      expect(find.text('bg/img_keting'), findsOneWidget);
      expect(find.text('role_male'), findsNothing);

      await tester.tap(find.text('全部'));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.widgetWithText(fluent.TextBox, '搜索资源 key'), 'role');
      await tester.pumpAndSettle();
      expect(find.text('role_male'), findsOneWidget);
      expect(find.text('bg/img_keting'), findsNothing);
    });

    testWidgets('多选模式累计计数，确定返回多项', (tester) async {
      await pumpPicker(tester, multiSelect: true);
      await tester.tap(find.text('bg/img_keting'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('role_male'));
      await tester.pumpAndSettle();
      expect(find.text('已选 2 项'), findsOneWidget);
      await tester.tap(find.text('确定（2）'));
      await tester.pumpAndSettle();
      expect(result, containsAll(['bg/img_keting', 'role_male']));
      expect(result, hasLength(2));
    });

    testWidgets('未选中时确定按钮禁用，取消返回 null', (tester) async {
      await pumpPicker(tester);
      final confirm = tester
          .widget<fluent.FilledButton>(
              find.ancestor(of: find.text('使用所选'), matching: find.byType(fluent.FilledButton)))
          .onPressed;
      expect(confirm, isNull);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(result, isNull);
    });

    testWidgets('多选初始选中项回显', (tester) async {
      await pumpPicker(tester, multiSelect: true, initial: ['bg/img_keting']);
      // 初始预览窗格 + 入场动画会周期性排帧，这里用定时 pump 代替 settle
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('已选 1 项'), findsOneWidget);
    });

    testWidgets('从电脑选择：自动导入、预勾选，确认回传新 key', (tester) async {
      ApiClient.instance.client = MockClient((req) async {
        final url = req.url.toString();
        if (url.contains('/api/aa/keys')) {
          if (url.contains('scope=flow')) {
            return http.Response(jsonEncode({'tex': <String>[]}), 200);
          }
          return http.Response(
              jsonEncode({
                'tex': ['bg/img_keting'],
              }),
              200);
        }
        if (url.contains('/api/aa/preview')) {
          return http.Response(jsonEncode({'data': _kPng1x1}), 200);
        }
        if (req.url.path == '/api/mod/import_files') {
          return http.Response(
              jsonEncode({
                'saved': [
                  {'name': 'local.png', 'path': 'Textures/local_x.png', 'size': 4},
                ],
                'errors': <Object>[],
              }),
              200,
              headers: {'content-type': 'application/json'});
        }
        return http.Response('{}', 404);
      });
      // 注入本地选择：返回一张 PNG，模拟从电脑选文件。
      debugLocalFilePicker = (kind) async =>
          [(name: 'local.png', bytes: base64Decode(_kPng1x1))];

      result = null;
      await tester.pumpWidget(fluent.FluentApp(
        theme: fluent.FluentThemeData(brightness: Brightness.dark),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: fluent.Button(
                child: const Text('open'),
                onPressed: () async {
                  result = await showImageAssetPicker(context);
                },
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      // 直接点动作栏「从电脑选择图片…」：选文件 → 自动导入 → 预勾选。
      await tester.tap(find.text('从电脑选择图片…'));
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();

      // 新 key（去掉扩展名，与 AA 索引口径一致）直接进画廊并已选中。
      expect(find.text('local_x'), findsWidgets);
      expect(find.text('已选：local_x'), findsOneWidget);

      // 导入成功的 InfoBar 浮层会挡住动作栏，且其 6s 自动关闭定时器不随
      // pumpAndSettle 推进：先推过它，再点确认。
      await tester.pump(const Duration(seconds: 7));
      await tester.pumpAndSettle();

      await tester.tap(find.text('使用所选'));
      await tester.pumpAndSettle();
      expect(result, ['local_x']);
    });
  });
}
