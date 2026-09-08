// wip/P4/test_p4_base.cpp — base_store tests: ARTIFACT_FORMAT §8 consumption
// rules over hand-crafted artifacts (deterministic) plus a guarded real-artifact
// check. Tagged [p4].
#include <catch_amalgamated.hpp>

#include <algorithm>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <string>

#include "test_support.h"
#include "sa_core/paths.h"
#include "base_store.h"
#include "server/services/stores_api.h"

using namespace sa;
namespace fs = std::filesystem;

namespace {

void wfile(const fs::path& p, const std::string& content) {
    fs::create_directories(p.parent_path());
    std::ofstream f(p, std::ios::binary);
    f << content;
}

// A minimal, self-consistent base-tables artifact (no sources => freshness not
// asserted), with the tables/rows the query tests need.
std::string make_artifact(const std::string& tag) {
    auto dir = sat::make_temp_dir(tag);
    wfile(dir / "base_data" / "EvtCfg.json", R"({
        "101": {"id": 101, "title": "开学典礼", "npc": [1, 2], "type": 1},
        "9": {"id": 9, "title": "小事件", "npc": 5, "type": 2},
        "102": {"id": 102, "title": "未命名", "npc": [], "type": 1},
        "99": {"id": 99, "title": "  ", "npc": [], "type": 1},
        "2": {"id": 2, "title": "自然序甲", "npc": [10], "type": 1}
    })");
    wfile(dir / "base_data" / "TalkCfg.json", R"({
        "101001": {"id": 101001, "content": "你好世界", "audio": 0},
        "101002": {"id": 101002, "content": "第二句", "audio": 0},
        "201001": {"id": 201001, "content": "别的", "audio": 0},
        "badkey":  {"id": 0, "content": "非数字键"}
    })");
    wfile(dir / "base_data" / "OptionCfg.json", R"({
        "10100": {"id": 10100, "content": "选项"},
        "10101": {"id": 10101, "content": "选项2"}
    })");
    wfile(dir / "base_data" / "AudioCfg.json", R"({
        "10": {"id": 10, "name": "bgm", "url": "audio/bgm/Theme_Song", "type": 1}
    })");
    // meta: missing_expected present; tables lists the four we wrote.
    wfile(dir / "base_meta.json", R"({
        "v": 1, "tool": "resource_scan", "partial": false,
        "missing_expected": ["ItemCfg"],
        "tables": {"EvtCfg": {"file": "base_data/EvtCfg.json", "rows": 5},
                   "TalkCfg": {"file": "base_data/TalkCfg.json", "rows": 4},
                   "OptionCfg": {"file": "base_data/OptionCfg.json", "rows": 2},
                   "AudioCfg": {"file": "base_data/AudioCfg.json", "rows": 1}}
    })");
    return sa_core::paths::path_to_utf8(dir);
}

}  // namespace

TEST_CASE("base load: ready, sorted loaded, missing_expected", "[p4][base]") {
    auto dir = make_artifact("p4_base_load");
    set_base_artifact_dir(dir);
    BaseStore s;
    REQUIRE(s.load(true));
    CHECK(s.status() == "ready");
    CHECK(s.available());
    auto loaded = s.loaded_tables();
    CHECK(std::is_sorted(loaded.begin(), loaded.end()));
    CHECK(std::find(loaded.begin(), loaded.end(), "EvtCfg") != loaded.end());
    json st = s.status_dict();
    CHECK(st["status"] == "ready");
    CHECK(st["missing"] == json::array({"ItemCfg"}));
    set_base_artifact_dir("");
}

TEST_CASE("base table() is const read-only view; absent -> empty object", "[p4][base]") {
    auto dir = make_artifact("p4_base_table");
    set_base_artifact_dir(dir);
    BaseStore s;
    REQUIRE(s.load(true));
    auto t = s.table("TalkCfg");
    REQUIRE(t->is_object());
    CHECK((*t)["101001"]["content"] == "你好世界");
    auto absent = s.table("NoSuchCfg");
    CHECK(absent->empty());
    set_base_artifact_dir("");
}

TEST_CASE("§8.1 table_ids int64-ify row keys; non-int keys skipped", "[p4][base]") {
    auto dir = make_artifact("p4_base_ids");
    set_base_artifact_dir(dir);
    BaseStore s;
    REQUIRE(s.load(true));
    auto ids = s.table_ids("TalkCfg");
    // 101001,101002,201001 present; "badkey" skipped.
    CHECK(ids->count(101001) == 1);
    CHECK(ids->count(201001) == 1);
    CHECK(ids->size() == 3);
    // A13: cached (second call returns same shared_ptr).
    auto ids2 = s.table_ids("TalkCfg");
    CHECK(ids.get() == ids2.get());
    set_base_artifact_dir("");
}

TEST_CASE("search_events: natural-id sort + npc single/array (§8.5) + filters", "[p4][base]") {
    auto dir = make_artifact("p4_base_events");
    set_base_artifact_dir(dir);
    BaseStore s;
    REQUIRE(s.load(true));
    // Title-validity filter drops "未命名" and blank-title rows.
    auto all = s.search_events("", "", "", 1, 50);
    CHECK(all["total"] == 3);  // 101, 9, 2 (102 "未命名" + 99 blank excluded)
    auto& ev = all["events"];
    // Natural order: 2, 9, 101 (2<9<101 numeric, not lexicographic).
    CHECK(ev[0]["id"] == "2");
    CHECK(ev[1]["id"] == "9");
    CHECK(ev[2]["id"] == "101");
    // npc single value (9 -> 5) matched via npc filter.
    auto bynpc = s.search_events("", "5", "", 1, 50);
    CHECK(bynpc["total"] == 1);
    CHECK(bynpc["events"][0]["id"] == "9");
    // npc array membership: only 101 (npc [1,2]) holds "1"; row "2" is npc [10].
    auto bynpc1 = s.search_events("", "1", "", 1, 50);
    CHECK(bynpc1["total"] == 1);
    CHECK(bynpc1["events"][0]["id"] == "101");
    // type filter.
    auto bytype = s.search_events("", "", "2", 1, 50);
    CHECK(bytype["total"] == 1);
    CHECK(bytype["events"][0]["id"] == "9");
    set_base_artifact_dir("");
}

