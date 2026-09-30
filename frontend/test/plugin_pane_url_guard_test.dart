// 阶段 1d 安全回归：manifest action/form 的相对 url 必须被折叠进插件命名空间。
// 修复前 `url:"../../mods/delete"` 会拼出 /api/plugins/<id>/../../mods/delete，
// 用户点一下按钮即可调用任意后端端点（带任意 body）。
import 'dart:convert';

import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:student_age_editor/core/api_client.dart';
import 'package:student_age_editor/features/plugins/plugin_pane.dart';

void _noop() {}

void main() {
  late List<String> sent;

  setUp(() {
    sent = [];
    ApiClient.instance.client = MockClient((request) async {
      sent.add('${request.method} ${request.url.path}');
      if (request.url.path == '/api/plugins/p1/panel/pane') {
        return http.Response(
            jsonEncode({
              'title': '面板',
              'blocks': [
                {
                  'type': 'actions',
                  'buttons': [
                    {
                      'label': 'evil',
                      'url': '../../mods/delete',
                      'method': 'POST',
                      'body': {'force': true},
                    },
                    {'label': 'fine', 'url': 'service/run', 'method': 'POST'},
                    {'label': 'dot', 'url': 'a/./b', 'method': 'POST'},
                  ],
                },
              ],
            }),
            200,
            headers: {'content-type': 'application/json'});
      }
      if (request.url.path == '/api/plugins/p1/service/run' ||
          request.url.path == '/api/plugins/p1/a/b') {
        return http.Response('{"message":"ok"}', 200,
            headers: {'content-type': 'application/json'});
      }
      return http.Response('{"error":"unexpected"}', 500,
          headers: {'content-type': 'application/json'});
    });
  });

  tearDown(() {
    ApiClient.instance.client = http.Client();
  });

  Future<void> mountPane(WidgetTester tester) async {
    await tester.pumpWidget(const fluent.FluentApp(
      home: PluginPane(pluginId: 'p1', panelId: 'pane', onClosed: _noop),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('越界 url（.. 段）不发出任何命名空间外请求，错误提示可见',
      (tester) async {
    await mountPane(tester);

    await tester.tap(find.text('evil'));
    // displayInfoBar：entry 同步插入、内部有 mediumAnimationDuration 淡入与
    // 3s 自动收起 Timer。先排空微任务，再跨过淡入，断言后再把收起 timer 耗尽。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('操作失败'), findsOneWidget);
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();

    // 除 panel 加载外没有任何请求发出；尤其没有打到 /mods/delete。
    final nonPanel =
        sent.where((s) => !s.startsWith('GET /api/plugins/p1/panel/')).toList();
    expect(nonPanel, isEmpty, reason: '逃逸请求不得发出: $nonPanel');
  });

  testWidgets('正常相对 url 仍拼进插件命名空间', (tester) async {
    await mountPane(tester);

    await tester.tap(find.text('fine'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    expect(sent, contains('POST /api/plugins/p1/service/run'));

    await tester.tap(find.text('dot'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    // '.' 段被 normalizePath 折叠，仍在本插件前缀内。
    expect(sent, contains('POST /api/plugins/p1/a/b'));
  });
}
