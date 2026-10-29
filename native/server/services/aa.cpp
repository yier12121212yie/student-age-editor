// wip/P4/aa.cpp — see aa.h (port of the aa_* routes + decoded_pack.py).
#include "aa.h"

#include <algorithm>
#include <cctype>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <list>
#include <mutex>
#include <set>
#include <string>
#include <unordered_map>
#include <vector>

#include "sa_core/env_store.h"
#include "sa_core/http_client.h"
#include "sa_core/paths.h"
#include "sa_core/steam_paths.h"
#include "sa_core/strings.h"
#include "sa_core/utf8.h"
#include "sa_core/util.h"
#include "server/state.h"
#include "flow_assets.h"
#include "p3b_resource_pack.h"
#include "p4_util.h"
#include "plugin_service.h"  // 扩展合并：启用插件目录参与资源解析

namespace sa {
namespace {

namespace csp = sa_core::steam_paths;

// File-scope singletons (resettable from tests) for the lazily-loaded game
// index and the active decoded pack. Guarded separately; ensure_* never nests.
std::mutex g_aa_mu;
std::shared_ptr<AaIndex> g_idx;
bool g_idx_tried = false;
std::mutex g_pack_mu;
std::shared_ptr<DecodedPack> g_pack;
std::vector<std::string> g_pack_dirs;  // last resolved active dirs

bool ends_ci(const std::string& s, const std::string& suffix) {
    return sa_core::str::lower(s).size() >= suffix.size() &&
           sa_core::str::ends_with(sa_core::str::lower(s), suffix);
}

// Read a big-endian unsigned int of n bytes (image headers).
long long be(const std::string& b, size_t off, int n) {
    long long v = 0;
    for (int i = 0; i < n; ++i) v = (v << 8) | static_cast<unsigned char>(b[off + i]);
    return v;
}
long long le(const std::string& b, size_t off, int n) {
    long long v = 0;
    for (int i = n - 1; i >= 0; --i) v = (v << 8) | static_cast<unsigned char>(b[off + i]);
    return v;
}

// [w, h] from a decoded image header (png/jpeg/webp) — the pack's stand-in for
// PIL.Image.open().size (decoded_pack.tex_meta). nullopt when unrecognised.
std::optional<std::array<int, 2>> image_size(const std::string& b) {
    if (b.size() < 12) return std::nullopt;
    auto u = [&](size_t i) { return static_cast<unsigned char>(b[i]); };
    // PNG
    // PNG needs the IHDR chunk's width/height at offsets 16..23; a valid 8-byte
    // signature plus "IHDR" can be as short as 16 bytes, so guard >= 24 before
    // be() indexes the string unchecked.
    if (b.compare(0, 8, "\x89PNG\r\n\x1a\n", 0, 8) == 0 && b.size() >= 24 &&
        b.compare(12, 4, "IHDR") == 0) {
        return std::array<int, 2>{static_cast<int>(be(b, 16, 4)), static_cast<int>(be(b, 20, 4))};
    }
    // WEBP: RIFF....WEBP <fmt>
    if (b.compare(0, 4, "RIFF") == 0 && b.compare(8, 4, "WEBP") == 0) {
        std::string fmt = b.substr(12, 4);
        if (fmt == "VP8X" && b.size() >= 30) {
            long long w = le(b, 24, 3) + 1;
            long long h = le(b, 27, 3) + 1;
            return std::array<int, 2>{static_cast<int>(w), static_cast<int>(h)};
        }
        if (fmt == "VP8 " && b.size() >= 30) {
            long long w = le(b, 26, 2) & 0x3FFF;
            long long h = le(b, 28, 2) & 0x3FFF;
            return std::array<int, 2>{static_cast<int>(w), static_cast<int>(h)};
        }
        if (fmt == "VP8L" && b.size() >= 25) {
            long long bits = le(b, 21, 4);  // little-endian signature+14 width+14 height bits
            long long w = (bits & 0x3FFF) + 1;
            long long h = ((bits >> 14) & 0x3FFF) + 1;
            return std::array<int, 2>{static_cast<int>(w), static_cast<int>(h)};
        }
        return std::nullopt;
    }
    // JPEG: SOI then scan markers for SOF0..SOF15 (except DHT/JPG/DAC).
    if (u(0) == 0xFF && u(1) == 0xD8) {
        size_t i = 2;
        while (i + 9 < b.size()) {
            if (u(i) != 0xFF) { ++i; continue; }
            unsigned char m = u(i + 1);
            if (m >= 0xC0 && m <= 0xCF && m != 0xC4 && m != 0xC8 && m != 0xCC) {
                return std::array<int, 2>{static_cast<int>(be(b, i + 7, 2)),
                                          static_cast<int>(be(b, i + 5, 2))};
            }
            if (m == 0xD8 || m == 0x01 || (m >= 0xD0 && m <= 0xD7)) { i += 2; continue; }
            long long seg = be(b, i + 2, 2);
            i += 2 + static_cast<size_t>(seg);
        }
        return std::nullopt;
    }
    // AVIF (ISOBMFF with ftyp brand 'avif'/'avis' and 'ispe' box)
    if (b.size() >= 16 && b.compare(4, 4, "ftyp") == 0) {
        size_t limit = std::min(b.size(), size_t(4096));
        auto pos = b.find("ispe", 0);
        if (pos != std::string::npos && pos + 16 <= b.size() && pos < limit) {
            long long w = be(b, pos + 8, 4);
            long long h = be(b, pos + 12, 4);
            if (w > 0 && h > 0) {
                return std::array<int, 2>{static_cast<int>(w), static_cast<int>(h)};
            }
        }
    }
    return std::nullopt;
}

}  // namespace

std::string norm_key(std::string_view object_name) {
    // splitext(name)[0] on the basename portion, then drop " #…" suffix, strip,
    // lower (unityfs_res._norm_key).
    auto [root, ext] = p4::split_ext(object_name);
    (void)ext;
    auto hash = root.find(" #");
    std::string key = hash == std::string::npos ? root : root.substr(0, hash);
    return sa_core::str::lower(p4::strip(key));
}

// ---- AaIndex -------------------------------------------------------------
bool AaIndex::load_from_json(const json& data) {
    tex_.clear(); aud_.clear(); txt_.clear(); texmeta_.clear(); bundles_.clear();
    partial_ = false;
    if (!data.is_object()) return false;
    auto v = data.find("v");
    if (v == data.end() || !v->is_number() || v->get<int>() != 3) return false;
    // A decoded pack's aa_index.json carries "decoded": true + key lists, NOT
    // [bundle, id] refs — that form is consumed by DecodedPack, not us.
    if (data.contains("decoded") && data.at("decoded").is_boolean() && data.at("decoded").get<bool>())
        return false;
    auto absorb = [&](const char* field, std::map<std::string, ResRef>& out) {
        auto it = data.find(field);
        if (it == data.end() || !it->is_object()) return;
        for (auto kt = it->begin(); kt != it->end(); ++kt) {
            const json& val = kt.value();
            if (!val.is_array() || val.size() < 2) continue;
            ResRef ref;
            if (val[0].is_string()) ref.bundle = val[0].get<std::string>();
            if (val[1].is_number_integer() || val[1].is_number_unsigned())
                ref.path_id = val[1].get<int64_t>();
            else if (val[1].is_number_float())
                ref.path_id = static_cast<int64_t>(val[1].get<double>());
            out.emplace(kt.key(), ref);  // keys already normalised by the tool
        }
    };
    absorb("tex", tex_);
    absorb("aud", aud_);
    absorb("txt", txt_);
    auto tm = data.find("texmeta");
    if (tm != data.end() && tm->is_object()) {
        for (auto it = tm->begin(); it != tm->end(); ++it) {
            if (it.value().is_array() && it.value().size() >= 2 && it.value()[0].is_number() &&
                it.value()[1].is_number()) {
                texmeta_[it.key()] = {it.value()[0].get<int>(), it.value()[1].get<int>()};
            }
        }
    }
    auto bs = data.find("bundles");
    if (bs != data.end() && bs->is_array()) {
        for (const auto& b : *bs) if (b.is_string()) bundles_.push_back(b.get<std::string>());
    }
    auto pc = data.find("partial");
    if (pc != data.end() && pc->is_boolean()) partial_ = pc->get<bool>();
    return true;
}

bool AaIndex::load_from_file(const std::string& path) {
    auto raw = sa_core::paths::read_bytes(path);
    if (!raw) return false;
    std::string body = *raw;
    if (body.size() >= 3 && static_cast<unsigned char>(body[0]) == 0xEF &&
        static_cast<unsigned char>(body[1]) == 0xBB && static_cast<unsigned char>(body[2]) == 0xBF)
        body = body.substr(3);
    auto parsed = json::parse(body, nullptr, false);
    if (parsed.is_discarded()) return false;
    return load_from_json(parsed);
}

int AaIndex::relocate_bundles(const std::string& aa_dir) {
    if (aa_dir.empty() || !sa_core::paths::is_dir(aa_dir)) return 0;
    // Collect all bundle files under aa_dir once (recursive, skip *_unpacked).
    std::map<std::string, std::string> by_lower_name;  // lower basename -> path
    std::vector<std::string> stack = {aa_dir};
    while (!stack.empty()) {
        std::string d = stack.back();
        stack.pop_back();
        std::error_code ec;
        for (auto& e : std::filesystem::directory_iterator(sa_core::paths::to_path(d), ec)) {
            if (ec) break;
            std::string name = sa_core::paths::path_to_utf8(e.path().filename());
            std::string full = sa_core::paths::path_to_utf8(e.path());
            if (e.is_directory()) {
                if (!sa_core::str::ends_with(name, "_unpacked")) stack.push_back(full);
            } else if (sa_core::str::ends_with(sa_core::str::lower(name), ".bundle")) {
                by_lower_name.emplace(sa_core::str::lower(name), full);
            }
        }
    }
    int relocated = 0;
    auto fix = [&](std::map<std::string, ResRef>& m) {
        for (auto& [k, ref] : m) {
            if (ref.bundle.empty() || sa_core::paths::is_file(ref.bundle)) continue;
            auto it = by_lower_name.find(sa_core::str::lower(p4::basename(ref.bundle)));
            if (it != by_lower_name.end()) {
                ref.bundle = it->second;
                ++relocated;
            }
        }
    };
    fix(tex_);
    fix(aud_);
    fix(txt_);
    // §8.2: after a relocation the recorded cabs (SerializedFile cross-refs) are
    // untrustworthy. C++ never decodes so it holds no cabs; the drop is a
    // no-op here but the contract is honoured by not relying on stale cabs.
    return relocated;
}

std::vector<std::string> AaIndex::tex_keys() const {
    std::vector<std::string> v;
    v.reserve(tex_.size());
    for (auto& [k, _] : tex_) v.push_back(k);
    return v;
}
std::vector<std::string> AaIndex::aud_keys() const {
    std::vector<std::string> v;
    v.reserve(aud_.size());
    for (auto& [k, _] : aud_) v.push_back(k);
    return v;
}
std::vector<std::string> AaIndex::txt_keys() const {
    std::vector<std::string> v;
    v.reserve(txt_.size());
    for (auto& [k, _] : txt_) v.push_back(k);
    return v;
}
bool AaIndex::has_tex(std::string key) const { return tex_.count(norm_key(key)) > 0; }
bool AaIndex::has_aud(std::string key) const { return aud_.count(norm_key(key)) > 0; }
bool AaIndex::has_txt(std::string key) const { return txt_.count(norm_key(key)) > 0; }
std::string AaIndex::tex_bundle(std::string key) const {
    auto it = tex_.find(norm_key(key));
    return it == tex_.end() ? std::string() : it->second.bundle;
}
std::string AaIndex::aud_bundle(std::string key) const {
    auto it = aud_.find(norm_key(key));
    return it == aud_.end() ? std::string() : it->second.bundle;
}
std::optional<std::array<int, 2>> AaIndex::tex_meta(std::string key) const {
    auto it = texmeta_.find(norm_key(key));
    if (it == texmeta_.end()) return std::nullopt;
    return std::array<int, 2>{it->second.first, it->second.second};
}
int64_t AaIndex::tex_path_id(std::string key) const {
    auto it = tex_.find(norm_key(key));
    return it == tex_.end() ? 0 : it->second.path_id;
}

// ---- DecodedPack ---------------------------------------------------------
void DecodedPack::refresh(const std::string& pack_dir) {
    refresh(pack_dir.empty() ? std::vector<std::string>{}
                             : std::vector<std::string>{pack_dir});
}

void DecodedPack::refresh(const std::vector<std::string>& pack_dirs) {
    {
        std::lock_guard<std::mutex> lk(data_mu_);
        if (pack_dirs == dirs_) return;
    }
    std::map<std::string, std::string> tex, aud;
    std::vector<std::string> txt;
    std::set<std::string> seen_txt;
    for (const std::string& pack_dir : pack_dirs) {
        if (pack_dir.empty()) continue;
        std::vector<std::string> scan_tex_dirs;
        const std::string tex_dir = sa_core::paths::join(pack_dir, "tex");
        if (sa_core::paths::is_dir(tex_dir)) scan_tex_dirs.push_back(tex_dir);
        const std::string bg_subdir = sa_core::paths::join(pack_dir, "bg");
        if (sa_core::paths::is_dir(bg_subdir)) scan_tex_dirs.push_back(bg_subdir);
        const std::string role_subdir = sa_core::paths::join(pack_dir, "role");
        if (sa_core::paths::is_dir(role_subdir)) scan_tex_dirs.push_back(role_subdir);
        if (scan_tex_dirs.empty() && sa_core::paths::is_dir(pack_dir)) {
            scan_tex_dirs.push_back(pack_dir);
        }

        std::map<std::string, uintmax_t> nk_sizes;
        for (const auto& td : scan_tex_dirs) {
            for (const auto& fn : sa_core::paths::listdir_sorted(td)) {
                auto [root, ext] = p4::split_ext(fn);
                std::string e = sa_core::str::lower(ext);
                if (e == ".webp" || e == ".png" || e == ".jpg" || e == ".jpeg" || e == ".avif") {
                    const std::string file_path = sa_core::paths::join(td, fn);
                    const std::string raw_k = sa_core::str::lower(root);
                    if (!tex.count(raw_k)) tex[raw_k] = file_path;

                    const std::string nk = norm_key(fn);
                    std::error_code sz_ec;
                    uintmax_t fsize = std::filesystem::file_size(sa_core::paths::to_path(file_path), sz_ec);
                    if (sz_ec) fsize = 0;

                    if (!tex.count(nk)) {
                        tex[nk] = file_path;
                        nk_sizes[nk] = fsize;
                    } else if (fsize > nk_sizes[nk]) {
                        // 优先保留大文件/高清全身立绘
                        tex[nk] = file_path;
                        nk_sizes[nk] = fsize;
                    }
                }
            }
        }
        const std::string aud_dir = sa_core::paths::join(pack_dir, "aud");
        if (sa_core::paths::is_dir(aud_dir)) {
            for (const auto& fn : sa_core::paths::listdir_sorted(aud_dir)) {
                auto [root, ext] = p4::split_ext(fn);
                std::string e = sa_core::str::lower(ext);
                if (e == ".ogg" || e == ".wav" || e == ".m4a" || e == ".mp3") {
                    const std::string k = sa_core::str::lower(root);
                    if (!aud.count(k)) aud[k] = sa_core::paths::join(aud_dir, fn);
                }
            }
        }
        // txt keys: prefer the decoded v3 aa_index.json list; else Cfgs/zh-cn scan.
        std::vector<std::string> dir_txt;
        auto raw = sa_core::paths::read_bytes(sa_core::paths::join(pack_dir, "aa_index.json"));
        if (raw) {
            std::string body = *raw;
            if (body.size() >= 3 && static_cast<unsigned char>(body[0]) == 0xEF) body = body.substr(3);
            auto j = json::parse(body, nullptr, false);
            if (!j.is_discarded() && j.is_object() && j.value("v", 0) == 3 &&
                j.contains("txt") && j.at("txt").is_array()) {
                for (const auto& k : j.at("txt"))
                    if (k.is_string()) dir_txt.push_back(k.get<std::string>());
            }
        }
        if (dir_txt.empty()) {
            const std::string zh = sa_core::paths::join(sa_core::paths::join(pack_dir, "Cfgs"), "zh-cn");
            if (sa_core::paths::is_dir(zh)) {
                for (const auto& f : sa_core::paths::listdir_sorted(zh))
                    if (ends_ci(f, ".json")) dir_txt.push_back(p4::split_ext(f).first);
                std::sort(dir_txt.begin(), dir_txt.end());
            }
        }
        for (auto& k : dir_txt) {
            if (seen_txt.insert(k).second) txt.push_back(std::move(k));
        }
    }
    std::lock_guard<std::mutex> lk(data_mu_);
    tex_ = std::move(tex);
    aud_ = std::move(aud);
    txt_ = std::move(txt);
    texsizes_.clear();
    dirs_ = pack_dirs;
}

bool DecodedPack::active() const {
    std::lock_guard<std::mutex> lk(data_mu_);
    return !dirs_.empty();
}

long long DecodedPack::tex_count() const {
    std::lock_guard<std::mutex> lk(data_mu_);
    return static_cast<long long>(tex_.size());
}
long long DecodedPack::aud_count() const {
    std::lock_guard<std::mutex> lk(data_mu_);
    return static_cast<long long>(aud_.size());
}
std::vector<std::string> DecodedPack::tex_keys() const {
    std::lock_guard<std::mutex> lk(data_mu_);
    std::vector<std::string> v;
    for (auto& [k, _] : tex_) v.push_back(k);
    std::sort(v.begin(), v.end());
    return v;
}
std::vector<std::string> DecodedPack::aud_keys() const {
    std::lock_guard<std::mutex> lk(data_mu_);
    std::vector<std::string> v;
    for (auto& [k, _] : aud_) v.push_back(k);
    std::sort(v.begin(), v.end());
    return v;
}
std::vector<std::string> DecodedPack::txt_keys() const {
    std::lock_guard<std::mutex> lk(data_mu_);
    return txt_;
}
std::string DecodedPack::tex_path(std::string key) const {
    std::lock_guard<std::mutex> lk(data_mu_);
    auto it = tex_.find(sa_core::str::lower(p4::strip(key)));
    return it == tex_.end() ? std::string() : it->second;
}
std::string DecodedPack::aud_path(std::string key) const {
    std::lock_guard<std::mutex> lk(data_mu_);
    auto it = aud_.find(sa_core::str::lower(p4::strip(key)));
    return it == aud_.end() ? std::string() : it->second;
}
std::optional<std::array<int, 2>> DecodedPack::tex_meta(std::string key) const {
    std::string ck = sa_core::str::lower(p4::strip(key));
    {
        std::lock_guard<std::mutex> lk(data_mu_);
        auto cached = texsizes_.find(ck);
        if (cached != texsizes_.end()) return cached->second;
    }
    auto path = tex_path(key);
    std::optional<std::array<int, 2>> size;
    if (!path.empty()) {
        auto raw = sa_core::paths::read_bytes(path);
        if (raw) size = image_size(*raw);
    }
    // Two threads may compute the same entry concurrently; both write the same
    // value, so no re-check is needed.
    std::lock_guard<std::mutex> lk(data_mu_);
    texsizes_[ck] = size;
    return size;
}
std::optional<std::pair<std::string, std::string>> DecodedPack::read_file(
    const std::string& path) const {
    if (path.empty()) return std::nullopt;
    auto raw = sa_core::paths::read_bytes(path);
    if (!raw) return std::nullopt;
    return std::make_pair(*raw, sa_core::str::lower(p4::split_ext(path).second));
}

// ---- accessors + pack-dir resolution -------------------------------------
// 多 base：启用列表来自 packs.json（p3b）。EDITOR_DECODED_PACK_DIR 与
// editor_env.decoded_pack_dir 作为唯一覆盖优先（开发/测试 seam）。
std::vector<std::string> active_pack_dirs() {
    std::vector<std::string> dirs;
    if (std::string env = sa_core::paths::getenv_utf8("EDITOR_DECODED_PACK_DIR"); !env.empty()) {
        dirs.push_back(env);
        return dirs;
    }
    json e = sa_core::env_store::read_editor_env(sa::editor_root());
    if (e.contains("decoded_pack_dir") && e.at("decoded_pack_dir").is_string()) {
        std::string d = p4::strip(e.at("decoded_pack_dir").get<std::string>());
        if (!d.empty()) {
            dirs.push_back(d);
            return dirs;
        }
    }
    dirs = p3b::resource_pack::active_pack_dirs();
    // 扩展合并：启用插件目录也参与资源解析（插件可携带 aa/tex/base 资源）。
    // 资源包在前、插件在后，保持既有资源包优先的键覆盖顺序。
    for (auto& d : sa::plugin_service::enabled_plugin_dirs()) dirs.push_back(std::move(d));
    return dirs;
}

std::string active_pack_dir() {
    auto dirs = active_pack_dirs();
    return dirs.empty() ? std::string() : dirs.front();
}

std::pair<std::string, std::string> pack_active_info() {
    // Only the injected/env override carries an id here; the orchestrator wires
    // resource_pack.list_packs at merge. Active id == dir basename, name == id.
    std::string d = active_pack_dir();
    if (d.empty()) return {"", ""};
    std::string id = p4::basename(d);
    return {id, id};
}

// All probed aa_index.json locations (first existing + parseable v3 index
// wins). Order: explicit env override → canonical _cache/aa_index → installer
// resource packs (setup.iss extracts the official pack with aa_index.json at
// its top level) → legacy Python-backend cache → dev dist fallbacks. The scan
// route renders this list in its error detail, so it stays cheap and pure.
std::vector<std::string> aa_index_candidate_paths() {
    std::vector<std::string> out;
    if (std::string env = sa_core::paths::getenv_utf8("EDITOR_AA_INDEX_FILE"); !env.empty())
        out.push_back(env);
    const std::string root = sa::editor_root();
    const std::string cache = sa_core::paths::join(root, "_cache");
    out.push_back(sa_core::paths::join(sa_core::paths::join(cache, "aa_index"), "aa_index.json"));
    std::vector<std::string> packs;
    std::error_code ec;
    const auto packs_dir = sa_core::paths::to_path(sa_core::paths::join(cache, "resource_packs"));
    if (std::filesystem::is_directory(packs_dir, ec)) {
        for (auto& e : std::filesystem::directory_iterator(packs_dir, ec)) {
            if (ec) break;
            if (e.is_directory()) packs.push_back(sa_core::paths::path_to_utf8(e.path()));
        }
    }
    std::sort(packs.begin(), packs.end());
    for (const auto& d : packs) out.push_back(sa_core::paths::join(d, "aa_index.json"));
    out.push_back(sa_core::paths::join(
        sa_core::paths::join(sa_core::paths::join(sa_core::paths::join(root, "backend"), "_cache"),
                             "aa_index"),
        "aa_index.json"));
    out.push_back(sa_core::paths::join(
        sa_core::paths::join(sa_core::paths::join(root, "dist"), "aa_index_cache"),
        "aa_index.json"));
    out.push_back(sa_core::paths::join(
        sa_core::paths::join(sa_core::paths::join(root, "dist"), "bundled_full"),
        "aa_index.json"));
    return out;
}

std::shared_ptr<AaIndex> ensure_aa_index() {
    std::lock_guard<std::mutex> lk(g_aa_mu);
    if (g_idx) return g_idx;
    if (g_idx_tried) return nullptr;
    g_idx_tried = true;
    // The game index is read-only from the backend cache (C++ never scans).
    for (const auto& cache : aa_index_candidate_paths()) {
        auto fresh = std::make_shared<AaIndex>();
        if (!fresh->load_from_file(cache) || fresh->empty()) continue;
        g_idx = fresh;
        // Mirror api.py: a usable cached index flips idle/error -> ready.
        std::lock_guard<std::mutex> slk(STATE().mu_);
        if (STATE().aa_status == "idle" || STATE().aa_status == "error")
            STATE().aa_status = "ready";
        return g_idx;
    }
    return nullptr;
}

std::shared_ptr<DecodedPack> ensure_pack_store() {
    std::lock_guard<std::mutex> lk(g_pack_mu);
    if (!g_pack) g_pack = std::make_shared<DecodedPack>();
    std::vector<std::string> dirs = active_pack_dirs();
    if (dirs != g_pack_dirs) {
        g_pack_dirs = dirs;
        g_pack->refresh(dirs);
    }
    return g_pack;
}

namespace {

// 自动探测目录辅助函数：优先 Tex2D，次之历史参考资料
std::string find_resource_subdir(const std::string& primary_sub,
                                 const std::string& fallback_rel) {
    // 1. 若测试显式覆盖了 editor_root（如单元测试隔离），仅在覆盖目录下探测，避免污染测试
    if (sa::detail::has_editor_root_override()) {
        std::string er = sa::editor_root();
        if (!er.empty()) {
            std::string cand1 = sa_core::paths::join(sa_core::paths::join(er, "Tex2D"), primary_sub);
            if (sa_core::paths::is_dir(cand1)) return cand1;
            std::string cand2 = sa_core::paths::join(er, fallback_rel);
            if (sa_core::paths::is_dir(cand2)) return cand2;
        }
        return std::string();
    }

    // 2. 正常运行时：先查 editor_root()
    std::string er = sa::editor_root();
    if (!er.empty()) {
        std::string cand1 = sa_core::paths::join(sa_core::paths::join(er, "Tex2D"), primary_sub);
        if (sa_core::paths::is_dir(cand1)) return cand1;
        std::string cand2 = sa_core::paths::join(er, fallback_rel);
        if (sa_core::paths::is_dir(cand2)) return cand2;
    }

    // 3. 源码开发运行：从 exe_dir 逐级向上回溯（最多 7 层，与 assets 探测一致）
    std::string exe = sa_core::paths::exe_dir();
    if (!exe.empty()) {
        std::string dir = exe;
        for (int i = 0; i < 7 && !dir.empty(); ++i) {
            std::string cand1 = sa_core::paths::join(sa_core::paths::join(dir, "Tex2D"), primary_sub);
            if (sa_core::paths::is_dir(cand1)) return cand1;
            std::string cand2 = sa_core::paths::join(dir, fallback_rel);
            if (sa_core::paths::is_dir(cand2)) return cand2;
            std::string parent = sa_core::paths::dirname(dir);
            if (parent == dir) break;
            dir = parent;
        }
    }

    // 4. 当前工作目录 cwd
    std::error_code ec;
    std::string cwd = sa_core::paths::path_to_utf8(std::filesystem::current_path(ec));
    if (!cwd.empty()) {
        std::string cand1 = sa_core::paths::join(sa_core::paths::join(cwd, "Tex2D"), primary_sub);
        if (sa_core::paths::is_dir(cand1)) return cand1;
        std::string cand2 = sa_core::paths::join(cwd, fallback_rel);
        if (sa_core::paths::is_dir(cand2)) return cand2;
    }
    return std::string();
}

template <int Tag>
std::shared_ptr<DecodedPack>& image_ext_store_ref() {
    static std::shared_ptr<DecodedPack> store;
    return store;
}
template <int Tag>
std::string& image_ext_dir_ref() {
    static std::string dir;
    return dir;
}
template <int Tag>
bool& image_ext_tried_ref() {
    static bool tried = false;
    return tried;
}
template <int Tag>
std::mutex& image_ext_mu_ref() {
    static std::mutex mu;
    return mu;
}

// 图片资源扩展（人物立绘 Tag=0 / 背景 Tag=1）：本地目录惰性 DecodedPack
template <int Tag>
std::shared_ptr<DecodedPack> image_ext_local_store() {
    auto& mu = image_ext_mu_ref<Tag>();
    auto& store = image_ext_store_ref<Tag>();
    auto& dir = image_ext_dir_ref<Tag>();
    auto& tried = image_ext_tried_ref<Tag>();

    const std::string d = (Tag == 0) ? resolve_portrait_dir() : resolve_background_dir();
    std::lock_guard<std::mutex> lk(mu);
    if (!store) store = std::make_shared<DecodedPack>();
    if (!tried || d != dir) {
        dir = d;
        tried = true;
        store->refresh(d);
    }
    return store;
}

template <int Tag>
void reset_image_ext_store() {
    auto& mu = image_ext_mu_ref<Tag>();
    std::lock_guard<std::mutex> lk(mu);
    image_ext_store_ref<Tag>() = nullptr;
    image_ext_dir_ref<Tag>().clear();
    image_ext_tried_ref<Tag>() = false;
}

// 对象存储公开基址（去掉尾部 '/'）；未配置返回 ""。
std::string image_ext_base_url(const char* env_name) {
    std::string u = sa_core::paths::getenv_utf8(env_name);
    if (!u.empty()) u = p4::strip(u);
    while (!u.empty() && u.back() == '/') u.pop_back();
    return u;
}

// norm_key 后把非 [a-z0-9._-] 字符替换为 '_'（与 decoded_export._safe_name 对齐），
// 用于对象存储上「按安全文件名」上传的布局。
std::string safe_asset_name(const std::string& key) {
    std::string s = norm_key(key);
    for (char& c : s) {
        const unsigned char u = static_cast<unsigned char>(c);
        const bool ok = (u >= 'a' && u <= 'z') || (u >= '0' && u <= '9') ||
                        c == '.' || c == '_' || c == '-';
        if (!ok) c = '_';
    }
    return s;
}

// 本地「图片扩展」目录解析命中路径：原样键 + safe_asset_name + 去前缀 + norm_key
// 多级命中。返回 "" 表示未命中。字节读取走 [read_image_ext_local_tex]（同一路径
// 逻辑），二进制直发路由也复用它以避免重复解析。
std::string resolve_image_ext_local_path(const std::shared_ptr<DecodedPack>& store,
                                         const std::string& key) {
    if (!store || !store->active() || key.empty()) return {};
    if (std::string p = store->tex_path(key); !p.empty()) return p;
    // 键含 '/' 等路径字符时，解码包文件名是 safe_asset_name（'/'→'_'）。
    if (std::string p = store->tex_path(safe_asset_name(key)); !p.empty()) return p;
    // 去掉前缀试探（支持 bg/, cg/, role/, role_full/, role_head/, textures/ 等）
    std::string stripped = key;
    std::string lk = sa_core::str::lower(key);
    for (const std::string& pfx : {"role_full/", "role_head/", "textures/role/", "textures/bg/", "textures/", "role/", "bg/", "cg/"}) {
        if (sa_core::str::starts_with(lk, pfx)) {
            stripped = key.substr(pfx.size());
            break;
        }
    }
    if (stripped != key) {
        if (std::string p = store->tex_path(stripped); !p.empty()) return p;
        if (std::string p = store->tex_path(safe_asset_name(stripped)); !p.empty()) return p;
        std::string nks = norm_key(stripped);
        if (!nks.empty()) {
            if (std::string p = store->tex_path(nks); !p.empty()) return p;
        }
    }
    // norm_key 归一化试探
    std::string nk = norm_key(key);
    if (!nk.empty() && nk != key) {
        if (std::string p = store->tex_path(nk); !p.empty()) return p;
    }
    return {};
}

// 本地「图片扩展」目录取字节：原样键 + safe_asset_name + 去前缀 + norm_key 多级命中。
std::optional<std::pair<std::string, std::string>> read_image_ext_local_tex(
    const std::shared_ptr<DecodedPack>& store, const std::string& key) {
    std::string path = resolve_image_ext_local_path(store, key);
    if (path.empty()) return std::nullopt;
    return store->read_file(path);
}

// 对象存储「图片扩展」URL：<base>/tex/<safe_name>.webp（统一转 WebP）。只回 URL，
// 不代替浏览器下载——客户端拿到 URL 后自行 GET。
std::optional<std::string> image_ext_url_for(const std::string& base,
                                             const std::string& key) {
    if (base.empty() || key.empty()) return std::nullopt;
    const std::string name = safe_asset_name(key);
    if (name.empty()) return std::nullopt;
    return base + "/tex/" + sa_core::http::quote_component(name) + ".webp";
}

}  // namespace

std::string resolve_portrait_dir() {
    std::string env = sa_core::paths::getenv_utf8("EDITOR_PORTRAIT_DIR");
    if (!p4::strip(env).empty()) return p4::strip(env);
    return find_resource_subdir("role", sa_core::paths::join("参考资料", "人物立绘"));
}

std::shared_ptr<DecodedPack> portrait_local_store() {
    return image_ext_local_store<0>();
}

std::optional<std::pair<std::string, std::string>> read_portrait_local_tex(
    const std::string& key) {
    return read_image_ext_local_tex(portrait_local_store(), key);
}

bool has_image_ext_local_tex(
    const std::shared_ptr<DecodedPack>& store, const std::string& key) {
    if (!store || !store->active() || key.empty()) return false;
    if (!store->tex_path(key).empty()) return true;
    if (!store->tex_path(safe_asset_name(key)).empty()) return true;
    std::string stripped = key;
    std::string lk = sa_core::str::lower(key);
    for (const std::string& pfx : {"role_full/", "role_head/", "textures/role/", "textures/bg/", "textures/", "role/", "bg/", "cg/"}) {
        if (sa_core::str::starts_with(lk, pfx)) {
            stripped = key.substr(pfx.size());
            break;
        }
    }
    if (stripped != key) {
        if (!store->tex_path(stripped).empty()) return true;
        if (!store->tex_path(safe_asset_name(stripped)).empty()) return true;
        std::string nks = norm_key(stripped);
        if (!nks.empty() && !store->tex_path(nks).empty()) return true;
    }
    std::string nk = norm_key(key);
    if (!nk.empty() && nk != key) {
        if (!store->tex_path(nk).empty()) return true;
    }
    return false;
}

bool has_portrait_local_tex(const std::string& key) {
    return has_image_ext_local_tex(portrait_local_store(), key);
}

std::optional<std::string> portrait_url_for(const std::string& key) {
    return image_ext_url_for(image_ext_base_url("EDITOR_PORTRAIT_BASE_URL"), key);
}

bool portrait_source_configured() {
    if (!resolve_portrait_dir().empty()) return true;
    return !image_ext_base_url("EDITOR_PORTRAIT_BASE_URL").empty();
}

std::string resolve_background_dir() {
    std::string env = sa_core::paths::getenv_utf8("EDITOR_BG_DIR");
    if (!p4::strip(env).empty()) return p4::strip(env);
    return find_resource_subdir("bg", sa_core::paths::join("参考资料", "背景"));
}

std::shared_ptr<DecodedPack> background_local_store() {
    return image_ext_local_store<1>();
}

std::optional<std::pair<std::string, std::string>> read_background_local_tex(
    const std::string& key) {
    return read_image_ext_local_tex(background_local_store(), key);
}

std::optional<std::string> background_url_for(const std::string& key) {
    return image_ext_url_for(image_ext_base_url("EDITOR_BG_BASE_URL"), key);
}

bool background_source_configured() {
    if (!resolve_background_dir().empty()) return true;
    return !image_ext_base_url("EDITOR_BG_BASE_URL").empty();
}

// Mod 本地贴图的路径解析：先做全路径精确匹配，未命中且 [allow_strip_expr] 为真
// 时再按表情差分规则回退（如 `hero_5` 缺差分图时回退 `hero.png`）。
//
// [allow_strip_expr] 为 false 时**只**做精确匹配——供 [has_mod_local_tex] 判存在性
// 使用：若开启回退，只要 Mod 本地有基础立绘 `hero.png`，`has_mod_local_tex("hero_5")`
// 就会误判为存在并遮蔽本体包内的真实差分表情。探测只做 stat 级 is_file，不读盘。
std::string resolve_mod_local_tex_path(const std::string& key,
                                       bool allow_strip_expr = true) {
    if (key.empty()) return "";
    std::string mod_root;
    std::string workspace_root;
    {
        std::lock_guard<std::mutex> lk(STATE().mu_);
        mod_root = STATE().mod_root;
        workspace_root = STATE().workspace_root;
    }

    // 规范化路径分隔符：统一反斜杠为正斜杠并去除前导斜杠
    std::string norm_k = key;
    for (char& c : norm_k) {
        if (c == '\\') c = '/';
    }
    while (!norm_k.empty() && norm_k.front() == '/') norm_k.erase(norm_k.begin());
    if (norm_k.empty()) return "";

    // 安全闸门：拒绝任何越界形态的 key（盘符 / `..` 段 / NUL）。
    // 与 static_routes.cpp rel_is_safe 同范式：前导 `/` 已在上方剥离，故这里只需
    // 拦「首段之前的盘符冒号」与「段级 `..`」。Windows 绝对路径（`C:/...`）不以
    // `/` 开头，只有本闸门能拦下。
    if (norm_k.find('\0') != std::string::npos) return "";
    {
        size_t sep = norm_k.find_first_of("/\\");
        size_t colon = norm_k.find(':');
        if (colon != std::string::npos && (sep == std::string::npos || colon < sep)) return "";
        size_t i = 0;
        while (i <= norm_k.size()) {
            size_t j = norm_k.find_first_of("/\\", i);
            if (j == std::string::npos) j = norm_k.size();
            if (norm_k.compare(i, j - i, "..") == 0) return "";
            i = j + 1;
            if (j == norm_k.size()) break;
        }
    }

    // 收集候选根目录
    std::vector<std::string> roots;
    if (!mod_root.empty() && sa_core::paths::is_dir(mod_root)) {
        roots.push_back(mod_root);
    }

    // 收集所有候选相对路径
    std::vector<std::string> cands;
    cands.push_back(norm_k);

    // 剥离 Mods/<any>/ 前缀，并在必要时从 workspace_root / sibling 探测该 mod
    std::string lower_k = sa_core::str::lower(norm_k);
    std::string mod_name_from_k;
    std::string rel_after_mod;
    if (sa_core::str::starts_with(lower_k, "mods/")) {
        auto first_slash = norm_k.find('/');
        if (first_slash != std::string::npos) {
            auto second_slash = norm_k.find('/', first_slash + 1);
            if (second_slash != std::string::npos) {
                mod_name_from_k = norm_k.substr(first_slash + 1, second_slash - (first_slash + 1));
                rel_after_mod = norm_k.substr(second_slash + 1);
                cands.push_back(rel_after_mod);
            } else {
                mod_name_from_k = norm_k.substr(first_slash + 1);
            }
        }
    }

    if (!mod_name_from_k.empty()) {
        if (!workspace_root.empty()) {
            auto ws_mod = sa_core::paths::join(workspace_root, mod_name_from_k);
            if (sa_core::paths::is_dir(ws_mod)) roots.push_back(ws_mod);
            auto ws_mods_mod = sa_core::paths::join(workspace_root, sa_core::paths::join("Mods", mod_name_from_k));
            if (sa_core::paths::is_dir(ws_mods_mod)) roots.push_back(ws_mods_mod);
        }
        if (!mod_root.empty()) {
            auto parent = sa_core::paths::dirname(mod_root);
            if (!parent.empty()) {
                auto sib = sa_core::paths::join(parent, mod_name_from_k);
                if (sa_core::paths::is_dir(sib)) roots.push_back(sib);
            }
        }
    }

    // 剥离 Textures/ 前缀以方便拼接到 Textures/、Textures/Bg/、Textures/Role/、Textures/Role2/
    std::vector<std::string> sub_cands;
    for (const auto& c : cands) {
        sub_cands.push_back(c);
        std::string lc = sa_core::str::lower(c);
        if (sa_core::str::starts_with(lc, "textures/")) {
            sub_cands.push_back(c.substr(9));
        }
    }

    // 表情差分回退探测（如 xyz_1.png 或 xyz.png_1 在本地缺少表情图时回退 xyz.png）
    auto strip_expr = [](const std::string& path) -> std::string {
        auto under = path.rfind('_');
        auto slash = path.find_last_of("/\\");
        if (under != std::string::npos && (slash == std::string::npos || under > slash)) {
            bool all_digits = (under + 1 < path.size());
            for (size_t i = under + 1; i < path.size(); ++i) {
                if (!std::isdigit(static_cast<unsigned char>(path[i]))) {
                    all_digits = false;
                    break;
                }
            }
            if (all_digits) {
                return path.substr(0, under);
            }
        }
        auto dot = path.rfind('.');
        if (dot != std::string::npos && (slash == std::string::npos || dot > slash)) {
            std::string stem = path.substr(0, dot);
            std::string ext = path.substr(dot);
            auto u = stem.rfind('_');
            if (u != std::string::npos) {
                bool all_digits = (u + 1 < stem.size());
                for (size_t i = u + 1; i < stem.size(); ++i) {
                    if (!std::isdigit(static_cast<unsigned char>(stem[i]))) {
                        all_digits = false;
                        break;
                    }
                }
                if (all_digits) {
                    return stem.substr(0, u) + ext;
                }
            }
        }
        return "";
    };

    // 文件名与 basename
    std::string base_name = sa_core::paths::basename(norm_k);
    std::string base_name_stripped = strip_expr(base_name);

    // 单个相对路径 → 各候选根目录/子目录下的全部组合。
    auto append_combos = [](std::vector<std::string>& out, const std::string& r,
                            const std::string& sc) {
        out.push_back(sa_core::paths::join(r, sc));
        out.push_back(sa_core::paths::join(r, sa_core::paths::join("Textures", sc)));
        out.push_back(sa_core::paths::join(r, sa_core::paths::join("Textures/Role", sc)));
        out.push_back(sa_core::paths::join(r, sa_core::paths::join("Textures/Role2", sc)));
        out.push_back(sa_core::paths::join(r, sa_core::paths::join("Textures/Bg", sc)));
        out.push_back(sa_core::paths::join(r, sa_core::paths::join("Textures/Cg", sc)));
    };
    auto append_base_name_combos = [](std::vector<std::string>& out,
                                      const std::string& r,
                                      const std::string& bn) {
        if (bn.empty()) return;
        out.push_back(sa_core::paths::join(r, sa_core::paths::join("Textures", bn)));
        out.push_back(sa_core::paths::join(r, sa_core::paths::join("Textures/Role", bn)));
        out.push_back(sa_core::paths::join(r, sa_core::paths::join("Textures/Role2", bn)));
        out.push_back(sa_core::paths::join(r, sa_core::paths::join("Textures/Bg", bn)));
        out.push_back(sa_core::paths::join(r, sa_core::paths::join("Textures/Cg", bn)));
    };
    // 沙箱根（防御纵深）：候选路径解析后必须仍位于某个允许根目录内，否则丢弃。
    // path_key 走 abs_path（纯词法 lexically_normal），能拦下拼接产生的 `..` 逃逸。
    std::vector<std::string> root_keys;
    root_keys.reserve(roots.size());
    for (const auto& r : roots) root_keys.push_back(sa_core::paths::path_key(r));
    auto within_roots = [&root_keys](const std::string& cand) -> bool {
        std::string ck = sa_core::paths::path_key(cand);
        for (const auto& rk : root_keys) {
            if (ck.size() >= rk.size() && ck.compare(0, rk.size(), rk) == 0) return true;
        }
        return false;
    };
    // 首个存在的候选路径（不带扩展名时依次补 .png/.webp/.jpg/.jpeg）。
    auto first_existing = [&within_roots](const std::vector<std::string>& paths) -> std::string {
        for (const auto& tp : paths) {
            if (within_roots(tp) && sa_core::paths::is_file(tp)) return tp;
            for (const char* ext : {".png", ".webp", ".jpg", ".jpeg"}) {
                std::string with_ext = tp + ext;
                if (within_roots(with_ext) && sa_core::paths::is_file(with_ext)) return with_ext;
            }
        }
        return "";
    };

    // 第一轮：精确匹配。注意**不**对用户原始串做裸 is_file（那是越界读取面）；
    // 所有候选都由 roots 拼接而来，再由 within_roots 复核。
    std::vector<std::string> exact_paths;
    for (const auto& r : roots) {
        for (const auto& sc : sub_cands) append_combos(exact_paths, r, sc);
        append_base_name_combos(exact_paths, r, base_name);
    }
    if (std::string hit = first_existing(exact_paths); !hit.empty()) return hit;
    if (!allow_strip_expr) return "";

    // 第二轮：表情差分回退。
    std::vector<std::string> stripped_paths;
    for (const auto& r : roots) {
        for (const auto& sc : sub_cands) {
            std::string stripped = strip_expr(sc);
            if (!stripped.empty()) append_combos(stripped_paths, r, stripped);
        }
        append_base_name_combos(stripped_paths, r, base_name_stripped);
    }
    return first_existing(stripped_paths);
}

std::optional<std::pair<std::string, std::string>> read_mod_local_tex(
    const std::string& key) {
    std::string path = resolve_mod_local_tex_path(key, /*allow_strip_expr=*/true);
    if (path.empty()) return std::nullopt;
    auto bytes = sa_core::paths::read_bytes(path);
    if (!bytes) return std::nullopt;
    std::string ext = sa_core::paths::path_to_utf8(
        sa_core::paths::to_path(path).extension());
    return std::make_pair(std::move(*bytes), std::move(ext));
}

bool has_mod_local_tex(const std::string& key) {
    // 仅判存在性：不做 strip_expr 回退（避免基础立绘遮蔽本体包内的真实差分），
    // 也不读文件内容（只做 stat 级探测）。
    return !resolve_mod_local_tex_path(key, /*allow_strip_expr=*/false).empty();
}

namespace {

// 图片二进制直发的 ETag：<size_hex>-<version_hex>（version = 磁盘 mtime_ns）。
// 带引号，符合 HTTP ETag 语法。
std::string make_etag(long long size, long long version) {
    char buf[80];
    std::snprintf(buf, sizeof(buf), "\"%llx-%llx\"",
                  static_cast<unsigned long long>(size),
                  static_cast<unsigned long long>(version));
    return std::string(buf);
}

struct ImageCacheEntry {
    std::string data;
    std::string mime;
    std::string etag;
    long long version = 0;  // 磁盘 mtime_ns
    long long size = 0;
};

// 线程安全图片字节 LRU（默认上限 64MB，可用 EDITOR_IMAGE_CACHE_MB 覆盖）。
// 命中时校验 version/size：磁盘文件被外部替换即自动失效重读。
class ImageBytesCache {
  public:
    ImageBytesCache() {
        long long mb = 64;
        std::string env = sa_core::paths::getenv_utf8("EDITOR_IMAGE_CACHE_MB");
        if (!env.empty()) {
            try {
                long long v = std::stoll(env);
                if (v > 0) mb = v;
            } catch (...) {
            }
        }
        max_bytes_ = mb * 1024 * 1024;
    }

