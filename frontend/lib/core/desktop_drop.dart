/// 桌面端「把文件拖进窗口」的条件导出。
///
/// - 有 `dart:io` 的平台：用 `desktop_drop` 接收原生拖放，读成字节后交给
///   [DropHandler]（与 Web 的 `web_drop` 共用 `DroppedFile` 形态，导入链路
///   完全一致）；
/// - Web：空包装，拖放仍由 `web_drop_web.dart` 接管（浏览器拿不到路径）。
library;

export 'desktop_drop_stub.dart'
    if (dart.library.io) 'desktop_drop_io.dart';
