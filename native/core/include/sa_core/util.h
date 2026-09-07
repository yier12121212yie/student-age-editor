// sa_core: Python-semantics helpers shared by the native backend.
//
// Everything here exists because the C++ port must reproduce CPython
// observable behavior (str()/repr() in error messages, int() parsing,
// time.time() granularity), not just JSON structure.
#pragma once

#include <cstdint>
#include <optional>
#include <string>
#include <string_view>

#include <nlohmann/json.hpp>

namespace sa_core {

// Milliseconds since the Unix epoch, Python int(time.time()*1000) equivalent.
long long now_ms();

// Python str(v) for JSON scalars: bool -> "True"/"False", float -> repr, null
// -> "None". Used by error messages that go through %r/%s in the Python code.
std::string py_str(const nlohmann::ordered_json& v);

// Python repr(v) for strings ('...' preferring quotes, escaping \\ \n \r).
std::string py_repr_str(std::string_view s);

// Python int(str) semantics on trimmed input (base 10, optional sign).
std::optional<long long> py_int(std::string_view s);

// Python urlparse(origin).hostname for http(s) origins: everything between
// "://" and the first '/' (port stripped), lowercased; std::nullopt when the
// value has no scheme:// prefix (urlparse then yields hostname None -> "").
std::optional<std::string> origin_hostname(std::string_view origin);

}  // namespace sa_core
