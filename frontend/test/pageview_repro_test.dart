// 单独验证 EditorPageView（含顶部配置表 ComboBox）在语义启用时的行为。
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_age_editor/core/api_client.dart';
import 'package:student_age_editor/core/models.dart';
import 'package:student_age_editor/features/pages/pages_catalog.dart';
import 'package:student_age_editor/features/pages/page_view.dart';

void main() {
  testWidgets('EditorPageView 渲染（语义启用）', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final semanticsHandle = tester.ensureSemantics();
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final state = AppState()
      ..gameSchema = {
        'EvtCfg': {
          'id': 'Number', 'title': 'String', 'type': 'Number', 'npc': 'Number',
        },
      }
      ..gameDicts = {
        'roles': {'100': '角色A'},
        'evt_types': {'0': '类型0'},
      };
    ApiClient.instance.client = MockClient((req) async {
      final path = req.url.path;
      if (req.method == 'GET' && path.startsWith('/api/cfg/')) {
        final name = path.split('/').last;
        final data = <String, dynamic>{};
        if (name == 'EvtCfg') {
          data['1'] = {'id': 1, 'title': '事件一', 'type': 1, 'npc': 100};
          data['2'] = {'id': 2, 'title': '事件二', 'type': 0, 'npc': 100};
        }
        return http.Response.bytes(
          utf8.encode(jsonEncode({'data': data, 'exists': true})),
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
          width: 1600,
          height: 1000,
          child: EditorPageView(state: state, page: pageById('evt')!),
        ),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull, reason: '事件页渲染不应异常');

    // 打开顶部配置表 ComboBox
    final combos = find.byType(fluent.ComboBox<String>);
    expect(combos, findsWidgets);
    await tester.tap(combos.first, warnIfMissed: false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull, reason: '打开配置表下拉不应异常');

    semanticsHandle.dispose();
  });
}
