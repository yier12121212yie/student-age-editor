// 资源面板（asset_explorer_panel）数据链路回归：
//   * 目录/标签来自 /api/assets/{catalog,tags}（旧的 /plugin/assets/* 已随
//     Python 插件服务退役，后端无该路由）；
//   * 过滤/分页在服务端做——搜索与标签点击都要带上 query，而不是本地筛已拉到的那页；
//   * tags 是 JSON 数组（List<dynamic>），卡片渲染不得抛类型异常；
//   * 预览走按 key 缓存的 future + compute 解码（见下两个预览用例）。
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:student_age_editor/core/api_client.dart';
import 'package:student_age_editor/features/resources/asset_explorer_panel.dart';

const _sha24a = '0123456789abcdef01234567';
const _sha24b = '89abcdef0123456789abcdef';

/// 合法 1×1 透明 PNG（Flutter 测试惯用字节）：让 Image.memory 真实解码成功，
/// 预览断言不吃「解码异常被吞」的运气。
const _kPreviewPngBytes = <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, //
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, //
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00, //
  0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00, //
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49, //
  0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
];

Map<String, dynamic> _row(String key, String kind, List<String> tags, String sha24) => {
      'key': key,
      'original_name': key,
      'kind': kind,
      'width': 0,
      'height': 0,
      'sha24': sha24,
      'tags': tags,
    };

final _allRows = <Map<String, dynamic>>[
  _row('character_sakura_001', 'sprite', ['role', 'role-001'], _sha24a),
  _row('bgm_theme_789', 'audio', ['bgm'], _sha24b),
];

/// compute（后台 isolate）的结果送达要走真实事件循环，FakeAsync 的
/// pumpAndSettle 等不到它——在 runAsync 里短延时轮询，直到预览图出现。
Future<void> settlePreviewCompute(WidgetTester tester) async {
  await tester.runAsync(() async {
    for (var i = 0; i < 40 && find.byType(Image).evaluate().isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
      await tester.pump();
    }
  });
}

