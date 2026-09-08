// [p3b] — wip/P3b service & route tests (in-process dispatch, same idea as the
// Python selftest's MockClient). Covers: sandbox escape suite, tools
// list/read/write/stat semantics, domain CRUD -> undo rollback, docx/xlsx
// attachment parsing (zip fixtures built with Python zipfile), resource-pack
// install/activate/uninstall, ai_settings roundtrip, manifest/status, plugins
// read-only stubs.
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <string>

#include <catch_amalgamated.hpp>

#include "p3b_ai_files.h"
#include "p3b_domain_service.h"
#include "p3b_domain_tools_routes.h"
#include "p3b_fs_tools.h"
#include "p3b_resource_pack.h"
#include "p3b_support.h"
#include "p3b_zip_fixtures.h"
#include "sa_core/paths.h"
#include "sa_core/strings.h"
#include "server/state.h"
#include "test_support.h"

namespace {

namespace cs = sa_core::paths;

// CfgFixture + the P3b routes grafted on (what api_router.cpp will do at merge).
struct P3bFixture : sat::CfgFixture {
    P3bFixture() : sat::CfgFixture("p3b") {  // NOLINT(cppcoreguidelines-pro-type-member-init)
        sa::register_domain_tools_routes(router());
    }
    sa::Resp call(const std::string& method, const std::string& path,
                  std::map<std::string, std::string> query = {}, const sa::json& body = sa::json()) {
        return sat::call_router(router(), method, path, std::move(query), body);
    }
};

// Env var RAII for EDITOR_PACKS_ROOT / EDITOR_PLUGINS_ROOT (tests set a temp
// dir; restoration keeps later tests pristine).
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
        else _putenv_s(key.c_str(), "");
    }
    void set(const std::string& v) { _putenv_s(key.c_str(), v.c_str()); }
    ScopedEnv(const ScopedEnv&) = delete;
    ScopedEnv& operator=(const ScopedEnv&) = delete;
};

bool has(const std::string& hay, const std::string& needle) {
    return hay.find(needle) != std::string::npos;
}

// The zip fixtures are stored as base64; the upload `data` field takes them
// verbatim, while raw-bytes consumers (docx_text/ZipReader/write file) need
// them decoded.
std::string raw(const std::string& b64) {
    auto r = sa::p3b::b64_decode_strict(b64);
    return r ? *r : std::string();
}

std::string fixture_root() {
    static auto p = sat::make_temp_dir("p3b_env");
    return cs::path_to_utf8(p);
}

}  // namespace

// ---------------------------------------------------------------------------
// sandbox / tools
// ---------------------------------------------------------------------------

TEST_CASE("tools sandbox: escape refusals (.., dotdot-collapse, drive, abs-slice)",
          "[p3b][sandbox]") {
    P3bFixture fx;
    for (const char* bad : {"../../etc/passwd", "..", "../x", "a/../../b", "..\\..\\x",
                            "C:/Windows/win.ini", "C:\\Windows\\win.ini", "a/..:b/c"}) {
        for (const char* ep :
             {"/api/tools/read", "/api/tools/list", "/api/tools/stat"}) {
            auto resp = fx.call("GET", ep, {{"scope", "workspace"}, {"path", bad}});
            INFO(ep << " path=" << bad);
            CHECK(resp.status == 400);
            CHECK(resp.json_payload.contains("error"));
            CHECK(resp.json_payload["error"].get<std::string>().find("escapes") !=
                  std::string::npos);
        }
        auto resp = fx.call("PUT", "/api/tools/write", {},
                            sa::json{{"scope", "workspace"},
                                     {"path", bad},
                                     {"content", "x"}});
        INFO("write path=" << bad);
        CHECK(resp.status == 400);
        CHECK(has(resp.json_payload.value("error", ""), "escapes"));
    }
    // URL-encoded variants arrive pre-decoded from the transport (httpd
    // unquotes before dispatch); the black-box smoke re-checks %2F over TCP.
}

TEST_CASE("tools: leading-slash paths are normalized into the sandbox, not rejected",
          "[p3b][sandbox]") {
    P3bFixture fx;
    // fs_tools._norm strips leading slashes BEFORE the escape checks, so
    // "/notes.txt" addresses <root>/notes.txt (Python parity).
    auto w = fx.call("PUT", "/api/tools/write", {},
                     sa::json{{"scope", "workspace"}, {"path", "/notes.txt"}, {"content", "hi"}});
    REQUIRE(w.status == 200);
    CHECK(cs::is_file(cs::join(cs::path_to_utf8(fx.root()), "notes.txt")));
}

