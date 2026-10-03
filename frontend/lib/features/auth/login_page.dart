import 'package:flutter/material.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../../core/app_theme.dart';
import '../../core/motion.dart';
import '../../core/responsive.dart';
import 'auth_state.dart';

/// 托管模式登录 / 注册页（M2.4；注册为自托管网页端新增能力）。
///
/// 网关部署且无有效会话时替换主壳显示。默认展示登录表单；当
/// [AuthState.registrationEnabled] 为真（网关 gateway.json 的
/// `registration.enabled`）时，底部出现「注册」入口，切换为注册表单
/// （用户名 / 密码 / 确认密码 / 可选邀请码）。
///
/// 视觉沿用 OOBE 卡片风格（居中卡片 + palette 配色），Enter 逐级提交，
/// 窄屏（<720）卡片自适应宽度并保证触控高度。
class LoginPage extends StatefulWidget {
  const LoginPage({super.key, required this.auth, this.onLoggedIn});

  final AuthState auth;

  /// 登录/注册成功回调（应用侧继续原 bootstrap 流程）。
  final VoidCallback? onLoggedIn;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _nameCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();
  final _inviteCtrl = TextEditingController();
  final _nameFocus = FocusNode();
  final _passFocus = FocusNode();
  final _confirmFocus = FocusNode();
  final _inviteFocus = FocusNode();
  bool _obscure = true;
  bool _isRegister = false;
  bool _remember = true;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _passCtrl.dispose();
    _confirmCtrl.dispose();
    _inviteCtrl.dispose();
    _nameFocus.dispose();
    _passFocus.dispose();
    _confirmFocus.dispose();
    _inviteFocus.dispose();
    super.dispose();
  }

  void _switchMode(bool register) {
    if (_isRegister == register) return;
    widget.auth.clearError();
    setState(() {
      _isRegister = register;
      _localError = null;
    });
  }

  Future<void> _submit() async {
    if (_isRegister && _confirmCtrl.text != _passCtrl.text) {
      // 本地校验：两次密码不一致，直接提示（AuthState 无此校验）。
      setState(() => _localError = '两次输入的密码不一致');
      return;
    }
    _localError = null;
    final ok = _isRegister
        ? await widget.auth.register(_nameCtrl.text, _passCtrl.text,
            inviteCode: _inviteCtrl.text, remember: _remember)
        : await widget.auth.login(_nameCtrl.text, _passCtrl.text,
            remember: _remember);
    if (ok && mounted) widget.onLoggedIn?.call();
  }

  /// 仅在本地产生（如密码确认）的提示，优先级高于 [AuthState.error]。
  String? _localError;

  @override
  Widget build(BuildContext context) {
    final mobile = isMobileWidth(context);
    final size = MediaQuery.sizeOf(context);
    final cardWidth = mobile ? (size.width - 24).clamp(0.0, 380.0) : 380.0;
    return Scaffold(
      backgroundColor: palette.bgDeep,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Container(
              width: cardWidth,
              padding: mobile
                  ? const EdgeInsets.fromLTRB(20, 22, 20, 18)
                  : const EdgeInsets.all(28),
              decoration: BoxDecoration(
                color: palette.bg,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: palette.border),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ScaleFade(
                    child: Container(
                      width: 52,
                      height: 52,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: accentColor.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(
                          _isRegister
                              ? FluentIcons.add_24_regular
                              : FluentIcons.lock_closed_24_regular,
                          size: 26,
                          color: accentColor),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Center(
                    child: Text('学生时代 · 模组编辑器',
                        style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                            color: palette.textHigh)),
                  ),
                  const SizedBox(height: 4),
                  Center(
                    child: Text(
                        _isRegister ? '创建账号后即可使用' : '此服务需登录后使用',
                        style: TextStyle(fontSize: 12, color: palette.textMuted)),
                  ),
                  const SizedBox(height: 22),
                  _fieldLabel('用户名'),
                  fluent.TextBox(
                    controller: _nameCtrl,
                    focusNode: _nameFocus,
                    placeholder: '请输入用户名',
                    autofocus: true,
                    onSubmitted: (_) => _passFocus.requestFocus(),
                  ),
                  const SizedBox(height: 12),
                  _fieldLabel('密码'),
                  fluent.TextBox(
                    controller: _passCtrl,
                    focusNode: _passFocus,
                    placeholder: _isRegister
                        ? '至少 ${widget.auth.minPasswordLength} 位'
                        : '请输入密码',
                    obscureText: _obscure,
                    onSubmitted: (_) => _isRegister
                        ? _confirmFocus.requestFocus()
                        : _submit(),
                    suffix: fluent.IconButton(
                      icon: Icon(
                        _obscure
                            ? FluentIcons.eye_24_regular
                            : FluentIcons.eye_off_24_regular,
                        size: 14,
                      ),
                      onPressed: () => setState(() => _obscure = !_obscure),
                    ),
                  ),
                  if (_isRegister) ...[
                    const SizedBox(height: 12),
                    _fieldLabel('确认密码'),
                    fluent.TextBox(
                      controller: _confirmCtrl,
                      focusNode: _confirmFocus,
                      placeholder: '请再次输入密码',
                      obscureText: _obscure,
                      onSubmitted: (_) => widget.auth.inviteRequired
                          ? _inviteFocus.requestFocus()
                          : _submit(),
                    ),
                    if (widget.auth.inviteRequired) ...[
                      const SizedBox(height: 12),
                      _fieldLabel('邀请码'),
                      fluent.TextBox(
                        controller: _inviteCtrl,
                        focusNode: _inviteFocus,
                        placeholder: '请输入管理员提供的邀请码',
                        onSubmitted: (_) => _submit(),
                      ),
                    ],
                  ],
                  const SizedBox(height: 12),
                  // 「记住我」：勾选走长期 refresh token（落本地存储，冷启动
                  // 免登）；不勾选令牌仅内存，关闭标签页即需重新登录。
                  ListenableBuilder(
                    listenable: widget.auth,
                    builder: (context, _) {
                      final busy = widget.auth.busy;
                      return Row(
                        children: [
                          fluent.Checkbox(
                            checked: _remember,
                            onChanged: busy
                                ? null
                                : (v) => setState(() => _remember = v ?? false),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: busy
                                  ? null
                                  : () =>
                                      setState(() => _remember = !_remember),
                              child: Text('记住我（长期保持登录）',
                                  style: TextStyle(
                                      fontSize: 12,
                                      color: palette.textMuted)),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                  // 错误文案：限高滚动兜底，避免长报错撑破卡片
                  ListenableBuilder(
                    listenable: widget.auth,
                    builder: (context, _) {
                      final err = _localError ?? widget.auth.error;
                      if (err == null) return const SizedBox.shrink();
                      return Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: FadeSlide(
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Icon(FluentIcons.error_circle_24_regular,
                                  size: 14, color: palette.statusDanger),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(err,
                                    style: TextStyle(
                                        fontSize: 12,
                                        color: palette.statusDanger)),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 18),
                  ListenableBuilder(
                    listenable: widget.auth,
                    builder: (context, _) {
                      final busy = widget.auth.busy;
                      return SizedBox(
                        height: mobile ? 44 : 36,
                        child: fluent.FilledButton(
                          onPressed: busy ? null : _submit,
                          child: busy
                              ? const SizedBox(
                                  width: 15,
                                  height: 15,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2))
                              : Text(_isRegister ? '注册并登录' : '登录'),
                        ),
                      );
                    },
                  ),
                  // 注册入口：仅在网关开启自助注册时出现。
                  ListenableBuilder(
                    listenable: widget.auth,
                    builder: (context, _) {
                      if (!widget.auth.registrationEnabled) {
                        return const SizedBox.shrink();
                      }
                      return Padding(
                        padding: const EdgeInsets.only(top: 14),
                        child: Center(
                          child: TextButton(
                            onPressed: widget.auth.busy
                                ? null
                                : () => _switchMode(!_isRegister),
                            child: Text(
                              _isRegister ? '已有账号？返回登录' : '还没有账号？注册',
                              style: TextStyle(
                                  fontSize: 12, color: palette.primaryColor),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _fieldLabel(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(text,
            style: TextStyle(fontSize: 12, color: palette.textMuted)),
      );
}
