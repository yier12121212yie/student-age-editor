// test_semantic_graph.cpp — [p1][graph] 只读分析三端点的进程内黑盒测试：
// POST /api/effect/parse、GET /api/graph/relations、GET /api/graph/timeline。
// fixture 与 test_p1_routes 同款（temp workspace + Cfgs/zh-cn 假 mod，经
// build_router() 挂载 semantic 族，绝不触碰真实 Mods）。
#include <catch_amalgamated.hpp>

#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <memory>
#include <mutex>

#include "test_support.h"

#include "sa_core/paths.h"
#include "semantic_assets.h"

#include "server/api_router.h"
#include "server/cfg_cache.h"
#include "server/cfg_store.h"
#include "server/httpd.h"
#include "server/state.h"

namespace fs = std::filesystem;
using sa::json;
using sa::Resp;

namespace {

void putenv_portable(const char* k, const char* v) {
#ifdef _WIN32
    _putenv_s(k, v);
#else
    if (v && *v) setenv(k, v, 1);
    else unsetenv(k);
#endif
}
std::string getenv_portable(const char* k) {
    const char* v = std::getenv(k);
    return v ? std::string(v) : std::string();
}

class GraphFixture {
  public:
    explicit GraphFixture(bool with_mod = true) : root_(sat::make_temp_dir("graph")) {
        mod_root_ = root_ / "mod";
        cfg_dir_ = mod_root_ / "Cfgs" / "zh-cn";
        if (with_mod) fs::create_directories(cfg_dir_);
        auto& st = sa::STATE();
        {
            std::lock_guard<std::mutex> lk(st.mu_);
            saved_ws_ = st.workspace_root;
            saved_mod_root_ = st.mod_root;
            saved_mod_name_ = st.mod_name;
            st.workspace_root = sa_core::paths::path_to_utf8(root_);
            st.mod_root = with_mod ? sa_core::paths::path_to_utf8(mod_root_) : std::string();
            st.mod_name = with_mod ? "mod" : std::string();
        }
        saved_data_root_ = getenv_portable("EDITOR_DATA_ROOT");
        putenv_portable("EDITOR_DATA_ROOT", "");
        sa::detail::set_editor_root(sa_core::paths::path_to_utf8(root_ / "data"));
        sa::invalidate_table_cache_all();
        sa::invalidate_mod_cfgs_cache();
        router_ = std::make_unique<sa::Router>(sa::build_router());
    }
    ~GraphFixture() {
        {
            auto& st = sa::STATE();
            std::lock_guard<std::mutex> lk(st.mu_);
            st.workspace_root = saved_ws_;
            st.mod_root = saved_mod_root_;
            st.mod_name = saved_mod_name_;
        }
        sa::detail::set_editor_root("");
        putenv_portable("EDITOR_DATA_ROOT", saved_data_root_.c_str());
        sa::invalidate_table_cache_all();
        sa::invalidate_mod_cfgs_cache();
        std::error_code ec;
        fs::remove_all(root_, ec);
    }
    GraphFixture(const GraphFixture&) = delete;
    GraphFixture& operator=(const GraphFixture&) = delete;

    Resp call(const std::string& method, const std::string& path,
              std::map<std::string, std::string> query = {}, const json& body = json()) {
        return sat::call_router(*router_, method, path, std::move(query), body);
    }
    void write_cfg_file(const std::string& name, const std::string& content) {
        std::ofstream f(cfg_dir_ / fs::u8path(name + ".json"), std::ios::binary);
        f << content;
    }

  private:
    fs::path root_, mod_root_, cfg_dir_;
    std::string saved_ws_, saved_mod_root_, saved_mod_name_, saved_data_root_;
    std::unique_ptr<sa::Router> router_;
};

json parse_call(GraphFixture& fx, const std::string& text, const std::string& mode) {
    auto r = fx.call("POST", "/api/effect/parse", {}, json{{"text", text}, {"mode", mode}});
    REQUIRE(r.status == 200);
    return r.json_payload;
}

// edges 里按 kind+source 找第一条。
const json* find_edge(const json& edges, const std::string& kind, const std::string& cfg = "") {
    for (const auto& e : edges) {
        if (e.value("kind", "") != kind) continue;
        if (!cfg.empty() && e.value("sourceCfg", "") != cfg) continue;
        return &e;
    }
    return nullptr;
}
const json* find_by_id(const json& arr, const std::string& id) {
    for (const auto& x : arr)
        if (x.value("id", std::string()) == id) return &x;
    return nullptr;
}

}  // namespace

