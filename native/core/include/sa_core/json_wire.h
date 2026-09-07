// sa_core: Python-compatible JSON serialization for the HTTP wire format.
//
// The Python backend serializes every response with
//   json.dumps(payload, ensure_ascii=False)
// which, with its default separators, emits `", "` between items and `": "`
// between key and value. nlohmann's own `dump()` produces *compact* output
// (no spaces), so it does NOT match byte-for-byte. This helper reproduces
// CPython's exact spacing so the native server is a drop-in for the black-box
// contract tests.
//
// It also relies on `ordered_json` (insertion order) rather than the default
// `json` (std::map, alphabetical order), because key order matters for byte
// parity with the Python dict literals in api.py.
#pragma once

#include <string>

#include <nlohmann/json.hpp>

namespace sa_core {

// Serialize `v` using CPython's default `json.dumps(..., ensure_ascii=False)`
// formatting: `": "` after keys, `", "` between members, no ASCII escaping of
// non-ASCII code points, and insertion order preserved for objects.
std::string py_dumps(const nlohmann::ordered_json& v);

// Convenience: an error envelope matching api.py's generic failure shape, e.g.
//   {"error": "no route: GET /api/nope"}
std::string error_json(std::string_view message);

}  // namespace sa_core
