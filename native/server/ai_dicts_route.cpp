// GET /api/ai/dicts — see ai_dicts_route.h for provenance.
#include "server/ai_dicts_route.h"

#include <algorithm>
#include <cctype>
#include <string>
#include <vector>

#include "sa_core/util.h"                  // py_str
#include "services/semantic_assets.h"  // sa::p1::dicts()
#include "server/state.h"              // SandboxError

namespace sa {
namespace {

// GAME_DICT_SOURCES (ai_domain_service.py:656-667): id -> {cn, dicts.json key}.
// Insertion order drives list_dicts() output order.
struct DictSource {
    const char* id;
    const char* cn;
};
const DictSource kGameDictSources[] = {
    {"roles", "角色"},          {"items", "物品"},        {"maps", "地点"},
    {"jobs", "职业"},           {"attrs", "属性"},        {"relations", "关系"},
    {"bgs", "背景"},            {"turns", "回合"},        {"evt_types", "事件类型"},
    {"badminton_models", "羽毛球模型"},
};

std::string ascii_lower(std::string s) {
    for (char& c : s) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    return s;
}

std::string strip(const std::string& s) {
    size_t b = s.find_first_not_of(" \t\n\r\f\v");
    if (b == std::string::npos) return "";
    size_t e = s.find_last_not_of(" \t\n\r\f\v");
    return s.substr(b, e - b + 1);
}

// str(v) for a scalar; list/tuple takes str(v[0]) (get_dict label rule).
std::string label_of(const json& v) {
    if (v.is_array() && !v.empty()) return sa_core::py_str(v.front());
    return sa_core::py_str(v);
}

bool id_is_digits(const std::string& s) {
    // Python str.isdigit() (ASCII subset; see merged-wave deviation notes).
    size_t i = (s == "-") ? 1 : 0;
    if (i >= s.size()) return false;
    for (; i < s.size(); ++i)
        if (!std::isdigit(static_cast<unsigned char>(s[i]))) return false;
    return true;
}

json list_dicts() {
    // ai_domain_service.py:670-683
    const json& gd = sa::p1::dicts().value("game_dicts", json::object());
    json out = json::array();
    for (const auto& src : kGameDictSources) {
        long long count = 0;
        auto it = gd.find(src.id);
        if (it != gd.end() && it->is_object()) count = static_cast<long long>(it->size());
        out.push_back(json{{"id", src.id}, {"name", src.cn}, {"count", count}});
    }
    return out;
}

json get_dict(const std::string& name_raw, const std::string& q_raw,
              const std::string* limit_raw) {
    // ai_domain_service.py:686-714
    std::string name = ascii_lower(strip(name_raw));
    const DictSource* src = nullptr;
    for (const auto& s : kGameDictSources)
        if (name == s.id) { src = &s; break; }
    if (!src) {
        throw SandboxError("未知字典 " + name_raw +
                           "（可用 get_game_dicts 不带参数查看可用字典列表）");
    }
    const json& gd = sa::p1::dicts().value("game_dicts", json::object());
    json d = json::object();
    auto it = gd.find(std::string(src->id));
    if (it != gd.end() && it->is_object()) d = *it;
    std::string q = ascii_lower(strip(q_raw));
    json items = json::array();
    for (auto& [k, v] : d.items()) {
        std::string label = label_of(v);
        if (!q.empty() && ascii_lower(k).find(q) == std::string::npos &&
            ascii_lower(label).find(q) == std::string::npos)
            continue;
        items.push_back(json{{"id", k}, {"name", label}});
    }
    std::stable_sort(items.begin(), items.end(), [](const json& a, const json& b) {
        auto key = [](const json& it) -> std::pair<long long, std::string> {
            const std::string& id = it["id"].get_ref<const std::string&>();
            // Python: it["id"].lstrip("-").isdigit() → int(id) else 1<<60
            size_t n = 0;
            while (n < id.size() && id[n] == '-') n++;
            std::string t = id.substr(n);
            bool numeric = !t.empty();
            for (char c : t)
                if (!std::isdigit(static_cast<unsigned char>(c))) { numeric = false; break; }
            if (numeric) {
                try { return {std::stoll(id), id}; } catch (...) {}
            }
            return {1LL << 60, id};
        };
        return key(a) < key(b);
    });
    // total = filtered count BEFORE the cap slice (Python len(items) before [:cap]).
    long long total = static_cast<long long>(items.size());
    long long cap = 30;
    if (limit_raw && !limit_raw->empty()) {
        try {
            size_t pos = 0;
            long long v = std::stoll(*limit_raw, &pos);
            if (pos == limit_raw->size()) cap = std::max(1LL, std::min(v, 100LL));
        } catch (...) { cap = 30; }
    }
    if (static_cast<long long>(items.size()) > cap)
        items = json(items.begin(), items.begin() + cap);
    return json{{"name", name}, {"cn", src->cn}, {"total", total}, {"items", items}};
}

}  // namespace

void register_ai_dicts_route(Router& r) {
    // api.py:1674-1684 (ai_dicts).
    r.get(R"(/api/ai/dicts)", [](const Req& req) -> Resp {
        auto qv = [&](const char* k) -> std::string {
            auto it = req.query.find(k);
            return it == req.query.end() ? "" : it->second;
        };
        try {
            std::string name = qv("name");
            if (name.empty()) {
                // Python `(_query or {}).get("name","")` — empty name → list.
                return Resp::Json(200, json{{"dicts", list_dicts()}});
            }
            std::string limit = qv("limit");
            return Resp::Json(200, get_dict(name, qv("q"), limit.empty() ? nullptr : &limit));
        } catch (const SandboxError& e) {
            return Resp::Json(400, json{{"error", e.what()}});
        }
    });
}

}  // namespace sa
