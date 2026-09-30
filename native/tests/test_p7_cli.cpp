// tests/test_p7_cli.cpp — pure-logic tests for the native CLI (P7).
//
// Covers the brief's focus areas: argument parsing (CLI11 -> Command),
// request planning (URL assembly + JSON bodies), output formatting and exit
// policy, plus the local import helpers. No sockets: main.cpp's embedded
// server path is black-boxed by native/tests/smoke_cli.py instead.
//
// Linked into sa_tests via the tests/*.cpp glob; the implementation comes
// from the sa_cli static lib (native/cli/p7_cli_logic.cpp).
#include <catch_amalgamated.hpp>

#include <fstream>

#include "p7_cli_logic.h"
#include "p7_color.h"

#include "sa_core/paths.h"

using namespace sa_cli;

namespace {

struct Parsed {
    GlobalFlags g;
    Command c;
    ParseResult r;
    std::string err;
};

Parsed run(std::vector<std::string> args) {
    Parsed p;
    p.r = parse_command_line(args, p.g, p.c, p.err);
    return p;
}

struct Planned {
    std::vector<HttpRequestSpec> reqs;
    bool ok = false;
    std::string err;
};

Planned plan(Command& c) {
    Planned p;
    p.ok = make_plan(c, p.reqs, p.err);
    return p;
}

std::string tmp_file(const std::string& name, const std::string& content) {
    std::string path = sa_core::paths::join(
        sa_core::paths::path_to_utf8(std::filesystem::temp_directory_path()), "p7_" + name);
    std::ofstream f(path, std::ios::binary | std::ios::trunc);
    f << content;
    f.close();
    return path;
}

}  // namespace

// ---------------------------------------------------------------------------
// Parsing
// ---------------------------------------------------------------------------

TEST_CASE("p7 parse: every command family maps to a Kind", "[p7]") {
    CHECK(run({"mods", "list"}).c.kind == Kind::ModsList);
    CHECK(run({"mods", "create", "T"}).c.kind == Kind::ModsCreate);
    CHECK(run({"mods", "add", "T"}).c.kind == Kind::ModsCreate);
    CHECK(run({"mods", "add", "--path", "d"}).c.kind == Kind::ModsAddPath);
    CHECK(run({"mods", "add", "--zip", "z.zip"}).c.kind == Kind::ModsAddZip);
    CHECK(run({"mods", "select", "M"}).c.kind == Kind::ModsSelect);
    CHECK(run({"mods", "remove", "M"}).c.kind == Kind::ModsRemove);
    CHECK(run({"cfg", "list"}).c.kind == Kind::CfgList);
    CHECK(run({"cfg", "get", "EvtCfg"}).c.kind == Kind::CfgGet);
    CHECK(run({"cfg", "set", "EvtCfg", "--data", "{}"}).c.kind == Kind::CfgSet);
    CHECK(run({"cfg", "patch", "EvtCfg", "--remove", "1"}).c.kind == Kind::CfgPatch);
    CHECK(run({"cfg", "history", "EvtCfg"}).c.kind == Kind::CfgHistory);
    CHECK(run({"validate", "EvtCfg"}).c.kind == Kind::Validate);
    CHECK(run({"bugfix", "scan"}).c.kind == Kind::BugfixScan);
    CHECK(run({"bugfix", "fix"}).c.kind == Kind::BugfixFix);
    CHECK(run({"story", "export", "--evt", "1"}).c.kind == Kind::StoryExport);
    CHECK(run({"story", "import", "--start-id", "1", "--text", "x"}).c.kind == Kind::StoryImport);
    CHECK(run({"oobe", "status"}).c.kind == Kind::OobeStatus);
    CHECK(run({"oobe", "done"}).c.kind == Kind::OobeDone);
    CHECK(run({"oobe", "setup", "--workspace", "w"}).c.kind == Kind::OobeSetup);
    CHECK(run({"env", "get", "k"}).c.kind == Kind::EnvGet);
    CHECK(run({"env", "set", "k", "v"}).c.kind == Kind::EnvSet);
}

TEST_CASE("p7 parse: global options, including after the subcommand", "[p7]") {
    auto a = run({"--url", "http://127.0.0.1:8765", "--data-root", "D:/x", "mods", "list"});
    REQUIRE(a.r == ParseResult::Ok);
    CHECK(a.g.url == "http://127.0.0.1:8765");
    CHECK(a.g.data_root == "D:/x");
    CHECK(!a.g.json);

    auto b = run({"mods", "list", "--json"});
    REQUIRE(b.r == ParseResult::Ok);
    CHECK(b.g.json);

    CHECK(run({}).r == ParseResult::UsageError);               // no subcommand
    CHECK(run({"nope", "list"}).r == ParseResult::UsageError);  // unknown command
    CHECK(run({"cfg", "get"}).r == ParseResult::UsageError);   // missing positional
}

TEST_CASE("p7 parse: mods add is title XOR --path XOR --zip", "[p7]") {
    CHECK(run({"mods", "add"}).r == ParseResult::UsageError);
    auto both = run({"mods", "add", "T", "--path", "d"});
    CHECK(both.r == ParseResult::UsageError);
    auto ok = run({"mods", "add", "--path", "C:/src/MyMod", "--name", "Alias"});
    REQUIRE(ok.r == ParseResult::Ok);
    CHECK(ok.c.path == "C:/src/MyMod");
    CHECK(ok.c.mod_name == "Alias");
}

TEST_CASE("p7 parse: cfg get projections and guards", "[p7]") {
    auto a = run({"cfg", "get", "EvtCfg", "--id", "101", "--field", "title"});
    REQUIRE(a.r == ParseResult::Ok);
    CHECK(a.c.id == "101");
    CHECK(a.c.field == "title");

    CHECK(run({"cfg", "get", "E", "--field", "x"}).r == ParseResult::UsageError);   // field w/o id
    CHECK(run({"cfg", "get", "E", "--id", "1", "--meta"}).r == ParseResult::UsageError);

    auto p = run({"cfg", "get", "E", "--prefix", "bg,cg", "--suffix", "4", "--limit", "5"});
    REQUIRE(p.r == ParseResult::Ok);
    CHECK(p.c.prefix == "bg,cg");
    CHECK(p.c.suffix == "4");
    CHECK(p.c.limit == 5);
}

TEST_CASE("p7 parse/plan: cfg get prefix/suffix are independent filters", "[p7][bug3]") {
    auto p = run({"cfg", "get", "E", "--prefix", "32"});
    REQUIRE(p.r == ParseResult::Ok);
    auto pl = plan(p.c);
    REQUIRE(pl.ok);
    REQUIRE(pl.reqs[0].query.size() == 1);
    CHECK(pl.reqs[0].query[0] == std::make_pair(std::string("prefix"), std::string("32")));

    auto s = run({"cfg", "get", "E", "--suffix", "1"});
    REQUIRE(s.r == ParseResult::Ok);
    auto sl = plan(s.c);
    REQUIRE(sl.ok);
    REQUIRE(sl.reqs[0].query.size() == 1);
    CHECK(sl.reqs[0].query[0] == std::make_pair(std::string("suffix"), std::string("1")));
}

TEST_CASE("p7 parse: search accepts the global --mod", "[p7][bug7]") {
    auto p = run({"search", "篮球场", "--mod", "test"});
    REQUIRE(p.r == ParseResult::Ok);
    CHECK(p.c.kind == Kind::Search);
    CHECK(p.g.mod == "test");
}

TEST_CASE("p7 parse/plan: settings appearance", "[p7][bug9]") {
    CHECK(run({"settings", "appearance", "bad"}).r == ParseResult::UsageError);
    auto s = run({"settings", "appearance", "light"});
    REQUIRE(s.r == ParseResult::Ok);
    CHECK(s.c.kind == Kind::SettingsAppearance);
    auto pl = plan(s.c);
    REQUIRE(pl.ok);
    CHECK(pl.reqs[0].method == "PUT");
    CHECK(pl.reqs[0].path == "/api/settings/editor");
    CHECK(pl.reqs[0].body == json{{"appearanceMode", "light"}});

    auto sh = run({"settings", "appearance", "show"});
    REQUIRE(sh.r == ParseResult::Ok);
    auto shp = plan(sh.c);
    REQUIRE(shp.ok);
    CHECK(shp.reqs[0].method == "GET");
}

TEST_CASE("p7 repl-entry: only known commands may fall through to REPL", "[p7][bug11]") {
    CHECK(references_known_commands_only({}));
    CHECK(references_known_commands_only({"cfg"}));
    CHECK(references_known_commands_only({"--json"}));
    CHECK(references_known_commands_only({"--mod", "test", "cfg"}));
    CHECK_FALSE(references_known_commands_only({"cfg", "badsub"}));
    CHECK_FALSE(references_known_commands_only({"settings", "appearance2"}));
}

TEST_CASE("p7 parse: JSON-valued options are parsed or rejected", "[p7]") {
    auto good = run({"cfg", "patch", "T", "--set", "{\"1\":{\"id\":1}}", "--remove", "2,3",
                     "--if-match", "{\"1\":{\"id\":1}}", "--expect-mtime", "123", "--force"});
    REQUIRE(good.r == ParseResult::Ok);
    REQUIRE(good.c.has_set);
    CHECK(good.c.set_obj["1"]["id"] == 1);
    REQUIRE(good.c.has_remove);
    CHECK(good.c.remove_arr == json::array({"2", "3"}));
    CHECK(good.c.has_if_match);
    CHECK(good.c.has_expect_mtime);
    CHECK(good.c.expect_mtime == 123);
    CHECK(good.c.force);

    auto bad = run({"cfg", "patch", "T", "--set", "{oops"});
    CHECK(bad.r == ParseResult::UsageError);
    auto notobj = run({"cfg", "patch", "T", "--set", "[1,2]"});
    CHECK(notobj.r == ParseResult::UsageError);
}

TEST_CASE("p7 parse: story/oobe/misc flags", "[p7]") {
    auto e = run({"story", "export", "--evt", "101,102", "--dual", "option", "--out", "o.txt"});
    REQUIRE(e.r == ParseResult::Ok);
    CHECK(e.c.evt_ids == "101,102");
    CHECK(e.c.dual == "option");
    CHECK(e.c.out == "o.txt");

    auto i = run({"story", "import", "--start-id", "101", "--file", "s.txt", "--write",
                   "--append"});
    REQUIRE(i.r == ParseResult::Ok);
    CHECK(i.c.write);
    CHECK(i.c.append);
    CHECK(i.c.path == "s.txt");

    auto s = run({"oobe", "setup", "--workspace", "W", "--mod", "M", "--desc", "D",
                  "--no-mark-done"});
    REQUIRE(s.r == ParseResult::Ok);
    CHECK(s.c.root == "W");
    CHECK(s.c.title == "M");
    CHECK(!s.c.mark_done);

    auto v = run({"validate", "EvtCfg", "--strict"});
    REQUIRE(v.r == ParseResult::Ok);
    CHECK(v.c.strict);

    auto h = run({"cfg", "history", "E", "--undo"});
    REQUIRE(h.r == ParseResult::Ok);
    CHECK(h.c.undo);
    CHECK(run({"cfg", "history", "E", "--undo", "--redo"}).r == ParseResult::UsageError);

    auto es = run({"env", "set", "k", "{\"a\":1}", "--json-value"});
    REQUIRE(es.r == ParseResult::Ok);
    CHECK(es.c.json_value);
}

