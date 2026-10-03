// wip/P1/test_p1_routes.cpp — [p1] 九条语义路由的进程内黑盒测试（sat::call_router，
// 同 test_s1_read_exit / P2 的做法：build_router() 上嫁接 register_semantic_routes，
// 与 backend_wip 的挂载路径一致）。fixture 为 temp workspace + 一个含 Cfgs/zh-cn
// 的 mod；绝不触碰真实 Mods。
#include <catch_amalgamated.hpp>

#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <memory>
#include <mutex>

#include "test_support.h"

#include "sa_core/env_store.h"
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

// MSVC 的 _putenv_s / POSIX 的 setenv（同 test_assets_routes.cpp 写法），空值=清除。
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
        // editor_root 隔离：/api/usage 与 /api/settings/editor 的存储都落在
        // <editor_root> 下，指到临时目录保证 golden（空 q 前 40）与用例互不污染。
        saved_data_root_ = getenv_portable("EDITOR_DATA_ROOT");
        putenv_portable("EDITOR_DATA_ROOT", "");
        sa::detail::set_editor_root(sa_core::paths::path_to_utf8(root_ / "data"));
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
        sa::detail::set_editor_root("");
        putenv_portable("EDITOR_DATA_ROOT", saved_data_root_.c_str());
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

    std::string data_root() const { return sa_core::paths::path_to_utf8(root_ / "data"); }

  private:
    fs::path root_, mod_root_, cfg_dir_;
    std::string saved_ws_, saved_mod_root_, saved_mod_name_, saved_data_root_;
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
    // key_maps：原 9 表（api.py 手工枚举）+ 新纳入编辑页的 66 张玩法表标签
    // （InteractCfg 本在原 9 表内，仅补 npc 字段，不计入新增）
    REQUIRE(b.at("key_maps").is_object());
    CHECK(b.at("key_maps").size() == 75);
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
    // D16 修复后（生产路由走 Mapping 全语义，不再被 mappingproxy 门空转）：
    // S1 断层（LOGIC）、S5 REF、S4-format（SCHEMA_HEAL）现在都经 scan 端点上报。
    // 与修复后 Python 后端逐条对齐（见 wip/P1/smoke.py --equiv 的 disk 对比）。
    CHECK(has_flag(bugs, "REF"));
    CHECK(has_flag(bugs, "LOGIC"));
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
    // D16 修复后：S4-format 段经 HTTP 路由触发，标量 talkId 按 1D Array 包装。
    // （修复前该段被 mappingproxy 门空转，talkId 保持标量——测试随之更正。）
    auto opt = fx.call("GET", "/api/cfg/OptionCfg");
    CHECK(opt.json_payload.at("data").at("131417001").at("talkId") == json::array({1314170001}));
}

TEST_CASE("p1 routes: scan is read-only on cache (G3/B1)", "[p1][bugfix]") {
    P1Fixture fx;
    fx.write_cfg_file("TalkCfg", R"({"1": {"id": 1, "option": 1}})");  // option 标量 → SCHEMA_HEAL
    auto r = fx.call("POST", "/api/bugfix/scan");
    REQUIRE(r.status == 200);
    // scan 不落盘：文件保持原样
    CHECK(fx.read_cfg_file("TalkCfg").find("\"option\": 1") != std::string::npos);
}

