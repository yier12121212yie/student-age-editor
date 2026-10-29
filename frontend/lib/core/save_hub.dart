/// UX R3 · W1：全局「当前可保存对象」注册中心。
///
/// 背景：SaveBar 一直显示 `Ctrl+S` 提示，但全局快捷键此前只认壳登记的
/// `AppCommandHost.save`（全仓无人赋值）——提示是假的。这里把「保存当前」
/// 的解析下沉到运行期：SaveBar 在**可见时**把句柄登记进 [SaveHub]，app 层
/// 快捷键按键时现取 [SaveHub.active]。
///
/// 可见性信号复用壳层既有机制：导演壳 Offstage 保活与移动壳 IndexedStack
/// 都以 `TickerMode(enabled: 当前视图)` 表达（见 director_shell/mobile_shell），
/// 隐藏视图不登记、不抢快捷键，无需给 12 个工作台加参数。
library;

import 'package:flutter/widgets.dart';

/// 一个「可保存对象」的句柄。字段全部为惰性闭包：登记后状态变化
/// （dirty/saving/saveBlocked、能否撤销）不需要重新登记。
class SaveHandle {
  SaveHandle({
    required this.debugOwner,
    required this.canSave,
    required this.save,
    this.isEditor = false,
    this.canUndo,
    this.undo,
    this.canRedo,
    this.redo,
  });

  /// 仅供调试/测试标识（如 `SaveBar:人物工作台`）。
  final String debugOwner;

  /// 是否为「编辑区文档」句柄（U1）：文档切换后视图会被重建，放弃是安全的；
  /// 工作台句柄没有 discard 能力，离开守卫不会对它显示「放弃」。
  final bool isEditor;

  /// 当前是否有可保存的修改（且未被阻塞）——决定 Ctrl+S 是真保存还是
  /// 提示「没有可保存的内容」。
  final bool Function() canSave;

  final Future<void> Function() save;

  /// 工作台级撤销/重做（N12）；不支持时为 null。
  final bool Function()? canUndo;
  final Future<void> Function()? undo;
  final bool Function()? canRedo;
  final Future<void> Function()? redo;
}

/// 活动可保存对象的登记栈（LIFO）。
class SaveHub {
  final List<SaveHandle> _stack = <SaveHandle>[];

  /// 当前活动句柄 = 最后登记者（切换视图时新可见的 SaveBar 后登记，
  /// 隐藏者随即注销）。
  SaveHandle? get active => _stack.isEmpty ? null : _stack.last;

  void register(SaveHandle h) {
    _stack.remove(h);
    _stack.add(h);
  }

  void unregister(SaveHandle h) {
    _stack.remove(h);
  }

  @visibleForTesting
  void reset() => _stack.clear();
}

/// 把 [SaveHub] 提供给路由内任意深度的 SaveBar。
///
/// 挂在 `FluentApp.builder`（Navigator 之上）：home、dialog、全屏子页
/// （移动端工作台）都在覆盖范围内。工作台单测直接 pump 时找不到 scope，
/// SaveBar 跳过登记即可（对测试无副作用）。
class SaveHubScope extends InheritedWidget {
  const SaveHubScope({super.key, required this.hub, required super.child});

  final SaveHub hub;

  static SaveHub? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<SaveHubScope>()?.hub;

  @override
  bool updateShouldNotify(SaveHubScope oldWidget) =>
      !identical(oldWidget.hub, hub);
}