TEST_CASE("p7 parse: non-ASCII values survive as bytes", "[p7]") {
    auto a = run({"mods", "create", "我的模组", "--desc", "你好"});
    REQUIRE(a.r == ParseResult::Ok);
    CHECK(a.c.title == "我的模组");
    CHECK(a.c.desc == "你好");
}

// ---------------------------------------------------------------------------
// Planning (method / path / query / body)
// ---------------------------------------------------------------------------

TEST_CASE("p7 plan: cfg GET carries the documented query projection", "[p7]") {
    auto p = run({"cfg", "get", "BgCfg", "--meta"});
    REQUIRE(p.r == ParseResult::Ok);
    auto pl = plan(p.c);
    REQUIRE(pl.ok);
    REQUIRE(pl.reqs.size() == 1);
    CHECK(pl.reqs[0].method == "GET");
    CHECK(pl.reqs[0].path == "/api/cfg/BgCfg");
    REQUIRE(pl.reqs[0].query.size() == 1);
    CHECK(pl.reqs[0].query[0] == std::make_pair(std::string("meta"), std::string("1")));

    auto p2 = run({"cfg", "get", "E", "--prefix", "bg, cg", "--suffix", "5"});
    REQUIRE(p2.r == ParseResult::Ok);
    auto pl2 = plan(p2.c);
    REQUIRE(pl2.ok);
    REQUIRE(pl2.reqs[0].query.size() == 2);
    CHECK(pl2.reqs[0].query[0] == std::make_pair(std::string("prefix"), std::string("bg, cg")));
    CHECK(pl2.reqs[0].query[1] == std::make_pair(std::string("suffix"), std::string("5")));
}

TEST_CASE("p7 plan: cfg set is a whole-table PUT; patch uses the body discriminator", "[p7]") {
    auto s = run({"cfg", "set", "TextCfg", "--data", "{\"1\":{\"id\":1}}", "--force"});
    REQUIRE(s.r == ParseResult::Ok);
    auto sp = plan(s.c);
    REQUIRE(sp.ok);
    CHECK(sp.reqs[0].method == "PUT");
    CHECK(sp.reqs[0].path == "/api/cfg/TextCfg");
    CHECK(sp.reqs[0].body["data"]["1"]["id"] == 1);
    CHECK(sp.reqs[0].body["force"] == true);
    CHECK(!sp.reqs[0].body.contains("expect_mtime_ns"));

    // S2 contract: there is no PATCH verb — the branch is the "patch" key.
    auto pt = run({"cfg", "patch", "TextCfg", "--set", "{\"2\":{}}", "--remove", "1,x"});
    REQUIRE(pt.r == ParseResult::Ok);
    auto pp = plan(pt.c);
    REQUIRE(pp.ok);
    CHECK(pp.reqs[0].method == "PUT");
    CHECK(pp.reqs[0].body["patch"]["set"].is_object());
    CHECK(pp.reqs[0].body["patch"]["remove"] == json::array({"1", "x"}));

    auto nodata = run({"cfg", "set", "E"});
    auto nd = plan(nodata.c);  // no data -> plan error
    CHECK(!nd.ok);
    CHECK(nd.err.find("data") != std::string::npos);
    auto nopatch = run({"cfg", "patch", "E"});
    CHECK(!plan(nopatch.c).ok);  // neither set nor remove
}

TEST_CASE("p7 plan: --file inputs materialize during planning", "[p7]") {
    std::string f = tmp_file("tbl.json", "\xEF\xBB\xBF{\"7\":{\"id\":7}}");  // with BOM
    auto s = run({"cfg", "set", "E", "--file", f});
    REQUIRE(s.r == ParseResult::Ok);
    auto sp = plan(s.c);
    REQUIRE(sp.ok);
    CHECK(sp.reqs[0].body["data"]["7"]["id"] == 7);

    std::string bad = tmp_file("bad.json", "{nope");
    auto b = run({"cfg", "set", "E", "--file", bad});
    REQUIRE(b.r == ParseResult::Ok);
    CHECK(!plan(b.c).ok);

    std::string t = tmp_file("story.txt", "【甲】话。\n");
    auto i = run({"story", "import", "--start-id", "9", "--file", t, "--write"});
    REQUIRE(i.r == ParseResult::Ok);
    auto ip = plan(i.c);
    REQUIRE(ip.ok);
    CHECK(ip.reqs[0].body["text"] == "【甲】话。\n");
    CHECK(ip.reqs[0].body["write"] == true);
    CHECK(ip.reqs[0].body["append"] == false);
}

TEST_CASE("p7 plan: mods and oobe bodies", "[p7]") {
    auto c = run({"mods", "create", "T", "--desc", "D"});
    auto cp = plan(c.c);
    REQUIRE(cp.ok);
    CHECK(cp.reqs[0].method == "POST");
    CHECK(cp.reqs[0].path == "/api/mods/create");
    CHECK(cp.reqs[0].body["title"] == "T");
    CHECK(cp.reqs[0].body["desc"] == "D");

    auto sel = run({"mods", "select", "M", "--root", "R"});
    auto selp = plan(sel.c);
    REQUIRE(selp.ok);
    CHECK(selp.reqs[0].path == "/api/mods/select");
    CHECK(selp.reqs[0].body["root"] == "R");

    auto rm = run({"mods", "remove", "M"});
    auto rmp = plan(rm.c);
    REQUIRE(rmp.ok);
    CHECK(rmp.reqs[0].path == "/api/mods/delete");

    auto imp = run({"mods", "add", "--zip", "C:/x/MyPack.zip"});
    auto impp = plan(imp.c);
    REQUIRE(impp.ok);
    REQUIRE(impp.reqs.size() == 2);
    CHECK(impp.reqs[0].path == "/api/state");
    CHECK(impp.reqs[1].path == "/api/mods/select");
    CHECK(impp.reqs[1].body["name"] == "MyPack");

    auto st = run({"oobe", "setup", "--mod", "M"});
    auto stp = plan(st.c);
    REQUIRE(stp.ok);
    CHECK(stp.reqs[0].path == "/api/oobe/setup");
    CHECK(stp.reqs[0].body["mod_title"] == "M");
    CHECK(stp.reqs[0].body["mark_done"] == true);

    auto dn = run({"oobe", "done"});
    auto dnp = plan(dn.c);
    REQUIRE(dnp.ok);
    CHECK(dnp.reqs[0].path == "/api/oobe/complete");
}

TEST_CASE("p7 plan: history, bugfix, story, validate and env", "[p7]") {
    auto h = run({"cfg", "history", "EvtCfg"});
    auto hp = plan(h.c);
    REQUIRE(hp.ok);
    CHECK(hp.reqs[0].method == "GET");
    CHECK(hp.reqs[0].path == "/api/history");
    CHECK(hp.reqs[0].query[0] == std::make_pair(std::string("cfg"), std::string("EvtCfg")));

    auto hu = run({"cfg", "history", "EvtCfg", "--undo"});
    auto hup = plan(hu.c);
    REQUIRE(hup.ok);
    CHECK(hup.reqs[0].path == "/api/history/undo");
    CHECK(hup.reqs[0].body["cfg"] == "EvtCfg");

    auto bs = run({"bugfix", "scan"});
    auto bsp = plan(bs.c);
    REQUIRE(bsp.ok);
    CHECK(bsp.reqs[0].path == "/api/bugfix/scan");
    CHECK(bsp.reqs[0].body.is_null());  // no body -> server sees null

    // --from-file accepts both the bare bugs array and a scan payload.
    std::string f1 = tmp_file("bugs_arr.json", "[{\"cfg\":\"E\"}]");
    auto b1 = run({"bugfix", "fix", "--from-file", f1});
    auto b1p = plan(b1.c);
    REQUIRE(b1p.ok);
    CHECK(b1p.reqs[0].body["bugs"].is_array());
    std::string f2 = tmp_file("bugs_obj.json", "{\"bugs\":[],\"count\":0}");
    auto b2 = run({"bugfix", "fix", "--from-file", f2});
    auto b2p = plan(b2.c);
    REQUIRE(b2p.ok);
    CHECK(b2p.reqs[0].body["bugs"].is_array());
    std::string f3 = tmp_file("bugs_bad.json", "5");
    auto b3 = run({"bugfix", "fix", "--from-file", f3});
    CHECK(!plan(b3.c).ok);
    auto b4 = run({"bugfix", "fix"});
    auto b4p = plan(b4.c);
    REQUIRE(b4p.ok);
    CHECK(b4p.reqs[0].body.is_object());
    CHECK(b4p.reqs[0].body.empty());  // fix-all

    auto se = run({"story", "export", "--evt", "1, 2", "--opts", "[\"a\"]"});
    auto sep = plan(se.c);
    REQUIRE(sep.ok);
    CHECK(sep.reqs[0].body["evt_ids"] == json::array({"1", "2"}));
    CHECK(sep.reqs[0].body["opts"] == json::array({"a"}));

    // validate: explicit data -> one POST; otherwise the auto GET.
    auto v1 = run({"validate", "EvtCfg", "--data", "{\"1\":{}}"});
    auto v1p = plan(v1.c);
    REQUIRE(v1p.ok);
    REQUIRE(v1p.reqs.size() == 1);
    CHECK(v1p.reqs[0].method == "POST");
    CHECK(v1p.reqs[0].body["cfg"] == "EvtCfg");
    CHECK(validate_post("EvtCfg", json{{"9", json::object()}}).body["data"]["9"].is_object());

    auto v2 = run({"validate", "EvtCfg"});
    auto v2p = plan(v2.c);
    REQUIRE(v2p.ok);
    REQUIRE(v2p.reqs.size() == 1);
    CHECK(v2p.reqs[0].method == "GET");
    CHECK(v2p.reqs[0].path == "/api/cfg/EvtCfg");

    // env never plans HTTP.
    auto e = run({"env", "get", "k"});
    auto ep = plan(e.c);
    REQUIRE(ep.ok);
    CHECK(ep.reqs.empty());
}

// ---------------------------------------------------------------------------
// URL assembly
// ---------------------------------------------------------------------------

