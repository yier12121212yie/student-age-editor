// backend: the native (C++) StudentAge editor server — thin entry.
//
// All process logic lives in server/run.cpp (sa::server_main), so wave-2+
// atelier harnesses can boot the identical production server with their own
// extra routes. CLI mirrors the Python launcher:
//   backend --port N [--write-port FILE]
//           [--workspace-root DIR] [--mod-root DIR] [--mod-name NAME]
#include "server/api_router.h"

int main(int argc, char** argv) { return sa::server_main(argc, argv); }
