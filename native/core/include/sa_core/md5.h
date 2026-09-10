// sa_core: MD5 (RFC 1321) for the bundled-zip version fingerprint.
//
// Python side: hashlib.md5(...).hexdigest() (editor/server/__init__.py:39-41,
// _extract_bundled) — W4-4 added this because the Android distribution channel
// dropped Chaquopy and the .bundled_version skip fingerprint must be computed
// natively. Lowercase hex, identical to Python for any input.
#pragma once

#include <string>
#include <string_view>

namespace sa_core {

// Lowercase hex digest of the byte string, e.g. md5_hex("") ==
// "d41d8cd98f00b204e9800998ecf8427e".
std::string md5_hex(std::string_view data);

}  // namespace sa_core
