// 创作布局（CreationShell，原 EditorShell 重构）冒烟测试：无后端时可渲染 + 状态栏可切换布局。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_age_editor/core/api_client.dart';
import 'package:student_age_editor/core/models.dart';
import 'package:student_age_editor/core/ui_mode.dart';
import 'package:student_age_editor/features/shell/editor_shell.dart';
import 'package:student_age_editor/features/shell/shell_state.dart';

void main() {
  testWidgets('创作布局渲染冒烟：活动栏 + 面板 + 状态栏 + 布局切换', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    ApiClient.instance.client = MockClient((req) async =>
        http.Response('{"ok":true,"data":[]}', 200,
            headers: {'content-type': 'application/json'}));

    final shell = ShellState()..toggleAi(); // 默认关，专注布局
    UiMode? changed;

    await tester.pumpWidget(fluent.FluentApp(
      debugShowCheckedModeBanner: false,
      home: CreationShell(
        state: AppState(),
        shell: shell,
        uiMode: UiMode.creation,
        onUiModeChanged: (m) => changed = m,
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull, reason: '创作布局渲染不应异常');

    // 状态栏切换按钮存在
    expect(find.text('切换经典布局'), findsOneWidget);

    // 切换面板
    await tester.tap(find.byTooltip('设置'));
    await tester.pump();
    expect(shell.pane, SidePane.settings);
    expect(find.text('界面风格'), findsOneWidget);

    // 状态栏切换布局
    await tester.tap(find.text('切换经典布局'));
    expect(changed, UiMode.classic);
    expect(tester.takeException(), isNull);
  });
}
