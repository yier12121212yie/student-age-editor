// tests/test_p5_cloud.cpp — [p5] suite for the cloud-sync domain.
//
// Truth sources: backend/editor/server/cloud_sync.py (+ test_cloud_sync.py
// case intents) and api.py:2714-3002 route envelopes. WebDAV / OpenList run
// against the header-only p5mock (httplib) local server; everything else is
// plain temp-dir IO. All test names ASCII (Git Bash argv filter safety).
#include <catch_amalgamated.hpp>

#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <map>
#include <memory>
#include <mutex>
#include <regex>
#include <set>
#include <string>
#include <vector>

#include "test_support.h"
#include "sa_core/http_client.h"
#include "sa_core/paths.h"
#include "server/state.h"

#include "cloud_routes.h"
#include "cloud_sync.h"
#include "p5_mock.h"
#include "p5_util.h"

namespace fs = std::filesystem;
using sa::cloud::json;
using namespace std::string_literals;

namespace {

// ---------------------------------------------------------------------------
// Fixture: temp workspace + temp data root; STATE + env redirected so nothing
// ever touches the real backend/ tree or the user's Mods dir.
// ---------------------------------------------------------------------------
class CloudFixture {
  public:
    explicit CloudFixture(const std::string& tag)
        : root_(sat::make_temp_dir(tag)), ws_(root_ / "ws"), data_(root_ / "data"),
          remote_(root_ / "remote") {
        fs::create_directories(ws_);
        fs::create_directories(data_);
        fs::create_directories(remote_);
        auto& st = sa::STATE();
        {
            std::lock_guard<std::mutex> lk(st.mu_);
            saved_ws_ = st.workspace_root;
            saved_mod_root_ = st.mod_root;
            saved_mod_name_ = st.mod_name;
            st.workspace_root = sa_core::paths::path_to_utf8(ws_);
            st.mod_root.clear();
            st.mod_name.clear();
            st.mods_cache_valid = false;
        }
        saved_data_root_ = env_get("EDITOR_DATA_ROOT");
        saved_no_steam_ = env_get("EDITOR_DISABLE_STEAM_DETECT");
        _putenv_s("EDITOR_DATA_ROOT", sa_core::paths::path_to_utf8(data_).c_str());
        _putenv_s("EDITOR_DISABLE_STEAM_DETECT", "1");
    }
    ~CloudFixture() {
        auto& st = sa::STATE();
        {
            std::lock_guard<std::mutex> lk(st.mu_);
            st.workspace_root = saved_ws_;
            st.mod_root = saved_mod_root_;
            st.mod_name = saved_mod_name_;
            st.mods_cache_valid = false;
        }
        _putenv_s("EDITOR_DATA_ROOT", saved_data_root_.c_str());
        _putenv_s("EDITOR_DISABLE_STEAM_DETECT", saved_no_steam_.c_str());
        std::error_code ec;
        fs::remove_all(root_, ec);
    }
    CloudFixture(const CloudFixture&) = delete;
    CloudFixture& operator=(const CloudFixture&) = delete;

    static std::string env_get(const char* k) {
        const char* v = std::getenv(k);
        return v ? std::string(v) : std::string();
    }
    void set_workspace(const std::string& ws) {
        std::lock_guard<std::mutex> lk(sa::STATE().mu_);
        sa::STATE().workspace_root = ws;
        sa::STATE().mods_cache_valid = false;
    }
    std::string ws() const { return sa_core::paths::path_to_utf8(ws_); }
    std::string data() const { return sa_core::paths::path_to_utf8(data_); }
    std::string remote() const { return sa_core::paths::path_to_utf8(remote_); }
    const fs::path& root() const { return root_; }
    const fs::path& ws_p() const { return ws_; }
    const fs::path& remote_p() const { return remote_; }

