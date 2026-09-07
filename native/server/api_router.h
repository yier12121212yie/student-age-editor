// server/api_router: the route-bus assembly point (CONVENTIONS 1).
//
// Every service file exports `register_<name>_routes(Router&)`; build_router()
// wires them in the api.py registration order and installs cross-cutting hooks
// (select_mod -> mod-cfgs invalidation; the preview invalidator stays a
// wave-3 seam).
#pragma once

#include "server/httpd.h"

namespace sa {

// The full wave-1 router: system (/api/ping /api/state /api/shutdown /api/perf),
// mods (/api/mods*), cfg/history (/api/cfg* /api/history*).
// Endpoints of later waves answer 404 {"error":"no route: ..."} until their
// register function lands here.
Router build_router();

// Hook seam: preview cache invalidation (preview_service is wave 3). Handlers
// call this after every successful write exactly where api.py does; until the
// real owner registers, it is a no-op.
void set_preview_invalidator_hook(std::function<void()> fn);
void invalidate_preview_cache();

}  // namespace sa
