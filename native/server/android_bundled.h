// server/android_bundled: native port of editor/server/__init__.py:32-62
// (_extract_bundled). Part of sa_server, shared by Windows/POSIX/Android —
// run_server() calls it whenever cfg.bundled_zip is set (today only the
// Android JNI channel does; the desktop CLI leaves it empty).
//
// Semantics locked to the Python truth source:
//   * skip = packs_root/bundled/.bundled_version contains md5(first 1 MiB of
//     the zip) (hexdigest, lowercase); marker match ends the call.
//   * zip entries whose name starts with "/", contains ".." or ":" are
//     skipped (path-escape filter, __init__.py:56).
//   * EVERY failure is swallowed (`except Exception: pass`): a broken bundled
//     zip must never block startup — the app then simply runs without the
//     built-in decoded pack. The marker is written only after a full pass.
#pragma once

#include <string>

namespace sa {

// zip_path / packs_root are UTF-8 filesystem paths. No-ops when either is
// empty or zip_path is not a regular file (Python: `not os.path.isfile`).
void extract_bundled(const std::string& zip_path, const std::string& packs_root);

}  // namespace sa
