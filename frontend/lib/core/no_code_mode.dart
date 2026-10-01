/// 无代码模式的全局开关入口（GUI 与设置页共用一份写穿逻辑）。
///
/// 开关是后端共享状态（editor_env.json 的 no_code_mode，GUI/CLI/TUI 同一份），
/// 所以任何"关闭无代码模式以手动编辑"的逃生口都必须写穿后端，而不是只改本地
/// [AppState]——否则重启后旧的开启态会把用户又锁回点选界面。
library;

import 'api_client.dart';
import 'models.dart';

/// 切换无代码模式并写穿后端共享设置；失败时回滚本地态。
/// 返回是否持久化成功（false = 后端不可达/旧后端无该端点，UI 应提示）。
Future<bool> persistNoCodeMode(bool value) async {
  final state = AppState.current;
  final prev = state?.noCodeMode ?? false;
  state?.setNoCodeMode(value);
  try {
    await ApiClient.instance
        .put('/api/settings/editor', body: {'noCodeMode': value});
    return true;
  } catch (_) {
    state?.setNoCodeMode(prev);
    return false;
  }
}
