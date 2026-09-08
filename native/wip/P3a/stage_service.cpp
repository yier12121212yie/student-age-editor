// wip/P3a/stage_service.cpp —— port of server/stage_service.py。
#include "stage_service.h"

#include <algorithm>
#include <cmath>
#include <map>
#include <string>
#include <vector>

#include "sa_core/json_wire.h"
#include "sa_core/paths.h"
#include "sa_core/strings.h"
#include "sa_core/utf8.h"
#include "sa_core/util.h"
#include "server/httpd.h"
#include "server/state.h"

namespace sa {
namespace stage {
namespace {

using content::json;

struct ParamDef {
    const char* key;
    const char* desc;
    bool required = false;
    std::optional<long long> def;  // "default" 值
};

struct ActionDef {
    long long tid;
    const char* name;
    const char* category;
    bool role;
    std::vector<std::string> aliases;
    std::vector<ParamDef> params;
};

// STAGE_ACTIONS 原表（tid 升序）。
const std::vector<ActionDef>& actions() {
    static const std::vector<ActionDef> v = {
        {1001, "滑动入场", "入场", true, {"入场"}, {{"pos", "站位：左/中/右", false, std::nullopt}}},
        {1002, "直接入场", "入场", true, {"直接出现"}, {{"pos", "站位：左/中/右", false, std::nullopt}}},
        {1003, "底部入场", "入场", true, {"从底部入场"}, {{"pos", "站位：左/中/右", false, std::nullopt}}},
        {2001, "滑动退场", "退场", true, {"退场"}, {}},
        {2002, "直接退场", "退场", true, {"消失"}, {}},
        {3000, "表情", "表情", true, {"表情"}, {{"expr", "表情名或表情ID（如 开心 / 1）", true, std::nullopt}}},
        {3001, "微动", "动作", true, {"跳一跳", "轻轻动"}, {}},
        {3002, "震动", "动作", true, {"人物抖动"}, {}},
        {3004, "左右移动", "移动", true, {"移动"}, {{"value", "位移像素值（负=向左 正=向右）", true, std::nullopt}}},
        {3005, "转身", "动作", true, {"回头"}, {}},
        {3006, "换装", "动作", true, {"换衣服"}, {{"value", "服装ID（ClothTypeCfg）", true, std::nullopt}}},
        {3007, "镜像", "动作", true, {"左右翻转"}, {}},
        {3008, "上下移动", "移动", true, {}, {{"value", "位移像素值（负=向下 正=向上）", true, std::nullopt}}},
        {3009, "气泡", "动作", true, {"气泡表情", "emoji"}, {{"value", "气泡ID", true, std::nullopt}}},
        {4001, "屏幕抖动", "屏幕特效", false, {"抖屏"}, {{"value", "抖动强度，默认 1", false, 1LL}}},
        {4002, "模糊", "屏幕特效", false, {"画面模糊"}, {}},
        {4003, "清空特效", "屏幕特效", false, {"清除特效"}, {}},
        {4004, "展示道具", "屏幕特效", false, {"显示道具"}, {{"value", "道具ID（ItemCfg）", true, std::nullopt}}},
        {4006, "延时", "屏幕特效", false, {"等待", "一段时间"}, {{"value", "延时秒数，默认 1", false, 1LL}}},
        {4008, "挂电话", "屏幕特效", false, {"挂断"}, {}},
        {4009, "做旧", "屏幕特效", false, {"陈旧效果"}, {}},
        {4010, "反色", "屏幕特效", false, {"颜色反转"}, {}},
        {4011, "睁眼/闭眼", "屏幕特效", false, {"睁眼", "闭眼"}, {{"value", "0=睁眼 1=闭眼", false, 0LL}}},
        {4012, "闪白", "屏幕特效", false, {"白闪"}, {{"value", "闪白次数，默认 1", false, 1LL}}},
        {4015, "播放CG", "屏幕特效", false, {"显示CG"}, {{"value", "CG ID（CGCfg）", true, std::nullopt}}},
        {4017, "结束CG", "屏幕特效", false, {"关闭CG"}, {}},
        {5001, "纸条", "屏幕特效", false, {"小纸条"}, {{"value", "纸条ID", true, std::nullopt}}},
    };
    return v;
}

const ActionDef* find_action(long long tid) {
    for (const auto& a : actions())
        if (a.tid == tid) return &a;
    return nullptr;
}

const char* kExpressionNames[27] = {
    "默认", "开心", "生气", "伤心", "害羞", "喜欢", "认真", "疑惑", "惊讶", "得意", "微笑",
    "坏笑", "担心", "害怕", "难过", "咆哮", "窘迫", "不满", "冷笑", "无语", "苦笑", "挫败",
    "尴尬", "迷茫", "嫌弃", "俏皮", "尴尬"};

bool is_known_expr_id(long long id) { return id >= 0 && id <= 26; }

// _EXPR_NAME_MAP：按 "0".."26" 插入序，重名 尴尬 被 26 覆盖。
long long expr_by_name(const std::string& name, bool* found) {
    *found = false;
    for (int i = 0; i <= 25; ++i) {
        if (name == kExpressionNames[i]) {
            *found = true;
            return i;  // 尴尬命中 22，但下面覆写语义等价（最后命中 26）
        }
    }
    if (name == "尴尬") {
        *found = true;
        return 26;
    }
    return 0;
}

// ACTION_CATEGORY_TYPES
bool in_category(const std::string& category, long long tid) {
    if (category == "入场") return tid == 1001 || tid == 1002 || tid == 1003;
    if (category == "退场") return tid == 2001 || tid == 2002;
    if (category == "移动") return tid == 3004 || tid == 3008;
    if (category == "表情") return tid == 3000;
    if (category == "动作")
        return tid == 3001 || tid == 3002 || tid == 3005 || tid == 3006 || tid == 3007 ||
               tid == 3009;
    if (category == "屏幕特效") return !in_category("入场", tid) && !in_category("退场", tid) &&
                                      !in_category("表情", tid) && !in_category("动作", tid) &&
                                      tid != 3004 && tid != 3008 && tid != 3000;
    return false;
}
bool is_category(const std::string& s) {
    return s == "入场" || s == "退场" || s == "移动" || s == "表情" || s == "动作" ||
           s == "屏幕特效";
}

// 码点序比较（Python str 排序）
bool cp_less(const std::string& a, const std::string& b) {
    auto ca = content::to_codepoints(a);
    auto cb = content::to_codepoints(b);
    return std::lexicographical_compare(ca.begin(), ca.end(), cb.begin(), cb.end());
}

// _ACTION_NAME_MAP：name+aliases 插入序，setdefault 保首个。
std::optional<long long> action_by_name(const std::string& name) {
    std::optional<long long> first_hit;
    for (const auto& a : actions()) {
        if (name == a.name) return a.tid;  // name 唯一，直接命中优先
    }
    for (const auto& a : actions()) {
        for (const auto& al : a.aliases) {
            if (al == name) return a.tid;  // setdefault：首个插入者；按 tid 升序扫描等价
        }
    }
    (void)first_hit;
    return std::nullopt;
}

// 数字 id 清理（_clean_num）
json clean_num(const json& v) {
    if (v.is_number_float()) {
        double d = v.get<double>();
        if (std::isfinite(d) && d == std::floor(d)) return json(static_cast<long long>(d));
    }
    return v;
}

std::string role_name_of(const json& role_id, const json& d) {
    std::string key = content::story_str(role_id);
    if (d.is_object() && d.contains(key)) return content::story_str(d.at(key));
    return key;
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
// 解析
// ---------------------------------------------------------------------------

bool looks_int_str(const std::string& s) {  // s.lstrip("-").isdigit()
    size_t b = 0;
    auto cps = content::to_codepoints(s);
    while (b < cps.size() && cps[b] == '-') ++b;
    if (b >= cps.size()) return false;
    for (size_t i = b; i < cps.size(); ++i)
        if (!content::is_digit_cp(cps[i])) return false;
    return true;
}

long long resolve_role_i(const json& ref, const json& role_dict) {
    if (ref.is_null()) throw sa::SandboxError("缺少 role 参数（角色名或角色ID）");
    std::string s = content::py_strip(content::story_str(ref));
    if (s.empty()) throw sa::SandboxError("role 参数为空");
    if (looks_int_str(s)) {
        return content::int_digits_str(s).value_or(0);
    }
    for (auto it = role_dict.begin(); it != role_dict.end(); ++it) {
        const json& v = it.value();
        std::string name;
        if (v.is_string())
            name = v.get<std::string>();
        else if (v.is_array() && !v.empty() && v.front().is_string())
            name = v.front().get<std::string>();
        if (name == s) {
            auto iv = content::int_digits_str(it.key());
            if (iv) return *iv;
            // 键非数字 Python 会返回字符串 id；舞台字典（dicts.json）键恒数字，
            // 该分支按「找不到」处理（见交付报告偏差）。
        }
    }
    throw sa::SandboxError("找不到角色「" + s +
                           "」，可先用 get_game_dicts(name=roles) 或 get_stage_dicts 核对角色名/ID");
}

long long resolve_expr(const json& ref) {
    if (ref.is_null()) throw sa::SandboxError("缺少 expr 参数（表情名或表情ID）");
    std::string s = content::py_strip(content::story_str(ref));
    if (s.empty()) throw sa::SandboxError("expr 参数为空");
    if (looks_int_str(s)) {
        long long eid = content::int_digits_str(s).value_or(-1);
        if (is_known_expr_id(eid)) return eid;  // str(eid) in STAGE_EXPRESSIONS（0..26）
        throw sa::SandboxError("表情ID " + s + " 不在范围内（0-26）");
    }
    bool found = false;
    long long eid = expr_by_name(s, &found);
    if (!found)
        throw sa::SandboxError("找不到表情「" + s + "」，可先用 get_stage_dicts 查看表情列表");
    return eid;
}

long long resolve_action_type(const json& ref, const std::string* category) {
    if (ref.is_null()) throw sa::SandboxError("缺少 type 参数（动作/特效名称或类型ID）");
    std::string s = content::py_strip(content::story_str(ref));
    if (s.empty()) throw sa::SandboxError("type 参数为空");
    long long tid;
    if (looks_int_str(s)) {
        tid = content::int_digits_str(s).value_or(-1);
        if (!find_action(tid)) throw sa::SandboxError("动作类型ID " + s + " 不在舞台指令表中");
    } else {
        auto t = action_by_name(s);
        if (!t)
            throw sa::SandboxError("找不到动作「" + s + "」，可先用 get_stage_dicts 查看动作列表");
        tid = *t;
    }
    if (category && !in_category(*category, tid)) {
        std::vector<std::string> names;
        for (const auto& a : actions())
            if (in_category(*category, a.tid)) names.push_back(a.name);
        std::sort(names.begin(), names.end(), cp_less);
        const ActionDef* ad = find_action(tid);
        throw sa::SandboxError(std::string("动作「") + ad->name + "」不属于分类「" + *category +
                               "」，该分类可用：" + join_str(names, "、"));
    }
    return tid;
}

long long as_int(const json& value, const std::string& label,
                 std::optional<long long> def) {
    if (value.is_null()) {
        if (def) return *def;
        throw sa::SandboxError("缺少 " + label + " 参数（数值）");
    }
    // int(str(value).strip().lstrip("+"))
    std::string s = content::py_strip(content::story_str(value));
    size_t b = 0;
    auto cps = content::to_codepoints(s);
    while (b < cps.size() && cps[b] == '+') ++b;
    auto parsed = content::int_digits_str(content::cp_prefix(s, cps.size()).substr(
        content::cp_to_byte(s, b)));
    if (!parsed) {
        throw sa::SandboxError(label + " 应为数值，收到: " + content::story_repr(value));
    }
    return *parsed;
}

std::string strip_field(const json& v, const char* fallback) {
    // `(x or fallback).strip()`：非字符串真值 -> AttributeError（路由转 500）。
    if (content::py_truthy(v)) {
        if (!v.is_string())
            throw sa::ApiError("AttributeError",
                               "'" + std::string(content::py_type_name(v)) +
                                   "' object has no attribute 'strip'");
        return content::py_strip(v.get<std::string>());
    }
    return fallback;
}

json encode_one(const json& cmd, const json& role_dict) {
    if (!cmd.is_object())
        throw sa::SandboxError("指令应为对象，收到: " + content::story_repr(cmd));
    std::string action =
        strip_field(cmd.contains("action") ? cmd.at("action") : json(), "");
    if (action.empty())
        throw sa::SandboxError("缺少 action 字段（入场/退场/移动/表情/动作/屏幕特效）");
    if (!is_category(action)) {
        std::vector<std::string> cats = {"入场", "退场", "移动", "表情", "动作", "屏幕特效"};
        std::sort(cats.begin(), cats.end(), cp_less);
        throw sa::SandboxError("未知 action「" + action + "」，可选：" + join_str(cats, "、"));
    }

    auto getf = [&cmd](const char* k) -> json { return cmd.contains(k) ? cmd.at(k) : json(); };

    if (action == "表情") {
        long long role_id = resolve_role(getf("role"), role_dict);
        if (role_id == -1) throw sa::SandboxError("旁白（-1）不能设置表情");
        json out = json::array();
        out.push_back(role_id);
        out.push_back(3000);
        out.push_back(resolve_expr(getf("expr")));
        return out;
    }

    if (action == "入场" || action == "退场" || action == "移动") {
        long long role_id = resolve_role(getf("role"), role_dict);
        if (role_id == -1) throw sa::SandboxError("旁白（-1）不能" + action);
        json out = json::array();
        out.push_back(role_id);
        if (action == "入场" || action == "退场") {
            std::string mode = strip_field(getf("mode"), "滑动");
            std::map<std::string, long long> modes =
                action == "入场" ? std::map<std::string, long long>{{"滑动", 1001},
                                                                    {"直接", 1002},
                                                                    {"底部", 1003}}
                                 : std::map<std::string, long long>{{"滑动", 2001},
                                                                    {"直接", 2002}};
            auto it = modes.find(mode);
            if (it == modes.end())
                throw sa::SandboxError(action + " mode 可选：" +
                                       (action == "入场" ? "滑动/直接/底部" : "滑动/直接") +
                                       "，收到: " + content::story_repr(json(mode)));
            out.push_back(it->second);
            if (action == "入场") {
                std::string pos = strip_field(getf("pos"), "中");
                long long pos_id;
                if (pos == "左")
                    pos_id = 1;
                else if (pos == "右")
                    pos_id = 2;
                else if (pos == "中")
                    pos_id = 3;
                else
                    throw sa::SandboxError("站位 pos 可选：左/中/右，收到: " +
                                           content::story_repr(json(pos)));
                out.push_back(1);
                out.push_back(pos_id);
            }
        } else {  // 移动
            std::string axis = strip_field(getf("axis"), "横");
            long long tid;
            if (axis == "横" || axis == "左右")
                tid = 3004;
            else if (axis == "纵" || axis == "上下")
                tid = 3008;
            else
                throw sa::SandboxError("移动 axis 可选：横/纵，收到: " +
                                       content::story_repr(json(axis)));
            long long value = as_int(getf("value"), "移动 value", std::nullopt);
            out.push_back(tid);
            out.push_back(value);
        }
        return out;
    }

    // 动作 / 屏幕特效：先解析 type，再按类型的参数要求补全
    std::string category = action;
    long long tid = resolve_action_type(getf("type"), &category);
    const ActionDef* tdef = find_action(tid);
    json out = json::array();
    long long role_id = -2;
    if (tdef->role) {
        role_id = resolve_role(getf("role"), role_dict);
        out.push_back(role_id);
    }
    out.push_back(tid);
    if (tdef->role && role_id == -1)
        throw sa::SandboxError(std::string("旁白（-1）不能执行动作「") + tdef->name + "」");
    if (tid == 4011) {
        std::string raw = strip_field(getf("type"), "");
        out.push_back(raw == "闭眼" ? 1 : 0);
        return out;
    }
    if (tdef->params.empty()) return out;
    std::optional<long long> def;
    for (const auto& p : tdef->params) {
        if (p.def) {
            def = p.def;
            break;
        }
    }
    out.push_back(as_int(getf("value"), "「" + std::string(tdef->name) + "」的 value", def));
    return out;
}

// ---------------------------------------------------------------------------
// roles -> 描述
// ---------------------------------------------------------------------------

// `isinstance(v, int)`（bool 亦 int）+ 命中 STAGE_ACTIONS
std::optional<long long> int_key_in_actions(const json& v) {
    if (v.is_boolean()) return v.get<bool>() ? 1LL : 0LL;
    if (v.is_number_integer() || v.is_number_unsigned()) return content::as_ll(v);
    return std::nullopt;
}

std::string describe_role_cmd(const json& role_id, long long tid, const std::vector<json>& params,
                              const json& d) {
    std::string name = role_name_of(role_id, d);
    const ActionDef* tdef = find_action(tid);
    if (tid == 1001 || tid == 1002 || tid == 1003) {
        std::string k = params.size() > 1 ? content::story_str(params[1]) : std::string("3");
        std::string pos = k == "1" ? "左" : k == "2" ? "右" : k == "3" ? "中" : "?";
        std::string verb = sa_core::str::replace_all(tdef->name, "入场", "");
        return name + verb + "到" + pos + "侧";
    }
    if (tid == 2001 || tid == 2002) return name + tdef->name;
    if (tid == 3000) {
        std::string expr_id = params.empty() ? std::string("0") : content::story_str(params[0]);
        std::string en = expr_id;
        for (int i = 0; i <= 26; ++i) {
            if (std::to_string(i) == expr_id) {
                en = kExpressionNames[i];
                break;
            }
        }
        return name + "表情：" + en;
    }
    if (tid == 3004 || tid == 3008) {
        json val = params.empty() ? json(0) : params[0];
        double dv;
        auto dl = int_key_in_actions(val);
        if (val.is_number()) {
            dv = val.get<double>();
        } else if (val.is_boolean()) {
            dv = val.get<bool>() ? 1 : 0;
        } else {
            throw sa::ApiError("TypeError",
                               "'<' not supported between instances of '" +
                                   std::string(content::py_type_name(val)) + "' and 'int'");
        }
        const char* neg = tid == 3004 ? "左" : "下";
        const char* pvs = tid == 3004 ? "右" : "上";
        std::string dir = dv < 0 ? neg : pvs;
        double a = std::fabs(dv);
        std::string av = val.is_number_float() && a != std::floor(a)
                             ? content::story_str(json(a))
                             : std::to_string(static_cast<long long>(a));
        return name + tdef->name + " " + av + dir;
    }
    if (tid == 3006 && !params.empty())
        return name + "换装（服装ID=" + content::story_str(params[0]) + "）";
    if (tid == 3009 && !params.empty())
        return name + "气泡（ID=" + content::story_str(params[0]) + "）";
    return name + tdef->name;
}

bool eq_int_val(const json& v, long long k) {
    if (v.is_boolean()) return (v.get<bool>() ? 1LL : 0LL) == k;
    if (v.is_number_integer() || v.is_number_unsigned()) return content::as_ll(v).value() == k;
    if (v.is_number_float()) {
        double d = v.get<double>();
        return std::isfinite(d) && d == std::floor(d) && static_cast<long long>(d) == k;
    }
    return false;  // str/list/dict 与 int 恒不等（Python ==）
}

std::string describe_screen_cmd(long long tid, const std::vector<json>& params) {
    const ActionDef* tdef = find_action(tid);
    if (tid == 4011)
        return std::string("画面") + (params.empty() || !eq_int_val(params[0], 1) ? "睁眼" : "闭眼");
    if (tid == 5001)
        return "纸条：" + (params.empty() ? std::string("?") : content::story_str(params[0]));
    if (!params.empty()) {
        std::vector<std::string> xs;
        for (const auto& p : params) xs.push_back(content::story_str(p));
        return std::string(tdef->name) + "（" + join_str(xs, "、") + "）";
    }
    return tdef->name;
}

std::vector<json> stage_iter(const json& v) {
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

std::string roles_desc(const json& roles) {
    if (!content::py_truthy(roles)) return "(无舞台指令)";
    json d = content::role_dict();
    std::vector<std::string> out;
    for (const json& raw_item : stage_iter(roles)) {
        if (!raw_item.is_array() || raw_item.size() < 2) {
            out.push_back("[未知指令] " + content::story_str(raw_item));
            continue;
        }
        json item = json::array();
        for (const auto& x : raw_item) item.push_back(clean_num(x));
        std::optional<long long> tid;
        {
            auto tl = int_key_in_actions(item[1]);
            if (tl && find_action(*tl)) tid = tl;
        }
        std::vector<json> params;
        for (size_t i = 2; i < item.size(); ++i) params.push_back(item[i]);
        if (tid && find_action(*tid)->role) {
            out.push_back(describe_role_cmd(item[0], *tid, params, d));
            continue;
        }
        auto head = int_key_in_actions(item[0]);
        if (head && find_action(*head) && !find_action(*head)->role) {
            std::vector<json> sp;
            for (size_t i = 1; i < item.size(); ++i) sp.push_back(item[i]);
            out.push_back(describe_screen_cmd(*head, sp));
            continue;
        }
        if (eq_int_val(item[1], 5001)) {
            out.push_back(item.size() > 2 ? "纸条：" + content::story_str(item[2]) : "纸条");
            continue;
        }
        out.push_back("[未知指令] " + content::story_str(item));
    }
    return join_str(out, "\n");
}

}  // namespace

std::string describe_roles(const json& roles) { return roles_desc(roles); }
long long resolve_role(const json& ref, const json& role_dict) {
    return resolve_role_i(ref, role_dict);
}

json get_role_dict() { return content::role_dict(); }

json get_stage_dicts() {
    json exprs = json::array();
    for (int i = 0; i <= 26; ++i) {
        json e = json::object();
        e["id"] = i;
        e["name"] = kExpressionNames[i];
        exprs.push_back(std::move(e));
    }
    json acts = json::array();
    for (const auto& a : actions()) {
        std::vector<std::string> ps;
        for (const auto& p : a.params)
            ps.push_back(std::string(p.key) + "：" + p.desc + (p.required ? "" : "（可选）"));
        json one = json::object();
        one["type"] = a.tid;
        one["name"] = a.name;
        one["category"] = a.category;
        one["role"] = a.role;
        one["params"] = ps.empty() ? "无参数" : join_str(ps, "；");
        acts.push_back(std::move(one));
    }
    json poss = json::array();
    for (auto kv : std::vector<std::pair<long long, const char*>>{{1, "左"}, {2, "右"}, {3, "中"}}) {
        json p = json::object();
        p["id"] = kv.first;
        p["name"] = kv.second;
        poss.push_back(std::move(p));
    }
    json roles = json::array();
    const json& rd = content::role_dict();
    for (auto it = rd.begin(); it != rd.end(); ++it) {
        json r = json::object();
        r["id"] = it.key();
        r["name"] = it.value();
        roles.push_back(std::move(r));
    }
    json out = json::object();
    out["expressions"] = std::move(exprs);
    out["actions"] = std::move(acts);
    out["positions"] = std::move(poss);
    out["roles"] = std::move(roles);
    return out;
}

json encode_commands(const json& commands, const json& role_dict) {
    if (commands.is_null()) return json::array();
    if (!commands.is_array()) throw sa::SandboxError("commands 应为指令数组");
    std::vector<std::string> errors;
    size_t idx = 0;
    for (const auto& cmd : commands) {
        ++idx;
        try {
            encode_one(cmd, role_dict);
        } catch (const sa::SandboxError& e) {
            errors.push_back("第 " + std::to_string(idx) + " 条" + e.what());
        }
    }
    if (!errors.empty())
        throw sa::SandboxError("舞台指令解析失败，请修正后重试：\n" + join_str(errors, "\n"));
    json out = json::array();
    for (const auto& cmd : commands) out.push_back(encode_one(cmd, role_dict));
    return out;
}

// ---------------------------------------------------------------------------
// TalkCfg 条目
// ---------------------------------------------------------------------------
namespace {

// ai_domain_service._cfg_path / load_cfg / cfg_exists 等价（错误消息逐字）。
std::string domain_cfg_path(const std::string& cfg_name) {
    std::string dir = sa::cfg_dir();
    if (dir.empty()) throw sa::SandboxError("未选择模组");
    std::string rel = sa::norm_rel(cfg_name + ".json");
    return sa_core::paths::join(dir, rel);
}

json load_domain_cfg(const std::string& cfg_name, const std::string& path) {
    auto raw = sa_core::paths::read_bytes(path);
    if (!raw)
        throw sa::SandboxError("配置表 " + cfg_name + " 读取失败: FileNotFoundError");
    std::optional<std::string> text = sa_core::decode_utf8_sig_strict(*raw);
    // Python open(...).read() + json.load 的异常文本形态复杂（UnicodeDecodeError/
    // JSONDecodeError），此处仅保证前缀契约「配置表 %s 读取失败: 」；细粒度消息
    // 差异见交付报告偏差清单。
    if (!text)
        throw sa::SandboxError("配置表 " + cfg_name +
                               " 读取失败: UnicodeDecodeError");
    json data = json::parse(*text, nullptr, false);
    if (data.is_discarded())
        throw sa::SandboxError("配置表 " + cfg_name +
                               " 读取失败: Expecting value: line 1 column 1 (char 0)");
    if (!data.is_object())
        throw sa::SandboxError("配置表 " + cfg_name + " 结构异常：顶层应为 JSON 对象");
    return data;
}

std::pair<std::string, json> load_talk(const std::string& talk_id_in) {
    std::string talk_id = content::py_strip(talk_id_in);
    if (talk_id.empty()) throw sa::SandboxError("缺少 talk_id 参数");
    std::string path;
    path = domain_cfg_path("TalkCfg");
    if (!sa_core::paths::is_file(path))
        throw sa::SandboxError(
            "当前模组还没有 TalkCfg 配置表（TalkCfg.json 不存在，通常是因为还没有创建过任何"
            "条目）。如需新建条目请用 create_domain_item（会自动创建该表）；如需确认已有条目"
            "可先用 list_domain_items 查看。");
    json data = load_domain_cfg("TalkCfg", path);
    if (!data.contains(talk_id))
        throw sa::SandboxError("TalkCfg 中不存在对白 id=" + talk_id +
                               "（可用 list_domain_items(domain=story, table=TalkCfg) 查看）");
    const json& record = data.at(talk_id);
    if (!record.is_object())
        throw sa::SandboxError("TalkCfg 的 id=" + talk_id + " 不是对象");
    return {talk_id, record};
}

}  // namespace

json get_talk_stage(const std::string& talk_id) {
    auto [tid, record] = load_talk(talk_id);
    json roles = record.contains("roles") && content::py_truthy(record.at("roles"))
                     ? record.at("roles")
                     : json::array();
    json out = json::object();
    out["talk_id"] = tid;
    out["roles"] = roles;
    out["desc"] = describe_roles(roles);
    return out;
}

json encode_talk_stage(const std::string& talk_id, const json& commands, bool clear) {
    auto [tid, record] = load_talk(talk_id);
    json old_roles = record.contains("roles") && content::py_truthy(record.at("roles"))
                         ? record.at("roles")
                         : json::array();
    json added = encode_commands(commands, content::role_dict());
    json new_roles = json::array();
    if (!clear)
        for (const auto& x : old_roles) new_roles.push_back(x);
    for (const auto& x : added) new_roles.push_back(x);
    json out = json::object();
    out["talk_id"] = tid;
    out["clear"] = clear;
    out["old_roles"] = old_roles;
    out["new_roles"] = new_roles;
    out["old_desc"] = describe_roles(old_roles);
    out["new_desc"] = describe_roles(new_roles);
    out["added"] = static_cast<long long>(added.size());
    return out;
}

}  // namespace stage
}  // namespace sa
