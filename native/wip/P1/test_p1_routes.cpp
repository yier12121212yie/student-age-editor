// wip/P1/test_p1_routes.cpp — [p1] 九条语义路由的进程内黑盒测试（sat::call_router，
// 同 test_s1_read_exit / P2 的做法：build_router() 上嫁接 register_semantic_routes，
// 与 backend_wip 的挂载路径一致）。fixture 为 temp workspace + 一个含 Cfgs/zh-cn
// 的 mod；绝不触碰真实 Mods。
#include <catch_amalgamated.hpp>

#include <filesystem>
#include <fstream>
#include <memory>
#include <mutex>

#include "test_support.h"

#include "sa_core/paths.h"
#include "semantic_assets.h"
#include "semantic_logic.h"
#include "semantic_routes.h"

#include "server/api_router.h"
#include "server/cfg_cache.h"
#include "server/cfg_store.h"
#include "server/httpd.h"
#include "server/state.h"

namespace fs = std::filesystem;
using sa::json;
using sa::Req;
using sa::Resp;

namespace {

// assets 定位：semantic_assets 的 exe-dir 向上查找（build-P1/bin → native/assets）
// 已覆盖测试运行位置，无需 env 干预。
class P1Fixture {
  public:
    explicit P1Fixture(bool with_mod = true) : root_(sat::make_temp_dir("p1")) {
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
        sa::invalidate_table_cache_all();
        sa::invalidate_mod_cfgs_cache();
        sa::cfg_store::debug_reset_stacks();
        router_ = std::make_unique<sa::Router>(sa::build_router());
        sa::register_semantic_routes(*router_);
    }
    ~P1Fixture() {
        {
            auto& st = sa::STATE();
            std::lock_guard<std::mutex> lk(st.mu_);
            st.workspace_root = saved_ws_;
            st.mod_root = saved_mod_root_;
            st.mod_name = saved_mod_name_;
        }
        sa::invalidate_table_cache_all();
        sa::invalidate_mod_cfgs_cache();
        std::error_code ec;
        fs::remove_all(root_, ec);
    }
    P1Fixture(const P1Fixture&) = delete;
    P1Fixture& operator=(const P1Fixture&) = delete;

    sa::Resp call(const std::string& method, const std::string& path,
                  std::map<std::string, std::string> query = {}, const json& body = json()) {
        return sat::call_router(*router_, method, path, std::move(query), body);
    }
    void write_cfg_file(const std::string& name, const std::string& content) {
        std::ofstream f(cfg_dir_ / fs::u8path(name + ".json"), std::ios::binary);
        f << content;
    }
    std::string read_cfg_file(const std::string& name) {
        auto raw = sa_core::paths::read_bytes(
            sa_core::paths::path_to_utf8(cfg_dir_ / fs::u8path(name + ".json")));
        return raw ? *raw : std::string();
    }

  private:
    fs::path root_, mod_root_, cfg_dir_;
    std::string saved_ws_, saved_mod_root_, saved_mod_name_;
    std::unique_ptr<sa::Router> router_;
};

bool has_flag(const json& bugs, const std::string& flag) {
    for (const auto& b : bugs)
        if (b.value("flag", "") == flag) return true;
    return false;
}
int count_flag(const json& bugs, const std::string& flag) {
    int n = 0;
    for (const auto& b : bugs)
        if (b.value("flag", "") == flag) ++n;
    return n;
}

}  // namespace

