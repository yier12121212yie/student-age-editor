import 'package:flutter/material.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;

import '../../core/models.dart';
import '../../core/plugin_state.dart';
import '../../core/ui_mode.dart';
import '../../core/motion.dart';
import 'ai_dock.dart';
import 'activity_bar.dart';
import 'editor_area.dart';
import 'shell_state.dart';
import 'shell_widgets.dart';
import 'status_bar.dart';

class CreationShell extends StatelessWidget {
  const CreationShell({
    super.key,
    required this.state,
    required this.shell,
    required this.pluginState,
    required this.uiMode,
    required this.onUiModeChanged,
  });
  final AppState state;
  final ShellState shell;
  final PluginState pluginState;
  final UiMode uiMode;
  final ValueChanged<UiMode> onUiModeChanged;

  @override
  Widget build(BuildContext context) {
    return fluent.FluentTheme(
      data: fluent.FluentTheme.of(context).copyWith(
        typography: const fluent.Typography.raw(
          body: TextStyle(fontSize: 13, fontFamily: 'Microsoft YaHei'),
          caption: TextStyle(fontSize: 12, fontFamily: 'Microsoft YaHei'),
        ),
      ),
      child: ListenableBuilder(
        // 也要听 pluginState：install/uninstall/reload 后 uiPanels 变化需重建
        // ActivityBar，冷启动时 refresh 完成也要在此触发。
        listenable: Listenable.merge([shell, pluginState]),
        builder: (context, _) => Column(
          children: [
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ActivityBar(
                    current: shell.pane,
                    aiOpen: shell.aiOpen,
                    onSelect: shell.selectPane,
                    onToggleAi: shell.toggleAi,
                    shell: shell,
                    pluginState: pluginState,
                  ),
                  // 侧边栏宽度平滑跟手（拖拽只重建此子树，阶段 1 局部化）
                  ValueListenableBuilder<double>(
                    valueListenable: shell.sidebarWidthV,
                    builder: (context, sidebarWidth, _) => Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        AnimatedContainer(
                          duration: AppMotion.fast,
                          curve: AppMotion.easeOut,
                          width: sidebarWidth,
                          child: SidePaneView(
                            pane: shell.pane,
                            state: state,
                            shell: shell,
                            pluginState: pluginState,
                            controller: shell.controller,
                            aiSettings: shell.aiSettings,
                            onAiChanged: shell.setAiSettings,
                            width: sidebarWidth,
                            uiMode: uiMode,
                            onUiModeChanged: onUiModeChanged,
                          ),
                        ),
                        ResizeHandle(
                          width: sidebarWidth,
                          min: ShellState.minSidebarWidth,
                          max: ShellState.maxSidebarWidth,
                          defaultWidth: shell.defaultSidebarWidth,
                          onChanged: shell.setSidebarWidth,
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: EditorArea(
                      state: state,
                      controller: shell.controller,
                    ),
                  ),
                  // AI 面板：共享停靠组件（拖宽/折叠条/持久化统一处理）
                  AiDock(
                    state: state,
                    shell: shell,
                    onOpenSettings: () => shell.selectPane(SidePane.settings),
                  ),
                ],
              ),
            ),
            StatusBar(
              state: state,
              onToggleAi: shell.toggleAi,
              uiMode: uiMode,
              onUiModeChanged: onUiModeChanged,
            ),
          ],
        ),
      ),
    );
  }
}
