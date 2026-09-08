// wip/P3b/main.cpp — backend_wip entry (test/CMakeLists.txt wip isolation
// contract): the production server_main with the P3b domain/tools/attachment/
// resource-pack routes grafted on, exactly as api_router.cpp will mount them
// at merge time.
#include "p3b_domain_tools_routes.h"
#include "server/api_router.h"

int main(int argc, char** argv) {
    return sa::server_main(argc, argv,
                           [](sa::Router& r) { sa::register_domain_tools_routes(r); });
}