TEST_CASE("search_talks: base + mod union, length-codepoint order (§8.6), infer_evt_id",
          "[p4][base]") {
    auto dir = make_artifact("p4_base_talks");
    set_base_artifact_dir(dir);
    BaseStore s;
    REQUIRE(s.load(true));
    json mod_talk = json::object();
    mod_talk["5001"] = json{{"content", "你好mod"}};
    json mod_evt = json::object();
    mod_evt["5"] = json{{"title", "mod事件"}};
    auto res = s.search_talks("你好", mod_talk, mod_evt, 150);
    REQUIRE(res.size() >= 2);
    // base hit talk 101001 "你好世界" (len 4 cp) + mod "你好mod" (len 5 cp).
    // Shorter content ranks first (both non-exact -> by utf8 length).
    CHECK(res[0]["talk_id"] == "101001");
    CHECK(res[0]["src"] == "本体");
    CHECK(res[0]["evt_id"] == "101");  // 101001 -> strip 3 -> 101
    CHECK(res[0]["evt_title"] == "开学典礼");
    bool has_mod = false;
    for (auto& r : res) if (r["src"] == "Mod") { has_mod = true; CHECK(r["evt_id"] == "5"); }
    CHECK(has_mod);
    set_base_artifact_dir("");
}

TEST_CASE("extract_event: id-suffix scoping (talk +3 / option +2), absent -> empty",
          "[p4][base]") {
    auto dir = make_artifact("p4_base_extract");
    set_base_artifact_dir(dir);
    BaseStore s;
    REQUIRE(s.load(true));
    auto delta = s.extract_event("101");
    REQUIRE(delta.contains("EvtCfg"));
    CHECK(delta["EvtCfg"].contains("101"));
    REQUIRE(delta.contains("TalkCfg"));
    CHECK(delta["TalkCfg"].contains("101001"));
    CHECK_FALSE(delta["TalkCfg"].contains("201001"));  // other event's talk
    REQUIRE(delta.contains("OptionCfg"));
    CHECK(delta["OptionCfg"].contains("10100"));
    CHECK(delta["OptionCfg"].contains("10101"));
    auto none = s.extract_event("99999");
    CHECK(none.empty());
    set_base_artifact_dir("");
}

TEST_CASE("§8.6 staleness: source mtime/size drift -> error (no auto rescan)", "[p4][base]") {
    auto dir = sat::make_temp_dir("p4_base_stale");
    wfile(dir / "base_data" / "EvtCfg.json", R"({"101": {"id":101,"title":"x","npc":[],"type":1}})");
    // A recorded source file with an impossible mtime_ns => detected as changed.
    wfile(dir / "base_meta.json", R"({
        "v": 1, "missing_expected": [],
        "tables": {"EvtCfg": {"file": "base_data/EvtCfg.json", "rows": 1}},
        "sources": [{"path": ")" + sa_core::paths::path_to_utf8(dir) +
                     R"(", "mode": "aa", "files": [{"name": "catalog.json", "mtime_ns": 1, "size": 1}]}]
    })");
    // Touch catalog.json so it EXISTS but with different stat => stale.
    wfile(dir / "catalog.json", "content");
    set_base_artifact_dir(sa_core::paths::path_to_utf8(dir));
    BaseStore s;
    CHECK_FALSE(s.load(true));
    CHECK(s.status() == "error");
    CHECK(s.status_dict()["status"] == "error");
    set_base_artifact_dir("");
}

TEST_CASE("register seam: stores_api base_store() sees tables after register", "[p4][base][seam]") {
    auto dir = make_artifact("p4_base_seam");
    set_base_artifact_dir(dir);
    auto store = std::make_shared<BaseStore>();
    REQUIRE(store->load(true));
    register_base_store(store);
    auto got = base_store();
    REQUIRE(got->available());
    CHECK(got->table("TalkCfg")->contains("101001"));
    CHECK(got->table_ids("TalkCfg")->count(101001) == 1);
    // Restore the empty/default seam so other cases are unaffected.
    register_base_store(nullptr);
    set_base_artifact_dir("");
}

TEST_CASE("real resource_scan artifact loads (EDITOR_BASE_ARTIFACT_DIR)", "[p4][base][real]") {
    const char* env = std::getenv("EDITOR_BASE_ARTIFACT_DIR");
    if (!env || !*env) {
        WARN("EDITOR_BASE_ARTIFACT_DIR unset: real-artifact check skipped "
             "(regenerate with tools/resource_scan base-tables --out <dir>)");
        return;
    }
    set_base_artifact_dir(env);
    BaseStore s;
    REQUIRE(s.load(true));
    CHECK(s.available());
    auto talk = s.table_ids("TalkCfg");
    CHECK_FALSE(talk->empty());               // real talk ids are int64-parseable
    auto evt = s.table("EvtCfg");
    CHECK(evt->size() > 100);                 // real EvtCfg has thousands of rows
    auto st = s.status_dict();
    CHECK(std::find(st["missing"].begin(), st["missing"].end(), "ItemCfg") !=
          st["missing"].end());               // §4: ItemCfg dropped by tc-clean filter
    set_base_artifact_dir("");
}
