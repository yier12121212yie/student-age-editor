// wip/P1/test_p1_semantic.cpp — [p1] 纯语义引擎测试（无 HTTP）。
// 移植 backend/editor/core/test_ref_rules.py 的全部 16 例（黑盒化：直接打
// sa::p1::check_refs / scan_bugs / apply_fix，等价于 pytest 里 import 的
// ref_rules.check_refs / bugfix_service.scan_bugs|apply_fix），外加
// guide_rules/data_dicts 标量归一的抽查。
#include <catch_amalgamated.hpp>

#include <algorithm>
#include <set>

#include "semantic_assets.h"
#include "semantic_logic.h"

using sa::p1::json;

namespace {

json j(const char* s) { return json::parse(s); }
json j(const std::string& s) { return json::parse(s); }

// 找 flag==REF 且 field 匹配的 issue（镜像 Python 的列表过滤）。
std::vector<json> ref_bugs(const json& bugs, const std::string& field = "") {
    std::vector<json> out;
    for (const auto& b : bugs) {
        if (b.value("flag", "") != "REF") continue;
        if (!field.empty() && b.value("key", "") != field) continue;
        out.push_back(b);
    }
    return out;
}

std::set<long long> int_keys(const std::map<std::string, std::string>& pool) {
    std::set<long long> out;
    for (auto& kv : pool) {
        try {
            size_t i = 0;
            long long v = std::stoll(kv.first, &i);
            if (i == kv.first.size()) out.insert(v);
        } catch (...) {}
    }
    return out;
}

}  // namespace

TEST_CASE("p1 check_refs: valid table refs pass", "[p1][ref_rules]") {
    json tables = j(R"({
        "ActionCfg": {"1": {"id": 1, "evtId": 1000001, "map": 101, "bg": 3}},
        "EvtCfg": {"1000001": {"id": 1000001}},
        "MapCfg": {"101": {"id": 101}},
        "BgCfg": {"3": {"id": 3}}})");
    CHECK(sa::p1::check_refs(tables, json()).empty());
}

TEST_CASE("p1 check_refs: dangling single value reported without heal", "[p1][ref_rules]") {
    json tables = j(R"({
        "EvtCfg": {"1000001": {"id": 1000001}},
        "ActionCfg": {"1": {"id": 1, "evtId": 9999999}}})");
    json issues = sa::p1::check_refs(tables, json());
    REQUIRE(issues.size() == 1);
    CHECK(issues[0].value("cfg", "") == "ActionCfg");
    CHECK(issues[0].value("field", "") == "evtId");
    CHECK(issues[0].value("target", "") == "EvtCfg");
    CHECK(issues[0].at("healed").is_null());
    // desc 逐字对照 ref_rules.py:214 模板
    CHECK(issues[0].value("desc", "") == "字段'evtId'引用了不存在的EvtCfg id 9999999");
}

TEST_CASE("p1 check_refs: array field heals dangling refs", "[p1][ref_rules]") {
    json tables = j(R"({
        "MapCfg": {"101": {"id": 101}, "102": {"id": 102}},
        "TalkCfg": {"1000001001": {"id": 1000001001}},
        "NpcActivityCfg": {"5": {"id": 5, "talkId": [1000001001, 2000000001]}}})");
    json issues = sa::p1::check_refs(tables, json());
    std::vector<json> dangling;
    for (auto& i : issues)
        if (i.value("field", "") == "talkId") dangling.push_back(i);
    REQUIRE(dangling.size() == 1);
    CHECK(dangling[0].at("healed") == j("[1000001001]"));
}

TEST_CASE("p1 check_refs: healed keeps exempt sentinels", "[p1][ref_rules]") {
    // 豁免值 0/-1/-2 必须留在 healed 里（否则一键修复悄悄删掉「无说话人」哨兵）
    json tables = j(R"({
        "PersonCfg": {"6": {"id": 6}},
        "TalkCfg": {"1": {"id": 1, "roleIds": [0, 99999, 6]}}})");
    json issues = sa::p1::check_refs(tables, json());
    std::vector<json> dangling;
    for (auto& i : issues)
        if (i.value("cfg", "") == "TalkCfg" && i.value("field", "") == "roleIds")
            dangling.push_back(i);
    REQUIRE(dangling.size() == 1);
    CHECK(dangling[0].at("healed") == j("[0, 6]"));
}

