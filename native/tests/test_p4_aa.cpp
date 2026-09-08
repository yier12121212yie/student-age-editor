// wip/P4/test_p4_aa.cpp — ARTIFACT_FORMAT §8 six rules over AaIndex/DecodedPack
// plus /api/aa route empty-degradation + non-decodable (422) shapes. [p4].
#include <catch_amalgamated.hpp>

#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <string>

#include "test_support.h"
#include "sa_core/paths.h"
#include "server/state.h"
#include "aa.h"

using namespace sa;
namespace fs = std::filesystem;

namespace {
void wfile(const fs::path& p, const std::string& content) {
    fs::create_directories(p.parent_path());
    std::ofstream f(p, std::ios::binary);
    f.write(content.data(), static_cast<std::streamsize>(content.size()));
}

json game_index_json() {
    return json::parse(R"({
        "v": 3, "fp": "",
        "tex": {
            "img_brickgame_tri": ["D:\\aa\\brickgame_f83284d28d95601afe637999a538060f.bundle", -6961645949212346451],
            "scene_open": ["D:\\aa\\textures_assets_cg_0123456789abcdef0.bundle", 42]
        },
        "aud": {"ingame_get_common_fly": ["D:\\aa\\audios_assets_bgm_4be02589f9be795da5d947415674cd5c.bundle", -9059115929332620942]},
        "txt": {"personcfg": ["D:\\aa\\cfgs_assets__5511f207679e32ec9da13b1d2a97c239.bundle", 1234]},
        "cabs": {"cab-cdee755dc00829c1788204d4ef707887": "D:\\aa\\localization-locales_assets_all.bundle"},
        "texmeta": {"scene_open": [1920, 1080]},
        "bundles": ["D:\\aa\\textures_assets_cg_0123456789abcdef0.bundle"]
    })");
}
}  // namespace

TEST_CASE("norm_key: splitext + ' #' suffix + strip + lower (dots/unicode kept)", "[p4][aa]") {
    CHECK(norm_key("Img_BrickGame.png") == "img_brickgame");
    CHECK(norm_key("a.b.json") == "a.b");               // dots preserved (splitext only drops ".json")
    CHECK(norm_key("Foo #extra") == "foo");             // " #" suffix dropped
    CHECK(norm_key("  Trim_Me  ") == "trim_me");
    CHECK(norm_key("你好_tex.png") == "你好_tex");       // unicode preserved, lower no-op
    CHECK(norm_key("DOTS.KEEP.txt") == "dots.keep");
}

TEST_CASE("§8.1 AaIndex: int64 path_id preserved (no double truncation)", "[p4][aa]") {
    AaIndex idx;
    REQUIRE(idx.load_from_json(game_index_json()));
    // -6961645949212346451 exceeds double's 2^53 exact-integer range; parsing to
    // double would corrupt it. Assert the exact int64 round-trips.
    CHECK(idx.tex_path_id("img_brickgame_tri") == -6961645949212346451LL);
    CHECK(idx.tex_path_id("scene_open") == 42);
    // aud key int64 too.
    CHECK(idx.aud_bundle("ingame_get_common_fly").find("bgm") != std::string::npos);
}

TEST_CASE("§8.1 key lookup normalizes query; §8 bundle grouping preserved", "[p4][aa]") {
    AaIndex idx;
    REQUIRE(idx.load_from_json(game_index_json()));
    CHECK(idx.has_tex("IMG_BRICKGAME_TRI.PNG"));   // normalized on the way in
    CHECK_FALSE(idx.has_tex("nope"));
    CHECK(idx.has_aud("ingame_get_common_fly"));
    CHECK(idx.has_txt("PersonCfg"));
    // Grouping survives as the bundle BASENAME (flow_assets needs it).
    CHECK(idx.tex_bundle("scene_open").find("textures_assets_cg") != std::string::npos);
}

TEST_CASE("§8.4 texmeta sparse -> missing key yields nullopt (CG fallback)", "[p4][aa]") {
    AaIndex idx;
    REQUIRE(idx.load_from_json(game_index_json()));
    CHECK(idx.has_texmeta());
    auto have = idx.tex_meta("scene_open");
    REQUIRE(have.has_value());
    CHECK((*have)[0] == 1920);
    CHECK(idx.tex_meta("img_brickgame_tri") == std::nullopt);  // not in texmeta
}

TEST_CASE("§8.3 partial defaults false; decoded-pack form rejected", "[p4][aa]") {
    AaIndex idx;
    json j = game_index_json();
    CHECK_FALSE(idx.partial());                    // key absent -> false
    CHECK(idx.load_from_json(j));
    j["partial"] = true;
    AaIndex idx2;
    REQUIRE(idx2.load_from_json(j));
    CHECK(idx2.partial());
    // A decoded pack's aa_index.json ("decoded": true, key lists) is NOT a game
    // index form -> load rejects it.
    AaIndex dp;
    json djson;
    djson["v"] = 3;
    djson["decoded"] = true;
    djson["tex"] = json::array();
    CHECK_FALSE(dp.load_from_json(djson));
}

TEST_CASE("§8.2 bundle relocation by basename; cabs not relied upon", "[p4][aa]") {
    auto aa = sat::make_temp_dir("p4_aa_reloc");
    // A bundle that DOES exist under the aa dir, under a different directory than
    // recorded (simulating a moved Steam library).
    std::string fname = "brickgame_f83284d28d95601afe637999a538060f.bundle";
    auto real = aa / "nested" / fname;
    wfile(real, "not-a-bundle");
    AaIndex idx;
    REQUIRE(idx.load_from_json(game_index_json()));
    // Recorded path is a non-existent drive path; relocation finds it by name.
    CHECK_FALSE(sa_core::paths::is_file(idx.tex_bundle("img_brickgame_tri")));
    int n = idx.relocate_bundles(sa_core::paths::path_to_utf8(aa));
    CHECK(n >= 1);
    CHECK(sa_core::paths::is_file(idx.tex_bundle("img_brickgame_tri")));
    CHECK(idx.tex_path_id("img_brickgame_tri") == -6961645949212346451LL);  // id kept
}

