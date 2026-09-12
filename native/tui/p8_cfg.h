// native/tui/p8_cfg.h — cfg table <-> view-model helpers (edit diff -> PATCH body).
//
// The cell editor stores raw JSON text per row; on save we diff those against
// the loaded base and build the `patch` body the backend's PUT /api/cfg/<name>
// patch branch expects (CONVENTIONS 5.4). Pure + unit-testable.
#pragma once

#include <map>
#include <string>
#include <vector>

#include "p8_model.h"

namespace p8 {

// Compact JSON text for one value, truncated to `max_len` code points for the
// row preview. Objects/arrays render in a stable single-line form.
std::string ValuePreview(const Json& value, size_t max_len = 60);

// Build browsable rows from a loaded cfg object (sorted by key for a stable
// navigation order independent of insertion order). `raw` holds the compact JSON
// text of each value; `preview` a truncated display form.
std::vector<TableRow> RowsFromData(const Json& data);

// Turn the pending edits into the patch "set" object: parse each edit buffer as
// JSON (fall back to a JSON string when the text is not valid JSON); drop edits
// whose parsed value equals the original raw value in `orig` (no-op writes).
// Keys listed in `adds` were appended this session (n / y) — they never appear
// in the base data, so they are always emitted even when the edit text equals
// the seed (a duplicated row must survive the save).
Json BuildPatchSet(const std::map<std::string, std::string>& orig,
                   const std::map<std::string, std::string>& edits,
                   const std::vector<std::string>& adds = {});

// Assemble the full PUT body: {"patch": {"set": {...}, "remove": [...]},
// "expect_mtime_ns": <n>} — the caller adds force= on a 409 retry.
Json BuildSaveBody(const std::map<std::string, std::string>& orig,
                   const std::map<std::string, std::string>& edits,
                   const std::vector<std::string>& removes, long long mtime_ns,
                   const std::vector<std::string>& adds = {});

// key -> raw JSON text, for feeding BuildSaveBody from a loaded Table.
std::map<std::string, std::string> OrigMapFromRows(const std::vector<TableRow>& rows);

// The next free row key for n/y (new/duplicate): numeric keys get max+1,
// otherwise "_new" / "_new2" / ... Unsortable keys never collide with existing
// rows (the result is always unused).
std::string NextRowKey(const std::vector<TableRow>& rows);

// Top-level fields of a record (raw JSON text of one row) as (key, compact
// JSON text) pairs in document order. Non-object rows yield an empty list —
// the form pane then just shows the JSON view.
std::vector<std::pair<std::string, std::string>> FormFields(const std::string& raw);

// Set one top-level field of the record `raw` to `value_text` (parsed as JSON,
// falling back to a plain string when invalid — same coercion as the cell
// editor). `raw` must be a JSON object. Returns false without touching *out.
bool ApplyFieldEdit(const std::string& raw, const std::string& field,
                    const std::string& value_text, std::string* out);

// The full-table data object (id -> record) used by `v` (validate): the loaded
// base rows plus pending edits, minus rows queued for removal.
Json TableDataForValidate(const std::vector<TableRow>& rows,
                          const std::map<std::string, std::string>& edits,
                          const std::vector<std::string>& removes);

}  // namespace p8
