// sa_core: SHA-1 (RFC 3174) for cfg_store conflict digests.
//
// Python side: hashlib.sha1(raw).hexdigest() (cfg_store.py:257) — expect_digest
// optimistic locking (B6: Windows mtime granularity ~15.6ms misses same-tick
// external edits, so content digest wins over mtime when both are given).
#pragma once

#include <string>
#include <string_view>

namespace sa_core {

// Lowercase hex digest of the byte string, e.g. sha1_hex("") ==
// "da39a3ee5e6b4b0d3255bfef95601890afd80709".
std::string sha1_hex(std::string_view data);

}  // namespace sa_core
