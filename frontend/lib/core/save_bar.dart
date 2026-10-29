/// 统一工作台底部「保存条」(A3.3)。
///
/// 12 个工作台此前各自实现一份保存条,文案 `有未保存的修改 / 已与磁盘同步`
/// 复制了 12 遍(加剧情等共 17 处),按钮组也各写各的。此处统一为一个组件:
/// 左侧状态点 + 文案,右侧「检索剧情库 / 放弃修改 / 保存修改」,并统一显示
/// `Ctrl+S` 提示。
///
/// 组件只做展示与回调,不持有业务状态:脏/保存中/是否可检索由参数传入。
/// 渲染之外它还负责一件事(UX R3 · W1):在**可见时**把「保存当前」句柄
/// 登记进 [SaveHub],让全局 `Ctrl+S` 真正落到当前工作台——壳层用
/// `TickerMode(enabled: 当前视图)` 表达可见性(导演壳 Offstage 保活、
/// 移动壳 IndexedStack),隐藏视图不会抢快捷键。
library;

import 'package:fluent_ui/fluent_ui.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart' as fui;

import 'app_theme.dart';
import 'app_dialogs.dart';
import 'design_tokens.dart';
import 'motion.dart';
import 'save_hub.dart';
import 'shortcut_labels.dart';
import 'workbench_controller.dart';

/// 统一的「有未保存的修改」文案 —— A3 起全项目仅此一处定义。
const String kUnsavedLabel = '有未保存的修改';
const String kSyncedLabel = '已与磁盘同步';

/// 工作台底部保存条。
class SaveBar extends StatefulWidget {
  const SaveBar({
    super.key,
    required this.dirty,
    required this.onSave,
    required this.onDiscard,
    this.saving = false,
    this.onOpenSearch,
    this.history,
    this.saveLabel = '保存修改',
    this.showShortcutHint = true,
    this.saveBlocked = false,
  });

  /// 是否有未保存修改(决定状态点颜色与按钮可用性)。
  final bool dirty;

  /// 保存中(显示进度环并禁用按钮)。
  final bool saving;

  /// 保存回调;`dirty == false || saving` 时按钮禁用。返回的 Future 供全局
  /// `Ctrl+S` 等待保存完成(按钮点击路径不关心它)。
  final Future<void> Function() onSave;

  /// 放弃修改回调。
  final VoidCallback onDiscard;

  /// 非空时显示「检索剧情库」按钮。
  final VoidCallback? onOpenSearch;

  /// 工作台历史（N12）：非空时条上出现「撤销 / 重做」按钮，并把能力一并
  /// 登记进 [SaveHub]（全局 Ctrl+Z / Ctrl+Y 可用）。为空则完全不显示。
  final WorkbenchController? history;

  final String saveLabel;

  /// 是否在保存按钮旁提示 `Ctrl+S`。
  final bool showShortcutHint;

  /// 额外阻塞保存(如 JSON 解析失败)。为 `true` 时保存按钮禁用。
  final bool saveBlocked;

  @override
  State<SaveBar> createState() => _SaveBarState();
}

