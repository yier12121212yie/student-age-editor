// wip/P4/base_routes.h — /api/base/{status,load,events,extract} (P4).
//
// register_base_routes() also performs sa::register_base_store(...) so the P1
// (/api/base_ids) and P3a (/api/search/talk) consumers find a live data
// provider. Route bodies are thin wrappers over the BaseStore query API; the
// data method `search_talks` lives on BaseStore for P3a's route to call through
// the seam (we deliberately do NOT register /api/search/talk here).
#pragma once
#include "server/httpd.h"

namespace sa {
void register_base_routes(Router& r);
}  // namespace sa
