#include "sa_core/env_store.h"

#include <mutex>

#include "sa_core/atomic_io.h"
#include "sa_core/json_wire.h"
#include "sa_core/paths.h"
#include "sa_core/strings.h"
#include "sa_core/utf8.h"

namespace sa_core {
namespace env_store {
namespace {

std::string strip_ws(const std::string& s) {
    // Python str.strip(): ASCII whitespace set == sa_core::str::trim.
    return str::trim(s);
}

}  // namespace

nlohmann::ordered_json read_json_file(const std::string& path) {
    auto raw = paths::read_bytes(path);
    if (!raw) return nlohmann::ordered_json::object();
    auto text = decode_utf8_sig_strict(*raw);  // utf-8-sig; invalid -> nullopt
    if (!text) return nlohmann::ordered_json::object();
    std::string body = strip_ws(*text);
    if (body.empty()) return nlohmann::ordered_json::object();  // "" -> {}
    auto parsed = nlohmann::ordered_json::parse(body, nullptr, false);
    if (parsed.is_discarded() || !parsed.is_object()) {
        return nlohmann::ordered_json::object();  // loads() raise / non-dict -> {}
    }
    return parsed;
}

std::string env_path(const std::string& editor_root) {
    return paths::join(editor_root, "editor_env.json");
}

nlohmann::ordered_json read_editor_env(const std::string& editor_root) {
    return read_json_file(env_path(editor_root));
}

std::string read_workshop_override(const std::string& editor_root) {
    auto data = read_editor_env(editor_root);
    auto it = data.find("workshop_root");
    if (it == data.end() || !it->is_string()) return {};
    return strip_ws(it->get<std::string>());
}

nlohmann::ordered_json atomic_merge_write(const std::string& path,
                                          const nlohmann::ordered_json& extra) {
    // env_store.py:96 _WRITE_LOCK：读-合并-写整体串行，否则并发 HTTP 端点的
    // 后写者会用读过时的快照覆盖对方刚写入的键。
    static std::mutex write_lock;
    std::lock_guard<std::mutex> lk(write_lock);
    auto merged = read_json_file(path);
    if (extra.is_object()) {
        for (auto it = extra.begin(); it != extra.end(); ++it) {
            merged[it.key()] = it.value();  // existing keys keep their position
        }
    }
    write_text_atomic(path, py_dumps_indent(merged));
    return merged;
}

nlohmann::ordered_json merge_editor_env(const std::string& editor_root,
                                        const nlohmann::ordered_json& extra) {
    return atomic_merge_write(env_path(editor_root), extra);
}

}  // namespace env_store
}  // namespace sa_core
