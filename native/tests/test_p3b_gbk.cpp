// tests/test_p3b_gbk.cpp — W4-3 [p3b][posix-only]: validate the POSIX iconv
// branch of sa::p3b::gbk_replace_decode (server/services/p3b_fs_tools.cpp) that
// mirrors the Windows CP936 decoder's "errors=replace" semantics byte-for-byte:
// ASCII passthrough, a valid GBK pair -> one codepoint, and one U+FFFD per
// maximal bad subpart advancing a single byte (a lead with an out-of-range or
// missing trail, a lone 0xFF, a truncated lead at EOF).
//
// Windows is gated by the golden 38/38 + the existing Windows-only CP936
// oracle in test_cfg_store.cpp, so this file is #if !defined(_WIN32) — an empty
// TU on Windows, preserving the 275/3055 baseline while adding real coverage on
// the POSIX (WSL) side where iconv is the code path under test.
#include <catch_amalgamated.hpp>

#if !defined(_WIN32)

#include <string>

#include "p3b_fs_tools.h"

namespace {

std::string bytes(std::initializer_list<int> bs) {
    std::string s;
    for (int b : bs) s.push_back(static_cast<char>(b));
    return s;
}

}  // namespace

TEST_CASE("posix gbk: ASCII passes through untouched", "[p3b][posix-only]") {
    CHECK(sa::p3b::gbk_replace_decode("hello world") == "hello world");
}

TEST_CASE("posix gbk: valid multibyte decodes to UTF-8", "[p3b][posix-only]") {
    // "中文" -> GBK D6 D0 CE C4; "旧数据" -> BE C9 CA FD BE DD
    CHECK(sa::p3b::gbk_replace_decode(bytes({0xD6, 0xD0, 0xCE, 0xC4})) == "\xE4\xB8\xAD\xE6\x96\x87");
    CHECK(sa::p3b::gbk_replace_decode(bytes({0xBE, 0xC9})) == "\xE6\x97\xA7");
}

TEST_CASE("posix gbk: lone invalid byte -> single U+FFFD", "[p3b][posix-only]") {
    // 0xFF is neither ASCII nor a valid GBK lead -> U+FFFD, advance one byte.
    CHECK(sa::p3b::gbk_replace_decode(bytes({0xFF})) == "\xEF\xBF\xBD");
    // 0x80 is not a valid CP936 lead either (the gate is 0x81..0xFE).
    CHECK(sa::p3b::gbk_replace_decode(bytes({0x80})) == "\xEF\xBF\xBD");
}

TEST_CASE("posix gbk: truncated lead at EOF -> one U+FFFD", "[p3b][posix-only]") {
    // A lead 0xA1 with no following byte cannot form a pair -> U+FFFD.
    CHECK(sa::p3b::gbk_replace_decode(bytes({0xA1})) == "\xEF\xBF\xBD");
}

TEST_CASE("posix gbk: lead with out-of-range trail -> U+FFFD then trail",
          "[p3b][posix-only]") {
    // 0xA1 is a valid lead but 0x00 is not a valid trail (outside 0x40..0xFE,
    // excl. 0x7F): emit U+FFFD advancing only the lead, then decode the 0x00.
    std::string got = sa::p3b::gbk_replace_decode(bytes({0xA1, 0x00}));
    CHECK(got == std::string("\xEF\xBF\xBD", 3) + std::string(1, '\0'));
    // 0x7F is explicitly excluded from the trail range too.
    CHECK(sa::p3b::gbk_replace_decode(bytes({0xA1, 0x7F})) == "\xEF\xBF\xBD\x7F");
}

TEST_CASE("posix gbk: mixed valid + invalid advances per maximal subpart",
          "[p3b][posix-only]") {
    // "中" (D6 D0) then an invalid 0xFF -> U+FFFD: exactly what the Windows
    // branch yields (pair decoded, then the stray byte replaced singly).
    CHECK(sa::p3b::gbk_replace_decode(bytes({0xD6, 0xD0, 0xFF})) ==
          std::string("\xE4\xB8\xAD") + "\xEF\xBF\xBD");
}

TEST_CASE("posix gbk: empty input -> empty output", "[p3b][posix-only]") {
    CHECK(sa::p3b::gbk_replace_decode(std::string_view{}).empty());
}

#endif  // !_WIN32
