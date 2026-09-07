// server/services/cfg_routes: /api/cfg*, /api/history* + cache wiring.
#pragma once

#include "server/httpd.h"

namespace sa {
void register_cfg_routes(Router& r);
}  // namespace sa
