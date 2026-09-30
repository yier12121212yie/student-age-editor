// native/tui/p8_api.cpp
#include "p8_api.h"

#include <algorithm>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <string>
#include <vector>

#include "p8_cfg.h"
#include "sa_core/http_client.h"
#include "sa_core/paths.h"

namespace p8 {

using sa_core::http::Request;
using sa_core::http::Response;

namespace {
// 安全批次 B：后端进程令牌（.backend_token 与 backend 可执行文件同目录；
// 发行包/构建产物里 TUI 与 backend 同目录，兜底 cwd）。空串 = 未找到（旧包
// 后端未启用令牌）。仅对 loopback base 注入。
std::string read_backend_token() {
    std::vector<std::string> dirs;
    std::error_code ec;
    dirs.push_back(sa_core::paths::exe_dir());
    dirs.push_back(sa_core::paths::path_to_utf8(std::filesystem::current_path(ec)));
    for (const auto& dir : dirs) {
        if (dir.empty()) continue;
        std::ifstream f(sa_core::paths::to_path(dir) / ".backend_token",
                        std::ios::binary);
        if (!f) continue;
        std::string t((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
        while (!t.empty() && (t.back() == '\n' || t.back() == '\r' || t.back() == ' ' ||
                              t.back() == '\t'))
            t.pop_back();
        if (!t.empty()) return t;
    }
    return {};
}

bool is_loopback_base(const std::string& base) {
    return base.rfind("http://127.0.0.1", 0) == 0 || base.rfind("http://localhost", 0) == 0 ||
           base.rfind("http://[::1]", 0) == 0;
}
}  // namespace

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

std::vector<PluginEntry> BackendApi::ParsePlugins(const Json& body) {
    std::vector<PluginEntry> out;
    if (!body.is_object() || !body.contains("plugins") || !body.at("plugins").is_array()) return out;
    auto field = [](const Json& p, const char* k) -> std::string {
        if (!p.is_object() || !p.contains(k) || !p.at(k).is_string()) return std::string();
        return p.at(k).get<std::string>();
    };
    for (const auto& p : body.at("plugins")) {
        PluginEntry e;
        e.id = field(p, "id");
        e.name = field(p, "name");
        e.version = field(p, "version");
        e.author = field(p, "author");
        e.description = field(p, "description");
        e.error = field(p, "error");
        e.loaded = p.is_object() && p.value("loaded", false);
        out.push_back(std::move(e));
    }
    return out;
}

std::vector<CloudProvider> BackendApi::ParseProviders(const Json& body) {
    std::vector<CloudProvider> out;
    if (!body.is_object() || !body.contains("providers") || !body.at("providers").is_array())
        return out;
    auto field = [](const Json& p, const char* k) -> std::string {
        if (!p.is_object() || !p.contains(k) || !p.at(k).is_string()) return std::string();
        return p.at(k).get<std::string>();
    };
    for (const auto& p : body.at("providers")) {
        CloudProvider c;
        c.id = field(p, "id");
        c.name = field(p, "name");
        c.type = field(p, "type");
        c.remote_root = field(p, "remote_root");
        out.push_back(std::move(c));
    }
    return out;
}

std::vector<CloudFile> BackendApi::ParseLocalFiles(const Json& body) {
    std::vector<CloudFile> out;
    if (!body.is_object() || !body.contains("entries") || !body.at("entries").is_array())
        return out;
    for (const auto& e : body.at("entries")) {
        CloudFile f;
        if (e.is_object() && e.contains("name") && e.at("name").is_string())
            f.name = e.at("name").get<std::string>();
        if (e.is_object() && e.contains("size") && e.at("size").is_number())
            f.size = e.at("size").get<long long>();
        out.push_back(std::move(f));
    }
    return out;
}

std::vector<CloudFile> BackendApi::ParseRemoteObjects(const Json& body) {
    std::vector<CloudFile> out;
    if (!body.is_object() || !body.contains("objects") || !body.at("objects").is_array())
        return out;
    for (const auto& o : body.at("objects")) {
        CloudFile f;
        // `path` is the provider-relative path; `name` is the leaf. The dual
        // panel compares against the local side, so prefer `path`.
        if (o.is_object()) {
            if (o.contains("path") && o.at("path").is_string())
                f.name = o.at("path").get<std::string>();
            else if (o.contains("name") && o.at("name").is_string())
                f.name = o.at("name").get<std::string>();
            f.is_dir = o.value("is_dir", false);
            if (o.contains("size") && o.at("size").is_number())
                f.size = o.at("size").get<long long>();
        }
        out.push_back(std::move(f));
    }
    return out;
}

CloudSyncSummary BackendApi::InterpretSync(const Json& body) {
    CloudSyncSummary s;
    if (!body.is_object()) return s;
    s.dry_run = body.value("dry_run", false);
    if (body.contains("direction") && body.at("direction").is_string())
        s.direction = body.at("direction").get<std::string>();
    if (body.contains("total") && body.at("total").is_number())
        s.total = body.at("total").get<long long>();
    if (body.contains("message") && body.at("message").is_string())
        s.message = body.at("message").get<std::string>();
    if (body.contains("error") && body.at("error").is_string() && s.message.empty())
        s.message = body.at("error").get<std::string>();
    if (body.contains("results") && body.at("results").is_array()) {
        for (const auto& r : body.at("results")) {
            const std::string action = r.is_object() && r.contains("action") &&
                                               r.at("action").is_string()
                                           ? r.at("action").get<std::string>()
                                           : std::string();
            const bool ok = r.is_object() && r.value("ok", false);
            if (!ok) {
                ++s.failed;
            } else if (action.rfind("download", 0) == 0) {
                ++s.downloaded;
            } else if (action.rfind("upload", 0) == 0) {
                ++s.uploaded;
            } else {
                ++s.skipped;
            }
        }
        if (s.total == 0) s.total = static_cast<long long>(body.at("results").size());
    } else {
        // Single-file shape: no results[] — one action, at most.
        const std::string action =
            body.contains("action") && body.at("action").is_string()
                ? body.at("action").get<std::string>()
                : std::string();
        s.total = 1;
        if (action.rfind("download", 0) == 0) ++s.downloaded;
        else if (action.rfind("upload", 0) == 0) ++s.uploaded;
        else ++s.skipped;
    }
    return s;
}

std::string BackendApi::ParsePermissionMode(const Json& body) {
    if (!body.is_object()) return "confirm";
    const Json* s = body.contains("settings") && body.at("settings").is_object()
                        ? &body.at("settings")
                        : &body;
    if (s->contains("permissionMode") && s->at("permissionMode").is_string()) {
        const std::string m = s->at("permissionMode").get<std::string>();
        if (m == "confirm" || m == "full") return m;
    }
    return "confirm";  // the backend's own default
}

bool BackendApi::ParseNoCodeMode(const Json& body) {
    if (!body.is_object()) return false;
    const Json* s = body.contains("settings") && body.at("settings").is_object()
                        ? &body.at("settings")
                        : &body;
    return s->contains("noCodeMode") && s->at("noCodeMode").is_boolean() &&
           s->at("noCodeMode").get<bool>();
}

std::vector<FieldSuggestion> BackendApi::ParseSuggestions(const Json& body) {
    std::vector<FieldSuggestion> out;
    if (!body.is_object() || !body.contains("items") || !body.at("items").is_array())
        return out;
    auto str = [](const Json& o, const char* key) {
        return o.contains(key) && o.at(key).is_string() ? o.at(key).get<std::string>()
                                                        : std::string();
    };
    for (const Json& e : body.at("items")) {
        if (!e.is_object()) continue;
        FieldSuggestion f;
        f.code = str(e, "code");
        f.desc = str(e, "desc");
        f.template_ = e.contains("raw_code") && !str(e, "raw_code").empty()
                          ? str(e, "raw_code")
                          : f.code;
        if (e.contains("slots") && e.at("slots").is_array()) {
            for (const Json& sl : e.at("slots")) {
                if (!sl.is_object()) continue;
                SuggestionSlot s;
                s.kind = sl.contains("kind") && sl.at("kind").is_string()
                             ? sl.at("kind").get<std::string>()
                             : std::string("number");
                s.name = str(sl, "name");
                s.dict = str(sl, "dict");
                s.label = str(sl, "label");
                if (sl.contains("count") && sl.at("count").is_number())
                    s.count = sl.at("count").get<int>();
                if (!s.name.empty()) f.slots.push_back(std::move(s));
            }
        }
        // Old backends ship no slots field — parse the template as fallback.
        if (f.slots.empty() && f.template_.find('@') != std::string::npos)
            f.slots = ParseCodeSlots(f.template_);
        if (!f.code.empty()) out.push_back(std::move(f));
    }
    return out;
}

std::vector<FieldSuggestion> BackendApi::ParseRoles(const Json& body) {
    std::vector<FieldSuggestion> out;
    if (!body.is_object() || !body.contains("roles") || !body.at("roles").is_array())
        return out;
    for (const Json& e : body.at("roles")) {
        if (!e.is_object()) continue;
        std::string id;
        if (e.contains("id")) {
            const Json& jid = e.at("id");
            if (jid.is_string()) id = jid.get<std::string>();
            else if (jid.is_number_integer()) id = std::to_string(jid.get<long long>());
            else if (jid.is_number()) id = std::to_string(jid.get<double>());
        }
        if (id.empty()) continue;
        FieldSuggestion f;
        f.code = id;
        f.template_ = id;
        const std::string name =
            e.contains("name") && e.at("name").is_string() ? e.at("name").get<std::string>() : "";
        f.desc = name.empty() ? ("角色 " + id) : name;
        out.push_back(std::move(f));
    }
    return out;
}

UpdateResult BackendApi::ParseUpdate(const Json& body) {
    UpdateResult r;
    if (!body.is_object()) {
        r.error = "官方版本信息格式异常";
        return r;
    }
    r.ok = body.value("ok", false);
    // current 在成功/失败两种形态里都有，先取出来（失败时弹窗也显示当前版本）。
    r.current = body.value("current", std::string());
    if (!r.ok) {
        r.error = body.value("error", std::string("检查更新失败"));
        return r;
    }
    r.latest_tag = body.value("latest_tag", std::string());
    r.latest_name = body.value("latest_name", std::string());
    r.published_at = body.value("published_at", std::string());
    r.html_url = body.value("html_url", std::string());
    r.notes = body.value("notes", std::string());
    r.update_available = body.value("update_available", false);
    r.prerelease = body.value("prerelease", false);
    if (body.contains("assets") && body.at("assets").is_array()) {
        for (const Json& a : body.at("assets")) {
            if (!a.is_object()) continue;
            UpdateAsset asset;
            asset.name = a.value("name", std::string());
            asset.url = a.value("url", std::string());
            if (a.contains("size") && a.at("size").is_number())
                asset.size = a.at("size").get<long long>();
            r.assets.push_back(std::move(asset));
        }
    }
    return r;
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
    // 安全批次 B：连桌面后端（loopback）时携带进程令牌；loopback 必须跳过系统
    // 代理会话，否则默认 WinHTTP 会话会把 127.0.0.1 交给企业代理吞掉，探测对
    // 活着的后端报 12029（bug #8）。
    if (is_loopback_base(base_)) {
        req.bypass_proxy = true;
        static const std::string kBackendToken = read_backend_token();
        if (!kBackendToken.empty())
            req.headers.emplace_back("X-Backend-Token", kBackendToken);
    }
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

bool BackendApi::CreateMod(const std::string& title, std::string* name_out, std::string* err) {
    Json body = Json::object();
    body["title"] = title;
    body["desc"] = "";
    int status = 0;
    Json resp = Call("POST", "/api/mods/create", &body, &status, err);
    if (!err->empty()) return false;
    if (status != 200) {
        *err = "创建模组失败: " + resp.value("error", std::string("HTTP " + std::to_string(status)));
        return false;
    }
    if (name_out) {
        const Json mod = resp.contains("mod") && resp.at("mod").is_object() ? resp.at("mod")
                                                                           : Json::object();
        *name_out = mod.value("name", resp.value("name", title));
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

std::vector<PluginEntry> BackendApi::ListPlugins(std::string* err) {
    if (err) err->clear();
    int status = 0;
    Json body = Call("GET", "/api/plugins", nullptr, &status, err);
    if (!err->empty()) return {};
    if (status != 200) {
        *err = "读取插件失败: " + body.value("error", std::string("HTTP " + std::to_string(status)));
        return {};
    }
    return ParsePlugins(body);
}

bool BackendApi::InstallPlugin(const std::string& zip_path, std::string* id_out,
                               std::string* err) {
    if (err) err->clear();
    Json req = Json::object();
    req["path"] = zip_path;
    // The backend defaults filename to basename(path) when it is absent, which
    // is exactly the desktop behaviour (no temp copy needed for a local path).
    int status = 0;
    Json body = Call("POST", "/api/plugins/install_path", &req, &status, err);
    if (!err->empty()) return false;
    if (status != 200) {
        *err = body.value("error", std::string("安装失败 (HTTP " + std::to_string(status) + ")"));
        return false;
    }
    if (id_out && body.contains("id") && body.at("id").is_string())
        *id_out = body.at("id").get<std::string>();
    return true;
}

bool BackendApi::UninstallPlugin(const std::string& id, std::string* err) {
    if (err) err->clear();
    int status = 0;
    Json body = Call("DELETE", "/api/plugins/" + sa_core::http::quote_component(id), nullptr,
                     &status, err);
    if (!err->empty()) return false;
    if (status != 200) {
        *err = body.value("error", std::string("卸载失败 (HTTP " + std::to_string(status) + ")"));
        return false;
    }
    return true;
}

bool BackendApi::ReloadPlugins(std::vector<PluginEntry>* out, std::string* err) {
    if (err) err->clear();
    Json empty = Json::object();
    int status = 0;
    Json body = Call("POST", "/api/plugins/reload", &empty, &status, err);
    if (!err->empty()) return false;
    if (status != 200) {
        *err = body.value("error", std::string("重载失败 (HTTP " + std::to_string(status) + ")"));
        return false;
    }
    if (out) *out = ParsePlugins(body);
    return true;
}

std::vector<CloudProvider> BackendApi::ListCloudProviders(std::string* err) {
    if (err) err->clear();
    int status = 0;
    Json body = Call("GET", "/api/cloud/providers", nullptr, &status, err);
    if (!err->empty()) return {};
    if (status != 200) {
        *err = "读取 Provider 失败: " +
               body.value("error", std::string("HTTP " + std::to_string(status)));
        return {};
    }
    return ParseProviders(body);
}

std::vector<CloudFile> BackendApi::CloudLocalFiles(const std::string& mod, std::string* err) {
    if (err) err->clear();
    std::string path = "/api/cloud/local_files";
    if (!mod.empty()) path += "?mod_name=" + sa_core::http::quote_component(mod);
    int status = 0;
    Json body = Call("GET", path, nullptr, &status, err);
    if (!err->empty()) return {};
    if (status != 200) {
        *err = body.value("error", std::string("本地列表失败 (HTTP " + std::to_string(status) + ")"));
        return {};
    }
    return ParseLocalFiles(body);
}

std::vector<CloudFile> BackendApi::CloudRemoteFiles(const std::string& provider_id,
                                                    const std::string& mod, std::string* err) {
    if (err) err->clear();
    std::string path = "/api/cloud/list?provider_id=" +
                       sa_core::http::quote_component(provider_id);
    if (!mod.empty()) path += "&mod_name=" + sa_core::http::quote_component(mod);
    int status = 0;
    Json body = Call("GET", path, nullptr, &status, err);
    if (!err->empty()) return {};
    if (status != 200) {
        *err = body.value("error", std::string("远端列表失败 (HTTP " + std::to_string(status) + ")"));
        return {};
    }
    return ParseRemoteObjects(body);
}

bool BackendApi::CloudTest(const std::string& provider_id, std::string* err) {
    if (err) err->clear();
    Json req = Json::object();
    req["provider_id"] = provider_id;
    int status = 0;
    Json body = Call("POST", "/api/cloud/test", &req, &status, err);
    if (!err->empty()) return false;
    if (status != 200) {
        *err = body.value("error", std::string("连接测试失败 (HTTP " + std::to_string(status) + ")"));
        return false;
    }
    return true;
}

CloudSyncSummary BackendApi::CloudSync(const std::string& provider_id,
                                       const std::string& direction, const std::string& mod,
                                       bool dry_run, bool delete_extra, bool full,
                                       std::string* err) {
    CloudSyncSummary s;
    s.dry_run = dry_run;
    s.direction = direction;
    if (err) err->clear();
    Json req = Json::object();
    req["provider_id"] = provider_id;
    req["direction"] = direction;
    if (!mod.empty()) req["mod_name"] = mod;
    if (full) req["folder"] = true;
    if (dry_run) req["dry_run"] = true;
    if (delete_extra) req["delete_extra"] = true;
    int status = 0;
    Json body = Call("POST", "/api/cloud/sync", &req, &status, err);
    if (!err->empty()) {
        s.message = *err;
        return s;
    }
    if (status != 200) {
        s.message = body.value("error", std::string("同步失败 (HTTP " + std::to_string(status) + ")"));
        *err = s.message;
        return s;
    }
    return InterpretSync(body);
}

UpdateResult BackendApi::CheckUpdate(const std::string& current, std::string* err) {
    UpdateResult r;
    if (err) err->clear();
    // timeout 交给后端的 GitHub 请求（默认 6 秒是同一口径）；current 非空时
    // 显式带上，空则由后端用它自己编译进去的版本号兜底。
    std::string path = "/api/update/check?timeout=6";
    if (!current.empty()) path += "&current=" + sa_core::http::quote_component(current);
    int status = 0;
    Json body = Call("GET", path, nullptr, &status, err);
    if (!err->empty()) {
        r.error = *err;
        return r;
    }
    if (status != 200) {
        r.error = body.value("error",
                             std::string("检查更新失败 (HTTP " + std::to_string(status) + ")"));
        *err = r.error;
        return r;
    }
    r = ParseUpdate(body);
    // 该路由失败也回 200 + {ok:false}：把 ok 翻成 *err，调用方两种口径都能用。
    if (!r.ok) *err = r.error;
    return r;
}

std::string BackendApi::LoadPermissionMode(std::string* err) {
    if (err) err->clear();
    int status = 0;
    Json body = Call("GET", "/api/ai/settings", nullptr, &status, err);
    // A missing/failing settings route must not block the UI: "confirm" is the
    // backend's own default and the safe choice.
    if (!err->empty() || status != 200) {
        if (err && err->empty()) *err = "读取 AI 设置失败";
        return "confirm";
    }
    return ParsePermissionMode(body);
}

bool BackendApi::SavePermissionMode(const std::string& mode, std::string* err) {
    if (err) err->clear();
    Json req = Json::object();
    req["permissionMode"] = mode;
    int status = 0;
    Json body = Call("PUT", "/api/ai/settings", &req, &status, err);
    if (!err->empty()) return false;
    if (status != 200) {
        *err = body.value("error", std::string("保存权限模式失败 (HTTP " + std::to_string(status) + ")"));
        return false;
    }
    return true;
}

bool BackendApi::LoadNoCodeMode(std::string* err) {
    if (err) err->clear();
    int status = 0;
    Json body = Call("GET", "/api/settings/editor", nullptr, &status, err);
    // An old backend without the route must not block the TUI: off is the safe
    // default and matches every pre-M0 build.
    if (!err->empty() || status != 200 || !body.is_object()) return false;
    return ParseNoCodeMode(body);
}

bool BackendApi::SaveNoCodeMode(bool on, std::string* err) {
    if (err) err->clear();
    Json req = Json::object();
    req["noCodeMode"] = on;
    int status = 0;
    Json body = Call("PUT", "/api/settings/editor", &req, &status, err);
    if (!err->empty()) return false;
    if (status != 200) {
        *err = body.value("error",
                          std::string("保存无代码模式失败 (HTTP " + std::to_string(status) + ")"));
        return false;
    }
    return true;
}

std::vector<FieldSuggestion> BackendApi::EffectSuggest(const std::string& mode,
                                                       const std::string& q,
                                                       std::string* err) {
    if (err) err->clear();
    int status = 0;
    const std::string path = "/api/effect_suggest?mode=" + sa_core::http::quote_component(mode) +
                             "&q=" + sa_core::http::quote_component(q);
    Json body = Call("GET", path, nullptr, &status, err);
    if (!err->empty() || status != 200) {
        if (err && err->empty())
            *err = "获取候选失败 (HTTP " + std::to_string(status) + ")";
        return {};
    }
    return ParseSuggestions(body);
}

std::vector<FieldSuggestion> BackendApi::RoleSuggest(const std::string& q, std::string* err) {
    if (err) err->clear();
    int status = 0;
    Json body = Call("GET", "/api/roles?q=" + sa_core::http::quote_component(q), nullptr, &status,
                     err);
    if (!err->empty() || status != 200) {
        if (err && err->empty()) *err = "获取人物目录失败 (HTTP " + std::to_string(status) + ")";
        return {};
    }
    return ParseRoles(body);
}

std::vector<std::pair<std::string, std::string>> BackendApi::DictEntries(
    const std::string& dict_key, std::string* err) {
    std::vector<std::pair<std::string, std::string>> out;
    if (err) err->clear();
    if (dict_key.empty()) return out;
    int status = 0;
    Json body = Call("GET", "/api/dicts", nullptr, &status, err);
    if (!err->empty() || status != 200 || !body.is_object()) {
        if (err && err->empty()) *err = "读取字典失败 (HTTP " + std::to_string(status) + ")";
        return out;
    }
    if (!body.contains("game_dicts") || !body.at("game_dicts").is_object()) return out;
    const Json& gd = body.at("game_dicts");
    if (!gd.contains(dict_key) || !gd.at(dict_key).is_object()) return out;
    for (auto it = gd.at(dict_key).begin(); it != gd.at(dict_key).end(); ++it) {
        std::string name;
        const Json& v = it.value();
        if (v.is_string()) name = v.get<std::string>();
        else if (v.is_array() && !v.empty() && v.front().is_string())
            name = v.front().get<std::string>();
        else if (!v.is_null()) name = v.dump();
        out.emplace_back(it.key(), std::move(name));
    }
    // Stable nav order like the GUI's option list: numeric ids ascending.
    std::sort(out.begin(), out.end(),
              [](const std::pair<std::string, std::string>& a,
                 const std::pair<std::string, std::string>& b) {
                  const long long na = atoll(a.first.c_str());
                  const long long nb = atoll(b.first.c_str());
                  if (na == nb) return a.first < b.first;
                  return na < nb;
              });
    return out;
}

void BackendApi::ReportUsage(const std::string& kind, const std::string& key) {
    // Fire-and-forget: a failed report must never surface in the editor flow.
    Json req = Json::object();
    req["kind"] = kind;
    req["key"] = key;
    int status = 0;
    std::string err;
    Call("POST", "/api/usage", &req, &status, &err);
}

void BackendApi::Shutdown() {
    // 服务端先响应再退出（httpd 的 shutdown 语义），响应/连接异常都无所谓。
    Json empty = Json::object();
    int status = 0;
    std::string err;
    Call("POST", "/api/shutdown", &empty, &status, &err);
}

}  // namespace p8
