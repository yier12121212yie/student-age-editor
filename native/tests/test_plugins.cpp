// [plugins] — R4: the /api/plugins family as a DECLARATIVE implementation
// (native/server/services/plugins_routes.cpp, PLUGIN_SPEC §5).
//
// Same in-process dispatch style as the p3b tests, but on the REAL route bus
// (sat::CfgFixture builds sa::build_router()), so the statics-before-<pid>
// registration order of the family is covered too. Everything runs against a
// temp EDITOR_PLUGINS_ROOT; the user's real plugins directory is never touched.
//
// Zip fixtures are base64 built with Python zipfile (same approach as
// p3b_zip_fixtures.h).
#include <cstdlib>
#include <fstream>
#include <map>
#include <string>
#include <vector>

#include <catch_amalgamated.hpp>

#include "p3b_support.h"
#include "plugin_service.h"
#include "plugins_routes.h"
#include "sa_core/paths.h"
#include "sa_core/strings.h"
#include "test_support.h"

namespace {

namespace cs = sa_core::paths;

// Env var RAII (same shape as the [p3b] suite's ScopedEnv): set a temp plugins
// root for the case, restore whatever was there afterwards.
struct ScopedEnv {
    std::string key;
    std::string saved;
    bool had;
    explicit ScopedEnv(const std::string& k, const std::string& v) : key(k) {
        const char* cur = std::getenv(k.c_str());
        had = cur != nullptr;
        saved = cur ? cur : "";
        set(v);
    }
    ~ScopedEnv() {
        if (had) set(saved);
#ifdef _WIN32
        else _putenv_s(key.c_str(), "");
#else
        else unsetenv(key.c_str());
#endif
    }
    // Portable env set (test_p2_workspace.cpp ScopedEnv is the precedent).
    void set(const std::string& v) {
#ifdef _WIN32
        _putenv_s(key.c_str(), v.c_str());
#else
        setenv(key.c_str(), v.c_str(), 1);
#endif
    }
    ScopedEnv(const ScopedEnv&) = delete;
    ScopedEnv& operator=(const ScopedEnv&) = delete;
};

// Full bus (api_router.cpp) => register_plugins_routes is mounted exactly the
// way the server mounts it. The §4 service cache is process-global, so every
// case starts from an empty one (a leftover verdict from a previous case's
// root would otherwise bleed into this case's rows).
struct PluginsFixture : sat::CfgFixture {
    PluginsFixture() : sat::CfgFixture("plugins") { sa::plugin_service::reset_for_test(); }
    sa::Resp call(const std::string& method, const std::string& path,
                  std::map<std::string, std::string> query = {},
                  const sa::json& body = sa::json()) {
        return sat::call_router(router(), method, path, std::move(query), body);
    }
};

std::string fixture_root() {
    static auto p = sat::make_temp_dir("plugins_env");
    return cs::path_to_utf8(p);
}

int g_seq = 0;
std::string fresh_root(const char* tag) {
    const std::string p = cs::join(fixture_root(), std::string(tag) + "_" + std::to_string(++g_seq));
    cs::create_dirs(p);
    return p;
}

void make_plugin(const std::string& root, const std::string& pid, const std::string& manifest_text) {
    const std::string dir = cs::join(root, pid);
    cs::create_dirs(dir);
    cs::write_bytes_simple(cs::join(dir, "manifest.json"), manifest_text);
}

std::vector<std::string> keys_of(const sa::json& v) {
    std::vector<std::string> out;
    for (auto it = v.begin(); it != v.end(); ++it) out.push_back(it.key());
    return out;
}

std::string raw_of(const std::string& b64) {
    auto r = sa::p3b::b64_decode_strict(b64);
    return r ? *r : std::string();
}

// ---------------------------------------------------------------------------
// zip fixtures (manifest.json only unless noted; NONE of them carries
// plugin.py — declarative install must not require an entry file)
// ---------------------------------------------------------------------------

// id "installed_demo" + ui.flow_cards + ui.panels + service + a nested file.
const char* const kPLUGIN_ZIP =
    "UEsDBBQAAAAIANK2KV12TwxF7wAAAGcBAAANAAAAbWFuaWZlc3QuanNvbmWOzUoDMRSFX6VkLdNmXIjzKlKGmFxpaJqE"
    "5M7YMgTcuHDhzm0X/qxdiwi+jK36FuamsxAlEHK+k3PvGZhWrJkwbSMKY0C1ClaOHU2YFSsgZ/d88/V4vX+7+3x6Jd5D"
    "iNpZsuqKVzNiosOFC4SEPIdASEGUQXscv5Ik3OmsBnZh3GUrRVAxy7OB4cZD+7cJ+f+b7G7vy0rvjYbYoiMrJ5YszTP3"
    "woIZp5b3ONZbTjHUaMqw7+3Dfvv+8XJFVMtDy7y5lIc1BlGKLvPNU5qnTCOEXksovAuGAgtE30ynvD6pZvnw5vi05vx3"
    "6dhLltIPUEsDBBQAAAAIANK2KV2GphA2BwAAAAUAAAAOAAAAZGF0YS9ub3Rlcy50eHTLSM3JyQcAUEsBAhQAFAAAAAgA"
    "0rYpXXZPDEXvAAAAZwEAAA0AAAAAAAAAAAAAAIABAAAAAG1hbmlmZXN0Lmpzb25QSwECFAAUAAAACADStildhqYQNgcA"
    "AAAFAAAADgAAAAAAAAAAAAAAgAEaAQAAZGF0YS9ub3Rlcy50eHRQSwUGAAAAAAIAAgB3AAAATQEAAAAA";

// {"name": "From Filename"} — no id -> id comes from the filename.
const char* const kNO_ID_ZIP =
    "UEsDBBQAAAAIANK2KV1LH9kmGAAAABkAAAANAAAAbWFuaWZlc3QuanNvbqtWykvMTVWyUlByK8rPVXDLzEkFC9QCAFBL"
    "AQIUABQAAAAIANK2KV1LH9kmGAAAABkAAAANAAAAAAAAAAAAAACAAQAAAABtYW5pZmVzdC5qc29uUEsFBgAAAAABAAEA"
    "OwAAAEMAAAAAAA==";

// {"ui":{"panels":[{"panel_id":"p9"}]}} — name/version/author/description must
// be backfilled into manifest.json on disk.
const char* const kBACKFILL_ZIP =
    "UEsDBBQAAAAIANK2KV0SvGN4IQAAACUAAAANAAAAbWFuaWZlc3QuanNvbqtWKs1UsqpWKkjMS80pVrKKhjLjM1OUrJQKLJ"
    "VqY2trAVBLAQIUABQAAAAIANK2KV0SvGN4IQAAACUAAAANAAAAAAAAAAAAAACAAQAAAABtYW5pZmVzdC5qc29uUEsFBgAA"
    "AAABAAEAOwAAAEwAAAAAAA==";

const char* const kDOTDOT_ZIP =
    "UEsDBBQAAAAIANK2KV26S7AVDwAAAA0AAAANAAAAbWFuaWZlc3QuanNvbqtWykxRslJKLcvMUaoFAFBLAwQUAAAACADSt"
    "ildgxbcjAMAAAABAAAACwAAAC4uL2V2aWwudHh0qwAAUEsBAhQAFAAAAAgA0rYpXbpLsBUPAAAADQAAAA0AAAAAAAAAAA"
    "AAAIABAAAAAG1hbmlmZXN0Lmpzb25QSwECFAAUAAAACADStildgxbcjAMAAAABAAAACwAAAAAAAAAAAAAAgAE6AAAALi4v"
    "ZXZpbC50eHRQSwUGAAAAAAIAAgB0AAAAZgAAAAAA";

const char* const kABS_ZIP =
    "UEsDBBQAAAAIANK2KV26S7AVDwAAAA0AAAANAAAAbWFuaWZlc3QuanNvbqtWykxRslJKLcvMUaoFAFBLAwQUAAAACADSt"
    "ildgxbcjAMAAAABAAAACwAAAC9ldGMvcGFzc3dkqwAAUEsBAhQAFAAAAAgA0rYpXbpLsBUPAAAADQAAAA0AAAAAAAAAAA"
    "AAAIABAAAAAG1hbmlmZXN0Lmpzb25QSwECFAAUAAAACADStildgxbcjAMAAAABAAAACwAAAAAAAAAAAAAAgAE6AAAAL2V0"
    "Yy9wYXNzd2RQSwUGAAAAAAIAAgB0AAAAZgAAAAAA";

const char* const kDRIVE_ZIP =
    "UEsDBBQAAAAIANK2KV26S7AVDwAAAA0AAAANAAAAbWFuaWZlc3QuanNvbqtWykxRslJKLcvMUaoFAFBLAwQUAAAACADSt"
    "ildgxbcjAMAAAABAAAADAAAAEM6L3dpbmRvd3MveKsAAFBLAQIUABQAAAAIANK2KV26S7AVDwAAAA0AAAANAAAAAAAAAA"
    "AAAAAgAQAAAABtYW5pZmVzdC5qc29uUEsBAhQAFAAAAAgA0rYpXYMW3IwDAAAAAQAAAAwAAAAAAAAAAAAAAIABOgAAAEM6"
    "L3dpbmRvd3MveFBLBQYAAAAAAgACAHUAAABnAAAAAAA=";

const char* const kRESERVED_ZIP =
    "UEsDBBQAAAAIANK2KV2ytW6NDQAAAAsAAAANAAAAbWFuaWZlc3QuanNvbqtWykxRslIqzVSqBQBQSwECFAAUAAAACADSt"
    "ildsrVujQ0AAAALAAAADQAAAAAAAAAAAAAAgAEAAAAAbWFuaWZlc3QuanNvblBLBQYAAAAAAQABADsAAAA4AAAAAAA=";

const char* const kBAD_ID_ZIP =
    "UEsDBBQAAAAIANK2KV2+Yv7DEQAAAA8AAAANAAAAbWFuaWZlc3QuanNvbqtWykxRslJySkyJ90xRqgUAUEsBAhQAFAAA"
    "AAgA0rYpXb5i/sMRAAAADwAAAA0AAAAAAAAAAAAAAIABAAAAAG1hbmlmZXN0Lmpzb25QSwUGAAAAAAEAAQA7AAAAPAAAA"
    "AAA";

const char* const kNO_MANIFEST_ZIP =
    "UEsDBBQAAAAIANK2KV2sKpPYBAAAAAIAAAAKAAAAcmVhZG1lLnR4dMvIBABQSwECFAAUAAAACADStildrCqT2AQAAAAC"
    "AAAACgAAAAAAAAAAAAAAgAEAAAAAcmVhZG1lLnR4dFBLBQYAAAAAAQABADgAAAAsAAAAAAA=";

const char* const kALPHA_MANIFEST = R"JSON({
  "id": "alpha",
  "name": "阿尔法",
  "version": "1.2.3",
  "author": "tester",
  "description": "alpha desc",
  "ui": {
    "flow_cards": [
      {"type_id": "alpha_card", "name": "阿尔法卡", "icon": "star", "color": "#ff0000",
       "applies_to": "talk", "match": {"field": "kind", "equals": "special"},
       "body_fields": ["content"], "hidden_ports": ["checkFail"], "description": "d"},
      {"type_id": "sparse"},
      "not-an-object"
    ],
    "panels": [
      {"panel_id": "pn_a", "title": "面板A", "icon": "star", "description": "", "extra": {"k": 7}},
      42
    ]
  },
  "service": {"url": "http://127.0.0.1:39211", "name": "svc"},
  "unknown_future_key": {"a": 1}
})JSON";

}  // namespace

