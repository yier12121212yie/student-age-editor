// wip/P3a/story_service.cpp —— port of server/story_service.py。
//
// Python re 的 \d/\s/$ 是 Unicode 语义、效果行含 (?<!屏幕) 后顾与 lookahead，
// std::regex 不支持——全部按码点手写匹配器（story_service.h 注释）。
#include "story_service.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <deque>
#include <initializer_list>
#include <set>
#include <string>
#include <vector>

#include "sa_core/json_wire.h"
#include "sa_core/util.h"
#include "server/httpd.h"

namespace sa {
namespace story {
namespace {

using content::json;

std::string replace_all_str(std::string s, const std::string& from, const std::string& to) {
    if (from.empty()) return s;
    size_t pos = 0;
    while ((pos = s.find(from, pos)) != std::string::npos) {
        s.replace(pos, from.size(), to);
        pos += to.size();
    }
    return s;
}

std::vector<std::string> split_char(const std::string& s, char delim) {
    std::vector<std::string> out;
    size_t start = 0;
    while (true) {
        size_t p = s.find(delim, start);
        if (p == std::string::npos) {
            out.push_back(s.substr(start));
            break;
        }
        out.push_back(s.substr(start, p - start));
        start = p + 1;
    }
    return out;
}

// re.split(r"[;；、]", s)：按码点分隔符切，保留空段。
std::vector<std::string> split_charset(const std::string& s, const std::string& seps) {
    struct UtfLite {
        std::vector<uint32_t> cp;
        std::vector<size_t> boff;
    };
    UtfLite u;
    const size_t n = s.size();
    size_t b = 0;
    while (b < n) {
        u.boff.push_back(b);
        unsigned char c = static_cast<unsigned char>(s[b]);
        uint32_t cp = 0xFFFD;
        size_t w = 1;
        if (c < 0x80) cp = c;
        else if ((c & 0xE0) == 0xC0 && b + 1 < n) { cp = ((c & 0x1Fu) << 6) | (static_cast<unsigned char>(s[b + 1]) & 0x3Fu); w = 2; }
        else if ((c & 0xF0) == 0xE0 && b + 2 < n) { cp = ((c & 0x0Fu) << 12) | ((static_cast<unsigned char>(s[b + 1]) & 0x3Fu) << 6) | (static_cast<unsigned char>(s[b + 2]) & 0x3Fu); w = 3; }
        else if ((c & 0xF8) == 0xF0 && b + 3 < n) { cp = ((c & 0x07u) << 18) | ((static_cast<unsigned char>(s[b + 1]) & 0x3Fu) << 12) | ((static_cast<unsigned char>(s[b + 2]) & 0x3Fu) << 6) | (static_cast<unsigned char>(s[b + 3]) & 0x3Fu); w = 4; }
        u.cp.push_back(cp);
        b += w;
    }
    u.boff.push_back(n);
    auto sepc = content::to_codepoints(seps);
    std::vector<std::string> out;
    size_t start = 0;
    for (size_t p = 0; p < u.cp.size(); ++p) {
        if (std::find(sepc.begin(), sepc.end(), u.cp[p]) != sepc.end()) {
            out.push_back(s.substr(u.boff[start], u.boff[p] - u.boff[start]));
            start = p + 1;
        }
    }
    out.push_back(s.substr(u.boff[start]));
    return out;
}

uint32_t ascii_lower_cp(uint32_t c) { return c >= 'A' && c <= 'Z' ? c + 32 : c; }
bool cp_eq_ci(uint32_t a, uint32_t b) {
    if (a == b) return true;
    bool ua = a >= 'A' && a <= 'Z';
    bool ub = b >= 'A' && b <= 'Z';
    bool la = a >= 'a' && a <= 'z';
    bool lb = b >= 'a' && b <= 'z';
    if (ua && lb) return a + 32 == b;
    if (ub && la) return b + 32 == a;
    return false;
}

size_t match_kw(const std::vector<uint32_t>& cps, size_t i, const std::vector<uint32_t>& kw,
                bool ci) {
    if (i + kw.size() > cps.size()) return std::string::npos;
    for (size_t k = 0; k < kw.size(); ++k) {
        bool ok = ci ? cp_eq_ci(cps[i + k], kw[k]) : cps[i + k] == kw[k];
        if (!ok) return std::string::npos;
    }
    return i + kw.size();
}

bool contains_str(const std::string& hay, const char* needle) {
    return hay.find(needle) != std::string::npos;
}

// int 相等语义（bool==int、整值 float==int）
std::optional<long long> int_like(const json& v) {
    if (v.is_boolean()) return v.get<bool>() ? 1LL : 0LL;
    if (v.is_number_integer() || v.is_number_unsigned()) return content::as_ll(v);
    if (v.is_number_float()) {
        double d = v.get<double>();
        if (std::isfinite(d) && d == std::floor(d)) return static_cast<long long>(d);
        return std::nullopt;
    }
    return std::nullopt;
}
bool eq_int(const json& v, long long k) {
    auto x = int_like(v);
    return x && *x == k;
}

// Python int(v) 的**值转换**（float 截断）；失败 nullopt（区分抛错交调用方）。
std::optional<long long> py_int_value(const json& v) {
    if (v.is_boolean()) return v.get<bool>() ? 1LL : 0LL;
    if (v.is_number_integer() || v.is_number_unsigned()) return content::as_ll(v);
    if (v.is_number_float()) {
        double d = v.get<double>();
        if (std::isfinite(d)) return static_cast<long long>(d);
        return std::nullopt;  // inf/nan -> OverflowError，调用方处理
    }
    if (v.is_string())
        return content::int_digits_str(content::py_strip(v.get_ref<const std::string&>()));
    return std::nullopt;
}
[[noreturn]] void throw_int_fail(const json& v) {
    if (v.is_number_float()) {
        double d = v.get<double>();
        if (!std::isfinite(d))
            throw sa::ApiError("OverflowError",
                               "cannot convert float infinity to integer");
    }
    if (v.is_string())
        throw sa::ApiError("ValueError",
                           content::value_error_int_repr_quoted(v.get<std::string>()));
    throw sa::ApiError("TypeError",
                       "int() argument must be a string, a bytes-like object or a "
                       "real number, not '" +
                           std::string(content::py_type_name(v)) + "'");
}

// 非容器值 str()、容器 Python repr 风格：统一走 content::story_str。
// 「可迭代」展开（list -> 元素；dict -> 键；str -> 码点；否则 TypeError）。
std::vector<json> py_iterate(const json& v) {
    std::vector<json> out;
    if (v.is_array()) {
        for (const auto& x : v) out.push_back(x);
    } else if (v.is_object()) {
        for (auto it = v.begin(); it != v.end(); ++it) out.push_back(json(it.key()));
    } else if (v.is_string()) {
        for (uint32_t cp : content::to_codepoints(v.get_ref<const std::string&>()))
            out.push_back(json(content::cp_to_utf8(cp)));
    } else {
        throw sa::ApiError("TypeError", std::string("'") + content::py_type_name(v) +
                                            "' object is not iterable");
    }
    return out;
}

std::string join_str(const std::vector<std::string>& xs, const std::string& sep) {
    std::string out;
    for (size_t i = 0; i < xs.size(); ++i) {
        if (i) out += sep;
        out += xs[i];
    }
    return out;
}

// ---------------------------------------------------------------------------
// 常量词表
// ---------------------------------------------------------------------------

struct SmartExpr {
    const char* kw;
    long long eid;
};
// build_smart_expression_map 的扁平插入序（eid 升序 × 词表序）。
const SmartExpr kSmartExprs[] = {
    {"默认", 0}, {"平静", 0}, {"正常", 0}, {"淡定", 0}, {"发呆", 0}, {"面无表情", 0}, {"恢复", 0},
    {"开心", 1}, {"高兴", 1}, {"快乐", 1}, {"喜悦", 1}, {"兴奋", 1}, {"乐", 1}, {"嘻嘻", 1},
    {"哈哈", 1}, {"愉悦", 1}, {"欣喜", 1}, {"雀跃", 1}, {"笑逐颜开", 1}, {"捧腹", 1},
    {"乐呵呵", 1}, {"好耶", 1},
    {"生气", 2}, {"愤怒", 2}, {"恼火", 2}, {"怒", 2}, {"暴怒", 2}, {"气愤", 2}, {"愤慨", 2},
    {"不爽", 2}, {"恼怒", 2}, {"发火", 2}, {"怒视", 2}, {"气呼呼", 2}, {"咬牙", 2},
    {"伤心", 3}, {"哭", 3}, {"哭泣", 3}, {"落泪", 3}, {"悲伤", 3}, {"呜呜", 3}, {"啜泣", 3},
    {"悲痛", 3}, {"哀伤", 3}, {"泪流满面", 3}, {"痛哭", 3}, {"抽泣", 3}, {"泪崩", 3},
    {"害羞", 4}, {"脸红", 4}, {"羞涩", 4}, {"不好意思", 4}, {"腼腆", 4}, {"羞答答", 4},
    {"扭捏", 4},
    {"喜欢", 5}, {"爱慕", 5}, {"花痴", 5}, {"心动", 5}, {"眼冒爱心", 5}, {"陶醉", 5},
    {"认真", 6}, {"严肃", 6}, {"凝重", 6}, {"神色凝重", 6}, {"郑重", 6}, {"沉重", 6},
    {"专注", 6}, {"仔细", 6}, {"一丝不苟", 6}, {"正经", 6},
    {"疑惑", 7}, {"疑问", 7}, {"不解", 7}, {"纳闷", 7}, {"奇怪", 7}, {"呃", 7}, {"问号", 7},
    {"困惑", 7}, {"迷糊", 7}, {"不懂", 7},
    {"惊讶", 8}, {"震惊", 8}, {"惊吓", 8}, {"吓", 8}, {"呆住", 8}, {"愣住", 8}, {"错愕", 8},
    {"难以置信", 8}, {"目瞪口呆", 8}, {"惊愕", 8}, {"意外", 8}, {"吃惊", 8},
    {"得意", 9}, {"骄傲", 9}, {"炫耀", 9}, {"哼", 9}, {"傲娇", 9}, {"翘尾巴", 9},
    {"洋洋得意", 9}, {"自豪", 9}, {"显摆", 9},
    {"微笑", 10}, {"莞尔", 10}, {"浅笑", 10}, {"嘴角上扬", 10}, {"含笑", 10}, {"笑意", 10},
    {"轻笑", 10}, {"笑吟吟", 10},
    {"坏笑", 11}, {"阴险", 11}, {"狡黠", 11}, {"嘿嘿", 11}, {"邪笑", 11}, {"阴笑", 11},
    {"不怀好意", 11},
    {"担心", 12}, {"担忧", 12}, {"忧虑", 12}, {"牵挂", 12}, {"紧张", 12}, {"不安", 12},
    {"悬着心", 12},
    {"害怕", 13}, {"恐惧", 13}, {"发抖", 13}, {"哆嗦", 13}, {"惊恐", 13}, {"畏惧", 13},
    {"胆怯", 13}, {"瑟瑟发抖", 13}, {"惊慌", 13},
    {"难过", 14}, {"失落", 14}, {"沮丧", 14}, {"郁闷", 14}, {"消沉", 14}, {"灰心", 14},
    {"低落", 14}, {"惆怅", 14},
    {"咆哮", 15}, {"大吼", 15}, {"怒吼", 15}, {"吼叫", 15}, {"歇斯底里", 15}, {"大叫", 15},
    {"窘迫", 16}, {"局促", 16}, {"不自在", 16},
    {"不满", 17}, {"抱怨", 17}, {"牢骚", 17}, {"抗议", 17}, {"撇嘴", 17}, {"啧", 17},
    {"冷笑", 18}, {"嗤之以鼻", 18}, {"不屑", 18}, {"嘲讽", 18}, {"讥讽", 18}, {"呵呵", 18},
    {"无语", 19}, {"汗", 19}, {"汗颜", 19}, {"黑线", 19}, {"...", 19}, {"……", 19}, {"沉默", 19},
    {"苦笑", 20}, {"无奈", 20}, {"勉强笑", 20},
    {"挫败", 21}, {"灰头土脸", 21}, {"打击", 21},
    {"尴尬", 22}, {"尬住", 22}, {"僵硬", 22},
    {"迷茫", 23}, {"呆滞", 23}, {"空洞", 23}, {"懵", 23}, {"懵逼", 23}, {"发愣", 23},
    {"嫌弃", 24}, {"鄙视", 24}, {"恶心", 24}, {"厌恶", 24}, {"皱眉", 24}, {"白眼", 24},
    {"俏皮", 25}, {"吐舌", 25}, {"鬼脸", 25}, {"调皮", 25}, {"眨眼", 25}, {"wink", 25},
};

const char* kExpressionNames[27] = {
    "默认", "开心", "生气", "伤心", "害羞", "喜欢", "认真", "疑惑", "惊讶", "得意", "微笑",
    "坏笑", "担心", "害怕", "难过", "咆哮", "窘迫", "不满", "冷笑", "无语", "苦笑", "挫败",
    "尴尬", "迷茫", "嫌弃", "俏皮", "尴尬"};

std::string expression_name(const std::string& id) {
    for (int i = 0; i <= 26; ++i)
        if (std::to_string(i) == id) return kExpressionNames[i];
    return id;
}

struct IdName {
    long long id;
    const char* name;
};
const IdName kEventTypes[] = {
    {0, "回合开始触发"}, {1, "独立按钮(不弹窗)"}, {2, "社交事件"}, {3, "回合结束触发"},
    {4, "行动触发"}, {10, "强制触发(不弹窗)"}, {11, "约会事件"}, {12, "篮球主线-自动"},
    {13, "篮球主线-被动"}, {14, "羽毛球主线-自动"}, {15, "羽毛球主线-被动"}, {20, "关系任务"},
    {21, "打招呼"}, {22, "话题"}, {30, "点击场景物品"}, {36, "漫展"}, {37, "生日派对"},
    {40, "考试"}, {41, "查看成绩"}, {50, "通知"}, {51, "流程"}, {60, "状态"}, {61, "路人"},
    {62, "点击物品"}, {63, "路人检查"}, {70, "玩家打电话"}, {71, "玩家接电话"}, {80, "新闻"},
    {90, "节日"}, {101, "独立按钮(强制)"}, {102, "精力低事件"}, {104, "捣蛋事件"},
    {110, "送礼"}, {200, "人生轨迹"}, {500, "高考"}, {520, "表白事件"}, {521, "情侣电影"},
    {522, "恋爱社交"}, {523, "生日礼物"}, {750, "学习"}, {801, "回家触发"},
    {802, "教学楼触发"}, {803, "操场触发"}, {804, "小卖部触发"}, {805, "游戏厅触发"},
    {806, "书店触发"}, {807, "商场触发"}, {808, "电影院触发"}, {811, "游乐园触发"},
    {817, "双子峰触发"}, {901, "回家触发"}, {902, "教学楼触发"}, {903, "操场触发"},
    {904, "小卖部触发"}, {905, "游戏厅触发"}, {906, "书店触发"}, {907, "商场触发"},
    {908, "电影院触发"}, {911, "游乐园触发"}, {917, "双子峰触发"},
};
const IdName kRelationLevels[] = {{1, "熟人"}, {2, "朋友"}, {3, "好友"},
                                  {4, "密友"}, {5, "挚友"}, {6, "至交"}, {520, "恋人"}};

std::string event_type_name(const json& t_id) {
    std::string fallback = "类型" + content::story_str(t_id);
    auto tl = int_like(t_id);
    if (!tl) return fallback;
    for (const auto& e : kEventTypes)
        if (e.id == *tl) return e.name;
    return fallback;
}
std::string relation_name(const json& lvl) {
    auto l = int_like(lvl);
    if (l) {
        for (const auto& r : kRelationLevels)
            if (r.id == *l) return r.name;
    }
    return "关系" + content::story_str(lvl);
}

// ---------------------------------------------------------------------------
// CPython set<int> 迭代序仿真（ScriptParser.run 的 pending_resets）
// ---------------------------------------------------------------------------
class PyIntSet {
  public:
    void insert(long long v) {
        if (fill() * 5 >= mask_ * 3) grow();
        do_insert(v);
    }
    std::vector<long long> in_slot_order() const {
        std::vector<long long> out;
        for (const auto& sl : slots_)
            if (sl.used) out.push_back(sl.val);
        return out;
    }

