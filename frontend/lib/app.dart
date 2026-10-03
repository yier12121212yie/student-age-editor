import 'dart:async' show unawaited;
import 'dart:ui' show AppExitResponse;

import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import 'package:flutter/foundation.dart' show kDebugMode, kIsWeb;
import 'package:flutter/material.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import 'core/api_client.dart';
import 'core/app_theme.dart';
import 'core/backend_launcher.dart';
import 'core/models.dart';
import 'core/platform_env.dart';
import 'core/plugin_state.dart';
import 'core/responsive.dart';
import 'core/ui_mode.dart';
import 'core/motion.dart';
import 'core/update_check.dart';
import 'features/auth/auth_state.dart';
import 'features/auth/login_page.dart';
import 'features/oobe/oobe_page.dart';
import 'features/shell/classic_shell.dart';
import 'features/shell/editor_shell.dart';
import 'features/shell/mobile_shell.dart';
import 'features/shell/shell_state.dart';
import 'features/shell/story_flow_shell.dart';

class StudentAgeEditorApp extends StatefulWidget {
  const StudentAgeEditorApp({super.key, this.forceOobe = false});

  /// 启动参数 --oobe 传入时强制显示首次使用引导页。
  final bool forceOobe;
  @override
  State<StudentAgeEditorApp> createState() => _StudentAgeEditorAppState();
}

