// wip/P5/p5_util.cpp — see p5_util.h.
#include "p5_util.h"

#include <chrono>
#include <cstdio>
#include <ctime>
#include <string>

#include "sa_core/paths.h"
#include "sa_core/util.h"
#include "server/httpd.h"  // ApiError for str_or_throw

namespace sa {
namespace p5 {

std::string iso_now_local() {
    // time.strftime("%Y-%m-%dT%H:%M:%S")
    auto now = std::chrono::system_clock::now();
    std::time_t t = std::chrono::system_clock::to_time_t(now);
    std::tm tmv{};
#ifdef _WIN32
    localtime_s(&tmv, &t);
#else
    localtime_r(&t, &tmv);
#endif
    char buf[32];
    std::strftime(buf, sizeof(buf), "%Y-%m-%dT%H:%M:%S", &tmv);
    return buf;
}

double epoch_now() {
    return std::chrono::duration<double>(
               std::chrono::system_clock::now().time_since_epoch())
        .count();
}

bool py_truthy(const json& v) {
    if (v.is_null()) return false;
    if (v.is_boolean()) return v.get<bool>();
    if (v.is_number_integer()) return v.get<long long>() != 0;
    if (v.is_number_unsigned()) return v.get<unsigned long long>() != 0;
    if (v.is_number_float()) return v.get<double>() != 0.0;
    if (v.is_string()) return !v.get<std::string>().empty();
    if (v.is_array()) return !v.empty();
    if (v.is_object()) return !v.empty();
    return true;
}

std::string join_path(const std::string& a, const std::string& b) {
    return sa_core::paths::join(a, b);
}

std::string py_list_repr(const json& arr) {
    // str() each element (Python list(changed) holds strings already; numbers
    // via py_str), then repr() them into "[..., ...]".
    std::string out = "[";
    bool first = true;
    for (const auto& item : arr) {
        if (!first) out += ", ";
        first = false;
        std::string s = item.is_string() ? item.get<std::string>()
                                         : sa_core::py_str(item);
        out += sa_core::py_repr_str(s);
    }
    out += "]";
    return out;
}

const char* py_type_name(const json& v) {
    if (v.is_null()) return "NoneType";
    if (v.is_boolean()) return "bool";
    if (v.is_number_integer() || v.is_number_unsigned()) return "int";
    if (v.is_number_float()) return "float";
    if (v.is_string()) return "str";
    if (v.is_array()) return "list";
    return "dict";
}

std::string str_or_throw(const json& v, const char* attr) {
    if (!py_truthy(v)) return "";
    if (v.is_string()) return v.get<std::string>();
    throw ApiError("AttributeError",
                   "'" + std::string(py_type_name(v)) + "' object has no attribute '" + attr +
                       "'");
}

}  // namespace p5
}  // namespace sa
