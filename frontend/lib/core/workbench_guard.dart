// 工作台「离开守卫」通用实现。
//
// 背景：导演模式下 12 个专属工作台都以 Offstage 保活，切模式（app.dart
// 按 ValueKey(uiMode) 重建整壳）或切模组时会销毁/重载它们的 State；而它们
// 各自持有整表内存数据与 `_dirty`。此前的 `AppState.leaveGuard` 是单槽，
// 只有剧情画布注册，工作台的未保存修改会被静默丢弃，切模组后还会用旧模组
// 数据覆盖新模组。
//
// 这里提供：
// - [showWorkbenchLeaveDialog]：统一的「保存并切换 / 放弃修改 / 取消」三选；
// - [WorkbenchLeaveGuard] mixin：注册进 AppState 守卫表 + 监听模组切换自动
//   重载。工作台只需暴露已有的 `_dirty` / `_saveAll` / `_discard` / `_loadAll`。
library;

import 'package:flutter/widgets.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;

import 'app_dialogs.dart';
import 'models.dart';

/// 离开脏工作台时用户的选择。
enum WorkbenchLeaveChoice { save, discard }

/// 统一的「有未保存修改」离开确认弹窗。
Future<WorkbenchLeaveChoice?> showWorkbenchLeaveDialog(
  BuildContext context, {
  required String subject,
  required String action,
}) {
  return fluent.showDialog<WorkbenchLeaveChoice>(
    context: context,
    builder: (ctx) => AppContentDialog(
      title: const Text('有未保存的修改'),
      content: Text(
        '$subject有未保存的修改，$action后将丢失。',
        style: const TextStyle(fontSize: 12.5, height: 1.5),
      ),
      actions: [
        fluent.Button(
          onPressed: () => Navigator.pop(ctx, WorkbenchLeaveChoice.discard),
          child: const Text('放弃修改'),
        ),
        fluent.Button(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('取消'),
        ),
        fluent.FilledButton(
          onPressed: () => Navigator.pop(ctx, WorkbenchLeaveChoice.save),
          child: const Text('保存并继续'),
        ),
      ],
    ),
  );
}

/// 工作台离开守卫 mixin。
///
/// 使用方只需实现抽象成员（直接转发到工作台已有的字段/方法即可），并在
/// `State` 上 `with WorkbenchLeaveGuard<自> 身部件类型>`。
///
/// - 脏时：切模式 / 切模组 / 刷新当前视图会弹确认；选择「保存并继续」会
///   先保存，保存失败（仍脏）则中止离开。
/// - 模组切换：切换完成后自动调用 [guardReload] 重载新模组数据（切换前的
///   守卫已由 [AppState.runLeaveGuards] 处理）。
mixin WorkbenchLeaveGuard<T extends StatefulWidget> on State<T> {
  /// 工作台使用的全局状态（通常是 `widget.state`）。
  AppState get guardAppState;

  /// 是否有未保存修改。
  bool get guardDirty;

  /// 保存全部表；完成时若 [guardDirty] 仍为真，视为保存失败。
  Future<void> guardSave();

  /// 放弃内存修改，恢复磁盘快照。
  void guardDiscard();

  /// 重新从磁盘加载（模组切换后调用）。
  Future<void> guardReload();

  /// 提示用主语，如「人物资料」。
  String get guardSubject;

  /// 本 State 加载数据时所属的模组名，用于判定模组是否切换。
  String? _guardMod;

  @override
  void initState() {
    super.initState();
    _guardMod = guardAppState.modName;
    guardAppState.registerLeaveGuard(this, _guardLeave);
    guardAppState.addListener(_onGuardAppStateChanged);
  }

  void _onGuardAppStateChanged() {
    final m = guardAppState.modName;
    if (m == _guardMod) return;
    _guardMod = m;
    // 切模组前的未保存数据已由 _selectMod 的 runLeaveGuards 处理完毕，
    // 这里只需重载新模组的数据。
    if (mounted) guardReload();
  }

  Future<bool> _guardLeave() async {
    if (!mounted || !guardDirty) return true;
    final choice = await showWorkbenchLeaveDialog(
      context,
      subject: guardSubject,
      action: '继续',
    );
    if (!mounted || choice == null) return false;
    if (choice == WorkbenchLeaveChoice.save) {
      await guardSave();
      return !guardDirty;
    }
    guardDiscard();
    return true;
  }

  @override
  void dispose() {
    guardAppState.removeListener(_onGuardAppStateChanged);
    guardAppState.unregisterLeaveGuard(this);
    super.dispose();
  }
}