// ---------------------------------------------------------------------------
// 补全优化 + 无代码模式（M0 后端）：/api/settings/editor、/api/usage、
// effect_suggest 的 slots/打分/最近置顶、/api/roles 人物目录。
// P1Fixture 已把 editor_root 指到临时 data 目录，各用例互不污染。
// ---------------------------------------------------------------------------
TEST_CASE("p1 routes: /api/settings/editor no-code toggle", "[p1][routes][nocode]") {
    P1Fixture fx;
    auto g = fx.call("GET", "/api/settings/editor");
    REQUIRE(g.status == 200);
    CHECK(g.json_payload.at("settings").at("noCodeMode") == false);

    auto p = fx.call("PUT", "/api/settings/editor", {}, json{{"noCodeMode", true}});
    REQUIRE(p.status == 200);
    CHECK(p.json_payload.at("ok") == true);
    CHECK(p.json_payload.at("settings").at("noCodeMode") == true);
    CHECK(fx.call("GET", "/api/settings/editor").json_payload.at("settings")
              .at("noCodeMode") == true);

    // 包裹形态 {"settings": {...}} 也可写。
    auto p2 = fx.call("PUT", "/api/settings/editor", {},
                      json{{"settings", json{{"noCodeMode", false}}}});
    CHECK(p2.json_payload.at("settings").at("noCodeMode") == false);

    // 非法值（非 bool）与未知键：忽略不改写。
    auto p3 = fx.call("PUT", "/api/settings/editor", {}, json{{"noCodeMode", "yes"}});
    CHECK(p3.json_payload.at("settings").at("noCodeMode") == false);
    auto p4 = fx.call("PUT", "/api/settings/editor", {}, json{{"bogus", 1}});
    CHECK(p4.json_payload.at("settings").at("noCodeMode") == false);

    // 落盘在 editor_env.json 的 no_code_mode 键（与 oobe 等同库）。
    fx.call("PUT", "/api/settings/editor", {}, json{{"noCodeMode", true}});
    json env = sa_core::env_store::read_editor_env(fx.data_root());
    CHECK(env.value("no_code_mode", false) == true);
}

TEST_CASE("p1 routes: /api/settings/editor appearance mode (白日模式)", "[p1][routes][appearance]") {
    P1Fixture fx;

    // 默认暗色；appearance_mode 从没写过 → explicit=false（GUI 据此把本地
    // 已选外观种子上传，而不是被默认值覆盖）。
    auto g = fx.call("GET", "/api/settings/editor");
    REQUIRE(g.status == 200);
    CHECK(g.json_payload.at("settings").at("appearanceMode") == "dark");
    CHECK(g.json_payload.at("meta").at("appearanceModeExplicit") == false);

    // PUT light 生效并转 explicit=true；noCodeMode 不受影响。
    auto p = fx.call("PUT", "/api/settings/editor", {}, json{{"appearanceMode", "light"}});
    REQUIRE(p.status == 200);
    CHECK(p.json_payload.at("settings").at("appearanceMode") == "light");
    CHECK(p.json_payload.at("meta").at("appearanceModeExplicit") == true);
    CHECK(p.json_payload.at("settings").at("noCodeMode") == false);
    CHECK(fx.call("GET", "/api/settings/editor").json_payload.at("settings")
              .at("appearanceMode") == "light");

    // 包裹形态 {"settings": {...}} 也可写；system 是合法枚举。
    auto p2 = fx.call("PUT", "/api/settings/editor", {},
                      json{{"settings", json{{"appearanceMode", "system"}}}});
    CHECK(p2.json_payload.at("settings").at("appearanceMode") == "system");

    // 两键互不覆盖：写 appearance 不动 noCode，反之亦然。
    fx.call("PUT", "/api/settings/editor", {}, json{{"noCodeMode", true}});
    auto p3 = fx.call("PUT", "/api/settings/editor", {}, json{{"appearanceMode", "dark"}});
    CHECK(p3.json_payload.at("settings").at("noCodeMode") == true);
    CHECK(p3.json_payload.at("settings").at("appearanceMode") == "dark");

    // 非法值 / 非字符串 / 未知键：忽略不改写（仍是上一次的 dark）。
    auto p4 = fx.call("PUT", "/api/settings/editor", {}, json{{"appearanceMode", "neon"}});
    CHECK(p4.json_payload.at("settings").at("appearanceMode") == "dark");
    CHECK(p4.json_payload.at("meta").at("appearanceModeExplicit") == true);
    auto p5 = fx.call("PUT", "/api/settings/editor", {}, json{{"appearanceMode", 3}});
    CHECK(p5.json_payload.at("settings").at("appearanceMode") == "dark");
    auto p6 = fx.call("PUT", "/api/settings/editor", {}, json{{"bogus", 1}});
    CHECK(p6.json_payload.at("settings").at("appearanceMode") == "dark");

    // 落盘在 editor_env.json 的 appearance_mode 键。
    json env = sa_core::env_store::read_editor_env(fx.data_root());
    CHECK(env.value("appearance_mode", std::string()) == "dark");
}