TEST_CASE("p7 url: base join, per-segment encoding, query encoding", "[p7]") {
    HttpRequestSpec s1{"GET", "/api/mods", {}, json()};
    CHECK(build_url("http://127.0.0.1:8765/", s1) == "http://127.0.0.1:8765/api/mods");

    HttpRequestSpec s2{"GET", "/api/cfg/表 名", {}, json()};
    // space -> %20, CJK -> percent-encoded UTF-8 (Python quote() parity).
    auto u2 = build_url("http://127.0.0.1:1", s2);
    CHECK(u2.find("%20") != std::string::npos);
    CHECK(u2.find("表") == std::string::npos);

    HttpRequestSpec s3{"GET", "/api/cfg/a%b", {}, json()};
    CHECK(build_url("http://h:1", s3).find("/api/cfg/a%25b") != std::string::npos);

    HttpRequestSpec s4{"GET", "/api/history", {{"cfg", "A B&c"}}, json()};
    CHECK(build_url("http://h:1", s4) == "http://h:1/api/history?cfg=A%20B%26c");

    // A slash typed into a name DOES create a new segment — deliberately.
    // The httpd layer URL-decodes the path BEFORE route fullmatch
    // (httpd.cpp:379 / CONVENTIONS 2: httpd.py:132-134), so a %2F would be
    // turned back into '/' before matching anyway: encoding a user-typed
    // slash buys nothing. Both forms route-miss and 404 identically, which
    // matches quote()'s safe='/' default and the Python CLI (filesystem-
    // direct: it never puts cfg names into URLs at all).
    HttpRequestSpec s5{"GET", "/api/cfg/a/b", {}, json()};
    CHECK(build_url("http://h:1", s5) == "http://h:1/api/cfg/a/b");
}

// ---------------------------------------------------------------------------
// Exit policy + rendering
// ---------------------------------------------------------------------------

TEST_CASE("p7 exit codes follow the documented policy", "[p7]") {
    Command c;
    c.kind = Kind::ModsList;
    CHECK(compute_exit(200, json{}, c) == 0);
    CHECK(compute_exit(404, json{{"error", "no route"}}, c) == 1);
    CHECK(compute_exit(500, json{{"error", "boom"}}, c) == 1);

    Command v;
    v.kind = Kind::Validate;
    CHECK(compute_exit(200, json{{"counts", {{"error", 2}}}}, v) == 0);  // not strict
    v.strict = true;
    CHECK(compute_exit(200, json{{"counts", {{"error", 2}, {"warn", 0}, {"info", 0}}}}, v) == 1);
    CHECK(compute_exit(200, json{{"counts", {{"error", 0}, {"warn", 5}, {"info", 0}}}}, v) == 0);

    Command g;
    g.kind = Kind::CfgGet;
    g.id = "9";
    CHECK(compute_exit(200, json{{"data", {{"9", json::object()}}}}, g) == 0);
    CHECK(compute_exit(200, json{{"data", json::object()}}, g) == 1);
}

TEST_CASE("p7 error_text renders the shared envelope", "[p7]") {
    json env;
    env["error"] = "conflict";
    env["detail"] = "源文件不是合法 UTF-8";
    env["conflicting_keys"] = json::array({"1", "2"});
    auto s = error_text(env);
    CHECK(s.find("error: conflict") == 0);
    CHECK(s.find("detail:") != std::string::npos);
    CHECK(s.find("conflicting_keys: 1, 2") != std::string::npos);
    CHECK(error_text(json{{"error", "no mod selected"}}) == "error: no mod selected");
    CHECK(error_text(json{{"_raw", "503"}}).find("error:") == 0);
}

TEST_CASE("p7 format_text: mods list marks the selection", "[p7]") {
    Command c;
    c.kind = Kind::ModsList;
    json body;
    body["selected"] = "B";
    body["mods"] = json::array(
        {json{{"name", "A"}, {"cfg_files", json::array({"EvtCfg"})}, {"manifest_title", "T"}}});
    body["mods"].push_back(json{{"name", "B"}, {"cfg_files", json::array()}});
    auto s = format_text(c, body);
    CHECK(s.find("selected: B") != std::string::npos);
    auto line_a = s.find("A");
    auto star = s.find("*   B");
    CHECK(star != std::string::npos);
    CHECK(s.substr(line_a, 6).find("*") == std::string::npos);  // A unmarked
    CHECK(s.find("cfgs=1") != std::string::npos);
}

TEST_CASE("p7 format_text: cfg get rows, id projection and --limit", "[p7]") {
    Command c;
    c.kind = Kind::CfgGet;
    c.limit = 2;
    json data = json::object();
    for (int i = 1; i <= 5; ++i) data[std::to_string(i)] = json{{"title", "t" + std::to_string(i)}};
    json body;
    body["cfg"] = "TextCfg";
    body["exists"] = true;
    body["mtime_ns"] = 123;
    body["data"] = data;
    auto s = format_text(c, body);
    CHECK(s.find("cfg: TextCfg") != std::string::npos);
    CHECK(s.find("records: 5") != std::string::npos);
    CHECK(s.find("3 more") != std::string::npos);

    c.id = "4";
    auto one = format_text(c, body);
    CHECK(one.find("\"title\": \"t4\"") != std::string::npos);  // indent dump
    c.id = "999";
    CHECK(format_text(c, body).find("no such id") != std::string::npos);
    c.id = "4";
    c.field = "title";
    CHECK(format_text(c, body) != one);
    CHECK(format_text(c, body).find("t4") != std::string::npos);
}

TEST_CASE("p7 format_text: the other renderers", "[p7]") {
    Command setc;
    setc.kind = Kind::CfgSet;
    CHECK(format_text(setc, json{{"ok", true}, {"cfg", "E"}, {"mtime_ns", 7}})
              .find("ok: E") != std::string::npos);
    Command pc;
    pc.kind = Kind::CfgPatch;
    auto ps = format_text(pc, json{{"cfg", "E"}, {"applied_set", 1}, {"applied_remove", 2}});
    CHECK(ps.find("applied_set: 1") != std::string::npos);
    CHECK(ps.find("applied_remove: 2") != std::string::npos);

    Command hc;
    hc.kind = Kind::CfgHistory;
    json entry{{"file", "E_1.json"}, {"ts", 1}, {"size", 5}};
    json hbody{{"cfg", "E"}, {"entries", json::array({entry})}};
    auto hs = format_text(hc, hbody);
    CHECK(hs.find("snapshots: 1") != std::string::npos);
    CHECK(hs.find("E_1.json") != std::string::npos);

    Command vc;
    vc.kind = Kind::Validate;
    json iss1{{"level", "error"}, {"rid", "5"}, {"msg", "坏"}};
    json iss2{{"level", "warn"}, {"rid", ""}, {"msg", "嗯"}};
    json vbody{{"issues", json::array({iss1, iss2})},
               {"counts", json{{"error", 1}, {"warn", 1}, {"info", 0}}}};
    auto vs = format_text(vc, vbody);
    CHECK(vs.find("[error] 5: 坏") != std::string::npos);
    CHECK(vs.find("[warn] 嗯") != std::string::npos);
    CHECK(vs.find("counts: error=1 warn=1 info=0") != std::string::npos);

    Command bc;
    bc.kind = Kind::BugfixScan;
    json bug{{"flag", "SCHEMA_HEAL"}, {"cfg", "T"}, {"id", 3}, {"key", "k"}};
    json bbody{{"bugs", json::array({bug})}, {"count", 1}};
    auto bs = format_text(bc, bbody);
    CHECK(bs.find("[SCHEMA_HEAL] T#3.k") != std::string::npos);
    CHECK(bs.find("count: 1") != std::string::npos);

    Command fx;
    fx.kind = Kind::BugfixFix;
    CHECK(format_text(fx, json{{"fixed", 2}, {"remaining_count", 1}})
              .find("fixed: 2") != std::string::npos);

    Command ex;
    ex.kind = Kind::StoryExport;
    CHECK(format_text(ex, json{{"text", "剧情导出文本"}}) == "剧情导出文本\n");

    Command im;
    im.kind = Kind::StoryImport;
    im.write = true;
    json row{{"content", "台词"}};
    json ibody{{"count", 1},
               {"preview", json::array({json::array({json("101001"), row})})}};
    auto is = format_text(im, ibody);
    CHECK(is.find("imported: 1 rows") != std::string::npos);
    CHECK(is.find("台词") != std::string::npos);

    Command ob;
    ob.kind = Kind::OobeStatus;
    auto os = format_text(ob, json{{"done", true}, {"first_run", false}, {"mods_count", 3}});
    CHECK(os.find("done: true") != std::string::npos);
    CHECK(os.find("mods_count: 3") != std::string::npos);

    Command se;
    se.kind = Kind::StoryExport;  // default renderer path via --json handled by main;
    se.kind = Kind::ModsSelect;
    auto ms = format_text(se, json{{"mod", {{"name", "M"}, {"root", "R"}}}});
    CHECK(ms.find("selected: M") != std::string::npos);
    Command rm;
    rm.kind = Kind::ModsRemove;
    CHECK(format_text(rm, json{{"ok", true}}) == "ok: removed\n");
}

TEST_CASE("p7 env_value_text uses Python scalar rendering", "[p7]") {
    CHECK(env_value_text(json("str")) == "str");
    CHECK(env_value_text(json(true)) == "True");
    CHECK(env_value_text(json(nullptr)) == "None");
    CHECK(env_value_text(json(5)) == "5");
    CHECK(env_value_text(json{{"a", 1}}).find("\"a\": 1") != std::string::npos);
}

// ---------------------------------------------------------------------------
// Local import helpers
// ---------------------------------------------------------------------------

TEST_CASE("p7 import_target_name picks a safe directory name", "[p7]") {
    CHECK(import_target_name("C:\\mods\\MyPack\\", false, "") == "MyPack");
    CHECK(import_target_name("/data/x/a.zip", true, "") == "a");
    CHECK(import_target_name("/data/x/A.ZIP", true, "") == "A");
    CHECK(import_target_name("whatever.zip", true, "Alias") == "Alias");
    CHECK(import_target_name("bad:name", false, "") == "");
    // Nested source paths are NORMAL (./mods/MyMod or C:\a\b\MyMod): the
    // target is basename semantics (Python Path(src).name parity), so the
    // last segment "name" is a fine directory name. Separator characters
    // can never survive into a computed basename; they only matter for the
    // explicit --name override, screened by the illegal set below.
    CHECK(import_target_name("bad/name", false, "") == "name");
    CHECK(import_target_name("x", false, "a/b") == "");  // override with slash rejected
    CHECK(import_target_name("", true, "") == "");
    CHECK(import_target_name("x", false, "..") == "");
}