// ---------------------------------------------------------------------------
// POST /api/effect/parse — 文本行 → 结构化（契约钉死形态）
// ---------------------------------------------------------------------------
TEST_CASE("graph: /api/effect/parse status branches", "[p1][graph]") {
    GraphFixture fx;
    {
        json b = parse_call(fx, "", "effect");
        CHECK(b.at("ok") == true);
        CHECK(b.at("status") == "empty");
        CHECK(b.at("translations").empty());
        CHECK(b.at("rows").empty());
        CHECK_FALSE(b.contains("message"));
    }
    {
        json b = parse_call(fx, "abc", "effect");
        CHECK(b.at("ok") == false);
        CHECK(b.at("status") == "json_error");
        CHECK(b.at("message") == "括号或逗号不匹配");
    }
    {
        // 扁平数组且首项纯数字 → 缺外层括号（与 /api/effect_validate 同判据）
        json b = parse_call(fx, "1, 2", "effect");
        CHECK(b.at("ok") == false);
        CHECK(b.at("status") == "missing_outer_bracket");
        CHECK(b.at("message").get<std::string>().find("缺少外层方括号") == 0);
    }
    {
        // 一级代码不在字典 → logic_error，行级错误进 rows[].error
        json b = parse_call(fx, "[888888, 0]", "effect");
        CHECK(b.at("ok") == false);
        CHECK(b.at("status") == "logic_error");
        REQUIRE(b.at("rows").size() == 1);
        CHECK(b["rows"][0]["error"].get<std::string>().find("一级代码 [888888] 不在二次代码字典中") !=
              std::string::npos);
        CHECK(b["rows"][0]["template"].is_null());
        CHECK(b["rows"][0]["slots"].is_null());
    }
}

TEST_CASE("graph: /api/effect/parse effect row slots & template", "[p1][graph]") {
    GraphFixture fx;
    json b = parse_call(fx, "[1, 1, 1, 5], [7, 2]", "effect");
    CHECK(b.at("status") == "logic_error");  // 第二行坏、第一行好
    const json& rows = b.at("rows");
    REQUIRE(rows.size() == 2);
    CHECK(b.at("translations").size() == 2);
    // ATTR id 1 = 智力（dicts.json 静态池）
    CHECK(b["translations"][0].get<std::string>().find("智力") != std::string::npos);

    const json& r0 = rows[0];
    CHECK(r0.at("line") == 1);
    CHECK(r0.at("negate") == false);
    CHECK(r0.at("primary") == 1);
    CHECK(r0.at("secondary") == 1);
    CHECK(r0.at("args") == json::array({1, 5}));
    CHECK(r0.at("display") == "[1, 1, 1, 5]");
    CHECK(r0.at("error").is_null());
    CHECK(r0.at("nested").is_null());
    REQUIRE(r0.at("template").is_object());
    CHECK(r0["template"].at("code") == "[1, 1, @ATTR@, V]");
    CHECK(r0["template"].at("desc").get<std::string>().find("属性") != std::string::npos);
    const json& slots = r0.at("slots");
    REQUIRE(slots.size() == 2);
    CHECK(slots[0].at("name") == "ATTR");
    CHECK(slots[0].at("kind") == "dict");
    CHECK(slots[0].at("dict") == "ATTR");
    CHECK(slots[0].at("label") == "属性");
    CHECK(slots[0].at("value") == "1");
    CHECK(slots[1].at("name") == "V");
    CHECK(slots[1].at("kind") == "number");
    CHECK(slots[1].at("dict").is_null());
    CHECK(slots[1].at("label") == "数值");
    CHECK(slots[1].at("value") == "5");

    // 坏行：模板未命中 → template/slots null + error 给校验信息
    CHECK(rows[1]["error"].is_string());
    CHECK(rows[1]["template"].is_null());
}

