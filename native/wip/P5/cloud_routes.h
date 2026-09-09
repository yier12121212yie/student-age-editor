// wip/P5/cloud_routes.h — registers the 18 /api/cloud* endpoints (api.py
// 2715-3002). The orchestrator mounts register_cloud_routes on the bus at
// merge time; the wip build grafts it via main.cpp's extra_routes hook.
#pragma once

#include "server/httpd.h"

namespace sa {

void register_cloud_routes(Router& r);

}  // namespace sa
