// server/api_router.cpp — the route bus (CONVENTIONS 1: the ONLY assembly point).
#include "server/api_router.h"

#include <functional>

#include "server/cfg_cache.h"
#include "server/ai_dicts_route.h"
#include "server/services/aa.h"
#include "server/services/ai_image.h"
#include "server/services/assets_routes.h"
#include "server/services/base_routes.h"
#include "server/services/cfg_routes.h"
#include "server/services/cloud_routes.h"
#include "server/services/content_routes.h"
#include "server/services/deleted_routes.h"
#include "server/services/mods_routes.h"
#include "server/services/p3b_domain_tools_routes.h"
#include "server/services/plugins_routes.h"
#include "server/services/semantic_routes.h"
#include "server/services/system_routes.h"
#include "server/services/tts.h"
#include "server/services/workspace_routes.h"
#include "server/state.h"

namespace sa {
namespace {
std::function<void()> g_preview_invalidator_hook;
}  // namespace

void set_preview_invalidator_hook(std::function<void()> fn) {
    g_preview_invalidator_hook = std::move(fn);
}

void invalidate_preview_cache() {
    // api.py calls preview_service.invalidate_cache() after every cfg write and
    // undo/redo. Wave 3 owns that cache; until then this seam is a no-op.
    if (g_preview_invalidator_hook) g_preview_invalidator_hook();
}

Router build_router() {
    Router r;
    // select_mod must invalidate the mod-cfgs view; wire it before any route
    // can run.
    set_mod_cfgs_invalidator(&invalidate_mod_cfgs_cache);
    set_preview_invalidator(&invalidate_preview_cache);

    // Wave-1 core; registration order follows api.py to avoid pattern shadow.
    register_system_routes(r);
    register_mods_routes(r);
    register_cfg_routes(r);
    register_deleted_routes(r);  // P8 Tombstone Semantics
    // Wave-2 merge: semantic (P1) first per its report's ordering note, then
    // workspace (P2), content (P3a), AI domain/tools (P3b), media (P4).
    register_semantic_routes(r);      // P1
    register_workspace_routes(r);     // P2
    register_content_routes(r);       // P3a
    register_ai_dicts_route(r);       // orchestrator gap-fill (ai.py:1674)
    register_domain_tools_routes(r);  // P3b
    // R4: the /api/plugins family (PLUGIN_SPEC §5 declarative implementation).
    // It used to be part of register_domain_tools_routes as read-only stubs;
    // statics-before-<pid> ordering is handled inside register_plugins_routes,
    // and no other family matches /api/plugins/*.
    register_plugins_routes(r);
    register_base_routes(r);          // P4 — installs the base_store seam
    register_aa_routes(r);
    // 只读派生视图 /api/assets/{catalog,tags}：复用 aa 索引 + 解码包单例，
    // 标签现算，不新增产物（additive，不进 golden）。
    register_assets_routes(r);
    register_tts_routes(r);
    register_ai_image_routes(r);
    register_update_routes(r);
    // P5 wave-3: cloud 18 路由 + realtime；register 尾部对齐 api.py:3149 触发
    // rt_auto_start（3s 延迟线程，等同 Python build_router 期行为）。
    register_cloud_routes(r);
    return r;
}

}  // namespace sa
