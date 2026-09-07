# Contract tests

A **contract test** here is a *black-box* HTTP test that exercises **any** backend
implementation of the StudentAge editor API — the current Python server
(`backend/`) and the C++ rewrite (`native/`) — purely over the wire. It never
imports Python or C++ code and never pokes at internal state; it asserts only
what a real client can observe: HTTP **status** and the **JSON response body**.

The point is a **parity oracle**: record the golden responses once from the live
Python backend, then run the same suite against a native `backend.exe` and require
both to match. That pins the wire format while internals migrate from Python to
C++ one wave at a time. If a response drifts (a key renamed, the error envelope
changed, a type flipped), the contract gate fails on the new implementation even
though its own white-box unit tests still pass.

## Layout

```
contract/
  normalize.py        # normalization + semantic-diff gate (stdlib only)
  golden/             # one recorded golden file per endpoint case
    <slug>.json
```

There are **no per-group subdirectories**; the endpoint family (the "group") is
encoded in the golden file *name*, which is the endpoint path with separators
turned into `_` and its path parameters inlined:

| Slug prefix | Family (api.py router) | Examples |
| ----------- | ---------------------- | -------- |
| `api_ping`, `api_state`, `api_base_status` | system | `api_ping.json` |
| `api_cfg*`, `api_history*`, `api_dicts`, `api_schema` | config tables | `api_cfg_EvtCfg.json` |
| `api_mods`, `api_manifest_status` | mods | `api_mods.json` |
| `api_ai_*` | AI assistant | `api_ai_settings.json` |
| `api_cloud_*` | cloud sync | `api_cloud_status.json` |
| `api_plugins*` | plugin system | `api_plugins_ui_flow_cards.json` |
| `api_aa_*`, `api_preview*`, `api_search*`, `api_tts_*` | asset/preview/search/tts | `api_aa_status.json` |

### Golden file shape

Each `golden/<slug>.json` is the **normalized** expectation for one call:

```json
{
  "endpoint": "/api/ping",
  "method": "GET",
  "status": 200,
  "response": { "...": "normalized response body" }
}
```

`status` is the required HTTP status; `response` is the expected body **after
normalization** (see below). `native/server` wave 0 implements `GET /api/ping`,
whose golden is `golden/api_ping.json`.

## The gate: `normalize.py`

Comparisons are semantic, not textual. Two stages:

1. **normalize(obj)** strips values that are legitimately machine- or
   run-dependent (so they are *not* part of the API contract):
   - keys in `VOLATILE_KEYS` (timestamps, `pid`, `port`, `mtime_ns`, …) → `"<VOLATILE>"`;
   - absolute filesystem paths — any value under a `PATH_KEYS` name
     (`workspace_root`, `mod_root`, `dirs`, `root`, …) that looks like a real path,
     plus drive-letter / UNC paths under any key — → `"<PATH>"`.
2. **diff_paths(expected, actual)** walks the two JSON trees and reports a
   minimal list of JSON-Pointer-style diff paths:
   - object **key order is ignored** (so byte-level ordering does NOT matter
     here — that parity is separately guarded by `test_json_wire.cpp`);
   - arrays are ordered, compared element-wise;
   - numbers compare with a float tolerance; `bool` is never equal to a number.

CLI (standard library only):

```
python normalize.py <golden.json> <actual.json>       # PASS -> exit 0, FAIL -> exit 1
python normalize.py --normalize <in.json> <out.json>  # emit normalized copy
```

## What the native server must guarantee (wave 0)

- `GET /api/ping` → **200** with body whose keys/values match `golden/api_ping.json`
  *after normalization*. Concretely: `ok`/`app`/`cfg_patch` are exact constants;
  `state.aa_status == "idle"`; `state.base_loaded_count == 0`; and the path/name
  fields must be present with the right *shape*.
  - Note: the golden was recorded under a temp workspace, so
    `state.workspace_root` normalizes to `"<PATH>"`. Until the native server loads a
    real workspace (a later wave), a bare native launch returns `""` there and will
    differ; the `--workspace-root` flag on `backend.exe` injects a real path for
    exact-parity demos. `mod_root`/`mod_name` are empty in the golden and match the
    defaults.
- `POST /api/shutdown` → **200** `{"ok": true}`, then the process exits cleanly.
- Any other (method, path) → **404** `{"error": "no route: <METHOD> <PATH>"}`.

Transport details (`Content-Type: application/json; charset=utf-8`,
`Cache-Control: no-store`, the `Access-Control-*` CORS headers) are fixed by the
Python `httpd._respond()` and reproduced by the native server; they are verified by
hand and by `sa_core` unit tests, and are the subject of `CONVENTIONS.md` (owned by
the main agent) rather than the JSON golden bodies compared here.

## Relationship to `sa_tests`

`native/tests/test_*.cpp` are **white-box unit tests** compiled into the
`sa_tests` Catch2 binary and linked against `sa_core` — including the
byte-for-byte `sa_core::py_dumps` parity check that guards the CPython-style
serializer the server uses to build every response body. The `contract/` suite in
this directory is the **black-box** layer: it drives a running server over HTTP and
is the cross-implementation parity oracle described above. Both layers must stay
green.
