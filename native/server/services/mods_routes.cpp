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
#include "server/services/p3b_resource_pack.h"  // p3b::PyValueError（400 信封）
#include "server/services/p3b_support.h"        // p3b::ZipReader / b64_encode
#include "server/services/file_transfer.h"      // 自托管大模组包：直传落盘记录
#include "server/services/upload_staging.h"     // 网页版 base64 zip 上传暂存
#include "server/services/zip_store_writer.h"   // store-only zip 打包
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

// ---------------------------------------------------------------------------
// 模组打包 / 导入（网页端上传下载）
// ---------------------------------------------------------------------------

// 允许解压的条目名：拒绝空、绝对路径、盘符/ADS、'..'（与资源包安装同款规则）。
bool mod_zip_entry_safe(const std::string& n) {
    if (n.empty()) return false;
    if (n[0] == '/' || n[0] == '\\') return false;
    if (n.find(':') != std::string::npos) return false;
    if (n.find("..") != std::string::npos) return false;
    return true;
}

// 若所有条目都在同一顶层目录下，返回 "top/"（'/' 分隔），否则 ""。常见于把整个
// 文件夹拖进压缩工具；不剥掉这层会得到 <mod>/<folder>/Cfgs 的错位结构。
std::string single_top_dir(const std::vector<std::string>& names) {
    std::string prefix;
    for (const auto& raw : names) {
        std::string n = raw;
        std::replace(n.begin(), n.end(), '\\', '/');
        auto pos = n.find('/');
        if (pos == std::string::npos) return "";  // 顶层直接是文件 -> 无统一前缀
        std::string top = n.substr(0, pos);
        if (prefix.empty()) prefix = top;
        else if (prefix != top) return "";
    }
    return prefix.empty() ? std::string() : prefix + "/";
}

std::string strip_zip_ext(std::string s) {
    auto p = s.find_last_of('.');
    if (p != std::string::npos && p > 0 &&
        sa_core::str::lower(s.substr(p)) == ".zip")
        s = s.substr(0, p);
    return s;
}

// 目录名净化（与 /api/mods/create 同款非法字符集）。
std::string safe_mod_dir_name(std::string s) {
    s = sa_core::str::trim(s);
    static const std::regex illegal(R"([\\/:*?"<>|\x00-\x1f])");
    s = std::regex_replace(s, illegal, std::string("_"));
    if (s == "." || s == "..") s.clear();
    return s;
}

