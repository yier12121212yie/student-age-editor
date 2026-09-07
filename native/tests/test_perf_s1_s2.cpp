// tests/test_perf_s1_s2.cpp — black-box 40MB acceptance over the REAL transport
// (CONVENTIONS 7 exit criteria + brief acceptance item 3):
//   cold GET: parses=1 dumps=1 read_bytes=file size
//   hot GET:  Δ all three == 0, response bytes == cold GET
//   patch:    Δwrites=1, response < 2048 bytes, stack_bytes == 0
//   GET after patch: three zeros again (write-after seeding), count correct
//
// Requests go through an httplib CLIENT against the loopback port — no test can
// peek inside, so the counters come back over GET /api/perf like any client.
#include <catch_amalgamated.hpp>

#include <filesystem>
#include <fstream>
#include <string>
#include <thread>

#include "bench_gen.h"
#include "httplib.h"
#include "sa_core/paths.h"
#include "sa_core/utf8.h"
#include "server/api_router.h"
#include "server/httpd.h"
#include "server/state.h"
#include "test_support.h"

namespace {

long long perf_counter(httplib::Client& cli, const char* key) {
    auto res = cli.Get("/api/perf");
    REQUIRE(res);
    REQUIRE(res->status == 200);
    auto j = nlohmann::ordered_json::parse(res->body);
    return j["counters"].contains(key) ? j["counters"][key].get<long long>() : 0;
}

long long perf_stack_bytes(httplib::Client& cli) {
    auto res = cli.Get("/api/perf");
    REQUIRE(res);
    auto j = nlohmann::ordered_json::parse(res->body);
    return j["debug"]["stack_bytes"].get<long long>();
}

}  // namespace

TEST_CASE("40MB read/write acceptance over HTTP", "[perf][s1][s2][bench][slow]") {
    namespace fs = std::filesystem;
    auto ws = sat::make_temp_dir("perf40");
    auto mod = ws / "mod";
    auto cfg_dir = mod / "Cfgs" / "zh-cn";
    fs::create_directories(cfg_dir);
    const std::string text = sat::synthetic_talk_cfg();
    std::string table_path = sa_core::paths::path_to_utf8(cfg_dir / "TalkCfg.json");
    REQUIRE(sa_core::paths::write_bytes_simple(table_path, text));
    const long long file_size = static_cast<long long>(text.size());
    // benchdata.py:95-99 size contract (±5%)
    CHECK(std::llabs(file_size - sat::kTargetSize) < sat::kTargetSize / 20);

    {
        auto& st = sa::STATE();
        std::lock_guard<std::mutex> lk(st.mu_);
        st.workspace_root = sa_core::paths::path_to_utf8(ws);
        st.mod_root = sa_core::paths::path_to_utf8(mod);
        st.mod_name = "mod";
        st.mods_cache_valid = false;
    }
    sa::invalidate_table_cache_all();
    sa::reset();
    sa::Router router = sa::build_router();
    sa::Httpd server(&router);
    std::string err;
    REQUIRE(server.bind_to("127.0.0.1", 0, &err));
    server.start();
    httplib::Client cli("http://127.0.0.1:" + std::to_string(server.port()));
    cli.set_read_timeout(120, 0);
    cli.set_write_timeout(120, 0);

    SECTION("cold -> hot -> patch -> hot, counters and bytes all verified") {
        long long p0 = perf_counter(cli, "cfg.parses");
        long long d0 = perf_counter(cli, "cfg.dumps");
        long long rb0 = perf_counter(cli, "cfg.read_bytes");
        long long r0 = perf_counter(cli, "cfg.reads");
        auto cold = cli.Get("/api/cfg/TalkCfg");
        REQUIRE(cold);
        REQUIRE(cold->status == 200);
        long long p1 = perf_counter(cli, "cfg.parses");
        long long d1 = perf_counter(cli, "cfg.dumps");
        long long rb1 = perf_counter(cli, "cfg.read_bytes");
        long long r1 = perf_counter(cli, "cfg.reads");
        INFO("cold: parses=" << p1 - p0 << " dumps=" << d1 - d0
                             << " read_bytes=" << rb1 - rb0 << " size=" << file_size);
        CHECK(p1 - p0 == 1);                    // one real parse
        CHECK(d1 - d0 == 1);                    // one real serialization
        CHECK(rb1 - rb0 == file_size);          // one real read of the whole table
        CHECK(r1 - r0 == 1);
        CHECK(static_cast<long long>(cold->body.size()) > file_size);  // envelope overhead

        // Hot GET: zero read / zero parse / zero serialize, byte-identical body.
        auto hot = cli.Get("/api/cfg/TalkCfg");
        REQUIRE(hot);
        long long p2 = perf_counter(cli, "cfg.parses");
        long long d2 = perf_counter(cli, "cfg.dumps");
        long long rb2 = perf_counter(cli, "cfg.read_bytes");
        CHECK(p2 - p1 == 0);
        CHECK(d2 - d1 == 0);
        CHECK(rb2 - rb1 == 0);
        CHECK(hot->body == cold->body);         // CONVENTIONS 7 热 GET 三零 + bytes equal

        // Single-field patch (S2 shape): one write, tiny response, no stack text.
        long long w0 = perf_counter(cli, "cfg.writes");
        long long sb_before = perf_stack_bytes(cli);
        nlohmann::ordered_json patch_body;
        patch_body["patch"]["set"]["999999"] = {{"id", 999999}, {"content", "补丁行"}};
        auto patch = cli.Put("/api/cfg/TalkCfg", patch_body.dump(), "application/json");
        REQUIRE(patch);
        REQUIRE(patch->status == 200);
        long long w1 = perf_counter(cli, "cfg.writes");
        CHECK(w1 - w0 == 1);                    // CONVENTIONS 7: 单字段补丁 Δwrites=1
        CHECK(static_cast<long long>(patch->body.size()) < 2048);  // response < 2KB
        auto env = nlohmann::ordered_json::parse(patch->body);
        CHECK(env["applied_set"] == 1);
        CHECK(env["ok"] == true);
        CHECK(env.contains("snapshot"));        // overwrite of an existing table -> snapshot

        // GET after the patch: seeding makes it three-zero again; content updated.
        long long p3 = perf_counter(cli, "cfg.parses");
        long long d3 = perf_counter(cli, "cfg.dumps");
        long long rb3 = perf_counter(cli, "cfg.read_bytes");
        auto after = cli.Get("/api/cfg/TalkCfg");
        REQUIRE(after);
        long long p4 = perf_counter(cli, "cfg.parses");
        long long d4 = perf_counter(cli, "cfg.dumps");
        long long rb4 = perf_counter(cli, "cfg.read_bytes");
        CHECK(p4 - p3 == 0);
        CHECK(d4 - d3 == 0);
        CHECK(rb4 - rb3 == 0);
        auto body = nlohmann::ordered_json::parse(after->body);
        CHECK(body["data"].size() == static_cast<size_t>(sat::kNumRows) + 1);  // one row added
        CHECK(body["data"]["999999"] == nlohmann::ordered_json{{"id", 999999},
                                                               {"content", "补丁行"}});
        CHECK(body["data"]["0"]["id"].get<std::string>() == "0");  // bench row shape kept

        // meta projection count agrees, and the undo stack holds no table text.
        auto meta = cli.Get("/api/cfg/TalkCfg?meta=1");
        REQUIRE(meta);
        auto mj = nlohmann::ordered_json::parse(meta->body);
        CHECK(mj["count"].get<long long>() == static_cast<long long>(sat::kNumRows) + 1);
        CHECK(perf_stack_bytes(cli) == 0);      // A8: snapshot-backed stack, ≈0 bytes
        (void)sb_before;
    }

    server.stop();
    sa::detail::clear_shutdown_for_test();
    std::error_code ec;
    fs::remove_all(ws, ec);
    fs::remove_all(mod.parent_path() / ".editor_history", ec);
}

