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
                // 匹配不到模板：template/slots=null，但不额外造错——cost/action/screen
                // 的行级错误以 /api/effect_validate 的校验口径为准（cost 无校验分支）。
                r["template"] = nullptr;
                r["slots"] = nullptr;
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
// GET /api/graph/relations
// ---------------------------------------------------------------------------

// 一条关系边的 JSON 形态（契约字段序：role,kind,value,relation,code,sourceCfg,
// sourceId,sourceName）。
json make_edge(const std::string& kind, const json& role, const json& value, const json& relation,
              const json& code, const std::string& cfg, const std::string& id,
              const std::string& name) {
    json e;
    e["role"] = role.is_null() ? json(nullptr) : json(ns(role));
    e["kind"] = kind;
    e["value"] = value;
    e["relation"] = relation;
    e["code"] = code;
    e["sourceCfg"] = cfg;
    e["sourceId"] = id;
    e["sourceName"] = name;
    return e;
}

json json_opt_int(const std::optional<long long>& v) { return v ? json(*v) : json(nullptr); }

// 2D 码数组的关系分类（effect_ctx=true 表示 effect/effect2 语境，false 为 cond/
// check/precondition 语境）。998 嵌套行递归展开（嵌套恒为效果码）。
void scan_code_rows(const json& arr2d, bool effect_ctx, const std::string& cfg,
                    const std::string& id, const std::string& name, json& edges) {
    if (!arr2d.is_array()) return;
    for (const auto& row : arr2d) {
        if (!row.is_array() || row.size() < 2) continue;
        auto pv = p1::to_int(row[0]);
        auto sv = p1::to_int(row[1]);
        if (!pv || !sv) continue;
        long long p = *pv, s = *sv;
        if (effect_ctx && p == 998) {  // 嵌套效果：逐项递归（效果语境）
            for (size_t j = 2; j < row.size(); ++j) {
                const json& x = row[j];
                if (!x.is_array()) continue;
                if (!x.empty() && x[0].is_array()) scan_code_rows(x, true, cfg, id, name, edges);
                else { json one = json::array(); one.push_back(x); scan_code_rows(one, true, cfg, id, name, edges); }
            }
            continue;
        }
        auto at = [&](size_t i) -> std::optional<long long> {
            return i < row.size() ? p1::to_int(row[i]) : std::nullopt;
        };
        auto json_at = [&](size_t i) -> json {
            return i < row.size() ? row[i] : json(nullptr);
        };
        json code = row_display(row);
        if (effect_ctx && p == 20 && (s == 1 || s == 22) && row.size() >= 4) {
            // 好感增/减：[20,1|22,@ROLE@,V]；V<0 归 favorLoss（契约：favorLoss 覆盖
            // EFFECT_DB 中改好感的其余二级，现核对 [20,22] 与负值 [20,1] 两类）。
            auto v = at(3);
            std::string kind = (v && *v < 0) ? "favorLoss" : "favorGain";
            edges.push_back(make_edge(kind, json_at(2), json_opt_int(v), json(nullptr), code, cfg, id, name));
        } else if (effect_ctx && p == 20 && s == 2 && row.size() >= 4) {
            // 确立关系：[20,2,@ROLE@,@RELATION@] → relation 给 RelationCfg id 串。
            edges.push_back(make_edge("relationSet", json_at(2), json(nullptr),
                                      json(ns(json_at(3))), code, cfg, id, name));
        } else if (!effect_ctx && p == 7 && (s == 1 || s == -1) && row.size() >= 4) {
            // 好感阈值条件：>=（[7,1]）与 <（[7,-1]）——negate 信息由 code 承载。
            edges.push_back(make_edge("favorCond", json_at(2), json_opt_int(at(3)), json(nullptr),
                                      code, cfg, id, name));
        } else if (!effect_ctx && p == 7 && (s == 2 || s == 0) && row.size() >= 4) {
            // 关系等级条件：契约钉了 [7,2]；CONDITION_DB 实际码是 [7,0,@ROLE@,@RELATION@]
            // （“关系等级为”），两者都收（relationCond 同一 kind，见汇报偏离说明）。
            edges.push_back(make_edge("relationCond", json_at(2), json(nullptr),
                                      json(ns(json_at(3))), code, cfg, id, name));
        } else if (!effect_ctx && p == 52 && s == 2 && row.size() >= 4) {
            // 恋人条件：[52,2,±1,@ROLE@]；value=±1（flag），role 在第 4 项。
            edges.push_back(make_edge("lover", json_at(3), json_opt_int(at(2)), json(nullptr),
                                      code, cfg, id, name));
        }
    }
}