  private:
    struct Slot {
        bool used = false;
        long long val = 0;
    };
    static size_t hash_of(long long v) {
        return static_cast<size_t>(v < 0 ? ~static_cast<unsigned long long>(v)
                                         : static_cast<unsigned long long>(v));
    }
    size_t fill() const {
        size_t f = 0;
        for (const auto& s : slots_) f += s.used;
        return f;
    }
    void do_insert(long long v) {
        size_t i = hash_of(v) & mask_;
        size_t perturb = hash_of(v);
        while (slots_[i].used) {
            if (slots_[i].val == v) return;
            perturb >>= 5;
            i = (5 * i + perturb + 1) & mask_;
        }
        slots_[i] = {true, v};
    }
    void grow() {
        size_t want = fill() * 4 + 1;
        size_t n = 8;
        while (n < want) n <<= 1;
        std::vector<Slot> old = std::move(slots_);
        slots_.assign(n, Slot{});
        mask_ = n - 1;
        for (const auto& s : old)
            if (s.used) do_insert(s.val);
    }
    std::vector<Slot> slots_{std::vector<Slot>(8)};
    size_t mask_ = 7;
};

// pending_resets：int 走 CPython 槽位序；非 int（name_to_id 的 str 兜底值）
// 走插入序附加在后——Python 侧 str hash 随机化本就跨进程不定，见交付报告偏差。
class PendingResets {
  public:
    void insert(const json& v) {
        auto l = content::as_ll(v);
        if (v.is_boolean() || v.is_number_integer() || v.is_number_unsigned()) {
            ints_.insert(l.value_or(0));
        } else {
            extras_.push_back(v);
        }
    }
    std::vector<json> ordered() const {
        std::vector<json> out;
        for (auto i : ints_.in_slot_order()) out.push_back(json(i));
        for (const auto& e : extras_) out.push_back(e);
        return out;
    }

