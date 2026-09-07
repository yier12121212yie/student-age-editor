// server/services/mods_routes.cpp — /api/mods* (port of api.py:872-946).
//
// A15: list_mods is TTL-cached in state.cpp; create/select/delete flow through
// select_mod which invalidates it (delete additionally clears the selection).
// Workshop roots are P2 placeholders (empty list), so the delete guard and the
// select sandbox only see the workspace root for now — the code shape is there.
#include <ctime>
#include <filesystem>
#include <regex>
#include <string>

#include "sa_core/json_wire.h"
#include "sa_core/paths.h"
#include "sa_core/strings.h"
#include "sa_core/utf8.h"
#include "sa_core/util.h"
#include "server/api_router.h"
#include "server/cfg_store.h"
#include "server/httpd.h"
#include "server/perf.h"
#include "server/state.h"

namespace sa {
namespace {

namespace cs = sa_core::paths;

std::string body_str(const json& body, const char* key) {
    if (!body.is_object()) return {};
    auto it = body.find(key);
    if (it == body.end() || it->is_null()) return {};
    if (it->is_string()) return it->get<std::string>();
    return sa_core::py_str(*it);  // str(x) coercion like `(_body or {}).get(k) or ""`
}

// datetime.now().isoformat(timespec="seconds") — local time, second precision.
std::string now_iso_seconds() {
    std::time_t t = std::time(nullptr);
    std::tm tm{};
#ifdef _WIN32
    localtime_s(&tm, &t);
#else
    localtime_r(&t, &tm);
#endif
    char buf[32];
    std::snprintf(buf, sizeof(buf), "%04d-%02d-%02dT%02d:%02d:%02d", tm.tm_year + 1900,
                  tm.tm_mon + 1, tm.tm_mday, tm.tm_hour, tm.tm_min, tm.tm_sec);
    return buf;
}

}  // namespace

void register_mods_routes(Router& r) {
    // GET /api/mods — api.py:872-874.
    r.get(R"(/api/mods)", [](const Req&) -> Resp {
        json body;
        body["mods"] = list_mods();
        {
            std::lock_guard<std::mutex> lk(STATE().mu_);
            body["selected"] = STATE().mod_name;
        }
        return Resp::Json(200, std::move(body));
    });

    // POST /api/mods/select — api.py:876-899. Explicit root must stay inside
    // the workspace (or a workshop root, P2); comparisons go through normcase
    // because Windows paths are case-insensitive.
    r.post(R"(/api/mods/select)", [](const Req& req) -> Resp {
        std::string name = body_str(req.body, "name");
        std::string root = body_str(req.body, "root");
        if (!root.empty()) {
            std::string ws;
            {
                std::lock_guard<std::mutex> lk(STATE().mu_);
                ws = STATE().workspace_root;
            }
            if (ws.empty()) ws = cs::join(sa_core::paths::path_to_utf8(std::filesystem::current_path()), "mods");
            std::vector<std::string> bases;
            bases.push_back(cs::abs_path(ws));
            for (const auto& w : workshop_mods_roots()) bases.push_back(cs::abs_path(w));
            std::string abs_root = cs::abs_path(root);
            std::string norm_root = cs::normcase(abs_root);
            bool inside = false;
            for (const auto& b : bases) {
                std::string nb = cs::normcase(b);
                if (norm_root == nb) {
                    inside = true;
                    break;
                }
                std::string prefix = nb;
                if (!prefix.empty() && prefix.back() != '\\' && prefix.back() != '/') prefix += "\\";
                if (norm_root.size() > prefix.size() &&
                    norm_root.compare(0, prefix.size(), prefix) == 0) {
                    inside = true;
                    break;
                }
            }
            if (!inside) {
                return Resp::Json(400,
                                  json{{"error", "mod root must be inside workspace or workshop dir"}});
            }
            if (cs::is_dir(abs_root)) {
                std::string mod_name =
                    !name.empty() ? name : cs::basename(cs::abs_path(root));
                json body;
                body["mod"] = select_mod(mod_name, abs_root);
                return Resp::Json(200, std::move(body));
            }
            return Resp::Json(404, json{{"error", "mod dir not found: " + root}});
        }
        json mods = list_mods();
        for (const auto& m : mods) {
            if (m.value("name", "") == name) {
                json body;
                body["mod"] = select_mod(name, m.value("root", ""));
                return Resp::Json(200, std::move(body));
            }
        }
        return Resp::Json(404, json{{"error", "mod not found: " + name}});
    });

    // POST /api/mods/create — api.py:901-926. Title doubles as the directory
    // name, so it must survive the path-illegal character screen.
    r.post(R"(/api/mods/create)", [](const Req& req) -> Resp {
        std::string title = sa_core::str::trim(body_str(req.body, "title"));
        std::string desc = sa_core::str::trim(body_str(req.body, "desc"));
        if (title.empty()) return Resp::Json(400, json{{"error", "title required"}});
        static const std::regex illegal(R"([\\/:*?"<>|\x00-\x1f])");
        if (std::regex_search(title, illegal) || title == "." || title == "..") {
            return Resp::Json(400, json{{"error",
                                         "标题含非法字符，不能用作目录名: " +
                                             sa_core::py_repr_str(title)}});
        }
        std::string base;
        {
            std::lock_guard<std::mutex> lk(STATE().mu_);
            base = STATE().workspace_root;
        }
        if (base.empty()) base = cs::join(sa_core::paths::path_to_utf8(std::filesystem::current_path()), "mods");
        std::string mod_dir = cs::join(base, title);
        std::string abs_base = cs::abs_path(base) + "\\";
        if (cs::abs_path(mod_dir).size() <= abs_base.size() ||
            cs::normcase(cs::abs_path(mod_dir)).compare(0, cs::normcase(abs_base).size(),
                                                        cs::normcase(abs_base)) != 0) {
            return Resp::Json(400, json{{"error", "title escapes workspace"}});
        }
        if (cs::exists(mod_dir)) {
            return Resp::Json(400, json{{"error", "mod already exists: " + title}});
        }
        cs::create_dirs(cs::join(cs::join(mod_dir, "Cfgs"), "zh-cn"));
        json manifest;
        manifest["title"] = title;
        manifest["description"] = desc;
        manifest["version"] = "1.0.0";
        manifest["created_at"] = now_iso_seconds();
        // Python writes the manifest with json.dump(indent=2, ensure_ascii=False)
        // in text mode; Windows text mode translates \n to \r\n, so the on-disk
        // bytes are CRLF (selftest only re-reads it as JSON, which is tolerant).
        std::string text = sa_core::py_dumps_indent(manifest);
        std::string crlf;
        crlf.reserve(text.size() + 16);
        for (char c : text) {
            if (c == '\n') crlf += "\r\n";
            else crlf += c;
        }
        cs::write_bytes_simple(cs::join(mod_dir, "manifest.json"), crlf);
        json body;
        body["mod"] = select_mod(title, mod_dir);
        return Resp::Json(200, std::move(body));
    });

