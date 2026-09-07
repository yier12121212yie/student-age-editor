// Unit tests for sa_core string utilities and identity constants.
#include <string>

#include <catch_amalgamated.hpp>

#include "sa_core/strings.h"
#include "sa_core/version.h"

using sa_core::str::ends_with;
using sa_core::str::replace_all;
using sa_core::str::starts_with;
using sa_core::str::trim;

TEST_CASE("version and app identity constants are populated") {
    REQUIRE(std::string(sa_core::version()) == "0.1.0");
    CHECK(sa_core::kVersionMajor == 0);
    CHECK(sa_core::kVersionMinor == 1);
    REQUIRE(std::string(sa_core::app_name()) == "student-age-editor");
}

TEST_CASE("trim strips ASCII whitespace on both ends") {
    CHECK(trim("  hello \t\n") == "hello");
    CHECK(trim("   ") == "");
    CHECK(trim("") == "");
    CHECK(trim("no_change") == "no_change");
    CHECK(trim("\r\n\t x\v\f ") == "x");
}

TEST_CASE("starts_with / ends_with handle boundaries") {
    CHECK(starts_with("/api/ping", "/api/"));
    CHECK_FALSE(starts_with("/api/ping", "/apis/"));
    CHECK(starts_with("", ""));
    CHECK_FALSE(starts_with("", "/"));
    CHECK(ends_with("backend.exe", ".exe"));
    CHECK_FALSE(ends_with("backend", ".exe"));
}

TEST_CASE("replace_all substitutes every occurrence") {
    CHECK(replace_all("a/b/c", "/", "//") == "a//b//c");
    CHECK(replace_all("aaa", "aa", "b") == "ba");  // non-overlapping, left-to-right
    CHECK(replace_all("nothing", "xyz", "!") == "nothing");
    CHECK(replace_all("keep", "", "Z") == "keep");  // empty needle -> unchanged
}
