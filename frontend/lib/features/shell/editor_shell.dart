import 'package:flutter/material.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import '../../core/models.dart';
import '../../core/plugin_state.dart';
import '../../core/ui_mode.dart';
import '../../core/motion.dart';
import '../ai/ai_panel.dart';
import '../settings/settings_page.dart';
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
        listenable: shell,
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
                  // 侧边栏宽度平滑跟手
                  AnimatedContainer(
                    duration: AppMotion.fast,
                    curve: AppMotion.easeOut,
                    width: shell.sidebarWidth,
                    child: SidePaneView(
                      pane: shell.pane,
                      state: state,
                      shell: shell,
                      pluginState: pluginState,
                      controller: shell.controller,
                      aiSettings: shell.aiSettings,
                      onAiChanged: shell.setAiSettings,
                      width: shell.sidebarWidth,
                      uiMode: uiMode,
                      onUiModeChanged: onUiModeChanged,
                    ),
                  ),
                  ResizeHandle(
                    width: shell.sidebarWidth,
                    min: ShellState.minSidebarWidth,
                    max: ShellState.maxSidebarWidth,
                    defaultWidth: shell.defaultSidebarWidth,
                    onChanged: shell.setSidebarWidth,
                  ),
                  Expanded(
                    child: EditorArea(state: state, controller: shell.controller),
                  ),
                  // AI 面板：宽度 + 透明度 + 位移动画
                  AnimatedContainer(
                    duration: AppMotion.normal,
                    curve: AppMotion.easeOut,
                    width: shell.aiOpen ? shell.aiWidth + 5 : 0,
                    child: ClipRect(
                      child: OverflowBox(
                        alignment: Alignment.centerRight,
                        maxWidth: shell.aiWidth + 5,
                        minWidth: shell.aiWidth + 5,
                        child: AnimatedOpacity(
                          duration: AppMotion.normal,
                          curve: AppMotion.easeOut,
                          opacity: shell.aiOpen ? 1 : 0,
                          child: AnimatedSlide(
                            duration: AppMotion.normal,
                            curve: AppMotion.easeOut,
                            offset: shell.aiOpen ? Offset.zero : const Offset(0.08, 0),
                            child: shell.aiOpen
                                ? Row(
                                    children: [
                                      ResizeHandle(
                                        width: shell.aiWidth,
                                        min: ShellState.minAiWidth,
                                        max: ShellState.maxAiWidth,
                                        defaultWidth: ShellState.defaultAiWidth,
                                        inverted: true,
                                        onChanged: shell.setAiWidth,
                                      ),
                                      SizedBox(
                                        width: shell.aiWidth,
                                        child: AiPanel(
                                          state: state,
                                          settings: shell.settingsLoaded ? shell.aiSettings : AiSettings(),
                                          onChanged: shell.setAiSettings,
                                          onOpenSettings: () => shell.selectPane(SidePane.settings),
                                        ),
                                      ),
                                    ],
                                  )
                                : const SizedBox.shrink(),
                          ),
                        ),
                      ),
                    ),
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
