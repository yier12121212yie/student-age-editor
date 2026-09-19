// native/server/live2d_renderer.cpp — Live2D Cubism offline rendering service.
// P5 Phase 1: Offline expression preview generation (PNG) for mob UI caching.
//
// Implementation plan:
// 1. Load Live2DCubismCore.dll from game root (via ctypes on Windows)
// 2. Parse moc3 + profile.json for parameter mappings
// 3. Render each expression to 512x512 PNG
// 4. Cache by signature: bundle_sha256[:24] + expr_name
//
// Usage (as HTTP plugin service):
//   cd native/server/services
//   python3 live2d_renderer.py --port 39252
//
// API:
//   GET /plugin.json           # Self-description for editor integration
//   GET /render/:person/:expr  # Render expression, return cached PNG path
//   GET /models                # List all available Live2D models
//
// TODO: macOS version using Metal renderer (simplified CPU fallback for now)

#include "server/live2d_renderer.h"

#include <fstream>
#include <mutex>
#include <unordered_map>

#include "sa_core/atomic_io.h"
#include "sa_core/json_wire.h"
#include "sa_core/paths.h"
#include "server/httpd.h"
#include "server/state.h"

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#endif

namespace sa {
namespace live2d_renderer {
namespace {

namespace paths = sa_core::paths;

std::string g_game_root;
std::mutex g_mutex;
std::unordered_map<std::string, std::string> g_cached_pngs;  // key → png_path

}  // namespace

void set_game_root(const std::string& root) {
    std::lock_guard<std::mutex> lk(g_mutex);
    g_game_root = root;
}

std::vector<Moc3Reference> list_models() {
    std::lock_guard<std::mutex> lk(g_mutex);
    
    std::vector<Moc3Reference> models;
    
    if (g_game_root.empty()) return models;
    
    // Search for .moc3 files in DLC_L2DModels directory
    std::string l2d_dir = g_game_root + "/DLC/DLC_L2DModels";
    if (!paths::is_dir(l2d_dir)) {
        return models;  // Empty = no models found
    }
    
    // Simple scan (would be improved with proper recursive traversal)
    bool ok = false;
    auto dirs = paths::listdir_sorted(l2d_dir, &ok);
    if (!ok) return models;
    
    for (const auto& subdir : dirs) {
        std::string subpath = l2d_dir + "/" + subdir;
        if (!paths::is_dir(subpath)) continue;
        
        Moc3Reference ref_wrapper;
        ref_wrapper.path = subpath;
        
        // Scan for .moc3 and profile.json
        auto files = paths::listdir_sorted(subpath, &ok);
        if (ok) {
            for (const auto& f : files) {
                if (f.size() > 5 && f.substr(f.size() - 5) == ".moc3") {
                    ref_wrapper.expressions.push_back(f.substr(0, f.size() - 5));
                } else if (f == "profile.json") {
                    // Parse profile.json for additional metadata here
                }
            }
        }
        
        models.push_back(std::move(ref_wrapper));
    }
    
    return models;
}

std::string render_expression(const std::string& model_path,
                              const std::string& expression_name,
                              int width, int height) {
    std::lock_guard<std::mutex> lk(g_mutex);
    
    std::string cache_key = model_path + ":" + expression_name + ":" + 
                           std::to_string(width) + "x" + std::to_string(height);
    
    // Check cache first
    auto it = g_cached_pngs.find(cache_key);
    if (it != g_cached_pngs.end()) {
        return it->second;
    }
    
    // TODO: Full implementation would:
    // 1. Load cubism library (Windows: LoadLibraryA("Live2DCubismCore.dll"))
    // 2. Parse moc3 file structure
    // 3. Apply expression parameters
    // 4. Rasterize using numpy/CPU fallback
    // 5. Save to cache directory
    // 6. Return cached path
    
    // Placeholder for now - return error path
    std::string out_path = paths::join(paths::dirname(model_path), 
                                       "_cached_" + expression_name + ".png");
    return out_path;
}

bool persist_cache(const std::string& dir) {
    // Write current cache map to disk for persistence across sessions
    json cache_data = json::object();
    
    {
        std::lock_guard<std::mutex> lk(g_mutex);
        for (const auto& [key, path] : g_cached_pngs) {
            cache_data[key] = path;
        }
    }
    
    std::string cache_file = dir + "/live2d_cache.json";
    
    try {
        sa_core::write_bytes_atomic(cache_file,
                                    cache_data.dump(4));
        return true;
    } catch (...) {
        return false;
    }
}

long long debug_total_caches() {
    std::lock_guard<std::mutex> lk(g_mutex);
    return static_cast<long long>(g_cached_pngs.size());
}

}  // namespace live2d_renderer
}  // namespace sa
