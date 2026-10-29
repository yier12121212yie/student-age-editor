/// 浏览器生命周期：离开页面前拦截未保存修改。
///
/// 覆盖四种「离开」：关标签页、刷新（F5 / Ctrl+R）、地址栏跳转、从上一页
/// 返回本页再后退。浏览器只允许应用决定「要不要拦」，弹窗文案与按钮由
/// 浏览器固定（不能自定义），且必须有过用户交互才会显示——这是平台限制，
/// 所以这里只保证「能拦就拦」，不做任何文案承诺。
///
/// 脏判定必须是同步探针：`beforeunload` 不能 await。工作台/编辑器的脏状态
/// 都在 [SaveHub] 与 EditorController 里现成可取（见 app.dart 的接线）。
library;

import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// 现取「是否有未保存修改」。必须同步且足够便宜（事件里直接调用）。
typedef UnsavedProbe = bool Function();

class WebLifecycle {
  WebLifecycle._({required this._isDirty}) {
    web.window.addEventListener('beforeunload', _listener);
  }

  static WebLifecycle? _instance;

  /// 幂等安装：重复调用返回同一实例。脏判定在事件发生时现取，故无需更新。
  static WebLifecycle? install({required UnsavedProbe isDirty}) =>
      _instance ??= WebLifecycle._(isDirty: isDirty);

  static void uninstall() {
    final inst = _instance;
    if (inst == null) return;
    _instance = null;
    web.window.removeEventListener('beforeunload', inst._listener);
  }

  final UnsavedProbe _isDirty;

  /// 同一个 JS 函数引用：removeEventListener 必须拿到注册时的那个对象。
  late final JSFunction _listener = _onBeforeUnload.toJS;

  /// 浏览器事件：只有 preventDefault() 才是现代浏览器的生效信号；
  /// returnValue 用于兼容旧版。
  void _onBeforeUnload(web.Event event) {
    if (!_isDirty()) return;
    event.preventDefault();
    (event as web.BeforeUnloadEvent).returnValue = '';
  }

  void dispose() => uninstall();
}
