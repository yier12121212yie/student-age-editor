// 编辑区「未保存修改」离开守卫（U1）。
//
// 背景：页签点击已有守卫，但左侧页面列表 / 文件树 / 命令面板 / 导演壳 /
// 配置表下拉都直接调用 `EditorController.open()` 或重建编辑器，导致静默
// 丢弃内存改动。这里把守卫收敛成一处：
//   - 脏信号：调用方传入的 [isDirty]（EditorController 的页签脏集合）+
//     [SaveHub.active]（当前可见编辑器 / 工作台登记的句柄）；
//   - 保存：优先用调用方传入的 [save]，否则用 SaveHub 活动句柄；
//   - 放弃：调用方传入 [onDiscard]（编辑器会清掉页签脏标记；视图随后被
//     AnimatedSwitcher 销毁）。
//
// 不引入新依赖：弹窗、反馈、SaveHub 都是既有基础设施。

import 'package:flutter/widgets.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;

import '../features/editor/editor_controller.dart';
import 'app_dialogs.dart';
import 'design_tokens.dart';
import 'save_hub.dart';

/// 离开脏编辑器前确认。返回 true 表示可以继续（已保存或已放弃）。
///
/// [action] 只用于按钮文案（如「切换文档」「切换配置表」）。
/// [isDirty] 额外脏信号（页签脏集合）；[onDiscard] 非空时提供「放弃」选项。
/// [allowDiscard] 为 false 时即使有 [onDiscard] 也不显示放弃（保守场景）。
Future<bool> confirmLeaveDirty(
  BuildContext context, {
  required String action,
  bool Function()? isDirty,
  VoidCallback? onDiscard,
  bool allowDiscard = true,
  Future<void> Function()? save,
}) async {
  final hub = SaveHubScope.maybeOf(context);
  final handle = hub?.active;
  final hubDirty = handle?.canSave() ?? false;
  final dirty = hubDirty || (isDirty?.call() ?? false);
  if (!dirty) return true;

  final canSave = save != null || hubDirty;
  // 只有「编辑器」句柄可以安全地放弃（视图会被重建）；工作台句柄没有
  // discard 能力，放弃按钮会把整场未保存修改一起丢掉。
  final canDiscard = onDiscard != null &&
      allowDiscard &&
      (!hubDirty || (handle?.isEditor ?? false));

  final choice = await fluent.showDialog<String>(
    context: context,
    builder: (ctx) => AppContentDialog(
      title: const Text('有未保存的修改'),
      content: Text(
        '当前内容有未保存的修改，$action后将丢失。',
        style: const TextStyle(fontSize: AppText.subhead, height: 1.5),
      ),
      actions: [
        fluent.Button(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('取消'),
        ),
        if (canDiscard)
          fluent.Button(
            onPressed: () => Navigator.pop(ctx, 'discard'),
            child: Text('放弃并$action'),
          ),
        if (canSave)
          fluent.FilledButton(
            onPressed: () => Navigator.pop(ctx, 'save'),
            child: Text('保存并$action'),
          ),
      ],
    ),
  );

  if (choice == 'save') {
    try {
      if (save != null) {
        await save();
      } else {
        await handle!.save();
      }
    } catch (_) {
      // 保存实现本身负责向用户报错；这里只保证异常不炸掉入口回调，
      // 并保持原页面（不切换）。
      return false;
    }
    // 保存失败 / 保存期间又有新编辑：保持原页面，不继续切换。
    return !(handle?.canSave() ?? false) && !(isDirty?.call() ?? false);
  }
  if (choice == 'discard') {
    onDiscard?.call();
    return true;
  }
  return false;
}

/// 打开文档前守卫。五个外部入口（页面列表 / 文件树 / 命令面板 / 导演壳 /
/// 预览「编辑」）统一走这里，避免再出现「点了另一页，改动没了」。
Future<bool> openDocGuarded(
  BuildContext context,
  EditorController controller,
  OpenDoc next, {
  String action = '切换文档',
}) async {
  final current = controller.current;
  // 同一文档重复打开（比如页签点击）不弹窗。
  if (current == next) return true;
  final ok = await confirmLeaveDirty(
    context,
    action: action,
    isDirty: () => current != null && controller.isDirty(current),
    onDiscard: current == null
        ? null
        : () => controller.markDirty(current, false),
  );
  if (!ok) return false;
  controller.open(next);
  return true;
}