// 表扫描规格：cfg → 待扫 2D 字段（effect_ctx）。
struct TableSpec {
    const char* cfg;
    std::vector<std::pair<const char*, bool>> fields;
};

void relations_body(const ModCfgsView& view, json& out) {
    // ---- nodes：/api/roles 同源数据（ROLE_DICT 静态池 + PersonCfg 覆盖合并；
    // 本体可用时先并 base PersonCfg 的 gender/立绘，Mod 行再覆盖）。
    json base_roles = p1::dicts().value("game_dicts", json::object())
                                     .value("roles", json::object());
    std::map<std::string, json> by_id;
    for (auto it = base_roles.begin(); it != base_roles.end(); ++it) {
        json n;
        n["id"] = canon_id(it.key());
        n["name"] = py_str_or_empty(it.value());
        n["gender"] = nullptr;
        n["tex"] = nullptr;
        by_id[canon_id(it.key())] = std::move(n);
    }
    auto first_url = [](const json& rec, const char* f) -> std::string {
        if (!rec.is_object() || !rec.contains(f) || !rec[f].is_array() || rec[f].empty())
            return "";
        return rec[f][0].is_string() ? rec[f][0].get<std::string>() : "";
    };
    auto merge_person = [&](const json& pcfg) {
        if (!pcfg.is_object()) return;
        for (auto it = pcfg.begin(); it != pcfg.end(); ++it) {
            if (!it.value().is_object()) continue;
            std::string id = canon_id(it.key());
            json& n = by_id[id];
            if (!n.is_object()) {
                n = json::object();
                n["id"] = id;
                n["name"] = "";
                n["gender"] = nullptr;
                n["tex"] = nullptr;
            }
            const json& rec = it.value();
            if (rec.contains("name") && py_truthy(rec["name"])) n["name"] = py_str_or_empty(rec["name"]);
            if (rec.contains("gender") && rec["gender"].is_number()) n["gender"] = rec["gender"];
            std::string tex = first_url(rec, "url2");
            if (tex.empty()) tex = first_url(rec, "url");
            if (!tex.empty()) n["tex"] = tex;
        }
    };
    {
        auto store = base_store();
        if (store && store->available()) {
            auto bt = store->table("PersonCfg");
            if (bt) merge_person(*bt);
        }
    }
    auto mit = view.tables.find("PersonCfg");
    if (mit != view.tables.end() && mit->second) merge_person(*mit->second);
    json nodes = json::array();
    for (auto& kv : by_id) nodes.push_back(kv.second);
    std::stable_sort(nodes.begin(), nodes.end(), [](const json& a, const json& b) {
        auto ia = sa_core::py_int(a.value("id", "")), ib = sa_core::py_int(b.value("id", ""));
        if (ia && ib) return *ia < *ib;
        if (ia != ib) return ia.has_value();
        return a.value("id", "") < b.value("id", "");
    });

    // ---- levels：RelationCfg 本体全表 + Mod 行按 id 覆盖（/api/dicts 的 relations
    // 是静态内嵌，不并 Mod——这里必须自行 merge）。
    json rel = merged_table(view, "RelationCfg");
    json levels = json::array();
    for (const std::string& id : sorted_ids(rel)) {
        const json& rec = rel[id];
        if (!rec.is_object()) continue;
        json lv;
        lv["id"] = id;
        lv["name"] = rec.contains("name") ? json(py_str_or_empty(rec["name"])) : json("");
        auto color = p1::to_int(rec.contains("color") ? rec["color"] : json());
        if (color) {
            char buf[16];
            std::snprintf(buf, sizeof(buf), "#%06X",
                          static_cast<unsigned>(std::max(0LL, std::min(0xFFFFFFLL, *color))));
            lv["color"] = std::string(buf);
        } else {
            lv["color"] = nullptr;
        }
        lv["condition"] = json_opt_int(p1::to_int(rec.contains("condition") ? rec["condition"] : json()));
        auto up = p1::to_int(rec.contains("upgrade") ? rec["upgrade"] : json());
        lv["upgrade"] = (up && *up > 0) ? json(std::to_string(*up)) : json(nullptr);
        lv["upgradeCost"] = json_opt_int(p1::to_int(rec.contains("upgradeCost") ? rec["upgradeCost"] : json()));
        lv["socialCapacity"] =
            json_opt_int(p1::to_int(rec.contains("socialCapacity") ? rec["socialCapacity"] : json()));
        lv["iconRelation"] = rec.contains("iconRelation") && py_truthy(rec["iconRelation"])
                                 ? json(py_str_or_empty(rec["iconRelation"]))
                                 : json(nullptr);
        levels.push_back(std::move(lv));
    }

    // ---- edges：逐表扫 2D 码 + InteractCfg/FriendRequestCfg/Love* 整行。
    json edges = json::array();
    static const std::vector<TableSpec> specs = {
        {"EvtCfg", {{"condition", false}, {"effect", true}}},
        {"TalkCfg", {{"check", false}, {"effect", true}, {"effect2", true}}},
        {"OptionCfg", {{"check", false}, {"precondition", false}, {"effect", true}, {"effect2", true}}},
        {"InteractCfg", {{"cond", false}, {"effect", true}}},
        {"FriendRequestCfg", {{"appearCond", false}, {"interactCond", false}}},
        {"LoveGreetingCfg", {{"cond", false}}},
        {"LoveBreakfastCfg", {{"cond", false}}},
        {"LoveRibbonCfg", {{"cond", false}}},
        {"MinigameActionCfg", {{"effect", true}}},
    };
    const std::vector<const char*> name_fields = {"name", "title", "content", "showTxt", "txt",
                                                  "desc"};
    for (const auto& spec : specs) {
        json tbl = merged_table(view, spec.cfg);
        for (const std::string& id : sorted_ids(tbl)) {
            const json& rec = tbl[id];
            if (!rec.is_object()) continue;
            std::string name = preview_name(rec, name_fields);
            for (const auto& f : spec.fields) {
                if (!rec.contains(f.first)) continue;
                scan_code_rows(rec.at(f.first), f.second, spec.cfg, id, name, edges);
            }
        }
    }

    // 整行类边：interact（value=cond 数量）/ friendRequest（value=weight）/ loveScene。
    struct RowKind { const char* cfg; const char* kind; };
    static const std::vector<RowKind> row_kinds = {
        {"InteractCfg", "interact"}, {"FriendRequestCfg", "friendRequest"},
        {"LoveGreetingCfg", "loveScene"}, {"LoveBreakfastCfg", "loveScene"},
        {"LoveRibbonCfg", "loveScene"},
    };
    for (const auto& rk : row_kinds) {
        json tbl = merged_table(view, rk.cfg);
        for (const std::string& id : sorted_ids(tbl)) {
            const json& rec = tbl[id];
            if (!rec.is_object()) continue;
            json role = rec.contains("npc") ? json(rec["npc"]) : json(nullptr);
            json value = nullptr;
            if (std::string(rk.kind) == "interact") {
                long long n = 0;
                if (rec.contains("cond") && rec["cond"].is_array()) n = static_cast<long long>(rec["cond"].size());
                value = json(n);
            } else if (rec.contains("weight")) {
                value = json_opt_int(p1::to_int(rec["weight"]));
            }
            // 整行边没有单条码：code 取该行首个 2D 条件码的归一文本（无则 null）。
            json code = nullptr;
            for (const char* f : {"cond", "appearCond", "interactCond"}) {
                if (rec.contains(f) && rec[f].is_array() && !rec[f].empty() && rec[f][0].is_array()) {
                    code = row_display(rec[f][0]);
                    break;
                }
            }
            edges.push_back(make_edge(rk.kind, role, value, json(nullptr), code, rk.cfg, id,
                                      preview_name(rec, name_fields)));
        }
    }

    out["nodes"] = std::move(nodes);
    out["levels"] = std::move(levels);
    out["edges"] = std::move(edges);
    // 全量保留（bugfix 同风：无条数上限），truncated 恒 false。
    out["truncated"] = false;
}