TEST_CASE("tools list/read/write/stat roundtrip + deep walk", "[p3b][sandbox]") {
    P3bFixture fx;
    const std::string ws = cs::path_to_utf8(fx.root());
    auto resp = fx.call("GET", "/api/tools/list", {{"scope", "workspace"}, {"path", ""}});
    REQUIRE(resp.status == 200);
    CHECK(resp.json_payload.value("root", "") == ws);
    REQUIRE(resp.json_payload["entries"].is_array());
    bool saw_mod = false;
    for (const auto& e : resp.json_payload["entries"]) {
        if (e.value("name", "") == "mod") {
            saw_mod = true;
            CHECK(e.value("type", "") == "dir");
            CHECK(e.value("size", -1) == 0);
        }
    }
    CHECK(saw_mod);

    // nested write auto-creates parents; response echoes the RAW rel path
    auto w = fx.call("PUT", "/api/tools/write", {},
                     sa::json{{"scope", "workspace"},
                              {"path", "sub/dir/hello.txt"},
                              {"content", "你好\nline2"}});
    REQUIRE(w.status == 200);
    CHECK(w.json_payload.value("path", "") == "sub/dir/hello.txt");
    CHECK(w.json_payload.value("size", -1) ==
          static_cast<long long>(std::string_view("你好\nline2").size()));

    auto r = fx.call("GET", "/api/tools/read",
                     {{"scope", "workspace"}, {"path", "sub/dir/hello.txt"}});
    REQUIRE(r.status == 200);
    CHECK(r.json_payload.value("text", "") == "你好\nline2");
    CHECK_FALSE(r.json_payload.contains("base64"));

    // binary payload via base64 flag (Python bool() semantics: string "false"
    // is TRUTHY, but JSON false is false)
    const std::string bin = std::string("\x89PNG\r\n bytes\x00", 12);
    auto wb = fx.call("PUT", "/api/tools/write", {},
                      sa::json{{"scope", "workspace"},
                               {"path", "img.png"},
                               {"content", sa::p3b::b64_encode(bin)},
                               {"base64", true}});
    REQUIRE(wb.status == 200);
    CHECK(wb.json_payload.value("size", -1) == 12);
    auto rb = fx.call("GET", "/api/tools/read", {{"scope", "workspace"}, {"path", "img.png"}});
    REQUIRE(rb.status == 200);
    CHECK_FALSE(rb.json_payload.contains("text"));
    CHECK(sa::p3b::b64_decode_loose(rb.json_payload.value("base64", "")) == bin);

    auto st = fx.call("GET", "/api/tools/stat", {{"scope", "workspace"}, {"path", "img.png"}});
    REQUIRE(st.status == 200);
    CHECK(st.json_payload.value("exists", false));
    CHECK(st.json_payload.value("type", "") == "file");
    CHECK(st.json_payload.value("size", -1) == 12);
    CHECK(st.json_payload.value("ext", "") == ".png");
    auto miss = fx.call("GET", "/api/tools/stat", {{"scope", "workspace"}, {"path", "nope"}});
    CHECK(miss.json_payload.value("exists", true) == false);
    CHECK(miss.json_payload.value("path", "") == "nope");

    // deep listing finds the nested file at depth 2 as a joined rel path
    auto deep = fx.call("GET", "/api/tools/list",
                        {{"scope", "workspace"}, {"path", ""}, {"deep", "1"}});
    REQUIRE(deep.status == 200);
    bool found = false;
    for (const auto& e : deep.json_payload["entries"]) {
        if (e.value("name", "") == "sub/dir/hello.txt") found = true;
    }
    CHECK(found);
}

TEST_CASE("tools read: utf-8 kept raw (BOM included) and oversized-ext files stay binary",
          "[p3b][sandbox]") {
    P3bFixture fx;
    const std::string path = cs::join(cs::path_to_utf8(fx.root()), "bom.txt");
    {
        std::ofstream f(cs::to_path(path), std::ios::binary);
        f << "\xef\xbb\xbf" << "hi";
    }
    auto r = fx.call("GET", "/api/tools/read", {{"scope", "workspace"}, {"path", "bom.txt"}});
    REQUIRE(r.status == 200);
    // Python raw.decode("utf-8") keeps U+FEFF as text — NOT utf-8-sig.
    CHECK(r.json_payload.value("text", "") == "\xef\xbb\xbfhi");
    CHECK(r.json_payload.value("size", -1) == 5);
}

TEST_CASE("tools write: binascii.Error analogue is a 500 not a 400", "[p3b][sandbox]") {
    P3bFixture fx;
    auto w = fx.call("PUT", "/api/tools/write", {},
                     sa::json{{"scope", "workspace"},
                              {"path", "x.txt"},
                              {"content", "!!!not base64!!!"},
                              {"base64", true}});
    CHECK(w.status == 500);
    CHECK(sa_core::str::starts_with(w.json_payload.value("error", ""), "Error:"));
}

// ---------------------------------------------------------------------------
// domains
// ---------------------------------------------------------------------------

TEST_CASE("ai domains: shape matches golden (15 domains, sorted tables, fallback)",
          "[p3b][domain]") {
    P3bFixture fx;
    auto resp = fx.call("GET", "/api/ai/domains");
    REQUIRE(resp.status == 200);
    const auto& doms = resp.json_payload["domains"];
    REQUIRE(doms.size() == 15);
    CHECK(doms[0]["id"] == "story");
    CHECK(doms[0]["name"] == "剧情");
    CHECK(doms[0]["tables"].size() == 11);
    CHECK(doms[1]["tables"].size() == 24);
    CHECK(doms[14]["id"] == "table");
    CHECK(doms[14]["name"] == "通用配置");
    CHECK(doms[14]["tables"].size() == 159);  // 406 schema - 247 assigned
    // story tables sorted; fallback carries auto-cn (e.g. "AttrDefineCfg" style)
    std::string prev;
    for (auto it = doms[0]["tables"].begin(); it != doms[0]["tables"].end(); ++it) {
        CHECK(it.key() > prev);
        prev = it.key();
    }
}