TEST_CASE("p7 zip_entry_reject screens traversal and absolute paths", "[p7]") {
    CHECK_FALSE(zip_entry_reject("Cfgs/zh-cn/EvtCfg.json"));
    CHECK_FALSE(zip_entry_reject("manifest.json"));
    CHECK_FALSE(zip_entry_reject("Cfgs\\zh-cn\\x.json"));  // backslash normalizes
    CHECK(zip_entry_reject("../evil.json"));
    CHECK(zip_entry_reject("Cfgs/../../evil.json"));
    CHECK(zip_entry_reject("/abs/path.json"));
    CHECK(zip_entry_reject("C:/Windows/x"));
    CHECK(zip_entry_reject("a\\..\\b"));
    CHECK(zip_entry_reject(""));
}

TEST_CASE("p7 misc helpers: csv / json / usage text", "[p7]") {
    auto v = split_csv(" a , ,b,");
    REQUIRE(v.size() == 2);
    CHECK(v[0] == "a");
    CHECK(v[1] == "b");
    json j;
    std::string e;
    CHECK(parse_json_arg("{\"k\":1}", j, e));
    CHECK_FALSE(parse_json_arg("{", j, e));
    CHECK_FALSE(usage_text().empty());
    CHECK(usage_text().find("--data-root") != std::string::npos);
    CHECK(usage_text().find("bugfix") != std::string::npos);
}

// ---------------------------------------------------------------------------
// plugin / cloud / ai (GUI-parity surface added on top of the wave-1 set)
// ---------------------------------------------------------------------------

TEST_CASE("p7 parse: plugin/cloud/ai command families", "[p7]") {
    CHECK(run({"plugin", "list"}).c.kind == Kind::PluginList);
    CHECK(run({"plugin", "reload"}).c.kind == Kind::PluginReload);
    CHECK(run({"plugin", "tools"}).c.kind == Kind::PluginTools);
    CHECK(run({"plugin", "install", "p.zip"}).c.kind == Kind::PluginInstall);
    CHECK(run({"plugin", "uninstall", "demo"}).c.kind == Kind::PluginUninstall);
    CHECK(run({"plugin", "install"}).r == ParseResult::UsageError);       // zip required
    CHECK(run({"plugin", "uninstall"}).r == ParseResult::UsageError);     // id required

    CHECK(run({"cloud", "providers"}).c.kind == Kind::CloudProviders);
    CHECK(run({"cloud", "status"}).c.kind == Kind::CloudStatus);
    CHECK(run({"cloud", "drivers"}).c.kind == Kind::CloudDrivers);
    CHECK(run({"cloud", "local"}).c.kind == Kind::CloudLocal);
    CHECK(run({"cloud", "remove", "p_1"}).c.kind == Kind::CloudRemove);
    CHECK(run({"cloud", "remove"}).r == ParseResult::UsageError);
    CHECK(run({"cloud", "remote", "p_1"}).c.kind == Kind::CloudRemote);
    CHECK(run({"cloud", "remote"}).r == ParseResult::UsageError);

    CHECK(run({"ai", "settings"}).c.kind == Kind::AiSettings);
    CHECK(run({"ai", "set", "--mode", "full"}).c.kind == Kind::AiSet);
    CHECK(run({"ai", "set"}).r == ParseResult::UsageError);               // nothing to set
}

TEST_CASE("p7 parse: cloud test / sync / ai set guards", "[p7]") {
    // cloud test: provider id XOR --type.
    auto by_id = run({"cloud", "test", "p_1"});
    REQUIRE(by_id.r == ParseResult::Ok);
    CHECK(by_id.c.provider_id == "p_1");
    auto by_type = run({"cloud", "test", "--type", "webdav", "--config", "{\"url\":\"u\"}"});
    REQUIRE(by_type.r == ParseResult::Ok);
    CHECK(by_type.c.provider_type == "webdav");
    CHECK(by_type.c.has_provider_config);
    CHECK(run({"cloud", "test"}).r == ParseResult::UsageError);

    // sync: direction is mandatory and validated, and is lowercased.
    CHECK(run({"cloud", "sync", "p_1"}).r == ParseResult::UsageError);
    CHECK(run({"cloud", "sync", "p_1", "--direction", "sideways"}).r == ParseResult::UsageError);
    auto up = run({"cloud", "sync", "p_1", "--direction", "UPLOAD", "--dry-run", "--files",
                   " a.json , b/c.json "});
    REQUIRE(up.r == ParseResult::Ok);
    CHECK(up.c.direction == "upload");
    CHECK(up.c.dry_run);
    CHECK(up.c.files_txt == " a.json , b/c.json ");

    // ai set: mode vocabulary + case folding.
    auto m = run({"ai", "set", "--mode", "FULL"});
    REQUIRE(m.r == ParseResult::Ok);
    CHECK(m.c.direction == "full");
    CHECK(run({"ai", "set", "--mode", "yolo"}).r == ParseResult::UsageError);
    CHECK(run({"ai", "set", "--data", "[1]"}).r == ParseResult::UsageError);  // not an object
    CHECK(run({"cloud", "add", "--config", "[1]"}).r == ParseResult::UsageError);
    CHECK(run({"oobe", "setup", "--cloud-provider", "5"}).r == ParseResult::UsageError);
}

TEST_CASE("p7 plan: plugin commands hit the real plugin routes", "[p7]") {
    auto l = run({"plugin", "list"});
    auto lp = plan(l.c);
    REQUIRE(lp.ok);
    CHECK(lp.reqs[0].method == "GET");
    CHECK(lp.reqs[0].path == "/api/plugins");

    auto t = run({"plugin", "tools"});
    auto tp = plan(t.c);
    REQUIRE(tp.ok);
    CHECK(tp.reqs[0].path == "/api/plugins/agent/tools");

    auto rl = run({"plugin", "reload"});
    auto rlp = plan(rl.c);
    REQUIRE(rlp.ok);
    CHECK(rlp.reqs[0].method == "POST");
    CHECK(rlp.reqs[0].path == "/api/plugins/reload");

    // install: local path form (no base64), filename only when --name is given.
    auto i1 = run({"plugin", "install", "C:/tmp/demo.zip"});
    auto i1p = plan(i1.c);
    REQUIRE(i1p.ok);
    CHECK(i1p.reqs[0].method == "POST");
    CHECK(i1p.reqs[0].path == "/api/plugins/install_path");
    CHECK(i1p.reqs[0].body["path"] == "C:/tmp/demo.zip");
    CHECK_FALSE(i1p.reqs[0].body.contains("filename"));

    auto i2 = run({"plugin", "install", "C:/tmp/My.Plugin.zip", "--name", "My.Plugin.zip"});
    auto i2p = plan(i2.c);
    REQUIRE(i2p.ok);
    CHECK(i2p.reqs[0].body["filename"] == "My.Plugin.zip");

    auto un = run({"plugin", "uninstall", "demo"});
    auto unp = plan(un.c);
    REQUIRE(unp.ok);
    CHECK(unp.reqs[0].method == "DELETE");
    CHECK(unp.reqs[0].path == "/api/plugins/demo");
}

TEST_CASE("p7 plan: cloud commands hit the real cloud routes", "[p7]") {
    auto p = run({"cloud", "providers"});
    auto pp = plan(p.c);
    REQUIRE(pp.ok);
    CHECK(pp.reqs[0].path == "/api/cloud/providers");

    auto a = run({"cloud", "add", "--name", "Drive", "--type", "webdav",
                  "--config", "{\"url\":\"u\"}", "--remote-root", "mods"});
    auto ap = plan(a.c);
    REQUIRE(ap.ok);
    CHECK(ap.reqs[0].method == "POST");
    CHECK(ap.reqs[0].path == "/api/cloud/providers");
    CHECK(ap.reqs[0].body["name"] == "Drive");
    CHECK(ap.reqs[0].body["type"] == "webdav");
    CHECK(ap.reqs[0].body["config"]["url"] == "u");
    CHECK(ap.reqs[0].body["remote_root"] == "mods");
    // Nothing to add at all is a plan error, not an empty POST.
    auto none = run({"cloud", "add"});
    CHECK(!plan(none.c).ok);

    auto u = run({"cloud", "update", "p_1", "--name", "New"});
    auto up = plan(u.c);
    REQUIRE(up.ok);
    CHECK(up.reqs[0].method == "PUT");
    CHECK(up.reqs[0].path == "/api/cloud/providers/p_1");
    CHECK(up.reqs[0].body["name"] == "New");
    CHECK_FALSE(up.reqs[0].body.contains("type"));
    auto uempty = run({"cloud", "update", "p_1"});
    CHECK(!plan(uempty.c).ok);

    auto rm = run({"cloud", "remove", "p_1"});
    auto rmp = plan(rm.c);
    REQUIRE(rmp.ok);
    CHECK(rmp.reqs[0].method == "DELETE");
    CHECK(rmp.reqs[0].path == "/api/cloud/providers/p_1");

    auto t_id = run({"cloud", "test", "p_1"});
    auto t_idp = plan(t_id.c);
    REQUIRE(t_idp.ok);
    CHECK(t_idp.reqs[0].path == "/api/cloud/test");
    CHECK(t_idp.reqs[0].body["provider_id"] == "p_1");
    CHECK_FALSE(t_idp.reqs[0].body.contains("type"));
    auto t_ty = run({"cloud", "test", "--type", "local"});
    auto t_typ = plan(t_ty.c);
    REQUIRE(t_typ.ok);
    CHECK(t_typ.reqs[0].body["type"] == "local");
    CHECK(t_typ.reqs[0].body["config"].is_object());

    // sync: folder mode when no --files, file mode when --files is supplied.
    auto sf = run({"cloud", "sync", "p_1", "--direction", "sync", "--delete-extra"});
    auto sfp = plan(sf.c);
    REQUIRE(sfp.ok);
    CHECK(sfp.reqs[0].path == "/api/cloud/sync");
    CHECK(sfp.reqs[0].body["provider_id"] == "p_1");
    CHECK(sfp.reqs[0].body["direction"] == "sync");
    CHECK(sfp.reqs[0].body["folder"] == true);
    CHECK(sfp.reqs[0].body["delete_extra"] == true);
    CHECK_FALSE(sfp.reqs[0].body.contains("files"));

    auto sfl = run({"cloud", "sync", "p_1", "--direction", "upload", "--files", "a.json,b.json"});
    auto sflp = plan(sfl.c);
    REQUIRE(sflp.ok);
    CHECK(sflp.reqs[0].body["files"] == json::array({"a.json", "b.json"}));
    CHECK_FALSE(sflp.reqs[0].body.contains("folder"));

    auto st = run({"cloud", "status"});
    auto stp = plan(st.c);
    REQUIRE(stp.ok);
    CHECK(stp.reqs[0].path == "/api/cloud/status");

    auto dr = run({"cloud", "drivers"});
    auto drp = plan(dr.c);
    REQUIRE(drp.ok);
    CHECK(drp.reqs[0].path == "/api/cloud/drivers");

    auto lo = run({"cloud", "local", "--mod", "M"});
    auto lop = plan(lo.c);
    REQUIRE(lop.ok);
    CHECK(lop.reqs[0].path == "/api/cloud/local_files");
    REQUIRE(lop.reqs[0].query.size() == 1);
    CHECK(lop.reqs[0].query[0] == std::make_pair(std::string("mod_name"), std::string("M")));

    auto re = run({"cloud", "remote", "p_1", "--mod", "M", "--path", "sub"});
    auto rep = plan(re.c);
    REQUIRE(rep.ok);
    CHECK(rep.reqs[0].path == "/api/cloud/list");
    REQUIRE(rep.reqs[0].query.size() == 4);
    CHECK(rep.reqs[0].query[0] == std::make_pair(std::string("provider_id"), std::string("p_1")));
    CHECK(rep.reqs[0].query[1] == std::make_pair(std::string("mod_name"), std::string("M")));
    CHECK(rep.reqs[0].query[2] == std::make_pair(std::string("path"), std::string("sub")));
    CHECK(rep.reqs[0].query[3] == std::make_pair(std::string("recursive"), std::string("1")));
}