TEST_CASE("p1 routes: /api/settings/editor theme color (用户主题色)", "[p1][routes][appearance]") {
    P1Fixture fx;

    // 默认品牌紫；theme_color 从没写过 → explicit=false（GUI 据此把本地
    // 已选主题色种子上传，而不是被默认值覆盖）。
    auto g = fx.call("GET", "/api/settings/editor");
    REQUIRE(g.status == 200);
    CHECK(g.json_payload.at("settings").at("themeColor") == "#6c5ce7");
    CHECK(g.json_payload.at("meta").at("themeColorExplicit") == false);

    // PUT 生效并转 explicit=true；大小写输入归一为小写落盘。
    auto p = fx.call("PUT", "/api/settings/editor", {}, json{{"themeColor", "#0078D4"}});
    REQUIRE(p.status == 200);
    CHECK(p.json_payload.at("settings").at("themeColor") == "#0078d4");
    CHECK(p.json_payload.at("meta").at("themeColorExplicit") == true);
    CHECK(fx.call("GET", "/api/settings/editor").json_payload.at("settings")
              .at("themeColor") == "#0078d4");

    // 非法值 / 非字符串 / 未知键：忽略不改写（仍是上一次的 #0078d4）。
    auto p2 = fx.call("PUT", "/api/settings/editor", {}, json{{"themeColor", "red"}});
    CHECK(p2.json_payload.at("settings").at("themeColor") == "#0078d4");
    auto p3 = fx.call("PUT", "/api/settings/editor", {}, json{{"themeColor", "#12345"}});
    CHECK(p3.json_payload.at("settings").at("themeColor") == "#0078d4");
    auto p4 = fx.call("PUT", "/api/settings/editor", {}, json{{"themeColor", 42}});
    CHECK(p4.json_payload.at("settings").at("themeColor") == "#0078d4");

    // 三键互不覆盖；落盘在 editor_env.json 的 theme_color 键。
    auto p5 = fx.call("PUT", "/api/settings/editor", {},
                      json{{"settings", json{{"themeColor", "#e5484d"}, {"appearanceMode", "light"}}}});
    CHECK(p5.json_payload.at("settings").at("themeColor") == "#e5484d");
    CHECK(p5.json_payload.at("settings").at("appearanceMode") == "light");
    CHECK(p5.json_payload.at("settings").at("noCodeMode") == false);
    json env = sa_core::env_store::read_editor_env(fx.data_root());
    CHECK(env.value("theme_color", std::string()) == "#e5484d");
}

TEST_CASE("p1 routes: /api/usage record + top", "[p1][routes][nocode]") {
    P1Fixture fx;
    auto post = [&](const json& b) { return fx.call("POST", "/api/usage", {}, b); };
    CHECK(post(json{{"kind", "command"}, {"key", "cfg"}}).json_payload.at("count") == 1);
    CHECK(post(json{{"kind", "command"}, {"key", "cfg"}}).json_payload.at("count") == 2);
    CHECK(post(json{{"kind", "command"}, {"key", "validate"}}).status == 200);

    auto g = fx.call("GET", "/api/usage", {{"kind", "command"}});
    REQUIRE(g.status == 200);
    const json& items = g.json_payload.at("items");
    REQUIRE(items.size() == 2);
    CHECK(items[0].at("key") == "cfg");  // count 高者在前
    CHECK(items[0].at("count") == 2);
    CHECK(items[1].at("key") == "validate");

    auto g1 = fx.call("GET", "/api/usage", {{"kind", "command"}, {"limit", "1"}});
    CHECK(g1.json_payload.at("items").size() == 1);

    CHECK(post(json{{"kind", "bogus"}, {"key", "x"}}).status == 400);
    CHECK(post(json{{"kind", "command"}}).status == 400);
    CHECK(fx.call("GET", "/api/usage").status == 400);
}

