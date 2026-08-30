import 'package:flutter/material.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import '../../core/models.dart';
import '../../core/plugin_state.dart';
import '../../core/ui_mode.dart';
import '../ai/ai_panel.dart';
import '../editor/editor_controller.dart';
import '../settings/settings_page.dart';
import '../story/story_flow_workspace.dart';
import 'activity_bar.dart';
import 'shell_state.dart';
import 'shell_widgets.dart';
import 'status_bar.dart';

/// 剧情图模式外壳：与创作壳同构（活动栏 + 侧栏 + AI 面板 + 状态栏），
/// 中央编辑区替换为流程图画布工作区。
class StoryFlowShell extends StatelessWidget {
  const StoryFlowShell({
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
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 120),
                    curve: Curves.easeOut,
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
                    // 剧情图工作区：事件列表 + 流程图画布 + 节点编辑
                    child: StoryFlowWorkspace(
                      state: state,
                      onPreview: (evtId) => shell.controller
                          .open(OpenDoc.preview(eventId: evtId)),
                    ),
                  ),
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    curve: Curves.easeOut,
                    width: shell.aiOpen ? shell.aiWidth + 5 : 0,
                    child: ClipRect(
                      child: OverflowBox(
                        alignment: Alignment.centerRight,
                        maxWidth: shell.aiWidth + 5,
                        minWidth: shell.aiWidth + 5,
                        child: AnimatedOpacity(
                          duration: const Duration(milliseconds: 150),
                          curve: Curves.easeOut,
                          opacity: shell.aiOpen ? 1 : 0,
                          child: AnimatedSlide(
                            duration: const Duration(milliseconds: 150),
                            curve: Curves.easeOut,
                            offset: shell.aiOpen
                                ? Offset.zero
                                : const Offset(0.08, 0),
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
                                          settings: shell.settingsLoaded
                                              ? shell.aiSettings
                                              : AiSettings(),
                                          onChanged: shell.setAiSettings,
                                          onOpenSettings: () => shell
                                              .selectPane(SidePane.settings),
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