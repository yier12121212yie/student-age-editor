// 事件预览「音频演出 + 屏幕效果演出」测试（覆盖修正后的后端契约：
//   顶层 audios 映射、screen_effects: talkId→{code,args}|null、stage.bgm 增量）。
// 全部用 MockClient；音频平台通道在测试环境不可用（play 抛异常被吞），
// 但取字节的 HTTP 请求照常发出，可断言。
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
import 'package:student_age_editor/features/editor/editor_controller.dart';
import 'package:student_age_editor/features/preview/event_preview_view.dart';
import 'package:student_age_editor/features/preview/preview_models.dart';
import 'package:student_age_editor/features/preview/stage_effects.dart';

/// 1x1 透明 PNG（背景/立绘/CG 贴图）。
const _kPng1x1 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==';

/// 「有效音频字节」占位（小体积，走同步 base64Decode，不碰 isolate）。
final _kB64Aud = base64Encode([137, 80, 78, 71, 13, 10, 26, 10]);

Map<String, dynamic> _talk(
  String id,
  String content, {
  List<int> next = const [],
  String? bgm,
  bool bgmKey = true,
}) {
  final stage = <String, dynamic>{
    'bg': null,
    'chars': <dynamic>[],
    if (bgmKey) 'bgm': bgm,
  };
  return {
    'id': int.tryParse(id) ?? id,
    'content': content,
    'roleIds': [-1],
    'roleName': '',
    'option': <dynamic>[],
    'nextTalk': next,
    'nextTalk2': <dynamic>[],
    'check': <dynamic>[],
    'stage': stage,
  };
}

Map<String, dynamic> _fxPayload() => {
      'ok': true,
      'evt_id': '9',
      'event_title': 'FX事件',
      'starts': ['5001'],
      'stage': {'bgm': null},
      'talks': {
        '5001': _talk('5001', '开始', next: [5002], bgm: null),
        '5002': _talk('5002', '进BGM', next: [5003], bgm: '700'),
        '5003': _talk('5003', '同BGM', next: [5004], bgm: '700'),
        '5004': _talk('5004', '闪白', next: [5005], bgm: '700'),
        '5005': _talk('5005', '放CG', next: [], bgm: '700'),
      },
      'options': <String, dynamic>{},
      'audios': {
        '700': {'url': 'aud/bgm_700.ogg', 'name': 'BGM 700', 'type': 1},
      },
      'screen_effects': {
        '5001': null,
        '5002': null,
        '5003': null,
        '5004': {'code': 4012, 'args': [0]},
        '5005': {'code': 4015, 'args': [900]},
      },
      'meta': {'roles': {}, 'bgs': {}, 'bgKeys': {}, 'charKeys': {}},
    };

/// 安装 FX Mock：返回记录到的请求列表。
List<http.Request> _installFx() {
  final reqs = <http.Request>[];
  ApiClient.instance.client = MockClient((req) async {
    reqs.add(req);
    final path = req.url.path;
    Map<String, dynamic> body;
    if (req.method == 'POST' && path == '/api/preview/event') {
      body = _fxPayload();
    } else if (req.method == 'POST' && path == '/api/aa/preview') {
      final kind = (jsonDecode(req.body)['kind']) ?? '';
      body = kind == 'aud'
          ? {'kind': 'aud', 'mime': 'audio/ogg', 'data': _kB64Aud}
          : {'kind': 'tex', 'mime': 'image/png', 'data': _kPng1x1};
    } else if (req.method == 'GET' && path == '/api/cfg/CGCfg') {
      body = {
        'data': {
          '900': {'url': 'cg/cg_900.png', 'name': 'CG900'}
        },
        'keys': ['900']
      };
    } else if (path == '/api/state') {
      body = {'mod_name': 'test', 'ok': true};
    } else {
      body = {'error': 'mock 404: $path'};
      return http.Response.bytes(utf8.encode(jsonEncode(body)), 404,
          headers: {'content-type': 'application/json'});
    }
    return http.Response.bytes(utf8.encode(jsonEncode(body)), 200,
        headers: {'content-type': 'application/json'});
  });
  return reqs;
}

/// kind=aud 的 /api/aa/preview 次数。
int _audCount(List<http.Request> reqs) => reqs
    .where((r) =>
        r.url.path == '/api/aa/preview' &&
        (jsonDecode(r.body)['kind'] == 'aud'))
    .length;

Widget _wrap(Widget child) => fluent.FluentApp(
      theme: fluent.FluentThemeData(brightness: Brightness.dark),
      home: Scaffold(body: child),
    );

Future<void> _boot(WidgetTester tester) async {
  final state = AppState();
  final controller = EditorController();
  await tester.pumpWidget(_wrap(EventPreviewView(
    state: state,
    controller: controller,
    eventId: '9',
  )));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 250));
}

