// wip/P5/realtime.h — C++ port of backend/editor/server/realtime_sync.py.
//
// Polling watcher (size+mtime snapshots, debounced) that auto-runs the
// cloud_sync engine on local changes, plus optional remote polling for the
// download/sync directions. Config persists in <workspace>/.editor_realtime.json
// (fallback <editor_root>/_cache/realtime_config.json), status/events live in
// the process (event ring max 120, status view max 50).
//
// Thread model: one std::thread watcher, interruptible sleep through a
// condition_variable (the _rt_stop Event analogue). /api/shutdown kills the
// process via std::_Exit right after the response (httpd), so the daemon-style
// watcher can never block exit — matching Python's daemon-thread semantics.
#pragma once

#include <map>
#include <string>
#include <utility>
#include <vector>

#include <nlohmann/json.hpp>

namespace sa {
namespace realtime {

using json = nlohmann::ordered_json;

std::string rt_config_path();           // _rt_config_path
json default_config();                  // _default_config (key order frozen)
json rt_get_config();                   // rt_get_config
json rt_update_config(const json& patch);  // rt_update_config (ValueError style throws)
json rt_get_status();                   // rt_get_status (state + config + cloud_sync)
json rt_start();                        // rt_start; ValueError / RuntimeError paths
json rt_stop();                         // rt_stop
void rt_auto_start();                   // rt_auto_start (api.py:3149 called at bus build)

// --- internals exposed for the [p5] test suite -----------------------------
// realtime_sync.py:279-311 _detect_changes (prev/cur are rel -> (size, mtime)).
struct Diff {
    std::vector<std::string> added, modified, deleted, changed;  // sorted
};
Diff detect_changes(const std::map<std::string, std::pair<long long, long long>>& prev,
                    const std::map<std::string, std::pair<long long, long long>>& cur,
                    const std::string& mod_name, bool with_ambig = true);
// realtime_sync.py:253-277 _ambig_content_changed
bool ambig_content_changed(const std::string& mod_name, const std::string& rel);
// Tests: rs._RT_AMBIG_SHA.clear() equivalent (setUp/addCleanup in
// test_realtime_sync.py:31-33).
void clear_ambig_cache();
// Block until the watcher thread has exited (test/shutdown helper).
bool wait_thread_done(int timeout_ms);

}  // namespace realtime
}  // namespace sa
