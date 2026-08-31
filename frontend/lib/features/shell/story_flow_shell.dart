import 'package:flutter/material.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import '../../core/app_theme.dart';
import '../../core/models.dart';
import '../../core/plugin_state.dart';
import '../../core/ui_mode.dart';
import '../ai/ai_panel.dart';
import '../base/base_search_page.dart';
import '../bugfix/bugfix_panel.dart';
import '../cloud/cloud_page.dart';
import '../editor/editor_controller.dart';
import '../editor/schema_editor_view.dart';
import '../files/file_tree_page.dart';
import '../files/file_viewer.dart';
import '../mods/mods_page.dart';
import '../pages/pages_catalog.dart';
import '../pages/page_view.dart';
import '../plugins/plugin_pane.dart';
import '../plugins/plugins_page.dart';
import '../preview/event_preview_view.dart';
import '../resources/resources_page.dart';
import '../settings/settings_page.dart';
import '../story/story_flow_top_tabs.dart';
import '../story/story_flow_workspace.dart';
import 'shell_state.dart';
import 'shell_widgets.dart';
import 'status_bar.dart';

/// 剧情图模式外壳：满幅画布为体，顶部常驻标签条切页面（浏览器式），
/// 左侧浮动工具栏（添加节点/媒体资产/AI/插件/设置）在画布内提供。
///
/// 顶部标签条覆盖一个懒加载保活的内容栈：切走再切回不丢画布/未保存状态。
/// 文档标签（cfg/file/page/preview）来自 [EditorController]，动态出现在
/// 标签条上；「运行预览」在剧情图模式内直接打开 preview 标签。
class StoryFlowShell extends StatefulWidget {
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
  State<StoryFlowShell> createState() => _StoryFlowShellState();
}

class _StoryFlowShellState extends State<StoryFlowShell> {
  /// 当前展示的视图（graph 为画布首页）。
  StoryFlowView _view = StoryFlowView.graph;

  /// 曾经激活过的视图索引（懒加载保活：未访问的视图不实例化）。
  final Set<int> _visited = {StoryFlowView.graph.index};

  void _setView(StoryFlowView v) {
    setState(() {
      _view = v;
      _visited.add(v.index);
    });
  }

  void _openDoc(OpenDoc doc) {
    widget.shell.controller.open(doc);
    _setView(StoryFlowView.doc);
  }

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
        listenable: widget.shell,
        builder: (context, _) => Column(
          children: [
            Expanded(
              child: Stack(
                children: [
                  // 懒加载保活内容栈：未访问视图不构建，已访问的保持状态。
                  // 标签条常驻悬浮在顶上（margin 6 + 高 42），
                  // 内容（含画布）统一让出这 50px。
                  Positioned.fill(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 50),
                      child: _contentStack(),
                    ),
                  ),
                  // AI 侧栏（右侧停靠，让出常驻标签条的高度）
                  Positioned(right: 0, top: 50, bottom: 0, child: _aiDock()),
                  // 顶部常驻标签条
                  StoryFlowTopTabs(
                    view: _view,
                    controller: widget.shell.controller,
                    onView: _setView,
                    onSelectDoc: (i) {
                      final docs = widget.shell.controller.docs;
                      if (i < 0 || i >= docs.length) return;
                      _openDoc(docs[i]);
                    },
                    onCloseDoc: (i) {
                      widget.shell.controller.close(i);
                      if (widget.shell.controller.docs.isEmpty) {
                        setState(() => _view = StoryFlowView.graph);
                      }
                    },
                  ),
                ],
              ),
            ),
            StatusBar(
              state: widget.state,
              onToggleAi: widget.shell.toggleAi,
              uiMode: widget.uiMode,
              onUiModeChanged: widget.onUiModeChanged,
            ),
          ],
        ),
      ),
    );
  }

  // ---------- 视图栈 ----------
  Widget _contentStack() {
    final children = <Widget>[];
    for (var i = 0; i < StoryFlowView.values.length; i++) {
      if (_visited.contains(i)) {
        children.add(Positioned.fill(
          child: Offstage(
            offstage: i != _view.index,
            child: _childFor(i),
          ),
        ));
      }
    }
    return Stack(fit: StackFit.expand, children: children);
  }

  Widget _childFor(int i) {
    final view = StoryFlowView.values[i];
    switch (view) {
      case StoryFlowView.graph:
        return StoryFlowWorkspace(
          key: const ValueKey('view-graph'),
          state: widget.state,
          onPreview: _openDocWithPreview,
          aiOpen: widget.shell.aiOpen,
          onToggleAi: widget.shell.toggleAi,
          onOpenPlugins: () => _setView(StoryFlowView.plugins),
          onOpenSettings: () => _setView(StoryFlowView.settings),
        );
      case StoryFlowView.pages:
        return _StoryFlowPagesView(
          key: const ValueKey('view-pages'),
          state: widget.state,
          onPreview: _openDocWithPreview,
        );
      case StoryFlowView.files:
        return FileTreePage(
          key: const ValueKey('view-files'),
          state: widget.state,
          controller: widget.shell.controller,
        );
      case StoryFlowView.resources:
        return ResourcesPage(
          key: const ValueKey('view-resources'),
          state: widget.state,
        );
      case StoryFlowView.base:
        return BaseSearchPage(
          key: const ValueKey('view-base'),
          state: widget.state,
        );
      case StoryFlowView.cloud:
        return CloudPage(
          key: const ValueKey('view-cloud'),
          state: widget.state,
        );
      case StoryFlowView.plugins:
        return _pluginsView();
      case StoryFlowView.settings:
        return SettingsPage(
          key: const ValueKey('view-settings'),
          settings: widget.shell.settingsLoaded
              ? widget.shell.aiSettings
              : AiSettings(),
          onChanged: widget.shell.setAiSettings,
          uiMode: widget.uiMode,
          onUiModeChanged: widget.onUiModeChanged,
        );
      case StoryFlowView.mods:
        return ModsPage(
          key: const ValueKey('view-mods'),
          state: widget.state,
          controller: widget.shell.controller,
        );
      case StoryFlowView.bugfix:
        return BugfixPanel(
          key: const ValueKey('view-bugfix'),
          state: widget.state,
        );
      case StoryFlowView.doc:
        return _DocView(
          key: const ValueKey('view-doc'),
          state: widget.state,
          controller: widget.shell.controller,
          onPreview: _openDocWithPreview,
        );
    }
  }

  void _openDocWithPreview(String evtId) =>
      _openDoc(OpenDoc.preview(eventId: evtId));

  /// AI 侧栏停靠层：折叠时仅剩一条可滑出边框的动画容器（与旧壳一致）。
  Widget _aiDock() {
    final shell = widget.shell;
    return AnimatedContainer(
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
                          // 侧栏悬浮在画布之上：AiPanel 本体无底板，
                          // 必须自带不透明背景，否则节点/连线透出（与经典壳一致）
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: ColoredBox(
                              color: palette.panel,
                              child: AiPanel(
                                state: widget.state,
                                settings: shell.settingsLoaded
                                    ? shell.aiSettings
                                    : AiSettings(),
                                onChanged: shell.setAiSettings,
                                onOpenSettings: () =>
                                    _setView(StoryFlowView.settings),
                              ),
                            ),
                          ),
                        ),
                      ],
                    )
                  : const SizedBox.shrink(),
            ),
          ),
        ),
      ),
    );
  }

  /// 插件面板视图：activePluginPanel 非空时显示对应用面板，否则显示列表。
  Widget _pluginsView() {
    return ListenableBuilder(
      listenable: widget.shell,
      builder: (context, _) {
        final active = widget.shell.activePluginPanel;
        if (active == null || active.trim().isEmpty) {
          return PluginsPage(
              key: const ValueKey('view-plugins'),
              pluginState: widget.pluginState);
        }
        final parts = active.split('/');
        if (parts.isEmpty || parts.first.isEmpty) {
          return PluginsPage(
              key: const ValueKey('view-plugins'),
              pluginState: widget.pluginState);
        }
        return PluginPane(
          key: ValueKey('panel-$active'),
          pluginId: parts.first,
          panelId: parts.length > 1 ? parts.sublist(1).join('/') : '',
          onClosed: () => widget.shell.setActivePluginPanel(null),
        );
      },
    );
  }
}

