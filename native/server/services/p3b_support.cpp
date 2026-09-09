// wip/P3b support implementation — see p3b_support.h for the contract.
#include "p3b_support.h"

#include <cctype>
#include <cmath>
#include <cstring>
#include <cstdlib>
#include <ctime>
#include <mutex>

#include "p3b_miniz_config.h"

#include "sa_core/assets.h"
#include "sa_core/json_wire.h"
#include "sa_core/paths.h"
#include "sa_core/strings.h"
#include "sa_core/utf8.h"
#include "sa_core/util.h"

namespace sa {
namespace p3b {
namespace {

bool is_b64_char(char c) {
    return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') ||
           c == '+' || c == '/';
}

int b64_val(char c) {
    if (c >= 'A' && c <= 'Z') return c - 'A';
    if (c >= 'a' && c <= 'z') return c - 'a' + 26;
    if (c >= '0' && c <= '9') return c - '0' + 52;
    if (c == '+') return 62;
    if (c == '/') return 63;
    return -1;
}

// base64.b64decode core. `strict` == validate=True: the input must fullmatch
// [A-Za-z0-9+/]*={0,2} before decoding (CPython's re-check), and the padding
// rules of binascii.a2b_base64 apply. `loose` discards every character
// outside the alphabet first — CPython's default behavior.
std::optional<std::string> b64_decode(std::string_view data, bool strict) {
    std::string cleaned;
    if (strict) {
        for (const char c : data) {
            if (!is_b64_char(c) && c != '=') return std::nullopt;
        }
        cleaned.assign(data);
    } else {
        cleaned.reserve(data.size());
        for (const char c : data) {
            if (is_b64_char(c) || c == '=') cleaned.push_back(c);
        }
    }
    if (cleaned.empty()) return std::string();
    if (cleaned.size() % 4 != 0) return std::nullopt;
    // '=' only allowed as trailing padding, at most 2 chars.
    size_t pad = 0;
    while (pad < cleaned.size() && cleaned[cleaned.size() - 1 - pad] == '=') ++pad;
    if (pad > 2) return std::nullopt;
    for (size_t i = 0; i + pad < cleaned.size(); ++i) {
        if (cleaned[i] == '=') return std::nullopt;  // padding in the middle
    }
    const size_t groups = cleaned.size() / 4;
    std::string out;
    out.reserve(groups * 3);
    for (size_t g = 0; g < groups; ++g) {
        int quad[4];
        for (int k = 0; k < 4; ++k) {
            const char c = cleaned[g * 4 + k];
            quad[k] = (c == '=') ? 0 : b64_val(c);
            if (quad[k] < 0) return std::nullopt;
        }
        const unsigned v = (static_cast<unsigned>(quad[0]) << 18) |
                           (static_cast<unsigned>(quad[1]) << 12) |
                           (static_cast<unsigned>(quad[2]) << 6) |
                           static_cast<unsigned>(quad[3]);
        out.push_back(static_cast<char>((v >> 16) & 0xFF));
        if (cleaned[g * 4 + 2] != '=') out.push_back(static_cast<char>((v >> 8) & 0xFF));
        if (cleaned[g * 4 + 3] != '=') out.push_back(static_cast<char>(v & 0xFF));
    }
    return out;
}

// Python's str.strip() whitespace set (approximated: ASCII blanks + the
// Unicode separators that realistically appear in mod text / AI payloads).
bool is_py_space_cp(unsigned long cp) {
    switch (cp) {
        case 0x20: case 0x09: case 0x0A: case 0x0B: case 0x0C: case 0x0D:
        case 0x85: case 0xA0: case 0x1680:
        case 0x2000: case 0x2001: case 0x2002: case 0x2003: case 0x2004: case 0x2005:
        case 0x2006: case 0x2007: case 0x2008: case 0x2009: case 0x200A:
        case 0x2028: case 0x2029: case 0x202F: case 0x205F: case 0x3000: case 0xFEFF:
            return true;
        default:
            return false;
    }
}

// Decode `s` into (code point, byte offset) pairs; invalid bytes map to U+FFFD
// so offsets still advance one byte at a time (never a hang).
std::vector<std::pair<unsigned long, size_t>> utf8_spans(std::string_view s) {
    std::vector<std::pair<unsigned long, size_t>> out;
    size_t i = 0;
    while (i < s.size()) {
        const unsigned char c = static_cast<unsigned char>(s[i]);
        size_t need = 0;
        unsigned long cp = 0;
        if (c < 0x80) { need = 1; cp = c; }
        else if ((c & 0xE0) == 0xC0) { need = 2; cp = c & 0x1Fu; }
        else if ((c & 0xF0) == 0xE0) { need = 3; cp = c & 0x0Fu; }
        else if ((c & 0xF8) == 0xF0) { need = 4; cp = c & 0x07u; }
        bool ok = need && i + need <= s.size();
        for (size_t k = 1; ok && k < need; ++k) {
            const unsigned char cc = static_cast<unsigned char>(s[i + k]);
            if ((cc & 0xC0) != 0x80) { ok = false; break; }
            cp = (cp << 6) | (cc & 0x3Fu);
        }
        if (!ok) {
            out.emplace_back(0xFFFDu, i);
            ++i;
            continue;
        }
        out.emplace_back(cp, i);
        i += need;
    }
    return out;
}

json load_asset(const std::string& filename) {
    const std::string p = find_asset(filename);
    if (p.empty()) return json();
    auto raw = sa_core::paths::read_bytes(p);
    if (!raw) return json();
    auto text = sa_core::decode_utf8_sig_strict(*raw);
    if (!text) text = sa_core::decode_utf8_sig_replace(*raw);
    json parsed = json::parse(*text, nullptr, false);
    if (parsed.is_discarded()) return json();
    return parsed;
}

}  // namespace

// ---------------------------------------------------------------------------
// base64
// ---------------------------------------------------------------------------

std::string b64_encode(std::string_view raw) {
    static const char* kAlpha =
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    std::string out;
    out.reserve(((raw.size() + 2) / 3) * 4);
    size_t i = 0;
    for (; i + 3 <= raw.size(); i += 3) {
        const unsigned v = (static_cast<unsigned>(static_cast<unsigned char>(raw[i])) << 16) |
                           (static_cast<unsigned>(static_cast<unsigned char>(raw[i + 1])) << 8) |
                           static_cast<unsigned>(static_cast<unsigned char>(raw[i + 2]));
        out.push_back(kAlpha[(v >> 18) & 63]);
        out.push_back(kAlpha[(v >> 12) & 63]);
        out.push_back(kAlpha[(v >> 6) & 63]);
        out.push_back(kAlpha[v & 63]);
    }
    const size_t rem = raw.size() - i;
    if (rem == 1) {
        const unsigned v = static_cast<unsigned>(static_cast<unsigned char>(raw[i])) << 16;
        out.push_back(kAlpha[(v >> 18) & 63]);
        out.push_back(kAlpha[(v >> 12) & 63]);
        out += "==";
    } else if (rem == 2) {
        const unsigned v = (static_cast<unsigned>(static_cast<unsigned char>(raw[i])) << 16) |
                           (static_cast<unsigned>(static_cast<unsigned char>(raw[i + 1])) << 8);
        out.push_back(kAlpha[(v >> 18) & 63]);
        out.push_back(kAlpha[(v >> 12) & 63]);
        out.push_back(kAlpha[(v >> 6) & 63]);
        out.push_back('=');
    }
    return out;
}

std::optional<std::string> b64_decode_loose(std::string_view data) {
    return b64_decode(data, false);
}

std::optional<std::string> b64_decode_strict(std::string_view data) {
    return b64_decode(data, true);
}

// ---------------------------------------------------------------------------
// text helpers
// ---------------------------------------------------------------------------

size_t utf8_len(std::string_view s) {
    size_t n = 0;
    for (size_t i = 0; i < s.size(); ++i) {
        if ((static_cast<unsigned char>(s[i]) & 0xC0) != 0x80) ++n;
    }
    return n;
}

std::string utf8_head(std::string_view s, size_t n) {
    size_t seen = 0;
    for (size_t i = 0; i < s.size(); ++i) {
        if ((static_cast<unsigned char>(s[i]) & 0xC0) != 0x80) {
            if (seen == n) return std::string(s.substr(0, i));
            ++seen;
        }
    }
    return std::string(s);
}

std::string py_strip(std::string_view s) {
    const auto spans = utf8_spans(s);
    if (spans.empty()) return {};
    size_t first = 0, last = spans.size();
    while (first < last && is_py_space_cp(spans[first].first)) ++first;
    while (last > first && is_py_space_cp(spans[last - 1].first)) --last;
    if (first == last) return {};
    const size_t begin = spans[first].second;
    size_t end = s.size();
    if (last < spans.size()) {
        // End offset = byte start of the first non-kept span.
        end = spans[last].second;
    }
    return std::string(s.substr(begin, end - begin));
}

std::string py_lstrip(std::string_view s) {
    const auto spans = utf8_spans(s);
    size_t first = 0;
    while (first < spans.size() && is_py_space_cp(spans[first].first)) ++first;
    if (first == spans.size()) return {};
    return std::string(s.substr(spans[first].second));
}

std::string py_repr(const json& v) {
    if (v.is_string()) return sa_core::py_repr_str(v.get<std::string>());
    if (v.is_object() || v.is_array()) return sa_core::py_dumps(v);
    return sa_core::py_str(v);
}

bool json_truthy(const json& v) {
    if (v.is_null()) return false;
    if (v.is_boolean()) return v.get<bool>();
    if (v.is_number_integer()) return v.get<long long>() != 0;
    if (v.is_number_unsigned()) return v.get<unsigned long long>() != 0;
    if (v.is_number_float()) return v.get<double>() != 0.0;
    if (v.is_string()) return !v.get_ref<const std::string&>().empty();
    if (v.is_object() || v.is_array()) return !v.empty();
    return true;
}

std::string json_str(const json& v) {
    if (v.is_string()) return v.get<std::string>();
    if (v.is_object() || v.is_array()) return sa_core::py_dumps(v);
    return sa_core::py_str(v);
}

std::optional<double> py_float_str(std::string_view sv) {
    std::string t = sa_core::str::trim(sv);
    if (t.empty()) return std::nullopt;
    std::string lower;
    for (char c : t) lower.push_back(static_cast<char>(std::tolower(static_cast<unsigned char>(c))));
    if (lower == "inf" || lower == "+inf" || lower == "infinity" || lower == "+infinity")
        return HUGE_VAL;
    if (lower == "-inf" || lower == "-infinity") return -HUGE_VAL;
    if (lower == "nan" || lower == "+nan" || lower == "-nan") return NAN;
    errno = 0;
    const char* begin = t.c_str();
    char* end = nullptr;
    const double d = std::strtod(begin, &end);
    if (end != begin + t.size()) return std::nullopt;
    return d;  // ERANGE overflow -> inf, matching float("1e999")
}

std::string local_time_seconds() {
    std::tm tmv{};
    const std::time_t now = std::time(nullptr);
#ifdef _WIN32
    localtime_s(&tmv, &now);
#else
    localtime_r(&now, &tmv);
#endif
    char buf[32];
    std::snprintf(buf, sizeof(buf), "%04d-%02d-%02dT%02d:%02d:%02d", tmv.tm_year + 1900,
                  tmv.tm_mon + 1, tmv.tm_mday, tmv.tm_hour, tmv.tm_min, tmv.tm_sec);
    return buf;
}

// ---------------------------------------------------------------------------
// ZipReader (miniz, reader-only build — see miniz_reader_tu.cpp)
// ---------------------------------------------------------------------------

struct ZipReader::Impl {
    mz_zip_archive zip;
    // Byte-buffer archives are served through positional reads on this string;
    // Impl is heap-allocated and never moved, so &data stays a stable opaque.
    std::string data;
    bool ok = false;
};

namespace {
size_t mz_mem_read(void* pOpaque, mz_uint64 file_ofs, void* pBuf, size_t n) {
    const auto* data = static_cast<const std::string*>(pOpaque);
    if (file_ofs >= data->size()) return 0;
    const size_t avail = data->size() - static_cast<size_t>(file_ofs);
    const size_t take = n < avail ? n : avail;
    std::memcpy(pBuf, data->data() + static_cast<size_t>(file_ofs), take);
    return take;
}
}  // namespace

ZipReader::ZipReader() = default;
ZipReader::ZipReader(ZipReader&& o) noexcept = default;
ZipReader& ZipReader::operator=(ZipReader&& o) noexcept = default;

ZipReader::~ZipReader() {
    if (impl_ && impl_->ok) mz_zip_reader_end(&impl_->zip);
}

std::optional<ZipReader> ZipReader::open_bytes(std::string_view data) {
    ZipReader r;
    r.impl_ = std::make_unique<Impl>();
    std::memset(&r.impl_->zip, 0, sizeof(mz_zip_archive));
    r.impl_->data.assign(data);
    r.impl_->zip.m_pRead = &mz_mem_read;
    r.impl_->zip.m_pIO_opaque = &r.impl_->data;
    if (r.impl_->data.empty() ||
        !mz_zip_reader_init(&r.impl_->zip, r.impl_->data.size(),
                            MZ_ZIP_FLAG_DO_NOT_SORT_CENTRAL_DIRECTORY)) {
        return std::nullopt;
    }
    r.impl_->ok = true;
    return r;
}

std::optional<ZipReader> ZipReader::open_file(const std::string& path) {
    ZipReader r;
    r.impl_ = std::make_unique<Impl>();
    std::memset(&r.impl_->zip, 0, sizeof(mz_zip_archive));
    if (!mz_zip_reader_init_file(&r.impl_->zip, path.c_str(),
                                 MZ_ZIP_FLAG_DO_NOT_SORT_CENTRAL_DIRECTORY)) {
        return std::nullopt;
    }
    r.impl_->ok = true;
    return r;
}

std::vector<std::string> ZipReader::names() const {
    std::vector<std::string> out;
    if (!impl_ || !impl_->ok) return out;
    const mz_uint n = mz_zip_reader_get_num_files(&impl_->zip);
    for (mz_uint i = 0; i < n; ++i) {
        mz_zip_archive_file_stat st;
        if (!mz_zip_reader_file_stat(&impl_->zip, i, &st)) continue;
        out.emplace_back(st.m_filename);
    }
    return out;
}

bool ZipReader::has(const std::string& name) const {
    if (!impl_ || !impl_->ok) return false;
    return mz_zip_reader_locate_file(&impl_->zip, name.c_str(), nullptr, 0) >= 0;
}

std::optional<long long> ZipReader::uncompressed_size(const std::string& name) const {
    if (!impl_ || !impl_->ok) return std::nullopt;
    const int idx = mz_zip_reader_locate_file(&impl_->zip, name.c_str(), nullptr, 0);
    if (idx < 0) return std::nullopt;
    mz_zip_archive_file_stat st;
    if (!mz_zip_reader_file_stat(&impl_->zip, static_cast<mz_uint>(idx), &st)) return std::nullopt;
    return static_cast<long long>(st.m_uncomp_size);
}

std::optional<std::string> ZipReader::read(const std::string& name) const {
    if (!impl_ || !impl_->ok) return std::nullopt;
    size_t size = 0;
    void* p = mz_zip_reader_extract_file_to_heap(&impl_->zip, name.c_str(), &size, 0);
    if (!p) return std::nullopt;
    std::string out(static_cast<const char*>(p), size);
    mz_free(p);
    return out;
}

bool ZipReader::extract_all(const std::string& dest) const {
    if (!impl_ || !impl_->ok) return false;
    const mz_uint n = mz_zip_reader_get_num_files(&impl_->zip);
    for (mz_uint i = 0; i < n; ++i) {
        mz_zip_archive_file_stat st;
        if (!mz_zip_reader_file_stat(&impl_->zip, i, &st)) return false;
        const std::string rel = sa_core::str::replace_all(std::string(st.m_filename), "\\", "/");
        // zipfile.extractall sanitizes members; here an unsafe name is a hard
        // failure (resource_pack._install_zip pre-validates every entry, so a
        // rejection means someone handed us a hostile archive directly).
        if (rel.empty() || rel[0] == '/' || rel.find(':') != std::string::npos ||
            rel.find("..") != std::string::npos) {
            return false;
        }
        const std::string target = sa_core::paths::join(dest, rel);
        if (st.m_is_directory) {
            if (!sa_core::paths::create_dirs(target)) return false;
            continue;
        }
        if (!sa_core::paths::create_dirs(sa_core::paths::dirname(target))) return false;
        if (!mz_zip_reader_extract_file_to_file(&impl_->zip, st.m_filename, target.c_str(), 0)) {
            return false;
        }
    }
    return true;
}

// ---------------------------------------------------------------------------
// assets
// ---------------------------------------------------------------------------

std::string find_asset(const std::string& filename) {
    // The old local candidate list (env, exe_dir up to ../../, cwd) only
    // resolved the official build/ layout — an archive-verify build placed
    // beside native/ failed four p3b-domain cases on missing schema.json.
    // No cache anymore: load_asset only feeds the static-once
    // schema/dicts/field_cn singletons.
    return sa_core::assets::find_asset(filename);
}

const json& game_schema() {
    static const json kSchema = [] {
        json d = load_asset("schema.json");
        return d.is_object() ? d : json::object();
    }();
    return kSchema;
}

const json& role_dict() {
    static const json kRoles = [] {
        json d = load_asset("dicts.json");
        if (d.is_object() && d.contains("game_dicts") && d["game_dicts"].is_object() &&
            d["game_dicts"].contains("roles") && d["game_dicts"]["roles"].is_object()) {
            return d["game_dicts"]["roles"];
        }
        return json::object();
    }();
    return kRoles;
}

const std::map<std::string, std::string>& field_cn() {
    static const std::map<std::string, std::string> kFieldCn = [] {
        std::map<std::string, std::string> out;
        const json d = load_asset("dicts.json");
        if (!d.is_object() || !d.contains("key_maps") || !d["key_maps"].is_object()) return out;
        // ai_domain_service._load_field_cn order: EVT, TALK, OPT, PERSON, GROW,
        // KZONE, PHONE, GIFT, INTERACT — first occurrence wins (setdefault).
        static const char* kOrder[] = {"EvtCfg",       "TalkCfg",         "OptionCfg",
                                       "PersonCfg",    "PersonGrowCfg",   "KZoneContentCfg",
                                       "PhoneMsgCfg",  "GiftEvtCfg",      "InteractCfg"};
        for (const char* map_name : kOrder) {
            if (!d["key_maps"].contains(map_name)) continue;
            const json& m = d["key_maps"].at(map_name);
            if (!m.is_object()) continue;
            for (auto it = m.begin(); it != m.end(); ++it) {
                if (!it.value().is_string()) continue;
                out.emplace(it.key(), it.value().get<std::string>());
            }
        }
        return out;
    }();
    return kFieldCn;
}

}  // namespace p3b
}  // namespace sa
