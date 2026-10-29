// A2 全局快捷键：Ctrl/Cmd+K 命令面板、Ctrl/Cmd+S 保存当前、Ctrl/Cmd+F 剧情库检索。
//
// 挂载位置：`FluentApp.builder` 之下、壳之上——**必须**在 Navigator 之下，
// 命令才能用宿主的 context 直接 `showDialog` / 弹 InfoBar；同时因为它在所有
// 焦点节点之上，按键事件从任意焦点向上冒泡都必然经过这里（无需给输入框留
// 特例：Ctrl+S/K/F 都不是文本编辑快捷键，文本框不会吃掉它们）。
//
// 唯一的坑：若首帧时焦点停在**路由 FocusScope**（本子树的祖先）上，事件向上
// 冒泡就绕过了这里。故 [_AppShortcutsState] 在首帧后兜底把焦点收进本子树，
// 但已有控件（编辑区自动聚焦的输入框）持有焦点时不抢。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_command.dart';
import 'app_feedback.dart';
import 'command_palette.dart';
import 'error_text.dart';

/// 意图（Intent）：把「按了哪个组合键」与「做什么」解耦，便于测试断言与后续
/// 让工作台自行接管（如 A3 的保存条控制器）。
class CommandPaletteIntent extends Intent {
  const CommandPaletteIntent();
}

class SaveCurrentIntent extends Intent {
  const SaveCurrentIntent();
}

class StorySearchIntent extends Intent {
  const StorySearchIntent();
}

/// 全局快捷键宿主。`enabled=false` 时原样返回 child（启动加载页 / 引导页
/// 不该抢走按键）。
class AppShortcuts extends StatefulWidget {
  const AppShortcuts({
    super.key,
    required this.child,
    required this.enabled,
    required this.commands,
    this.onSave,
    this.onSearch,
    this.onUndo,
    this.onRedo,
  });

  final Widget child;

  final bool enabled;

  /// 打开命令面板时现取命令（模组列表等可变数据因此始终是最新的一份）。
  ///
  /// 传入的 [BuildContext] 位于 Navigator/Overlay 之下（因此有 MediaQuery 与
  /// Overlay），宿主可安全地用它判断窄屏 / 弹提示。
  final List<AppCommand> Function(BuildContext context) commands;

  /// 保存当前：由 app 层提供（按键时现取活动工作台的 [SaveHandle]，其次
  /// 壳登记的 `AppCommandHost.save`）。返回 `false` 表示当前界面没有可保存
  /// 的内容，本组件统一提示「当前界面没有可保存的内容」，让用户确认快捷键
  /// 已生效而非失灵；`null` 视为 false。
  final Future<bool> Function()? onSave;

  /// 打开「剧情库检索」。
  final VoidCallback? onSearch;

  /// 撤销当前（N12）：同 [onSave]，按键时现取活动工作台的撤销栈。
  /// 返回 `false`（无可撤销内容）静默——与文本框内 Ctrl+Z 的行为一致。
  final Future<bool> Function()? onUndo;

  /// 重做当前（N12）。
  final Future<bool> Function()? onRedo;

  @override
  State<AppShortcuts> createState() => _AppShortcutsState();
}

class _AppShortcutsState extends State<AppShortcuts> {
  final FocusNode _root = FocusNode(
    debugLabel: 'AppShortcuts',
    skipTraversal: true,
  );
  bool _grabbed = false;

  static const Map<ShortcutActivator, Intent> _shortcuts =
      <ShortcutActivator, Intent>{
    SingleActivator(LogicalKeyboardKey.keyK,
        control: true, includeRepeats: false): CommandPaletteIntent(),
    SingleActivator(LogicalKeyboardKey.keyK,
        meta: true, includeRepeats: false): CommandPaletteIntent(),
    SingleActivator(LogicalKeyboardKey.keyS,
        control: true, includeRepeats: false): SaveCurrentIntent(),
    SingleActivator(LogicalKeyboardKey.keyS,
        meta: true, includeRepeats: false): SaveCurrentIntent(),
    SingleActivator(LogicalKeyboardKey.keyF,
        control: true, includeRepeats: false): StorySearchIntent(),
    SingleActivator(LogicalKeyboardKey.keyF,
        meta: true, includeRepeats: false): StorySearchIntent(),
  };

  @override
  void initState() {
    super.initState();
    _scheduleFocusGrab();
  }