TEST_CASE("p1 routes: effect_suggest slots, scoring and recent-first", "[p1][routes][nocode]") {
    P1Fixture fx;
    {
        auto r = fx.call("GET", "/api/effect_suggest", {{"mode", "effect"}, {"q", "属性"}});
        const json& items = r.json_payload.at("items");
        REQUIRE_FALSE(items.empty());
        // desc 前缀命中排最前（score=100，同分时 usage 才 +≤5）。
        CHECK(items[0].at("desc").get<std::string>().rfind("属性", 0) == 0);
        CHECK(items[0].at("score").get<int>() >= 100);
        const json* attrs = nullptr;
        for (const auto& it : items)
            if (it.at("raw_code") == "[1, 1, @ATTR@, V]") attrs = &it;
        REQUIRE(attrs != nullptr);
        const json& slots = attrs->at("slots");
        REQUIRE(slots.size() == 2);
        CHECK(slots[0].at("kind") == "dict");
        CHECK(slots[0].at("name") == "ATTR");
        CHECK(slots[0].at("dict") == "ATTR");
        CHECK(slots[0].at("label") == "属性");
        CHECK(slots[1].at("kind") == "number");
        CHECK(slots[1].at("name") == "V");
        CHECK(slots[1].at("count") == 1);
    }
    {
        // action 指令行 [N, 1001, 0, S]：N/S 都是 number 槽。
        auto r = fx.call("GET", "/api/effect_suggest", {{"mode", "action"}, {"q", "滑动入场"}});
        bool found = false;
        for (const auto& it : r.json_payload.at("items")) {
            if (it.at("raw_code").get<std::string>().find("1001") != std::string::npos) {
                found = true;
                const json& slots = it.at("slots");
                CHECK(std::any_of(slots.begin(), slots.end(), [](const json& s) {
                    return s.at("kind") == "number" && s.at("name") == "N";
                }));
                CHECK(std::any_of(slots.begin(), slots.end(), [](const json& s) {
                    return s.at("kind") == "number" && s.at("name") == "S";
                }));
            }
        }
        CHECK(found);
    }
    {
        // 空 q：最近接受过的模板置顶（usage kind=mode key=raw_code），仍满 40 条。
        CHECK(fx.call("POST", "/api/usage", {},
                      json{{"kind", "condition"}, {"key", "[0, 1, V]"}}).status == 200);
        auto r = fx.call("GET", "/api/effect_suggest", {{"mode", "condition"}, {"q", ""}});
        const json& items = r.json_payload.at("items");
        REQUIRE(items.size() == 40);
        CHECK(items[0].at("raw_code") == "[0, 1, V]");
        // 目录头部同样是它，但 used 去重后第二项顺延到目录第二条，不重复出现。
        CHECK(items[1].at("raw_code") != "[0, 1, V]");
        int dup = 0;
        for (const auto& it : items)
            if (it.at("raw_code") == "[0, 1, V]") ++dup;
        CHECK(dup == 1);
    }
}

