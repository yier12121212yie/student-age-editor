// 故事编排视图（StoryDirectorView）与移动端事件详情页的未保存修改保护回归测试。
// 覆盖：点击当前事件不丢修改、dirty 时切换事件弹确认、保存失败中止切换；
// 移动端（阶段 2c）：编辑后返回弹确认、取消保留、保存成功后放行。
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:student_age_editor/core/api_client.dart';
import 'package:student_age_editor/core/models.dart';
import 'package:student_age_editor/features/story/story_detail_mobile_page.dart';
import 'package:student_age_editor/features/story/story_director_view.dart';

const _evtCfg = {
  '1000': {'id': 1000, 'title': '事件A', 'talkId': <dynamic>[1000001]},
  '2000': {'id': 2000, 'title': '事件B', 'talkId': <dynamic>[2000001]},
};

const _talkCfg = {
  '1000001': {
    'id': 1000001,
    'roleIds': <dynamic>[],
    'content': '原始内容A',
  },
  '2000001': {
    'id': 2000001,
    'roleIds': <dynamic>[],
    'content': '内容B',
  },
};

/// 可注入的 MockClient：GET 返回各 cfg 表，PUT 可返回 200 或 500。
MockClient _mockBackend({bool failSave = false}) {
  return MockClient((req) async {
    final path = req.url.path;
    if (req.method == 'GET' && path.startsWith('/api/cfg/')) {
      final name = path.split('/').last;
      final data = switch (name) {
        'EvtCfg' => _evtCfg,
        'TalkCfg' => _talkCfg,
        'OptionCfg' => <String, dynamic>{},
        'PersonCfg' => <String, dynamic>{},
        'BgCfg' => <String, dynamic>{},
        'AudioCfg' => <String, dynamic>{},
        'EvtTypeCfg' => <String, dynamic>{},
        _ => <String, dynamic>{},
      };
      return http.Response(
          jsonEncode({'cfg': name, 'data': data, 'exists': true}), 200,
          headers: {'content-type': 'application/json'});
    }
    if (req.method == 'PUT' && path.startsWith('/api/cfg/')) {
      if (failSave) return http.Response(jsonEncode({'error': '模拟保存失败'}), 500);
      return http.Response(jsonEncode({'ok': true}), 200,
          headers: {'content-type': 'application/json'});
    }
    return http.Response(jsonEncode({'error': 'not found'}), 404);
  });
}

