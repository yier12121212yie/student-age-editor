// /api/assets/{catalog,tags}（server/services/assets_routes.*）：[assets][routes]。
//
// 覆盖三件事：
//   1. 形状与口径——catalog 的 total/matched/returned/truncated/counts 与
//      resources_by_kind 分桶；tags 的固定顺序 + 全量 counts；
//   2. 过滤——q / tags（或语义）/ kind / limit+offset；
//   3. 降级——索引不可用时 200 + 空目录（对齐 /api/aa/keys 的 empty-degradation），
//      非法 kind 回 400，绝不 500。
#include <catch_amalgamated.hpp>

#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <string>

#include "test_support.h"
#include "sa_core/paths.h"
#include "server/api_router.h"
#include "server/state.h"
#include "aa.h"
#include "assets_routes.h"

using namespace sa;
namespace fs = std::filesystem;

namespace {

// MSVC 的 _putenv_s / POSIX 的 setenv（同 test_p5_realtime.cpp 的写法），
// 空值 = 取消设置。用它而不是 _putenv，POSIX 构建里这个 TU 也能编过。
void putenv_portable(const char* k, const char* v) {
#ifdef _WIN32
    _putenv_s(k, v);
#else
    if (v && *v) setenv(k, v, 1);
    else unsetenv(k);
#endif
}

std::string P(const fs::path& p) { return sa_core::paths::path_to_utf8(p); }

void wfile(const fs::path& p, const std::string& content) {
    fs::create_directories(p.parent_path());
    std::ofstream f(p, std::ios::binary);
    f.write(content.data(), static_cast<std::streamsize>(content.size()));
}

// 最小 v3 游戏索引（形态照 test_p4_aa.cpp 的 game_index_json 与真实
// _cache/aa_index/aa_index.json 的分组编码）。
json fixture_index() {
    return json::parse(R"({
        "v": 3, "fp": "",
        "tex": {
            "role_comic_1": ["D:\\aa\\StandaloneWindows64\\atlas_assets_assets\\res\\atlas\\role_comic_1168c761bc507e56b7fb2064d262ee7e.bundle", -6961645949212346451],
            "img_brickgame_tri": ["D:\\aa\\StandaloneWindows64\\textures_assets_comic_d3f82cbf211920cffc65dd76902d9ca8.bundle", 42],
            "character_sakura_001": ["D:\\aa\\StandaloneWindows64\\atlas_assets_assets\\res\\atlas\\role2_ec04c6efe2b8761623f406db65226d34.bundle", 9],
            "icon_1": ["D:\\aa\\StandaloneWindows64\\atlas_assets_assets\\res\\atlas\\icon3_f8d0b4b8fed4df3b60a5a8f12f2890b5.bundle", 7],
            "scene_open": ["D:\\aa\\StandaloneWindows64\\textures_assets_v177_347d991f609b33923c42fced4291a90d.bundle", 5]
        },
        "aud": {
            "bgm_theme_789": ["D:\\aa\\StandaloneWindows64\\audios_assets_bgm_f23e224bdd8d4d1ef898afd4f3236bde.bundle", -1],
            "jump012": ["D:\\aa\\StandaloneWindows64\\audios_assets__93d8d8ed3f5dabca16b589fe23e7b97b.bundle", 5]
        },
        "txt": {"personcfg": ["D:\\aa\\StandaloneWindows64\\cfgs_assets__5511f207679e32ec9da13b1d2a97c239.bundle", 1234]},
        "cabs": {},
        "texmeta": {"img_brickgame_tri": [256, 512], "scene_open": [1920, 1080]},
        "bundles": []
    })");
}

// 指向 temp editor root 的索引；析构时还原 env 与 editor root（用例之间共享进程）。
struct AssetsFixture {
    fs::path root;
    std::string saved_data_root;
    std::string saved_index_file;
    std::string saved_pack_dir;
    std::string saved_aa_status;

