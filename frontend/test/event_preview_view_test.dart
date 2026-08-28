// 事件场景预览：数据模型解析 + 预览视图渲染/导航/画笔/AI 侧栏 的 widget 测试。
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
import 'package:student_age_editor/features/editor/editor_controller.dart';
import 'package:student_age_editor/features/preview/event_preview_view.dart';
import 'package:student_age_editor/features/preview/preview_models.dart';

/// 1x1 透明 PNG（base64）。
const _kPng1x1 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==';

Map<String, dynamic> _previewPayload() => {
      'ok': true,
      'evt_id': '5',
      'event_title': '测试事件',
      'starts': ['5001'],
      'talks': {
        '5001': {
          'id': 5001,
          'content': '你好呀，一起去操场吧',
          'roleIds': [101],
          'roleName': '',
          'bg': 100,
          'option': [],
          'nextTalk': [5002],
          'nextTalk2': [],
          'check': [],
          'stage': {
            'bg': {'id': '100', 'name': '篮球场', 'key': 'img_lanqiuchang'},
            'chars': [
              {'roleId': '101', 'tex': 'role_xiaochun', 'pos': 'left', 'expr': 0, 'flip': false},
            ],
          },
        },
        '5002': {
          'id': 5002,
          'content': '太好了！',
          'roleIds': [-1],
          'roleName': '',
          'bg': 0,
          'option': [1],
          'nextTalk': [],
          'nextTalk2': [],
          'check': [],
          'stage': {'bg': null, 'chars': []},
        },
        '5003': {
          'id': 5003,
          'content': '好，我们出发！',
          'roleIds': [101],
          'roleName': '薛诗蕾',
          'bg': 100,
          'option': [],
          'nextTalk': [],
          'nextTalk2': [],
          'check': [],
          'stage': {
            'bg': {'id': '100', 'name': '篮球场', 'key': 'img_lanqiuchang'},
            'chars': [],
          },
        },
      },
      'options': {
        '1': {
          'id': 1,
          'content': '选这个选项',
          'talkId': [5003],
          'talkId2': [],
        },
      },
      'meta': {
        'roles': {'-1': '旁白', '101': '薛诗蕾'},
        'bgs': {'100': '篮球场'},
        'bgKeys': {'100': 'img_lanqiuchang'},
        'charKeys': {
          '101': {'base': 'role_xiaochun', 'base2': 'role_xiaochun2'},
        },
      },
    };

void _installMockClient() {
  ApiClient.instance.client = MockClient((req) async {
    final path = req.url.path;
    Map<String, dynamic> body = {};
    if (req.method == 'POST' && path == '/api/preview/event') {
      body = _previewPayload();
    } else if (req.method == 'POST' && path == '/api/aa/preview') {
      body = {
        'kind': 'tex',
        'mime': 'image/png',
        'data': _kPng1x1,
      };
    } else if (req.method == 'GET' && path == '/api/state') {
      body = {'mod_name': 'test', 'ok': true};
    } else {
      body = {'error': 'mock 404: $path'};
      return http.Response.bytes(utf8.encode(jsonEncode(body)), 404,
          headers: {'content-type': 'application/json'});
    }
    return http.Response.bytes(utf8.encode(jsonEncode(body)), 200,
        headers: {'content-type': 'application/json'});
  });
}

