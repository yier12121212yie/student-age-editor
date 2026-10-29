// 工作台三栏布局的统一骨架（N2 + N8）。
//
// 背景：12 个专属工作台此前各写一套 `LayoutBuilder` + 魔法数——断点
// 980 / 1000 / 1040 / 1080 混用，左栏 188–350、右栏 262–350 各不相同；
// 且低于阈值时**直接把右栏整块丢掉**，导致窄窗（720–1000）下「设置 / 预览」
// 无法打开。
//
// [WorkbenchScaffold] 统一为：
// - 宽布局（≥ [WorkbenchLayout.sideBreakpoint]）：左栏 + 中栏 + 右栏并排；
// - 中窄布局（≥ [WorkbenchLayout.mobileBreakpoint]）：右栏收成右侧常驻图标条
//   （rail），点击以浮层抽屉展开，**能力不丢**；
// - 窄屏（< [WorkbenchLayout.mobileBreakpoint]，即手机宽度）：改为「主从形态」——
//   列表铺满、编辑页 push 进入（系统返回逐级退出）、右栏内容改为编辑页底部
//   「设置」入口（`showModalBottomSheet`，92% 屏高）。一次改骨架，12 个工作台
//   同时获得手机可用的基础形态。
// - 尺寸全部取自 [WorkbenchLayout] token，各工作台不再自带断点与栏宽。
//
// 左右栏以 builder 传入：builder 接收本骨架计算出的宽度，内部仍可沿用
// 既有的 `_leftPanel(double w)` / `_rightPanel(double w)`（其内部 `width: w`
// 与本骨架的 SizedBox 一致）。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import 'app_dialogs.dart';
import 'app_feedback.dart';
import 'app_theme.dart';
import 'design_tokens.dart';
import 'error_text.dart';
import 'mobile_widgets.dart';
import 'motion.dart';
import 'responsive.dart';
import 'workbench_controller.dart';

/// 工作台加载状态（C4）：把「加载中 / 出错 / 就绪」三态统一到骨架层。
///
/// 背景：12 个专属工作台此前各写一套 `if (_loading)`/`if (_error != null)`
/// 页面——图标、字号、按钮文案各不相同，错误文案直接把 `API 409: …` 原样
/// 丢给用户。现在改为在骨架入口处按状态渲染统一的骨架屏 / 错误面板，
/// 各工作台只负责把状态报上来。
enum WorkbenchStatus {
  /// 首次加载：渲染统一骨架屏（[WorkbenchSkeleton]）。
  loading,

  /// 加载失败：渲染统一错误面板（人性化文案 + 重试 + 复制详情）。
  error,

  /// 就绪：渲染正常三栏/主从布局。
  ready,
}

/// 工作台布局尺寸 token（单一来源）。
class WorkbenchLayout {
  WorkbenchLayout._();

  /// 低于此宽度：右栏从并排改为收进右侧浮层抽屉（而不是直接丢弃）。
  /// 桌面壳在宽度 ≥720 时可用，因此这是常见窗口宽度下的关键阈值。
  static const double sideBreakpoint = 1000;

  /// 低于此宽度：改用「窄屏主从形态」（列表铺满 + 底部操作条，编辑/设置以
  /// 全高底部滑出层展开）。复用 [Breakpoints.mobile]（720），不新造断点。
  static const double mobileBreakpoint = Breakpoints.mobile;

  /// 宽档起始宽度：达到后左/右栏切到更宽档位。
  static const double wideBreakpoint = 1320;

  static const double leftNarrow = 240;
  static const double leftWide = 300;
  static const double rightNarrow = 300;
  static const double rightWide = 340;

  /// 窄布局下右侧常驻图标条宽度。
  static const double railWidth = 36;

  static double leftWidth(double maxWidth) =>
      maxWidth >= wideBreakpoint ? leftWide : leftNarrow;

  static double rightWidth(double maxWidth) =>
      maxWidth >= wideBreakpoint ? rightWide : rightNarrow;
}

