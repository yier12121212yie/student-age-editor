import 'dart:async' show unawaited;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/api_client.dart';

/// 部署模式（M2.4 托管登录）。
enum AuthMode {
  /// 探测中。
  unknown,

  /// 本机/桌面后端：`GET /api/auth/whoami` 返回 404（无该路由），无需登录。
  local,

  /// 网关托管：whoami 返回 401，必须登录后才能访问业务接口。
  hosted,
}

/// 托管登录状态（ChangeNotifier）。
///
/// 探测协议：`GET /api/auth/whoami`（不带或带缓存 Bearer）——
/// - 404 `{"error":"no route: ..."}` → [AuthMode.local]，现状体验零变化；
/// - 401 `{"error":"unauthorized"}` → [AuthMode.hosted]，需要登录；
/// - 200 → hosted 且缓存 token 有效，直进。
/// 登录 `POST /api/auth/login` {name,password} → 200 {token,name,expires_in}；
/// 401 时账号不存在与密码错同形（后端防枚举）。
/// 会话过期由 [ApiClient.onUnauthorized] 统一回调 [logout] 清态回登录页。
///
/// 桌面端 [_isWeb] 为 false 时 [probe] 恒判 local（不发请求）；测试可注入
/// [isWebOverride] 走 hosted 探测路径。
class AuthState extends ChangeNotifier {
  AuthState({bool? isWebOverride}) : _isWeb = isWebOverride ?? kIsWeb;

  /// 全局挂点（状态栏用户名/登出芯片等非 prop-drilling 消费）。
  static AuthState? current;

  final bool _isWeb;

  static const String _tokenKey = 'auth_token_v1';
  static const String _nameKey = 'auth_name_v1';

  AuthMode _mode = AuthMode.unknown;
  String? _token;
  String? _name;
  bool _busy = false;
  String? _error;

  // 自助注册策略（GET /api/auth/registration，公开端点）。默认关闭；
  // 探测失败一律视为不可注册（安全默认）。
  bool _registrationEnabled = false;
  bool _inviteRequired = false;
  int _minPasswordLength = 8;

  AuthMode get mode => _mode;
  String? get name => _name;
  bool get busy => _busy;
  bool get registrationEnabled => _registrationEnabled;
  bool get inviteRequired => _inviteRequired;
  int get minPasswordLength => _minPasswordLength;

  /// 登录失败/校验提示文案（登录后成功清空）。
  String? get error => _error;

  bool get authenticated => _token != null && _token!.isNotEmpty;

  /// hosted 且无有效会话 → 应用层应显示登录页（桌面/本机恒 false）。
  bool get requiresLogin =>
      _isWeb && _mode == AuthMode.hosted && !authenticated;

  /// 状态栏是否显示用户名 + 登出芯片。
  bool get showUserChip =>
      _isWeb && _mode == AuthMode.hosted && authenticated && _name != null;

  @override
  void dispose() {
    if (current == this) current = null;
    super.dispose();
  }

  /// 探测部署模式并验证缓存 token。app.dart 仅在 kIsWeb 调用；
  /// 桌面端直接落 [AuthMode.local]，不发任何请求。
  Future<void> probe() async {
    if (!_isWeb) {
      _mode = AuthMode.local;
      notifyListeners();
      return;
    }
    await _restore();
    try {
      final resp = await ApiClient.instance
          .get('/api/auth/whoami')
          .timeout(const Duration(seconds: 8));
      // 200：网关在场且 token 有效；若响应带 name 则刷新显示名。
      _mode = AuthMode.hosted;
      final n = resp is Map ? resp['name'] : null;
      if (n is String && n.isNotEmpty) _name = n;
    } on ApiException catch (e) {
      if (e.statusCode == 404) {
        // 本机/桌面后端无 whoami 路由：无鉴权模式，行为与现状一致。
        _mode = AuthMode.local;
      } else if (e.statusCode == 401) {
        // 网关在线且（无 token 或缓存 token 已过期）→ 托管模式回登录。
        _mode = AuthMode.hosted;
      } else {
        _mode = AuthMode.local;
      }
      await _clearSession();
    } catch (_) {
      // 网络异常等无法判定时不阻塞：按 local 进入原流程，
      // 后端真不可达时由 bootstrap 的错误页统一提示。
      _mode = AuthMode.local;
      await _clearSession();
    }
    // hosted 时拉取注册策略，登录页据此显示/隐藏注册入口。
    if (_mode == AuthMode.hosted) await loadRegistrationPolicy();
    notifyListeners();
  }

  /// 拉取公开的注册策略（GET /api/auth/registration）。非 Web 部署或请求
  /// 失败时保持关闭（安全默认）。可在登录页打开时再次调用以刷新。
  Future<void> loadRegistrationPolicy() async {
    if (!_isWeb) return;
    try {
      final resp = await ApiClient.instance
          .get('/api/auth/registration')
          .timeout(const Duration(seconds: 8));
      if (resp is Map) {
        _registrationEnabled = resp['enabled'] == true;
        _inviteRequired = resp['invite_required'] == true;
        final minLen = resp['min_password_length'];
        if (minLen is int && minLen > 0) _minPasswordLength = minLen;
      }
    } catch (_) {
      _registrationEnabled = false;
      _inviteRequired = false;
    }
    notifyListeners();
  }