TEST_CASE("graph: /api/effect/parse negate & condition mode", "[p1][graph]") {
    GraphFixture fx;
    json b = parse_call(fx, "[7, -1, 101, 50]", "condition");
    CHECK(b.at("status") == "ok");
    const json& r0 = b["rows"][0];
    CHECK(r0.at("negate") == true);   // 二级取负判定
    CHECK(r0.at("secondary") == 1);   // 绝对值回填
    CHECK(r0.at("primary") == 7);
    CHECK(r0["template"].at("code") == "[7, -1, @ROLE@, V]");
    const json& slots = r0["slots"];
    REQUIRE(slots.size() == 2);
    CHECK(slots[0].at("name") == "ROLE");
    CHECK(slots[0].at("value") == "101");
    CHECK(slots[1].at("name") == "V");
    CHECK(slots[1].at("value") == "50");
}

TEST_CASE("graph: /api/effect/parse 998 nested & fullwidth & screen/action", "[p1][graph]") {
    GraphFixture fx;
    {
        // 引擎存储的扁平尾形态（与 validate_secondary_item 的 EFFECTS* 吸收一致）
        json b = parse_call(fx, "[998, 1, 101, 20, 1, 101, 50]", "effect");
        CHECK(b.at("status") == "ok");
        const json& r0 = b["rows"][0];
        CHECK(r0.at("primary") == 998);
        REQUIRE(r0.at("nested").is_array());
        REQUIRE(r0["nested"].size() == 1);
        CHECK(r0["nested"][0].at("line") == 1);
        CHECK(r0["nested"][0].at("primary") == 20);
        CHECK(r0["nested"][0].at("secondary") == 1);
        CHECK(r0["nested"][0].at("error").is_null());
        // 父行 rest 槽给出 nested 形态
        bool has_nested_slot = false;
        for (const auto& s : r0["slots"])
            if (s.value("kind", "") == "nested") has_nested_slot = true;
        CHECK(has_nested_slot);
    }
    {
        // 嵌套数组形态：结构照样展开；父行错误口径与 /api/effect_validate 一致
        json b = parse_call(fx, "[998, 1, 101, [[20, 1, 101, 50]]]", "effect");
        const json& r0 = b["rows"][0];
        REQUIRE(r0.at("nested").is_array());
        REQUIRE(r0["nested"].size() == 1);
        CHECK(r0["nested"][0].at("primary") == 20);
        CHECK(r0["nested"][0].at("error").is_null());
    }
    {
        // 全角逗号宽容（契约明列）
        json b = parse_call(fx, "[1，1，3，5]", "effect");
        CHECK(b.at("status") == "ok");
        CHECK(b["rows"][0]["args"] == json::array({3, 5}));
    }
    {
        json b = parse_call(fx, "[4001, 0.5]", "screen");
        CHECK(b.at("status") == "ok");
        const json& r0 = b["rows"][0];
        CHECK(r0.at("primary") == 4001);
        CHECK(r0.at("secondary").is_null());
        CHECK(r0.at("negate") == false);
        CHECK(r0["template"].at("code") == "[4001, X]");
        CHECK(r0["slots"][0].at("value") == "0.5");
        CHECK(b["translations"][0].get<std::string>().find("屏幕抖动") != std::string::npos);
    }
    {
        json b = parse_call(fx, "[0, 3000, 1]", "action");
        CHECK(b.at("status") == "ok");
        const json& r0 = b["rows"][0];
        CHECK(r0["template"].at("code") == "[N, 3000, E]");
        CHECK(r0["slots"][0].at("value") == "0");
        CHECK(r0["slots"][1].at("value") == "1");
    }
    {
        // cost：无二级语义；槽位取 COST_DB 模板
        json b = parse_call(fx, "[1, 20]", "cost");
        CHECK(b.at("status") == "ok");
        const json& r0 = b["rows"][0];
        CHECK(r0.at("secondary").is_null());
        CHECK(r0.at("negate") == false);
        CHECK(r0["template"].at("code") == "[@ATTR@, V]");
        CHECK(r0["slots"][0].at("kind") == "dict");
        CHECK(r0["slots"][0].at("value") == "1");
        CHECK(r0["slots"][1].at("value") == "20");
    }
}