  private:
    PyIntSet ints_;
    std::vector<json> extras_;
};

// ---------------------------------------------------------------------------
// ScriptParser
// ---------------------------------------------------------------------------

struct Utf {
    std::string s;
    std::vector<uint32_t> cp;
    std::vector<size_t> boff;  // cp.size()+1

    explicit Utf(std::string str) : s(std::move(str)) {
        size_t b = 0;
        const size_t n = s.size();
        while (b < n) {
            boff.push_back(b);
            unsigned char c = static_cast<unsigned char>(s[b]);
            uint32_t v = 0xFFFD;
            size_t w = 1;
            if (c < 0x80) {
                v = c;
            } else if ((c & 0xE0) == 0xC0 && b + 1 < n) {
                v = ((c & 0x1Fu) << 6) | (static_cast<unsigned char>(s[b + 1]) & 0x3Fu);
                w = 2;
            } else if ((c & 0xF0) == 0xE0 && b + 2 < n) {
                v = ((c & 0x0Fu) << 12) | ((static_cast<unsigned char>(s[b + 1]) & 0x3Fu) << 6) |
                    (static_cast<unsigned char>(s[b + 2]) & 0x3Fu);
                w = 3;
            } else if ((c & 0xF8) == 0xF0 && b + 3 < n) {
                v = ((c & 0x07u) << 18) | ((static_cast<unsigned char>(s[b + 1]) & 0x3Fu) << 12) |
                    ((static_cast<unsigned char>(s[b + 2]) & 0x3Fu) << 6) |
                    (static_cast<unsigned char>(s[b + 3]) & 0x3Fu);
                w = 4;
            }
            cp.push_back(v);
            b += w;
        }
        boff.push_back(n);
    }
    size_t len() const { return cp.size(); }
    std::string slice(size_t from, size_t to) const {
        if (from > to) from = to;
        return s.substr(boff[from], boff[to] - boff[from]);
    }
};

class Parser {
  public:
    Parser(long long base_id, const json& name_to_id)
        : base_id_(base_id), current_idx_(1), name_to_id_(name_to_id) {
        for (auto it = name_to_id.begin(); it != name_to_id.end(); ++it)
            names_.push_back({it.key(), content::to_codepoints(it.key())});
        // sorted(names, key=len, reverse=True)：稳定排序、码点长度降序。
        std::stable_sort(names_.begin(), names_.end(),
                         [](const NameRef& a, const NameRef& b) {
                             return a.cp.size() > b.cp.size();
                         });
    }

    json run(const std::string& full_text) {
        Utf u(full_text);
        std::vector<M> ms;
        size_t scan = 0;
        while (scan <= u.len()) {
            bool found = false;
            for (size_t p = scan; p <= u.len(); ++p) {
                bool line_start = (p == 0 || u.cp[p - 1] == '\n');
                bool nl = (p < u.len() && u.cp[p] == '\n');
                if (!line_start && !nl) continue;
                M m;
                if (line_start && try_name(u, p, 0, &m)) {
                    ms.push_back(m);
                    scan = m.end;
                    found = true;
                    break;
                }
                if (nl && try_name(u, p, 1, &m)) {
                    ms.push_back(m);
                    scan = m.end;
                    found = true;
                    break;
                }
            }
            if (!found) break;
        }

        std::vector<json> processed;
        if (ms.empty()) {
            if (!content::py_strip(full_text).empty()) {
                if (auto d = process_block("旁白", full_text)) processed.push_back(std::move(*d));
            }
        } else {
            if (ms[0].start > 0) {
                std::string pre = u.slice(0, ms[0].start);
                if (!content::py_strip(pre).empty()) {
                    if (auto d = process_block("旁白", pre)) processed.push_back(std::move(*d));
                }
            }
            for (size_t i = 0; i < ms.size(); ++i) {
                size_t cs = ms[i].end;
                size_t ce = i + 1 < ms.size() ? ms[i + 1].start : u.len();
                if (auto d = process_block(ms[i].name, u.slice(cs, ce)))
                    processed.push_back(std::move(*d));
            }
        }

        std::vector<json> final_list;
        PendingResets pending;
        for (auto& item : processed) {
            std::set<long long> users;
            for (const auto& action : item["roles"]) {
                if (action.is_array() && action.size() >= 2 && eq_int(action[1], 3000)) {
                    auto uid = content::as_ll(action[0]);
                    if (uid) users.insert(*uid);
                }
            }
            for (const json& uid : pending.ordered()) {
                bool known = false;
                auto ul = content::as_ll(uid);
                if (ul && users.count(*ul)) known = true;
                if (!known && !eq_int(uid, -1)) {
                    json reset = json::array();
                    reset.push_back(uid);
                    reset.push_back(3000);
                    reset.push_back(0);
                    item["roles"].insert(item["roles"].begin(), std::move(reset));
                }
            }
            pending = PendingResets{};
            for (const auto& action : item["roles"]) {
                if (action.is_array() && action.size() >= 3 && eq_int(action[1], 3000) &&
                    !eq_int(action[2], 0) && !eq_int(action[0], -1))
                    pending.insert(action[0]);
            }
            json expr_dict = json::object();
            json other = json::array();
            for (const auto& act : item["roles"]) {
                if (!act.is_array() || act.size() < 2) continue;
                std::string uid_key = content::story_str(act[0]);
                if (act.size() >= 2 && eq_int(act[1], 3000)) {
                    expr_dict[uid_key] = act;
                } else {
                    bool dup = false;
                    for (const auto& o : other)
                        if (o == act) {
                            dup = true;
                            break;
                        }
                    if (!dup) other.push_back(act);
                }
            }
            json merged = json::array();
            for (auto it = expr_dict.begin(); it != expr_dict.end(); ++it) merged.push_back(it.value());
            for (const auto& o : other) merged.push_back(o);
            item["roles"] = std::move(merged);
            final_list.push_back(std::move(item));
        }
        if (!final_list.empty()) final_list.back()["nextTalk"] = json::array();

        json out = json::object();
        for (auto& item : final_list) {
            // 先取键再 move：`out[story_str(item["id"])] = std::move(item)` 在
            // MSVC 下会从已 move 的对象算键（实测得 "None"）。
            std::string key = content::story_str(item["id"]);
            out[key] = std::move(item);
        }
        return out;
    }

  private:
    struct NameRef {
        std::string name;
        std::vector<uint32_t> cp;
    };
    struct M {
        size_t start;  // 全匹配起点（含 (^|\n) 消耗）
        size_t end;    // 全匹配终点（lookahead 零宽）
        std::string name;
    };

    bool try_name(const Utf& u, size_t p, size_t skip, M* out) {
        size_t q = p + skip;
        size_t w = q;
        while (w < u.len() && content::is_space_cp(u.cp[w])) ++w;
        for (size_t t = w;; --t) {
            for (const auto& n : names_) {
                if (t + n.cp.size() <= u.len() &&
                    std::equal(n.cp.begin(), n.cp.end(), u.cp.begin() + t)) {
                    size_t r = t + n.cp.size();
                    if (lookahead_ok(u, r)) {
                        out->start = p;
                        out->end = r;
                        out->name = n.name;
                        return true;
                    }
                }
            }
            if (t == q) return false;
        }
    }
    static bool lookahead_ok(const Utf& u, size_t r) {
        if (r >= u.len()) return true;
        uint32_t c = u.cp[r];
        if (content::is_space_cp(c)) return true;
        return c == ':' || c == 0xFF1A || c == '(' || c == ')' || c == 0xFF08 || c == 0xFF09 ||
               c == '[' || c == ']';
    }