/// 保存冲突（HTTP 409）的统一弹窗：重新加载（放弃该表本地未保存的改动）/
/// 强制覆盖 / 取消。
///
/// 12 个工作台此前各自复制了同一份 28 行弹窗代码（约 280 行重复）；文案或
/// 按钮顺序一旦漂移，就会出现「有的工作台只能重载、有的能强覆盖」的不一致。
/// 集中到这里后，工作台只需把 [WorkbenchController.onConflict] 指过来。
Future<WorkbenchConflictChoice?> showWorkbenchConflictDialog(
  BuildContext context,
  WorkbenchTable table,
) {
  return fluent.showDialog<WorkbenchConflictChoice>(
    context: context,
    builder: (ctx) => AppContentDialog(
      title: const Text('文件冲突'),
      content: Text(
        '${table.cfg} 已被外部修改（可能被游戏或其他端改写）。\n'
        '重新加载将放弃本地未保存的修改；强制覆盖将用当前编辑内容覆盖磁盘文件。',
        style: TextStyle(
            fontSize: AppText.subhead, color: palette.textPrimary, height: 1.5),
      ),
      actions: [
        fluent.Button(
          onPressed: () => Navigator.pop(ctx, WorkbenchConflictChoice.reload),
          child: const Text('重新加载'),
        ),
        fluent.FilledButton(
          onPressed: () => Navigator.pop(ctx, WorkbenchConflictChoice.force),
          child: const Text('强制覆盖'),
        ),
      ],
    ),
  );
}

/// 工作台三栏骨架。左/右栏用 builder，宽度由骨架按 token 决定。
///
/// C4：可选传 [status] / [error] / [onRetry]，骨架会在 loading / error 时
/// 短路渲染统一骨架屏或错误面板，工作台不必再各写一套。
class WorkbenchScaffold extends StatefulWidget {
  const WorkbenchScaffold({
    super.key,
    required this.leftBuilder,
    required this.center,
    required this.rightBuilder,
    required this.rightLabel,
    this.rightIcon = FluentIcons.settings_24_regular,
    this.mobileTitle,
    this.mobileEditorLabel = '打开编辑',
    this.status = WorkbenchStatus.ready,
    this.error,
    this.onRetry,
    this.errorTitle,
    this.skeletonRows = 8,
  });

  /// 左栏（列表 / 目录）。参数为本骨架分配的宽度。
  final Widget Function(double width) leftBuilder;

  /// 中栏（编辑 / 预览主区）。
  final Widget center;

  /// 右栏（设置 / 概览 / 预览）。窄布局下收进浮层抽屉。
  final Widget Function(double width) rightBuilder;

  /// 右栏名称：窄布局 rail 的 tooltip 与浮层标题。
  final String rightLabel;

  final IconData rightIcon;

  /// 窄屏（<720）下 push 出来的编辑页标题。缺省「编辑」。
  final String? mobileTitle;

  /// 窄屏列表页底部动作条上「进入编辑」的文案。缺省「打开编辑」。
  final String mobileEditorLabel;

  /// 加载状态（C4）。缺省 [WorkbenchStatus.ready]，即维持旧行为。
  final WorkbenchStatus status;

  /// [WorkbenchStatus.error] 时的原始异常（交给 [humanizeError] 人性化）。
  final Object? error;

  /// [WorkbenchStatus.error] 时「重试」按钮的回调；null 则不显示按钮。
  final VoidCallback? onRetry;

  /// [WorkbenchStatus.error] 时的标题文案。缺省「数据加载失败」。
  final String? errorTitle;

  /// [WorkbenchStatus.loading] 时骨架屏占位行数。
  final int skeletonRows;

  @override
  State<WorkbenchScaffold> createState() => _WorkbenchScaffoldState();
}

class _WorkbenchScaffoldState extends State<WorkbenchScaffold> {
  bool _open = false;

