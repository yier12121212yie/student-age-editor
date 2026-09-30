import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import 'app.dart';
import 'core/backend_launcher.dart';
import 'core/platform_env.dart';

/// 启动参数（Windows runner 经 dart_entrypoint_arguments 透传）：
///   --oobe   强制开启首次使用引导页
Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  // 桌面：探测本地 API，未就绪则自动拉起后端 exe（发行版=同目录；debug 构建
  // 回退到 native 源码构建产物，见 BackendLauncher）。
  // Android 上后端由原生 JNI 在后台线程启动，首次就绪可能要数十秒；此时不阻塞
  // 首帧，立即 runApp，由 App 的 _bootstrap（已有 loading/错误 UI）继续等待。
  // Web 同理不阻塞首帧：ensureBackend 只做几轮 /api/ping 探测（绝不 spawn
  // 进程），App 的 _bootstrap 探测失败时渲染居中「无法连接后端服务」提示页
  // （带重试按钮），不抛异常。
  if (!isAndroidPlatform && !kIsWeb) {
    await BackendLauncher.instance.ensureBackend();
  }
  final forceOobe = args.contains('--oobe');
  runApp(StudentAgeEditorApp(forceOobe: forceOobe));
}
