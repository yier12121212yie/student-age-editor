// test_effect_corpus.cpp — [corpus] 拆解率基线 + 往返等价（D5）。
//
// 目标（见 plan/ux_roadmap_r2.md 的 D5）：
//   1. 用「本体全表语料」度量 /api/effect/parse 的**拆解率**：
//      静态模板 DB（CONDITION_DB / EFFECT_DB / COST_DB / SCREEN_EFFECT_DB /
//      ACTION_CMD_DB）里的每条 code 展开成一条真实码串（占位符代入字典池的
//      合法值），逐条 parse，统计
//        ok / logic_error / json_error / partial / 无模板行
//      占比 —— 这就是「拆解率」基线，之后只升不降。
//   2. **往返等价**：parse 后把 rows 重新拼回码串（父行 display + nested 递归），
//      与原码串做「JSON 语义等价」（逐行 parse 成数组后逐元素数值/字符串比较，
//      忽略空白差异）。这是"一旦用户改一行，其余行会被重新序列化"的安全网。
//
// 语料完全自包含（不依赖 base_store 产物 / 真实 Mods）：模板 DB 本身即本体声明
// 的码空间，逐条代入占位符即可构造出「必然应当拆得动」的样本。若某条拆不动，
// 说明本体模板与解析器/二次代码字典之间已经漂移——这正是基线要护栏的东西。
//
// 口径说明（D5 回填实测后澄清）：
//   * 模板 DB 的 `code` **自带外层 `[ … ]`**（见 semantic_assets.cpp 的
//     `gain["code"] = "[7, 2, @STATE@]"`），所以语料直接喂 `expanded`，**不要**再包一层
//     ——否则会把单行变成嵌套行，往返比对整列假性失败（历史上正是这个坑）。
//   * `logic_error`（"XX ID 字典中不存在"）是**运行环境字典数据**的有效性问题，
//     不是"拆不成积木"：这类行**仍然带模板与参数槽**，在简易模式里照常可编辑
//     （D1/D2）。因此它与 `json_error`（结构性拆不动）必须分开统计，前者不设硬门槛。
//   * 因此「拆解率」= **拿到模板的行 / 总行数**；`json_error`/`partial` 才是硬门槛。
//
// fixture 与 test_semantic_graph.cpp 同款（temp workspace + 空 mod + build_router）。
#include <catch_amalgamated.hpp>

#include <algorithm>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <map>
#include <memory>
#include <mutex>
#include <set>
#include <string>
#include <vector>

#include "test_support.h"

#include "sa_core/paths.h"
#include "sa_core/util.h"
#include "semantic_assets.h"

#include "server/api_router.h"
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