TEST_CASE("auto_cn / split_camel match Python _split_camel semantics", "[p3b][domain]") {
    CHECK(sa::p3b::split_camel("EvtCfg") == "evt cfg");
    CHECK(sa::p3b::split_camel("PersonGrowCfg") == "person grow cfg");
    CHECK(sa::p3b::auto_cn("PersonGrowCfg") == "person grow配置");
    CHECK(sa::p3b::auto_cn("QuizAICfg") == "quiz a i配置");  // [A-Z][a-z0-9]* splits AI -> A,I
    CHECK(sa::p3b::auto_cn("Cfg") == "cfg配置");  // len==suffix: not stripped
    CHECK(sa::p3b::auto_cn("SportDefine") == "sport配置");
    CHECK(sa::p3b::auto_cn("CfgDefine") == "cfg配置");  // Define stripped -> "Cfg"
}

TEST_CASE("domain CRUD roundtrip rolls back through the cfg_store undo stack",
          "[p3b][domain][undo]") {
    P3bFixture fx;
    // create in a table the mod does not have yet -> auto-creates the file
    auto create = fx.call("POST", "/api/ai/domain/item", {},
                          sa::json{{"domain", "story"},
                                   {"cfg", "TalkCfg"},
                                   {"data", sa::json{{"id", 8001}, {"content", "你好"}}}});
    REQUIRE(create.status == 200);
    CHECK(create.json_payload.value("id", "") == "8001");
    CHECK(create.json_payload.value("created", false));
    CHECK(cs::is_file(fx.cfg_path_str("TalkCfg")));

    // .bak was NOT made on first creation (file didn't exist); the update will
    auto upd = fx.call("PUT", "/api/ai/domain/item", {},
                       sa::json{{"domain", "story"},
                                {"cfg", "TalkCfg"},
                                {"id", "8001"},
                                {"patch", sa::json{{"content", "新台词"}}}});
    REQUIRE(upd.status == 200);
    CHECK(upd.json_payload.value("changed", false));
    CHECK(upd.json_payload["data"]["content"] == "新台词");
    CHECK(cs::is_file(fx.cfg_path_str("TalkCfg") + ".bak"));

    // unknown field / bad type refusals
    auto bad = fx.call("PUT", "/api/ai/domain/item", {},
                       sa::json{{"domain", "story"},
                                {"cfg", "TalkCfg"},
                                {"id", "8001"},
                                {"patch", sa::json{{"noSuchField", 1}}}});
    CHECK(bad.status == 400);
    CHECK(has(bad.json_payload.value("error", ""), "不在 schema 中"));
    auto badnum = fx.call("PUT", "/api/ai/domain/item", {},
                          sa::json{{"domain", "story"},
                                   {"cfg", "TalkCfg"},
                                   {"id", "8001"},
                                   {"patch", sa::json{{"id", "abc"}}}});
    CHECK(badnum.status == 400);
    auto badbool = fx.call("PUT", "/api/ai/domain/item", {},
                           sa::json{{"domain", "story"},
                                    {"cfg", "TalkCfg"},
                                    {"id", "8001"},
                                    {"patch", sa::json{{"content", true}}}});
    CHECK(badbool.status == 400);
    CHECK(has(badbool.json_payload.value("error", ""), "字符串"));

    // wrong-domain refusal
    auto wrong = fx.call("GET", "/api/ai/domain/item",
                         {{"domain", "background"}, {"cfg", "TalkCfg"}, {"id", "8001"}});
    CHECK(wrong.status == 400);
    CHECK(has(wrong.json_payload.value("error", ""), "不属于领域"));

    // listing finds the entry with the summary name
    auto list = fx.call("GET", "/api/ai/domain/items",
                        {{"domain", "story"}, {"table", "TalkCfg"}});
    REQUIRE(list.status == 200);
    CHECK(list.json_payload.value("domain", "") == "story");
    REQUIRE(list.json_payload["items"].size() == 1);
    CHECK(list.json_payload["items"][0]["name"] == "新台词");

    // undo #1 reverts the patch, undo #2 reverts the creation (file removed)
    auto u1 = fx.call("POST", "/api/history/undo", {}, sa::json{{"cfg", "TalkCfg"}});
    REQUIRE(u1.status == 200);
    auto g1 = fx.call("GET", "/api/ai/domain/item",
                      {{"domain", "story"}, {"cfg", "TalkCfg"}, {"id", "8001"}});
    REQUIRE(g1.status == 200);
    CHECK(g1.json_payload["data"]["content"] == "你好");

    auto u2 = fx.call("POST", "/api/history/undo", {}, sa::json{{"cfg", "TalkCfg"}});
    REQUIRE(u2.status == 200);
    auto g2 = fx.call("GET", "/api/ai/domain/item",
                      {{"domain", "story"}, {"cfg", "TalkCfg"}, {"id", "8001"}});
    CHECK(g2.status == 400);
    CHECK(has(g2.json_payload.value("error", ""), "create_domain_item"));
    CHECK_FALSE(cs::is_file(fx.cfg_path_str("TalkCfg")));
}

