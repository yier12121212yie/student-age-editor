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
    bool registrationEnabled = false,
    bool inviteRequired = false,
    bool registerOk = true,
    String? registerErrorCode,
    bool refreshOk = true,
  }) {
    ApiClient.instance.client = MockClient((req) async {
      recorded.add(req);
      final path = req.url.path;
      if (path == '/api/auth/registration') {
        return _json({
          'enabled': registrationEnabled,
          'invite_required': inviteRequired,
          'min_password_length': 8,
        }, 200);
      }
      if (path == '/api/auth/register') {
        if (!registerOk || registerErrorCode != null) {
          return _json(
              {'error': 'register failed', 'code': registerErrorCode ?? 'server_error'},
              409);
        }
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        return _json({
          'token': validToken ?? 'tok-new',
          'name': body['name'],
          'expires_in': 86400,
          'refresh_token': 'rt-new',
          'refresh_expires_in': body['remember'] == true ? 2592000 : 86400,
        }, 200);
      }
      if (path == '/api/auth/refresh') {
        if (!refreshOk) {
          return _json({'error': 'invalid refresh token', 'code': 'invalid_refresh'},
              401);
        }
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        // 契约：refresh 旋转后签发新 access + 新 refresh。
        return _json({
          'token': validToken ?? 'tok-refreshed',
          'name': 'alice',
          'expires_in': 86400,
          'refresh_token': 'rt-rotated',
          'refresh_expires_in': 2592000,
          'echo': body['refresh_token'],
        }, 200);
      }
      if (path == '/api/auth/logout') {
        return _json({'ok': true}, 200);
      }
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
          'refresh_token': 'rt-login',
          'refresh_expires_in': body['remember'] == true ? 2592000 : 86400,
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
    ApiClient.instance.refreshToken = null;
    ApiClient.instance.onUnauthorized = null;
    ApiClient.instance.onRefresh = null;
  });

  tearDown(() {
    ApiClient.instance.accessToken = null;
    ApiClient.instance.refreshToken = null;
    ApiClient.instance.onUnauthorized = null;
    ApiClient.instance.onRefresh = null;
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
    test('记住我：登录成功后 token/refresh 持久化并注入后续请求头', () async {
      mockGateway(whoamiUnauthorized: true, validToken: 'tok-abc');
      final auth = AuthState(isWebOverride: true);
      ApiClient.instance.onUnauthorized = auth.logout;
      await auth.probe();
      expect(auth.requiresLogin, isTrue);

      final ok = await auth.login('alice', 'hunter2', remember: true);
      expect(ok, isTrue);
      expect(auth.authenticated, isTrue);
      expect(auth.requiresLogin, isFalse);
      expect(auth.name, 'alice');
      expect(auth.error, isNull);
      expect(ApiClient.instance.accessToken, 'tok-abc');
      expect(ApiClient.instance.refreshToken, 'rt-login');

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('auth_token_v1'), 'tok-abc');
      expect(prefs.getString('auth_refresh_v1'), 'rt-login');
      expect(prefs.getString('auth_name_v1'), 'alice');
      expect(prefs.getBool('auth_remember_v1'), isTrue);

      // 请求体契约：带 remember
      final loginReq =
          recorded.firstWhere((r) => r.url.path == '/api/auth/login');
      expect((jsonDecode(loginReq.body) as Map)['remember'], true);

      // 业务请求自动带 Bearer 且能通过网关
      final recordedBefore = recorded.length;
      final resp = await ApiClient.instance.get('/api/state');
      expect(resp, {'ok': true});
      expect(recordedBefore < recorded.length, isTrue);
      expect(recorded.last.headers['Authorization'], 'Bearer tok-abc');
    });

    test('未勾选记住我：令牌仅内存、不落 prefs', () async {
      mockGateway(whoamiUnauthorized: true, validToken: 'tok-abc');
      final auth = AuthState(isWebOverride: true);
      ApiClient.instance.onUnauthorized = auth.logout;
      await auth.probe();

      final ok = await auth.login('alice', 'hunter2');  // remember 默认 false
      expect(ok, isTrue);
      expect(auth.authenticated, isTrue);
      expect(ApiClient.instance.accessToken, 'tok-abc');

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('auth_token_v1'), isNull);
      expect(prefs.getString('auth_refresh_v1'), isNull);
      expect(prefs.getBool('auth_remember_v1'), isNull);
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

      // 请求体契约：{name, password, remember}
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

  group('注册', () {
    test('策略开启：probe 后 registrationEnabled 为真', () async {
      mockGateway(
          whoamiUnauthorized: true,
          validToken: 'tok-abc',
          registrationEnabled: true,
          inviteRequired: true);
      final auth = AuthState(isWebOverride: true);
      await auth.probe();
      expect(auth.mode, AuthMode.hosted);
      expect(auth.registrationEnabled, isTrue);
      expect(auth.inviteRequired, isTrue);
    });

    test('策略默认关闭：registrationEnabled 为假', () async {
      mockGateway(whoamiUnauthorized: true, validToken: 'tok-abc');
      final auth = AuthState(isWebOverride: true);
      await auth.probe();
      expect(auth.registrationEnabled, isFalse);
    });

    test('注册成功：签发会话、注入 token、自动登录', () async {
      mockGateway(
          whoamiUnauthorized: true,
          validToken: 'tok-abc',
          registrationEnabled: true);
      final auth = AuthState(isWebOverride: true);
      ApiClient.instance.onUnauthorized = auth.logout;
      await auth.probe();
      expect(auth.requiresLogin, isTrue);

      final ok = await auth.register('bob', 'hunter2x');
      expect(ok, isTrue);
      expect(auth.authenticated, isTrue);
      expect(auth.requiresLogin, isFalse);
      expect(auth.name, 'bob');
      expect(auth.error, isNull);
      expect(ApiClient.instance.accessToken, 'tok-abc');

      // 请求体契约：{name, password, invite_code}
      final req = recorded.firstWhere((r) => r.url.path == '/api/auth/register');
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      expect(body['name'], 'bob');
      expect(body['password'], 'hunter2x');
      expect(body['invite_code'], '');

      // 后续业务请求带 Bearer
      final resp = await ApiClient.instance.get('/api/state');
      expect(resp, {'ok': true});
      expect(recorded.last.headers['Authorization'], 'Bearer tok-abc');
    });

    test('注册失败：按 code 映射文案，无 token', () async {
      mockGateway(
          whoamiUnauthorized: true,
          validToken: 'tok-abc',
          registrationEnabled: true,
          registerOk: false,
          registerErrorCode: 'name_taken');
      final auth = AuthState(isWebOverride: true);
      await auth.probe();

      final ok = await auth.register('alice', 'hunter2x');
      expect(ok, isFalse);
      expect(auth.error, '用户名已被占用');
      expect(auth.authenticated, isFalse);
      expect(ApiClient.instance.accessToken, isNull);
    });

    test('本地校验：空用户名 / 短密码 / 缺邀请码均不发请求', () async {
      mockGateway(
          whoamiUnauthorized: true,
          validToken: 'tok-abc',
          registrationEnabled: true,
          inviteRequired: true);
      final auth = AuthState(isWebOverride: true);
      await auth.probe();
      final before = recorded.length;

      expect(await auth.register('  ', 'hunter2x', inviteCode: 'x'), isFalse);
      expect(auth.error, '请输入用户名');
      expect(await auth.register('bob', 'short', inviteCode: 'x'), isFalse);
      expect(auth.error, '密码至少 8 位');
      expect(await auth.register('bob', 'hunter2x'), isFalse);
      expect(auth.error, '请输入邀请码');
      expect(recorded.length, before); // 三次均本地拦截
    });
  });

  group('长期鉴权（refresh）', () {
    test('access 过期但带 refresh：whoami 401 → 自动刷新并重试直进', () async {
      SharedPreferences.setMockInitialValues({
        'auth_token_v1': 'stale-tok',
        'auth_refresh_v1': 'rt-good',
        'auth_name_v1': 'alice',
        'auth_remember_v1': true,
      });
      mockGateway(whoamiUnauthorized: true, validToken: 'tok-new');
      final auth = AuthState(isWebOverride: true);
      await auth.probe();
      expect(auth.mode, AuthMode.hosted);
      expect(auth.requiresLogin, isFalse);
      expect(auth.authenticated, isTrue);
      expect(ApiClient.instance.accessToken, 'tok-new');
      expect(ApiClient.instance.refreshToken, 'rt-rotated');

      // 发生了一次 refresh 旋转；重试 whoami 带的是新 token。
      final paths = recorded.map((r) => r.url.path).toList();
      expect(paths.where((p) => p == '/api/auth/refresh').length, 1);
      final lastWhoami =
          recorded.lastWhere((r) => r.url.path == '/api/auth/whoami');
      expect(lastWhoami.headers['Authorization'], 'Bearer tok-new');

      // 旋转后的 refresh 落盘（记住我）。
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('auth_refresh_v1'), 'rt-rotated');
      expect(prefs.getString('auth_token_v1'), 'tok-new');
    });

    test('业务请求 401 → 自动刷新并重试一次（不回登录页）', () async {
      mockGateway(whoamiUnauthorized: true, validToken: 'tok-abc');
      final auth = AuthState(isWebOverride: true);
      ApiClient.instance.onUnauthorized = auth.logout;
      await auth.probe();
      await auth.login('alice', 'hunter2', remember: true);
      expect(auth.requiresLogin, isFalse);

      // access 失效但 refresh 有效：业务接口 401 → 刷新 → 重试成功。
      ApiClient.instance.client = MockClient((req) async {
        recorded.add(req);
        final path = req.url.path;
        if (path == '/api/auth/refresh') {
          return _json({
            'token': 'tok-fresh',
            'name': 'alice',
            'expires_in': 86400,
            'refresh_token': 'rt-rotated2',
            'refresh_expires_in': 2592000,
          }, 200);
        }
        if (req.headers['Authorization'] == 'Bearer tok-fresh') {
          return _json({'ok': true}, 200);
        }
        return _json({'error': 'unauthorized'}, 401);
      });

      final resp = await ApiClient.instance.get('/api/state');
      expect(resp, {'ok': true});
      expect(auth.requiresLogin, isFalse); // 未回登录页
      expect(ApiClient.instance.accessToken, 'tok-fresh');
      expect(ApiClient.instance.refreshToken, 'rt-rotated2');
    });

    test('刷新失败 → 回登录页清态清 prefs', () async {
      SharedPreferences.setMockInitialValues({
        'auth_token_v1': 'stale-tok',
        'auth_refresh_v1': 'rt-bad',
        'auth_name_v1': 'alice',
        'auth_remember_v1': true,
      });
      mockGateway(
          whoamiUnauthorized: true, validToken: 'tok-abc', refreshOk: false);
      final auth = AuthState(isWebOverride: true);
      ApiClient.instance.onUnauthorized = auth.logout;
      await auth.probe();
      expect(auth.requiresLogin, isTrue);
      expect(auth.authenticated, isFalse);
      expect(ApiClient.instance.accessToken, isNull);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('auth_refresh_v1'), isNull);
      expect(prefs.getString('auth_token_v1'), isNull);
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