    AssetsFixture() {
        saved_data_root = sa_core::paths::getenv_utf8("EDITOR_DATA_ROOT");
        saved_index_file = sa_core::paths::getenv_utf8("EDITOR_AA_INDEX_FILE");
        saved_pack_dir = sa_core::paths::getenv_utf8("EDITOR_DECODED_PACK_DIR");
        {
            // ensure_aa_index() 会把 STATE().aa_status 从 idle 翻成 ready（aa.cpp:446-449）；
            // /api/ping 的契约用例断言的是 fresh 进程的 idle，所以这里必须还原。
            std::lock_guard<std::mutex> lk(STATE().mu_);
            saved_aa_status = STATE().aa_status;
        }
        root = sat::make_temp_dir("assets_routes");
        wfile(root / "_cache" / "aa_index" / "aa_index.json", fixture_index().dump());
        putenv_portable("EDITOR_DATA_ROOT", "");       // 让 set_editor_root 生效
        putenv_portable("EDITOR_AA_INDEX_FILE", "");
        putenv_portable("EDITOR_DECODED_PACK_DIR", "");
        sa::detail::set_editor_root(P(root));
        reset_aa_singletons_for_test();
    }

    ~AssetsFixture() {
        reset_aa_singletons_for_test();
        {
            std::lock_guard<std::mutex> lk(STATE().mu_);
            STATE().aa_status = saved_aa_status;
        }
        sa::detail::set_editor_root("");
        putenv_portable("EDITOR_DATA_ROOT", saved_data_root.c_str());
        putenv_portable("EDITOR_AA_INDEX_FILE", saved_index_file.c_str());
        putenv_portable("EDITOR_DECODED_PACK_DIR", saved_pack_dir.c_str());
    }

    static Router router() {
        Router r;
        register_assets_routes(r);
        return r;
    }
};

// 把 resources_by_kind 拍平成一个 (kind, key) 列表，便于整体断言。
std::vector<std::string> keys_of(const json& payload, const char* kind) {
    std::vector<std::string> out;
    const json& bucket = payload.at("resources_by_kind").at(kind);
    for (const auto& row : bucket) out.push_back(row.at("key").get<std::string>());
    return out;
}

}  // namespace

TEST_CASE("/api/assets/tags: 全量口径 + 固定顺序", "[assets][routes]") {
    AssetsFixture fx;
    Router r = AssetsFixture::router();

    auto resp = sat::call_router(r, "GET", "/api/assets/tags");
    REQUIRE(resp.status == 200);
    const json& body = resp.json_payload;
    CHECK(body.at("status") == "ready");
    CHECK(body.at("total") == 7);  // tex 5 + aud 2（txt 不进资源目录）
    CHECK(body.at("sources") == json::array({"aa_index"}));

    // 类型标签按 base_types() 固定顺序在前，其余字典序。
    CHECK(body.at("tags") ==
          json::array({"role", "cg", "ui", "background", "bgm", "se", "bgm-789", "role-001",
                       "se-012"}));
    CHECK(body.at("counts").at("role") == 2);
    CHECK_FALSE(body.at("counts").contains("sprite_absent"));  // 只统计真实存在的标签
    CHECK(body.at("counts").at("bgm-789") == 1);
    CHECK(body.at("counts").size() == 9);
}

