// wip/P3b support: shared primitives for the AI-domain / sandbox / attachment /
// resource-pack services (wave-2 group P3b).
//
// Everything here exists because P3b's four services need the same Python-
// semantics helpers: base64 (upload + tools read/write), a zip reader built on
// the vendored miniz amalgamation (docx/xlsx/resource packs/manifests), code-
// point-aware truncation (Python str[:n] is characters, not bytes) and the
// static game assets (schema.json / dicts.json) that GAME_SCHEMA + ROLE_DICT
// come from.
//
// Official layout at merge: this file moves to server/services/support_p3b.*
#pragma once

#include <cstdint>
#include <map>
#include <memory>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

#include <nlohmann/json.hpp>

namespace sa {

using json = nlohmann::ordered_json;

namespace p3b {

// ---------------------------------------------------------------------------
// base64
// ---------------------------------------------------------------------------

// base64.b64encode(raw).decode("ascii")
std::string b64_encode(std::string_view raw);

// base64.b64decode(data) — LENIENT (validate=False, fs_tools.write_file).
// Characters outside the alphabet are discarded first, exactly like CPython.
std::optional<std::string> b64_decode_loose(std::string_view data);

// base64.b64decode(data, validate=True) — STRICT (/api/ai/upload,
// /api/resource_packs/install). Any non-alphabet character (including
// whitespace and newlines) or bad padding/payload length is an error.
std::optional<std::string> b64_decode_strict(std::string_view data);

// ---------------------------------------------------------------------------
// text helpers with CPython semantics
// ---------------------------------------------------------------------------

// Number of UTF-8 code points in `s` (len(s) in Python).
size_t utf8_len(std::string_view s);

// s[:n] on code points, not bytes.
std::string utf8_head(std::string_view s, size_t n);

// Python str.strip(): trims Unicode whitespace. We cover the ASCII set plus
// U+00A0/U+3000/U+FEFF, which is what cfg text and AI payloads realistically
// carry (documented approximation).
std::string py_strip(std::string_view s);
std::string py_lstrip(std::string_view s);

// Python str(v) repr for error messages ("%r" of a JSON value). Strings use
// sa_core::py_repr_str; containers fall back to JSON text (deviation: Python
// repr uses single quotes — these messages are only substring-matched).
std::string py_repr(const json& v);

// Python truthiness of a JSON value: null/false/0/""/[]/{} falsy, everything
// else truthy.
bool json_truthy(const json& v);

// Python str(v) for a JSON value: strings raw, null "None", bools True/False,
// numbers repr; containers use the JSON text (deviation: single-quoted
// repr — these feed substring filters and truncation only).
std::string json_str(const json& v);

// float(str) with CPython tolerance: surrounding whitespace ok, "inf"/"nan"
// words (signed, "infinity" accepted); anything else -> nullopt.
std::optional<double> py_float_str(std::string_view s);

// strftime("%Y-%m-%dT%H:%M:%S") in local time (resource_pack manifest default).
std::string local_time_seconds();

// ---------------------------------------------------------------------------
// zip reader (vendored miniz, reader-only: MINIZ_NO_DEFLATE_APIS)
// ---------------------------------------------------------------------------

class ZipReader {
  public:
    // Returns nullopt on a malformed archive (zipfile.BadZipFile analogue).
    static std::optional<ZipReader> open_bytes(std::string_view data);
    static std::optional<ZipReader> open_file(const std::string& path);
    ZipReader(ZipReader&& o) noexcept;
    ZipReader& operator=(ZipReader&& o) noexcept;
    ~ZipReader();

    // zipfile.namelist() order (archive order).
    std::vector<std::string> names() const;
    bool has(const std::string& name) const;
    // zipfile.getinfo(name).file_size (uncompressed size); nullopt: no entry.
    std::optional<long long> uncompressed_size(const std::string& name) const;
    // zipfile.read(name); nullopt when the entry is missing or unreadable.
    std::optional<std::string> read(const std::string& name) const;
    // zipfile.extractall(dest): creates directories, skips entry names that
    // would escape dest. Returns false on any IO failure (caller cleans up).
    bool extract_all(const std::string& dest) const;

  private:
    ZipReader();  // out-of-line in the .cpp — Impl is incomplete here.
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

// ---------------------------------------------------------------------------
// static game assets (schema.json / dicts.json)
// ---------------------------------------------------------------------------

// editor.core.game_schema.GAME_SCHEMA: {cfg: {field: type}}. Empty when the
// asset cannot be located (mirrors the `except Exception: GAME_SCHEMA = {}`
// guard at ai_domain_service.py:23-26).
const json& game_schema();

// data_dicts.ROLE_DICT equivalent: dicts.json game_dicts.roles (id -> name).
const json& role_dict();

// _FIELD_CN (ai_domain_service.py:377-395): the nine DEFAULT_*_KEY_MAP merges
// from dicts.json key_maps, first occurrence wins.
const std::map<std::string, std::string>& field_cn();

// Locate an asset file — thin forward to sa_core::assets::find_asset (the
// single resolver; candidate list documented in sa_core/assets.h).
// "" when missing.
std::string find_asset(const std::string& filename);

}  // namespace p3b
}  // namespace sa