  /// 窄屏编辑页是否已 push。编辑页是独立 route，工作台 `setState` 不会重建它，
  /// 故需在脚手架重建时把最新的 `center` 推给它（否则编辑页是「快照」，改字段
  /// 不刷新、保存条永远停在进页那一刻的禁用态 → 移动端根本存不了盘）。B3。
  bool _editorOpen = false;
  bool _sheetOpen = false;
  final ValueNotifier<int> _editorRev = ValueNotifier<int>(0);

  @override
  void dispose() {
    _editorRev.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 编辑页 / 设置滑出层打开时：每次脚手架重建（= 工作台 setState）后，通知
    // 这些独立 route 用最新内容重绘一次。放 post-frame，避免 build 期间
    // markNeedsBuild 报错。
    if (_editorOpen || _sheetOpen) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _editorRev.value = _editorRev.value + 1;
      });
    }

    // C4：加载 / 出错两态在骨架层短路。窄屏同样适用（列表本身还没数据）。
    if (widget.status != WorkbenchStatus.ready) {
      return Container(
        color: palette.bgDeep2,
        child: widget.status == WorkbenchStatus.loading
            ? WorkbenchSkeleton(rows: widget.skeletonRows)
            : WorkbenchErrorPanel(
                error: widget.error,
                title: widget.errorTitle,
                onRetry: widget.onRetry,
              ),
      );
    }

    return Container(
      color: palette.bgDeep2,
      child: LayoutBuilder(
        builder: (context, box) {
          final w = box.maxWidth;

          // 窄屏（手机宽度/横屏手机）：主从形态。列表铺满，编辑页与右栏都改为
          // 「进入」的二级页 / 滑出层，横排三栏不再可行。
          if (isMobileLayoutOf(
              Size(w, MediaQuery.sizeOf(context).height))) {
            return _buildMobile(w);
          }

          final docked = w >= WorkbenchLayout.sideBreakpoint;
          final leftW = WorkbenchLayout.leftWidth(w);
          final rightW = WorkbenchLayout.rightWidth(w);

          if (docked) {
            return Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(width: leftW, child: widget.leftBuilder(leftW)),
                VerticalDivider(width: 1, color: palette.border),
                Expanded(child: widget.center),
                VerticalDivider(width: 1, color: palette.border),
                SizedBox(width: rightW, child: widget.rightBuilder(rightW)),
              ],
            );
          }

          // 中窄布局：右栏收进浮层，宽度不超过可用宽度的 92%。
          final overlayW = math.min(rightW, w * 0.92);
          return Stack(
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(width: leftW, child: widget.leftBuilder(leftW)),
                  VerticalDivider(width: 1, color: palette.border),
                  Expanded(child: widget.center),
                  _RightRail(
                    icon: widget.rightIcon,
                    label: widget.rightLabel,
                    active: _open,
                    onTap: () => setState(() => _open = !_open),
                  ),
                ],
              ),
              if (_open) ...[
                // 遮罩：点空白处收起；给 rail 让出宽度，点 rail 也能收起。
                Positioned.fill(
                  right: WorkbenchLayout.railWidth,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => setState(() => _open = false),
                    child: ColoredBox(color: palette.scrim),
                  ),
                ),
                Positioned(
                  top: 0,
                  bottom: 0,
                  right: WorkbenchLayout.railWidth,
                  width: overlayW,
                  child: _OverlayPanel(
                    icon: widget.rightIcon,
                    label: widget.rightLabel,
                    onClose: () => setState(() => _open = false),
                    child: widget.rightBuilder(overlayW),
                  ),
                ),
              ],
            ],
          );
        },
      ),
    );
  }

  /// 窄屏主从形态：列表占满，底部动作条给「编辑 / 设置」两个入口。
  ///
  /// 这里刻意不再套一层 [Scaffold]——外层壳（移动壳/MobileSubPage/桌面壳）
  /// 已经是 Scaffold，由它统一处理软键盘 `viewInsets`（正文收缩、动作条上移），
  /// 避免嵌套 Scaffold 把 inset 叠加两次。
  Widget _buildMobile(double w) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: widget.leftBuilder(w)),
        _MobileActionBar(
          items: [
            _MobileAction(
              icon: FluentIcons.edit_24_regular,
              label: widget.mobileEditorLabel,
              onTap: () => _openMobileEditor(),
            ),
            _MobileAction(
              icon: widget.rightIcon,
              label: widget.rightLabel,
              onTap: () => _openMobileSheet(context),
            ),
          ],
        ),
      ],
    );
  }

  /// 列表 → push 编辑页（系统返回逐级退出）；编辑页底部再给「设置」入口。
  void _openMobileEditor() {
    setState(() => _editorOpen = true);
    Navigator.of(context)
        .push(
      MaterialPageRoute<void>(
        builder: (_) => _MobileEditorPage(
          title: widget.mobileTitle ?? '编辑',
          settingsIcon: widget.rightIcon,
          settingsLabel: widget.rightLabel,
          // 传 builder 而非快照：每次重绘都取脚手架当前（最新）的 center。
          centerBuilder: () => widget.center,
          rev: _editorRev,
          rightBuilder: widget.rightBuilder,
        ),
      ),
    )
        .whenComplete(() {
      if (mounted) setState(() => _editorOpen = false);
    });
  }

  /// 右栏（设置 / 概览 / 预览）以 92% 屏高底部滑出层展开。
  void _openMobileSheet(BuildContext context) {
    setState(() => _sheetOpen = true);
    _showWorkbenchSheet(
      context,
      icon: widget.rightIcon,
      label: widget.rightLabel,
      builder: widget.rightBuilder,
      rev: _editorRev,
    ).whenComplete(() {
      if (mounted) setState(() => _sheetOpen = false);
    });
  }
}

