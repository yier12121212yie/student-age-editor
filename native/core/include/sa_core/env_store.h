// sa_core/env_store: the C++ port of `backend/editor/core/env_store.py` —
// shared editor environment storage (editor_env.json).
//
// Contract (env_store.py:82-114):
//   * read: utf-8-sig tolerant (BOM stripped); invalid UTF-8 / invalid JSON /
//     non-object payload all degrade to {} exactly like the Python
//     try/except; empty or whitespace-only file is {}.
//   * write: read-merge-write under one call, serialized with
//     json.dumps(ensure_ascii=False, indent=2) and replaced atomically
//     (sa_core::write_text_atomic — the same tmp+replace durability story as
//     atomic_io.write_text_atomic used by env_store._merge_write_unlocked).
//
// `editor_root` (the directory holding editor_env.json) is a parameter, not a
// dependency: the server layer resolves it (EDITOR_DATA_ROOT env / exe dir)
// and passes it in, keeping sa_core free of server/state includes.
#pragma once

#include <string>

#include <nlohmann/json.hpp>

namespace sa_core {
namespace env_store {

// env_store.read_json: tolerant dict read; any failure -> {}.
nlohmann::ordered_json read_json_file(const std::string& path);

// <editor_root>/editor_env.json
std::string env_path(const std::string& editor_root);

// read_json(env_path(root)) — the merged view of the env file.
nlohmann::ordered_json read_editor_env(const std::string& editor_root);

// env_store.read_workshop_override: editor_env.json["workshop_root"] as a
// stripped string (str(x) coercion for non-strings like the Python does via
// .get() + isinstance check — non-str yields "" there, so match that).
std::string read_workshop_override(const std::string& editor_root);

// env_store.atomic_merge_write: merge `extra` over the current content of
// `path` and atomically write it back with indent=2. Returns the merged
// document. Throws sa_core::FsError when the write fails.
nlohmann::ordered_json atomic_merge_write(const std::string& path,
                                          const nlohmann::ordered_json& extra);

// Convenience: atomic_merge_write(env_path(root), extra).
nlohmann::ordered_json merge_editor_env(const std::string& editor_root,
                                        const nlohmann::ordered_json& extra);

}  // namespace env_store
}  // namespace sa_core
