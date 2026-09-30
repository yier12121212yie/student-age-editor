import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show ImageFilter, TileMode; // widgets 只透出了 TileMode？两者都显式引入以消除歧义。

import 'package:flutter/widgets.dart';

import '../../core/app_theme.dart';

/// 屏幕效果（TalkCfg.screenEffect）演出层：把「逐句」的 screenEffect 指令编译成
/// 舞台画面上的持续滤镜 / 一次性动画 / 全屏 CG。
///
/// 语义来源：native `SCREEN_EFFECT_DB`（`_semantic_db.json`）：
/// - 4001 抖动（X 秒）、4002 背景模糊、4003 清空背景特效（还原）、
///   4006 黑屏片刻、4010 背景反色、4012 闪白（X 下）、4015 播 CG（参数=CG id）、
///   4017 结束 CG。
/// - 4004 展示物品 / 4007 电话 / 4008 挂断 / 4009 做旧 / 4011 闭眼：本期白名单跳过。
///
/// 状态机分两类：
/// - **持续滤镜**（4002 模糊 / 4010 反色）：粘滞，遇到 4003/4017（清特效）才复位，
///   跨句保持（“下一句无该码”不清除）——与视觉小说「背景模糊」的语义一致。
/// - **逐句画面**（4006 黑屏 / 4015 CG）：仅当本句 code 命中才为真，下一句换码即结束
///   （“若下一句仍是 4006 则保持”“下一句无 CG 则结束”由「逐句重算」自然实现）。
/// - **一次性动画**（4012 闪白 / 4001 抖动）：进入该句触发一次，不改变持续画面。
///
/// 颜色：闪白 / 黑屏 / CG 底是「游戏画面内容」而非编辑器 UI chrome，两模式同为纯白/纯黑；
/// 用 [Color.fromARGB] 表达（刻意不并入随外观切换的 palette token），与全屏预览顶栏
/// 渐隐遮罩同类。

// ---------------- 指令码常量 ----------------

const int kFxShake = 4001;
const int kFxBlur = 4002;
const int kFxClear = 4003;
const int kFxBlack = 4006;
const int kFxInvert = 4010;
const int kFxFlash = 4012;
const int kFxPlayCg = 4015;
const int kFxStopCg = 4017;

/// 两模式同值的游戏画面效果色（非 UI chrome，不随外观切换）。
const Color kFxWhite = Color.fromARGB(255, 255, 255, 255);
const Color kFxBlackColor = Color.fromARGB(255, 0, 0, 0);

/// 反色矩阵（R/G/B → 255-c；alpha 与偏移不变）。
final Float64List kInvertColorMatrix = Float64List.fromList(<double>[
  -1, 0, 0, 0, 255, //
  0, -1, 0, 0, 255, //
  0, 0, -1, 0, 255, //
  0, 0, 0, 1, 0, //
]);

/// 解析后的「第一组码」：一行 screenEffect 指令。
class ScreenEffect {
  const ScreenEffect._(this.code, this.params, this.cgRef);

  /// 行首效果码（4001..4017）。
  final int code;

  /// 首码之后的数值参数（抖秒数 / 闪白次数 / CG id 等）。
  final List<double> params;

  /// 4015 播 CG 的原始参数（CGCfg id 或直接的 url/key），其余为 null。
  final Object? cgRef;

  double get firstParam => params.isEmpty ? 0 : params.first;

  /// 从后端归一的 screen_effects 条目 `{code, args:[...]}` 构造（首选路径）。
  /// 4015 播 CG：cgRef 取 args 首元素（CGCfg id 或 url），供上层解析贴图。
  static ScreenEffect? fromDirective(int? code, List<dynamic> args) {
    if (code == null) return null;
    final params = <double>[];
    for (final p in args) {
      final d = _doubleOf(p);
      if (d != null) params.add(d);
    }
    final cgRef = code == kFxPlayCg && args.isNotEmpty ? args.first : null;
    return ScreenEffect._(code, params, cgRef);
  }