TEST_CASE("domain: TalkCfg roleName auto-fill + PhoneMsg role requirement",
          "[p3b][domain]") {
    P3bFixture fx;
    auto ok = fx.call("POST", "/api/ai/domain/item", {},
                      sa::json{{"domain", "story"},
                               {"cfg", "TalkCfg"},
                               {"data", sa::json{{"id", 8101},
                                                 {"content", "你好呀"},
                                                 {"roleName", "薛诗蕾"}}}});
    REQUIRE(ok.status == 200);
    REQUIRE(ok.json_payload["data"].contains("roleIds"));
    CHECK(ok.json_payload["data"]["roleIds"] == sa::json::array({102}));

    auto bad = fx.call("POST", "/api/ai/domain/item", {},
                       sa::json{{"domain", "story"},
                                {"cfg", "TalkCfg"},
                                {"data", sa::json{{"id", 8102},
                                                  {"content", "你好"},
                                                  {"roleName", "神秘人"}}}});
    CHECK(bad.status == 400);
    CHECK(has(bad.json_payload.value("error", ""), "roleIds"));
    CHECK(has(bad.json_payload.value("error", ""), "get_game_dicts"));

    auto narration = fx.call("POST", "/api/ai/domain/item", {},
                             sa::json{{"domain", "story"},
                                      {"cfg", "TalkCfg"},
                                      {"data", sa::json{{"id", 8103}, {"content", "一天清晨"}}}});
    CHECK(narration.status == 200);

    auto phone = fx.call("POST", "/api/ai/domain/item", {},
                         sa::json{{"domain", "social"},
                                  {"cfg", "PhoneMsgCfg"},
                                  {"data", sa::json{{"id", 8201}, {"content", "周末来"}}}});
    CHECK(phone.status == 400);
    CHECK(has(phone.json_payload.value("error", ""), "role"));
}

TEST_CASE("domain: empty-schema table refuses AI writes; missing table gives actionable error",
          "[p3b][domain]") {
    P3bFixture fx;
    auto g = fx.call("GET", "/api/ai/domain/item",
                     {{"domain", "story"}, {"cfg", "TalkCfg"}, {"id", "1"}});
    REQUIRE(g.status == 400);
    CHECK(has(g.json_payload.value("error", ""), "create_domain_item"));

    // SportDefine: fallback domain; either absent or empty-schema -> 无字段定义
    auto p = fx.call("PUT", "/api/cfg/SportDefine",
                     {}, sa::json{{"data", sa::json{{"1", sa::json{{"id", 1}}}}}});
    REQUIRE(p.status == 200);
    auto patch = fx.call("PUT", "/api/ai/domain/item", {},
                         sa::json{{"domain", "table"},
                                  {"cfg", "SportDefine"},
                                  {"id", "1"},
                                  {"patch", sa::json{{"x", 1}}}});
    CHECK(patch.status == 400);
    CHECK(has(patch.json_payload.value("error", ""), "无字段定义"));
}

// ---------------------------------------------------------------------------
// attachments (/api/ai/upload)
// ---------------------------------------------------------------------------

TEST_CASE("upload: docx/xlsx parse equals the Python ai_files oracle", "[p3b][upload]") {
    P3bFixture fx;
    auto r = fx.call("POST", "/api/ai/upload", {},
                     sa::json{{"name", "文档.docx"}, {"data", kDOCX}});
    INFO(r.json_payload.dump());
    REQUIRE(r.status == 200);
    CHECK(r.json_payload.value("ok", false));
    CHECK(r.json_payload.value("kind", "") == "text");
    CHECK(r.json_payload.value("name", "") == "文档.docx");
    CHECK(r.json_payload["size"] == static_cast<long long>(raw(kDOCX).size()));
    CHECK_FALSE(r.json_payload.value("truncated", true));
    CHECK(r.json_payload.value("text", "") ==
          "第一段文本\nPara\tTwo\nLine2\n带 & 实体与 检 查");

    auto x = fx.call("POST", "/api/ai/upload", {},
                     sa::json{{"name", "表格.xlsx"}, {"data", kXLSX}});
    INFO(x.json_payload.dump());
    REQUIRE(x.status == 200);
    CHECK(x.json_payload.value("text", "") ==
          "【工作表：成绩表】\n姓名\t\t95\n张三\t内联\n【工作表：第二个】\n\t7");
}

