// wip/P4/test_p4_flow_assets.cpp — flow_assets.py CG/BGM pure-function ports.
#include <catch_amalgamated.hpp>

#include <string>

#include "flow_assets.h"

using namespace sa;
using json = nlohmann::ordered_json;

TEST_CASE("is_cg_image: resolution floor + group + ratio + key veto", "[p4][flow]") {
    // Below the 1280x720 hard floor -> never CG.
    CHECK_FALSE(flow::is_cg_image("foo", "textures_assets_cg_0123456789abcdef0.bundle", 1279, 1080));
    CHECK_FALSE(flow::is_cg_image("foo", "textures_assets_cg_0123456789abcdef0.bundle", 1920, 719));
    // Deterministic CG group passes once the floor is met.
    CHECK(flow::is_cg_image("scene_open", "textures_assets_cg_0123456789abcdef0.bundle", 1920, 1080));
    CHECK(flow::is_cg_image("x", "textures_assets_big_0123456789abcdef0.bundle", 1600, 900));
    // sactx-* SpriteAtlas page veto even at CG resolution.
    CHECK_FALSE(flow::is_cg_image("sactx-0-2048x2048", "textures_assets_cg_0123456789abcdef0.bundle",
                                  2048, 2048));
    // Non-texture bundle that ends with .bundle and isn't a cg group -> veto.
    CHECK_FALSE(flow::is_cg_image("x", "localization_locales_assets_all.bundle", 1920, 1080));
    // Mixed group (""/bg) with sane 16:9 ratio + clean key -> CG.
    CHECK(flow::is_cg_image("bg_forest", "textures_assets_bg_0123456789abcdef0.bundle", 1920, 1080));
    // Mixed group but extreme aspect -> veto.
    CHECK_FALSE(flow::is_cg_image("banner", "textures_assets__0123456789abcdef0.bundle", 4000, 400));
    // Key veto (icon/head/atlas/spine) on a mixed group.
    CHECK_FALSE(flow::is_cg_image("role_head", "textures_assets_bg_0123456789abcdef0.bundle",
                                  1920, 1080));
    // DLC "v1xx" group counts as mixed.
    CHECK(flow::is_cg_image("event177", "textures_assets_v177_0123456789abcdef0.bundle", 1600, 900));
    // Missing size (0) -> below floor -> false (caller's fallback path).
    CHECK_FALSE(flow::is_cg_image("x", "pack/tex/a.webp", 0, 0));
    // Flat pack file (no .bundle): group None, name not .bundle -> heuristic applies.
    CHECK(flow::is_cg_image("cover", "pack/tex/cover.webp", 1920, 1080));
    CHECK_FALSE(flow::is_cg_image("cover_icon", "pack/tex/cover_icon.webp", 1920, 1080));
}

TEST_CASE("music_url_basenames + is_music", "[p4][flow]") {
    json rows;
    rows["1"] = json{{"type", 1}, {"url", "audio/bgm/Theme_Song"}};
    rows["2"] = json{{"type", 1}, {"url", "audio/bgm/credits.ogg"}};
    rows["3"] = json{{"type", 0}, {"url", "audio/sfx/click"}};
    rows["4"] = json{{"type", "x"}, {"url", "audio/bgm/bad"}};  // int() raise -> skipped
    auto urls = flow::music_url_basenames(rows);
    CHECK(urls.count("theme_song") == 1);
    CHECK(urls.count("credits") == 1);
    CHECK(urls.count("click") == 0);
    CHECK(urls.count("bad") == 0);

    // bgm bundle grouping wins.
    CHECK(flow::is_music("anything", "audios_assets_bgm_deadbeefdeadbeef0.bundle", urls));
    // role voice / ogc sfx excluded even if bgm-ish.
    CHECK_FALSE(flow::is_music("v", "audios_assets_role_0123456789abcdef0.bundle", urls));
    // TTS dubs excluded.
    CHECK_FALSE(flow::is_music("audio/tts/x", "whatever", urls));
    // key matches a known BGM url basename.
    CHECK(flow::is_music("theme_song", "pack/aud/theme_song.ogg", urls));
    // not bgm, not in urls.
    CHECK_FALSE(flow::is_music("footstep", "pack/aud/footstep.ogg", urls));
}
