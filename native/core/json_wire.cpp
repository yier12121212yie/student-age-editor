#include "sa_core/json_wire.h"

#include <string_view>

namespace sa_core {

namespace {

using nlohmann::ordered_json;

void dump(const ordered_json& v, std::string& out) {
    if (v.is_object()) {
        out.push_back('{');
        bool first = true;
        for (auto it = v.begin(); it != v.end(); ++it) {
            if (!first) {
                out += ", ";
            }
            first = false;
            // Key: serialize as a JSON string so it gets CPython-compatible
            // escaping (`\"`, `\\`, control chars) identical to Python dict keys.
            out += ordered_json(it.key()).dump();
            out += ": ";
            dump(it.value(), out);
        }
        out.push_back('}');
        return;
    }
    if (v.is_array()) {
        out.push_back('[');
        bool first = true;
        for (auto it = v.begin(); it != v.end(); ++it) {
            if (!first) {
                out += ", ";
            }
            first = false;
            dump(*it, out);
        }
        out.push_back(']');
        return;
    }
    // Scalars (string / number / bool / null): nlohmann's compact dump already
    // matches CPython for these types (raw UTF-8 for non-ASCII, `true`/`false`/
    // `null`, minimal numeric formatting). Empty object/array are handled above.
    out += v.dump();
}

}  // namespace

std::string py_dumps(const ordered_json& v) {
    std::string out;
    dump(v, out);
    return out;
}

std::string error_json(std::string_view message) {
    ordered_json env;
    env["error"] = std::string(message);
    return py_dumps(env);
}

}  // namespace sa_core