// ---------------------------------------------------------------------------
// GET /api/graph/relations — nodes/levels/edges（mod+本体合并，无 base 时纯 mod）
// ---------------------------------------------------------------------------
TEST_CASE("graph: /api/graph/relations merge and edges", "[p1][graph]") {
    GraphFixture fx;
    fx.write_cfg_file("PersonCfg",
                      R"({"101": {"id": 101, "name": "小明", "gender": 1, "url": ["Role/xm.png"]},)"
                      R"("999": {"id": 999, "name": "自定义", "url2": ["Role2/z.png"]}})");
    fx.write_cfg_file("RelationCfg",
                      R"({"520": {"id": 520, "name": "恋人", "color": 16750592, "condition": 90,)"
                      R"( "upgrade": 0, "upgradeCost": 100, "socialCapacity": 1,)"
                      R"( "iconRelation": "icon/love.png"}})");
    fx.write_cfg_file("TalkCfg",
                      R"({"1314170001": {"id": 1314170001, "content": "你好呀今天也要加油哦",)"
                      R"( "check": [[7, 1, 101, 50]], "effect": [[20, 1, 101, 10], [20, 2, 101, 520]]}})");
    fx.write_cfg_file("InteractCfg", R"({"1": {"id": 1, "npc": 101, "name": "送奶茶", "cond": [[2, 0, 6]]}})");
    fx.write_cfg_file("FriendRequestCfg", R"({"5": {"id": 5, "npc": 999, "weight": 7, "txt": "加个好友"}})");
    fx.write_cfg_file("LoveBreakfastCfg",
                      R"({"9": {"id": 9, "npc": 101, "weight": 3, "cond": [[7, 0, 101, 520]]}})");

    auto r = fx.call("GET", "/api/graph/relations");
    REQUIRE(r.status == 200);
    const json& b = r.json_payload;
    CHECK(b.at("truncated") == false);

    // nodes：/api/roles 同源（静态角色池 + PersonCfg 覆盖）
    const json* n101 = find_by_id(b.at("nodes"), "101");
    REQUIRE(n101 != nullptr);
    CHECK(n101->at("name") == "小明");
    CHECK(n101->at("gender") == 1);
    CHECK(n101->at("tex") == "Role/xm.png");
    const json* n999 = find_by_id(b.at("nodes"), "999");
    REQUIRE(n999 != nullptr);
    CHECK(n999->at("tex") == "Role2/z.png");   // url2 优先
    const json* narr = find_by_id(b.at("nodes"), "-1");
    REQUIRE(narr != nullptr);
    CHECK(narr->at("name") == "旁白");
    CHECK(narr->at("tex").is_null());

    // levels：RelationCfg mod 行（无 base 时纯 mod）
    const json* lv = find_by_id(b.at("levels"), "520");
    REQUIRE(lv != nullptr);
    CHECK(lv->at("name") == "恋人");
    CHECK(lv->at("color") == "#FF9800");       // 0xFF9800 → #RRGGBB
    CHECK(lv->at("condition") == 90);
    CHECK(lv->at("upgrade").is_null());        // 0 → null
    CHECK(lv->at("upgradeCost") == 100);
    CHECK(lv->at("socialCapacity") == 1);
    CHECK(lv->at("iconRelation") == "icon/love.png");

    // edges：2D 码 + 整行
    const json& edges = b.at("edges");
    const json* gain = find_edge(edges, "favorGain", "TalkCfg");
    REQUIRE(gain != nullptr);
    CHECK(gain->at("role") == "101");
    CHECK(gain->at("value") == 10);
    CHECK(gain->at("relation").is_null());
    CHECK(gain->at("code") == "[20, 1, 101, 10]");
    CHECK(gain->at("sourceId") == "1314170001");
    CHECK(gain->at("sourceName").get<std::string>().find("你好呀") == 0);
    const json* cond = find_edge(edges, "favorCond", "TalkCfg");
    REQUIRE(cond != nullptr);
    CHECK(cond->at("value") == 50);
    CHECK(cond->at("code") == "[7, 1, 101, 50]");
    const json* rel = find_edge(edges, "relationSet", "TalkCfg");
    REQUIRE(rel != nullptr);
    CHECK(rel->at("relation") == "520");
    const json* rc = find_edge(edges, "relationCond", "LoveBreakfastCfg");
    REQUIRE(rc != nullptr);
    CHECK(rc->at("relation") == "520");
    const json* inter = find_edge(edges, "interact", "InteractCfg");
    REQUIRE(inter != nullptr);
    CHECK(inter->at("role") == "101");
    CHECK(inter->at("value") == 1);            // cond 数量
    CHECK(inter->at("code") == "[2, 0, 6]");
    const json* fr = find_edge(edges, "friendRequest", "FriendRequestCfg");
    REQUIRE(fr != nullptr);
    CHECK(fr->at("value") == 7);               // weight
    const json* love = find_edge(edges, "loveScene", "LoveBreakfastCfg");
    REQUIRE(love != nullptr);
    CHECK(love->at("role") == "101");
    CHECK(love->at("value") == 3);
}

