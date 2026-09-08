// wip/P2/workspace_routes — POST /api/workspace + the /api/oobe/* family
// (port of api.py:768-775 and api.py:784-848, state layer on cli/oobe.py).
//
// Merge note for the orchestrator: same shape as the wave-1 services —
//   namespace sa { void register_workspace_routes(Router& r); }
// to be mounted in server/api_router.cpp after register_mods_routes.
#pragma once

#include "server/httpd.h"

namespace sa {

void register_workspace_routes(Router& r);

// Exposed for [p2] tests: the GET /api/oobe/status payload (cli/oobe.py
// snapshot + api.py:794-796 server_workspace overlay).
json oobe_status_payload();

}  // namespace sa