// ---------------------------------------------------------------------------
// bare root (the golden red line)
// ---------------------------------------------------------------------------

TEST_CASE("plugins bare root: every collection is empty, detail is the golden 404",
          "[plugins]") {
    ScopedEnv env("EDITOR_PLUGINS_ROOT", fresh_root("bare"));
    PluginsFixture fx;

    auto list = fx.call("GET", "/api/plugins");
    REQUIRE(list.status == 200);
    CHECK(list.json_payload == sa::json{{"plugins", sa::json::array()}});

    auto ui = fx.call("GET", "/api/plugins/ui");
    REQUIRE(ui.status == 200);
    CHECK(ui.json_payload == sa::json{{"panels", sa::json::array()}});

    auto fc = fx.call("GET", "/api/plugins/ui/flow_cards");
    REQUIRE(fc.status == 200);
    CHECK(fc.json_payload == sa::json{{"flow_cards", sa::json::array()}});

    auto tools = fx.call("GET", "/api/plugins/agent/tools");
    REQUIRE(tools.status == 200);
    CHECK(tools.json_payload == sa::json{{"tools", sa::json::array()}});

    auto info = fx.call("GET", "/api/plugins/anything");
    CHECK(info.status == 404);
    CHECK(info.json_payload == sa::json{{"error", "plugin not found"}});

    auto reload = fx.call("POST", "/api/plugins/reload");
    REQUIRE(reload.status == 200);
    CHECK(reload.json_payload == sa::json{{"ok", true}, {"plugins", sa::json::array()}});

    // §5/§4 deprecated surface: not registered -> the transport's no-route 404.
    auto exec = fx.call("POST", "/api/plugins/agent/exec", {}, sa::json{{"name", "x"}});
    CHECK(exec.status == 404);
    auto proxy = fx.call("GET", "/api/plugins/alpha/panel/pn_a");
    CHECK(proxy.status == 404);
    // install_path with no body is still the registered route (400, not 404).
    CHECK(fx.call("POST", "/api/plugins/install_path").status == 400);
}