TEST_CASE("p7 plan: ai settings read/write and --file merge", "[p7]") {
    auto g = run({"ai", "settings"});
    auto gp = plan(g.c);
    REQUIRE(gp.ok);
    CHECK(gp.reqs[0].method == "GET");
    CHECK(gp.reqs[0].path == "/api/ai/settings");

    auto m = run({"ai", "set", "--mode", "full"});
    auto mp = plan(m.c);
    REQUIRE(mp.ok);
    CHECK(mp.reqs[0].method == "PUT");
    CHECK(mp.reqs[0].path == "/api/ai/settings");
    CHECK(mp.reqs[0].body == json{{"permissionMode", "full"}});

    auto d = run({"ai", "set", "--mode", "confirm", "--data", "{\"model\":\"m1\"}"});
    auto dp = plan(d.c);
    REQUIRE(dp.ok);
    CHECK(dp.reqs[0].body["permissionMode"] == "confirm");
    CHECK(dp.reqs[0].body["model"] == "m1");

    std::string f = tmp_file("ai.json", "\xEF\xBB\xBF{\"ttsVoice\":\"v1\"}");  // BOM tolerated
    auto ff = run({"ai", "set", "--file", f});
    auto ffp = plan(ff.c);
    REQUIRE(ffp.ok);
    CHECK(ffp.reqs[0].body["ttsVoice"] == "v1");

    std::string bad = tmp_file("ai_bad.json", "[1]");
    auto bf = run({"ai", "set", "--file", bad});
    REQUIRE(bf.r == ParseResult::Ok);
    CHECK(!plan(bf.c).ok);
}

TEST_CASE("p7 plan: cloud add merges --config-file over --config", "[p7]") {
    std::string f = tmp_file("drv.json", "{\"username\":\"u\",\"password\":\"p\"}");
    auto a = run({"cloud", "add", "--type", "webdav", "--config", "{\"url\":\"https://x\"}",
                  "--config-file", f});
    REQUIRE(a.r == ParseResult::Ok);
    auto ap = plan(a.c);
    REQUIRE(ap.ok);
    CHECK(ap.reqs[0].body["config"]["url"] == "https://x");
    CHECK(ap.reqs[0].body["config"]["username"] == "u");
    CHECK(ap.reqs[0].body["config"]["password"] == "p");

    std::string bad = tmp_file("drv_bad.json", "[]");
    auto b = run({"cloud", "add", "--type", "webdav", "--config-file", bad});
    REQUIRE(b.r == ParseResult::Ok);
    CHECK(!plan(b.c).ok);
}

TEST_CASE("p7 plan: oobe setup composes ai + cloud follow-ups", "[p7]") {
    // Bare setup stays a single request (unchanged wave-1 contract).
    auto bare = run({"oobe", "setup", "--workspace", "W"});
    auto barep = plan(bare.c);
    REQUIRE(barep.ok);
    REQUIRE(barep.reqs.size() == 1);
    CHECK(barep.reqs[0].path == "/api/oobe/setup");

    // With --ai/--cloud-provider the backend setup route drops them on the
    // floor, so the CLI appends real follow-up requests in order.
    auto full = run({"oobe", "setup", "--workspace", "W", "--mod", "M",
                     "--ai", "{\"permissionMode\":\"full\"}",
                     "--cloud-provider", "{\"name\":\"D\",\"type\":\"local\"}"});
    auto fullp = plan(full.c);
    REQUIRE(fullp.ok);
    REQUIRE(fullp.reqs.size() == 3);
    CHECK(fullp.reqs[0].path == "/api/oobe/setup");
    CHECK(fullp.reqs[0].body["mod_title"] == "M");
    CHECK(fullp.reqs[1].method == "PUT");
    CHECK(fullp.reqs[1].path == "/api/ai/settings");
    CHECK(fullp.reqs[1].body["settings"]["permissionMode"] == "full");
    CHECK(fullp.reqs[2].method == "POST");
    CHECK(fullp.reqs[2].path == "/api/cloud/providers");
    CHECK(fullp.reqs[2].body["type"] == "local");  // provider object IS the body
}

TEST_CASE("p7 format_text: plugin renderers", "[p7]") {
    Command lc;
    lc.kind = Kind::PluginList;
    json p1{{"id", "demo"},
            {"name", "Demo Plugin"},
            {"version", "1.2.3"},
            {"author", "me"},
            {"description", "desc"},
            {"loaded", true},
            {"error", ""}};
    json p2{{"id", "broken"}, {"name", "Broken"}, {"loaded", false}, {"error", "boom"}};
    auto ls = format_text(lc, json{{"plugins", json::array({p1, p2})}});
    CHECK(ls.find("plugins: 2") != std::string::npos);
    CHECK(ls.find("demo  Demo Plugin v1.2.3  已加载") != std::string::npos);
    CHECK(ls.find("author=me") != std::string::npos);
    CHECK(ls.find("broken  Broken  未加载  error=boom") != std::string::npos);
    CHECK(format_text(lc, json{{"plugins", json::array()}}).find("plugins: 0") != std::string::npos);

    Command ic;
    ic.kind = Kind::PluginInstall;
    auto is = format_text(ic, json{{"ok", true}, {"id", "demo"}, {"plugin", p1}});
    CHECK(is.find("installed: demo") != std::string::npos);
    CHECK(is.find("Demo Plugin") != std::string::npos);

    Command uc;
    uc.kind = Kind::PluginUninstall;
    CHECK(format_text(uc, json{{"ok", true}}) == "ok: uninstalled\n");

    Command rc;
    rc.kind = Kind::PluginReload;
    CHECK(format_text(rc, json{{"ok", true}, {"plugins", json::array({p1})}})
              .find("ok: reloaded  plugins: 1") != std::string::npos);

    Command tc;
    tc.kind = Kind::PluginTools;
    json tool{{"name", "do_thing"}, {"plugin_id", "demo"}, {"confirm", true}, {"description", "d"}};
    auto ts = format_text(tc, json{{"tools", json::array({tool})}});
    CHECK(ts.find("tools: 1") != std::string::npos);
    CHECK(ts.find("do_thing  plugin=demo  confirm") != std::string::npos);
}

TEST_CASE("p7 format_text: cloud renderers", "[p7]") {
    Command pc;
    pc.kind = Kind::CloudProviders;
    json prov{{"id", "p_1"}, {"name", "Drive"}, {"type", "webdav"}, {"remote_root", "mods"}};
    auto ps = format_text(
        pc, json{{"providers", json::array({prov})}, {"drivers", json::array({"local", "webdav"})}});
    CHECK(ps.find("providers: 1") != std::string::npos);
    CHECK(ps.find("p_1  Drive  [webdav]  remote_root=mods") != std::string::npos);
    CHECK(ps.find("drivers: local webdav") != std::string::npos);

    Command ac;
    ac.kind = Kind::CloudAdd;
    CHECK(format_text(ac, json{{"provider", prov}}).find("provider: p_1  Drive  [webdav]")
          != std::string::npos);
    Command upc;
    upc.kind = Kind::CloudUpdate;
    CHECK(format_text(upc, json{{"provider", prov}}).find("provider: p_1") != std::string::npos);
    Command rmc;
    rmc.kind = Kind::CloudRemove;
    CHECK(format_text(rmc, json{{"ok", true}}) == "ok: removed\n");
    Command tsc;
    tsc.kind = Kind::CloudTest;
    CHECK(format_text(tsc, json{{"ok", true}}) == "ok: connection ok\n");

    Command sc;
    sc.kind = Kind::CloudStatus;
    json hist{{"time", "T"}, {"provider", "p_1"}, {"mod", "M"}, {"direction", "upload"}, {"count", 3}};
    auto ss = format_text(sc, json{{"running", true},
                                   {"action", "upload"},
                                   {"progress", 1},
                                   {"total", 4},
                                   {"history", json::array({hist})}});
    CHECK(ss.find("running: true") != std::string::npos);
    CHECK(ss.find("progress: 1/4") != std::string::npos);
    CHECK(ss.find("T  p_1  M  upload  count=3") != std::string::npos);

    Command dc;
    dc.kind = Kind::CloudDrivers;
    json drv{{"webdav", json{{"url", ""}, {"username", ""}}}};
    auto ds = format_text(dc, json{{"drivers", drv}});
    CHECK(ds.find("drivers: 1") != std::string::npos);
    CHECK(ds.find("webdav: url username") != std::string::npos);

    Command loc;
    loc.kind = Kind::CloudLocal;
    json ent{{"name", "Cfgs/zh-cn/EvtCfg.json"}, {"type", "file"}, {"size", 12}};
    auto los = format_text(loc, json{{"mod", "M"},
                                     {"root", "R"},
                                     {"entries", json::array({ent})},
                                     {"count", 1}});
    CHECK(los.find("mod: M  root: R") != std::string::npos);
    CHECK(los.find("files: 1") != std::string::npos);
    CHECK(los.find("Cfgs/zh-cn/EvtCfg.json  12B") != std::string::npos);

    Command rem;
    rem.kind = Kind::CloudRemote;
    json o1{{"name", "a.json"}, {"path", "mods/a.json"}, {"is_dir", false}, {"size", 5}};
    json o2{{"name", "d"}, {"path", "mods/d"}, {"is_dir", true}, {"size", 0}};
    auto rs = format_text(rem, json{{"remote", "mods"},
                                    {"objects", json::array({o1, o2})}});
    CHECK(rs.find("remote: mods") != std::string::npos);
    CHECK(rs.find("objects: 2") != std::string::npos);
    CHECK(rs.find("mods/a.json  5B") != std::string::npos);
    CHECK(rs.find("mods/d/  0B") != std::string::npos);
}