    bool get(const std::string& key, long long version, long long size,
             ImageCacheEntry* out) {
        std::lock_guard<std::mutex> lk(mu_);
        auto it = map_.find(key);
        if (it == map_.end()) return false;
        auto lit = it->second;
        if (lit->second.version != version || lit->second.size != size) {
            bytes_ -= static_cast<long long>(lit->second.data.size());
            lru_.erase(lit);
            map_.erase(it);
            return false;
        }
        if (out) *out = lit->second;
        lru_.splice(lru_.begin(), lru_, lit);  // 触碰续命（LRU）
        return true;
    }

    void put(const std::string& key, ImageCacheEntry entry) {
        std::lock_guard<std::mutex> lk(mu_);
        auto it = map_.find(key);
        if (it != map_.end()) {
            bytes_ -= static_cast<long long>(it->second->second.data.size());
            lru_.erase(it->second);
            map_.erase(it);
        }
        bytes_ += static_cast<long long>(entry.data.size());
        lru_.emplace_front(key, std::move(entry));
        map_[key] = lru_.begin();
        evict();
    }

    void clear() {
        std::lock_guard<std::mutex> lk(mu_);
        lru_.clear();
        map_.clear();
        bytes_ = 0;
    }

  private:
    void evict() {
        while (bytes_ > max_bytes_ && !lru_.empty()) {
            auto& back = lru_.back();
            bytes_ -= static_cast<long long>(back.second.data.size());
            map_.erase(back.first);
            lru_.pop_back();
        }
    }

