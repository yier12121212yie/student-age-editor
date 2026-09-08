// wip/P4/ai_image.h — OpenAI Images generate/edit + GitHub update check (P4).
//
// Port of ai_image_service.py (images/generations + images/edits multipart) and
// core/update_check.py (GitHub Releases). Both consume sa_core::http (WinHTTP);
// every request URL is derived from an injectable base (settings base_url / the
// EDITOR_UPDATE_URL override), which is how the [p4] tests point them at a
// local httplib::Server mock — no real network.
#pragma once

#include <string>
#include <vector>

#include <nlohmann/json.hpp>

#include "server/httpd.h"

namespace sa {

using json = nlohmann::ordered_json;

// ai_image_service.ImageGenError.
struct ImageGenError : std::runtime_error {
    explicit ImageGenError(const std::string& msg) : std::runtime_error(msg) {}
};

namespace ai_image {

// generate_images -> {"images":[{b64,mime}], "model":..., "created":...}. Throws.
json generate_images(const std::string& api_key, const std::string& base_url,
                     const std::string& model, const std::string& prompt, const json& n,
                     const std::string& size, const std::string& quality, const std::string& style,
                     const std::string& background);
json edit_image(const std::string& api_key, const std::string& base_url, const std::string& model,
                const std::string& prompt, const std::string& image_b64,
                const std::string& image_mime, const std::string& mask_b64, const json& n,
                const std::string& size);

// Exposed pure helpers for tests.
std::string normalize_base_url(std::string_view base_url);
// _build_multipart: returns body bytes and sets `content_type` out-param.
std::string build_multipart(const std::string& boundary,
                            const std::vector<std::pair<std::string, std::string>>& fields,
                            const std::vector<std::tuple<std::string, std::string, std::string, std::string>>& files,
                            std::string* content_type);

}  // namespace ai_image

namespace update_check {

// check_update -> result dict. `url_override` (else EDITOR_UPDATE_URL else
// the GitHub releases URL) and `current` (else "Alpha-v0.1") are injection
// seams for tests / integration. Never throws.
json check_update(int timeout = 6, const std::string& url_override = "",
                  const std::string& current = "");

// Pure version helpers (exposed for tests).
std::vector<long long> version_key(const std::string& tag);
std::string line_prefix(const std::string& tag);
bool same_release(const std::string& tag, const std::string& current);
bool should_update(const std::string& latest_tag, const std::string& current);

}  // namespace update_check

// Register /api/ai/image/{generate,edit} and /api/update/check (additive; the
// Python backend exposes update only via its CLI/TUI, not HTTP).
void register_ai_image_routes(Router& r);
void register_update_routes(Router& r);

}  // namespace sa
