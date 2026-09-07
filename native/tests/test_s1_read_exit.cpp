// tests/test_s1_read_exit.cpp — S1 read-path acceptance, ported line-by-line
// from backend/editor/server/test_s1_read_exit.py.
//
// Every case documents its Python origin and the pitfall id it locks in
// (CONVENTIONS 10): S1 (免序列化三零), A10 (逐表指纹/写后播种), A7 (一次读盘).
#include <catch_amalgamated.hpp>

#include <fstream>

#include "sa_core/json_wire.h"
#include "sa_core/paths.h"
#include "sa_core/strings.h"
#include "sa_core/utf8.h"
#include "sa_core/util.h"
#include "server/api_router.h"
#include "server/cfg_cache.h"
#include "server/cfg_store.h"
#include "server/perf.h"
#include "server/state.h"
#include "test_support.h"

namespace {

using sa::json;

// test_s1_read_exit.py:34-51 _legacy_cfg_read — the byte-for-byte reference
// implementation of the no-cache path (kills indent/ensure_ascii parameter mixups).
std::string legacy_cfg_read(const std::string& path, const std::string& cfg_name) {
    auto raw = sa_core::paths::read_bytes(path);
    REQUIRE(raw.has_value());
    bool lossy = false;
    std::string content;
    auto strict = sa_core::decode_utf8_sig_strict(*raw);
    if (strict) {
        content = *strict;
    } else {
        content = sa_core::decode_utf8_sig_replace(*raw);
        lossy = true;
    }
    json data = json::parse(sa_core::str::trim(content).empty() ? "{}" : sa_core::str::trim(content));
    if (!data.is_object()) data = json::object();
    auto st = sa_core::paths::stat(path);
    json payload;
    payload["cfg"] = cfg_name;
    payload["data"] = data;
    payload["exists"] = true;
    payload["mtime_ns"] = st->mtime_ns;
    if (lossy) payload["lossy"] = true;
    return sa_core::py_dumps(payload);
}

struct Counters {
    long long parses, dumps, read_bytes, reads;
};
Counters snapshot_counters() {
    return {sa::get(sa::lc::kCfgParses), sa::get(sa::lc::kCfgDumps),
            sa::get(sa::lc::kCfgReadBytes), sa::get(sa::lc::kCfgReads)};
}

}  // namespace

TEST_CASE("S1 hot GET has zero parse/dump/read_bytes counters", "[s1][A7][S1]") {
    sat::CfgFixture fx("s1_hot");
    fx.write_cfg_file("TalkCfg", sat::big_table_text());
    sat::call_router(fx.router(), "GET", "/api/cfg/TalkCfg");  // warm

    auto before = snapshot_counters();
    auto res = sat::call_router(fx.router(), "GET", "/api/cfg/TalkCfg");
    REQUIRE(res.status == 200);
    REQUIRE(res.is_bytes);  // 免序列化原始字节出口 (httpd.py:157-160)
    auto after = snapshot_counters();
    CHECK(after.parses - before.parses == 0);
    CHECK(after.dumps - before.dumps == 0);       // bytes 直发不计 dumps
    CHECK(after.read_bytes - before.read_bytes == 0);
    CHECK(after.reads - before.reads == 1);       // per-request counter still ticks
}

TEST_CASE("S1 cache-hit bytes equal fresh serialization", "[s1][B5][S1]") {
    sat::CfgFixture fx("s1_bytes");
    fx.write_cfg_file("TalkCfg", sat::big_table_text());
    auto warm = sat::call_router(fx.router(), "GET", "/api/cfg/TalkCfg");
    auto warm2 = sat::call_router(fx.router(), "GET", "/api/cfg/TalkCfg");
    std::string legacy = legacy_cfg_read(fx.cfg_path_str("TalkCfg"), "TalkCfg");
    // test_s1_read_exit.py:106-109: byte equality, only possible with the same
    // json.dumps parameter set on both sides.
    REQUIRE(warm2.is_bytes);
    CHECK(warm2.bytes == legacy);
    CHECK(warm.bytes == warm2.bytes);
    // behavioural equivalence (parse both, compare trees)
    auto a = json::parse(warm.bytes);
    auto b = json::parse(legacy);
    CHECK(a == b);
}