TEST_CASE("plugins routes register standalone onto an empty router", "[plugins]") {
    ScopedEnv env("EDITOR_PLUGINS_ROOT", fresh_root("standalone"));
    sa::Router r;
    sa::register_plugins_routes(r);
    auto resp = sat::call_router(r, "GET", "/api/plugins");
    REQUIRE(resp.status == 200);
    CHECK(resp.json_payload["plugins"].empty());
    CHECK(sat::call_router(r, "POST", "/api/plugins/whatever/disable").status == 410);
}

// ---------------------------------------------------------------------------
// declarative manifests
// ---------------------------------------------------------------------------

TEST_CASE("plugins from manifests: entries, panels, flow_cards, broken ignored", "[plugins]") {
    const std::string root = fresh_root("declarative");
    ScopedEnv env("EDITOR_PLUGINS_ROOT", root);
    make_plugin(root, "alpha", kALPHA_MANIFEST);
    make_plugin(root, "beta", R"({"description": "only desc"})");
    make_plugin(root, "gamma", "{[bad");                 // unparsable -> ignored
    make_plugin(root, "delta", R"("a json string")");   // not an object -> ignored
    cs::create_dirs(cs::join(root, "epsilon"));           // no manifest.json -> ignored
    cs::write_bytes_simple(cs::join(root, "stray.json"), "{}");  // not a dir -> ignored
    make_plugin(root, "__pycache__", R"({"name":"cached"})");    // excluded like Python

    PluginsFixture fx;
    auto list = fx.call("GET", "/api/plugins");
    REQUIRE(list.status == 200);
    const auto& plugins = list.json_payload["plugins"];
    REQUIRE(plugins.size() == 2);
    CHECK(plugins[0]["id"] == "alpha");
    CHECK(plugins[1]["id"] == "beta");
    // _entry_for key set AND order (ordered_json keeps Python's dict order).
    // §4: a manifest that declares "service" also carries service_status (the
    // refresh verdict; checked=false here because nothing has refreshed yet).
    CHECK(keys_of(plugins[0]) ==
          std::vector<std::string>{"id",       "name",     "version",     "author",
                                   "description", "entry", "enabled",     "loaded",
                                   "error",    "risk_ack_at", "ui",       "service",
                                   "service_status"});
    CHECK(plugins[0]["service_status"] ==
          sa::json{{"ok", false}, {"url", "http://127.0.0.1:39211"}, {"name", "svc"},
                   {"checked", false}});
    CHECK(plugins[0]["name"] == "阿尔法");
    CHECK(plugins[0]["version"] == "1.2.3");
    CHECK(plugins[0]["author"] == "tester");
    CHECK(plugins[0]["description"] == "alpha desc");
    CHECK(plugins[0]["entry"] == "plugin.py");  // manifest has no entry key -> default
    CHECK(plugins[0]["enabled"] == true);       // declarative: always on, always loaded
    CHECK(plugins[0]["loaded"] == true);
    CHECK(plugins[0]["error"] == "");
    CHECK(plugins[0]["risk_ack_at"] == "");
    // §2 manifest passthroughs.
    CHECK(plugins[0]["ui"]["panels"].size() == 2);
    CHECK(plugins[0]["service"]["url"] == "http://127.0.0.1:39211");
    CHECK_FALSE(plugins[0].contains("unknown_future_key"));  // not a §2 passthrough
    // beta: name defaults to the directory name, no ui/service declared -> absent.
    CHECK(keys_of(plugins[1]) ==
          std::vector<std::string>{"id", "name", "version", "author", "description", "entry",
                                   "enabled", "loaded", "error", "risk_ack_at"});
    CHECK(plugins[1]["name"] == "beta");
    CHECK(plugins[1]["version"] == "");
    CHECK(plugins[1]["description"] == "only desc");

    // ---- GET /api/plugins/ui: ui.panels passed through with plugin_id injected
    auto ui = fx.call("GET", "/api/plugins/ui");
    REQUIRE(ui.status == 200);
    const auto& panels = ui.json_payload["panels"];
    REQUIRE(panels.size() == 1);  // the non-object element (42) is skipped
    CHECK(panels[0]["panel_id"] == "pn_a");
    CHECK(panels[0]["title"] == "面板A");
    CHECK(panels[0]["extra"]["k"] == 7);  // 原样透传：unknown keys survive
    CHECK(panels[0]["plugin_id"] == "alpha");

    // ---- flow_cards: wire format unchanged from the wave-2 reader
    auto fc = fx.call("GET", "/api/plugins/ui/flow_cards");
    REQUIRE(fc.status == 200);
    const auto& cards = fc.json_payload["flow_cards"];
    REQUIRE(cards.size() == 2);  // "not-an-object" skipped
    CHECK(keys_of(cards[0]) == std::vector<std::string>{"type_id",     "name",    "icon",
                                                        "color",       "applies_to", "match",
                                                        "body_fields", "hidden_ports", "description",
                                                        "plugin_id"});
    CHECK(cards[0]["type_id"] == "alpha_card");
    CHECK(cards[0]["name"] == "阿尔法卡");
    CHECK(cards[0]["match"]["field"] == "kind");
    CHECK(cards[0]["plugin_id"] == "alpha");
    CHECK(cards[1]["type_id"] == "sparse");
    CHECK(cards[1]["icon"].is_null());  // absent whitelist fields render as null
    CHECK(cards[1]["hidden_ports"].is_null());
    CHECK(cards[1]["plugin_id"] == "alpha");

    // ---- detail endpoint
    auto info = fx.call("GET", "/api/plugins/alpha");
    REQUIRE(info.status == 200);
    CHECK(info.json_payload["id"] == "alpha");
    CHECK(info.json_payload["ui"]["flow_cards"].size() == 3);
    REQUIRE(info.json_payload.contains("contributions"));
    const auto& contrib = info.json_payload["contributions"];
    CHECK(keys_of(contrib) == std::vector<std::string>{"routes", "tools", "commands", "panels",
                                                       "flow_cards"});
    CHECK(contrib["routes"].empty());
    CHECK(contrib["flow_cards"].empty());
    // statics registered before /<pid>: these are NOT the 404 detail route
    CHECK(fx.call("GET", "/api/plugins/gamma").status == 404);
    CHECK(fx.call("GET", "/api/plugins/delta").status == 404);
    CHECK(fx.call("GET", "/api/plugins/epsilon").status == 404);
    CHECK(fx.call("GET", "/api/plugins/__pycache__").status == 404);
    // _safe_pid gate: no traversal, no drive, no separator
    CHECK(fx.call("GET", "/api/plugins/..").status == 404);
    CHECK(fx.call("GET", "/api/plugins/a:b").status == 404);
    CHECK(fx.call("GET", "/api/plugins/a\\b").status == 404);
    // reload sees the same set (re-scan, idempotent). §4: reload also re-fetches
    // the service self-descriptions — alpha declares a service on :39211 where
    // nothing listens in this suite, so its error/service_status now carry the
    // failed-fetch verdict; compare everything else.
    auto reload = fx.call("POST", "/api/plugins/reload");
    REQUIRE(reload.status == 200);
    REQUIRE(reload.json_payload["plugins"].size() == 2);
    const auto& refreshed = reload.json_payload["plugins"][0];
    CHECK(refreshed["error"] == "plugin service unavailable");
    CHECK(refreshed["service_status"]["checked"] == true);
    CHECK(refreshed["service_status"]["ok"] == false);
    auto strip_service = [](sa::json e) {
        e.erase("error");
        e.erase("service_status");
        return e;
    };
    CHECK(strip_service(refreshed) == strip_service(plugins[0]));
    CHECK(reload.json_payload["plugins"][1] == plugins[1]);  // no service -> untouched
}

