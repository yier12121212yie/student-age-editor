// server/services/deleted_routes: /api/cfg/deleted_talks endpoint for P8 tombstone semantics.
#pragma once

#include "server/httpd.h"

namespace sa {
void register_deleted_routes(Router& r);
}  // namespace sa