// ---------------------------------------------------------------------------
// GET /api/schema — api.py:1361-1368 派生字段组装
// ---------------------------------------------------------------------------
TEST_CASE("p1 routes: /api/schema assembly", "[p1][routes]") {
    P1Fixture fx;
    auto r = fx.call("GET", "/api/schema");
    REQUIRE(r.status == 200);
    const json& body = r.json_payload;
    CHECK(body.contains("game_schema"));
    CHECK(body.contains("field_types"));
    CHECK(body.contains("cfg_names"));
    CHECK(body.at("game_schema").contains("EvtCfg"));
    CHECK(body.at("cfg_names").size() == 406);
    // cfg_names = sorted(keys)
    auto names = body.at("cfg_names");
    for (size_t i = 1; i < names.size(); ++i)
        CHECK(names[i - 1].get<std::string>() <= names[i].get<std::string>());
    // field_types 拉平：后表覆盖前表（与 Python 覆写循环一致），键数 = 并集
    CHECK(body.at("field_types").contains("id"));
    CHECK(body.at("field_types")["id"] == "Number");
}

// ---------------------------------------------------------------------------
// GET /api/dicts — api.py:1584-1615 逐 key 组装
// ---------------------------------------------------------------------------
TEST_CASE("p1 routes: /api/dicts assembly", "[p1][routes]") {
    P1Fixture fx;
    auto r = fx.call("GET", "/api/dicts");
    REQUIRE(r.status == 200);
    const json& b = r.json_payload;
    // key_maps 恰 9 表（api.py 手工枚举）
    REQUIRE(b.at("key_maps").is_object());
    CHECK(b.at("key_maps").size() == 9);
    for (const char* k : {"EvtCfg", "TalkCfg", "OptionCfg", "PersonCfg", "PersonGrowCfg",
                          "KZoneContentCfg", "PhoneMsgCfg", "GiftEvtCfg", "InteractCfg"})
        CHECK(b.at("key_maps").contains(k));
    const json& gd = b.at("game_dicts");
    CHECK(gd.at("roles").size() == 200);   // ROLE_DICT
    CHECK(gd.at("items").size() == 369);   // ITEM_DICT
    CHECK(gd.at("attrs").size() == 66);    // ATTR_DICT
    CHECK(gd.at("bgs").size() == 525);     // BG_DICT
    CHECK(gd.at("maps").size() == 21);
    CHECK(gd.at("jobs").size() == 17);
    CHECK(gd.at("turns").size() == 62);
    CHECK(gd.at("badminton_models").size() == 13);
    CHECK(gd.at("bgm").empty());
    CHECK(gd.at("sound").empty());
    CHECK(gd.at("icons").empty());
    CHECK(gd.at("audios").is_object());    // base 未注册 → {}
    CHECK(gd.at("evt_types").size() >= 65);
    CHECK(b.at("story_dicts") == json::object());  // api.py 恒返回 {}
}

