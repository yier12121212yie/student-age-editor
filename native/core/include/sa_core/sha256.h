// sa_core: SHA-256 (FIPS 180-4) for the workspace revision fingerprint.
//
// Self-contained like sha1/md5 on purpose: the Android NDK cross-build has no
// OpenSSL, and the server previously pulled EVP_Digest through
// cpp-httplib + find_package(OpenSSL) just for this one call.
// Python side: hashlib.sha256(raw).hexdigest().
#pragma once

#include <string>
#include <string_view>

namespace sa_core {

// Lowercase hex digest, e.g. sha256_hex("abc") ==
// "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad".
std::string sha256_hex(std::string_view data);

}  // namespace sa_core
