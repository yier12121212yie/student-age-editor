// wip/P4/tts.h — 配音（TTS）合成 + 存取 (P4). Port of tts_service.py + tts_store.py.
//
// Providers: MiniMax T2A V2 and Aliyun DashScope (qwen-tts / cosyvoice).
// Both speak over sa_core::http (WinHTTP). Every request URL is derived from
// settings.ttsBaseUrl, which is also the seam tests point at a local mock
// server (httplib::Server) — no real network in the [p4] suite.
#pragma once

#include <optional>
#include <string>
#include <utility>
#include <vector>

#include <nlohmann/json.hpp>

#include "server/httpd.h"

namespace sa {

using json = nlohmann::ordered_json;

// tts_service.TtsError — user-facing (Chinese) message.
struct TtsError : std::runtime_error {
    explicit TtsError(const std::string& msg) : std::runtime_error(msg) {}
};
// tts_store.TtsStoreError — same envelope, storage layer.
struct TtsStoreError : std::runtime_error {
    explicit TtsStoreError(const std::string& msg) : std::runtime_error(msg) {}
};

namespace tts {

// ---- pure helpers exposed for tests --------------------------------------
// tts_service._minimax_base: strip trailing /v1 to avoid /v1/v1.
std::string minimax_base(const json& settings);
// tts_service._extract_error: readable message from an upstream error body.
std::string extract_error(std::string_view raw);

// ---- provider-facing API -------------------------------------------------
// list_voices -> {"voices":[...], "source":"live"|"preset"}.
json voices_list(const std::string& provider, const json& settings);
// synthesize -> (audio_bytes, ext "wav"). Throws TtsError.
std::pair<std::string, std::string> synthesize(const std::string& provider,
                                               const std::string& text, const std::string& voice,
                                               const json& settings, const json& params);
// test_connection -> {"ok":bool, "detail"|"error":...}.
json test_connection(const std::string& provider, const json& settings, const json& params);

// wav -> ogg/vorbis via ffmpeg/oggenc; nullopt when no encoder or failure.
std::optional<std::string> encode_ogg(std::string_view wav);
// detect_encoder(): "" | "ffmpeg" | "oggenc" (only positive results cached).
std::string detect_encoder();

}  // namespace tts

namespace tts_store {

inline constexpr const char* kAudioDir = "audio/tts";

// save_audio -> {"key","path","ext","convertedOgg","bytes"}. Throws TtsStoreError.
json save_audio(const std::string& mod_root, const std::string& audio, const std::string& ext,
                const std::string& key, bool ogg);
// register_audio_cfg -> new AudioCfg id (int). Writes AudioCfg.json via cfg_store.
long long register_audio_cfg(const std::string& cfg_dir, const std::string& key,
                             const std::string& title);
// bind_talk_audio -> {"talkId","audioCfgId"}. Writes TalkCfg.audio via cfg_store
// with a table-level expect_mtime_ns; conflict raises TtsStoreError (B7).
json bind_talk_audio(const std::string& mod_root, const std::string& talk_id, long long audio_cfg_id);
// list_materials -> [{"path","size","ext"}].
json list_materials(const std::string& mod_root);
// read_audio -> bytes. delete_material -> deleted rel path.
std::string read_audio(const std::string& mod_root, const std::string& rel);
std::string delete_material(const std::string& mod_root, const std::string& rel);

}  // namespace tts_store

// /api/tts/{settings,test,voices,synthesize,save,audio,list,delete}.
void register_tts_routes(Router& r);

}  // namespace sa