// 模组 zip -> workspace 下的新目录；返回该模组信息。失败抛 p3b::PyValueError。
json import_mod_zip(const std::string& path, const std::string& filename) {
    if (path.empty() || !cs::is_file(path)) throw p3b::PyValueError("file not found: " + path);
    auto z = p3b::ZipReader::open_file(path);
    if (!z) throw p3b::PyValueError("invalid zip: File is not a zip file");
    const std::vector<std::string> names = z->names();
    if (names.empty()) throw p3b::PyValueError("empty zip");
    for (const auto& n : names) {
        if (!mod_zip_entry_safe(n))
            throw p3b::PyValueError("illegal entry: " + sa_core::py_repr_str(n));
    }

    // 顶层目录（若有）先算出来：manifest 可能在其内（压缩整个文件夹的形态）。
    const std::string top = single_top_dir(names);
    const std::string manifest_entry =
        top.empty() ? std::string("manifest.json") : top + "manifest.json";

    // 目录名优先级：manifest 标题 > 压缩包文件名 > imported_mod
    std::string mod_name;
    if (z->has(manifest_entry)) {
        if (auto m = z->read(manifest_entry)) {
            json mf = json::parse(*m, nullptr, false);
            if (mf.is_object()) {
                std::string t = body_str(mf, "title");
                if (t.empty()) t = body_str(mf, "name");
                mod_name = safe_mod_dir_name(t);
            }
        }
    }
    if (mod_name.empty()) mod_name = safe_mod_dir_name(strip_zip_ext(filename));
    if (mod_name.empty()) mod_name = "imported_mod";

    std::string base;
    {
        std::lock_guard<std::mutex> lk(STATE().mu_);
        base = STATE().workspace_root;
    }
    if (base.empty())
        base = cs::join(cs::path_to_utf8(std::filesystem::current_path()), "mods");

    std::string unique = mod_name;
    for (int i = 1; cs::exists(cs::join(base, unique)); ++i)
        unique = mod_name + "_" + std::to_string(i);
    const std::string dest = cs::join(base, unique);

    cs::create_dirs(dest);
    bool ok = true;
    for (const auto& raw : names) {
        std::string rel = raw;
        std::replace(rel.begin(), rel.end(), '\\', '/');
        if (!top.empty()) {
            if (rel.rfind(top, 0) != 0) continue;
            rel = rel.substr(top.size());
        }
        if (rel.empty() || rel.back() == '/') continue;  // 目录条目
        if (!mod_zip_entry_safe(rel)) { ok = false; break; }
        auto data = z->read(raw);
        if (!data) { ok = false; break; }
        std::string out = cs::join(dest, rel);
        // UTF-8-safe parent extraction: std::filesystem::path(std::string) uses
        // the ANSI code page on Windows and throws for non-ASCII resource names
        // (e.g. 贴图/配乐), so route through the u8 helpers like every other path.
        cs::create_dirs(cs::dirname(out));
        if (!cs::write_bytes_simple(out, *data)) { ok = false; break; }
    }
    if (!ok) {
        cs::remove_tree(dest);
        throw p3b::PyValueError("extract failed: zip extraction error");
    }

    const bool has_manifest = cs::is_file(cs::join(dest, "manifest.json"));
    const bool has_cfgs = cs::is_dir(cs::join(cs::join(dest, "Cfgs"), "zh-cn"));
    if (!has_manifest && !has_cfgs) {
        cs::remove_tree(dest);
        throw p3b::PyValueError("zip missing Cfgs/zh-cn or manifest.json");
    }
    json manifest;
    if (has_manifest) {
        auto raw = cs::read_bytes(cs::join(dest, "manifest.json"));
        if (raw) {
            json parsed = json::parse(std::string(*raw), nullptr, false);
            if (parsed.is_object()) manifest = parsed;
        }
    }
    if (!manifest.is_object()) manifest = json::object();
    if (!manifest.contains("title") || !manifest["title"].is_string() ||
        manifest["title"].get<std::string>().empty())
        manifest["title"] = unique;
    if (!manifest.contains("version")) manifest["version"] = "1.0.0";
    if (!manifest.contains("description")) manifest["description"] = "";
    if (!manifest.contains("created_at")) manifest["created_at"] = now_iso_seconds();
    cs::write_bytes_simple(cs::join(dest, "manifest.json"),
                           sa_core::py_dumps_indent(manifest));

    json mod = select_mod(unique, dest);
    json out;
    out["ok"] = true;
    out["mod"] = std::move(mod);
    return out;
}

// 当前/指定模组 -> store-only zip（base64 返回，供浏览器下载）。
json export_mod_zip(const std::string& req_name) {
    std::string name = req_name;
    std::string root;
    if (name.empty()) {
        std::lock_guard<std::mutex> lk(STATE().mu_);
        name = STATE().mod_name;
        root = STATE().mod_root;
    } else {
        for (const auto& m : list_mods())
            if (m.value("name", "") == name) { root = m.value("root", ""); break; }
    }
    if (name.empty() || root.empty() || !cs::is_dir(root))
        throw p3b::PyValueError("mod not found: " +
                                (name.empty() ? std::string("(none)") : name));

    std::vector<zipstore::Entry> entries;
    // to_path, not path(root): root is UTF-8 and may contain a Chinese mod name;
    // the ANSI narrow constructor would throw before any file is packed.
    const std::filesystem::path base = cs::to_path(root);
    std::error_code ec;
    for (auto it = std::filesystem::recursive_directory_iterator(base, ec);
         !ec && it != std::filesystem::recursive_directory_iterator(); it.increment(ec)) {
        if (it->is_directory(ec)) continue;
        if (!it->is_regular_file(ec)) continue;
        std::error_code rel_ec;
        auto rel = std::filesystem::relative(it->path(), base, rel_ec);
        if (rel_ec) continue;
        // generic_u8string, not generic_string(): the latter narrows through the
        // ANSI code page on Windows, so 贴图/配乐 names become GBK mojibake that
        // no longer reads back as UTF-8. generic_u8string keeps '/' separators and
        // the original UTF-8 bytes, so the exported zip re-imports identically.
        const std::u8string rel_u8 = rel.generic_u8string();
        const std::string relname(reinterpret_cast<const char*>(rel_u8.data()),
                                  rel_u8.size());
        // 不打包编辑器本地历史（体积大、无分发价值）。
        if (relname.rfind(".editor_history/", 0) == 0) continue;
        auto bytes = cs::read_bytes(cs::path_to_utf8(it->path()));
        if (!bytes) continue;
        entries.push_back({relname, std::string(*bytes)});
    }
    if (entries.empty()) throw p3b::PyValueError("mod is empty: " + name);

    std::string zip;
    if (!zipstore::build(entries, zip)) throw p3b::PyValueError("archive too large");
    json out;
    out["filename"] = name + ".zip";
    out["data_base64"] = p3b::b64_encode(zip);
    out["size"] = static_cast<long long>(zip.size());
    out["entries"] = static_cast<long long>(entries.size());
    return out;
}

}  // namespace

