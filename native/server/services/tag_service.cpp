#include "tag_service.h"

#include <algorithm>

#include "sa_core/strings.h"

namespace sa {
namespace {

// 词元：小写化后按非 [a-z0-9] 切分。非 ASCII 字节（中文键）一律当分隔符，
// 于是中文键只会被切碎而不会与 ASCII 词元误匹配。
bool word_char(unsigned char c) {
    return (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9');
}

std::vector<std::string> tokens_of(const std::string& s) {
    const std::string low = sa_core::str::lower(s);
    std::vector<std::string> out;
    std::string cur;
    for (unsigned char c : low) {
        if (word_char(c)) {
            cur.push_back(static_cast<char>(c));
        } else if (!cur.empty()) {
            out.push_back(cur);
            cur.clear();
        }
    }
    if (!cur.empty()) out.push_back(cur);
    return out;
}

// 词元匹配：完全相等，或 "<word> + 纯数字后缀"。
// 后者覆盖真实数据里的 role2_ec04c6….bundle / icon3_f8d0b4….bundle；
// 因为后缀必须是纯数字，短词元（bg / ui / se）不会误伤 bgm、session 之类。
bool token_matches(const std::string& token, const std::string& word) {
    if (token == word) return true;
    if (token.size() <= word.size()) return false;
    if (token.compare(0, word.size(), word) != 0) return false;
    for (std::size_t i = word.size(); i < token.size(); ++i) {
        if (token[i] < '0' || token[i] > '9') return false;
    }
    return true;
}

// 规则：words 为空表示兜底（必须是该分节的最后一条）。
struct Rule {
    const char* tag;
    std::vector<const char*> words;
};

// 固定顺序 = 优先级。首个命中即停（保留"一个资源一个主类型"的语义）。
const std::vector<Rule>& tex_rules() {
    static const std::vector<Rule> kRules = {
        {"role", {"role", "character", "char", "portrait", "halfbody", "avatar"}},
        {"cg", {"comic", "cg"}},
        {"ui", {"atlas", "icon", "ui", "button"}},
        {"background", {"bg", "background", "scene", "map"}},
        {"texture", {}},  // 兜底
    };
    return kRules;
}

const std::vector<Rule>& aud_rules() {
    static const std::vector<Rule> kRules = {
        {"bgm", {"bgm"}},
        {"se", {}},  // 兜底
    };
    return kRules;
}

const std::vector<Rule>& txt_rules() {
    static const std::vector<Rule> kRules = {
        {"cfg", {}},  // 兜底
    };
    return kRules;
}

const std::vector<Rule>* rules_for(const std::string& section) {
    if (section == "tex") return &tex_rules();
    if (section == "aud") return &aud_rules();
    if (section == "txt") return &txt_rules();
    return nullptr;
}

// 键里最后一个长度 >= 3 的连续数字串。
// **只看 key**：bundle 名里带 32 位内容 hash（1168c761bc507e56b7fb2064d262ee7e），
// 让它参与会产出随机 ID。数字原样保留（不补零），与旧实现的 "%02d" 语义相反。
std::string last_id_run(const std::string& key) {
    std::string best;
    std::size_t i = 0;
    while (i < key.size()) {
        if (key[i] >= '0' && key[i] <= '9') {
            std::size_t j = i;
            while (j < key.size() && key[j] >= '0' && key[j] <= '9') ++j;
            if (j - i >= 3) best = key.substr(i, j - i);
            i = j;
        } else {
            ++i;
        }
    }
    return best;
}

}  // namespace

const std::vector<std::string>& TagService::base_types() {
    static const std::vector<std::string> kTypes = {"role",     "cg",   "ui", "background",
                                                    "texture",  "bgm",  "se", "cfg"};
    return kTypes;
}

std::vector<std::string> TagService::tags_for(const std::string& section,
                                              const std::string& key,
                                              const std::string& location) const {
    std::vector<std::string> tags;
    const std::vector<Rule>* rules = rules_for(section);
    if (rules == nullptr) return tags;

    // bundle 路径参与匹配（目录名 atlas/role 是真信号），键兜底。
    const std::vector<std::string> tokens = tokens_of(location + " " + key);

    std::string base;
    for (const Rule& rule : *rules) {
        if (rule.words.empty()) {  // 兜底
            base = rule.tag;
            break;
        }
        bool hit = false;
        for (const std::string& token : tokens) {
            for (const char* word : rule.words) {
                if (token_matches(token, word)) {
                    hit = true;
                    break;
                }
            }
            if (hit) break;
        }
        if (hit) {
            base = rule.tag;
            break;
        }
    }
    if (base.empty()) return tags;

    tags.push_back(base);
    const std::string id = last_id_run(key);
    if (!id.empty()) tags.push_back(base + "-" + id);
    return tags;
}

}  // namespace sa
