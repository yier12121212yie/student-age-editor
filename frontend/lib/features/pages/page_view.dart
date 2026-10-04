import 'package:flutter/material.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../../core/models.dart';
import '../../core/responsive.dart';
import '../editor/cfg_display_names.dart';
import '../editor/schema_editor_view.dart';
import '../story/story_director_view.dart';
import '../story/story_list_mobile_page.dart';
import 'manifest_card.dart';
import 'classic_page_layouts.dart';
import 'pages_catalog.dart';
import '../../core/app_theme.dart';

/// 编辑页面视图：页面说明 + 配置表选择 + schema 驱动编辑器。
class EditorPageView extends StatefulWidget {
  const EditorPageView({
    super.key,
    required this.state,
    required this.page,
    this.onPreview,
    this.onOpenSearch,
    this.classic = false,
  });
  final AppState state;
  final EditorPageDef page;

  /// 事件预览回调：page 为故事且 cfg 为 EvtCfg 时携带当前条目 ID 触发。
  final ValueChanged<String>? onPreview;

  /// 剧情库检索回调（透传给内部编辑器）。
  final VoidCallback? onOpenSearch;

  /// 经典布局：内部编辑器以卡片形式呈现。
  final bool classic;
  @override
  State<EditorPageView> createState() => _PageViewState();
}

class _PageViewState extends State<EditorPageView> {
  late String _cfg;

  @override
  void initState() {
    super.initState();
    _cfg = widget.page.defaultCfg;
  }

  @override
  void didUpdateWidget(covariant EditorPageView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 宿主若不带 key 复用本 State（如同位置直接换 page），配置表必须跟随
    // 页面重置，否则新页面渲染的是上一个页面的表（页面"长得一模一样"）。
    if (widget.page.id != oldWidget.page.id) {
      _cfg = widget.page.defaultCfg;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Icon(
                FluentIcons.table_24_regular,
                size: 16,
                color: accentColor,
              ),
              const SizedBox(width: 10),
              Text(
                widget.page.title,
                style: TextStyle(
                  fontSize: 14,
                  color: palette.textHigh,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 12),
              // 移动端空间紧张：隐藏描述、压缩下拉框宽度，避免固定宽度溢出
              if (!isMobileWidth(context)) ...[
                Expanded(
                  child: Text(
                    widget.page.description,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: palette.textMuted,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
              ],
              Text(
                '配置表',
                style: TextStyle(fontSize: 12, color: palette.textMuted),
              ),
              const SizedBox(width: 8),
              // 注意：Row 给子项无界宽度约束，isExpanded: true 的 ComboBox 内部用
              // Expanded 需要有限宽度，直接放 Row 中会触发布局断言（编辑区黑屏）。
              SizedBox(
                width: isMobileWidth(context) ? 130 : 200,
                child: fluent.ComboBox<String>(
                  value: _cfg,
                  isExpanded: true,
                  items: [
                    for (final name in widget.page.cfgNames)
                      fluent.ComboBoxItem(
                        value: name,
                        child: Text(
                          cfgDisplayName(name),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: (v) {
                    if (v != null) setState(() => _cfg = v);
                  },
                ),
              ),
            ],
          ),
        ),
        Divider(height: 1, color: palette.border),
        if (widget.page.id == 'official') ManifestStatusCard(),
        Expanded(
          child: widget.classic
              ? ClassicPageLayouts(
                  key: ValueKey('${widget.page.id}:$_cfg'),
                  state: widget.state,
                  page: widget.page,
                  cfgName: _cfg,
                  onPreview: widget.onPreview,
                  onOpenSearch: widget.onOpenSearch,
                )
              : widget.page.id == 'story'
              ? (isMobileWidth(context)
                  ? StoryListMobilePage(
                      // 跟随当前选中模组（此前写死 mods 第一个：切换模组后
                      // 列表仍显示旧模组数据）；换模组由页面 didUpdateWidget 重载。
                      key: const ValueKey('story-list-mobile'),
                      modName: widget.state.modName,
                    )
                  // 桌面故事页默认进导演视图；一旦用「配置表」下拉选了别的表，
                  // 就切到该表的 schema 编辑器（bug #13：此前下拉只改标签）。
                  : (_cfg == widget.page.defaultCfg
                      ? StoryDirectorView(
                          key: const ValueKey('story-director'),
                          state: widget.state,
                          onPreview: widget.onPreview,
                        )
                      : SchemaEditorView(
                          key: ValueKey('story:$_cfg'),
                          state: widget.state,
                          cfgName: _cfg,
                          onPreview: _cfg == 'EvtCfg' ? widget.onPreview : null,
                          onOpenSearch: widget.onOpenSearch,
                        )))
              : SchemaEditorView(
                  key: ValueKey('${widget.page.id}:$_cfg'),
                  state: widget.state,
                  cfgName: _cfg,
                  onPreview: _cfg == 'EvtCfg' ? widget.onPreview : null,
                  onOpenSearch: widget.onOpenSearch,
                ),
        ),
      ],
    );
  }
}


