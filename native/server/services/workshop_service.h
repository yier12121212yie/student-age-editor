#pragma once

#include "server/httpd.h"

namespace sa {

// Registers Steam Workshop publishing endpoints:
//   GET  /api/workshop/status
//   POST /api/workshop/publish
//   GET  /api/workshop/publish-progress
//   POST /api/workshop/publish-cancel
void register_workshop_routes(Router& r);

}  // namespace sa
