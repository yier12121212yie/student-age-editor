/// 轻量输入防抖工具。
///
/// 搜索框 `onChanged` 里直接 `setState` 会在每个按键上触发一次全表过滤/排序
/// （数千行表格每键数十毫秒），是列表页掉帧的主因之一。用本类把「连续输入
/// 只在停止后执行最后一次」收敛成一处实现，避免每个工作台各抄一份 Timer。
library;

import 'dart:async';

/// 连续调用 [run] 时，只在最后一次调用后静默超过 [delay] 才真正执行。
class Debouncer {
  Debouncer({this.delay = const Duration(milliseconds: 200)});

  final Duration delay;
  Timer? _timer;

  /// 排一次待执行动作（会取消上一次尚未触发的）。
  void run(void Function() action) {
    _timer?.cancel();
    _timer = Timer(delay, action);
  }

  /// 取消尚未触发的动作（`dispose` 里调用，避免用例报「Timer is still pending」）。
  void dispose() {
    _timer?.cancel();
    _timer = null;
  }
}
