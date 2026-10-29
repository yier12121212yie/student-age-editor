// A2 命令面板（Ctrl+K）：模糊搜索并执行 [AppCommand]。
//
// - 数据来源是「当前壳登记的命令集合」（由 `buildAppCommands` 现场从
//   `pages_catalog` / `workshop_features` / `UiMode` / `AppState.mods` 生成），
//   本文件不维护任何清单；
// - 只负责「选中哪条命令」，执行交给调用方用宿主 context 完成——这样命令
//   自己 push 的路由（如模式选择器）不会与面板的 pop 打架。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import 'app_command.dart';
import 'app_theme.dart';

/// 模糊过滤：空查询原样返回；命中按得分降序、同分按标题排序。
///
/// 匹配规则（够用即可，不引入依赖）：先试子串命中（位置越靠前分越高），
/// 失败再试「顺序子序列」（跨度越短分越高）；多词以空格分隔，需全部命中。
List<AppCommand> filterCommands(List<AppCommand> all, String query) {
  final q = query.trim();
  if (q.isEmpty) return all;
  final tokens = q.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
  final scored = <(int, AppCommand)>[];
  for (final c in all) {
    var total = 0;
    var ok = true;
    for (final t in tokens) {
      final s = _fuzzy(c.searchText, t);
      if (s == null) {
        ok = false;
        break;
      }
      total += s;
    }
    if (ok) scored.add((total, c));
  }
  scored.sort((a, b) {
    final byScore = b.$1.compareTo(a.$1);
    if (byScore != 0) return byScore;
    return a.$2.label.compareTo(b.$2.label);
  });
  return [for (final e in scored) e.$2];
}

int? _fuzzy(String haystack, String needle) {
  final h = haystack.toLowerCase();
  final n = needle.toLowerCase();
  if (n.isEmpty) return 0;
  final idx = h.indexOf(n);
  if (idx >= 0) return 1000 - (idx > 900 ? 900 : idx);
  var cursor = 0;
  var first = -1;
  var last = 0;
  for (var i = 0; i < n.length; i++) {
    final found = h.indexOf(n[i], cursor);
    if (found < 0) return null;
    if (first < 0) first = found;
    last = found;
    cursor = found + 1;
  }
  final span = last - first;
  return 500 - (span > 400 ? 400 : span);
}

/// 弹出命令面板；用户选中返回该命令，取消返回 null。
Future<AppCommand?> showCommandPalette(
  BuildContext context,
  List<AppCommand> commands,
) {
  if (commands.isEmpty) return Future<AppCommand?>.value();
  final screen = MediaQuery.sizeOf(context);
  final width = math.min(560.0, screen.width - 32);
  final height = math.min(440.0, screen.height * 0.66);
  return fluent.showDialog<AppCommand>(
    context: context,
    barrierDismissible: true,
    barrierColor: palette.scrim,
    builder: (ctx) => Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.all(16),
      child: Container(
        key: const ValueKey('command-palette'),
        width: width,
        height: height,
        decoration: BoxDecoration(
          color: palette.panel,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: palette.border),
        ),
        clipBehavior: Clip.antiAlias,
        child: _CommandPaletteView(commands: commands),
      ),
    ),
  );
}

class _CommandPaletteView extends StatefulWidget {
  const _CommandPaletteView({required this.commands});

  final List<AppCommand> commands;

  @override
  State<_CommandPaletteView> createState() => _CommandPaletteViewState();
}

class _CommandPaletteViewState extends State<_CommandPaletteView> {
  static const double _rowHeight = 46;

  late final TextEditingController _query = TextEditingController();
  late final FocusNode _field = FocusNode(debugLabel: 'CommandPaletteField');
  final ScrollController _scroll = ScrollController();
  late List<AppCommand> _results = widget.commands;
  int _index = 0;

  @override
  void initState() {
    super.initState();
    // 文本框会把 ↑/↓/Enter 吃成 DoNothingAndStopPropagationTextIntent，
    // 上层的 Shortcuts 收不到；这里挂在**文本框自己的** FocusNode 上，先于
    // 文本编辑快捷键拿到按键。
    _field.onKeyEvent = _onKey;
  }

  @override
  void dispose() {
    _query.dispose();
    _field.dispose();
    _scroll.dispose();
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final k = event.logicalKey;
    if (k == LogicalKeyboardKey.arrowDown) {
      _move(1);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowUp) {
      _move(-1);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.numpadEnter) {
      _pick();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _onQueryChanged(String value) {
    setState(() {
      _results = filterCommands(widget.commands, value);
      _index = 0;
    });
    _revealSelection();
  }

  void _move(int delta) {
    if (_results.isEmpty) return;
    setState(() {
      _index = (_index + delta) % _results.length;
      if (_index < 0) _index += _results.length;
    });
    _revealSelection();
  }

  void _pick() {
    if (_results.isEmpty) return;
    Navigator.of(context).pop(_results[_index]);
  }

  void _revealSelection() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final view = _scroll.position;
      final top = _index * _rowHeight;
      final bottom = top + _rowHeight;
      if (top < view.pixels) {
        _scroll.jumpTo(top);
      } else if (bottom > view.pixels + view.viewportDimension) {
        _scroll.jumpTo(bottom - view.viewportDimension);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
          child: Row(
            children: [
              Icon(FluentIcons.search_24_regular,
                  size: 16, color: palette.textSecondary),
              const SizedBox(width: 10),
              Expanded(
                child: fluent.TextBox(
                  controller: _query,
                  focusNode: _field,
                  autofocus: true,
                  placeholder: '搜索功能 / 页面 / 模组 / 模式 / 动作',
                  onChanged: _onQueryChanged,
                ),
              ),
            ],
          ),
        ),
        Divider(height: 1, color: palette.border),
        Expanded(
          child: _results.isEmpty
              ? Center(
                  child: Text(
                    '没有匹配的命令',
                    style: TextStyle(fontSize: 12.5, color: palette.textMuted),
                  ),
                )
              : ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  itemExtent: _rowHeight,
                  itemCount: _results.length,
                  itemBuilder: (context, i) => _CommandRow(
                    command: _results[i],
                    selected: i == _index,
                    onTap: () {
                      setState(() => _index = i);
                      _pick();
                    },
                  ),
                ),
        ),
        Divider(height: 1, color: palette.border),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 7, 14, 7),
          child: Row(
            children: [
              Text(
                '↑↓ 选择 · Enter 执行 · Esc 关闭',
                style: TextStyle(fontSize: 11, color: palette.textMuted),
              ),
              const Spacer(),
              Text(
                '${_results.length} 项',
                style: TextStyle(fontSize: 11, color: palette.textMuted),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _CommandRow extends StatefulWidget {
  const _CommandRow({
    required this.command,
    required this.selected,
    required this.onTap,
  });

  final AppCommand command;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_CommandRow> createState() => _CommandRowState();
}

class _CommandRowState extends State<_CommandRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = widget.command;
    final active = widget.selected || _hover;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 6),
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: active ? palette.card : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            children: [
              Icon(
                c.icon ?? FluentIcons.chevron_right_24_regular,
                size: 16,
                color: widget.selected ? accentColor : palette.textSecondary,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      c.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.5,
                        color: palette.textPrimary,
                        fontWeight: widget.selected
                            ? FontWeight.w600
                            : FontWeight.normal,
                      ),
                    ),
                    if (c.description.isNotEmpty)
                      Text(
                        c.description,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          color: palette.textMuted,
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: palette.bgDeep2,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  c.category.label,
                  style: TextStyle(fontSize: 10.5, color: palette.textSecondary),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
