/// 部署形态能力位（Web 本机 / Web 自托管 / 桌面 / 移动端）。
///
/// 自托管（`backend_gateway`）把账号放进服务器沙箱：没有本机 Steam 客户端、
/// 服务型插件代理被网关 403、工作区由管理员托管。UI 用这里的判断把「按设计
/// 不可用」提前说清楚，而不是等用户点击后才报错。
///
/// 注意：这里只回答**部署形态**问题；AI/TTS/生图等由 policy 下发的开关仍以
/// `AiPolicy` 为准（管理员可显式开启）。
library;

import 'package:flutter/foundation.dart' show kIsWeb;

import 'auth_state.dart';

class DeploymentCaps {
  DeploymentCaps._();

  /// 浏览器 + 网关托管登录。
  static bool get hostedWeb =>
      kIsWeb && AuthState.current?.mode == AuthMode.hosted;

  /// 本机浏览器版（浏览器直连本机 backend，无网关）。
  static bool get localWeb =>
      kIsWeb && AuthState.current?.mode == AuthMode.local;

  /// Steam 创意工坊发布需要后端所在机器安装并登录 Steam 客户端。
  /// 自托管服务器通常没有，故禁用；本机 Web 与桌面可用。
  static bool get steamWorkshopAvailable => !hostedWeb;

  /// `/api/plugins/service/*` 与 `/api/plugins/agent/*` 在托管模式下由网关
  /// 封禁（SSRF / 任意工具执行面）。声明型插件不受影响。
  static bool get pluginServiceAvailable => !hostedWeb;

  /// 本机子进程能力（stdio MCP）。Web 端是否可用还取决于后端 policy
  /// (`mcp_stdio_available`)，这里只排除托管形态的默认值。
  static bool get localStdioProcessAllowed => !hostedWeb;
}