TEST_CASE("DecodedPack: tex/aud scan + txt from decoded index + header size", "[p4][aa]") {
    auto pack = sat::make_temp_dir("p4_aa_pack");
    // PNG header (signature + IHDR) declaring 4x2.
    std::string png;
    const unsigned char sig[] = {0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
                                 'I', 'H', 'D', 'R', 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x02};
    png.assign(reinterpret_cast<const char*>(sig), sizeof(sig));
    wfile(pack / "tex" / "Hero.png", png);
    wfile(pack / "aud" / "note.Ogg", "OGGDATA");
    wfile(pack / "aa_index.json", R"({"v":3,"decoded":true,"tex":["hero"],"aud":["note"],"txt":["PersonCfg","TalkCfg"]})");
    DecodedPack dp;
    dp.refresh(sa_core::paths::path_to_utf8(pack));
    REQUIRE(dp.active());
    CHECK(dp.tex_count() == 1);
    CHECK(dp.aud_count() == 1);
    auto tk = dp.tex_keys();
    REQUIRE(tk.size() == 1);
    CHECK(tk[0] == "hero");                         // basename stem, lowercased
    CHECK_FALSE(dp.aud_path("note").empty());
    auto sz = dp.tex_meta("HERO");
    REQUIRE(sz.has_value());
    CHECK((*sz)[0] == 4);
    CHECK((*sz)[1] == 2);
    auto rd = dp.read_file(dp.tex_path("hero"));
    REQUIRE(rd.has_value());
    CHECK(rd->second == ".png");
    CHECK(tex_mime(".png") == "image/png");
    CHECK(aud_mime(".ogg") == "audio/ogg");
    // txt keys come from the decoded index list.
    CHECK(dp.txt_keys() == std::vector<std::string>{"PersonCfg", "TalkCfg"});
}

// ---- route-level behaviour -----------------------------------------------

TEST_CASE("/api/aa/* empty-degradation (no game index, no pack)", "[p4][aa][routes]") {
    auto root = sat::make_temp_dir("p4_aa_empty");
    sa::detail::set_editor_root(sa_core::paths::path_to_utf8(root));  // no _cache here
    reset_aa_singletons_for_test();
    _putenv("EDITOR_DECODED_PACK_DIR=");
    reset_aa_singletons_for_test();
    {
        std::lock_guard<std::mutex> lk(STATE().mu_);
        STATE().aa_status = "idle";
        STATE().aa_error.clear();
        STATE().aa_dirs.clear();
    }
    Router r;
    register_aa_routes(r);
    auto st = sat::call_router(r, "GET", "/api/aa/status");
    REQUIRE(st.status == 200);
    CHECK(st.json_payload["status"] == "idle");
    CHECK(st.json_payload["bundled"].is_null());

    auto keys = sat::call_router(r, "GET", "/api/aa/keys", {{"limit", "5"}});
    REQUIRE(keys.status == 200);
    CHECK(keys.json_payload["status"] == "idle");
    CHECK(keys.json_payload["tex"].empty());
    CHECK(keys.json_payload["aud"].empty());
    CHECK(keys.json_payload["txt"].empty());

    auto prev = sat::call_router(r, "POST", "/api/aa/preview", {}, json{{"kind", "tex"}, {"key", "x"}});
    REQUIRE(prev.status == 400);
    CHECK(std::string(prev.json_payload["error"]).find("not ready") != std::string::npos);

    auto scan = sat::call_router(r, "POST", "/api/aa/scan", {}, json::object());
    REQUIRE(scan.status == 500);
    CHECK(scan.json_payload["error"] == "unityfs unavailable");

    reset_aa_singletons_for_test();
    sa::detail::set_editor_root("");
}

TEST_CASE("/api/aa/preview of a game-index tex answers 422 (C++ cannot decode)", "[p4][aa][routes]") {
    auto root = sat::make_temp_dir("p4_aa_cached");
    std::string cache = sa_core::paths::path_to_utf8(
        root / "_cache" / "aa_index");
    wfile(fs::path(cache) / "aa_index.json", game_index_json().dump());
    sa::detail::set_editor_root(cache.empty() ? std::string() : sa_core::paths::path_to_utf8(root));
    reset_aa_singletons_for_test();
    _putenv("EDITOR_DECODED_PACK_DIR=");
    reset_aa_singletons_for_test();
    {
        std::lock_guard<std::mutex> lk(STATE().mu_);
        STATE().aa_status = "idle";
    }
    Router r;
    register_aa_routes(r);
    auto keys = sat::call_router(r, "GET", "/api/aa/keys");
    REQUIRE(keys.status == 200);
    CHECK(keys.json_payload["status"] == "ready");            // cached index flips ready
    auto tex = keys.json_payload["tex"];
    bool has_scene = false;
    for (auto& k : tex) if (k == "scene_open") has_scene = true;
    CHECK(has_scene);
    // present in the game index but no decoded pack -> cannot decode.
    auto prev = sat::call_router(r, "POST", "/api/aa/preview", {},
                                 json{{"kind", "tex"}, {"key", "scene_open"}});
    CHECK(prev.status == 422);
    auto miss = sat::call_router(r, "POST", "/api/aa/preview", {},
                                 json{{"kind", "tex"}, {"key", "nope"}});
    CHECK(miss.status == 404);
    reset_aa_singletons_for_test();
    sa::detail::set_editor_root("");
}