TEST_CASE("p7 format_text: cloud sync folder + single-file shapes", "[p7]") {
    Command sc;
    sc.kind = Kind::CloudSync;
    json r1{{"rel", "a.json"}, {"ok", true}, {"action", "upload_new"}};
    json r2{{"rel", "b.json"}, {"ok", true}, {"action", "skip_unchanged"}};
    json r3{{"rel", "c.json"}, {"ok", false}, {"action", ""}, {"error", "boom"}};
    auto s = format_text(sc, json{{"direction", "upload"},
                                  {"dry_run", true},
                                  {"total", 3},
                                  {"results", json::array({r1, r2, r3})}});
    CHECK(s.find("direction: upload  dry_run: true") != std::string::npos);
    CHECK(s.find("total: 3") != std::string::npos);
    CHECK(s.find("[ok] upload_new  a.json") != std::string::npos);
    CHECK(s.find("summary: upload=1 download=0 skip=1 failed=1") != std::string::npos);
    CHECK(s.find("error=boom") != std::string::npos);

    // Single-file dry-run shape (no results[]).
    auto one = format_text(sc, json{{"dry_run", true},
                                    {"local_exists", true},
                                    {"remote_exists", false},
                                    {"direction", "upload"},
                                    {"remote", "mods/a.json"}});
    CHECK(one.find("local_exists: true  remote_exists: false") != std::string::npos);
    CHECK(one.find("remote: mods/a.json") != std::string::npos);
}

TEST_CASE("p7 format_text: ai settings + bugfix flag grouping", "[p7]") {
    Command ac;
    ac.kind = Kind::AiSettings;
    auto as = format_text(ac, json{{"settings", json{{"permissionMode", "full"},
                                                    {"provider", "openai_compatible"},
                                                    {"baseUrl", ""},
                                                    {"model", "m"},
                                                    {"temperature", 0.7}}}});
    CHECK(as.find("permissionMode: full") != std::string::npos);
    CHECK(as.find("provider: openai_compatible") != std::string::npos);

    Command sc;
    sc.kind = Kind::AiSet;
    auto ss = format_text(sc, json{{"ok", true}, {"settings", json{{"permissionMode", "confirm"}}}});
    CHECK(ss.find("ok: settings updated") != std::string::npos);
    CHECK(ss.find("permissionMode: confirm") != std::string::npos);
    // A shape without settings still renders (no throw).
    CHECK(format_text(sc, json{{"ok", true}}).find("ok: settings updated") != std::string::npos);

    Command bc;
    bc.kind = Kind::BugfixScan;
    json b1{{"flag", "LOGIC"}, {"cfg", "T"}, {"id", 1}, {"key", "k"}, {"desc", "d1"}};
    json b2{{"flag", "ERROR"}, {"cfg", "T"}, {"id", 2}, {"key", "k"}, {"desc", "d2"}};
    json b3{{"flag", "LOGIC"}, {"cfg", "T"}, {"id", 3}, {"key", "k"}, {"desc", "d3"}};
    auto bs = format_text(bc, json{{"bugs", json::array({b1, b2, b3})}, {"count", 3}});
    CHECK(bs.find("count: 3") != std::string::npos);
    CHECK(bs.find("by_flag: LOGIC=2 ERROR=1") != std::string::npos);

    Command fc;
    fc.kind = Kind::BugfixFix;
    auto fs = format_text(fc, json{{"fixed", 1},
                                   {"remaining_count", 1},
                                   {"remaining", json::array({b1})}});
    CHECK(fs.find("fixed: 1  remaining: 1") != std::string::npos);
    CHECK(fs.find("remaining [LOGIC] T#1.k") != std::string::npos);
}

// ------------------------------------------------ Alpha-v0.3 UI restoration
TEST_CASE("p7 parse: search command plans GET /api/search/talk", "[p7]") {
    auto s = run({"search", "你好"});
    REQUIRE(s.r == ParseResult::Ok);
    REQUIRE(s.c.kind == Kind::Search);
    Planned p;
    p.ok = make_plan(s.c, p.reqs, p.err);
    REQUIRE(p.ok);
    REQUIRE(p.reqs.size() == 1);
    REQUIRE(p.reqs[0].method == "GET");
    REQUIRE(p.reqs[0].path == "/api/search/talk");
    REQUIRE(p.reqs[0].query.size() == 1);
    REQUIRE(p.reqs[0].query[0].first == "q");
    REQUIRE(p.reqs[0].query[0].second == "你好");

    // The renderer lists hits (src/talk_id/title/content) and respects --limit.
    Command sc = s.c;
    json body{{"results",
               json::array({json{{"src", "Mod"},
                                 {"evt_id", "101"},
                                 {"evt_title", "开学"},
                                 {"talk_id", "101001"},
                                 {"content", "你好，同学"}}})}};
    auto out = format_text(sc, body);
    CHECK(out.find("hits: 1") != std::string::npos);
    CHECK(out.find("[Mod]") != std::string::npos);
    CHECK(out.find("101001") != std::string::npos);
    CHECK(out.find("你好，同学") != std::string::npos);
}

TEST_CASE("p7 parse: repl is a first-class subcommand", "[p7]") {
    auto s = run({"repl"});
    REQUIRE(s.r == ParseResult::Ok);
    REQUIRE(s.c.kind == Kind::Repl);
}

TEST_CASE("p7 color: --color/--no-color set the mode flag", "[p7]") {
    auto on = run({"--color", "mods", "list"});
    REQUIRE(on.r == ParseResult::Ok);
    REQUIRE(on.g.color == 1);
    auto off = run({"--no-color", "mods", "list"});
    REQUIRE(off.r == ParseResult::Ok);
    REQUIRE(off.g.color == 0);
    // Auto (absent) stays -1; the TTY probe happens in Style::Init at runtime.
    auto auto_ = run({"mods", "list"});
    REQUIRE(auto_.g.color == -1);
}

TEST_CASE("p7 color: disabled styling is the identity, forced styling wraps",
          "[p7]") {
    // Tests and pipes run with styling off: plain text must stay byte-identical.
    REQUIRE(Style::Enabled() == false);
    CHECK(Style::Green("ok") == "ok");
    CHECK(Style::BoldGreen("id") == "id");
    CHECK(Style::Wrap("1", "") == "");

    Style::Init(1);  // force on
    CHECK(Style::Enabled());
    CHECK(Style::Green("ok") == "\x1b[32mok\x1b[0m");
    CHECK(Style::BoldCyan("›") == "\x1b[1;36m›\x1b[0m");
    Style::Init(0);  // force off again — later cases keep seeing plain text
    CHECK_FALSE(Style::Enabled());
    CHECK(Style::Green("ok") == "ok");
}

TEST_CASE("p7 repl: classify_repl_line sorts the input vocabulary", "[p7]") {
    auto empty = classify_repl_line("   ");
    CHECK(empty.kind == ReplLine::Empty);

    auto quit1 = classify_repl_line("/exit");
    CHECK(quit1.kind == ReplLine::Quit);
    CHECK(classify_repl_line("/quit").kind == ReplLine::Quit);
    CHECK(classify_repl_line("/q").kind == ReplLine::Quit);
    CHECK(classify_repl_line("exit").kind == ReplLine::Quit);
    CHECK(classify_repl_line("quit").kind == ReplLine::Quit);
    CHECK(classify_repl_line("q").kind == ReplLine::Quit);

    auto shell = classify_repl_line("  !git status");
    CHECK(shell.kind == ReplLine::Shell);
    CHECK(shell.payload == "git status");

    auto slash = classify_repl_line("/mods list");
    CHECK(slash.kind == ReplLine::Slash);
    CHECK(slash.payload == "mods list");

    auto plain = classify_repl_line("mods list --all");
    CHECK(plain.kind == ReplLine::Command);
    CHECK(plain.payload == "mods list --all");
}

TEST_CASE("p7 repl: split_repl_tokens is quote-aware", "[p7]") {
    CHECK(split_repl_tokens("").empty());
    auto a = split_repl_tokens("mods create \"我的 模组\" --desc x");
    REQUIRE(a.size() == 5);
    CHECK(a[0] == "mods");
    CHECK(a[1] == "create");
    CHECK(a[2] == "我的 模组");
    CHECK(a[3] == "--desc");
    CHECK(a[4] == "x");
    auto b = split_repl_tokens("  spaced\t tokens  ");
    REQUIRE(b.size() == 2);
    CHECK(b[0] == "spaced");
    CHECK(b[1] == "tokens");
    auto c = split_repl_tokens("'quoted arg'");
    REQUIRE(c.size() == 1);
    CHECK(c[0] == "quoted arg");
}

// ---------------------------------------------------------------------------
// 无代码模式 + 自动补全（M3）：settings 命令族 + ReplComplete 词法槽分流
// ---------------------------------------------------------------------------

TEST_CASE("p7 parse: settings no-code on|off|show", "[p7]") {
    auto on = run({"settings", "no-code", "on"});
    REQUIRE(on.r == ParseResult::Ok);
    CHECK(on.c.kind == Kind::SettingsNoCode);
    CHECK(on.c.setting_value == "on");

    // 别名 nocode + 大小写归一。
    auto off = run({"settings", "nocode", "OFF"});
    REQUIRE(off.r == ParseResult::Ok);
    CHECK(off.c.setting_value == "off");
    CHECK(run({"settings", "no-code", "show"}).c.setting_value == "show");

    CHECK(run({"settings", "no-code"}).r == ParseResult::UsageError);   // 缺取值
    CHECK(run({"settings", "no-code", "maybe"}).r == ParseResult::UsageError);
    CHECK(run({"settings"}).r == ParseResult::UsageError);              // 缺子命令
}

TEST_CASE("p7 plan: settings no-code is a GET or a flat PUT", "[p7]") {
    auto show = run({"settings", "no-code", "show"});
    auto ps = plan(show.c);
    REQUIRE(ps.ok);
    REQUIRE(ps.reqs.size() == 1);
    CHECK(ps.reqs[0].method == "GET");
    CHECK(ps.reqs[0].path == "/api/settings/editor");
    CHECK(ps.reqs[0].body.is_null());

    auto on = run({"settings", "no-code", "on"});
    auto po = plan(on.c);
    REQUIRE(po.ok);
    REQUIRE(po.reqs.size() == 1);
    CHECK(po.reqs[0].method == "PUT");
    CHECK(po.reqs[0].path == "/api/settings/editor");
    CHECK(po.reqs[0].body == json{{"noCodeMode", true}});

    auto off = run({"settings", "no-code", "off"});
    auto pf = plan(off.c);
    REQUIRE(pf.ok);
    CHECK(pf.reqs[0].body == json{{"noCodeMode", false}});

    // 纯请求构造器（REPL /settings 复用）。
    CHECK(editor_settings_get_request().path == "/api/settings/editor");
    CHECK(editor_settings_put_request(true).body == json{{"noCodeMode", true}});
    CHECK(editor_settings_put_request(false).body == json{{"noCodeMode", false}});
}