class _StudentAgeEditorAppState extends State<StudentAgeEditorApp>
    with WidgetsBindingObserver {
  final AppState state = AppState();
  final PluginState pluginState = PluginState();
  final AuthState _auth = AuthState();
  ShellState? _shell;
  UiMode _uiMode = UiMode.creation;
  bool _loaded = false;
  String? _loadError;
  bool _showOobe = false;
  bool _oobeSettled = false; // 本会话内用户已完成/跳过引导后不再重弹
  bool _bootstrapping = false; // _bootstrap 防重入（启动与错误页重试可能并发）
  bool _buildingBackend = false; // 错误页「编译并启动后端」进行中（仅 debug）
  AppLifecycleListener? _exitHandler;

  @override
  void initState() {
    super.initState();
    AppState.current = state; // 深层小控件（如无代码模式开关）同步全局态的挂点
    AuthState.current = _auth; // 状态栏用户芯片等非 prop-drilling 消费
    // 退出回收后端进程仅桌面有意义；Web 无进程可杀（onExitRequested 在浏览器
    // 也不会触发），不注册。
    if (!kIsWeb) {
      _exitHandler = AppLifecycleListener(
        onExitRequested: () async {
          await BackendLauncher.instance.shutdownBackend();
          return AppExitResponse.exit;
        },
      );
    }
    _startApp();
    _initUiMode();
    unawaited(AppTheme.init());
    // 跟随系统模式下，系统亮度变化时同步当前调色板。
    //
    // 必须走 WidgetsBindingObserver：直接给 platformDispatcher 的
    // onPlatformBrightnessChanged 赋值会顶掉框架自己注册的
    // handlePlatformBrightnessChanged，MediaQuery/WidgetsApp 再也收不到亮度
    // 变化（系统换主题后内建控件与自绘控件各停一半）。addObserver 不抢回调，
    // 且 AppTheme 会在调色板变化时通知根部重建。
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangePlatformBrightness() {
    if (AppTheme.mode.value == AppThemeMode.system) {
      AppTheme.apply(AppThemeMode.system, save: false);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (AppState.current == state) AppState.current = null;
    if (AuthState.current == _auth) AuthState.current = null;
    ApiClient.instance.onUnauthorized = null;
    _exitHandler?.dispose();
    _auth.dispose();
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
    // 恢复上次会话的 AI 开合与两侧宽度（阶段 2 布局持久化）
    unawaited(shell.loadLayout());
    // 插件卸载/刷新后，若当前打开的动态面板所属插件已不在列表，清掉选中态：
    // 否则壳层会一直停留在失效面板的“加载失败 + 重试”页。
    pluginState.addListener(() {
      final active = shell.activePluginPanel;
      if (active == null) return;
      final pid = active.split('/').first;
      if (!pluginState.plugins.any((p) => p.id == pid)) {
        shell.setActivePluginPanel(null);
      }
    });
    if (!mounted) return;
    setState(() {
      _uiMode = mode;
      _shell = shell;
    });
  }

  Future<void> _setUiMode(UiMode mode) async {
    if (mode == _uiMode) return;
    // 壳按 ValueKey(_uiMode) 整体重建：内容区注册的守卫（剧情图画布的
    // 未保存确认）必须先通过，否则舞台编辑会被无声丢弃
    final guard = state.leaveGuard;
    if (guard != null) {
      final ok = await guard();
      if (!ok || !mounted) return;
    }
    await mode.save();
    if (!mounted) return;
    setState(() {
      _uiMode = mode;
      if (mode == UiMode.classic) _shell?.setAiOpen(false);
    });
  }

  /// 启动门控（M2.4 托管登录）：桌面/Android 直接进原流程（零变化）；
  /// Web 先探测网关鉴权模式——local 直进；hosted 且无有效会话则停在登录页
  /// （不跑 bootstrap，避免 schema/字典等接口被网关 401 刷屏），登录成功后
  /// 由 [LoginPage.onLoggedIn] 回调继续 _bootstrap。
  Future<void> _startApp() async {
    if (kIsWeb) {
      // 任何接口 401（token 过期等）→ 清会话回登录页
      ApiClient.instance.onUnauthorized = _auth.logout;
      await _auth.probe();
      if (!mounted) return;
      if (_auth.requiresLogin) {
        setState(() {}); // 触发 ListenableBuilder 外的首帧兜底重建
        return;
      }
    }
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    // 防重入：启动路径与错误页「重试」按钮（以及后台唤醒重连）可能并发
    // 触发，双跑会对同一批端点发两遍请求、后写者覆盖先写者的 setState。
    if (_bootstrapping) return;
    _bootstrapping = true;
    try {
      await BackendLauncher.instance.ensureBackend();
      // ping 先单独完成：它是「后端在线」的唯一判定源，必须最先定案。
      final ping = await ApiClient.instance.get('/api/ping');
      // state/schema/dicts 互不依赖（各自响应写回各自无依赖的 AppState 字段），
      // 并行发出，把冷启动关键路径从三个串行往返压成一个。
      final loaded = await Future.wait<dynamic>([
        ApiClient.instance.get('/api/state'),
        ApiClient.instance.get('/api/schema'),
        ApiClient.instance.get('/api/dicts'),
      ]);
      final st = loaded[0];
      final schema = loaded[1];
      final dicts = loaded[2];
      if (!mounted) return;
      setState(() {
        state.workspaceRoot = st['workspace_root'] as String? ?? '';
        state.modRoot = st['mod_root'] as String? ?? '';
        state.modName = st['mod_name'] as String? ?? '';
        state.mods = (st['mods'] as List? ?? const [])
            .whereType<Map>()
            .map((e) => ModInfo.fromJson(Map<String, dynamic>.from(e)))
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
      // 编辑器共享设置与 OOBE 状态互不依赖（两端点、各自内部消化错误），
      // 并行执行，冷启动少一个串行往返。
      await Future.wait<void>([
        _syncEditorSettings(),
        _checkOobe(),
      ]);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadError = e.toString();
      });
    } finally {
      _bootstrapping = false;
    }
  }

  /// 编辑器共享设置：无代码模式开关 + 外观（白日/暗色，三端共享）。
  /// 旧后端无此端点时两者都保持本地现状，不报错。
  Future<void> _syncEditorSettings() async {
    try {
      final ed = await ApiClient.instance
          .get('/api/settings/editor')
          .timeout(const Duration(seconds: 8));
      final s = ed is Map ? ed['settings'] : null;
      final nc = s is Map && s['noCodeMode'] == true;
      if (mounted) state.setNoCodeMode(nc);
      await _syncSharedAppearance(ed);
    } catch (e) {
      // 旧后端无此端点属正常；留 debug 日志便于排查真实故障。
      if (kDebugMode) debugPrint('[bootstrap] settings/editor 同步失败: $e');
    }
  }

  /// 开发模式（flutter run）：从 native 源码增量构建后端并拉起，成功后重跑
  /// _bootstrap 进入正常界面；失败把构建输出摘要显示回错误页。
  Future<void> _buildAndStartBackend() async {
    if (_buildingBackend) return;
    setState(() {
      _buildingBackend = true;
      _loadError = null;
    });
    final result = await BackendLauncher.instance.buildSourceBackend();
    if (!mounted) return;
    setState(() => _buildingBackend = false);
    if (result.ok) {
      _bootstrap();
    } else {
      setState(() => _loadError = result.log.isEmpty ? '编译并启动后端失败' : result.log);
    }
  }

  /// 把后端共享外观值（明暗模式 + 用户主题色）同步到本地（三端统一的关键一步）。
  ///
  /// 两个键同一条规则：
  /// - 后端从没写过该键（meta.XxxExplicit=false）：把本地已选值**种子上传**，
  ///   避免老用户在本机选的设置被后端默认值盖掉；
  /// - 后端写过且与本地不同：采纳后端值，除非用户本次会话已经手动选过；
  /// - 任何写失败都静默：本机观感已生效，共享值下次启动再对齐。
  Future<void> _syncSharedAppearance(dynamic ed) async {
    if (ed is! Map) return;
    // init 幂等（同一 future）：确保 prefs 里的本地选择先落地再做种子/回灌裁决。
    await AppTheme.init();
    final s = ed['settings'];
    final meta = ed['meta'];
    final raw = s is Map ? s['appearanceMode'] : null;
    final shared = AppThemeMode.fromPrefsValue(raw is String ? raw : null);
    final explicit =
        meta is Map && meta['appearanceModeExplicit'] == true;
    try {
      if (!explicit) {
        // 种子迁移：只在值非默认（暗色）时写，避免无意义写入。
        if (AppTheme.mode.value != AppThemeMode.dark) {
          // PUT 前复查：等待期间用户可能刚手动选了外观，种子不得盖过它。
          if (AppTheme.userTouchedThisSession) return;
          await ApiClient.instance.put('/api/settings/editor',
              body: {'appearanceMode': AppTheme.mode.value.prefsValue});
        }
      } else if (!AppTheme.userTouchedThisSession &&
          AppTheme.mode.value != shared) {
        await AppTheme.apply(shared);
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[appearance] 共享值同步失败（忽略）: $e');
    }
    await _syncSharedAccentColor(s, meta);
  }

  /// 用户主题色的共享同步：裁决逻辑与明暗模式完全同款（见上）。
  Future<void> _syncSharedAccentColor(dynamic s, dynamic meta) async {
    final raw = s is Map ? s['themeColor'] : null;
    final shared = AppAccentColor.parse(raw is String ? raw : null);
    final explicit =
        meta is Map && meta['themeColorExplicit'] == true;
    try {
      if (!explicit) {
        if (AppTheme.accentSeed != kDefaultAccent) {
          if (AppTheme.userTouchedAccentThisSession) return;
          await ApiClient.instance.put('/api/settings/editor',
              body: {'themeColor': AppAccentColor.toHex(AppTheme.accentSeed)});
        }
      } else if (!AppTheme.userTouchedAccentThisSession &&
          shared != null &&
          AppTheme.accentSeed != shared) {
        await AppTheme.setAccent(shared, userIntent: false);
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[accent] 共享主题色同步失败（忽略）: $e');
    }
  }

  /// OOBE 状态判定：--oobe / EDITOR_OOBE=1 强制开启；
  /// 否则读取后端共享标记（editor_env.json），首访未完成时开启。
  Future<void> _checkOobe() async {
    if (_oobeSettled) return;
    try {
      // 环境变量覆盖仅桌面有效；Web 上 envValue 恒 null（等价无该变量）。
      final envRaw =
          envValue('EDITOR_OOBE')?.trim().toLowerCase() ?? '';
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
  ///
  /// accent 色阶随用户主题色变化：默认品牌紫沿用历史七档，自定义色派生。
  fluent.FluentThemeData _fluentTheme(Brightness brightness) {
    return fluent.FluentThemeData(
      brightness: brightness,
      accentColor: fluent.AccentColor.swatch(accentSwatch()),
      visualDensity: VisualDensity.standard,
      fontFamily: 'Microsoft YaHei',
      scaffoldBackgroundColor: palette.bg,
      // Fluent 的 Card 默认走 Mica 半透明资源色，在深色底上几乎全透；用调色板
      // 卡片色兜底，具体见 app_theme.opaqueMaterialSurfaces（Material 侧同源）。
      cardColor: palette.card,
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: AppTheme.changes,
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
          // Material 兜底主题：FluentApp 注入的 Material 层表面色是 Mica 半透明
          // 资源色，凡未显式指定底板的 Material 弹层都会整窗透明。这里把弹层统一
          // 覆盖成不透明调色板色（包在 Navigator 之上，弹窗/菜单也在覆盖范围内）。
          builder: (context, child) => Theme(
            data: opaqueMaterialSurfaces(Theme.of(context), palette),
            // 闸门放在 Navigator/Overlay 之上：弹窗、信息条里的转圈与装饰动画
            // 同样受窗口生命周期管制（只包 home 会漏掉 overlay 那一层）。
            child: MotionGate(child: child ?? const SizedBox.shrink()),
          ),
          home: Material(
            // 壳基于 Fluent UI，但部分控件（InkWell/PopupMenuButton 等）来自 Material，
            // 全局提供透明 Material 祖先满足其渲染校验
            type: MaterialType.transparency,
            child: ListenableBuilder(
              listenable: _auth,
              builder: (context, _) {
                // 托管登录门（M2.4）：Web + hosted + 无有效会话时只渲染
                // 登录页；探测中（unknown）走下方 loading，本机模式恒不命中。
                if (_auth.requiresLogin) {
                  return LoginPage(
                    auth: _auth,
                    onLoggedIn: () => unawaited(_bootstrap()),
                  );
                }
                return _loaded && _shell != null
                    ? (_showOobe
                        ? OobePage(
                            onFinished: _onOobeFinished,
                            forced: widget.forceOobe,
                            onUiModeChanged: _setUiMode,
                          )
                        // 启动静默检查宿主：包住壳层，拿到 Navigator/Overlay 之下的
                        // context，才能用 fluent.displayInfoBar 弹「发现新版本」。
                        : _UpdateCheckHost(child: _buildShell()))
                    : _buildLoading();
              },
            ),
          ),
        );
      },
    );
  }

  Widget _buildShell() {
    final shell = _shell!;
    // Opaque palette background at the shell root: the shells are bare Columns
    // with no Scaffold, so without this the window's default dark clear color
    // shows through in light mode while text uses the light palette -> dark on
    // dark (bug #4).
    return ColoredBox(
      color: palette.bg,
      child: AnimatedSwitcher(
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
                          // 品牌紫 → 当前外观的浅一档（dark=#8B7FEF 与历史同值）
                          color: Color.lerp(accentColor, palette.accentLight, (v * 2) % 1),
                        ),
                      ),
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: accentColor.withValues(alpha: 0.9 - 0.4 * v),
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
                ScaleFade(child: Icon(FluentIcons.error_circle_24_regular, color: palette.danger, size: 32)),
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
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // 开发模式（flutter run）且后端连不上：提供源码构建入口，
                          // 产物未构建时自动增量编译（首次可能需要几分钟）。
                          if (kDebugMode && BackendLauncher.supportsSpawn) ...[
                            fluent.Button(
                              onPressed:
                                  _buildingBackend ? null : _buildAndStartBackend,
                              child: _buildingBackend
                                  ? const Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        SizedBox(
                                          width: 12,
                                          height: 12,
                                          child: CircularProgressIndicator(
                                              strokeWidth: 2),
                                        ),
                                        SizedBox(width: 8),
                                        Text('构建中…'),
                                      ],
                                    )
                                  : const Text('编译并启动后端'),
                            ),
                            const SizedBox(width: 8),
                          ],
                          fluent.Button(
                            onPressed: _buildingBackend
                                ? null
                                : () {
                                    setState(() {
                                      _loadError = null;
                                      _loaded = false;
                                    });
                                    _bootstrap();
                                  },
                            child: const Text('重试'),
                          ),
                        ],
                      ),
                      if (kDebugMode && BackendLauncher.supportsSpawn)
                        Padding(
                          padding: const EdgeInsets.only(top: 10),
                          child: Text(
                            _buildingBackend
                                ? '正在从源码构建后端（native），首次可能需要几分钟…'
                                : '开发模式：也可在仓库根运行 python run_dev.py 一键启动',
                            style: TextStyle(
                                color: palette.textMuted, fontSize: 11)),
                        ),
                    ],
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

/// 启动静默检查宿主：首帧后（后端已就绪）查一次最新发行版。
///
/// - 关闭自动检查、或距上次尝试不足 24h → 不发请求（UpdateState.maybeStartupCheck）；
/// - 发现未跳过的新版本 → 弹一条 InfoBar（含「复制发行页链接」）；
/// - 任何失败都静默：用户仍可在设置页手动检查，启动路径绝不因网络问题报错。
class _UpdateCheckHost extends StatefulWidget {
  const _UpdateCheckHost({required this.child});

  final Widget child;

  @override
  State<_UpdateCheckHost> createState() => _UpdateCheckHostState();
}

class _UpdateCheckHostState extends State<_UpdateCheckHost> {
  bool _scheduled = false;

  @override
  Widget build(BuildContext context) {
    // 首帧后再查：此时壳层已挂载，InfoBar 有可用的 Overlay。
    if (!_scheduled) {
      _scheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _check());
    }
    return widget.child;
  }

  Future<void> _check() async {
    if (!mounted) return;
    final s = UpdateState.instance;
    await s.load();
    await s.ensureVersion();
    final r = await s.maybeStartupCheck();
    if (r == null || !mounted) return;
    final current = r.current.isEmpty ? '未知' : r.current;
    fluent.displayInfoBar(
      context,
      builder: (ctx, close) => fluent.InfoBar(
        title: Text('发现新版本 ${r.latestTag}'),
        content: Text(
          '当前版本 $current。可在「设置 → 关于 · 检查更新」查看发行说明，'
          '或把发行页链接复制到浏览器下载。',
          style: const TextStyle(fontSize: 12),
        ),
        action: fluent.Button(
          onPressed: () {
            if (r.htmlUrl.isEmpty) return;
            Clipboard.setData(ClipboardData(text: r.htmlUrl));
          },
          child: const Text('复制发行页链接', style: TextStyle(fontSize: 11)),
        ),
        severity: fluent.InfoBarSeverity.info,
      ),
    );
  }
}