    std::optional<json> process_block(const std::string& speaker_name,
                                      const std::string& raw_content) {
        if (content::py_strip(raw_content).empty()) return std::nullopt;

        json speaker_id = json(-1);
        {
            auto it = name_to_id_.find(speaker_name);
            if (!speaker_name.empty() && it != name_to_id_.end()) speaker_id = it.value();
        }

        size_t lb = 0;
        while (lb < raw_content.size() && (raw_content[lb] == ' ' || raw_content[lb] == '\t'))
            ++lb;
        std::string lstripped = raw_content.substr(lb);

        std::string custom_role_name;
        std::string raw_text;
        size_t rn_end = 0;
        if (role_paren_prefix(lstripped, &rn_end, &custom_role_name)) {
            raw_text = content::py_strip(lstripped.substr(rn_end));
        } else {
            raw_text = content::py_strip(raw_content);
        }
        if (!raw_text.empty()) {
            auto cps = content::to_codepoints(raw_text);
            uint32_t first = cps[0];
            if (first == ':' || first == 0xFF1A) {
                std::string head = content::cp_to_utf8(first);
                raw_text = content::py_strip(raw_text.substr(head.size()));
            }
        }

        json d = json::object();
        d["id"] = base_id_ + current_idx_;
        d["roleIds"] = json::array();
        if (!eq_int(speaker_id, -1)) d["roleIds"].push_back(speaker_id);
        d["content"] = "";
        d["bg"] = 0;
        d["audio"] = 0;
        d["roles"] = json::array();
        d["effect"] = json::array();
        d["miniGame"] = json::array();
        d["screenEffect"] = json::array();
        d["check"] = json::array();
        d["nextTalk"] = json::array();
        d["nextTalk2"] = json::array();
        d["option"] = json::array();
        d["replace"] = json::array();
        d["showTxt"] = nullptr;
        d["time"] = 0;
        d["vocals"] = json::array();
        d["roleName"] = nullptr;
        d["effect2"] = json::array();
        d["highlights"] = json::array();

        if (!custom_role_name.empty()) {
            d["roleName"] = custom_role_name;
        } else if (eq_int(speaker_id, -1) && speaker_name != "旁白") {
            d["roleName"] = speaker_name;
        }

        // ---- 触发效果 / effect / (?<!屏幕)效果 ----
        if (auto m = search_effect(raw_text)) {
            std::string val_str = content::py_strip(m->group1);
            // json.loads 严格：strict=true 等价「全串必须为单值」；NaN/Infinity
            // 字面量差异见交付报告（Python 接受、nlohmann 拒 -> 走 fallback 分支）。
            json parsed = json::parse(val_str, nullptr, false, true);
            if (parsed.is_discarded()) {
                std::string vs = replace_all_str(val_str, "[", "");
                vs = replace_all_str(vs, "]", "");
                for (const auto& eg : split_charset(vs, ";；")) {
                    if (content::py_strip(eg).empty()) continue;
                    json nums = json::array();
                    for (const auto& n : content::findall_digits(eg, false))
                        nums.push_back(*content::int_digits_str(n));
                    if (!nums.empty()) d["effect"].push_back(std::move(nums));
                }
            } else if (parsed.is_array()) {
                bool all_list = true;
                for (const auto& x : parsed)
                    if (!x.is_array()) {
                        all_list = false;
                        break;
                    }
                if (all_list) {
                    for (const auto& x : parsed) d["effect"].push_back(x);
                } else {
                    d["effect"].push_back(parsed);
                }
            }
            raw_text = replace_all_str(raw_text, content::py_strip(m->whole), "");
        }

        if (auto m = search_bg_like(raw_text, {"bg", "背景"})) {
            d["bg"] = *content::int_digits_str(m->group1);
            raw_text = replace_all_str(raw_text, m->whole, "");
        }
        if (auto m = search_bg_like(raw_text, {"bgm", "music", "音乐"})) {
            d["audio"] = *content::int_digits_str(m->group1);
            raw_text = replace_all_str(raw_text, m->whole, "");
        }

        std::string full_act_text;
        for (const auto& m : finditer_actions(raw_text)) {
            full_act_text += m.group1 + ";";
            raw_text = replace_all_str(raw_text, m.whole, "");
        }
        for (const auto& b : findall_brackets(raw_text)) {
            if (contains_str(b, "系统") || contains_str(b, "前提判定") || contains_str(b, "条件"))
                continue;
            bool valid_found = false;
            for (const auto& sub : split_charset(b, ";；、")) {
                auto pa = parse_natural_action(sub, speaker_id);
                if (pa && !pa->empty()) {
                    full_act_text += sub + ";";
                    valid_found = true;
                }
            }
            if (valid_found) {
                raw_text = replace_all_str(raw_text, "[" + b + "]", "");
                raw_text = replace_all_str(raw_text, "(" + b + ")", "");
                raw_text = replace_all_str(raw_text, "（" + b + "）", "");
            }
        }
        if (!full_act_text.empty()) {
            for (const auto& act : split_charset(full_act_text, ";；、")) {
                auto code = parse_natural_action(act, speaker_id);
                if (!code || code->empty()) continue;
                long long code_id = content::as_ll(code->front()).value_or(-999999);
                if (code_id >= 4000 && code_id < 5000) {
                    d["screenEffect"] = *code;
                } else if (code_id == 0 && code->size() >= 2 && eq_int((*code)[1], 5001)) {
                    d["roles"].push_back(*code);
                } else if (code_id != -1) {
                    d["roles"].push_back(*code);
                }
            }
        }

        {
            Utf t(raw_text);
            size_t b = 0;
            while (b < t.len() &&
                   (t.cp[b] == ':' || t.cp[b] == 0xFF1A || content::is_space_cp(t.cp[b])))
                ++b;
            std::string clean = strip_bgm_all(t.slice(b, t.len()));
            d["content"] = content::py_strip(clean);
        }
        d["nextTalk"] = json::array();
        d["nextTalk"].push_back(base_id_ + current_idx_ + 1);
        ++current_idx_;
        return d;
    }

    static bool role_paren_prefix(const std::string& s, size_t* end, std::string* inner) {
        Utf u(s);
        if (u.len() == 0) return false;
        if (u.cp[0] != '(' && u.cp[0] != 0xFF08) return false;
        size_t i = 1;
        while (i < u.len() && u.cp[i] != ')' && u.cp[i] != 0xFF09 && u.cp[i] != '\n') ++i;
        if (i <= 1 || i >= u.len()) return false;
        if (u.cp[i] != ')' && u.cp[i] != 0xFF09) return false;
        *inner = content::py_strip(u.slice(1, i));
        *end = u.boff[i + 1];
        return true;
    }

    struct SimpleMatch {
        std::string whole;
        std::string group1;
    };

    // (?:触发效果|effect|(?<!屏幕)效果)[:：\s]*(\[.*?\]|[\d,，;；\s]+)(?:[。.\n]|$)
    static std::optional<SimpleMatch> search_effect(const std::string& text) {
        Utf u(text);
        static const auto g_trigger = content::to_codepoints("触发效果");
        static const auto g_effect = content::to_codepoints("effect");
        static const auto g_xiaoguo = content::to_codepoints("效果");
        static const auto g_pingmu = content::to_codepoints("屏幕");
        auto tail_ok = [&u](size_t r) {
            if (r < u.len())
                return u.cp[r] == 0x3002 || u.cp[r] == '.' || u.cp[r] == '\n';
            return r == u.len() || (r + 1 == u.len() && u.cp[r] == '\n');
        };
        for (size_t p = 0; p < u.len(); ++p) {
            std::optional<size_t> after;
            size_t e = match_kw(u.cp, p, g_trigger, false);
            if (e == std::string::npos) e = match_kw(u.cp, p, g_effect, true);
            if (e == std::string::npos) {
                e = match_kw(u.cp, p, g_xiaoguo, false);
                if (e != std::string::npos) {
                    if (p >= g_pingmu.size() &&
                        std::equal(g_pingmu.begin(), g_pingmu.end(),
                                   u.cp.begin() + (p - g_pingmu.size())))
                        continue;  // (?<!屏幕)
                }
            }
            if (e == std::string::npos) continue;
            after = e;
            size_t mx = *after;
            while (mx < u.len() && (u.cp[mx] == ':' || u.cp[mx] == 0xFF1A ||
                                    content::is_space_cp(u.cp[mx])))
                ++mx;
            for (size_t sep = mx;; --sep) {
                if (sep < u.len() && u.cp[sep] == '[') {
                    // \[.*?\]：惰性——逐个 ']' 尝试（不跨 \n）
                    for (size_t j = sep + 1; j < u.len() && u.cp[j] != '\n'; ++j) {
                        if (u.cp[j] != ']') continue;
                        if (tail_ok(j + 1)) {
                            SimpleMatch m;
                            m.whole = u.slice(p, j + 1);
                            m.group1 = u.slice(sep, j + 1);
                            return m;
                        }
                    }
                } else {
                    // [\d,，;；\s]+ 贪婪回溯
                    size_t j = sep;
                    auto in_class = [](uint32_t c) {
                        return content::is_digit_cp(c) || c == ',' || c == 0xFF0C || c == ';' ||
                               c == 0xFF1B || content::is_space_cp(c);
                    };
                    while (j < u.len() && in_class(u.cp[j])) ++j;
                    for (size_t end = j; end > sep; --end) {
                        if (tail_ok(end)) {
                            SimpleMatch m;
                            m.whole = u.slice(p, end);
                            m.group1 = u.slice(sep, end);
                            return m;
                        }
                    }
                }
                if (sep == *after) break;
            }
        }
        return std::nullopt;
    }

