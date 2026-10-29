/// 浏览器生命周期钩子的条件导出（关标签 / 刷新 / 离开页面前的未保存拦截）。
///
/// - Web：注册 `beforeunload`，脏状态下让浏览器弹「确定离开吗」；
/// - 其他平台：空实现（桌面退出由 AppLifecycleListener 负责，见 app.dart）。
///
/// 为什么不接管浏览器「后退」：本仓库没有 Router/URL 路由，按后退离开本页
/// 同样会触发 `beforeunload`；额外用 `popstate` + 哨兵 history 拦截反而会
/// 吃掉用户的一次返回（无历史时表现为「点了没反应」），故不做。
library;

export 'web_lifecycle_stub.dart'
    if (dart.library.js_interop) 'web_lifecycle_web.dart';
