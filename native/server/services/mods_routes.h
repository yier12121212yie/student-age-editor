// server/services/mods_routes: /api/mods listing + select/create/delete.
#pragma once

#include "server/httpd.h"

namespace sa {
void register_mods_routes(Router& r);
}  // namespace sa