TEST_CASE("plugins panel content route serves declared panels, 404 otherwise", "[plugins]") {
    const std::string root = fresh_root("panelcontent");
    ScopedEnv env("EDITOR_PLUGINS_ROOT", root);
    make_plugin(root, "pdemo", R"JSON({
      "ui": {"panels": [
        {"panel_id": "main", "title": "主面板", "icon": "star",
         "description": "一段面板说明"},
        {"panel_id": "bare", "title": "无说明"}
      ]}
    })JSON");
    PluginsFixture fx;

    // Declared panel with a description -> markdown block.
    auto r = fx.call("GET", "/api/plugins/pdemo/panel/main");
    REQUIRE(r.status == 200);
    CHECK(r.json_payload["title"] == "主面板");
    REQUIRE(r.json_payload["blocks"].size() == 1);
    CHECK(r.json_payload["blocks"][0]["type"] == "markdown");
    CHECK(r.json_payload["blocks"][0]["text"] == "一段面板说明");

    // Declared panel without description -> no blocks (still 200).
    auto bare = fx.call("GET", "/api/plugins/pdemo/panel/bare");
    REQUIRE(bare.status == 200);
    CHECK(bare.json_payload["title"] == "无说明");
    CHECK(bare.json_payload["blocks"].empty());

    // Unknown panel id / unknown plugin / traversal -> 404, never a filesystem hit.
    CHECK(fx.call("GET", "/api/plugins/pdemo/panel/nope").status == 404);
    CHECK(fx.call("GET", "/api/plugins/ghost/panel/main").status == 404);
    CHECK(fx.call("GET", "/api/plugins/..%2F..%2Fetc/panel/x").status == 404);
}