TEST_CASE("/api/assets/catalog: 分桶、字段与 texmeta 尺寸", "[assets][routes]") {
    AssetsFixture fx;
    Router r = AssetsFixture::router();

    auto resp = sat::call_router(r, "GET", "/api/assets/catalog");
    REQUIRE(resp.status == 200);
    const json& body = resp.json_payload;
    CHECK(body.at("status") == "ready");
    CHECK(body.at("total") == 7);
    CHECK(body.at("matched") == 7);
    CHECK(body.at("returned") == 7);
    CHECK(body.at("truncated") == false);
    CHECK(body.at("counts") == json{{"sprite", 2}, {"texture", 3}, {"audio", 2}});

    // 分桶固定顺序 sprite → texture → audio，桶内按 key 升序。
    CHECK(keys_of(body, "sprite") ==
          std::vector<std::string>{"character_sakura_001", "role_comic_1"});
    CHECK(keys_of(body, "texture") ==
          std::vector<std::string>{"icon_1", "img_brickgame_tri", "scene_open"});
    CHECK(keys_of(body, "audio") == std::vector<std::string>{"bgm_theme_789", "jump012"});

    // 行字段齐全；sha24 = sha256(kind+":"+key) 前 24 位；尺寸来自 texmeta（稀疏）。
    for (const char* kind : {"sprite", "texture", "audio"}) {
        for (const auto& row : body.at("resources_by_kind").at(kind)) {
            CHECK(row.at("key") == row.at("original_name"));
            CHECK(row.at("kind") == kind);
            CHECK(row.at("sha24").get<std::string>().size() == 24);
            CHECK(row.at("tags").is_array());
            CHECK(row.at("tags").size() >= 1);
        }
    }
    for (const auto& row : body.at("resources_by_kind").at("texture")) {
        const std::string key = row.at("key").get<std::string>();
        if (key == "img_brickgame_tri") {
            CHECK(row.at("width") == 256);
            CHECK(row.at("height") == 512);
        } else if (key == "scene_open") {
            CHECK(row.at("width") == 1920);
            CHECK(row.at("height") == 1080);
        } else {
            CHECK(row.at("width") == 0);  // 不在 texmeta 里（允许稀疏）
            CHECK(row.at("height") == 0);
        }
    }
    // 立绘标签带 ID 后缀。
    for (const auto& row : body.at("resources_by_kind").at("sprite")) {
        if (row.at("key") == "character_sakura_001")
            CHECK(row.at("tags") == json::array({"role", "role-001"}));
    }
}

TEST_CASE("/api/assets/catalog: q / tags / kind 过滤", "[assets][routes]") {
    AssetsFixture fx;
    Router r = AssetsFixture::router();

    auto by_kind = sat::call_router(r, "GET", "/api/assets/catalog", {{"kind", "audio"}});
    REQUIRE(by_kind.status == 200);
    CHECK(by_kind.json_payload.at("matched") == 2);
    CHECK(keys_of(by_kind.json_payload, "sprite").empty());
    CHECK(keys_of(by_kind.json_payload, "texture").empty());
    CHECK(by_kind.json_payload.at("counts").at("sprite") == 2);  // counts 仍是全量口径

    auto by_tag = sat::call_router(r, "GET", "/api/assets/catalog", {{"tags", "role"}});
    REQUIRE(by_tag.status == 200);
    CHECK(by_tag.json_payload.at("matched") == 2);
    CHECK(keys_of(by_tag.json_payload, "sprite") ==
          std::vector<std::string>{"character_sakura_001", "role_comic_1"});

    // 多标签是"命中任一"（或语义）。
    auto any_tag = sat::call_router(r, "GET", "/api/assets/catalog", {{"tags", "cg, bgm"}});
    REQUIRE(any_tag.status == 200);
    CHECK(any_tag.json_payload.at("matched") == 2);
    CHECK(keys_of(any_tag.json_payload, "texture") == std::vector<std::string>{"img_brickgame_tri"});
    CHECK(keys_of(any_tag.json_payload, "audio") == std::vector<std::string>{"bgm_theme_789"});

    // q 对 key 大小写不敏感。
    auto by_q = sat::call_router(r, "GET", "/api/assets/catalog", {{"q", "ICON"}});
    REQUIRE(by_q.status == 200);
    CHECK(by_q.json_payload.at("matched") == 1);
    CHECK(keys_of(by_q.json_payload, "texture") == std::vector<std::string>{"icon_1"});

    // 未知标签 -> 空结果（不是错误）。
    auto miss = sat::call_router(r, "GET", "/api/assets/catalog", {{"tags", "nope"}});
    REQUIRE(miss.status == 200);
    CHECK(miss.json_payload.at("matched") == 0);

    // 非法 kind -> 400（外部输入绝不 500）。
    auto bad = sat::call_router(r, "GET", "/api/assets/catalog", {{"kind", "bogus"}});
    REQUIRE(bad.status == 400);
    CHECK(bad.json_payload.at("error") == "bad kind");

    // 坏 limit -> 回默认值，不 500。
    auto bad_limit = sat::call_router(r, "GET", "/api/assets/catalog", {{"limit", "abc"}});
    REQUIRE(bad_limit.status == 200);
    CHECK(bad_limit.json_payload.at("returned") == 7);
}

