// server/services/cloud_sync.cpp — C++ port of backend/editor/server/cloud_sync.py.
// See cloud_sync.h for the section map. Error messages / envelope fields are
// copied verbatim from the Python source (契约无差异；实现层差异见 STATUS.md).
#include "cloud_sync.h"

#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <filesystem>
#include <mutex>
#include <regex>
#include <set>
#include <sstream>

#include "sa_core/atomic_io.h"
#include "sa_core/http_client.h"
#include "sa_core/json_wire.h"
#include "sa_core/paths.h"
#include "sa_core/sha1.h"
#include "sa_core/strings.h"
#include "sa_core/util.h"
#include "server/cfg_store.h"
#include "server/httpd.h"  // ApiError for the AttributeError-flavoured 500s
#include "server/state.h"
#include "p5_util.h"

#include "server/services/p4_util.h"

namespace sa {
namespace cloud {
namespace {

namespace sp = sa_core::str;
namespace spath = sa_core::paths;

// Python type(e).__name__ for a JSON value (used in AttributeError messages).
std::string py_type_of(const json& v) {
    if (v.is_null()) return "NoneType";
    if (v.is_boolean()) return "bool";
    if (v.is_number_integer() || v.is_number_unsigned()) return "int";
    if (v.is_number_float()) return "float";
    if (v.is_string()) return "str";
    if (v.is_array()) return "list";
    return "dict";
}

bool contains(const std::string& hay, const std::string& needle) {
    return hay.find(needle) != std::string::npos;
}

std::string rstrip_slashes(std::string s) {
    while (!s.empty() && s.back() == '/') s.pop_back();
    return s;
}
std::string lstrip_slashes(std::string s) {
    while (!s.empty() && s.front() == '/') s.erase(s.begin());
    return s;
}
std::string strip_slashes(std::string s) {
    return lstrip_slashes(rstrip_slashes(std::move(s)));
}

// ---------------------------------------------------------------------------
// URL helpers (urllib.parse pieces the WebDAV/OpenList drivers need)
// ---------------------------------------------------------------------------

// urllib.parse.urlparse(x).path
std::string url_path(const std::string& u) {
    size_t i = 0;
    size_t scheme_end = u.find("://");
    if (scheme_end != std::string::npos) {  // treat any scheme as netloc-bearing
        i = scheme_end + 3;
        size_t slash = u.find('/', i);
        if (slash == std::string::npos) return "/";
        i = slash;
    }
    std::string rest = u.substr(i);
    size_t q = rest.find_first_of("?#");
    if (q != std::string::npos) rest = rest.substr(0, q);
    return rest;
}

int hexval(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

// urllib.parse.unquote: '%' + 2 hex -> byte; otherwise passthrough.
std::string unquote(const std::string& s) {
    std::string out;
    for (size_t i = 0; i < s.size(); ++i) {
        if (s[i] == '%' && i + 2 < s.size() && hexval(s[i + 1]) >= 0 &&
            hexval(s[i + 2]) >= 0) {
            out += static_cast<char>(hexval(s[i + 1]) * 16 + hexval(s[i + 2]));
            i += 2;
        } else {
            out += s[i];
        }
    }
    return out;
}

// Python bytes repr (raw[:500] goes through "%s" as a bytes object).
std::string bytes_repr(const std::string& raw, size_t maxn) {
    std::string s = raw.size() > maxn ? raw.substr(0, maxn) : raw;
    bool has_sq = s.find('\'') != std::string::npos;
    bool has_dq = s.find('"') != std::string::npos;
    char q = (has_sq && !has_dq) ? '"' : '\'';
    std::string out = "b";
    out += q;
    for (unsigned char c : s) {
        if (c == '\\') out += "\\\\";
        else if (c == '\n') out += "\\n";
        else if (c == '\r') out += "\\r";
        else if (c == '\t') out += "\\t";
        else if (c == static_cast<unsigned char>(q)) { out += '\\'; out += q; }
        else if (c < 0x20 || c >= 0x7f) {
            char buf[8];
            std::snprintf(buf, sizeof(buf), "\\x%02x", c);
            out += buf;
        } else {
            out += static_cast<char>(c);
        }
    }
    out += q;
    return out;
}

// data.decode("utf-8", errors="ignore")
std::string utf8_ignore(const std::string& raw) {
    std::string out;
    size_t i = 0;
    while (i < raw.size()) {
        unsigned char c = static_cast<unsigned char>(raw[i]);
        size_t need = 0;
        if (c < 0x80) need = 1;
        else if ((c & 0xE0) == 0xC0) need = 2;
        else if ((c & 0xF0) == 0xE0) need = 3;
        else if ((c & 0xF8) == 0xF0) need = 4;
        else { ++i; continue; }  // invalid lead byte: drop (errors="ignore")
        bool ok = i + need <= raw.size();
        for (size_t k = 1; ok && k < need; ++k) {
            unsigned char cc = static_cast<unsigned char>(raw[i + k]);
            if ((cc & 0xC0) != 0x80) ok = false;
        }
        if (ok) out.append(raw, i, need);
        i += need;
    }
    return out;
}

// str(e) — Python's exception coercion used by "%s" embeds.
std::string exception_str(const std::exception& e) {
    if (auto* py = dynamic_cast<const PyError*>(&e)) return py->str_msg;
    if (auto* ae = dynamic_cast<const ApiError*>(&e)) {
        std::string w = ae->what();
        std::string pre = ae->type_name + ": ";
        return w.rfind(pre, 0) == 0 ? w.substr(pre.size()) : w;
    }
    return e.what();
}
// f"{type(e).__name__}: {e}" — per-file sync result strings.
std::string exception_repr_full(const std::exception& e) {
    if (auto* py = dynamic_cast<const PyError*>(&e)) return py->what();
    if (auto* ae = dynamic_cast<const ApiError*>(&e)) return ae->what();
    return std::string("RuntimeError: ") + e.what();
}

// ---------------------------------------------------------------------------
// HTTP layer — cloud_sync.py:110-125 _http_request.
// ---------------------------------------------------------------------------

struct HttpResult {
    int status = 0;
    std::string body;
    std::vector<std::pair<std::string, std::string>> headers;
};

HttpResult http_request(const std::string& url, const std::string& method,
                        std::vector<std::pair<std::string, std::string>> headers,
                        const std::string* data, double timeout) {
    // urllib carries headers in a dict: assigning the same key twice means
    // LAST WINS and exactly one header line goes on the wire (at the FIRST
    // insertion position). The vector ports (e.g. OpenListDriver.put:
    // Content-Type json -> octet-stream) would otherwise emit a duplicate and
    // WinHttpSendRequest rejects it (WinHTTP error 183). Collapse case-insensitively.
    {
        std::map<std::string, size_t> seen;  // lower key -> index
        std::vector<std::pair<std::string, std::string>> merged;
        for (auto& kv : headers) {
            std::string lk;
            for (char c : kv.first)
                lk += static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
            auto it = seen.find(lk);
            if (it == seen.end()) {
                seen[lk] = merged.size();
                merged.push_back(kv);
            } else {
                merged[it->second].second = kv.second;  // dict overwrite keeps position
            }
        }
        headers = std::move(merged);
    }
    bool has_ua = false, has_accept = false;
    for (const auto& [k, v] : headers) {
        if (k == "User-Agent" || k == "user-agent") has_ua = true;  // exact dict keys
        if (k == "Accept") has_accept = true;
    }
    if (!has_ua) {
        headers.emplace_back(
            "User-Agent",
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
            "(KHTML, like Gecko) Chrome/120.0 Safari/537.36");
    }
    if (!has_accept) headers.emplace_back("Accept", "application/json, text/plain, */*");

    sa_core::http::Request req;
    req.method = method;
    req.url = url;
    req.headers = std::move(headers);
    if (data) req.body = *data;
    req.timeout_seconds = timeout;
    sa_core::http::Response resp = sa_core::http::request(req);
    // urlopen transport failures re-raise; type/str mirror urllib's shapes.
    switch (resp.error) {
        case sa_core::http::Response::Error::None:
            break;
        case sa_core::http::Response::Error::Timeout:
            raise_typed("timeout", "timed out");
        case sa_core::http::Response::Error::Tls:
            raise_typed("SSLError", resp.error_message);
        case sa_core::http::Response::Error::BadInput:
            raise_typed("ValueError", resp.error_message);
        default:
            raise_typed("URLError", "<urlopen error " + resp.error_message + ">");
    }
    HttpResult out;
    out.status = resp.status;
    out.body = std::move(resp.body);
    out.headers = std::move(resp.headers);
    return out;
}

// ---------------------------------------------------------------------------
// Date/time parsing
// ---------------------------------------------------------------------------

const char* const kMonths[] = {"Jan", "Feb", "Mar", "Apr", "May", "Jun",
                               "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"};
const char* const kWdays[] = {"Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"};

// Howard Hinnant days_from_civil — UTC seconds of a midnight.
long long days_from_civil(int y, unsigned m, unsigned d) {
    y -= m <= 2;
    const int era = (y >= 0 ? y : y - 399) / 400;
    const unsigned yoe = static_cast<unsigned>(y - era * 400);
    const unsigned doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1;
    const unsigned doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    return era * 146097LL + static_cast<long long>(doe) - 719468LL;
}

// email.utils.parsedate_to_datetime for the RFC1123 family ("Sun, 06 Nov 1994
// 08:49:37 GMT", numeric offsets honoured; naive → UTC per the Python caller
// wrapping it with tzinfo=utc).
bool parse_rfc1123(const std::string& in, long long* out) {
    std::string s = p4::strip(in);
    size_t comma = s.find(',');
    if (comma != std::string::npos) {
        std::string wd = p4::strip(s.substr(0, comma));
        for (const char* w : kWdays) {
            if (sp::lower(wd) == sp::lower(std::string(w))) {
                s = p4::strip(s.substr(comma + 1));
                break;
            }
        }
    }
    std::istringstream is(s);
    int day = 0, year = 0, hh = 0, mi = 0, ss = 0;
    char c1 = 0, c2 = 0, c3 = 0, c4 = 0;
    std::string mon;
    if (!(is >> day >> mon >> year >> hh >> c1 >> mi >> c2 >> ss)) return false;
    if (c1 != ':' || c2 != ':') return false;
    int month = 0;
    for (int i = 0; i < 12; ++i) {
        if (sp::lower(mon).rfind(sp::lower(kMonths[i]), 0) == 0) {
            month = i + 1;
            break;
        }
    }
    if (!month) return false;
    int offset = 0;
    std::string tz;
    if (is >> tz) {
        if (tz == "GMT" || tz == "UTC" || tz == "Z" || tz == "UT") {
            offset = 0;
        } else {
            int sign = tz[0] == '-' ? -1 : 1;
            std::string digits = (tz[0] == '+' || tz[0] == '-') ? tz.substr(1) : tz;
            if (digits.size() != 4 ||
                !std::all_of(digits.begin(), digits.end(),
                             [](char c) { return std::isdigit(static_cast<unsigned char>(c)); })) {
                return false;
            }
            offset = sign * (std::stoi(digits.substr(0, 2)) * 3600 +
                             std::stoi(digits.substr(2, 2)) * 60);
        }
    }
    *out = days_from_civil(year, static_cast<unsigned>(month),
                           static_cast<unsigned>(day)) * 86400LL +
             hh * 3600 + mi * 60 + ss - offset;
    return true;
}

// ---------------------------------------------------------------------------
// Small json helpers
// ---------------------------------------------------------------------------

// `config.get(key) or ""` — on a truthy non-dict config (garbage body.config)
// Python's first .get() raises AttributeError('get'); mirror that. Values that
// are themselves non-str but truthy get str()'d (callers then .strip() etc.).
std::string json_str_or(const json& obj, const char* key, const std::string& def = "") {
    if (!obj.is_object()) {
        if (!p5::py_truthy(obj)) return def;
        throw ApiError("AttributeError",
                       "'" + py_type_of(obj) + "' object has no attribute 'get'");
    }
    auto it = obj.find(key);
    if (it == obj.end() || !p5::py_truthy(*it)) return def;
    if (it->is_string()) return it->get<std::string>();
    return sa_core::py_str(*it);
}

// `_norm_remote(str value)` on a JSON slot of an already-or-chained value.
std::string norm_remote_json(const json& v) {
    if (v.is_null()) return "";
    if (v.is_string()) return norm_remote(v.get<std::string>());
    throw ApiError("AttributeError",
                   "'" + py_type_of(v) + "' object has no attribute 'replace'");
}

std::string read_file_or_throw(const std::string& path, const std::string& op) {
    auto b = spath::read_bytes(path);
    if (!b.has_value()) raise_typed("OSError", op + " failed: " + path);
    return std::move(*b);
}

// ---------------------------------------------------------------------------
// Drivers
// ---------------------------------------------------------------------------

class LocalDriver : public Driver {
  public:
    using Driver::Driver;

    std::string root() const {
        std::string r = json_str_or(config_, "root");
        if (r.empty()) r = json_str_or(config_, "path");
        if (r.empty()) raise_value_error("local root required");
        return spath::abs_path(r);
    }
    std::string abs_for(const std::string& remote_path) const {
        std::string rp = norm_remote(remote_path);
        std::string base = root();
        std::string abs_p = rp.empty() ? base : spath::abs_path(spath::join(base, rp));
        // Python compares raw strings with os.sep; normcase keeps the same
        // verdict under separator jitter (contract = escape refusal).
        std::string nk = spath::normcase(abs_p), bk = spath::normcase(base);
        if (nk != bk && !sp::starts_with(nk, bk + "\\")) raise_value_error("path escapes root");
        return abs_p;
    }

    void test() override {
        std::string r = root();
        if (!spath::is_dir(r)) raise_value_error("local root not found: " + r);
    }
    std::vector<Obj> list(const std::string& remote_path) override {
        std::string ap = abs_for(remote_path);
        std::vector<Obj> out;
        if (!spath::is_dir(ap)) return out;
        std::string prefix = norm_remote(remote_path);
        bool ok = false;
        auto names = spath::listdir_sorted(ap, &ok);
        if (!ok) return out;
        for (const auto& name : names) {
            std::string fp = spath::join(ap, name);
            std::string rp = prefix.empty() ? name : lstrip_slashes(prefix + "/" + name);
            auto st = spath::stat(fp);
            if (!st.has_value()) continue;  // Python: try/except continue
            bool dir = spath::is_dir(fp);
            out.push_back(Obj{name, rp, dir, dir ? 0 : st->size,
                              static_cast<long long>(std::floor(st->mtime_ns / 1e9)), ""});
        }
        return out;
    }
    std::optional<Obj> stat(const std::string& remote_path) override {
        std::string ap = abs_for(remote_path);
        if (!spath::exists(ap)) return std::nullopt;
        auto st = spath::stat(ap);
        bool dir = spath::is_dir(ap);
        std::string rp = norm_remote(remote_path);
        return Obj{spath::basename(ap), rp, dir, dir || !st ? 0 : st->size,
                   static_cast<long long>(st ? std::floor(st->mtime_ns / 1e9) : 0),
                   dir ? "" : sha1_of_file(ap)};
    }
    void get(const std::string& remote_path, const std::string& local_path) override {
        std::string ap = abs_for(remote_path);
        if (!spath::is_file(ap)) raise_file_not_found(remote_path);
        copy2(ap, local_path);
    }
    void put(const std::string& local_path, const std::string& remote_path) override {
        if (!spath::is_file(local_path)) raise_file_not_found(local_path);
        std::string ap = abs_for(remote_path);
        spath::create_dirs(spath::dirname(ap));
        copy2(local_path, ap);
    }
    void remove(const std::string& remote_path) override {
        std::string ap = abs_for(remote_path);
        if (spath::is_file(ap)) spath::remove_file(ap);
        else if (spath::is_dir(ap)) spath::remove_tree(ap);
    }
    void mkdir(const std::string& remote_path) override {
        spath::create_dirs(abs_for(remote_path));
    }
    json config_schema() override {
        json s;
        s["root"] = "本地根目录绝对路径";
        return s;
    }

  private:
    static std::string sha1_of_file(const std::string& path) {
        auto b = spath::read_bytes(path);
        if (!b.has_value()) return "";
        return sa_core::sha1_hex(*b);
    }
    // shutil.copy2: content + mtime (atime not modeled — nothing reads it back).
    static void copy2(const std::string& src, const std::string& dst) {
        spath::create_dirs(spath::dirname(spath::abs_path(dst)));
        auto b = spath::read_bytes(src);
        if (!b.has_value()) raise_typed("OSError", "copy failed: " + src);
        if (!spath::write_bytes_simple(dst, *b)) {
            raise_typed("OSError", "copy failed: " + dst);
        }
        auto st = spath::stat(src);
        if (st.has_value()) spath::set_mtime_ns(dst, st->mtime_ns);
    }
};

// Regex search helper with Python first-match semantics.
std::optional<std::string> re_search_1(const std::string& text, const std::regex& rx) {
    std::smatch m;
    if (std::regex_search(text, m, rx) && m.size() > 1) return m[1].str();
    return std::nullopt;
}

bool digits_only(const std::string& s) {
    return !s.empty() &&
           std::all_of(s.begin(), s.end(),
                       [](char c) { return std::isdigit(static_cast<unsigned char>(c)); });
}

class WebDAVDriver : public Driver {
  public:
    using Driver::Driver;

    std::string base() const {
        std::string u = p4::strip(json_str_or(config_, "url"));
        if (u.empty()) u = p4::strip(json_str_or(config_, "address"));
        u = rstrip_slashes(u);
        if (u.empty()) raise_value_error("webdav url required");
        if (!sp::starts_with(u, "http")) u = "https://" + u;
        return u;
    }
    std::vector<std::pair<std::string, std::string>> auth_headers() const {
        std::vector<std::pair<std::string, std::string>> h;
        std::string user = json_str_or(config_, "username");
        if (user.empty()) user = json_str_or(config_, "user");
        std::string pwd = json_str_or(config_, "password");
        if (pwd.empty()) pwd = json_str_or(config_, "pass");
        if (!user.empty() || !pwd.empty()) {
            h.emplace_back("Authorization",
                           "Basic " + sa_core::http::b64_encode(user + ":" + pwd));
        }
        return h;
    }
    std::string url_for(const std::string& remote_path) const {
        std::string b = base();
        std::string rp = norm_remote(remote_path);
        if (!rp.empty()) return b + "/" + sa_core::http::quote_component(rp);
        return b + "/";
    }

    void test() override {
        auto headers = auth_headers();
        headers.emplace_back("Depth", "0");
        headers.emplace_back("Content-Type", "application/xml");
        std::string body =
            "<?xml version=\"1.0\"?><propfind xmlns=\"DAV:\"><prop><displayname/></prop></propfind>";
        auto r = http_request(url_for(""), "PROPFIND", headers, &body, 15);
        if (r.status == 207 || r.status == 200 || r.status == 301 || r.status == 302) return;
        raise_value_error("webdav test failed: " + std::to_string(r.status));
    }
    std::vector<Obj> list(const std::string& remote_path) override {
        auto headers = auth_headers();
        headers.emplace_back("Depth", "1");
        headers.emplace_back("Content-Type", "application/xml");
        std::string body =
            "<?xml version=\"1.0\"?><propfind xmlns=\"DAV:\"><prop><displayname/>"
            "<getcontentlength/><getlastmodified/><resourcetype/></prop></propfind>";
        auto r = http_request(url_for(remote_path), "PROPFIND", headers, &body, 30);
        std::vector<Obj> out;
        if (!(r.status == 207 || r.status == 200)) return out;
        std::string text = utf8_ignore(r.body);
        static const std::regex rx_split("<D:response|<response", std::regex::icase);
        static const std::regex rx_href_d("<D:href[^>]*>([\\s\\S]*?)</D:href>",
                                          std::regex::icase);
        static const std::regex rx_href("<href[^>]*>([\\s\\S]*?)</href>", std::regex::icase);
        static const std::regex rx_len("<D:getcontentlength[^>]*>([\\s\\S]*?)</D:getcontentlength>",
                                       std::regex::icase);
        static const std::regex rx_lm(
            "<[^>]*getlastmodified[^>]*>([\\s\\S]*?)</[^>]*getlastmodified>", std::regex::icase);
        // re.split(r"<D:response|<response", text)[1:] — blocks after each match.
        std::sregex_token_iterator it(text.begin(), text.end(), rx_split, -1), end;
        if (it != end) ++it;  // drop blocks[0] (pre-first-match)
        for (; it != end; ++it) {
            const std::string blk = *it;
            auto href = re_search_1(blk, rx_href_d);
            if (!href) href = re_search_1(blk, rx_href);
            if (!href) continue;
            try {
                std::string path_part = url_path(unquote(p4::strip(*href)));
                std::string base_path = rstrip_slashes(url_path(base()));
                std::string rel = path_part;
                if (!base_path.empty() && sp::starts_with(rel, base_path))
                    rel = rel.substr(base_path.size());
                rel = strip_slashes(rel);
                std::string prefix = norm_remote(remote_path);
                if (rel == prefix) continue;  // skip self
                std::string tail;
                if (!prefix.empty()) {
                    if (!sp::starts_with(rel, prefix + "/")) continue;
                    tail = rel.substr(prefix.size() + 1);
                } else {
                    tail = rel;
                }
                if (tail.find('/') != std::string::npos) continue;  // direct children only
                const std::string& name = tail;
                if (name.empty()) continue;
                bool is_dir = contains(blk, "<D:collection") || contains(blk, "<collection");
                long long size = 0;
                auto len = re_search_1(blk, rx_len);
                if (len) {
                    std::string ds = p4::strip(*len);
                    if (digits_only(ds)) size = std::stoll(ds);
                }
                long long mtime = 0;
                auto lm = re_search_1(blk, rx_lm);
                if (lm) mtime = parse_http_date(*lm);
                out.push_back(Obj{name, rel, is_dir, size, mtime, ""});
            } catch (...) {
                continue;  // Python: except Exception: continue
            }
        }
        return out;
    }
    std::optional<Obj> stat(const std::string& remote_path) override {
        auto headers = auth_headers();
        headers.emplace_back("Depth", "0");
        headers.emplace_back("Content-Type", "application/xml");
        std::string body =
            "<?xml version=\"1.0\"?><propfind xmlns=\"DAV:\"><prop><getcontentlength/>"
            "<resourcetype/><getlastmodified/></prop></propfind>";
        auto r = http_request(url_for(remote_path), "PROPFIND", headers, &body, 15);
        if (!(r.status == 207 || r.status == 200)) return std::nullopt;
        std::string text = utf8_ignore(r.body);
        bool is_dir = contains(text, "<D:collection") || contains(text, "<collection");
        static const std::regex rx_len("<D:getcontentlength[^>]*>([\\s\\S]*?)</D:getcontentlength>",
                                       std::regex::icase);
        static const std::regex rx_lm(
            "<[^>]*getlastmodified[^>]*>([\\s\\S]*?)</[^>]*getlastmodified>", std::regex::icase);
        long long size = 0;
        auto len = re_search_1(text, rx_len);
        if (len) {
            std::string ds = p4::strip(*len);
            if (digits_only(ds)) size = std::stoll(ds);
        }
        long long mtime = 0;
        auto lm = re_search_1(text, rx_lm);
        if (lm) mtime = parse_http_date(*lm);
        std::string rp = norm_remote(remote_path);
        return Obj{spath::basename(rp), rp, is_dir, size, mtime, ""};
    }
    void get(const std::string& remote_path, const std::string& local_path) override {
        auto r = http_request(url_for(remote_path), "GET", auth_headers(), nullptr, 60);
        if (r.status != 200) raise_value_error("webdav get failed: " + std::to_string(r.status));
        spath::create_dirs(spath::dirname(spath::abs_path(local_path)));
        if (!spath::write_bytes_simple(local_path, r.body)) {
            raise_typed("OSError", "write failed: " + local_path);
        }
    }
    void put(const std::string& local_path, const std::string& remote_path) override {
        if (!spath::is_file(local_path)) raise_file_not_found(local_path);
        std::string parent = spath::dirname(norm_remote(remote_path));
        if (!parent.empty()) mkdir(parent);
        std::string data = read_file_or_throw(local_path, "read");
        auto r = http_request(url_for(remote_path), "PUT", auth_headers(), &data, 60);
        if (!(r.status == 200 || r.status == 201 || r.status == 204)) {
            raise_value_error("webdav put failed: " + std::to_string(r.status));
        }
    }
    void remove(const std::string& remote_path) override {
        auto r = http_request(url_for(remote_path), "DELETE", auth_headers(), nullptr, 15);
        if (!(r.status == 200 || r.status == 204 || r.status == 404)) {
            raise_value_error("webdav delete failed: " + std::to_string(r.status));
        }
    }
    void mkdir(const std::string& remote_path) override {
        std::string rp = norm_remote(remote_path);
        size_t pos = 0;
        std::string cur;
        while (pos < rp.size()) {
            size_t slash = rp.find('/', pos);
            std::string part =
                rp.substr(pos, slash == std::string::npos ? std::string::npos : slash - pos);
            cur = cur.empty() ? part : cur + "/" + part;
            http_request(url_for(cur), "MKCOL", auth_headers(), nullptr, 15);  // ignored
            if (slash == std::string::npos) break;
            pos = slash + 1;
        }
    }
    json config_schema() override {
        json s;
        s["url"] = "WebDAV 地址 (https://dav.example.com/path)";
        s["username"] = "用户名";
        s["password"] = "密码";
        return s;
    }
};

class OpenListDriver : public Driver {
  public:
    using Driver::Driver;

    std::string base() const {
        std::string u = p4::strip(json_str_or(config_, "url"));
        if (u.empty()) u = p4::strip(json_str_or(config_, "address"));
        u = rstrip_slashes(u);
        if (u.empty()) raise_value_error("openlist url required");
        std::string low = sp::lower(u);
        if (contains(low, "renewapi") || contains(low, "googleui") ||
            contains(low, "baiduyun/renew") || contains(low, "aliyundrive/renew")) {
            raise_value_error(
                "openlist url 填写错误：" + u +
                " 是 Token 刷新接口（/renewapi），不是 OpenList 实例地址。请填你的 OpenList "
                "服务地址，如 http://127.0.0.1:5244 或 http://host:5244");
        }
        if (!sp::starts_with(u, "http")) u = "http://" + u;
        return u;
    }
    std::vector<std::pair<std::string, std::string>> json_headers() const {
        std::vector<std::pair<std::string, std::string>> h;
        h.emplace_back("Content-Type", "application/json");
        std::string token = json_str_or(config_, "token");
        if (token.empty()) token = json_str_or(config_, "password");
        if (!token.empty()) h.emplace_back("Authorization", token);
        return h;
    }

    // _api — returns j["data"] (possibly null).
    json api_call(const std::string& path, const json* payload, const std::string& method) {
        std::string url = base() + path;
        std::string body;
        const std::string* data = nullptr;
        if (payload != nullptr) {
            body = sa_core::py_dumps(p5::py_truthy(*payload) ? *payload : json::object());
            data = &body;
        }
        auto r = http_request(url, method, json_headers(), data, 30);
        if (r.status != 200) {
            std::string snippet = lossy8(r.body, 800);
            if (r.status == 403 && contains(snippet, "1010")) {
                raise_value_error(
                    "openlist api " + path +
                    " failed: 403 error code: 1010 (Cloudflare 拦截)。原因：OpenList 地址 " +
                    base() +
                    " 无法访问，可能是填错了地址（把 https://api.oplist.org/.../renewapi "
                    "当成了 OpenList 地址），或该公共服务已禁止此请求。请检查：1) OpenList "
                    "地址应为你的 OpenList 实例如 http://127.0.0.1:5244；2) 若走直连 Google "
                    "Drive 请清空 OpenList 地址，仅填 refresh_token 并确保网络可访问 "
                    "https://www.googleapis.com");
            }
            if (r.status == 403) {
                raise_value_error("openlist api " + path +
                                  " failed: 403 Forbidden " + clip_codepoints(snippet, 300) +
                                  "。检查 OpenList 地址/Token 是否正确，及防火墙/Cloudflare 是否拦截。");
            }
            raise_value_error("openlist api " + path + " failed: " + std::to_string(r.status) +
                              " " + bytes_repr(r.body, 500));
        }
        json j;
        try {
            j = json::parse(r.body);
        } catch (const std::exception&) {
            raise_value_error("openlist invalid json: " + py_json_err(r.body));
        }
        if (!j.is_object()) {
            throw ApiError("AttributeError",
                           "'" + py_type_of(j) + "' object has no attribute 'get'");
        }
        // `if j.get("code") != 200` — Python equality semantics: int 200 /
        // float 200.0 pass, str "200" and missing do not.
        bool code_ok = false;
        if (j.contains("code")) {
            const json& c = j["code"];
            if (c.is_number_integer() || c.is_number_unsigned()) code_ok = c.get<long long>() == 200;
            else if (c.is_number_float()) code_ok = c.get<double>() == 200.0;
        }
        if (!code_ok) {
            std::string msg = j.contains("message") ? sa_core::py_str(j["message"])
                                                    : std::string("None");
            raise_value_error("openlist error: " + msg);
        }
        auto it = j.find("data");
        if (it == j.end()) return json(nullptr);
        return *it;
    }

    void test() override {
        json empty = json::object();
        try {
            api_call("/api/me", &empty, "GET");
            return;
        } catch (...) {
        }
        list("");
    }
    std::vector<Obj> list(const std::string& remote_path) override {
        std::string rp = "/" + norm_remote(remote_path);
        json payload;
        payload["path"] = rp;
        payload["password"] = "";
        payload["page"] = 1;
        payload["per_page"] = 0;
        payload["refresh"] = true;
        json data = api_call("/api/fs/list", &payload, "POST");
        if (!data.is_object()) {
            throw ApiError("AttributeError",
                           "'" + py_type_of(data) + "' object has no attribute 'get'");
        }
        json content = data.contains("content") ? data["content"] : json(nullptr);
        std::vector<Obj> out;
        if (!p5::py_truthy(content)) return out;
        std::string prefix = norm_remote(remote_path);
        for (const auto& item : content) {
            if (!item.is_object()) {
                throw ApiError("AttributeError",
                               "'" + py_type_of(item) + "' object has no attribute 'get'");
            }
            std::string name;
            if (item.contains("name") && item["name"].is_string())
                name = item["name"].get<std::string>();
            bool is_dir =
                p5::py_truthy(item.contains("is_dir") ? item["is_dir"] : json(nullptr));
            long long size = 0;
            {
                json v = item.contains("size") ? item["size"] : json(nullptr);
                size = p4::json_int(p5::py_truthy(v) ? v : json(0)).value_or(0);
            }
            // int(modified or 0) first; a numeric string keeps the assigned
            // int when the follow-up fromisoformat() raises (Python quirk —
            // the ISO attempt is only reachable for already-int-parsable
            // strings).
            long long mtime = 0;
            try {
                json v = item.contains("modified") ? item["modified"] : json(nullptr);
                auto iv = p4::json_int(p5::py_truthy(v) ? v : json(0));
                if (!iv) raise_value_error("invalid literal for int()");
                mtime = *iv;
                if (v.is_string()) {
                    mtime = parse_iso_time(v.get<std::string>()).value();  // may throw
                }
            } catch (...) {
                // except Exception: pass — pre-assigned mtime (if any) stands.
            }
            std::string rel = prefix.empty() ? name : lstrip_slashes(prefix + "/" + name);
            out.push_back(Obj{name, rel, is_dir, size, mtime, ""});
        }
        return out;
    }
    std::optional<Obj> stat(const std::string& remote_path) override {
        try {
            std::string rp = "/" + norm_remote(remote_path);
            json payload;
            payload["path"] = rp;
            payload["password"] = "";
            json data = api_call("/api/fs/get", &payload, "POST");
            if (!p5::py_truthy(data)) return std::nullopt;
            if (!data.is_object()) {
                throw ApiError("AttributeError",
                               "'" + py_type_of(data) + "' object has no attribute 'get'");
            }
            std::string name = json_str_or(data, "name");
            if (name.empty()) name = posix_basename(rp);
            bool is_dir =
                p5::py_truthy(data.contains("is_dir") ? data["is_dir"] : json(nullptr));
            long long size = 0;
            {
                json v = data.contains("size") ? data["size"] : json(nullptr);
                size = p4::json_int(p5::py_truthy(v) ? v : json(0)).value_or(0);
            }
            long long mtime = 0;
            try {
                if (data.contains("modified") && data["modified"].is_string()) {
                    mtime = parse_iso_time(data["modified"].get<std::string>()).value();
                } else {
                    json v = data.contains("modified") ? data["modified"] : json(nullptr);
                    mtime = p4::json_int(p5::py_truthy(v) ? v : json(0)).value_or(0);
                }
            } catch (...) {
                mtime = 0;  // except (ValueError, TypeError, OSError)
            }
            return Obj{name, norm_remote(remote_path), is_dir, size, mtime, ""};
        } catch (...) {
            return std::nullopt;
        }
    }
    void get(const std::string& remote_path, const std::string& local_path) override {
        std::string rp = "/" + norm_remote(remote_path);
        json payload;
        payload["path"] = rp;
        payload["password"] = "";
        json data = api_call("/api/fs/get", &payload, "POST");
        if (!data.is_object()) {
            throw ApiError("AttributeError",
                           "'" + py_type_of(data) + "' object has no attribute 'get'");
        }
        std::string raw_url = json_str_or(data, "raw_url");
        if (raw_url.empty()) raw_url = json_str_or(data, "url");
        if (raw_url.empty()) raise_value_error("no raw_url for " + remote_path);
        if (sp::starts_with(raw_url, "/")) raw_url = base() + raw_url;
        std::vector<std::pair<std::string, std::string>> empty_headers;
        auto r = http_request(raw_url, "GET", empty_headers, nullptr, 60);
        if (r.status != 200) raise_value_error("download failed: " + std::to_string(r.status));
        spath::create_dirs(spath::dirname(spath::abs_path(local_path)));
        if (!spath::write_bytes_simple(local_path, r.body)) {
            raise_typed("OSError", "write failed: " + local_path);
        }
    }
    void put(const std::string& local_path, const std::string& remote_path) override {
        if (!spath::is_file(local_path)) raise_file_not_found(local_path);
        std::string rp = "/" + norm_remote(remote_path);
        std::string url = base() + "/api/fs/put";
        auto headers = json_headers();
        headers.emplace_back("File-Path", sa_core::http::quote_component(rp));
        headers.emplace_back("Content-Type", "application/octet-stream");
        std::string data = read_file_or_throw(local_path, "read");
        auto r = http_request(url, "PUT", headers, &data, 60);
        if (r.status != 200) {
            raise_value_error("openlist put failed: " + std::to_string(r.status) + " " +
                              bytes_repr(r.body, 500));
        }
        json j;
        try {
            j = json::parse(r.body);
        } catch (const std::exception&) {
            raise_value_error("openlist invalid json: " + py_json_err(r.body));
        }
        bool code_ok = j.is_object() && j.contains("code") &&
                       j["code"].is_number_integer() && j["code"].get<long long>() == 200;
        if (!code_ok) {
            raise_value_error("openlist put error: " +
                              (j.is_object() && j.contains("message")
                                   ? sa_core::py_str(j["message"])
                                   : std::string("None")));
        }
    }
    void remove(const std::string& remote_path) override {
        std::string rp = "/" + norm_remote(remote_path);
        json payload;
        std::string dir = posix_dirname(rp);
        payload["dir"] = dir.empty() ? std::string("/") : dir;
        payload["names"] = json::array({posix_basename(rp)});
        api_call("/api/fs/remove", &payload, "POST");
    }
    void mkdir(const std::string& remote_path) override {
        std::string rp = "/" + norm_remote(remote_path);
        json payload;
        payload["path"] = rp;
        api_call("/api/fs/mkdir", &payload, "POST");
    }
    json config_schema() override {
        json s;
        s["url"] = "OpenList/Alist 地址 (http://host:5244)";
        s["token"] = "Token (设置-后端-令牌)";
        s["username"] = "可选用户名";
        s["password"] = "可选密码";
        return s;
    }

  private:
    static std::string lossy8(const std::string& raw, size_t n) {
        return utf8_ignore(raw.size() > n ? raw.substr(0, n) : raw);
    }
    // body[:300] on the decoded str — codepoint-aware clip.
    static std::string clip_codepoints(const std::string& s, size_t n) {
        size_t cp = 0, i = 0;
        while (i < s.size() && cp < n) {
            unsigned char c = static_cast<unsigned char>(s[i]);
            i += (c < 0x80) ? 1 : (c < 0xE0) ? 2 : (c < 0xF0) ? 3 : 4;
            ++cp;
        }
        return s.substr(0, std::min(i, s.size()));
    }
    // CPython json.loads error text for the shapes these paths see.
    static std::string py_json_err(const std::string& raw) {
        size_t pos = raw.find_first_not_of(" \t\n\r");
        size_t line = 1, col = 1;
        if (pos == std::string::npos) pos = raw.size();
        for (size_t k = 0; k < pos; ++k) {
            if (raw[k] == '\n') { ++line; col = 1; }
            else ++col;
        }
        std::string what = "Expecting value";
        if (pos < raw.size() && raw[pos] == '{') {
            what = "Expecting property name enclosed in double quotes";
        }
        return what + ": line " + std::to_string(line) + " column " + std::to_string(col) +
               " (char " + std::to_string(pos) + ")";
    }
    static std::string posix_dirname(const std::string& p) {
        size_t slash = p.find_last_of('/');
        if (slash == std::string::npos) return "";
        if (slash == 0) return "/";
        return p.substr(0, slash);
    }
    static std::string posix_basename(const std::string& p) {
        size_t slash = p.find_last_of('/');
        return slash == std::string::npos ? p : p.substr(slash + 1);
    }
};

// ---- net-disk drivers: root/openlist delegation (full parity); direct legs
// degraded with deterministic envelopes (see cloud_sync.h header note). ----

struct NetDiskDriver : Driver {
    using Driver::Driver;
    explicit NetDiskDriver(json cfg) : Driver(std::move(cfg)) {}

    bool has_root() const { return p5::py_truthy(cfg_at("root")); }
    bool has_openlist() const { return p5::py_truthy(cfg_at("openlist_url")); }
    const json& cfg_at(const char* k) const {
        static const json null_json(nullptr);
        if (!config_.is_object()) return null_json;
        auto it = config_.find(k);
        return it == config_.end() ? null_json : *it;
    }
    std::shared_ptr<Driver> openlist() const {
        json sub;
        sub["url"] = cfg_at("openlist_url");
        std::string tok;
        const json& tv = cfg_at("openlist_token");
        if (tv.is_string()) tok = tv.get<std::string>();
        sub["token"] = tok;
        return std::make_shared<OpenListDriver>(sub);
    }
    std::shared_ptr<Driver> local() const { return std::make_shared<LocalDriver>(config_); }
    std::string mount_full(const std::string& remote_path) const {
        std::string mount = json_str_or(config_, "mount_path");
        if (mount.empty()) mount = mount_default_;
        return strip_slashes(rstrip_slashes(mount) + "/" + norm_remote(remote_path));
    }
    [[noreturn]] void direct() const { raise_value_error(direct_msg_); }

    std::string mount_default_ = "/baidu";
    std::string direct_msg_ =
        "baidu 直连需真实外联（refresh_token 刷新/OAuth API），C++ 侧请配置 root 或 openlist_url";
};

class BaiduNetdiskDriver : public NetDiskDriver {
  public:
    using NetDiskDriver::NetDiskDriver;
    void test() override {
        if (has_root()) return local()->test();
        if (has_openlist()) return openlist()->test();
        direct();
    }
    std::vector<Obj> list(const std::string& rp) override {
        if (has_openlist()) return openlist()->list(mount_full(rp));
        if (has_root()) return local()->list(rp);
        direct();
    }
    std::optional<Obj> stat(const std::string& rp) override {
        if (has_openlist()) return openlist()->stat(mount_full(rp));
        if (has_root()) return local()->stat(rp);
        direct();
    }
    void mkdir(const std::string& rp) override {
        if (has_openlist()) return openlist()->mkdir(mount_full(rp));
        if (has_root()) return local()->mkdir(rp);
        direct();
    }
    void remove(const std::string& rp) override {
        if (has_openlist()) return openlist()->remove(mount_full(rp));
        if (has_root()) return local()->remove(rp);
        direct();
    }
    void get(const std::string& rp, const std::string& lp) override {
        if (has_openlist()) return openlist()->get(mount_full(rp), lp);
        if (has_root()) return local()->get(rp, lp);
        direct();
    }
    void put(const std::string& lp, const std::string& rp) override {
        if (has_openlist()) return openlist()->put(lp, mount_full(rp));
        if (has_root()) return local()->put(lp, rp);
        direct();
    }
    json config_schema() override {
        json s;
        s["refresh_token"] = "百度 refresh_token（必填）";
        s["client_id"] = "Client ID（可选，官方 OAuth）";
        s["client_secret"] = "Client Secret";
        s["api_url_address"] = "在线刷新地址";
        s["openlist_url"] = "OpenList 代理（可选）";
        s["mount_path"] = "/baidu";
        s["root"] = "本地测试根";
        return s;
    }
};

class Pan123Driver : public NetDiskDriver {
  public:
    explicit Pan123Driver(json cfg) : NetDiskDriver(std::move(cfg)) {
        mount_default_ = "/123";
        direct_msg_ = "123 直连需真实外联（登录 + 签名上传 API），C++ 侧请配置 root 或 openlist_url";
    }
    void test() override {
        if (has_root()) return local()->test();
        if (has_openlist()) return openlist()->test();
        direct();
    }
    std::vector<Obj> list(const std::string& rp) override {
        if (has_openlist()) return openlist()->list(mount_full(rp));
        if (has_root()) return local()->list(rp);
        direct();
    }
    std::optional<Obj> stat(const std::string& rp) override {
        if (has_openlist()) return openlist()->stat(mount_full(rp));
        if (has_root()) return local()->stat(rp);
        direct();
    }
    void mkdir(const std::string& rp) override {
        if (has_openlist()) return openlist()->mkdir(mount_full(rp));
        if (has_root()) return local()->mkdir(rp);
        direct();
    }
    void remove(const std::string& rp) override {
        if (has_openlist()) return openlist()->remove(mount_full(rp));
        if (has_root()) return local()->remove(rp);
        direct();
    }
    void get(const std::string& rp, const std::string& lp) override {
        if (has_openlist()) return openlist()->get(mount_full(rp), lp);
        if (has_root()) return local()->get(rp, lp);
        direct();
    }
    void put(const std::string& lp, const std::string& rp) override {
        if (has_openlist()) return openlist()->put(lp, mount_full(rp));
        if (has_root()) return local()->put(lp, rp);
        direct();
    }
    json config_schema() override {
        json s;
        s["username"] = "123 用户名/邮箱";
        s["password"] = "密码";
        s["passport"] = "passport（可选）";
        s["openlist_url"] = "OpenList 地址（可选，直连失败时走代理）";
        s["openlist_token"] = "OpenList Token";
        s["mount_path"] = "/123";
        s["root"] = "本地测试根";
        return s;
    }
};

class GoogleDriveDriver : public NetDiskDriver {
  public:
    explicit GoogleDriveDriver(json cfg) : NetDiskDriver(std::move(cfg)) {
        mount_default_ = "/gdrive";
        direct_msg_ = "Google Drive 直连列目录失败（需 openlist_url 或本地 root，或确保 "
                      "refresh_token/client_id 正确且网络可达）：直连 OAuth/drive/v3 "
                      "未移植。建议：在 OpenList 中挂载 Google Drive 后填入 "
                      "openlist_url=http://127.0.0.1:5244";
    }
    void test() override {
        if (has_root()) return local()->test();
        if (has_openlist()) {
            std::string url = p4::strip(json_str_or(config_, "openlist_url"));
            std::string low = sp::lower(url);
            if (contains(low, "renewapi") || contains(low, "googleui")) {
                raise_value_error(
                    "Google Drive 的 OpenList 地址填写错误：" + url +
                    " 是 Google Token 刷新接口，不是 OpenList 实例。请留空该字段以走直连，或填你的 "
                    "OpenList 服务地址如 http://127.0.0.1:5244（需在 OpenList 中挂载 Google "
                    "Drive 到 /gdrive），并确保挂载路径正确（如 /gdrive）");
            }
            std::shared_ptr<Driver> drv = openlist();
            try {
                drv->test();
                return;
            } catch (const std::exception& e) {
                std::string msg = exception_str(e);
                if ((contains(msg, "10061") || contains(msg, "ConnectionRefused") ||
                     contains(msg, "Failed to establish") || contains(msg, "urlopen error")) &&
                    p5::py_truthy(cfg_at("refresh_token"))) {
                    direct();  // direct about-check leg degraded
                }
                raise_value_error("无法连接 OpenList " + url + "：" + msg +
                                  "。请确认 OpenList 已启动（双击 OpenList.exe 或运行 openlist "
                                  "server），端口 5244 可访问，且已在 OpenList 后台添加 Google "
                                  "Drive 存储并挂载到 " +
                                  json_str_or(config_, "mount_path", "/gdrive") +
                                  "。若不想自建，请清空 OpenList 地址走直连（需补充 Client ID）");
            }
        }
        direct();
    }
    std::vector<Obj> list(const std::string& rp) override {
        if (has_openlist()) {
            std::shared_ptr<Driver> drv = openlist();
            std::string full = mount_full(rp);
            try {
                return drv->list(full);
            } catch (const std::exception& e) {
                std::string msg = exception_str(e);
                if ((contains(msg, "10061") || contains(msg, "ConnectionRefused") ||
                     contains(msg, "urlopen error") || contains(msg, "Failed to establish")) &&
                    p5::py_truthy(cfg_at("refresh_token"))) {
                    raise_value_error("OpenList " + json_str_or(config_, "openlist_url") +
                                      " 不可用且直连也失败: " + direct_msg_ +
                                      "（原始 OpenList 错误: " + msg + "）");
                }
                throw;
            }
        }
        if (has_root()) return local()->list(rp);
        direct();
    }
    std::optional<Obj> stat(const std::string& rp) override {
        if (has_openlist()) {
            try {
                return openlist()->stat(mount_full(rp));
            } catch (...) {
                // Python falls through to root/direct legs after a swallowed error
            }
        }
        if (has_root()) return local()->stat(rp);
        return std::nullopt;  // direct list-search degrades to "not found"
    }
    void mkdir(const std::string& rp) override {
        if (has_openlist()) {
            try {
                return openlist()->mkdir(mount_full(rp));
            } catch (const std::exception& e) {
                if ((contains(exception_str(e), "10061") ||
                     contains(exception_str(e), "urlopen error")) &&
                    p5::py_truthy(cfg_at("refresh_token"))) {
                    direct();
                }
                throw;
            }
        }
        if (has_root()) return local()->mkdir(rp);
        direct();
    }
    void remove(const std::string& rp) override {
        if (has_openlist()) {
            try {
                return openlist()->remove(mount_full(rp));
            } catch (const std::exception& e) {
                if ((contains(exception_str(e), "10061") ||
                     contains(exception_str(e), "urlopen error")) &&
                    p5::py_truthy(cfg_at("refresh_token"))) {
                    direct();
                }
                throw;
            }
        }
        if (has_root()) return local()->remove(rp);
        direct();
    }
    void get(const std::string& rp, const std::string& lp) override {
        if (has_openlist()) {
            try {
                return openlist()->get(mount_full(rp), lp);
            } catch (const std::exception& e) {
                std::string msg = exception_str(e);
                if ((contains(msg, "10061") || contains(msg, "urlopen error")) &&
                    p5::py_truthy(cfg_at("refresh_token"))) {
                    raise_value_error("openlist " + json_str_or(config_, "openlist_url") +
                                      " 不可用且直连找不到文件 " + rp + ": " + msg);
                }
                throw;
            }
        }
        if (has_root()) return local()->get(rp, lp);
        direct();
    }
    void put(const std::string& lp, const std::string& rp) override {
        if (has_openlist()) {
            try {
                return openlist()->put(lp, mount_full(rp));
            } catch (const std::exception& e) {
                if ((contains(exception_str(e), "10061") ||
                     contains(exception_str(e), "urlopen error")) &&
                    p5::py_truthy(cfg_at("refresh_token"))) {
                    direct();
                }
                throw;
            }
        }
        if (has_root()) return local()->put(lp, rp);
        direct();
    }
    json config_schema() override {
        json s;
        s["client_id"] = "Client ID";
        s["client_secret"] = "Client Secret";
        s["refresh_token"] = "refresh_token";
        s["openlist_url"] = "OpenList 地址";
        s["mount_path"] = "/gdrive";
        s["root"] = "本地测试根";
        return s;
    }
};

class OneDriveDriver : public NetDiskDriver {
  public:
    explicit OneDriveDriver(json cfg) : NetDiskDriver(std::move(cfg)) {
        mount_default_ = "/onedrive";
        direct_msg_ = "OneDrive 直连列目录失败（需 openlist_url 或本地 root，或确保 "
                      "refresh_token/Client ID 正确）：Microsoft Graph 直连未移植。建议 OpenList "
                      "挂载后填 openlist_url=http://127.0.0.1:5244";
    }
    void test() override {
        if (has_root()) return local()->test();
        if (has_openlist()) {
            std::shared_ptr<Driver> drv = openlist();
            try {
                drv->test();
                return;
            } catch (const std::exception& e) {
                std::string msg = exception_str(e);
                if ((contains(msg, "10061") || contains(msg, "ConnectionRefused") ||
                     contains(msg, "urlopen error")) &&
                    p5::py_truthy(cfg_at("refresh_token"))) {
                    direct();  // graph fallback degraded
                }
                raise_value_error("无法连接 OpenList " + json_str_or(config_, "openlist_url") +
                                  ": " + msg +
                                  "。请确认 OpenList 已启动，或清空 OpenList 地址走直连并补充 "
                                  "Client ID");
            }
        }
        // Direct leg: the token-bootstrap guard messages are real Python
        // behavior (no network needed); the graph call itself is degraded.
        if (p5::py_truthy(cfg_at("access_token"))) direct();
        if (p5::py_truthy(cfg_at("refresh_token"))) {
            std::string cid = json_str_or(config_, "client_id");
            if (cid.empty() || cid == "f0e3cad9-1bf3-4006-9999-1a1a1e1a4ae0") {
                raise_value_error(
                    "OneDrive 需要 refresh_token + Client ID（Azure 应用客户端 ID）。当前仅提供 "
                    "refresh_token 但未填 Client ID（默认示例 4b3492b7-... 仅占位，需填你自己的 "
                    "Azure 应用 ID，见 Azure 门户->应用注册，或使用 oplist.org 提供的完整 Client "
                    "ID）。或走 OpenList：填 OpenList 地址如 http://127.0.0.1:5244 并在 OpenList "
                    "中挂载 OneDrive（推荐），此时无需在编辑器填 refresh_token");
            }
            direct();
        }
        raise_value_error(
            "onedrive 需要 refresh_token（+ Client ID）或 access_token，或填 OpenList 地址走代理");
    }
    std::vector<Obj> list(const std::string& rp) override {
        if (has_openlist()) return openlist()->list(mount_full(rp));
        if (has_root()) return local()->list(rp);
        direct();
    }
    std::optional<Obj> stat(const std::string& rp) override {
        if (has_openlist()) return openlist()->stat(mount_full(rp));
        if (has_root()) return local()->stat(rp);
        return std::nullopt;  // Python direct branch: return None
    }
    void get(const std::string& rp, const std::string& lp) override {
        if (has_openlist()) return openlist()->get(mount_full(rp), lp);
        if (has_root()) return local()->get(rp, lp);
        // Exact Python behaviour — no network involved.
        raise_value_error("OneDrive 直连下载需配置 openlist_url，请通过 OpenList 代理");
    }
    void put(const std::string& lp, const std::string& rp) override {
        if (has_openlist()) return openlist()->put(lp, mount_full(rp));
        if (has_root()) return local()->put(lp, rp);
        raise_typed("NotImplementedError", "onedrive requires openlist_url");
    }
    void remove(const std::string& rp) override {
        if (has_openlist()) return openlist()->remove(mount_full(rp));
        if (has_root()) return local()->remove(rp);
        // Python direct branch: return True
    }
    void mkdir(const std::string& rp) override {
        if (has_openlist()) return openlist()->mkdir(mount_full(rp));
        if (has_root()) return local()->mkdir(rp);
        // Python direct branch: return True
    }
    json config_schema() override {
        json s;
        s["refresh_token"] = "refresh_token";
        s["client_id"] = "Client ID";
        s["client_secret"] = "Client Secret";
        s["openlist_url"] = "OpenList 地址";
        s["mount_path"] = "/onedrive";
        s["root"] = "本地测试根";
        return s;
    }
};

std::shared_ptr<Driver> new_local(json c) { return std::make_shared<LocalDriver>(std::move(c)); }
std::shared_ptr<Driver> new_webdav(json c) { return std::make_shared<WebDAVDriver>(std::move(c)); }
std::shared_ptr<Driver> new_openlist(json c) {
    return std::make_shared<OpenListDriver>(std::move(c));
}
std::shared_ptr<Driver> new_baidu(json c) {
    return std::make_shared<BaiduNetdiskDriver>(std::move(c));
}
std::shared_ptr<Driver> new_123(json c) { return std::make_shared<Pan123Driver>(std::move(c)); }
std::shared_ptr<Driver> new_gdrive(json c) {
    return std::make_shared<GoogleDriveDriver>(std::move(c));
}
std::shared_ptr<Driver> new_onedrive(json c) {
    return std::make_shared<OneDriveDriver>(std::move(c));
}

// cloud_sync.py:1707-1710 REMOVED_DRIVERS
const std::map<std::string, std::string>& removed_drivers() {
    static const std::map<std::string, std::string> kRemoved = {
        {"aliyundrive", "阿里云盘"}, {"aliyun", "阿里云盘"}, {"quark", "夸克云盘"},
        {"189", "天翼云盘"},        {"tianyi", "天翼云盘"},
    };
    return kRemoved;
}

}  // namespace

// ---------------------------------------------------------------------------
// Public utility implementations (cloud_sync.py:52-95, 129-138)
// ---------------------------------------------------------------------------

void raise_value_error(const std::string& msg) { throw PyError("ValueError", msg); }
void raise_file_not_found(const std::string& msg) { throw PyError("FileNotFoundError", msg); }
void raise_typed(const std::string& type_name, const std::string& msg) {
    throw PyError(type_name, msg);
}

std::string norm_remote(const std::string& p_in) {
    // cloud_sync.py:62-71
    std::string p = p4::strip(sa_core::str::replace_all(p_in, "\\", "/"));
    std::string collapsed;  // re.sub(r"/+", "/", p)
    for (size_t i = 0; i < p.size(); ++i) {
        if (p[i] == '/' && i + 1 < p.size() && p[i + 1] == '/') continue;
        collapsed += p[i];
    }
    while (!collapsed.empty() && collapsed.front() == '/') collapsed.erase(collapsed.begin());
    if (collapsed.empty()) return "";
    size_t pos = 0;  // if ".." in p.split("/"): raise
    while (pos <= collapsed.size()) {
        size_t slash = collapsed.find('/', pos);
        std::string seg = collapsed.substr(
            pos, slash == std::string::npos ? std::string::npos : slash - pos);
        if (seg == "..") raise_value_error("invalid remote path: " + collapsed);
        if (slash == std::string::npos) break;
        pos = slash + 1;
    }
    return collapsed;
}

long long parse_http_date(const std::string& s) {
    // cloud_sync.py:74-95 _parse_http_date — RFC1123 first, then ISO-Z, else 0.
    std::string t = p4::strip(s);
    if (t.empty()) return 0;
    long long v = 0;
    if (parse_rfc1123(t, &v)) return v;
    {
        std::istringstream is(t);
        int y = 0, mo = 0, d = 0, hh = 0, mi = 0, ss = 0;
        char c1 = 0, c2 = 0, c3 = 0, c4 = 0, z = 0;
        if ((is >> y >> c1 >> mo >> c2 >> d) && c1 == '-' && c2 == '-' && is.peek() == 'T') {
            is.get();
            if ((is >> hh >> c3 >> mi >> c4 >> ss) && c3 == ':' && c4 == ':') {
                if ((is >> z) && z == 'Z' && !is.rdbuf()->in_avail()) {
                    return days_from_civil(y, static_cast<unsigned>(mo),
                                           static_cast<unsigned>(d)) * 86400 +
                           hh * 3600 + mi * 60 + ss;
                }
            }
        }
    }
    return 0;
}

std::optional<long long> parse_iso_time(const std::string& s) {
    // datetime.fromisoformat(x.replace("Z", "+00:00")).timestamp()
    // — naive inputs resolve in LOCAL time (Python datetime.timestamp()).
    std::string t = s;
    if (!t.empty() && (t.back() == 'Z' || t.back() == 'z')) {
        t.pop_back();
        t += "+00:00";
    }
    std::istringstream is(t);
    int y = 0, mo = 0, d = 0, hh = 0, mi = 0, ss = 0;
    char c1 = 0, c2 = 0, c3 = 0;
    if (!(is >> y >> c1 >> mo >> c2 >> d) || c1 != '-' || c2 != '-') return std::nullopt;
    long long secs =
        days_from_civil(y, static_cast<unsigned>(mo), static_cast<unsigned>(d)) * 86400;
    if (is.eof()) {
        // date-only naive — Python resolves local midnight.
        std::tm tmv{};
        tmv.tm_year = y - 1900;
        tmv.tm_mon = mo - 1;
        tmv.tm_mday = d;
        tmv.tm_isdst = -1;
        std::time_t lt = std::mktime(&tmv);
        return lt == static_cast<std::time_t>(-1) ? std::optional<long long>()
                                                  : std::optional<long long>(
                                                        static_cast<long long>(lt));
    }
    char sep = static_cast<char>(is.get());
    if (sep != 'T' && sep != 't' && sep != ' ') return std::nullopt;
    if (!(is >> hh >> c3 >> mi) || c3 != ':') return std::nullopt;
    secs += hh * 3600 + mi * 60;
    if (is.peek() == ':') {
        is.get();
        if (!(is >> ss)) return std::nullopt;
        secs += ss;
        if (is.peek() == '.') {  // fractional seconds — consume, truncate
            is.get();
            while (!is.eof() && std::isdigit(static_cast<unsigned char>(is.peek()))) is.get();
        }
    }
    if (is.eof()) {
        // naive datetime -> local
        std::tm tmv{};
        tmv.tm_year = y - 1900;
        tmv.tm_mon = mo - 1;
        tmv.tm_mday = d;
        tmv.tm_hour = hh;
        tmv.tm_min = mi;
        tmv.tm_sec = ss;
        tmv.tm_isdst = -1;
        std::time_t lt = std::mktime(&tmv);
        if (lt == static_cast<std::time_t>(-1)) return std::nullopt;
        return static_cast<long long>(lt);
    }
    std::string rest;
    is >> rest;
    if (!is.eof() || rest.empty()) return std::nullopt;
    int sign = rest[0] == '-' ? -1 : 1;
    std::string digits = (rest[0] == '+' || rest[0] == '-') ? rest.substr(1) : rest;
    int oh = -1, om = 0;
    auto all_digits = [](const std::string& x) {
        return !x.empty() &&
               std::all_of(x.begin(), x.end(),
                           [](char c) { return std::isdigit(static_cast<unsigned char>(c)); });
    };
    if (digits.size() == 5 && digits[2] == ':') {
        oh = std::stoi(digits.substr(0, 2));
        om = std::stoi(digits.substr(3, 2));
    } else if (digits.size() == 4 && all_digits(digits)) {
        oh = std::stoi(digits.substr(0, 2));
        om = std::stoi(digits.substr(2, 2));
    } else if (digits.size() == 2 && all_digits(digits)) {
        oh = std::stoi(digits);
    }
    if (oh < 0) return std::nullopt;
    return secs - sign * (oh * 3600 + om * 60);
}

json Obj::to_dict() const {
    json o;
    o["name"] = name;
    o["path"] = path;
    o["is_dir"] = is_dir;
    o["size"] = size;
    o["mtime"] = mtime;
    o["sha1"] = sha1;
    return o;
}

std::shared_ptr<Driver> make_local(json config) { return new_local(std::move(config)); }
std::shared_ptr<Driver> make_openlist(json config) { return new_openlist(std::move(config)); }

const std::vector<std::pair<std::string, DriverFactory>>& drivers() {
    static const std::vector<std::pair<std::string, DriverFactory>> kReg = {
        {"local", new_local},
        {"webdav", new_webdav},
        {"openlist", new_openlist},
        {"alist", new_openlist},
        {"baidu_netdisk", new_baidu},
        {"baidu", new_baidu},
        {"123", new_123},
        {"123pan", new_123},
        {"google_drive", new_gdrive},
        {"gdrive", new_gdrive},
        {"onedrive", new_onedrive},
    };
    return kReg;
}

std::shared_ptr<Driver> get_driver(const json& type_val, const json& config) {
    std::string type_name_disp;  // "unknown driver: %s" keeps the original case
    std::string key;
    if (type_val.is_null()) {
        type_name_disp = "None";
    } else if (type_val.is_string()) {
        type_name_disp = type_val.get<std::string>();
        key = sp::lower(type_name_disp);
    } else {
        // (type_name or "").lower() on a non-str truthy object → AttributeError
        throw ApiError("AttributeError",
                       "'" + py_type_of(type_val) + "' object has no attribute 'lower'");
    }
    auto rem = removed_drivers().find(key);
    if (rem != removed_drivers().end()) {
        raise_value_error(rem->second +
                          "已停止支持：请删除该云存储配置，改用 OpenList "
                          "代理（在 OpenList 中添加对应存储后，此处填 OpenList 地址 + 挂载路径）。");
    }
    for (const auto& [name, factory] : drivers()) {
        if (name == key) {
            // BaseDriver.__init__: self.config = config or {}
            return factory(p5::py_truthy(config) ? config : json::object());
        }
    }
    raise_value_error("unknown driver: " + type_name_disp);
}

// ---------------------------------------------------------------------------
// Provider config storage
// ---------------------------------------------------------------------------
namespace {
std::mutex g_cfg_mu;  // read-modify-write atomicity across the CRUD ops
}

std::string cloud_config_path() {
    std::string ws;
    {
        std::lock_guard<std::mutex> lk(STATE().mu_);
        ws = STATE().workspace_root;
    }
    if (!ws.empty() && spath::is_dir(ws)) return spath::join(ws, ".editor_cloud.json");
    return spath::join(spath::join(editor_root(), "_cache"), "cloud_config.json");
}

json load_config() {
    std::string p = cloud_config_path();
    try {
        auto raw = spath::read_bytes(p);
        if (raw.has_value()) {
            json data = json::parse(*raw);
            if (data.is_object()) {
                if (!data.contains("providers")) data["providers"] = json::array();
                return data;
            }
        }
    } catch (...) {
    }
    json empty;
    empty["providers"] = json::array();
    return empty;
}

void save_config(const json& data) {
    std::string p = cloud_config_path();
    try {
        sa_core::write_text_atomic(p, sa_core::py_dumps_indent(data));
    } catch (...) {
    }
}

json list_providers() {
    std::lock_guard<std::mutex> lk(g_cfg_mu);
    return load_config()["providers"];
}

std::optional<json> get_provider(const std::string& pid) {
    for (const auto& p : list_providers()) {
        if (p.is_object() && p.contains("id") && p["id"].is_string() &&
            p["id"].get<std::string>() == pid) {
            return p;
        }
    }
    return std::nullopt;
}

json add_provider(const json& info) {
    std::lock_guard<std::mutex> lk(g_cfg_mu);
    json cfg = load_config();
    std::string pid;
    {
        json v = info.is_object() && info.contains("id") ? info["id"] : json(nullptr);
        if (!p5::py_truthy(v)) {
            pid = "";
        } else if (v.is_string()) {
            pid = p4::strip(v.get<std::string>());
        } else {
            throw ApiError("AttributeError",
                           "'" + py_type_of(v) + "' object has no attribute 'strip'");
        }
    }
    if (pid.empty()) {
        long long ms = sa_core::now_ms();
        pid = "p_" + std::to_string(((ms % 1000000) + 1000000) % 1000000);
    }
    json providers = json::array();
    if (cfg["providers"].is_array()) {
        for (const auto& p : cfg["providers"]) {
            if (!(p.is_object() && p.contains("id") && p["id"].is_string() &&
                  p["id"].get<std::string>() == pid)) {
                providers.push_back(p);
            }
        }
    }
    json entry;
    entry["id"] = pid;
    {
        json v = info.is_object() && info.contains("name") ? info["name"] : json(nullptr);
        entry["name"] = p5::py_truthy(v) ? v : json(pid);
    }
    std::string type;
    {
        json v = info.is_object() && info.contains("type") ? info["type"] : json(nullptr);
        if (!p5::py_truthy(v)) {
            type = "webdav";
        } else if (v.is_string()) {
            type = sp::lower(v.get<std::string>());
        } else {
            throw ApiError("AttributeError",
                           "'" + py_type_of(v) + "' object has no attribute 'lower'");
        }
    }
    entry["type"] = type;
    {
        json v = info.is_object() && info.contains("config") ? info["config"] : json(nullptr);
        entry["config"] = p5::py_truthy(v) ? v : json::object();
    }
    {
        json v = info.is_object() && info.contains("remote_root") ? info["remote_root"]
                                                                  : json(nullptr);
        if (!p5::py_truthy(v)) {
            v = info.is_object() && info.contains("remoteRoot") ? info["remoteRoot"]
                                                                : json(nullptr);
        }
        if (!p5::py_truthy(v)) v = json("mods");
        entry["remote_root"] = norm_remote_json(v);
    }
    entry["created_at"] = p5::iso_now_local();
    bool known = false;
    for (const auto& [name, f] : drivers()) {
        if (name == type) known = true;
    }
    if (!known) raise_value_error("unsupported driver type: " + type);
    providers.push_back(entry);
    cfg["providers"] = providers;
    save_config(cfg);
    return entry;
}

json update_provider(const std::string& pid, const json& patch) {
    std::lock_guard<std::mutex> lk(g_cfg_mu);
    json cfg = load_config();
    if (!cfg["providers"].is_array()) cfg["providers"] = json::array();
    json providers = cfg["providers"];
    long long found_i = -1;
    for (size_t i = 0; i < providers.size(); ++i) {
        if (providers[i].is_object() && providers[i].contains("id") &&
            providers[i]["id"].is_string() && providers[i]["id"].get<std::string>() == pid) {
            found_i = static_cast<long long>(i);
            break;
        }
    }
    if (found_i < 0) raise_value_error("provider not found: " + pid);
    json& found = providers[static_cast<size_t>(found_i)];
    auto patch_has = [&](const char* k) { return patch.is_object() && patch.contains(k); };

    // Python loops ("name","type","config","remote_root","remoteRoot") in that
    // fixed order (remoteRoot wins when both are present).
    if (patch_has("name")) found["name"] = patch["name"];
    if (patch_has("type")) {
        const json& v = patch["type"];
        std::string t;
        if (!p5::py_truthy(v)) {
            t = "";
        } else if (v.is_string()) {
            t = sp::lower(v.get<std::string>());
        } else {
            throw ApiError("AttributeError",
                           "'" + py_type_of(v) + "' object has no attribute 'lower'");
        }
        bool known = false;
        for (const auto& [name, f] : drivers()) {
            if (name == t) known = true;
        }
        if (!known) raise_value_error("unsupported type");
        found["type"] = t;
    }
    if (patch_has("config")) {
        const json& v = patch["config"];
        if (v.is_object()) {
            json new_cfg = v;
            json orig_cfg =
                found.contains("config") && found["config"].is_object() ? found["config"]
                                                                        : json::object();
            for (auto it = new_cfg.begin(); it != new_cfg.end(); ++it) {
                if (it.value().is_string() && it.value().get<std::string>() == "***" &&
                    orig_cfg.contains(it.key())) {
                    new_cfg[it.key()] = orig_cfg[it.key()];
                }
            }
            json merged = orig_cfg;
            for (auto it = new_cfg.begin(); it != new_cfg.end(); ++it) merged[it.key()] = it.value();
            found["config"] = merged;
        } else {
            found["config"] = v;
        }
    }
    if (patch_has("remote_root")) {
        found["remote_root"] = norm_remote_json(patch["remote_root"]);
    }
    if (patch_has("remoteRoot")) {
        found["remote_root"] = norm_remote_json(patch["remoteRoot"]);
    }
    cfg["providers"] = providers;
    save_config(cfg);
    return found;
}

void remove_provider(const std::string& pid) {
    std::lock_guard<std::mutex> lk(g_cfg_mu);
    json cfg = load_config();
    if (!cfg["providers"].is_array()) cfg["providers"] = json::array();
    size_t before = cfg["providers"].size();
    json providers = json::array();
    for (const auto& p : cfg["providers"]) {
        if (!(p.is_object() && p.contains("id") && p["id"].is_string() &&
              p["id"].get<std::string>() == pid)) {
            providers.push_back(p);
        }
    }
    if (providers.size() == before) raise_value_error("provider not found: " + pid);
    cfg["providers"] = providers;
    save_config(cfg);
}

// ---------------------------------------------------------------------------
// Sync engine
// ---------------------------------------------------------------------------
namespace {
std::mutex g_sync_mu;
json g_sync_state = [] {
    // cloud_sync.py:1854 — key order preserved.
    json s;
    s["running"] = false;
    s["provider"] = "";
    s["action"] = "";
    s["progress"] = 0;
    s["total"] = 0;
    s["last"] = "";
    s["error"] = "";
    s["history"] = json::array();
    return s;
}();

void push_history(const std::string& provider_id, const std::string& mod_name,
                  const std::string& direction, long long count) {
    std::lock_guard<std::mutex> lk(g_sync_mu);
    json hist;
    hist["time"] = p5::iso_now_local();
    hist["provider"] = provider_id;
    hist["mod"] = mod_name;
    hist["direction"] = direction;
    hist["count"] = count;
    json new_hist = json::array();
    new_hist.push_back(hist);
    if (g_sync_state["history"].is_array()) {
        for (const auto& h : g_sync_state["history"]) new_hist.push_back(h);
    }
    while (new_hist.size() > 20) new_hist.erase(new_hist.end() - 1);
    g_sync_state["history"] = new_hist;
}

std::string local_maybe_str(const json& v) {
    return v.is_string() ? v.get<std::string>() : sa_core::py_str(v);
}
}  // namespace

json sync_status() {
    std::lock_guard<std::mutex> lk(g_sync_mu);
    return g_sync_state;  // dict(_sync_state)
}

void set_sync_state(const json& kw) {
    std::lock_guard<std::mutex> lk(g_sync_mu);
    for (auto it = kw.begin(); it != kw.end(); ++it) g_sync_state[it.key()] = it.value();
}

std::string local_mods_root() {
    std::string ws, mod_root;
    {
        std::lock_guard<std::mutex> lk(STATE().mu_);
        ws = STATE().workspace_root;
        mod_root = STATE().mod_root;
    }
    if (!ws.empty() && spath::is_dir(ws)) return ws;
    if (!mod_root.empty() && spath::is_dir(spath::dirname(mod_root)))
        return spath::dirname(mod_root);
    return user_mods_dir();
}

std::string get_mod_dir(const std::string& mod_name) {
    try {
        json mods = list_mods();
        if (mods.is_array()) {
            for (const auto& m : mods) {
                if (m.is_object() && m.contains("name") && m["name"].is_string() &&
                    m["name"].get<std::string>() == mod_name) {
                    json rv = m.contains("root") ? m["root"] : json(nullptr);
                    if (!p5::py_truthy(rv)) return std::string();
                    return local_maybe_str(rv);
                }
            }
        }
    } catch (...) {
    }
    return spath::join(local_mods_root(), mod_name);
}

LocalFileMap list_local_files(const std::string& mod_name, bool compute_sha) {
    std::string mod_dir = get_mod_dir(mod_name);
    LocalFileMap out;
    if (mod_dir.empty() || !spath::is_dir(mod_dir)) return out;
    std::error_code ec;
    std::filesystem::path mod_p = spath::to_path(mod_dir);
    std::vector<std::filesystem::path> stack{mod_p};
    while (!stack.empty()) {
        std::filesystem::path root = std::move(stack.back());
        stack.pop_back();
        std::string rel_root =
            sa_core::str::replace_all(spath::path_to_utf8(
                                              std::filesystem::relative(root, mod_p, ec)),
                                          "\\", "/");
        if (ec || rel_root == "." ) rel_root = "";
        std::vector<std::string> files, dirs;
        for (std::filesystem::directory_iterator it(root, ec), e; it != e; it.increment(ec)) {
            if (ec) break;
            std::string name = spath::path_to_utf8(it->path().filename());
            std::error_code e2;
            if (it->is_directory(e2)) dirs.push_back(name);
            else files.push_back(name);
        }
        for (const auto& fn : files) {
            std::string full = spath::path_to_utf8(root / spath::to_path(fn));
            std::string rel = rel_root.empty() ? fn : rel_root + "/" + fn;
            if (sp::starts_with(rel, "_cache") || sp::starts_with(rel, ".git/") ||
                sp::ends_with(rel, ".tmp")) {
                continue;
            }
            if (rel == ".editor_flow.json") continue;
            if (sp::starts_with(fn, "~") || sp::starts_with(fn, ".")) {
                if (!sp::ends_with(fn, ".json")) continue;
            }
            std::error_code se;
            auto fsize = std::filesystem::file_size(full, se);
            if (se) continue;  // Python: try/except continue
            auto st = spath::stat(spath::path_to_utf8(full));
            std::string sha;
            if (compute_sha) {
                auto b = spath::read_bytes(spath::path_to_utf8(full));
                if (b.has_value()) sha = sa_core::sha1_hex(*b);
            }
            long long mt = st ? static_cast<long long>(std::floor(st->mtime_ns / 1e9)) : 0;
            out[rel] = {static_cast<long long>(fsize), mt, sha};
        }
        for (const auto& d : dirs) {
            if (sp::starts_with(d, "_cache") || sp::starts_with(d, ".tmp") ||
                d == "__pycache__" || d == ".editor_history") {
                continue;
            }
            stack.push_back(root / spath::to_path(d));
        }
    }
    return out;
}

std::string sha1_file(const std::string& path) {
    auto b = spath::read_bytes(path);
    if (!b.has_value()) return "";
    return sa_core::sha1_hex(*b);
}

std::string lazy_sha(const std::string& path) {
    try {
        if (spath::is_file(path)) {
            if (spath::file_size(path) > 20LL * 1024 * 1024) return "";
            return sha1_file(path);
        }
    } catch (...) {
    }
    return "";
}

bool need_sync(long long ls, long long lm, const std::string& lh, long long rs, long long rm,
               const std::string& rsha, const std::string& local_path) {
    if (ls != rs) return true;
    if (!lh.empty() && !rsha.empty()) return lh != rsha;
    // (lh present, rsha absent): Python's `pass` — mtime decides below.
    if (lh.empty() && !rsha.empty() && !local_path.empty()) {
        std::string lh2 = lazy_sha(local_path);
        if (!lh2.empty() && lh2 != rsha) return true;
    }
    if (lm && rm && std::llabs(lm - rm) > 2) return true;
    return false;
}

std::string remote_path_for(const json& provider, const std::string& mod_name,
                            const std::string& rel_path) {
    std::string root;
    {
        json v = provider.is_object() && provider.contains("remote_root")
                     ? provider["remote_root"]
                     : json(nullptr);
        if (!p5::py_truthy(v)) v = json("mods");
        root = norm_remote_json(v);
    }
    std::vector<std::string> parts;
    if (!root.empty()) parts.push_back(root);
    if (!mod_name.empty()) parts.push_back(norm_remote(mod_name));
    if (!rel_path.empty()) parts.push_back(norm_remote(rel_path));
    std::string out;
    for (const auto& p : parts) {
        if (p.empty()) continue;
        if (!out.empty()) out += "/";
        out += p;
    }
    return out;
}

std::optional<std::string> safe_rel_join(const std::string& mod_dir, const std::string& rel_in) {
    std::string rel = sa_core::str::replace_all(rel_in, "\\", "/");
    rel = strip_slashes(rel);
    std::vector<std::string> parts;
    size_t pos = 0;
    while (pos <= rel.size()) {
        size_t slash = rel.find('/', pos);
        std::string seg =
            rel.substr(pos, slash == std::string::npos ? std::string::npos : slash - pos);
        if (!seg.empty() && seg != ".") parts.push_back(seg);
        if (slash == std::string::npos) break;
        pos = slash + 1;
    }
    if (parts.empty()) return std::nullopt;
    for (const auto& p : parts) {
        if (p == "..") return std::nullopt;
    }
    if (rel[0] == '/' || (parts[0].size() >= 2 && parts[0][1] == ':')) {
        return std::nullopt;  // os.path.isabs(rel) / Windows drive letter
    }
    std::string base = spath::abs_path(mod_dir);
    std::string full = base;
    for (const auto& p : parts) full = spath::join(full, p);
    full = spath::abs_path(full);
    std::string nk = spath::normcase(full), bk = spath::normcase(base);
    if (nk != bk && !sp::starts_with(nk, bk + "\\")) return std::nullopt;
    return full;
}

std::map<std::string, Obj> list_remote_recursive(Driver* driver,
                                                 const std::string& remote_base) {
    std::map<std::string, Obj> out;
    std::vector<std::string> errors;
    std::vector<std::string> stack{std::string("")};
    std::set<std::string> visited;
    std::string base_norm = norm_remote(remote_base);
    while (!stack.empty()) {
        std::string cur = std::move(stack.back());
        stack.pop_back();
        if (visited.count(cur)) continue;
        visited.insert(cur);
        std::string remote = cur.empty() ? remote_base : strip_slashes(remote_base + "/" + cur);
        std::vector<Obj> objs;
        try {
            objs = driver->list(remote);
        } catch (const std::exception& e) {
            errors.push_back(remote + ": " + exception_str(e));
            if (cur.empty()) {
                raise_value_error("remote list failed at " + remote + ": " + exception_str(e));
            }
            continue;
        }
        if (objs.empty()) continue;
        for (const auto& o : objs) {
            std::string rel = o.path;
            if (!base_norm.empty() && sp::starts_with(rel, base_norm + "/")) {
                rel = rel.substr(base_norm.size() + 1);
            } else if (rel == base_norm) {
                rel = "";
            } else if (rel.find('/') == std::string::npos && !cur.empty()) {
                rel = lstrip_slashes(cur + "/" + rel);
            }
            rel = lstrip_slashes(sa_core::str::replace_all(rel, "\\", "/"));
            if (rel.empty()) continue;
            if (o.is_dir) {
                if (!visited.count(rel)) stack.push_back(rel);
            } else {
                out[rel] = o;
            }
        }
    }
    if (out.empty() && !errors.empty()) {
        std::string joined;
        for (const auto& e : errors) {
            if (!joined.empty()) joined += "; ";
            joined += e;
        }
        raise_value_error("remote list failed: " + joined);
    }
    return out;
}

void drv_get(Driver* driver, const std::string& remote, const std::string& local_path) {
    driver->get(remote, local_path);
    try {
        std::filesystem::path np = spath::to_path(local_path).lexically_normal();
        std::string rp = sa_core::str::replace_all(spath::path_to_utf8(np), "\\", "/");
        if (sp::ends_with(rp, ".json") && contains(rp, "/Cfgs/")) {
            sa::cfg_store::forget(local_path);
        }
    } catch (...) {
    }
}

json sync_mod_folder(const std::string& provider_id, const std::string& direction,
                     const std::string& mod_name, bool dry_run, bool delete_extra) {
    auto prov_opt = get_provider(provider_id);
    if (!prov_opt) raise_value_error("provider not found");
    std::shared_ptr<Driver> driver = get_driver(
        prov_opt->contains("type") ? (*prov_opt)["type"] : json(nullptr),
        prov_opt->contains("config") ? (*prov_opt)["config"] : json(nullptr));
    if (mod_name.empty() || contains(mod_name, "..") || contains(mod_name, "/") ||
        contains(mod_name, "\\")) {
        raise_value_error("invalid mod_name");
    }
    std::string mod_dir = get_mod_dir(mod_name);
    std::string remote_base = remote_path_for(*prov_opt, mod_name, "");
    set_sync_state(json{
        {"running", true}, {"provider", provider_id}, {"action", "folder_" + direction},
        {"progress", 0},   {"total", 0},              {"error", ""},
    });
    try {
        LocalFileMap local_map = list_local_files(mod_name, false);
        std::map<std::string, Obj> remote_map;
        try {
            remote_map = list_remote_recursive(driver.get(), remote_base);
        } catch (const std::exception& e) {
            set_sync_state(json{{"running", false}, {"error", exception_repr_full(e)}});
            raise_value_error("远端列举失败: " + exception_str(e));
        }
        std::set<std::string> all_rels;
        for (const auto& [k, v] : local_map) all_rels.insert(k);
        for (const auto& [k, v] : remote_map) all_rels.insert(k);
        long long total = static_cast<long long>(all_rels.size());
        set_sync_state(json{{"total", total}});
        if (total == 0) {
            bool mod_exists = false;
            try {
                std::string check_dir;
                json mods = list_mods();
                if (mods.is_array()) {
                    for (const auto& m : mods) {
                        if (m.is_object() && m.contains("name") && m["name"].is_string() &&
                            m["name"].get<std::string>() == mod_name) {
                            check_dir = m.contains("root") && m["root"].is_string()
                                            ? m["root"].get<std::string>()
                                            : std::string();
                            break;
                        }
                    }
                }
                if (check_dir.empty()) check_dir = spath::join(local_mods_root(), mod_name);
                mod_exists = spath::is_dir(check_dir);
            } catch (...) {
            }
            if (!mod_exists) {
                raise_value_error("本地 Mod 不存在: " + mod_name + "，请先在 Mod 列表中选择或创建");
            }
            set_sync_state(json{{"running", false}, {"progress", 0}});
            json res;
            res["results"] = json::array();
            res["dry_run"] = dry_run;
            res["direction"] = direction;
            res["total"] = 0;
            res["message"] = "未发现文件：本地与远端均为空或 Mod 为空，请确认 Mod 名称与远端路径";
            return res;
        }
        json results = json::array();
        long long idx = 0;
        for (const auto& rel : all_rels) {
            set_sync_state(json{{"progress", idx + 1}, {"last", rel}});
            ++idx;
            bool has_local = local_map.count(rel) != 0;
            bool has_remote = remote_map.count(rel) != 0;
            std::optional<std::string> local_full =
                rel.empty() ? std::optional<std::string>(mod_dir)
                            : safe_rel_join(mod_dir, rel);
            if (!local_full.has_value()) {
                json e;
                e["rel"] = rel;
                e["ok"] = false;
                e["action"] = "skip_unsafe_path";
                e["error"] = "远端路径不安全（含 .. 或盘符），已跳过";
                results.push_back(e);
                continue;
            }
            try {
                auto push_action = [&](const std::string& action) {
                    json e;
                    e["rel"] = rel;
                    e["ok"] = true;
                    e["action"] = action;
                    results.push_back(e);
                };
                if (direction == "upload") {
                    if (!has_local) {
                        if (delete_extra && has_remote) {
                            if (!dry_run) driver->remove(remote_base + "/" + rel);
                            push_action("delete_remote");
                        } else {
                            push_action("skip_extra_remote");
                        }
                    } else if (!has_remote) {
                        if (!dry_run) driver->put(*local_full, remote_base + "/" + rel);
                        push_action("upload_new");
                    } else {
                        auto [ls, lm, lh] = local_map[rel];
                        const Obj& ro = remote_map[rel];
                        long long rs = ro.size, rm = ro.mtime;
                        std::string rsha = ro.sha1;
                        if (lh.empty() && ls == rs) {
                            lh = lazy_sha(*local_full);
                            local_map[rel] = {ls, lm, lh};
                        }
                        if (need_sync(ls, lm, lh, rs, rm, rsha, *local_full)) {
                            if (!dry_run) driver->put(*local_full, remote_base + "/" + rel);
                            push_action("upload_update");
                        } else {
                            push_action("skip_unchanged");
                        }
                    }
                } else if (direction == "download") {
                    if (!has_remote) {
                        push_action("skip_local_extra");
                    } else if (!has_local) {
                        if (!dry_run) {
                            spath::create_dirs(spath::dirname(*local_full));
                            drv_get(driver.get(), remote_base + "/" + rel, *local_full);
                        }
                        push_action("download_new");
                    } else {
                        auto [ls, lm, lh] = local_map[rel];
                        const Obj& ro = remote_map[rel];
                        long long rs = ro.size, rm = ro.mtime;
                        std::string rsha = ro.sha1;
                        if (lh.empty() && ls == rs && !rsha.empty()) {
                            lh = lazy_sha(*local_full);
                            local_map[rel] = {ls, lm, lh};
                        }
                        if (need_sync(ls, lm, lh, rs, rm, rsha, *local_full)) {
                            if (!dry_run) {
                                spath::create_dirs(spath::dirname(*local_full));
                                drv_get(driver.get(), remote_base + "/" + rel, *local_full);
                            }
                            push_action("download_update");
                        } else {
                            push_action("skip_unchanged");
                        }
                    }
                } else if (direction == "sync") {
                    if (!has_local && has_remote) {
                        if (!dry_run) {
                            spath::create_dirs(spath::dirname(*local_full));
                            drv_get(driver.get(), remote_base + "/" + rel, *local_full);
                        }
                        push_action("sync_download");
                    } else if (!has_remote && has_local) {
                        if (!dry_run) driver->put(*local_full, remote_base + "/" + rel);
                        push_action("sync_upload");
                    } else if (has_local && has_remote) {
                        auto [ls, lm, lh] = local_map[rel];
                        const Obj& ro = remote_map[rel];
                        long long rs = ro.size, rm = ro.mtime;
                        std::string rsha = ro.sha1;
                        if (lh.empty() && ls == rs && !rsha.empty()) {
                            lh = lazy_sha(*local_full);
                            local_map[rel] = {ls, lm, lh};
                        }
                        if (need_sync(ls, lm, lh, rs, rm, rsha, *local_full)) {
                            if (rm && lm && rm > lm) {
                                if (!dry_run) {
                                    spath::create_dirs(spath::dirname(*local_full));
                                    drv_get(driver.get(), remote_base + "/" + rel, *local_full);
                                }
                                push_action("sync_download_update");
                            } else {
                                if (!dry_run) driver->put(*local_full, remote_base + "/" + rel);
                                push_action("sync_upload_update");
                            }
                        } else {
                            push_action("skip");
                        }
                    }
                    // both-false cannot occur: rel came from one of the maps.
                } else {
                    raise_value_error("unknown direction");
                }
            } catch (const std::exception& e) {
                json err;
                err["rel"] = rel;
                err["ok"] = false;
                err["error"] = exception_repr_full(e);
                results.push_back(err);
            }
        }
        set_sync_state(json{{"running", false}, {"progress", total}});
        push_history(provider_id, mod_name, "folder_" + direction,
                     static_cast<long long>(results.size()));
        json res;
        res["results"] = results;
        res["dry_run"] = dry_run;
        res["direction"] = direction;
        res["total"] = total;
        return res;
    } catch (...) {
        std::string err;
        try {
            throw;
        } catch (const std::exception& e) {
            err = exception_repr_full(e);
        } catch (...) {
            err = "RuntimeError: unknown";
        }
        set_sync_state(json{{"running", false}, {"error", err}});
        throw;
    }
}

json sync_single_file(const std::string& provider_id, const std::string& direction,
                      const std::string& mod_name, const std::string& rel_path, bool dry_run) {
    auto prov_opt = get_provider(provider_id);
    if (!prov_opt) raise_value_error("provider not found");
    std::shared_ptr<Driver> driver = get_driver(
        prov_opt->contains("type") ? (*prov_opt)["type"] : json(nullptr),
        prov_opt->contains("config") ? (*prov_opt)["config"] : json(nullptr));
    std::string mod_dir_real = get_mod_dir(mod_name);
    if (mod_name.empty() || contains(mod_name, "..") || contains(mod_name, "/") ||
        contains(mod_name, "\\")) {
        raise_value_error("invalid mod_name");
    }
    std::string rel = norm_remote(rel_path);
    if (rel.empty()) raise_value_error("rel_path required");
    std::string local_path = spath::abs_path(spath::join(mod_dir_real, rel));
    std::string base = spath::abs_path(mod_dir_real);
    std::string nk = spath::normcase(local_path), bk = spath::normcase(base);
    if (nk != bk && !sp::starts_with(nk, bk + "\\")) raise_value_error("path escapes mod");
    std::string remote = remote_path_for(*prov_opt, mod_name, rel);
    if (dry_run) {
        bool local_exists = spath::is_file(local_path);
        std::optional<Obj> remote_obj;
        try {
            remote_obj = driver->stat(remote);
        } catch (...) {
            remote_obj = std::nullopt;
        }
        json res;
        res["dry_run"] = true;
        res["local_exists"] = local_exists;
        res["local_size"] = local_exists ? spath::file_size(local_path) : 0;
        res["remote_exists"] = remote_obj.has_value();
        res["remote_size"] = remote_obj ? remote_obj->size : 0;
        res["remote"] = remote;
        res["local"] = local_path;
        res["direction"] = direction;
        return res;
    }
    if (direction == "upload") {
        if (!spath::is_file(local_path)) raise_file_not_found("local file not found: " + rel);
        driver->put(local_path, remote);
        set_sync_state(json{{"last", "upload " + rel + " -> " + remote}});
        json res;
        res["ok"] = true;
        res["remote"] = remote;
        return res;
    } else if (direction == "download") {
        spath::create_dirs(spath::dirname(local_path));
        drv_get(driver.get(), remote, local_path);
        set_sync_state(json{{"last", "download " + rel}});
        json res;
        res["ok"] = true;
        res["local"] = local_path;
        return res;
    } else if (direction == "delete_remote") {
        driver->remove(remote);
        json res;
        res["ok"] = true;
        return res;
    } else if (direction == "delete_local") {
        if (spath::is_file(local_path)) spath::remove_file(local_path);
        json res;
        res["ok"] = true;
        return res;
    } else if (direction == "sync") {
        bool local_exists = spath::is_file(local_path);
        std::optional<Obj> remote_obj;
        try {
            remote_obj = driver->stat(remote);
        } catch (...) {
            remote_obj = std::nullopt;
        }
        json res;
        if (!local_exists && !remote_obj) {
            raise_file_not_found("neither local nor remote exists: " + rel);
        }
        if (local_exists && !remote_obj) {
            driver->put(local_path, remote);
            set_sync_state(json{{"last", "sync upload " + rel + " -> " + remote}});
            res["ok"] = true;
            res["action"] = "sync_upload";
            res["remote"] = remote;
            return res;
        }
        if (!local_exists && remote_obj) {
            spath::create_dirs(spath::dirname(local_path));
            drv_get(driver.get(), remote, local_path);
            set_sync_state(json{{"last", "sync download " + rel}});
            res["ok"] = true;
            res["action"] = "sync_download";
            res["local"] = local_path;
            return res;
        }
        long long ls = spath::file_size(local_path);
        auto lst = spath::stat(local_path);
        long long lm = lst ? static_cast<long long>(std::floor(lst->mtime_ns / 1e9)) : 0;
        if (!need_sync(ls, lm, "", remote_obj->size, remote_obj->mtime, remote_obj->sha1,
                       local_path)) {
            res["ok"] = true;
            res["action"] = "skip";
            return res;
        }
        if (remote_obj->mtime && lm && remote_obj->mtime > lm) {
            drv_get(driver.get(), remote, local_path);
            set_sync_state(json{{"last", "sync download " + rel}});
            res["ok"] = true;
            res["action"] = "sync_download_update";
            res["local"] = local_path;
            return res;
        }
        driver->put(local_path, remote);
        set_sync_state(json{{"last", "sync upload " + rel + " -> " + remote}});
        res["ok"] = true;
        res["action"] = "sync_upload_update";
        res["remote"] = remote;
        return res;
    } else {
        raise_value_error("unknown direction: " + direction);
    }
}

json sync_mod_files(const std::string& provider_id, const std::string& direction,
                    const std::string& mod_name, const json& rel_paths, bool dry_run) {
    auto prov_opt = get_provider(provider_id);
    if (!prov_opt) raise_value_error("provider not found");
    if (mod_name.empty()) raise_value_error("mod_name required");
    json paths_in = p5::py_truthy(rel_paths) ? rel_paths : json::array();
    if (!paths_in.is_array()) raise_value_error("rel_paths must be list");
    std::vector<std::string> paths;
    for (const auto& p : paths_in) {
        if (!p5::py_truthy(p)) continue;
        paths.push_back(norm_remote(local_maybe_str(p)));
    }
    if (paths.empty()) raise_value_error("no files to sync");
    if (paths.size() > 500) raise_value_error("too many files (>500)");
    set_sync_state(json{{"running", true},
                        {"provider", provider_id},
                        {"action", direction},
                        {"progress", 0},
                        {"total", static_cast<long long>(paths.size())},
                        {"error", ""}});
    json results = json::array();
    try {
        for (size_t i = 0; i < paths.size(); ++i) {
            const std::string& rel = paths[i];
            set_sync_state(
                json{{"progress", static_cast<long long>(i + 1)}, {"last", rel}});
            try {
                json r = sync_single_file(provider_id, direction, mod_name, rel, dry_run);
                json e;
                e["rel"] = rel;
                e["ok"] = true;
                e["result"] = r;
                results.push_back(e);
            } catch (const std::exception& e) {
                json err;
                err["rel"] = rel;
                err["ok"] = false;
                err["error"] = exception_repr_full(e);
                results.push_back(err);
            }
        }
        set_sync_state(
            json{{"running", false}, {"progress", static_cast<long long>(paths.size())}});
        push_history(provider_id, mod_name, direction,
                     static_cast<long long>(paths.size()));
        json res;
        res["results"] = results;
        res["dry_run"] = dry_run;
        return res;
    } catch (...) {
        std::string err;
        try {
            throw;
        } catch (const std::exception& e) {
            err = exception_repr_full(e);
        } catch (...) {
            err = "RuntimeError: unknown";
        }
        set_sync_state(json{{"running", false}, {"error", err}});
        throw;
    }
}

}  // namespace cloud
}  // namespace sa
