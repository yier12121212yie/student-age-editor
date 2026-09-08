// wip/P3b — see p3b_resource_pack.h (port of resource_pack.py).
#include "p3b_resource_pack.h"

#include <algorithm>
#include <cctype>
#include <cstdio>
#include <cstdlib>
#include <ctime>
#include <functional>
#include <set>
#include <string_view>
#include <vector>

#include "p3b_fs_tools.h"
#include "p3b_support.h"
#include "sa_core/atomic_io.h"
#include "sa_core/json_wire.h"
#include "sa_core/paths.h"
#include "sa_core/strings.h"
#include "sa_core/utf8.h"
#include "sa_core/util.h"
#include "server/api_router.h"
#include "server/state.h"

namespace sa {
namespace p3b {
namespace resource_pack {
namespace {

namespace cs = sa_core::paths;

std::string env_or_empty(const char* name) {
    const char* v = std::getenv(name);
    return v ? std::string(v) : std::string();
}

bool is_pycache(const std::string& name) { return name == "__pycache__"; }

// list immediate sub-directories (os.listdir + isdir), sorted for determinism.
std::vector<std::string> list_subdirs(const std::string& root) {
    std::vector<std::string> out;
    if (root.empty() || !cs::is_dir(root)) return out;
    bool ok = false;
    const std::vector<std::string> names = cs::listdir_sorted(root, &ok);
    if (!ok) return out;
    for (const auto& name : names) {
        if (is_pycache(name)) continue;
        if (cs::is_dir(cs::join(root, name))) out.push_back(name);
    }
    return out;
}

// json.load(open(path, encoding=...)): utf8_sig strips a leading BOM (matches
// manifest reads in _install_zip); the non-sig form rejects a leading BOM the
// way Python's plain-utf-8 open + json.load do (BOM -> decode error -> {}).
json read_json_strict(const std::string& path, bool utf8_sig) {
    auto raw = cs::read_bytes(path);
    if (!raw) return json();
    std::optional<std::string> text = sa_core::decode_utf8_sig_strict(*raw);
    if (!text) return json();
    if (!utf8_sig && sa_core::starts_with_bom(*raw)) return json();
    json parsed = json::parse(*text, nullptr, false);
    if (parsed.is_discarded() || !parsed.is_object()) return json();
    return parsed;
}

// count .json files directly under `dir` (os.listdir, not recursive; Python
// does not isfile()-check, so a *directory* ending in .json counts too).
long long count_json_here(const std::string& dir) {
    long long n = 0;
    bool ok = false;
    for (const auto& f : cs::listdir_sorted(dir, &ok)) {
        if (!ok) break;
        if (sa_core::str::ends_with(f, ".json")) ++n;
    }
    return n;
}

// sum over os.walk(dir): all *.json files anywhere below.
long long count_json_recursive(const std::string& dir) {
    long long n = 0;
    std::vector<std::string> stack{dir};
    while (!stack.empty()) {
        const std::string cur = stack.back();
        stack.pop_back();
        bool ok = false;
        for (const auto& name : cs::listdir_sorted(cur, &ok)) {
            if (!ok) break;
            const std::string full = cs::join(cur, name);
            if (cs::is_dir(full)) {
                stack.push_back(full);
            } else if (sa_core::str::ends_with(name, ".json")) {
                ++n;
            }
        }
    }
    return n;
}

// Python `manifest.get(key) or default`
std::string or_str(const json& m, const char* key, const std::string& fallback) {
    if (m.is_object() && m.contains(key) && json_truthy(m.at(key))) {
        const json& v = m.at(key);
        return v.is_string() ? v.get<std::string>() : json_str(v);
    }
    return fallback;
}

json pack_entry(const std::string& pid, const std::string& d, bool builtin) {
    json manifest = read_json_strict(cs::join(d, "manifest.json"), false);
    if (!manifest.is_object()) manifest = json::object();
    const long long cnt = count_files_recursive(d);
    json e = json::object();
    e["id"] = pid;
    e["name"] = or_str(manifest, "name", pid);
    e["version"] = or_str(manifest, "version", "");
    e["description"] = or_str(manifest, "description", "");
    e["game_version"] = or_str(manifest, "game_version", "");
    e["created_at"] = or_str(manifest, "created_at", "");
    e["files"] = cnt;
    e["builtin"] = builtin;
    return e;
}

}  // namespace

std::string packs_root() {
    std::string root = env_or_empty("EDITOR_PACKS_ROOT");
    if (root.empty()) root = cs::join(cs::join(sa::editor_root(), "_cache"), "resource_packs");
    cs::create_dirs(root);  // best-effort (Python try/except)
    // alt-copy from <editor_root>/../data/resource_packs when the root has
    // no entries (os.listdir truthiness — files count too, unlike my subdir
    // probe below, so use raw listdir here). Deviation note: the Python
    // source path (backend/editor/data/resource_packs) never exists in this
    // repo, so the branch is a no-op in dev/golden runs; kept so a packaged
    // build behaves the same.
    const std::string alt =
        cs::join(cs::join(cs::dirname(sa::editor_root()), "data"), "resource_packs");
    bool root_empty = true;
    if (cs::is_dir(root)) {
        bool ok = false;
        root_empty = cs::listdir_sorted(root, &ok).empty();
    }
    if (root_empty && cs::is_dir(alt)) {
        std::function<void(const std::string&, const std::string&)> copy_tree =
            [&](const std::string& src, const std::string& dst) {
                cs::create_dirs(dst);
                bool ok = false;
                for (const auto& name : cs::listdir_sorted(src, &ok)) {
                    const std::string s = cs::join(src, name);
                    if (cs::is_dir(s)) {
                        copy_tree(s, cs::join(dst, name));
                    } else if (auto b = cs::read_bytes(s)) {
                        cs::write_bytes_simple(cs::join(dst, name), *b);
                    }
                }
            };
        bool ok = false;
        for (const auto& name : cs::listdir_sorted(alt, &ok)) {
            const std::string dst = cs::join(root, name);
            if (cs::exists(dst)) continue;
            const std::string src = cs::join(alt, name);
            if (cs::is_dir(src)) {
                copy_tree(src, dst);  // shutil.copytree
            } else if (auto b = cs::read_bytes(src)) {
                cs::write_bytes_simple(dst, *b);  // shutil.copy2
            }
        }
    }
    return root;
}

std::string system_packs_root() {
    // Python: only when sys.frozen (installed portable bundle). A native
    // build is never frozen -> "". EDITOR_SYSTEM_PACK_ROOT allows a packaged
    // build to inject the read-only root without code changes.
    std::string r = env_or_empty("EDITOR_SYSTEM_PACK_ROOT");
    return (!r.empty() && cs::is_dir(r)) ? r : std::string();
}

std::string meta_path() { return cs::join(packs_root(), "packs.json"); }

namespace {

json load_meta() {
    json data = read_json_strict(meta_path(), false);
    if (data.is_object() && data.contains("packs")) return data;
    json empty = json::object();
    empty["active"] = "";
    empty["packs"] = json::array();
    return empty;
}

void save_meta(const json& meta) {
    try {
        sa_core::write_text_atomic(meta_path(), sa_core::py_dumps_indent(meta));
    } catch (...) {
        // best-effort (Python try/except)
    }
}

std::string pack_dir(const std::string& pack_id) {
    if (pack_id.empty() || pack_id.find('/') != std::string::npos ||
        pack_id.find('\\') != std::string::npos || pack_id.find("..") != std::string::npos) {
        return {};
    }
    for (const std::string& root : {packs_root(), system_packs_root()}) {
        if (root.empty()) continue;
        const std::string d = cs::join(root, pack_id);
        if (cs::is_dir(d)) return d;
    }
    return {};
}

bool is_builtin(const std::string& pack_id) {
    const std::string root = system_packs_root();
    if (root.empty() || !cs::is_dir(cs::join(root, pack_id))) return false;
    return !cs::is_dir(cs::join(packs_root(), pack_id));
}

}  // namespace

std::string pack_id_from_name(const std::string& name) {
    std::string base = cs::basename(name);
    const size_t dot = base.rfind('.');
    if (dot != std::string::npos && dot != 0) base = base.substr(0, dot);
    base = py_strip(base);
    if (base.empty()) base = "pack_" + std::to_string(static_cast<long long>(std::time(nullptr)));
    std::string safe;
    for (unsigned char c : base) {
        if (std::isalnum(c) || c == '-' || c == '_' || c == '.') {
            safe.push_back(static_cast<char>(c));
        } else if (c >= 0x80) {
            safe.push_back(static_cast<char>(c));  // UTF-8 byte of a name
        } else {
            safe.push_back('_');
        }
    }
    safe = utf8_head(safe, 64);
    return safe.empty() ? std::string("pack") : safe;
}

json list_packs() {
    json meta = load_meta();
    const std::string wroot = packs_root();
    const std::string sroot = system_packs_root();
    const std::vector<std::string> existing_v = list_subdirs(wroot);
    const std::set<std::string> existing(existing_v.begin(), existing_v.end());
    const std::vector<std::string> builtin_v = sroot.empty() ? std::vector<std::string>()
                                                             : list_subdirs(sroot);
    const std::set<std::string> builtin_ids(builtin_v.begin(), builtin_v.end());

    json packs = json::array();
    if (!meta.contains("packs") || !meta.at("packs").is_array()) meta["packs"] = json::array();
    for (const auto& p : meta.at("packs")) {
        if (p.is_object() && p.contains("id") && p.at("id").is_string() &&
            existing.count(p.at("id").get<std::string>())) {
            packs.push_back(p);
        }
    }
    std::string active = meta.contains("active") && json_truthy(meta.at("active"))
                             ? json_str(meta.at("active"))
                             : std::string();
    if (!active.empty() && !existing.count(active) && !builtin_ids.count(active)) active.clear();
    std::set<std::string> ids;
    for (const auto& p : packs) {
        if (p.is_object() && p.contains("id") && p.at("id").is_string())
            ids.insert(p.at("id").get<std::string>());
    }
    for (const auto& pid : existing_v) {  // sorted (deviation: Python set order)
        if (ids.count(pid)) continue;
        if (is_pycache(pid)) continue;
        packs.push_back(pack_entry(pid, cs::join(wroot, pid), false));
    }
    for (const auto& pid : builtin_v) {
        if (ids.count(pid) || existing.count(pid)) continue;
        if (is_pycache(pid)) continue;
        packs.push_back(pack_entry(pid, cs::join(sroot, pid), true));
    }
    // First launch (no packs.json yet) with exactly one discovered pack:
    // default-activate it (installer-embedded official packs).
    if (!cs::is_file(meta_path()) && active.empty() && packs.size() == 1) {
        active = packs[0].value("id", "");
        json fresh = json::object();
        fresh["active"] = active;
        fresh["packs"] = packs;
        save_meta(fresh);
    }
    json out = json::object();
    out["active"] = active;
    out["packs"] = std::move(packs);
    return out;
}

json set_active(const std::string& id) {
    json meta = load_meta();
    if (!id.empty()) {
        if (pack_dir(id).empty()) throw PyValueError("pack not found: " + id);
    }
    meta["active"] = id;
    save_meta(meta);
    invalidate_preview_cache();
    // base.status = "idle": our BaseDataService seam is a no-op until wave 3.
    return meta;
}

namespace {

// Shared install: validate member safety -> extract -> backfill manifest ->
// register metadata. `z` is an already-open archive.
json install_zip(const ZipReader& z, const std::string& filename) {
    const std::vector<std::string> names = z.names();
    if (names.empty()) throw PyValueError("empty zip");
    for (const auto& n : names) {
        if (!n.empty() && n[0] == '/') throw PyValueError("illegal entry: " + py_repr(json(n)));
        if (n.find("..") != std::string::npos || n.find(':') != std::string::npos) {
            throw PyValueError("illegal entry: " + py_repr(json(n)));
        }
    }
    std::string pack_id = pack_id_from_name(filename);
    const std::string base_id = pack_id;
    const std::string root = packs_root();
    int i = 1;
    while (cs::exists(cs::join(root, pack_id))) {
        pack_id = base_id + "_" + std::to_string(i);
        ++i;
    }
    const std::string dest = cs::join(root, pack_id);
    cs::create_dirs(dest);
    if (!z.extract_all(dest)) {
        cs::remove_tree(dest);
        throw PyValueError("extract failed: zip extraction error");
    }
    const std::string mp = cs::join(dest, "manifest.json");
    json manifest;
    if (cs::is_file(mp)) {
        manifest = read_json_strict(mp, true);  // utf-8-sig
        if (!manifest.is_object()) manifest = json::object();
    } else {
        manifest = json::object();
    }
    if (!manifest.contains("name")) manifest["name"] = pack_id;
    if (!manifest.contains("version")) manifest["version"] = "1.0.0";
    if (!manifest.contains("description")) manifest["description"] = "";
    if (!manifest.contains("created_at")) manifest["created_at"] = local_time_seconds();
    try {
        sa_core::write_text_atomic(mp, sa_core::py_dumps_indent(manifest));
    } catch (...) {
    }
    // has_content: named probes first, then any *.json anywhere.
    bool has_content = false;
    for (const char* probe :
         {"aa_index.json", "base_data.json", "dicts.json", "game_schema.json", "manifest.json"}) {
        if (cs::is_file(cs::join(dest, probe))) {
            has_content = true;
            break;
        }
    }
    if (!has_content) has_content = has_any_json_recursive(dest);
    if (!has_content) {
        cs::remove_tree(dest);
        throw PyValueError("zip missing valid resources");
    }
    json meta = load_meta();
    json filtered = json::array();
    if (meta.contains("packs") && meta.at("packs").is_array()) {
        for (const auto& p : meta.at("packs")) {
            if (!(p.is_object() && p.contains("id") && json_str(p.at("id")) == pack_id)) {
                filtered.push_back(p);
            }
        }
    }
    json entry = json::object();
    entry["id"] = pack_id;
    entry["name"] = or_str(manifest, "name", pack_id);
    entry["version"] = or_str(manifest, "version", "");
    entry["description"] = or_str(manifest, "description", "");
    entry["game_version"] = or_str(manifest, "game_version", "");
    entry["created_at"] = or_str(manifest, "created_at", "");
    entry["files"] = count_files_recursive(pack_dir(pack_id));
    filtered.push_back(entry);
    meta["packs"] = filtered;
    if (!json_truthy(meta.contains("active") ? meta.at("active") : json())) {
        meta["active"] = pack_id;
    }
    save_meta(meta);
    json result = json::object();
    result["id"] = pack_id;
    result["manifest"] = manifest;
    result["meta"] = meta;
    return result;
}

}  // namespace

json install_pack_bytes(std::string_view zip_bytes, const std::string& filename) {
    if (zip_bytes.empty() || zip_bytes.size() < 4) throw PyValueError("empty zip");
    if (zip_bytes.size() > 500ull * 1024 * 1024) throw PyValueError("zip too large (>500MB)");
    auto z = ZipReader::open_bytes(zip_bytes);
    if (!z) throw PyValueError("invalid zip: not a zip archive");
    return install_zip(*z, filename);
}

json install_pack_from_path(const std::string& path, const std::string& filename) {
    if (path.empty() || !cs::is_file(path)) throw PyValueError("file not found: " + path);
    const long long size = cs::file_size(path);
    if (size <= 0) throw PyValueError("empty file");
    if (size > 4ll * 1024 * 1024 * 1024) throw PyValueError("zip too large (>4GB)");
    auto z = ZipReader::open_file(path);
    if (!z) throw PyValueError("invalid zip: not a zip archive");
    return install_zip(*z, filename.empty() ? cs::basename(path) : filename);
}

json uninstall_pack(const std::string& pack_id) {
    if (pack_id.empty() || pack_id.find('/') != std::string::npos ||
        pack_id.find('\\') != std::string::npos || pack_id.find("..") != std::string::npos) {
        throw PyValueError("invalid pack id");
    }
    if (is_builtin(pack_id)) throw PyValueError("内置资源包不可删除：" + pack_id);
    const std::string d = cs::join(packs_root(), pack_id);
    if (!cs::is_dir(d)) throw PyValueError("pack not found: " + pack_id);
    cs::remove_tree(d);
    json meta = load_meta();
    json filtered = json::array();
    if (meta.contains("packs") && meta.at("packs").is_array()) {
        for (const auto& p : meta.at("packs")) {
            if (!(p.is_object() && p.contains("id") && json_str(p.at("id")) == pack_id)) {
                filtered.push_back(p);
            }
        }
    }
    meta["packs"] = filtered;
    if (meta.contains("active") && json_str(meta.at("active")) == pack_id) {
        if (filtered.empty() || !filtered[0].is_object() || !filtered[0].contains("id")) {
            meta["active"] = "";
        } else {
            meta["active"] = json_str(filtered[0].at("id"));
        }
    }
    save_meta(meta);
    return meta;
}

json get_pack_info(const std::string& pack_id) {
    const std::string d = pack_dir(pack_id);
    if (d.empty()) return json();
    json manifest = read_json_strict(cs::join(d, "manifest.json"), false);
    if (!manifest.is_object()) manifest = json::object();
    json stats = json::object();
    stats["total_files"] = 0;
    stats["has_aa"] = cs::is_file(cs::join(d, "aa_index.json"));
    stats["has_base"] = cs::is_file(cs::join(d, "base_data.json"));
    const std::string cfgs_dir = cs::join(cs::join(d, "Cfgs"), "zh-cn");
    long long has_cfgs = 0;
    if (cs::is_dir(cfgs_dir)) {
        has_cfgs = count_json_here(cfgs_dir);  // os.listdir, not recursive
    } else if (cs::is_dir(cs::join(d, "Cfgs"))) {
        has_cfgs = count_json_recursive(cs::join(d, "Cfgs"));  // os.walk Cfgs/
    }
    stats["has_cfgs"] = has_cfgs;
    stats["total_files"] = count_files_recursive(d);
    json out = json::object();
    out["id"] = pack_id;
    out["manifest"] = manifest;
    out["stats"] = stats;
    out["dir"] = d;
    return out;
}

}  // namespace resource_pack
}  // namespace p3b
}  // namespace sa
