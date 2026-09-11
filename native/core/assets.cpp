// sa_core/assets.cpp — see sa_core/assets.h for the contract and history.
#include "sa_core/assets.h"

#include <cstdlib>
#include <mutex>

#include "sa_core/paths.h"

namespace sa_core {
namespace assets {
namespace {

std::string g_root_override;
std::mutex g_mu;

}  // namespace

std::vector<std::string> candidate_paths(const std::string& filename) {
    std::vector<std::string> dirs;
    {
        std::lock_guard<std::mutex> lk(g_mu);
        if (!g_root_override.empty()) dirs.push_back(g_root_override);
    }
    // getenv_utf8 (not std::getenv): on Windows the CRT returns the ANSI value,
    // which mojibakes a CJK EDITOR_ASSETS_ROOT / SA_NATIVE_SOURCE_DIR.
    if (std::string env = paths::getenv_utf8("EDITOR_ASSETS_ROOT"); !env.empty())
        dirs.push_back(env);
    if (std::string env = paths::getenv_utf8("SA_NATIVE_SOURCE_DIR"); !env.empty()) {
        dirs.push_back(paths::join(env, "assets"));
        // SA_NATIVE_SOURCE_DIR may point at native/tests; back up one level.
        dirs.push_back(paths::join(paths::dirname(env), "assets"));
    }
    std::string exe = paths::exe_dir();
    if (!exe.empty()) {
        std::string dir = exe;
        // Walk up from build[-group]/bin looking for a sibling native/assets
        // (repo layout) or assets dir.
        for (int i = 0; i < 7 && !dir.empty(); ++i) {
            dirs.push_back(paths::join(dir, "assets"));
            dirs.push_back(paths::join(paths::join(dir, "native"), "assets"));
            std::string parent = paths::dirname(dir);
            if (parent == dir) break;
            dir = parent;
        }
    }
    dirs.push_back("assets");
    dirs.push_back(paths::join("native", "assets"));
    std::vector<std::string> files;
    files.reserve(dirs.size());
    for (auto& d : dirs) files.push_back(paths::join(d, filename));
    return files;
}

std::string find_asset(const std::string& filename) {
    for (const auto& p : candidate_paths(filename))
        if (paths::is_file(p)) return p;
    return std::string();
}

void set_assets_root_override(const std::string& root) {
    std::lock_guard<std::mutex> lk(g_mu);
    g_root_override = root;
}

}  // namespace assets
}  // namespace sa_core
