// sa_core: UTF-8 codec mirroring CPython's utf-8 / utf-8-sig decoders.
//
// Python semantic sources:
//   * cfg_store.read_lossy / _read_text_from (cfg_store.py:89-121): strict
//     utf-8-sig decode; on UnicodeDecodeError retry with errors="replace".
//   * BOM handling (cfg_store.py:237-242, atomic_io.py:29): "utf-8-sig" strips
//     a leading EF BB BF on read; on write the BOM is re-prepended verbatim.
//
// CPython's "replace" error handler emits exactly one U+FFFD per maximal
// subpart of an ill-formed sequence (Unicode UAX#39 default behavior, which
// CPython's codec implements); byte-per-subpart would diverge on 4-byte
// truncations. decode_utf8_replace() reproduces the maximal-subpart rule.
#pragma once

#include <optional>
#include <string>
#include <string_view>

namespace sa_core {

// BOM bytes as Python atomic_io.BOM (b"\xef\xbb\xbf").
inline constexpr std::string_view kBom = "\xef\xbb\xbf";

// Strip one leading BOM if present (mirrors utf-8-sig decode; Python's
// "utf-8-sig" only ever removes a leading BOM).
std::string_view lstrip_bom(std::string_view raw);

bool starts_with_bom(std::string_view raw);

// Strict UTF-8 validation + decode to std::u32string?  We only need validity
// plus the (BOM-stripped) text; return nullopt when invalid.
std::optional<std::string> decode_utf8_sig_strict(std::string_view raw);

// Decode like `raw.decode("utf-8-sig", errors="replace")`: BOM stripped, each
// invalid maximal subpart replaced by one U+FFFD (encoded back to UTF-8).
std::string decode_utf8_sig_replace(std::string_view raw);

// True when `raw` is valid UTF-8 after an optional leading BOM.
bool is_utf8(std::string_view raw);

// UTF-8 encode a single code point (surrogates encode to U+FFFD).
void append_codepoint(std::string& out, unsigned cp);

}  // namespace sa_core