  /// 从 TalkCfg.screenEffect 原值解析「第 1 组码」。
  ///
  /// 兼容三种落位：1D 扁平 `[4015, id]`、2D 行列表 `[[4015, id], ...]`、
  /// 单元素逗号串 `['4015,20']`。无法解析出数字首码时返回 null。
  static ScreenEffect? parse(List<dynamic> raw) {
    if (raw.isEmpty) return null;
    List<dynamic> group =
        raw.first is List ? List<dynamic>.from(raw.first as List) : raw;
    if (group.isEmpty) return null;
    if (group.length == 1 && group.first is String) {
      group = (group.first as String).split(',');
    }
    final code = _intOf(group.first);
    if (code == null) return null;
    final params = <double>[];
    for (final p in group.skip(1)) {
      final d = _doubleOf(p);
      if (d != null) params.add(d);
    }
    final cgRef = code == kFxPlayCg && group.length > 1 ? group[1] : null;
    return ScreenEffect._(code, params, cgRef);
  }
}

int? _intOf(dynamic v) {
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v.trim()) ?? double.tryParse(v.trim())?.toInt();
  return null;
}

double? _doubleOf(dynamic v) {
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v.trim());
  return null;
}

/// 跨句持续的画面状态（由 [nextStageVisual] 逐句演算）。
class StageVisual {
  const StageVisual({
    this.blur = false,
    this.invert = false,
    this.black = false,
    this.cgRef,
  });

  final bool blur;
  final bool invert;
  final bool black;

  /// 本句要求展示的 CG 标识；null = 本句无 CG（结束上一句 CG）。
  final Object? cgRef;
}

/// 由上一状态 + 本句效果算出新状态。见文件头「状态机」说明。
StageVisual nextStageVisual(StageVisual prev, ScreenEffect? fx) {
  // 持续滤镜粘滞：只有 4003/4017（清特效）复位。
  var blur = prev.blur;
  var invert = prev.invert;
  // 黑屏 / CG 逐句重算：本句没有对应码即结束。
  var black = false;
  Object? cgRef;
  if (fx != null) {
    switch (fx.code) {
      case kFxClear:
      case kFxStopCg:
        blur = false;
        invert = false;
        break;
      case kFxBlur:
        blur = true;
        break;
      case kFxInvert:
        invert = true;
        break;
      case kFxBlack:
        black = true;
        break;
      case kFxPlayCg:
        cgRef = fx.cgRef;
        break;
      // kFxFlash / kFxShake 为一次性动画；白名单外的码跳过——均不改持续画面。
      default:
        break;
    }
  }
  return StageVisual(blur: blur, invert: invert, black: black, cgRef: cgRef);
}

/// 本句是否触发一次性动画。
enum StageOneShot { none, flash, shake }

StageOneShot stageOneShotOf(ScreenEffect? fx) {
  switch (fx?.code) {
    case kFxFlash:
      return StageOneShot.flash;
    case kFxShake:
      return StageOneShot.shake;
    default:
      return StageOneShot.none;
  }
}

// ---------------- 舞台叠加构件 ----------------

/// 对「背景 + 立绘」图层施加持续滤镜（模糊→反色）。选项/对白框/CG/闪白不进此层，
/// 保持清晰，符合视觉小说惯例。
Widget applyStageFilters(Widget scene, {bool blur = false, bool invert = false}) {
  if (blur) {
    scene = ImageFiltered(
      imageFilter: ImageFilter.blur(sigmaX: 10, sigmaY: 10, tileMode: TileMode.decal),
      child: scene,
    );
  }
  if (invert) {
    scene = ColorFiltered(
      colorFilter: ColorFilter.matrix(kInvertColorMatrix),
      child: scene,
    );
  }
  return scene;
}

