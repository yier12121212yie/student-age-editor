import 'dart:async';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';

import 'app.dart';
import 'core/editor_font.dart';
import 'core/error_fallback.dart';
import 'core/texture_budget.dart';

/// 启动参数（Windows runner 经 dart_entrypoint_arguments 透传）：
///   --oobe   强制开启首次使用引导页
Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  if (kDebugMode) {
    debugPrint('[main] 从源码运行（开发模式启动）');
  }
  // 阶段 5（降 GPU 峰值）：先收紧引擎的解码位图预算，再让任何图片开始解码。
  // 引擎默认 1000 条 / 100 MiB 且只进不出；这一步是「峰值」的第一道闸。
  TextureBudget.apply();
  // Web：纯 canvas 渲染，异常默认只是一块灰底/一行控制台日志。这里接管
  // 框架与 JS 两层异常：就地渲染错误卡片 + 收集诊断（桌面为空实现）。
  installErrorHandlers();
  // Web：CanvasKit 没有系统字体，中文要内置字体才稳（详见 core/editor_font.dart）。
  // 桌面端系统自带中文字体，这里什么都不做。
  //
  // C1（首屏）：**不阻塞 runApp**。字体晚到不会留下豆腐块——引擎加载完字体会
  // 发 'fontsChange' 系统消息，框架的 RenderParagraph 会重排全部文本
  // （RelayoutWhenSystemFontsChangeMixin）。index.html 的加载屏用
  // `window.__editorFontReady` 决定何时让位给 Flutter 首帧，因此用户也看不到
  // 中间态。
  unawaited(ensureEditorCjkFont());
  final forceOobe = args.contains('--oobe');
  runApp(StudentAgeEditorApp(forceOobe: forceOobe));
}