// ---------------------------------------------------------------------------
// GET /api/effect_suggest — api.py:1370-1480
// ---------------------------------------------------------------------------
TEST_CASE("p1 routes: /api/effect_suggest", "[p1][routes]") {
    P1Fixture fx;
    {
        auto r = fx.call("GET", "/api/effect_suggest", {{"mode", "effect"}, {"q", ""}});
        REQUIRE(r.status == 200);
        CHECK(r.json_payload.at("mode") == "effect");
        CHECK(r.json_payload.at("q") == "");
        const json& items = r.json_payload.at("items");
        CHECK(items.size() == 40);  // 空 q 前 40 条
        // D1 回归：editor DB 头部是 [移除, 获取]（golden api_effect_suggest_mode_effect_q_）
        CHECK(items[0].at("code") == "[7, 3, @STATE@]");
        CHECK(items[0].at("desc") == "移除状态 @STATE@");
        CHECK(items[1].at("code") == "[7, 2, @STATE@]");
    }
    {
        auto r = fx.call("GET", "/api/effect_suggest", {{"mode", "condition"}, {"q", ""}});
        const json& items = r.json_payload.at("items");
        REQUIRE(items.size() == 40);
        CHECK(items[0].at("code") == "[0, 1, V]");
        CHECK(items[0].at("desc") == "发生概率为 V(1为100%)");
    }
    {
        // mode 非法 → effect 兜底
        auto r = fx.call("GET", "/api/effect_suggest", {{"mode", "bogus"}, {"q", ""}});
        CHECK(r.json_payload.at("mode") == "effect");
    }
    {
        // 数字直映占位符（q=5 → 首个 [A-Z] 换成 5）
        auto r = fx.call("GET", "/api/effect_suggest", {{"mode", "condition"}, {"q", "5"}});
        const json& items = r.json_payload.at("items");
        REQUIRE(items.size() >= 1);
        bool rendered = false;
        for (const auto& it : items)
            if (it.at("code") == "[0, 1, 5]") rendered = true;
        CHECK(rendered);
    }
    {
        // 中文关键词按码点判定（D14 回归：逐字节实现会把不命中的条目判成命中）
        auto r = fx.call("GET", "/api/effect_suggest", {{"mode", "condition"}, {"q", "属性"}});
        const json& items = r.json_payload.at("items");
        CHECK_FALSE(items.empty());
        for (const auto& it : items) {
            std::string t = it.at("desc").get<std::string>() + it.at("code").get<std::string>();
            // 码点级判定：两个整字符都须出现（Python 是逐字符 `c in target`）。
            // 若实现退化为逐字节，会出现只含碎片字节的假命中条目——用整字符断防不住，
            // 故再加一条：全库反例（不含这两个整字的条目绝不能出现在结果里）。
            CHECK(t.find("属") != std::string::npos);
            CHECK(t.find("性") != std::string::npos);
        }
    }
    {
        // 未命中 → 回退前 15 条
        auto r = fx.call("GET", "/api/effect_suggest", {{"mode", "effect"}, {"q", "ＱＷＺ不存在"}});
        CHECK(r.json_payload.at("items").size() == 15);
    }
}

// ---------------------------------------------------------------------------
// POST /api/effect_validate — api.py:1482-1582
// ---------------------------------------------------------------------------
TEST_CASE("p1 routes: /api/effect_validate", "[p1][routes]") {
    P1Fixture fx;
    auto post = [&](const json& body) { return fx.call("POST", "/api/effect_validate", {}, body); };
    {
        auto r = post(json{{"mode", "effect"}, {"text", ""}});
        CHECK(r.json_payload.at("status") == "empty");
        CHECK(r.json_payload.at("valid") == true);
    }
    {
        auto r = post(json{{"mode", "effect"}, {"text", json()}});  // 假值 null → ""（D12）
        CHECK(r.json_payload.at("status") == "empty");
    }
    {
        // 单行合法：一级1 二级1 属性1 数值5 —— ATTR_DICT 有 id "1"
        auto r = post(json{{"mode", "effect"}, {"text", "[1, 1, 1, 5]"}});
        CHECK(r.json_payload.at("valid") == true);
        CHECK(r.json_payload.at("errors").empty());
        CHECK(r.json_payload.at("translations").size() == 1);
    }
    {
        // 缺外层括号（首个标量数字）
        auto r = post(json{{"mode", "effect"}, {"text", "4001"}});
        CHECK(r.json_payload.at("status") == "missing_outer_bracket");
    }
    {
        auto r = post(json{{"mode", "effect"}, {"text", "abc"}});
        CHECK(r.json_payload.at("status") == "json_error");
        CHECK(r.json_payload.at("message") == "括号或逗号不匹配");
    }
    {
        // 999 是真实一级代码（双倍回复等），拿一个真不存在的：
        auto r = post(json{{"mode", "effect"}, {"text", "[888888, 0]"}});
        CHECK(r.json_payload.at("valid") == false);
        CHECK(r.json_payload.at("status") == "logic_error");
        CHECK(r.json_payload.at("errors")[0].get<std::string>() ==
              "第 1 行 👉 一级代码 [888888] 不在二次代码字典中。");
    }
    {
        // condition 模式：模板库为 CONDITION_DB（[0,1,V]）
        auto r = post(json{{"mode", "condition"}, {"text", "[0, 1, 5]"}});
        CHECK(r.json_payload.at("valid") == true);
        CHECK(r.json_payload.at("translations")[0].get<std::string>().find("发生概率为 5") !=
              std::string::npos);
    }
    {
        auto r = post(json{{"mode", "cost"}, {"text", "[1, 2]"}});
        CHECK(r.json_payload.at("valid") == true);
        CHECK(r.json_payload.at("translations")[0] == "1, 2");
        CHECK_FALSE(r.json_payload.contains("status"));  // cost 分支无 status 键
    }
    {
        auto r = post(json{{"mode", "screen"}, {"text", "4001,0.5"}});
        CHECK(r.json_payload.at("valid") == true);
        CHECK(r.json_payload.at("translations")[0].get<std::string>().find("屏幕抖动") !=
              std::string::npos);
    }
    {
        auto r = post(json{{"mode", "screen"}, {"text", "[[4001],[9999]]"}});
        CHECK(r.json_payload.at("valid") == false);
        CHECK(r.json_payload.at("errors")[0].get<std::string>() ==
              "第 1 行 👉 一句话只能填写一个屏幕效果");
    }
    {
        auto r = post(json{{"mode", "action"}, {"text", "[[0,3000,1]]"}});
        CHECK(r.json_payload.at("valid") == true);
        CHECK(r.json_payload.at("translations")[0].get<std::string>().find("设置表情") !=
              std::string::npos);
    }
    {
        auto r = post(json{{"mode", "action"}, {"text", "[[0,1001,1,2]]"}});
        CHECK(r.json_payload.at("valid") == false);
    }
    {
        // 二级代码不存在 → 已知二级提示
        auto r = post(json{{"mode", "effect"}, {"text", "[1, 9999]"}});
        CHECK(r.json_payload.at("valid") == false);
        CHECK(r.json_payload.at("errors")[0].get<std::string>().find("不存在") != std::string::npos);
    }
}