// ---------------------------------------------------------------------------
// GET /api/graph/timeline
// ---------------------------------------------------------------------------

struct RoundInfo {
    long long round = 0, year = 0, season = 0;
    std::vector<long long> months;
    bool holiday = false;
    std::string season_name;
};

// 回合表：RoundCfg（id=回合号）+ SeasonCfg（月表/季节名/type）+ SeasonTypeCfg
// （id 501 或名称含「寒暑假」的类型 → holiday）。seasonName 优先用静态 turns
// 目录（round-1 下标，游戏内 62 回合逐一对位），缺表回退季节名。
std::vector<RoundInfo> build_rounds(const ModCfgsView& view) {
    json rcfg = merged_table(view, "RoundCfg");
    json scfg = merged_table(view, "SeasonCfg");
    json tcfg = merged_table(view, "SeasonTypeCfg");
    std::set<std::string> holiday_types;
    std::set<std::string> holiday_seasons;
    if (tcfg.is_object()) {
        for (auto it = tcfg.begin(); it != tcfg.end(); ++it) {
            bool is_holiday = canon_id(it.key()) == "501";
            if (!is_holiday && it.value().is_object() && it.value().contains("name") &&
                py_str_or_empty(it.value()["name"]).find("寒暑假") != std::string::npos)
                is_holiday = true;
            if (!is_holiday) continue;
            holiday_types.insert(canon_id(it.key()));
            if (it.value().is_object() && it.value().contains("seasons") && it.value()["seasons"].is_array())
                for (const auto& s : it.value()["seasons"])
                    if (auto v = p1::to_int(s)) holiday_seasons.insert(std::to_string(*v));
        }
    }
    const json& turns = p1::dicts().value("game_dicts", json::object()).value("turns", json::object());
    std::vector<RoundInfo> rounds;
    for (const std::string& id : sorted_ids(rcfg)) {
        const json& rec = rcfg[id];
        if (!rec.is_object()) continue;
        auto rid = p1::to_int(json(id));
        if (!rid) continue;
        RoundInfo r;
        r.round = *rid;
        r.year = p1::to_int(rec.contains("year") ? rec["year"] : json()).value_or(0);
        r.season = p1::to_int(rec.contains("season") ? rec["season"] : json()).value_or(0);
        std::string sid = std::to_string(r.season);
        if (scfg.contains(sid) && scfg[sid].is_object()) {
            const json& s = scfg[sid];
            r.season_name = py_str_or_empty(s.contains("name") ? s["name"] : json());
            if (s.contains("month") && s["month"].is_array())
                for (const auto& m : s["month"])
                    if (auto v = p1::to_int(m)) r.months.push_back(*v);
            std::string tid = s.contains("type") && p1::to_int(s["type"])
                                  ? std::to_string(*p1::to_int(s["type"]))
                                  : std::string();
            r.holiday = holiday_types.count(tid) > 0 || holiday_seasons.count(sid) > 0;
        }
        // turns 目录（静态 62 项）提供「小一 春」式整句季节名；越界/缺项退回季节名。
        std::string tkey = std::to_string(r.round - 1);
        if (turns.contains(tkey)) r.season_name = py_str_or_empty(turns.at(tkey));
        rounds.push_back(std::move(r));
    }
    return rounds;
}

