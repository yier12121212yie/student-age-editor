// wip/P3a/content_util.h —— 剧情/预览/搜索/舞台 共享的 Python 语义小工具。
//
// 存在理由（波次 2 P3a）：story/preview/stage 三个服务都要求逐字对齐 CPython 的
// str()/repr()/truthy/strip/len 语义（错误消息与导出文本是对外契约），
// sa_core::py_str 对容器走的是 JSON dump（与 Python str(list) 的单引号 repr
// 不一致），且 %s 出现在中文消息里，必须精确。这里补齐差异部分。
//
// 文本按 UTF-8 处理：Python 的 len()/切片/isdigit 类语义都是码点级的，
// 所有工具统一走码点迭代，不按字节数长度。
#pragma once

#include <cstdint>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

#include <nlohmann/json.hpp>

namespace sa {
namespace content {

using json = nlohmann::ordered_json;

// ---------------------------------------------------------------------------
// UTF-8 码点工具
// ---------------------------------------------------------------------------

// 解码为码点数组（非法字节按 U+FFFD 计一个码点，与 Python replace 解码同数）。
std::vector<uint32_t> to_codepoints(std::string_view utf8);
// 码点 → UTF-8 字节。
std::string cp_to_utf8(uint32_t cp);
// Python len(str)：码点数。
size_t cp_len(std::string_view utf8);
// 码点索引 -> 字节偏移（越界返回 size）。
size_t cp_to_byte(std::string_view utf8, size_t cp_index);
// 按码点取前 n 个码点的字节子串 [0, n)（n 超界则全串）。
std::string cp_prefix(std::string_view utf8, size_t cp_count);

// Python str.isspace()（re \s 同源子集：C1 控制位 + Unicode 空白类）。
bool is_space_cp(uint32_t cp);
// Python str.isdigit() 的常用子集：ASCII 0-9、全角 FF10-FF19、阿拉伯-印度、
// 天城文（剧情文本实际只会出现这几类；见交付报告偏差清单）。
bool is_digit_cp(uint32_t cp);
// str.strip()（两侧去 is_space_cp 码点）。
std::string py_strip(const std::string& s);
std::string py_lstrip_ws(const std::string& s);
std::string py_lower(std::string s);  // ASCII 小写（tex key 语义，等价够用）

// ---------------------------------------------------------------------------
// Python 值语义
// ---------------------------------------------------------------------------

// bool(v)：None/False/0/""/[]/{} 为假。注意与 sa::truthy（_truthy，只认
// true/"true"）不同——story/stage 的路由用的是裸 bool()。
bool py_truthy(const json& v);

// Python str(v)（%s / + 语境）：容器用 str(list)/str(dict) 的 repr 逗号风格。
std::string story_str(const json& v);
// Python repr(v)（%r 语境）。
std::string story_repr(const json& v);
// Python 容器/标量的 int(v) 等价：整数数值（float 截断），非数值 nullopt。
std::optional<long long> as_ll(const json& v);
// json 类型 -> Python 类型名（AttributeError 消息用）。
const char* py_type_name(const json& v);

// 深拷贝 + story_service._clean_floats（递归）：
//   float 整值 -> int；字符串 "123.0"/"-5.0" -> int。
json clean_floats(const json& v);

// 表记录取值：table[str(id)]（Python table.get(str(rid))；非对象记录视作缺失
// 的地方由调用方决定）。返回 nullptr 表示没有。
const json* record_at(const json& table, const std::string& id);

// 数字 id 规范化（preview_service._clean_id）：float/int 整值 -> "213"，
// 字符串 "213.0" 也 -> "213"；其余 str(v)。
std::string clean_id(const json& v);

// int("...") 失败时的 CPython ValueError 文本：
//   invalid literal for int() with base 10: 'abc'
std::string value_error_int(std::string_view s);
std::string value_error_int_repr_quoted(const std::string& s);  // story_repr 版

// Python int() 对「可选 ± + Nd 数字串」的逐位求值（int("１２")==12）。
// 数字类同 is_digit_cp 覆盖面；非数字/空数字段 -> nullopt。
std::optional<long long> int_digits_str(std::string_view s);
// 纯数字码点序列 -> 数值（调用方保证全是 is_digit_cp）。
long long digits_to_ll(const std::vector<uint32_t>& cps);
// re.findall(r"\d+") / r"-?\d+" 的码点版：按字节返回各匹配子串
//（UTF-8 自同步，字节子串可安全回查）。
std::vector<std::string> findall_digits(const std::string& s, bool allow_sign);

// ---------------------------------------------------------------------------
// assets/dicts.json（data_dicts 快照：game_dicts.roles/bgs/evt_types 等）
// 查找顺序：EDITOR_ASSETS_ROOT、可执行文件向上若干级的 native/assets|assets、
// CWD 相对（同 wip/P1 semantic_assets 的口径；正式嵌合归波次 3 统一处理）。
// 载入失败返回空对象并 stderr 警告一次。
// ---------------------------------------------------------------------------
const json& dicts_json();  // 整个 dicts.json
// game_dicts.roles（id->名字，保持文件顺序 = ROLE_DICT 插入顺序）。
const json& role_dict();

}  // namespace content
}  // namespace sa
