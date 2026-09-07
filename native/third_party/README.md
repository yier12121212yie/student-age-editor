# Vendored third-party dependencies

This directory holds **pinned, single-header / amalgamated** third-party libraries
committed directly into the repository. We deliberately do **not** use vcpkg or any
package manager for the native backend: the toolchain on the build hosts is a plain
MSVC + CMake + Ninja install, and vendoring keeps the configure step offline and
reproducible.

Re-download a file with the exact URL below and verify the version macro inside the
header before committing. Do not edit these files in place; upgrade by re-fetching a
new pinned version and updating this table.

| Library | Version | File(s) | License | Source URL |
| ------- | ------- | ------- | ------- | ---------- |
| cpp-httplib | 0.18.3 | `httplib/httplib.h` | MIT | https://raw.githubusercontent.com/yhirose/cpp-httplib/v0.18.3/httplib.h |
| nlohmann/json | 3.11.3 | `nlohmann/json.hpp` | MIT | https://raw.githubusercontent.com/nlohmann/json/v3.11.3/single_include/nlohmann/json.hpp |
| Catch2 (amalgamated) | 3.7.1 | `catch2/catch_amalgamated.hpp`, `catch2/catch_amalgamated.cpp` | Boost Software License 1.0 | https://raw.githubusercontent.com/catchorg/Catch2/v3.7.1/extras/catch_amalgamated.hpp |

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

## License texts

Each file retains its upstream copyright/license header. Summaries:
- cpp-httplib — MIT, Copyright (c) 2017 Yuji Hirose.
- nlohmann/json — MIT, Copyright (c) 2013-2025 Niels Lohmann.
- Catch2 — Boost Software License 1.0, Copyright (c) Catch2 Contributors.
