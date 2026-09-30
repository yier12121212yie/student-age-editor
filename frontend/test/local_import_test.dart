// 「从本地电脑导入」(local_import) 回归。
//
// 契约（后端由主会话并行实现，这里全部用 MockClient 打桩）：
//   POST /api/mod/import_files
//     {"files":[{"name","data"(base64),"dir"?}], "register_audio": bool}
//     -> 200 {"saved":[{name,path,size,audio_id,audio_error}], "errors":[{name,error}]}
//     -> 400 {"error":"未选择模组"}
//
// 覆盖点：
//   * 纯网络层 importFiles：请求体形状、saved/errors 原样透传（重名后缀是
//     后端算的，前端不得改写）、400 错误信封透出；
//   * UI 层 importLocalAssets：文件读取通过 `picker` 注入（file_selector 在
//     flutter test 环境没有平台通道实现），断言空选/失败/逐条错误的 fluent
//     InfoBar 中文提示，以及图片导入成功后 TexBytesCache 失效。
import 'dart:convert';

import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:student_age_editor/core/api_client.dart';
import 'package:student_age_editor/features/resources/image_asset_picker.dart'
    show TexBytesCache;
import 'package:student_age_editor/features/resources/local_import.dart';

/// 1×1 透明 PNG（base64），够用来验证「原样 base64 上行」。
const _kPng1x1 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==';

final _pngBytes = base64Decode(_kPng1x1);

