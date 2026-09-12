// wip/P4/aa.h — Addressables artifact consumers for /api/aa/* (P4).
//
// Two read-only data sources feed the media endpoints:
//   * AaIndex    — the game aa_index.json (ARTIFACT_FORMAT §1 v3). Read-only:
//                  C++ NEVER opens bundles (no UnityPy); a bundle-referenced
//                  object that is not present in a decoded pack cannot be
//                  decoded => preview/export answer 422 (the §8.7 boundary).
//   * DecodedPack — a pre-decoded resource pack (tex/*.webp, aud/*.ogg, §6):
//                  files are read directly with the right mime.
//
// norm_key (ARTIFACT_FORMAT §1) is the shared key normalisation for lookups.
#pragma once

#include <array>
#include <cstdint>
#include <map>
#include <memory>
#include <mutex>
#include <optional>
#include <set>
#include <string>
#include <vector>

#include <nlohmann/json.hpp>

#include "server/httpd.h"

namespace sa {

using json = nlohmann::ordered_json;

// os.path.splitext(obj)[0].split(" #")[0].strip().lower() (unityfs_res._norm_key).
std::string norm_key(std::string_view object_name);

// One [bundle_path, path_id] reference (int64 id preserved, ARTIFACT_FORMAT §1).
struct ResRef {
    std::string bundle;
    int64_t path_id = 0;
};

class AaIndex {
  public:
    // Parse an aa_index.json document. Returns false unless it is a v3,
    // non-decoded index with a tex/aud/txt object map.
    bool load_from_json(const json& data);
    // Load + parse from disk (utf-8-sig tolerant). Returns false on any miss.
    bool load_from_file(const std::string& path);

    // §8.2 relocation: for every reference whose bundle no longer exists, try
    // to relocate it by basename under `aa_dir`; a successful relocation makes
    // `cabs` untrustworthy, so it is dropped (rebuilt on next tool run).
    // Returns the number of relocated references.
    int relocate_bundles(const std::string& aa_dir);

    bool has_texmeta() const { return !texmeta_.empty(); }

    std::vector<std::string> tex_keys() const;  // index insertion order (§1)
    std::vector<std::string> aud_keys() const;
    std::vector<std::string> txt_keys() const;

    bool has_tex(std::string key) const;  // key normalised before lookup
    bool has_aud(std::string key) const;
    bool has_txt(std::string key) const;

    // bundle path carrying `key` (for group-based CG/BGM decisions); "" absent.
    std::string tex_bundle(std::string key) const;
    std::string aud_bundle(std::string key) const;
    // [w, h] from texmeta; nullopt when absent (sparse — §8.4).
    std::optional<std::array<int, 2>> tex_meta(std::string key) const;
    // §8.1: the raw int64 path_id for a tex key (0 when absent) — proves the
    // large ±9.2e18 ids survive parsing (no double truncation).
    int64_t tex_path_id(std::string key) const;

    bool empty() const { return tex_.empty() && aud_.empty() && txt_.empty(); }
    bool partial() const { return partial_; }
    const std::vector<std::string>& bundles() const { return bundles_; }

  private:
    std::map<std::string, ResRef> tex_, aud_, txt_;  // key (already normalised)
    std::map<std::string, std::pair<int, int>> texmeta_;
    std::vector<std::string> bundles_;
    bool partial_ = false;
    std::map<std::string, std::vector<std::string>> tex_order_;  // for stable key lists
};

class DecodedPack {
  public:
    // Rebuild the index for `pack_dir` (no-op when unchanged). Scans tex/ +
    // aud/, resolves txt keys from a v3-decoded aa_index.json or Cfgs/zh-cn.
    void refresh(const std::string& pack_dir);
    bool active() const;

    long long tex_count() const;
    long long aud_count() const;
    std::vector<std::string> tex_keys() const;  // sorted (decoded_pack.tex_keys)
    std::vector<std::string> aud_keys() const;
    std::vector<std::string> txt_keys() const;

    std::string tex_path(std::string key) const;
    std::string aud_path(std::string key) const;
    // [w, h] read from the image header (png/jpeg/webp); nullopt otherwise.
    std::optional<std::array<int, 2>> tex_meta(std::string key) const;
    // Read a decoded file's bytes + lowercased extension; nullopt on failure.
    std::optional<std::pair<std::string, std::string>> read_file(const std::string& path) const;

  private:
    // Instance data is read through shared_ptr copies held across requests
    // while refresh() may run on another thread (active-pack switch), so every
    // access to the members below goes through data_mu_.
    mutable std::mutex data_mu_;
    std::string dir_;
    std::map<std::string, std::string> tex_, aud_;
    std::vector<std::string> txt_;
    mutable std::map<std::string, std::optional<std::array<int, 2>>> texsizes_;
};

// Process-wide, lazily refreshed accessors.
std::shared_ptr<AaIndex> ensure_aa_index();       // from _cache/aa_index/aa_index.json
std::shared_ptr<DecodedPack> ensure_pack_store(); // from active_pack_dir()
std::string active_pack_dir();                    // "" when no pack configured

// Clear the lazy singletons (tests only) so a re-pointed editor root / pack dir
// is re-read.
void reset_aa_singletons_for_test();

// (id, name) of the active bundled pack for /api/aa/status.
std::pair<std::string, std::string> pack_active_info();

// mime tables (decoded_pack._TEX_MIME / _AUD_MIME) + the preview mime maps.
std::string tex_mime(std::string_view ext);
std::string aud_mime(std::string_view ext);

// Register /api/aa/{keys,preview,status,export,scan}.
void register_aa_routes(Router& r);

}  // namespace sa
