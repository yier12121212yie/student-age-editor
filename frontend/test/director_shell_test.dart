// 导演布局（DirectorShell）冒烟测试：无后端时可渲染三栏舞台工作台 +
// 顶部工程栏 + 状态栏，且布局切换按钮循环到下一模式。
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
import 'package:student_age_editor/features/resources/image_asset_picker.dart'
    show TexThumb, debugResetMergedMetaCache;
import 'package:student_age_editor/features/shell/director_shell.dart';
import 'package:student_age_editor/features/shell/shell_state.dart';
import 'package:student_age_editor/features/warehouse/warehouse_workbench.dart';
import 'package:student_age_editor/features/resources/resources_page.dart';
import 'package:student_age_editor/features/json/json_workbench.dart';
import 'package:student_age_editor/features/mods/mods_page.dart';
import 'package:student_age_editor/features/pages/workshop_features.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ApiClient.instance.client = MockClient((req) async {
      final path = req.url.path;
      if (path.startsWith('/api/cfg/')) {
        final cfg = path.substring('/api/cfg/'.length);
        Map<String, dynamic> data;
        switch (cfg) {
          case 'EvtCfg':
            data = {
              '8000': {
                'id': '8000',
                'title': '测试事件',
                'talkIds': ['800001'],
              },
            };
            break;
          case 'TalkCfg':
            data = {
              '800001': {
                'id': 800001,
                'roleIds': [10],
                'content': '测试台词',
              },
            };
            break;
          case 'PersonCfg':
            data = {
              '10': {'id': 10, 'name': '主角'},
            };
            break;
          default:
            data = {};
        }
        return http.Response(
          jsonEncode({'data': data, 'exists': true}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (path == '/api/state') {
        return http.Response(
          jsonEncode({'mod_name': '测试模组', 'ok': true}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response(
        jsonEncode({'data': {}}),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
  });

  tearDown(() {
    ApiClient.instance.client = http.Client();
  });

  testWidgets('导演布局渲染冒烟：工程栏 + 舞台工作台 + 状态栏', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    final state = AppState()..modName = '测试模组';
    final shell = ShellState()..setAiOpen(false);
    UiMode? changed;

    await tester.pumpWidget(
      fluent.FluentApp(
        debugShowCheckedModeBanner: false,
        home: DirectorShell(
          state: state,
          shell: shell,
          pluginState: PluginState(),
          uiMode: UiMode.director,
          onUiModeChanged: (m) => changed = m,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(tester.takeException(), isNull, reason: '导演布局渲染不应异常');
    // 顶部工程栏品牌 + 副标题
    expect(find.text('学生时代模组编辑器'), findsOneWidget);
    expect(find.text('导演工作台'), findsOneWidget);
    // 进入导演布局先到主页（功能总览）
    expect(find.text('模组编辑功能'), findsOneWidget);
    // 状态栏模组名
    expect(find.text('模组: 测试模组'), findsOneWidget);
    // 头部模式入口（A1）：显示当前模式；点开为「模式选择器」直接选目标模式
    expect(find.text('导演'), findsOneWidget);
    await tester.tap(find.text('导演'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('切换界面模式'), findsOneWidget, reason: '应弹出模式选择器');
    final picker = find.byKey(const ValueKey('mode-picker'));
    expect(picker, findsOneWidget);
    await tester.tap(find.descendant(of: picker, matching: find.text('创作')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(changed, UiMode.creation);
    expect(tester.takeException(), isNull);
  });

  testWidgets('导演布局紧凑窗口（800x600）无像素溢出', (tester) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(
      fluent.FluentApp(
        debugShowCheckedModeBanner: false,
        home: DirectorShell(
          state: AppState()..modName = '测试模组',
          shell: ShellState()..setAiOpen(false),
          pluginState: PluginState(),
          uiMode: UiMode.director,
          onUiModeChanged: (_) {},
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(tester.takeException(), isNull, reason: '导演布局在 800x600 下不应溢出');

    // 配置表工作台在窄窗下也不应溢出。
    await tester.ensureVisible(find.text('珍贵记忆').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('珍贵记忆').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.takeException(), isNull, reason: '配置表工作台在 800x600 下不应溢出');
  });

  testWidgets('导演工作台：主页卡片 / 功能切换 / 操作说明', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(
      fluent.FluentApp(
        debugShowCheckedModeBanner: false,
        home: DirectorShell(
          state: AppState()..modName = '测试模组',
          shell: ShellState()..setAiOpen(false),
          pluginState: PluginState(),
          uiMode: UiMode.director,
          onUiModeChanged: (_) {},
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // 首页：标题 + 功能卡片 + 模组管理工具 + 打开入口。
    expect(find.text('模组编辑功能'), findsOneWidget);
    expect(find.text('剧情编辑'), findsWidgets);
    expect(find.text('模组管理'), findsOneWidget);
    expect(find.text('打开 →'), findsWidgets);

    // 点「珍贵记忆」功能卡片进入 Feature 配置表工作台。
    await tester.ensureVisible(find.text('珍贵记忆').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('珍贵记忆').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(DirectorFeatureTableView), findsOneWidget);
    expect(find.text('全部功能'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // 操作说明覆盖层。
    await tester.tap(find.text('操作说明'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('常用快捷键'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('导演模式：进入剧情舞台后元数据迟到，背景与立绘应自动补齐（无需换页）',
      (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    debugResetMergedMetaCache();
    ApiClient.instance.client = MockClient((req) async {
      final path = req.url.path;
      if (path == '/api/preview/meta') {
        // 合并元数据明显慢于整表加载。
        await Future<void>.delayed(const Duration(seconds: 1));
        return http.Response(
          jsonEncode({
            'bgKeys': {'100': 'bg_classroom'},
            'charKeys': {
              '10': {'base': 'role_hero', 'base2': 'role_hero2'},
            },
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (path.startsWith('/api/cfg/')) {
        final cfg = path.substring('/api/cfg/'.length);
        final Map<String, dynamic> data = switch (cfg) {
          'EvtCfg' => {
              '8000': {'id': '8000', 'title': '测试事件', 'talkId': ['800001']},
            },
          'TalkCfg' => {
              '800001': {
                'id': 800001,
                'roleIds': [10],
                'roles': [
                  [10, 1001, 1, 1],
                ],
                'bg': 100,
                'content': '测试台词',
              },
            },
          'PersonCfg' => {
              '10': {'id': 10, 'name': '主角'},
            },
          _ => <String, dynamic>{},
        };
        return http.Response(
          jsonEncode({'data': data, 'exists': true, 'mtime_ns': 1}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (path == '/api/roles') {
        return http.Response(
          jsonEncode({'roles': []}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (path == '/api/state') {
        return http.Response(
          jsonEncode({'mod_name': '测试模组', 'ok': true}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response(
        jsonEncode({'data': {}}),
        200,
        headers: {'content-type': 'application/json'},
      );
    });

    await tester.pumpWidget(
      fluent.FluentApp(
        debugShowCheckedModeBanner: false,
        home: DirectorShell(
          state: AppState()..modName = '测试模组',
          shell: ShellState()..setAiOpen(false),
          pluginState: PluginState(),
          uiMode: UiMode.director,
          onUiModeChanged: (_) {},
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // 从主页卡片进入「剧情舞台」。
    await tester.ensureVisible(find.text('剧情编辑').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('剧情编辑').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // 元数据未到达：舞台背景/立绘还是占位。
    expect(
      find.byWidgetPredicate(
          (w) => w is TexThumb && w.keyName == 'bg_classroom'),
      findsNothing,
    );

    // 元数据到达后：不切换对白、不切功能页，舞台应自动补齐背景与立绘。
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      find.byWidgetPredicate(
          (w) => w is TexThumb && w.keyName == 'bg_classroom'),
      findsWidgets,
      reason: '导演模式下舞台背景应在元数据到达后自动出现',
    );
    expect(
      find.byWidgetPredicate((w) => w is TexThumb && w.keyName == 'role_hero'),
      findsWidgets,
      reason: '导演模式下人物立绘应在元数据到达后自动出现',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('导演主页：按参考产品的功能目录渲染卡片', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(
      fluent.FluentApp(
        debugShowCheckedModeBanner: false,
        home: DirectorShell(
          state: AppState()..modName = '测试模组',
          shell: ShellState()..setAiOpen(false),
          pluginState: PluginState(),
          uiMode: UiMode.director,
          onUiModeChanged: (_) {},
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // 参考产品 workshop-features.json 的功能目录原样出现在主页：
    // 常用功能、人物、结局与记忆、玩法与配置、恋爱与送礼等分组的功能卡片。
    for (final label in [
      '剧情编辑',
      '人物',
      '物品',
      '企鹅动态',
      '珍贵记忆',
      '目标',
      '看番与漫展',
      '生日派对',
      '表白与成功率',
      '送礼事件',
    ]) {
      expect(find.text(label), findsWidgets, reason: '主页应有「$label」功能卡片');
    }

    // 点「珍贵记忆」直达该功能的配置表工作台。
    await tester.ensureVisible(find.text('珍贵记忆').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('珍贵记忆').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(DirectorFeatureTableView), findsOneWidget);
    expect(find.text('全部功能'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('导演工程栏模组下拉：显示 manifest 标题，且能切换模组', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    final selected = <String>[];
    // 引导阶段 state.mods 可能是空快照（从源码启动时工作区晚就绪）；导演壳
    // 进入后应主动 /api/mods 拉全列表，下拉才能切换。
    ApiClient.instance.client = MockClient((req) async {
      final path = req.url.path;
      if (path == '/api/mods') {
        return http.Response(
          jsonEncode({
            'mods': [
              {
                'name': 'test',
                'root': r'/w/test',
                'cfg_files': ['EvtCfg'],
                'has_manifest': true,
                'manifest_title': '测试模组',
              },
              {
                'name': '3503380889',
                'root': r'/w/3503380889',
                'cfg_files': [],
                'has_manifest': true,
                'manifest_title': '青春校花',
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (path == '/api/mods/select') {
        final b = jsonDecode(req.body) as Map<String, dynamic>;
        selected.add(b['name'] as String);
        return http.Response(
          jsonEncode({
            'mod': {'name': b['name'], 'root': r'/w/' + (b['name'] as String)},
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response(
        '{"data":{}}',
        200,
        headers: {'content-type': 'application/json'},
      );
    });

    // 当前选中创意工坊模组：目录名是一串数字 id，标题在 manifest 里。
    final state = AppState()..modName = '3503380889';
    await tester.pumpWidget(
      fluent.FluentApp(
        debugShowCheckedModeBanner: false,
        home: DirectorShell(
          state: state,
          shell: ShellState()..setAiOpen(false),
          pluginState: PluginState(),
          uiMode: UiMode.director,
          onUiModeChanged: (_) {},
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // 下拉展示 manifest 标题而不是数字 id。
    expect(find.text('青春校花'), findsOneWidget);
    expect(find.text('3503380889'), findsNothing);
    expect(tester.takeException(), isNull);

    // 打开模组下拉（工程栏第一个 String 下拉）并切换到「测试模组」。
    await tester.tap(find.byType(fluent.ComboBox<String>).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('测试模组').last);
    await tester.pumpAndSettle();

    expect(selected, ['test'], reason: '应提交被选模组的目录名');
    expect(state.modName, 'test');
    expect(find.text('测试模组'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('主页卡片完全对齐测试：总数52项（21内置 + 27拓展 + 4素材），无多余与管理项', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    // 验证静态元数据定义
    final active = kWorkshopFeatures.where((f) => f.native).toList();
    expect(active.length, 52, reason: '主页可见功能应严格为 52 项');

    final builtins = active.where((f) => !f.resourceOnly && !f.isLibrary && f.homeCategory == 'builtin').toList();
    expect(builtins.length, 21, reason: '游戏内置可编辑项应严格为 21 项');

    final extensions = active.where((f) => !f.resourceOnly && !f.isLibrary && f.homeCategory == 'extension').toList();
    expect(extensions.length, 27, reason: '编辑器拓展项应严格为 27 项');

    final resources = active.where((f) => f.resourceOnly || f.isLibrary).toList();
    expect(resources.length, 4, reason: '素材库卡片应严格为 4 项');

    // 验证管理项 native: false
    expect(featureById('manifest')?.native, isFalse);
    expect(featureById('resources')?.native, isFalse);

    // 验证渲染的主页卡片数量
    await tester.pumpWidget(
      fluent.FluentApp(
        debugShowCheckedModeBanner: false,
        home: DirectorShell(
          state: AppState()..modName = '测试模组',
          shell: ShellState()..setAiOpen(false),
          pluginState: PluginState(),
          uiMode: UiMode.director,
          onUiModeChanged: (_) {},
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byType(DirectorHomeCard), findsNWidgets(52));
  });

  testWidgets('卡片路由精准性：shops/items进仓库对应模式，素材进资源库，多表进工作台', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    Future<void> pumpShell() async {
      await tester.pumpWidget(
        fluent.FluentApp(
          debugShowCheckedModeBanner: false,
          home: DirectorShell(
            state: AppState()..modName = '测试模组',
            shell: ShellState()..setAiOpen(false),
            pluginState: PluginState(),
            uiMode: UiMode.director,
            onUiModeChanged: (_) {},
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }

    await pumpShell();

    // 1. 点击「商店商品」-> WarehouseWorkbench 且 initialMode == 'shop'
    await tester.ensureVisible(find.text('商店商品').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('商店商品').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final whShop = tester.widget<WarehouseWorkbench>(find.byType(WarehouseWorkbench));
    expect(whShop.initialMode, 'shop');

    // 2. 点击「物品」-> WarehouseWorkbench 且 initialMode == 'item'
    await tester.tap(find.text('主页'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.ensureVisible(find.text('物品').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('物品').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final whItem = tester.widget<WarehouseWorkbench>(find.byType(WarehouseWorkbench));
    expect(whItem.initialMode, 'item');

    // 3. 点击「场景背景」-> ResourcesPage 且 initialTab == 'bg'
    await tester.tap(find.text('主页'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.ensureVisible(find.text('场景背景').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('场景背景').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final resBg = tester.widget<ResourcesPage>(find.byType(ResourcesPage));
    expect(resBg.initialTab, 'bg');

    // 4. 点击「音乐与音效」-> ResourcesPage 且 initialTab == 'aud'
    await tester.tap(find.text('主页'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.ensureVisible(find.text('音乐与音效').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('音乐与音效').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final resAud = tester.widget<ResourcesPage>(find.byType(ResourcesPage));
    expect(resAud.initialTab, 'aud');

    // 5. 点击「职业」-> DirectorFeatureTableView 且包含 JobCfg 与 JobUnlockCfg 标签
    await tester.tap(find.text('主页'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.ensureVisible(find.text('职业').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('职业').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(DirectorFeatureTableView), findsOneWidget);
    expect(find.text('职业解锁'), findsOneWidget);
  });

  testWidgets('多表切换与返回测试：子表切换与返回全部功能', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(
      fluent.FluentApp(
        debugShowCheckedModeBanner: false,
        home: DirectorShell(
          state: AppState()..modName = '测试模组',
          shell: ShellState()..setAiOpen(false),
          pluginState: PluginState(),
          uiMode: UiMode.director,
          onUiModeChanged: (_) {},
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // 进入职业（包含 JobCfg 与 JobUnlockCfg 两张表）
    await tester.ensureVisible(find.text('职业').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('职业').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // 切换到「职业解锁」子表
    expect(find.text('职业解锁'), findsOneWidget);
    await tester.tap(find.text('职业解锁'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);

    // 点击「全部功能」返回主页
    expect(find.text('全部功能'), findsOneWidget);
    await tester.tap(find.text('全部功能'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('模组编辑功能'), findsOneWidget);
  });

  testWidgets('N10 导演历史：工作台换表后切走，后退应回到该功能该配置表', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(
      fluent.FluentApp(
        debugShowCheckedModeBanner: false,
        home: DirectorShell(
          state: AppState()..modName = '测试模组',
          shell: ShellState()..setAiOpen(false),
          pluginState: PluginState(),
          uiMode: UiMode.director,
          onUiModeChanged: (_) {},
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // 进入「职业」工作台，默认主表 JobCfg。
    await tester.ensureVisible(find.text('职业').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('职业').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(DirectorFeatureTableView), findsOneWidget);
    expect(
      find.byKey(const ValueKey('director-feature-schema-JobCfg')),
      findsOneWidget,
    );

    // 切到副表「职业解锁」（JobUnlockCfg）。
    await tester.tap(find.text('职业解锁'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      find.byKey(const ValueKey('director-feature-schema-JobUnlockCfg')),
      findsOneWidget,
    );

    // 切走回主页。
    await tester.tap(find.text('全部功能'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('模组编辑功能'), findsOneWidget);

    // 后退：应回到「职业」工作台且停在此前查看的「职业解锁」表（而非主表）。
    await tester.tap(find.byTooltip('后退'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(DirectorFeatureTableView), findsOneWidget);
    expect(
      find.byKey(const ValueKey('director-feature-schema-JobUnlockCfg')),
      findsOneWidget,
      reason: '后退应恢复历史条目记录的配置表（N10）',
    );
    expect(
      find.byKey(const ValueKey('director-feature-schema-JobCfg')),
      findsNothing,
    );

    // 前进：回到主页；再后退仍能回到该表（双向稳定）。
    await tester.tap(find.byTooltip('前进'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('模组编辑功能'), findsOneWidget);

    await tester.tap(find.byTooltip('后退'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      find.byKey(const ValueKey('director-feature-schema-JobUnlockCfg')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('模组管理四个工具按钮测试：高级配置打开JSON工作台，模组信息打开弹窗', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(
      fluent.FluentApp(
        debugShowCheckedModeBanner: false,
        home: DirectorShell(
          state: AppState()..modName = '测试模组',
          shell: ShellState()..setAiOpen(false),
          pluginState: PluginState(),
          uiMode: UiMode.director,
          onUiModeChanged: (_) {},
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // 验证「高级配置」按钮
    await tester.ensureVisible(find.text('高级配置'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('高级配置'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(JsonWorkbench), findsOneWidget);

    // 返回主页
    await tester.tap(find.text('主页'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('模组编辑功能'), findsOneWidget);

    // 验证「模组信息」按钮
    await tester.ensureVisible(find.text('模组信息'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('模组信息'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(ModsPage), findsOneWidget);
  });
}
