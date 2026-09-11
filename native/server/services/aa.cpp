// wip/P4/aa.cpp — see aa.h (port of the aa_* routes + decoded_pack.py).
#include "aa.h"

#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <mutex>
#include <string>
#include <vector>

#include "sa_core/env_store.h"
#include "sa_core/paths.h"
#include "sa_core/steam_paths.h"
#include "sa_core/strings.h"
#include "sa_core/utf8.h"
#include "sa_core/util.h"
#include "server/state.h"
#include "flow_assets.h"
#include "p4_util.h"

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
std::string g_pack_last = "\x01";  // sentinel != any real dir

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
    if (pack_dir == dir_) return;
    std::map<std::string, std::string> tex, aud;
    std::vector<std::string> txt;
    const std::string tex_dir = sa_core::paths::join(pack_dir, "tex");
    if (!pack_dir.empty() && sa_core::paths::is_dir(tex_dir)) {
        for (const auto& fn : sa_core::paths::listdir_sorted(tex_dir)) {
            auto [root, ext] = p4::split_ext(fn);
            std::string e = sa_core::str::lower(ext);
            if (e == ".webp" || e == ".png" || e == ".jpg" || e == ".jpeg")
                tex[sa_core::str::lower(root)] = sa_core::paths::join(tex_dir, fn);
        }
    }
    const std::string aud_dir = sa_core::paths::join(pack_dir, "aud");
    if (!pack_dir.empty() && sa_core::paths::is_dir(aud_dir)) {
        for (const auto& fn : sa_core::paths::listdir_sorted(aud_dir)) {
            auto [root, ext] = p4::split_ext(fn);
            std::string e = sa_core::str::lower(ext);
            if (e == ".ogg" || e == ".wav" || e == ".m4a" || e == ".mp3")
                aud[sa_core::str::lower(root)] = sa_core::paths::join(aud_dir, fn);
        }
    }
    // txt keys: prefer the decoded v3 aa_index.json list; else Cfgs/zh-cn scan.
    if (!pack_dir.empty()) {
        auto raw = sa_core::paths::read_bytes(sa_core::paths::join(pack_dir, "aa_index.json"));
        if (raw) {
            std::string body = *raw;
            if (body.size() >= 3 && static_cast<unsigned char>(body[0]) == 0xEF) body = body.substr(3);
            auto j = json::parse(body, nullptr, false);
            if (!j.is_discarded() && j.is_object() && j.value("v", 0) == 3 &&
                j.contains("txt") && j.at("txt").is_array()) {
                for (const auto& k : j.at("txt")) if (k.is_string()) txt.push_back(k.get<std::string>());
            }
        }
        if (txt.empty()) {
            const std::string zh = sa_core::paths::join(sa_core::paths::join(pack_dir, "Cfgs"), "zh-cn");
            if (sa_core::paths::is_dir(zh)) {
                for (const auto& f : sa_core::paths::listdir_sorted(zh))
                    if (ends_ci(f, ".json")) txt.push_back(p4::split_ext(f).first);
                std::sort(txt.begin(), txt.end());
            }
        }
    }
    tex_ = std::move(tex);
    aud_ = std::move(aud);
    txt_ = std::move(txt);
    texsizes_.clear();
    dir_ = pack_dir;
}

long long DecodedPack::tex_count() const { return static_cast<long long>(tex_.size()); }
long long DecodedPack::aud_count() const { return static_cast<long long>(aud_.size()); }
std::vector<std::string> DecodedPack::tex_keys() const {
    std::vector<std::string> v;
    for (auto& [k, _] : tex_) v.push_back(k);
    std::sort(v.begin(), v.end());
    return v;
}
std::vector<std::string> DecodedPack::aud_keys() const {
    std::vector<std::string> v;
    for (auto& [k, _] : aud_) v.push_back(k);
    std::sort(v.begin(), v.end());
    return v;
}
std::vector<std::string> DecodedPack::txt_keys() const { return txt_; }
std::string DecodedPack::tex_path(std::string key) const {
    auto it = tex_.find(sa_core::str::lower(p4::strip(key)));
    return it == tex_.end() ? std::string() : it->second;
}
std::string DecodedPack::aud_path(std::string key) const {
    auto it = aud_.find(sa_core::str::lower(p4::strip(key)));
    return it == aud_.end() ? std::string() : it->second;
}
std::optional<std::array<int, 2>> DecodedPack::tex_meta(std::string key) const {
    std::string ck = sa_core::str::lower(p4::strip(key));
    auto cached = texsizes_.find(ck);
    if (cached != texsizes_.end()) return cached->second;
    auto path = tex_path(key);
    std::optional<std::array<int, 2>> size;
    if (!path.empty()) {
        auto raw = sa_core::paths::read_bytes(path);
        if (raw) size = image_size(*raw);
    }
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
std::string active_pack_dir() {
    if (std::string env = sa_core::paths::getenv_utf8("EDITOR_DECODED_PACK_DIR"); !env.empty())
        return env;
    json env = sa_core::env_store::read_editor_env(sa::editor_root());
    if (env.contains("decoded_pack_dir") && env.at("decoded_pack_dir").is_string()) {
        std::string d = p4::strip(env.at("decoded_pack_dir").get<std::string>());
        if (!d.empty()) return d;
    }
    return {};
}

std::pair<std::string, std::string> pack_active_info() {
    // Only the injected/env override carries an id here; the orchestrator wires
    // resource_pack.list_packs at merge. Active id == dir basename, name == id.
    std::string d = active_pack_dir();
    if (d.empty()) return {"", ""};
    std::string id = p4::basename(d);
    return {id, id};
}

std::shared_ptr<AaIndex> ensure_aa_index() {
    std::lock_guard<std::mutex> lk(g_aa_mu);
    if (g_idx) return g_idx;
    if (g_idx_tried) return nullptr;
    g_idx_tried = true;
    // The game index is read-only from the backend cache (C++ never scans).
    const std::string cache =
        sa_core::paths::join(sa_core::paths::join(sa_core::paths::join(sa::editor_root(), "_cache"),
                                                  "aa_index"),
                             "aa_index.json");
    auto fresh = std::make_shared<AaIndex>();
    if (!fresh->load_from_file(cache) || fresh->empty()) return nullptr;
    g_idx = fresh;
    // Mirror api.py: a usable cached index flips idle/error -> ready.
    std::lock_guard<std::mutex> slk(STATE().mu_);
    if (STATE().aa_status == "idle" || STATE().aa_status == "error") STATE().aa_status = "ready";
    return g_idx;
}

std::shared_ptr<DecodedPack> ensure_pack_store() {
    std::lock_guard<std::mutex> lk(g_pack_mu);
    if (!g_pack) g_pack = std::make_shared<DecodedPack>();
    std::string d = active_pack_dir();
    if (d != g_pack_last) {
        g_pack_last = d;
        g_pack->refresh(d);
    }
    return g_pack;
}

void reset_aa_singletons_for_test() {
    std::lock_guard<std::mutex> lk(g_aa_mu);
    g_idx = nullptr;
    g_idx_tried = false;
    std::lock_guard<std::mutex> lk2(g_pack_mu);
    g_pack = nullptr;
    g_pack_last = "\x01";
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
