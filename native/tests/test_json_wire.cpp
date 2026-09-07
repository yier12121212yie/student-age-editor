// Unit tests for the CPython-compatible JSON wire formatter.
//
// The strongest test here pins `py_dumps` against the *exact* bytes the Python
// backend emits for GET /api/ping (captured live). If the formatter drifts from
// json.dumps(..., ensure_ascii=False) spacing/escaping/ordering, this fails.
#include <string>

#include <catch_amalgamated.hpp>
#include <nlohmann/json.hpp>

#include "sa_core/json_wire.h"

using nlohmann::ordered_json;

TEST_CASE("py_dumps matches CPython default separators for scalars") {
    CHECK(sa_core::py_dumps(ordered_json(1)) == "1");
    CHECK(sa_core::py_dumps(ordered_json(true)) == "true");
    CHECK(sa_core::py_dumps(ordered_json(nullptr)) == "null");
    CHECK(sa_core::py_dumps(ordered_json("hi")) == "\"hi\"");
}

TEST_CASE("py_dumps uses ': ' and ', ' for containers, insertion order preserved") {
    ordered_json o;
    o["z"] = 1;  // inserted first on purpose -> must appear first (not alphabetical)
    o["a"] = 2;
    CHECK(sa_core::py_dumps(o) == "{\"z\": 1, \"a\": 2}");

    ordered_json arr = ordered_json::array({1, 2, 3});
    CHECK(sa_core::py_dumps(arr) == "[1, 2, 3]");

    CHECK(sa_core::py_dumps(ordered_json::object()) == "{}");
    CHECK(sa_core::py_dumps(ordered_json::array()) == "[]");
}

TEST_CASE("py_dumps escapes backslash and quote like CPython (ensure_ascii=False)") {
    ordered_json o;
    o["path"] = "C:\\a\"b";  // runtime value: C:\a"b
    // CPython: {"path": "C:\\a\"b"}
    CHECK(sa_core::py_dumps(o) == "{\"path\": \"C:\\\\a\\\"b\"}");
}

TEST_CASE("error_json produces the api.py generic failure envelope") {
    CHECK(sa_core::error_json("no route: GET /api/nope") ==
          "{\"error\": \"no route: GET /api/nope\"}");
    CHECK(sa_core::error_json("no route: GET /api/nope").size() == 36);  // Content-Length parity
}

TEST_CASE("py_dumps reproduces the live Python /api/ping body byte-for-byte") {
    // Values captured from `python -m editor.server --port 18766` on this host.
    ordered_json j;
    j["ok"] = true;
    j["app"] = "student-age-editor";
    j["cfg_patch"] = true;
    ordered_json state;
    state["workspace_root"] = "C:\\Users\\acber\\AppData\\LocalLow\\PakyiGame\\StudentAge\\Mods";
    state["mod_root"] = "C:\\Users\\acber\\AppData\\LocalLow\\PakyiGame\\StudentAge\\Mods\\test";
    state["mod_name"] = "test";
    state["aa_status"] = "idle";
    state["base_loaded_count"] = 0;
    j["state"] = state;

    const std::string expected = R"({"ok": true, "app": "student-age-editor", "cfg_patch": true, "state": {"workspace_root": "C:\\Users\\acber\\AppData\\LocalLow\\PakyiGame\\StudentAge\\Mods", "mod_root": "C:\\Users\\acber\\AppData\\LocalLow\\PakyiGame\\StudentAge\\Mods\\test", "mod_name": "test", "aa_status": "idle", "base_loaded_count": 0}})";

    REQUIRE(sa_core::py_dumps(j) == expected);
}
