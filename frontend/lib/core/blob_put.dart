/// 大文件直传 PUT / 直链下载的条件导出（自托管大模组包 / 大资源 / 导出下载）。
///
/// - Web：`package:web` 的 XMLHttpRequest——[putXFileToUrl] 把 XFile 背后的浏览器
///   Blob 直接 `send()` 给预签名 URL（零 Dart 堆大字节拷贝）；调用方已持有字节
///   时用 [putBytesToUrl]；[getBytesFromUrl] 按预签名直链取回字节（带进度）。
/// - IO 平台：`package:http` 兜底（桌面/安卓的模组导入导出走本机路径与文件选择器，
///   正常不会走到这里）。
library;

export 'blob_put_io.dart' if (dart.library.js_interop) 'blob_put_web.dart';
