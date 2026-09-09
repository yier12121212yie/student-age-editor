// sa_core/assets.h — the single assets/<file> resolver for the whole backend.
//
// History (post-merge refactor R1): four independent copies of this lookup
// existed (p1 semantic_assets, p3a content_util, p3b support, wave-0
// system_routes inline). The inline/system copies only probed exe_dir +
// two cwd patterns, so any layout that is not the official build/ one (tests
// run from a temp cwd, archive-verify builds placed beside native/) silently
// failed — the golden harness had to set EDITOR_ASSETS_ROOT to mask it. The
// p1 list (widest) is now the only one, living here so every layer
// (server/cli/tui/tests) reaches it through sa_core without cross-service
// includes.
#pragma once

#include <string>
#include <vector>

namespace sa_core {
namespace assets {

// Candidate file paths for an asset name (e.g. "schema.json"), in priority
// order:
//   1. set_assets_root_override() root (tests / smoke)
//   2. $EDITOR_ASSETS_ROOT/<filename>
//   3. $SA_NATIVE_SOURCE_DIR/assets (plus parent/assets — the var may point
//      at native/tests)
//   4. exe_dir and up to 7 walk-up levels, each probing <dir>/assets then
//      <dir>/native/assets (covers build-<group>/bin repo layouts)
//   5. cwd-relative assets/ and native/assets/
// Exposed so each loader keeps its own per-file parse/fallback behaviour.
std::vector<std::string> candidate_paths(const std::string& filename);

// First existing candidate; "" when none is a readable file.
std::string find_asset(const std::string& filename);

// Force the assets root (empty resets to auto-discovery).
void set_assets_root_override(const std::string& root);

}  // namespace assets
}  // namespace sa_core