/// 通用底部滑出层：复用 [showMobileSheet]（92% 高、随键盘抬升），
/// 顶部补一行「图标 + 标题」的面板头，正文由 [builder] 按滑出层宽度渲染。
Future<void> _showWorkbenchSheet(
  BuildContext context, {
  required IconData icon,
  required String label,
  required Widget Function(double width) builder,
  Listenable? rev,
}) {
  final w = MediaQuery.sizeOf(context).width;
  return showMobileSheet(
    context,
    Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _MobileSheetHeader(icon: icon, label: label),
        // 滑出层同样是独立 route：不监听 rev 的话，里面的表单会一直停在
        // 打开那一刻的快照（改字段不刷新，保存条也不翻脏）。B3。
        Expanded(
          child: rev == null
              ? builder(w)
              : ListenableBuilder(
                  listenable: rev,
                  builder: (_, __) => builder(w),
                ),
        ),
      ],
    ),
  );
}

/// 底部滑出层面板头。
class _MobileSheetHeader extends StatelessWidget {
  const _MobileSheetHeader({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: palette.border)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 15, color: accentColor),
          const SizedBox(width: AppSpace.s),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: AppText.subhead,
                fontWeight: FontWeight.w600,
                color: palette.textHigh,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 窄屏 push 出来的编辑页：系统返回 + 底部「设置」入口。
class _MobileEditorPage extends StatelessWidget {
  const _MobileEditorPage({
    required this.title,
    required this.settingsIcon,
    required this.settingsLabel,
    required this.centerBuilder,
    required this.rev,
    required this.rightBuilder,
  });

  final String title;
  final IconData settingsIcon;
  final String settingsLabel;

  /// 每次重绘都重新取工作台最新的中栏（避免编辑页沦为「快照」）。
  final Widget Function() centerBuilder;

  /// 脚手架在工作台重建后 tick 一下，驱动本页用最新中栏重绘。
  final Listenable rev;
  final Widget Function(double width) rightBuilder;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: palette.bgDeep2,
      appBar: AppBar(
        backgroundColor: palette.bg,
        elevation: 0,
        toolbarHeight: 48,
        leading: BackButton(color: palette.textHigh),
        title: Text(
          title,
          style: TextStyle(fontSize: AppText.display, color: palette.textHigh),
        ),
      ),
      body: SafeArea(
        top: false,
        child: ListenableBuilder(
          listenable: rev,
          builder: (_, __) => centerBuilder(),
        ),
      ),
      bottomNavigationBar: _MobileActionBar(
        items: [
          _MobileAction(
            icon: settingsIcon,
            label: settingsLabel,
            onTap: () => _showWorkbenchSheet(
              context,
              icon: settingsIcon,
              label: settingsLabel,
              builder: rightBuilder,
              rev: rev,
            ),
          ),
        ],
      ),
    );
  }
}

