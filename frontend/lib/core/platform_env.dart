/// 平台环境信息条件导出：dart:io 可用时读真实操作系统/环境变量，
/// Web 上全部给出「无」语义（浏览器既无环境变量也无本机操作系统概念）。
///
/// 仅收拢编译期必须离开 dart:io 的零星查询；进程管理等成块逻辑在
/// backend_launcher 的条件导出里。
export 'platform_env_stub.dart'
    if (dart.library.io) 'platform_env_io.dart';
