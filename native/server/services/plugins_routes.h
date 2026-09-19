// server/services/plugins_routes.h — the /api/plugins family (PLUGIN_SPEC §5).
//
// Declarative port of api.py:3006-3127 after the in-process Python plugin
// engine was retired: every endpoint is a fresh scan of
// <plugins_root>/<pid>/manifest.json, so there is no enable state, no loaded
// plugin registry and no code execution. §4 adds the HTTP-service-plugin
// surface on top (plugin_service.{h,cpp} owns the infrastructure): service
// self-descriptions are fetched by explicit refresh (startup / reload /
// install) into a cache that every GET reads without touching the network.
// Mounted by api_router.cpp after register_domain_tools_routes (the family
// moved out of that file with R4).
//
//   GET    /api/plugins                    目录枚举 -> _entry_for 同键形状（+§4 error/service_status）
//   GET    /api/plugins/ui                 manifest ui.panels + §4 service panels 聚合
//   GET    /api/plugins/ui/flow_cards      manifest ui.flow_cards + §4 service cards（线格式冻结）
//   GET    /api/plugins/agent/tools        §4 service agent_tools 聚合（声明型恒空贡献）
//   POST   /api/plugins/agent/exec         §4：路由到 owning service 代理执行
//   GET    /api/plugins/<pid>              详情（未命中 404 "plugin not found"）
//   ALL    /api/plugins/service/<pid>/<subpath>  §4 代理（GET/POST/PUT/DELETE）
//   GET    /api/plugins/<pid>/panel/<panel_id>   声明面板；service 插件代理动态内容
//   POST   /api/plugins/install            base64 zip 安装（装后 refresh_one）
//   POST   /api/plugins/install_path       本地 zip 路径安装（装后 refresh_one）
//   POST   /api/plugins/reload             重扫目录 + 重拉 §4 自描述（同步）
//   POST   /api/plugins/<pid>/enable       410（§5 永久废弃）
//   POST   /api/plugins/<pid>/disable      410（§5 永久废弃）
//   DELETE /api/plugins/<pid>              递归删目录（纯卸载，并清 §4 缓存项）
//
// Not registered on purpose: the GET/POST/PUT/DELETE /api/plugins/<pid>/<rest>
// catch-all proxy fallback — only the explicit /service/<pid>/<subpath> form
// is proxied; anything else stays 404.
#pragma once

#include "server/httpd.h"

namespace sa {

void register_plugins_routes(Router& r);

}  // namespace sa