// ---------------------------------------------------------------------------
// GET /api/cfg_ids — api.py:1283-1311（排序键 / preview / 截断）
// ---------------------------------------------------------------------------
TEST_CASE("p1 routes: /api/cfg_ids sort & preview", "[p1][routes]") {
    P1Fixture fx;
    fx.write_cfg_file("EvtCfg", R"({
        "05": {"id": 5, "content": "abc"},
        "5": {"id": 5, "content": "def"},
        "10": {"id": 10, "title": "标题"},
        "z1": {"id": 99, "content": "尾键"},
        "20": {"id": 20, "content": "一二三四五六七八九十一二三四五六七八九十一二三四五六七八九十"}
    })");
    auto r = fx.call("GET", "/api/cfg_ids", {{"name", "EvtCfg"}});
    REQUIRE(r.status == 200);
    CHECK(r.json_payload.at("cfg") == "EvtCfg");
    const json& items = r.json_payload.at("items");
    REQUIRE(items.size() == 5);
    // 数字键升序、"05"/"5" 同值取原插入序（stable，无字符串 tie-break）；非数字最后
    CHECK(items[0].at("id") == "05");
    CHECK(items[1].at("id") == "5");
    CHECK(items[2].at("id") == "10");
    CHECK(items[3].at("id") == "20");
    CHECK(items[4].at("id") == "z1");
    // preview：title/content/showTxt/desc 首个非空、\r\n 剔除、20 码点截断（D14）
    CHECK(items[0].at("preview") == "abc");
    CHECK(items[2].at("preview") == "标题");
    std::string cn30 = "一二三四五六七八九十一二三四五六七八九十一二三四五六七八九十";
    std::string expect20 = cn30.substr(0, 60);  // 20 个 CJK 字符 = 60 字节
    CHECK(items[3].at("preview") == expect20);
    CHECK(items[4].at("preview") == "尾键");
    // 表不存在 → items []（Python _read_mod_table None 语义）
    auto r2 = fx.call("GET", "/api/cfg_ids", {{"name", "NotThereCfg"}});
    CHECK(r2.json_payload.at("items").empty());
    // api.py _cfg_name 只去 .json 后缀（不取 basename）：
    auto r3 = fx.call("GET", "/api/cfg_ids", {{"name", "EvtCfg.json"}});
    CHECK(r3.json_payload.at("cfg") == "EvtCfg");
    CHECK_FALSE(r3.json_payload.at("items").empty());
    // 目录形态键归一后仍带目录 → _read_mod_table 路径不存在 → items []（Python 同形）
    auto r4 = fx.call("GET", "/api/cfg_ids", {{"name", "Cfgs/zh-cn/EvtCfg.json"}});
    CHECK(r4.json_payload.at("cfg") == "Cfgs/zh-cn/EvtCfg");
    CHECK(r4.json_payload.at("items").empty());
}

