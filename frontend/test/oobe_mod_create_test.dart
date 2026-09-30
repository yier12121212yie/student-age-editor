// OOBE「创建第一个模组」步骤回归测试（bug #5）。
//
// 缺陷：第②步填了模组名，离开该步时既不建模组也没有任何提示（静默失败）；
// 正确行为：离开第②步（点「下一步」）时就应 POST /api/oobe/setup 并带上
// mod_title，而不是拖到最后一步或悄悄丢掉用户输入。
import 'dart:convert';

import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:student_age_editor/core/api_client.dart';
import 'package:student_age_editor/features/oobe/oobe_page.dart';

/// OOBE 页面同时使用 Fluent（按钮/主题）与 Material（TextField/Overlay）控件，
/// 所以外层给 FluentTheme（FluentApp），内层给透明 Material 祖先。
Widget _wrap() => fluent.FluentApp(
      debugShowCheckedModeBanner: false,
      home: Material(
        type: MaterialType.transparency,
        child: OobePage(onFinished: () {}),
      ),
    );

void main() {
  late List<http.Request> requests;

  setUp(() {
    requests = <http.Request>[];
    ApiClient.instance.client = MockClient((req) async {
      requests.add(req);
      final path = req.url.path;
      if (path == '/api/oobe/status') {
        return http.Response(
            jsonEncode({'first_run': true, 'oobe_completed': false}), 200);
      }
      if (path == '/api/settings/editor') {
        return http.Response(jsonEncode({'settings': {}}), 200);
      }
      if (path == '/api/oobe/setup') {
        return http.Response(jsonEncode({'ok': true}), 200);
      }
      if (path == '/api/mods') {
        return http.Response(jsonEncode({'mods': []}), 200);
      }
      return http.Response(jsonEncode({'ok': true}), 200);
    });
  });

  tearDown(() {
    ApiClient.instance.client = http.Client();
  });

  http.Request? setupPost() {
    for (final r in requests) {
      if (r.method == 'POST' && r.url.path == '/api/oobe/setup') return r;
    }
    return null;
  }

  testWidgets('离开第②步即创建模组（不再静默丢弃输入的模组名）', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_wrap());
    await tester.pumpAndSettle();

    // 第①步（欢迎）→ 第②步（工作区）
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    // 第②步（工作区）→ 第③步（首个 Mod）
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();

    // 第③步：填模组名后离开该步。OOBE 用的是 Fluent 的 TextBox（不是
    // Material 的 TextField），按 placeholder 'MyFirstMod' 定位「模组名称」框。
    final modField = find.byWidgetPredicate(
      (w) => w is fluent.TextBox && w.placeholder == 'MyFirstMod',
      description: "fluent.TextBox(placeholder: 'MyFirstMod')",
    );
    expect(modField, findsOneWidget, reason: '第③步应有模组名输入框');
    await tester.enterText(modField, '我的模组');
    await tester.pump();

    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();

    final post = setupPost();
    expect(post, isNotNull, reason: '离开第③步必须请求 /api/oobe/setup（bug #5）');
    final body = jsonDecode(post!.body) as Map;
    expect(body['mod_title'], '我的模组');
    expect(body['mark_done'], isFalse,
        reason: '离开第③步只是建模组，不应把引导标记为完成');
  });

  testWidgets('模组名留空时离开第③步不建模组', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_wrap());
    await tester.pumpAndSettle();

    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();

    expect(setupPost(), isNull, reason: '空模组名是可选步骤，不应发创建请求');
  });
}
