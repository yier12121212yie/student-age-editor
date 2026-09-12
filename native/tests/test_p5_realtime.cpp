// tests/test_p5_realtime.cpp — [p5] suite for the realtime watcher domain.
//
// Truth source: backend/editor/server/realtime_sync.py (+ test_realtime_sync.py
// intents: same-second equal-size ambiguity, drain-race guards) and the
// realtime block of api.py:2928-3002 for the route envelopes. Watcher-thread
// based cases stop the thread and WAIT for its exit before leaving the case,
// so no test ever mutates global state behind another's back.
//
// NOTE: the auto_start-thread case (rt_auto_start with enabled+auto_start)
// MUST stay the last TEST_CASE of this file: its watcher thread lives ~3s
// beyond the call and would otherwise race with later [p5] assertions.
#include <catch_amalgamated.hpp>

#include <atomic>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <map>
#include <mutex>
#include <regex>
#include <string>
#include <thread>
#include <vector>

#include "test_support.h"
#include "sa_core/paths.h"
#include "server/state.h"

#include "cloud_sync.h"
#include "p5_util.h"
#include "realtime.h"

namespace fs = std::filesystem;
using sa::cloud::json;  // == sa::realtime::json == nlohmann::ordered_json

namespace {

// Env-var write helper (W4-3 POSIX port): MSVC's _putenv_s on Windows,
// setenv/unsetenv on POSIX. Empty value unsets on both, matching the old
// restore-to-"" behaviour. Same shape as test_p2_workspace.cpp's ScopedEnv.
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

std::string rfile(const fs::path& p) {
    std::ifstream f(p, std::ios::binary);
    return std::string((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
}

std::vector<std::string> keys_of(const json& j) {
    std::vector<std::string> out;
    for (auto it = j.begin(); it != j.end(); ++it) out.push_back(it.key());
    return out;
}

class RtFixture {
  public:
    explicit RtFixture(const std::string& tag)
        : root_(sat::make_temp_dir(tag)), ws_(root_ / "ws"), data_(root_ / "data") {
        fs::create_directories(ws_);
        fs::create_directories(data_);
        auto& st = sa::STATE();
        {
            std::lock_guard<std::mutex> lk(st.mu_);
            saved_ws_ = st.workspace_root;
            saved_mod_root_ = st.mod_root;
            saved_mod_name_ = st.mod_name;
            st.workspace_root = P(ws_);
            st.mod_root.clear();
            st.mod_name.clear();
            st.mods_cache_valid = false;
        }
        saved_data_root_ = env_get("EDITOR_DATA_ROOT");
        saved_no_steam_ = env_get("EDITOR_DISABLE_STEAM_DETECT");
        putenv_portable("EDITOR_DATA_ROOT", P(data_).c_str());
        putenv_portable("EDITOR_DISABLE_STEAM_DETECT", "1");
        sa::realtime::clear_ambig_cache();
    }
    ~RtFixture() {
        // Belt and braces: never leave a watcher alive across fixtures.
        sa::realtime::rt_stop();
        sa::realtime::wait_thread_done(5000);
        auto& st = sa::STATE();
        {
            std::lock_guard<std::mutex> lk(st.mu_);
            st.workspace_root = saved_ws_;
            st.mod_root = saved_mod_root_;
            st.mod_name = saved_mod_name_;
            st.mods_cache_valid = false;
        }
        putenv_portable("EDITOR_DATA_ROOT", saved_data_root_.c_str());
        putenv_portable("EDITOR_DISABLE_STEAM_DETECT", saved_no_steam_.c_str());
        std::error_code ec;
        fs::remove_all(root_, ec);
    }
    RtFixture(const RtFixture&) = delete;
    RtFixture& operator=(const RtFixture&) = delete;

    static std::string env_get(const char* k) {
        const char* v = std::getenv(k);
        return v ? std::string(v) : std::string();
    }
    const fs::path& root() const { return root_; }
    const fs::path& ws() const { return ws_; }

  private:
    fs::path root_, ws_, data_;
    std::string saved_ws_, saved_mod_root_, saved_mod_name_, saved_data_root_, saved_no_steam_;
};

fs::path make_mod(const RtFixture& fx, const std::string& name) {
    fs::path mod_dir = fx.ws() / name;
    fs::create_directories(mod_dir / "Cfgs" / "zh-cn");
    std::lock_guard<std::mutex> lk(sa::STATE().mu_);
    sa::STATE().mods_cache_valid = false;
    return mod_dir;
}

std::string add_local_provider(const std::string& id, const std::string& root_dir) {
    json info;
    info["id"] = id;
    info["type"] = "local";
    info["name"] = id;
    info["config"] = json{{"root", root_dir}};
    return sa::cloud::add_provider(info)["id"].get<std::string>();
}

}  // namespace

// ---------------------------------------------------------------------------
// config
// ---------------------------------------------------------------------------

TEST_CASE("P5 rt defaults + config file location (workspace then _cache)", "[p5][rt][config]") {
    RtFixture fx("rtdef");
    CHECK(sa::realtime::rt_config_path() == P(fx.ws() / ".editor_realtime.json"));

    json def = sa::realtime::default_config();
    CHECK(keys_of(def) == std::vector<std::string>{"enabled", "provider_id", "mod_name", "mods",
                                                   "direction", "debounce_ms", "poll_interval_ms",
                                                   "remote_poll_interval_ms", "delete_extra",
                                                   "auto_start", "watch_all_mods"});
    CHECK(def["enabled"] == false);
    CHECK(def["direction"] == "upload");
    CHECK(def["debounce_ms"] == 2000);
    CHECK(def["poll_interval_ms"] == 2000);
    CHECK(def["remote_poll_interval_ms"] == 30000);

    auto cfg = sa::realtime::rt_get_config();
    CHECK(cfg == def);  // missing file -> defaults

    // update persists into the workspace file
    auto after = sa::realtime::rt_update_config(json{{"provider_id", "pp"}});
    CHECK(after["provider_id"] == "pp");
    REQUIRE(fs::exists(fx.ws() / ".editor_realtime.json"));
    CHECK(json::parse(rfile(fx.ws() / ".editor_realtime.json"))["provider_id"] == "pp");

    // fallback path: workspace gone -> <data>/_cache/realtime_config.json
    // (never call rt_config_path() while holding STATE().mu_ — it re-locks it)
    {
        {
            std::lock_guard<std::mutex> lk(sa::STATE().mu_);
            sa::STATE().workspace_root = "Z:/rt/nope";
        }
        CHECK(sa::realtime::rt_config_path() ==
              P(fx.root() / "data" / "_cache" / "realtime_config.json"));
        {
            std::lock_guard<std::mutex> lk(sa::STATE().mu_);
            sa::STATE().workspace_root = P(fx.ws());
        }
    }
}

TEST_CASE("P5 rt config clamp chain (load + update)", "[p5][rt][config]") {
    RtFixture fx("rtclamp");

    // update-side clamps
    auto c1 = sa::realtime::rt_update_config(json{
        {"debounce_ms", 10}, {"poll_interval_ms", 99999}, {"remote_poll_interval_ms", 1}});
    CHECK(c1["debounce_ms"] == 300);
    CHECK(c1["poll_interval_ms"] == 10000);
    CHECK(c1["remote_poll_interval_ms"] == 5000);
    auto c2 = sa::realtime::rt_update_config(json{
        {"debounce_ms", 99999}, {"poll_interval_ms", 600000}, {"remote_poll_interval_ms", 999999}});
    CHECK(c2["debounce_ms"] == 15000);
    CHECK(c2["poll_interval_ms"] == 10000);
    CHECK(c2["remote_poll_interval_ms"] == 300000);
    auto c3 = sa::realtime::rt_update_config(json{{"debounce_ms", "4000"}});  // numeric str
    CHECK(c3["debounce_ms"] == 4000);
    auto c4 = sa::realtime::rt_update_config(json{{"poll_interval_ms", "abc"}});  // garbage kept
    CHECK(c4["poll_interval_ms"] == 10000);  // previous value survives

    // load-side normalization from a raw persisted file (python _rt_load_config)
    wfile(fx.ws() / ".editor_realtime.json",
          R"({"enabled":true,"direction":"sideways","mods":"notalist","debounce_ms":99999,"poll_interval_ms":1500.9,"remote_poll_interval_ms":-5})");
    auto cfg = sa::realtime::rt_get_config();
    CHECK(cfg["direction"] == "upload");   // unknown direction resets
    CHECK(cfg["mods"].is_array());          // non-list mods -> []
    CHECK(cfg["mods"].empty());
    CHECK(cfg["debounce_ms"] == 15000);
    CHECK(cfg["poll_interval_ms"] == 1500);  // float truncation via int()
    CHECK(cfg["remote_poll_interval_ms"] == 5000);
    CHECK(cfg["enabled"] == true);           // unknown-elsewhere keys kept as-is
    (void)c3;
}

TEST_CASE("P5 rt update key coercion (mods/direction/bools/watch_all)", "[p5][rt][config]") {
    RtFixture fx("rtcoerce");
    auto c = sa::realtime::rt_update_config(json{{"mods", json::array({"m1", "", "  ", "m2"})}});
    // python: [str(x) for x in v if str(x).strip()] — blank entries dropped,
    // originals (unstripped) kept
    CHECK(c["mods"] == json::array({"m1", "m2"}));
    c = sa::realtime::rt_update_config(json{{"mods", "single"}});
    CHECK(c["mods"] == json::array({"single"}));
    c = sa::realtime::rt_update_config(json{{"mods", nullptr}});
    CHECK(c["mods"].is_array());
    CHECK(c["mods"].empty());
    c = sa::realtime::rt_update_config(json{{"mods", 5}});
    CHECK(c["mods"].empty());

    c = sa::realtime::rt_update_config(json{{"direction", "SYNC"}});
    CHECK(c["direction"] == "sync");
    c = sa::realtime::rt_update_config(json{{"direction", "nope"}});
    CHECK(c["direction"] == "sync");  // invalid keeps previous

    // Python bool(x), NOT _truthy: strings "false"/"0" are True
    c = sa::realtime::rt_update_config(
        json{{"delete_extra", "false"}, {"enabled", 1}, {"auto_start", 0}});
    CHECK(c["delete_extra"] == true);
    CHECK(c["enabled"] == true);
    CHECK(c["auto_start"] == false);

    c = sa::realtime::rt_update_config(json{{"mod_name", "m9"}, {"mods", json::array({"x"})}});
    CHECK(c["mod_name"] == "m9");
    c = sa::realtime::rt_update_config(json{{"watch_all_mods", true}});
    CHECK(c["mods"].empty());
    CHECK(c["mod_name"] == "");

    try {
        sa::realtime::rt_update_config(json(5));
        FAIL("expected ValueError");
    } catch (const sa::cloud::PyError& e) {
        CHECK(std::string(e.what()) == "ValueError: config patch must be dict");
    }
}

// ---------------------------------------------------------------------------
// state / events
// ---------------------------------------------------------------------------

TEST_CASE("P5 rt status shape: 16 keys incl config + cloud_sync", "[p5][rt][state]") {
    RtFixture fx("rtstate");
    auto st = sa::realtime::rt_get_status();
    CHECK(keys_of(st) ==
          std::vector<std::string>{"running", "enabled", "provider_id", "mod_name", "direction",
                                   "last_sync", "last_sync_result", "pending_count",
                                   "pending_files", "error", "events", "stats", "watching_mods",
                                   "next_remote_poll", "config", "cloud_sync"});
    CHECK(st["running"] == false);
    CHECK(st["last_sync_result"].is_null());
    CHECK(st["next_remote_poll"] == 0);
    CHECK(keys_of(st["stats"]) == std::vector<std::string>{"local_changes", "remote_changes",
                                                           "sync_success", "sync_failed"});
    CHECK(st["stats"]["local_changes"] == 0);
    CHECK(keys_of(st["config"]) == keys_of(sa::realtime::default_config()));
    CHECK(keys_of(st["cloud_sync"]) == std::vector<std::string>{"running", "provider", "action",
                                                                "progress", "total", "last",
                                                                "error", "history"});
}

TEST_CASE("P5 rt events: newest-first + status view cap 50", "[p5][rt][state]") {
    RtFixture fx("rtevents");
    std::string pid = add_local_provider("evtprov", P(fx.root() / "remote"));
    fs::create_directories(fx.root() / "remote");
    make_mod(fx, "evmod");
    sa::realtime::rt_update_config(json{{"provider_id", pid}, {"mod_name", "evmod"}});
    // each rt_stop appends one event ("realtime sync disabled"); 60 rounds
    // overflow both the 50-view and exercise the 120 ring trim.
    for (int i = 0; i < 60; ++i) sa::realtime::rt_stop();
    auto st = sa::realtime::rt_get_status();
    REQUIRE(st["events"].is_array());
    CHECK(st["events"].size() == 50);
    CHECK(st["events"][0]["msg"] == "realtime sync disabled");
    CHECK(st["events"][0]["level"] == "info");
    CHECK(std::regex_match(st["events"][0]["time"].get<std::string>(),
                           std::regex(R"(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})")));
    // start logs the enabled line with py_list_repr mods
    auto started = sa::realtime::rt_start();
    CHECK(started["running"] == true);
    CHECK(started["enabled"] == true);
    sa::realtime::rt_stop();
    sa::realtime::wait_thread_done(5000);
    auto st2 = sa::realtime::rt_get_status();
    // events[0] disabled (rt_stop), events[1] "realtime watcher stopped"
    CHECK(st2["events"][0]["msg"] == "realtime sync disabled");
    bool saw_enabled = false;
    for (const auto& e : st2["events"]) {
        std::string msg = e.contains("msg") ? e["msg"].get<std::string>() : "";
        if (msg.rfind("realtime sync enabled provider=" + pid, 0) == 0) saw_enabled = true;
    }
    CHECK(saw_enabled);
}

// ---------------------------------------------------------------------------
// change detection
// ---------------------------------------------------------------------------

TEST_CASE("P5 detect_changes sets, temp-file filtering, sorted output", "[p5][rt][detect]") {
    RtFixture fx("rtdetect");
    using Snap = std::map<std::string, std::pair<long long, long long>>;
    Snap prev{{"a.json", {1, 100}},
              {"b.json", {2, 200}},
              {"c.json", {3, 300}},
              {".editor_flow.json", {4, 400}},
              {".editor_history/snap.json", {5, 500}},
              {"~temp", {6, 600}},
              {"scratch.tmp", {7, 700}},
              {".hidden", {8, 800}},
              {"__pycache__/x.pyc", {9, 900}},
              {"_cache/y.json", {10, 1000}}};
    Snap cur{{"a.json", {1, 101}},   // 1s mtime delta -> NOT modified
             {"b.json", {2, 202}},   // 2s delta -> modified
             {"new.json", {1, 50}},   // added
             {".hidden", {8, 800}},   // prev only but invalid -> not deleted
             {"keep.hidden.json", {2, 1}}};
    cur["a.json"] = {1, 101};
    // deleted: c.json (+ invalid ones filtered out)
    auto d = sa::realtime::detect_changes(prev, cur, "", false);
    // "keep.hidden.json" is a VALID rel (hidden but .json), so it lands in added
    CHECK(d.added == std::vector<std::string>{"keep.hidden.json", "new.json"});
    CHECK(d.modified == std::vector<std::string>{"b.json"});
    CHECK(d.deleted == std::vector<std::string>{"c.json"});
    CHECK(d.changed ==
          std::vector<std::string>{"b.json", "keep.hidden.json", "new.json"});  // sorted union

    // added-side invalid filtering: everything junk never reaches `added`
    Snap empty_prev;
    Snap junk{{".editor_flow.json", {1, 1}}, {".editor_history/s.json", {1, 1}},
              {"~x", {1, 1}}, {"x.tmp", {1, 1}}, {"x.swp", {1, 1}}, {".hidden", {1, 1}},
              {"__pycache__/y", {1, 1}}, {"_cache/z", {1, 1}}};
    auto dj = sa::realtime::detect_changes(empty_prev, junk, "", false);
    CHECK(dj.added.empty());
    CHECK(dj.changed.empty());
    // hidden .json IS valid (ends .json)
    Snap one{{".editor_x.json", {1, 1}}};
    auto dk = sa::realtime::detect_changes(empty_prev, one, "", false);
    CHECK(dk.added == std::vector<std::string>{".editor_x.json"});
}

TEST_CASE("P5 ambig sha baseline: same-second equal-size edits (parity test_realtime_sync)",
          "[p5][rt][detect]") {
    RtFixture fx("rtambig");
    fs::path mod_dir = make_mod(fx, "m1");
    fs::path path = mod_dir / "Cfgs" / "TalkCfg.json";
    sa::realtime::clear_ambig_cache();

    wfile(path, "ABCDEFGHIJ");
    CHECK_FALSE(sa::realtime::ambig_content_changed("m1", "Cfgs/TalkCfg.json"));  // baseline
    wfile(path, "abcdefghij");  // equal length, different content
    CHECK(sa::realtime::ambig_content_changed("m1", "Cfgs/TalkCfg.json"));
    wfile(path, "ABCDEFGHIJ");  // changed again
    CHECK(sa::realtime::ambig_content_changed("m1", "Cfgs/TalkCfg.json"));
    CHECK(sa::realtime::ambig_content_changed("m1", "Cfgs/Missing.json") == false);  // not a file
    sa::realtime::clear_ambig_cache();

    // _detect_changes over identical tuples reports the content change only via ambig
    std::map<std::string, std::pair<long long, long long>> snap{
        {"Cfgs/TalkCfg.json", {10, 1000}}};
    sa::realtime::clear_ambig_cache();
    auto d0 = sa::realtime::detect_changes(snap, snap, "m1", true);
    CHECK(d0.changed.empty());  // first look records the baseline
    wfile(path, "xyzabcdxyz");  // equal length again
    auto d1 = sa::realtime::detect_changes(snap, snap, "m1", true);
    REQUIRE(d1.changed.size() == 1);
    CHECK(d1.changed[0] == "Cfgs/TalkCfg.json");
    auto d2 = sa::realtime::detect_changes(snap, snap, "m1", false);  // ambig off -> blind
    CHECK(d2.changed.empty());
    sa::realtime::clear_ambig_cache();
}

// ---------------------------------------------------------------------------
// start / stop control
// ---------------------------------------------------------------------------

TEST_CASE("P5 rt_start validation envelopes + stop idempotence", "[p5][rt][control]") {
    RtFixture fx("rtstart");
    // no provider_id
    try {
        sa::realtime::rt_start();
        FAIL("expected ValueError");
    } catch (const sa::cloud::PyError& e) {
        CHECK(std::string(e.what()) == "ValueError: provider_id required to start realtime sync");
    }
    // provider but nothing to watch (empty workspace, no mods list)
    sa::realtime::rt_update_config(json{{"provider_id", "p1"}});
    try {
        sa::realtime::rt_start();
        FAIL("expected ValueError");
    } catch (const sa::cloud::PyError& e) {
        CHECK(std::string(e.what()) == "ValueError: no mods to watch (select mod or enable watch_all)");
    }
    // stop without a live thread: benign, config disabled, logs event
    auto st = sa::realtime::rt_stop();
    CHECK(st["running"] == false);
    CHECK(st["enabled"] == false);
    CHECK(st["config"]["enabled"] == false);
    CHECK(sa::realtime::wait_thread_done(100) == true);
}

TEST_CASE("P5 rt_start -> watcher syncs a local change end to end -> rt_stop",
          "[p5][rt][control]") {
    RtFixture fx("rte2e");
    fs::path remote = fx.root() / "remote";
    fs::create_directories(remote);
    std::string pid = add_local_provider("e2eprov", P(remote));
    fs::path mod_dir = make_mod(fx, "m1");

    sa::realtime::rt_update_config(json{
        {"provider_id", pid}, {"mod_name", "m1"}, {"direction", "upload"},
        {"debounce_ms", 300}, {"poll_interval_ms", 500},
    });
    auto st = sa::realtime::rt_start();
    CHECK(st["running"] == true);
    CHECK(st["enabled"] == true);
    CHECK(st["watching_mods"] == json::array({"m1"}));
    CHECK(st["config"]["enabled"] == true);

    // already-running start is a no-op (no respawn)
    auto st_again = sa::realtime::rt_start();
    CHECK(st_again["running"] == true);

    // mutate the mod: the watcher must auto-upload it to <remote>/mods/m1/...
    // The first write can lose a race against the watcher's initial snapshot on
    // a loaded runner (make_mod creates no files, so a snapshot taken after the
    // write swallows the change and nothing is ever "added") — rewrite mid-wait
    // so an already-polling watcher still detects it.
    fs::path talk = mod_dir / "Cfgs" / "zh-cn" / "TalkCfg.json";
    fs::path expect = remote / "mods" / "m1" / "Cfgs" / "zh-cn" / "TalkCfg.json";
    std::string sent;
    bool uploaded = false;
    for (int i = 0; i < 240 && !uploaded; ++i) {  // <= 24s
        if (i == 0) { wfile(talk, "{\"v\":1}"); sent = "{\"v\":1}"; }
        if (i == 50) { wfile(talk, "{\"v\":2}"); sent = "{\"v\":2}"; }  // ~5s: beat the snapshot race
        uploaded = fs::exists(expect);
        if (!uploaded) std::this_thread::sleep_for(std::chrono::milliseconds(100));
    }
    sa::realtime::rt_stop();
    sa::realtime::wait_thread_done(5000);
    CHECK(uploaded);
    if (uploaded) CHECK(rfile(expect) == sent);
    auto st2 = sa::realtime::rt_get_status();
    CHECK(st2["running"] == false);
    CHECK(st2["enabled"] == false);
    CHECK(st2["config"]["enabled"] == false);
    CHECK(st2["stats"]["local_changes"].get<long long>() >= 1);
    CHECK(st2["stats"]["sync_success"].get<long long>() >= 1);
    CHECK_FALSE(st2["last_sync"].get<std::string>().empty());
    REQUIRE(st2["last_sync_result"].is_object());
    CHECK(st2["last_sync_result"]["total"] == 1);
    CHECK(st2["last_sync_result"]["results"][0]["result"]["ok"] == true);
}

// ---------------------------------------------------------------------------
// Concurrency regression: two racing rt_start calls must spawn ONE watcher.
// Previously g_state["running"]/g_alive were only published inside the freshly
// detached thread, so both callers saw alive==false and each detached a
// watcher, which then raced the unsynchronized watcher-owned globals.
// ---------------------------------------------------------------------------

TEST_CASE("P5 rt_start concurrent calls spawn a single watcher", "[p5][rt][control]") {
    RtFixture fx("rtrace");
    fs::path remote = fx.root() / "remote";
    fs::create_directories(remote);
    std::string pid = add_local_provider("raceprov", P(remote));
    make_mod(fx, "m1");
    sa::realtime::rt_update_config(json{
        {"provider_id", pid}, {"mod_name", "m1"}, {"direction", "upload"},
        {"debounce_ms", 300}, {"poll_interval_ms", 500},
    });

    const int before = sa::realtime::watcher_starts_for_test();
    std::atomic<int> ready{0};
    std::atomic<bool> go{false};
    std::vector<std::thread> racers;
    std::atomic<int> running_seen{0};
    for (int i = 0; i < 8; ++i) {
        racers.emplace_back([&]() {
            ready.fetch_add(1);
            while (!go.load()) std::this_thread::yield();
            try {
                if (sa::realtime::rt_start()["running"] == true) running_seen.fetch_add(1);
            } catch (...) {
            }
        });
    }
    while (ready.load() < 8) std::this_thread::yield();
    go.store(true);  // release them together to maximize the race window
    for (auto& t : racers) t.join();

    CHECK(running_seen.load() == 8);                                 // all report running
    CHECK(sa::realtime::watcher_starts_for_test() - before == 1);    // exactly one spawned
    CHECK(sa::realtime::rt_get_status()["running"] == true);
    sa::realtime::rt_stop();
}

// ---------------------------------------------------------------------------
// auto_start — MUST be the last TEST_CASE (detached 3s-delayed thread).
// ---------------------------------------------------------------------------

TEST_CASE("P5 rt_auto_start: no-op when disabled; delayed failure envelope when unstartable",
          "[p5][rt][control]") {
    RtFixture fx("rtauto");
    // disabled config -> does nothing at all
    sa::realtime::rt_auto_start();
    CHECK(sa::realtime::rt_get_status()["running"] == false);
    CHECK(sa::realtime::wait_thread_done(10) == true);

    // enabled + auto_start but no provider_id: the 3s-delayed thread must
    // surface "auto_start failed" as an error event (and state.error).
    std::string ev_before;
    sa::realtime::rt_update_config(json{{"enabled", true}, {"auto_start", true}});
    sa::realtime::rt_auto_start();
    bool saw_failure = false;
    for (int i = 0; i < 80 && !saw_failure; ++i) {  // <= 8s
        auto st = sa::realtime::rt_get_status();
        for (const auto& e : st["events"]) {
            std::string msg = e.contains("msg") ? e["msg"].get<std::string>() : "";
            if (msg.find("auto_start failed") != std::string::npos) {
                CHECK(e["level"] == "error");
                CHECK(msg.find("provider_id required to start realtime sync") !=
                      std::string::npos);
                saw_failure = true;
                break;
            }
        }
        if (!saw_failure) std::this_thread::sleep_for(std::chrono::milliseconds(100));
    }
    CHECK(saw_failure);
    CHECK(sa::realtime::rt_get_status()["error"].get<std::string>().find(
              "provider_id required") != std::string::npos);
    // reset so the fixture destructor's rt_stop runs against a sane state
    sa::realtime::rt_update_config(json{{"enabled", false}, {"auto_start", false}});
    (void)ev_before;
}
