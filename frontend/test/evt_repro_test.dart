// 复现：真实 EvtCfg schema（19 字段含 2D Array + 多种下拉规则）下
// 语义启用时 schema 编辑器交互不触发 parentDataDirty 断言。
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:student_age_editor/core/api_client.dart';
import 'package:student_age_editor/core/models.dart';
import 'package:student_age_editor/features/editor/schema_editor_view.dart';

const _schema = {
  'EvtCfg': {
    'id': 'Number',
    'title': 'String',
    'type': 'Number',
    'talkId': '1D Array',
    'rate': 'Number',
    'npc': 'Number',
    'maxcount': 'Number',
    'mapId': 'Number',
    'effect': '2D Array',
    'condition': '2D Array',
    'displayType': 'Number',
    'content': 'String',
    'desc': 'String',
    'maxoptions': 'Number',
    'miniGame': '1D Array',
    'options': '1D Array',
    'probability': '1D Array',
    'replace': '1D Array',
    'weight': 'Number',
  },
};

Map<String, dynamic> _evtRecord(int i) => {
      'id': i,
      'title': '事件$i',
      'type': i % 10,
      'talkId': <dynamic>[i * 100 + 1, i * 100 + 2],      'rate': 100,
      'npc': 100 + i,
      'maxcount': 0,
      'mapId': i % 20,
      'effect': <dynamic>[
        <dynamic>[1, 2],
        <dynamic>[3, 4],
      ],
      'condition': <dynamic>[
        <dynamic>[5, 6],
      ],
      'displayType': 0,
      'content': '内容$i',
      'desc': '描述$i',
      'maxoptions': 2,
      'miniGame': <dynamic>[],
      'options': <dynamic>[],
      'probability': <dynamic>[100],
      'replace': <dynamic>[],
      'weight': 1,
    };

void main() {
  testWidgets('复现：真实 EvtCfg 字段与下拉交互不触发 parentDataDirty',
      (tester) async {
    final semanticsHandle = tester.ensureSemantics();
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final state = AppState()
      ..gameSchema = _schema
      ..gameDicts = {
        'evt_types': {for (var i = 0; i < 65; i++) '$i': '类型$i'},
        'roles': {for (var i = 100; i < 300; i++) '$i': '角色$i'},
        'maps': {for (var i = 0; i < 21; i++) '$i': '地图$i'},
        'items': {for (var i = 0; i < 369; i++) '$i': '物品$i'},
      }
      ..keyMaps = {
        'EvtCfg': {'id': '事件ID', 'title': '标题', 'type': '事件类型', 'npc': '指定对象(NPC)'},
      };
    ApiClient.instance.client = MockClient((req) async {
      final path = req.url.path;
      if (req.method == 'GET' && path == '/api/cfg/EvtCfg') {
        return http.Response.bytes(
          utf8.encode(jsonEncode({
            'data': {for (var i = 1; i <= 40; i++) '$i': _evtRecord(i)},
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
          width: 1400,
          height: 900,
          child: SchemaEditorView(state: state, cfgName: 'EvtCfg'),
        ),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.takeException(), isNull, reason: '初始渲染不应异常');

    // 依次打开/关闭每种下拉框（ComboBox 弹出层显隐）
    final combos = find.byType(fluent.ComboBox<String>);
    expect(combos, findsWidgets);
    for (var k = 0; k < combos.evaluate().length && k < 6; k++) {
      await tester.tap(combos.at(k), warnIfMissed: false);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.takeException(), isNull, reason: '打开下拉$k不应异常');
      // 关闭（按 Esc 或点外部）
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.takeException(), isNull, reason: '关闭下拉$k不应异常');
    }

    // 选择下拉项
    await tester.tap(combos.at(1), warnIfMissed: false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.textContaining('角色').last, warnIfMissed: false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull, reason: '选择下拉项不应异常');

    // 2D Array 字段输入
    final boxes = find.byType(fluent.TextBox);
    for (var b = 0; b < boxes.evaluate().length && b < 8; b++) {
      await tester.ensureVisible(boxes.at(b));
      await tester.enterText(boxes.at(b), '1, 2; 3, 4');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      expect(tester.takeException(), isNull, reason: '字段输入$b不应异常');
    }

    // 添加/删除/切换条目
    await tester.tap(find.byIcon(FluentIcons.add_24_regular), warnIfMissed: false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.takeException(), isNull, reason: '添加条目不应异常');

    final deleteIcons = find.byIcon(FluentIcons.delete_24_regular);
    if (deleteIcons.evaluate().isNotEmpty) {
      await tester.tap(deleteIcons.first, warnIfMissed: false);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.takeException(), isNull, reason: '删除条目不应异常');
    }

    // 滚动左侧 + 右侧
    await tester.drag(find.byType(ListView).first, const Offset(0, -900));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.takeException(), isNull, reason: '滚动不应异常');

    semanticsHandle.dispose();
  });
}