  private:
    fs::path root_, ws_, data_, remote_;
    std::string saved_ws_, saved_mod_root_, saved_mod_name_, saved_data_root_, saved_no_steam_;
};

std::string P(const fs::path& p) { return sa_core::paths::path_to_utf8(p); }

void wfile(const fs::path& p, const std::string& content) {
    fs::create_directories(p.parent_path());
    std::ofstream f(p, std::ios::binary);
    f.write(content.data(), static_cast<std::streamsize>(content.size()));
}

std::string rfile(const fs::path& p) {
    std::ifstream f(p, std::ios::binary);
    std::string s((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
    return s;
}

std::vector<std::string> keys_of(const json& j) {
    std::vector<std::string> out;
    for (auto it = j.begin(); it != j.end(); ++it) out.push_back(it.key());
    return out;
}

// Make <ws>/<name> a discoverable mod (Cfgs/zh-cn marker dir) and optionally
// seed files (rel -> content, rel like "Cfgs/zh-cn/a.json").
fs::path make_mod(const CloudFixture& fx, const std::string& name,
                  const std::map<std::string, std::string>& files = {}) {
    fs::path mod_dir = fx.root() / "ws" / name;
    fs::create_directories(mod_dir / "Cfgs" / "zh-cn");
    for (const auto& [rel, content] : files) wfile(mod_dir / rel, content);
    std::lock_guard<std::mutex> lk(sa::STATE().mu_);
    sa::STATE().mods_cache_valid = false;
    return mod_dir;
}

// Add a provider entry straight through the CRUD API (writes
// <ws>/.editor_cloud.json).
std::string add_local_provider(const std::string& id, const std::string& root_dir,
                               const std::string& remote_root = "") {
    json info;
    info["id"] = id;
    info["type"] = "local";
    info["name"] = id;
    json cfg;
    cfg["root"] = root_dir;
    info["config"] = cfg;
    if (!remote_root.empty()) info["remote_root"] = remote_root;
    return sa::cloud::add_provider(info)["id"].get<std::string>();
}

// ===========================================================================
// WebDAV mock state
// ===========================================================================
struct DavState {
    std::mutex mu;
    std::set<std::string> dirs;                  // decoded paths, no trailing slash
    std::map<std::string, std::string> files;    // decoded path -> content
    std::vector<p5mock::Call> log;               // method/target pairs of interest
};

std::string dav_xml_escape(const std::string& s) { return s; }  // test data is ASCII

std::string propfind_block(const std::string& href, bool is_dir, long long size,
                           const std::string& lm) {
    std::string s = "<D:response><D:href>" + href + "</D:href><D:propstat><D:prop>";
    if (is_dir) {
        s += "<D:resourcetype><D:collection xmlns:D=\"DAV:\"/></D:resourcetype>";
    } else {
        s += "<D:resourcetype/>";
        s += "<D:getcontentlength>" + std::to_string(size) + "</D:getcontentlength>";
    }
    if (!lm.empty()) s += "<D:getlastmodified>" + lm + "</D:getlastmodified>";
    s += "</D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>";
    return s;
}

// ===========================================================================
// OpenList mock
// ===========================================================================
struct OlState {
    std::mutex mu;
    std::map<std::string, std::string> files;  // logical path "/mods/a.json" -> content
    p5mock::Call last_list;
    p5mock::Call last_get;
    p5mock::Call last_put;
    p5mock::Call last_remove;
    p5mock::Call last_mkdir;
};

constexpr long long kEpoch2026Sep01_0830 = 1788251400LL;  // 2026-09-01T08:30:00Z

}  // namespace

// ---------------------------------------------------------------------------
// Pure helpers
// ---------------------------------------------------------------------------

TEST_CASE("P5 norm_remote: backslash/space trim, slash collapse, dotdot reject", "[p5][cloud][units]") {
    using sa::cloud::norm_remote;
    CHECK(norm_remote("") == "");
    CHECK(norm_remote("   ") == "");
    CHECK(norm_remote("/mods//demo/") == "mods/demo/");  // lstrip only
    CHECK(norm_remote("\\mods\\demo\\a.json") == "mods/demo/a.json");
    CHECK(norm_remote("a/./b") == "a/./b");  // "." segments are NOT special
    auto dotdot = [](const char* p) {
        try {
            norm_remote(p);
            return std::string("");
        } catch (const sa::cloud::PyError& e) {
            return std::string(e.what());
        }
    };
    CHECK(dotdot("a/../b") == "ValueError: invalid remote path: a/../b");
    CHECK(dotdot("..") == "ValueError: invalid remote path: ..");
    CHECK(dotdot("a\\..\\b") == "ValueError: invalid remote path: a/../b");
}

TEST_CASE("P5 parse_http_date / parse_iso_time anchors", "[p5][cloud][units]") {
    using sa::cloud::parse_http_date;
    CHECK(parse_http_date("") == 0);
    CHECK(parse_http_date("not a date") == 0);
    CHECK(parse_http_date("Tue, 01 Sep 2026 08:30:00 GMT") == kEpoch2026Sep01_0830);
    CHECK(parse_http_date("2026-09-01T08:30:00Z") == kEpoch2026Sep01_0830);
    // numeric offset honoured
    CHECK(parse_http_date("Tue, 01 Sep 2026 16:30:00 +0800") == kEpoch2026Sep01_0830);

    using sa::cloud::parse_iso_time;
    CHECK(parse_iso_time("2026-09-01T08:30:00Z") == std::optional<long long>(kEpoch2026Sep01_0830));
    CHECK(parse_iso_time("2026-09-01T10:30:00+02:00") ==
          std::optional<long long>(kEpoch2026Sep01_0830));
    CHECK(parse_iso_time("2026-09-01T08:30:00.25Z") ==
          std::optional<long long>(kEpoch2026Sep01_0830));  // fraction truncated
    CHECK_FALSE(parse_iso_time("not-a-date").has_value());
    CHECK_FALSE(parse_iso_time("2026-09-01T08:30:00XX").has_value());
}

TEST_CASE("P5 p5_util helpers (iso stamp, py_truthy, repr, type names)", "[p5][cloud][units]") {
    CHECK(std::regex_match(sa::p5::iso_now_local(),
                           std::regex(R"(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})")));
    using sa::p5::py_truthy;
    CHECK_FALSE(py_truthy(json()));
    CHECK_FALSE(py_truthy(json(false)));
    CHECK_FALSE(py_truthy(json(0)));
    CHECK_FALSE(py_truthy(json("")));
    CHECK_FALSE(py_truthy(json::array()));
    CHECK_FALSE(py_truthy(json::object()));
    CHECK(py_truthy(json("0")));      // Python bool("0") is True
    CHECK(py_truthy(json(1)));
    CHECK(sa::p5::py_list_repr(json::array({"a.json", "b.json"})) == "['a.json', 'b.json']");
    CHECK(sa::p5::py_list_repr(json::array()) == "[]");
    CHECK(std::string(sa::p5::py_type_name(json())) == "NoneType");
    CHECK(std::string(sa::p5::py_type_name(json(1))) == "int");
    CHECK(std::string(sa::p5::py_type_name(json(1.5))) == "float");
    CHECK(std::string(sa::p5::py_type_name(json(true))) == "bool");
    CHECK(sa::p5::str_or_throw(json("x"), "lower") == "x");
    CHECK(sa::p5::str_or_throw(json(), "lower") == "");
    bool threw = false;
    try {
        sa::p5::str_or_throw(json(7), "lower");
    } catch (const sa::ApiError& e) {
        threw = true;
        CHECK(std::string(e.what()) == "AttributeError: 'int' object has no attribute 'lower'");
    }
    CHECK(threw);
}

TEST_CASE("P5 safe_rel_join traversal rules (test_cloud_sync.py parity)", "[p5][cloud][units]") {
    using sa::cloud::safe_rel_join;
    std::string mod_dir = "C:/tmp/sa_p5/mod";
    auto full = safe_rel_join(mod_dir, "Cfgs/zh-cn/TalkCfg.json");
    REQUIRE(full.has_value());
    CHECK(full->find("Cfgs") != std::string::npos);
    for (const char* bad : {"../evil.json", "../../evil.json", "a/../../evil.json",
                            "..\\evil.json", "Cfgs/../../outside.json", "C:/Windows/evil.json",
                            "", "."}) {
        CHECK_FALSE(safe_rel_join(mod_dir, bad).has_value());
    }
    // "/Cfgs/a.json" is stripped-then-contained (Python behavior, not rejected)
    auto rooted = safe_rel_join(mod_dir, "/Cfgs/a.json");
    REQUIRE(rooted.has_value());
    auto dots = safe_rel_join(mod_dir, "./Cfgs//zh-cn/./TalkCfg.json");
    REQUIRE(dots.has_value());
}

TEST_CASE("P5 need_sync decision table (sha1+mtime, lazy sha)", "[p5][cloud][units]") {
    using sa::cloud::need_sync;
    CHECK(need_sync(10, 100, "", 11, 100, ""));           // size differs -> sync
    CHECK(need_sync(10, 100, "aa", 10, 100, "bb"));       // both sha -> differ
    CHECK_FALSE(need_sync(10, 100, "aa", 10, 100, "aa")); // both sha -> equal
    CHECK(need_sync(10, 100, "", 10, 200, ""));           // mtime delta > 2
    CHECK_FALSE(need_sync(10, 100, "", 10, 102, ""));     // delta == 2 -> unchanged
    CHECK_FALSE(need_sync(10, 0, "", 10, 500, ""));       // lm 0 -> mtime guard off
    CHECK_FALSE(need_sync(10, 500, "", 10, 0, ""));       // rm 0 likewise
    // rsha only + local file present: lazy sha decides
    CloudFixture fx("needsync");
    fs::path f = fx.root() / "lf.json";
    wfile(f, "hello");
    std::string sha_local = sa::cloud::sha1_file(P(f));
    CHECK(sha_local == "aaf4c61ddcc5e8a2dabede0f3b482cd9aea9434d");
    CHECK_FALSE(need_sync(5, 100, "", 5, 100, sha_local, P(f)));      // same content
    CHECK(need_sync(5, 100, "", 5, 100, "0000", P(f)));  // lazy sha differs
    CHECK_FALSE(need_sync(5, 100, "", 5, 100, "0000", ""));  // no local_path: equal size+mtime
}

TEST_CASE("P5 remote_path_for builds <root>/<mod>/<rel>", "[p5][cloud][units]") {
    using sa::cloud::remote_path_for;
    json prov;
    CHECK(remote_path_for(prov, "demo", "Cfgs/a.json") == "mods/demo/Cfgs/a.json");  // default root
    prov["remote_root"] = "/mods//v2";
    CHECK(remote_path_for(prov, "demo", "Cfgs/a.json") == "mods/v2/demo/Cfgs/a.json");
    CHECK(remote_path_for(prov, "demo", "") == "mods/v2/demo");
    CHECK(remote_path_for(prov, "", "") == "mods/v2");
    // python parity: _norm_remote keeps a trailing slash and "/".join doubles it
    prov["remote_root"] = "/mods/v2/";
    CHECK(remote_path_for(prov, "demo", "") == "mods/v2//demo");
    bool threw = false;
    try {
        remote_path_for(prov, "../evil", "x");
    } catch (const sa::cloud::PyError& e) {
        threw = true;
        CHECK(std::string(e.what()) == "ValueError: invalid remote path: ../evil");
    }
    CHECK(threw);
}

TEST_CASE("P5 DRIVERS registry order + get_driver envelopes", "[p5][cloud][units]") {
    std::vector<std::string> names;
    for (const auto& [n, f] : sa::cloud::drivers()) names.push_back(n);
    CHECK(names == std::vector<std::string>{"local", "webdav", "openlist", "alist",
                                            "baidu_netdisk", "baidu", "123", "123pan",
                                            "google_drive", "gdrive", "onedrive"});
    auto get = [&](const json& t) { return sa::cloud::get_driver(t, json::object()); };
    CHECK(get(json("LOCAL")) != nullptr);          // lower-cased
    CHECK(get(json("alist")) != nullptr);          // alias
    auto env = [&](const json& t) {
        try {
            get(t);
            return std::string("");
        } catch (const sa::cloud::PyError& e) {
            return std::string(e.what());
        } catch (const sa::ApiError& e) {
            return std::string(e.what());
        }
    };
    CHECK(env(json("quark")) ==
          "ValueError: 夸克云盘已停止支持：请删除该云存储配置，改用 OpenList "
          "代理（在 OpenList 中添加对应存储后，此处填 OpenList 地址 + 挂载路径）。");
    CHECK(env(json("aliyundrive")).find("阿里云盘") != std::string::npos);
    CHECK(env(json()) == "ValueError: unknown driver: None");
    CHECK(env(json("nope")) == "ValueError: unknown driver: nope");
    CHECK(env(json(5)) == "AttributeError: 'int' object has no attribute 'lower'");
}

TEST_CASE("P5 netdisk drivers: root/openlist delegation + degraded direct legs", "[p5][cloud][units]") {
    CloudFixture fx("netdisk");
    // baidu with root delegates to LocalDriver (full parity)
    {
        json cfg;
        cfg["root"] = fx.remote();
        auto drv = sa::cloud::get_driver(json("baidu"), cfg);
        drv->test();
        drv->mkdir("a/b");
        REQUIRE(sa::cloud::get_driver(json("baidu_netdisk"), cfg)->stat("a/b")->is_dir);
    }
    // google_drive direct (no root/openlist) -> deterministic ValueError
    auto direct_env = [](const char* type) {
        try {
            sa::cloud::get_driver(json(type), json::object())->list("x");
            return std::string("");
        } catch (const sa::cloud::PyError& e) {
            return std::string(e.what());
        }
    };
    CHECK(direct_env("baidu").find("ValueError: baidu 直连需真实外联") == 0);
    CHECK(direct_env("123").find("ValueError: 123 直连需真实外联") == 0);
    CHECK(direct_env("google_drive").find("ValueError: Google Drive 直连列目录失败") == 0);
    CHECK(direct_env("onedrive").find("ValueError: OneDrive 直连列目录失败") == 0);
    // onedrive pure-logic direct branches (no network in Python either)
    {
        auto od = sa::cloud::get_driver(json("onedrive"), json::object());
        CHECK(od->stat("mods/x").has_value() == false);           // returns None
        od->remove("mods/x");                                     // returns True
        od->mkdir("mods/x");                                      // returns True
        try {
            od->get("mods/x", "out");
            FAIL("expected ValueError");
        } catch (const sa::cloud::PyError& e) {
            CHECK(std::string(e.what()) ==
                  "ValueError: OneDrive 直连下载需配置 openlist_url，请通过 OpenList 代理");
        }
        try {
            od->put("in", "mods/x");
            FAIL("expected NotImplementedError");
        } catch (const sa::cloud::PyError& e) {
            CHECK(std::string(e.what()) ==
                  "NotImplementedError: onedrive requires openlist_url");
        }
        // refresh_token without client_id -> the guard message is real behavior
        json cfg;
        cfg["refresh_token"] = "rt";
        try {
            sa::cloud::get_driver(json("onedrive"), cfg)->test();
            FAIL("expected ValueError");
        } catch (const sa::cloud::PyError& e) {
            CHECK(std::string(e.what()).find("OneDrive 需要 refresh_token + Client ID") !=
                  std::string::npos);
        }
    }
}

// ---------------------------------------------------------------------------
// LocalDriver full chain
// ---------------------------------------------------------------------------

TEST_CASE("P5 LocalDriver list/stat/get/put/delete/mkdir + escape refusals", "[p5][cloud][local]") {
    CloudFixture fx("localdrv");
    fs::path root = fx.root() / "R";
    json cfg;
    cfg["root"] = P(root);
    auto drv = sa::cloud::make_local(cfg);

    // root required
    CHECK_THROWS_AS(sa::cloud::make_local(json::object())->test(), sa::cloud::PyError);
    try {
        sa::cloud::make_local(json::object())->test();
    } catch (const sa::cloud::PyError& e) {
        CHECK(std::string(e.what()) == "ValueError: local root required");
    }
    // missing dir -> test fails like ValueError
    try {
        drv->test();
        FAIL("expected ValueError");
    } catch (const sa::cloud::PyError& e) {
        CHECK(e.type_name == "ValueError");
        CHECK(e.str_msg.find("local root not found:") == 0);
    }
    fs::create_directories(root);
    drv->test();

    drv->mkdir("mods/demo/sub");
    wfile(fx.root() / "src.json", "hello");
    drv->put(P(fx.root() / "src.json"), "mods/demo/sub/a.json");
    drv->put(P(fx.root() / "src.json"), "mods/demo/b.json");

    // list: sorted, dirs is_dir size 0, files carry size
    auto entries = drv->list("mods/demo");
    REQUIRE(entries.size() == 2);
    CHECK(entries[0].name == "b.json");
    CHECK(entries[0].path == "mods/demo/b.json");
    CHECK_FALSE(entries[0].is_dir);
    CHECK(entries[0].size == 5);
    CHECK(entries[1].name == "sub");
    CHECK(entries[1].is_dir);
    CHECK(entries[1].size == 0);
    CHECK(drv->list("nope/none").empty());  // missing dir -> empty, no throw

    // stat file: sha1 + mtime
    auto st = drv->stat("mods/demo/b.json");
    REQUIRE(st.has_value());
    CHECK(st->name == "b.json");
    CHECK(st->size == 5);
    CHECK(st->sha1 == "aaf4c61ddcc5e8a2dabede0f3b482cd9aea9434d");
    CHECK(drv->stat("mods/missing.json") == std::nullopt);

    // get copies content and creates parent dirs
    fs::path out = fx.root() / "deep/x/out.json";
    drv->get("mods/demo/sub/a.json", P(out));
    CHECK(rfile(out) == "hello");
    try {
        drv->get("mods/missing.json", P(out));
        FAIL("expected FileNotFoundError");
    } catch (const sa::cloud::PyError& e) {
        CHECK(std::string(e.what()) == "FileNotFoundError: mods/missing.json");
    }

    // remove file and recursive dir
    drv->remove("mods/demo/b.json");
    CHECK_FALSE(fs::exists(root / "mods" / "demo" / "b.json"));
    drv->remove("mods/demo");
    CHECK_FALSE(fs::exists(root / "mods" / "demo"));

    // escapes: norm rejects "..", drive letter resolves outside root
    try {
        drv->stat("../evil");
        FAIL("expected ValueError");
    } catch (const sa::cloud::PyError& e) {
        CHECK(e.str_msg.find("invalid remote path") != std::string::npos);
    }
    try {
        drv->stat("C:/Windows/win.ini");
        FAIL("expected ValueError");
    } catch (const sa::cloud::PyError& e) {
        CHECK(e.str_msg == "path escapes root");
    }
}

// ---------------------------------------------------------------------------
// WebDAV driver vs local mock
// ---------------------------------------------------------------------------

TEST_CASE("P5 WebDAVDriver full chain against mock server", "[p5][cloud][webdav][mock]") {
    CloudFixture fx("webdav");
    auto st = std::make_shared<DavState>();
    st->dirs.insert("/dav");
    st->dirs.insert("/dav/mods");
    st->files["/dav/mods/a.json"] = "hello";
    st->files["/dav/mods/big.bin"] = std::string(100, 'x');

    p5mock::Server mock;
    mock.on("", "", [st](const p5mock::Request& req, p5mock::Response& res) {
        const std::string& t = req.path;
        std::lock_guard<std::mutex> lk(st->mu);
        if (t == "/dav401" || t == "/dav401/") {
            res.status = 401;
            return;
        }
        if (t == "/davfail" || t == "/davfail/") {
            res.status = 404;
            return;
        }
        std::string method = req.method;
        std::string body;
        if (method == "PROPFIND") {
            std::string depth = req.get_header_value("Depth");
            std::string xml = "<?xml version=\"1.0\"?><D:multistatus xmlns:D=\"DAV:\">";
            if (depth == "1") {
                xml += propfind_block("/dav/mods/", true, 0, "");
                xml += propfind_block("/dav/mods/a.json", false, 5,
                                      "Tue, 01 Sep 2026 08:30:00 GMT");
                xml += propfind_block("/dav/mods/big.bin", false, 100, "");
                xml += propfind_block("/dav/mods/sub", true, 0, "");
                xml += propfind_block("/dav/mods/sub/deep.json", false, 1, "");
                xml += "<D:response><D:propstat><D:prop/></D:propstat></D:response>";
            } else if (t == "/dav" || t == "/dav/") {
                xml += propfind_block("/dav/", true, 0, "");  // the mount root itself
            } else {
                if (t == "/dav/mods/a.json") {
                    xml += propfind_block("/dav/mods/a.json", false, 5,
                                          "Tue, 01 Sep 2026 08:30:00 GMT");
                } else if (t == "/dav/mods/sub") {
                    xml += propfind_block("/dav/mods/sub", true, 0, "");
                } else {
                    res.status = 404;
                    return;
                }
            }
            xml += "</D:multistatus>";
            res.status = 207;
            res.set_content(xml, "application/xml");
            return;
        }
        if (method == "MKCOL") {
            st->dirs.insert(t);
            res.status = 201;
            return;
        }
        if (method == "PUT") {
            if (t.rfind("/davfail/", 0) == 0) {
                res.status = 500;
                return;
            }
            st->files[t] = req.body;
            res.status = 201;
            return;
        }
        if (method == "GET") {
            auto it = st->files.find(t);
            if (it == st->files.end()) {
                res.status = 404;
                return;
            }
            res.set_content(it->second, "application/octet-stream");
            return;
        }
        if (method == "DELETE") {
            if (t.rfind("/davfail/", 0) == 0) {
                res.status = 500;
                return;
            }
            auto it = st->files.find(t);
            if (it != st->files.end()) {
                st->files.erase(it);
                res.status = 204;
                return;
            }
            res.status = 404;  // deleting a missing path: python treats 404 as OK
            return;
        }
        res.status = 405;
    });
    mock.serve();
    int port = mock.start();
    REQUIRE(port > 0);

    json cfg;
    cfg["url"] = mock.base() + "/dav";
    cfg["username"] = "u";
    cfg["password"] = "p";
    auto drv = sa::cloud::get_driver(json("webdav"), cfg);

    // test(): PROPFIND Depth 0 on base -> 207 ok; 401 mount -> ValueError;
    // empty url -> ValueError.
    drv->test();
    {
        json c401;
        c401["url"] = mock.base() + "/dav401";
        try {
            sa::cloud::get_driver(json("webdav"), c401)->test();
            FAIL("expected ValueError");
        } catch (const sa::cloud::PyError& e) {
            CHECK(std::string(e.what()) == "ValueError: webdav test failed: 401");
        }
        json cnone;
        cnone["url"] = "";
        try {
            sa::cloud::get_driver(json("webdav"), cnone)->test();
            FAIL("expected ValueError");
        } catch (const sa::cloud::PyError& e) {
            CHECK(std::string(e.what()) == "ValueError: webdav url required");
        }
    }

    // list("mods") — direct children only, sizes, http-date mtime
    auto objs = drv->list("mods");
    REQUIRE(objs.size() == 3);
    CHECK(objs[0].name == "a.json");
    CHECK(objs[0].path == "mods/a.json");
    CHECK(objs[0].size == 5);
    CHECK(objs[0].mtime == kEpoch2026Sep01_0830);
    CHECK_FALSE(objs[0].is_dir);
    CHECK(objs[1].name == "big.bin");
    CHECK(objs[1].mtime == 0);
    CHECK(objs[2].name == "sub");
    CHECK(objs[2].is_dir);

    // stat file + dir + missing
    auto s1 = drv->stat("mods/a.json");
    REQUIRE(s1.has_value());
    CHECK(s1->name == "a.json");
    CHECK(s1->size == 5);
    CHECK(s1->mtime == kEpoch2026Sep01_0830);
    auto s2 = drv->stat("mods/sub");
    REQUIRE(s2.has_value());
    CHECK(s2->is_dir);
    CHECK(drv->stat("mods/missing.json") == std::nullopt);

    // get / get-fail
    fs::path out = fx.root() / "dl.json";
    drv->get("mods/a.json", P(out));
    CHECK(rfile(out) == "hello");
    try {
        drv->get("mods/missing.json", P(out));
        FAIL("expected ValueError");
    } catch (const sa::cloud::PyError& e) {
        CHECK(std::string(e.what()) == "ValueError: webdav get failed: 404");
    }

    // put: creates parents via MKCOL segment-by-segment, then PUT
    wfile(fx.root() / "up.json", "payload");
    drv->put(P(fx.root() / "up.json"), "mods/newp/deep/up.json");
    {
        auto calls = mock.calls();
        std::vector<std::string> mkcols, puts;
        for (const auto& c : calls) {
            if (c.method == "MKCOL") mkcols.push_back(c.target);
            if (c.method == "PUT") puts.push_back(c.target);
        }
        CHECK(mkcols == std::vector<std::string>{"/dav/mods", "/dav/mods/newp",
                                                 "/dav/mods/newp/deep"});
        REQUIRE(!puts.empty());
        CHECK(puts.back() == "/dav/mods/newp/deep/up.json");
        std::lock_guard<std::mutex> lk(st->mu);
        CHECK(st->files["/dav/mods/newp/deep/up.json"] == "payload");
    }
    // put with missing local source -> FileNotFoundError
    try {
        drv->put(P(fx.root() / "nope.json"), "mods/x.json");
        FAIL("expected FileNotFoundError");
    } catch (const sa::cloud::PyError& e) {
        CHECK(e.type_name == "FileNotFoundError");
    }
    // put on failing server -> ValueError "webdav put failed: 500"
    {
        json cfail;
        cfail["url"] = mock.base() + "/davfail";
        try {
            sa::cloud::get_driver(json("webdav"), cfail)->put(P(fx.root() / "up.json"), "x.json");
            FAIL("expected ValueError");
        } catch (const sa::cloud::PyError& e) {
            CHECK(std::string(e.what()) == "ValueError: webdav put failed: 500");
        }
    }

    // delete: 204 ok, 404 ok, 500 raises
    drv->remove("mods/a.json");
    {
        std::lock_guard<std::mutex> lk(st->mu);
        CHECK(st->files.count("/dav/mods/a.json") == 0);
    }
    drv->remove("mods/never-existed.json");  // 404 treated as success
    {
        json cfail;
        cfail["url"] = mock.base() + "/davfail";
        try {
            sa::cloud::get_driver(json("webdav"), cfail)->remove("x.json");
            FAIL("expected ValueError");
        } catch (const sa::cloud::PyError& e) {
            CHECK(std::string(e.what()) == "ValueError: webdav delete failed: 500");
        }
    }

    // Basic auth header wire-format
    bool saw_auth = false;
    for (const auto& c : mock.calls()) {
        auto it = c.headers.find("authorization");
        if (it != c.headers.end() && it->second == "Basic dTpw") saw_auth = true;
    }
    CHECK(saw_auth);
}

// ---------------------------------------------------------------------------
// OpenList driver vs local mock
// ---------------------------------------------------------------------------

TEST_CASE("P5 OpenListDriver full chain against mock server", "[p5][cloud][openlist][mock]") {
    CloudFixture fx("openlist");
    auto st = std::make_shared<OlState>();
    st->files["/mods/a.json"] = "hello";

    p5mock::Server mock;
    mock.on("", "", [st](const p5mock::Request& req, p5mock::Response& res) {
        std::lock_guard<std::mutex> lk(st->mu);
        const std::string& t = req.target;
        auto ends = [&](const char* s) { return t.find(s) != std::string::npos; };
        auto json_res = [&res](int code, const std::string& body) {
            res.status = code;
            res.set_content(body, "application/json");
        };
        // Special-status mounts first (their URLs also contain /api/... paths).
        if (t.rfind("/cf/", 0) == 0) {
            res.status = 403;
            res.set_content("oplist.org | Sorry, you have been blocked. error code: 1010",
                            "text/plain");
            return;
        }
        if (t.rfind("/403plain/", 0) == 0) {
            res.status = 403;
            res.set_content("nope", "text/plain");
            return;
        }
        if (ends("/api/me")) {
            if (ends("/nomecase/")) return json_res(404, "nope");
            return json_res(200, R"({"code":200,"message":"success","data":{"id":1}})");
        }
        if (ends("/api/fs/list")) {
            st->last_list = {req.method, t, req.body, {}};
            std::string content =
                R"({"code":200,"message":"success","data":{"content":[)"
                R"({"name":"a.json","is_dir":false,"size":123,"modified":"2026-09-01T08:30:00Z"},)"
                R"({"name":"b.json","is_dir":false,"size":1,"modified":1788328200},)"
                R"({"name":"c.json","is_dir":false,"size":1,"modified":"not-a-date"},)"
                R"({"name":"d.json","is_dir":false,"size":1,"modified":"1788328200"},)"
                R"({"name":"sub","is_dir":true,"size":0,"modified":null})"
                R"(]}})";
            if (ends("/badcode/")) content = R"({"code":500,"message":"boom"})";
            if (ends("/badjson/")) return json_res(200, "hello");
            return json_res(200, content);
        }
        if (ends("/api/fs/get")) {
            st->last_get = {req.method, t, req.body, {}};
            json p = json::parse(req.body);
            std::string path = p.value("path", "");
            auto it = st->files.find(path);
            std::string name = path.substr(path.find_last_of('/') + 1);
            if (it == st->files.end()) {
                return json_res(404, R"({"code":404,"message":"Entry not found","data":null})");
            }
            std::string raw_url = "/raw" + path;
            std::string body = R"({"code":200,"message":"success","data":{)"
                               R"("name":")" + name + R"(","is_dir":false,"size":)" +
                               std::to_string(it->second.size()) +
                               R"(,"modified":"2026-09-01T08:30:00Z","raw_url":")" + raw_url +
                               R"("}})";
            return json_res(200, body);
        }
        if (t.find("/api/fs/put") != std::string::npos && req.method == "PUT") {
            st->last_put = {req.method, t, req.body, {}};
            std::string fp = req.get_header_value("File-Path");
            if (ends("/putfail/")) return json_res(200, R"({"code":500,"message":"disk full"})");
            st->files[fp] = req.body;
            return json_res(200, R"({"code":200,"message":"success"})");
        }
        if (ends("/api/fs/remove")) {
            st->last_remove = {req.method, t, req.body, {}};
            json p = json::parse(req.body);
            std::string dir = p.value("dir", "");
            if (p.contains("names") && p["names"].is_array()) {
                for (const auto& n : p["names"]) {
                    if (n.is_string()) st->files.erase(dir + "/" + n.get<std::string>());
                }
            }
            return json_res(200, R"({"code":200,"message":"success"})");
        }
        if (ends("/api/fs/mkdir")) {
            st->last_mkdir = {req.method, t, req.body, {}};
            return json_res(200, R"({"code":200,"message":"success"})");
        }
        if (t.rfind("/raw/", 0) == 0) {
            auto it = st->files.find(t.substr(4));  // strip the /raw prefix
            if (it == st->files.end()) return json_res(404, "missing");
            res.status = 200;
            res.set_content(it->second, "application/octet-stream");
            return;
        }
        json_res(404, R"({"error":"no mock route"})");
    });
    mock.serve();
    int port = mock.start();
    REQUIRE(port > 0);

    json cfg;
    cfg["url"] = mock.base();
    cfg["token"] = "tk1";
    auto drv = sa::cloud::get_driver(json("alist"), cfg);  // alias path too

    // Authorization passthrough
    {
        drv->test();
        bool saw_auth = false;
        for (const auto& c : mock.calls()) {
            auto it = c.headers.find("authorization");
            if (it != c.headers.end() && it->second == "tk1") saw_auth = true;
        }
        CHECK(saw_auth);
    }
    // test(): /api/me ok; missing /api/me falls back to list("")
    drv->test();
    {
        json c2;
        c2["url"] = mock.base() + "/nomecase";
        sa::cloud::get_driver(json("openlist"), c2)->test();  // list fallback succeeds
    }

    // list: modified parsing variants incl. the numeric-string quirk
    auto objs = drv->list("mods");
    REQUIRE(objs.size() == 5);
    CHECK(objs[0].name == "a.json");
    CHECK(objs[0].path == "mods/a.json");
    CHECK(objs[0].size == 123);
    // python list() does int(modified) FIRST: an ISO string raises before the
    // fromisoformat branch is reached -> mtime 0 (only stat() parses ISO;
    // test_cloud_sync.py asserts that on STAT). Quirk kept with full parity.
    CHECK(objs[0].mtime == 0);
    CHECK(objs[1].mtime == 1788328200);           // numeric
    CHECK(objs[2].mtime == 0);                    // garbage string -> 0
    CHECK(objs[3].mtime == 1788328200);           // numeric string (python quirk)
    CHECK(objs[4].is_dir);
    CHECK(objs[4].mtime == 0);                    // null modified -> 0
    {
        std::lock_guard<std::mutex> lk(st->mu);
        json p = json::parse(st->last_list.body);
        CHECK(p["path"] == "/mods");
        CHECK(p["page"] == 1);
        CHECK(p["per_page"] == 0);
        CHECK(p["refresh"] == true);
        CHECK(p["password"] == "");
    }

    // stat (test_cloud_sync.py OpenListStatTest intent)
    auto s = drv->stat("mods/a.json");
    REQUIRE(s.has_value());
    CHECK(s->size == 5);
    CHECK(s->mtime == kEpoch2026Sep01_0830);
    CHECK(s->path == "mods/a.json");
    CHECK(drv->stat("mods/missing.json") == std::nullopt);  // code 404 -> None

    // get: relative raw_url resolved against base
    fs::path out = fx.root() / "dl.json";
    drv->get("mods/a.json", P(out));
    CHECK(rfile(out) == "hello");
    try {
        drv->get("mods/missing.json", P(out));
        FAIL("expected ValueError");
    } catch (const sa::cloud::PyError& e) {
        CHECK(std::string(e.what()).find("openlist api /api/fs/get failed: 404") !=
              std::string::npos);
    }

    // put: File-Path header + body stored; failure envelope
    wfile(fx.root() / "up.json", "uploaded");
    drv->put(P(fx.root() / "up.json"), "mods/up.json");
    {
        std::lock_guard<std::mutex> lk(st->mu);
        CHECK(st->files["/mods/up.json"] == "uploaded");
    }
    {
        json c2;
        c2["url"] = mock.base() + "/putfail";
        try {
            sa::cloud::get_driver(json("openlist"), c2)->put(P(fx.root() / "up.json"), "mods/x");
            FAIL("expected ValueError");
        } catch (const sa::cloud::PyError& e) {
            CHECK(std::string(e.what()) == "ValueError: openlist put error: disk full");
        }
    }

    // remove + mkdir payloads
    drv->remove("mods/a.json");
    {
        std::lock_guard<std::mutex> lk(st->mu);
        json p = json::parse(st->last_remove.body);
        CHECK(p["dir"] == "/mods");
        REQUIRE(p["names"].is_array());
        CHECK(p["names"][0] == "a.json");
        CHECK(st->files.count("/mods/a.json") == 0);
    }
    drv->mkdir("mods/n");
    {
        std::lock_guard<std::mutex> lk(st->mu);
        CHECK(json::parse(st->last_mkdir.body)["path"] == "/mods/n");
    }

    // error envelopes
    auto env_at = [&](const std::string& prefix, const std::string& method_call) {
        json c2;
        c2["url"] = mock.base() + prefix;
        auto d2 = sa::cloud::get_driver(json("openlist"), c2);
        try {
            if (method_call == "list") d2->list("x");
            return std::string("");
        } catch (const sa::cloud::PyError& e) {
            return std::string(e.what());
        } catch (const std::exception& e) {
            return std::string("OTHER: ") + e.what();
        }
    };
    CHECK(env_at("/badcode", "list").find("ValueError: openlist error: boom") == 0);
    CHECK(env_at("/badjson", "list").find("ValueError: openlist invalid json: Expecting value") ==
          0);
    CHECK(env_at("/403plain", "list").find("403 Forbidden") != std::string::npos);
    CHECK(env_at("/cf", "list").find("error code: 1010 (Cloudflare 拦截)") != std::string::npos);

    // mis-filled OpenList url (token-refresh endpoint) rejected locally
    {
        json c3;
        c3["url"] = "https://api.oplist.org/baiduyun/renewapi";
        try {
            sa::cloud::get_driver(json("openlist"), c3)->test();
            FAIL("expected ValueError");
        } catch (const sa::cloud::PyError& e) {
            CHECK(e.str_msg.find("renewapi") != std::string::npos);
            CHECK(e.str_msg.find("不是 OpenList 实例地址") != std::string::npos);
        }
        json c4;
        c4["url"] = "";
        try {
            sa::cloud::get_driver(json("openlist"), c4)->test();
        } catch (const sa::cloud::PyError& e) {
            CHECK(std::string(e.what()) == "ValueError: openlist url required");
        }
    }
}

