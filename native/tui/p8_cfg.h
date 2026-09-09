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
Json BuildPatchSet(const std::map<std::string, std::string>& orig,
                   const std::map<std::string, std::string>& edits);

// Assemble the full PUT body: {"patch": {"set": {...}, "remove": [...]},
// "expect_mtime_ns": <n>} — the caller adds force= on a 409 retry.
Json BuildSaveBody(const std::map<std::string, std::string>& orig,
                   const std::map<std::string, std::string>& edits,
                   const std::vector<std::string>& removes, long long mtime_ns);

// key -> raw JSON text, for feeding BuildSaveBody from a loaded Table.
std::map<std::string, std::string> OrigMapFromRows(const std::vector<TableRow>& rows);

}  // namespace p8