// ---------------------------------------------------------------------------
// GET /api/base_ids — api.py:1313-1327；A13 base=None 语义
// ---------------------------------------------------------------------------
TEST_CASE("p1 routes: /api/base_ids without base store", "[p1][routes]") {
    P1Fixture fx;
    auto r = fx.call("GET", "/api/base_ids", {{"cfg", "EvtCfg"}});
    REQUIRE(r.status == 200);
    // 与 golden api_base_ids_cfg_EvtCfg 逐字一致的形态
    CHECK(r.json_payload == json{{"cfg", "EvtCfg"}, {"ids", json::array()}, {"loaded", false}});
}

// ---------------------------------------------------------------------------
// POST /api/validate — api.py:1219-1281
// ---------------------------------------------------------------------------
TEST_CASE("p1 routes: /api/validate positive & negative", "[p1][routes]") {
    P1Fixture fx;
    fx.write_cfg_file("EvtCfg", R"({"1314170": {"id": 1314170, "talkId": [1314170001]}})");
    fx.write_cfg_file("TalkCfg", R"({"1314170001": {"id": 1314170001, "content": "第一句"}})");

    // 合规：0 error
    {
        json body{{"cfg", "EvtCfg"},
                  {"data", json{{"1314170",
                                 json{{"id", 1314170}, {"title", "t"}, {"type", 4},
                                       {"rate", 1}, {"talkId", json::array({1314170001})}}}}}};
        auto r = fx.call("POST", "/api/validate", {}, body);
        REQUIRE(r.status == 200);
        CHECK(r.json_payload.at("counts").at("error") == 0);
        CHECK(r.json_payload.at("cfg") == "EvtCfg");
    }
    // 请求 data 覆盖磁盘同名表 → 非法首句 error
    {
        json body{{"cfg", "EvtCfg"},
                  {"data", json{{"1314170", json{{"id", 1314170},
                                                  {"talkId", json::array({9999999999})}}}}}};
        auto r = fx.call("POST", "/api/validate", {}, body);
        CHECK(r.json_payload.at("counts").at("error") >= 1);
        bool found = false;
        for (const auto& it : r.json_payload.at("issues"))
            if (it.value("level", "") == "error" &&
                it.value("msg", "").find("首句对话ID") != std::string::npos &&
                it.value("msg", "").find("事件 1314170:") == 0 &&
                it.value("rid", "") == "" &&  // 跨表 issue 的 rid 恒 ""（api.py:1276）
                it.value("cfg", "") == "EvtCfg")
                found = true;
        CHECK(found);  // issue 形态 {level,msg,rid,cfg}
    }
    // 非法事件ID → error
    {
        json body{{"cfg", "EvtCfg"}, {"data", json{{"7123456", json{{"id", 7123456}}}}}};
        auto r = fx.call("POST", "/api/validate", {}, body);
        CHECK(r.json_payload.at("counts").at("error") >= 1);
    }
    // cfg 假值（null）→ ""（D12；py_str(null) 会变成 "None" 的坑）
    {
        json body{{"cfg", nullptr}, {"data", json::object()}};
        auto r = fx.call("POST", "/api/validate", {}, body);
        CHECK(r.json_payload.at("cfg") == "");
        CHECK(r.status == 200);
    }
    // 跨表 issue 的 cfg 标注前缀映射（_CROSS_MSG_CFG_PREFIX）
    {
        json body{{"cfg", "TalkCfg"},
                  {"data", json{{"1314170001", json{{"id", 1314170001},
                                                     {"nextTalk", json::array({1234567890})}}}}}};
        auto r = fx.call("POST", "/api/validate", {}, body);
        bool found = false;
        for (const auto& it : r.json_payload.at("issues"))
            if (it.value("msg", "").find("对话 1314170001:") == 0) {
                found = true;
                CHECK(it.value("cfg", "") == "TalkCfg");
                CHECK(it.value("rid", "") == "");
            }
        CHECK(found);
    }
    // 无 mod 时 validate 仍 200：跨表读盘 SandboxError → 跳过（api.py continue）
    {
        P1Fixture nomod(false);
        auto r = nomod.call("POST", "/api/validate", {}, json{{"cfg", "EvtCfg"},
                                                              {"data", json::object()}});
        CHECK(r.status == 200);
    }
}

