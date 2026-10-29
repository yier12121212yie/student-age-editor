import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_age_editor/core/api_client.dart';
import 'package:student_age_editor/core/mobile_widgets.dart';
import 'package:student_age_editor/core/models.dart';
import 'package:student_age_editor/core/plugin_state.dart';
import 'package:student_age_editor/core/responsive.dart';
import 'package:student_age_editor/core/ui_mode.dart';
import 'package:student_age_editor/features/editor/editor_controller.dart';
import 'package:student_age_editor/features/editor/schema_editor_view.dart';
import 'package:student_age_editor/features/files/file_tree_page.dart';
import 'package:student_age_editor/features/shell/mobile_shell.dart';
import 'package:student_age_editor/features/shell/shell_state.dart';

/// 移动端 UX 收口回归：
/// - 横屏手机仍按移动布局（不落回桌面三栏壳）；
/// - 底部滑出层可关闭、按 initialSize 定高、拖拽可收起；
/// - 文件 tab 移动端逐级浏览、行高 ≥48、可搜索/返回；
/// - 移动编辑页支持上一条/下一条与返回脏确认；
/// - 壳层图标按钮具备语义标签。
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
      if (path == '/api/cfg/ShopCfg') {
        return http.Response(
          jsonEncode({
            'data': {
              '1': {'id': 1, 'name': '甲'},
              '2': {'id': 2, 'name': '乙'},
            },
            'exists': true,
          }),
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

  test('移动布局判定覆盖横屏手机与桌面窗口', () {
    expect(isMobileLayoutOf(const Size(390, 844)), isTrue);
    expect(isMobileLayoutOf(const Size(360, 640)), isTrue);
    expect(isMobileLayoutOf(const Size(844, 390)), isTrue,
        reason: '横屏手机短边 <480 应继续走移动布局');
    expect(isMobileLayoutOf(const Size(800, 600)), isFalse);
    expect(isMobileLayoutOf(const Size(1024, 768)), isFalse);
    expect(isMobileLayoutOf(const Size(1280, 720)), isFalse);
  });

  testWidgets('844×390 横屏手机挂载移动壳且无溢出', (tester) async {
    useScreen(tester, const Size(844, 390));
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

    expect(find.byType(NavigationBar), findsOneWidget);
    expect(tester.takeException(), isNull, reason: '横屏手机移动壳不应溢出');
  });

  testWidgets('系统字号 1.3 下移动壳与底部导航不溢出', (tester) async {
    useScreen(tester, const Size(390, 844));
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(
        tester.platformDispatcher.clearTextScaleFactorTestValue);

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

    expect(tester.takeException(), isNull,
        reason: '1.3 倍系统字号下移动壳不应溢出');
  });

  testWidgets('滑出层按 initialSize 定高、可关闭', (tester) async {
    useScreen(tester, const Size(390, 844));
    await tester.pumpWidget(
      fluent.FluentApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: MaterialButton(
                onPressed: () => showMobileSheet(
                  context,
                  const Text('SHEET-BODY'),
                  title: '测试弹层',
                  initialSize: 0.6,
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

    final sheet = tester.getSize(find.byKey(const ValueKey('mobile-sheet')));
    expect(sheet.height, closeTo(844 * 0.6, 2));
    expect(find.text('SHEET-BODY'), findsOneWidget);
    expect(find.text('测试弹层'), findsOneWidget);
    expect(find.byIcon(Icons.close_rounded), findsOneWidget);

    await tester.tap(find.byIcon(Icons.close_rounded));
    await tester.pumpAndSettle();
    expect(find.text('SHEET-BODY'), findsNothing);
  });

  testWidgets('滑出层向下拖动可收起', (tester) async {
    useScreen(tester, const Size(390, 844));
    await tester.pumpWidget(
      fluent.FluentApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: MaterialButton(
                onPressed: () => showMobileSheet(
                  context,
                  const Text('DRAG-BODY'),
                  title: '拖动我',
                  initialSize: 0.6,
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
    expect(find.text('DRAG-BODY'), findsOneWidget);

    await tester.drag(find.text('拖动我'), const Offset(0, 500));
    await tester.pumpAndSettle();
    expect(find.text('DRAG-BODY'), findsNothing);
  });

  testWidgets('文件 tab 移动端逐级浏览、行高 ≥48、可搜索', (tester) async {
    useScreen(tester, const Size(390, 844));
    final requests = <String>[];
    ApiClient.instance.client = MockClient((req) async {
      if (req.url.path == '/api/tools/list') {
        final path = req.url.queryParameters['path'] ?? '';
        requests.add(path);
        final entries = path.isEmpty
            ? [
                {'name': 'Cfgs', 'type': 'dir', 'size': 0},
                {'name': 'readme.txt', 'type': 'file', 'size': 12},
              ]
            : [
                {'name': 'zh-cn', 'type': 'dir', 'size': 0},
                {'name': 'ItemCfg.json', 'type': 'file', 'size': 1024},
              ];
        return http.Response(
          jsonEncode({'entries': entries}),
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

    final state = AppState()
      ..modName = '测试模组'
      ..modRoot = 'C:/mods/demo';
    await tester.pumpWidget(
      fluent.FluentApp(
        home: Scaffold(
          body: FileTreePage(state: state, controller: EditorController()),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('Cfgs'), findsOneWidget);
    expect(find.text('readme.txt'), findsOneWidget);
    expect(requests.first, '');

    // 第一行是文件/目录行（头部按钮用 GestureDetector，不产生 InkWell）。
    final row = tester.getSize(find.byType(InkWell).first);
    expect(row.height, greaterThanOrEqualTo(48),
        reason: '移动端文件行热区应 ≥48dp，实际 ${row.height}');

    await tester.tap(find.text('Cfgs'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(requests.last, 'Cfgs');
    expect(find.text('zh-cn'), findsOneWidget);
    expect(find.text('ItemCfg.json'), findsOneWidget);

    // 返回上级
    await tester.tap(find.byIcon(FluentIcons.arrow_left_24_regular));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('readme.txt'), findsOneWidget);

    // 搜索过滤
    await tester.tap(find.byIcon(FluentIcons.search_24_regular));
    await tester.pump();
    await tester.enterText(find.byType(TextField).first, 'zzz');
    await tester.pump();
    expect(find.text('没有匹配的文件'), findsOneWidget);
  });

  testWidgets('移动编辑页：下一条 + 返回脏确认', (tester) async {
    useScreen(tester, const Size(390, 844));
    final state = AppState()
      ..modName = '测试模组'
      ..gameSchema = {
        'ShopCfg': {'id': 'Number', 'name': 'String'},
      };

    await tester.pumpWidget(
      fluent.FluentApp(
        home: Scaffold(
          body: SchemaEditorView(state: state, cfgName: 'ShopCfg'),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    // 打开第 1 条
    await tester.tap(find.text('ID: 1'));
    await tester.pumpAndSettle();
    expect(find.text('上一条'), findsOneWidget);
    expect(find.text('下一条'), findsOneWidget);
    expect(find.textContaining('第 1 / 2 条'), findsWidgets);

    // 切到下一条
    await tester.tap(find.text('下一条'));
    await tester.pumpAndSettle();
    expect(find.textContaining('第 2 / 2 条'), findsWidgets);
    final boxes = find.byType(fluent.TextBox);
    expect(boxes, findsWidgets);
    expect(tester.widget<fluent.TextBox>(boxes.last).controller?.text, '乙');

    // 改字段 → 返回应弹脏确认
    await tester.enterText(boxes.last, '丙');
    await tester.pump();
    expect(find.textContaining('未保存'), findsOneWidget);

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('有未保存修改'), findsOneWidget);
    await tester.tap(find.text('继续编辑'));
    await tester.pumpAndSettle();
    expect(find.text('有未保存修改'), findsNothing);

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text('直接返回'));
    await tester.pumpAndSettle();
    expect(find.byType(BackButton), findsNothing, reason: '应回到列表页');
  });

  testWidgets('移动壳图标按钮有可读语义标签', (tester) async {
    useScreen(tester, const Size(390, 844));
    final handle = tester.ensureSemantics();
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

    expect(find.bySemanticsLabel('检索'), findsOneWidget);
    expect(find.bySemanticsLabel('AI 助手'), findsOneWidget);
    expect(find.bySemanticsLabel('菜单'), findsOneWidget);
    handle.dispose();
  });
}