    // (?:bg|背景)[:：\s]*(\d+)（ASCII 大小写不敏感）
    static std::optional<SimpleMatch> search_bg_like(const std::string& text,
                                                     const std::vector<std::string>& kws) {
        Utf u(text);
        std::vector<std::vector<uint32_t>> kcp;
        for (const auto& k : kws) kcp.push_back(content::to_codepoints(k));
        for (size_t p = 0; p < u.len(); ++p) {
            std::optional<size_t> e;
            for (const auto& k : kcp) {
                size_t x = match_kw(u.cp, p, k, true);
                if (x != std::string::npos) {
                    e = x;
                    break;
                }
            }
            if (!e) continue;
            size_t mx = *e;
            while (mx < u.len() && (u.cp[mx] == ':' || u.cp[mx] == 0xFF1A ||
                                    content::is_space_cp(u.cp[mx])))
                ++mx;
            size_t ds = mx;
            while (mx < u.len() && content::is_digit_cp(u.cp[mx])) ++mx;
            if (mx > ds) {
                SimpleMatch m;
                m.whole = u.slice(p, mx);
                m.group1 = u.slice(ds, mx);
                return m;
            }
        }
        return std::nullopt;
    }

    // finditer: (?:动作|action|roles|屏幕效果|screenEffect)[:：\s]+(.*?)(?=\n|$)
    static std::vector<SimpleMatch> finditer_actions(const std::string& text) {
        std::vector<SimpleMatch> out;
        Utf u(text);
        const std::vector<std::vector<uint32_t>> kcp = {
            content::to_codepoints("动作"), content::to_codepoints("action"),
            content::to_codepoints("roles"), content::to_codepoints("屏幕效果"),
            content::to_codepoints("screenEffect"),
        };
        size_t scan = 0;
        while (scan < u.len()) {
            bool found = false;
            for (size_t p = scan; p < u.len(); ++p) {
                std::optional<size_t> e;
                for (const auto& k : kcp) {
                    size_t x = match_kw(u.cp, p, k, true);
                    if (x != std::string::npos) {
                        e = x;
                        break;
                    }
                }
                if (!e) continue;
                size_t sep = *e;
                while (sep < u.len() && (u.cp[sep] == ':' || u.cp[sep] == 0xFF1A ||
                                         content::is_space_cp(u.cp[sep])))
                    ++sep;
                if (sep == *e) continue;  // [:：\s]+ 至少一个
                size_t g = sep;
                while (g < u.len() && u.cp[g] != '\n') ++g;
                SimpleMatch m;
                m.whole = u.slice(p, g);
                m.group1 = u.slice(sep, g);
                out.push_back(std::move(m));
                scan = g;
                found = true;
                break;
            }
            if (!found) break;
        }
        return out;
    }

    // findall: [（\(\[](.*?)[）\)\]]
    static std::vector<std::string> findall_brackets(const std::string& text) {
        std::vector<std::string> out;
        Utf u(text);
        auto is_open = [](uint32_t c) { return c == '(' || c == 0xFF08 || c == '['; };
        auto is_close = [](uint32_t c) { return c == ')' || c == 0xFF09 || c == ']'; };
        size_t scan = 0;
        while (scan < u.len()) {
            size_t i = scan;
            for (; i < u.len(); ++i)
                if (is_open(u.cp[i])) break;
            if (i >= u.len()) break;
            size_t j = i + 1;
            for (; j < u.len(); ++j) {
                if (u.cp[j] == '\n' || is_close(u.cp[j])) break;
            }
            if (j < u.len() && is_close(u.cp[j])) {
                out.push_back(u.slice(i + 1, j));
                scan = j + 1;
            } else {
                scan = i + 1;
            }
        }
        return out;
    }

    // re.sub(r"\s*bgm?\s*", "", s, flags=re.IGNORECASE)
    static std::string strip_bgm_all(const std::string& text) {
        Utf u(text);
        std::string out;
        size_t p = 0;
        const size_t n = u.len();
        while (p < n) {
            size_t q = p;
            while (q < n && content::is_space_cp(u.cp[q])) ++q;
            bool hit = false;
            size_t r = q;
            if (r + 1 < n && ascii_lower_cp(u.cp[r]) == 'b' && ascii_lower_cp(u.cp[r + 1]) == 'g') {
                r += 2;
                if (r < n && ascii_lower_cp(u.cp[r]) == 'm') ++r;
                while (r < n && content::is_space_cp(u.cp[r])) ++r;
                hit = true;
            }
            if (hit) {
                if (r == p && r < n) {  // 理论不可达（hit 至少 2 字符），保前进
                    out += u.slice(p, p + 1);
                    p += 1;
                } else {
                    p = r;
                }
            } else {
                out += u.slice(p, p + 1);
                p += 1;
            }
        }
        return out;
    }

    std::optional<json> parse_natural_action(const std::string& in, const json& speaker_id) {
        std::string t = content::py_strip(in);
        t = replace_all_str(t, "[", "");
        t = replace_all_str(t, "]", "");
        if (t.empty()) return std::nullopt;

        {
            auto cps = content::to_codepoints(t);
            bool all = !cps.empty();
            for (uint32_t c : cps) {
                if (content::is_digit_cp(c) || c == ',' || c == '-' || content::is_space_cp(c))
                    continue;
                all = false;
                break;
            }
            if (all) {
                std::string code_str = replace_all_str(t, "，", ",");
                json parsed = json::array();
                bool ok = true;
                for (const auto& part : split_char(code_str, ',')) {
                    auto v = content::int_digits_str(content::py_strip(part));
                    if (!v) {
                        ok = false;
                        break;
                    }
                    parsed.push_back(*v);
                }
                if (ok && !parsed.empty()) {
                    if (eq_int(parsed[0], -1) &&
                        !(parsed.size() >= 2 && int_ge(parsed[1], 4000) &&
                          int_lt(parsed[1], 6000)))
                        return std::nullopt;
                    return parsed;
                }
            }
        }

        json target_id = speaker_id;
        for (const auto& n : names_) {
            if (contains_str(t, n.name.c_str())) {
                auto it = name_to_id_.find(n.name);
                if (it != name_to_id_.end()) target_id = it.value();
                break;
            }
        }

        bool t_is_minus1 = eq_int(target_id, -1);
        auto first_num = [&](bool sign, long long def) {
            auto v = content::findall_digits(t, sign);
            if (v.empty()) return def;
            return content::int_digits_str(v[0]).value_or(def);
        };
        auto arr = [](std::initializer_list<long long> xs) {
            json a = json::array();
            for (auto x : xs) a.push_back(x);
            return a;
        };
        auto with_target = [&](std::initializer_list<json> tail) {
            json a = json::array();
            a.push_back(target_id);
            for (const auto& x : tail) a.push_back(x);
            return a;
        };

        if (contains_str(t, "一段时间") || contains_str(t, "延时")) return arr({4006});
        if (contains_str(t, "震动") || contains_str(t, "抖动")) {
            long long val = first_num(false, 1);
            if (contains_str(t, "屏幕")) return arr({4001, val});
            if (t_is_minus1) return std::nullopt;
            return with_target({json(3002)});
        }
        if (contains_str(t, "跳一跳") || contains_str(t, "微动")) {
            if (t_is_minus1) return std::nullopt;
            return with_target({json(3001)});
        }
        if (contains_str(t, "模糊")) return arr({4002});
        if (contains_str(t, "陈旧") || contains_str(t, "做旧")) return arr({4009});
        if (contains_str(t, "反色")) return arr({4010});
        if (contains_str(t, "清空") && (contains_str(t, "特效") || contains_str(t, "效果")))
            return arr({4003});
        if (contains_str(t, "挂电话") || contains_str(t, "挂断")) return arr({4008});
        if (contains_str(t, "闭眼")) return arr({4011, 1});
        if (contains_str(t, "睁眼")) return arr({4011, 0});
        if (contains_str(t, "闪白")) return arr({4012, first_num(false, 1)});
        if (contains_str(t, "结束CG") || contains_str(t, "关闭CG")) return arr({4017});
        if (contains_str(t, "道具")) return arr({4004, first_num(false, 0)});
        if (contains_str(t, "纸条")) return arr({0, 5001, first_num(false, 0)});

        for (const auto& se : kSmartExprs) {
            if (contains_str(t, se.kw)) {
                if (t_is_minus1) return std::nullopt;
                return with_target({json(3000), json(se.eid)});
            }
        }

        std::optional<long long> enter;
        if (contains_str(t, "直接") && (contains_str(t, "入场") || contains_str(t, "出现")))
            enter = 1002;
        else if (contains_str(t, "底部") && (contains_str(t, "入场") || contains_str(t, "出现")))
            enter = 1003;
        else if (contains_str(t, "滑动") || contains_str(t, "入场"))
            enter = 1001;
        if (enter) {
            if (t_is_minus1) return std::nullopt;
            long long pos = 3;
            if (contains_str(t, "左"))
                pos = 1;
            else if (contains_str(t, "右"))
                pos = 2;
            return with_target({json(*enter), json(1), json(pos)});
        }
        if (contains_str(t, "退场") || contains_str(t, "消失")) {
            if (t_is_minus1) return std::nullopt;
            return with_target({json(contains_str(t, "直接") ? 2002 : 2001)});
        }
        if (contains_str(t, "移动")) {
            if (t_is_minus1) return std::nullopt;
            long long val = first_num(true, 0);
            if (contains_str(t, "左") && val > 0) val = -val;
            if (contains_str(t, "下") && val > 0) val = -val;
            long long mt = (contains_str(t, "上") || contains_str(t, "下")) ? 3008 : 3004;
            return with_target({json(mt), json(val)});
        }
        if (contains_str(t, "镜像")) {
            if (t_is_minus1) return std::nullopt;
            return with_target({json(3007)});
        }
        if (contains_str(t, "转身")) {
            if (t_is_minus1) return std::nullopt;
            return with_target({json(3005)});
        }
        if (contains_str(t, "换装") || contains_str(t, "衣服")) {
            if (t_is_minus1) return std::nullopt;
            return with_target({json(3006), json(first_num(false, 0))});
        }
        if (contains_str(content::py_lower(t), "emoji") || contains_str(t, "气泡")) {
            if (t_is_minus1) return std::nullopt;
            return with_target({json(3009), json(first_num(false, 0))});
        }
        return std::nullopt;
    }

