// test_semantic_graph.cpp — [p1][graph] 只读分析端点的进程内黑盒测试：
// POST /api/effect/parse（关系图/时间线端点已随前端 graph 视图一并移除）。
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
        // D4：失败位置（0-based 码点偏移 + 1-based 行列），供前端显示「第 N 个字符附近」。
        CHECK(b.contains("error_offset"));
        CHECK(b.contains("error_line"));
        CHECK(b.contains("error_col"));
        CHECK(b.at("error_line").get<long long>() >= 1);
        CHECK(b.at("error_col").get<long long>() >= 1);
        CHECK(b.at("error_offset").get<long long>() >= 0);
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
    // A1：数字槽标签来自模板（"属性 @ATTR@ 增加 V" 跳过占位符取上文词），不再统一"数值"。
    CHECK(slots[1].at("label") == "增加");
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
// A1 元数据：family/ops 在 /api/effect_suggest 与 /api/effect/parse 一致；
// 数字槽 label 来自模板（不再统一"数值"）；范围模板给 下限/上限 + 上下限下标。
// ---------------------------------------------------------------------------
TEST_CASE("graph: A1 family/ops metadata consistency", "[p1][graph]") {
    GraphFixture fx;
    // suggest 拉全量 condition 目录（235 条 > 默认 40，limit=1000 取全）。
    auto sr = fx.call("GET", "/api/effect_suggest",
                      {{"mode", "condition"}, {"q", ""}, {"limit", "1000"}});
    REQUIRE(sr.status == 200);
    const json& items = sr.json_payload.at("items");
    REQUIRE(items.size() >= 200);

    json age_ops = json();
    json age_item = json();
    for (const auto& it : items)
        if (it.value("raw_code", "") == "[1, 1, V]") { age_item = it; age_ops = it.at("ops"); }
    REQUIRE_FALSE(age_item.is_null());
    CHECK(age_item.at("family") == "1|年龄");
    CHECK(age_item.at("family_label") == "年龄");
    CHECK(age_item.at("description") == "年龄 >= V");
    // 参数 label 来自模板：V → 上文词「年龄」。
    REQUIRE(age_item.at("slots").size() == 1);
    CHECK(age_item.at("slots")[0].at("label") == "年龄");

    // 同一概念折叠 3 个变体，按 = > ≥ < ≤ ≠ 范围 循环序。
    REQUIRE(age_ops.size() == 3);
    CHECK(age_ops[0].at("op") == "≥");
    CHECK(age_ops[0].at("code") == "[1, 1, V]");
    CHECK(age_ops[0].at("value_index") == 2);
    CHECK(age_ops[0].at("upper_index") == -1);
    CHECK(age_ops[1].at("op") == "≤");
    CHECK(age_ops[1].at("code") == "[1, 2, V]");
    CHECK(age_ops[2].at("op") == "范围");
    CHECK(age_ops[2].at("code") == "[1, 3, X, Y]");
    CHECK(age_ops[2].at("value_index") == 2);
    CHECK(age_ops[2].at("upper_index") == 3);
    // ops 内嵌目标变体的 slots（供前端行内切换算符），范围上下限 label 分明。
    REQUIRE(age_ops[2].at("slots").size() == 2);
    CHECK(age_ops[2].at("slots")[0].at("label") == "下限");
    CHECK(age_ops[2].at("slots")[1].at("label") == "上限");

    // parse 侧同概念：family/ops 与 suggest 完全一致（模板串同源，同一派生点）。
    json pb = parse_call(fx, "[1, 1, 5]", "condition");
    const json& r0 = pb.at("rows")[0];
    REQUIRE(r0.at("template").is_object());
    CHECK(r0.at("template").at("family") == "1|年龄");
    CHECK(r0.at("template").at("family_label") == "年龄");
    CHECK(r0.at("template").at("description") == "年龄 >= V");
    CHECK(r0.at("template").at("op") == "≥");
    CHECK(r0.at("template").at("value_index") == 2);
    CHECK(r0.at("template").at("upper_index") == -1);
    CHECK(r0.at("template").at("ops") == age_ops);
    CHECK(r0.at("slots")[0].at("label") == "年龄");
    CHECK(r0.at("slots")[0].at("value") == "5");

    // 范围行：上下限槽标 下限/上限，值落到 X/Y。
    json rb = parse_call(fx, "[1, 3, 5, 10]", "condition");
    const json& rr = rb.at("rows")[0];
    CHECK(rr.at("template").at("op") == "范围");
    REQUIRE(rr.at("slots").size() == 2);
    CHECK(rr.at("slots")[0].at("label") == "下限");
    CHECK(rr.at("slots")[0].at("value") == "5");
    CHECK(rr.at("slots")[1].at("label") == "上限");
    CHECK(rr.at("slots")[1].at("value") == "10");

    // cost：模板级标签同样生效（"…数量 V" → 数量）。
    json cb = parse_call(fx, "[1, 20]", "cost");
    CHECK(cb.at("rows")[0].at("template").at("family_label") == "消耗 属性 @ATTR@ 数量");
    CHECK(cb.at("rows")[0].at("slots")[1].at("label") == "数量");
}

TEST_CASE("graph: /api/effect/parse partial fallback", "[p1][graph]") {
    GraphFixture fx;
    {
        // 整体 JSON 坏（第二行 `x` 非法），但第一行完整 → 逐行回退：好行照常、
        // 坏行 {error, display, unrecognized:true}，整体 status=partial、ok=false。
        json b = parse_call(fx, "[1, 1, 1, 5], [999, x]", "effect");
        CHECK(b.at("ok") == false);
        CHECK(b.at("status") == "partial");
        REQUIRE(b.at("rows").size() == 2);
        CHECK(b["rows"][0].at("error").is_null());
        CHECK_FALSE(b["rows"][0].contains("unrecognized"));
        CHECK(b["rows"][1].at("unrecognized") == true);
        CHECK(b["rows"][1]["error"].is_string());
        CHECK(b["rows"][1].at("display") == "[999, x]");
        CHECK(b["rows"][1].at("primary").is_null());
    }
    {
        // 一行都救不回来 → 维持整体失败语义（不引入 partial）
        json b = parse_call(fx, "[999, x]", "effect");
        CHECK(b.at("status") == "json_error");
        CHECK(b.at("ok") == false);
        // D4：此时也带定位信息，且偏移落在出错字符附近。
        CHECK(b.contains("error_offset"));
        CHECK(b.at("error_offset").get<long long>() >= 0);
    }
    {
        // 分号分隔（前端 serializeBlockRows 的书写习惯）：同样能整体拆解
        json b = parse_call(fx, "[1, 1, 1, 5]; [1, 1, 1, 6]", "effect");
        CHECK(b.at("status") != "json_error");
        REQUIRE(b.at("rows").size() == 2);
        CHECK(b["rows"][0].at("error").is_null());
        CHECK(b["rows"][1].at("error").is_null());
    }
}
