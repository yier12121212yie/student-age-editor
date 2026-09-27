// server/services/ai_relay_routes.h — buffered AI chat relay + supply policy
// (网页版计划 M1.3).
//
// Two endpoints:
//   GET  /api/ai/policy      — what AI supply this server offers (relay vs the
//                              browser's own-key direct mode, provider, model).
//   POST /api/ai/relay/chat  — one non-streaming chat round-trip forwarded to
//                              the ADMIN-configured provider.
//
// Why a relay at all: a browser page cannot call most AI providers directly
// (CORS blocks OpenAI; keys must not leak to the client), so the web editor's
// "platform key" mode routes chat through here. The frontend agent tool loop
// stays client-side — it drives the loop by calling this endpoint once per
// round, exactly as the desktop client calls the provider per round.
//
// SSRF guard (the whole point of the trust boundary): the relay uses ONLY the
// server-side admin-configured base_url / apiKey / provider. A client-sent
// base_url is ignored. This endpoint therefore never proxies to a caller-
// chosen host. The gateway (M2.3) reuses the same ai_relay:: helpers but reads
// its own admin config (gateway.json) instead of the local env_store.
#pragma once

#include <string>
#include <vector>

#include <nlohmann/json.hpp>

#include "server/httpd.h"

namespace sa {
namespace ai_relay {

// Resolved chat-provider view of the AI settings (either source: local
// env_store_ai json, or the gateway's gateway.json ai_relay section).
struct RelaySettings {
    std::string provider = "openai_compatible";
    std::string base_url;   // admin-configured; client-supplied value ignored
    std::string api_key;
    std::string model;
    bool usable = false;    // apiKey present && provider is chat-capable
};

// Map an already-normalized AI settings object (env_store_ai::read_ai_settings
// output, or a hand-built gateway config json with the same key names) into a
// RelaySettings, applying the chat-provider allowlist.
RelaySettings read_settings_from_ai(const nlohmann::ordered_json& ai);

// The GET /api/ai/policy body. The two boolean flags differ by tier: a raw
// local backend reports own-key/TTS as available (everything is on the user's
// own machine); the gateway flips them per admin policy.
nlohmann::ordered_json policy_json(const RelaySettings& s, bool own_key_allowed,
                                   bool tts_image_available,
                                   const std::vector<std::string>& models,
                                   long long daily_limit);

// One buffered round-trip. Never logs or retains the body; on transport failure
// returns 502 {"error":"ai_upstream_unreachable: ..."}. Upstream status + bytes
// pass through verbatim.
Resp relay_chat(const RelaySettings& s, const nlohmann::ordered_json& client_body);

}  // namespace ai_relay

// Registers GET /api/ai/policy + POST /api/ai/relay/chat on the RAW backend
// (local editor_env source). The gateway registers its own variants via the
// ai_relay:: helpers directly — it does not call this.
void register_ai_relay_routes(Router& r);

}  // namespace sa
