// server/services/ai_relay_routes.cpp — see ai_relay_routes.h for the contract.
//
// The relay is deliberately THIN: it never inspects the conversation, never
// logs message bodies, and holds no state. What it does guarantee:
//   * the upstream URL + credentials come from the admin/server config only
//     (a client-supplied base_url in the body is dropped — SSRF wall);
//   * `stream` is forced false so the buffered httpd transport never needs
//     chunked responses (打字机流式是 M4 的 httpd 扩展);
//   * upstream status + JSON body pass through verbatim so the client-side
//     agent loop parses exactly what it would parse from a direct call.
#include "ai_relay_routes.h"

#include <string>

#include "env_store_ai.h"
#include "sa_core/http_client.h"
#include "sa_core/json_wire.h"
#include "sa_core/strings.h"
#include "server/state.h"

namespace sa {

namespace http = sa_core::http;

namespace ai_relay {
namespace {

// Frontend parity: ai_client._uri — trailing slashes trimmed, scheme added.
// Defaults mirror ai_client's provider switch.
std::string normalize_base(std::string_view base, const std::string& provider) {
    std::string b = sa_core::str::trim(std::string(base));
    while (!b.empty() && b.back() == '/') b.pop_back();
    if (b.empty()) {
        b = provider == "anthropic" ? "https://api.anthropic.com/v1"
                                    : "https://api.openai.com/v1";
    }
    if (!sa_core::str::starts_with(b, "http://") && !sa_core::str::starts_with(b, "https://"))
        b = "https://" + b;
    return b;
}

const char* path_for(const std::string& provider) {
    if (provider == "anthropic") return "/messages";
    if (provider == "openai_responses") return "/responses";
    return "/chat/completions";  // openai_compatible (and anything normalized to it)
}

std::string error_json_str(const std::string& msg) {
    json env;
    env["error"] = msg;
    return sa_core::py_dumps(env);
}

}  // namespace

RelaySettings read_settings_from_ai(const json& ai) {
    RelaySettings s;
    s.provider = ai.contains("provider") && ai["provider"].is_string()
                    ? ai["provider"].get<std::string>()
                    : "openai_compatible";
    s.base_url = ai.contains("baseUrl") && ai["baseUrl"].is_string()
                     ? ai["baseUrl"].get<std::string>()
                     : "";
    s.api_key = ai.contains("apiKey") && ai["apiKey"].is_string()
                    ? ai["apiKey"].get<std::string>()
                    : "";
    s.model = ai.contains("model") && ai["model"].is_string() ? ai["model"].get<std::string>()
                                                              : "";
    s.usable = !s.api_key.empty() &&
               (s.provider == "openai_compatible" || s.provider == "openai_responses" ||
                s.provider == "anthropic");
    return s;
}

json policy_json(const RelaySettings& s, bool own_key_allowed, bool tts_image_available,
                 const std::vector<std::string>& models, long long daily_limit) {
    json body;
    body["relay_available"] = s.usable;
    body["provider"] = s.usable ? s.provider : "";
    body["model"] = s.model;
    json m = json::array();
    for (const auto& x : models) m.push_back(x);
    body["models"] = std::move(m);  // empty == unrestricted
    body["own_key_allowed"] = own_key_allowed;
    body["tts_image_available"] = tts_image_available;
    body["stream"] = false;  // buffered transport only (v1)
    json limits = json::object();
    limits["daily"] = daily_limit;  // 0 == no limit (raw backend)
    body["limits"] = std::move(limits);
    return body;
}

Resp relay_chat(const RelaySettings& s, const json& client_body) {
    if (!s.usable) return Resp::Json(503, json{{"error", "ai relay not configured"}});
    if (!client_body.is_object())
        return Resp::Json(400, json{{"error", "body must be a JSON object"}});

    json fwd = client_body;  // ordered_json copy; drop control + injection keys
    fwd.erase("protocol");   // frontend hint; the SERVER decides the protocol
    fwd.erase("base_url");   // SSRF wall: caller-chosen hosts are never used
    fwd.erase("baseUrl");
    fwd.erase("api_key");
    fwd.erase("apiKey");
    fwd["stream"] = false;   // httpd has no chunked transport (v1)
    if (!fwd.contains("model") || !fwd.at("model").is_string() ||
        fwd.at("model").get<std::string>().empty()) {
        if (!s.model.empty()) fwd["model"] = s.model;
    }
    // Anthropic rejects requests without max_tokens; supply a sane default.
    if (s.provider == "anthropic" && !fwd.contains("max_tokens")) fwd["max_tokens"] = 8192;

    http::Request req;
    req.method = "POST";
    req.url = normalize_base(s.base_url, s.provider) + path_for(s.provider);
    req.body = sa_core::py_dumps(fwd);
    req.timeout_seconds = 300.0;
    req.follow_redirects = true;  // 云端 API 上游：保持 urllib 跟随语义
    if (s.provider == "anthropic") {
        req.headers = {{"Content-Type", "application/json"},
                       {"Accept", "application/json"},
                       {"x-api-key", s.api_key},
                       {"anthropic-version", "2023-06-01"}};
    } else {
        req.headers = {{"Content-Type", "application/json"},
                       {"Accept", "application/json"},
                       {"Authorization", "Bearer " + s.api_key}};
    }
    http::Response up = http::request(req);
    if (!up.transport_ok()) {
        // Machine-readable prefix lets the client branch; message is the OS one.
        return Resp::Json(
            502, json{{"error", "ai_upstream_unreachable: " + up.error_message}});
    }
    // Verbatim pass-through (status + bytes). Body is never logged anywhere.
    std::string ct = up.header("Content-Type");
    if (ct.empty()) ct = "application/json";
    Resp r = Resp::BytesTyped(up.status, std::move(up.body), std::move(ct));
    return r;
}

}  // namespace ai_relay

void register_ai_relay_routes(Router& r) {
    // GET /api/ai/policy — local backend semantics: relay is available once
    // chat is configured in editor_env; own-key direct mode and TTS/生图 are
    // unrestricted here (they only live on the user's own machine).
    r.get(R"(/api/ai/policy)", [](const Req&) -> Resp {
        json ai = env_store_ai::read_ai_settings(editor_root());
        ai_relay::RelaySettings s = ai_relay::read_settings_from_ai(ai);
        return Resp::Json(200, ai_relay::policy_json(s, /*own_key_allowed=*/true,
                                                     /*tts_image_available=*/true, {}, 0));
    });

    // POST /api/ai/relay/chat — one buffered round of the provider conversation
    // the client is driving (tool loop stays client-side).
    // 性能 P1：?async=1 走后台 job（202 {"job_id"}，GET /api/jobs/{id} 轮询）。
    r.post(R"(/api/ai/relay/chat)", sa::wrap_async_job([](const Req& req) -> Resp {
        json ai = env_store_ai::read_ai_settings(editor_root());
        ai_relay::RelaySettings s = ai_relay::read_settings_from_ai(ai);
        return ai_relay::relay_chat(s, req.body);
    }));
}

}  // namespace sa
