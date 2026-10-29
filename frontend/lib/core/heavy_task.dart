/// 大响应的「正在解析 / 正在整理」状态（Web 主线程会冻结，先把话说清楚）。
///
/// Web 上 `compute()` 退化为同步执行，几十 MB 的 `jsonDecode` / `jsonEncode`
/// 会让画面停住几百毫秒到数秒。这里只放一个字符串：`ApiClient` 在开始解析
/// 前写入并等一帧（`nextWebPaint`），解析结束清空；状态栏据此显示进度圈，
/// 用户就知道「卡住」不是卡死。
///
/// 桌面/移动端不写（那边的重活在后台 isolate，界面照常响应）。
library;

import 'package:flutter/foundation.dart';

class HeavyTask {
  HeavyTask._();

  /// 非空 = 正在做重活，内容直接展示给用户（如「正在解析 12.4 MB 数据…」）。
  static final ValueNotifier<String?> message = ValueNotifier<String?>(null);
}
