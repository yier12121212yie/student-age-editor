import 'package:flutter/foundation.dart';

import '../settings/settings_page.dart';
import '../editor/editor_controller.dart';

/// 左侧面板类型（创作模式的活动栏 / 经典模式的导航列表共用）。
enum SidePane { mods, pages, files, resources, base, bugfix, cloud, plugins, settings }

/// 两套布局（创作/经典）共享的界面状态：当前面板、文档标签、AI 面板、
/// 各板块宽度等。提升到应用层持有，切换布局风格时不丢失任何状态。
class ShellState extends ChangeNotifier {
  ShellState({double defaultSidebarWidth = 264.0})
      : _sidebarWidth = defaultSidebarWidth,
        _defaultSidebarWidth = defaultSidebarWidth;

  final EditorController controller = EditorController();

  SidePane _pane = SidePane.mods;
  SidePane get pane => _pane;
  void selectPane(SidePane p) {
    if (_pane == p) return;
    _pane = p;
    if (p == SidePane.settings) _aiOpen = false;
    notifyListeners();
  }

  bool _aiOpen = true;
  bool get aiOpen => _aiOpen;
  void toggleAi() {
    _aiOpen = !_aiOpen;
    notifyListeners();
  }

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
  }

  double _aiWidth = 380;
  double get aiWidth => _aiWidth;
  static const minAiWidth = 280.0;
  static const maxAiWidth = 640.0;
  static const defaultAiWidth = 380.0;
  void setAiWidth(double w) {
    _aiWidth = w.clamp(minAiWidth, maxAiWidth);
    notifyListeners();
  }

  double _sidebarWidth;
  double get sidebarWidth => _sidebarWidth;
  final double _defaultSidebarWidth;
  double get defaultSidebarWidth => _defaultSidebarWidth;
  static const minSidebarWidth = 240.0;
  static const maxSidebarWidth = 520.0;
  void setSidebarWidth(double w) {
    _sidebarWidth = w.clamp(minSidebarWidth, maxSidebarWidth);
    notifyListeners();
  }

  AiSettings _aiSettings = AiSettings();
  AiSettings get aiSettings => _aiSettings;
  bool settingsLoaded = false;
  void setAiSettings(AiSettings s) {
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