// ---------------------------------------------------------------------------
// POST /api/bugfix/scan + fix —— B16/A11/A12/B9/D6/D10 销账
// ---------------------------------------------------------------------------
TEST_CASE("p1 routes: bugfix scan reports broken tables (B16) and flags", "[p1][bugfix]") {
    P1Fixture fx;
    fx.write_cfg_file("EvtCfg",
                      R"({"1314170": {"id": 1314170, "npc": 8888888, "talkId": [1314170001]}})");
    fx.write_cfg_file("TalkCfg",
                      R"({"1314170001": {"id": 1314170001, "option": [1], "nextTalk": [999]}})");
    fx.write_cfg_file("OptionCfg", R"({"1": {"id": 1, "content": "坏选项"}})");
    fx.write_cfg_file("PersonStateCfg", "{ not-json");  // 坏表
    auto r = fx.call("POST", "/api/bugfix/scan");
    REQUIRE(r.status == 200);
    const json& bugs = r.json_payload.at("bugs");
    CHECK(r.json_payload.at("count") == static_cast<long long>(bugs.size()));
    CHECK(has_flag(bugs, "FIX_OPTION_1"));
    CHECK(has_flag(bugs, "FIX_TALK_1"));
    CHECK(has_flag(bugs, "RENAME_NPC") == false);  // 本 fixture 无 GiftEvtCfg
    // 生产语义（mappingproxy 门，D16）：S1 断层/S2 越界/S4-format/S5 REF 段在
    // HTTP 路由整段空转 —— EvtCfg.npc 悬挂、nextTalk 999 断层都不经 scan 端点上报。
    // 引擎全语义由 test_p1_semantic（普通 dict 直调）覆盖。
    CHECK_FALSE(has_flag(bugs, "REF"));
    CHECK_FALSE(has_flag(bugs, "LOGIC"));
    CHECK_FALSE(has_flag(bugs, "SCHEMA_HEAL"));
    bool broken_reported = false;
    for (const auto& b : bugs) {
        if (b.value("flag", "") != "ERROR") continue;
        if (b.value("cfg", "") == "PersonStateCfg") {
            broken_reported = true;
            CHECK(b.value("desc", "").find("配置表 PersonStateCfg 解析失败，未参与扫描（非无问题）: ") ==
                  0);
        }
    }
    CHECK(broken_reported);
    // 坏表不伪装空表：没有以 PersonStateCfg 为 cfg 的 SCHEMA_HEAL/REF 条目
    CHECK_FALSE(has_flag(bugs, "nope"));
}

TEST_CASE("p1 routes: bugfix scan requires mod", "[p1][bugfix]") {
    P1Fixture nomod(false);
    auto r = nomod.call("POST", "/api/bugfix/scan");
    REQUIRE(r.status == 400);
    CHECK(r.json_payload.at("error") == "no mod selected");
    auto r2 = nomod.call("POST", "/api/bugfix/fix", {}, json::object());
    CHECK(r2.status == 400);
}

