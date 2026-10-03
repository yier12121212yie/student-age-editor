import 'dart:async';

import 'package:flutter/material.dart';
import 'app_theme.dart';

/// 常驻（无限）动画的统一闸门——「降 GPU 负担」阶段 4。
///
/// 阶段 1~3 收的是**重绘范围**（`RepaintBoundary` 把 repeat 动画圈在自己的小
/// 区域内）和**隐藏视图停表**（`TickerMode`）。这里补最后一条，也是空闲占用的
/// 真正来源：**没人看的时候根本不该出帧**。只要还活着一个 `repeat()` 的装饰动
/// 画，引擎每个 vsync 都排一帧，Task Manager 里就是持续的 GPU 占用——停在欢
/// 迎页、空编辑区都一样。
///
/// 两条独立判据（挂在 App 根的 [MotionGate] 上）：
///   * [focused] —— 窗口拿到焦点且系统没开「减少动画」。本 App 自绘的装饰动画
///     （呼吸点 / shimmer / 欢迎页浮动方块）据此停表或改走静态渲染。
///   * [visible] —— 窗口没被最小化/遮挡。据此关掉整棵子树的 ticker，连
///     Material / fluent_ui 自带的转圈一起停，最小化后彻底零帧。
///
/// 刻意**不**用根 `TickerMode` 处理失焦：那会让失焦期间到达的状态更新卡在
/// `AnimatedSwitcher` 的透明度 0 上（内容看不见），聚焦才跳回来。
class MotionScope extends InheritedWidget {
  const MotionScope({
    super.key,
    required this.focused,
    required this.visible,
    required super.child,
  });

  /// 装饰动画可播放（窗口聚焦 + 系统未要求减少动画）。
  final bool focused;

  /// 窗口可见（未最小化/未遮挡）。
  final bool visible;

  /// 缺省视为「可播放」：闸门取不到时宁可让动画跑，也不能把界面钉死。
  static bool focusedOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<MotionScope>()?.focused ?? true;

  static bool visibleOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<MotionScope>()?.visible ?? true;

  @override
  bool updateShouldNotify(MotionScope old) =>
      old.focused != focused || old.visible != visible;
}

/// 把窗口生命周期 + 系统「减少动画」翻成 [MotionScope]，挂在 App 根上。
class MotionGate extends StatefulWidget {
  const MotionGate({super.key, required this.child});
  final Widget child;
  @override
  State<MotionGate> createState() => _MotionGateState();
}

class _MotionGateState extends State<MotionGate> with WidgetsBindingObserver {
  /// 当前窗口生命周期；null（尚未收到引擎回调 / widget 测试）按 resumed 处理。
  AppLifecycleState? _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = WidgetsBinding.instance.lifecycleState;
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!mounted) return;
    // 失焦（inactive）与最小化（hidden）在 Windows/macOS 上都会走到这里。
    setState(() => _lifecycle = state);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = _lifecycle;
    final visible = s != AppLifecycleState.hidden &&
        s != AppLifecycleState.paused &&
        s != AppLifecycleState.detached;
    // MediaQuery 是框架惯例（顺带尊重 App 层的局部覆盖）；取不到时回落到
    // 平台无障碍开关，保证闸门在任何插入点都能判对「减少动画」。
    final reducedMotion = MediaQuery.maybeDisableAnimationsOf(context) ??
        WidgetsBinding
            .instance.platformDispatcher.accessibilityFeatures.disableAnimations;
    final focused =
        visible && !reducedMotion && s != AppLifecycleState.inactive;
    return TickerMode(
      enabled: visible,
      child:
          MotionScope(focused: focused, visible: visible, child: widget.child),
    );
  }
}

/// 挂在 [MotionGate] 之下、自己持有 `repeat()` 动画的组件用这个 mixin 停表。
///
/// 闸门开 → 续播；闸门关（失焦 / 系统减少动画）→ `stop()` 停在当前帧。
/// 隐藏视图那一路仍由 `TickerProviderStateMixin` 的 ticker mute 兜着，两者叠加
/// 才是「不在看 = 不出帧」。
mixin DecorativeLoopMixin<T extends StatefulWidget> on State<T> {
  AnimationController? _loop;
  bool _loopReverse = false;

  /// 把要受闸门管制的循环动画交给 mixin（initState 里调用）。
  /// `reverse` 同 [AnimationController.repeat]：往返式呼吸要传 true。
  void attachLoop(AnimationController controller, {bool reverse = false}) {
    _loop = controller;
    _loopReverse = reverse;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    syncLoop();
  }

  void syncLoop() {
    final c = _loop;
    if (c == null) return;
    if (MotionScope.focusedOf(context)) {
      if (!c.isAnimating) c.repeat(reverse: _loopReverse);
    } else {
      c.stop();
    }
  }
}

