// W4-4: tests for sa::extract_bundled (native port of
// editor/server/__init__.py:32-62 _extract_bundled) and sa_core::md5_hex.
//
// Zip fixtures are base64 built with Python zipfile (same approach as
// test_plugins.cpp / p3b_zip_fixtures.h; generator kept at wip/W44/
// gen_zip_fixtures.py). The embedded kV*Md5 constants are
// hashlib.md5(blob[:1MiB]).hexdigest() — so the assertions cross-validate the
// C++ MD5 against CPython directly.
//
// Portable by design (std::filesystem + sa_core::paths only): runs green on
// both the Windows gate and WSL.
#include <algorithm>
#include <chrono>
#include <filesystem>
#include <fstream>
#include <map>
#include <string>

#include <catch_amalgamated.hpp>

#include "sa_core/http_client.h"  // b64_decode
#include "sa_core/md5.h"
#include "sa_core/paths.h"
#include "server/android_bundled.h"

namespace fs = std::filesystem;

namespace {

// ---- fixtures (native/wip/W44/gen_zip_fixtures.py, Python 3.12 zipfile) ---
static const char kV1ZipB64[] =
        "UEsDBBQAAAAAAABgKl2dmBIEDgAAAA4AAAAJAAAAcGxhaW4udHh0aGVsbG8gYnVuZGxlZApQSwMEFAAAAAAAAGAqXQAAAAAA"
    "AAAAAAAAAAYAAABtZWRpYS9QSwMEFAAAAAAAAGAqXSrfwLAAAwAAAAMAAA4AAABtZWRpYS9zb25nLmRhdAABAgMEBQYHCAkK"
    "CwwNDg8QERITFBUWFxgZGhscHR4fICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj9AQUJDREVGR0hJSktMTU5PUFFS"
    "U1RVVldYWVpbXF1eX2BhYmNkZWZnaGlqa2xtbm9wcXJzdHV2d3h5ent8fX5/gIGCg4SFhoeIiYqLjI2Oj5CRkpOUlZaXmJma"
    "m5ydnp+goaKjpKWmp6ipqqusra6vsLGys7S1tre4ubq7vL2+v8DBwsPExcbHyMnKy8zNzs/Q0dLT1NXW19jZ2tvc3d7f4OHi"
    "4+Tl5ufo6err7O3u7/Dx8vP09fb3+Pn6+/z9/v8AAQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyAhIiMkJSYnKCkq"
    "KywtLi8wMTIzNDU2Nzg5Ojs8PT4/QEFCQ0RFRkdISUpLTE1OT1BRUlNUVVZXWFlaW1xdXl9gYWJjZGVmZ2hpamtsbW5vcHFy"
    "c3R1dnd4eXp7fH1+f4CBgoOEhYaHiImKi4yNjo+QkZKTlJWWl5iZmpucnZ6foKGio6SlpqeoqaqrrK2ur7CxsrO0tba3uLm6"
    "u7y9vr/AwcLDxMXGx8jJysvMzc7P0NHS09TV1tfY2drb3N3e3+Dh4uPk5ebn6Onq6+zt7u/w8fLz9PX29/j5+vv8/f7/AAEC"
    "AwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8gISIjJCUmJygpKissLS4vMDEyMzQ1Njc4OTo7PD0+P0BBQkNERUZHSElK"
    "S0xNTk9QUVJTVFVWV1hZWltcXV5fYGFiY2RlZmdoaWprbG1ub3BxcnN0dXZ3eHl6e3x9fn+AgYKDhIWGh4iJiouMjY6PkJGS"
    "k5SVlpeYmZqbnJ2en6ChoqOkpaanqKmqq6ytrq+wsbKztLW2t7i5uru8vb6/wMHCw8TFxsfIycrLzM3Oz9DR0tPU1dbX2Nna"
    "29zd3t/g4eLj5OXm5+jp6uvs7e7v8PHy8/T19vf4+fr7/P3+/1BLAwQUAAAAAAAAYCpd+Luf9A8AAAAPAAAAFQAAAHN1Yi9p"
    "bm5lci9uZXN0ZWQuanNvbnsiayI6ICLkuK3mlocifVBLAwQUAAAAAAAAYCpdlwa5pBAAAAAQAAAADQAAAC4uL2VzY2FwZS50"
    "eHRtdXN0IG5ldmVyIGV4aXN0UEsDBBQAAAAAAABgKl2XBrmkEAAAABAAAAAIAAAAL2Ficy50eHRtdXN0IG5ldmVyIGV4aXN0"
    "UEsDBBQAAAAAAABgKl2XBrmkEAAAABAAAAALAAAAZHJpdmU6Yy50eHRtdXN0IG5ldmVyIGV4aXN0UEsDBBQAAAAAAABgKl2X"
    "BrmkEAAAABAAAAAQAAAAb2svLi4vLi4vYmFkLnR4dG11c3QgbmV2ZXIgZXhpc3RQSwECFAAUAAAAAAAAYCpdnZgSBA4AAAAO"
    "AAAACQAAAAAAAAAAAAAAgAEAAAAAcGxhaW4udHh0UEsBAhQAFAAAAAAAAGAqXQAAAAAAAAAAAAAAAAYAAAAAAAAAAAAAAIAB"
    "NQAAAG1lZGlhL1BLAQIUABQAAAAAAABgKl0q38CwAAMAAAADAAAOAAAAAAAAAAAAAACAAVkAAABtZWRpYS9zb25nLmRhdFBL"
    "AQIUABQAAAAAAABgKl34u5/0DwAAAA8AAAAVAAAAAAAAAAAAAACAAYUDAABzdWIvaW5uZXIvbmVzdGVkLmpzb25QSwECFAAU"
    "AAAAAAAAYCpdlwa5pBAAAAAQAAAADQAAAAAAAAAAAAAAgAHHAwAALi4vZXNjYXBlLnR4dFBLAQIUABQAAAAAAABgKl2XBrmk"
    "EAAAABAAAAAIAAAAAAAAAAAAAACAAQIEAAAvYWJzLnR4dFBLAQIUABQAAAAAAABgKl2XBrmkEAAAABAAAAALAAAAAAAAAAAA"
    "AACAATgEAABkcml2ZTpjLnR4dFBLAQIUABQAAAAAAABgKl2XBrmkEAAAABAAAAAQAAAAAAAAAAAAAACAAXEEAABvay8uLi8u"
    "Li9iYWQudHh0UEsFBgAAAAAIAAgA0gEAAK8EAAAAAA==";
static const char kV1Md5[] = "0169e784ed1733638d1e3fe526c34815";

// v2 = v1 + one appended entry (sub/second.txt) — clean archive, new digest.
static const char kV2ZipB64[] =
        "UEsDBBQAAAAAAABgKl2dmBIEDgAAAA4AAAAJAAAAcGxhaW4udHh0aGVsbG8gYnVuZGxlZApQSwMEFAAAAAAAAGAqXQAAAAAA"
    "AAAAAAAAAAYAAABtZWRpYS9QSwMEFAAAAAAAAGAqXSrfwLAAAwAAAAMAAA4AAABtZWRpYS9zb25nLmRhdAABAgMEBQYHCAkK"
    "CwwNDg8QERITFBUWFxgZGhscHR4fICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj9AQUJDREVGR0hJSktMTU5PUFFS"
    "U1RVVldYWVpbXF1eX2BhYmNkZWZnaGlqa2xtbm9wcXJzdHV2d3h5ent8fX5/gIGCg4SFhoeIiYqLjI2Oj5CRkpOUlZaXmJma"
    "m5ydnp+goaKjpKWmp6ipqqusra6vsLGys7S1tre4ubq7vL2+v8DBwsPExcbHyMnKy8zNzs/Q0dLT1NXW19jZ2tvc3d7f4OHi"
    "4+Tl5ufo6err7O3u7/Dx8vP09fb3+Pn6+/z9/v8AAQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyAhIiMkJSYnKCkq"
    "KywtLi8wMTIzNDU2Nzg5Ojs8PT4/QEFCQ0RFRkdISUpLTE1OT1BRUlNUVVZXWFlaW1xdXl9gYWJjZGVmZ2hpamtsbW5vcHFy"
    "c3R1dnd4eXp7fH1+f4CBgoOEhYaHiImKi4yNjo+QkZKTlJWWl5iZmpucnZ6foKGio6SlpqeoqaqrrK2ur7CxsrO0tba3uLm6"
    "u7y9vr/AwcLDxMXGx8jJysvMzc7P0NHS09TV1tfY2drb3N3e3+Dh4uPk5ebn6Onq6+zt7u/w8fLz9PX29/j5+vv8/f7/AAEC"
    "AwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8gISIjJCUmJygpKissLS4vMDEyMzQ1Njc4OTo7PD0+P0BBQkNERUZHSElK"
    "S0xNTk9QUVJTVFVWV1hZWltcXV5fYGFiY2RlZmdoaWprbG1ub3BxcnN0dXZ3eHl6e3x9fn+AgYKDhIWGh4iJiouMjY6PkJGS"
    "k5SVlpeYmZqbnJ2en6ChoqOkpaanqKmqq6ytrq+wsbKztLW2t7i5uru8vb6/wMHCw8TFxsfIycrLzM3Oz9DR0tPU1dbX2Nna"
    "29zd3t/g4eLj5OXm5+jp6uvs7e7v8PHy8/T19vf4+fr7/P3+/1BLAwQUAAAAAAAAYCpd+Luf9A8AAAAPAAAAFQAAAHN1Yi9p"
    "bm5lci9uZXN0ZWQuanNvbnsiayI6ICLkuK3mlocifVBLAwQUAAAAAAAAYCpdlwa5pBAAAAAQAAAADQAAAC4uL2VzY2FwZS50"
    "eHRtdXN0IG5ldmVyIGV4aXN0UEsDBBQAAAAAAABgKl2XBrmkEAAAABAAAAAIAAAAL2Ficy50eHRtdXN0IG5ldmVyIGV4aXN0"
    "UEsDBBQAAAAAAABgKl2XBrmkEAAAABAAAAALAAAAZHJpdmU6Yy50eHRtdXN0IG5ldmVyIGV4aXN0UEsDBBQAAAAAAABgKl2X"
    "BrmkEAAAABAAAAAQAAAAb2svLi4vLi4vYmFkLnR4dG11c3QgbmV2ZXIgZXhpc3RQSwMEFAAAAAAAAGAqXTGCS/0OAAAADgAA"
    "AA4AAABzdWIvc2Vjb25kLnR4dHYyIGFkZGVkIGZpbGUKUEsBAhQAFAAAAAAAAGAqXZ2YEgQOAAAADgAAAAkAAAAAAAAAAAAA"
    "AIABAAAAAHBsYWluLnR4dFBLAQIUABQAAAAAAABgKl0AAAAAAAAAAAAAAAAGAAAAAAAAAAAAAACAATUAAABtZWRpYS9QSwEC"
    "FAAUAAAAAAAAYCpdKt/AsAADAAAAAwAADgAAAAAAAAAAAAAAgAFZAAAAbWVkaWEvc29uZy5kYXRQSwECFAAUAAAAAAAAYCpd"
    "+Luf9A8AAAAPAAAAFQAAAAAAAAAAAAAAgAGFAwAAc3ViL2lubmVyL25lc3RlZC5qc29uUEsBAhQAFAAAAAAAAGAqXZcGuaQQ"
    "AAAAEAAAAA0AAAAAAAAAAAAAAIABxwMAAC4uL2VzY2FwZS50eHRQSwECFAAUAAAAAAAAYCpdlwa5pBAAAAAQAAAACAAAAAAA"
    "AAAAAAAAgAECBAAAL2Ficy50eHRQSwECFAAUAAAAAAAAYCpdlwa5pBAAAAAQAAAACwAAAAAAAAAAAAAAgAE4BAAAZHJpdmU6"
    "Yy50eHRQSwECFAAUAAAAAAAAYCpdlwa5pBAAAAAQAAAAEAAAAAAAAAAAAAAAgAFxBAAAb2svLi4vLi4vYmFkLnR4dFBLAQIU"
    "ABQAAAAAAABgKl0xgkv9DgAAAA4AAAAOAAAAAAAAAAAAAACAAa8EAABzdWIvc2Vjb25kLnR4dFBLBQYAAAAACQAJAA4CAADp"
    "BAAAAAA=";
static const char kV2Md5[] = "89ee0cabad419b8e0364d307183ed4d4";

static const char kBrokenZipB64[] =
    "UEsDBG5vdCBhIHppcCBhdCBhbGwsIGp1c3Qgbm9pc2UgMDEyMzQ1Njc4OQ==";

std::string un64(const char* b64) {
    std::string out;
    bool ok = sa_core::http::b64_decode(b64, &out);
    REQUIRE(ok);
    return out;
}

// Expected extracted contents (everything the __init__.py:56 filter keeps).
// `with_second` adds the v2-only entry.
std::map<std::string, std::string> expected_tree(bool with_second) {
    std::string song;
    for (int rep = 0; rep < 3; ++rep)
        for (int i = 0; i < 256; ++i) song.push_back(static_cast<char>(i));
    std::map<std::string, std::string> t = {
        {"plain.txt", "hello bundled\n"},
        {"media/song.dat", song},
        {"sub/inner/nested.json", "{\"k\": \"\xe4\xb8\xad\xe6\x96\x87\"}"},
    };
    if (with_second) t["sub/second.txt"] = "v2 added file\n";
    return t;
}

// ---- scratch dir -----------------------------------------------------------
struct Scratch {
    fs::path root;
    explicit Scratch(const std::string& tag) {
        static int counter = 0;
        auto ms = std::chrono::steady_clock::now().time_since_epoch().count();
        root = fs::temp_directory_path() /
               ("sa_w44_" + tag + "_" + std::to_string(ms) + "_" +
                std::to_string(counter++));
        std::error_code ec;
        fs::remove_all(root, ec);
        fs::create_directories(root);
    }
    ~Scratch() {
        std::error_code ec;
        fs::remove_all(root, ec);
    }
    std::string path_str(const std::string& rel = "") {
        fs::path p = rel.empty() ? root : root / rel;
        return sa_core::paths::path_to_utf8(p);
    }
};

std::string read_or_missing(const std::string& p) {
    auto b = sa_core::paths::read_bytes(p);
    return b ? *b : std::string("<MISSING>");
}

// All regular files under dir, rel-path-with-slashes -> contents. The marker
// is excluded (each test asserts on it explicitly).
std::map<std::string, std::string> tree(const std::string& dir) {
    std::map<std::string, std::string> out;
    if (!sa_core::paths::is_dir(dir)) return out;
    fs::path base = sa_core::paths::to_path(dir);
    std::error_code ec;
    for (auto it = fs::recursive_directory_iterator(base, ec);
         it != fs::recursive_directory_iterator();
         it.increment(ec)) {
        if (ec) break;
        if (!it->is_regular_file()) continue;
        std::string rel =
            sa_core::paths::path_to_utf8(fs::relative(it->path(), base));
        std::replace(rel.begin(), rel.end(), '\\', '/');
        if (rel == ".bundled_version") continue;
        std::ifstream f(it->path(), std::ios::binary);
        out[rel] = std::string((std::istreambuf_iterator<char>(f)),
                               std::istreambuf_iterator<char>());
    }
    return out;
}

void write_file(const std::string& p, const std::string& data) {
    REQUIRE(sa_core::paths::create_dirs(sa_core::paths::dirname(p)));
    REQUIRE(sa_core::paths::write_bytes_simple(p, data));
}

}  // namespace

