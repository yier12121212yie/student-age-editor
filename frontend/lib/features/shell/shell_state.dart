import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/models.dart';
import '../ai/ai_chat_controller.dart';
import '../settings/settings_page.dart';
import '../editor/editor_controller.dart';

/// 左侧面板类型（创作模式的活动栏 / 经典模式的导航列表共用）。
enum SidePane {
  mods,
  pages,
  files,
  resources,
  base,
  bugfix,
  cloud,
  plugins,
  settings,
}

/// 两套布局（创作/经典）共享的界面状态：当前面板、文档标签、AI 面板、
/// 各板块宽度等。提升到应用层持有，切换布局风格时不丢失任何状态。
class ShellState extends ChangeNotifier {
  ShellState({double defaultSidebarWidth = 264.0})
    : _sidebarWidth = defaultSidebarWidth,
      _defaultSidebarWidth = defaultSidebarWidth {
    sidebarWidthV.value = defaultSidebarWidth;
  }

  final EditorController controller = EditorController();

  // ---------------- AI 聊天控制器（应用级单例） ----------------

  AiChatController? _chat;

  /// 共享的 AI 聊天控制器：三个桌面壳与移动端 sheet/全屏使用同一实例，
  /// 切换视图、收起侧栏、底部滑出↔全屏都不再中断在途流式回复与工具审批。
  /// 首次访问以传入的 [appState] 创建（各壳持有同一个 AppState）。
  AiChatController chatControllerFor(AppState appState) =>
      _chat ??= AiChatController(appState: appState, settings: _aiSettings);

  /// 已创建的共享聊天控制器（未创建时为 null，供只读状态展示）。
  AiChatController? get chatOrNull => _chat;

  SidePane _pane = SidePane.mods;
  SidePane get pane => _pane;
  void selectPane(SidePane p) {
    if (_pane == p) return;
    _pane = p;
    // 设置页占据左侧栏时收起 AI 停靠区，避免双开挤压编辑区。
    if (p == SidePane.settings) setAiOpen(false);
    notifyListeners();
  }

  bool _aiOpen = true;
  bool get aiOpen => _aiOpen;
  void toggleAi() => setAiOpen(!_aiOpen);

  /// 当前打开的插件面板（`pluginId/panelId`），null 表示显示插件列表页。
  String? _activePluginPanel;
  String? get activePluginPanel => _activePluginPanel;
  void setActivePluginPanel(String? v) {
    if (_activePluginPanel == v) return;
    _activePluginPanel = v;
    notifyListeners();
  }

  void setAiOpen(bool open) {
    if (_aiOpen == open) return;
    _aiOpen = open;
    notifyListeners();
    _scheduleSaveLayout();
  }

  double _aiWidth = defaultAiWidth;
  double get aiWidth => _aiWidth;
  static const minAiWidth = 280.0;
  static const maxAiWidth = 640.0;
  static const defaultAiWidth = 380.0;

  /// AI 停靠宽度信号：拖拽调宽只经此通知局部重建 AiDock 子树，
  /// 不再 notifyListeners 触发整壳（编辑区/侧栏/状态栏）全树重建。
  final ValueNotifier<double> aiWidthV = ValueNotifier<double>(defaultAiWidth);
  void setAiWidth(double w) {
    final c = w.clamp(minAiWidth, maxAiWidth);
    if (c == _aiWidth) return;
    _aiWidth = c;
    aiWidthV.value = c;
    _scheduleSaveLayout();
  }

  double _sidebarWidth;
  double get sidebarWidth => _sidebarWidth;
  final double _defaultSidebarWidth;
  double get defaultSidebarWidth => _defaultSidebarWidth;
  static const minSidebarWidth = 240.0;
  static const maxSidebarWidth = 520.0;

  /// 左侧栏宽度信号（同 aiWidthV：拖拽局部化）。
  final ValueNotifier<double> sidebarWidthV = ValueNotifier<double>(264.0);
  void setSidebarWidth(double w) {
    final c = w.clamp(minSidebarWidth, maxSidebarWidth);
    if (c == _sidebarWidth) return;
    _sidebarWidth = c;
    sidebarWidthV.value = c;
    _scheduleSaveLayout();
  }

  // ---------------- 布局持久化 ----------------

  static const _layoutKey = 'shell_layout_v1';
  bool _saveLayoutQueued = false;

  /// 启动时恢复上次的 AI 开合与两侧宽度（无记录时保持默认值）。
  Future<void> loadLayout() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_layoutKey);
    if (raw == null || _disposed) return;
    try {
      final j = jsonDecode(raw);
      if (j is! Map) return;
      final open = j['aiOpen'];
      final aiW = (j['aiWidth'] as num?)?.toDouble();
      final sideW = (j['sidebarWidth'] as num?)?.toDouble();
      _aiOpen = open is bool ? open : _aiOpen;
      if (aiW != null) {
        _aiWidth = aiW.clamp(minAiWidth, maxAiWidth);
        aiWidthV.value = _aiWidth;
      }
      if (sideW != null) {
        _sidebarWidth = sideW.clamp(minSidebarWidth, maxSidebarWidth);
        sidebarWidthV.value = _sidebarWidth;
      }
      notifyListeners();
    } catch (_) {
      // 损坏的布局记录直接忽略，用默认值
    }
  }

  /// 合并连续拖拽/切换：同一事件循环轮次内的多次变更只落盘一次。
  /// 用微任务而非 Timer——避免测试环境残留 pending timer。
  void _scheduleSaveLayout() {
    if (_saveLayoutQueued) return;
    _saveLayoutQueued = true;
    Future<void>.microtask(() async {
      _saveLayoutQueued = false;
      if (_disposed) return;
      final prefs = await SharedPreferences.getInstance();
      if (_disposed) return;
      await prefs.setString(
        _layoutKey,
        jsonEncode({
          'aiOpen': _aiOpen,
          'aiWidth': _aiWidth,
          'sidebarWidth': _sidebarWidth,
        }),
      );
    });
  }

  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    aiWidthV.dispose();
    sidebarWidthV.dispose();
    _chat?.dispose();
    super.dispose();
  }

  AiSettings _aiSettings = AiSettings();
  AiSettings get aiSettings => _aiSettings;
  bool settingsLoaded = false;
  void setAiSettings(AiSettings s) {
    // 统一登记最近使用模型：面板快捷切换与设置页手改都会记录（阶段 3c）。
    final m = s.model.trim();
    if (m.isNotEmpty && m != _aiSettings.model.trim()) s.rememberModel(m);
    _aiSettings = s;
    notifyListeners();
  }

  Future<void> loadSettings() async {
    final s = await AiSettings.loadWithRemote();
    _aiSettings = s;
    settingsLoaded = true;
    notifyListeners();
  }
}
