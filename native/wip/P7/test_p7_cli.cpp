// wip/P7/test_p7_cli.cpp — pure-logic tests for the native CLI (P7).
//
// Covers the brief's focus areas: argument parsing (CLI11 -> Command),
// request planning (URL assembly + JSON bodies), output formatting and exit
// policy, plus the local import helpers. No sockets: main.cpp's embedded
// server path is black-boxed by wip/P7/smoke.py instead.
//
// Linked into sa_tests automatically via the SA_GROUP_WIP glob (wip/P7/*.cpp
// for the implementation, wip/P7/test_*.cpp here).
#include <catch_amalgamated.hpp>

#include <fstream>

#include "p7_cli_logic.h"

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
    CHECK(p.c.suffix == 4);
    CHECK(p.c.limit == 5);
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