class _SaveBarState extends State<SaveBar> {
  SaveHub? _hub;
  SaveHandle? _handle;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final hub = SaveHubScope.maybeOf(context);
    // TickerMode 是壳层「本视图当前可见」的既有信号（导演壳 Offstage 保活、
    // 移动壳 IndexedStack 均用它表达）；隐藏的保存条不得抢全局 Ctrl+S。
    final visible = TickerMode.valuesOf(context).enabled;
    if (!identical(hub, _hub)) {
      _unregister();
      _hub = hub;
    }
    if (visible) {
      _register();
    } else {
      _unregister();
    }
  }

  /// U2：「放弃修改」紧挨保存键，误点一次会丢掉整场编辑。先确认；放弃后
  /// 控制器会把放弃前快照压入撤销栈（Ctrl+Z 可恢复），所以文案不夸大。
  Future<void> _confirmDiscard() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AppContentDialog(
        title: const Text('放弃修改'),
        content: const Text(
          '当前内存中的修改将全部撤销，恢复到磁盘上的版本。\n'
          '放弃后仍可用「撤销」找回。',
          style: TextStyle(fontSize: AppText.subhead, height: 1.5),
        ),
        actions: [
          Button(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('放弃修改'),
          ),
        ],
      ),
    );
    if (ok == true && mounted) widget.onDiscard();
  }

  void _register() {
    final hub = _hub;
    if (hub == null || _handle != null) return;
    final history = widget.history;
    final handle = SaveHandle(
      debugOwner: 'SaveBar',
      canSave: () =>
          widget.dirty && !widget.saving && !widget.saveBlocked,
      save: () async {
        await widget.onSave();
      },
      canUndo: history == null ? null : () => history.canUndo,
      undo: history == null ? null : () async { history.undo(); },
      canRedo: history == null ? null : () => history.canRedo,
      redo: history == null ? null : () async { history.redo(); },
    );
    _handle = handle;
    hub.register(handle);
  }

  void _unregister() {
    final hub = _hub;
    final handle = _handle;
    if (hub == null || handle == null) return;
    hub.unregister(handle);
    _handle = null;
  }

  @override
  void dispose() {
    _unregister();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 保存条内容变化稀疏（仅在脏/保存中切换时），用 RepaintBoundary 与其上方
    // 频繁重绘的列表/编辑区隔离开，避免被连带重绘。
    return RepaintBoundary(
      child: Container(
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpace.l, vertical: AppSpace.s10),
        decoration: BoxDecoration(
          color: palette.panel,
          border: Border(top: BorderSide(color: palette.border)),
        ),
        child: LayoutBuilder(
          builder: (context, c) {
            // 撤销/重做图标按钮在窄条（手机编辑页 ~360）下会挤出溢出：窄于
            // 阈值时收起按钮（快捷键 Ctrl+Z/Y 在桌面仍然可用）。
            final showHistory = widget.history != null && c.maxWidth >= 460;
            return Row(
              children: [
                Icon(
                  widget.dirty ? fui.FluentIcons.circle_24_filled : fui.FluentIcons.checkmark_circle_24_regular,
                  size: 12,
                  color: widget.dirty ? palette.statusWarn : palette.statusOk,
                ),
                const SizedBox(width: AppSpace.s6),
                // 窄面板(如移动端右栏)下允许状态文案先被压缩，避免溢出。
                Flexible(
                  child: Text(
                    widget.dirty ? kUnsavedLabel : kSyncedLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: AppText.caption,
                        color: palette.textSecondary),
                  ),
                ),
                const SizedBox(width: AppSpace.s),
                const Spacer(),
                if (showHistory) ...[
                  _HistoryButton(
                    undo: true,
                    enabled: widget.history!.canUndo,
                    onTap: widget.history!.undo,
                  ),
                  const SizedBox(width: AppSpace.xxs),
                  _HistoryButton(
                    undo: false,
                    enabled: widget.history!.canRedo,
                    onTap: widget.history!.redo,
                  ),
                  const SizedBox(width: AppSpace.s),
                ],
                if (widget.onOpenSearch != null) ...[
                  WorkbenchMiniButton(label: '检索剧情库', onTap: widget.onOpenSearch!),
                  const SizedBox(width: AppSpace.s),
                ],
                WorkbenchMiniButton(
                  label: '放弃修改',
                  enabled: widget.dirty && !widget.saving,
                  onTap: _confirmDiscard,
                ),
                const SizedBox(width: AppSpace.s),
                FilledButton(
                  onPressed: (!widget.dirty || widget.saving || widget.saveBlocked)
                      ? null
                      : widget.onSave,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (widget.saving)
                        const SizedBox(
                          width: 12,
                          height: 12,
                          child: ProgressRing(strokeWidth: 2),
                        )
                      else
                        const Icon(fui.FluentIcons.save_24_regular, size: 13),
                      const SizedBox(width: AppSpace.s6),
                      Text(widget.saveLabel,
                          style: const TextStyle(fontSize: AppText.subhead)),
                      if (widget.showShortcutHint && !widget.saving) ...[
                        const SizedBox(width: AppSpace.s),
                        Text(
                          saveShortcutLabel,
                          style: TextStyle(
                            fontSize: AppText.dense,
                            color: palette.textHint,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// 保存条上的撤销/重做图标按钮（N12）：窄条下比文字按钮省宽度。
class _HistoryButton extends StatefulWidget {
  const _HistoryButton({
    required this.undo,
    required this.enabled,
    required this.onTap,
  });

  /// true = 撤销，false = 重做。
  final bool undo;
  final bool enabled;
  final VoidCallback onTap;

  @override
  State<_HistoryButton> createState() => _HistoryButtonState();
}

class _HistoryButtonState extends State<_HistoryButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final color =
        widget.enabled ? palette.textPrimary : palette.iconDisabled;
    return Tooltip(
      message: widget.undo ? undoTooltipLabel : redoTooltipLabel,
      child: MouseRegion(
        cursor: widget.enabled
            ? SystemMouseCursors.click
            : SystemMouseCursors.basic,
        onEnter: (_) {
          if (widget.enabled) setState(() => _hover = true);
        },
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.enabled ? widget.onTap : null,
          child: AnimatedContainer(
            duration: AppMotion.fast,
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: _hover && widget.enabled ? palette.card : Colors.transparent,
              borderRadius: BorderRadius.circular(AppRadius.m),
              border: Border.all(
                color:
                    _hover && widget.enabled ? palette.border : Colors.transparent,
              ),
            ),
            child: Icon(
              widget.undo
                  ? fui.FluentIcons.arrow_undo_24_regular
                  : fui.FluentIcons.arrow_redo_24_regular,
              size: 14,
              color: color,
            ),
          ),
        ),
      ),
    );
  }
}

/// 保存条上的次级按钮(原各工作台私有 `_MiniBtn` 的公共版)。
class WorkbenchMiniButton extends StatefulWidget {
  const WorkbenchMiniButton({
    super.key,
    required this.label,
    required this.onTap,
    this.enabled = true,
    this.danger = false,
  });

  final String label;
  final VoidCallback onTap;
  final bool enabled;
  final bool danger;

  @override
  State<WorkbenchMiniButton> createState() => _WorkbenchMiniButtonState();
}

class _WorkbenchMiniButtonState extends State<WorkbenchMiniButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final color = !widget.enabled
        ? palette.iconDisabled
        : widget.danger
            ? palette.statusDanger
            : palette.textPrimary;
    return MouseRegion(
      cursor:
          widget.enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.enabled ? widget.onTap : null,
        child: AnimatedContainer(
          duration: AppMotion.fast,
          padding: const EdgeInsets.symmetric(
              horizontal: AppSpace.s10, vertical: AppSpace.s6),
          decoration: BoxDecoration(
            color: _hover && widget.enabled ? palette.card : palette.bgAlt,
            borderRadius: BorderRadius.circular(AppRadius.m),
            border: Border.all(
              color: widget.danger && widget.enabled
                  ? palette.statusDanger.withValues(alpha: 0.35)
                  : palette.border,
            ),
          ),
          child: Text(
            widget.label,
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: AppText.caption, color: color),
          ),
        ),
      ),
    );
  }
}