TEST_CASE("plugins top-level flow_cards alias still aggregates", "[plugins]") {
    const std::string root = fresh_root("toplevel");
    ScopedEnv env("EDITOR_PLUGINS_ROOT", root);
    make_plugin(root, "legacy", R"({"flow_cards": [{"type_id": "t", "name": "n"}]})");
    PluginsFixture fx;
    auto fc = fx.call("GET", "/api/plugins/ui/flow_cards");
    REQUIRE(fc.status == 200);
    REQUIRE(fc.json_payload["flow_cards"].size() == 1);
    CHECK(fc.json_payload["flow_cards"][0]["type_id"] == "t");
    CHECK(fc.json_payload["flow_cards"][0]["plugin_id"] == "legacy");
}

TEST_CASE("plugins lifecycle routes are retired with an explicit 410", "[plugins]") {
    const std::string root = fresh_root("lifecycle");
    ScopedEnv env("EDITOR_PLUGINS_ROOT", root);
    make_plugin(root, "alpha", kALPHA_MANIFEST);
    PluginsFixture fx;

    for (const char* verb : {"enable", "disable"}) {
        const std::string path = std::string("/api/plugins/alpha/") + verb;
        auto r = fx.call("POST", path, {}, sa::json{{"risk_ack", true}});
        INFO(path);
        CHECK(r.status == 410);
        CHECK(r.json_payload == sa::json{{"error", "声明型插件常开无启用态，enable/disable 已废弃"}});
    }
    // retired regardless of whether the plugin exists (state itself is gone)
    CHECK(fx.call("POST", "/api/plugins/ghost/disable").status == 410);
    // and it did not write any state: alpha is still listed as enabled
    auto list = fx.call("GET", "/api/plugins");
    REQUIRE(list.json_payload["plugins"].size() == 1);
    CHECK(list.json_payload["plugins"][0]["enabled"] == true);
    CHECK(list.json_payload["plugins"][0]["risk_ack_at"] == "");
}

