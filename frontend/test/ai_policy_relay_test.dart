// AI 双通道（网页版 M0.4）传输层单元测试：policy 解析/兜底/缓存、
// 通道解析矩阵、relay 与 web 直连（非流式）两条请求路径的契约。
// 全部走 MockClient / 注入 loader，不发起真实网络请求、不依赖 kIsWeb。
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_age_editor/core/api_client.dart';
import 'package:student_age_editor/features/ai/ai_client.dart';
import 'package:student_age_editor/features/ai/ai_policy.dart';
import 'package:student_age_editor/features/settings/settings_page.dart';

AiClient _relayClient({String? model}) => AiClient(
      AiSettings(
        baseUrl: 'https://api.example.com/v1',
        apiKey: 'sk-own-key',
        model: model ?? 'not-in-whitelist',
      ),
      channel: AiTransportChannel.relay,
      relayProvider: 'openai_compatible',
      relayModel: 'gateway-default',
      relayModels: const ['gateway-default'],
      forceNonStream: true,
    );

void main() {
  tearDown(() {
    // 恢复默认传输与鉴权，避免泄漏到其他测试文件。
    ApiClient.instance.client = http.Client();
    ApiClient.instance.accessToken = null;
  });

  group('AiPolicy.fromJson', () {
    test('全字段映射 + models 清洗（去空/去空白）', () {
      final p = AiPolicy.fromJson(const {
        'relay_available': true,
        'provider': 'openai_compatible',
        'model': 'gateway-default',
        'models': [' a ', '', 'b'],
        'own_key_allowed': false,
        'tts_image_available': false,
        'stream': false,
        'limits': {'daily': 50},
      });
      expect(p.relayAvailable, isTrue);
      expect(p.provider, 'openai_compatible');
      expect(p.model, 'gateway-default');
      expect(p.models, ['a', 'b']);
      expect(p.ownKeyAllowed, isFalse);
      expect(p.ttsImageAvailable, isFalse);
      expect(p.stream, isFalse);
      expect(p.dailyLimit, 50);
      expect(p.displayModels, 'a、b');
      expect(p.dailyNote, '每日 50 次');
    });

    test('缺字段回落默认（own_key/tts_image 缺席 = 允许）', () {
      final p = AiPolicy.fromJson(const {
        'relay_available': true,
        'provider': 'anthropic',
      });
      expect(p.ownKeyAllowed, isTrue);
      expect(p.ttsImageAvailable, isTrue);
      expect(p.models, isEmpty);
      expect(p.dailyLimit, 0);
      expect(p.dailyNote, '');
      expect(p.displayModels, '');
    });

    test('fallback = 引入双通道前的旧行为', () {
      const p = AiPolicy.fallback;
      expect(p.relayAvailable, isFalse);
      expect(p.ownKeyAllowed, isTrue);
      expect(p.ttsImageAvailable, isTrue);
    });
  });

  group('AiPolicyStore', () {
    test('拉取失败兜底 fallback，且记为已加载不反复重试', () async {
      var calls = 0;
      final store = AiPolicyStore(loader: () async {
        calls++;
        throw Exception('backend down');
      });
      final p = await store.ensureLoaded();
      expect(p.relayAvailable, isFalse); // = fallback
      expect(store.loaded, isTrue);
      await store.ensureLoaded();
      expect(calls, 1); // 失败也只拉一次
    });

    test('并发调用共享同一次在途拉取', () async {
      var calls = 0;
      final gate = Completer<void>();
      final store = AiPolicyStore(loader: () async {
        calls++;
        await gate.future;
        return const {'relay_available': true, 'provider': 'anthropic'};
      });
      final f1 = store.ensureLoaded();
      final f2 = store.ensureLoaded();
      gate.complete();
      await Future.wait([f1, f2]);
      expect(calls, 1);
      expect(store.policy.provider, 'anthropic');
    });

    test('已加载后直接返回缓存', () async {
      var calls = 0;
      final store = AiPolicyStore(loader: () async {
        calls++;
        return const {'relay_available': true};
      });
      await store.ensureLoaded();
      await store.ensureLoaded();
      expect(calls, 1);
      expect(store.policy.relayAvailable, isTrue);
    });
  });

  group('resolveUseRelay', () {
    const available = AiPolicy(relayAvailable: true, provider: 'openai_compatible');
    const unavailable = AiPolicy();

    test('桌面恒直连（web=false），任何选择都不 relay', () {
      for (final choice in AiChannelChoice.values) {
        expect(
          resolveUseRelay(
            web: false, choice: choice, policy: available, hasOwnKey: false),
          isFalse,
          reason: 'choice=$choice',
        );
      }
    });

    test('显式选平台：网关可用才 relay', () {
      expect(
        resolveUseRelay(
            web: true, choice: AiChannelChoice.platform, policy: available, hasOwnKey: true),
        isTrue); // 显式平台优先于有自带 key
      expect(
        resolveUseRelay(
            web: true, choice: AiChannelChoice.platform, policy: unavailable, hasOwnKey: false),
        isFalse);
    });

    test('显式选自带 key：总是直连', () {
      expect(
        resolveUseRelay(
            web: true, choice: AiChannelChoice.own, policy: available, hasOwnKey: false),
        isFalse);
    });

    test('auto：网关可用且没填自带 key 才走平台', () {
      expect(
        resolveUseRelay(
            web: true, choice: AiChannelChoice.auto, policy: available, hasOwnKey: false),
        isTrue);
      expect(
        resolveUseRelay(
            web: true, choice: AiChannelChoice.auto, policy: available, hasOwnKey: true),
        isFalse); // 填了自己的 key → 直连（旧行为）
      expect(
        resolveUseRelay(
            web: true, choice: AiChannelChoice.auto, policy: unavailable, hasOwnKey: false),
        isFalse);
    });
  });

  group('AiChannelPrefs', () {
    test('save/load 往返', () async {
      SharedPreferences.setMockInitialValues({});
      await AiChannelPrefs.save(AiChannelChoice.platform);
      expect(await AiChannelPrefs.load(), AiChannelChoice.platform);
      await AiChannelPrefs.save(AiChannelChoice.own);
      expect(await AiChannelPrefs.load(), AiChannelChoice.own);
    });

    test('坏值/缺值回落 auto', () async {
      SharedPreferences.setMockInitialValues({'ai_web_channel_v1': 'garbage'});
      expect(await AiChannelPrefs.load(), AiChannelChoice.auto);
      SharedPreferences.setMockInitialValues({});
      expect(await AiChannelPrefs.load(), AiChannelChoice.auto);
    });
  });

  group('relay 传输契约', () {
    test('POST /api/ai/relay/chat：模型回填白名单默认 + 非流式 + Bearer 鉴权', () async {
      final bodies = <Map<String, dynamic>>[];
      ApiClient.instance.client = MockClient((req) async {
        bodies.add(jsonDecode(req.body) as Map<String, dynamic>);
        expect(req.method, 'POST');
        expect(req.url.path, '/api/ai/relay/chat');
        expect(req.headers['authorization'], 'Bearer tok123');
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {'content': '网关回复'},
                'finish_reason': 'stop',
              }
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      ApiClient.instance.accessToken = 'tok123';

      final client = _relayClient();
      final history = <Map<String, dynamic>>[
        {'role': 'user', 'content': '你好'},
      ];
      final texts = <String>[];
      var done = false;
      await client.send(
        history: history,
        tools: const [],
        callbacks: AiCallbacks(
          onText: texts.add,
          onDone: () => done = true,
        ),
      );

      expect(done, isTrue);
      expect(texts.join(), '网关回复');
      expect(bodies.single['model'], 'gateway-default'); // 不在白名单 → 网关默认
      expect(bodies.single['stream'], anyOf(isFalse, isNull)); // 契约恒非流式
    });

    test('relay 通道本地 model 命中白名单时原样发送', () async {
      Map<String, dynamic>? body;
      ApiClient.instance.client = MockClient((req) async {
        body = jsonDecode(req.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {'content': 'ok'},
                'finish_reason': 'stop',
              }
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final client = AiClient(
        AiSettings(
          baseUrl: 'https://api.example.com/v1',
          apiKey: 'sk-own-key',
          model: 'gateway-default',
        ),
        channel: AiTransportChannel.relay,
        relayProvider: 'openai_compatible',
        relayModel: 'gateway-default',
        relayModels: const ['gateway-default'],
        forceNonStream: true,
      );
      await client.send(
        history: [
          {'role': 'user', 'content': 'hi'},
        ],
        tools: const [],
        callbacks: AiCallbacks(),
      );
      expect(body!['model'], 'gateway-default');
    });

    test('网关信封错误（4xx）人话化透出', () async {
      ApiClient.instance.client = MockClient((req) async {
        return http.Response(
          jsonEncode({'error': 'model 不在白名单'}),
          403,
          headers: {'content-type': 'application/json'},
        );
      });
      final client = _relayClient();
      await expectLater(
        client.send(
          history: [
            {'role': 'user', 'content': 'hi'},
          ],
          tools: const [],
          callbacks: AiCallbacks(),
        ),
        throwsA(isA<AiClientException>().having(
          (e) => e.toString(), 'message', contains('model 不在白名单'))),
      );
    });

    test('自带 key 直连：请求发往服务商原地址，不经 /api/relay', () async {
      Uri? uri;
      Map<String, String>? headers;
      final client = AiClient(
        AiSettings(
          baseUrl: 'https://api.example.com/v1',
          apiKey: 'sk-own-key',
          model: 'm1',
        ),
        forceNonStream: true,
        clientFactory: () => MockClient((req) async {
          uri = req.url;
          headers = req.headers;
          return http.Response(
            jsonEncode({
              'choices': [
                {
                  'message': {'content': '直连回复'},
                  'finish_reason': 'stop',
                }
              ],
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      final texts = <String>[];
      await client.send(
        history: [
          {'role': 'user', 'content': 'hi'},
        ],
        tools: const [],
        callbacks: AiCallbacks(onText: texts.add),
      );
      expect(uri!.host, 'api.example.com'); // 浏览器直连服务商
      expect(uri!.path, contains('/chat/completions'));
      expect(uri!.path, isNot(contains('/api/ai/relay')));
      expect(headers!['authorization'], 'Bearer sk-own-key'); // key 只发服务商
      expect(texts.join(), '直连回复');
    });
  });
}