TEST_CASE("p7 format_text: settings no-code shows the current value", "[p7]") {
    auto show = run({"settings", "no-code", "show"});
    auto on = run({"settings", "no-code", "on"});
    CHECK(format_text(show.c, json{{"settings", json{{"noCodeMode", true}}}}) == "no-code: on\n");
    CHECK(format_text(show.c, json{{"settings", json{{"noCodeMode", false}}}}) ==
          "no-code: off\n");
    CHECK(format_text(on.c, json{{"ok", true}, {"settings", json{{"noCodeMode", true}}}}) ==
          "ok: no-code: on\n");
    CHECK(format_text(on.c, json{{"settings", json{{"noCodeMode", false}}}}) ==
          "ok: no-code: off\n");
    // 响应不是 settings 信封：原样 dump，不假装知道。
    CHECK(format_text(show.c, json{{"weird", 1}}).find("weird") != std::string::npos);

    bool known = true;
    CHECK(parse_no_code_mode(json{{"settings", json{{"noCodeMode", true}}}}, &known) == true);
    CHECK(known);
    CHECK(parse_no_code_mode(json{{"settings", json{{"noCodeMode", "yes"}}}}, &known) == false);
    CHECK_FALSE(known);
    CHECK(parse_no_code_mode(json::object(), nullptr) == false);
}

TEST_CASE("p7 completion: FuzzyScore ranks prefix > substring > subsequence", "[p7]") {
    CHECK(FuzzyScore("cf", "cfg") == 100);
    CHECK(FuzzyScore("fg", "cfg") == 60);
    CHECK(FuzzyScore("cg", "cfg") == 30);  // 子序列
    CHECK(FuzzyScore("xyz", "cfg") == 0);
    CHECK(FuzzyScore("", "cfg") == 1);  // 空查询 = 全命中（最低分）
    CHECK(FuzzyScore("CFG", "cfg") == 100);  // ASCII 大小写不敏感
    CHECK(FuzzyScore("Cfg", "CFG") == 100);
    // 中文按 UTF-8 字节：前缀 / 包含 / 跨码点子序列 / 不匹配。
    CHECK(FuzzyScore("移除", "移除状态") == 100);
    CHECK(FuzzyScore("除状", "移除状态") == 60);
    CHECK(FuzzyScore("状态移", "移除状态") == 0);
    CHECK(FuzzyScore("不存在", "移除状态") == 0);
}

TEST_CASE("p7 completion: command tree mirrors wire_app", "[p7]") {
    auto has = [](const std::vector<CompletionItem>& v, const std::string& s) {
        for (const auto& i : v)
            if (i.value == s) return true;
        return false;
    };
    auto cmds = top_level_commands();
    CHECK(has(cmds, "cfg"));
    CHECK(has(cmds, "settings"));
    CHECK(has(command_subcommands("cfg"), "patch"));
    CHECK(has(command_subcommands("settings"), "no-code"));
    CHECK(has(command_subcommands("cloud"), "providers"));
    CHECK(command_subcommands("nope").empty());
    // flag 池含命令自己的 flag + 全局 fallthrough flag。
    CHECK(has(command_flags("cfg", "get"), "--id"));
    CHECK(has(command_flags("cfg", "get"), "--json"));
    CHECK(has(command_flags("settings", "no-code"), "--mod"));
    CHECK(has(literal_values("no_code"), "on"));
    CHECK(has(literal_values("direction"), "upload"));
}

TEST_CASE("p7 completion: ReplComplete routes lexical slots to the right pool", "[p7]") {
    CompletionCtx ctx;
    ctx.commands = {{"cfg", "配置表"}, {"mods", "模组管理"}, {"story", "剧情"}};
    ctx.slash_commands = {{"/cfg", "配置表 CRUD"}, {"/mods", "模组管理"}};
    ctx.subcommands = {{"get", "读取"}, {"set", "写入"}, {"patch", "补丁"}};
    ctx.flags = {{"--id", "只看一条"}, {"--field", "只看字段"}, {"--json", "JSON"}};
    ctx.recent = {{"cfg", "配置表"}, {"mods", "模组管理"}};
    ctx.tables = {{"TalkCfg", "对白表"}, {"EvtCfg", "事件表"}};
    ctx.mods = {{"Imported", ""}, {"ZipMod", ""}};
    ctx.paths = {{"table.json", "文件"}};
    ctx.effects = {{"[1, 1, @ATTR@, V]", "移除状态"}};
    ctx.roles = {{"101", "小美"}};

    // 首词 → 命令池。
    auto c1 = ReplComplete("c", ctx);
    REQUIRE(c1.size() == 1);
    CHECK(c1[0].text == "cfg");
    CHECK(c1[0].hint == "配置表");

    // 空行 Tab → 高频命令池（hint 保留说明）。
    auto c0 = ReplComplete("", ctx);
    REQUIRE(c0.size() == 2);
    CHECK(c0[0].text == "cfg");
    CHECK(c0[1].text == "mods");

    // 斜杠首词 → 斜杠池。
    auto cs = ReplComplete("/mo", ctx);
    REQUIRE(cs.size() == 1);
    CHECK(cs[0].text == "/mods");

    // `cfg <sub>` → 子命令池。
    auto c2 = ReplComplete("cfg g", ctx);
    REQUIRE(c2.size() == 1);
    CHECK(c2[0].text == "cfg get");

    // `-` 前缀 → 当前命令 flag 池（匹配忽略前导横线）。
    auto c3 = ReplComplete("cfg get --i", ctx);
    REQUIRE(c3.size() == 2);
    CHECK(c3[0].text == "cfg get --id");
    CHECK(c3[0].hint == "只看一条");
    CHECK(c3[1].text == "cfg get --field");  // 包含匹配排在前缀后面

    // 值槽 → cfg 表名池。
    auto c4 = ReplComplete("cfg get Ta", ctx);
    REQUIRE(c4.size() == 1);
    CHECK(c4[0].text == "cfg get TalkCfg");
    CHECK(c4[0].hint == "对白表");

    // 模组槽。
    auto c5 = ReplComplete("mods select Zi", ctx);
    REQUIRE(c5.size() == 1);
    CHECK(c5[0].text == "mods select ZipMod");

    // 枚举槽（settings no-code on|off|show）。
    auto c6 = ReplComplete("settings no-code o", ctx);
    REQUIRE(c6.size() == 3);
    CHECK(c6[0].text == "settings no-code on");
    CHECK(c6[1].text == "settings no-code off");
    CHECK(c6[2].text == "settings no-code show");  // 包含匹配垫底

    // 路径槽（--out）。
    auto c7 = ReplComplete("story export --evt 101 --out tab", ctx);
    REQUIRE(c7.size() == 1);
    CHECK(c7[0].text == "story export --evt 101 --out table.json");

    // 不补全的槽（自由文本 / 数值 id）返回空。
    CHECK(ReplComplete("search 你", ctx).empty());
    CHECK(ReplComplete("cfg get TalkCfg --id 9", ctx).empty());
}

TEST_CASE("p7 completion: JSON 值槽接 effect / role 池并保留引号", "[p7]") {
    CompletionCtx ctx;
    ctx.effects = {{"[1, 1, @ATTR@, V]", "移除状态"}, {"[0, 1, V]", "判定"}};
    ctx.roles = {{"101", "小美"}};

    // 字符串内（未闭合）：中文 desc 命中，插入代码且补齐引号。
    auto e1 = ReplComplete("cfg patch TalkCfg --set {\"1\":{\"effect\":\"移除", ctx);
    REQUIRE(e1.size() == 1);
    CHECK(e1[0].text == "cfg patch TalkCfg --set {\"1\":{\"effect\":\"[1, 1, @ATTR@, V]\"");
    CHECK(e1[0].hint == "移除状态");

    // `"effect":` 后直接 Tab（无空格）：空查询给整池，并补一对引号。
    auto e2 = ReplComplete("cfg patch TalkCfg --set {\"1\":{\"effect\":", ctx);
    REQUIRE(e2.size() == 2);
    CHECK(e2[0].text == "cfg patch TalkCfg --set {\"1\":{\"effect\":\"[1, 1, @ATTR@, V]\"");
    CHECK(e2[1].text == "cfg patch TalkCfg --set {\"1\":{\"effect\":\"[0, 1, V]\"");
    auto p2 = plan_completion("cfg patch TalkCfg --set {\"1\":{\"effect\":");
    CHECK(p2.json_string);
    CHECK(p2.json_bare);

    // `"effect": ` 带空格：保留空格在行尾追加。
    auto e2b = ReplComplete("cfg patch TalkCfg --set {\"1\":{\"effect\": ", ctx);
    REQUIRE(e2b.size() == 2);
    CHECK(e2b[0].text ==
          "cfg patch TalkCfg --set {\"1\":{\"effect\": \"[1, 1, @ATTR@, V]\"");

    // 没加引号的部分值：替换掉它（键后空白原样保留）。
    auto e2c = ReplComplete("cfg patch TalkCfg --set {\"1\":{\"effect\":移除", ctx);
    REQUIRE(e2c.size() == 1);
    CHECK(e2c[0].text == "cfg patch TalkCfg --set {\"1\":{\"effect\":\"[1, 1, @ATTR@, V]\"");
    auto p2c = plan_completion("cfg patch TalkCfg --set {\"1\":{\"effect\":移除");
    CHECK(p2c.json_string);
    CHECK_FALSE(p2c.json_bare);  // 已经写了值，只替换不追加

    // 已闭合的字符串可重选。
    auto e3 = ReplComplete("cfg patch TalkCfg --set {\"1\":{\"effect\":\"判定\"", ctx);
    REQUIRE(e3.size() == 1);
    CHECK(e3[0].text == "cfg patch TalkCfg --set {\"1\":{\"effect\":\"[0, 1, V]\"");
    CHECK(plan_completion("cfg patch TalkCfg --set {\"1\":{\"effect\":\"判定\"").json_string);

    // 人物槽（roleIds/speaker）→ roles 池，value=id、hint=名字。
    auto r1 = ReplComplete("cfg patch PersonCfg --set {\"101\":{\"roleIds\":\"小", ctx);
    REQUIRE(r1.size() == 1);
    CHECK(r1[0].text == "cfg patch PersonCfg --set {\"101\":{\"roleIds\":\"101\"");
    CHECK(r1[0].hint == "小美");

    // 键不映射到任何池（title 等自由文本）：不补全。
    CHECK(ReplComplete("cfg patch TalkCfg --set {\"1\":{\"title\":\"你", ctx).empty());
}

