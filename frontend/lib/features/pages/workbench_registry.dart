// 页面 → 专属工作台 的**权威映射表**（B2）。
//
// 背景：导演壳把「功能」硬编码成一串工作台构造器（`_childFor`），而移动端
// 「页面」tab 与桌面「编辑页面」列表只认通用 SchemaEditorView——同一份
// 「哪些页面有专属工作台」的知识散在多处，容易漂移。本文件集中这张表：
//   * 页面 id → 工作台构造器（[kWorkbenchRegistry]）；
//   * 移动端「页面」tab 与桌面「编辑页面」列表经 [workbenchEntryForPage] 判定；
//   * 导演壳对重叠的功能（人物 / 社交 / 事件）也走本表构造，避免两处各写一遍。
//
// 说明：导演壳另有若干**无对应页面 id** 的功能（空间 / 仓库 / 目标 / 手机消息 /
// 外部对话 / 闲聊 / 积木库 / JSON），它们是导演布局独有的入口，不在本表内。
library;

import 'package:flutter/widgets.dart';

import '../../core/models.dart';
import '../events/event_workbench.dart';
import '../json/json_workbench.dart';
import '../messages/messages_workbench.dart';
import '../minigames/minigames_workbench.dart';
import '../person/person_workbench.dart';
import '../social/social_workbench.dart';
import '../story/story_studio_editor.dart';

/// 构造工作台所需的公共依赖。缺省回调退化为「不做任何跳转」的空实现，
/// 保证在移动端 / 桌面列表等没有完整壳回调的上下文里也能构造出可用工作台。
class WorkbenchDeps {
  const WorkbenchDeps({
    required this.state,
    this.onOpenSearch,
    this.onPreview,
    this.onOpenStudio,
  });

  final AppState state;

  /// 打开「剧情库检索」（缺省无操作）。
  final VoidCallback? onOpenSearch;

  /// 打开事件预览（缺省无操作）。
  final void Function(String eventId)? onPreview;

  /// 打开「剧情舞台」（缺省无操作）。
  final VoidCallback? onOpenStudio;
}

/// 一条「页面 → 工作台」映射。
class WorkbenchEntry {
  const WorkbenchEntry({
    required this.pageId,
    required this.title,
    required this.build,
  });

  /// 对应 [EditorPageDef.id]（pages_catalog.dart）。
  final String pageId;

  /// 工作台标题（移动端子页 AppBar / 工具提示）。
  final String title;

  final Widget Function(WorkbenchDeps deps) build;
}

/// 权威映射表：页面 id → 专属工作台。
final Map<String, WorkbenchEntry> kWorkbenchRegistry = {
  'person': WorkbenchEntry(
    pageId: 'person',
    title: '人物工作台',
    build: (d) => PersonWorkbench(
      state: d.state,
      onPreview: d.onPreview,
      onOpenSearch: d.onOpenSearch,
    ),
  ),
  'evt': WorkbenchEntry(
    pageId: 'evt',
    title: '事件工作台',
    build: (d) => EventWorkbench(
      state: d.state,
      onOpenSearch: d.onOpenSearch,
      onOpenStudio: d.onOpenStudio,
    ),
  ),
  'social': WorkbenchEntry(
    pageId: 'social',
    title: '社交动态',
    build: (d) => SocialWorkbench(
      state: d.state,
      onOpenSearch: d.onOpenSearch,
    ),
  ),
  'function': WorkbenchEntry(
    pageId: 'function',
    title: '小游戏库',
    build: (d) => MinigamesWorkbench(
      state: d.state,
      onOpenSearch: d.onOpenSearch,
    ),
  ),
  'story': WorkbenchEntry(
    pageId: 'story',
    title: '剧情工作台',
    build: (d) => StoryStudioEditor(
      state: d.state,
      onPreview: d.onPreview,
    ),
  ),
  // 供导演壳 / 其它入口按「工作台名」取用（这些没有独立页面 id）。
  'messages': WorkbenchEntry(
    pageId: 'messages',
    title: '手机消息',
    build: (d) => MessagesWorkbench(
      state: d.state,
      onOpenSearch: d.onOpenSearch,
    ),
  ),
  'json': WorkbenchEntry(
    pageId: 'json',
    title: '高级编辑器',
    build: (d) => JsonWorkbench(
      state: d.state,
      onOpenSearch: d.onOpenSearch,
    ),
  ),
};

/// 页面 id 是否有专属工作台（无则返回 null）。
WorkbenchEntry? workbenchEntryForPage(String pageId) => kWorkbenchRegistry[pageId];
