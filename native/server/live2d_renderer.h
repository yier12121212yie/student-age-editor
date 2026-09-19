// native/server/live2d_renderer.h — Header for Live2D offline rendering service.
#pragma once

#include <string>
#include <vector>

namespace sa {
namespace live2d_renderer {

// Structure for cubism model reference
struct Moc3Reference {
    std::string path;
    std::vector<std::string> expressions;
};

void set_game_root(const std::string& root);

// List all available Live2D models from game root
std::vector<Moc3Reference> list_models();

// Render expression to cached PNG (returns path)
std::string render_expression(const std::string& model_path,
                              const std::string& expression_name,
                              int width = 512,
                              int height = 512);

// Persist cache to disk
bool persist_cache(const std::string& dir);

// Debug helpers
long long debug_total_caches();

}  // namespace live2d_renderer
}  // namespace sa
