// C1 起本文件用到 Timer（慢启动提示），故不能再限制为 `show unawaited`。
import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import 'package:flutter/foundation.dart'
    show kDebugMode, kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import 'core/a11y_semantics.dart';
import 'core/app_title_text.dart';
import 'core/api_client.dart';
import 'core/app_command.dart';
import 'core/app_feedback.dart';
import 'core/app_shortcuts.dart';
import 'core/app_theme.dart';
import 'core/backend_launcher.dart';
import 'core/editor_font.dart';
import 'core/error_text.dart';
import 'core/models.dart';
import 'core/platform_env.dart';
import 'core/plugin_state.dart';
import 'core/responsive.dart';
import 'core/save_hub.dart';
import 'core/ui_mode.dart';
import 'core/motion.dart';
import 'core/update_check.dart';
import 'core/web_diag.dart';
import 'core/web_drop.dart';
import 'core/desktop_drop.dart';
import 'core/web_head.dart';
import 'core/web_lifecycle.dart';
import 'features/auth/auth_state.dart';
import 'features/auth/login_page.dart';
import 'features/oobe/oobe_page.dart';
import 'features/resources/local_import.dart';
import 'features/shell/app_command_builder.dart';
import 'features/shell/classic_shell.dart';
import 'features/shell/director_shell.dart';
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
  // W1：全局「当前可保存对象」注册中心（SaveBar 可见时登记，Ctrl+S 现取）。
  final SaveHub _saveHub = SaveHub();
  // Web 拖放导入 / 标签页标题 / 关页拦截需要的 Navigator 上下文。
  final GlobalKey<NavigatorState> _navKey = GlobalKey<NavigatorState>();
  ShellState? _shell;
  UiMode _uiMode = UiMode.creation;
  bool _loaded = false;
  String? _loadError;
  bool _showOobe = false;
  bool _oobeSettled = false; // 本会话内用户已完成/跳过引导后不再重弹
  bool _bootstrapping = false; // _bootstrap 防重入（启动与错误页重试可能并发）
  bool _buildingBackend = false; // 错误页「编译并启动后端」进行中（仅 debug）
  AppLifecycleListener? _exitHandler;
  /// 诊断用：本页创建过几个 App 实例（>1 说明有地方把根节点重挂了）。
  static int _appInstances = 0;
  // Web：关标签/刷新前的未保存拦截（非 Web 为空实现）。持引用仅为 dispose 对称。
  WebLifecycle? _webLifecycle;
  // Web：把拖进窗口的文件当资源导入（非 Web 为 null）。
  WebFileDrop? _webDrop;
  // pluginState 的失效面板清理监听（_initUiMode 注册）；持引用以便 dispose 解绑。
  VoidCallback? _pluginPanelListener;

  // C1：加载页分阶段文案 + 慢启动提示（首帧后仍等待后端时展示）。
  String _bootStage = '正在连接本地服务';
  bool _slowBoot = false; // 超过阈值仍在等待 → 追加提示与重试
  Timer? _slowTimer;
  static const Duration _slowBootAfter = Duration(seconds: 20);

  @override
  void initState() {
    super.initState();
    _appInstances++;
    markWebDiag('init', 'n=$_appInstances');
    AppState.current = state; // 深层小控件（如简易模式开关）同步全局态的挂点
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
    } else {
      // 浏览器里没有退出回调：关标签页/刷新会直接销毁页面，未保存的修改
      // 只能靠 beforeunload 拦一次（文案由浏览器固定，无法自定义）。
      _webLifecycle = WebLifecycle.install(isDirty: _hasUnsavedChanges);
      // 拖文件到窗口 = 导入到当前模组；同时挡掉浏览器「直接打开被拖文件」
      // 的默认行为（那会整页跳走并丢掉未保存的修改）。
      _webDrop = WebFileDrop.install(onFiles: _importDroppedFiles);
      // 标签页标题 + theme-color：在任何界面（登录/引导/错误页）都生效，
      // 因此挂在根 State 上，而不是等壳层出现（core/web_head.dart）。
      bindWebHead(_composeWebTitle);
      state.addListener(_syncWebTitle);
      _syncWebTitle();
    }
    _startApp();
    _initUiMode();
    unawaited(AppTheme.init());
    // Web：恢复「屏幕阅读器支持」开关（默认关，见 core/a11y_semantics.dart）。
    unawaited(A11ySemantics.init());
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
    if (_pluginPanelListener != null) {
      pluginState.removeListener(_pluginPanelListener!);
      _pluginPanelListener = null;
    }
    if (AppState.current == state) AppState.current = null;
    if (AuthState.current == _auth) AuthState.current = null;
    state.removeListener(_syncWebTitle);
    _shell?.removeListener(_syncWebTitle);
    _shell?.controller.removeListener(_syncWebTitle);
    unbindWebHead();
    ApiClient.instance.onUnauthorized = null;
    _exitHandler?.dispose();
    _webLifecycle?.dispose();
    _webDrop?.dispose();
    _slowTimer?.cancel();
    _auth.dispose();
    super.dispose();
  }

  Future<void> _initUiMode() async {
    final mode = await UiMode.load();
    markWebDiag('uiMode', 'loaded ${mode.name}');
    // 经典布局侧栏偏窄（分组导航），创作/剧情图使用相同宽度，导演工作台更宽
    final sidebar = switch (mode) {
      UiMode.classic => 280.0,
      UiMode.creation || UiMode.storyFlow => 320.0,
      UiMode.director => 300.0,
    };
    final shell = ShellState(defaultSidebarWidth: sidebar);
    // 标签页标题跟随「模组 / 当前文档」变化（Web；桌面为空实现）。
    shell.addListener(_syncWebTitle);
    shell.controller.addListener(_syncWebTitle);
    unawaited(shell.loadSettings());
    // 恢复上次会话的 AI 开合与两侧宽度（阶段 2 布局持久化）
    unawaited(shell.loadLayout());
    // 插件卸载/刷新后，若当前打开的动态面板所属插件已不在列表，清掉选中态：
    // 否则壳层会一直停留在失效面板的“加载失败 + 重试”页。
    _pluginPanelListener = () {
      final active = shell.activePluginPanel;
      if (active == null) return;
      final pid = active.split('/').first;
      if (!pluginState.plugins.any((p) => p.id == pid)) {
        shell.setActivePluginPanel(null);
      }
    };
    pluginState.addListener(_pluginPanelListener!);
    if (!mounted) return;
    setState(() {
      _uiMode = mode;
      _shell = shell;
    });
    markWebDiag('uiMode', 'ready ${mode.name}');
  }

  Future<void> _setUiMode(UiMode mode) async {
    if (mode == _uiMode) return;
    // 壳按 ValueKey(_uiMode) 整体重建：内容区注册的守卫（剧情图画布、
    // 各工作台的未保存修改）必须先通过，否则编辑内容会被无声丢弃。
    if (!await state.runLeaveGuards()) return;
    if (!mounted) return;
    await mode.save();
    if (!mounted) return;
    setState(() {
      _uiMode = mode;
      // 经典/导演进入时先收起 AI，避免停靠侧栏或悬浮层一上来就挤压/遮挡工作区。
      if (mode == UiMode.classic || mode == UiMode.director) {
        _shell?.setAiOpen(false);
      }
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
      markWebDiag('auth', 'probe done mode=${_auth.mode.name}');
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
    // C1：超过阈值仍未就绪 → 追加「首次启动较慢」提示与「重试 / 编译启动」入口。
    _slowTimer?.cancel();
    _slowTimer = Timer(_slowBootAfter, () {
      if (mounted && !_loaded && _loadError == null) {
        setState(() => _slowBoot = true);
      }
    });
    try {
      if (kDebugMode) {
        debugPrint('[bootstrap] 开始初始化（从源码运行）...');
      }
      if (mounted) setState(() => _bootStage = '检测并启动本地服务…');
      await BackendLauncher.instance.ensureBackend();
      if (mounted && !_loaded) setState(() => _bootStage = '加载模组数据…');
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
        _slowBoot = false;
      });
      _slowTimer?.cancel();
      markWebDiag('boot', 'loaded=$_loaded shell=${_shell != null}');
      // bootstrap 直接写 state 字段（不走 setMod），这里补一次标题同步。
      _syncWebTitle();
      // 启动竞态是 Web 端最常见的「白屏/加载页卡住」根因，release 也留一条
      // 控制台线索（浏览器里 F12 即可看到，不影响正常路径）。
      debugPrint('[bootstrap] 初始化完成: workspace=${state.workspaceRoot}, '
          'mod=${state.modName}, backendOnline=${state.backendOnline}');
      // 后端就绪后拉取插件列表与面板声明（失败静默，插件页内可手动重试）
      unawaited(pluginState.refresh());
      // 编辑器共享设置与 OOBE 状态互不依赖（两端点、各自内部消化错误），
      // 并行执行，冷启动少一个串行往返。
      await Future.wait<void>([
        _syncEditorSettings(),
        _checkOobe(),
      ]);
    } catch (e) {
      debugPrint('[bootstrap] 初始化异常: $e');
      if (!mounted) return;
      setState(() {
        _loadError = humanizeErrorMessage(e);
      });
    } finally {
      _bootstrapping = false;
      _slowTimer?.cancel();
    }
  }

  /// 编辑器共享设置：简易模式开关 + 外观（白日/暗色，三端共享）。
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
        // 种子迁移：只在值非默认（亮色）时写，避免无意义写入。
        if (AppTheme.mode.value != AppThemeMode.light) {
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
  /// accent 色阶随用户主题色变化：默认品牌蓝沿用固定七档，自定义色派生。
  fluent.FluentThemeData _fluentTheme(Brightness brightness) {
    final theme = fluent.FluentThemeData(
      brightness: brightness,
      accentColor: fluent.AccentColor.swatch(accentSwatch()),
      visualDensity: VisualDensity.standard,
      // Web 用随包内置的中文字体（CanvasKit 无系统字体）；桌面端继续用系统雅黑。
      fontFamily: kIsWeb ? kEditorCjkFamily : 'Microsoft YaHei',
      scaffoldBackgroundColor: palette.bg,
      // Fluent 的 Card 默认走 Mica 半透明资源色，在深色底上几乎全透；用调色板
      // 卡片色兜底，具体见 app_theme.opaqueMaterialSurfaces（Material 侧同源）。
      cardColor: palette.card,
    );
    return theme;
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: AppTheme.changes,
      builder: (context, _) {
        final mode = AppTheme.mode.value;
        return fluent.FluentApp(
          title: '学生时代模组编辑器',
          navigatorKey: _navKey,
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
          builder: (context, child) {
            // 移动端字号/触控密度下沉到 Navigator 之上：push 出来的
            // MobileSubPage、工作台编辑页与弹窗也能继承，而不只作用于壳内。
            final mobile = isMobileWidth(context);
            final baseTheme = fluent.FluentTheme.of(context);
            final fluentData = mobile
                ? baseTheme.copyWith(
                    visualDensity: fluent.VisualDensity.comfortable,
                    typography: const fluent.Typography.raw(
                      // 移动端阅读阶梯：桌面 13/12 直接搬到手机偏小，抬到 14/13。
                      body: TextStyle(
                          fontSize: 14, fontFamily: 'Microsoft YaHei'),
                      caption: TextStyle(
                          fontSize: 13, fontFamily: 'Microsoft YaHei'),
                    ),
                  )
                : baseTheme;
            return fluent.FluentTheme(
              data: fluentData,
              child: Theme(
                data: opaqueMaterialSurfaces(Theme.of(context), palette),
                // 闸门放在 Navigator/Overlay 之上：弹窗、信息条里的转圈与装饰动画
                // 同样受窗口生命周期管制（只包 home 会漏掉 overlay 那一层）。
                child: MotionGate(
                  // 桌面端拖拽导入（Web 由 web_drop 接管；stub 在 Web 透明）。
                  child: DesktopDropRegion(
                    onFiles: _importDroppedFiles,
                    // 语义树：Windows 桌面端一律排除（accessibility_bridge 会因
                    // AXTree 更新刷屏并冻结）；Web 端默认排除（CanvasKit 语义树
                    // 每帧开销大），但允许用户在设置里开启屏幕阅读器支持。
                    // Android/iOS 必须保留语义树，否则 TalkBack 读不到任何控件。
                    child: ValueListenableBuilder<bool>(
                      valueListenable: A11ySemantics.enabled,
                      builder: (context, a11yOn, _) {
                        // W1：SaveHub 也包在 Navigator 之上——home、弹窗、移动端全屏
                        // 子页（工作台）里的 SaveBar 都在覆盖范围内。
                        final content = SaveHubScope(
                          hub: _saveHub,
                          child: child ?? const SizedBox.shrink(),
                        );
                        if (kIsWeb) {
                          return a11yOn
                              ? content
                              : ExcludeSemantics(child: content);
                        }
                        if (defaultTargetPlatform == TargetPlatform.windows) {
                          return ExcludeSemantics(child: content);
                        }
                        return content;
                      },
                    ),
                  ),
                ),
              ),
            );
          },
          home: AppShortcuts(
            // A2：快捷键只在「壳已就绪」时生效——加载页 / 引导页 / 登录页
            // 不该抢走按键，更不该弹出命令面板。
            enabled: _loaded &&
                _shell != null &&
                !_showOobe &&
                !_auth.requiresLogin,
            commands: _buildCommands,
            onSave: _saveCurrent,
            onSearch: _searchCurrent,
            onUndo: _undoCurrent,
            onRedo: _redoCurrent,
            child: Material(
              // 壳基于 Fluent UI，但部分控件（InkWell/PopupMenuButton 等）来自 Material，
              // 全局提供透明 Material 祖先满足其渲染校验
              type: MaterialType.transparency,
              child: ListenableBuilder(
                listenable: _auth,
                builder: (context, _) {
                  // 托管登录门（M2.4）：Web + hosted + 无有效会话时只渲染
                  // 登录页；探测中（unknown）走下方 loading，本机模式恒不命中。
                  if (_auth.requiresLogin) {
                    markWebDiag('render', 'login');
                    return LoginPage(
                      auth: _auth,
                      onLoggedIn: () => unawaited(_bootstrap()),
                    );
                  }
                  if (_loaded && _shell != null) {
                    markWebDiag('render', 'shell oobe=$_showOobe');
                  } else {
                    markWebDiag(
                        'render',
                        'loading loaded=$_loaded shell=${_shell != null} '
                            'err=${_loadError ?? "-"} auth=${_auth.mode.name}');
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
          ),
        );
      },
    );
  }

  /// A2：命令面板（Ctrl+K）的命令清单——现场从现有目录生成
  /// （页面 / 功能 / 模组 / 模式 / 常用动作），不新建第二份清单。
  List<AppCommand> _buildCommands(BuildContext context) {
    final shell = _shell;
    if (shell == null) return const <AppCommand>[];
    // 注意：这里必须用调用方（快捷键宿主）的 context——它是 FluentApp 之下、
    // Navigator/Overlay 之内的节点，才有 MediaQuery；app 根 context 在
    // FluentApp 之上，直接 sizeOf 会断言失败。
    final mobile = isMobileWidth(context);
    return buildAppCommands(
      state: state,
      shell: shell,
      uiMode: _uiMode,
      host: shell.commandHost,
      setUiMode: _setUiMode,
      // 导演壳与手机宽度没有左侧栏：面板类动作点了没反应，不生成；它们各自
      // 通过 host.extraActions / host.openFeature 提供自己的入口。
      includePaneActions: !mobile && _uiMode != UiMode.director,
      // 「保存当前」只在真的有可保存对象（活动工作台 / 壳登记）时出现。
      saveCurrent: (_saveHub.active != null || shell.commandHost.save != null)
          ? _saveCurrent
          : null,
    );
  }

  /// Ctrl+S：优先保存当前可见工作台登记到 [SaveHub] 的句柄，其次壳登记的
  /// 命令回调。返回 `false` 表示当前没有可保存的内容，由快捷键宿主统一
  /// 提示（保持「按了有反馈」）。
  Future<bool> _saveCurrent() async {
    final handle = _saveHub.active;
    if (handle != null && handle.canSave()) {
      await handle.save();
      return true;
    }
    final hostSave = _shell?.commandHost.save;
    if (hostSave != null) {
      await hostSave();
      return true;
    }
    return false;
  }

  /// 浏览器标签页标题（桌面/移动端由 runner 决定，这里是空实现）。
  String _composeWebTitle() => composeAppTitle(
        modName: state.modName,
        modDisplayName: state.currentModDisplayName,
        docTitle: _shell?.controller.current?.title,
      );

  void _syncWebTitle() => setWebDocumentTitle(_composeWebTitle());

  /// Ctrl+F：打开「剧情库检索」（壳登记优先，创作/经典退回左侧栏面板）。
  void _searchCurrent() => _shell?.openSearch();

  /// Web 关标签/刷新拦截的同步脏判定。
  ///
  /// 两个来源覆盖全部「用户以为已经改了」的地方：
  /// - [SaveHub]：可见保存条登记的句柄（12 个工作台 + 编辑区都走它），
  ///   `canSave()` 就是「脏且未被阻塞」；
  /// - 编辑区页签脏集合：页签被切走时对应 SaveBar 可能已注销，但文档仍脏。
  ///
  /// 剧情画布等自绘守卫是异步的（`Future<bool> Function()`），无法在
  /// beforeunload 里 await，故不纳入——宁可少拦一次，也不误报。
  bool _hasUnsavedChanges() {
    if (_saveHub.active?.canSave() ?? false) return true;
    return _shell?.controller.hasDirtyDocs ?? false;
  }

  /// 拖进窗口的文件按扩展名分流后走与「导入本地…」完全相同的链路
  /// （`importPickedLocalAssets`：小文件落盘、Web 大文件转 COS 引用、
  /// 逐条错误反馈、图片缓存失效）。
  Future<void> _importDroppedFiles(List<DroppedFile> files) async {
    final ctx = _navKey.currentState?.overlay?.context;
    if (ctx == null || files.isEmpty) return;
    if (state.modName.isEmpty) {
      AppFeedback.warning(ctx, '请先选择一个模组，再把文件拖进来');
      return;
    }

    final byKind = <String, List<PickedLocalFile>>{};
    final skipped = <String>[];
    for (final f in files) {
      final kind = _dropKindOf(f.name);
      if (kind == null) {
        skipped.add(f.name);
        continue;
      }
      (byKind[kind] ??= <PickedLocalFile>[]).add(f);
    }

    for (final entry in byKind.entries) {
      if (!ctx.mounted) return;
      await importPickedLocalAssets(ctx, entry.value, kind: entry.key,
          registerAudio: entry.key == 'audio');
    }

    if (skipped.isNotEmpty && ctx.mounted) {
      final head = skipped.take(3).join('、');
      final tail = skipped.length > 3 ? ' 等 ${skipped.length} 个' : '';
      AppFeedback.info(ctx, '已跳过不支持的文件：$head$tail');
    }
  }

  /// 按扩展名推断导入类型；未识别返回 null（不猜，交给用户走选择器）。
  static String? _dropKindOf(String name) {
    final dot = name.lastIndexOf('.');
    if (dot <= 0 || dot == name.length - 1) return null;
    final ext = name.substring(dot + 1).toLowerCase();
    if (kLocalImageExtensions.contains(ext)) return 'image';
    if (kLocalAudioExtensions.contains(ext)) return 'audio';
    if (kLocalVideoExtensions.contains(ext)) return 'video';
    return null;
  }

  /// Ctrl+Z（N12）：撤销当前可见工作台登记到 [SaveHub] 的句柄。
  /// 返回 `false`（无可撤销内容）由快捷键宿主静默处理。
  Future<bool> _undoCurrent() async {
    final handle = _saveHub.active;
    if (handle == null || !(handle.canUndo?.call() ?? false)) return false;
    await handle.undo?.call();
    return true;
  }

  /// Ctrl+Y / Ctrl+Shift+Z（N12）：重做。
  Future<bool> _redoCurrent() async {
    final handle = _saveHub.active;
    if (handle == null || !(handle.canRedo?.call() ?? false)) return false;
    await handle.redo?.call();
    return true;
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
          final slide =
              Tween<Offset>(begin: const Offset(0, 0.015), end: Offset.zero)
                  .animate(anim);
          return FadeTransition(
              opacity: anim,
              child: SlideTransition(position: slide, child: child));
        },
        child: LayoutBuilder(
          key: ValueKey(_uiMode),
          builder: (context, c) {
            if (isMobileLayoutOf(c.biggest)) {
              return MobileShell(state: state, shell: shell, pluginState: pluginState, uiMode: _uiMode, onUiModeChanged: _setUiMode);
            }
            if (_uiMode == UiMode.classic) {
              return ClassicShell(state: state, shell: shell, pluginState: pluginState, uiMode: _uiMode, onUiModeChanged: _setUiMode);
            }
            if (_uiMode == UiMode.storyFlow) {
              return StoryFlowShell(state: state, shell: shell, pluginState: pluginState, uiMode: _uiMode, onUiModeChanged: _setUiMode);
            }
            if (_uiMode == UiMode.director) {
              return DirectorShell(state: state, shell: shell, pluginState: pluginState, uiMode: _uiMode, onUiModeChanged: _setUiMode);
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
                          // 品牌蓝 → 当前外观的浅一档
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
                  child: Text(_bootStage,
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
                // C1：超过 20s 仍在等待 → 追加说明与「重试 / 编译并启动后端」，
                // 不再让用户面对一个无法判断的转圈（首帧早已出现，不阻塞交互）。
                if (_slowBoot) ...[
                  const SizedBox(height: 18),
                  FadeSlide(
                    delay: const Duration(milliseconds: 60),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 460),
                      child: Text(
                        '首次启动可能较慢：正在检测 / 启动本地服务，'
                        'dev 构建下首次可能需要编译后端。请稍候，或手动重试。',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            color: palette.textHint, fontSize: 12, height: 1.5),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
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
                                  _slowBoot = false;
                                  _loaded = false;
                                  _loadError = null;
                                });
                                _bootstrap();
                              },
                        child: const Text('重试'),
                      ),
                    ],
                  ),
                ],
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
