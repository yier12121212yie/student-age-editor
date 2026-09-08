// wip/P4/env_store_ai.cpp — see env_store_ai.h (port of env_store.py AI half).
#include "env_store_ai.h"

#include <algorithm>
#include <cctype>
#include <cmath>
#include <map>
#include <mutex>
#include <string>
#include <vector>

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

// Python `json.dumps(x, ensure_ascii=False, indent=2)`-style dict read is
// shared with editor_env (tolerant: bad json / non-object -> {}).
json read_json_tolerant(const std::string& path) { return esp::read_json_file(path); }

double clampd(double v, double lo, double hi) { return std::min(std::max(v, lo), hi); }
long long clampi(long long v, long long lo, long long hi) { return std::min(std::max(v, lo), hi); }

// Python round(x, 2) for the finite doubles we feed it. CPython uses
// banker's rounding at exact halves; the TTS/temperature domain never lands on
// a 0.5-at-the-third-decimal tie in practice, so half-away-from-zero on x*100
// (with a 1e-9 guard against binary representation drift) is byte-equivalent
// for every golden value (0.7 / 1.0 / clamped bounds).
double py_round2(double x) {
    double scaled = x * 100.0;
    double r = std::floor(scaled + 0.5 + 1e-9);
    if (x < 0) r = std::ceil(scaled - 0.5 - 1e-9);
    return r / 100.0;
}

// Coerce a JSON scalar to double with Python float() semantics; returns false
// on the (TypeError, ValueError) case so the caller applies the default.
bool to_double(const json& v, double* out) {
    if (v.is_number()) {
        *out = v.get<double>();
        return true;
    }
    if (v.is_boolean()) {
        *out = v.get<bool>() ? 1.0 : 0.0;
        return true;
    }
    if (v.is_string()) {
        // float(" 1.5 ") works; anything else is ValueError.
        std::string s = sa_core::str::trim(v.get<std::string>());
        if (s.empty()) return false;
        try {
            size_t pos = 0;
            double d = std::stod(s, &pos);
            // Reject trailing junk (stod is lenient); also allow exponent signs.
            while (pos < s.size() && std::isspace(static_cast<unsigned char>(s[pos]))) pos++;
            if (pos != s.size()) return false;
            *out = d;
            return true;
        } catch (...) {
            return false;
        }
    }
    return false;
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
        json val = json();  // None
        if (data.contains(key)) val = data.at(key);
        if (val.is_null()) {
            for (const auto& a : aliases_for(key)) {
                if (data.contains(a) && !data.at(a).is_null()) {
                    val = data.at(a);
                    break;
                }
            }
        }
        if (val.is_string()) {
            out[key] = sa_core::str::trim(val.get<std::string>());
        } else if (val.is_boolean()) {
            // env_store has no boolean field; a stray bool keeps the default.
            continue;
        } else {
            out[key] = val;  // number / null / object / array pass through
        }
    }

    // provider domain.
    if (out["provider"] != "openai_compatible" && out["provider"] != "openai_responses" &&
        out["provider"] != "anthropic") {
        out["provider"] = "openai_compatible";
    }
    // temperature: 0.0 legal, never `or 0.7`.
    {
        double temp = 0.7;
        if (!out["temperature"].is_null() && !to_double(out["temperature"], &temp)) temp = 0.7;
        out["temperature"] = py_round2(clampd(temp, 0.0, 2.0));
    }
    for (const char* k : {"imageModel", "imageApiKey", "imageBaseUrl"}) {
        if (!out[k].is_string()) out[k] = "";
    }
    // ttsProvider domain.
    {
        std::string provider;
        if (out["ttsProvider"].is_string()) {
            provider = sa_core::str::lower(sa_core::str::trim(out["ttsProvider"].get<std::string>()));
        }
        if (provider != "minimax" && provider != "aliyun") provider = "";
        out["ttsProvider"] = provider;
    }
    for (const char* k : {"ttsApiKey", "ttsBaseUrl", "ttsModel", "ttsVoice", "ttsGroupId",
                          "ttsFormat"}) {
        if (!out[k].is_string()) out[k] = "";
    }
    if (out["ttsFormat"].get_ref<const std::string&>().empty()) out["ttsFormat"] = "wav";
    // speed / volume: 0.0 / 0 legal, clamped [0.5, 2.0] (a value below the
    // floor still rounds to the floor; only an *unset* value yields 1.0).
    for (const char* k : {"ttsSpeed", "ttsVolume"}) {
        double v = 1.0;
        if (!out[k].is_null() && !to_double(out[k], &v)) v = 1.0;
        out[k] = py_round2(clampd(v, 0.5, 2.0));
    }
    // pitch: int(out.get or 0) — falsy (None/0/""/False) collapses to 0 first.
    {
        long long pitch = 0;
        const json& p = out["ttsPitch"];
        bool falsy = p.is_null() || (p.is_number() && p.get<double>() == 0.0) ||
                     (p.is_string() && p.get<std::string>().empty()) ||
                     (p.is_boolean() && !p.get<bool>());
        if (!falsy) {
            // Python int(x): number truncates; string parses like int(str).
            if (p.is_number_integer() || p.is_number_unsigned()) {
                pitch = p.get<long long>();
            } else if (p.is_number_float()) {
                pitch = static_cast<long long>(p.get<double>());
            } else if (p.is_string()) {
                auto iv = sa_core::py_int(sa_core::str::trim(p.get<std::string>()));
                pitch = iv.value_or(0);
            }
        }
        out["ttsPitch"] = clampi(pitch, -12, 12);
    }
    {
        long long retries = 3;
        if (!out["maxRetries"].is_null()) {
            if (out["maxRetries"].is_number()) {
                retries = static_cast<long long>(out["maxRetries"].get<double>());
            } else if (out["maxRetries"].is_string()) {
                auto iv = sa_core::py_int(sa_core::str::trim(out["maxRetries"].get<std::string>()));
                if (!iv) retries = 3; else retries = *iv;
            }
        }
        out["maxRetries"] = clampi(retries, 0, 10);
    }
    {
        long long delay = 1000;
        if (!out["retryDelayMs"].is_null()) {
            if (out["retryDelayMs"].is_number()) {
                delay = static_cast<long long>(out["retryDelayMs"].get<double>());
            } else if (out["retryDelayMs"].is_string()) {
                auto iv = sa_core::py_int(
                    sa_core::str::trim(out["retryDelayMs"].get<std::string>()));
                if (!iv) delay = 1000; else delay = *iv;
            }
        }
        out["retryDelayMs"] = clampi(delay, 0, 30000);
    }
    {
        std::string pm;
        if (out["permissionMode"].is_string()) {
            pm = sa_core::str::lower(sa_core::str::trim(out["permissionMode"].get<std::string>()));
        }
        if (pm != "confirm" && pm != "full") pm = "confirm";
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
