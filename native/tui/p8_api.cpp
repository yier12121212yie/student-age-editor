// native/tui/p8_api.cpp
#include "p8_api.h"

#include "p8_cfg.h"
#include "sa_core/http_client.h"

namespace p8 {

using sa_core::http::Request;
using sa_core::http::Response;

std::string BackendApi::JoinUrl(const std::string& base, const std::string& path) {
    std::string b = base;
    while (!b.empty() && b.back() == '/') b.pop_back();
    return b + path;
}

std::vector<ModEntry> BackendApi::ParseMods(const Json& body) {
    std::vector<ModEntry> out;
    if (!body.is_object() || !body.contains("mods") || !body.at("mods").is_array()) return out;
    for (const auto& m : body.at("mods")) {
        if (!m.is_object()) continue;
        out.push_back(ModEntry{m.value("name", std::string()), m.value("root", std::string())});
    }
    return out;
}

std::vector<std::string> BackendApi::ParseTables(const Json& body) {
    std::vector<std::string> out;
    if (!body.is_object() || !body.contains("cfg_files") || !body.at("cfg_files").is_array())
        return out;
    for (const auto& f : body.at("cfg_files"))
        if (f.is_string()) out.push_back(f.get<std::string>());
    return out;
}

void BackendApi::ParseTable(const Json& body, std::vector<TableRow>& rows, long long& mtime_ns,
                            bool& exists) {
    rows.clear();
    mtime_ns = 0;
    exists = body.is_object() && body.value("exists", false);
    if (body.is_object() && body.contains("mtime_ns") && body.at("mtime_ns").is_number())
        mtime_ns = body.at("mtime_ns").get<long long>();
    if (body.is_object() && body.contains("data") && body.at("data").is_object())
        rows = RowsFromData(body.at("data"));
}

std::vector<BugEntry> BackendApi::ParseBugs(const Json& body) {
    std::vector<BugEntry> out;
    if (!body.is_object() || !body.contains("bugs") || !body.at("bugs").is_array()) return out;
    auto field = [](const Json& b, const char* k) -> std::string {
        if (!b.is_object() || !b.contains(k) || b.at(k).is_null()) return std::string();
        return b.at(k).is_string() ? b.at(k).get<std::string>() : b.at(k).dump();
    };
    for (const auto& b : body.at("bugs"))
        out.push_back(BugEntry{field(b, "cfg"), field(b, "id"), field(b, "key"), field(b, "flag"),
                               field(b, "desc")});
    return out;
}

std::vector<SearchHit> BackendApi::ParseSearch(const Json& body) {
    std::vector<SearchHit> out;
    if (!body.is_object() || !body.contains("results") || !body.at("results").is_array())
        return out;
    auto str_field = [](const Json& b, const char* k) -> std::string {
        if (!b.is_object() || !b.contains(k) || b.at(k).is_null()) return std::string();
        return b.at(k).is_string() ? b.at(k).get<std::string>() : b.at(k).dump();
    };
    for (const auto& r : body.at("results"))
        out.push_back(SearchHit{str_field(r, "src"), str_field(r, "evt_id"),
                                str_field(r, "evt_title"), str_field(r, "talk_id"),
                                str_field(r, "content")});
    return out;
}

void BackendApi::ParseValidate(const Json& body, ValidateResult& out) {
    out = ValidateResult{};
    if (!body.is_object()) return;
    out.ok = body.value("ok", true);
    if (body.contains("issues") && body.at("issues").is_array()) {
        auto str_field = [](const Json& b, const char* k) -> std::string {
            if (!b.is_object() || !b.contains(k) || b.at(k).is_null()) return std::string();
            return b.at(k).is_string() ? b.at(k).get<std::string>() : b.at(k).dump();
        };
        for (const auto& it : body.at("issues"))
            out.issues.push_back(Issue{str_field(it, "level"), str_field(it, "rid"),
                                       str_field(it, "msg")});
    }
    if (body.contains("counts") && body.at("counts").is_object()) {
        const Json& c = body.at("counts");
        auto num = [&](const char* k) -> long long {
            return c.contains(k) && c.at(k).is_number() ? c.at(k).get<long long>() : 0;
        };
        out.errors = num("error");
        out.warns = num("warn");
        out.infos = num("info");
    }
}

SaveResult BackendApi::InterpretSave(int http_status, const Json& body) {
    SaveResult r;
    std::string code =
        body.is_object() && body.contains("error") && body.at("error").is_string()
            ? body.at("error").get<std::string>()
            : std::string();
    if (http_status == 200 && (!body.is_object() || body.value("ok", false))) {
        r.kind = SaveResult::Kind::Ok;
        if (body.is_object() && body.contains("mtime_ns") && body.at("mtime_ns").is_number())
            r.mtime_ns = body.at("mtime_ns").get<long long>();
        r.message = "已保存";
        return r;
    }
    if (http_status == 409 && code == "non-utf8-source") {
        r.kind = SaveResult::Kind::LossySource;
        r.message = "源文件非 UTF-8，需 force";
        return r;
    }
    if (http_status == 409 && code == "conflict") {
        bool rows = body.is_object() && body.contains("reason") &&
                    body.at("reason").is_string() &&
                    body.at("reason").get<std::string>() == "rows";
        r.kind = rows ? SaveResult::Kind::ConflictRows : SaveResult::Kind::ConflictTable;
        if (body.is_object() && body.contains("data")) r.data = body.at("data");
        r.message = rows ? "行级冲突（他人已改该条）" : "表级冲突（文件已变化），Ctrl-S 重试强制覆盖";
        return r;
    }
    r.kind = SaveResult::Kind::Error;
    r.message = code.empty() ? ("保存失败 (HTTP " + std::to_string(http_status) + ")") : code;
    return r;
}

Json BackendApi::Call(const std::string& method, const std::string& path, const Json* body,
                      int* status, std::string* err) {
    Request req;
    req.method = method;
    req.url = JoinUrl(base_, path);
    req.headers.emplace_back("Content-Type", "application/json");
    req.timeout_seconds = 30.0;
    if (body) req.body = body->dump();
    Response resp = sa_core::http::request(req);
    if (status) *status = resp.status;
    if (!resp.transport_ok()) {
        if (err) *err = resp.error_message.empty() ? "连接失败" : resp.error_message;
        return Json();
    }
    Json parsed = Json::parse(resp.body, nullptr, /*allow_exceptions=*/false);
    if (parsed.is_discarded()) parsed = Json::object();
    return parsed;
}

bool BackendApi::Ping(std::string* err) {
    int status = 0;
    Json body = Call("GET", "/api/ping", nullptr, &status, err);
    if (!err->empty()) return false;
    return status == 200 && body.value("ok", false);
}

std::vector<ModEntry> BackendApi::ListMods(std::string* err) {
    int status = 0;
    Json body = Call("GET", "/api/mods", nullptr, &status, err);
    if (!err->empty()) return {};
    return ParseMods(body);
}

bool BackendApi::SelectMod(const std::string& name, std::string* err) {
    Json body = Json::object();
    body["name"] = name;
    int status = 0;
    Json resp = Call("POST", "/api/mods/select", &body, &status, err);
    if (!err->empty()) return false;
    if (status != 200) {
        *err = "选择模组失败: " + resp.value("error", std::string("HTTP " + std::to_string(status)));
        return false;
    }
    return true;
}

std::vector<std::string> BackendApi::ListTables(std::string* err) {
    int status = 0;
    Json body = Call("GET", "/api/cfg", nullptr, &status, err);
    if (!err->empty()) return {};
    return ParseTables(body);
}

bool BackendApi::LoadTable(const std::string& name, Table& out, std::string* err) {
    int status = 0;
    Json body = Call("GET", "/api/cfg/" + name + "?keys=1", nullptr, &status, err);
    if (!err->empty()) return false;
    if (status != 200) {
        *err = "读取失败: " + body.value("error", std::string("HTTP " + std::to_string(status)));
        return false;
    }
    out.name = name;
    ParseTable(body, out.rows, out.mtime_ns, out.exists);
    out.edits.clear();
    out.removes.clear();
    out.adds.clear();
    return true;
}

SaveResult BackendApi::SaveTable(const std::string& name, const Json& body, std::string* err) {
    int status = 0;
    Json resp = Call("PUT", "/api/cfg/" + name, &body, &status, err);
    if (!err->empty()) {
        SaveResult r;
        r.kind = SaveResult::Kind::Error;
        r.message = *err;
        return r;
    }
    return InterpretSave(status, resp);
}

std::vector<BugEntry> BackendApi::ScanBugs(std::string* err) {
    Json empty = Json::object();
    int status = 0;
    Json body = Call("POST", "/api/bugfix/scan", &empty, &status, err);
    if (!err->empty()) return {};
    if (status != 200) {
        *err = "扫描失败: " + body.value("error", std::string("HTTP " + std::to_string(status)));
        return {};
    }
    return ParseBugs(body);
}

bool BackendApi::FixAllBugs(long long* fixed, std::string* err) {
    Json empty = Json::object();
    int status = 0;
    Json body = Call("POST", "/api/bugfix/fix", &empty, &status, err);
    if (!err->empty()) return false;
    if (status != 200) {
        *err = "修复失败: " + body.value("error", std::string("HTTP " + std::to_string(status)));
        return false;
    }
    if (fixed && body.is_object() && body.contains("fixed") && body.at("fixed").is_number())
        *fixed = body.at("fixed").get<long long>();
    return true;
}

std::vector<SearchHit> BackendApi::SearchTalk(const std::string& q, std::string* err) {
    if (err) err->clear();
    int status = 0;
    // Percent-encode the keyword (Chinese input must survive the query line).
    Json body = Call("GET", "/api/search/talk?q=" + sa_core::http::quote_component(q) +
                                "&limit=30",
                     nullptr, &status, err);
    if (!err->empty()) return {};
    if (status != 200) {
        if (err)
            *err = "搜索失败: " + body.value("error", std::string("HTTP " + std::to_string(status)));
        return {};
    }
    return ParseSearch(body);
}

bool BackendApi::ValidateTable(const std::string& cfg, const Json& data, ValidateResult* out,
                               std::string* err) {
    if (err) err->clear();
    Json body = Json::object();
    body["cfg"] = cfg;
    body["data"] = data;
    int status = 0;
    Json resp = Call("POST", "/api/validate", &body, &status, err);
    if (!err->empty()) return false;
    if (status != 200) {
        if (err)
            *err = "校验失败: " + resp.value("error", std::string("HTTP " + std::to_string(status)));
        return false;
    }
    if (out) ParseValidate(resp, *out);
    return true;
}

void BackendApi::Shutdown() {
    // 服务端先响应再退出（httpd 的 shutdown 语义），响应/连接异常都无所谓。
    Json empty = Json::object();
    int status = 0;
    std::string err;
    Call("POST", "/api/shutdown", &empty, &status, &err);
}

}  // namespace p8