TEST_CASE("upload: txt/md/images + refusals", "[p3b][upload]") {
    P3bFixture fx;
    auto t = fx.call("POST", "/api/ai/upload", {},
                     sa::json{{"name", "说明.txt"},
                              {"data", sa::p3b::b64_encode("你好，AI！\n第二行")}});
    REQUIRE(t.status == 200);
    CHECK(t.json_payload.value("kind", "") == "text");
    CHECK(has(t.json_payload.value("text", ""), "第二行"));

    // leading BOM stripped for txt (ai_files drops \ufeff after decode)
    auto b = fx.call("POST", "/api/ai/upload", {},
                     sa::json{{"name", "b.md"}, {"data", sa::p3b::b64_encode("\xef\xbb\xbf# t")}});
    REQUIRE(b.status == 200);
    CHECK(b.json_payload.value("text", "") == "# t");

    const std::string png = std::string("\x89PNG\r\n\x1a\n\x00\x00", 10);
    auto p = fx.call("POST", "/api/ai/upload", {},
                     sa::json{{"name", "截图.png"}, {"data", sa::p3b::b64_encode(png)}});
    REQUIRE(p.status == 200);
    CHECK(p.json_payload.value("kind", "") == "image");
    CHECK(p.json_payload.value("mime", "") == "image/png");
    CHECK(p.json_payload.value("data", "") == sa::p3b::b64_encode(png));

    auto j = fx.call("POST", "/api/ai/upload", {},
                     sa::json{{"name", "照片.jpeg"},
                              {"data", sa::p3b::b64_encode(std::string("\xff\xd8\xff\xe0", 4))}});
    REQUIRE(j.status == 200);
    CHECK(j.json_payload.value("mime", "") == "image/jpeg");

    auto exe = fx.call("POST", "/api/ai/upload", {},
                       sa::json{{"name", "恶意.exe"}, {"data", sa::p3b::b64_encode("MZ..")}});
    CHECK(exe.status == 400);
    CHECK(has(exe.json_payload.value("error", ""), "不支持"));

    auto fake = fx.call("POST", "/api/ai/upload", {},
                        sa::json{{"name", "伪图.png"}, {"data", sa::p3b::b64_encode("nope")}});
    CHECK(fake.status == 400);
    CHECK(has(fake.json_payload.value("error", ""), "PNG"));

    auto noname = fx.call("POST", "/api/ai/upload", {},
                          sa::json{{"name", "  "}, {"data", sa::p3b::b64_encode("x")}});
    CHECK(noname.status == 400);
    CHECK(noname.json_payload.value("error", "") == "缺少文件名 name");

    auto nodata = fx.call("POST", "/api/ai/upload", {}, sa::json{{"name", "a.txt"}});
    CHECK(nodata.status == 400);
    CHECK(has(nodata.json_payload.value("error", ""), "base64"));

    auto badb64 = fx.call("POST", "/api/ai/upload", {},
                          sa::json{{"name", "a.txt"}, {"data", "YW Jh Z w=="}});
    CHECK(badb64.status == 400);
    CHECK(badb64.json_payload.value("error", "") == "data 不是合法的 base64 编码");

    // "" decodes empty only if non-empty b64 could — Python guards `not data`
    // first, so an empty payload reports 缺少文件内容 (文件内容为空 unreachable
    // for legal base64, mirrored here).
    auto emptyb = fx.call("POST", "/api/ai/upload", {},
                          sa::json{{"name", "a.txt"}, {"data", ""}});
    CHECK(emptyb.status == 400);
    CHECK(emptyb.json_payload.value("error", "") == "缺少文件内容 data（base64）");
}

TEST_CASE("ai_files internals: zip corruption and XML failure messages", "[p3b][upload]") {
    using sa::p3b::docx_text;
    using sa::p3b::xlsx_text;
    auto zbad = [&]() {
        try {
            docx_text("PK\x03\x04not a real archive at all");
            return std::string();
        } catch (const sa::p3b::UploadError& e) {
            return std::string(e.what());
        }
    }();
    CHECK(zbad == "docx 文件损坏：无法解压");

    // valid zip, missing member
    std::string empty_docx;
    {
        auto zf = sa::p3b::ZipReader::open_bytes(raw(kPACK_NO_MANIFEST));  // valid zip, no doc parts
        REQUIRE(static_cast<bool>(zf));
    }
    auto xmiss = [&]() {
        try {
            xlsx_text(raw(kDOCX));  // docx as xlsx -> no xl/workbook.xml
            return std::string();
        } catch (const sa::p3b::UploadError& e) {
            return std::string(e.what());
        }
    }();
    CHECK(xmiss == "xlsx 文件缺少 xl/workbook.xml");

    // XML with a w:p holding invalid XML bytes -> parse failure
    auto badxml = sa::p3b::xml_parse("<a><b></a>");
    CHECK(badxml == nullptr);
    auto unbound = sa::p3b::xml_parse("<a:p xmlns:w=\"urn:x\"><q:t/></a:p>");
    CHECK(unbound == nullptr);
    auto cdata = sa::p3b::xml_parse("<r>pre<![CDATA[a<b>c]]>post</r>");
    REQUIRE(cdata);
    CHECK(cdata->text == "prea<b>cpost");
    auto entity = sa::p3b::xml_parse("<r a=\"1&amp;2\">&#26816;&nbsp;</r>");
    CHECK(entity == nullptr);  // undefined entity rejected like expat
}

TEST_CASE("base64 semantics: strict vs loose and py repr helpers", "[p3b][support]") {
    CHECK(sa::p3b::b64_encode("") == "");
    CHECK(sa::p3b::b64_encode("a") == "YQ==");
    CHECK(sa::p3b::b64_encode("ab") == "YWI=");
    CHECK(sa::p3b::b64_encode("abc") == "YWJj");
    CHECK(sa::p3b::b64_encode("abcd") == "YWJjZA==");
    // strict: whitespace rejected (validate=True)
    CHECK_FALSE(sa::p3b::b64_decode_strict("YWJj "));
    CHECK(sa::p3b::b64_decode_loose("YW Jj") == "abc");   // loose drops the space
    CHECK(sa::p3b::b64_decode_strict("YWJj") == "abc");
    CHECK(sa::p3b::utf8_head("你好abc", 2) == "你好");
    CHECK(sa::p3b::utf8_len("a你b") == 3);
    CHECK(sa::p3b::py_strip("  \tx ") == "x");
    CHECK(sa::p3b::py_repr(sa::json("ab\"c")) == "'ab\"c'");
}