// ---------------------------------------------------------------------------
// install
// ---------------------------------------------------------------------------

TEST_CASE("plugins install: declarative zip lands, manifest backfilled, no entry file needed",
          "[plugins]") {
    const std::string root = fresh_root("install");
    ScopedEnv env("EDITOR_PLUGINS_ROOT", root);
    PluginsFixture fx;

    auto inst = fx.call("POST", "/api/plugins/install", {},
                        sa::json{{"data", kPLUGIN_ZIP}, {"filename", "ignored.zip"}});
    INFO(inst.json_payload.dump());
    REQUIRE(inst.status == 200);
    CHECK(keys_of(inst.json_payload) ==
          std::vector<std::string>{"ok", "id", "plugin"});  // api.py:3034 shape
    CHECK(inst.json_payload["ok"] == true);
    CHECK(inst.json_payload["id"] == "installed_demo");      // manifest id wins over filename
    const auto& entry = inst.json_payload["plugin"];
    CHECK(entry["name"] == "安装演示");
    CHECK(entry["version"] == "2.1.0");
    CHECK(entry["enabled"] == true);  // §5: installed == usable, no enable step
    CHECK(entry["service"]["url"] == "http://127.0.0.1:39211");

    const std::string dir = cs::join(root, "installed_demo");
    CHECK(cs::is_file(cs::join(dir, "data/notes.txt")));  // nested member extracted
    // No plugin.py in the archive and no entry-file probe (the retired engine
    // required one; declarative plugins carry no code at all).
    CHECK_FALSE(cs::is_file(cs::join(dir, "plugin.py")));
    // manifest.json was rewritten with the §2 defaults + id.
    auto disk = cs::read_bytes(cs::join(dir, "manifest.json"));
    REQUIRE(disk.has_value());
    const std::string text = *disk;
    CHECK(sa_core::str::starts_with(text, "{\n  \"id\": \"installed_demo\",\n"));
    CHECK(text.find("\"version\": \"2.1.0\"") != std::string::npos);
    CHECK(text.find("\"plugin.py\"") == std::string::npos);
    // py_dumps_indent (ensure_ascii=False, indent=2): the Chinese name is raw UTF-8.
    CHECK(text.find("安装演示") != std::string::npos);
    // plugins.json registry is gone with the engine: nothing but the plugin dir.
    CHECK_FALSE(cs::is_file(cs::join(root, "plugins.json")));

    // installed == listed == detail == flow_cards/panels aggregated
    auto list = fx.call("GET", "/api/plugins");
    REQUIRE(list.json_payload["plugins"].size() == 1);
    CHECK(list.json_payload["plugins"][0]["id"] == "installed_demo");
    CHECK(fx.call("GET", "/api/plugins/installed_demo").status == 200);
    auto fc = fx.call("GET", "/api/plugins/ui/flow_cards");
    REQUIRE(fc.json_payload["flow_cards"].size() == 1);
    CHECK(fc.json_payload["flow_cards"][0]["plugin_id"] == "installed_demo");
    auto ui = fx.call("GET", "/api/plugins/ui");
    REQUIRE(ui.json_payload["panels"].size() == 1);
    CHECK(ui.json_payload["panels"][0]["panel_id"] == "pn1");

    // reinstall is refused by the directory-exists rule
    auto again = fx.call("POST", "/api/plugins/install", {}, sa::json{{"data", kPLUGIN_ZIP}});
    CHECK(again.status == 400);
    CHECK(again.json_payload["error"] == "plugin already exists: installed_demo");

    // ---- id legalization: no id in the manifest -> from the filename
    auto noid = fx.call("POST", "/api/plugins/install", {},
                        sa::json{{"data", kNO_ID_ZIP}, {"filename", "My Plugin.zip"}});
    REQUIRE(noid.status == 200);
    CHECK(noid.json_payload["id"] == "my_plugin");
    CHECK(noid.json_payload["plugin"]["name"] == "From Filename");
    // _install_zip backfills the manifest BEFORE synthesizing the entry, so the
    // install response reports the defaulted version (Python parity).
    CHECK(noid.json_payload["plugin"]["version"] == "1.0.0");
    CHECK(cs::is_dir(cs::join(root, "my_plugin")));

    // ---- manifest backfill defaults (name=pid, version 1.0.0)
    auto back = fx.call("POST", "/api/plugins/install", {},
                        sa::json{{"data", kBACKFILL_ZIP}, {"filename", "back fill@1.zip"}});
    REQUIRE(back.status == 200);
    CHECK(back.json_payload["id"] == "back_fill_1");  // non [a-z0-9_-] -> "_"
    auto binfo = fx.call("GET", "/api/plugins/back_fill_1");
    REQUIRE(binfo.status == 200);
    CHECK(binfo.json_payload["name"] == "back_fill_1");
    CHECK(binfo.json_payload["version"] == "1.0.0");
    auto bdisk = cs::read_bytes(cs::join(cs::join(root, "back_fill_1"), "manifest.json"));
    REQUIRE(bdisk.has_value());
    CHECK(bdisk->find("\"author\": \"\"") != std::string::npos);
    CHECK(bdisk->find("\"description\": \"\"") != std::string::npos);
}

