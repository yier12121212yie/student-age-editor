// wip/P4/flow_assets.h — C++ port of `server/flow_assets.py` (pure functions).
//
// CG-image / BGM-music classification over AA key + bundle-file-name signals.
// Consumed by /api/aa/keys?scope=flow. Pure, STATE-free, unit-testable.
//
// Pitfalls honoured:
//   * is_cg_image: resolution hard floor (1280x720) first, sactx- atlas veto,
//     Addressable group whitelist/veto, then mixed-group ratio + key-name veto.
//     Missing width/height returns False (caller decides the fallback filter —
//     ARTIFACT_FORMAT §8.4).
//   * _tex_group parses the group out of `textures_assets_<group>_<hash>.bundle`
//     (group may contain '-'; trailing 16+ hex is the packing hash).
#pragma once

#include <set>
#include <string>

#include <nlohmann/json.hpp>

namespace sa {
namespace flow {

// flow_assets.is_cg_image.
bool is_cg_image(const std::string& key, const std::string& bundle_path, long long width,
                 long long height);

// flow_assets.music_url_basenames: AudioCfg row dict (or iterable of rows) ->
// the set of lowercased, extension-stripped url basenames for type==1 rows.
std::set<std::string> music_url_basenames(const nlohmann::ordered_json& audio_rows);

// flow_assets.is_music.
bool is_music(const std::string& key, const std::string& bundle_path,
              const std::set<std::string>& music_urls);

}  // namespace flow
}  // namespace sa