TEST_CASE("p1 check_refs: exempt values pass", "[p1][ref_rules]") {
    json tables = j(R"({
        "ActionCfg": {"1": {"id": 1, "evtId": 0, "next": -1, "map": -2}},
        "EvtCfg": {"1000001": {"id": 1000001}}})");
    CHECK(sa::p1::check_refs(tables, json()).empty());
}

TEST_CASE("p1 check_refs: extra base ids satisfy", "[p1][ref_rules]") {
    json tables = j(R"({
        "PersonCfg": {"101": {"id": 101}},
        "BgCfg": {"5": {"id": 5}},
        "MapCfg": {"5": {"id": 5, "bg": 55}}})");
    json extra = j(R"({"BgCfg": [55, 5]})");
    CHECK(sa::p1::check_refs(tables, extra).empty());
}

TEST_CASE("p1 check_refs: lazy extra ids satisfy (index-access semantics)", "[p1][ref_rules]") {
    // 镜像 _LazyIdSets：下标访问给 base 键集。C++ 侧 scan_bugs 预物化成数组等价。
    json tables = j(R"({
        "TalkCfg": {"1000001001": {"id": 1000001001}},
        "NpcActivityCfg": {"5": {"id": 5, "talkId": [2000000001]}}})");
    json extra = j(R"({"TalkCfg": ["2000000001"]})");
    CHECK(sa::p1::check_refs(tables, extra).empty());
}

TEST_CASE("p1 check_refs: lazy extra ids enable dangling detection", "[p1][ref_rules]") {
    // Mod 无目标表数据时，仅靠原版 id 也必须判定悬挂（不得整条规则静默跳过）
    json tables = j(R"({"ActionCfg": {"1": {"id": 1, "evtId": 9999999}}})");
    json extra = j(R"({"EvtCfg": ["1000001"]})");
    json issues = sa::p1::check_refs(tables, extra);
    REQUIRE(issues.size() == 1);
    CHECK(issues[0].value("cfg", "") == "ActionCfg");
    CHECK(issues[0].value("field", "") == "evtId");
}

TEST_CASE("p1 scan_bugs: base ids produce no false REF", "[p1][ref_rules]") {
    json mod = j(R"({
        "TalkCfg": {"1000001001": {"id": 1000001001}},
        "NpcActivityCfg": {"5": {"id": 5, "talkId": [2000000001]}}})");
    json base = j(R"({"TalkCfg": {"2000000001": {"id": 2000000001}}})");
    json bugs = sa::p1::scan_bugs(mod, base, nullptr);
    CHECK(ref_bugs(bugs).empty());
}

TEST_CASE("p1 ref pool: BgCfg maps to BG pool (not MAP)", "[p1][ref_rules]") {
    const auto* bg = sa::p1::ref_pool_for_target("BgCfg");
    REQUIRE(bg != nullptr);
    CHECK(bg == &sa::p1::pool_by_key("BG"));
    CHECK_FALSE(bg->empty());  // dicts.json bgs 非空（525 条）
}

TEST_CASE("p1 check_refs: Bg field rejects map-only ids", "[p1][ref_rules]") {
    auto bg_keys = int_keys(sa::p1::pool_by_key("BG"));
    auto map_keys = int_keys(sa::p1::pool_by_key("MAP"));
    std::set<long long> bg_only, map_only;
    std::set_difference(bg_keys.begin(), bg_keys.end(), map_keys.begin(), map_keys.end(),
                        std::inserter(bg_only, bg_only.begin()));
    std::set_difference(map_keys.begin(), map_keys.end(), bg_keys.begin(), bg_keys.end(),
                        std::inserter(map_only, map_only.begin()));
    REQUIRE_FALSE(bg_only.empty());
    REQUIRE_FALSE(map_only.empty());
    json tables = j("{\"ActionCfg\": {\"1\": {\"id\": 1, \"bg\": " + std::to_string(*bg_only.begin()) +
                    "}}}");
    CHECK(sa::p1::check_refs(tables, json()).empty());
    json bad = j("{\"ActionCfg\": {\"1\": {\"id\": 1, \"bg\": " + std::to_string(*map_only.begin()) +
                 "}}}");
    json issues = sa::p1::check_refs(bad, json());
    REQUIRE(issues.size() == 1);
    CHECK(issues[0].value("target", "") == "BgCfg");
}