TEST_CASE("plugins install refusals mirror api.py:3014-3036 + _install_zip", "[plugins]") {
    const std::string root = fresh_root("install_refuse");
    ScopedEnv env("EDITOR_PLUGINS_ROOT", root);
    PluginsFixture fx;

    auto err = [](const sa::Resp& r) { return r.json_payload.value("error", std::string()); };

    // missing / empty data -> "zip data required" (checked before any decoding)
    auto nodata = fx.call("POST", "/api/plugins/install", {}, sa::json{{"filename", "a.zip"}});
    CHECK(nodata.status == 400);
    CHECK(err(nodata) == "zip data required");
    auto emptydata = fx.call("POST", "/api/plugins/install", {}, sa::json{{"data", ""}});
    CHECK(emptydata.status == 400);
    CHECK(err(emptydata) == "zip data required");

    // strict base64 (validate=True): whitespace and non-alphabet both rejected
    auto badb64 = fx.call("POST", "/api/plugins/install", {}, sa::json{{"data", "UE sB AAA="}});
    CHECK(badb64.status == 400);
    CHECK(err(badb64) == "invalid base64");
    auto junkb64 = fx.call("POST", "/api/plugins/install", {}, sa::json{{"data", "!!!"}});
    CHECK(junkb64.status == 400);
    CHECK(err(junkb64) == "invalid base64");

    // decode succeeds but the payload is too small to be a zip -> "empty zip"
    auto tiny = fx.call("POST", "/api/plugins/install", {},
                        sa::json{{"data", sa::p3b::b64_encode("ab")}});
    CHECK(tiny.status == 400);
    CHECK(err(tiny) == "empty zip");

    // non-zip bytes (>= 4) -> the BadZipFile analogue
    auto notzip = fx.call("POST", "/api/plugins/install", {},
                          sa::json{{"data", sa::p3b::b64_encode("1234567890abcd")}});
    CHECK(notzip.status == 400);
    CHECK(err(notzip) == "invalid zip: File is not a zip file");

    // ---- entry safety (the size gate below must NOT have to decompress first)
    for (const auto& kv : std::vector<std::pair<const char*, const char*>>{
             {"../", kDOTDOT_ZIP}, {"/abs", kABS_ZIP}, {"drive", kDRIVE_ZIP}}) {
        auto r = fx.call("POST", "/api/plugins/install", {}, sa::json{{"data", kv.second}});
        INFO(kv.first);
        CHECK(r.status == 400);
        CHECK(sa_core::str::starts_with(err(r), "illegal entry: '"));
    }

    auto nomanifest = fx.call("POST", "/api/plugins/install", {},
                              sa::json{{"data", kNO_MANIFEST_ZIP}});
    CHECK(nomanifest.status == 400);
    CHECK(err(nomanifest) == "zip missing manifest.json");

    auto reserved = fx.call("POST", "/api/plugins/install", {},
                            sa::json{{"data", kRESERVED_ZIP}});
    CHECK(reserved.status == 400);
    CHECK(err(reserved) == "reserved plugin id: ui");

    auto badid = fx.call("POST", "/api/plugins/install", {}, sa::json{{"data", kBAD_ID_ZIP}});
    CHECK(badid.status == 400);
    CHECK(err(badid) == "invalid plugin id: 'Bad_Id'");

    // >100MB decoded is refused BEFORE any zip parsing (api.py:3026-3027).
    // 139810136 chars == 104857602 bytes decoded, one byte past the cap.
    sa::json big;
    std::string huge(139810136, 'A');
    big["data"] = std::move(huge);
    auto oversized = fx.call("POST", "/api/plugins/install", {}, big);
    CHECK(oversized.status == 400);
    CHECK(err(oversized) == "zip too large (>100MB)");

    // nothing landed: every refusal above short-circuits before makedirs
    auto list = fx.call("GET", "/api/plugins");
    CHECK(list.json_payload["plugins"].empty());
    CHECK_FALSE(cs::is_dir(cs::join(root, "installed_demo")));
    CHECK_FALSE(cs::is_dir(cs::join(root, "evil")));
    bool any_dir = false;
    for (const auto& n : cs::listdir_sorted(root)) {
        if (cs::is_dir(cs::join(root, n))) any_dir = true;
    }
    CHECK_FALSE(any_dir);

    // An all-punctuation filename legalizes to a "p_"-prefixed id instead of
    // failing: "!!.zip" -> "!!" -> "__" -> "p___" (plugin_system._id_from_filename).
    auto badfilename = fx.call("POST", "/api/plugins/install", {},
                               sa::json{{"data", kNO_ID_ZIP}, {"filename", "!!.zip"}});
    CHECK(badfilename.status == 200);
    CHECK(badfilename.json_payload["id"] == "p___");
    CHECK(fx.call("GET", "/api/plugins").json_payload["plugins"].size() == 1);
}