  /// 登录。成功返回 true（token 已注入 [ApiClient] 并持久化），
  /// 失败仅记录 [error]，不抛。
  Future<bool> login(String name, String password) async {
    if (_busy) return false;
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      _fail('请输入用户名');
      return false;
    }
    if (password.isEmpty) {
      _fail('请输入密码');
      return false;
    }
    _busy = true;
    _error = null;
    notifyListeners();
    try {
      final resp = await ApiClient.instance
          .post('/api/auth/login',
              body: {'name': trimmed, 'password': password})
          .timeout(const Duration(seconds: 15));
      final token = resp is Map ? resp['token'] : null;
      if (token is! String || token.isEmpty) {
        _fail('登录响应异常，请稍后重试');
        return false;
      }
      final n = resp['name'] is String && (resp['name'] as String).isNotEmpty
          ? resp['name'] as String
          : trimmed;
      await _adoptSession(token, n);
      return true;
    } on ApiException catch (e) {
      // 后端对账号不存在与密码错误返回同一形态（防枚举）。
      _fail(e.statusCode == 401
          ? '用户名或密码错误'
          : '登录失败（HTTP ${e.statusCode}）');
      return false;
    } catch (_) {
      _fail('无法连接服务器，请稍后重试');
      return false;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// 自助注册。成功与 [login] 同效：签发并持久化会话、自动登录进编辑器。
  /// 失败仅记录 [error]，不抛。
  ///
  /// 错误按后端稳定 `code` 映射为本地化文案（见 gateway gw_proxy.cpp）：
  /// registration_disabled / invalid_name / weak_password / invalid_invite /
  /// name_taken / account_limit / rate_limited。
  Future<bool> register(String name, String password,
      {String inviteCode = ''}) async {
    if (_busy) return false;
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      _fail('请输入用户名');
      return false;
    }
    if (password.length < _minPasswordLength) {
      _fail('密码至少 $_minPasswordLength 位');
      return false;
    }
    if (_inviteRequired && inviteCode.trim().isEmpty) {
      _fail('请输入邀请码');
      return false;
    }
    _busy = true;
    _error = null;
    notifyListeners();
    try {
      final resp = await ApiClient.instance.post('/api/auth/register', body: {
        'name': trimmed,
        'password': password,
        'invite_code': inviteCode.trim(),
      }).timeout(const Duration(seconds: 30));
      final token = resp is Map ? resp['token'] : null;
      if (token is! String || token.isEmpty) {
        _fail('注册响应异常，请稍后重试');
        return false;
      }
      final n = resp['name'] is String && (resp['name'] as String).isNotEmpty
          ? resp['name'] as String
          : trimmed;
      await _adoptSession(token, n);
      return true;
    } on ApiException catch (e) {
      _fail(_registerError(e));
      return false;
    } catch (_) {
      _fail('无法连接服务器，请稍后重试');
      return false;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  static String _registerError(ApiException e) {
    switch (e.code) {
      case 'registration_disabled':
        return '服务器未开放注册';
      case 'invalid_name':
        return '用户名不合法（仅限字母、数字、下划线、短横线）';
      case 'weak_password':
        return '密码不符合要求';
      case 'invalid_invite':
        return '邀请码错误';
      case 'name_taken':
        return '用户名已被占用';
      case 'account_limit':
        return '账号数量已达上限';
      case 'rate_limited':
        return '操作过于频繁，请稍后再试';
    }
    return '注册失败（HTTP ${e.statusCode}）';
  }

  /// 建立会话：写入内存态 + 注入 [ApiClient] + 持久化（供冷启动免登）。
  Future<void> _adoptSession(String token, String name) async {
    _token = token;
    _name = name;
    _mode = AuthMode.hosted;
    ApiClient.instance.accessToken = token;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_tokenKey, token);
      await prefs.setString(_nameKey, name);
    } catch (_) {
      // prefs 写失败仅影响下次冷启动免登，本次会话照常。
    }
  }

  /// 清会话回登录页：手动登出与 [ApiClient.onUnauthorized]（401 过期）共用。
  void logout() {
    _token = null;
    _name = null;
    _error = null;
    ApiClient.instance.accessToken = null;
    unawaited(_clearPrefs());
    notifyListeners();
  }

  void _fail(String msg) {
    _error = msg;
    notifyListeners();
  }

  /// 清空错误提示（登录/注册表单切换时用）。
  void clearError() {
    if (_error == null) return;
    _error = null;
    notifyListeners();
  }

  /// 冷启动恢复缓存会话（whoami 验证前先行注入 Bearer）。
  Future<void> _restore() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final t = prefs.getString(_tokenKey);
      if (t != null && t.isNotEmpty) {
        _token = t;
        _name = prefs.getString(_nameKey);
        ApiClient.instance.accessToken = t;
      }
    } catch (_) {}
  }

  Future<void> _clearSession() async {
    if (_token == null && _name == null) return;
    _token = null;
    _name = null;
    ApiClient.instance.accessToken = null;
    await _clearPrefs();
  }

  Future<void> _clearPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_tokenKey);
      await prefs.remove(_nameKey);
    } catch (_) {}
  }
}
