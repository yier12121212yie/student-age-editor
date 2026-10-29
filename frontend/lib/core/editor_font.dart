// 内置中文字体的跨平台入口（Web 真正加载，桌面/移动端空实现）。
//
// 为什么 Web 需要内置字体：CanvasKit 用不了系统字体，中文只能靠 Flutter 引擎
// 的 fallback 字体服务按 unicode 切片从网络下载。该服务在首屏经常只登记极少
// 数切片就停止（见 tools/build_web_cjk_font.py 顶部说明），导致界面出现豆腐块
// （□）。因此网页版随包带一份覆盖 GB2312 的中文字体，并把它设为主题字体。
export 'editor_font_io.dart'
    if (dart.library.js_interop) 'editor_font_web.dart';