TEST_CASE("graph: /api/graph/relations without mod selected", "[p1][graph]") {
    GraphFixture nomod(false);
    auto r = nomod.call("GET", "/api/graph/relations");
    REQUIRE(r.status == 200);
    CHECK(r.json_payload.at("edges").empty());
    CHECK(r.json_payload.at("levels").empty());
    // 静态角色池仍在（本体未加载也不炸）
    CHECK_FALSE(r.json_payload.at("nodes").empty());
    auto r2 = nomod.call("GET", "/api/graph/timeline");
    REQUIRE(r2.status == 200);
    CHECK(r2.json_payload.at("rounds").empty());
    CHECK(r2.json_payload.at("items").empty());
}

// ---------------------------------------------------------------------------
// GET /api/graph/timeline — 回合视图 + [2,*] 时间码 → spans
// ---------------------------------------------------------------------------
TEST_CASE("graph: /api/graph/timeline rounds and spans", "[p1][graph]") {
    GraphFixture fx;
    fx.write_cfg_file("RoundCfg",
                      R"({"1": {"id": 1, "year": 1, "season": 1, "grade": 1},)"
                      R"( "2": {"id": 2, "year": 1, "season": 2, "grade": 1},)"
                      R"( "3": {"id": 3, "year": 1, "season": 5, "grade": 1}})");
    fx.write_cfg_file("SeasonCfg",
                      R"({"1": {"id": 1, "name": "春", "month": [3, 4, 5], "type": 101},)"
                      R"( "2": {"id": 2, "name": "夏", "month": [6, 7, 8], "type": 501},)"
                      R"( "5": {"id": 5, "name": "秋", "month": [9, 10, 11], "type": 102}})");
    fx.write_cfg_file("SeasonTypeCfg", R"({"501": {"id": 501, "name": "寒暑假", "order": 1, "seasons": [2]}})");
    fx.write_cfg_file("EvtCfg",
                      R"({"1200001": {"id": 1200001, "title": "开学礼", "mapId": 3, "npc": 101,)"
                      R"( "condition": [[2, 0, 2], [2, 4, 2]]},)"
                      R"( "1200002": {"id": 1200002, "title": "生日惊喜", "condition": [[2, 101, 1]]},)"
                      R"( "1200003": {"id": 1200003, "title": "没有时间码", "condition": [[0, 1, 100]]}})");
    fx.write_cfg_file("ActionCfg",
                      R"({"7": {"id": 7, "name": "街头打工", "map": 4, "beginTime": [1, 7], "endTime": [1, 8]}})");

    auto r = fx.call("GET", "/api/graph/timeline");
    REQUIRE(r.status == 200);
    const json& b = r.json_payload;

    const json& rounds = b.at("rounds");
    REQUIRE(rounds.size() == 3);
    CHECK(rounds[0].at("round") == 1);
    CHECK(rounds[0].at("year") == 1);
    CHECK(rounds[0].at("season") == 1);
    CHECK(rounds[0].at("months") == json::array({3, 4, 5}));
    CHECK(rounds[0].at("holiday") == false);
    CHECK_FALSE(rounds[0].at("seasonName").get<std::string>().empty());
    CHECK(rounds[1].at("holiday") == true);   // SeasonTypeCfg 501 寒暑假

    const json& items = b.at("items");
    REQUIRE(items.size() == 3);               // 1200003 无时间码不输出
    const json* e1 = nullptr;
    const json* e2 = nullptr;
    const json* a7 = nullptr;
    for (const auto& it : items) {
        if (it.value("id", "") == "1200001") e1 = &it;
        if (it.value("id", "") == "1200002") e2 = &it;
        if (it.value("cfg", "") == "ActionCfg") a7 = &it;
    }
    REQUIRE(e1 != nullptr);
    CHECK(e1->at("cfg") == "EvtCfg");
    CHECK(e1->at("name") == "开学礼");
    CHECK(e1->at("mapId") == "3");
    CHECK(e1->at("npc") == "101");
    CHECK(e1->at("timeKinds") == json::array({"round", "season"}));
    REQUIRE(e1->at("spans").size() == 1);     // 第2回合 ∩ 2季 → {2..2}
    CHECK(e1->at("spans")[0].at("from") == 2);
    CHECK(e1->at("spans")[0].at("to") == 2);
    CHECK(e1->at("codes") == json::array({"[2,0,2]", "[2,4,2]"}));

    REQUIRE(e2 != nullptr);
    CHECK(e2->at("timeKinds") == json::array({"special"}));  // 生日无法定位
    CHECK(e2->at("spans").empty());
    CHECK(e2->at("codes") == json::array({"[2,101,1]"}));

    REQUIRE(a7 != nullptr);
    CHECK(a7->at("cfg") == "ActionCfg");
    CHECK(a7->at("name") == "街头打工");
    CHECK(a7->at("mapId") == "4");
    CHECK(a7->at("npc").is_null());
    CHECK(a7->at("timeKinds") == json::array({"month"}));
    REQUIRE(a7->at("spans").size() == 1);     // 1年7月 至 1年8月 → 第2回合
    CHECK(a7->at("spans")[0].at("from") == 2);
    CHECK(a7->at("spans")[0].at("to") == 2);
    CHECK(a7->at("codes").empty());
}