  @override
  void didUpdateWidget(covariant AppShortcuts oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.enabled && widget.enabled) _scheduleFocusGrab();
  }

  @override
  void dispose() {
    _root.dispose();
    super.dispose();
  }

  void _scheduleFocusGrab() {
    if (_grabbed || !widget.enabled) return;
    _grabbed = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!_focusInside()) _root.requestFocus();
    });
  }

  /// 主焦点是否已经在「本子树」内：是则事件冒泡必然经过 [Shortcuts]，
  /// 不必抢焦点（避免踩掉编辑区/工作台的自动聚焦）。
  bool _focusInside() {
    var node = FocusManager.instance.primaryFocus;
    while (node != null) {
      if (identical(node, _root)) return true;
      node = node.parent;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    return Shortcuts(
      shortcuts: _shortcuts,
      child: Actions(
        actions: <Type, Action<Intent>>{
          CommandPaletteIntent:
              CallbackAction<CommandPaletteIntent>(onInvoke: (_) {
            unawaited(_openPalette());
            return null;
          }),
          SaveCurrentIntent: CallbackAction<SaveCurrentIntent>(onInvoke: (_) {
            unawaited(_save());
            return null;
          }),
          StorySearchIntent: CallbackAction<StorySearchIntent>(onInvoke: (_) {
            widget.onSearch?.call();
            return null;
          }),
        },
        child: Focus(focusNode: _root, onKeyEvent: _onRootKeyEvent, child: widget.child),
      ),
    );
  }

  /// Ctrl/Cmd+Z、Ctrl+Y、Ctrl+Shift+Z（N12 撤销/重做）。
  ///
  /// 不放进 Shortcuts 映射表：那会遮蔽文本框自身的 Ctrl+Z（本子树在
  /// DefaultTextEditingShortcuts 之内，先于它收到按键）。改在这里手判——
  /// 焦点在文本输入内时原样放行（`ignored`），让文本撤销栈先消费；
  /// 工作台/编辑区自带的更深 Shortcuts 本就先于这里收到事件，不受影响。
  KeyEventResult _onRootKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final keys = HardwareKeyboard.instance;
    if (!keys.isControlPressed && !keys.isMetaPressed) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    final wantUndo = key == LogicalKeyboardKey.keyZ && !keys.isShiftPressed;
    final wantRedo = (key == LogicalKeyboardKey.keyZ && keys.isShiftPressed) ||
        key == LogicalKeyboardKey.keyY;
    if (!wantUndo && !wantRedo) return KeyEventResult.ignored;
    if (_focusInTextField()) return KeyEventResult.ignored;
    final handler = wantUndo ? widget.onUndo : widget.onRedo;
    if (handler == null) return KeyEventResult.ignored;
    unawaited(_runHistory(handler));
    return KeyEventResult.handled;
  }

  /// 主焦点是否落在文本输入控件内（EditableText 的祖先链上）。
  bool _focusInTextField() {
    final ctx = FocusManager.instance.primaryFocus?.context;
    return ctx != null &&
        ctx.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  Future<void> _runHistory(Future<bool> Function() handler) async {
    try {
      // false = 没有可撤销/重做的内容：静默（与文本内 Ctrl+Z 一致）。
      await handler();
    } catch (e) {
      final ctx = _root.context;
      if (ctx != null && ctx.mounted) {
        AppFeedback.error(ctx, humanizeErrorMessage(e), detail: e.toString());
      }
    }
  }

  Future<void> _openPalette() async {
    final ctx = _root.context;
    if (ctx == null || !ctx.mounted) return;
    // 用本子树的 context 现取命令：它位于 MediaQuery / Overlay 之下，
    // 宿主据此判断窄屏（手机宽度不生成左侧栏面板类动作）不会踩断言。
    final commands = widget.commands(ctx);
    final picked = await showCommandPalette(ctx, commands);
    if (picked == null || !mounted) return;
    try {
      await picked.run(ctx);
    } catch (e) {
      // 必须用本子树 context 的 mounted，而非 State 的（lint: guarded by an
      // unrelated 'mounted' check）——ctx 可能已随子树卸载，State 仍存活。
      if (ctx.mounted) {
        AppFeedback.error(ctx, humanizeErrorMessage(e), detail: e.toString());
      }
    }
  }

  Future<void> _save() async {
    final handler = widget.onSave;
    var handled = false;
    if (handler != null) {
      try {
        handled = await handler();
      } catch (e) {
        final ctx = _root.context;
        if (ctx != null && ctx.mounted) {
          AppFeedback.error(ctx, humanizeErrorMessage(e), detail: e.toString());
        }
        return;
      }
    }
    if (!handled) {
      final ctx = _root.context;
      if (ctx != null && ctx.mounted) {
        AppFeedback.info(ctx, '当前界面没有可保存的内容');
      }
    }
  }
}