const std::string kind_round = "round", kind_month = "month", kind_season = "season",
                  kind_year = "year", kind_holiday = "holiday", kind_special = "special";

// 单条 [2,*] 时间码 → 回合下标集合。返回 false 表示「有时间语义但无法定位」
// （计入 special）。open_end 指示集合是否语义上不封顶（[2,100]/[2,110]/[2,30]）。
bool map_time_code(const json& row, const std::vector<RoundInfo>& rounds, std::set<size_t>& idx_out,
                   std::string& kind_out, bool& open_end) {
    open_end = false;
    auto val = [&](size_t i) -> std::optional<long long> {
        return i < row.size() ? p1::to_int(row[i]) : std::nullopt;
    };
    auto s = val(1);
    if (!s) { kind_out = kind_special; return true; }
    auto hit = [&](std::function<bool(const RoundInfo&)> pred) {
        for (size_t i = 0; i < rounds.size(); ++i) if (pred(rounds[i])) idx_out.insert(i);
    };
    auto has_month = [&](const RoundInfo& r, long long m) {
        return std::find(r.months.begin(), r.months.end(), m) != r.months.end();
    };
    switch (*s) {
        case 0: {  // 第 V 回合
            auto v = val(2); if (!v) return false;
            kind_out = kind_round;
            hit([&](const RoundInfo& r) { return r.round == *v; });
            return true;
        }
        case 100: {  // 第 V 回合或以后
            auto v = val(2); if (!v) return false;
            kind_out = kind_round; open_end = true;
            hit([&](const RoundInfo& r) { return r.round >= *v; });
            return true;
        }
        case -100: {  // 未到第 V 回合
            auto v = val(2); if (!v) return false;
            kind_out = kind_round;
            hit([&](const RoundInfo& r) { return r.round < *v; });
            return true;
        }
        case 1: {  // V 月
            auto v = val(2); if (!v) return false;
            kind_out = kind_month;
            hit([&](const RoundInfo& r) { return has_month(r, *v); });
            return true;
        }
        case 11: {  // X 年 Y 月
            auto x = val(2), y = val(3); if (!x || !y) return false;
            kind_out = kind_month;
            hit([&](const RoundInfo& r) { return r.year == *x && has_month(r, *y); });
            return true;
        }
        case 110: {  // X 年 Y 月或以后 → 该月起，to=null
            auto x = val(2), y = val(3); if (!x || !y) return false;
            kind_out = kind_month; open_end = true;
            size_t start = rounds.size();
            for (size_t i = 0; i < rounds.size(); ++i) {
                const RoundInfo& r = rounds[i];
                if (r.year > *x || (r.year == *x && has_month(r, *y))) { start = i; break; }
            }
            if (start < rounds.size())
                for (size_t i = start; i < rounds.size(); ++i) idx_out.insert(i);
            return true;
        }
        case 20: {  // X 到 Y 年（区间）
            auto x = val(2), y = val(3); if (!x || !y) return false;
            long long lo = std::min(*x, *y), hi = std::max(*x, *y);
            kind_out = kind_year;
            hit([&](const RoundInfo& r) { return r.year >= lo && r.year <= hi; });
            return true;
        }
        case 10: {  // V 年
            auto v = val(2); if (!v) return false;
            kind_out = kind_year;
            hit([&](const RoundInfo& r) { return r.year == *v; });
            return true;
        }
        case 12: {  // 偶数年
            kind_out = kind_year;
            hit([](const RoundInfo& r) { return r.year % 2 == 0; });
            return true;
        }
        case 4: {  // V 季（year 未约束时全季所有回合）
            auto v = val(2); if (!v) return false;
            kind_out = kind_season;
            hit([&](const RoundInfo& r) { return r.season == *v; });
            return true;
        }
        case 3: {  // X 年 Y 季
            auto x = val(2), y = val(3); if (!x || !y) return false;
            kind_out = kind_season;
            hit([&](const RoundInfo& r) { return r.year == *x && r.season == *y; });
            return true;
        }
        case 30: {  // X 年 Y 季或以后
            auto x = val(2), y = val(3); if (!x || !y) return false;
            kind_out = kind_season; open_end = true;
            size_t start = rounds.size();
            for (size_t i = 0; i < rounds.size(); ++i) {
                const RoundInfo& r = rounds[i];
                if (r.year > *x || (r.year == *x && r.season == *y)) { start = i; break; }
            }
            if (start < rounds.size())
                for (size_t i = start; i < rounds.size(); ++i) idx_out.insert(i);
            return true;
        }
        case 8: {  // 寒暑假（1 是 / -1 非）
            auto v = val(2); if (!v) return false;
            kind_out = kind_holiday;
            bool want = *v > 0;
            hit([&](const RoundInfo& r) { return r.holiday == want; });
            return true;
        }
        case 101:  // 生日等主角个人历 → 无回合表可依，special
        default:
            kind_out = kind_special;
            return true;
    }
}

