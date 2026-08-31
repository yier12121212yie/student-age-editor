import 'dart:async' show unawaited;
import 'dart:io' show Platform;
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import 'core/api_client.dart';
import 'core/app_theme.dart';
import 'core/backend_launcher.dart';
import 'core/models.dart';
import 'core/plugin_state.dart';
import 'core/responsive.dart';
import 'core/ui_mode.dart';
import 'core/motion.dart';
import 'features/oobe/oobe_page.dart';
import 'features/shell/classic_shell.dart';
import 'features/shell/editor_shell.dart';
import 'features/shell/mobile_shell.dart';
import 'features/shell/shell_state.dart';
import 'features/shell/story_flow_shell.dart';

const accentColor = Color(0xFF6C5CE7);

class StudentAgeEditorApp extends StatefulWidget {
  const StudentAgeEditorApp({super.key, this.forceOobe = false});

  /// 启动参数 --oobe 传入时强制显示首次使用引导页。
  final bool forceOobe;
  @override
  State<StudentAgeEditorApp> createState() => _StudentAgeEditorAppState();
}

class _StudentAgeEditorAppState extends State<StudentAgeEditorApp> {
  final AppState state = AppState();
  final PluginState pluginState = PluginState();
  ShellState? _shell;
  UiMode _uiMode = UiMode.creation;
  bool _loaded = false;
  String? _loadError;
  bool _showOobe = false;
  bool _oobeSettled = false; // 本会话内用户已完成/跳过引导后不再重弹
  AppLifecycleListener? _exitHandler;

  @override
  void initState() {
    super.initState();
    _exitHandler = AppLifecycleListener(
      onExitRequested: () async {
        await BackendLauncher.instance.shutdownBackend();
        return AppExitResponse.exit;
      },
    );
    _bootstrap();
    _initUiMode();
    unawaited(AppTheme.init());
    // 跟随系统模式下，系统亮度变化时同步当前调色板
    WidgetsBinding.instance.platformDispatcher.onPlatformBrightnessChanged = () {
      if (AppTheme.mode.value == AppThemeMode.system) {
        AppTheme.apply(AppThemeMode.system, save: false);
      }
    };
  }

  @override
  void dispose() {
    _exitHandler?.dispose();
    super.dispose();
  }

  Future<void> _initUiMode() async {
    final mode = await UiMode.load();
    // 经典布局侧栏偏窄（分组导航），创作/剧情图使用相同宽度
    final sidebar = switch (mode) {
      UiMode.classic => 280.0,
      UiMode.creation || UiMode.storyFlow => 320.0,
    };
    final shell = ShellState(defaultSidebarWidth: sidebar);
    unawaited(shell.loadSettings());
    if (!mounted) return;
    setState(() {
      _uiMode = mode;
      _shell = shell;
    });
  }

  Future<void> _setUiMode(UiMode mode) async {
    if (mode == _uiMode) return;
    await mode.save();
    if (!mounted) return;
    setState(() {
      _uiMode = mode;
      if (mode == UiMode.classic) _shell?.setAiOpen(false);
    });
  }

