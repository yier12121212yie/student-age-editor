// server/services/env_store_ai.cpp — see env_store_ai.h (port of env_store.py
// AI half). Post-merge refactor R3: this is the ONE copy. It absorbed p3b's
// implementation, which was Python-faithful in three places where the old
// P4 copy diverged: str.strip over full Unicode whitespace (py_strip, not
// ASCII-only trim), round(x, 2) as correctly-rounded %.2f (banker's on exact
// binary ties, matching CPython — e.g. temperature 0.125 -> 0.12), and
// float()/int() coercion via py_float_str/py_int. p3b_ai_settings.{h,cpp}
// was deleted; /api/ai/settings calls read_ai_settings/write_ai_settings.
#include "env_store_ai.h"

#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <map>
#include <mutex>
#include <optional>
#include <string>
#include <vector>

#include "p3b_support.h"  // py_strip / py_float_str / json_truthy
#include "sa_core/atomic_io.h"
#include "sa_core/env_store.h"
#include "sa_core/json_wire.h"
#include "sa_core/paths.h"
#include "sa_core/strings.h"
#include "sa_core/util.h"

namespace sa {
namespace env_store_ai {
namespace {

namespace esp = sa_core::env_store;

std::mutex g_write_lock;  // read-merge-write serialisation (env_store._WRITE_LOCK)

// env_store.py:126-144 — primary -> alias fallback keys (order preserved).
const std::vector<std::string>& aliases_for(const std::string& key) {
    static const std::map<std::string, std::vector<std::string>> kMap = {
        {"baseUrl", {"base_url"}},
        {"apiKey", {"api_key", "apikey"}},
        {"imageModel", {"image_model"}},
        {"imageApiKey", {"image_api_key"}},
        {"imageBaseUrl", {"image_base_url"}},
        {"temperature", {"temp"}},
        {"ttsProvider", {"tts_provider"}},
        {"ttsApiKey", {"tts_api_key"}},
        {"ttsBaseUrl", {"tts_base_url"}},
        {"ttsModel", {"tts_model"}},
        {"ttsVoice", {"tts_voice"}},
        {"ttsGroupId", {"tts_group_id"}},
        {"ttsSpeed", {"tts_speed"}},
        {"ttsVolume", {"tts_volume"}},
        {"ttsPitch", {"tts_pitch"}},
        {"ttsFormat", {"tts_format"}},
        {"permissionMode", {"permission_mode"}},
    };
    static const std::vector<std::string> kEmpty;
    auto it = kMap.find(key);
    return it == kMap.end() ? kEmpty : it->second;
}

// env_store.py:121 ALLOWED providers / permission modes.
bool is_provider(const std::string& s) {
    return s == "openai_compatible" || s == "openai_responses" || s == "anthropic";
}
bool is_permission_mode(const std::string& s) { return s == "confirm" || s == "full"; }

std::string ascii_lower(std::string s) {
    for (auto& c : s) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    return s;
}

// Tolerant JSON-object read (bad json / non-object -> {}), shared with
// editor_env via sa_core::env_store.
json read_json_tolerant(const std::string& path) { return esp::read_json_file(path); }

double clampd(double v, double lo, double hi) { return std::min(std::max(v, lo), hi); }
long long clampi(long long v, long long lo, long long hi) {
    return v < lo ? lo : (v > hi ? hi : v);
}

// round(x, 2): CPython uses round-half-even on the exact binary value; the
// CRT %.2f is correctly rounded, which reproduces it for clamped inputs.
double round2(double x) {
    char buf[32];
    std::snprintf(buf, sizeof(buf), "%.2f", x);
    return std::strtod(buf, nullptr);
}

// float(x) on the JSON scalars normalize can hand it (bools never arrive —
// they are skipped upstream; containers -> TypeError -> nullopt).
std::optional<double> to_float(const json& v) {
    if (v.is_number()) return v.get<double>();
    if (v.is_string()) return p3b::py_float_str(v.get<std::string>());
    return std::nullopt;
}

// int(x): float truncates toward zero; string strict.
std::optional<long long> to_int(const json& v) {
    if (v.is_number_integer()) return v.get<long long>();
    if (v.is_number_unsigned()) return static_cast<long long>(v.get<unsigned long long>());
    if (v.is_number_float()) return static_cast<long long>(v.get<double>());
    if (v.is_string()) return sa_core::py_int(v.get<std::string>());
    return std::nullopt;
}

}  // namespace

const json& default_ai_settings() {
    // env_store.DEFAULT_AI_SETTINGS — insertion order is the wire order.
    static const json kDefault = [] {
        json d = json::object();
        d["provider"] = "openai_compatible";
        d["baseUrl"] = "";
        d["apiKey"] = "";
        d["model"] = "";
        d["temperature"] = 0.7;
        d["imageModel"] = "";
        d["imageApiKey"] = "";
        d["imageBaseUrl"] = "";
        d["ttsProvider"] = "";
        d["ttsApiKey"] = "";
        d["ttsBaseUrl"] = "";
        d["ttsModel"] = "";
        d["ttsVoice"] = "";
        d["ttsGroupId"] = "";
        d["ttsSpeed"] = 1.0;
        d["ttsVolume"] = 1.0;
        d["ttsPitch"] = 0;
        d["ttsFormat"] = "wav";
        d["maxRetries"] = 3;
        d["retryDelayMs"] = 1000;
        d["permissionMode"] = "confirm";
        return d;
    }();
    return kDefault;
}

json normalize_ai_settings(const json& data) {
    json out = default_ai_settings();
    if (!data.is_object()) return out;

    // Per-key: absent -> None assigned over the default (apiKey/baseUrl/model
    // legitimately answer null on a fresh store — the golden pins this).
    for (auto it = out.begin(); it != out.end(); ++it) {
        const std::string& key = it.key();
        json val = data.contains(key) ? data.at(key) : json();
        if (val.is_null()) {
            for (const auto& a : aliases_for(key)) {
                if (data.contains(a) && !data.at(a).is_null()) {
                    val = data.at(a);
                    break;
                }
            }
        }
        if (val.is_string()) {
            out[key] = p3b::py_strip(val.get<std::string>());
        } else if (val.is_boolean()) {
            // env_store has no boolean field; a stray bool keeps the default.
            continue;
        } else {
            out[key] = val;  // number / null / container passthrough
        }
    }

    // provider domain.
    if (!out["provider"].is_string() || !is_provider(out["provider"].get<std::string>())) {
        out["provider"] = "openai_compatible";
    }
    // temperature: 0.0 is legal — never `or 0.7` (env_store.py:157-158).
    {
        double temp = 0.7;
        if (!out["temperature"].is_null()) {
            auto f = to_float(out["temperature"]);
            temp = f.has_value() ? *f : 0.7;
        }
        out["temperature"] = round2(clampd(temp, 0.0, 2.0));
    }
    for (const char* k : {"imageModel", "imageApiKey", "imageBaseUrl"}) {
        if (!out[k].is_string()) out[k] = "";
    }
    // ---- tts block (env_store.py:172-209) ----
    if (out["ttsProvider"].is_string()) {
        out["ttsProvider"] = ascii_lower(out["ttsProvider"].get<std::string>());
    }
    // Python membership on the raw value: None not in ("", "minimax",
    // "aliyun") is TRUE -> reset to "". So a non-string (e.g. absent -> null)
    // must become "", NOT be treated as ""-valid.
    const json& tpv = out["ttsProvider"];
    const bool tp_ok = tpv.is_string() &&
                       (tpv.get_ref<const std::string&>() == "" ||
                        tpv.get_ref<const std::string&>() == "minimax" ||
                        tpv.get_ref<const std::string&>() == "aliyun");
    if (!tp_ok) out["ttsProvider"] = "";
    for (const char* k : {"ttsApiKey", "ttsBaseUrl", "ttsModel", "ttsVoice", "ttsGroupId",
                          "ttsFormat"}) {
        if (!out[k].is_string()) out[k] = "";
    }
    if (out["ttsFormat"].get_ref<const std::string&>().empty()) out["ttsFormat"] = "wav";
    // speed / volume: 0.0 legal, clamped [0.5, 2.0]; only an *unset* null
    // yields the 1.0 default.
    for (const char* k : {"ttsSpeed", "ttsVolume"}) {
        double v = 1.0;
        if (!out[k].is_null()) {
            auto f = to_float(out[k]);
            v = f.has_value() ? *f : 1.0;
        }
        out[k] = round2(clampd(v, 0.5, 2.0));
    }
    // pitch: int(x or 0) — falsy (None/0/""/False) collapses to 0 first.
    {
        long long pitch = 0;
        if (p3b::json_truthy(out["ttsPitch"])) {
            auto iv = to_int(out["ttsPitch"]);
            pitch = iv.has_value() ? *iv : 0;
        }
        out["ttsPitch"] = clampi(pitch, -12, 12);
    }
    {
        long long retries = 3;
        if (!out["maxRetries"].is_null()) {
            auto iv = to_int(out["maxRetries"]);
            retries = iv.has_value() ? *iv : 3;
        }
        out["maxRetries"] = clampi(retries, 0, 10);
    }
    {
        long long delay = 1000;
        if (!out["retryDelayMs"].is_null()) {
            auto iv = to_int(out["retryDelayMs"]);
            delay = iv.has_value() ? *iv : 1000;
        }
        out["retryDelayMs"] = clampi(delay, 0, 30000);
    }
    {
        std::string pm;
        if (out["permissionMode"].is_string()) {
            pm = ascii_lower(out["permissionMode"].get<std::string>());
        }
        if (!is_permission_mode(pm)) pm = "confirm";
        out["permissionMode"] = pm;
    }
    return out;
}

std::string ai_settings_path(const std::string& editor_root) {
    return sa_core::paths::join(editor_root, ".editor_ai.json");
}

json read_ai_settings(const std::string& editor_root) {
    return normalize_ai_settings(read_json_tolerant(ai_settings_path(editor_root)));
}

json write_ai_settings(const std::string& editor_root, const json& patch) {
    std::lock_guard<std::mutex> lk(g_write_lock);
    const std::string path = ai_settings_path(editor_root);
    json current = read_ai_settings(editor_root);
    json merged = current;  // current already carries all default keys
    if (patch.is_object()) {
        for (auto it = patch.begin(); it != patch.end(); ++it) {
            if (it.value().is_null()) continue;  // dict-comp: drop None values
            merged[it.key()] = it.value();
        }
    }
    json normalized = normalize_ai_settings(merged);
    // _merge_write_unlocked: merge normalized over the raw on-disk doc (which
    // may hold non-AI keys a future reader shares) and persist with indent=2.
    json on_disk = read_json_tolerant(path);
    for (auto it = normalized.begin(); it != normalized.end(); ++it) {
        on_disk[it.key()] = it.value();
    }
    sa_core::write_text_atomic(path, sa_core::py_dumps_indent(on_disk));
    return normalized;
}

}  // namespace env_store_ai
}  // namespace sa