// [年,月] 的排序键（季节跨多月：起点用最小月、终点用最大月，命中「当月及其后」
// 语义即 起点<=键<=终点 的回合参与区间）。
long long key_of(long long year, long long month) { return year * 100 + month; }

void timeline_body(const ModCfgsView& view, json& out) {
    std::vector<RoundInfo> rounds = build_rounds(view);
    json rarr = json::array();
    for (const auto& r : rounds) {
        json o;
        o["round"] = r.round;
        o["year"] = r.year;
        o["season"] = r.season;
        o["seasonName"] = r.season_name;
        json months = json::array();
        for (auto m : r.months) months.push_back(m);
        o["months"] = std::move(months);
        o["holiday"] = r.holiday;
        rarr.push_back(std::move(o));
    }
    out["rounds"] = std::move(rarr);

    json items = json::array();
    // 时间码交集求解器：codes（[2,*] 行）+ begin/end（[年,月]）→ spans。
    // 多条时间约束按「同时成立」取交集；无法定位的码计入 special（不缩集，
    // 且当全部约束都 special 时 spans 给空数组——契约的生日规则）。
    auto solve = [&](const std::vector<const json*>& time_codes, const json* begin_t,
                     const json* end_t, json& item_out, bool& emit) {
        std::set<size_t> cur;
        for (size_t i = 0; i < rounds.size(); ++i) cur.insert(i);
        std::vector<std::string> kinds, codes;
        bool any = false, open_end = false, special = false;
        auto intersect = [&](const std::set<size_t>& s) {
            std::set<size_t> nxt;
            std::set_intersection(cur.begin(), cur.end(), s.begin(), s.end(),
                                  std::inserter(nxt, nxt.end()));
            cur = std::move(nxt);
        };
        auto push_kind = [&](const std::string& k) {
            if (std::find(kinds.begin(), kinds.end(), k) == kinds.end()) kinds.push_back(k);
        };
        for (const json* code : time_codes) {
            any = true;
            std::set<size_t> s;
            std::string kind;
            bool open = false;
            codes.push_back(row_compact(*code));
            if (!rounds.empty() && map_time_code(*code, rounds, s, kind, open) && kind != kind_special) {
                intersect(s);
                if (open) open_end = true;
            } else {
                special = true;
            }
            push_kind(kind.empty() ? kind_special : kind);
        }
        // ActionCfg beginTime/endTime：「当月及其后到 end 月」。缺省形态（空数组/
        // 年<=0，游戏数据里的 [0,0] 即未设）不参与约束。
        auto month_range = [&](const json* bound, bool is_end) -> std::optional<std::set<size_t>> {
            if (!bound || !bound->is_array() || bound->empty()) return std::nullopt;
            auto y = p1::to_int((*bound)[0]);
            if (!y || *y <= 0) return std::nullopt;
            long long m = bound->size() >= 2 ? p1::to_int((*bound)[1]).value_or(1) : 1;
            long long k = key_of(*y, m);
            std::set<size_t> s;
            for (size_t i = 0; i < rounds.size(); ++i) {
                const RoundInfo& r = rounds[i];
                if (r.months.empty()) continue;
                long long lo = key_of(r.year, *std::min_element(r.months.begin(), r.months.end()));
                long long hi = key_of(r.year, *std::max_element(r.months.begin(), r.months.end()));
                if (is_end) { if (lo <= k) s.insert(i); }
                else { if (hi >= k) s.insert(i); }
            }
            return s;
        };
        if (!rounds.empty()) {
            auto bs = month_range(begin_t, false);
            auto es = month_range(end_t, true);
            if (bs) { any = true; intersect(*bs); push_kind(kind_month); if (!es) open_end = true; }
            if (es) { any = true; intersect(*es); push_kind(kind_month); }
        } else {
            // 无回合表：beginTime/endTime 也无从换算 → special。
            if ((begin_t && begin_t->is_array() && !begin_t->empty() && p1::to_int((*begin_t)[0])) ||
                (end_t && end_t->is_array() && !end_t->empty() && p1::to_int((*end_t)[0]))) {
                any = true;
                special = true;
                push_kind(kind_special);
            }
        }
        if (!any) { emit = false; return; }
        bool has_mapped = false;
        for (auto& k : kinds) if (k != kind_special) has_mapped = true;
        if (special && !has_mapped) {
            kinds = {kind_special};
            cur.clear();  // 契约：无法定位 → timeKinds=["special"]、spans=[]
        }
        json spans = json::array();
        {
            // 连续段压缩；open_end 且最后一段贴到末回合时 to=null。
            std::vector<size_t> vec(cur.begin(), cur.end());
            size_t i = 0;
            while (i < vec.size()) {
                size_t j = i;
                while (j + 1 < vec.size() && vec[j + 1] == vec[j] + 1) ++j;
                json sp;
                sp["from"] = rounds[vec[i]].round;
                sp["to"] = rounds[vec[j]].round;
                spans.push_back(std::move(sp));
                i = j + 1;
            }
            if (open_end && !vec.empty() && vec.back() + 1 == rounds.size())
                spans[spans.size() - 1]["to"] = nullptr;
        }
        json karr = json::array();
        for (auto& k : kinds) karr.push_back(k);
        json carr = json::array();
        for (auto& c : codes) carr.push_back(c);
        item_out["timeKinds"] = std::move(karr);
        item_out["spans"] = std::move(spans);
        item_out["codes"] = std::move(carr);
        emit = true;
    };

    auto add_item = [&](const char* cfg, const std::string& id,
                        std::vector<const json*> codes, const json* begin_t, const json* end_t,
                        const json& map_id, const json& npc, const json& name) {
        json item;
        item["cfg"] = cfg;
        item["id"] = id;
        item["name"] = name;
        item["mapId"] = map_id;
        item["npc"] = npc;
        bool emit = false;
        solve(codes, begin_t, end_t, item, emit);
        if (emit) items.push_back(std::move(item));
    };

    // EvtCfg：condition（2D）里的 [2,*] 码族。
    {
        json evt = merged_table(view, "EvtCfg");
        for (const std::string& id : sorted_ids(evt)) {
            const json& rec = evt[id];
            if (!rec.is_object()) continue;
            std::vector<const json*> codes;
            if (rec.contains("condition") && rec["condition"].is_array())
                for (const auto& row : rec["condition"])
                    if (row.is_array() && !row.empty() && p1::to_int(row[0]) == 2) codes.push_back(&row);
            if (codes.empty()) continue;
            json map_id = rec.contains("mapId") && p1::to_int(rec["mapId"]) && *p1::to_int(rec["mapId"]) != 0
                              ? json(ns(rec["mapId"])) : json(nullptr);
            json npc = rec.contains("npc") && p1::to_int(rec["npc"]) && *p1::to_int(rec["npc"]) != 0
                           ? json(ns(rec["npc"])) : json(nullptr);
            add_item("EvtCfg", id, codes, nullptr, nullptr, map_id, npc,
                     json(preview_name(rec, {"title", "content", "desc"})));
        }
    }
    // ActionCfg：cond（若存在）+ beginTime/endTime。
    {
        json act = merged_table(view, "ActionCfg");
        for (const std::string& id : sorted_ids(act)) {
            const json& rec = act[id];
            if (!rec.is_object()) continue;
            std::vector<const json*> codes;
            for (const char* f : {"cond", "condition"}) {
                if (!rec.contains(f) || !rec[f].is_array()) continue;
                for (const auto& row : rec[f])
                    if (row.is_array() && !row.empty() && p1::to_int(row[0]) == 2) codes.push_back(&row);
            }
            const json* bt = rec.contains("beginTime") ? &rec["beginTime"] : nullptr;
            const json* et = rec.contains("endTime") ? &rec["endTime"] : nullptr;
            if (codes.empty() &&
                !(bt && bt->is_array() && !bt->empty()) &&
                !(et && et->is_array() && !et->empty()))
                continue;
            json map_id = rec.contains("map") && p1::to_int(rec["map"]) && *p1::to_int(rec["map"]) != 0
                              ? json(ns(rec["map"])) : json(nullptr);
            add_item("ActionCfg", id, codes, bt, et, map_id, json(nullptr),
                     json(preview_name(rec, {"name", "title"})));
        }
    }
    out["items"] = std::move(items);
}

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

    // GET /api/graph/relations — 人物关系图（nodes/levels/edges，mod+本体合并）。
    r.get(R"(/api/graph/relations)", [](const Req&) -> Resp {
        ModCfgsView view = load_mod_cfgs();
        json out = json::object();
        relations_body(view, out);
        return Resp::Json(200, std::move(out));
    });

    // GET /api/graph/timeline — 时间约束 → 回合索引（rounds/items，mod+本体合并）。
    r.get(R"(/api/graph/timeline)", [](const Req&) -> Resp {
        ModCfgsView view = load_mod_cfgs();
        json out = json::object();
        timeline_body(view, out);
        return Resp::Json(200, std::move(out));
    });
}

}  // namespace sa