  Future<void> _bootstrap() async {
    try {
      await BackendLauncher.instance.ensureBackend();
      final ping = await ApiClient.instance.get('/api/ping');
      final st = await ApiClient.instance.get('/api/state');
      final schema = await ApiClient.instance.get('/api/schema');
      final dicts = await ApiClient.instance.get('/api/dicts');
      if (!mounted) return;
      setState(() {
        state.workspaceRoot = st['workspace_root'] as String? ?? '';
        state.modRoot = st['mod_root'] as String? ?? '';
        state.modName = st['mod_name'] as String? ?? '';
        state.mods = (st['mods'] as List? ?? [])
            .map((e) => ModInfo.fromJson(e as Map<String, dynamic>))
            .toList();
        state.aaStatus = st['aa_status'] as String? ?? 'idle';
        state.gameSchema = (schema['game_schema'] as Map?)?.cast<String, dynamic>() ?? {};
        state.keyMaps = (dicts['key_maps'] as Map?)?.cast<String, dynamic>() ?? {};
        state.gameDicts = (dicts['game_dicts'] as Map?)?.cast<String, dynamic>() ?? {};
      state.backendOnline = ping['ok'] == true;
        _loaded = true;
      });
      // 后端就绪后拉取插件列表与面板声明（失败静默，插件页内可手动重试）
      unawaited(pluginState.refresh());
      await _checkOobe();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadError = e.toString();
      });
    }
  }

  /// OOBE 状态判定：--oobe / EDITOR_OOBE=1 强制开启；
  /// 否则读取后端共享标记（editor_env.json），首访未完成时开启。
  Future<void> _checkOobe() async {
    if (_oobeSettled) return;
    try {
      final envRaw = Platform.environment['EDITOR_OOBE']?.trim().toLowerCase() ?? '';
      final forced = widget.forceOobe ||
          (envRaw.isNotEmpty && const {'1', 'true', 'yes', 'on'}.contains(envRaw));
      bool firstRun = false;
      try {
        final st = await ApiClient.instance
            .get('/api/oobe/status')
            .timeout(const Duration(seconds: 8));
        firstRun = st is Map && st['first_run'] == true;
      } catch (_) {
        // 后端较旧无此接口时按已完成处理，避免误弹
        firstRun = false;
      }
      // await 期间用户可能刚完成/跳过引导，不应再覆盖其决定
      if (!mounted || _oobeSettled) return;
      setState(() {
        _showOobe = forced || firstRun;
      });
    } catch (_) {}
  }

  Future<void> _onOobeFinished() async {
    if (!mounted) return;
    setState(() {
      _oobeSettled = true;
      _showOobe = false;
    });
    unawaited(_bootstrap());
  }

  /// 构建 Fluent 主题（亮/暗共用强调色与字体，亮色为新增）。
  fluent.FluentThemeData _fluentTheme(Brightness brightness) {
    return fluent.FluentThemeData(
      brightness: brightness,
      accentColor: fluent.AccentColor.swatch(const <String, Color>{
        'normal': accentColor,
        'dark': Color(0xFF5A4BD1),
        'darker': Color(0xFF4A3DB8),
        'darkest': Color(0xFF3B3096),
        'light': Color(0xFF8B7FEF),
        'lighter': Color(0xFFA99FF4),
        'lightest': Color(0xFFC7C0F9),
      }),
      visualDensity: VisualDensity.standard,
      fontFamily: 'Microsoft YaHei',
      scaffoldBackgroundColor: palette.bg,
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: AppTheme.mode,
      builder: (context, _) {
        final mode = AppTheme.mode.value;
        return fluent.FluentApp(
          title: '学生时代模组编辑器',
          debugShowCheckedModeBanner: false,
          theme: _fluentTheme(Brightness.light),
          darkTheme: _fluentTheme(Brightness.dark),
          themeMode: switch (mode) {
            AppThemeMode.system => ThemeMode.system,
            AppThemeMode.light => ThemeMode.light,
            AppThemeMode.dark => ThemeMode.dark,
          },
          home: Material(
            // 壳基于 Fluent UI，但部分控件（InkWell/PopupMenuButton 等）来自 Material，
            // 全局提供透明 Material 祖先满足其渲染校验
            type: MaterialType.transparency,
            child: _loaded && _shell != null
                ? (_showOobe
                    ? OobePage(
                        onFinished: _onOobeFinished,
                        forced: widget.forceOobe,
                        onUiModeChanged: _setUiMode,
                      )
                    : _buildShell())
                : _buildLoading(),
          ),
        );
      },
    );
  }

  Widget _buildShell() {
    final shell = _shell!;
    return AnimatedSwitcher(
      duration: AppMotion.normal,
      switchInCurve: AppMotion.easeOut,
      switchOutCurve: AppMotion.easeOut,
      transitionBuilder: (child, anim) {
        final slide = Tween<Offset>(begin: const Offset(0, 0.015), end: Offset.zero).animate(anim);
        return FadeTransition(opacity: anim, child: SlideTransition(position: slide, child: child));
      },
      child: LayoutBuilder(
        key: ValueKey(_uiMode),
        builder: (context, c) {
          if (c.maxWidth < Breakpoints.mobile) {
            return MobileShell(state: state, shell: shell, pluginState: pluginState, uiMode: _uiMode, onUiModeChanged: _setUiMode);
          }
          if (_uiMode == UiMode.classic) {
            return ClassicShell(state: state, shell: shell, pluginState: pluginState, uiMode: _uiMode, onUiModeChanged: _setUiMode);
          }
          if (_uiMode == UiMode.storyFlow) {
            return StoryFlowShell(state: state, shell: shell, pluginState: pluginState, uiMode: _uiMode, onUiModeChanged: _setUiMode);
          }
          return CreationShell(state: state, shell: shell, pluginState: pluginState, uiMode: _uiMode, onUiModeChanged: _setUiMode);
        },
      ),
    );
  }

  Widget _buildLoading() {
    return Scaffold(
      backgroundColor: palette.bg,
      body: Center(
        child: ScaleFade(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_loadError == null) ...[
                TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0, end: 1),
                  duration: const Duration(milliseconds: 1200),
                  builder: (context, v, child) => Stack(
                    alignment: Alignment.center,
                    children: [
                      SizedBox(
                        width: 36,
                        height: 36,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          value: null,
                          color: Color.lerp(const Color(0xFF6C5CE7), const Color(0xFF8B7FEF), (v * 2) % 1),
                        ),
                      ),
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: const Color(0xFF6C5CE7).withValues(alpha: 0.9 - 0.4 * v),
                          shape: BoxShape.circle,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                FadeSlide(
                  delay: const Duration(milliseconds: 100),
                  child: Text('正在连接本地服务',
                      style: TextStyle(
                          color: palette.textMuted,
                          fontSize: 13,
                          letterSpacing: 0.3)),
                ),
                const SizedBox(height: 16),
                const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ShimmerBox(width: 72, height: 8, radius: 4),
                    SizedBox(width: 8),
                    ShimmerBox(width: 48, height: 8, radius: 4),
                  ],
                ),
              ] else ...[
                const ScaleFade(child: Icon(FluentIcons.error_circle_24_regular, color: Colors.redAccent, size: 32)),
                const SizedBox(height: 12),
                // 错误详情可能很长：限宽限高并允许滚动，避免小窗纵向溢出
                FadeSlide(
                  delay: const Duration(milliseconds: 80),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 560, maxHeight: 220),
                    child: SingleChildScrollView(
                      child: Text('无法连接后端服务\n$_loadError',
                          softWrap: true,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              color: palette.textMuted, fontSize: 13)),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                FadeSlide(
                  delay: const Duration(milliseconds: 160),
                  child: fluent.Button(
                    onPressed: () {
                      setState(() {
                        _loadError = null;
                        _loaded = false;
                      });
                      _bootstrap();
                    },
                    child: const Text('重试'),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