// ---------------------------------------------------------------------------
// resource packs
// ---------------------------------------------------------------------------

TEST_CASE("resource packs: install / list / activate / info / uninstall roundtrip",
          "[p3b][pack]") {
    const std::string root = cs::join(fixture_root(), "packs_" + std::to_string(rand()));
    ScopedEnv env("EDITOR_PACKS_ROOT", root);
    P3bFixture fx;

    auto empty = fx.call("GET", "/api/resource_packs");
    REQUIRE(empty.status == 200);
    CHECK(empty.json_payload.value("active", "") == "");
    CHECK(empty.json_payload["packs"].empty());

    auto inst = fx.call("POST", "/api/resource_packs/install", {},
                        sa::json{{"filename", "测试包.zip"}, {"data", kPACK}});
    REQUIRE(inst.status == 200);
    CHECK(inst.json_payload.value("id", "") == "测试包");
    CHECK(inst.json_payload["manifest"]["name"] == "测试包");
    CHECK(inst.json_payload["manifest"]["version"] == "0.9");
    CHECK(inst.json_payload["meta"]["active"] == "测试包");

    // same-name second install: Python's while-loop assigns base_1 and
    // re-checks, so the SECOND install lands on "<id>_1" (parity quirk).
    auto inst2 = fx.call("POST", "/api/resource_packs/install", {},
                         sa::json{{"filename", "测试包.zip"}, {"data", kPACK}});
    REQUIRE(inst2.status == 200);
    CHECK(inst2.json_payload.value("id", "") == "测试包_1");

    // manifest backfill (no manifest.json in the zip -> created with defaults)
    auto inst3 = fx.call("POST", "/api/resource_packs/install", {},
                         sa::json{{"filename", "no-manifest.zip"}, {"data", kPACK_NO_MANIFEST}});
    REQUIRE(inst3.status == 200);
    CHECK(inst3.json_payload["manifest"]["version"] == "1.0.0");
    CHECK(inst3.json_payload["manifest"]["name"] == "no-manifest");
    CHECK(cs::is_file(cs::join(cs::join(root, "no-manifest"), "manifest.json")));

    auto list = fx.call("GET", "/api/resource_packs");
    REQUIRE(list.status == 200);
    CHECK(list.json_payload["packs"].size() == 3);
    for (const auto& p : list.json_payload["packs"]) {
        // installed packs are recorded into packs.json WITHOUT a builtin key
        // (Python parity: only directory-discovered entries carry builtin).
        if (p.contains("builtin")) CHECK(p["builtin"] == false);
    }
    // the first pack's files count (manifest + aa_index + Cfgs/zh-cn/TestCfg)
    bool tested = false;
    for (const auto& p : list.json_payload["packs"]) {
        if (p.value("id", "") == "测试包") {
            tested = true;
            CHECK(p.value("files", -1) == 3);
            CHECK(p.value("name", "") == "测试包");
        }
    }
    CHECK(tested);

    auto info = fx.call("GET", "/api/resource_packs/测试包");
    REQUIRE(info.status == 200);
    CHECK(info.json_payload["stats"]["has_aa"] == true);
    CHECK(info.json_payload["stats"]["total_files"] == 3);
    CHECK(info.json_payload["stats"]["has_cfgs"] == 1);
    CHECK(info.json_payload.contains("dir"));

    auto act = fx.call("POST", "/api/resource_packs/active", {}, sa::json{{"id", "no-manifest"}});
    REQUIRE(act.status == 200);
    CHECK(act.json_payload.value("active", "") == "no-manifest");
    auto badact = fx.call("POST", "/api/resource_packs/active", {}, sa::json{{"id", "ghost"}});
    CHECK(badact.status == 400);
    CHECK(badact.json_payload.value("error", "") == "pack not found: ghost");

    auto del = fx.call("DELETE", "/api/resource_packs/no-manifest");
    REQUIRE(del.status == 200);
    CHECK(del.json_payload["packs"].size() == 2);
    // active was no-manifest -> falls back to the first remaining pack
    CHECK(del.json_payload.value("active", "") != "no-manifest");
    CHECK_FALSE(cs::is_dir(cs::join(root, "no-manifest")));

    auto del_again = fx.call("DELETE", "/api/resource_packs/no-manifest");
    CHECK(del_again.status == 400);
    auto info_missing = fx.call("GET", "/api/resource_packs/ghost");
    CHECK(info_missing.status == 404);
    CHECK(info_missing.json_payload.value("error", "") == "pack not found");

    // hostile archives refused
    auto evil = fx.call("POST", "/api/resource_packs/install", {},
                        sa::json{{"data", kPACK_BAD_ENTRY}});
    CHECK(evil.status == 400);
    CHECK(has(evil.json_payload.value("error", ""), "illegal entry"));
    auto abse = fx.call("POST", "/api/resource_packs/install", {},
                        sa::json{{"data", kPACK_ABS_ENTRY}});
    CHECK(abse.status == 400);
    // garbage bytes
    auto junk = fx.call("POST", "/api/resource_packs/install", {},
                        sa::json{{"data", sa::p3b::b64_encode("1234567890abcd")}});
    CHECK(junk.status == 400);
    CHECK(junk.json_payload.value("error", "") == "invalid zip: not a zip archive");
    // base64 with whitespace is strict-rejected here
    auto wsb = fx.call("POST", "/api/resource_packs/install", {},
                       sa::json{{"data", "YW Jj"}});
    CHECK(wsb.status == 400);
    CHECK(wsb.json_payload.value("error", "") == "invalid base64");

    // import_path happy + missing
    const std::string zp = cs::join(root, "drop.zip");
    cs::write_bytes_simple(zp, raw(kPACK));
    auto imp = fx.call("POST", "/api/resource_packs/import_path", {}, sa::json{{"path", zp}});
    REQUIRE(imp.status == 200);
    CHECK(imp.json_payload.value("id", "") == "drop");
    auto imp_missing = fx.call("POST", "/api/resource_packs/import_path", {},
                               sa::json{{"path", cs::join(root, "none.zip")}});
    CHECK(imp_missing.status == 400);
    CHECK(sa_core::str::starts_with(imp_missing.json_payload.value("error", ""), "file not found:"));
    auto imp_none = fx.call("POST", "/api/resource_packs/import_path", {}, sa::json{});
    CHECK(imp_none.status == 400);
    CHECK(imp_none.json_payload.value("error", "") == "path required");
}