Future<void> _advance(WidgetTester tester, {int times = 1}) async {
  for (var i = 0; i < times; i++) {
    await tester.tap(find.byIcon(FluentIcons.chevron_right_24_regular));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() => ApiClient.instance.client = http.Client());

  // ---------------- 契约解析（纯模型） ----------------

  test('screen_effects 映射 / stage.bgm / audios 解析', () {
    final d = PreviewEventData.fromJson(_fxPayload());
    expect(d.audios['700']!.isBgm, true);
    expect(d.audios['700']!.url, 'aud/bgm_700.ogg');
    expect(d.talks['5002']!.stage.hasBgm, true);
    expect(d.talks['5002']!.stage.bgmId, '700');
    expect(d.talks['5001']!.stage.hasBgm, true);
    expect(d.talks['5001']!.stage.bgmId, null);
    // 覆盖每条访问到的 talk：显式 null 也要有键。
    expect(d.screenEffects.containsKey('5004'), true);
    expect(d.screenEffects['5004']!.code, 4012);
    expect(d.screenEffects['5005']!.code, 4015);
    expect(d.screenEffects['5005']!.args, [900]);
    expect(d.screenEffects['5002'], isNull);
    expect(d.screenEffects.containsKey('5002'), true);
  });

  test('stage 无 bgm 键 → hasBgm=false（回落 talk.audio）', () {
    final j = _fxPayload();
    // 去掉 5002 的 bgm 键
    (j['talks']['5002']['stage'] as Map).remove('bgm');
    final d = PreviewEventData.fromJson(j);
    expect(d.talks['5002']!.stage.hasBgm, false);
  });

  test('屏效状态机：持续滤镜粘滞 / 黑屏逐句 / 4003 复位', () {
    const s0 = StageVisual();
    final blur = nextStageVisual(s0, ScreenEffect.fromDirective(4002, const []));
    expect(blur.blur, true);
    // 下一句黑屏：模糊保持、黑屏出现、无 CG。
    final s2 = nextStageVisual(blur, ScreenEffect.fromDirective(4006, const []));
    expect(s2.blur, true);
    expect(s2.black, true);
    expect(s2.cgRef, isNull);
    // 清特效 4003：模糊复位；本句非 4006 → 黑屏结束。
    final s3 = nextStageVisual(s2, ScreenEffect.fromDirective(4003, const []));
    expect(s3.blur, false);
    expect(s3.black, false);
    // 播 CG 逐句：本句 4015 → cgRef；下一句无码 → 结束。
    final cg = nextStageVisual(s0, ScreenEffect.fromDirective(4015, [900]));
    expect(cg.cgRef, 900);
    expect(nextStageVisual(cg, null).cgRef, isNull);
    // 白名单码跳过（4011 闭眼）：不改持续画面。
    final skipped = nextStageVisual(s0, ScreenEffect.fromDirective(4011, [0.5]));
    expect(skipped.blur, false);
    expect(skipped.black, false);
    expect(stageOneShotOf(ScreenEffect.fromDirective(4012, const [])),
        StageOneShot.flash);
    expect(stageOneShotOf(ScreenEffect.fromDirective(4001, const [])),
        StageOneShot.shake);
  });

  // ---------------- 音频演出（widget） ----------------

  testWidgets('推进触发 BGM：POST /api/aa/preview(kind=aud) 恰好一次，同曲去重',
      (tester) async {
    final reqs = _installFx();
    await _boot(tester);
    // 首句 stage.bgm=null → 停 BGM，无取字节。
    expect(_audCount(reqs), 0);

    await _advance(tester); // →5002 bgm 700 → 一次
    expect(_audCount(reqs), 1);

    await _advance(tester); // →5003 同 bgm 700 → 去重
    expect(_audCount(reqs), 1);
  });

  testWidgets('全局静音：静音后推进不取音频字节', (tester) async {
    final reqs = _installFx();
    await _boot(tester);

    await tester.tap(find.byIcon(FluentIcons.speaker_2_24_regular));
    await tester.pump();
    expect(find.byIcon(FluentIcons.speaker_mute_24_regular), findsOneWidget);

    await _advance(tester); // →5002 本应取 BGM，静音跳过
    await tester.pump(const Duration(milliseconds: 200));
    expect(_audCount(reqs), 0);
  });

  // ---------------- 屏幕效果（widget） ----------------

  testWidgets('屏效 4012 闪白遮罩出现后随动画消失', (tester) async {
    _installFx();
    await _boot(tester);
    await _advance(tester, times: 3); // 5001→5004（闪白句）

    // 触发后推进动画到中段 → 白幕可见。
    await tester.pump(const Duration(milliseconds: 60));
    expect(find.byKey(fxFlashKey), findsOneWidget);

    // 动画结束 → 白幕消失。
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byKey(fxFlashKey), findsNothing);
  });

  testWidgets('屏效 4015 全屏 CG 层出现（走 CGCfg→贴图）', (tester) async {
    final reqs = _installFx();
    await _boot(tester);
    await _advance(tester, times: 4); // →5005（放CG句）
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byKey(fxCgKey), findsOneWidget);
    // CG 解析走了 CGCfg 查行。
    expect(
        reqs.any((r) => r.url.path == '/api/cfg/CGCfg'), isTrue);
  });

  testWidgets('点击 CG 可提前关闭', (tester) async {
    _installFx();
    await _boot(tester);
    await _advance(tester, times: 4);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(fxCgKey), findsOneWidget);

    await tester.tap(find.byKey(fxCgKey));
    await tester.pump();
    expect(find.byKey(fxCgKey), findsNothing);
  });
}
