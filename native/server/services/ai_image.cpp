// wip/P4/ai_image.cpp — see ai_image.h. Port of ai_image_service.py +
// core/update_check.py + their /api/ai/image/* routes (api.py:1757-1791).
#include "ai_image.h"

#include <algorithm>
#include <cctype>
#include <cstdlib>
#include <regex>
#include <set>
#include <sstream>
#include <string>
#include <vector>

#include "sa_core/http_client.h"
#include "sa_core/json_wire.h"
#include "sa_core/paths.h"
#include "sa_core/strings.h"
#include "sa_core/utf8.h"
#include "sa_core/util.h"
#include "server/httpd.h"
#include "p4_util.h"

namespace sa {
namespace {
namespace http = sa_core::http;

const char* kDefaultBaseUrl = "https://api.openai.com/v1";
const char* kDefaultModel = "gpt-image-2";
constexpr int kImageTimeout = 300;

std::string trunc_chars(const std::string& s, size_t n) {
    size_t seen = 0, i = 0;
    while (i < s.size() && seen < n) {
        unsigned char c = static_cast<unsigned char>(s[i]);
        size_t len = (c >= 0xF0) ? 4 : (c >= 0xE0) ? 3 : (c >= 0xC0) ? 2 : 1;
        if (i + len > s.size()) break;
        i += len;
        ++seen;
    }
    return s.substr(0, i);
}

const std::set<std::string>& dalle_sizes() {
    static const std::set<std::string> k = {"256x256", "512x512", "1024x1024", "1024x1792",
                                            "1792x1024"};
    return k;
}
const std::set<std::string>& quality_set() {
    static const std::set<std::string> k = {"low", "medium", "high", "auto"};
    return k;
}
const std::set<std::string>& style_set() {
    static const std::set<std::string> k = {"vivid", "natural"};
    return k;
}
const std::set<std::string>& background_set() {
    static const std::set<std::string> k = {"transparent", "opaque", "auto"};
    return k;
}

bool is_valid_size(const std::string& model, const std::string& size) {
    if (size.empty() || size == "auto") return true;
    static const std::regex kRe(R"(^(\d{2,5})x(\d{2,5})$)");
    std::smatch m;
    std::string s = p4::strip(size);
    if (!std::regex_match(s, m, kRe)) return false;
    long long w = std::stoll(m[1].str()), h = std::stoll(m[2].str());
    if (sa_core::str::starts_with(model, "gpt-image"))
        return w >= 1 && w <= 8192 && h >= 1 && h <= 8192 && w % 64 == 0 && h % 64 == 0;
    return dalle_sizes().count(s) > 0;
}

std::string j_get_str(const json& o, const std::string& k, const std::string& def = "") {
    if (!o.is_object() || !o.contains(k) || o.at(k).is_null()) return def;
    return o.at(k).is_string() ? o.at(k).get<std::string>() : sa_core::py_str(o.at(k));
}

}  // namespace

// ===========================================================================
// ai_image
// ===========================================================================
namespace ai_image {

std::string normalize_base_url(std::string_view base_url) {
    std::string base = sa_core::str::trim(std::string(base_url));
    while (!base.empty() && base.back() == '/') base.pop_back();
    if (base.empty()) base = kDefaultBaseUrl;
    if (!sa_core::str::starts_with(base, "http://") && !sa_core::str::starts_with(base, "https://"))
        base = "https://" + base;
    return base;
}

namespace {

std::string extract_error(std::string_view raw) {
    std::string text = sa_core::str::trim(sa_core::decode_utf8_sig_replace(raw));
    if (text.empty()) return "empty response from upstream";
    auto obj = json::parse(text, nullptr, false);
    if (!obj.is_discarded() && obj.is_object()) {
        if (obj.contains("error")) {
            const json& err = obj.at("error");
            if (err.is_object() && err.contains("message") && !err.at("message").is_null())
                return sa_core::py_str(err.at("message"));
            if (err.is_string() && !err.get<std::string>().empty()) return err.get<std::string>();
        }
        if (obj.contains("code") && !obj.at("code").is_null() &&
            !(obj.at("code").is_number() && obj.at("code").get<double>() == 0.0)) {
            std::string msg = obj.contains("message") && !obj.at("message").is_null()
                                  ? sa_core::py_str(obj.at("message"))
                                  : "";
            return "[" + sa_core::py_str(obj.at("code")) + "] " + msg;
        }
        if (obj.contains("message") && !obj.at("message").is_null())
            return sa_core::py_str(obj.at("message"));
    }
    return trunc_chars(text, 400);
}

struct RequestResult {
    json obj = nullptr;
    std::string err;
    bool ok() const { return err.empty(); }
};

RequestResult request_bytes(const std::string& url, const std::string& data,
                            std::vector<std::pair<std::string, std::string>> headers,
                            const std::string& method = "POST") {
    RequestResult res;
    http::Request req;
    req.method = method;
    req.url = url;
    req.headers = std::move(headers);
    req.body = data;
    req.timeout_seconds = kImageTimeout;
    http::Response r = http::request(req);
    if (!r.transport_ok()) {
        if (r.error == http::Response::Error::Timeout)
            res.err = "请求图片服务超时（" + std::to_string(kImageTimeout) + " 秒）";
        else if (r.error == http::Response::Error::Connection)
            res.err = "无法连接图片服务：" + r.error_message;
        else
            res.err = "请求图片服务失败：" + r.error_message;
        return res;
    }
    if (r.status >= 400) {
        res.err = "HTTP " + std::to_string(r.status) + ": " + extract_error(r.body);
        return res;
    }
    auto parsed = json::parse(r.body, nullptr, false);
    if (parsed.is_discarded()) {
        res.err = "图片服务返回了非 JSON 内容：" + trunc_chars(r.body, 200);
        return res;
    }
    res.obj = parsed;
    return res;
}

std::pair<std::string, std::string> download_to_b64(const std::string& url,
                                                    const std::string& api_key) {
    http::Request req;
    req.method = "GET";
    req.url = url;
    req.timeout_seconds = 60;
    if (!api_key.empty()) req.headers = {{"Authorization", "Bearer " + api_key}};
    http::Response r = http::request(req);
    if (!r.transport_ok() || r.status >= 400)
        throw ImageGenError("下载生成图片失败：" + (r.transport_ok() ? std::to_string(r.status) : r.error_message));
    std::string ctype = sa_core::str::lower(p4::strip(r.header("Content-Type")));
    auto semi = ctype.find(';');
    if (semi != std::string::npos) ctype = ctype.substr(0, semi);
    std::string mime = sa_core::str::starts_with(ctype, "image/") ? ctype : "image/png";
    return {http::b64_encode(r.body), mime};
}

json resolve_images(const json& data, const std::string& api_key) {
    json out = json::array();
    if (!data.is_array()) return out;
    for (const auto& it : data) {
        if (!it.is_object()) continue;
        std::string b64 = j_get_str(it, "b64_json");
        if (!b64.empty()) {
            out.push_back(json{{"b64", b64}, {"mime", "image/png"}});
            continue;
        }
        std::string url = j_get_str(it, "url");
        if (!url.empty()) {
            auto [enc, mime] = download_to_b64(url, api_key);
            out.push_back(json{{"b64", enc}, {"mime", mime}});
        }
    }
    return out;
}

// _validate_common -> p dict {model,prompt,n,size,quality,style,background}.
json validate_common(const std::string& model_in, const std::string& prompt, const json& n,
                     const std::string& size, const std::string& quality, const std::string& style,
                     const std::string& background) {
    if (p4::strip(prompt).empty()) throw ImageGenError("prompt（图片描述/修改指令）不能为空");
    long long nn = 1;
    if (n.is_null()) {
        nn = 1;
    } else {
        auto iv = p4::json_int(n);
        if (!iv) throw ImageGenError("n（生成数量）必须是整数");
        nn = *iv;
    }
    nn = std::max(1LL, std::min(10LL, nn));
    std::string model = sa_core::str::trim(model_in);
    if (model.empty()) model = kDefaultModel;
    if (!is_valid_size(model, size)) {
        if (sa_core::str::starts_with(model, "gpt-image"))
            throw ImageGenError("不支持的 size：" + size +
                                "（gpt-image 系列支持「宽x高」且宽高为 64 的整数倍、不超过 8192，或 auto）");
        throw ImageGenError("不支持的 size：" + size + "（可选：1024x1024 / 1024x1792 / 1792x1024 / 256x256 / 512x512）");
    }
    if (!quality.empty() && !quality_set().count(quality))
        throw ImageGenError("不支持的 quality：" + quality + "（可选：auto / high / low / medium）");
    if (!style.empty() && !style_set().count(style))
        throw ImageGenError("不支持的 style：" + style + "（可选：natural / vivid）");
    if (!background.empty() && !background_set().count(background))
        throw ImageGenError("不支持的 background：" + background + "（可选：auto / opaque / transparent）");
    json p;
    p["model"] = model;
    p["prompt"] = p4::strip(prompt);
    p["n"] = nn;
    p["size"] = size;
    p["quality"] = quality;
    p["style"] = style;
    p["background"] = background;
    return p;
}

}  // namespace

std::string build_multipart(const std::string& boundary,
                            const std::vector<std::pair<std::string, std::string>>& fields,
                            const std::vector<std::tuple<std::string, std::string, std::string, std::string>>& files,
                            std::string* content_type) {
    std::string b = "--" + boundary;
    std::string out;
    for (const auto& [name, value] : fields) {
        out += b + "\r\n";
        out += "Content-Disposition: form-data; name=\"" + name + "\"\r\n\r\n";
        out += value + "\r\n";
    }
    for (const auto& [name, filename, mime, raw] : files) {
        out += b + "\r\n";
        out += "Content-Disposition: form-data; name=\"" + name + "\"; filename=\"" + filename +
               "\"\r\n";
        out += "Content-Type: " + mime + "\r\n\r\n";
        out += raw + "\r\n";
    }
    out += b + "--\r\n";
    if (content_type) *content_type = "multipart/form-data; boundary=" + boundary;
    return out;
}

json generate_images(const std::string& api_key, const std::string& base_url,
                     const std::string& model, const std::string& prompt, const json& n,
                     const std::string& size, const std::string& quality, const std::string& style,
                     const std::string& background) {
    if (sa_core::str::trim(api_key).empty())
        throw ImageGenError("未配置图片生成 API Key，请先在「设置」中配置");
    json p = validate_common(model, prompt, n, size, quality, style, background);
    std::string base = normalize_base_url(base_url);
    json body;
    body["model"] = p["model"];
    body["prompt"] = p["prompt"];
    body["n"] = p["n"];
    body["response_format"] = "b64_json";
    for (const char* k : {"size", "quality", "style", "background"})
        if (p[k].is_string() && !p[k].get<std::string>().empty()) body[k] = p[k];
    auto res = request_bytes(base + "/images/generations", sa_core::py_dumps(body),
                             {{"Content-Type", "application/json"},
                              {"Authorization", "Bearer " + sa_core::str::trim(api_key)}});
    if (!res.ok()) throw ImageGenError(res.err);
    json images = resolve_images(
        res.obj.contains("data") ? res.obj.at("data") : json(), api_key);
    if (images.empty())
        throw ImageGenError("图片服务未返回任何图片：" + trunc_chars(sa_core::py_dumps(res.obj), 300));
    std::string out_model = p["model"].get<std::string>();
    if (res.obj.contains("model") && !res.obj.at("model").is_null()) out_model = sa_core::py_str(res.obj.at("model"));
    json created = res.obj.contains("created") ? res.obj.at("created") : json();
    return json{{"images", images}, {"model", out_model}, {"created", created}};
}

json edit_image(const std::string& api_key, const std::string& base_url, const std::string& model,
                const std::string& prompt, const std::string& image_b64,
                const std::string& image_mime, const std::string& mask_b64, const json& n,
                const std::string& size) {
    if (sa_core::str::trim(api_key).empty())
        throw ImageGenError("未配置图片生成 API Key，请先在「设置」中配置");
    json p = validate_common(model, prompt, n, size, "", "", "");
    if (image_b64.empty()) throw ImageGenError("image（要修改的图片）不能为空");
    std::string image_bytes;
    if (!http::b64_decode(image_b64, &image_bytes))
        throw ImageGenError("image 不是合法的 base64 图片数据");
    if (image_bytes.empty()) throw ImageGenError("image 内容为空");
    std::string mime = sa_core::str::lower(p4::strip(image_mime));
    if (mime.empty()) mime = "image/png";
    if (!sa_core::str::starts_with(mime, "image/")) mime = "image/png";
    std::string mask_bytes;
    bool have_mask = false;
    if (!mask_b64.empty()) {
        if (!http::b64_decode(mask_b64, &mask_bytes))
            throw ImageGenError("mask 不是合法的 base64 图片数据");
        have_mask = true;
    }
    std::string base = normalize_base_url(base_url);
    std::vector<std::pair<std::string, std::string>> fields = {
        {"model", p["model"].get<std::string>()},
        {"prompt", p["prompt"].get<std::string>()},
        {"n", std::to_string(p["n"].get<long long>())},
    };
    if (p["size"].is_string() && !p["size"].get<std::string>().empty())
        fields.emplace_back("size", p["size"].get<std::string>());
    std::vector<std::tuple<std::string, std::string, std::string, std::string>> files = {
        {"image", "image.png", mime, image_bytes}};
    if (have_mask) files.emplace_back("mask", "mask.png", "image/png", mask_bytes);
    std::string boundary = "----studentage_aiedit_" + p4::random_hex(32);
    std::string ct;
    std::string body = build_multipart(boundary, fields, files, &ct);
    auto res = request_bytes(base + "/images/edits", body,
                             {{"Content-Type", ct}, {"Authorization", "Bearer " + sa_core::str::trim(api_key)}});
    if (!res.ok()) throw ImageGenError(res.err);
    json images = resolve_images(res.obj.contains("data") ? res.obj.at("data") : json(), api_key);
    if (images.empty())
        throw ImageGenError("图片服务未返回任何图片：" + trunc_chars(sa_core::py_dumps(res.obj), 300));
    std::string out_model = p["model"].get<std::string>();
    if (res.obj.contains("model") && !res.obj.at("model").is_null()) out_model = sa_core::py_str(res.obj.at("model"));
    json created = res.obj.contains("created") ? res.obj.at("created") : json();
    return json{{"images", images}, {"model", out_model}, {"created", created}};
}

}  // namespace ai_image

// ===========================================================================
// update_check
// ===========================================================================
namespace update_check {

std::vector<long long> version_key(const std::string& tag) {
    static const std::regex kRe(R"((\d+(?:\.\d+)+))");
    std::smatch m;
    if (!std::regex_search(tag, m, kRe)) return {};
    std::vector<long long> out;
    std::string g = m[1].str();
    size_t pos = 0;
    while (pos <= g.size()) {
        size_t dot = g.find('.', pos);
        std::string part = g.substr(pos, dot == std::string::npos ? std::string::npos : dot - pos);
        out.push_back(std::stoll(part));
        if (dot == std::string::npos) break;
        pos = dot + 1;
    }
    return out;
}

std::string line_prefix(const std::string& tag) {
    static const std::regex kRe(R"(\d+(?:\.\d+)+)");
    std::smatch m;
    if (!std::regex_search(tag, m, kRe)) return tag;
    return tag.substr(0, static_cast<size_t>(m.position(0)));
}

static std::string norm_release(std::string s) {
    s = p4::strip(s);
    if (!s.empty() && (s[0] == 'v' || s[0] == 'V')) s = s.substr(1);
    return sa_core::str::trim(s);
}

bool same_release(const std::string& tag, const std::string& current) {
    if (tag.empty()) return false;
    return sa_core::str::lower(norm_release(tag)) == sa_core::str::lower(norm_release(current));
}

// Python tuple '>' over the numeric version tuples.
static bool tuple_gt(const std::vector<long long>& a, const std::vector<long long>& b) {
    size_t n = std::min(a.size(), b.size());
    for (size_t i = 0; i < n; ++i) {
        if (a[i] != b[i]) return a[i] > b[i];
    }
    return a.size() > b.size();
}

bool should_update(const std::string& latest_tag, const std::string& current) {
    if (p4::strip(latest_tag).empty()) return false;
    auto vl = version_key(latest_tag);
    if (vl.empty()) return false;
    auto vc = version_key(current);
    if (!vc.empty() && line_prefix(latest_tag) == line_prefix(current))
        return tuple_gt(vl, vc);
    return !same_release(latest_tag, current);
}

static json empty_result(const std::string& current) {
    json r;
    r["ok"] = true;
    r["current"] = current;
    r["latest_tag"] = "";
    r["latest_name"] = "";
    r["prerelease"] = false;
    r["published_at"] = "";
    r["html_url"] = "";
    r["notes"] = "";
    r["update_available"] = false;
    r["assets"] = json::array();
    return r;
}

json check_update(int timeout, const std::string& url_override, const std::string& current_in) {
    std::string current = current_in.empty() ? "Alpha-v0.1" : current_in;
    std::string url = url_override;
    if (url.empty()) {
        if (std::string u = sa_core::paths::getenv_utf8("EDITOR_UPDATE_URL"); !u.empty())
            url = u;
    }
    if (url.empty()) {
        std::string repo = sa_core::paths::getenv_utf8("EDITOR_UPDATE_REPO");
        std::string r = !repo.empty() ? repo : "yier12121212yie/student-age-editor";
        url = "https://api.github.com/repos/" + r + "/releases?per_page=5";
    }
    try {
        http::Request req;
        req.method = "GET";
        req.url = url;
        req.timeout_seconds = timeout;
        req.headers = {{"User-Agent", "student-age-editor-update-check"},
                       {"Accept", "application/vnd.github+json"}};
        http::Response r = http::request(req);
        if (!r.transport_ok())
            return json{{"ok", false}, {"error", r.error_message}, {"current", current}};
        if (r.status >= 400)
            return json{{"ok", false}, {"error", "HTTP " + std::to_string(r.status)}, {"current", current}};
        auto releases = json::parse(r.body, nullptr, false);
        if (releases.is_discarded() || !releases.is_array())
            return json{{"ok", false}, {"error", "GitHub 返回了意外的响应格式（非列表）"}, {"current", current}};
        const json* rel = nullptr;
        std::string best_created;
        for (const auto& it : releases) {
            if (!it.is_object()) continue;
            if (it.value("draft", false) == true) continue;
            std::string c = j_get_str(it, "created_at");
            if (!rel || c > best_created) { rel = &it; best_created = c; }
        }
        if (!rel) return empty_result(current);
        std::string latest_tag = j_get_str(*rel, "tag_name");
        json assets = json::array();
        if (rel->contains("assets") && rel->at("assets").is_array()) {
            for (const auto& a : rel->at("assets")) {
                if (!a.is_object()) continue;
                json item;
                item["name"] = j_get_str(a, "name");
                item["url"] = j_get_str(a, "browser_download_url");
                item["size"] = a.contains("size") && a.at("size").is_number() ? a.at("size") : json(0);
                assets.push_back(std::move(item));
            }
        }
        std::string html = j_get_str(*rel, "html_url");
        if (html.empty()) html = j_get_str(*rel, "url");
        json out;
        out["ok"] = true;
        out["current"] = current;
        out["latest_tag"] = latest_tag;
        out["latest_name"] = j_get_str(*rel, "name");
        out["prerelease"] = rel->value("prerelease", false) == true;
        out["published_at"] = j_get_str(*rel, "published_at");
        out["html_url"] = html;
        out["notes"] = j_get_str(*rel, "body");
        out["update_available"] = should_update(latest_tag, current);
        out["assets"] = std::move(assets);
        return out;
    } catch (const std::exception& e) {
        return json{{"ok", false}, {"error", std::string(e.what())}, {"current", current}};
    }
}

}  // namespace update_check

// ===========================================================================
// routes
// ===========================================================================
namespace {
std::string bstr(const json& body, const char* key) { return j_get_str(body, key, ""); }
}  // namespace

void register_ai_image_routes(Router& r) {
    r.post(R"(/api/ai/image/generate)", [](const Req& req) -> Resp {
        const json& body = req.body;
        json n = body.is_object() && body.contains("n") ? body.at("n") : json(1);
        try {
            return Resp::Json(200, ai_image::generate_images(
                bstr(body, "api_key"), bstr(body, "base_url"), bstr(body, "model"),
                bstr(body, "prompt"), n, bstr(body, "size"), bstr(body, "quality"),
                bstr(body, "style"), bstr(body, "background")));
        } catch (const ImageGenError& e) {
            return Resp::Json(400, json{{"error", e.what()}});
        }
    });
    r.post(R"(/api/ai/image/edit)", [](const Req& req) -> Resp {
        const json& body = req.body;
        json n = body.is_object() && body.contains("n") ? body.at("n") : json(1);
        std::string mime = bstr(body, "image_mime");
        if (mime.empty()) mime = "image/png";
        try {
            return Resp::Json(200, ai_image::edit_image(
                bstr(body, "api_key"), bstr(body, "base_url"), bstr(body, "model"),
                bstr(body, "prompt"), bstr(body, "image_base64"), mime, bstr(body, "mask_base64"),
                n, bstr(body, "size")));
        } catch (const ImageGenError& e) {
            return Resp::Json(400, json{{"error", e.what()}});
        }
    });
}

void register_update_routes(Router& r) {
    // GET /api/update/check (additive: the Python backend only exposes this via
    // its CLI/TUI). Optional ?timeout=N, ?url=..., ?current=... for tests.
    r.get(R"(/api/update/check)", [](const Req& req) -> Resp {
        int timeout = 6;
        auto it = req.query.find("timeout");
        if (it != req.query.end()) timeout = static_cast<int>(sa_core::py_int(it->second).value_or(6));
        std::string url, current;
        if (auto u = req.query.find("url"); u != req.query.end()) url = u->second;
        if (auto c = req.query.find("current"); c != req.query.end()) current = c->second;
        return Resp::Json(200, update_check::check_update(timeout, url, current));
    });
}

}  // namespace sa
