// wip/P5/p5_util.h — Python-semantics glue shared by the cloud-sync domain.
//
// Deliberately tiny: path/stat primitives live in sa_core::paths, int/str
// coercion in sa_core::util + p4::json_int. What is left are the time formats
// cloud_sync.py / realtime_sync.py stamp into config files, event logs and
// sync history, plus Python-truthiness helpers.
#pragma once

#include <string>

#include <nlohmann/json.hpp>

namespace sa {
namespace p5 {

using json = nlohmann::ordered_json;

// time.strftime("%Y-%m-%dT%H:%M:%S") — LOCAL time, no timezone suffix
// (cloud_sync.py:1777,2229,2342 / realtime_sync.py:172,593,619).
std::string iso_now_local();

// time.time() as epoch seconds (float).
double epoch_now();

// Python bool(x): None/False/0/0.0/""/[]/{} are False; every other value True.
// Distinct from sa::truthy (_truthy only accepts real true / "true").
bool py_truthy(const json& v);

// os.path.join(root, *parts) for exactly one part (backslash on Windows via
// paths::join semantics; keeps whichever separator style paths::join uses).
std::string join_path(const std::string& a, const std::string& b);

// Python repr on a list of JSON scalars, limited to the str/None/number cases
// these files need: log lines like `%s` on list(changed)[:3] print
// ['a.json', 'b.json'] (single quotes, elements str()'d then repr'd).
std::string py_list_repr(const json& arr);

// type(x).__name__ for a JSON scalar (NoneType/bool/int/float/str/list/dict).
const char* py_type_name(const json& v);

// `x or ""` feeding a *string* operation: truthy non-str mirrors Python's
// AttributeError ("<Type> object has no attribute '<attr>'") via ApiError so
// the httpd 500 envelope carries the type name. `x` itself: falsy → "".
std::string str_or_throw(const json& v, const char* attr);

}  // namespace p5
}  // namespace sa
