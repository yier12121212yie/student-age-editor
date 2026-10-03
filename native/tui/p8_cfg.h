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

// ---- Alpha-v0.3 form view (grouped sections + Chinese labels + hints) ------

// One row of the form pane: a section header or one editable field. The text
// fields carry the *encoded* (human-friendly) value, not raw JSON.
struct FormRow {
    enum class Kind { Section, Field };
    Kind kind = Kind::Field;
    // Section rows:
    std::string section;
    // Field rows:
    std::string key;
    std::string label;   // TALK_LABELS / key_maps / fallback = key
    std::string value;   // encoded display text ("" for empty)
    std::string hint;    // FIELD_HINTS entry ("" none)
    std::string type;    // schema field type (String/Number/1D Array/2D Array)
    std::string dict;    // game_dicts pool for suggestions ("" none)
};

// The form pane layout for one record of `cfg`: TalkCfg gets the Alpha's
// TALK_SECTIONS grouping (remaining keys under "高级属性 N 项"), every other
// table lists id-first then sorted keys. `schema` is the game_schema object
// (cfg -> field -> type), `key_maps` the dicts key_maps (cfg -> field -> 中文).
std::vector<FormRow> FormLayout(const std::string& cfg, const std::string& raw,
                                const Json& schema, const Json& key_maps);

// Encode a JSON value to the friendly text the form input shows (Alpha _encode):
// 1D arrays join with ", ", 2D arrays join rows with "; ".
std::string EncodeFieldValue(const Json& value, const std::string& ftype);

// Decode the typed text back to a JSON value (Alpha _decode): numbers coerce,
// 1D arrays split on , ， ; and newlines, 2D arrays on ; and newlines.
Json DecodeFieldValue(const std::string& text, const std::string& ftype);

// The Alpha _choose_columns: "ID" + up to 3 schema-ordered fields that appear
// in the sample rows (preferred names first), falling back to a 预览 column.
// `schema_cfg` is game_schema[cfg] (ordered); `sample_rows` are raw JSON texts.
std::vector<std::string> ChooseColumns(const std::string& cfg, const Json& schema_cfg,
                                       const std::vector<std::string>& sample_rows);

// One table cell for the chosen columns: arrays/objects dump as compact JSON,
// scalars stringify; both cut to `max_chars` code points with an ellipsis.
std::string TableCellText(const Json& record, const std::string& col, size_t max_chars = 28);

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

// ---- no-code mode / field suggestions (mirrors the GUI's field_meta +
// effect_slot_form.dart; pure + unit-testable) ------------------------------

// Candidate mode for one form field, or "" when it has no suggestion source.
// Same mapping as the GUI (TalkCfg.roles -> action, screenEffect -> screen,
// cost/condition aliases, *effect* -> effect; role-ish refs -> role).
std::string FieldSuggestMode(const std::string& cfg, const std::string& field);

// Parse parameter slots from a raw code template (fallback for backends that
// do not ship items[].slots): "@NAME@" -> dict slot, lone A-Z -> number slot;
// repeated letters merge into one slot with a count.
std::vector<SuggestionSlot> ParseCodeSlots(const std::string& code);

// Match normalization: upper-case, spaces stripped, ≥/≤/＞/＜ folded to ASCII
// (same algorithm as the backend's norm_for_match).
std::string NormalizeForMatch(const std::string& s);

// Indices of candidates whose normalized desc/code contains the normalized
// query (empty query keeps document order = backend score order).
std::vector<int> FilterSuggestions(const std::vector<FieldSuggestion>& all,
                                   const std::string& query);

// Entries filter for the slot fill-in list: (id, name) pairs whose id or name
// contains q (ASCII case-insensitive; substring otherwise).
std::vector<int> FilterEntries(const std::vector<std::pair<std::string, std::string>>& entries,
                               const std::string& q);

// Assemble a code from template + slot values: @NAME@ replaced wholesale, lone
// letters replaced as independent tokens; an unfilled slot keeps its raw text.
std::string AssembleEffectCode(const std::string& tmpl,
                               const std::vector<SuggestionSlot>& slots,
                               const std::map<std::string, std::string>& values);

// Insert a suggested code into a field's JSON edit buffer (the buffers hold
// compact JSON text): empty/`""` -> "\"code\""; a quoted string -> appended
// with ", " inside the quotes; anything else -> replaced with "\"code\"".
std::string MergeCodeIntoBuffer(const std::string& buf, const std::string& code);

// Slot pool name (ATTR/ROLE/ITEM/...) -> /api/dicts game_dicts key. Empty when
// the pool has no lookup source (the slot then takes a typed value).
std::string SlotPoolDictKey(const std::string& pool);

// Form field -> game_dicts pool (roles/bgs/audios/maps/items/jobs/attrs) for
// the suggest dropdown; "" when the field has no dictionary source.
std::string FieldDictPool(const std::string& cfg, const std::string& field);

}  // namespace p8