    static bool int_ge(const json& v, long long k) {
        auto x = py_int_value(v);
        return x && *x >= k;
    }
    static bool int_lt(const json& v, long long k) {
        auto x = py_int_value(v);
        return x && *x < k;
    }

    long long base_id_;
    long long current_idx_;
    const json& name_to_id_;
    std::vector<NameRef> names_;
};

// ---------------------------------------------------------------------------
// 导出
// ---------------------------------------------------------------------------

struct ExportOptions {
    json pure = false;
    json show_id = true;
    json show_type = true;
    json show_cond = true;
    json show_expr = true;
    json show_action = true;
    json show_bg = true;
    json show_audio = true;
    json show_minigame = true;
    json show_effect = true;
    bool attrs_ok = true;
    std::string bad_type;

    const json* find_field(const char* name) const {
        if (!std::strcmp(name, "pure")) return &pure;
        if (!std::strcmp(name, "show_id")) return &show_id;
        if (!std::strcmp(name, "show_type")) return &show_type;
        if (!std::strcmp(name, "show_cond")) return &show_cond;
        if (!std::strcmp(name, "show_expr")) return &show_expr;
        if (!std::strcmp(name, "show_action")) return &show_action;
        if (!std::strcmp(name, "show_bg")) return &show_bg;
        if (!std::strcmp(name, "show_audio")) return &show_audio;
        if (!std::strcmp(name, "show_minigame")) return &show_minigame;
        if (!std::strcmp(name, "show_effect")) return &show_effect;
        return nullptr;
    }
    bool truthy(const char* name) const {
        if (!attrs_ok)
            throw sa::ApiError("AttributeError",
                               "'" + bad_type + "' object has no attribute '" + name + "'");
        const json* f = find_field(name);
        return f && content::py_truthy(*f);
    }
};

const char* kValidOpts[] = {"pure",       "show_id",   "show_type",    "show_cond",
                            "show_expr",  "show_action", "show_bg",    "show_audio",
                            "show_minigame", "show_effect"};

ExportOptions make_options(const json& opts) {
    ExportOptions o;
    if (opts.is_object()) {
        for (const char* k : kValidOpts) {
            if (!opts.contains(k)) continue;
            const json& v = opts.at(k);
            if (const json* slot = const_cast<const ExportOptions&>(o).find_field(k)) {
                *const_cast<json*>(slot) = v;
            }
        }
    } else if (!opts.is_null()) {
        o.attrs_ok = false;
        o.bad_type = content::py_type_name(opts);
    }
    return o;
}

class Exporter {
  public:
    Exporter(const json& evt, const json& talk, const json& opt, const json& roles,
             ExportOptions opts)
        : evt_cfg_(evt.is_object() ? evt : empty_obj()),
          talk_cfg_(talk.is_object() ? talk : empty_obj()),
          opt_cfg_(opt.is_object() ? opt : empty_obj()),
          role_dict_(roles.is_object() ? roles : empty_obj()),
          opts_(std::move(opts)) {
        for (auto it = evt_cfg_.begin(); it != evt_cfg_.end(); ++it) {
            const json& e = it.value();
            if (!e.is_object() || !e.contains("talkId")) continue;
            const json& sid = e.at("talkId");
            if (sid.is_array()) {
                for (const auto& s : sid) all_starts_.insert(content::story_str(s));
            } else if (content::py_truthy(sid)) {
                all_starts_.insert(content::story_str(sid));
            }
        }
    }

    std::string export_events(const std::vector<std::string>& evt_ids,
                              const std::string& dual_choice) {
        std::vector<std::string> output;
        for (const std::string& eid : evt_ids) {
            static const json kObj = json::object();
            const json& event = evt_cfg_.contains(eid) ? evt_cfg_.at(eid) : kObj;
            if (!event.is_object()) continue;
            std::set<std::string> processed;
            std::vector<std::string> buffer;
            buffer.push_back(format_event_header(eid, event));
            buffer.push_back("");
            std::vector<std::string> starts;
            if (event.contains("talkId")) {
                for (const json& x : py_iterate(event.at("talkId"))) {
                    if (content::py_truthy(x)) starts.push_back(content::story_str(x));
                }
            }
            if (starts.size() == 2) {
                if (dual_choice == "male")
                    starts = {starts[0]};
                else if (dual_choice == "female")
                    starts = {starts[1]};
            }
            std::vector<std::string> all_ids(all_starts_.begin(), all_starts_.end());
            process_sequence(buffer, processed, starts, all_ids);
            buffer.push_back("----- END -----");
            buffer.push_back("");
            buffer.push_back("");
            output.insert(output.end(), buffer.begin(), buffer.end());
        }
        return join_str(output, "\n");
    }

  private:
    static const json& empty_obj() {
        static const json v = json::object();
        return v;
    }
    static const json& empty_arr() {
        static const json v = json::array();
        return v;
    }

    std::string role_name_val(const json& rid) {
        std::string key = content::story_str(rid);
        if (role_dict_.contains(key)) return content::story_str(role_dict_.at(key));
        return key;
    }

    std::string format_event_header(const std::string& eid, const json& event) {
        std::string title =
            event.contains("title") ? content::story_str(event.at("title")) : ("未命名_" + eid);
        std::string type_str;
        if (opts_.truthy("show_type")) {
            json t_id = event.contains("type") ? event.at("type") : json(-1);
            type_str = event_type_name(t_id) + "：";
        }
        std::vector<std::string> parts;
        if (event.contains("npc")) {
            const json& npc = event.at("npc");
            if (content::py_truthy(npc) && !eq_int(npc, 0))
                parts.push_back(role_name_val(npc) + "专属事件");
        }
        if (opts_.truthy("show_cond")) {
            json cond = content::clean_floats(
                event.contains("condition") ? event.at("condition") : json::array());
            if (content::py_truthy(cond))
                parts.push_back("触发条件为：" + parse_all_conditions(cond));
        }
        std::string parens;
        if (!parts.empty()) parens = "（" + join_str(parts, "，") + "）";
        std::string id_str = opts_.truthy("show_id") ? (" 事件id：" + eid) : "";
        return type_str + title + parens + id_str;
    }

    std::string parse_all_conditions(const json& cond_list) {
        if (!content::py_truthy(cond_list)) return "";
        std::vector<std::string> parts;
        for (const auto& c : py_iterate(cond_list)) parts.push_back(parse_condition_item(c));
        return join_str(parts, "并且");
    }

