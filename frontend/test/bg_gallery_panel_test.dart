// 背景展示（bg_gallery_panel）数据链路回归：
//   * 目录来自 /api/preview/meta 的 bgKeys/bgs（id → key / 名称）；
//   * 缩略图走 /api/aa/preview（TexBytesCache），无游戏时由后端背景资源扩展回退；
//   * 卡片点击打开大图预览。
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:student_age_editor/core/api_client.dart';
import 'package:student_age_editor/features/resources/bg_gallery_panel.dart';
import 'package:student_age_editor/features/resources/bg_visuals.dart';
import 'package:student_age_editor/features/resources/image_asset_picker.dart';

/// 合法 1×1 透明 PNG（让 Image.memory 真实解码成功）。
const _kPngBytes = <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, //
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, //
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00, //
  0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00, //
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49, //
  0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
];

void main() {
  final requests = <Uri>[];

  http.Response jsonResp(Object body) => http.Response(jsonEncode(body), 200,
      headers: {'content-type': 'application/json'});

  void installMock() {
    requests.clear();
    ApiClient.instance.client = MockClient((request) async {
      requests.add(request.url);
      if (request.url.path == '/api/preview/meta') {
        return jsonResp({
          'bgs': {'1': '操场', '2': '教室'},
          'bgKeys': {'1': 'bg_badminton', '2': 'img_jiaoshi'},
          'roles': <String, dynamic>{},
          'charKeys': <String, dynamic>{},
        });
      }
      if (request.url.path == '/api/aa/preview') {
        return jsonResp({
          'kind': 'tex',
          'mime': 'image/png',
          'data': base64Encode(_kPngBytes),
        });
      }
      if (request.url.path == '/api/aa/scan') {
        return jsonResp({'status': 'ready'});
      }
      if (request.url.path == '/api/aa/status') {
        return jsonResp({'status': 'ready'});
      }
      return http.Response('{"error":"unexpected"}', 500);
    });
  }

  setUp(() {
    BgVisualCache.instance.debugReset();
    TexBytesCache.clear();
  });

  tearDown(() {
    ApiClient.instance.client = http.Client();
  });

  Future<void> pumpPanel(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1100, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(fluent.FluentApp(
      home: Scaffold(
        body: SizedBox(
          width: 1000,
          height: 700,
          child: const BgGalleryPanel(),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('背景网格：名称/key/计数来自 /api/preview/meta', (tester) async {
    installMock();
    await pumpPanel(tester);

    expect(tester.takeException(), isNull);
    expect(find.text('背景展示'), findsOneWidget);
    expect(find.text('共 2 张'), findsOneWidget);
    expect(find.text('操场'), findsOneWidget);
    expect(find.text('教室'), findsOneWidget);
    expect(
      requests.any((u) => u.path == '/api/preview/meta'),
      isTrue,
      reason: '背景目录应来自 /api/preview/meta',
    );
  });

  testWidgets('点击背景卡片打开预览', (tester) async {
    installMock();
    await pumpPanel(tester);

    await tester.tap(find.text('操场'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('关闭'), findsOneWidget);
    expect(
      requests.any((u) => u.path == '/api/aa/preview'),
      isTrue,
      reason: '缩略图/预览应请求 /api/aa/preview',
    );
  });

  testWidgets('搜索按名称/key 过滤', (tester) async {
    installMock();
    await pumpPanel(tester);

    await tester.enterText(find.byType(fluent.TextBox), 'jiaoshi');
    await tester.pumpAndSettle();

    expect(find.text('教室'), findsOneWidget);
    expect(find.text('操场'), findsNothing);
  });
}
