// 界面模式「直接选择」弹窗（A1 / N5）。
//
// 背景：状态栏、经典头部、导演头部此前都是 `nextCycle()` 循环切换，文案
// 「切换到 X 布局」含义模糊、要连点 1–3 次才能到目标模式。本文件提供单一
// 入口 [showModePicker]：一次列出四种模式（当前项打勾 + 图标 + 一句话说明），
// 点选即返回目标模式，由调用方经既有 onUiModeChanged 走 runLeaveGuards 切换。
//
// [UiMode.nextCycle] 保留作程序化切换（脚本 / 测试）。
library;

import 'package:flutter/material.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import 'app_dialogs.dart';
import 'app_theme.dart';
import 'ui_mode.dart';

/// 模式图标（与状态栏 / 导演头部口径一致）：画笔 / 列表 / 流程图 / 场记板。
IconData uiModeIcon(UiMode m) => switch (m) {
      UiMode.creation => FluentIcons.paint_brush_24_regular,
      UiMode.classic => FluentIcons.list_24_regular,
      UiMode.storyFlow => FluentIcons.flow_24_regular,
      UiMode.director => FluentIcons.movies_and_tv_24_regular,
    };

/// 模式的一句话说明（选择器里展示，帮助用户区分四种布局）。
String uiModeDescription(UiMode m) => switch (m) {
      UiMode.creation => '图标活动栏 + 侧边栏 + 标签编辑区 + AI 面板',
      UiMode.classic => '传统桌面工具：顶部工具栏 + 左侧分组导航',
      UiMode.storyFlow => '节点画布：事件列表 + 连线编排 + 属性面板',
      UiMode.director => '三栏工作台：对话线 + 舞台编辑 + 人物表情',
    };

/// 弹出模式选择器；返回用户选中的模式（未改变或取消返回 null）。
///
/// 只负责「选」，不负责「切」——切换统一由调用方交给 `onUiModeChanged`
/// （内部会先跑 runLeaveGuards 保护未保存修改）。
Future<UiMode?> showModePicker(BuildContext context, UiMode current) {
  return fluent.showDialog<UiMode>(
    context: context,
    barrierColor: palette.scrim,
    builder: (ctx) => AppContentDialog(
      // 供测试在其中唯一定位模式项：面板外的同名字样（经典头部标签、设置页
      // 的「界面风格」卡片）会让 find.text 命中多个。
      key: const ValueKey('mode-picker'),
      title: const Text('切换界面模式'),
      preferredWidth: 460,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final m in UiMode.values)
            _ModeTile(
              mode: m,
              selected: m == current,
              onTap: () => Navigator.pop(ctx, m == current ? null : m),
            ),
        ],
      ),
      actions: [
        fluent.Button(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('取消'),
        ),
      ],
    ),
  );
}

class _ModeTile extends StatefulWidget {
  const _ModeTile({
    required this.mode,
    required this.selected,
    required this.onTap,
  });

  final UiMode mode;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_ModeTile> createState() => _ModeTileState();
}

class _ModeTileState extends State<_ModeTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final m = widget.mode;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          margin: const EdgeInsets.only(bottom: 6),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: widget.selected
                ? accentColor.withValues(alpha: 0.12)
                : _hover
                    ? palette.card
                    : palette.panel,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
                color: widget.selected ? accentColor : palette.border),
          ),
          child: Row(
            children: [
              Icon(uiModeIcon(m),
                  size: 18,
                  color: widget.selected ? accentColor : palette.textSecondary),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(m.label,
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: palette.textHigh)),
                    const SizedBox(height: 2),
                    Text(uiModeDescription(m),
                        style: TextStyle(
                            fontSize: 11, color: palette.textHint)),
                  ],
                ),
              ),
              if (widget.selected)
                Icon(FluentIcons.checkmark_24_regular,
                    size: 16, color: accentColor),
            ],
          ),
        ),
      ),
    );
  }
}
