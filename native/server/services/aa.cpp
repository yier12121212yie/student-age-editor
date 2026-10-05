// wip/P4/aa.cpp — see aa.h (port of the aa_* routes + decoded_pack.py).
#include "aa.h"

#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <mutex>
#include <set>
#include <string>
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
        const std::string tex_dir = sa_core::paths::join(pack_dir, "tex");
        if (sa_core::paths::is_dir(tex_dir)) {
            for (const auto& fn : sa_core::paths::listdir_sorted(tex_dir)) {
                auto [root, ext] = p4::split_ext(fn);
                std::string e = sa_core::str::lower(ext);
                if (e == ".webp" || e == ".png" || e == ".jpg" || e == ".jpeg") {
                    const std::string k = sa_core::str::lower(root);
                    if (!tex.count(k)) tex[k] = sa_core::paths::join(tex_dir, fn);
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

// 图片资源扩展（人物立绘 / 背景，服务器端自托管）：本地目录惰性 DecodedPack
// （与资源包同一套 tex/<文件> 扫描/取文件语义）；目录未配置时 active()==false。
// Tag 让两类来源各持独立 static store（互不串味）。env_name 决定读哪个变量。
template <int Tag>
std::shared_ptr<DecodedPack> image_ext_local_store(const char* env_name) {
    static std::mutex mu;
    static std::shared_ptr<DecodedPack> store;
    static std::string dir;
    static bool tried = false;
    const std::string d = sa_core::paths::getenv_utf8(env_name);
    std::lock_guard<std::mutex> lk(mu);
    if (!store) store = std::make_shared<DecodedPack>();
    if (!tried || d != dir) {
        dir = d;
        tried = true;
        store->refresh(d);
    }
    return store;
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

// 本地「图片扩展」目录取字节：原样键 + safe_asset_name 两级命中。
std::optional<std::pair<std::string, std::string>> read_image_ext_local_tex(
    const std::shared_ptr<DecodedPack>& store, const std::string& key) {
    if (!store || !store->active() || key.empty()) return std::nullopt;
    if (auto r = store->read_file(store->tex_path(key))) return r;
    // 键含 '/' 等路径字符时，解码包文件名是 safe_asset_name（'/'→'_'）。
    if (auto r = store->read_file(store->tex_path(safe_asset_name(key)))) return r;
    return std::nullopt;
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

std::optional<std::pair<std::string, std::string>> read_portrait_local_tex(
    const std::string& key) {
    return read_image_ext_local_tex(
        image_ext_local_store<0>("EDITOR_PORTRAIT_DIR"), key);
}

std::optional<std::string> portrait_url_for(const std::string& key) {
    return image_ext_url_for(image_ext_base_url("EDITOR_PORTRAIT_BASE_URL"), key);
}

bool portrait_source_configured() {
    if (!p4::strip(sa_core::paths::getenv_utf8("EDITOR_PORTRAIT_DIR")).empty())
        return true;
    return !image_ext_base_url("EDITOR_PORTRAIT_BASE_URL").empty();
}

std::optional<std::pair<std::string, std::string>> read_background_local_tex(
    const std::string& key) {
    return read_image_ext_local_tex(
        image_ext_local_store<1>("EDITOR_BG_DIR"), key);
}

std::optional<std::string> background_url_for(const std::string& key) {
    return image_ext_url_for(image_ext_base_url("EDITOR_BG_BASE_URL"), key);
}

bool background_source_configured() {
    if (!p4::strip(sa_core::paths::getenv_utf8("EDITOR_BG_DIR")).empty())
        return true;
    return !image_ext_base_url("EDITOR_BG_BASE_URL").empty();
}

void reset_aa_singletons_for_test() {
    std::lock_guard<std::mutex> lk(g_aa_mu);
    g_idx = nullptr;
    g_idx_tried = false;
    std::lock_guard<std::mutex> lk2(g_pack_mu);
    g_pack = nullptr;
    g_pack_dirs.clear();
}

std::string tex_mime(std::string_view ext) {
    std::string e = sa_core::str::lower(ext);
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

}  // namespace sa
