// MD5 unit tests — companion to the sha1 cases in test_cfg_store.cpp (that TU
// is excluded on POSIX, so the W4-4 bundled-zip fingerprint digest gets its own
// glob-collected TU to run green on both the Windows gate and WSL).
//
// Expected values cross-verified against CPython 3.12 hashlib.md5(...).hexdigest()
// (the truth source for _extract_bundled's fingerprint in
// backend/editor/server/__init__.py:39-41) plus the RFC 1321 appendix vectors.
#include <catch_amalgamated.hpp>

#include <string>

#include "sa_core/md5.h"

TEST_CASE("md5_hex matches hashlib", "[digest][md5]") {
    // RFC 1321 test suite (all four), the empty-string digest that
    // _extract_bundled produces for an unreadable/short zip head, and a
    // 1,000,000-'a' case that exercises multi-block compression + padding.
    CHECK(sa_core::md5_hex("") == "d41d8cd98f00b204e9800998ecf8427e");
    CHECK(sa_core::md5_hex("a") == "0cc175b9c0f1b6a831c399e269772661");
    CHECK(sa_core::md5_hex("abc") == "900150983cd24fb0d6963f7d28e17f72");
    CHECK(sa_core::md5_hex("message digest") == "f96b697d7cb7938d525a2f31aaf161d0");
    CHECK(sa_core::md5_hex("abcdefghijklmnopqrstuvwxyz") ==
          "c3fcd3d76192e4007dfb496cca67e13b");
    CHECK(sa_core::md5_hex(
              "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789") ==
          "d174ab98d277d9f5a5611c2c9f419d9f");
    CHECK(sa_core::md5_hex("1234567890123456789012345678901234567890"
                           "1234567890123456789012345678901234567890") ==
          "57edf4a22be3c955ac49da2e2107b67a");
    CHECK(sa_core::md5_hex("The quick brown fox jumps over the lazy dog") ==
          "9e107d9d372bb6826bd81d3542a419d6");
    // 1 MB is exactly what _extract_bundled hashes (read(1 << 20)); this length
    // is the real-world input shape for the fingerprint.
    CHECK(sa_core::md5_hex(std::string(1000000, 'a')) ==
          "7707d6ae4e027c70eea2a935c2296f21");
    // Non-ASCII / embedded NUL bytes must digest the raw bytes, not a
    // UTF-8-interpretation — the zip head is binary.
    CHECK(sa_core::md5_hex(std::string("\x00\x01\x02\xff", 4)) ==
          "0416dab819887333af831f8c765ac2ae");
}