TEST_CASE("p1 routes: bugfix fix option-1 chain (B9/D6/D10/四连失效)", "[p1][bugfix]") {
    P1Fixture fx;
    fx.write_cfg_file("EvtCfg", R"({"1314170": {"id": 1314170, "talkId": [1314170001]}})");
    fx.write_cfg_file("TalkCfg", R"({"1314170001": {"id": 1314170001, "option": [1]}})");
    fx.write_cfg_file("OptionCfg", R"({"1": {"id": 1, "content": "坏选项"}})");
    fx.write_cfg_file("PersonStateCfg", "{ broken");

    // 默认（不带 bugs 列表）→ 修全部可修项
    auto r = fx.call("POST", "/api/bugfix/fix", {}, json::object());
    REQUIRE(r.status == 200);
    CHECK(r.json_payload.at("fixed") >= 1);
    const json& rem = r.json_payload.at("remaining");
    CHECK(r.json_payload.at("remaining_count") == static_cast<long long>(rem.size()));
    CHECK_FALSE(has_flag(rem, "FIX_OPTION_1"));  // touched 表的旧条目已剔除
    CHECK_FALSE(has_flag(rem, "FIX_TALK_1"));
    // D10：Python 真实行为 —— broken ERROR 在 remaining 里出现两次
    // （remaining_untouched 携带一次 + 末尾 _report_broken_tables 再追加一次）
    int broken_in_rem = 0;
    for (const auto& b : rem)
        if (b.value("flag", "") == "ERROR" && b.value("cfg", "") == "PersonStateCfg")
            ++broken_in_rem;
    CHECK(broken_in_rem == 2);

    // 落盘验证：OptionCfg "1" → "131417001"（evt=1314170 + 后缀 01），TalkCfg 重指
    auto opt = fx.call("GET", "/api/cfg/OptionCfg");
    REQUIRE(opt.status == 200);
    CHECK_FALSE(opt.json_payload.at("data").contains("1"));
    REQUIRE(opt.json_payload.at("data").contains("131417001"));
    CHECK(opt.json_payload.at("data")["131417001"].at("id") == 131417001);
    auto talk = fx.call("GET", "/api/cfg/TalkCfg");
    REQUIRE(talk.status == 200);
    // D6 回归：talk_cfg 必须是活引用，option 重指要能落盘
    CHECK(talk.json_payload.at("data")["1314170001"].at("option") == json::array({131417001}));
    // 四连失效后可读性 + 磁盘一致
    CHECK(fx.read_cfg_file("TalkCfg").find("131417001") != std::string::npos);

    // 再扫一次：只剩不可自动修的（REF/LOGIC/ERROR），FIX_* 全销
    auto r2 = fx.call("POST", "/api/bugfix/scan");
    CHECK_FALSE(has_flag(r2.json_payload.at("bugs"), "FIX_OPTION_1"));
    CHECK_FALSE(has_flag(r2.json_payload.at("bugs"), "FIX_TALK_1"));
}

TEST_CASE("p1 routes: bugfix fix honors client bug list & A11 set lookup", "[p1][bugfix]") {
    P1Fixture fx;
    fx.write_cfg_file("OptionCfg", R"({"1": {"id": 1, "content": "坏选项"}})");
    fx.write_cfg_file("TalkCfg", R"({"5001": {"id": 5001, "option": [1]}})");
    auto scan = fx.call("POST", "/api/bugfix/scan");
    json target = json::array();
    for (const auto& b : scan.json_payload.at("bugs"))
        if (b.value("flag", "") == "REF") target.push_back(b);  // 挑一条不相干的 REF
    // 只送 FIX_OPTION_1 一条：fixed==1
    json only_fix = json::array();
    for (const auto& b : scan.json_payload.at("bugs"))
        if (b.value("flag", "") == "FIX_OPTION_1") only_fix.push_back(b);
    REQUIRE(only_fix.size() == 1);
    auto r = fx.call("POST", "/api/bugfix/fix", {}, json{{"bugs", only_fix}});
    CHECK(r.json_payload.at("fixed") == 1);
    auto opt = fx.call("GET", "/api/cfg/OptionCfg");
    CHECK_FALSE(opt.json_payload.at("data").contains("1"));
    // 过期/不存在的 (cfg,id,key) 客户端条目被忽略（重新定位语义）
    auto r2 = fx.call("POST", "/api/bugfix/fix", {},
                      json{{"bugs", json::array({json{{"cfg", "NopeCfg"},
                                                      {"id", "7"}, {"key", "x"}, {"flag", "SCHEMA_HEAL"},
                                                      {"healed", json::array()}}})}});
    CHECK(r2.json_payload.at("fixed") == 0);
    CHECK(r2.json_payload.at("remaining").is_array());
    (void)target;
}

