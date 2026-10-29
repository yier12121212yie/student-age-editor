/// 浏览器「把文件拖进窗口」的条件导出。
///
/// - Web：接管 window 的 dragenter/dragover/drop（**必须 preventDefault**，
///   否则浏览器会直接打开被拖入的文件、整页跳走，未保存的修改随之丢失），
///   读成字节后交给 Dart 侧导入；
/// - 其他平台：空实现（桌面端目前没有拖放导入，不做行为变更）。
library;

export 'web_drop_stub.dart'
    if (dart.library.js_interop) 'web_drop_web.dart';