void main() {
  final requests = <Uri>[];

  int previewRequests() =>
      requests.where((u) => u.path == '/api/aa/preview').length;

  http.Response jsonResp(Object body) => http.Response(jsonEncode(body), 200,
      headers: {'content-type': 'application/json'});

  void installMock({bool failing = false}) {
    requests.clear();
    ApiClient.instance.client = MockClient((request) async {
      requests.add(request.url);
      if (failing) return http.Response('{"error":"boom"}', 500);
      if (request.url.path == '/api/assets/tags') {
        return jsonResp({
          'status': 'ready',
          'total': 2,
          'tags': ['role', 'bgm'],
          'counts': {'role': 1, 'bgm': 1},
        });
      }
      if (request.url.path == '/api/aa/scan') {
        return jsonResp({'status': 'ready', 'total': _allRows.length});
      }
      if (request.url.path == '/api/aa/preview') {
        return jsonResp({
          'status': 'ok',
          'kind': 'tex',
          'mime': 'image/png',
          'data': base64Encode(_kPreviewPngBytes),
        });
      }
      if (request.url.path == '/api/assets/catalog') {
        final q = request.url.queryParameters['q'] ?? '';
        final tags = (request.url.queryParameters['tags'] ?? '')
            .split(',')
            .where((t) => t.isNotEmpty)
            .toList();
        final kind = request.url.queryParameters['kind'] ?? '';
        final rows = _allRows.where((r) {
          if (q.isNotEmpty && !(r['key'] as String).contains(q)) return false;
          if (kind.isNotEmpty && r['kind'] != kind) return false;
          if (tags.isNotEmpty &&
              !(r['tags'] as List).any((t) => tags.contains(t))) {
            return false;
          }
          return true;
        }).toList();
        return jsonResp({
          'status': 'ready',
          'total': _allRows.length,
          'matched': rows.length,
          'returned': rows.length,
          'truncated': false,
          'counts': {'sprite': 1, 'texture': 0, 'audio': 1},
          'resources_by_kind': {
            'sprite': rows.where((r) => r['kind'] == 'sprite').toList(),
            'texture': <Map<String, dynamic>>[],
            'audio': rows.where((r) => r['kind'] == 'audio').toList(),
          },
        });
      }
      return http.Response('{"error":"unexpected"}', 500);
    });
  }

  Future<void> pumpPanel(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(fluent.FluentApp(
      home: Scaffold(
        body: SizedBox(
          width: 1000,
          height: 700,
          child: const AssetExplorerPanel(),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  tearDown(() {
    ApiClient.instance.client = http.Client();
  });

  testWidgets('目录渲染：两张卡片 + 标签云 + 计数行', (tester) async {
    installMock();
    await pumpPanel(tester);

    expect(tester.takeException(), isNull);
    expect(find.text('character_sakura_001'), findsOneWidget);
    expect(find.text('bgm_theme_789'), findsOneWidget);
    // 标签云来自 /api/assets/tags。
    expect(find.text('清除选择'), findsOneWidget);
    expect(find.text('role'), findsWidgets);
    // 计数行用的是服务端口径（total）。
    expect(find.textContaining('共 2 条'), findsOneWidget);
    expect(
      requests.any((u) => u.path == '/api/assets/catalog' && u.queryParameters['limit'] == '500'),
      isTrue,
      reason: 'catalog 请求应带 limit',
    );
  });

  testWidgets('搜索走服务端：防抖后带 q 重新请求，列表随之收敛', (tester) async {
    installMock();
    await pumpPanel(tester);

    await tester.enterText(find.byType(TextField), 'bgm');
    await tester.pump(const Duration(milliseconds: 300)); // 越过 220ms 防抖
    await tester.pumpAndSettle();

    expect(requests.any((u) => u.queryParameters['q'] == 'bgm'), isTrue,
        reason: '搜索应在服务端过滤（带 q 参数）');
    expect(find.text('bgm_theme_789'), findsOneWidget);
    expect(find.text('character_sakura_001'), findsNothing);
  });

  testWidgets('标签点击走服务端：带 tags 请求并只渲染匹配项；清除选择恢复', (tester) async {
    installMock();
    await pumpPanel(tester);

    // 标签栏在网格之前，first 命中标签云里的那个 chip。
    await tester.tap(find.text('role').first);
    await tester.pumpAndSettle();

    expect(requests.any((u) => u.queryParameters['tags'] == 'role'), isTrue,
        reason: '点标签应带 tags= 重新请求');
    expect(find.text('character_sakura_001'), findsOneWidget);
    expect(find.text('bgm_theme_789'), findsNothing);

    await tester.tap(find.text('清除选择'));
    await tester.pumpAndSettle();

    final last = requests.lastWhere((u) => u.path == '/api/assets/catalog');
    expect(last.queryParameters.containsKey('tags'), isFalse);
    expect(find.text('bgm_theme_789'), findsOneWidget);
  });

  testWidgets('类型下拉走服务端：kind 参数 + 空结果走空态', (tester) async {
    installMock();
    await pumpPanel(tester);

    await tester.tap(find.text('全部'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('音频').last);
    await tester.pumpAndSettle();

    expect(requests.any((u) => u.queryParameters['kind'] == 'audio'), isTrue);
    expect(find.text('bgm_theme_789'), findsOneWidget);
    expect(find.text('character_sakura_001'), findsNothing);
  });

  testWidgets('后端 500：空态 + 错误文案，不抛异常', (tester) async {
    installMock(failing: true);
    await pumpPanel(tester);

    expect(tester.takeException(), isNull);
    expect(find.textContaining('API 500'), findsOneWidget);
  });

  testWidgets('预览缓存：同一资源重复打开只发一次 /api/aa/preview', (tester) async {
    installMock();
    await pumpPanel(tester);

    // 打开立绘预览：future 进缓存，请求发出。
    await tester.tap(find.text('character_sakura_001'));
    await tester.pump();
    await tester.pump(); // 对话框重建路径：同 key 复用 future，不得二次请求
    expect(previewRequests(), 1);

    // 等 compute 回传 + Image.memory 解码落地。
    await settlePreviewCompute(tester);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byType(Image), findsOneWidget);

    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();

    // 重开命中缓存：不再发请求，直接渲染。
    await tester.tap(find.text('character_sakura_001'));
    await tester.pumpAndSettle();
    expect(previewRequests(), 1);
    expect(find.byType(Image), findsOneWidget);
  });

  testWidgets('重读索引清空预览缓存：刷新后重开预览会重新请求', (tester) async {
    installMock();
    await pumpPanel(tester);

    await tester.tap(find.text('character_sakura_001'));
    await tester.pump();
    await settlePreviewCompute(tester);
    await tester.pumpAndSettle();
    expect(previewRequests(), 1);

    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();

    // 触发「重新读取索引」→ 扫描 → 弹确认框 → 确定。
    await tester.tap(find.text('重新读取索引'));
    await tester.pump();
    await tester.pumpAndSettle();
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(previewRequests(), 1); // 扫描本身不发预览请求

    // 刷新清缓存后重开预览：应重新发起请求。
    await tester.tap(find.text('character_sakura_001'));
    await tester.pump();
    expect(previewRequests(), 2, reason: '刷新后缓存已清，预览应重新拉取');
  });
}
