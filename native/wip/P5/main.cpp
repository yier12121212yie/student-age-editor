// wip/P5/main.cpp — backend_wip entry: production server_main + P5's cloud
// sync / realtime routes (18 /api/cloud* endpoints). build_router() already
// installs wave-1/2 system..media routes; extra_routes grafts ours on top
// (CONVENTIONS 9 / tests CMake SA_GROUP_WIP block).
#include "server/api_router.h"

#include "cloud_routes.h"

int main(int argc, char** argv) {
    return sa::server_main(argc, argv, [](sa::Router& r) {
        sa::register_cloud_routes(r);
    });
}
