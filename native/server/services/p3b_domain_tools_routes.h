// wip/P3b route surface (official layout at merge:
// server/services/domain_tools_routes.*; merge note: this ONE register function
// covers the three api.py families — AI 工具沙箱 / AI 细分领域 / 附件上传 /
// 资源扩展包 / manifest / plugins 只读桩 — so the orchestrator mounts it once).
//
//   GET  /api/tools/list|read|stat, PUT /api/tools/write
//   GET  /api/ai/domains
//   GET/PUT/POST/DELETE /api/ai/domain/item, GET /api/ai/domain/items
//   GET/PUT /api/ai/settings
//   POST /api/ai/upload
//   GET/POST/DELETE /api/resource_packs* (full set)
//   GET  /api/manifest/status
//   GET  /api/plugins family — READ-ONLY STUBS (shape == golden; in-process
//        plugins were retired; flow_cards additionally serves the
//        declarative manifest-directory reader, full spec wave 3).
#pragma once

#include "server/httpd.h"

namespace sa {
void register_domain_tools_routes(Router& r);
}  // namespace sa
