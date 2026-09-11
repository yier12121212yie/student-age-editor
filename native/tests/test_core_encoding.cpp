// [core][encoding] — UTF-16 -> UTF-8 decoding and UTF-8-safe environment access.
//
// These cover the two encoding fixes: getenv_utf8/setenv_utf8 must round-trip a
// non-ASCII value regardless of the Windows ANSI codepage (a Chinese USERPROFILE
// used to come back as mojibake), and utf16_to_utf8 must decode surrogate pairs
// (the JNI GetStringChars path) instead of emitting CESU-8.
#include <string>

#include <catch_amalgamated.hpp>

#include "sa_core/paths.h"
#include "sa_core/utf8.h"

namespace {

// RAII restore for the env var the round-trip case writes.
struct ScopedEnvValue {
    std::string key;
    std::string saved;
    bool had;
    explicit ScopedEnvValue(const std::string& k) : key(k) {
        saved = sa_core::paths::getenv_utf8(k.c_str());
        had = !saved.empty();
    }
    ~ScopedEnvValue() {
        if (had) sa_core::paths::setenv_utf8(key.c_str(), saved, true);
        else sa_core::paths::setenv_utf8(key.c_str(), "", true);
    }
    ScopedEnvValue(const ScopedEnvValue&) = delete;
    ScopedEnvValue& operator=(const ScopedEnvValue&) = delete;
};

}  // namespace

TEST_CASE("utf16_to_utf8 decodes BMP text", "[core][encoding]") {
    const char16_t in[] = {u'\u4F60', u'\u597D', u'!', 0};  // 你好!
    CHECK(sa_core::utf16_to_utf8(in, 3) == "\xE4\xBD\xA0\xE5\xA5\xBD!");
}

TEST_CASE("utf16_to_utf8 joins a surrogate pair into one code point", "[core][encoding]") {
    // U+1F600 GRINNING FACE = D83D DE00. Modified UTF-8 would emit two CESU-8
    // sequences; standard UTF-8 is the single 4-byte F0 9F 98 80.
    const char16_t in[] = {static_cast<char16_t>(0xD83D), static_cast<char16_t>(0xDE00), 0};
    CHECK(sa_core::utf16_to_utf8(in, 2) == "\xF0\x9F\x98\x80");
}

TEST_CASE("utf16_to_utf8 replaces unpaired surrogates with U+FFFD", "[core][encoding]") {
    const char16_t lone_high[] = {static_cast<char16_t>(0xD83D), 0};
    CHECK(sa_core::utf16_to_utf8(lone_high, 1) == "\xEF\xBF\xBD");
    const char16_t lone_low[] = {static_cast<char16_t>(0xDE00), 0};
    CHECK(sa_core::utf16_to_utf8(lone_low, 1) == "\xEF\xBF\xBD");
}

TEST_CASE("getenv_utf8/setenv_utf8 round-trip a non-ASCII value", "[core][encoding]") {
    // The value is deliberately CJK + an astral emoji: on Windows this would
    // fail through the ANSI CRT path in both directions. (/utf-8 makes these
    // narrow literals UTF-8 bytes.)
    const std::string key = "SA_TEST_UTF8_ENV";
    ScopedEnvValue guard(key);
    const std::string value = "中文路径\\Mods\\\U0001F600";
    REQUIRE(sa_core::paths::setenv_utf8(key.c_str(), value, true));
    CHECK(sa_core::paths::getenv_utf8(key.c_str()) == value);

    // Missing name -> empty (not a crash / not "null").
    CHECK(sa_core::paths::getenv_utf8("SA_TEST_UTF8_ENV_DEFINITELY_UNSET").empty());
}

TEST_CASE("setenv_utf8 non-overwrite leaves an existing value alone", "[core][encoding]") {
    const std::string key = "SA_TEST_UTF8_KEEP";
    ScopedEnvValue guard(key);
    REQUIRE(sa_core::paths::setenv_utf8(key.c_str(), "第一", true));
    REQUIRE(sa_core::paths::setenv_utf8(key.c_str(), "第二", false));  // setdefault
    CHECK(sa_core::paths::getenv_utf8(key.c_str()) == "第一");
}