TEST_CASE("p1 check_refs: 2D array flattens for healing", "[p1][ref_rules]") {
    json tables = j(R"({
        "TalkCfg": {"1000001001": {"id": 1000001001}, "1000001002": {"id": 1000001002}},
        "GiftEvtCfg": {"1": {"id": 1, "talkId": [[1000001001], [7777777001]]}}})");
    json issues = sa::p1::check_refs(tables, json());
    std::vector<json> dangling;
    for (auto& i : issues)
        if (i.value("field", "") == "talkId") dangling.push_back(i);
    REQUIRE(dangling.size() == 1);
    CHECK(dangling[0].at("value") == j("[[1000001001], [7777777001]]"));
    CHECK(dangling[0].at("healed") == j("[1000001001]"));
    CHECK(dangling[0].value("array", false) == true);
}

TEST_CASE("p1 check_refs: missing target table skips rule", "[p1][ref_rules]") {
    json tables = j(R"({"TalkCfg": {"1000001001": {"id": 1000001001, "miniGame": [1, 2]}}})");
    CHECK(sa::p1::check_refs(tables, json()).empty());
}

TEST_CASE("p1 check_refs: float-string ids normalize", "[p1][ref_rules]") {
    json tables = j(R"({
        "EvtCfg": {"1000001": {"id": 1000001}},
        "ActionCfg": {"1": {"id": 1, "evtId": "1000001.0"}}})");
    CHECK(sa::p1::check_refs(tables, json()).empty());
}

TEST_CASE("p1 validate_cross integrates ref_rules", "[p1][ref_rules]") {
    json tables = j(R"({
        "EvtCfg": {"1000001": {"id": 1000001}},
        "MapCfg": {"101": {"id": 101}},
        "ActionCfg": {"1": {"id": 1, "map": 999}}})");
    json issues = sa::p1::validate_cross(tables, j("{}"));
    bool found = false;
    for (auto& p : issues) {
        std::string lv = p[0].get<std::string>(), msg = p[1].get<std::string>();
        if (lv == "warn" && msg.find("ActionCfg") != std::string::npos &&
            msg.find("map") != std::string::npos && msg.find("999") != std::string::npos)
            found = true;
    }
    CHECK(found);
}

TEST_CASE("p1 scan_bugs + apply_fix: REF heal applied / single not", "[p1][ref_rules]") {
    json mod = j(R"({
        "TalkCfg": {"1000001001": {"id": 1000001001}, "1000001002": {"id": 1000001002}},
        "NpcActivityCfg": {"5": {"id": 5, "talkId": [1000001001, 2000000001]}}})");
    json bugs = sa::p1::scan_bugs(mod, j("{}"), nullptr);
    auto ref = ref_bugs(bugs);
    REQUIRE_FALSE(ref.empty());
    CHECK(ref[0].at("healed") == j("[1000001001]"));
    // Python: mod 是活字典；C++ 侧 mod_data 传引用、内部就地改
    CHECK(sa::p1::apply_fix(mod, ref[0]));
    CHECK(mod["NpcActivityCfg"]["5"]["talkId"] == j("[1000001001]"));

    json mod2 = j(R"({
        "EvtCfg": {"1000001": {"id": 1000001}},
        "ActionCfg": {"1": {"id": 1, "evtId": 9999999}}})");
    json bugs2 = sa::p1::scan_bugs(mod2, j("{}"), nullptr);
    auto single = ref_bugs(bugs2, "evtId");
    REQUIRE(single.size() == 1);
    CHECK(single[0].at("healed").is_null());
    CHECK_FALSE(sa::p1::apply_fix(mod2, single[0]));
}

// ---------------------------------------------------------------------------
// 引擎级（普通 dict）scan/fix：路由层因 Python 生产路径的 MappingProxyType 门
// （D16）不触发的 S1/S2/S4-format 段，在这里按 Python 单元测试同构覆盖。
// ---------------------------------------------------------------------------

