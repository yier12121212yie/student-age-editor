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

namespace {

// CPython json.dumps(..., indent=2, ensure_ascii=False): newline + (level+1)*2
// spaces before each member, "," between members (NOT ", "), ": " after keys,
// "{}"/"[]" for empty containers. (cfg_store._serialize's exact output; used
// for on-disk bytes parity so unchanged-detection and undo byte-compare work.)
void dump_indent(const ordered_json& v, std::string& out, int level) {
    if (v.is_object()) {
        if (v.empty()) {
            out += "{}";
            return;
        }
        out += "{\n";
        bool first = true;
        for (auto it = v.begin(); it != v.end(); ++it) {
            if (!first) {
                out += ",\n";
            }
            first = false;
            out.append(static_cast<size_t>(level + 1) * 2, ' ');
            out += ordered_json(it.key()).dump();
            out += ": ";
            dump_indent(it.value(), out, level + 1);
        }
        out += "\n";
        out.append(static_cast<size_t>(level) * 2, ' ');
        out += '}';
        return;
    }
    if (v.is_array()) {
        if (v.empty()) {
            out += "[]";
            return;
        }
        out += "[\n";
        bool first = true;
        for (auto it = v.begin(); it != v.end(); ++it) {
            if (!first) {
                out += ",\n";
            }
            first = false;
            out.append(static_cast<size_t>(level + 1) * 2, ' ');
            dump_indent(*it, out, level + 1);
        }
        out += "\n";
        out.append(static_cast<size_t>(level) * 2, ' ');
        out += ']';
        return;
    }
    out += v.dump();
}

}  // namespace

std::string py_dumps_indent(const ordered_json& v) {
    std::string out;
    dump_indent(v, out, 0);
    return out;
}

std::string error_json(std::string_view message) {
    ordered_json env;
    env["error"] = std::string(message);
    return py_dumps(env);
}

}  // namespace sa_core
