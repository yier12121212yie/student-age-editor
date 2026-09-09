// native/tui/p8_agent.cpp
#include "p8_agent.h"

#include <cctype>

#include "sa_core/http_client.h"
#include "sa_core/paths.h"

namespace p8 {

using sa_core::http::Request;
using sa_core::http::Response;
namespace cs = sa_core::paths;

std::string AgentClient::ResolveBase(const std::string& base) {
    std::string b = base.empty() ? std::string("https://api.openai.com/v1") : base;
    while (!b.empty() && b.back() == '/') b.pop_back();
    return b;
}

Json AgentClient::BuildChatBody(const std::string& model, double temperature,
                                const std::string& system,
                                const std::vector<ChatMsg>& messages) {
    Json msgs = Json::array();
    Json sys = Json::object();
    sys["role"] = "system";
    sys["content"] = system;
    msgs.push_back(sys);
    for (const auto& m : messages) {
        Json e = Json::object();
        e["role"] = m.role;
        e["content"] = m.content;
        msgs.push_back(e);
    }
    Json body = Json::object();
    body["model"] = model;
    body["temperature"] = temperature;
    body["stream"] = true;
    body["messages"] = std::move(msgs);
    return body;
}

std::vector<std::string> AgentClient::SplitSSE(const std::string& body) {
    std::vector<std::string> out;
    size_t pos = 0;
    while (pos <= body.size()) {
        size_t nl = body.find('\n', pos);
        std::string line = body.substr(pos, nl == std::string::npos ? std::string::npos : nl - pos);
        if (!line.empty() && line.back() == '\r') line.pop_back();
        // Trim ASCII whitespace.
        size_t a = line.find_first_not_of(" \t");
        if (a != std::string::npos) line = line.substr(a);
        size_t b = line.find_last_not_of(" \t");
        if (b != std::string::npos) line = line.substr(0, b + 1);
        const std::string pfx = "data:";
        if (line.rfind(pfx, 0) == 0) {
            std::string payload = line.substr(pfx.size());
            size_t q = payload.find_first_not_of(" \t");
            if (q != std::string::npos) payload = payload.substr(q);
            if (!payload.empty() && payload != "[DONE]") out.push_back(payload);
        }
        if (nl == std::string::npos) break;
        pos = nl + 1;
    }
    return out;
}

std::string AgentClient::AccumulateStream(const std::vector<std::string>& data_lines) {
    std::string text;
    for (const auto& payload : data_lines) {
        Json chunk = Json::parse(payload, nullptr, /*allow_exceptions=*/false);
        if (chunk.is_discarded() || !chunk.is_object()) continue;
        if (!chunk.contains("choices") || !chunk.at("choices").is_array() ||
            chunk.at("choices").empty())
            continue;
        const Json& first = chunk.at("choices").at(0);
        if (!first.is_object() || !first.contains("delta")) continue;
        const Json& delta = first.at("delta");
        if (delta.is_object() && delta.contains("content") && delta.at("content").is_string())
            text += delta.at("content").get<std::string>();
    }
    return text;
}

std::string AgentClient::ParseWhole(const Json& resp) {
    if (!resp.is_object() || !resp.contains("choices") || !resp.at("choices").is_array() ||
        resp.at("choices").empty())
        return {};
    const Json& first = resp.at("choices").at(0);
    if (!first.is_object() || !first.contains("message")) return {};
    const Json& msg = first.at("message");
    if (msg.is_object() && msg.contains("content") && msg.at("content").is_string())
        return msg.at("content").get<std::string>();
    return {};
}

std::string AgentClient::SendTurn(const std::string& system, const std::vector<ChatMsg>& history,
                                 std::string* err) {
    if (err) err->clear();
    if (settings_.api_key.empty()) {
        if (err) *err = "未配置 API Key";
        return {};
    }
    Request req;
    req.method = "POST";
    req.url = ResolveBase(settings_.base) + "/chat/completions";
    req.headers.emplace_back("Content-Type", "application/json");
    req.headers.emplace_back("Accept", "text/event-stream");
    req.headers.emplace_back("Authorization", "Bearer " + settings_.api_key);
    req.timeout_seconds = 120.0;
    req.body = BuildChatBody(settings_.model, settings_.temperature, system, history).dump();

    Response resp = sa_core::http::request(req);
    if (!resp.transport_ok()) {
        if (err) *err = resp.error_message.empty() ? "网络错误" : resp.error_message;
        return {};
    }
    if (resp.status >= 400) {
        Json parsed = Json::parse(resp.body, nullptr, false);
        std::string msg = "HTTP " + std::to_string(resp.status);
        if (!parsed.is_discarded() && parsed.is_object() && parsed.contains("error"))
            msg += ": " + parsed.at("error").dump();
        if (err) *err = msg;
        return {};
    }
    auto data_lines = SplitSSE(resp.body);
    if (!data_lines.empty()) return AccumulateStream(data_lines);
    Json parsed = Json::parse(resp.body, nullptr, false);
    if (parsed.is_discarded()) {
        if (err) *err = "响应无法解析";
        return {};
    }
    return ParseWhole(parsed);
}

AgentSettings AgentSettingsFromJson(const Json& body) {
    AgentSettings s;
    if (!body.is_object()) return s;
    if (body.contains("provider") && body.at("provider").is_string())
        s.provider = body.at("provider").get<std::string>();
    if (body.contains("baseUrl") && body.at("baseUrl").is_string())
        s.base = body.at("baseUrl").get<std::string>();
    if (body.contains("model") && body.at("model").is_string())
        s.model = body.at("model").get<std::string>();
    if (body.contains("temperature") && body.at("temperature").is_number())
        s.temperature = body.at("temperature").get<double>();
    if (body.contains("apiKey") && body.at("apiKey").is_string())
        s.api_key = body.at("apiKey").get<std::string>();
    return s;
}

namespace {
bool SafeId(const std::string& id) {
    if (id.empty()) return false;
    for (char c : id) {
        bool ok = std::isalnum(static_cast<unsigned char>(c)) || c == '.' || c == '_' || c == '-';
        if (!ok) return false;
    }
    return id != "..";
}
}  // namespace

std::string HistoryDir(const std::string& data_root) {
    std::string root = data_root.empty() ? cs::exe_dir() : data_root;
    return cs::join(root, ".p8_ai_history");
}

bool SaveSession(const std::string& data_root, const std::string& id,
                 const std::vector<ChatMsg>& messages) {
    if (!SafeId(id)) return false;
    std::string dir = HistoryDir(data_root);
    if (!cs::create_dirs(dir)) return false;
    Json arr = Json::array();
    for (const auto& m : messages) {
        Json e = Json::object();
        e["role"] = m.role;
        e["content"] = m.content;
        arr.push_back(e);
    }
    Json session = Json::object();
    session["id"] = id;
    session["messages"] = std::move(arr);
    return cs::write_bytes_simple(cs::join(dir, id + ".json"), session.dump());
}

std::vector<ChatMsg> LoadSession(const std::string& data_root, const std::string& id) {
    std::vector<ChatMsg> out;
    if (!SafeId(id)) return out;
    auto raw = cs::read_bytes(cs::join(HistoryDir(data_root), id + ".json"));
    if (!raw) return out;
    Json session = Json::parse(*raw, nullptr, false);
    if (session.is_discarded() || !session.is_object() || !session.contains("messages") ||
        !session.at("messages").is_array())
        return out;
    for (const auto& m : session.at("messages")) {
        if (m.is_object()) out.push_back(ChatMsg{m.value("role", std::string()),
                                                 m.value("content", std::string())});
    }
    return out;
}

}  // namespace p8