Future<void> _pumpStory(WidgetTester tester, {bool failSave = false}) async {
  // 三栏布局需要较宽窗口，避免窄窗渲染溢出干扰断言
  tester.view.physicalSize = const Size(1600, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  ApiClient.instance.client = _mockBackend(failSave: failSave);
  final state = AppState();
  await tester.pumpWidget(fluent.FluentApp(
    home: Scaffold(body: StoryDirectorView(state: state)),
  ));
  await tester.pumpAndSettle();
}

/// 找到对白内容输入框（placeholder 特征）。
Finder _contentBox() => find.byWidgetPredicate((w) =>
    w is fluent.TextBox &&
    w.placeholder == '输入对白内容（支持 <color=..> <size=..> 富文本标签）');

Future<void> _editContent(WidgetTester tester, String text) async {
  final box = _contentBox();
  await tester.ensureVisible(box);
  await tester.enterText(box, text);
  await tester.pump();
}

void main() {
  tearDown(() {
    ApiClient.instance.client = http.Client();
  });

  testWidgets('点击当前已选中事件不弹确认、不丢未保存修改', (tester) async {
    await _pumpStory(tester);
    await _editContent(tester, '新内容A');

    // 点击当前事件（1000）的列表项
    await tester.tap(find.textContaining('[1000]').first);
    await tester.pumpAndSettle();

    expect(find.text('保存并切换'), findsNothing,
        reason: '点击当前事件不应触发未保存确认对话框');
    expect(
        tester.widget<fluent.TextBox>(_contentBox()).controller?.text, '新内容A',
        reason: '点击当前事件不应重载舞台丢弃未保存修改');
  });

  testWidgets('dirty 时切换事件弹确认，取消后保留修改', (tester) async {
    await _pumpStory(tester);
    await _editContent(tester, '新内容A');

    await tester.tap(find.textContaining('[2000]').first);
    await tester.pumpAndSettle();

    expect(find.text('保存并切换'), findsOneWidget,
        reason: 'dirty 时切换事件应弹未保存确认对话框');

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(find.text('保存并切换'), findsNothing,
        reason: '取消后对话框应关闭');
    expect(
        tester.widget<fluent.TextBox>(_contentBox()).controller?.text, '新内容A',
        reason: '取消后应停留在原事件并保留修改');
  });

  testWidgets('保存失败时「保存并切换」中止切换、保留现场', (tester) async {
    await _pumpStory(tester, failSave: true);
    await _editContent(tester, '新内容A');

    await tester.tap(find.textContaining('[2000]').first);
    await tester.pumpAndSettle();
    expect(find.text('保存并切换'), findsOneWidget);

    await tester.tap(find.text('保存并切换'));
    await tester.pumpAndSettle();

    // 保存失败（PUT 返回 500）应中止切换：仍停留在 1000 且内容未被丢弃
    expect(find.text('内容B'), findsNothing,
        reason: '保存失败后不应切换到事件 B');
    expect(
        tester.widget<fluent.TextBox>(_contentBox()).controller?.text, '新内容A',
        reason: '保存失败后不应丢弃未保存修改');
    expect(find.text('保存并切换'), findsNothing,
        reason: '保存失败后确认对话框应已关闭');
    // 让「保存失败」InfoBar 的自动关闭 Timer 过期，避免测试收尾报 pending timer
    await tester.pump(const Duration(seconds: 6));
  });

  // ---------------- 移动端事件详情页（阶段 2c） ----------------
  group('移动端详情页未保存守卫', () {
    Future<void> pumpDetail(WidgetTester tester, {bool failSave = false}) async {
      // HapticFeedback 走平台通道：测试环境无真实处理器时 await 永挂
      // （保存链路卡在 MobileHaptic.success），必须 mock 成 no-op。
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform,
              (call) async => null);
      tester.view.physicalSize = const Size(500, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      ApiClient.instance.client = MockClient((req) async {
        final path = req.url.path;
        if (req.method == 'GET' && path.startsWith('/api/cfg/')) {
          final name = path.split('/').last;
          final data = switch (name) {
            'EvtCfg' => const {
                '1000': {'id': 1000, 'title': '事件A', 'talkId': <dynamic>[1000001]},
              },
            'TalkCfg' => const {
                '1000001': {
                  'id': 1000001,
                  'content': '原始内容A',
                  'roleIds': <dynamic>[],
                },
              },
            _ => const <String, dynamic>{},
          };
          return http.Response(
              jsonEncode({'cfg': name, 'data': data, 'exists': true}), 200,
              headers: {'content-type': 'application/json'});
        }
        if (req.method == 'POST' && path == '/api/story/event/save') {
          if (failSave) {
            return http.Response(jsonEncode({'error': '模拟保存失败'}), 500);
          }
          return http.Response(jsonEncode({'ok': true}), 200,
              headers: {'content-type': 'application/json'});
        }
        return http.Response(jsonEncode({'error': 'not found'}), 404);
      });
      await tester.pumpWidget(fluent.FluentApp(
        home: Builder(builder: (ctx) => Scaffold(
              body: Center(
                child: TextButton(
                  key: const Key('go_detail'),
                  onPressed: () => Navigator.push(
                    ctx,
                    MaterialPageRoute(
                      builder: (_) => const StoryDetailMobilePage(
                          modName: 'm', eventId: '1000'),
                    ),
                  ),
                  child: const Text('进入详情页'),
                ),
              ),
            )),
      ));
      await tester.tap(find.byKey(const Key('go_detail')));
      await tester.pumpAndSettle();
      expect(find.text('事件A'), findsWidgets,
          reason: '直达详情也应回填事件元数据，而不是「事件不存在」');
    }

    Finder contentBox() => find.byWidgetPredicate((w) =>
        w is TextField &&
        (w.decoration?.hintText ?? '').startsWith('输入对白内容'));

    Future<void> editContent(WidgetTester tester, String text) async {
      final box = contentBox();
      await tester.ensureVisible(box);
      await tester.enterText(box, text);
      await tester.pump();
    }

    testWidgets('编辑后返回弹确认，取消保留修改', (tester) async {
      await pumpDetail(tester);
      await editContent(tester, '改过的对白');

      await tester.tap(find.byTooltip('返回'));
      await tester.pumpAndSettle();
      expect(find.text('有未保存修改'), findsOneWidget);

      await tester.tap(find.text('留在本页'));
      await tester.pumpAndSettle();
      expect(find.text('有未保存修改'), findsNothing);
      expect(tester.widget<TextField>(contentBox()).controller?.text,
          '改过的对白');
      // 仍在详情页且再次返回仍会拦
      await tester.tap(find.byTooltip('返回'));
      await tester.pumpAndSettle();
      expect(find.text('有未保存修改'), findsOneWidget);
      await tester.tap(find.text('放弃并离开'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('go_detail')), findsOneWidget);
    });

    testWidgets('保存成功后经对话框「好」直接返回列表', (tester) async {
      await pumpDetail(tester);
      await editContent(tester, '改过的对白');

      await tester.tap(find.byTooltip('保存'));
      await tester.pumpAndSettle();
      expect(find.text('保存成功'), findsOneWidget);
      expect(find.text('有未保存修改'), findsNothing);

      await tester.tap(find.text('好')); // 成功对话框设计上连带退出详情页
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('go_detail')), findsOneWidget);
    });

    testWidgets('保存失败后返回仍被拦截', (tester) async {
      await pumpDetail(tester, failSave: true);
      await editContent(tester, '改过的对白');

      await tester.tap(find.byTooltip('保存'));
      await tester.pumpAndSettle();
      // 失败提示对话框关闭
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('返回'));
      await tester.pumpAndSettle();
      expect(find.text('有未保存修改'), findsOneWidget);
    });
  });
}