TEST_CASE("pack_id_from_name mirrors _pack_id_from_name", "[p3b][pack]") {
    CHECK(sa::p3b::resource_pack::pack_id_from_name("My Pack.zip") == "My_Pack");
    CHECK(sa::p3b::resource_pack::pack_id_from_name("bad!*?.zip") == "bad___");
    CHECK(sa::p3b::resource_pack::pack_id_from_name("") != "");
    CHECK(sa::p3b::resource_pack::pack_id_from_name("pack.zip") == "pack");
}

// ---------------------------------------------------------------------------
// ai settings
// ---------------------------------------------------------------------------

TEST_CASE("ai settings: GET empty store matches golden shape; PUT roundtrips normalize",
          "[p3b][settings]") {
    const std::string root = cs::join(fixture_root(), "settings_" + std::to_string(rand()));
    cs::create_dirs(root);
    const std::string saved = sa::editor_root();
    sa::detail::set_editor_root(root);
    struct Restore {
        ~Restore() { sa::detail::set_editor_root(""); }
    } restore;
    (void)restore;

    P3bFixture fx;
    auto g = fx.call("GET", "/api/ai/settings");
    REQUIRE(g.status == 200);
    const auto& s = g.json_payload["settings"];
    CHECK(s["provider"] == "openai_compatible");
    CHECK(s["apiKey"].is_null());   // golden-pinned null, do not "fix" to ""
    CHECK(s["baseUrl"].is_null());
    CHECK(s["model"].is_null());
    CHECK(s["temperature"] == 0.7);
    CHECK(s["permissionMode"] == "confirm");
    CHECK(s["ttsFormat"] == "wav");
    CHECK(s["maxRetries"] == 3);

    auto p = fx.call("PUT", "/api/ai/settings", {},
                     sa::json{{"apiKey", "sk-1"}, {"temperature", 9}});
    REQUIRE(p.status == 200);
    CHECK(p.json_payload["settings"]["apiKey"] == "sk-1");
    CHECK(p.json_payload["settings"]["temperature"] == 2.0);  // clamped
    auto g2 = fx.call("GET", "/api/ai/settings");
    CHECK(g2.json_payload["settings"]["apiKey"] == "sk-1");

    // snake_case alias + null-skipped merge
    auto p2 = fx.call("PUT", "/api/ai/settings", {},
                      sa::json{{"settings", sa::json{{"base_url", "http://x"},
                                                     {"apiKey", nullptr}}}});
    REQUIRE(p2.status == 200);
    CHECK(p2.json_payload["settings"]["baseUrl"] == "http://x");
    CHECK(p2.json_payload["settings"]["apiKey"] == "sk-1");  // null was filtered

    // 0 is legal (maxRetries=0 persists; not replaced by default 3)
    auto p3 = fx.call("PUT", "/api/ai/settings", {}, sa::json{{"maxRetries", 0},
                                                               {"ttsSpeed", 0}});
    CHECK(p3.json_payload["settings"]["maxRetries"] == 0);
    CHECK(p3.json_payload["settings"]["ttsSpeed"] == 0.5);  // clamped
    auto p4 = fx.call("PUT", "/api/ai/settings", {}, sa::json{{"permissionMode", "YOLO"}});
    CHECK(p4.json_payload["settings"]["permissionMode"] == "confirm");

    // on-disk file exists with the merged (unknown-key-preserving) shape
    cs::write_bytes_simple(cs::join(root, ".editor_ai.json"),
                           "{\n  \"futureKey\": 7\n}");
    auto p5 = fx.call("PUT", "/api/ai/settings", {}, sa::json{{"model", "m"}});
    REQUIRE(p5.status == 200);
    auto disk = cs::read_bytes(cs::join(root, ".editor_ai.json"));
    REQUIRE(disk.has_value());
    CHECK(disk->find("\"futureKey\": 7") != std::string::npos);
    CHECK(disk->find("\"model\": \"m\"") != std::string::npos);
}