TEST_CASE("plugins install_path mirrors api.py:3036-3049", "[plugins]") {
    const std::string root = fresh_root("install_path");
    ScopedEnv env("EDITOR_PLUGINS_ROOT", root);
    PluginsFixture fx;

    const std::string zp = cs::join(root, "drop here.zip");
    REQUIRE(cs::write_bytes_simple(zp, raw_of(kNO_ID_ZIP)));

    auto ok = fx.call("POST", "/api/plugins/install_path", {}, sa::json{{"path", zp}});
    INFO(ok.json_payload.dump());
    REQUIRE(ok.status == 200);
    // filename defaulted from the path basename (api.py:3042) -> "drop here" ->
    // "drop_here"; manifest has no id, so the filename wins.
    CHECK(ok.json_payload["id"] == "drop_here");
    CHECK(ok.json_payload["plugin"]["name"] == "From Filename");
    CHECK(fx.call("GET", "/api/plugins/drop_here").status == 200);

    auto explicit_name = fx.call("POST", "/api/plugins/install_path", {},
                                 sa::json{{"path", zp}, {"filename", "second.zip"}});
    INFO(explicit_name.json_payload.dump());
    REQUIRE(explicit_name.status == 200);
    // body filename wins over the path basename (api.py:3042) -> own directory
    CHECK(explicit_name.json_payload["id"] == "second");
    CHECK(cs::is_dir(cs::join(root, "second")));
    CHECK_FALSE(cs::is_dir(cs::join(root, "drop_here_1")));

    auto nopath = fx.call("POST", "/api/plugins/install_path", {}, sa::json{});
    CHECK(nopath.status == 400);
    CHECK(nopath.json_payload.value("error", std::string()) == "path required");

    const std::string missing = cs::join(root, "nope.zip");
    auto notfound = fx.call("POST", "/api/plugins/install_path", {}, sa::json{{"path", missing}});
    CHECK(notfound.status == 400);
    CHECK(notfound.json_payload.value("error", std::string()) == "file not found: " + missing);

    const std::string empty = cs::join(root, "empty.zip");
    REQUIRE(cs::write_bytes_simple(empty, ""));
    auto zero = fx.call("POST", "/api/plugins/install_path", {}, sa::json{{"path", empty}});
    CHECK(zero.status == 400);
    CHECK(zero.json_payload.value("error", std::string()) == "empty file");
}

// ---------------------------------------------------------------------------
// uninstall
// ---------------------------------------------------------------------------

TEST_CASE("plugins delete removes the directory; unknown ids mirror uninstall_plugin",
          "[plugins]") {
    const std::string root = fresh_root("delete");
    ScopedEnv env("EDITOR_PLUGINS_ROOT", root);
    PluginsFixture fx;

    auto inst = fx.call("POST", "/api/plugins/install", {}, sa::json{{"data", kPLUGIN_ZIP}});
    REQUIRE(inst.status == 200);
    CHECK(cs::is_dir(cs::join(root, "installed_demo")));

    auto del = fx.call("DELETE", "/api/plugins/installed_demo");
    REQUIRE(del.status == 200);
    CHECK(del.json_payload == sa::json{{"ok", true}});
    CHECK_FALSE(cs::is_dir(cs::join(root, "installed_demo")));
    auto list = fx.call("GET", "/api/plugins");
    CHECK(list.json_payload["plugins"].empty());
    CHECK(fx.call("GET", "/api/plugins/installed_demo").status == 404);

    auto again = fx.call("DELETE", "/api/plugins/installed_demo");
    CHECK(again.status == 400);
    CHECK(again.json_payload.value("error", std::string()) == "plugin not found: installed_demo");

    auto ghost = fx.call("DELETE", "/api/plugins/ghost");
    CHECK(ghost.status == 400);
    CHECK(ghost.json_payload.value("error", std::string()) == "plugin not found: ghost");

    auto unsafe = fx.call("DELETE", "/api/plugins/..");
    CHECK(unsafe.status == 400);
    CHECK(unsafe.json_payload.value("error", std::string()) == "invalid plugin id");
    CHECK(cs::is_dir(root));  // the traversal attempt was refused, not resolved
    CHECK(fx.call("DELETE", "/api/plugins/a\\b").json_payload.value("error", std::string()) ==
          "invalid plugin id");
    CHECK(fx.call("DELETE", "/api/plugins/a:b").json_payload.value("error", std::string()) ==
          "invalid plugin id");
}