TEST_CASE("/api/assets/catalog: limit/offset 分页与 truncated", "[assets][routes]") {
    AssetsFixture fx;
    Router r = AssetsFixture::router();

    auto page1 = sat::call_router(r, "GET", "/api/assets/catalog", {{"limit", "1"}});
    REQUIRE(page1.status == 200);
    CHECK(page1.json_payload.at("returned") == 1);
    CHECK(page1.json_payload.at("matched") == 7);
    CHECK(page1.json_payload.at("truncated") == true);

    // 次序是 kind 升序 + key 升序：0 bgm_theme_789 · 1 jump012 · 2 character_sakura_001
    // · 3 role_comic_1 · 4 icon_1 · 5 img_brickgame_tri · 6 scene_open。
    auto last = sat::call_router(r, "GET", "/api/assets/catalog",
                                 {{"limit", "1"}, {"offset", "6"}});
    REQUIRE(last.status == 200);
    CHECK(last.json_payload.at("returned") == 1);
    CHECK(last.json_payload.at("truncated") == false);
    CHECK(keys_of(last.json_payload, "texture") == std::vector<std::string>{"scene_open"});

    auto past_end = sat::call_router(r, "GET", "/api/assets/catalog", {{"offset", "99"}});
    REQUIRE(past_end.status == 200);
    CHECK(past_end.json_payload.at("returned") == 0);
    CHECK(past_end.json_payload.at("truncated") == false);
}

TEST_CASE("/api/assets/*: 无索引时 200 空降级（不是 500）", "[assets][routes]") {
    // 指向一个没有 _cache/aa_index 的 temp root。
    const std::string saved_data_root = sa_core::paths::getenv_utf8("EDITOR_DATA_ROOT");
    const std::string saved_index_file = sa_core::paths::getenv_utf8("EDITOR_AA_INDEX_FILE");
    const std::string saved_pack_dir = sa_core::paths::getenv_utf8("EDITOR_DECODED_PACK_DIR");
    auto root = sat::make_temp_dir("assets_routes_empty");
    putenv_portable("EDITOR_DATA_ROOT", "");
    putenv_portable("EDITOR_AA_INDEX_FILE", "");
    putenv_portable("EDITOR_DECODED_PACK_DIR", "");
    sa::detail::set_editor_root(P(root));
    reset_aa_singletons_for_test();

    Router r = AssetsFixture::router();
    auto catalog = sat::call_router(r, "GET", "/api/assets/catalog");
    REQUIRE(catalog.status == 200);
    CHECK(catalog.json_payload.at("status") == "idle");
    CHECK(catalog.json_payload.at("total") == 0);
    CHECK(catalog.json_payload.at("matched") == 0);
    CHECK(catalog.json_payload.at("truncated") == false);
    CHECK(catalog.json_payload.at("counts") == json{{"sprite", 0}, {"texture", 0}, {"audio", 0}});
    CHECK(catalog.json_payload.at("resources_by_kind").at("sprite").empty());

    auto tags = sat::call_router(r, "GET", "/api/assets/tags");
    REQUIRE(tags.status == 200);
    CHECK(tags.json_payload.at("status") == "idle");
    CHECK(tags.json_payload.at("total") == 0);
    CHECK(tags.json_payload.at("tags").empty());

    reset_aa_singletons_for_test();
    sa::detail::set_editor_root("");
    putenv_portable("EDITOR_DATA_ROOT", saved_data_root.c_str());
    putenv_portable("EDITOR_AA_INDEX_FILE", saved_index_file.c_str());
    putenv_portable("EDITOR_DECODED_PACK_DIR", saved_pack_dir.c_str());
}
