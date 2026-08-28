import 'package:flutter/material.dart';

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
      backgroundColor: const Color(0xFF131316),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1B1B1F),
        elevation: 0,
        leading: const BackButton(color: Colors.white),
        title: Text(
          title,
          style: const TextStyle(fontSize: 16, color: Colors.white),
        ),
        actions: actions,
      ),
      body: SafeArea(child: body),
    );
  }
}