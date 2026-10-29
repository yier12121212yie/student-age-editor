#pragma once

#include "server/httpd.h"

namespace sa {

// Registers Mod Semantic Linter and QuickFix endpoints:
//   GET  /api/linter/diagnose
//   POST /api/linter/diagnose
//   POST /api/linter/quickfix
void register_semantic_linter_routes(Router& r);

}  // namespace sa