// ---------------------------------------------------------------------------

// md5_hex's own vectors live in test_md5.cpp ([digest][md5]); this TU only
// pins the fixture fingerprints (hashlib.md5(blob[:1MiB]), both blobs are
// under 1 MiB so prefix == content) and then tests the extraction port.

TEST_CASE("bundled: first extract is byte-identical; hostile entries skipped",
          "[bundled]") {
    CHECK(sa_core::md5_hex(un64(kV1ZipB64)) == kV1Md5);
    Scratch s("first");
    const std::string zip = s.path_str("resource_pack.zip");
    write_file(zip, un64(kV1ZipB64));
    const std::string packs = s.path_str("packs");

    sa::extract_bundled(zip, packs);

    const std::string dest = sa_core::paths::join(packs, "bundled");
    // __init__.py:56 skip filter: "../escape.txt", "/abs.txt", "drive:c.txt",
    // "ok/../../bad.txt" must leave NO extracted file.
    CHECK(tree(dest) == expected_tree(false));
    // Directory-only entry materialized:
    CHECK(sa_core::paths::is_dir(sa_core::paths::join(dest, "media")));
    // Marker holds exactly the digest, no newline (Python f.write(digest)).
    CHECK(read_or_missing(sa_core::paths::join(dest, ".bundled_version")) ==
          kV1Md5);
}