    // POST /api/mods/delete — api.py:928-946.
    r.post(R"(/api/mods/delete)", [](const Req& req) -> Resp {
        std::string name = body_str(req.body, "name");
        json mods = list_mods();
        for (const auto& m : mods) {
            if (m.value("name", "") != name) continue;
            std::string abs_root = cs::abs_path(m.value("root", ""));
            for (const auto& w : workshop_mods_roots()) {
                std::string base = cs::abs_path(w) + "\\";
                if (cs::normcase(abs_root).size() > cs::normcase(base).size() &&
                    cs::normcase(abs_root).compare(0, cs::normcase(base).size(),
                                                   cs::normcase(base)) == 0) {
                    return Resp::Json(400, json{{"error", "创意工坊订阅内容请在 Steam 客户端取消订阅，不能直接删除"}});
                }
            }
            cs::remove_tree(m.value("root", ""));  // rmtree(ignore_errors=True)
            {
                std::lock_guard<std::mutex> lk(STATE().mu_);
                if (STATE().mod_name == name) {
                    STATE().mod_root.clear();
                    STATE().mod_name.clear();
                }
            }
            json body;
            body["ok"] = true;
            return Resp::Json(200, std::move(body));
        }
        return Resp::Json(404, json{{"error", "mod not found"}});
    });
}

}  // namespace sa
