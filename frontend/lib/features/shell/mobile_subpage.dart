import 'package:flutter/material.dart';
import '../../core/app_theme.dart';

/// 移动端全屏子页：自带 AppBar（自动返回）+ SafeArea + 暗色背景。
/// 「更多」里的资源 / 剧情库 / 云同步 / 资源包管理 / 诊断修复 / 设置等全屏子页统一复用。
class MobileSubPage extends StatelessWidget {
  const MobileSubPage({
    super.key,
    required this.title,
    required this.body,
    this.actions,
  });

  final String title;
  final Widget body;

  /// AppBar 右侧操作（如图标按钮）。
  final List<Widget>? actions;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: palette.bgDeep2,
      appBar: AppBar(
        backgroundColor: palette.bg,
        elevation: 0,
        leading: BackButton(color: palette.textHigh),
        title: Text(
          title,
          style: TextStyle(fontSize: 16, color: palette.textHigh),
        ),
        actions: actions,
      ),
      body: SafeArea(child: body),
    );
  }
}