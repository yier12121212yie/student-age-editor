# Vendored third-party dependencies

This directory holds **pinned, single-header / amalgamated** third-party libraries
committed directly into the repository. We deliberately do **not** use vcpkg or any
package manager for the native backend: the toolchain on the build hosts is a plain
MSVC + CMake + Ninja install, and vendoring keeps the configure step offline and
reproducible.

One exception as of wave 3: `ftxui/` is vendored as a **full CMake project**
(first of its kind here) because it is ~100 interdependent TUs with generated
export headers — see its usage note below. It is still pinned and offline.

Re-download a file with the exact URL below and verify the version macro inside the
header before committing. Do not edit these files in place; upgrade by re-fetching a
new pinned version and updating this table.

| Library | Version | File(s) | License | Source URL |
| ------- | ------- | ------- | ------- | ---------- |
| cpp-httplib | 0.18.3 | `httplib/httplib.h` | MIT | https://raw.githubusercontent.com/yhirose/cpp-httplib/v0.18.3/httplib.h |
| nlohmann/json | 3.11.3 | `nlohmann/json.hpp` | MIT | https://raw.githubusercontent.com/nlohmann/json/v3.11.3/single_include/nlohmann/json.hpp |
| Catch2 (amalgamated) | 3.7.1 | `catch2/catch_amalgamated.hpp`, `catch2/catch_amalgamated.cpp` | Boost Software License 1.0 | https://raw.githubusercontent.com/catchorg/Catch2/v3.7.1/extras/catch_amalgamated.hpp |
| miniz (amalgamated, P3b wave-2) | 3.0.2 release zip (header `MZ_VERSION` "11.0.2"; sha256 miniz.h `295d1a00…af37b`, miniz.c `0fcdc988…1d3740`) | `miniz/miniz.h`, `miniz/miniz.c`, `miniz/LICENSE` | MIT-style (release LICENSE; header carries the public-domain/unlicense statement) | https://github.com/richgel999/miniz/releases/download/3.0.2/miniz-3.0.2.zip |
| CLI11 (single header, P7 wave-3) | 2.4.2 (`CLI11_VERSION` at `CLI11/CLI11.hpp` head) | `CLI11/CLI11.hpp` | BSD-3-Clause | https://github.com/CLIUtils/CLI11/releases/download/v2.4.2/CLI11.hpp |
| FTXUI (full project, P8 wave-3) | 5.0.0 (`git clone -b v5.0.0`, tag commit cdf2890; nested `.git` removed at import) | `ftxui/` | Apache-2.0 | https://github.com/ArthurSonzogni/FTXUI (tag v5.0.0) |

## Usage notes

### cpp-httplib
Header-only, HTTP-only build. We compile it **without** OpenSSL, so the server can
bind and speak plain HTTP on `127.0.0.1` only. The TLS support macro
`CPPHTTPLIB_OPENSSL_SUPPORT` is intentionally **not** defined; it is reserved for a
later wave if HTTPS becomes a requirement (that would additionally pull in OpenSSL
and is out of scope for the vendored strategy above).

`httplib` requires Winsock on Windows; the server target links `ws2_32` (done in
`native/server/CMakeLists.txt`).

### nlohmann/json
Used for request/response JSON. The HTTP contract requires **insertion-ordered**
serialization that matches the Python backend's `json.dumps(..., ensure_ascii=False)`
output byte-for-byte, so we use `nlohmann::ordered_json` (not the default
`nlohmann::json`, which is an ordered `std::map` and would alphabetize keys).

### Catch2 (amalgamated)
The two amalgamated files are compiled into a small static test framework library
inside the `tests` target rather than fetched and built via CMake `FetchContent`.
The `catch_amalgamated.cpp` file already provides a `main()` when built with the
default `CATCH_CONFIG_MAIN`-equivalent entry, so the `sa_tests` executable adds its
own test `.cpp` files alongside it (see `native/tests/CMakeLists.txt`).

### CLI11 (single header)
`<CLI11/CLI11.hpp>` resolves with **no extra include wiring**: `third_party/`
itself is on the `sa_third_party` INTERFACE include dirs (root CMakeLists), the
same mechanism that makes `<nlohmann/json.hpp>` work. Used by `sa_cli`/
`backend_cli` only (P7 merge).

### FTXUI (project-style, TUI)
Built via `add_subdirectory` from `native/tui/CMakeLists.txt` as three static
libs (screen/dom/component, consumed through the `ftxui::` ALIAS targets).
The five `FTXUI_*` cache vars forced there are **load-bearing**:
`FTXUI_BUILD_TESTS=OFF` is what keeps `FetchContent(googletest)` out and the
configure offline; `FTXUI_ENABLE_INSTALL/EXAMPLES/DOCS=OFF` skip CPack rules
and the ~40MB example/doc targets (the dirs stay on disk — upstream CMakeLists
enters them unconditionally and editing vendored files is forbidden above).
Note `ftxui/.gitignore` is an ignore-all + whitelist scheme and governs git for
this subtree; after upgrading, re-verify nothing needed was dropped
(`git add` then compare `git status --short` counts against a `find` count).

## License texts

Each file retains its upstream copyright/license header. Summaries:
- cpp-httplib — MIT, Copyright (c) 2017 Yuji Hirose.
- nlohmann/json — MIT, Copyright (c) 2013-2025 Niels Lohmann.
- Catch2 — Boost Software License 1.0, Copyright (c) Catch2 Contributors.
- CLI11 — BSD-3-Clause, Copyright (c) 2017-2024 University of Cincinnati.
- FTXUI — Apache-2.0, Copyright (c) Arnaud Sonzogni (full text in `ftxui/LICENSE`).