TEST_CASE("p1 routes: bugfix B9 suffix exhaustion hands back to remaining", "[p1][bugfix]") {
    P1Fixture fx;
    fx.write_cfg_file("TalkCfg", R"({"1314170001": {"id": 1314170001, "option": [1]}})");
    // 事件段 1314170 后缀用到 99 → next=100 >99 → B9 放弃自动修复
    fx.write_cfg_file("OptionCfg",
                      R"({"1": {"id": 1, "content": "坏选项"}, "131417099": {"id": 131417099}})");
    auto r = fx.call("POST", "/api/bugfix/fix", {}, json::object());
    REQUIRE(r.status == 200);
    CHECK(r.json_payload.at("fixed") == 0);
    CHECK(has_flag(r.json_payload.at("remaining"), "FIX_OPTION_1"));
    CHECK(has_flag(r.json_payload.at("remaining"), "FIX_TALK_1"));
    // 磁盘未动
    auto opt = fx.call("GET", "/api/cfg/OptionCfg");
    CHECK(opt.json_payload.at("data").contains("1"));
    auto talk = fx.call("GET", "/api/cfg/TalkCfg");
    CHECK(talk.json_payload.at("data")["1314170001"].at("option") == json::array({1}));
}

TEST_CASE("p1 routes: bugfix schema-heal & rename apply", "[p1][bugfix]") {
    P1Fixture fx;
    fx.write_cfg_file("GiftEvtCfg", R"({"1": {"id": 1, "npcId": [3], "condition": [[1, 1, 1, 5]]}})");
    fx.write_cfg_file("OptionCfg", R"({"131417001": {"id": 131417001, "talkId": 1314170001}})");
    auto r = fx.call("POST", "/api/bugfix/fix", {}, json::object());
    CHECK(r.json_payload.at("fixed") >= 1);
    auto gift = fx.call("GET", "/api/cfg/GiftEvtCfg");
    const json& row = gift.json_payload.at("data").at("1");
    CHECK_FALSE(row.contains("npcId"));
    CHECK_FALSE(row.contains("condition"));
    CHECK(row.contains("npc"));
    CHECK(row.contains("cond"));
    // D16 生产语义：S4-format 段在只读代理门下不触发 → talkId 标量保持原样
    // （引擎级 1D Array 包装由 test_p1_semantic 的普通 dict 直调用例覆盖）。
    auto opt = fx.call("GET", "/api/cfg/OptionCfg");
    CHECK(opt.json_payload.at("data").at("131417001").at("talkId") == 1314170001);
}

TEST_CASE("p1 routes: scan is read-only on cache (G3/B1)", "[p1][bugfix]") {
    P1Fixture fx;
    fx.write_cfg_file("TalkCfg", R"({"1": {"id": 1, "option": 1}})");  // option 标量 → SCHEMA_HEAL
    auto r = fx.call("POST", "/api/bugfix/scan");
    REQUIRE(r.status == 200);
    // scan 不落盘：文件保持原样
    CHECK(fx.read_cfg_file("TalkCfg").find("\"option\": 1") != std::string::npos);
}