void register_mods_routes(Router& r) {
    // GET /api/mods — api.py:872-874. `?with_counts=1` additionally returns
    // cfg_counts {mod_name: {cfg_name: record_count}} for the TUI tree (and a
    // workspace field with the resolved workspace root); both are additive and
    // omitted unless asked for, so the plain response stays contract-identical.
    r.get(R"(/api/mods)", [](const Req& req) -> Resp {
        json body;
        body["mods"] = list_mods();
        {
            std::lock_guard<std::mutex> lk(STATE().mu_);
            body["selected"] = STATE().mod_name;
            body["workspace"] = STATE().workspace_root;
        }
        if (req.query.count("with_counts")) {
            json counts_all = json::object();
            for (const auto& m : body["mods"]) {
                const std::string root = m.value("root", "");
                const std::string cfg_dir =
                    sa_core::paths::join(sa_core::paths::join(root, "Cfgs"), "zh-cn");
                bool ok = false;
                auto names = sa_core::paths::listdir_sorted(cfg_dir, &ok);
                if (!ok) continue;
                json counts = json::object();
                for (const auto& f : names) {
                    if (f.size() < 5 || f.compare(f.size() - 5, 5, ".json") != 0) continue;
                    auto raw = sa_core::paths::read_bytes(sa_core::paths::join(cfg_dir, f));
                    if (!raw) continue;
                    auto text = sa_core::decode_utf8_sig_strict(*raw);
                    if (!text) continue;
                    json parsed = json::parse(*text, nullptr, false);
                    if (parsed.is_discarded() || !parsed.is_object()) continue;
                    counts[f.substr(0, f.size() - 5)] = parsed.size();
                }
                if (!counts.empty()) counts_all[m.value("name", "")] = std::move(counts);
            }
            body["cfg_counts"] = std::move(counts_all);
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
                // Containment suffix must be the HOST separator (Python:
                // startswith(normcase(b) + os.sep), api.py:889). normcase maps
                // '/'->'\' only on Windows, so a hardcoded "\\" made every POSIX
                // child of a workspace/workshop base read as an escape and the
                // workshop-root select answer a constant 400 (W4-2 WSL gate).
#ifdef _WIN32
                if (!prefix.empty() && prefix.back() != '\\' && prefix.back() != '/') prefix += "\\";
#else
                if (!prefix.empty() && prefix.back() != '/') prefix += "/";
#endif
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
        // Host separator (Python: abspath(mod_dir).startswith(abspath(base)+os.sep),
        // api.py:913); a literal "\\" made every POSIX create report "title escapes
        // workspace" (W4-2 WSL gate).
#ifdef _WIN32
        std::string abs_base = cs::abs_path(base) + "\\";
#else
        std::string abs_base = cs::abs_path(base) + "/";
#endif
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
                // Workshop protection prefix must use the host separator
                // (Python: abs_root.startswith(abspath(r)+os.sep), api.py:936).
                // The literal "\\" never matched a POSIX subscription path, so on
                // Linux a workshop dir slipped past the guard and the rmtree below
                // deleted live Steam content (destructive; W4-2 WSL gate).
#ifdef _WIN32
                std::string base = cs::abs_path(w) + "\\";
#else
                std::string base = cs::abs_path(w) + "/";
#endif
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

    // POST /api/mods/export — 把当前/指定模组打包成 zip（store-only），以 base64
    // 返回给前端落盘下载。网页/桌面同一契约（浏览器拿不到本机路径）。
    r.post(R"(/api/mods/export)", [](const Req& req) -> Resp {
        try {
            return Resp::Json(200, export_mod_zip(body_str(req.body, "name")));
        } catch (const p3b::PyValueError& e) {
            return Resp::Json(400, json{{"error", e.what()}});
        }
    });

    // POST /api/mods/import_path — 本机 zip 路径导入（桌面；网关封禁此端点）。
    r.post(R"(/api/mods/import_path)", [](const Req& req) -> Resp {
        const std::string path = body_str(req.body, "path");
        if (path.empty()) return Resp::Json(400, json{{"error", "path required"}});
        try {
            return Resp::Json(200, import_mod_zip(path, body_str(req.body, "filename")));
        } catch (const p3b::PyValueError& e) {
            return Resp::Json(400, json{{"error", e.what()}});
        }
    });

    // POST /api/mods/import_upload — 网页版：浏览器把 zip 以 {filename,
    // data_base64} 上传，落临时文件后走与 import_path 完全相同的导入管线。
    r.post(R"(/api/mods/import_upload)", [](const Req& req) -> Resp {
        try {
            return upload::install_from_upload(
                req,
                [](const std::string& path, const std::string& filename) {
                    return import_mod_zip(path, filename);
                },
                "mod.zip");
        } catch (const p3b::PyValueError& e) {
            return Resp::Json(400, json{{"error", e.what()}});
        }
    });

    // POST /api/mods/import_staged — 自托管网页版**大模组包**（带贴图/配乐等
    // 资源，动辄数百 MB）导入：base64 的 *_upload 通道受传输层请求体上限
    // （网关 max_body_bytes，默认 256 MiB）与浏览器内存双重压制，资源一多必
    // 失败。改走文件流转模块（模块 A）：浏览器把 zip 直传 COS 暂存区
    // （/api/v1/files/upload/request + PUT），/upload/complete 触发 Worker
    // 内网落盘（archived），最后拿 {file_id} 调本端点，对落盘文件跑与
    // import_path 完全相同的导入管线。本端点不接受调用方提供的本机路径
    // （import_path 被网关封禁的老原因），只认本账号数据根里已归档的流转
    // 记录，路径取自服务端自己写入的 local_path。
    r.post(R"(/api/mods/import_staged)", [](const Req& req) -> Resp {
        const std::string id = body_str(req.body, "file_id");
        if (id.empty()) return Resp::Json(400, json{{"error", "file_id required"}});
        const json rec = file_transfer::find_record(editor_root(), id);
        if (!rec.is_object())
            return Resp::Json(404, json{{"error", "no such file: " + id}});
        const std::string st = rec.value("status", std::string());
        if (st != "archived" && st != "ready") {
            json out = {{"error", "file not archived yet"}, {"status", st}};
            if (st == "archiving" || st == "warming_up") out["retry_after"] = 5;
            return Resp::Json(409, std::move(out));
        }
        // local_path 由归档 Worker 生成（<data_root>/_cache/file_transfer/
        // objects/<id>），非调用方可控输入；记录里的 name 也经 sanitize_name。
        const std::string local = rec.value("local_path", std::string());
        if (local.empty() || !cs::is_file(local))
            return Resp::Json(409, json{{"error", "staged file missing on server: " + id}});
        std::string filename = rec.value("name", std::string());
        if (filename.empty()) filename = "mod.zip";
        try {
            return Resp::Json(200, import_mod_zip(local, filename));
        } catch (const p3b::PyValueError& e) {
            return Resp::Json(400, json{{"error", e.what()}});
        }
    });
}

}  // namespace sa