TEST_CASE("graph: /api/graph/timeline open-ended and year range", "[p1][graph]") {
    GraphFixture fx;
    fx.write_cfg_file("RoundCfg",
                      R"({"1": {"id": 1, "year": 1, "season": 1, "grade": 1},)"
                      R"( "2": {"id": 2, "year": 1, "season": 2, "grade": 1},)"
                      R"( "3": {"id": 3, "year": 2, "season": 1, "grade": 2}})");
    fx.write_cfg_file("SeasonCfg",
                      R"({"1": {"id": 1, "name": "春", "month": [3, 4, 5], "type": 101},)"
                      R"( "2": {"id": 2, "name": "夏", "month": [6, 7, 8], "type": 102}})");
    fx.write_cfg_file("EvtCfg",
                      R"({"1000001": {"id": 1000001, "title": "以后", "condition": [[2, 100, 2]]},)"
                      R"( "1000002": {"id": 1000002, "title": "两年", "condition": [[2, 20, 1, 1]]},)"
                      R"( "1000003": {"id": 1000003, "title": "某月以后", "condition": [[2, 110, 1, 4]]}})");
    auto r = fx.call("GET", "/api/graph/timeline");
    REQUIRE(r.status == 200);
    const json& items = r.json_payload.at("items");
    REQUIRE(items.size() == 3);
    auto find_item = [&](const std::string& id) -> const json* {
        for (const auto& it : items) if (it.value("id", "") == id) return &it;
        return nullptr;
    };
    const json* i1 = find_item("1000001");
    REQUIRE(i1 != nullptr);
    REQUIRE(i1->at("spans").size() == 1);
    CHECK(i1->at("spans")[0].at("from") == 2);
    CHECK(i1->at("spans")[0]["to"].is_null());          // 或以后 → 末段 to=null
    const json* i2 = find_item("1000002");
    REQUIRE(i2 != nullptr);
    CHECK(i2->at("timeKinds") == json::array({"year"}));
    CHECK(i2->at("spans")[0].at("from") == 1);          // 1..2 回合（第1年）
    CHECK(i2->at("spans")[0].at("to") == 2);
    const json* i3 = find_item("1000003");
    REQUIRE(i3 != nullptr);
    CHECK(i3->at("spans")[0].at("from") == 1);          // 1年4月起（回合1 月表含4）
    CHECK(i3->at("spans")[0]["to"].is_null());
}