TEST_CASE("S1 invalidation via forced mtime, not sleep", "[s1][A10][B6]") {
    sat::CfgFixture fx("s1_inval");
    fx.write_cfg_file("TalkCfg", sat::big_table_text());
    auto first = sat::call_router(fx.router(), "GET", "/api/cfg/TalkCfg");
    fx.write_cfg_file("TalkCfg", sat::big_table_text(1200, 'y'));  // external rewrite, same size
    auto st = sa_core::paths::stat(fx.cfg_path_str("TalkCfg"));
    REQUIRE(st.has_value());
    // Windows mtime granularity ~15.6ms: force the clock forward (os.utime).
    REQUIRE(sa_core::paths::set_mtime_ns(fx.cfg_path_str("TalkCfg"), st->mtime_ns + 1000000000LL));
    auto before = sa::get(sa::lc::kCfgParses);
    auto second = sat::call_router(fx.router(), "GET", "/api/cfg/TalkCfg");
    CHECK(sa::get(sa::lc::kCfgParses) - before == 1);  // exactly one re-parse
    REQUIRE(second.is_bytes);
    CHECK(second.bytes.find("y190") != std::string::npos);  // new content present
    auto d1 = json::parse(first.is_bytes ? first.bytes : sa_core::py_dumps(first.json_payload));
    auto d2 = json::parse(second.bytes);
    CHECK(d1["data"] != d2["data"]);
}

TEST_CASE("S1 write reparses only the written table", "[s1][A10][S1]") {
    sat::CfgFixture fx("s1_write");
    fx.write_cfg_file("TalkCfg", sat::big_table_text());
    fx.write_cfg_file("OptionCfg", sat::big_table_text());
    sat::call_router(fx.router(), "GET", "/api/cfg/TalkCfg");
    sat::call_router(fx.router(), "GET", "/api/cfg/OptionCfg");
    auto before = sa::get(sa::lc::kCfgParses);
    json new_data = json::parse(sat::big_table_text(1200, 'z'));
    auto res = sat::call_router(fx.router(), "PUT", "/api/cfg/TalkCfg", {},
                                json{{"data", new_data}});
    REQUIRE(res.status == 200);
    auto after_write = sa::get(sa::lc::kCfgParses);
    // the pre-write lossy probe hits the warm cache: 0 parses during the PUT
    CHECK(after_write - before == 0);
    auto talk = sat::call_router(fx.router(), "GET", "/api/cfg/TalkCfg");
    // write-after seeding (api.py:488-506): the first GET after the write is
    // already zero-parse
    CHECK(sa::get(sa::lc::kCfgParses) - after_write == 0);
    auto body = json::parse(talk.is_bytes ? talk.bytes : sa_core::py_dumps(talk.json_payload));
    CHECK(body["data"] == new_data);
    sat::call_router(fx.router(), "GET", "/api/cfg/OptionCfg");
    // OptionCfg stayed cached end to end (one write never re-parses other tables)
    CHECK(sa::get(sa::lc::kCfgParses) - before == 0);
}

TEST_CASE("S1 patch then GET is zero parse", "[s1][S2][S1]") {
    sat::CfgFixture fx("s1_patch");
    fx.write_cfg_file("TalkCfg", sat::big_table_text());
    sat::call_router(fx.router(), "GET", "/api/cfg/TalkCfg");
    auto before = sa::get(sa::lc::kCfgParses);
    json patch_body;
    patch_body["patch"] = json{{"set", json{{"7", json{{"id", 7}, {"content", "补丁行"}}}}}};
    auto res = sat::call_router(fx.router(), "PUT", "/api/cfg/TalkCfg", {}, patch_body);
    REQUIRE(res.status == 200);
    auto env = json::parse(sa_core::py_dumps(res.json_payload));
    CHECK(env["applied_set"] == 1);
    auto body = sat::call_router(fx.router(), "GET", "/api/cfg/TalkCfg");
    auto parsed = json::parse(body.is_bytes ? body.bytes : sa_core::py_dumps(body.json_payload));
    // Python's {"id": 7, "content": "补丁行"} — non-ASCII round-trips verbatim.
    CHECK(parsed["data"]["7"] == json({{"id", 7}, {"content", "补丁行"}}));
    CHECK(parsed["data"].contains("1000"));  // untouched rows survive
    // apply_patch reads current data through the parse provider (api.py:343-350):
    // no full-table re-parse anywhere in this flow.
    CHECK(sa::get(sa::lc::kCfgParses) - before == 0);
}