// ---------------------------------------------------------------------------
// Provider CRUD (file = workspace/.editor_cloud.json, fallback <data>/_cache)
// ---------------------------------------------------------------------------

TEST_CASE("P5 providers CRUD via files: order, dedupe, masked-write, fallback path", "[p5][cloud][providers]") {
    CloudFixture fx("providers");
    CHECK(sa::cloud::cloud_config_path() == P(fx.root() / "ws" / ".editor_cloud.json"));

    // empty state
    CHECK(sa::cloud::list_providers().empty());

    json info;
    info["type"] = "local";
    info["config"] = json{{"root", fx.remote()}};
    info["name"] = "first";
    info["remote_root"] = "/mods//";
    auto e1 = sa::cloud::add_provider(info);
    CHECK(keys_of(e1) == std::vector<std::string>{"id", "name", "type", "config",
                                                  "remote_root", "created_at"});
    CHECK(std::regex_match(e1["id"].get<std::string>(), std::regex(R"(p_\d{1,6})")));
    CHECK(e1["name"] == "first");
    CHECK(e1["remote_root"] == "mods/");  // norm_remote collapses//and lstrips, KEEPS trailing (python parity)
    CHECK(std::regex_match(e1["created_at"].get<std::string>(),
                           std::regex(R"(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})")));
    std::string pid = e1["id"].get<std::string>();
    CHECK(fs::exists(fx.root() / "ws" / ".editor_cloud.json"));

    // unsupported type rejected before write
    json bad = info;
    bad["type"] = "nope";
    CHECK_THROWS_AS(sa::cloud::add_provider(bad), sa::cloud::PyError);

    // add with explicit id, same id dedupes (replace)
    json info2;
    info2["id"] = "pFixed";
    info2["type"] = "Local";  // lower-cased
    info2["config"] = json{{"root", fx.remote()}};
    auto e2 = sa::cloud::add_provider(info2);
    CHECK(e2["id"] == "pFixed");
    CHECK(e2["type"] == "local");
    CHECK(sa::cloud::list_providers().size() == 2);
    auto e2b = sa::cloud::add_provider(info2);
    CHECK(sa::cloud::list_providers().size() == 2);  // same id deduped (replaced)
    CHECK((*sa::cloud::get_provider("pFixed"))["id"] == "pFixed");
    (void)e2b;

    // get_provider roundtrip + miss
    REQUIRE(sa::cloud::get_provider("pFixed").has_value());
    CHECK((*sa::cloud::get_provider("pFixed"))["name"] == e2b["name"]);
    CHECK_FALSE(sa::cloud::get_provider("ghost").has_value());

    // update: merge semantics + "***" restore + remoteRoot alias + type guard
    json patch;
    patch["config"] = json{{"token", "***"}, {"root", fx.remote()}};
    sa::cloud::update_provider("pFixed", json{{"config", json{{"token", "secret"}}}});
    auto cur = *sa::cloud::get_provider("pFixed");
    CHECK(cur["config"]["token"] == "secret");
    sa::cloud::update_provider("pFixed", json{{"config", json{{"token", "***"}, {"extra", 1}}}});
    cur = *sa::cloud::get_provider("pFixed");
    CHECK(cur["config"]["token"] == "secret");  // masked writeback restores
    CHECK(cur["config"]["extra"] == 1);         // merge keeps new keys
    CHECK(cur["config"]["root"] == fx.remote());// merge keeps untouched keys
    sa::cloud::update_provider("pFixed", json{{"remoteRoot", "/r2/"}});
    CHECK((*sa::cloud::get_provider("pFixed"))["remote_root"] == "r2/");
    CHECK_THROWS_AS(sa::cloud::update_provider("pFixed", json{{"type", "nope"}}),
                    sa::cloud::PyError);
    try {
        sa::cloud::update_provider("ghost", json::object());
    } catch (const sa::cloud::PyError& e) {
        CHECK(std::string(e.what()) == "ValueError: provider not found: ghost");
    }
    auto upd = sa::cloud::update_provider("pFixed", json{{"name", "renamed"}});
    CHECK(upd["name"] == "renamed");

    // remove
    sa::cloud::remove_provider("pFixed");
    CHECK(sa::cloud::list_providers().size() == 1);
    try {
        sa::cloud::remove_provider("pFixed");
        FAIL("expected ValueError");
    } catch (const sa::cloud::PyError& e) {
        CHECK(std::string(e.what()) == "ValueError: provider not found: pFixed");
    }

    // fallback: workspace missing -> <data>/_cache/cloud_config.json
    {
        fx.set_workspace("Z:/definitely/not/here");
        CHECK(sa::cloud::cloud_config_path() ==
              P(fx.root() / "data" / "_cache" / "cloud_config.json"));
        auto e3 = sa::cloud::add_provider(info);  // writes into the fallback
        CHECK(fs::exists(fx.root() / "data" / "_cache" / "cloud_config.json"));
        CHECK(sa::cloud::list_providers().size() == 1);
        sa::cloud::remove_provider(e3["id"]);
        fx.set_workspace(P(fx.root() / "ws"));
        CHECK(sa::cloud::cloud_config_path() == P(fx.root() / "ws" / ".editor_cloud.json"));
        CHECK(sa::cloud::list_providers().size() == 1);  // original entry intact
    }
}

