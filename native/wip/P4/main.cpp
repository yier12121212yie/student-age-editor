// wip/P4/main.cpp — backend_wip entry: production server_main + P4's networking
// and artifact routes (TTS, AI image, update check, AA media, base data).
// build_router() already installs wave-1 system/mods/cfg; extra_routes grafts
// ours on top (CONVENTIONS 9 / tests CMake SA_GROUP_WIP block).
#include "server/api_router.h"

#include "aa.h"
#include "ai_image.h"
#include "base_routes.h"
#include "tts.h"

int main(int argc, char** argv) {
    return sa::server_main(argc, argv, [](sa::Router& r) {
        // base_routes also wires sa::register_base_store (P1/P3a seam).
        sa::register_base_routes(r);
        sa::register_aa_routes(r);
        sa::register_tts_routes(r);
        sa::register_ai_image_routes(r);
        sa::register_update_routes(r);
    });
}
