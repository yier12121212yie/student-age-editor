// wip/P4/flow_assets.cpp — see flow_assets.h (port of flow_assets.py).
#include "flow_assets.h"

#include <optional>
#include <regex>
#include <string>
#include <vector>

#include "sa_core/strings.h"
#include "sa_core/util.h"
#include "p4_util.h"

namespace sa {
namespace flow {
namespace {

constexpr int kCgMinW = 1280;
constexpr int kCgMinH = 720;
constexpr double kCgRatioMin = 1.15;
constexpr double kCgRatioMax = 2.4;

std::string bundle_name(std::string_view bundle_path) {
    // flow_assets._bundle_name: forward-slash, lowercase, basename.
    std::string s = sa_core::str::lower(sa_core::str::replace_all(std::string(bundle_path), "\\", "/"));
    return p4::basename(s);
}

// flow_assets._tex_group: textures_assets_<group>_<hash>.bundle -> group.
std::optional<std::string> tex_group(const std::string& name) {
    static const std::string kPrefix = "textures_assets_";
    if (!sa_core::str::starts_with(name, kPrefix)) return std::nullopt;
    std::string rest = name.substr(kPrefix.size());
    if (sa_core::str::ends_with(rest, ".bundle"))
        rest = rest.substr(0, rest.size() - std::string(".bundle").size());
    std::vector<std::string> parts;
    size_t pos = 0;
    while (true) {
        size_t under = rest.find('_', pos);
        parts.push_back(rest.substr(pos, under == std::string::npos ? std::string::npos : under - pos));
        if (under == std::string::npos) break;
        pos = under + 1;
    }
    // Trailing 16+ hex segment is the packing hash — drop it.
    static const std::regex kHash("[0-9a-f]{16,}$");
    if (parts.size() > 1 && std::regex_search(parts.back(), kHash)) parts.pop_back();
    if (parts.empty()) return std::nullopt;
    return parts.front();
}

}  // namespace

bool is_cg_image(const std::string& key, const std::string& bundle_path, long long width,
                 long long height) {
    long long w = width;
    long long h = height;
    if (w < kCgMinW || h < kCgMinH) return false;
    std::string kl_lower = sa_core::str::lower(p4::strip(key));
    if (sa_core::str::starts_with(kl_lower, "sactx-")) return false;

    std::string name = bundle_name(bundle_path);
    auto group = tex_group(name);
    if (!group) {
        if (sa_core::str::ends_with(name, ".bundle")) return false;
    } else if (*group == "cg" || *group == "cg2" || *group == "big" || *group == "comic") {
        return true;
    } else if (!(*group == "" || *group == "bg" || sa_core::str::starts_with(*group, "v"))) {
        return false;  // paint/icon/role/kzone-head/guide/...
    }
    double ratio = static_cast<double>(w) / static_cast<double>(h);
    if (!(ratio >= kCgRatioMin && ratio <= kCgRatioMax)) return false;
    static const std::regex kVeto("(icon|head|avatar|cloth|\\bui[_-]|atlas|spine)");
    if (std::regex_search(kl_lower, kVeto)) return false;
    return true;
}

std::set<std::string> music_url_basenames(const nlohmann::ordered_json& audio_rows) {
    std::set<std::string> out;
    // dict-of-rows (values) or an array of rows.
    auto consider = [&](const nlohmann::ordered_json& row) {
        if (!row.is_object()) return;
        long long type = 0;
        if (row.contains("type") && !row.at("type").is_null()) {
            auto iv = p4::json_int(row.at("type"));
            if (!iv) return;  // int() raised -> continue
            type = *iv;
        }
        if (type != 1) return;
        std::string url;
        if (row.contains("url") && !row.at("url").is_null()) url = p4::strip(sa_core::py_str(row.at("url")));
        if (url.empty()) return;
        std::string base = sa_core::str::lower(p4::basename(sa_core::str::replace_all(url, "\\", "/")));
        base = p4::split_ext(base).first;
        if (!base.empty()) out.insert(base);
    };
    if (audio_rows.is_object()) {
        for (auto it = audio_rows.begin(); it != audio_rows.end(); ++it) consider(it.value());
    } else if (audio_rows.is_array()) {
        for (const auto& row : audio_rows) consider(row);
    }
    return out;
}

bool is_music(const std::string& key, const std::string& bundle_path,
              const std::set<std::string>& music_urls) {
    std::string kl = sa_core::str::lower(p4::strip(key));
    std::string name = bundle_name(bundle_path);
    std::string full = sa_core::str::lower(sa_core::str::replace_all(bundle_path, "\\", "/"));
    static const char* kReject[] = {"audios_assets_role", "audios_assets_ogg", "audio/tts",
                                    "audio\\tts"};
    for (const char* tag : kReject) {
        bool in_name = name.find(tag) != std::string::npos;
        bool in_full = full.find(tag) != std::string::npos;
        if (in_name || in_full || sa_core::str::starts_with(kl, "audio/tts")) return false;
    }
    if (name.find("audios_assets_bgm") != std::string::npos ||
        name.find("bgm") != std::string::npos)
        return true;
    return music_urls.count(kl) > 0;
}

}  // namespace flow
}  // namespace sa
