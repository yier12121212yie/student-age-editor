import 'dart:io';

import 'package:flutter/material.dart';

import 'app.dart';
import 'core/backend_launcher.dart';

/// 启动参数（Windows runner 经 dart_entrypoint_arguments 透传）：
///   --oobe   强制开启首次使用引导页
Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  // 发行模式：探测本地 API，未就绪则自动拉起同目录 backend.exe。
  // Android 上后端由原生 JNI 在后台线程启动，首次就绪可能要数十秒；此时不阻塞
  // 首帧，立即 runApp，由 App 的 _bootstrap（已有 loading/错误 UI）继续等待。
  if (!Platform.isAndroid) {
    await BackendLauncher.instance.ensureBackend();
  }
  final forceOobe = args.contains('--oobe');
  runApp(StudentAgeEditorApp(forceOobe: forceOobe));
}