/// 黑屏遮罩（4006）：渐入渐出，[on] 由所属句是否含 4006 决定。
/// 全透明时不拦截点击（[IgnorePointer]），保证「点画面推进」照常。
class StageBlackCurtain extends StatelessWidget {
  const StageBlackCurtain({super.key, required this.on});
  final bool on;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: AnimatedOpacity(
        opacity: on ? 1 : 0,
        duration: const Duration(milliseconds: 320),
        child: Container(color: kFxBlackColor),
      ),
    );
  }
}

/// 闪白（4012）一次性叠加：[token] 自增触发一闪（白幕 alpha 走 0→1→0）。
/// 空闲时返回零尺寸——故测试可在触发瞬间 `find.byKey(fxFlashKey)`，动画结束即消失。
const Key fxFlashKey = ValueKey<String>('fx-flash');

class StageFlashBurst extends StatefulWidget {
  const StageFlashBurst({super.key, required this.token, this.intensity = 1});
  final int token;

  /// 强度 0..1，映射闪白峰值 alpha。
  final double intensity;

  @override
  State<StageFlashBurst> createState() => _StageFlashBurstState();
}

class _StageFlashBurstState extends State<StageFlashBurst>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 420),
  );

  @override
  void initState() {
    super.initState();
    if (widget.token > 0) _c.forward(from: 0);
  }

  @override
  void didUpdateWidget(StageFlashBurst old) {
    super.didUpdateWidget(old);
    if (old.token != widget.token) _c.forward(from: 0);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        // 半正弦：进入(0)与结束(1)处 opacity≈0，中段冲顶。
        final alpha = math.sin(_c.value * math.pi) * widget.intensity.clamp(0.0, 1.0);
        if (alpha <= 0.012) return const SizedBox.shrink();
        return IgnorePointer(
          child: Container(key: fxFlashKey, color: kFxWhite.withValues(alpha: alpha)),
        );
      },
    );
  }
}

/// 屏幕抖动（4001）一次性：[token] 自增触发短时 translate 正弦抖动。
/// 空/结束时 offset 归零（半正弦包络在两端为 0），不影响正常交互。
class StageShake extends StatefulWidget {
  const StageShake({super.key, required this.token, required this.seconds, required this.child});
  final int token;
  final double seconds;
  final Widget child;

  @override
  State<StageShake> createState() => _StageShakeState();
}

class _StageShakeState extends State<StageShake> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 600));

  void _restart() {
    final ms = (widget.seconds <= 0 ? 0.6 : widget.seconds) * 1000;
    _c.duration = Duration(milliseconds: ms.clamp(200, 3000).round());
    _c.forward(from: 0);
  }

  @override
  void initState() {
    super.initState();
    if (widget.token > 0) _restart();
  }

  @override
  void didUpdateWidget(StageShake old) {
    super.didUpdateWidget(old);
    if (old.token != widget.token) _restart();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, child) {
        final v = _c.value;
        // 衰减包络（1-v）× 高频正弦，两端自然归零。
        final env = (1 - v) * 10;
        final dx = math.sin(v * math.pi * 20) * env;
        final dy = math.cos(v * math.pi * 24) * env * 0.6;
        return Transform.translate(offset: Offset(dx, dy), child: child);
      },
      child: widget.child,
    );
  }
}

/// 全屏 CG 层（4015）：黑底 + 居中控图；点击进入 [onDismiss]（提前结束）。
/// [bytes] 为空（取字节中）时显示占位提示，仍占据 [fxCgKey]，便于「出现/消失」断言。
const Key fxCgKey = ValueKey<String>('fx-cg');

class StageCgLayer extends StatelessWidget {
  const StageCgLayer({super.key, required this.bytes, required this.onDismiss});
  final Uint8List? bytes;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      key: fxCgKey,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onDismiss,
        child: ColoredBox(
          color: kFxBlackColor,
          child: Center(
            child: bytes == null
                ? Text('CG 加载中…',
                    style: TextStyle(fontSize: 13, color: palette.textSecondary))
                : Image.memory(bytes!, fit: BoxFit.contain, gaplessPlayback: true),
          ),
        ),
      ),
    );
  }
}