TEST_CASE("p1 scan_bugs engine-level: 断层/越界/降维/格式 heal + rename apply", "[p1][semantic]") {
    json mod = j(R"({
        "TalkCfg": {"1314170001": {"id": 1314170001, "nextTalk": [999]}},
        "OptionCfg": {"5": {"id": 5, "talkId": 7}},
        "GiftEvtCfg": {"1": {"id": 1, "npcId": [3], "condition": [[1, 1, 1, 5]]}}})");
    json bugs = sa::p1::scan_bugs(mod, j("{}"), nullptr /* read_only_view=false */);
    // S1：nextTalk 999 / talkId 7 均不在表内 → 致命断层
    int faults = 0;
    for (auto& b : bugs)
        if (b.value("flag", "") == "LOGIC" && b.value("key", "") == "致命断层") ++faults;
    CHECK(faults == 2);
    // S4-format：OptionCfg.talkId 标量 7 → [7]（1D Array）SCHEMA_HEAL
    bool talk_wrap = false;
    for (auto& b : bugs)
        if (b.value("flag", "") == "SCHEMA_HEAL" && b.value("cfg", "") == "OptionCfg" &&
            b.value("key", "") == "talkId" && b.at("healed") == j("[7]"))
            talk_wrap = true;
    CHECK(talk_wrap);
    // RENAME_NPC/RENAME_COND 引擎级 apply（与路由同码，路由用例已测 HTTP 侧）
    json priv = mod;
    int fixed = 0;
    for (auto& b : bugs)
        if (b.value("flag", "").rfind("RENAME_", 0) == 0 && sa::p1::apply_fix(priv, b)) ++fixed;
    CHECK(fixed == 2);
    CHECK(priv["GiftEvtCfg"]["1"].contains("npc"));
    CHECK(priv["GiftEvtCfg"]["1"].contains("cond"));
    CHECK_FALSE(priv["GiftEvtCfg"]["1"].contains("npcId"));
    CHECK_FALSE(priv["GiftEvtCfg"]["1"].contains("condition"));
    // cond 改名后按 parse_from_display(2D Array) 还原为 [[1, 1, 1, 5]]
    CHECK(priv["GiftEvtCfg"]["1"]["cond"] == j("[[1, 1, 1, 5]]"));
}

TEST_CASE("p1 validate_secondary_item engine-level", "[p1][semantic]") {
    sa::p1::AvailableMap av;
    for (auto& kv : sa::p1::pool_by_key("ATTR")) av["ATTR"][kv.first] = kv.second;
    for (auto& kv : sa::p1::pool_by_key("ROLE")) av["ROLE"][kv.first] = kv.second;
    // [1, 1, 1, 5]：一级1 二级1 @ATTR@=1（存在） V=5 → 有效
    json r = sa::p1::validate_secondary_item(j("[1, 1, 1, 5]"),
                                             sa::p1::effect_secondary_index(), av);
    CHECK(r.at("errors").empty());
    CHECK_FALSE(r.value("translation", "").empty());
    // 属性 999999 不在字典 → 报错
    json r2 = sa::p1::validate_secondary_item(j("[1, 1, 999999, 5]"),
                                              sa::p1::effect_secondary_index(), av);
    REQUIRE(r2.at("errors").size() >= 1);
    CHECK(r2.at("errors")[0].get<std::string>() == "属性ID [999999] 字典中不存在。");
    // 998 嵌套效果（EFFECTS*）：嵌套项经 _normalize_scalar 变字符串后按
    // 单元素行校验 —— Python 亦产生「嵌套效果 -> ...」错误（逐字对齐行为）。
    json r3 = sa::p1::validate_secondary_item(j("[998, 1, 102, [1, 1, 1, 5]]"),
                                              sa::p1::effect_secondary_index(), av);
    REQUIRE_FALSE(r3.at("errors").empty());
    CHECK(r3.at("errors")[0].get<std::string>().rfind("嵌套效果 -> ", 0) == 0);
    CHECK_FALSE(r3.value("translation", "").empty());
}

// ---------------------------------------------------------------------------
// 标量归一 / ID 规则抽查（guide_rules._to_int / data_dicts._normalize_scalar）
// ---------------------------------------------------------------------------

TEST_CASE("p1 scalar helpers", "[p1][semantic]") {
    CHECK(sa::p1::to_int(j("123")) == 123);
    CHECK(sa::p1::to_int(j("\"-5\"")) == -5);
    CHECK(sa::p1::to_int(j("\"1e3\"")).has_value() == false);
    CHECK(sa::p1::to_int(j("true")).has_value() == false);
    CHECK(sa::p1::to_int(j("4.0")) == 4);
    CHECK(sa::p1::to_int(j("4.5")).has_value() == false);
    CHECK(sa::p1::to_int_loose(j("\"123.0\"")) == 123);
    CHECK(sa::p1::to_int_loose(j("\"12.5\"")).has_value() == false);
    CHECK(sa::p1::to_int_loose(j("\"-5\"")).has_value() == false);  // _to_int_loose 不吃负号 str
    CHECK(sa::p1::is_numeric_token("1.2"));
    CHECK(sa::p1::is_numeric_token("--1"));
    CHECK_FALSE(sa::p1::is_numeric_token("1.2.3"));
    CHECK(sa::p1::normalize_scalar(j("\"12.0\"")) == "12");
    CHECK(sa::p1::normalize_scalar(j("12.5")) == "12.5");
    CHECK(sa::p1::normalize_scalar(j("true")) == "1");
    CHECK(sa::p1::normalize_scalar(j("null")) == "None");
}