// ---------------------------------------------------------------------------
// Sync engine on LocalDriver providers
// ---------------------------------------------------------------------------

TEST_CASE("P5 sync_single_file upload/download/dry-run/sync direction matrix", "[p5][cloud][engine]") {
    CloudFixture fx("engine1");
    std::string pid = add_local_provider("ploc", fx.remote());
    fs::path mod_dir = make_mod(fx, "m1", {{"Cfgs/zh-cn/t.json", "hello"}});

    // upload
    auto r = sa::cloud::sync_single_file(pid, "upload", "m1", "Cfgs/zh-cn/t.json", false);
    CHECK(r["ok"] == true);
    CHECK(r["remote"] == "mods/m1/Cfgs/zh-cn/t.json");
    fs::path rfile_p = fx.remote_p() / "mods/m1/Cfgs/zh-cn/t.json";
    REQUIRE(fs::exists(rfile_p));
    CHECK(rfile(rfile_p) == "hello");
    CHECK(sa::cloud::sync_status()["last"] == "upload Cfgs/zh-cn/t.json -> mods/m1/Cfgs/zh-cn/t.json");

    // upload missing local file -> FileNotFoundError "local file not found: <rel>"
    try {
        sa::cloud::sync_single_file(pid, "upload", "m1", "ghost.json", false);
        FAIL("expected FileNotFoundError");
    } catch (const sa::cloud::PyError& e) {
        CHECK(std::string(e.what()) == "FileNotFoundError: local file not found: ghost.json");
    }

    // dry_run reports both sides without touching them
    auto d = sa::cloud::sync_single_file(pid, "download", "m1", "Cfgs/zh-cn/t.json", true);
    CHECK(keys_of(d) == std::vector<std::string>{"dry_run", "local_exists", "local_size",
                                                 "remote_exists", "remote_size", "remote",
                                                 "local", "direction"});
    CHECK(d["dry_run"] == true);
    CHECK(d["local_exists"] == true);
    CHECK(d["local_size"] == 5);
    CHECK(d["remote_exists"] == true);
    CHECK(d["remote_size"] == 5);
    CHECK(d["direction"] == "download");

    // download overwrite
    wfile(mod_dir / "Cfgs/zh-cn/t.json", "local-newer-content");
    auto dl = sa::cloud::sync_single_file(pid, "download", "m1", "Cfgs/zh-cn/t.json", false);
    CHECK(dl["ok"] == true);
    CHECK(rfile(mod_dir / "Cfgs/zh-cn/t.json") == "hello");

    // sync direction: both exist, identical size+mtime (copy2 preserved) -> skip
    auto s1 = sa::cloud::sync_single_file(pid, "sync", "m1", "Cfgs/zh-cn/t.json", false);
    CHECK(s1["action"] == "skip");

    // sync: remote newer (stat sha differs from local + mtime newer) -> download_update
    {
        auto stat0 = sa_core::paths::stat(P(rfile_p));
        REQUIRE(stat0.has_value());
        sa_core::paths::set_mtime_ns(P(rfile_p), stat0->mtime_ns + 100'000'000'000LL);  // +100s
        wfile(rfile_p, "hello");
        sa_core::paths::set_mtime_ns(P(rfile_p), stat0->mtime_ns + 100'000'000'000LL);
        wfile(mod_dir / "Cfgs/zh-cn/t.json", "local-ver");
        auto s2 = sa::cloud::sync_single_file(pid, "sync", "m1", "Cfgs/zh-cn/t.json", false);
        CHECK(s2["action"] == "sync_download_update");
        CHECK(rfile(mod_dir / "Cfgs/zh-cn/t.json") == "hello");
    }
    // sync: local newer -> upload_update
    {
        auto stat0 = sa_core::paths::stat(P(rfile_p));
        REQUIRE(stat0.has_value());
        wfile(mod_dir / "Cfgs/zh-cn/t.json", "mine");
        sa_core::paths::set_mtime_ns(P(mod_dir / "Cfgs/zh-cn/t.json"),
                                     stat0->mtime_ns + 200'000'000'000LL);
        auto s3 = sa::cloud::sync_single_file(pid, "sync", "m1", "Cfgs/zh-cn/t.json", false);
        CHECK(s3["action"] == "sync_upload_update");
        CHECK(rfile(rfile_p) == "mine");
    }
    // sync: neither side exists -> FileNotFoundError
    try {
        sa::cloud::sync_single_file(pid, "sync", "m1", "nowhere.json", false);
        FAIL("expected FileNotFoundError");
    } catch (const sa::cloud::PyError& e) {
        CHECK(std::string(e.what()) ==
              "FileNotFoundError: neither local nor remote exists: nowhere.json");
    }
    // sync: remote only -> sync_download of a fresh file
    {
        wfile(rfile_p.parent_path() / "only-r.json", "R");
        auto s4 = sa::cloud::sync_single_file(pid, "sync", "m1", "Cfgs/zh-cn/only-r.json", false);
        CHECK(s4["action"] == "sync_download");
        CHECK(rfile(mod_dir / "Cfgs/zh-cn/only-r.json") == "R");
    }
    // delete_local + delete_remote
    wfile(mod_dir / "gone.json", "x");
    auto ddel = sa::cloud::sync_single_file(pid, "delete_local", "m1", "gone.json", false);
    CHECK(ddel["ok"] == true);
    CHECK_FALSE(fs::exists(mod_dir / "gone.json"));
    sa::cloud::sync_single_file(pid, "upload", "m1", "Cfgs/zh-cn/t.json", false);
    auto rdel = sa::cloud::sync_single_file(pid, "delete_remote", "m1", "Cfgs/zh-cn/t.json", false);
    CHECK(rdel["ok"] == true);
    CHECK_FALSE(fs::exists(rfile_p));
    // unknown direction
    try {
        sa::cloud::sync_single_file(pid, "bogus", "m1", "Cfgs/zh-cn/t.json", false);
        FAIL("expected ValueError");
    } catch (const sa::cloud::PyError& e) {
        CHECK(std::string(e.what()) == "ValueError: unknown direction: bogus");
    }
    // bad provider / bad mod name
    try {
        sa::cloud::sync_single_file("noprovider", "upload", "m1", "x", false);
    } catch (const sa::cloud::PyError& e) {
        CHECK(std::string(e.what()) == "ValueError: provider not found");
    }
    try {
        sa::cloud::sync_single_file(pid, "upload", "bad/mod", "x", false);
    } catch (const sa::cloud::PyError& e) {
        CHECK(std::string(e.what()) == "ValueError: invalid mod_name");
    }
    // empty rel (whitespace-only collapses to "" after strip)
    try {
        sa::cloud::sync_single_file(pid, "upload", "m1", "  ", false);
    } catch (const sa::cloud::PyError& e) {
        CHECK(std::string(e.what()) == "ValueError: rel_path required");
    }
}

TEST_CASE("P5 sync_mod_files batching: per-file results, failures do not abort", "[p5][cloud][engine]") {
    CloudFixture fx("engine2");
    std::string pid = add_local_provider("p2", fx.remote());
    make_mod(fx, "m1", {{"a.txt", "AAA"}, {"b.txt", "BBBB"}});

    json paths = json::array({"a.txt", "ghost.txt", "b.txt"});
    auto res = sa::cloud::sync_mod_files(pid, "upload", "m1", paths, false);
    REQUIRE(res["results"].size() == 3);
    CHECK(res["results"][0]["ok"] == true);
    CHECK(res["results"][0]["rel"] == "a.txt");
    CHECK(res["results"][0]["result"]["remote"] == "mods/m1/a.txt");
    CHECK(res["results"][1]["ok"] == false);
    CHECK(res["results"][1]["error"] == "FileNotFoundError: local file not found: ghost.txt");
    CHECK(res["results"][2]["ok"] == true);
    CHECK(res["dry_run"] == false);
    CHECK(fs::exists(fx.remote_p() / "mods/m1/a.txt"));
    CHECK(fs::exists(fx.remote_p() / "mods/m1/b.txt"));

    // validation envelopes
    try {
        sa::cloud::sync_mod_files(pid, "upload", "m1", json(5), false);
    } catch (const sa::cloud::PyError& e) {
        CHECK(std::string(e.what()) == "ValueError: rel_paths must be list");
    }
    try {
        sa::cloud::sync_mod_files(pid, "upload", "m1", json::array(), false);
    } catch (const sa::cloud::PyError& e) {
        CHECK(std::string(e.what()) == "ValueError: no files to sync");
    }
    json many = json::array();
    for (int i = 0; i < 501; ++i) many.push_back("f" + std::to_string(i) + ".json");
    try {
        sa::cloud::sync_mod_files(pid, "upload", "m1", many, false);
    } catch (const sa::cloud::PyError& e) {
        CHECK(std::string(e.what()) == "ValueError: too many files (>500)");
    }
    try {
        sa::cloud::sync_mod_files(pid, "upload", "", json::array({"x"}), false);
    } catch (const sa::cloud::PyError& e) {
        CHECK(std::string(e.what()) == "ValueError: mod_name required");
    }
    // history recorded (count = len(paths) not len(results))
    auto hist = sa::cloud::sync_status()["history"];
    REQUIRE(hist.size() >= 1);
    CHECK(hist[0]["count"] == 3);
    CHECK(hist[0]["direction"] == "upload");
    CHECK(hist[0]["mod"] == "m1");
}

TEST_CASE("P5 sync_mod_folder upload/dry-run/delete-extra/empty flows", "[p5][cloud][engine]") {
    CloudFixture fx("engine3");
    std::string pid = add_local_provider("p3", fx.remote());
    make_mod(fx, "m2", {{"a.txt", "AAAA"}, {"Cfgs/zh-cn/b.json", "{\"k\":1}"}});
    fs::path rbase = fx.remote_p() / "mods/m2";

    // dry run first: actions decided, nothing written
    auto dr = sa::cloud::sync_mod_folder(pid, "upload", "m2", true, false);
    CHECK(dr["dry_run"] == true);
    CHECK(dr["total"] == 2);
    CHECK(dr["direction"] == "upload");
    REQUIRE(dr["results"].size() == 2);
    CHECK(dr["results"][0]["action"] == "upload_new");
    CHECK(dr["results"][0]["rel"] == "Cfgs/zh-cn/b.json");  // sorted() order: 'C' < 'a'
    CHECK(dr["results"][1]["rel"] == "a.txt");
    CHECK_FALSE(fs::exists(rbase));

    // real run -> files appear
    auto run1 = sa::cloud::sync_mod_folder(pid, "upload", "m2", false, false);
    REQUIRE(run1["results"].size() == 2);
    CHECK(fs::exists(rbase / "a.txt"));
    CHECK(fs::exists(rbase / "Cfgs/zh-cn/b.json"));

    // re-run: unchanged -> skip_unchanged (copy2 preserved mtime, sizes equal)
    auto run2 = sa::cloud::sync_mod_folder(pid, "upload", "m2", false, false);
    for (const auto& e : run2["results"]) CHECK(e["action"] == "skip_unchanged");

    // remote extra file: default skip_extra_remote; delete_extra removes it
    wfile(rbase / "extra.txt", "R-only");
    auto run3 = sa::cloud::sync_mod_folder(pid, "upload", "m2", false, false);
    bool saw_skip = false;
    for (const auto& e : run3["results"]) {
        if (e["rel"] == "extra.txt") {
            CHECK(e["action"] == "skip_extra_remote");
            saw_skip = true;
        }
    }
    CHECK(saw_skip);
    auto run4 = sa::cloud::sync_mod_folder(pid, "upload", "m2", false, true);
    for (const auto& e : run4["results"]) {
        if (e["rel"] == "extra.txt") CHECK(e["action"] == "delete_remote");
    }
    CHECK_FALSE(fs::exists(rbase / "extra.txt"));

    // download flow: new provider pointed elsewhere, remote side seeded
    {
        std::string pid2 = add_local_provider("p3b", fx.remote());
        json st = sa::cloud::sync_status();
        // mod with empty dir list: make_mod creates Cfgs/zh-cn but no files
        make_mod(fx, "m3");
        // seed remote under mods/m3
        wfile(fx.remote_p() / "mods/m3/h.txt", "from-remote");
        auto dl = sa::cloud::sync_mod_folder(pid2, "download", "m3", false, false);
        REQUIRE(dl["results"].size() == 1);
        CHECK(dl["results"][0]["action"] == "download_new");
        CHECK(rfile(fx.root() / "ws/m3/h.txt") == "from-remote");
        (void)st;
    }

    // total==0 with an existing but file-less mod + no remote -> friendly message
    {
        fs::create_directories(fx.root() / "empty-remote");
        std::string pid4 = add_local_provider("p3c", P(fx.root() / "empty-remote"));
        make_mod(fx, "mempty");  // only Cfgs/zh-cn dir, no files
        auto res = sa::cloud::sync_mod_folder(pid4, "upload", "mempty", false, false);
        CHECK(res["results"].empty());
        CHECK(res["total"] == 0);
        CHECK(res["message"].get<std::string>().find("未发现文件") != std::string::npos);
    }
    // mod does not exist locally at all
    try {
        sa::cloud::sync_mod_folder(pid, "upload", "ghostmod", false, false);
        FAIL("expected ValueError");
    } catch (const sa::cloud::PyError& e) {
        CHECK(e.str_msg.find("本地 Mod 不存在: ghostmod") != std::string::npos);
    }
    // history entries: folder_* direction prefix, count = len(results), newest first
    auto hist = sa::cloud::sync_status()["history"];
    REQUIRE(hist.size() >= 2);
    CHECK(hist[0]["direction"] == "folder_download");  // last pushing op: m3 download (mempty's
                                                       // total==0 path returns BEFORE push)
    bool any_folder_upload = false, any_folder_download = false;
    for (const auto& h : hist) {
        if (h["direction"] == "folder_upload") any_folder_upload = true;
        if (h["direction"] == "folder_download") any_folder_download = true;
    }
    CHECK(any_folder_upload);
    CHECK(any_folder_download);

    // sync_status shape: 8 keys in python insertion order
    CHECK(keys_of(sa::cloud::sync_status()) ==
          std::vector<std::string>{"running", "provider", "action", "progress", "total", "last",
                                   "error", "history"});
}

// ---------------------------------------------------------------------------
// Routes (black-box through Router::dispatch, no socket)
// ---------------------------------------------------------------------------

TEST_CASE("P5 cloud routes: providers list masks secrets + drivers order", "[p5][cloud][routes]") {
    CloudFixture fx("routes1");
    json info;
    info["id"] = "mask1";
    info["type"] = "webdav";
    info["config"] = json{{"url", "http://x"}, {"token", "abc"}, {"password", ""}, {"passphrase", "pp"}};
    sa::cloud::add_provider(info);

    sa::Router r;
    sa::register_cloud_routes(r);
    auto resp = sat::call_router(r, "GET", "/api/cloud/providers");
    REQUIRE(resp.status == 200);
    CHECK(resp.json_payload["providers"].size() == 1);
    const json& p = resp.json_payload["providers"][0];
    CHECK(p["config"]["url"] == "http://x");
    CHECK(p["config"]["token"] == "***");
    CHECK(p["config"]["password"] == "");   // falsy masked to ""
    CHECK(p["config"]["passphrase"] == "***");
    CHECK(resp.json_payload["drivers"].get<std::vector<std::string>>() ==
          std::vector<std::string>{"local", "webdav", "openlist", "alist", "baidu_netdisk",
                                   "baidu", "123", "123pan", "google_drive", "gdrive",
                                   "onedrive"});

    auto dv = sat::call_router(r, "GET", "/api/cloud/drivers");
    REQUIRE(dv.status == 200);
    CHECK(keys_of(dv.json_payload["drivers"]) == resp.json_payload["drivers"].get<std::vector<std::string>>());
    CHECK(dv.json_payload["drivers"]["local"].contains("root"));

    auto st = sat::call_router(r, "GET", "/api/cloud/status");
    REQUIRE(st.status == 200);
    CHECK(keys_of(st.json_payload) == std::vector<std::string>{"running", "provider", "action",
                                                               "progress", "total", "last",
                                                               "error", "history"});
}

TEST_CASE("P5 cloud routes: provider CRUD envelopes", "[p5][cloud][routes]") {
    CloudFixture fx("routes2");
    sa::Router r;
    sa::register_cloud_routes(r);

    json good;
    good["id"] = "wp";
    good["type"] = "local";
    good["config"] = json{{"root", fx.remote()}};
    auto add = sat::call_router(r, "POST", "/api/cloud/providers", {}, good);
    REQUIRE(add.status == 200);
    CHECK(add.json_payload["provider"]["id"] == "wp");

    json bad = good;
    bad["id"] = "b1";
    bad["type"] = "bogus";
    auto add_bad = sat::call_router(r, "POST", "/api/cloud/providers", {}, bad);
    REQUIRE(add_bad.status == 400);
    CHECK(add_bad.json_payload["error"] == "unsupported driver type: bogus");

    auto upd = sat::call_router(r, "PUT", "/api/cloud/providers/wp", {},
                                json{{"config", json{{"token", "***"}}}});
    REQUIRE(upd.status == 200);  // unknown key masked-write is a no-op merge

    auto del2 = sat::call_router(r, "DELETE", "/api/cloud/providers/wp");
    REQUIRE(del2.status == 200);
    CHECK(del2.json_payload["ok"] == true);
    auto del3 = sat::call_router(r, "DELETE", "/api/cloud/providers/wp");
    REQUIRE(del3.status == 400);
    CHECK(del3.json_payload["error"] == "provider not found: wp");
}

TEST_CASE("P5 cloud routes: test/sync/file/list/local_files mappings", "[p5][cloud][routes]") {
    CloudFixture fx("routes3");
    std::string pid = add_local_provider("rp", fx.remote());
    make_mod(fx, "m1", {{"Cfgs/zh-cn/t.json", "hello"}});

    sa::Router r;
    sa::register_cloud_routes(r);

    // POST /api/cloud/test
    auto t1 = sat::call_router(r, "POST", "/api/cloud/test", {}, json{{"provider_id", pid}});
    REQUIRE(t1.status == 200);
    CHECK(t1.json_payload["ok"] == true);
    auto t2 = sat::call_router(r, "POST", "/api/cloud/test", {}, json{});
    REQUIRE(t2.status == 400);
    CHECK(t2.json_payload["error"] == "type or provider_id required");
    auto t3 = sat::call_router(r, "POST", "/api/cloud/test", {}, json{{"provider_id", "ghost"}});
    REQUIRE(t3.status == 404);
    CHECK(t3.json_payload["error"] == "provider not found");
    auto t4 = sat::call_router(r, "POST", "/api/cloud/test", {},
                               json{{"type", "local"}, {"config", json{{"root", P(fx.root() / "no-dir")}}}});
    REQUIRE(t4.status == 400);  // ValueError from driver.test()
    CHECK(t4.json_payload["error"].get<std::string>().find("local root not found:") == 0);

    // POST /api/cloud/sync validation + single file batch
    auto s1 = sat::call_router(r, "POST", "/api/cloud/sync", {}, json{{"direction", "upload"}});
    REQUIRE(s1.status == 400);
    CHECK(s1.json_payload["error"] == "provider_id required");
    auto s2 = sat::call_router(r, "POST", "/api/cloud/sync", {},
                               json{{"provider_id", pid}, {"direction", "teleport"}, {"mod_name", "m1"}});
    REQUIRE(s2.status == 400);
    CHECK(s2.json_payload["error"] == "invalid direction");
    auto s3 = sat::call_router(r, "POST", "/api/cloud/sync", {},
                               json{{"provider_id", pid}, {"direction", "upload"},
                                    {"mod_name", "m1"}, {"file", "Cfgs/zh-cn/t.json"}});
    REQUIRE(s3.status == 200);  // single "file" form -> sync_mod_files
    CHECK(s3.json_payload["results"][0]["ok"] == true);
    CHECK(fs::exists(fx.remote_p() / "mods/m1/Cfgs/zh-cn/t.json"));
    auto s4 = sat::call_router(r, "POST", "/api/cloud/sync", {},
                               json{{"provider_id", pid}, {"direction", "upload"},
                                    {"mod_name", "m1"}, {"all", true}});
    REQUIRE(s4.status == 200);  // folder form
    CHECK(s4.json_payload.contains("total"));
    CHECK(s4.json_payload["results"].size() == 1);
    auto s5 = sat::call_router(r, "POST", "/api/cloud/sync", {},
                               json{{"provider_id", pid}, {"direction", "upload"}});
    REQUIRE(s5.status == 400);  // no mod_name anywhere
    CHECK(s5.json_payload["error"] == "mod_name required (select mod first)");

    // POST /api/cloud/file
    auto f1 = sat::call_router(r, "POST", "/api/cloud/file", {}, json{{"provider_id", pid}});
    REQUIRE(f1.status == 400);
    CHECK(f1.json_payload["error"] == "provider_id and rel_path required");
    auto f2 = sat::call_router(r, "POST", "/api/cloud/file", {},
                               json{{"provider_id", pid}, {"rel_path", "ghost.json"},
                                    {"direction", "upload"}, {"mod_name", "m1"}});
    REQUIRE(f2.status == 404);  // FileNotFoundError -> 404 str(e)
    CHECK(f2.json_payload["error"] == "local file not found: ghost.json");
    auto f3 = sat::call_router(r, "POST", "/api/cloud/file", {},
                               json{{"provider_id", pid}, {"mod_name", "m1"},
                                    {"rel_path", "Cfgs/zh-cn/t.json"}, {"dry_run", true}});
    REQUIRE(f3.status == 200);
    CHECK(f3.json_payload["dry_run"] == true);
    CHECK(f3.json_payload["remote_exists"] == true);

    // GET /api/cloud/list
    auto l0 = sat::call_router(r, "GET", "/api/cloud/list");
    REQUIRE(l0.status == 400);
    CHECK(l0.json_payload["error"] == "provider_id required");
    auto l1 = sat::call_router(r, "GET", "/api/cloud/list", {{"provider_id", "ghost"}});
    REQUIRE(l1.status == 404);
    auto l2 = sat::call_router(r, "GET", "/api/cloud/list", {{"provider_id", pid}, {"mod_name", "m1"}});
    REQUIRE(l2.status == 200);
    CHECK(l2.json_payload["remote"] == "mods/m1");
    REQUIRE(l2.json_payload["objects"].size() == 1);
    const json& o = l2.json_payload["objects"][0];
    CHECK(o["name"] == "Cfgs");
    CHECK(o["is_dir"] == true);
    CHECK(keys_of(o) == std::vector<std::string>{"name", "path", "is_dir", "size", "mtime", "sha1"});

    // GET /api/cloud/local_files
    auto g1 = sat::call_router(r, "GET", "/api/cloud/local_files", {{"mod", "m1"}});
    REQUIRE(g1.status == 200);
    CHECK(g1.json_payload["count"] == 1);
    CHECK(g1.json_payload["entries"][0]["name"] == "Cfgs/zh-cn/t.json");
    CHECK(g1.json_payload["entries"][0]["type"] == "file");
    auto g2 = sat::call_router(r, "GET", "/api/cloud/local_files", {{"mod", "ghost"}});
    REQUIRE(g2.status == 404);
    CHECK(g2.json_payload["error"] == "mod not found: ghost");
    CHECK(g2.json_payload.contains("mod_dir"));
    auto g3 = sat::call_router(r, "GET", "/api/cloud/local_files");
    REQUIRE(g3.status == 400);
    CHECK(g3.json_payload["error"] == "mod_name required");
}
