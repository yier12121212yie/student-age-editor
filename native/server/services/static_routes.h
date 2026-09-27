// server/services/static_routes.h — static hosting of the web editor build
// (网页版计划 M1.2). Registered by run.cpp LAST (after build_router and any
// extra_routes) when --web-root is given: the catch-all GET only ever sees
// paths that matched no API route, so every existing endpoint keeps priority
// and the default (no --web-root) process registers nothing from this file.
//
// This serves the separately-distributed `flutter build web` output — the
// desktop installers never contain it (发行解耦). Same-origin by design (the
// browser loads the page and calls /api on the same host), which is why the
// default loopback origin tier works unchanged for 127.0.0.1 access.
#pragma once

#include <string>

#include "server/httpd.h"

namespace sa {

void register_static_routes(Router& r, const std::string& web_root);

}  // namespace sa
