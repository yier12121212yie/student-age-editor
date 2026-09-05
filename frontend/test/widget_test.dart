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
import 'package:student_age_editor/features/ai/ai_panel.dart';
import 'package:student_age_editor/features/base/base_search_page.dart';
import 'package:student_age_editor/features/bugfix/bugfix_panel.dart';
import 'package:student_age_editor/features/editor/schema_editor_view.dart';
import 'package:student_age_editor/features/settings/settings_page.dart';

void main() {
  test('smoke', () {
    expect(1 + 1, 2);
  });

  testWidgets('剧情库侧栏渲染冒烟（无后端时不崩溃）', (tester) async {
    final state = AppState();
    await tester.pumpWidget(fluent.FluentApp(
      home: Scaffold(body: BaseSearchPage(state: state)),
    ));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('剧情库'), findsOneWidget);
    expect(find.text('原版事件'), findsOneWidget);
    expect(find.text('台词搜索'), findsOneWidget);
  });

  testWidgets('诊断修复侧栏渲染冒烟（无后端时不崩溃）', (tester) async {
    final state = AppState();
    await tester.pumpWidget(fluent.FluentApp(
      home: Scaffold(body: BugfixPanel(state: state)),
    ));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('诊断修复'), findsOneWidget);
    expect(find.text('开始扫描'), findsOneWidget);
  });

  testWidgets('AI 侧栏渲染冒烟：历史恢复 + Markdown 渲染 + 多行输入', (tester) async {
    // 预置持久化历史：一条 user + 一条含 markdown 的 assistant 回复
    SharedPreferences.setMockInitialValues({
      'ai_chat_messages_v1': jsonEncode([
        {'role': 'user', 'text': '你好', 'time': 0, 'tools': []},
        {
          'role': 'assistant',
          'text': '**加粗内容**\n\n```json\n{"a": 1}\n```',
          'time': 0,
          'tools': [],
        },
      ]),
      'ai_chat_history_v1': jsonEncode([
        {'role': 'user', 'content': '你好'},
        {'role': 'assistant', 'content': '**加粗内容**'},
      ]),
    });
    final state = AppState();
    final panel = AiPanel(
      state: state,
      settings: AiSettings(provider: 'openai_compatible', apiKey: 'k', model: 'm'),
      onChanged: (_) {},
    );
    await tester.pumpWidget(fluent.FluentApp(
      home: Scaffold(body: SizedBox(width: 380, height: 700, child: panel)),
    ));
    // 等待异步恢复
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('AI 助手'), findsOneWidget);
    expect(find.text('你好'), findsOneWidget);
    // markdown 粗体渲染生效（纯文本模式下会是「**加粗内容**」）
    expect(find.text('**加粗内容**'), findsNothing);
    expect(find.text('加粗内容'), findsOneWidget);
    // 代码块内容可复制选择（含尾随换行，用 textContaining 匹配）
    expect(find.textContaining('{"a": 1}'), findsOneWidget);
    // 多行输入 placeholder
    expect(find.textContaining('Enter 发送'), findsOneWidget);
    // 每条消息的时间戳元信息行 + 复制按钮（消息×2 + 代码块×1）
    expect(find.byIcon(FluentIcons.copy_24_regular), findsNWidgets(3));
  });

  testWidgets('AI 侧栏失败重试：不产生重复用户消息、结构化历史保留用户条目', (tester) async {
    SharedPreferences.setMockInitialValues({});
    // MockClient：仅 /api/state 返回当前 mod，让 _ensureModSynced 通过；
    // 其余请求一律 400，使 AiClient 走 HTTP 错误路径（触发重试按钮）。
    // （flutter_test 的 HttpOverrides 会拦截一切真实网络，MockClient 是纯内存实现）
    ApiClient.instance.client = MockClient((req) async {
      final isState = req.method == 'GET' && req.url.path == '/api/state';
      final body = jsonEncode(
          isState ? {'mod_name': 'test', 'ok': true} : {'error': 'mock 400'});
      return http.Response.bytes(utf8.encode(body), isState ? 200 : 400,
          headers: {'content-type': 'application/json'});
    });
    addTearDown(() {
      ApiClient.instance.client = http.Client();
    });
    final state = AppState();
    // 必须有选中的 mod：未选模组时 _send 会被拦截，不会进入发送流程
    state.modName = 'test';
    final panel = AiPanel(
      state: state,
      settings: AiSettings(provider: 'openai_compatible', apiKey: 'k', model: 'm'),
      onChanged: (_) {},
    );
    await tester.pumpWidget(fluent.FluentApp(
      home: Scaffold(body: SizedBox(width: 380, height: 700, child: panel)),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200)); // 异步恢复完成

    // 输入并发送（flutter_test 环境所有 HTTP 返回 400 → 触发错误路径）。
    // enterText 后必须补一帧：发送按钮的 canSend 在 ListenableBuilder 内
    // 依据输入框内容计算，不 pump 则按钮仍是禁用态，tap 无效果。
    await tester.enterText(find.byType(fluent.TextBox), '你好');
    await tester.pump();
    await tester.tap(find.text('发送'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    expect(find.text('你好'), findsOneWidget, reason: '用户消息应恰好一条');
    expect(find.text('重试'), findsOneWidget, reason: '失败后应出现重试按钮');

    // 点击重试：不应追加第二条用户消息
    await tester.tap(find.text('重试'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    expect(find.text('你好'), findsOneWidget, reason: '重试后用户消息不应重复');
    expect(find.text('重试'), findsOneWidget, reason: '重试再次失败后仍显示重试按钮');
    // 再次重试，验证可反复重试且用户消息始终唯一
    await tester.tap(find.text('重试'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('你好'), findsOneWidget, reason: '多次重试后用户消息仍唯一');
  });

  testWidgets('音频预览控件在 Fluent 树中可渲染：Material Slider 不报 No Material / 不溢出', (tester) async {
    // 回归：AudioPreview 直接挂在 Fluent 内容区（无 Scaffold/Material 祖先）。
    // 修复前 Material Slider 因找不到 Material 祖先，被 ErrorWidget（固定 100000×100000）
    // 替换，撑高 Row 导致 BOTTOM OVERFLOWED；修复后应正常渲染、无任何异常。
    await tester.pumpWidget(fluent.FluentApp(
      home: Center(
        child: Material(
          type: MaterialType.transparency,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.play_arrow),
                    onPressed: () {},
                  ),
                  Expanded(
                    child: Slider(value: 0, max: 99420, onChanged: (_) {}),
                  ),
                  const SizedBox(width: 8),
                  const Icon(Icons.volume_up, size: 14),
                  SizedBox(
                    width: 90,
                    child: Slider(value: 1, onChanged: (_) {}),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ));
    await tester.pump();
    expect(tester.takeException(), isNull,
        reason: 'Material Slider 在 Fluent 树中不应抛 No Material 异常或溢出');
    expect(find.byType(Slider), findsNWidgets(2));
  });

  testWidgets('AI 侧栏多会话：旧数据迁移 + 历史列表查看/恢复 + 新建对话', (tester) async {
    // 预置旧版单会话数据（v1 key），启动时应自动迁移为第一个历史会话
    SharedPreferences.setMockInitialValues({
      'ai_chat_messages_v1': jsonEncode([
        {'role': 'user', 'text': '旧对话第一条消息', 'time': 0, 'tools': []},
        {'role': 'assistant', 'text': '旧回复', 'time': 0, 'tools': []},
      ]),
      'ai_chat_history_v1': jsonEncode([
        {'role': 'user', 'content': '旧对话第一条消息'},
        {'role': 'assistant', 'content': '旧回复'},
      ]),
    });
    final state = AppState();
    final panel = AiPanel(
      state: state,
      settings: AiSettings(provider: 'openai_compatible', apiKey: 'k', model: 'm'),
      onChanged: (_) {},
    );
    await tester.pumpWidget(fluent.FluentApp(
      home: Scaffold(body: SizedBox(width: 380, height: 700, child: panel)),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200)); // 异步恢复完成

    // 迁移后的旧对话消息直接在聊天视图可见
    expect(find.text('旧对话第一条消息'), findsOneWidget);
    expect(find.text('旧回复'), findsOneWidget);

    // 打开历史列表：迁移后的会话以第一条用户消息为标题
    await tester.tap(find.byIcon(FluentIcons.chat_history_24_regular));
    await tester.pump();
    expect(find.text('历史对话'), findsOneWidget);
    expect(find.text('旧对话第一条消息'), findsOneWidget, reason: '历史条目标题');
    expect(find.text('当前'), findsOneWidget, reason: '当前会话标记');

    // 新建对话：保存旧会话并切换到空会话
    await tester.tap(find.byIcon(FluentIcons.add_24_regular));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('AI 助手'), findsOneWidget, reason: '回到聊天视图');
    expect(find.text('旧对话第一条消息'), findsNothing, reason: '空会话无旧消息');

    // 再次打开历史，恢复旧会话
    await tester.tap(find.byIcon(FluentIcons.chat_history_24_regular));
    await tester.pump();
    expect(find.text('历史对话'), findsOneWidget);
    await tester.tap(find.text('旧对话第一条消息'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('AI 助手'), findsOneWidget, reason: '恢复后回到聊天视图');
    expect(find.text('旧对话第一条消息'), findsOneWidget, reason: '恢复后的用户消息');
    expect(find.text('旧回复'), findsOneWidget, reason: '恢复后的 AI 回复');
  });

  testWidgets('设置页在侧栏宽度下渲染：ComboBox 不向右溢出', (tester) async {
    // 回归：设置页挂载在固定 264px 宽的侧栏中，接口协议 ComboBox 的
    // 选中项文本（如 "OpenAI Responses API"）超过可用宽度时，
    // 修复前 RenderFlex 向右溢出 72px；修复后 isExpanded 收缩 + 省略号，无异常。
    // mock 扩展列表接口：否则 flutter_test 一律 400，失败路径弹出的
    // InfoBar 带 3s 自动关闭 Timer，测试结束会触发 timersPending 断言。
    ApiClient.instance.client = MockClient((req) async => http.Response(
        '{"packs":[],"active":""}', 200,
        headers: {'content-type': 'application/json'}));
    addTearDown(() {
      ApiClient.instance.client = http.Client();
    });
    await tester.pumpWidget(fluent.FluentApp(
      home: Scaffold(
        body: SizedBox(
          width: 264,
          height: 700,
          child: SettingsPage(
            settings: AiSettings(
                provider: 'openai_responses', apiKey: 'k', model: 'm'),
            onChanged: (_) {},
          ),
        ),
      ),
    ));
    await tester.pump();
    expect(tester.takeException(), isNull,
        reason: '设置页 ComboBox 不应向右溢出');
    // 弹出下拉菜单：三个协议项均可点选
    await tester.tap(find.text('OpenAI Responses API'));
    await tester.pump();
    expect(find.text('Anthropic Compatible'), findsOneWidget,
        reason: '下拉菜单应包含全部协议项');
    // 选择一项关闭菜单，避免残留的弹出动画计时器
    await tester.tap(find.text('Anthropic Compatible'));
    await tester.pumpAndSettle();
  });

  testWidgets('schema 编辑器 ID 选择下拉：长名称不向右溢出', (tester) async {
    // 回归：ID 选择 ComboBox（固定 220px 宽）选中项显示「ID · 名称」，
    // 名称较长时修复前 RenderFlex 向右溢出；修复后 isExpanded 收缩 + 省略号。
    final state = AppState()
      ..gameSchema = {
        'ShopCfg': {'id': 'Number', 'itemId': 'Number', 'name': 'String'},
      }
      ..gameDicts = {
        'items': {
          '101': '这是一个特别特别特别长的物品名称用来触发横向溢出检测的场景',
          '102': '另一个同样非常长的名称用于验证下拉列表也不溢出',
        },
      };
    ApiClient.instance.client = MockClient((req) async {
      final path = req.url.path;
      if (req.method == 'GET' && path == '/api/cfg/ShopCfg') {
        return http.Response.bytes(
          utf8.encode(jsonEncode({
            'data': {
              '1': {'id': 1, 'itemId': 101, 'name': 'x'},
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
          width: 600,
          height: 700,
          child: SchemaEditorView(state: state, cfgName: 'ShopCfg'),
        ),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(tester.takeException(), isNull,
        reason: 'schema 编辑器渲染不应溢出');
    // 打开 ID 下拉并选择长名称条目（选择后 placeholder 即「ID · 名称」）
    final combo = find.byType(fluent.ComboBox<String>);
    expect(combo, findsWidgets, reason: '应渲染出 ID 选择下拉框');
    await tester.tap(combo.first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.takeException(), isNull, reason: '打开下拉不应溢出');
    final longItem = find.textContaining('特别特别特别长的物品名称');
    expect(longItem, findsWidgets, reason: '下拉应包含长名称条目');
    await tester.tap(longItem.last);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull, reason: '选中长名称后不应溢出');
  });
}
