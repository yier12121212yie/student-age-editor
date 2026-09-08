// wip/P4/env_store_ai.h — C++ port of `editor/core/env_store.py` AI-settings
// half (read_ai_settings / write_ai_settings / normalize_ai_settings).
//
// Owned by P4 for the /api/tts/settings contract; P3b implements the same
// store for /api/ai/settings — at merge the orchestrator should keep ONE
// copy (this one covers the tts* normalisation the配音 routes need; the
// ai-settings golden api_ai_settings.json pins the identical shape).
//
// Pitfalls honored (env_store.py):
//   * normalize starts from DEFAULT but every key absent from `data` is
//     assigned None afterwards -> apiKey/baseUrl/model legitimately answer
//     null on a fresh store (the golden records exactly that — do NOT
//     "fix" it back to "").
//   * temperature/speed/volume/maxRetries/retryDelayMs: 0 is a legal value,
//     never `or default`-falsy-replaced.
//   * read-merge-write under one lock so concurrent PUTs cannot clobber.
#pragma once

#include <mutex>
#include <string>

#include <nlohmann/json.hpp>

namespace sa {
namespace env_store_ai {

using json = nlohmann::ordered_json;

// env_store.DEFAULT_AI_SETTINGS (order = wire order).
const json& default_ai_settings();

// env_store.normalize_ai_settings.
json normalize_ai_settings(const json& data);

// <editor_root>/.editor_ai.json
std::string ai_settings_path(const std::string& editor_root);

// read_ai_settings(): tolerant read + normalize. `editor_root` is passed in
// (sa layer owns EDITOR_DATA_ROOT resolution).
json read_ai_settings(const std::string& editor_root);

// write_ai_settings(patch): merge (null values dropped like the Python
// dict-comp), normalize, persist indent=2 atomically; returns normalized.
json write_ai_settings(const std::string& editor_root, const json& patch);

}  // namespace env_store_ai
}  // namespace sa
