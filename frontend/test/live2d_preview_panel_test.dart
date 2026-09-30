// Live2D 面板：模型列表 / 表达式渲染 / 缓存去重 / renderer unavailable 降级。
// 全部 MockClient（后端 /api/live2d/* 由并行代理实现）。
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:student_age_editor/core/api_client.dart';
import 'package:student_age_editor/features/resources/live2d_preview_panel.dart';

const _kPng1x1 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==';

const _modelsBody = {
  'models': [
    {
      'path': 'models/a/a.model3.json',
      'name': '模型一',
      'expressions': ['joy', 'sad']
    },
    {
      'path': 'models/b/b.model3.json',
      'name': '模型二',
      'expressions': ['idle']
    },
  ],
};

List<http.Request> _install(
    {Object? renderBody, int renderStatus = 200}) {
  final reqs = <http.Request>[];
  ApiClient.instance.client = MockClient((req) async {
    reqs.add(req);
    http.Response json(Object b, [int code = 200]) => http.Response.bytes(
        utf8.encode(jsonEncode(b)), code,
        headers: {'content-type': 'application/json'});
    if (req.method == 'GET' && req.url.path == '/api/live2d/models') {
      return json(_modelsBody);
    }
    if (req.method == 'POST' && req.url.path == '/api/live2d/render') {
      final body = renderBody ??
          {'ok': true, 'mime': 'image/png', 'data': _kPng1x1};
      return json(body, renderStatus);
    }
    return json({'error': 'mock 404'}, 404);
  });
  return reqs;
}

int _renderCount(List<http.Request> reqs) =>
    reqs.where((r) => r.url.path == '/api/live2d/render').length;

Widget _wrap() => fluent.FluentApp(
      theme: fluent.FluentThemeData(brightness: Brightness.dark),
      home: Scaffold(body: Live2DPreviewPanel()),
    );

Future<void> _boot(WidgetTester tester) async {
  await tester.pumpWidget(_wrap());
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  tearDown(() => ApiClient.instance.client = http.Client());

  testWidgets('模型列表渲染：名称 + 表达式数', (tester) async {
    _install();
    await _boot(tester);
    expect(find.text('模型一'), findsOneWidget);
    expect(find.text('模型二'), findsOneWidget);
    expect(find.text('2 个表情'), findsOneWidget);
    expect(find.text('1 个表情'), findsOneWidget);
  });

  testWidgets('选中模型默认渲染 + 表达式重渲染 + 缓存二次零请求', (tester) async {
    final reqs = _install();
    await _boot(tester);

    // 载入即渲染默认表达式（模型一首个 'joy'）→ 1 次；并显示 PNG。
    expect(_renderCount(reqs), 1);
    final body0 = jsonDecode(reqs.last.body);
    expect(body0['path'], 'models/a/a.model3.json');
    expect(body0['expression'], 'joy');
    expect(find.byType(Image), findsWidgets);

    // 点 'sad' → 再渲染 1 次（共 2）。
    await tester.tap(find.text('sad'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(_renderCount(reqs), 2);
    expect(jsonDecode(reqs.last.body)['expression'], 'sad');

    // 再点回 'joy'（已缓存）→ 零新增请求。
    await tester.tap(find.text('joy'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(_renderCount(reqs), 2);
  });

  testWidgets('renderer unavailable：ok:false 降级为 InfoBar，不崩',
      (tester) async {
    final reqs = _install(renderBody: {'ok': false, 'error': 'renderer unavailable'});
    await _boot(tester);

    // 确实发起了渲染请求（这里带 path+expression，非缺参数）。
    expect(_renderCount(reqs), greaterThan(0));
    final body = jsonDecode(reqs.last.body);
    expect(body['path'], isNotEmpty);

    // 面板存活并显示后端错误文案（inline + InfoBar）。
    expect(find.textContaining('renderer unavailable'), findsWidgets);
    expect(find.text('重试'), findsWidgets);

    // 排空 InfoBar 的 3s 自动关闭定时器，避免「pending timer」断言。
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('缺参数 400 model required 也降级为 InfoBar（与 ok:false 区分文案）',
      (tester) async {
    _install(
        renderBody: {'ok': false, 'error': 'model required'},
        renderStatus: 400);
    await _boot(tester);

    // 400 走 ApiException 分支，同样把后端 error 文案显示出来，不崩。
    expect(find.textContaining('model required'), findsWidgets);
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('空模型列表（game root 落空 200 {models:[]}）显示空态',
      (tester) async {
    ApiClient.instance.client = MockClient((req) async {
      if (req.url.path == '/api/live2d/models') {
        return http.Response.bytes(
            utf8.encode(jsonEncode({'models': <dynamic>[]}))
            , 200,
            headers: {'content-type': 'application/json'});
      }
      return http.Response.bytes(
          utf8.encode(jsonEncode({'error': 'x'})), 404);
    });
    await _boot(tester);
    expect(find.text('暂无 Live2D 模型'), findsOneWidget);
  });
}
