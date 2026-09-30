/// 后端启动器条件导出：
/// - 有 dart:io 的平台（桌面/Android）：进程探测与拉起（backend_launcher_io.dart）；
/// - Web：绝不 spawn 进程，只做同源 /api/ping 重试探测（backend_launcher_stub.dart）。
///
/// 两份实现暴露同一公共 API（BackendLauncher.instance.ensureBackend /
/// probe / shutdownBackend / buildSourceBackend / supportsSpawn）。
export 'backend_launcher_stub.dart'
    if (dart.library.io) 'backend_launcher_io.dart';