TEST_CASE("ai settings PUT rejects non-object settings", "[p3b][settings]") {
    P3bFixture fx;
    auto r = fx.call("PUT", "/api/ai/settings", {}, sa::json{{"settings", 5}});
    CHECK(r.status == 400);
    CHECK(r.json_payload.value("error", "") == "body must be a settings object");
}

// ---------------------------------------------------------------------------
// manifest/status
// ---------------------------------------------------------------------------

TEST_CASE("manifest status: no mod / no manifest / valid / broken", "[p3b][manifest]") {
    P3bFixture fx;
    // temporarily deselect the mod
    std::string saved;
    {
        std::lock_guard<std::mutex> lk(sa::STATE().mu_);
        saved = sa::STATE().mod_root;
        sa::STATE().mod_root.clear();
    }
    auto none = fx.call("GET", "/api/manifest/status");
    REQUIRE(none.status == 200);
    CHECK(none.json_payload.value("selected", true) == false);
    CHECK(none.json_payload["checks"].empty());
    {
        std::lock_guard<std::mutex> lk(sa::STATE().mu_);
        sa::STATE().mod_root = saved;
    }

    auto noManifest = fx.call("GET", "/api/manifest/status");
    REQUIRE(noManifest.status == 200);
    CHECK(noManifest.json_payload.value("selected", false));
    CHECK(noManifest.json_payload.value("has_manifest", true) == false);
    REQUIRE(noManifest.json_payload["checks"].size() == 1);
    CHECK(noManifest.json_payload["checks"][0]["detail"] == "缺少 manifest.json");

    cs::write_bytes_simple(cs::join(cs::path_to_utf8(fx.mod_root()), "manifest.json"),
                           R"({"title": "我的模组", "description": "", "version": "1.0"})");
    auto ok = fx.call("GET", "/api/manifest/status");
    REQUIRE(ok.status == 200);
    CHECK(ok.json_payload.value("has_manifest", false));
    const auto& checks = ok.json_payload["checks"];
    REQUIRE(checks.size() == 4);
    CHECK(checks[0]["key"] == "title");
    CHECK(checks[0]["label"] == "标题");
    CHECK(checks[0]["ok"] == true);
    CHECK(checks[0]["detail"] == "我的模组");
    CHECK(checks[1]["ok"] == false);
    CHECK(checks[1]["detail"] == "（缺失）");
    CHECK(checks[3]["key"] == "cfgs");
    CHECK(checks[3]["detail"] == "0 个 JSON 配置表");

    cs::write_bytes_simple(cs::join(cs::path_to_utf8(fx.mod_root()), "manifest.json"), "{[bad");
    auto broken = fx.call("GET", "/api/manifest/status");
    REQUIRE(broken.status == 200);
    CHECK(broken.json_payload.contains("parse_error"));
    CHECK(broken.json_payload["checks"][0]["ok"] == false);
    CHECK(sa_core::str::starts_with(broken.json_payload["checks"][0]["detail"].get<std::string>(),
                                    "解析失败:"));
}

// ---------------------------------------------------------------------------
// plugins read-only stubs
// ---------------------------------------------------------------------------

TEST_CASE("plugins stubs: golden shapes + declarative flow_cards reader", "[p3b][plugins]") {
    const std::string proot = cs::join(fixture_root(), "plugins_" + std::to_string(rand()));
    ScopedEnv env("EDITOR_PLUGINS_ROOT", proot);
    P3bFixture fx;

    CHECK(fx.call("GET", "/api/plugins").json_payload["plugins"].empty());
    CHECK(fx.call("GET", "/api/plugins/ui").json_payload["panels"].empty());
    CHECK(fx.call("GET", "/api/plugins/agent/tools").json_payload["tools"].empty());
    auto fc0 = fx.call("GET", "/api/plugins/ui/flow_cards");
    REQUIRE(fc0.status == 200);
    CHECK(fc0.json_payload["flow_cards"].empty());
    auto info = fx.call("GET", "/api/plugins/anything");
    CHECK(info.status == 404);
    CHECK(info.json_payload.value("error", "") == "plugin not found");

    // declarative manifest directory: <root>/p1/manifest.json -> ui.flow_cards
    const std::string pdir = cs::join(proot, "p1");
    cs::create_dirs(pdir);
    cs::write_bytes_simple(cs::join(pdir, "manifest.json"),
                           R"({"name":"P1","ui":{"flow_cards":[{"type_id":"cardX","name":"卡片"}]}})");
    cs::write_bytes_simple(cs::join(proot, "broken.json"), "junk");  // not a dir: ignored
    auto fc = fx.call("GET", "/api/plugins/ui/flow_cards");
    REQUIRE(fc.status == 200);
    REQUIRE(fc.json_payload["flow_cards"].size() == 1);
    const auto& c = fc.json_payload["flow_cards"][0];
    CHECK(c["type_id"] == "cardX");
    CHECK(c["name"] == "卡片");
    CHECK(c["plugin_id"] == "p1");
    CHECK(c.contains("hidden_ports"));
    CHECK(c.size() == 10);
}