TEST_CASE("p7 completion: plan_completion names the pool the REPL must fetch", "[p7]") {
    CHECK(plan_completion("").slot == CompletionSlot::Recent);
    CHECK(plan_completion("cf").slot == CompletionSlot::Command);
    CHECK(plan_completion("/cf").slot == CompletionSlot::SlashCommand);
    CHECK(plan_completion("cfg ").slot == CompletionSlot::Subcommand);
    CHECK(plan_completion("cfg get --i").slot == CompletionSlot::Flag);
    CHECK(plan_completion("cfg get Ta").slot == CompletionSlot::Table);
    CHECK(plan_completion("mods select Im").slot == CompletionSlot::Mod);
    CHECK(plan_completion("story export --out x").slot == CompletionSlot::Path);
    CHECK(plan_completion("settings no-code o").slot == CompletionSlot::Literal);
    CHECK(plan_completion("@ro").slot == CompletionSlot::Mention);

    auto fx = plan_completion("cfg patch T --set {\"1\":{\"effect\":\"移除");
    CHECK(fx.slot == CompletionSlot::Effect);
    CHECK(fx.effect_mode == "effect");
    auto fc = plan_completion("cfg patch T --set {\"1\":{\"condition\":\"");
    CHECK(fc.slot == CompletionSlot::Effect);
    CHECK(fc.effect_mode == "condition");
    auto fsc = plan_completion("cfg patch T --set {\"1\":{\"screenEffect\":\"");
    CHECK(fsc.effect_mode == "screen");
    auto fr = plan_completion("cfg patch T --set {\"1\":{\"speaker\":\"小");
    CHECK(fr.slot == CompletionSlot::Role);
    CHECK(plan_completion("cfg patch T --set {\"1\":{\"title\":\"x").slot ==
          CompletionSlot::None);
    // story import --text 是 effect-like 值槽（mode=effect）。
    auto ft = plan_completion("story import --start-id 1 --text 移");
    CHECK(ft.slot == CompletionSlot::Effect);
    CHECK(ft.effect_mode == "effect");
}

TEST_CASE("p7 completion: @提及扩展 @role: 并混入表/模组", "[p7]") {
    CompletionCtx ctx;
    ctx.roles = {{"101", "小美"}};
    ctx.tables = {{"TalkCfg", ""}};
    ctx.mods = {{"Imported", ""}};

    auto m1 = ReplComplete("@ro", ctx);
    REQUIRE(m1.size() == 1);
    CHECK(m1[0].text == "@role:小美");
    CHECK(m1[0].hint == "小美");

    auto m2 = ReplComplete("@role:小", ctx);
    REQUIRE(m2.size() == 1);
    CHECK(m2[0].text == "@role:小美");

    auto m3 = ReplComplete("@Tal", ctx);
    REQUIRE(m3.size() == 1);
    CHECK(m3[0].text == "@TalkCfg");

    auto m4 = ReplComplete("@Imp", ctx);
    REQUIRE(m4.size() == 1);
    CHECK(m4[0].text == "@Imported");
}

TEST_CASE("p7 completion: ReplComplete sorts by score and dedupes by text", "[p7]") {
    CompletionCtx ctx;
    ctx.commands = {{"cfg", ""}, {"cfgmod", ""}, {"mycfg", ""}};
    auto a = ReplComplete("cf", ctx);
    REQUIRE(a.size() == 3);
    CHECK(a[0].text == "cfg");     // 前缀（池内顺序保持）
    CHECK(a[1].text == "cfgmod");  // 前缀
    CHECK(a[2].text == "mycfg");   // 包含

    CompletionCtx dup;
    dup.tables = {{"Dup", ""}, {"Dup", ""}, {"Dup2", ""}};
    auto b = ReplComplete("cfg get Du", dup);
    REQUIRE(b.size() == 2);
    CHECK(b[0].text == "cfg get Dup");
    CHECK(b[1].text == "cfg get Dup2");

    // 空池 = 无候选（不抛、不编造）。
    CHECK(ReplComplete("cfg get Ta", CompletionCtx{}).empty());
}

// ---------------------------------------------------------------------------
// 检查更新（update check · GET /api/update/check）
// ---------------------------------------------------------------------------

TEST_CASE("p7 parse: update check options", "[p7]") {
    CHECK(run({"update"}).r == ParseResult::UsageError);        // check 是必需子命令
    CHECK(run({"update", "bogus"}).r == ParseResult::UsageError);

    auto d = run({"update", "check"});
    REQUIRE(d.r == ParseResult::Ok);
    CHECK(d.c.kind == Kind::UpdateCheck);
    CHECK(d.c.update_timeout == 6);  // 默认 6s
    CHECK(d.c.update_url.empty());
    CHECK(d.c.update_current.empty());

    auto o = run({"update", "check", "--timeout", "9",
                  "--update-url", "https://api.test/releases", "--current", "v1.2.3"});
    REQUIRE(o.r == ParseResult::Ok);
    CHECK(o.c.kind == Kind::UpdateCheck);
    CHECK(o.c.update_timeout == 9);
    CHECK(o.c.update_url == "https://api.test/releases");
    CHECK(o.c.update_current == "v1.2.3");
    // 子命令自己的 --timeout 不污染全局 --timeout（默认 30）。
    CHECK(o.g.timeout == 30.0);
}

TEST_CASE("p7 plan: update check builds query timeout/current/url", "[p7]") {
    auto d = run({"update", "check"});
    REQUIRE(d.r == ParseResult::Ok);
    auto dp = plan(d.c);
    REQUIRE(dp.ok);
    REQUIRE(dp.reqs.size() == 1);
    CHECK(dp.reqs[0].method == "GET");
    CHECK(dp.reqs[0].path == "/api/update/check");
    REQUIRE(dp.reqs[0].query.size() == 1);  // timeout 始终传
    CHECK(dp.reqs[0].query[0] == std::make_pair(std::string("timeout"), std::string("6")));
    CHECK(dp.reqs[0].body.is_null());

    auto o = run({"update", "check", "--timeout", "12", "--current", "v1.0.0",
                  "--update-url", "https://example.test/releases"});
    REQUIRE(o.r == ParseResult::Ok);
    auto op = plan(o.c);
    REQUIRE(op.ok);
    REQUIRE(op.reqs.size() == 1);
    REQUIRE(op.reqs[0].query.size() == 3);
    CHECK(op.reqs[0].query[0] == std::make_pair(std::string("timeout"), std::string("12")));
    CHECK(op.reqs[0].query[1] == std::make_pair(std::string("current"), std::string("v1.0.0")));
    CHECK(op.reqs[0].query[2] ==
          std::make_pair(std::string("url"), std::string("https://example.test/releases")));
    CHECK(build_url("http://127.0.0.1:8765", op.reqs[0]) ==
          "http://127.0.0.1:8765/api/update/check?timeout=12&current=v1.0.0"
          "&url=https%3A//example.test/releases");
}

TEST_CASE("p7 format_text: update check success envelope", "[p7]") {
    Command c;
    c.kind = Kind::UpdateCheck;
    json assets = json::array({json{{"name", "editor.zip"},
                                    {"url", "https://example.test/editor.zip"},
                                    {"size", 1572864}},
                               json{{"name", "extra.zip"}, {"url", "u"}, {"size", 10}}});
    json body{{"ok", true},
              {"current", "v1.0.0"},
              {"latest_tag", "v1.2.0"},
              {"latest_name", "Release 1.2.0"},
              {"prerelease", false},
              {"published_at", "2024-05-01T00:00:00Z"},
              {"html_url", "https://example.test/v1.2.0"},
              {"notes", "第一行\n第二行"},
              {"update_available", true},
              {"assets", assets}};
    auto s = format_text(c, body);
    CHECK(s.find("当前版本: v1.0.0") != std::string::npos);
    CHECK(s.find("最新版本: v1.2.0  Release 1.2.0") != std::string::npos);
    CHECK(s.find("是否需要更新: 是") != std::string::npos);
    CHECK(s.find("预发行版") == std::string::npos);  // 非预发布不标注
    CHECK(s.find("发布时间: 2024-05-01T00:00:00Z") != std::string::npos);
    CHECK(s.find("发行页: https://example.test/v1.2.0") != std::string::npos);
    CHECK(s.find("第一行") != std::string::npos);
    CHECK(s.find("第二行") != std::string::npos);
    CHECK(s.find("附件: 2") != std::string::npos);
    CHECK(s.find("editor.zip") != std::string::npos);
    CHECK(s.find("1.5MB") != std::string::npos);
    CHECK(compute_exit(200, body, c) == 0);

    // 预发行版标注 + 已是最新。
    auto pre = format_text(c, json{{"ok", true},
                                   {"current", "v1.0.0"},
                                   {"latest_tag", "v2.0.0-rc1"},
                                   {"prerelease", true},
                                   {"update_available", false}});
    CHECK(pre.find("是否需要更新: 否") != std::string::npos);
    CHECK(pre.find("预发行版: 是") != std::string::npos);

    // notes 只铺前 20 行，其余引导到发行页。
    std::string notes;
    for (int i = 0; i < 25; ++i) notes += "L" + std::to_string(i) + "\n";
    auto long_notes = format_text(c, json{{"ok", true}, {"notes", notes}});
    CHECK(long_notes.find("L19") != std::string::npos);
    CHECK(long_notes.find("L20") == std::string::npos);
    CHECK(long_notes.find("…（完整说明见发行页）") != std::string::npos);
}

TEST_CASE("p7 format_text/exit: update check failure envelope", "[p7]") {
    Command c;
    c.kind = Kind::UpdateCheck;
    json body{{"ok", false}, {"error", "network unreachable"}, {"current", "v1.0.0"}};
    auto s = format_text(c, body);
    CHECK(s.find("检查更新失败：network unreachable") != std::string::npos);
    CHECK(compute_exit(200, body, c) == 1);
    // ok 缺失（旧后端/异常体）不当作失败。
    CHECK(compute_exit(200, json{{"current", "v1.0.0"}}, c) == 0);
}

TEST_CASE("p7 completion: update check is in the help/completion tables", "[p7]") {
    auto has = [](const std::vector<CompletionItem>& v, const std::string& s) {
        for (const auto& i : v)
            if (i.value == s) return true;
        return false;
    };
    CHECK(has(top_level_commands(), "update"));
    CHECK(has(command_subcommands("update"), "check"));
    CHECK(has(command_flags("update", "check"), "--timeout"));
    CHECK(has(command_flags("update", "check"), "--update-url"));
    CHECK(has(command_flags("update", "check"), "--current"));
    CHECK(references_known_commands_only({"update", "check"}));
    // usage/help 文本里也应出现新命令（名称 + 中文说明）。
    const std::string help = usage_text();
    CHECK(help.find("update") != std::string::npos);
    CHECK(help.find("检查更新") != std::string::npos);
}