    std::string parse_condition_item(const json& cond_in) {
        json cond = content::clean_floats(cond_in);
        if (!content::py_truthy(cond)) return "未知条件";
        size_t n;
        if (cond.is_array() || cond.is_object())
            n = cond.size();
        else if (cond.is_string())
            n = content::cp_len(cond.get_ref<const std::string&>());
        else
            throw sa::ApiError("TypeError", std::string("object of type '") +
                                                content::py_type_name(cond) + "' has no len()");
        if (n < 2) return "未知条件";

        json c_type = seq_at(cond, 0);
        json c_code = seq_at(cond, 1);
        json p1 = n > 2 ? seq_at(cond, 2) : json(0);
        json p2 = n > 3 ? seq_at(cond, 3) : json(0);
        json p3 = n > 4 ? seq_at(cond, 4) : json(0);
        const std::string s_p1 = content::story_str(p1);
        const std::string s_p2 = content::story_str(p2);
        const std::string s_p3 = content::story_str(p3);
        std::string r_name = role_name_val(p1);
        auto rel = [&](const json& lvl) { return relation_name(lvl); };

        if (eq_int(c_type, 7)) {
            if (eq_int(c_code, 0)) return r_name + "是你的" + rel(p2);
            if (eq_int(c_code, 1)) return r_name + "的好感>=" + s_p2;
            if (eq_int(c_code, -1)) return r_name + "的好感<" + s_p2;
            if (eq_int(c_code, 10)) return "与父母成功交涉" + s_p2 + "次";
            if (eq_int(c_code, 7)) return "社交" + s_p1 + "次";
            if (eq_int(c_code, 9)) return "有认识的人";
            if (eq_int(c_code, 5)) {
                auto l = int_like(p1);
                std::string nm;
                if (l)
                    for (const auto& r : kRelationLevels)
                        if (r.id == *l) { nm = r.name; break; }
                if (nm.empty()) nm = s_p1;
                return nm + "(及以上)人数>=" + s_p2;
            }
            if (eq_int(c_code, 50)) {
                auto l = int_like(p1);
                std::string nm;
                if (l)
                    for (const auto& r : kRelationLevels)
                        if (r.id == *l) { nm = r.name; break; }
                if (nm.empty()) nm = s_p1;
                return nm + "关系异性人数>=" + s_p2;
            }
            if (eq_int(c_code, 8)) return "提升关系" + s_p1 + "次";
            if (eq_int(c_code, 22)) return r_name + "是好感最高的异性";
        } else if (eq_int(c_type, 1)) {
            if (eq_int(c_code, 1)) return "年龄>=" + s_p1;
            if (eq_int(c_code, 2)) return "年龄<=" + s_p1;
            if (eq_int(c_code, 3)) return s_p1 + "<=年龄<=" + s_p2;
            if (eq_int(c_code, 0)) return s_p1 + "岁" + s_p2 + "月";
            if (eq_int(c_code, 12)) {
                if (eq_int(p1, 0)) return "年级=" + s_p2;
                if (eq_int(p1, 1)) return "年级>=" + s_p2;
                if (eq_int(p1, -1)) return "年级<=" + s_p2;
                if (eq_int(p1, 101)) return s_p2 + "<=年级<=" + s_p3;
            }
            if (eq_int(c_code, 99)) {
                std::string g = eq_int(p1, 1) ? "男" : eq_int(p1, 2) ? "女" : s_p1;
                return "性别为" + g;
            }
            if (eq_int(c_code, 98)) return std::string(eq_int(p1, 1) ? "文科" : "理科") + "生";
            if (eq_int(c_code, -98))
                return "非" + std::string(eq_int(p1, 1) ? "文科" : "理科") + "生";
            if (eq_int(c_code, 97)) return std::string(eq_int(p1, 1) ? "已" : "未") + "文理分班";
            if (eq_int(c_code, 20)) return eq_int(p1, 1) ? "小学毕业之前" : "小学毕业之后";
        } else if (eq_int(c_type, 2)) {
            if (eq_int(c_code, 0)) return "当前第" + s_p1 + "回合";
            if (eq_int(c_code, 100)) return "第" + s_p1 + "回合及以后";
            if (eq_int(c_code, -100)) return "未到第" + s_p1 + "回合";
            if (eq_int(c_code, 1)) return "当前" + s_p1 + "月";
            if (eq_int(c_code, 4)) return "当前" + s_p1 + "季";
            if (eq_int(c_code, 10)) return "当前" + s_p1 + "年";
            if (eq_int(c_code, 20)) return s_p1 + "-" + s_p2 + "年";
            if (eq_int(c_code, 11)) return "当前" + s_p1 + "年" + s_p2 + "月";
            if (eq_int(c_code, 110)) return "当前" + s_p1 + "年" + s_p2 + "月及以后";
            if (eq_int(c_code, 12)) return "当前是偶数年";
            if (eq_int(c_code, 101)) return "当前是主角生日";
            if (eq_int(c_code, 3)) return "当前" + s_p1 + "年" + s_p2 + "季";
            if (eq_int(c_code, 30)) return "当前" + s_p1 + "年" + s_p2 + "季及以后";
            if (eq_int(c_code, 8)) return eq_int(p1, 1) ? "当前是寒暑假" : "当前不是寒暑假";
        } else if (eq_int(c_type, 3)) {
            if (eq_int(c_code, 1)) return "事件" + s_p1 + "已发生";
            if (eq_int(c_code, 2)) return "选项" + s_p1 + "已激活";
            if (eq_int(c_code, -1)) return "事件" + s_p1 + "未发生";
            if (eq_int(c_code, -2)) return "选项" + s_p1 + "未激活";
            if (eq_int(c_code, 3)) return "对话" + s_p1 + "已激活";
            if (eq_int(c_code, -3)) return "对话" + s_p1 + "未激活";
            if (eq_int(c_code, 4)) return "价值观" + s_p1 + "已激活";
            if (eq_int(c_code, -4)) return "价值观" + s_p1 + "未激活";
            if (eq_int(c_code, 5)) return "短信" + s_p1 + "已发出";
            if (eq_int(c_code, -5)) return "短信" + s_p1 + "未发出";
            if (eq_int(c_code, 30)) return "本回合已发生对话" + s_p1;
            if (eq_int(c_code, -30)) return "本回合未发生对话" + s_p1;
            if (eq_int(c_code, 6)) return "跑团对话" + s_p1 + "已触发";
        }
        return "未知条件" + content::story_str(cond);
    }

    static json seq_at(const json& cond, size_t i) {
        if (cond.is_array()) {
            if (i >= cond.size())
                throw sa::ApiError("IndexError", "list index out of range");
            return cond[i];
        }
        if (cond.is_string()) {
            auto cps = content::to_codepoints(cond.get_ref<const std::string&>());
            if (i >= cps.size()) throw sa::ApiError("IndexError", "string index out of range");
            return json(content::cp_to_utf8(cps[i]));
        }
        if (cond.is_object()) {
            // dict[int] 恒 KeyError（JSON 解析的 dict 键都是 str，0 != "0"）。
            throw sa::ApiError("KeyError", std::to_string(i));
        }
        throw sa::ApiError("TypeError", std::string("'") + content::py_type_name(cond) +
                                            "' object is not subscriptable");
    }

    std::pair<std::string, std::string> parse_roles_and_effects(const json& talk) {
        json roles = content::clean_floats(
            talk.contains("roles") ? talk.at("roles") : json::array());
        std::vector<std::string> expressions;
        std::vector<std::string> actions;
        if (!content::py_truthy(roles)) return {"", ""};
        for (const auto& item : py_iterate(roles)) {
            if (!item.is_array() || item.size() < 2) continue;
            json role_id_v = item[0];
            auto tl = py_int_value(item[1]);
            if (!tl) throw_int_fail(item[1]);
            long long type_id = *tl;
            std::vector<json> params;
            for (size_t i = 2; i < item.size(); ++i) params.push_back(item[i]);
            std::string rn = role_name_val(role_id_v);

            if (type_id == 3000) {
                if (opts_.truthy("show_expr")) {
                    std::string expr_id = params.empty() ? std::string("0")
                                                         : content::story_str(params[0]);
                    expressions.push_back(rn + expression_name(expr_id));
                }
                continue;
            }
            if (!opts_.truthy("show_action")) continue;
            std::string desc;
            if (type_id >= 1001 && type_id <= 1003) {
                std::string method = type_id == 1001 ? "滑动" : type_id == 1002 ? "直接" : "底部";
                json pv = params.size() > 1 ? params[1] : json(1);
                std::string pos = "?";
                auto pl = int_like(pv);
                if (pl) {
                    if (*pl == 1) pos = "左";
                    else if (*pl == 2) pos = "右";
                    else if (*pl == 3) pos = "中";
                }
                desc = rn + method + "入场到" + pos + "侧";
            } else if (type_id == 2001) {
                desc = rn + "滑动退场";
            } else if (type_id == 2002) {
                desc = rn + "直接退场";
            } else if (type_id == 3004) {
                desc = rn + "移动" + (params.empty() ? std::string("0")
                                                     : content::story_str(params[0]));
            } else if (type_id == 4001) {
                desc = "屏幕抖动";
            } else if (type_id == 4015) {
                desc = "播放CG:" + (params.empty() ? std::string("?")
                                                   : content::story_str(params[0]));
            } else {
                std::vector<std::string> xs;
                for (const auto& x : item) xs.push_back(content::story_str(x));
                desc = "[" + join_str(xs, ",") + "]";
            }
            if (!desc.empty()) actions.push_back(desc);
        }
        return {join_str(expressions, ";"), join_str(actions, ";")};
    }