// Unified motion tokens for StudentAge Editor
// Duration / curve consistent across shell, tabs, cards
class AppMotion {
  static const fast = Duration(milliseconds: 180);
  static const normal = Duration(milliseconds: 240);
  static const slow = Duration(milliseconds: 320);
  static const emphasis = Duration(milliseconds: 400);

  static const easeOut = Curves.easeOutCubic;
  static const easeInOut = Curves.easeInOutCubic;
  static const spring = Curves.easeOutBack;
  static const decelerate = Curves.decelerate;

  // Stagger delays for list entrance
  static Duration stagger(int index, {int baseMs = 40}) =>
      Duration(milliseconds: baseMs * index);
}

// Reusable fade+slide entrance
class FadeSlide extends StatefulWidget {
  const FadeSlide({
    super.key,
    required this.child,
    this.delay = Duration.zero,
    this.offset = const Offset(0, 12),
    this.duration = AppMotion.normal,
  });
  final Widget child;
  final Duration delay;
  final Offset offset;
  final Duration duration;
  @override
  State<FadeSlide> createState() => _FadeSlideState();
}

class _FadeSlideState extends State<FadeSlide>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  late final CurvedAnimation _curve;
  Timer? _delayTimer;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(vsync: this, duration: widget.duration);
    _curve = CurvedAnimation(parent: _c, curve: AppMotion.easeOut);
    _delayTimer = Timer(widget.delay, () {
      if (!mounted) return;
      // 闸门关着就不进场：build 已经是终态，起动画只会白出几帧。
      if (MotionScope.focusedOf(context)) {
        _c.forward();
      } else {
        _c.value = 1.0;
      }
    });
  }

  /// 停在终态：闸门关闭时不能把内容留在 opacity 0 上（否则要等重新聚焦才显形）。
  void _finishNow() {
    _delayTimer?.cancel();
    if (_c.status != AnimationStatus.completed) {
      _c.stop();
      _c.value = 1.0;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!MotionScope.focusedOf(context)) _finishNow();
  }

  @override
  void dispose() {
    _delayTimer?.cancel();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 闸门关闭（失焦 / 系统要求减少动画）：直接给终态，不做中途冻结。
    if (!MotionScope.focusedOf(context)) return widget.child;
    return FadeTransition(
      opacity: _curve,
      // SlideTransition 的 position 是「子项尺寸的比例」而非像素，
      // 直接喂像素值会把动画放大到子项高度的数值倍（44px 高按钮 × 12 = 528px 位移）。
      // 用 Transform.translate 保持像素语义，位移量与控件尺寸无关。
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, child) {
          final v = _curve.value;
          return Transform.translate(
            offset: widget.offset * (1 - v),
            child: child,
          );
        },
        child: widget.child,
      ),
    );
  }
}

// Scale+fade for welcome / empty states
class ScaleFade extends StatefulWidget {
  const ScaleFade({super.key, required this.child, this.delay = Duration.zero});
  final Widget child;
  final Duration delay;
  @override
  State<ScaleFade> createState() => _ScaleFadeState();
}

class _ScaleFadeState extends State<ScaleFade>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  late final Animation<double> _opacity;
  late final Animation<double> _scale;
  Timer? _delayTimer;
  @override
  void initState() {
    super.initState();
    _c = AnimationController(vsync: this, duration: AppMotion.slow);
    _opacity = CurvedAnimation(parent: _c, curve: AppMotion.easeOut);
    _scale = Tween<double>(begin: 0.92, end: 1.0)
        .animate(CurvedAnimation(parent: _c, curve: AppMotion.spring));
    _delayTimer = Timer(widget.delay, () {
      if (!mounted) return;
      // 与 FadeSlide 同：闸门关着就不进场，直接把动画置成终态。
      if (MotionScope.focusedOf(context)) {
        _c.forward();
      } else {
        _c.value = 1.0;
      }
    });
  }

  void _finishNow() {
    _delayTimer?.cancel();
    if (_c.status != AnimationStatus.completed) {
      _c.stop();
      _c.value = 1.0;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!MotionScope.focusedOf(context)) _finishNow();
  }

  @override
  void dispose() {
    _delayTimer?.cancel();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!MotionScope.focusedOf(context)) return widget.child;
    return FadeTransition(
      opacity: _opacity,
      child: ScaleTransition(scale: _scale, child: widget.child),
    );
  }
}