TEST_CASE("bundled: second start skips re-extraction (fingerprint)",
          "[bundled]") {
    Scratch s("skip");
    const std::string zip = s.path_str("resource_pack.zip");
    write_file(zip, un64(kV1ZipB64));
    const std::string packs = s.path_str("packs");
    const std::string dest = sa_core::paths::join(packs, "bundled");

    sa::extract_bundled(zip, packs);
    // Clobber an extracted file + add an orphan, then re-extract: a SKIP
    // leaves both untouched.
    const std::string plain = sa_core::paths::join(dest, "plain.txt");
    write_file(plain, "clobbered");
    const std::string orphan = sa_core::paths::join(dest, "orphan.txt");
    write_file(orphan, "mine");

    sa::extract_bundled(zip, packs);
    CHECK(read_or_missing(plain) == "clobbered");
    CHECK(read_or_missing(orphan) == "mine");
}

TEST_CASE("bundled: changed zip digest re-extracts, orphans survive",
          "[bundled]") {
    CHECK(sa_core::md5_hex(un64(kV2ZipB64)) == kV2Md5);
    Scratch s("redigest");
    const std::string zip = s.path_str("resource_pack.zip");
    write_file(zip, un64(kV1ZipB64));
    const std::string packs = s.path_str("packs");
    const std::string dest = sa_core::paths::join(packs, "bundled");

    sa::extract_bundled(zip, packs);
    const std::string plain = sa_core::paths::join(dest, "plain.txt");
    write_file(plain, "clobbered");
    const std::string orphan = sa_core::paths::join(dest, "orphan.txt");
    write_file(orphan, "mine");

    // Swap in a DIFFERENT well-formed zip (new fingerprint). Python's
    // zipfile.extract never deletes extras, so the orphan must survive.
    write_file(zip, un64(kV2ZipB64));
    sa::extract_bundled(zip, packs);
    CHECK(read_or_missing(plain) == "hello bundled\n");
    CHECK(read_or_missing(orphan) == "mine");
    auto t = tree(dest);
    t.erase("orphan.txt");  // our own extra, not part of the archive
    CHECK(t == expected_tree(true));
    CHECK(read_or_missing(sa_core::paths::join(dest, ".bundled_version")) ==
          kV2Md5);
}

