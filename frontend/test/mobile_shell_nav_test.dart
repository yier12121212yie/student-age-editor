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
import 'package:student_age_editor/features/editor/editor_controller.dart';
import 'package:student_age_editor/features/shell/mobile_shell.dart';
import 'package:student_age_editor/features/shell/shell_state.dart';

/// 移动端外壳导航回归：
/// - 底部 tab 切换记录历史；
/// - 系统返回键逐级回退 tab，而不是在任何 tab 上直接退出应用；
/// - 回到首页（模组）后返回键才交还给系统。
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ApiClient.instance.client = MockClient((req) async {
      final path = req.url.path;
      if (path.startsWith('/api/cfg/')) {
        return http.Response(
            jsonEncode({'data': {}, 'exists': true}), 200,
            headers: {'content-type': 'application/json'});
      }
      if (path == '/api/state') {
        return http.Response(
            jsonEncode({'mod_name': '测试模组', 'ok': true}), 200,
            headers: {'content-type': 'application/json'});
      }
      if (path == '/api/plugins') {
        return http.Response(jsonEncode({'plugins': [], 'ui_panels': []}), 200,
            headers: {'content-type': 'application/json'});
      }
      return http.Response(jsonEncode({'data': {}, 'ok': true}), 200,
          headers: {'content-type': 'application/json'});
    });
  });

  tearDown(() {
    ApiClient.instance.client = http.Client();
  });

  int selectedTab(WidgetTester tester) =>
      tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex;

  Future<void> pumpShell(WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() => tester.view.resetPhysicalSize());

    final state = AppState();
    state.modName = '测试模组';
    await tester.pumpWidget(
      fluent.FluentApp(
        home: MobileShell(
          state: state,
          shell: ShellState(),
          pluginState: PluginState(),
          uiMode: UiMode.creation,
          onUiModeChanged: (_) {},
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('返回键逐级回退访问过的 tab', (tester) async {
    await pumpShell(tester);
    expect(selectedTab(tester), 0);

    await tester.tap(find.text('文件').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(selectedTab(tester), 2);

    // 系统返回：应回退到上一个 tab（模组），而不是退出。
    await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(selectedTab(tester), 0, reason: '非首页 tab 返回应先回退到上一个 tab');

    // 已在首页，再返回才交还系统（此测试只断言不再改变 tab）。
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(selectedTab(tester), 0);
  });

  testWidgets('多级 tab 历史按最近访问倒序回退', (tester) async {
    await pumpShell(tester);

    await tester.tap(find.text('文件').last);
    await tester.pump(const Duration(milliseconds: 120));
    await tester.tap(find.text('更多').last);
    await tester.pump(const Duration(milliseconds: 120));
    expect(selectedTab(tester), 4);

    await tester.binding.handlePopRoute();
    await tester.pump(const Duration(milliseconds: 120));
    expect(selectedTab(tester), 2, reason: '先回到最近一次访问的「文件」');

    await tester.binding.handlePopRoute();
    await tester.pump(const Duration(milliseconds: 120));
    expect(selectedTab(tester), 0, reason: '再回到首页「模组」');
  });

  testWidgets('编辑 tab 打开文档后返回回到来源 tab', (tester) async {
    final state = AppState();
    state.modName = '测试模组';
    final shell = ShellState();
    await tester.pumpWidget(
      fluent.FluentApp(
        home: MobileShell(
          state: state,
          shell: shell,
          pluginState: PluginState(),
          uiMode: UiMode.creation,
          onUiModeChanged: (_) {},
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('页面').last);
    await tester.pump(const Duration(milliseconds: 120));
    expect(selectedTab(tester), 1);

    // 打开一个文档：壳应自动切到编辑 tab 并把「页面」压入历史。
    shell.controller.open(OpenDoc.cfg(cfgName: 'EvtCfg'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(selectedTab(tester), 3);

    await tester.binding.handlePopRoute();
    await tester.pump(const Duration(milliseconds: 120));
    expect(selectedTab(tester), 1, reason: '返回应回到打开文档前的「页面」tab');
  });
}
