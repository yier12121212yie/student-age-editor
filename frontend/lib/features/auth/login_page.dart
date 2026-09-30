import 'package:flutter/material.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../../core/app_theme.dart';
import '../../core/motion.dart';
import '../../core/responsive.dart';
import 'auth_state.dart';

/// 托管模式登录页（M2.4）：网关部署且无有效会话时替换主壳显示。
///
/// 视觉沿用 OOBE 卡片风格（居中卡片 + palette 配色），表单为
/// 用户名/密码 + 登录按钮 + 中文错误文案；Enter 逐级提交（用户名 →
/// 密码 → 登录）；窄屏（<720）卡片自适应宽度并保证触控高度。
class LoginPage extends StatefulWidget {
  const LoginPage({super.key, required this.auth, this.onLoggedIn});

  final AuthState auth;

  /// 登录成功回调（应用侧继续原 bootstrap 流程）。
  final VoidCallback? onLoggedIn;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _nameCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  final _nameFocus = FocusNode();
  final _passFocus = FocusNode();
  bool _obscure = true;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _passCtrl.dispose();
    _nameFocus.dispose();
    _passFocus.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final ok = await widget.auth.login(_nameCtrl.text, _passCtrl.text);
    if (ok && mounted) widget.onLoggedIn?.call();
  }

  @override
  Widget build(BuildContext context) {
    final mobile = isMobileWidth(context);
    final size = MediaQuery.sizeOf(context);
    final cardWidth = mobile
        ? (size.width - 24).clamp(0.0, 380.0)
        : 380.0;
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
                      child: Icon(FluentIcons.lock_closed_24_regular,
                          size: 26, color: accentColor),
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
                    child: Text('此服务需登录后使用',
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
                    placeholder: '请输入密码',
                    obscureText: _obscure,
                    onSubmitted: (_) => _submit(),
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
                  // 错误文案：限高滚动兜底，避免长报错撑破卡片
                  ListenableBuilder(
                    listenable: widget.auth,
                    builder: (context, _) {
                      final err = widget.auth.error;
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
                              : const Text('登录'),
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
