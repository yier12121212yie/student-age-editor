// server/services/system_routes: /api/ping /api/state /api/shutdown /api/perf.
#pragma once

#include "server/httpd.h"

namespace sa {
void register_system_routes(Router& r);
}  // namespace sa