    std::mutex mu_;
    using Node = std::pair<std::string, ImageCacheEntry>;
    std::list<Node> lru_;  // front = MRU
    std::unordered_map<std::string, std::list<Node>::iterator> map_;
    long long bytes_ = 0;
    long long max_bytes_;
};

ImageBytesCache& image_bytes_cache() {
    static ImageBytesCache cache;
    return cache;
}

void clear_image_bytes_cache() { image_bytes_cache().clear(); }

// 磁盘文件直发（含 ETag/304 协商 + 64MB 内存 LRU）。
Resp serve_path_bytes(const std::string& path, const std::string& if_none_match,
                      bool is_audio) {
    auto st = sa_core::paths::stat(path);
    if (!st) return Resp::Json(404, json{{"error", "file not found"}});
    const std::string ext = sa_core::str::lower(p4::split_ext(path).second);
    const std::string mime = is_audio ? aud_mime(ext) : tex_mime(ext);
    const std::string etag = make_etag(st->size, st->mtime_ns);
    const char* kCache = "public, max-age=86400";
    if (!if_none_match.empty() && if_none_match == etag) {
        return Resp::NotModified(etag, kCache);
    }
    ImageCacheEntry entry;
    if (image_bytes_cache().get(path, st->mtime_ns, st->size, &entry)) {
        Resp r = Resp::BytesTyped(200, std::move(entry.data), entry.mime);
        r.etag = etag;
        r.cache_control = kCache;
        return r;
    }
    auto raw = sa_core::paths::read_bytes(path);
    if (!raw) return Resp::Json(404, json{{"error", "file not found"}});
    ImageCacheEntry ne;
    ne.mime = mime;
    ne.etag = etag;
    ne.version = st->mtime_ns;
    ne.size = st->size;
    ne.data = *raw;  // 缓存一份
    image_bytes_cache().put(path, std::move(ne));
    Resp r = Resp::BytesTyped(200, std::move(*raw), mime);
    r.etag = etag;
    r.cache_control = kCache;
    return r;
}

}  // namespace


void reset_aa_singletons_for_test() {
    // 两个互斥量各自独立的临界区，**不嵌套**：原实现持 g_aa_mu 再锁 g_pack_mu，
    // 形成固定加锁序，任何反向序的路径都会死锁。测试重置不需要跨两者的原子性。
    {
        std::lock_guard<std::mutex> lk(g_aa_mu);
        g_idx = nullptr;
        g_idx_tried = false;
    }
    {
        std::lock_guard<std::mutex> lk2(g_pack_mu);
        g_pack = nullptr;
        g_pack_dirs.clear();
    }
    reset_image_ext_store<0>();
    reset_image_ext_store<1>();
    clear_image_bytes_cache();
}

std::string tex_mime(std::string_view ext) {
    std::string e = sa_core::str::lower(ext);
    if (e == ".avif") return "image/avif";
    if (e == ".webp") return "image/webp";
    if (e == ".png") return "image/png";
    if (e == ".jpg" || e == ".jpeg") return "image/jpeg";
    return "application/octet-stream";
}
std::string aud_mime(std::string_view ext) {
    std::string e = sa_core::str::lower(ext);
    if (e == ".ogg") return "audio/ogg";
    if (e == ".wav") return "audio/wav";
    if (e == ".m4a") return "audio/mp4";
    if (e == ".mp3") return "audio/mpeg";
    return "application/octet-stream";
}

// 统一二进制取图：本地立绘/背景/模组资源直出原始字节（200 + ETag +
// Cache-Control），对象存储扩展回 302（Location: <url>，客户端自行跳转），
// If-None-Match 命中回 304（0 字节）。解析优先级与 POST /api/aa/preview 完全一致。
Resp fetch_tex_raw(const std::string& key, const std::string& if_none_match) {
    if (key.empty())
        return Resp::Json(404, json{{"error", "texture key not found: " + key}});
    // 当前活动模组本地资源（WYSIWYG）优先：与 POST /api/aa/preview 一致。
    // 走磁盘直发：复用 stat 级 ETag（304 零读盘）与 64MB ImageBytesCache LRU。
    if (std::string mp = resolve_mod_local_tex_path(key); !mp.empty()) {
        return serve_path_bytes(mp, if_none_match, false);
    }
    auto store = ensure_pack_store();
    if (store && store->active()) {
        std::string p = store->tex_path(key);
        if (!p.empty()) return serve_path_bytes(p, if_none_match, false);
    }
    // 人物图片资源扩展：本地目录直出字节，对象存储回 302。
    if (std::string p = resolve_image_ext_local_path(portrait_local_store(), key);
        !p.empty())
        return serve_path_bytes(p, if_none_match, false);
    if (auto url = portrait_url_for(key)) return Resp::Redirect(302, *url);
    // 背景图片资源扩展：与人物扩展同构。
    if (std::string p = resolve_image_ext_local_path(background_local_store(), key);
        !p.empty())
        return serve_path_bytes(p, if_none_match, false);
    if (auto url = background_url_for(key)) return Resp::Redirect(302, *url);
    auto idx = ensure_aa_index();
    if (idx && idx->has_tex(key))
        return Resp::Json(422, json{{"error", "texture decode failed: " + key}});
    return Resp::Json(404, json{{"error", "texture key not found: " + key}});
}

// 音频二进制直发（解码包 aud/<key>.<ext>）；无解码文件时按索引给 422/404。
Resp fetch_aud_raw(const std::string& key, const std::string& if_none_match) {
    if (key.empty())
        return Resp::Json(404, json{{"error", "audio key not found: " + key}});
    auto store = ensure_pack_store();
    if (store && store->active()) {
        std::string p = store->aud_path(key);
        if (!p.empty()) return serve_path_bytes(p, if_none_match, true);
    }
    auto idx = ensure_aa_index();
    if (idx && idx->has_aud(key))
        return Resp::Json(422, json{{"error", "audio decode failed: " + key}});
    return Resp::Json(404, json{{"error", "audio key not found: " + key}});
}

}  // namespace sa
