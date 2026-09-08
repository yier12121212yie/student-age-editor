// wip/P1/main.cpp — backend_wip entry: the production server plus this group's
// semantic routes (schema/dicts/validate/effect_suggest/effect_validate/bugfix).
// server_main() already installs the wave-1 build_router; extra_routes grafts
// ours on top (CONVENTIONS 9 / tests/CMakeLists.txt SA_GROUP_WIP block).
#include "semantic_routes.h"
#include "server/api_router.h"

int main(int argc, char** argv) {
    return sa::server_main(argc, argv, [](sa::Router& r) { sa::register_semantic_routes(r); });
}
