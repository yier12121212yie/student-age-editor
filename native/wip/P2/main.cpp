// wip/P2/main.cpp — backend_wip entry (test/CMakeLists.txt wip isolation
// contract): the production server_main with the P2 workspace/oobe routes
// grafted on, exactly as api_router.cpp will mount them at merge time.
#include <functional>

#include "server/api_router.h"
#include "workspace_routes.h"

int main(int argc, char** argv) {
    return sa::server_main(argc, argv,
                           [](sa::Router& r) { sa::register_workspace_routes(r); });
}