TEST_CASE("bundled: corrupt zip is silent (no marker, dest created)",
          "[bundled]") {
    Scratch s("corrupt");
    const std::string zip = s.path_str("resource_pack.zip");
    write_file(zip, un64(kBrokenZipB64));
    const std::string packs = s.path_str("packs");
    const std::string dest = sa_core::paths::join(packs, "bundled");

    sa::extract_bundled(zip, packs);  // must not throw
    CHECK(sa_core::paths::is_dir(dest));  // makedirs ran before ZipFile() raised
    CHECK_FALSE(sa_core::paths::is_file(
        sa_core::paths::join(dest, ".bundled_version")));
}

TEST_CASE("bundled: no-ops and the empty-file digest skip", "[bundled]") {
    Scratch s("noop");
    const std::string packs = s.path_str("packs");
    const std::string zip = s.path_str("resource_pack.zip");

    sa::extract_bundled("", packs);
    sa::extract_bundled(zip, "");
    sa::extract_bundled(sa_core::paths::join(packs, "absent.zip"), packs);
    CHECK_FALSE(sa_core::paths::exists(packs));  // nothing touched

    // Zero-byte zip: isfile passes, digest = md5("") = d41d..., ZipFile fails
    // -> dest created, no marker.
    write_file(zip, "");
    sa::extract_bundled(zip, packs);
    const std::string dest = sa_core::paths::join(packs, "bundled");
    CHECK(sa_core::paths::is_dir(dest));
    const std::string marker =
        sa_core::paths::join(dest, ".bundled_version");
    CHECK_FALSE(sa_core::paths::is_file(marker));

    // A marker that already holds md5("") makes the next start SKIP exactly
    // like Python's `f.read().strip() == digest` (both are that hex).
    write_file(marker, "d41d8cd98f00b204e9800998ecf8427e");
    const std::string sentinel = sa_core::paths::join(dest, "sentinel.txt");
    write_file(sentinel, "keep");
    sa::extract_bundled(zip, packs);
    CHECK(read_or_missing(sentinel) == "keep");
    CHECK(read_or_missing(marker) == "d41d8cd98f00b204e9800998ecf8427e");
}