TEST_CASE("40MB patch response stays < 2KB while the table body is bytes-direct",
          "[perf][s2][slow]") {
    // Guards the regression "patch ships the whole table back": the PUT response
    // must stay tiny no matter how big the table is (S2 exit metric).
    namespace fs = std::filesystem;
    auto ws = sat::make_temp_dir("perf40b");
    auto mod = ws / "mod";
    auto cfg_dir = mod / "Cfgs" / "zh-cn";
    fs::create_directories(cfg_dir);
    std::string table_path = sa_core::paths::path_to_utf8(cfg_dir / "TalkCfg.json");
    REQUIRE(sa_core::paths::write_bytes_simple(table_path, sat::synthetic_talk_cfg()));
    {
        auto& st = sa::STATE();
        std::lock_guard<std::mutex> lk(st.mu_);
        st.workspace_root = sa_core::paths::path_to_utf8(ws);
        st.mod_root = sa_core::paths::path_to_utf8(mod);
        st.mod_name = "mod";
    }
    sa::invalidate_table_cache_all();
    sa::reset();
    sa::Router router = sa::build_router();
    sa::Httpd server(&router);
    REQUIRE(server.bind_to("127.0.0.1", 0, nullptr));
    server.start();
    httplib::Client cli("http://127.0.0.1:" + std::to_string(server.port()));
    cli.set_read_timeout(120, 0);

    // warm the cache so the patch path exercises the parse provider
    auto warm = cli.Get("/api/cfg/TalkCfg");
    REQUIRE(warm);
    nlohmann::ordered_json patch;
    patch["patch"]["remove"] = nlohmann::ordered_json::array({"5000"});
    auto res = cli.Put("/api/cfg/TalkCfg", patch.dump(), "application/json");
    REQUIRE(res);
    REQUIRE(res->status == 200);
    CHECK(static_cast<long long>(res->body.size()) < 2048);
    auto after = cli.Get("/api/cfg/TalkCfg?meta=1");
    auto mj = nlohmann::ordered_json::parse(after->body);
    CHECK(mj["count"].get<long long>() == static_cast<long long>(sat::kNumRows) - 1);
    server.stop();
    std::error_code ec;
    fs::remove_all(ws, ec);
}
