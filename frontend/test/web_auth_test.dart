// 托管登录模块（M2.4）逻辑测试：模式探测 / 登录注入 / 401 失效清态。
// 通过 AuthState(isWebOverride: true) 在 VM 测试中走 Web 探测分支，
// MockClient 注入 ApiClient.instance.client 模拟网关契约。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_age_editor/core/api_client.dart';
import 'package:student_age_editor/features/auth/auth_state.dart';

http.Response _json(Map<String, dynamic> body, int status) =>
    http.Response(jsonEncode(body), status,
        headers: {'content-type': 'application/json'});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final recorded = <http.Request>[];

  /// 网关形态的 Mock：/api/auth/* 按契约响应，业务接口无 token 时 401。
  void mockGateway({
    bool whoamiUnauthorized = true,
    String? validToken,
    bool loginOk = true,
  }) {
    ApiClient.instance.client = MockClient((req) async {
      recorded.add(req);
      final path = req.url.path;
      if (path == '/api/auth/whoami') {
        final authed =
            validToken != null && req.headers['Authorization'] == 'Bearer $validToken';
        return authed
            ? _json({'name': 'alice'}, 200)
            : whoamiUnauthorized
                ? _json({'error': 'unauthorized'}, 401)
                : _json({'error': 'no route: GET /api/auth/whoami'}, 404);
      }
      if (path == '/api/auth/login') {
        if (!loginOk) return _json({'error': 'invalid credentials'}, 401);
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        return _json({
          'token': validToken ?? 'tok-abc',
          'name': body['name'],
          'expires_in': 86400,
        }, 200);
      }
      // 业务接口：hosted 下不带有效 Bearer → 401
      if (validToken != null &&
          req.headers['Authorization'] == 'Bearer $validToken') {
        return _json({'ok': true}, 200);
      }
      if (whoamiUnauthorized) return _json({'error': 'unauthorized'}, 401);
      return _json({'ok': true}, 200);
    });
  }

  /// 本机后端形态：whoami 无路由 404，其余照常。
  void mockLocalBackend() {
    ApiClient.instance.client = MockClient((req) async {
      recorded.add(req);
      if (req.url.path == '/api/auth/whoami') {
        return _json({'error': 'no route: GET /api/auth/whoami'}, 404);
      }
      return _json({'ok': true}, 200);
    });
  }

  setUp(() {
    recorded.clear();
    SharedPreferences.setMockInitialValues({});
    ApiClient.instance.accessToken = null;
    ApiClient.instance.onUnauthorized = null;
  });

  tearDown(() {
    ApiClient.instance.accessToken = null;
    ApiClient.instance.onUnauthorized = null;
  });

  group('模式探测', () {
    test('whoami 404 → local：不要求登录、不发鉴权后续', () async {
      mockLocalBackend();
      final auth = AuthState(isWebOverride: true);
      await auth.probe();
      expect(auth.mode, AuthMode.local);
      expect(auth.requiresLogin, isFalse);
      expect(recorded.length, 1); // 桌面 local 零变化：探测只此一发
    });

    test('whoami 401 → hosted：requiresLogin，登录前拿不到业务数据', () async {
      mockGateway(whoamiUnauthorized: true, validToken: 'tok-abc');
      final auth = AuthState(isWebOverride: true);
      await auth.probe();
      expect(auth.mode, AuthMode.hosted);
      expect(auth.requiresLogin, isTrue);
      expect(auth.authenticated, isFalse);
    });

    test('桌面（非 Web）恒 local，不发探测请求', () async {
      mockGateway(whoamiUnauthorized: true, validToken: 'tok-abc');
      final auth = AuthState(isWebOverride: false);
      await auth.probe();
      expect(auth.mode, AuthMode.local);
      expect(recorded, isEmpty);
    });

    test('缓存 token 有效：whoami 200 直进，无需登录', () async {
      SharedPreferences.setMockInitialValues({
        'auth_token_v1': 'tok-abc',
        'auth_name_v1': 'alice',
      });
      mockGateway(whoamiUnauthorized: true, validToken: 'tok-abc');
      final auth = AuthState(isWebOverride: true);
      await auth.probe();
      expect(auth.mode, AuthMode.hosted);
      expect(auth.requiresLogin, isFalse);
      expect(auth.name, 'alice');
      expect(ApiClient.instance.accessToken, 'tok-abc');
      // 缓存 token 以 Bearer 携带进 whoami 验证
      expect(recorded.first.headers['Authorization'], 'Bearer tok-abc');
    });

    test('缓存 token 过期：whoami 401 → 清态回登录并清 prefs', () async {
      SharedPreferences.setMockInitialValues({
        'auth_token_v1': 'stale-tok',
        'auth_name_v1': 'alice',
      });
      mockGateway(whoamiUnauthorized: true, validToken: 'tok-abc');
      final auth = AuthState(isWebOverride: true);
      await auth.probe();
      expect(auth.mode, AuthMode.hosted);
      expect(auth.requiresLogin, isTrue);
      expect(auth.name, isNull);
      expect(ApiClient.instance.accessToken, isNull);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('auth_token_v1'), isNull);
    });
  });

  group('登录', () {
    test('登录成功后 token 持久化并注入后续请求头', () async {
      mockGateway(whoamiUnauthorized: true, validToken: 'tok-abc');
      final auth = AuthState(isWebOverride: true);
      ApiClient.instance.onUnauthorized = auth.logout;
      await auth.probe();
      expect(auth.requiresLogin, isTrue);

      final ok = await auth.login('alice', 'hunter2');
      expect(ok, isTrue);
      expect(auth.authenticated, isTrue);
      expect(auth.requiresLogin, isFalse);
      expect(auth.name, 'alice');
      expect(auth.error, isNull);
      expect(ApiClient.instance.accessToken, 'tok-abc');

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('auth_token_v1'), 'tok-abc');
      expect(prefs.getString('auth_name_v1'), 'alice');

      // 业务请求自动带 Bearer 且能通过网关
      final recordedBefore = recorded.length;
      final resp = await ApiClient.instance.get('/api/state');
      expect(resp, {'ok': true});
      expect(recordedBefore < recorded.length, isTrue);
      expect(recorded.last.headers['Authorization'], 'Bearer tok-abc');
    });

    test('登录 401：错误文案、无 token、可重试', () async {
      mockGateway(whoamiUnauthorized: true, validToken: 'tok-abc', loginOk: false);
      final auth = AuthState(isWebOverride: true);
      await auth.probe();

      final ok = await auth.login('alice', 'wrong-pass');
      expect(ok, isFalse);
      expect(auth.error, '用户名或密码错误');
      expect(auth.authenticated, isFalse);
      expect(ApiClient.instance.accessToken, isNull);

      // 请求体契约：{name, password}
      final loginReq =
          recorded.firstWhere((r) => r.url.path == '/api/auth/login');
      final body = jsonDecode(loginReq.body) as Map<String, dynamic>;
      expect(body['name'], 'alice');
      expect(body['password'], 'wrong-pass');

      // 空输入仅本地校验，不发请求
      expect(await auth.login('  ', 'x'), isFalse);
      expect(auth.error, '请输入用户名');
      expect(await auth.login('alice', ''), isFalse);
      expect(auth.error, '请输入密码');
    });
  });

  group('会话失效', () {
    test('业务接口 401 → onUnauthorized 清态回登录页', () async {
      mockGateway(whoamiUnauthorized: true, validToken: 'tok-abc');
      final auth = AuthState(isWebOverride: true);
      ApiClient.instance.onUnauthorized = auth.logout;
      await auth.probe();
      await auth.login('alice', 'hunter2');
      expect(auth.requiresLogin, isFalse);

      // 服务端吊销 token：后续请求 401（validToken 换掉模拟过期）
      ApiClient.instance.client = MockClient((req) async =>
          _json({'error': 'unauthorized'}, 401));
      await expectLater(
          ApiClient.instance.get('/api/state'), throwsA(isA<ApiException>()));

      expect(auth.requiresLogin, isTrue);
      expect(auth.authenticated, isFalse);
      expect(auth.name, isNull);
      expect(ApiClient.instance.accessToken, isNull);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('auth_token_v1'), isNull);
    });

    test('手动登出清空会话', () async {
      mockGateway(whoamiUnauthorized: true, validToken: 'tok-abc');
      final auth = AuthState(isWebOverride: true);
      await auth.probe();
      await auth.login('alice', 'hunter2');

      auth.logout();
      expect(auth.requiresLogin, isTrue);
      expect(ApiClient.instance.accessToken, isNull);
      expect(auth.showUserChip, isFalse);
      await Future<void>.delayed(Duration.zero); // 等 prefs 异步删除
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('auth_token_v1'), isNull);
    });
  });
}
