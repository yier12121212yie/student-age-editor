import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_age_editor/core/api_client.dart';
import 'package:student_age_editor/core/models.dart';
import 'package:student_age_editor/core/plugin_state.dart';
import 'package:student_age_editor/core/ui_mode.dart';
import 'package:student_age_editor/features/nocode/entity_picker.dart';
import 'package:student_age_editor/features/resources/asset_explorer_panel.dart';
import 'package:student_age_editor/features/shell/mobile_shell.dart';
import 'package:student_age_editor/features/shell/shell_state.dart';

/// 移动端体验回归：
/// - 抽屉选中导航项后自动关闭（旧实现只在抽屉下切换 tab，抽屉继续盖住页面）；
/// - 资源库筛选条在窄屏改为两行，不横向溢出；
/// - 实体选择器正文按屏幕收敛，不再固定 560×460 溢出手机。
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ApiClient.instance.client = MockClient((req) async {
      final path = req.url.path;
      if (path == '/api/state') {
        return http.Response(
          jsonEncode({'mod_name': '测试模组', 'ok': true}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (path == '/api/plugins') {
        return http.Response(
          jsonEncode({'plugins': [], 'ui_panels': []}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response(
        jsonEncode({'data': {}, 'ok': true}),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    addTearDown(() => ApiClient.instance.client = http.Client());
  });

  void useScreen(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() => tester.view.resetPhysicalSize());
  }

  testWidgets('抽屉选中导航项后自动关闭并切换 tab', (tester) async {
    useScreen(tester, const Size(390, 844));

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

    // 打开抽屉
    await tester.tap(find.byIcon(FluentIcons.navigation_24_regular));
    await tester.pumpAndSettle();
    expect(
      tester.state<ScaffoldState>(find.byType(Scaffold).first).isDrawerOpen,
      isTrue,
    );

    // 点「设置」：应切到「更多」tab 且抽屉关闭
    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    expect(
      tester.state<ScaffoldState>(find.byType(Scaffold).first).isDrawerOpen,
      isFalse,
      reason: '点抽屉导航项后抽屉应关闭，而不是继续盖住页面',
    );
    expect(
      tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
      4,
    );
  });

  testWidgets('资源库筛选条在 320x640 手机上不横向溢出', (tester) async {
    useScreen(tester, const Size(320, 640));

    await tester.pumpWidget(
      const fluent.FluentApp(
        home: Scaffold(body: AssetExplorerPanel()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull, reason: '窄屏筛选条不应 RenderFlex 溢出');
    // 两个操作按钮与类型筛选仍可见（改为两行而非隐藏）。
    expect(find.text('重新读取索引'), findsOneWidget);
    expect(find.text('全部'), findsOneWidget);
  });

  testWidgets('实体选择器在 360x640 手机上收敛到屏幕内', (tester) async {
    useScreen(tester, const Size(360, 640));

    await tester.pumpWidget(
      fluent.FluentApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: MaterialButton(
                onPressed: () => showEntityPicker(
                  context,
                  kind: EntityKind.items,
                  multi: true,
                  gameDicts: const {},
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull, reason: '实体选择器不应溢出手机屏幕');
    final dialog = tester.getSize(find.byType(AlertDialog));
    expect(dialog.width, lessThanOrEqualTo(360.0));
    expect(dialog.height, lessThanOrEqualTo(640.0));
  });
}
