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

TEST_CASE("DecodedPack: truncated PNG header does not read out of bounds", "[p4][aa]") {
    // 16 bytes = 8-byte signature + "IHDR" + 4 bytes. A valid PNG signature with
    // "IHDR" at offset 12 can be as short as 16 bytes, but the width/height live
    // at 16..23, so image_size must guard on >= 24 instead of indexing past the
    // end of the string (previously unchecked UB).
    auto pack = sat::make_temp_dir("p4_aa_trunc");
    std::string png;
    const unsigned char sig[] = {0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00,
                                 0x00, 0x0D, 'I',  'H',  'D',  'R'};
    png.assign(reinterpret_cast<const char*>(sig), sizeof(sig));
    wfile(pack / "tex" / "Broken.png", png);
    wfile(pack / "aa_index.json",
          R"({"v":3,"decoded":true,"tex":["broken"],"aud":[],"txt":[]})");
    DecodedPack dp;
    dp.refresh(sa_core::paths::path_to_utf8(pack));
    REQUIRE(dp.active());
    CHECK(dp.tex_meta("broken") == std::nullopt);  // unrecognised -> no size, no OOB
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

TEST_CASE("/api/aa/preview falls back to EDITOR_PORTRAIT_DIR (人物图片扩展·本地)",
          "[p4][aa][routes][portraits]") {
    // 既无游戏索引也无活动包：仅配置人物图片本地目录时，preview 不应 400，
    // 而应按解码包语义从 tex/<文件> 提供立绘字节。
    auto root = sat::make_temp_dir("p4_aa_portrait_root");
    auto portraits = sat::make_temp_dir("p4_aa_portrait_pack");
    sa::detail::set_editor_root(sa_core::paths::path_to_utf8(root));
    wfile(portraits / "tex" / "role_xiaomei.webp", std::string("RIFFwebp-bytes"));
    _putenv(("EDITOR_PORTRAIT_DIR=" + sa_core::paths::path_to_utf8(portraits))
                .c_str());
    _putenv("EDITOR_PORTRAIT_BASE_URL=");
    _putenv("EDITOR_DECODED_PACK_DIR=");
    reset_aa_singletons_for_test();
    {
        std::lock_guard<std::mutex> lk(STATE().mu_);
        STATE().aa_status = "idle";
        STATE().aa_error.clear();
    }
    Router r;
    register_aa_routes(r);
    // 键含 '/' 时走 safe_asset_name（'/'→'_'）回退：命中 role_xiaomei.webp。
    auto hit = sat::call_router(r, "POST", "/api/aa/preview", {},
                                json{{"kind", "tex"}, {"key", "role/xiaomei"}});
    REQUIRE(hit.status == 200);
    CHECK(hit.json_payload["kind"] == "tex");
    CHECK(!hit.json_payload["data"].get<std::string>().empty());
    auto miss = sat::call_router(r, "POST", "/api/aa/preview", {},
                                 json{{"kind", "tex"}, {"key", "role/nobody"}});
    CHECK(miss.status == 404);
    // 清理：避免 EDITOR_PORTRAIT_DIR 泄漏到后续用例。
    _putenv("EDITOR_PORTRAIT_DIR=");
    reset_aa_singletons_for_test();
    sa::detail::set_editor_root("");
}

TEST_CASE("/api/aa/preview returns a COS URL for portraits (人物图片扩展·对象存储)",
          "[p4][aa][routes][portraits]") {
    // 配置对象存储 base_url 时：本地目录未命中，preview 返回 200 + url，
    // 服务端不再代下载图片（客户端自行 GET）。
    auto root = sat::make_temp_dir("p4_aa_portrait_url_root");
    sa::detail::set_editor_root(sa_core::paths::path_to_utf8(root));
    _putenv("EDITOR_PORTRAIT_DIR=");
    _putenv("EDITOR_PORTRAIT_BASE_URL=https://cos.example.com/portraits/");
    _putenv("EDITOR_DECODED_PACK_DIR=");
    reset_aa_singletons_for_test();
    {
        std::lock_guard<std::mutex> lk(STATE().mu_);
        STATE().aa_status = "idle";
        STATE().aa_error.clear();
    }
    Router r;
    register_aa_routes(r);
    auto hit = sat::call_router(r, "POST", "/api/aa/preview", {},
                                json{{"kind", "tex"}, {"key", "role/xiaomei"}});
    REQUIRE(hit.status == 200);
    CHECK(hit.json_payload["kind"] == "tex");
    CHECK(hit.json_payload["url"] ==
          "https://cos.example.com/portraits/tex/role_xiaomei.webp");
    CHECK(!hit.json_payload.contains("data"));
    // 清理：避免 base_url 泄漏到后续用例。
    _putenv("EDITOR_PORTRAIT_BASE_URL=");
    reset_aa_singletons_for_test();
    sa::detail::set_editor_root("");
}

TEST_CASE("/api/aa/preview falls back to EDITOR_BG_DIR (背景图片扩展·本地)",
          "[p4][aa][routes][backgrounds]") {
    // 与人物图片扩展同构：仅配置背景本地目录时，preview 从 tex/<文件> 出背景字节。
    auto root = sat::make_temp_dir("p4_aa_bg_root");
    auto backgrounds = sat::make_temp_dir("p4_aa_bg_pack");
    sa::detail::set_editor_root(sa_core::paths::path_to_utf8(root));
    wfile(backgrounds / "tex" / "bg_badminton.webp", std::string("RIFFwebp-bytes"));
    _putenv(("EDITOR_BG_DIR=" + sa_core::paths::path_to_utf8(backgrounds)).c_str());
    _putenv("EDITOR_BG_BASE_URL=");
    _putenv("EDITOR_PORTRAIT_DIR=");
    _putenv("EDITOR_PORTRAIT_BASE_URL=");
    _putenv("EDITOR_DECODED_PACK_DIR=");
    reset_aa_singletons_for_test();
    {
        std::lock_guard<std::mutex> lk(STATE().mu_);
        STATE().aa_status = "idle";
        STATE().aa_error.clear();
    }
    Router r;
    register_aa_routes(r);
    // 键含 '/' 时走 safe_asset_name 回退：命中 bg_badminton.webp。
    auto hit = sat::call_router(r, "POST", "/api/aa/preview", {},
                                json{{"kind", "tex"}, {"key", "bg/badminton"}});
    REQUIRE(hit.status == 200);
    CHECK(hit.json_payload["kind"] == "tex");
    CHECK(!hit.json_payload["data"].get<std::string>().empty());
    auto miss = sat::call_router(r, "POST", "/api/aa/preview", {},
                                 json{{"kind", "tex"}, {"key", "bg/nobody"}});
    CHECK(miss.status == 404);
    // 清理：避免 EDITOR_BG_DIR 泄漏到后续用例。
    _putenv("EDITOR_BG_DIR=");
    reset_aa_singletons_for_test();
    sa::detail::set_editor_root("");
}

TEST_CASE("/api/aa/preview returns a COS URL for backgrounds (背景图片扩展·对象存储)",
          "[p4][aa][routes][backgrounds]") {
    // 配置对象存储 base_url 时：本地目录未命中，preview 返回 200 + url。
    auto root = sat::make_temp_dir("p4_aa_bg_url_root");
    sa::detail::set_editor_root(sa_core::paths::path_to_utf8(root));
    _putenv("EDITOR_BG_DIR=");
    _putenv("EDITOR_BG_BASE_URL=https://cos.example.com/backgrounds/");
    _putenv("EDITOR_PORTRAIT_DIR=");
    _putenv("EDITOR_PORTRAIT_BASE_URL=");
    _putenv("EDITOR_DECODED_PACK_DIR=");
    reset_aa_singletons_for_test();
    {
        std::lock_guard<std::mutex> lk(STATE().mu_);
        STATE().aa_status = "idle";
        STATE().aa_error.clear();
    }
    Router r;
    register_aa_routes(r);
    auto hit = sat::call_router(r, "POST", "/api/aa/preview", {},
                                json{{"kind", "tex"}, {"key", "bg/badminton"}});
    REQUIRE(hit.status == 200);
    CHECK(hit.json_payload["kind"] == "tex");
    CHECK(hit.json_payload["url"] ==
          "https://cos.example.com/backgrounds/tex/bg_badminton.webp");
    CHECK(!hit.json_payload.contains("data"));
    // 清理：避免 base_url 泄漏到后续用例。
    _putenv("EDITOR_BG_BASE_URL=");
    reset_aa_singletons_for_test();
    sa::detail::set_editor_root("");
}

TEST_CASE("Tex2D flat directory auto-discovery and full-body立绘 selection",
          "[p4][aa][tex2d]") {
    auto root = sat::make_temp_dir("p4_aa_tex2d_root");
    sa::detail::set_editor_root(sa_core::paths::path_to_utf8(root));
    _putenv("EDITOR_BG_DIR=");
    _putenv("EDITOR_BG_BASE_URL=");
    _putenv("EDITOR_PORTRAIT_DIR=");
    _putenv("EDITOR_PORTRAIT_BASE_URL=");
    _putenv("EDITOR_DECODED_PACK_DIR=");
    reset_aa_singletons_for_test();

    // 构造 Tex2D 目录结构：
    // root/Tex2D/bg/bg_school.png
    // root/Tex2D/role/role_hero.png (小型头像 10 字节)
    // root/Tex2D/role/role_hero #12345.png (全身大立绘 50 字节)
    auto bg_dir = root / "Tex2D" / "bg";
    auto role_dir = root / "Tex2D" / "role";
    std::filesystem::create_directories(bg_dir);
    std::filesystem::create_directories(role_dir);

    // 有效 PNG 头（至少 24 字节以通过 image_size 校验）
    std::string small_png = "\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x01\x00\x00\x00\x01\x00\x08\x06\x00\x00\x00";
    std::string large_png = "\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x04\x00\x00\x00\x08\x00\x08\x06\x00\x00\x00" +
                            std::string(100, 'X');

    wfile(bg_dir / "bg_school.png", small_png);
    wfile(role_dir / "role_hero.png", small_png);
    wfile(role_dir / "role_hero #12345.png", large_png);

    Router r;
    register_aa_routes(r);

    // 1. 验证状态变为 ready（无游戏 index 时，因 Tex2D 本地扩展生效）
    auto st = sat::call_router(r, "GET", "/api/aa/status");
    REQUIRE(st.status == 200);
    CHECK(st.json_payload["status"] == "ready");

    // 2. /api/aa/keys 返回 bg 与 role 贴图
    auto keys = sat::call_router(r, "GET", "/api/aa/keys", {{"limit", "10"}});
    REQUIRE(keys.status == 200);
    auto tex_arr = keys.json_payload["tex"];
    bool has_bg = false, has_role = false;
    for (const auto& item : tex_arr) {
        if (item == "bg_school") has_bg = true;
        if (item == "role_hero") has_role = true;
    }
    CHECK(has_bg);
    CHECK(has_role);

    // 3. /api/aa/preview 成功返回背景（包含 bg/ 前缀容错）
    auto prev_bg1 = sat::call_router(r, "POST", "/api/aa/preview", {},
                                     json{{"kind", "tex"}, {"key", "bg_school"}});
    REQUIRE(prev_bg1.status == 200);
    CHECK(prev_bg1.json_payload["mime"] == "image/png");

    auto prev_bg2 = sat::call_router(r, "POST", "/api/aa/preview", {},
                                     json{{"kind", "tex"}, {"key", "bg/bg_school"}});
    REQUIRE(prev_bg2.status == 200);

    // 4. /api/aa/preview 成功返回立绘，且优先命中大尺寸全身立绘 (large_png)
    auto prev_role = sat::call_router(r, "POST", "/api/aa/preview", {},
                                      json{{"kind", "tex"}, {"key", "role_hero"}});
    REQUIRE(prev_role.status == 200);
    std::string b64_role = prev_role.json_payload["data"];
    // 解码长度应对应 large_png 的长度（大于 small_png）
    CHECK(b64_role.size() > 50);

    reset_aa_singletons_for_test();
    sa::detail::set_editor_root("");
}

TEST_CASE("Tex2D AVIF format discovery and size extraction",
          "[p4][aa][tex2d][avif]") {
    auto root = sat::make_temp_dir("p4_aa_tex2d_avif_root");
    sa::detail::set_editor_root(sa_core::paths::path_to_utf8(root));
    _putenv("EDITOR_PORTRAIT_DIR=");
    _putenv("EDITOR_BG_DIR=");
    _putenv("EDITOR_PORTRAIT_BASE_URL=");
    _putenv("EDITOR_DECODED_PACK_DIR=");
    reset_aa_singletons_for_test();

    auto bg_dir = root / "Tex2D" / "bg";
    auto role_dir = root / "Tex2D" / "role";
    std::filesystem::create_directories(bg_dir);
    std::filesystem::create_directories(role_dir);

    // 构造合法 AVIF 探测样本（ftyp + ispe，1920x1080）
    std::string sample_avif =
        std::string("\x00\x00\x00\x20\x66\x74\x79\x70\x61\x76\x69\x66\x00\x00\x00\x00\x61\x76\x69\x66\x6d\x69\x66\x31", 24) +
        std::string("\x00\x00\x00\x14\x69\x73\x70\x65\x00\x00\x00\x00\x00\x00\x07\x80\x00\x00\x04\x38", 20);

    wfile(bg_dir / "bg_classroom.avif", sample_avif);
    wfile(role_dir / "role_student.avif", sample_avif);

    Router r;
    register_aa_routes(r);

    auto st = sat::call_router(r, "GET", "/api/aa/status");
    REQUIRE(st.status == 200);
    CHECK(st.json_payload["status"] == "ready");

    auto keys = sat::call_router(r, "GET", "/api/aa/keys", {{"limit", "10"}});
    REQUIRE(keys.status == 200);
    auto tex_arr = keys.json_payload["tex"];
    bool has_bg = false, has_role = false;
    for (const auto& item : tex_arr) {
        if (item == "bg_classroom") has_bg = true;
        if (item == "role_student") has_role = true;
    }
    CHECK(has_bg);
    CHECK(has_role);

    auto prev_bg = sat::call_router(r, "POST", "/api/aa/preview", {},
                                    json{{"kind", "tex"}, {"key", "bg_classroom"}});
    REQUIRE(prev_bg.status == 200);
    CHECK(prev_bg.json_payload["mime"] == "image/avif");

    auto prev_role = sat::call_router(r, "POST", "/api/aa/preview", {},
                                      json{{"kind", "tex"}, {"key", "role_student"}});
    REQUIRE(prev_role.status == 200);
    CHECK(prev_role.json_payload["mime"] == "image/avif");

    reset_aa_singletons_for_test();
    sa::detail::set_editor_root("");
}

// ---- 二进制直发路由（性能优化） ---------------------------------------------

namespace {
// GET 请求 + If-None-Match 的原样 dispatch（call_router 不暴露该头部）。
Resp raw_get(Router& r, const std::string& path,
             std::map<std::string, std::string> query,
             const std::string& if_none_match = "") {
    Req req;
    req.method = "GET";
    req.path = path;
    req.query = std::move(query);
    req.if_none_match_header = if_none_match;
    req.host_header = "127.0.0.1:1234";
    return r.dispatch(req);
}
}  // namespace

TEST_CASE("GET /api/aa/raw binary: 200 bytes + ETag + 304 + 404 + preview compat",
          "[p4][aa][routes][raw]") {
    auto root = sat::make_temp_dir("p4_aa_raw_root");
    auto pack = sat::make_temp_dir("p4_aa_raw_pack");
    sa::detail::set_editor_root(sa_core::paths::path_to_utf8(root));
    // 一个 24 字节的合法 PNG 头（image_size 可识别），用字节内容做等值断言。
    std::string png;
    const unsigned char sig[] = {0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
                                 'I', 'H', 'D', 'R', 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x02};
    png.assign(reinterpret_cast<const char*>(sig), sizeof(sig));
    wfile(pack / "tex" / "raw_hero.png", png);
    wfile(pack / "aud" / "raw_note.ogg", "OGGDATA");
    wfile(pack / "aa_index.json",
          R"({"v":3,"decoded":true,"tex":["raw_hero"],"aud":["raw_note"],"txt":[]})");
    _putenv(("EDITOR_DECODED_PACK_DIR=" + sa_core::paths::path_to_utf8(pack)).c_str());
    _putenv("EDITOR_PORTRAIT_DIR=");
    _putenv("EDITOR_BG_DIR=");
    _putenv("EDITOR_PORTRAIT_BASE_URL=");
    _putenv("EDITOR_BG_BASE_URL=");
    reset_aa_singletons_for_test();
    {
        std::lock_guard<std::mutex> lk(STATE().mu_);
        STATE().aa_status = "idle";
        STATE().aa_error.clear();
    }
    Router r;
    register_aa_routes(r);

    // 1) GET /api/aa/raw?kind=tex -> 200 原始字节 + image/png + ETag。
    Resp resp = raw_get(r, "/api/aa/raw", {{"kind", "tex"}, {"key", "raw_hero"}});
    REQUIRE(resp.status == 200);
    CHECK(resp.is_bytes);
    CHECK(resp.content_type == "image/png");
    CHECK(resp.bytes == png);
    REQUIRE_FALSE(resp.etag.empty());
    const std::string etag = resp.etag;

    // 2) 同一 ETag 的 If-None-Match -> 304 且 0 字节，ETag 原样回带。
    Resp resp304 = raw_get(r, "/api/aa/raw", {{"kind", "tex"}, {"key", "raw_hero"}}, etag);
    CHECK(resp304.status == 304);
    CHECK(resp304.bytes.empty());
    CHECK(resp304.etag == etag);

    // 3) GET /api/aa/tex?key=... 等价 raw?kind=tex。
    Resp resp_tex = raw_get(r, "/api/aa/tex", {{"key", "raw_hero"}});
    REQUIRE(resp_tex.status == 200);
    CHECK(resp_tex.bytes == png);

    // 4) 未知 key -> 404 JSON（不是 no route）。
    auto miss = sat::call_router(r, "GET", "/api/aa/raw",
                                 {{"kind", "tex"}, {"key", "nope"}});
    REQUIRE(miss.status == 404);
    CHECK(std::string(miss.json_payload["error"]).find("not found") != std::string::npos);

    // 5) 旧接口向后兼容：POST /api/aa/preview 仍回 Base64 JSON。
    auto prev = sat::call_router(r, "POST", "/api/aa/preview", {},
                                 json{{"kind", "tex"}, {"key", "raw_hero"}});
    REQUIRE(prev.status == 200);
    CHECK(prev.json_payload["mime"] == "image/png");
    CHECK(!prev.json_payload["data"].get<std::string>().empty());

    // 6) kind=aud 二进制直发。
    auto aud = sat::call_router(r, "GET", "/api/aa/raw",
                                {{"kind", "aud"}, {"key", "raw_note"}});
    REQUIRE(aud.status == 200);
    CHECK(aud.content_type == "audio/ogg");
    CHECK(aud.bytes == "OGGDATA");

    // 清理：避免 env 泄漏到后续用例。
    _putenv("EDITOR_DECODED_PACK_DIR=");
    reset_aa_singletons_for_test();
    sa::detail::set_editor_root("");
}

TEST_CASE("GET /api/aa/raw returns 302 Location for a COS portrait",
          "[p4][aa][routes][raw]") {
    auto root = sat::make_temp_dir("p4_aa_raw_cos_root");
    sa::detail::set_editor_root(sa_core::paths::path_to_utf8(root));
    _putenv("EDITOR_PORTRAIT_DIR=");
    _putenv("EDITOR_PORTRAIT_BASE_URL=https://cos.example.com/portraits/");
    _putenv("EDITOR_BG_DIR=");
    _putenv("EDITOR_BG_BASE_URL=");
    _putenv("EDITOR_DECODED_PACK_DIR=");
    reset_aa_singletons_for_test();
    {
        std::lock_guard<std::mutex> lk(STATE().mu_);
        STATE().aa_status = "idle";
        STATE().aa_error.clear();
    }
    Router r;
    register_aa_routes(r);
    Resp resp = raw_get(r, "/api/aa/raw", {{"kind", "tex"}, {"key", "role/xiaomei"}});
    REQUIRE(resp.status == 302);
    CHECK(resp.location ==
          "https://cos.example.com/portraits/tex/role_xiaomei.webp");
    CHECK(resp.bytes.empty());
    CHECK(resp.content_type.empty());
    // 清理：避免 env 泄漏到后续用例。
    _putenv("EDITOR_PORTRAIT_BASE_URL=");
    reset_aa_singletons_for_test();
    sa::detail::set_editor_root("");
}