/// 窄屏底部动作条（单项）。
class _MobileAction {
  const _MobileAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
}

/// 窄屏底部动作条：等分铺满、单项 ≥48 高、贴底时补系统安全区。
class _MobileActionBar extends StatelessWidget {
  const _MobileActionBar({required this.items});

  final List<_MobileAction> items;

  @override
  Widget build(BuildContext context) {
    return clampedChromeText(
      Container(
        decoration: BoxDecoration(
          color: palette.panel,
          border: Border(top: BorderSide(color: palette.border)),
        ),
        child: SafeArea(
          top: false,
          child: SizedBox(
            height: 48,
            child: Row(
              children: [
                for (final it in items)
                  Expanded(
                    child: InkWell(
                      onTap: () {
                        MobileHaptic.lightImpact();
                        it.onTap();
                      },
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(it.icon, size: 17, color: palette.textPrimary),
                          const SizedBox(height: AppSpace.xxs),
                          Text(
                            it.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: AppText.small,
                              color: palette.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 统一加载骨架屏（C4）：左侧列表行 + 中部内容块的占位高亮。
///
/// 用 [ShimmerBox]（已在 motion.dart 内实现、尊重 `disableAnimations`）
/// 取代此前各工作台的 `ProgressRing`——结构可见、观感连续，比转圈更有
/// 「正在加载什么」的信息量。
class WorkbenchSkeleton extends StatelessWidget {
  const WorkbenchSkeleton({super.key, this.rows = 8});

  /// 左栏占位行数。
  final int rows;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        // 太窄（手机/横屏手机）时不摆左栏，直接渲染整块内容骨架。
        final narrow = isMobileLayoutOf(
            Size(box.maxWidth, MediaQuery.sizeOf(context).height));
        if (narrow) return _skeletonContent(rows);
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: WorkbenchLayout.leftWidth(box.maxWidth),
              child: _skeletonList(rows),
            ),
            VerticalDivider(width: 1, color: palette.border),
            Expanded(child: _skeletonContent(rows ~/ 2 + 2)),
          ],
        );
      },
    );
  }

  Widget _skeletonList(int n) {
    return Container(
      color: palette.panel,
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(
            vertical: AppSpace.m, horizontal: AppSpace.m),
        itemCount: n,
        itemBuilder: (_, i) => Padding(
          padding: const EdgeInsets.only(bottom: AppSpace.m),
          child: ShimmerBox(height: 14, width: i.isEven ? 150 : 110),
        ),
      ),
    );
  }

  Widget _skeletonContent(int n) {
    // 用 ListView 而非 Column：骨架屏常挂在受限高度里（工作台测试多为
    // 800x600），固定行数会 RenderFlex overflow。
    return ListView.builder(
      padding: const EdgeInsets.all(20),
      itemCount: n,
      itemBuilder: (_, i) => Padding(
        padding: const EdgeInsets.only(bottom: 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ShimmerBox(height: 16, width: i.isEven ? 220 : 160),
            const SizedBox(height: AppSpace.m),
            ShimmerBox(height: 90, width: double.infinity),
          ],
        ),
      ),
    );
  }
}

/// 统一错误面板（C4）：人性化文案 + 重试 + 复制详情。
///
/// 文案走 [humanizeError]（C3）——把 `API 409: …` 这类技术串换成能读懂、
/// 能行动的一句话；技术细节收进「复制详情」，排查时不丢。
class WorkbenchErrorPanel extends StatelessWidget {
  const WorkbenchErrorPanel({
    super.key,
    this.error,
    this.title,
    this.onRetry,
  });

  /// 原始异常。
  final Object? error;

  /// 标题。缺省「数据加载失败」。
  final String? title;

  /// 重试回调；null 则不显示按钮。
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final h = humanizeError(error);
    final canRetry = onRetry != null && h.retryable;
    // 外层可滚动：窄屏横屏等极矮视口下正文不至于溢出。
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(AppSpace.xl),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(FluentIcons.error_circle_24_regular,
                  size: 34, color: palette.statusDanger),
              const SizedBox(height: AppSpace.m),
              Text(
                title ?? '数据加载失败',
                style: TextStyle(fontSize: 13.5, color: palette.textPrimary),
              ),
              const SizedBox(height: AppSpace.s6),
              Text(
                h.message,
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: AppText.caption,
                    color: palette.textMuted,
                    height: 1.5),
              ),
              const SizedBox(height: 14),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (onRetry != null)
                    fluent.Button(
                      onPressed: onRetry,
                      child: Text(canRetry ? '重试' : '再试一次'),
                    ),
                  if (onRetry != null && h.detail != null)
                    const SizedBox(width: AppSpace.s),
                  if (h.detail != null)
                    fluent.Button(
                      onPressed: () => _copyDetail(context, h),
                      child: const Text('复制详情'),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _copyDetail(BuildContext context, HumanizedError h) async {
    await Clipboard.setData(ClipboardData(text: h.detail!));
    if (!context.mounted) return;
    AppFeedback.info(context, '已复制错误详情');
  }
}

/// 窄布局右侧常驻图标条：点击展开/收起浮层。
class _RightRail extends StatefulWidget {
  const _RightRail({
    required this.icon,
    required this.label,
    required this.active,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  State<_RightRail> createState() => _RightRailState();
}

class _RightRailState extends State<_RightRail> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: WorkbenchLayout.railWidth,
      decoration: BoxDecoration(
        color: palette.panel,
        border: Border(left: BorderSide(color: palette.border)),
      ),
      child: Center(
        child: Tooltip(
          message: widget.active ? '收起${widget.label}' : '展开${widget.label}',
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            onEnter: (_) => setState(() => _hover = true),
            onExit: (_) => setState(() => _hover = false),
            child: GestureDetector(
              onTap: widget.onTap,
              child: AnimatedContainer(
                duration: AppMotion.fast,
                curve: AppMotion.easeOut,
                padding: const EdgeInsets.all(7),
                decoration: BoxDecoration(
                  color: widget.active
                      ? accentColor.withValues(alpha: 0.14)
                      : _hover
                          ? palette.card
                          : Colors.transparent,
                  borderRadius: BorderRadius.circular(AppRadius.m),
                ),
                child: Icon(
                  widget.active
                      ? FluentIcons.dismiss_24_regular
                      : widget.icon,
                  size: 18,
                  color: widget.active
                      ? accentColor
                      : _hover
                          ? palette.textPrimary
                          : palette.textMuted,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 窄布局右栏浮层：不透明底板 + 标题栏（含关闭），正文复用右栏 builder。
class _OverlayPanel extends StatelessWidget {
  const _OverlayPanel({
    required this.icon,
    required this.label,
    required this.onClose,
    required this.child,
  });

  final IconData icon;
  final String label;
  final VoidCallback onClose;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: palette.panel,
        border: Border(left: BorderSide(color: palette.border)),
        boxShadow: [
          BoxShadow(
            color: palette.scrimWeak,
            blurRadius: 18,
            offset: const Offset(-4, 0),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: 40,
            padding: const EdgeInsets.only(left: 14, right: 6),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: palette.border)),
            ),
            child: Row(
              children: [
                Icon(icon, size: 15, color: accentColor),
                const SizedBox(width: AppSpace.s),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: AppText.subhead,
                      fontWeight: FontWeight.w600,
                      color: palette.textHigh,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '收起',
                  icon: Icon(
                    FluentIcons.dismiss_24_regular,
                    size: 16,
                    color: palette.textSecondary,
                  ),
                  onPressed: onClose,
                ),
              ],
            ),
          ),
          Expanded(child: child),
        ],
      ),
    );
  }
}
