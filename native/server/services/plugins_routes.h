// server/services/plugins_routes.h — the /api/plugins family (PLUGIN_SPEC §5).
//
// Declarative port of api.py:3006-3127 after the in-process Python plugin
// engine was retired: every endpoint is a fresh scan of
// <plugins_root>/<pid>/manifest.json, so there is no enable state, no loaded
// plugin registry and no code execution. Mounted by api_router.cpp after
// register_domain_tools_routes (the family moved out of that file with R4).
//
//   GET    /api/plugins                    目录枚举 -> _entry_for 同键形状
//   GET    /api/plugins/ui                 manifest ui.panels 聚合
//   GET    /api/plugins/ui/flow_cards      manifest ui.flow_cards 聚合（线格式冻结）
//   GET    /api/plugins/agent/tools        恒空（§5：agent 工具走 service 代理，未实现）
//   GET    /api/plugins/<pid>              详情（未命中 404 "plugin not found"）
//   POST   /api/plugins/install            base64 zip 安装
//   POST   /api/plugins/install_path       本地 zip 路径安装
//   POST   /api/plugins/reload             重扫目录（声明型天然幂等）
//   POST   /api/plugins/<pid>/enable       410（§5 永久废弃）
//   POST   /api/plugins/<pid>/disable      410（§5 永久废弃）
//   DELETE /api/plugins/<pid>              递归删目录（纯卸载）
//
// Not registered on purpose (§4/§5): POST /api/plugins/agent/exec and the
// GET/POST/PUT/DELETE /api/plugins/<pid>/<rest> proxy fallback — they had no
// declarative meaning and were 404 in the wave-2 stubs anyway.
#pragma once

#include "server/httpd.h"

namespace sa {

void register_plugins_routes(Router& r);

}  // namespace sa
