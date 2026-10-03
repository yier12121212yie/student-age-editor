// wip/P1/semantic_graph.cpp — 三个只读/分析型 JSON 端点（契约详见 semantic_graph.h）：
//   POST /api/effect/parse     文本行 → {status, translations, rows[]}，rows 逐行给出
//                              模板 / 参数槽 / 嵌套展开 / 行级错误；文本解析语义与
//                              /api/effect_validate 一致（每行 `[1, 1, 3, 5], [7, 1, 101, 50]`
//                              逗号分隔、单行扁平数组自动升二维、全角标点宽容）。
//   GET  /api/graph/relations  人物关系图：nodes（/api/roles 同源数据）+
//                              levels（RelationCfg 本体+Mod 按 id 覆盖合并——注意
//                              /api/dicts 的 relations 是静态内嵌不合并，这里必须自行 merge）
//                              + edges（EvtCfg/TalkCfg/OptionCfg/InteractCfg/FriendRequestCfg/
//                              Love*/MinigameActionCfg 的 cond/check/precondition/effect/
//                              effect2 2D 码 + InteractCfg/FriendRequestCfg/Love* 整行）。
//   GET  /api/graph/timeline   RoundCfg+SeasonCfg+SeasonTypeCfg[501 寒暑假] 合并视图 +
//                              EvtCfg.condition / ActionCfg(cond+beginTime/endTime) 的
//                              [2,*] 时间码族 → 回合索引 spans。
// 全部纯读：不写盘、不改缓存；扫描上限沿用 bugfix 的做法（全量 ModCfgsView，无截断，
// 响应恒带 "truncated": false）。
#include "semantic_graph.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <functional>
#include <map>
#include <optional>
#include <set>
#include <string>
#include <vector>

#include "sa_core/json_wire.h"
#include "sa_core/strings.h"
#include "sa_core/util.h"
#include "semantic_assets.h"
#include "semantic_logic.h"
#include "server/cfg_cache.h"
#include "server/httpd.h"
#include "server/services/stores_api.h"

