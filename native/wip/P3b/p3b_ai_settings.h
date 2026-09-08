// wip/P3b — C++ port of the AI-settings half of backend/editor/core/env_store.py
// (.editor_ai.json). /api/ai/settings contract for P3b.
//
// Merge note: P4 carries an equivalent wip/P4/env_store_ai.h for
// /api/tts/settings; the orchestrator keeps ONE copy (both pin the identical
// shape recorded by golden api_ai_settings.json).
//
// Pitfalls honoured (env_store.py):
//   * normalize starts from DEFAULT_AI_SETTINGS but every key is then
//     RE-ASSIGNED from the data (`data.get(key)`), so a field absent from a
//     fresh store legitimately answers None — golden api_ai_settings.json
//     pins apiKey/baseUrl/model as null. Do NOT "fix" that back to "".
//   * 0 is a legal value for temperature / ttsSpeed / ttsVolume / ttsPitch /
//     maxRetries / retryDelayMs — never `or default`-falsy replacement.
//   * read-merge-write under one lock (concurrent PUTs must not clobber).
#pragma once

#include <string>

#include <nlohmann/json.hpp>

namespace sa {
namespace p3b {

using json = nlohmann::ordered_json;

namespace ai_settings {

// env_store.DEFAULT_AI_SETTINGS (key order == wire order).
const json& defaults();

// env_store.normalize_ai_settings.
json normalize(const json& data);

// <editor_root>/.editor_ai.json
std::string path_for(const std::string& editor_root);

// read_ai_settings(): tolerant read + normalize.
json read_settings(const std::string& editor_root);

// write_ai_settings(patch): merge over current, normalize, atomic
// read-merge-write of the raw file; returns the normalized result.
json write_settings(const std::string& editor_root, const json& patch);

}  // namespace ai_settings
}  // namespace p3b
}  // namespace sa