/// 状态点：常态是实心静止圆点，**只在状态刚变化时呼吸 [PulseDot.bursts] 下**。
///
/// 旧实现是 `..repeat()` 的永久动画，且这条状态栏在所有桌面壳的每一屏都在，
/// 等于「无论停在哪个画面，空闲都按 60fps 出帧」——这是本次 GPU 占用的主因。
/// 「在线」本身是静态事实，不需要每秒重述 60 次；连通/断开那一瞬动两下已经
/// 把信息传达到了。
class PulseDot extends StatefulWidget {
  const PulseDot({
    super.key,
    required this.color,
    this.size = 8,
    this.bursts = 2,
  });
  final Color color;
  final double size;

  /// 状态变化时呼吸几次（0 = 恒静止）。
  final int bursts;
  @override
  State<PulseDot> createState() => _PulseDotState();
}

class _PulseDotState extends State<PulseDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  /// 作废进行中的脉冲序列（失焦/停表时 `_c.stop()` 会让 await 返回，靠 token
  /// 让那一串循环立刻退出，不在停表后又接着 forward 一次）。
  int _token = 0;
  bool _firstDeps = true;

  /// [MotionScope.focused] 的缓存：异步循环里不回头查 widget 树。
  bool _decorative = true;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1600));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _decorative = MotionScope.focusedOf(context);
    if (!_decorative) {
      _token++;
      _c.stop();
      return;
    }
    if (!_firstDeps) return;
    _firstDeps = false;
    _burst();
  }

  @override
  void didUpdateWidget(PulseDot old) {
    super.didUpdateWidget(old);
    // 只在状态真的换了（离线↔在线）时呼吸，父级重建不重播。
    if (old.color != widget.color && _decorative) _burst();
  }

  @override
  void dispose() {
    _token++;
    _c.dispose();
    super.dispose();
  }

  Future<void> _burst() async {
    final my = ++_token;
    for (var i = 0; i < widget.bursts; i++) {
      if (!mounted || my != _token || !_decorative) return;
      await _c.forward(from: 0.0);
    }
  }

  @override
  Widget build(BuildContext context) {
    final dot = Container(
      width: widget.size,
      height: widget.size,
      decoration: BoxDecoration(shape: BoxShape.circle, color: widget.color),
    );
    // 闸门关了（失焦 / 系统减少动画）：只画实心点，连那层涟漪都不建。
    if (!_decorative || widget.bursts == 0) {
      return SizedBox(
          width: widget.size + 8,
          height: widget.size + 8,
          child: Center(child: dot));
    }
    // 脉冲期间仍要有自己的绘制边界：不加 RepaintBoundary 时重绘会向上传播到
    // 最近边界（整条状态栏甚至更大区域）。
    return RepaintBoundary(
      child: SizedBox(
        width: widget.size + 8,
        height: widget.size + 8,
        child: Stack(
          alignment: Alignment.center,
          children: [
            ScaleTransition(
              scale: Tween<double>(begin: 1.0, end: 2.2).animate(
                CurvedAnimation(parent: _c, curve: Curves.easeOut),
              ),
              child: FadeTransition(
                opacity: Tween<double>(begin: 0.45, end: 0.0).animate(_c),
                child: dot,
              ),
            ),
            dot,
          ],
        ),
      ),
    );
  }
}

// Shimmer loading placeholder
class ShimmerBox extends StatefulWidget {
  const ShimmerBox({super.key, required this.width, required this.height, this.radius = 6});
  final double width;
  final double height;
  final double radius;
  @override
  State<ShimmerBox> createState() => _ShimmerBoxState();
}

class _ShimmerBoxState extends State<ShimmerBox>
    with SingleTickerProviderStateMixin, DecorativeLoopMixin {
  late final AnimationController _c;
  @override
  void initState() {
    super.initState();
    _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400));
    attachLoop(_c);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 与 PulseDot 同因：repeat() 每帧重建渐变 Container，不加边界时重绘会
    // 向上传播到最近的边界（启动页/加载卡片所在的整块区域）。
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) {
          return Container(
            width: widget.width,
            height: widget.height,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(widget.radius),
              gradient: LinearGradient(
                begin: Alignment(-1.0 + 2 * _c.value, -1),
                end: Alignment(1.0 + 2 * _c.value, 1),
                colors: [
                  palette.card,
                  palette.surface,
                  palette.card,
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