TEST_CASE("p1 routes: /api/roles catalog (dict + PersonCfg merge)", "[p1][routes][nocode]") {
    P1Fixture fx;
    fx.write_cfg_file("PersonCfg",
                      R"({"101": {"id": 101, "name": "小美", "gender": 0, "url": ["Role/xiaomei.png"]},)"
                      R"("999": {"id": 999, "name": "自定义", "url2": ["Role2/z.png"]}})");
    auto r = fx.call("GET", "/api/roles");
    REQUIRE(r.status == 200);
    CHECK(r.json_payload.at("total").get<int>() >= 200);
    const json& roles = r.json_payload.at("roles");
    auto find = [&](const std::string& id) -> const json* {
        for (const auto& x : roles)
            if (x.at("id") == id) return &x;
        return nullptr;
    };
    const json* narr = find("-1");
    REQUIRE(narr != nullptr);
    CHECK(narr->at("name") == "旁白");
    CHECK(narr->at("portrait") == "");
    CHECK(narr->at("portrait1") == "");
    CHECK(narr->at("portrait2") == "");
    const json* xm = find("101");
    REQUIRE(xm != nullptr);
    CHECK(xm->at("name") == "小美");
    CHECK(xm->at("gender") == 0);
    CHECK(xm->at("portrait") == "Role/xiaomei.png");
    CHECK(xm->at("portrait1") == "Role/xiaomei.png");  // url 首项 = 小学立绘
    CHECK(xm->at("portrait2") == "");
    const json* self = find("999");
    REQUIRE(self != nullptr);
    CHECK(self->at("portrait") == "Role2/z.png");  // url2 优先
    CHECK(self->at("portrait1") == "");
    CHECK(self->at("portrait2") == "Role2/z.png");  // url2 首项 = 中学立绘
    // 数值 id 升序在前：第一个是 -1（旁白）。
    CHECK(roles[0].at("id") == "-1");
    // q 过滤：名字包含 / id 全等。
    auto f = fx.call("GET", "/api/roles", {{"q", "小美"}});
    REQUIRE(f.json_payload.at("roles").size() == 1);
    CHECK(f.json_payload.at("roles")[0].at("id") == "101");
    auto fid = fx.call("GET", "/api/roles", {{"q", "-1"}});
    CHECK(fid.json_payload.at("roles")[0].at("name") == "旁白");
}

// 工作区 PersonCfg 只含少数行（角色线 mod 常态）时，未被覆盖的官方角色必须
// 保留立绘键；否则 /api/roles 的 portrait* 全空，人物选择器整片占位、且因 key
// 为空根本不发 /api/aa/preview 取图。
TEST_CASE("p1 routes: partial workspace PersonCfg keeps official portraits",
          "[p1][routes][nocode]") {
    P1Fixture fx;
    fx.write_cfg_file("PersonCfg",
                      R"({"105": {"id": 105, "name": "肖清雅MOD", "url": ["role_mod105"]}})");
    auto r = fx.call("GET", "/api/roles");
    REQUIRE(r.status == 200);
    const json& roles = r.json_payload.at("roles");
    auto find = [&](const std::string& id) -> const json* {
        for (const auto& x : roles)
            if (x.at("id") == id) return &x;
        return nullptr;
    };
    const json* m = find("105");
    REQUIRE(m != nullptr);
    CHECK(m->at("name") == "肖清雅MOD");
    CHECK(m->at("portrait1") == "role_mod105");
    // 未被 mod 覆盖的官方角色（102 = 薛诗蕾，随包表带 role_xiaolei）仍带立绘键。
    const json* official = find("102");
    REQUIRE(official != nullptr);
    CHECK(!official->at("portrait").get<std::string>().empty());
}

// 工作区没有 PersonCfg 时（网页/托管环境的常态），/api/roles 必须回落到随包
// 官方人物表，否则 portrait* 全空、人物资源库显示不出立绘。
TEST_CASE("p1 routes: /api/roles falls back to bundled PersonCfg",
          "[p1][routes][nocode]") {
    P1Fixture fx;  // 不写任何 PersonCfg 到工作区
    auto r = fx.call("GET", "/api/roles");
    REQUIRE(r.status == 200);
    const json& roles = r.json_payload.at("roles");
    const json* r101 = nullptr;
    for (const auto& x : roles)
        if (x.at("id") == "101") { r101 = &x; break; }
    REQUIRE(r101 != nullptr);
    // 官方 PersonCfg 的 101 = 罗晓纯，url/url2 均在。
    CHECK(r101->at("name") == "罗晓纯");
    CHECK(r101->at("portrait1") == "role_xiaochun");
    CHECK(r101->at("portrait2") == "role_xiaochun2");
    CHECK(r101->at("portrait") == "role_xiaochun2");  // url2 优先
    // 至少有一批角色拿到立绘键（回落生效的强断言）。
    int with_portrait = 0;
    for (const auto& x : roles) {
        if (!x.at("portrait").get<std::string>().empty()) ++with_portrait;
    }
    CHECK(with_portrait >= 100);
}