/// 文档标签内容（cfg/file/page/preview），与 EditorArea 的内容分发一致，
/// 但不带标签栏（标签条在顶部 StoryFlowTopTabs）。
class _DocView extends StatelessWidget {
  const _DocView({
    super.key,
    required this.state,
    required this.controller,
    required this.onPreview,
  });

  final AppState state;
  final EditorController controller;
  final ValueChanged<String> onPreview;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final doc = controller.current;
        if (doc == null) {
          return const Center(
            child: Text('没有打开的文档\n\n打开文件/预览后会在顶部标签条出现',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: Color(0xFF8B8B93))),
          );
        }
        if (doc.kind == 'cfg') {
          return SchemaEditorView(
            key: ValueKey(doc),
            state: state,
            cfgName: doc.cfgName,
            onPreview: onPreview,
          );
        }
        if (doc.kind == 'page') {
          final page = pageById(doc.pageId);
          if (page != null) {
            return EditorPageView(
              key: ValueKey(doc),
              state: state,
              page: page,
              onPreview: onPreview,
            );
          }
        }
        if (doc.kind == 'preview') {
          return EventPreviewView(
            key: ValueKey(doc),
            state: state,
            controller: controller,
            eventId: doc.eventId,
          );
        }
        return FileViewer(
          key: ValueKey(doc),
          state: state,
          path: doc.path,
          title: doc.title,
        );
      },
    );
  }
}

/// 「编辑页面」标签：左侧页面列表 + 右侧编辑页（复刻经典模式导航的入口形态）。
class _StoryFlowPagesView extends StatefulWidget {
  const _StoryFlowPagesView({
    super.key,
    required this.state,
    required this.onPreview,
  });

  final AppState state;
  final ValueChanged<String> onPreview;

  @override
  State<_StoryFlowPagesView> createState() => _StoryFlowPagesViewState();
}

class _StoryFlowPagesViewState extends State<_StoryFlowPagesView> {
  String _pageId = 'story';

  @override
  Widget build(BuildContext context) {
    final page = pageById(_pageId);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          width: 200,
          decoration: BoxDecoration(
            color: palette.panel,
            border: Border(right: BorderSide(color: palette.border)),
          ),
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: editorPages.length,
            itemBuilder: (context, i) {
              final p = editorPages[i];
              final sel = p.id == _pageId;
              return InkWell(
                onTap: () => setState(() => _pageId = p.id),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: sel
                        ? const Color(0xFF6C5CE7).withValues(alpha: 0.14)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  margin:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        p.title,
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight:
                              sel ? FontWeight.w600 : FontWeight.normal,
                          color: sel ? palette.textHigh : palette.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        p.description,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 10.5, color: palette.textHint),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
        VerticalDivider(width: 1, color: palette.border),
        Expanded(
          child: page == null
              ? const SizedBox.shrink()
              : EditorPageView(
                  state: widget.state,
                  page: page,
                  onPreview: widget.onPreview,
                ),
        ),
      ],
    );
  }
}