void main() {
  final posts = <http.Request>[];

  http.Response jsonResp(Object body, {int status = 200}) => http.Response(
      jsonEncode(body), status,
      headers: {'content-type': 'application/json'});

  /// 装一个只认 `/api/mod/import_files` 的 mock：状态码与响应体由用例给。
  void installImport({
    Object? body,
    int status = 200,
  }) {
    posts.clear();
    ApiClient.instance.client = MockClient((req) async {
      posts.add(req);
      if (req.url.path != '/api/mod/import_files') {
        return jsonResp({'error': 'unexpected ${req.url.path}'}, status: 500);
      }
      return jsonResp(body ?? {'saved': [], 'errors': []}, status: status);
    });
  }

  /// 最近一次导入请求的 JSON 体。
  Map<String, dynamic> imported() =>
      jsonDecode(posts.last.body) as Map<String, dynamic>;

  Map<String, dynamic> savedOf(String name, String path,
          {Object? audioId, Object? audioError}) =>
      {
        'name': name,
        'path': path,
        'size': 4,
        'audio_id': audioId,
        'audio_error': audioError,
      };

  tearDown(() {
    ApiClient.instance.client = http.Client();
    debugLocalFilePicker = null;
  });

  group('importFiles（纯网络层）', () {
    test('请求体形状：files[{name,data}] + register_audio，缺省不带 dir', () async {
      installImport();
      await importFiles([(name: 'a.png', bytes: _pngBytes)]);

      expect(posts, hasLength(1));
      expect(posts.single.url.path, '/api/mod/import_files');
      final body = imported();
      final files = body['files'] as List;
      expect(files, hasLength(1));
      final f0 = files.single as Map<String, dynamic>;
      expect(f0['name'], 'a.png');
      // 上行必须是原始字节的 base64，后端直接解码落盘。
      expect(base64Decode(f0['data'] as String), _pngBytes);
      expect(f0.containsKey('dir'), isFalse,
          reason: 'dir 缺省时由后端按扩展名推断，前端不要塞空值');
      expect(body['register_audio'], isFalse);
    });

    test('多文件 + 显式 dir + register_audio=true 一并透传', () async {
      installImport();
      await importFiles(
        [
          (name: 'a.png', bytes: _pngBytes),
          (name: 'b.wav', bytes: _pngBytes),
        ],
        registerAudio: true,
        dir: 'Textures',
      );

      final body = imported();
      final files = (body['files'] as List).cast<Map<String, dynamic>>();
      expect(files.map((f) => f['name']), ['a.png', 'b.wav']);
      expect(files.every((f) => f['dir'] == 'Textures'), isTrue);
      expect(body['register_audio'], isTrue);
    });

    test('saved/errors 原样透传（含后端算出的重名后缀与 audio_id）', () async {
      installImport(body: {
        'saved': [
          savedOf('a.png', 'Textures/a_1.png'),
          savedOf('vo.mp3', 'Audios/vo.mp3', audioId: 77),
        ],
        'errors': [
          {'name': 'x.psd', 'error': '无法按扩展名推断目录，请放入指定文件夹'},
        ],
      });

      final r = await importFiles([(name: 'a.png', bytes: _pngBytes)]);
      // 重名后缀必须是后端给的 path，前端不得按「原名」回写。
      expect(r.saved.map((s) => s['path']), ['Textures/a_1.png', 'Audios/vo.mp3']);
      expect(r.saved[1]['audio_id'], 77);
      expect(r.saved[0]['audio_id'], isNull);
      expect(r.errors.single['error'], contains('扩展名'));
    });

    test('未选模组 400：ApiException 带后端中文错误', () async {
      installImport(status: 400, body: {'error': '未选择模组'});
      await expectLater(
        importFiles([(name: 'a.png', bytes: _pngBytes)]),
        throwsA(isA<ApiException>()
            .having((e) => e.statusCode, 'statusCode', 400)
            .having((e) => e.message, 'message', '未选择模组')),
      );
    });
  });

  group('importLocalAssets（picker 注入 + InfoBar 反馈）', () {
    /// 在 FluentApp + Scaffold（displayInfoBar 需要 FluentTheme 与 Overlay）里
    /// 跑一次导入，结果存进 [out]。
    Future<void> runImport(
      WidgetTester tester,
      void Function(List<Map<String, dynamic>>) target, {
      required String kind,
      bool registerAudio = false,
      required List<PickedLocalFile> Function() files,
    }) async {
      await tester.pumpWidget(fluent.FluentApp(
        home: Scaffold(
          body: Center(
            child: Builder(
              builder: (context) => fluent.Button(
                onPressed: () async {
                  // 显式注入 picker：测试环境没有 file_selector 的平台实现。
                  target(await importLocalAssets(
                    context,
                    kind: kind,
                    registerAudio: registerAudio,
                    picker: (_) async => files(),
                  ));
                },
                child: const Text('go'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('go'));
      await tester.pump();
      await tester.pump();
      // displayInfoBar 先占位 SizedBox.shrink()，等 mediumAnimationDuration
      // （默认 250ms）才换成真实 InfoBar；不推进假时间永远 find 不到。
      await tester.pump(const Duration(milliseconds: 300));
    }

    testWidgets('取消选择：不发请求，InfoBar 中文提示', (tester) async {
      installImport();
      late List<Map<String, dynamic>> out;
      await runImport(tester, (r) => out = r,
          kind: 'image', files: () => const []);

      expect(out, isEmpty);
      expect(posts, isEmpty, reason: '没选到文件就不该打后端');
      expect(find.text('未选择文件'), findsOneWidget);
      await _drainInfoBar(tester);
    });

    testWidgets('图片导入成功：返回 saved 且失效 TexBytesCache', (tester) async {
      installImport(body: {
        'saved': [savedOf('a.png', 'Textures/a_1.png')],
        'errors': [],
      });
      // 先塞一张旧字节：导入后必须被清掉，否则同名图仍显示旧内容。
      TexBytesCache.debugPut('a_1.png', _pngBytes);
      expect(TexBytesCache.peek('a_1.png'), isNotNull);

      late List<Map<String, dynamic>> out;
      await runImport(tester, (r) => out = r,
          kind: 'image', files: () => [(name: 'a.png', bytes: _pngBytes)]);

      expect(out.single['path'], 'Textures/a_1.png');
      expect(TexBytesCache.peek('a_1.png'), isNull,
          reason: '图片导入成功后必须清进程级字节缓存');
      expect(imported()['register_audio'], isFalse);
      expect(find.textContaining('已导入 1 个文件'), findsOneWidget);
      expect(find.textContaining('Textures/a_1.png'), findsOneWidget);
      await _drainInfoBar(tester);
    });

    testWidgets('音频导入：register_audio=true，且不动图片缓存', (tester) async {
      installImport(body: {
        'saved': [savedOf('vo.mp3', 'Audios/vo.mp3', audioId: 12)],
        'errors': [],
      });
      TexBytesCache.debugPut('keep', _pngBytes);

      late List<Map<String, dynamic>> out;
      await runImport(tester, (r) => out = r,
          kind: 'audio',
          registerAudio: true,
          files: () => [(name: 'vo.mp3', bytes: _pngBytes)]);

      expect(imported()['register_audio'], isTrue);
      expect(out.single['audio_id'], 12);
      expect(TexBytesCache.peek('keep'), isNotNull,
          reason: '音频导入与图片缓存无关，不该顺手清掉');
      await _drainInfoBar(tester);
    });

    testWidgets('errors 数组逐条展示；部分成功也算问题项', (tester) async {
      installImport(body: {
        'saved': [savedOf('ok.png', 'Textures/ok.png')],
        'errors': [
          {'name': 'x.psd', 'error': '无法推断目录'},
          {'name': 'y.txt', 'error': '非法文件名'},
        ],
      });

      late List<Map<String, dynamic>> out;
      await runImport(tester, (r) => out = r,
          kind: 'image', files: () => [(name: 'ok.png', bytes: _pngBytes)]);

      expect(out, hasLength(1), reason: '成功项照常回传给调用方');
      expect(find.textContaining('1 项有问题'), findsNothing);
      expect(find.textContaining('2 项有问题'), findsOneWidget);
      expect(find.textContaining('x.psd：无法推断目录'), findsOneWidget);
      expect(find.textContaining('y.txt：非法文件名'), findsOneWidget);
      await _drainInfoBar(tester);
    });

    testWidgets('已存盘但音频登记失败：audio_error 也逐条提示', (tester) async {
      installImport(body: {
        'saved': [
          savedOf('bad.mp3', 'Audios/bad.mp3',
              audioError: 'AudioCfg 写入失败'),
        ],
        'errors': [],
      });

      late List<Map<String, dynamic>> out;
      await runImport(tester, (r) => out = r,
          kind: 'audio',
          registerAudio: true,
          files: () => [(name: 'bad.mp3', bytes: _pngBytes)]);

      expect(out, hasLength(1));
      expect(find.textContaining('bad.mp3：已存盘但音频登记失败'), findsOneWidget);
      expect(find.textContaining('AudioCfg 写入失败'), findsOneWidget);
      await _drainInfoBar(tester);
    });

    testWidgets('后端 400：InfoBar 展示后端原文「未选择模组」', (tester) async {
      installImport(status: 400, body: {'error': '未选择模组'});

      late List<Map<String, dynamic>> out;
      await runImport(tester, (r) => out = r,
          kind: 'image', files: () => [(name: 'a.png', bytes: _pngBytes)]);

      expect(out, isEmpty);
      expect(find.text('导入失败'), findsOneWidget);
      expect(find.textContaining('未选择模组'), findsOneWidget);
      await _drainInfoBar(tester);
    });

    testWidgets('全部失败（只有 errors）：按失败提示且返回空表', (tester) async {
      installImport(body: {
        'saved': [],
        'errors': [
          {'name': 'a.png', 'error': '磁盘写入失败'},
        ],
      });

      late List<Map<String, dynamic>> out;
      await runImport(tester, (r) => out = r,
          kind: 'image', files: () => [(name: 'a.png', bytes: _pngBytes)]);

      expect(out, isEmpty);
      expect(find.text('导入失败'), findsOneWidget);
      expect(find.textContaining('a.png：磁盘写入失败'), findsOneWidget);
      await _drainInfoBar(tester);
    });

    testWidgets('选择器本身抛错（缺平台实现等）：提示且不崩', (tester) async {
      installImport();

      late List<Map<String, dynamic>> out;
      await runImport(tester, (r) => out = r, kind: 'image', files: () {
        throw UnsupportedError('file_selector 未注册平台实现');
      });

      expect(out, isEmpty);
      expect(find.textContaining('打开文件选择器失败'), findsOneWidget);
      expect(find.textContaining('file_selector'), findsOneWidget);
      expect(posts, isEmpty);
      await _drainInfoBar(tester);
    });

    testWidgets('缺省 picker 走 debugLocalFilePicker（深层按钮无法透传时用）',
        (tester) async {
      installImport(body: {
        'saved': [savedOf('g.png', 'Textures/g.png')],
        'errors': [],
      });
      var pickedKind = '';
      debugLocalFilePicker = (kind) async {
        pickedKind = kind;
        return [(name: 'g.png', bytes: _pngBytes)];
      };

      await tester.pumpWidget(fluent.FluentApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => fluent.Button(
              // 不传 picker：模拟真实按钮的调用形态。
              onPressed: () => importLocalAssets(context, kind: 'audio'),
              child: const Text('go'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('go'));
      await tester.pump();
      await tester.pump();
      // InfoBar 占位动画推进（与 runImport 同口径），否则 find 不到文本。
      await tester.pump(const Duration(milliseconds: 300));

      expect(pickedKind, 'audio');
      expect(imported()['register_audio'], isFalse,
          reason: 'register_audio 默认 false，由接线方显式打开');
      expect(find.textContaining('已导入 1 个文件'), findsOneWidget);
      await _drainInfoBar(tester);
    });
  });
}

/// displayInfoBar 的自动关闭是 6s 定时器（不持续排帧），pumpAndSettle 排不掉；
/// 直接把假时间推过定时器，再收尾退场动画，避免「Timer is still pending」。
Future<void> _drainInfoBar(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 7));
  await tester.pumpAndSettle();
}
