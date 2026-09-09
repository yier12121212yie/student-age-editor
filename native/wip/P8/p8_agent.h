// wip/P8/p8_agent.h — the lightweight agent chat pane.
//
// Speaks the same wire shape as the Python agent client (agent/client.py) but
// only the `openai_compatible` provider: POST {base}/chat/completions with
// {"model","temperature","stream":true,"messages":[{role,content}...]} and an
// `Authorization: Bearer <key>` header. Response is parsed either as an SSE
// stream (the `data:` deltas are concatenated) or as a single JSON body. No
// tool-call loop is ported (see STATUS.md "取舍"); this pane is pure chat.
//
// Chat history persistence mirrors agent/history_store.py only loosely: one JSON
// file per session under <dir>/.p8_ai_history/, written into the temp data root.
#pragma once

#include <string>
#include <vector>

#include "p8_model.h"

namespace p8 {

struct AgentSettings {
    std::string provider = "openai_compatible";
    std::string base;         // e.g. https://api.openai.com/v1 (empty -> default)
    std::string model;
    double temperature = 0.7;
    std::string api_key;
};

class AgentClient {
public:
    explicit AgentClient(AgentSettings settings) : settings_(std::move(settings)) {}
    const AgentSettings& settings() const { return settings_; }
    bool configured() const { return !settings_.api_key.empty(); }

    // ---- pure request/response transforms (unit-tested) -----------------
    // OpenAI-compatible chat/completions body with a leading system message.
    static Json BuildChatBody(const std::string& model, double temperature,
                              const std::string& system, const std::vector<ChatMsg>& messages);
    // Yield each `data:` payload from an SSE body (prefix + whitespace stripped).
    static std::vector<std::string> SplitSSE(const std::string& body);
    // Concatenate choices[0].delta.content across SSE data payloads.
    static std::string AccumulateStream(const std::vector<std::string>& data_lines);
    // choices[0].message.content from a non-streaming JSON body.
    static std::string ParseWhole(const Json& resp);
    static std::string ResolveBase(const std::string& base);

    // ---- transport (blocking; fills *err on failure) --------------------
    // One round-trip: returns the assistant text (also appended to *err_msg on
    // failure). Never throws.
    std::string SendTurn(const std::string& system, const std::vector<ChatMsg>& history,
                         std::string* err);

private:
    AgentSettings settings_;
};

// Parse {provider,baseUrl,model,temperature,apiKey} from a JSON object.
AgentSettings AgentSettingsFromJson(const Json& body);

// ---- history persistence (a session = role/content message list) --------
std::string HistoryDir(const std::string& data_root);
bool SaveSession(const std::string& data_root, const std::string& id,
                 const std::vector<ChatMsg>& messages);
std::vector<ChatMsg> LoadSession(const std::string& data_root, const std::string& id);

}  // namespace p8