    bool print_talk_entry(std::vector<std::string>& output, const json& talk,
                          std::set<std::string>& processed) {
        if (!talk.is_object())
            throw sa::ApiError("AttributeError",
                               std::string("'") + content::py_type_name(talk) +
                                   "' object has no attribute 'get'");
        std::string tid =
            talk.contains("id") ? content::story_str(talk.at("id")) : std::string("None");
        if (processed.count(tid)) {
            output.push_back("   >>> (剧情汇合/跳转至已读剧情 ID: " + tid + ")");
            return false;
        }
        processed.insert(tid);
        std::string content_str;
        if (talk.contains("content") && talk.at("content").is_string())
            content_str = content::py_strip(talk.at("content").get<std::string>());

        std::string speaker;
        {
            const json& role_ids = talk.contains("roleIds") ? talk.at("roleIds") : empty_arr();
            if (content::py_truthy(role_ids) && role_ids.is_array() && !role_ids.empty()) {
                std::vector<std::string> names;
                for (const auto& r : role_ids) names.push_back(role_name_val(r));
                speaker = join_str(names, "和");
            } else if (talk.contains("npcId") && !talk.at("npcId").is_null()) {
                speaker = role_name_val(talk.at("npcId"));
            } else {
                speaker = "旁白";
            }
        }
        if (talk.contains("roleName") && content::py_truthy(talk.at("roleName"))) {
            if (speaker != "旁白")
                speaker = speaker + "(" + content::story_str(talk.at("roleName")) + ")";
            else
                speaker = content::story_str(talk.at("roleName"));
        }
        if (opts_.truthy("pure")) {
            if (!content_str.empty()) {
                output.push_back(speaker + "：" + content_str);
                output.push_back("");
            }
            return true;
        }
        std::vector<std::string> tags;
        if (opts_.truthy("show_bg") && talk.contains("bg") && content::py_truthy(talk.at("bg")))
            tags.push_back("背景：" + content::story_str(talk.at("bg")));
        if (opts_.truthy("show_audio") && talk.contains("audio") &&
            content::py_truthy(talk.at("audio")))
            tags.push_back("BGM：" + content::story_str(talk.at("audio")));
        if (opts_.truthy("show_minigame") && talk.contains("miniGame") &&
            content::py_truthy(talk.at("miniGame")))
            tags.push_back("小游戏：" + content::story_str(content::clean_floats(talk.at("miniGame"))));
        if (opts_.truthy("show_effect") && talk.contains("effect") &&
            content::py_truthy(talk.at("effect")))
            tags.push_back("效果：" + sa_core::py_dumps(content::clean_floats(talk.at("effect"))));

        auto [expr, act] = parse_roles_and_effects(talk);
        std::vector<std::string> line;
        if (!content_str.empty() || !expr.empty() || !act.empty()) line.push_back(speaker);
        if (!expr.empty()) line.push_back("[" + expr + "]");
        for (auto& t : tags) line.push_back(t);
        if (!act.empty()) line.push_back("动作：" + act);

        if (!line.empty() || !content_str.empty()) {
            if (!line.empty()) output.push_back(join_str(line, "   "));
            if (!content_str.empty()) output.push_back(content_str);
            output.push_back("");
        }
        return true;
    }

    bool process_options(const json& talk, std::vector<std::string>& output,
                         std::set<std::string>& processed,
                         const std::vector<std::string>& start_tids) {
        const json& options = talk.contains("option") ? talk.at("option") : empty_arr();
        std::vector<json> valid;
        bool has_opt_cfg = opt_cfg_.is_object() && !opt_cfg_.empty();
        if (has_opt_cfg) {
            for (const auto& oid : py_iterate(options))
                if (opt_cfg_.contains(content::story_str(oid))) valid.push_back(oid);
        }
        if (valid.empty()) return false;
        size_t idx1 = 0;
        for (const auto& oid : valid) {
            ++idx1;
            output.push_back("——————");
            std::string oid_s = content::story_str(oid);
            static const json kObj = json::object();
            const json& cfg = opt_cfg_.contains(oid_s) ? opt_cfg_.at(oid_s) : kObj;
            std::string opt_content = cfg.contains("content")
                                          ? content::story_str(cfg.at("content"))
                                          : std::string("未命名选项");
            if (opts_.truthy("show_effect") && cfg.contains("effect") &&
                content::py_truthy(cfg.at("effect")))
                opt_content += "   效果：" + sa_core::py_dumps(content::clean_floats(cfg.at("effect")));
            output.push_back("决定" + std::to_string(idx1) + "：" + opt_content);
            output.push_back("——————");
            std::vector<std::string> branch;
            // `(cfg.get("talkId") or []) + (cfg.get("talkId2") or [])`——null 视作 []
            for (const char* key : {"talkId", "talkId2"}) {
                if (!cfg.contains(key)) continue;
                const json& v = cfg.at(key);
                if (!content::py_truthy(v)) continue;
                for (const auto& x : py_iterate(v))
                    if (content::py_truthy(x)) branch.push_back(content::story_str(x));
            }
            process_sequence(output, processed, branch, start_tids);
        }
        output.push_back("——————");
        return true;
    }

    std::vector<std::string> strs_of_or_missing(const json& talk, const char* key) {
        std::vector<std::string> out;
        const json& v = talk.contains(key) ? talk.at(key) : empty_arr();
        for (const auto& x : py_iterate(v)) {
            if (content::py_truthy(x)) out.push_back(content::story_str(x));
        }
        return out;
    }

    void process_sequence(std::vector<std::string>& output, std::set<std::string>& processed,
                          const std::vector<std::string>& start_tids,
                          const std::vector<std::string>& all_start_ids) {
        if (start_tids.empty()) return;
        std::deque<std::string> queue;
        for (const auto& x : start_tids)
            if (!x.empty()) queue.push_back(x);
        while (!queue.empty()) {
            std::string tid = queue.front();
            queue.pop_front();
            if (!talk_cfg_.contains(tid) || !content::py_truthy(talk_cfg_.at(tid))) continue;
            const json& talk = talk_cfg_.at(tid);
            if (!print_talk_entry(output, talk, processed)) continue;

            const json& check = talk.contains("check") ? talk.at("check") : empty_arr();
            const json& ns = talk.contains("nextTalk") ? talk.at("nextTalk") : empty_arr();
            const json& nf = talk.contains("nextTalk2") ? talk.at("nextTalk2") : empty_arr();
            if (content::py_truthy(check) && content::py_truthy(ns) && content::py_truthy(nf)) {
                std::string c_str = content::story_str(content::clean_floats(seq_at(check, 0)));
                output.push_back("--- 检定成功 (" + c_str + ") ---");
                process_sequence(output, processed, strs_of(ns), all_start_ids);
                output.push_back("--- 检定失败 ---");
                process_sequence(output, processed, strs_of(nf), all_start_ids);
                continue;
            }
            if (process_options(talk, output, processed, start_tids)) continue;

            std::vector<std::string> next_ids = strs_of(talk_at_or_empty(talk, "nextTalk"));
            for (const auto& n : next_ids) {
                bool in_valid = std::find(all_start_ids.begin(), all_start_ids.end(), n) ==
                                all_start_ids.end();
                if (!in_valid) {
                    for (const auto& s : start_tids)
                        if (s == n) {
                            in_valid = true;
                            break;
                        }
                }
                if (in_valid) queue.push_back(n);
            }
        }
    }

    static const json& talk_at_or_empty(const json& talk, const char* key) {
        if (!talk.contains(key)) return empty_arr();
        return talk.at(key);
    }
    static std::vector<std::string> strs_of(const json& v) {
        std::vector<std::string> out;
        for (const auto& x : py_iterate(v)) {
            if (content::py_truthy(x)) out.push_back(content::story_str(x));
        }
        return out;
    }

    const json& evt_cfg_;
    const json& talk_cfg_;
    const json& opt_cfg_;
    const json& role_dict_;
    ExportOptions opts_;
    std::set<std::string> all_starts_;
};

}  // namespace

json parse_script(const std::string& start_id, const std::string& text, const json& name_to_id) {
    auto base = content::int_digits_str(content::py_strip(start_id));
    if (!base)
        throw sa::ApiError("ValueError", content::value_error_int_repr_quoted(start_id));
    Parser parser(*base * 1000, name_to_id);
    return parser.run(text);
}

std::string export_story(const json& evt_cfg, const json& talk_cfg, const json& opt_cfg,
                         const json& role_dict, const std::vector<std::string>& evt_ids,
                         const json& opts, const std::string& dual_choice) {
    // Exporter 构造内部做 is_object 兜底（返回静态空对象引用），避免三元产生
    // 临时对象绑到 const 引用成员上出作用域悬空。
    Exporter e(evt_cfg, talk_cfg, opt_cfg, role_dict, make_options(opts));
    return e.export_events(evt_ids, dual_choice);
}

}  // namespace story
}  // namespace sa