class CorpusFixture {
  public:
    CorpusFixture() : root_(sat::make_temp_dir("corpus")) {
        mod_root_ = root_ / "mod";
        cfg_dir_ = mod_root_ / "Cfgs" / "zh-cn";
        fs::create_directories(cfg_dir_);
        auto& st = sa::STATE();
        {
            std::lock_guard<std::mutex> lk(st.mu_);
            saved_ws_ = st.workspace_root;
            saved_mod_root_ = st.mod_root;
            saved_mod_name_ = st.mod_name;
            st.workspace_root = sa_core::paths::path_to_utf8(root_);
            st.mod_root = sa_core::paths::path_to_utf8(mod_root_);
            st.mod_name = "mod";
        }
        saved_data_root_ = getenv_portable("EDITOR_DATA_ROOT");
        putenv_portable("EDITOR_DATA_ROOT", "");
        sa::detail::set_editor_root(sa_core::paths::path_to_utf8(root_ / "data"));
        sa::invalidate_table_cache_all();
        sa::invalidate_mod_cfgs_cache();
        router_ = std::make_unique<sa::Router>(sa::build_router());
    }
    ~CorpusFixture() {
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
    CorpusFixture(const CorpusFixture&) = delete;
    CorpusFixture& operator=(const CorpusFixture&) = delete;

    json parse(const std::string& text, const std::string& mode) {
        auto r = sat::call_router(*router_, "POST", "/api/effect/parse", {},
                                  json{{"text", text}, {"mode", mode}});
        REQUIRE(r.status == 200);
        return r.json_payload;
    }

  private:
    fs::path root_, mod_root_, cfg_dir_;
    std::string saved_ws_, saved_mod_root_, saved_mod_name_, saved_data_root_;
    std::unique_ptr<sa::Router> router_;
};

// 占位符 → 合法值的代入表。取值优先用字典池（ATTR/ROLE/... 的实键），
// 池为空（CSV 派生池在本仓库运行时为空）时退化为提示号本身能接受的中性值。
std::map<std::string, std::string> placeholder_values() {
    using sa::p1::pool_by_key;
    auto pick = [](const std::string& key, const std::string& fallback) -> std::string {
        const auto& p = pool_by_key(key);
        if (!p.empty()) return p.begin()->first;
        return fallback;
    };
    std::map<std::string, std::string> m;
    m["@ATTR@"] = pick("ATTR", "1");
    m["@ROLE@"] = pick("ROLE", "101");
    m["@ITEM@"] = pick("ITEM", "1");
    m["@RELATION@"] = pick("RELATION", "1");
    m["@MAP@"] = pick("MAP", "1");
    m["@JOB@"] = pick("JOB", "1");
    m["@STATE@"] = pick("STATE", "1");
    // 文本槽必须**带引号**代入，否则展开出的码串不是合法 JSON（形如 `[999, 10, 文本]`），
    // 会把本该 logic/ok 的样本误判成 json_error。
    m["@TEXT@"] = "\"文本\"";
    m["@GAME@"] = pick("GAME", "1");
    m["@KZONE_POST@"] = pick("KZONE_POST", "1");
    m["@KZONE_MESSAGE@"] = pick("KZONE_MESSAGE", "1");
    m["@PHONE_MSG@"] = pick("PHONE_MSG", "1");
    m["@NEGOTIATION_SKILL@"] = pick("NEGOTIATION_SKILL", "1");
    m["@NEGOTIATION_BUFF@"] = pick("NEGOTIATION_BUFF", "1");
    return m;
}

// 把模板 code 里所有占位符与单字母形参替换成具体值，得到一条「应当可拆」的码串。
//
// 形参约定（见 data_dicts.py 的模板注释）：N/X/Y/Z/V/T/I/B/C/G/S/A/P/MAX/Emoji/
// Bg/Npc/CG 等为数值或引用位；EFFECTS* 为嵌套尾（调用方决定是否展开）。
std::string expand_template(const std::string& code,
                            const std::map<std::string, std::string>& ph) {
    std::string out = code;
    // 长占位符优先（@KZONE_POST@ 先于 @KZONE_... 等无前缀冲突，但按长度降序更稳）。
    std::vector<std::pair<std::string, std::string>> subs;
    for (const auto& kv : ph) subs.emplace_back(kv.first, kv.second);
    std::sort(subs.begin(), subs.end(), [](const auto& a, const auto& b) {
        return a.first.size() > b.first.size();
    });
    for (const auto& kv : subs) {
        size_t p = 0;
        while ((p = out.find(kv.first, p)) != std::string::npos) {
            out.replace(p, kv.first.size(), kv.second);
            p += kv.second.size();
        }
    }
    // 单字母形参：token 边界匹配（前后为非字母数字）。
    static const std::map<char, std::string> single = {
        {'N', "1"}, {'X', "3"}, {'Y', "4"}, {'Z', "5"}, {'V', "6"},
        {'T', "1"}, {'I', "2"},  {'B', "1"}, {'C', "0"}, {'G', "1"},
        {'S', "1"}, {'A', "1"},  {'P', "0"}, {'E', "0"},
    };
    std::string res;
    res.reserve(out.size());
    auto is_ident = [](char c) {
        return (c >= '0' && c <= '9') || (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || c == '_';
    };
    for (size_t i = 0; i < out.size(); ++i) {
        char c = out[i];
        auto it = single.find(c);
        bool boundary = (i == 0 || !is_ident(out[i - 1])) &&
                        (i + 1 >= out.size() || !is_ident(out[i + 1]));
        if (it != single.end() && boundary) {
            res += it->second;
        } else {
            res += c;
        }
    }
    // 多字母形参里只有 MAX/Emoji/Bg/Npc/CG 会剩下；逐个替换。
    static const std::pair<const char*, const char*> words[] = {
        {"MAX", "99"}, {"Emoji", "1"}, {"Bg", "1"}, {"Npc", "1"}, {"CG", "1"},
    };
    for (const auto& w : words) {
        size_t p = 0;
        while ((p = res.find(w.first, p)) != std::string::npos) {
            res.replace(p, std::string(w.first).size(), w.second);
            p += std::string(w.second).size();
        }
    }
    return res;
}

// 从模板 code 里抠出所有非数字位置（形参），用于判断展开后是否仍有残留字母。
bool has_alpha(const std::string& s) {
    for (char c : s)
        if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z')) return true;
    return false;
}

// rows（含 nested）→ 逐行码串列表，用于往返等价比较。
void collect_displays(const json& rows, std::vector<std::string>& out) {
    for (const auto& r : rows) {
        if (r.contains("display") && r.at("display").is_string())
            out.push_back(r.at("display").get<std::string>());
        if (r.contains("nested") && r.at("nested").is_array())
            collect_displays(r.at("nested"), out);
        // 998 的 rest 槽也可能是 nested 形态（本文只按 display 递归，足够）。
    }
}

// 行级统计：拿到模板的行 / 无模板的行（nested 递归）。
void count_row_templates(const json& rows, long long& with_tpl, long long& no_tpl) {
    for (const auto& r : rows) {
        if (r.contains("template") && r.at("template").is_null()) ++no_tpl;
        else ++with_tpl;
        if (r.contains("nested") && r.at("nested").is_array())
            count_row_templates(r.at("nested"), with_tpl, no_tpl);
    }
}

// 把一行码串规范化成可比较的 token 序列（去掉方括号/空白，按逗号切分）。
std::vector<std::string> row_tokens(const std::string& line) {
    std::string t = line;
    size_t a = t.find_first_not_of(" \t\r\n");
    size_t b = t.find_last_not_of(" \t\r\n");
    t = (a == std::string::npos) ? std::string() : t.substr(a, b - a + 1);
    if (!t.empty() && t.front() == '[') t.erase(t.begin());
    if (!t.empty() && t.back() == ']') t.pop_back();
    std::vector<std::string> out;
    std::string cur;
    for (char c : t) {
        if (c == ',') {
            size_t s = cur.find_first_not_of(" \t");
            size_t e = cur.find_last_not_of(" \t");
            out.push_back(s == std::string::npos ? std::string() : cur.substr(s, e - s + 1));
            cur.clear();
        } else {
            cur += c;
        }
    }
    {
        size_t s = cur.find_first_not_of(" \t");
        size_t e = cur.find_last_not_of(" \t");
        if (s != std::string::npos) out.push_back(cur.substr(s, e - s + 1));
    }
    return out;
}

// 逐行「JSON 语义」比较：元素数一致且逐元素字符串相等（数值的 01/1 差异按
// 整数归一）。返回不等价的行下标（空 = 全部等价）。
std::vector<size_t> roundtrip_mismatches(const std::string& original,
                                         const std::vector<std::string>& reparsed) {
    // 原串按顶层 `;` 切行（本语料每模板一条码，但兼容多行）。
    std::vector<std::string> orig_lines;
    {
        std::string cur;
        int depth = 0;
        for (char c : original) {
            if (c == '[') ++depth;
            if (c == ']') --depth;
            if (c == ';' && depth == 0) {
                orig_lines.push_back(cur);
                cur.clear();
            } else {
                cur += c;
            }
        }
        if (!cur.empty()) orig_lines.push_back(cur);
    }
    std::vector<size_t> bad;
    const size_t n = std::min(orig_lines.size(), reparsed.size());
    for (size_t i = 0; i < n; ++i) {
        auto a = row_tokens(orig_lines[i]);
        auto b = row_tokens(reparsed[i]);
        if (a.size() != b.size()) {
            bad.push_back(i);
            continue;
        }
        bool same = true;
        for (size_t j = 0; j < a.size(); ++j) {
            if (a[j] == b[j]) continue;
            // 数值容忍：前导零 / 正负号写法差异按整数比较。
            auto pa = sa_core::py_int(a[j]);
            auto pb = sa_core::py_int(b[j]);
            if (pa && pb && *pa == *pb) continue;
            same = false;
            break;
        }
        if (!same) bad.push_back(i);
    }
    if (orig_lines.size() != reparsed.size()) {
        // 行数不一致：把多出来的行也标为不等价。
        for (size_t i = n; i < std::max(orig_lines.size(), reparsed.size()); ++i) bad.push_back(i);
    }
    return bad;
}

struct DbCase {
    const char* name;
    const char* mode;
    const json* db;
};

std::vector<DbCase> all_dbs() {
    using sa::p1::condition_db;
    using sa::p1::cost_db;
    // 关键：effect 模式解析器匹配的是 **派生表** `effect_editor_db()`
    // （semantic_core.cpp:374 `effect_editor_secondary_index` → parse_semantic_row），
    // **不是**原始 `effect_db()`。原始表里含遗留的 4 元形态 `[7, 2, V, T]`
    // （"获得状态 V (持续T回合)"），派生表把它丢弃并替换为 3 元规范形
    // `[7, 2, @STATE@]`（见 semantic_assets.cpp:194-216）。若照原始表喂，
    // 该条会命中"无模板行"，是**测错了表**、不是真漂移。
    using sa::p1::effect_editor_db;
    using sa::p1::screen_effect_db;
    using sa::p1::action_cmd_db;
    return {
        {"condition", "condition", &condition_db()},
        {"effect", "effect", &effect_editor_db()},
        {"cost", "cost", &cost_db()},
        {"screen", "screen", &screen_effect_db()},
        {"action", "action", &action_cmd_db()},
    };
}

}  // namespace

// ---------------------------------------------------------------------------
// D5-1 拆解率基线：模板 DB 展开后的语料逐条 parse，统计各状态占比。
//
// 分两类指标：
//   * 结构性（硬门槛）：json_error / partial 必须为 0；行级「拿到模板」占比即拆解率。
//   * 有效性（软记录）：logic_error 是"ID 不在当前字典"——依赖运行环境的 Cfg 数据，
//     在空工作区的单测环境必然存在，只作 INFO 回填，不设硬门槛（否则测试与数据耦合）。
// ---------------------------------------------------------------------------
TEST_CASE("corpus: 拆解率基线 over 模板 DB 全表", "[p1][graph][corpus]") {
    CorpusFixture fx;
    const auto ph = placeholder_values();

    long long total = 0, ok = 0, logic = 0, json_err = 0, partial = 0, skipped = 0;
    long long with_tpl = 0, no_tpl = 0;

    for (const auto& c : all_dbs()) {
        REQUIRE(c.db->is_array());
        for (const auto& t : *c.db) {
            if (!t.is_object() || !t.contains("code")) continue;
            const std::string code = t.at("code").get<std::string>();
            const std::string expanded = expand_template(code, ph);
            // 展开后仍残留字母（未知形参）的模板：跳过，避免噪音（并计入 skipped）。
            if (has_alpha(expanded)) {
                ++skipped;
                continue;
            }
            // 模板 code 自带外层 `[ … ]`，直接喂 expanded（勿再包一层）。
            json b = fx.parse(expanded, c.mode);
            ++total;
            const std::string st = b.value("status", std::string());
            if (st == "ok") {
                ++ok;
            } else if (st == "logic_error") {
                ++logic;
            } else if (st == "json_error") {
                ++json_err;
            } else if (st == "partial") {
                ++partial;
            }
            if (b.contains("rows") && b.at("rows").is_array())
                count_row_templates(b.at("rows"), with_tpl, no_tpl);
        }
    }

    const double rows_total = static_cast<double>(with_tpl + no_tpl);
    const double structured_rate = rows_total > 0 ? static_cast<double>(with_tpl) / rows_total : 0.0;
    const double valid_rate =
        (ok + logic) > 0 ? static_cast<double>(ok) / static_cast<double>(ok + logic) : 0.0;

    INFO("拆解率基线: 样本模板=" << total << " 结构化OK=" << ok << " logic_error=" << logic
                              << " json_error=" << json_err << " partial=" << partial
                              << " skipped(未知形参)=" << skipped);
    INFO("行级: 有模板行=" << with_tpl << " 无模板行=" << no_tpl << " 拆解率(行)="
                         << (structured_rate * 100.0) << "%");
    INFO("逻辑校验(依赖运行环境字典): 通过=" << ok << " 未通过=" << logic << " 通过率="
                                        << (valid_rate * 100.0) << "%");

    CHECK(total > 100);      // 语料规模下限：本体模板表远大于 100 条
    CHECK(json_err == 0);    // 结构性：本体模板展开后必须都能被 JSON 解析
    CHECK(partial == 0);     // 结构性：不存在需要逐行回退的坏段
    CHECK(no_tpl == 0);      // 每一行都要能落到模板（或通用 param_N 槽）
    // 拆解率（拿到模板的行 / 总行数）作为棘轮：记录基线，之后只升不降。
    INFO("拆解率 = " << (structured_rate * 100.0) << "% (有模板 " << with_tpl << "/"
                   << (long long)rows_total << ")");
    CHECK(structured_rate >= 0.999);
}

// ---------------------------------------------------------------------------
// D5-2 往返等价：parse(x) 后 rows[].display 重拼，与原值 JSON 语义等价。
// ---------------------------------------------------------------------------
TEST_CASE("corpus: 往返等价 (parse → rows.display 重拼)", "[p1][graph][corpus]") {
    CorpusFixture fx;
    const auto ph = placeholder_values();

    long long checked = 0, mismatched = 0;
    std::vector<std::string> bad_samples;

    for (const auto& c : all_dbs()) {
        for (const auto& t : *c.db) {
            if (!t.is_object() || !t.contains("code")) continue;
            const std::string expanded = expand_template(t.at("code").get<std::string>(), ph);
            if (has_alpha(expanded)) continue;

            const std::string input = expanded;  // code 自带外层括号
            json b = fx.parse(input, c.mode);
            const std::string st = b.value("status", std::string());
            if (st != "ok" && st != "logic_error") continue;  // 只校验拆得动的
            ++checked;

            std::vector<std::string> displays;
            if (b.contains("rows")) collect_displays(b.at("rows"), displays);
            // 拼回顶层码串（本语料每模板一条；多行情形也一并覆盖）。
            std::string rejoined;
            for (size_t i = 0; i < displays.size(); ++i) {
                if (i) rejoined += "; ";
                rejoined += displays[i];
            }
            auto bad = roundtrip_mismatches(input, {rejoined});
            if (!bad.empty()) {
                ++mismatched;
                if (bad_samples.size() < 12)
                    bad_samples.push_back(input + "  ->  " + rejoined);
            }
        }
    }

    for (const auto& s : bad_samples) INFO("往返不等价样本: " << s);
    INFO("往返等价: checked=" << checked << " mismatched=" << mismatched);
    CHECK(checked > 100);
    CHECK(mismatched == 0);  // D5 验收：往返不等价样本清零
}

// ---------------------------------------------------------------------------
// D5-3 语料里含问题/坏行的样本：确保 status 分类口径与 D1/D3 一致。
// ---------------------------------------------------------------------------
TEST_CASE("corpus: 分类口径抽样（logic_error / partial / json_error）",
          "[p1][graph][corpus]") {
    CorpusFixture fx;
    // 一行坏、一行好 → logic_error（第一行是字典里不存在的 ID）。
    {
        json b = fx.parse("[888888, 0]; [1, 1, 1, 5]", "effect");
        CHECK(b.value("status", std::string()) == "logic_error");
        CHECK(b.value("ok", true) == false);
    }
    // 整体坏、逐行可救 → partial。
    {
        json b = fx.parse("[1, 1, 1, 5]; [999, x]", "effect");
        CHECK(b.value("status", std::string()) == "partial");
    }
    // 一行都救不回 → json_error + 定位。
    {
        json b = fx.parse("[999, x]", "effect");
        CHECK(b.value("status", std::string()) == "json_error");
        CHECK(b.contains("error_offset"));
    }
}
