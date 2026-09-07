// server/api_router.cpp — the route bus (CONVENTIONS 1: the ONLY assembly point).
#include "server/api_router.h"

#include <functional>

#include "server/cfg_cache.h"
#include "server/services/cfg_routes.h"
#include "server/services/mods_routes.h"
#include "server/services/system_routes.h"
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

    register_system_routes(r);
    register_mods_routes(r);
    register_cfg_routes(r);
    return r;
}

}  // namespace sa
