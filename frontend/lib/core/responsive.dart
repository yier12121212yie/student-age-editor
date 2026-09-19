import 'package:flutter/widgets.dart';

/// 响应式断点与工具。
/// 移动端以 720 逻辑像素为分界（兼顾手机竖屏与小平板）。
class Breakpoints {
  static const double mobile = 720;
  static const double tablet = 1024;
}

/// 宽度 < 720 视为移动端（手机竖屏 / 折叠屏内屏窄态）。
bool isMobileWidth(BuildContext context) =>
    MediaQuery.sizeOf(context).width < Breakpoints.mobile;

/// 更语义化的短名。
bool isMobile(BuildContext context) => isMobileWidth(context);

bool isDesktop(BuildContext context) => !isMobile(context);

/// 直接判定宽度数值，方便在非 BuildContext 处或测试中使用。
bool isMobileForWidth(double width) => width < Breakpoints.mobile;

/// 获取当前是否为移动端的缓存版本，避免在 build 中频繁调用。
class MobileDetector extends StatefulWidget {
  const MobileDetector({super.key, required this.builder});
  
  final Widget Function(bool isMobile) builder;
  
  @override
  State<MobileDetector> createState() => _MobileDetectorState();
}

class _MobileDetectorState extends State<MobileDetector> {
  late bool _isMobile;
  
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _isMobile = isMobileWidth(context);
  }
  
  @override
  Widget build(BuildContext context) {
    return widget.builder(_isMobile);
  }
}

/// 移动端安全边距包裹，避免刘海/手势条遮挡。
Widget mobileSafeArea({required Widget child}) => SafeArea(child: child);

/// 供移动端全屏对话框使用的自适应宽度。
double dialogWidth(BuildContext context, {double desktopWidth = 760}) {
  final w = MediaQuery.sizeOf(context).width;
  if (isMobileWidth(context)) return w - 24;
  return desktopWidth.clamp(0, w - 48);
}

double dialogHeight(BuildContext context, {double desktopHeight = 620}) {
  final h = MediaQuery.sizeOf(context).height;
  if (isMobileWidth(context)) return h * 0.92;
  return desktopHeight.clamp(0, h - 48);
}