TEST_CASE("S1 GET projections: meta / keys / prefix / missing / parse-error", "[s1][5.3]") {
    sat::CfgFixture fx("s1_proj");
    // CONVENTIONS 5.3 table, one assertion per row.
    auto missing = sat::call_router(fx.router(), "GET", "/api/cfg/Nope");
    REQUIRE(missing.status == 200);  // missing file is NOT 404
    auto m = json::parse(sa_core::py_dumps(missing.json_payload));
    CHECK(m["exists"] == false);
    CHECK(m["data"].is_object());
    CHECK(m["data"].empty());
    CHECK(m["mtime_ns"].is_null());

    fx.write_cfg_file("Small", R"({"10": {"id": 10}, "2": {"id": 2}})");
    auto meta = sat::call_router(fx.router(), "GET", "/api/cfg/Small", {{"meta", "1"}});
    auto mj = json::parse(sa_core::py_dumps(meta.json_payload));
    CHECK(mj.contains("count"));
    CHECK(mj["count"] == 2);
    CHECK_FALSE(mj.contains("data"));  // meta=1 never ships the table

    auto keys = sat::call_router(fx.router(), "GET", "/api/cfg/Small", {{"keys", "1"}});
    auto kj = json::parse(sa_core::py_dumps(keys.json_payload));
    // sorted(data.keys()) — string sort: "10" < "2"
    REQUIRE(kj["keys"].is_array());
    CHECK(kj["keys"][0] == "10");
    CHECK(kj["keys"][1] == "2");

    fx.write_cfg_file("Pfx", R"({"ab123": 1, "ab456": 2, "zz000": 3})");
    auto p = sat::call_router(fx.router(), "GET", "/api/cfg/Pfx",
                              {{"prefix", "ab,zz"}, {"suffix", "3"}});
    auto pj = json::parse(sa_core::py_dumps(p.json_payload));
    // _prefix_match (api.py:515-519): str(key)[:-3] in {ab, zz}
    CHECK(pj["data"].size() == 3);
    auto p2 = sat::call_router(fx.router(), "GET", "/api/cfg/Pfx",
                               {{"prefix", "ab"}, {"suffix", "3"}});
    auto p2j = json::parse(sa_core::py_dumps(p2.json_payload));
    CHECK(p2j["data"].size() == 2);
    // suffix clamps: N>8 clamps to 8; garbage falls back to 3
    auto p3 = sat::call_router(fx.router(), "GET", "/api/cfg/Pfx",
                               {{"prefix", "ab123zz0"}, {"suffix", "99"}});
    auto p3j = json::parse(sa_core::py_dumps(p3.json_payload));
    CHECK(p3j["data"].empty());  // clamp 8: short keys pass through whole, none equals the prefix
    auto p4 = sat::call_router(fx.router(), "GET", "/api/cfg/Pfx", {{"prefix", "ab"}, {"suffix", "x"}});
    auto p4j = json::parse(sa_core::py_dumps(p4.json_payload));
    CHECK(p4j["data"].size() == 2);  // invalid suffix -> default 3

    fx.write_cfg_file("Broken", "{not json");
    auto err = sat::call_router(fx.router(), "GET", "/api/cfg/Broken");
    REQUIRE(err.status == 400);
    auto ej = json::parse(sa_core::py_dumps(err.json_payload));
    // api.py:569 — the exact Python error string
    CHECK(ej["error"] == "JSON parse failed: 文件内容不是合法 JSON");
    CHECK(ej["cfg"] == "Broken");
}

TEST_CASE("S1 empty/whitespace file reads as {}", "[s1][3]") {
    sat::CfgFixture fx("s1_empty");
    fx.write_cfg_file("Blank", "   \n ");
    auto r = sat::call_router(fx.router(), "GET", "/api/cfg/Blank");
    REQUIRE(r.status == 200);
    auto j = json::parse(sa_core::py_dumps(r.json_payload));
    CHECK(j["data"].is_object());
    CHECK(j["data"].empty());
    CHECK(j["exists"] == true);
}

TEST_CASE("S1 array top-level file behaves like {}", "[s1][572-573]") {
    sat::CfgFixture fx("s1_array");
    fx.write_cfg_file("Arr", "[1,2,3]");
    auto r = sat::call_router(fx.router(), "GET", "/api/cfg/Arr");
    REQUIRE(r.status == 200);
    auto j = json::parse(sa_core::py_dumps(r.json_payload));
    CHECK(j["data"].empty());  // api.py:572-573: top-level non-object -> {}
}