TEST_CASE("p1 validate_record mirrors guide_rules semantics", "[p1][semantic]") {
    json ok_evt = j(R"({"id": 1314170, "rate": 0.5, "type": 4, "talkId": [1314170001]})");
    json issues = sa::p1::validate_record("EvtCfg", "1314170", ok_evt);
    for (auto& p : issues) CHECK(p[0] != "error");
    json bad = j(R"({"id": 7123456, "rate": 5, "type": 2, "npc": 0, "talkId": []})");
    json bi = sa::p1::validate_record("EvtCfg", "7123456", bad);
    bool has_err = false, has_rate = false, has_npc = false, has_talk = false;
    for (auto& p : bi) {
        std::string lv = p[0].get<std::string>(), m = p[1].get<std::string>();
        if (lv == "error") has_err = true;
        if (lv == "warn" && m.find(".rate") != std::string::npos) {
            has_rate = true;
            // Python "%s" % float(5) == "5.0"（原始值 "5"/int 5 都要打 float 形态）
            CHECK(m.find("发生概率 5.0 超出") != std::string::npos);
        }
        if (lv == "warn" && m.find(".npc") != std::string::npos) has_npc = true;  // npc=0 也报
        if (lv == "warn" && m.find(".talkId") != std::string::npos) has_talk = true;
    }
    CHECK(has_err);
    CHECK(has_rate);
    CHECK(has_npc);
    CHECK(has_talk);
    // 事件ID与首句对话ID前缀不匹配 → error
    json mis = sa::p1::validate_record("EvtCfg", "123", j(R"({"id": 123, "talkId": [123001]})"));
    bool talk_err = false;
    for (auto& p : mis)
        if (p[0] == "error" && p[1].get<std::string>().find("talkId") != std::string::npos)
            talk_err = true;
    CHECK(talk_err);
}

TEST_CASE("p1 validate_cross checks nextTalk before nextTalk2 (order)", "[p1][semantic]") {
    json tables = j(R"({
        "EvtCfg": {},
        "TalkCfg": {"1314170001": {"id": 1314170001, "nextTalk": [1], "nextTalk2": [2]}},
        "OptionCfg": {}})");
    json issues = sa::p1::validate_cross(tables, j("{}"));
    // 收集 warn 消息里出现的下一句 id 顺序：Python `_ref_entries(nt)+_ref_entries(nt2)`
    std::vector<std::string> seq;
    for (auto& p : issues) {
        std::string m = p[1].get<std::string>();
        auto pos = m.find("下一句对话ID ");
        if (pos != std::string::npos)
            seq.push_back(m.substr(pos + std::string("下一句对话ID ").size()));
    }
    REQUIRE(seq.size() >= 2);
    CHECK(seq[0].rfind("1 不存在", 0) == 0);
    CHECK(seq[1].rfind("2 不存在", 0) == 0);
}

TEST_CASE("p1 describe rows match guide_rules", "[p1][semantic]") {
    json d = sa::p1::describe_screen_row(j("[4001, 0.5]"));
    CHECK(d.value("desc", "") == "屏幕抖动 0.5 秒");
    CHECK(d.at("errors").empty());
    CHECK_FALSE(sa::p1::describe_screen_row(j("[9999]")).at("errors").empty());
    json a = sa::p1::describe_action_row(j("[102, 1001, 0, 2]"));
    CHECK(a.at("errors").empty());
    CHECK_FALSE(a.value("desc", "").empty());
    CHECK_FALSE(sa::p1::describe_action_row(j("[0, 1001, 1, 2]")).at("errors").empty());
    CHECK(sa::p1::describe_action_row(j("[0, 3004, -100]")).value("desc", "").find("像素") !=
          std::string::npos);
}