namespace sa {
namespace {

namespace str = sa_core::str;
using sa::p1::AvailableMap;
using sa::p1::SecondaryIndex;

// ---------------------------------------------------------------------------
// 小工具（与 semantic_routes.cpp 匿名区同款，独立 TU 自带一份）
// ---------------------------------------------------------------------------
std::string lstrip_neg(const std::string& s) {
    size_t i = 0;
    while (i < s.size() && s[i] == '-') ++i;
    return s.substr(i);
}

bool py_truthy(const json& v) {
    if (v.is_null()) return false;
    if (v.is_boolean()) return v.get<bool>();
    if (v.is_number()) return v.get<double>() != 0.0;
    if (v.is_string()) return !v.get<std::string>().empty();
    return !v.empty();
}

// Python `str(v or "")`。
std::string py_str_or_empty(const json& v) {
    return py_truthy(v) ? (v.is_string() ? v.get<std::string>() : sa_core::py_str(v))
                        : std::string();
}

// 按 UTF-8 码点截前 n 个字符（Python [:n] 语义）。
std::string cp_prefix(const std::string& s, size_t n) {
    size_t chars = 0, i = 0;
    while (i < s.size() && chars < n) {
        unsigned char c = static_cast<unsigned char>(s[i]);
        size_t len = 1;
        if ((c >> 5) == 0x6) len = 2;
        else if ((c >> 4) == 0xE) len = 3;
        else if ((c >> 3) == 0x1E) len = 4;
        i = std::min(s.size(), i + len);
        ++chars;
    }
    return s.substr(0, i);
}

// api.py _norm_effect_rows（与 semantic_routes 同实现）：单行扁平数组自动升二维、
// 三重包裹自动降回二维。
json norm_effect_rows(const json& arr) {
    if (!arr.is_array() || arr.empty()) return json::array();
    if (!arr[0].is_array()) { json a = json::array(); a.push_back(arr); return a; }
    if (!arr[0].empty() && arr[0][0].is_array()) return arr[0];
    return arr;
}

// /api/effect_validate 同款字典池（ROLE/ATTR/…静态池）。
AvailableMap game_pools() {
    AvailableMap av;
    for (const char* key : {"ROLE", "ATTR", "ITEM", "RELATION", "MAP", "JOB", "STATE", "TEXT",
                            "NEGOTIATION_SKILL", "NEGOTIATION_BUFF", "GAME", "KZONE_POST",
                            "KZONE_MESSAGE", "PHONE_MSG"})
        for (const auto& kv : p1::pool_by_key(key)) av[key][kv.first] = kv.second;
    return av;
}

// 行元素的规范标量串（data_dicts._normalize_scalar）。
std::string ns(const json& v) { return p1::normalize_scalar(v); }

// 行的单行归一显示文本：format_to_display 对 2D 字段的逐行形态就是
// py_dumps(row)（逗号后一个空格，如 "[1, 1, 3, 5]"）；不带字段上下文直接调
// format_to_display 会走它的标量剥括号分支，所以这里取其行级等价实现。
std::string row_display(const json& row) { return sa_core::py_dumps(row); }

// 紧凑码文本 "[2,0,6]"（timeline 的 codes 契约：无空格）。
std::string row_compact(const json& row) {
    if (!row.is_array()) return ns(row);
    std::string out = "[";
    for (size_t i = 0; i < row.size(); ++i) {
        if (i) out += ",";
        out += row[i].is_array() ? row_compact(row[i]) : ns(row[i]);
    }
    return out + "]";
}

// ---------------------------------------------------------------------------
// /api/effect/parse —— 模板匹配与槽位提取
// ---------------------------------------------------------------------------

// 模板码拆分：与 semantic_core 的 parse_template_parts 同语义（剥 [] 后按逗号拆、
// 逐段 trim）。SECONDARY 索引内部件只在 semantic_core 匿名区，这里对 cost/action/
// screen 三种无二级语义的模式用轻量等价实现。
std::vector<std::string> split_code_parts(const std::string& code) {
    std::string s = str::trim(code);
    size_t b = 0, e = s.size();
    while (b < e && (s[b] == '[' || s[b] == ']')) ++b;
    while (e > b && (s[e - 1] == '[' || s[e - 1] == ']')) --e;
    s = s.substr(b, e - b);
    std::vector<std::string> parts;
    size_t pos = 0;
    while (true) {
        size_t comma = s.find(',', pos);
        std::string piece = str::trim(s.substr(
            pos, comma == std::string::npos ? std::string::npos : comma - pos));
        if (!piece.empty()) parts.push_back(piece);
        if (comma == std::string::npos) break;
        pos = comma + 1;
    }
    return parts;
}

bool is_num_tok(const std::string& t) {
    std::string d = lstrip_neg(t);
    return !d.empty() && std::all_of(d.begin(), d.end(), [](char c) { return c >= '0' && c <= '9'; });
}
bool is_rest_tok(const std::string& t) {
    return !t.empty() && t.back() == '*' && !is_num_tok(t);
}
bool is_placeholder_tok(const std::string& t) {
    return t.size() >= 3 && t.front() == '@' && t.back() == '@';
}

// 在 db（[{desc,code}]）里为行匹配模板：固定数字段必须逐位相等；rest 尾段允许
// 变长尾巴。候选取舍与 validate_secondary_item 一致（固定段多者胜、再比长度、
// 再比码文本）。
std::optional<std::pair<const json*, std::vector<std::string>>> match_row_template(
    const json& row, const json& entries) {
    struct Cand { int fixed; size_t len; std::string code; size_t order; };
    std::vector<Cand> cands;
    std::vector<std::pair<const json*, std::vector<std::string>>> stores;
    size_t order = 0;
    for (const auto& e : entries) {
        auto parts = split_code_parts(e.value("code", ""));
        if (parts.empty() || !row.is_array()) { ++order; continue; }
        bool rest = is_rest_tok(parts.back());
        bool lenok = rest ? row.size() >= parts.size() : row.size() == parts.size();
        if (!lenok) { ++order; continue; }
        int fixed = 0;
        bool ok = true;
        for (size_t i = 0; i < parts.size(); ++i) {
            if (!is_num_tok(parts[i])) continue;
            if (i >= row.size() || ns(row[i]) != parts[i]) { ok = false; break; }
            ++fixed;
        }
        if (ok) {
            stores.push_back({&e, std::move(parts)});
            cands.push_back({fixed, stores.back().second.size(),
                             stores.back().first->value("code", ""), order});
        }
        ++order;
    }
    if (cands.empty()) return std::nullopt;
    size_t best = 0;
    for (size_t i = 1; i < cands.size(); ++i) {
        const Cand& a = cands[i];
        const Cand& b = cands[best];
        if (a.fixed != b.fixed) { if (a.fixed > b.fixed) best = i; continue; }
        if (a.len != b.len) { if (a.len > b.len) best = i; continue; }
        if (a.code != b.code) { if (a.code < b.code) best = i; continue; }
    }
    return stores[best];
}

// 按模板段提取参数槽。契约：
//   slots[] = {name, kind, dict, label, value}
//   * `@ATTR@` 等占位符        → kind="dict"，dict=池名，label=SECONDARY_PLACEHOLDER_MAP
//                                中文名，value=该行该位标量串（ID 字符串）。
//   * 裸字母（V/X/P/N/Bg/…）   → kind="number"，dict=null，label="数值"（统一，契约只
//                                钉了 V→"数值"，不臆造其它数字标签），value=标量串。
//   * rest 尾段（EFFECTS*）    → kind="nested"，dict=null，label="嵌套效果"，
//                                value=该行剩余元素的归一文本（结构已由 nested 字段
//                                展开，见下）。
// 同名槽多次出现只保留首个（与 /api/effect_suggest 的 slots 合并语义一致）。
json build_slots(const std::vector<std::string>& parts, const json& row) {
    json slots = json::array();
    std::map<std::string, size_t> seen;
    const json& sp = p1::secondary_placeholder_map();
    for (size_t i = 0; i < parts.size(); ++i) {
        const std::string& tok = parts[i];
        if (is_num_tok(tok)) continue;
        bool rest = is_rest_tok(tok);
        bool dict = is_placeholder_tok(tok);
        std::string name = rest ? tok.substr(0, tok.size() - 1)
                                : (dict ? tok.substr(1, tok.size() - 2) : tok);
        std::string kind = rest ? "nested" : (dict ? "dict" : "number");
        if (!rest) {
            auto it = seen.find(name);
            if (it != seen.end()) continue;  // 重复字母槽取首个值
        } else {
            // rest 槽的值 = 该行从该位起剩余元素的紧凑文本
            json tail = json::array();
            for (size_t j = i; j < row.size(); ++j) tail.push_back(row[j]);
            json slot;
            slot["name"] = name;
            slot["kind"] = "nested";
            slot["dict"] = nullptr;
            slot["label"] = "嵌套效果";
            slot["value"] = row_display(tail);
            slots.push_back(std::move(slot));
            continue;
        }
        std::string dict_name, label;
        if (dict) {
            std::string key = "@" + name + "@";
            if (sp.contains(key) && sp[key].is_array() && sp[key].size() >= 2) {
                if (sp[key][0].is_string()) dict_name = sp[key][0].get<std::string>();
                if (sp[key][1].is_string()) label = sp[key][1].get<std::string>();
            }
        } else {
            label = "数值";
        }
        json slot;
        slot["name"] = name;
        slot["kind"] = kind;
        slot["dict"] = dict && !dict_name.empty() ? json(dict_name) : (dict ? json("") : json(nullptr));
        slot["label"] = label;
        slot["value"] = i < row.size() ? json(ns(row[i])) : json(nullptr);
        seen[name] = slots.size();
        slots.push_back(std::move(slot));
    }
    return slots;
}

// 行数组里跳过一级/二级后的「参数值」段（effect/condition 从第 3 项起，其余模式
// 从第 2 项起）；整数值转 JSON number，其它标量保持归一字符串，嵌套数组原样带上。
json args_slice(const json& row, size_t from) {
    json args = json::array();
    for (size_t i = from; i < row.size(); ++i) {
        const json& v = row[i];
        if (v.is_array()) args.push_back(v);
        else if (auto n = p1::to_int(v)) args.push_back(*n);
        else args.push_back(ns(v));
    }
    return args;
}

// 单个 effect/condition 行的结构化解析（递归复用于 998 嵌套行）。
// 返回 row 对象；translation 带出该行的中文译名（与 /api/effect_validate 同源：
// validate_secondary_item 的 translation，含失败回退 repr）。
json parse_semantic_row(const json& row, size_t line, const SecondaryIndex& idx,
                        const AvailableMap& av, std::string& translation) {
    json res = p1::validate_secondary_item(row, idx, av);
    translation = res.value("translation", sa_core::py_str(row));

    json out;
    out["line"] = static_cast<long long>(line);
    auto pv = row.is_array() && !row.empty() ? p1::to_int(row[0]) : std::nullopt;
    auto sv = row.is_array() && row.size() >= 2 ? p1::to_int(row[1]) : std::nullopt;
    bool negate = sv.has_value() && *sv < 0;
    out["negate"] = negate;
    out["primary"] = pv ? json(*pv) : json(nullptr);
    out["secondary"] = sv ? json(std::abs(*sv)) : json(nullptr);
    out["args"] = args_slice(row, 2);
    out["display"] = row_display(row);

    json errors = res.contains("errors") ? res.at("errors") : json::array();
    const bool has_tmpl = res.contains("template") && res["template"].is_object();
    if (has_tmpl) {
        const json& tmpl = res["template"];
        json t;
        t["code"] = tmpl.value("code", "");
        t["desc"] = tmpl.value("desc", "");
        out["template"] = std::move(t);
        std::vector<std::string> parts;
        if (tmpl.contains("parts") && tmpl["parts"].is_array())
            for (const auto& p : tmpl["parts"]) if (p.is_string()) parts.push_back(p.get<std::string>());
        out["slots"] = build_slots(parts, row);
    } else {
        out["template"] = nullptr;
        out["slots"] = nullptr;
    }

    // 998 嵌套效果行：把行内嵌套数组展开成同结构的 nested rows（校验池与
    // validate_secondary_item 的嵌套分支一致，走 EFFECT_DB）。
    // 两种存储形态都收：尾巴为嵌套数组（[[..],..]）或扁平标量尾巴
    // （[998,1,101,20,1,101,50] —— 与 validate 的 EFFECTS* 吸收规则同形）。
    out["nested"] = nullptr;
    if (pv && *pv == 998) {
        std::vector<json> nested_rows;
        bool saw_array = false;
        for (size_t j = 2; j < row.size(); ++j) {
            const json& x = row[j];
            if (!x.is_array()) continue;
            saw_array = true;
            if (!x.empty() && x[0].is_array()) {
                for (const auto& sub : x) if (sub.is_array()) nested_rows.push_back(sub);
            } else if (x.size() >= 2) {
                nested_rows.push_back(x);
            }
        }
        if (!saw_array && has_tmpl && row.size() > 3) {
            size_t rest_i = 0;
            bool found_rest = false;
            if (res["template"].contains("parts"))
                for (size_t i = 0; i < res["template"]["parts"].size(); ++i) {
                    const json& p = res["template"]["parts"][i];
                    if (p.is_string() && is_rest_tok(p.get<std::string>())) {
                        rest_i = i;
                        found_rest = true;
                        break;
                    }
                }
            if (found_rest) {
                json one = json::array();
                for (size_t j = rest_i; j < row.size(); ++j) one.push_back(row[j]);
                if (one.size() >= 2) nested_rows.push_back(std::move(one));
            }
        }
        if (!nested_rows.empty()) {
            json narr = json::array();
            // 与 validate_secondary_item 的嵌套分支一致：998 内层恒走 EFFECT_DB。
            const SecondaryIndex& nidx = p1::effect_secondary_index();
            size_t li = 0;
            for (const auto& sub : nested_rows) {
                ++li;
                std::string sub_tr;
                json sub_out = parse_semantic_row(sub, li, nidx, av, sub_tr);
                narr.push_back(std::move(sub_out));
            }
            out["nested"] = std::move(narr);
        }
    }

    std::string err;
    if (errors.is_array())
        for (const auto& e : errors) {
            if (!err.empty()) err += "; ";
            err += e.is_string() ? e.get<std::string>() : sa_core::py_str(e);
        }
    out["error"] = err.empty() ? json(nullptr) : json(err);
    return out;
}

std::string normalize_parse_text(const std::string& text_in) {
    std::string t = str::trim(text_in);
    // 全角标点宽容：中文逗号/分号/顿号、全角括号、全角空格、全角减号、全角数字
    // 统一折算成 ASCII 形态（契约要求 text 语义宽容；/api/effect_validate 本身
    // 由上游保证输入形态，这里在 parse 端点内做前处理）。
    auto rep = [&t](const std::string& a, const std::string& b) {
        size_t p = 0;
        while ((p = t.find(a, p)) != std::string::npos) { t.replace(p, a.size(), b); p += b.size(); }
    };
    rep("\xEF\xBC\x8C", ",");   // ，
    rep("\xEF\xBC\x9B", ";");   // ；
    rep("\xE3\x80\x81", ",");   // 、
    rep("\xEF\xBC\x88", "[");   // （
    rep("\xEF\xBC\x89", "]");   // ）
    rep("\xE3\x80\x90", "[");   // 【
    rep("\xE3\x80\x91", "]");   // 】
    rep("\xE3\x80\x80", " ");   // 全角空格
    rep("\xEF\xBC\x8D", "-");   // －
    // 全角数字 ０..９（U+FF10..FF19）
    for (int d = 0; d <= 9; ++d) {
        std::string fw = "\xEF\xBC";
        fw += static_cast<char>(0x90 + d);  // FF10..FF19 的第三字节 = 0x90..0x99
        rep(fw, std::string(1, static_cast<char>('0' + d)));
    }
    while (!t.empty() && (t.back() == ',' || t.back() == ';' || t.back() == ' ' || t.back() == '\n' ||
                          t.back() == '\t')) t.pop_back();
    return t;
}

// POST /api/effect/parse 主体（契约见文件头）。
json effect_parse_body(const std::string& text_in, const std::string& mode_in) {
    std::string mode = str::lower(str::trim(mode_in));
    if (mode.empty()) mode = "effect";
    if (!std::set<std::string>{"effect", "condition", "cost", "action", "screen"}.count(mode))
        mode = "effect";

    json out;
    json translations = json::array(), rows = json::array();
    auto finish = [&](const std::string& status, bool ok, const std::string& message) {
        out["ok"] = ok;
        out["status"] = status;
        if (!message.empty()) out["message"] = message;
        out["translations"] = std::move(translations);
        out["rows"] = std::move(rows);
        return out;
    };

    std::string t = normalize_parse_text(text_in);
    if (t.empty()) return finish("empty", true, "");

    json arr = json::parse("[" + t + "]", nullptr, false);
    if (arr.is_discarded())
        return finish("json_error", false, "括号或逗号不匹配");
    // 缺外层括号判定与 /api/effect_validate 完全一致（screen/action 除外）。
    if (mode != "screen" && mode != "action" && arr.is_array() && !arr.empty() && !arr[0].is_array()) {
        std::string s0 = sa_core::py_str(arr[0]);
        std::string d = lstrip_neg(s0);
        bool numeric = std::all_of(d.begin(), d.end(), [](char c) { return c >= '0' && c <= '9'; }) &&
                       !d.empty();
        if (numeric)
            return finish("missing_outer_bracket", false, "缺少外层方括号，请改为: [ [" + t + "] ]");
    }
    json in_rows = norm_effect_rows(arr);
    bool any_error = false;

    if (mode == "effect" || mode == "condition") {
        const SecondaryIndex& idx = mode == "effect" ? p1::effect_editor_secondary_index()
                                                    : p1::condition_secondary_index();
        AvailableMap av = game_pools();
        size_t i = 0;
        for (const auto& item : in_rows) {
            ++i;
            if (!item.is_array()) continue;
            std::string tr;
            json r = parse_semantic_row(item, i, idx, av, tr);
            translations.push_back(tr);
            if (!r["error"].is_null()) any_error = true;
            rows.push_back(std::move(r));
        }
    } else {
        // cost/action/screen：无二级语义（secondary=null、negate=false），模板从
        // 对应静态码表做轻量匹配；译名/错误沿用 /api/effect_validate 的分支实现。
        const json* db = nullptr;
        if (mode == "cost") db = &p1::cost_db();
        else if (mode == "action") db = &p1::action_cmd_db();
        else db = &p1::screen_effect_db();
        size_t i = 0;
        std::string screen_multi_err;
        if (mode == "screen" && in_rows.is_array() && in_rows.size() > 1)
            screen_multi_err = "一句话只能填写一个屏幕效果";
        for (const auto& item : in_rows) {
            ++i;
            if (!item.is_array()) continue;
            std::string tr, err;
            if (mode == "screen" || mode == "action") {
                json d = mode == "screen" ? p1::describe_screen_row(item) : p1::describe_action_row(item);
                tr = d.value("desc", "");
                if (tr.empty()) {
                    for (size_t j = 0; j < item.size(); ++j) {
                        if (j) tr += ", ";
                        tr += sa_core::py_str(item[j]);
                    }
                }
                if (d.contains("errors"))
                    for (const auto& e : d.at("errors")) {
                        if (!err.empty()) err += "; ";
                        err += e.get<std::string>();
                    }
            } else {  // cost
                for (size_t j = 0; j < item.size(); ++j) {
                    if (j) tr += ", ";
                    tr += sa_core::py_str(item[j]);
                }
                // cost 首项是属性 ID：字典池校验（与行级错误同形态的中文提示）。
                if (!item.empty()) {
                    auto a = p1::to_int(item[0]);
                    if (!a) err = "第 1 项不是有效的属性 ID。";
                    else if (!p1::pool_by_key("ATTR").count(std::to_string(*a)))
                        err = "属性ID [" + std::to_string(*a) + "] 字典中不存在。";
                }
            }
            if (i == 1 && !screen_multi_err.empty())
                err = err.empty() ? screen_multi_err : (err + "; " + screen_multi_err);

            json r;
            r["line"] = static_cast<long long>(i);
            r["negate"] = false;
            r["primary"] = !item.empty() && p1::to_int(item[0]) ? json(*p1::to_int(item[0])) : json(nullptr);
            r["secondary"] = nullptr;
            r["args"] = args_slice(item, 1);
            r["display"] = row_display(item);
            auto m = match_row_template(item, *db);
            if (m) {
                json tt;
                tt["code"] = m->first->value("code", "");
                tt["desc"] = m->first->value("desc", "");
                r["template"] = std::move(tt);
                r["slots"] = build_slots(m->second, item);
            } else {
                // 匹配不到模板：生成通用参数槽位 (用于 action/screen/cost 中的动态值，如人物 ID 引用)
                // 这样即使没有 template，前端也能显示原始参数并支持编辑；cost/action/screen 的
                // 行级错误仍按 /api/effect_validate 的校验口径处理（cost 无校验分支）。
                r["template"] = nullptr;
                json generic_slots = json::array();
                for (size_t j = 0; j < item.size(); ++j) {
                    json slot;
                    slot["name"] = "param_" + std::to_string(j);
                    slot["kind"] = "number";
                    slot["label"] = "参数";
                    slot["value"] = sa_core::py_str(item[j]);
                    generic_slots.push_back(std::move(slot));
                }
                r["slots"] = std::move(generic_slots);
            }
            r["nested"] = nullptr;
            r["error"] = err.empty() ? json(nullptr) : json(err);
            if (!r["error"].is_null()) any_error = true;
            translations.push_back(tr);
            rows.push_back(std::move(r));
        }
    }
    return finish(any_error ? "logic_error" : "ok", !any_error, "");
}

// ---------------------------------------------------------------------------
// mod+本体合并表工具（图端点共用）
// ---------------------------------------------------------------------------

// 表键规范化："101"/"0101"/101 → "101"；非数字键原样（trim 后）。
std::string canon_id(const std::string& k) {
    std::string t = str::trim(k);
    if (auto n = sa_core::py_int(t)) return std::to_string(*n);
    return t;
}

// 本体全表 + Mod 行按 id 覆盖合并（只读视图拷贝进普通 json；与 scan_bugs 的
// mod/base 合并语义一致，这里仅取需要的表，不做全量拷贝）。
json merged_table(const ModCfgsView& view, const std::string& name) {
    json out = json::object();
    auto store = base_store();
    if (store && store->available()) {
        auto t = store->table(name);
        if (t && t->is_object())
            for (auto it = t->begin(); it != t->end(); ++it) out[canon_id(it.key())] = it.value();
    }
    auto it = view.tables.find(name);
    if (it != view.tables.end() && it->second && it->second->is_object())
        for (auto k = it->second->begin(); k != it->second->end(); ++k)
            out[canon_id(k.key())] = k.value();
    return out;
}

// cfg_ids 同款排序：数字键升序在前，非数字键按字符串。
std::vector<std::string> sorted_ids(const json& tbl) {
    std::vector<std::string> keys;
    if (tbl.is_object()) for (auto it = tbl.begin(); it != tbl.end(); ++it) keys.push_back(it.key());
    std::stable_sort(keys.begin(), keys.end(), [](const std::string& a, const std::string& b) {
        auto ia = sa_core::py_int(a), ib = sa_core::py_int(b);
        if (ia && ib) return *ia < *ib;
        if (ia != ib) return ia.has_value();
        return a < b;
    });
    return keys;
}

// 记录里首个非空字符串字段的 24 码点前缀（sourceName/预览用）。
std::string preview_name(const json& rec, const std::vector<const char*>& fields) {
    if (!rec.is_object()) return "";
    for (const char* f : fields) {
        if (!rec.contains(f)) continue;
        std::string s = py_str_or_empty(rec.at(f));
        if (!s.empty()) return cp_prefix(s, 24);
    }
    return "";
}

// ---------------------------------------------------------------------------

}  // namespace

void register_semantic_graph(Router& r) {
    // POST /api/effect/parse — 文本 → 逐行结构化（契约见文件头；文本语义与
    // /api/effect_validate 完全一致：外层包裹解析、扁平单行升二维、全角宽容）。
    r.post(R"(/api/effect/parse)", [](const Req& req) -> Resp {
        const json& body = req.body.is_object() ? req.body : json::object();
        std::string text = body.contains("text") ? py_str_or_empty(body.at("text")) : std::string();
        std::string mode = body.contains("mode") && body.at("mode").is_string()
                               ? body.at("mode").get<std::string>()
                               : std::string("effect");
        return Resp::Json(200, effect_parse_body(text, mode));
    });
}

}  // namespace sa