Widget _wrap(Widget child) => fluent.FluentApp(
      theme: fluent.FluentThemeData(brightness: Brightness.dark),
      home: Scaffold(body: child),
    );

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    _installMockClient();
  });
  tearDown(() {
    ApiClient.instance.client = http.Client();
  });

  // ---------------- 数据模型 ----------------

  test('PreviewEventData.fromJson 解析完整结构', () {
    final d = PreviewEventData.fromJson(_previewPayload());
    expect(d.evtId, '5');
    expect(d.title, '测试事件');
    expect(d.starts, ['5001']);
    expect(d.talks.length, 3);
    expect(d.talkCount, 3);
    expect(d.linearIndex('5003'), 2);
    expect(d.linearIndex('不存在'), -1);

    final t1 = d.talks['5001']!;
    expect(t1.content, '你好呀，一起去操场吧');
    expect(t1.roleIds, ['101']);
    expect(t1.speakerLabel(d), '薛诗蕾');
    expect(t1.isNarrator, false);
    expect(t1.nextTalk, ['5002']);
    expect(t1.stage.bg!.id, '100');
    expect(t1.stage.bg!.key, 'img_lanqiuchang');
    expect(t1.stage.chars.single.roleId, '101');
    expect(t1.stage.chars.single.pos, 'left');
    expect(t1.stage.chars.single.tex, 'role_xiaochun');

    final t2 = d.talks['5002']!;
    expect(t2.isNarrator, true);
    expect(t2.speakerLabel(d), '旁白');
    expect(t2.options, ['1']);
    final opt = d.options['1']!;
    expect(opt.content, '选这个选项');
    expect(opt.talkId, ['5003']);

    expect(d.meta.roleName('101'), '薛诗蕾');
    expect(d.meta.bgKeys['100'], 'img_lanqiuchang');
    expect(d.meta.charKeys['101']!['base'], 'role_xiaochun');
  });

  // ---------------- 预览视图 ----------------

  testWidgets('渲染事件标题 / 对白 / 说话人 / 背景占位', (tester) async {
    final state = AppState();
    final controller = EditorController();
    await tester.pumpWidget(_wrap(EventPreviewView(
      state: state,
      controller: controller,
      eventId: '5',
    )));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('测试事件'), findsOneWidget);
    expect(find.text('对白 1 / 3'), findsOneWidget);
    expect(find.text('你好呀，一起去操场吧'), findsOneWidget);
    expect(find.text('薛诗蕾'), findsOneWidget);
  });

  testWidgets('立绘与背景图加载并渲染', (tester) async {
    final state = AppState();
    final controller = EditorController();
    await tester.pumpWidget(_wrap(EventPreviewView(
      state: state,
      controller: controller,
      eventId: '5',
    )));
    await tester.pump();
    // 等待 /api/preview/event + 两张 /api/aa/preview（背景 + 立绘）异步返回
    await tester.pump(const Duration(milliseconds: 500));

    // 背景 1 张 + 立绘 1 张（5001 对白有 role_xiaochun）
    expect(find.byType(Image), findsNWidgets(2));
  });

  testWidgets('下一条 / 上一条导航', (tester) async {
    final state = AppState();
    final controller = EditorController();
    await tester.pumpWidget(_wrap(EventPreviewView(
      state: state,
      controller: controller,
      eventId: '5',
    )));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    // 前进到 5002（旁白 + 选项）
    await tester.tap(find.byIcon(FluentIcons.chevron_right_24_regular));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('对白 2 / 3'), findsOneWidget);
    expect(find.text('太好了！'), findsOneWidget);
    expect(find.text('旁白'), findsOneWidget);
    expect(find.text('选这个选项'), findsOneWidget);

    // 后退回 5001
    await tester.tap(find.byIcon(FluentIcons.chevron_left_24_regular));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('对白 1 / 3'), findsOneWidget);
    expect(find.text('你好呀，一起去操场吧'), findsOneWidget);
  });

  testWidgets('选项分支跳转', (tester) async {
    final state = AppState();
    final controller = EditorController();
    await tester.pumpWidget(_wrap(EventPreviewView(
      state: state,
      controller: controller,
      eventId: '5',
    )));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    // 前进到选项对白
    await tester.tap(find.byIcon(FluentIcons.chevron_right_24_regular));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    // 点击选项 → 跳转分支 5003
    await tester.tap(find.text('选这个选项'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('好，我们出发！'), findsOneWidget);
    expect(find.text('对白 3 / 3'), findsOneWidget);
    expect(find.text('薛诗蕾'), findsOneWidget);
  });

  testWidgets('画笔模式开关 + AI 侧栏开关', (tester) async {
    final state = AppState();
    final controller = EditorController();
    await tester.pumpWidget(_wrap(EventPreviewView(
      state: state,
      controller: controller,
      eventId: '5',
    )));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    // AI 侧栏默认关闭，点击 chat 图标后出现 AiPanel
    expect(find.byType(AiPanel), findsNothing);
    await tester.tap(find.byIcon(FluentIcons.chat_multiple_24_regular));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byType(AiPanel), findsOneWidget);

    // 画笔开关：点击 draw_shape 图标后画布出现画笔覆盖层（圈选后弹窗由命中逻辑驱动）
    await tester.tap(find.byIcon(FluentIcons.draw_shape_24_regular));
    await tester.pump();
    // 画笔模式下仍然显示对白
    expect(find.text('你好呀，一起去操场吧'), findsOneWidget);
  });

  testWidgets('画笔圈选对白框 → 命中对白并弹窗', (tester) async {
    final state = AppState();
    final controller = EditorController();
    await tester.pumpWidget(_wrap(EventPreviewView(
      state: state,
      controller: controller,
      eventId: '5',
    )));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    // 开启画笔模式
    await tester.tap(find.byIcon(FluentIcons.draw_shape_24_regular));
    await tester.pump();

    // 圈选对白文本所在区域（底部对白框）
    final talkRect = tester.getRect(find.text('你好呀，一起去操场吧'));
    final g = await tester.startGesture(
        Offset(talkRect.left - 20, talkRect.top - 10));
    await g.moveTo(Offset(talkRect.right + 20, talkRect.bottom + 10));
    await g.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    // 命中弹窗出现，且包含对白条目
    expect(find.text('圈选内容'), findsOneWidget);
    expect(find.textContaining('对白（TalkCfg id=5001）'), findsOneWidget);
    expect(find.text('交给 AI 修改'), findsOneWidget);
  });

  testWidgets('画笔圈选场景上部 → 命中立绘/背景，不再提示未命中', (tester) async {
    final state = AppState();
    final controller = EditorController();
    await tester.pumpWidget(_wrap(EventPreviewView(
      state: state,
      controller: controller,
      eventId: '5',
    )));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    // 开启画笔模式
    await tester.tap(find.byIcon(FluentIcons.draw_shape_24_regular));
    await tester.pump();

    // 圈选画布上部（背景/立绘区域，避开对白框与选项）
    final canvas = tester.getRect(find.byType(ClipRect));
    final top = Offset(canvas.left + canvas.width * 0.20, canvas.top + canvas.height * 0.10);
    final bottom = Offset(canvas.left + canvas.width * 0.50, canvas.top + canvas.height * 0.30);
    final g = await tester.startGesture(top);
    await g.moveTo(bottom);
    await g.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    // 不应出现"未命中"提示，弹窗应显示命中内容
    expect(find.textContaining('未命中任何内容'), findsNothing);
    expect(find.text('圈选内容'), findsOneWidget);
    expect(find.textContaining('立绘角色'), findsWidgets);
  });

  testWidgets('「打开事件配置表」按钮打开 EvtCfg 文档', (tester) async {
    final state = AppState();
    final controller = EditorController();
    await tester.pumpWidget(_wrap(EventPreviewView(
      state: state,
      controller: controller,
      eventId: '5',
    )));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    await tester.tap(find.byIcon(FluentIcons.table_24_regular));
    await tester.pump();
    expect(controller.current!.kind, 'cfg');
    expect(controller.current!.cfgName, 'EvtCfg');
  });
}
