import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:student_age_editor/core/api_client.dart';
import 'package:student_age_editor/core/models.dart';
import 'package:student_age_editor/features/editor/schema_editor_view.dart';

void main() {
  testWidgets('复现：语义启用时 schema 编辑器完整交互不触发 parentDataDirty 断言',
      (tester) async {
    final semanticsHandle = tester.ensureSemantics();

    final state = AppState()
      ..gameSchema = {
        'ShopCfg': {
          'id': 'Number',
          'itemId': 'Number',
          'type': 'Number',
          'name': 'String',
        },
      }
      ..gameDicts = {
        'items': {
          '101': '物品A',
          '102': '物品B',
        },
      };
    ApiClient.instance.client = MockClient((req) async {
      final path = req.url.path;
      if (req.method == 'GET' && path == '/api/cfg/ShopCfg') {
        return http.Response.bytes(
          utf8.encode(jsonEncode({
            'data': {
              '1': {'id': 1, 'itemId': 101, 'type': 1, 'name': 'x'},
              '2': {'id': 2, 'itemId': 102, 'type': 2, 'name': 'y'},
            },
            'exists': true,
          })),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response.bytes(
        utf8.encode(jsonEncode({'error': 'mock 404'})),
        404,
        headers: {'content-type': 'application/json'},
      );
    });
    addTearDown(() {
      ApiClient.instance.client = http.Client();
    });

    await tester.pumpWidget(fluent.FluentApp(
      home: Scaffold(
        body: SizedBox(
          width: 800,
          height: 700,
          child: SchemaEditorView(state: state, cfgName: 'ShopCfg'),
        ),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.takeException(), isNull, reason: '初始渲染不应异常');

    // 1) 打开 itemId 下拉菜单并选择
    final combos = find.byType(fluent.ComboBox<String>);
    expect(combos, findsWidgets);
    await tester.tap(combos.first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull, reason: '打开下拉不应异常');
    await tester.tap(find.textContaining('物品B').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull, reason: '选择下拉项不应异常');

    // 2) 文本框输入 → 触发 setState 重建 + didUpdateWidget 回写 controller
    final boxes = find.byType(fluent.TextBox);
    await tester.enterText(boxes.at(1), '0101');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.takeException(), isNull, reason: '输入不应异常');

    // 3) 添加新条目
    await tester.tap(find.byIcon(FluentIcons.add_24_regular));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.takeException(), isNull, reason: '添加条目不应异常');

    // 4) 切换条目
    await tester.tap(find.text('ID: 2'), warnIfMissed: false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.takeException(), isNull, reason: '切换条目不应异常');

    // 5) 删除条目
    final deleteIcons = find.byIcon(FluentIcons.delete_24_regular);
    if (deleteIcons.evaluate().isNotEmpty) {
      await tester.tap(deleteIcons.first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.takeException(), isNull, reason: '删除条目不应异常');
    }

    // 6) 大量条目 + 滚动：ListView.builder 懒加载回收子项与语义更新竞争
    state.gameSchema = {
      'BigCfg': {
        for (var i = 0; i < 40; i++) 'field$i': 'String',
      },
    };
    ApiClient.instance.client = MockClient((req) async {
      final path = req.url.path;
      if (req.method == 'GET' && path == '/api/cfg/BigCfg') {
        return http.Response.bytes(
          utf8.encode(jsonEncode({
            'data': {
              for (var i = 1; i <= 60; i++)
                '$i': {
                  'id': i,
                  for (var f = 0; f < 40; f++) 'field$f': 'v$i-$f',
                },
            },
            'exists': true,
          })),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response.bytes(
        utf8.encode(jsonEncode({'error': 'mock 404'})),
        404,
        headers: {'content-type': 'application/json'},
      );
    });
    await tester.pumpWidget(fluent.FluentApp(
      home: Scaffold(
        body: SizedBox(
          width: 800,
          height: 700,
          child: SchemaEditorView(state: state, cfgName: 'BigCfg'),
        ),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.takeException(), isNull, reason: '大表初始渲染不应异常');

    // 滚动左侧条目列表
    final leftList = find.byType(ListView).first;
    await tester.drag(leftList, const Offset(0, -800));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.takeException(), isNull, reason: '滚动条目列表不应异常');

    // 滚动右侧字段列表
    final rightLists = find.byType(ListView);
    if (rightLists.evaluate().length > 1) {
      await tester.drag(rightLists.at(1), const Offset(0, -800));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(tester.takeException(), isNull, reason: '滚动字段列表不应异常');
    }

    // 滚动后切换条目，触发列表重建
    await tester.drag(leftList, const Offset(0, 400));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.takeException(), isNull, reason: '滚动后切换不应异常');

    semanticsHandle.dispose();
  });
}
