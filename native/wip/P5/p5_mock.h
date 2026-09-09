// wip/P5/p5_mock.h — header-only local HTTP mock for the [p5] suite.
//
// Why not httplib::Server (previously tried here): the vendored cpp-httplib
// 0.18.3 hard-rejects any verb outside {GET,HEAD,POST,PUT,DELETE,CONNECT,
// OPTIONS,TRACE,PATCH,PRI} at parse_request_line (→ bare 400, routing never
// runs), and a set_pre_routing_handler catch-all answers BEFORE the request
// body is consumed — the unread body bytes desynchronize the keep-alive
// stream (WinHTTP then sees garbage/400 on the pooled connection). WebDAV
// needs PROPFIND/MKCOL, so this mock is a tiny Winsock server instead:
// arbitrary verb tokens, Content-Length bodies, one request per connection
// (Connection: close), handlers keyed by (method, path-prefix).
//
// Usage: register handlers with on(...), call start(). stop() runs from dtor.
#pragma once

#include <atomic>
#include <cctype>
#include <cstdlib>
#include <functional>
#include <map>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#ifdef _WIN32
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <winsock2.h>
#include <ws2tcpip.h>
#endif

namespace p5mock {

struct Call {
    std::string method;
    std::string target;  // path[?query]
    std::string body;
    std::map<std::string, std::string> headers;  // lower-cased keys
};

struct Request {
    std::string method;
    std::string target;
    std::string path;   // decoded, query stripped
    std::string body;
    std::map<std::string, std::string> headers;  // lower-cased keys

    std::string get_header_value(const std::string& key) const {
        std::string k;
        for (char c : key) k += static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
        auto it = headers.find(k);
        return it == headers.end() ? std::string() : it->second;
    }
    bool has_header(const std::string& key) const {
        std::string k;
        for (char c : key) k += static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
        return headers.count(k) != 0;
    }
};

struct Response {
    int status = 200;
    std::string body;
    std::string content_type = "text/plain";
    std::map<std::string, std::string> extra_headers;

    void set_content(std::string data, std::string mime) {
        body = std::move(data);
        content_type = std::move(mime);
    }
    void set_header(std::string k, std::string v) { extra_headers[std::move(k)] = std::move(v); }
};

class Server {
  public:
    using Responder = std::function<void(const Request&, Response&)>;

    ~Server() { stop(); }

    // First registered responder whose (method, path-prefix) matches wins.
    // Empty method/prefix are wildcards. Prefix is matched against the RAW
    // target (path[?query], percent-encoded form as sent).
    void on(std::string method, std::string path_prefix, Responder fn) {
        std::lock_guard<std::mutex> lk(mu_);
        routes_.push_back({std::move(method), std::move(path_prefix), std::move(fn)});
    }
    void serve() {}  // API-compat shim; this mock always serves.

    int start() {
#ifdef _WIN32
        static bool wsa_ready = [] {
            WSADATA wsa;
            return WSAStartup(MAKEWORD(2, 2), &wsa) == 0;
        }();
        if (!wsa_ready) return 0;
        listen_ = ::socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
        if (listen_ == INVALID_SOCKET) return 0;
        sockaddr_in addr{};
        addr.sin_family = AF_INET;
        addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        addr.sin_port = 0;
        if (::bind(listen_, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) != 0) {
            ::closesocket(listen_);
            listen_ = INVALID_SOCKET;
            return 0;
        }
        int name_len = sizeof(addr);
        ::getsockname(listen_, reinterpret_cast<sockaddr*>(&addr), &name_len);
        port_ = ntohs(addr.sin_port);
        if (::listen(listen_, 16) != 0) {
            ::closesocket(listen_);
            listen_ = INVALID_SOCKET;
            port_ = 0;
            return 0;
        }
        th_ = std::thread([this] { accept_loop(); });
#endif
        return port_;
    }

    void stop() {
#ifdef _WIN32
        stop_ = true;
        if (listen_ != INVALID_SOCKET) {
            ::closesocket(listen_);
            listen_ = INVALID_SOCKET;
        }
        if (th_.joinable()) th_.join();
#endif
    }

    int port() const { return port_; }
    std::string base() const { return "http://127.0.0.1:" + std::to_string(port_); }

    std::vector<Call> calls() {
        std::lock_guard<std::mutex> lk(mu_);
        return calls_;
    }
    void clear_calls() {
        std::lock_guard<std::mutex> lk(mu_);
        calls_.clear();
    }

  private:
    struct Route {
        std::string method;
        std::string prefix;
        Responder fn;
    };

#ifdef _WIN32
    static std::string to_lower(std::string s) {
        for (auto& c : s) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
        return s;
    }

    static std::string percent_decode(const std::string& in) {
        auto hexv = [](char c) -> int {
            if (c >= '0' && c <= '9') return c - '0';
            if (c >= 'a' && c <= 'f') return c - 'a' + 10;
            if (c >= 'A' && c <= 'F') return c - 'A' + 10;
            return -1;
        };
        std::string out;
        for (size_t i = 0; i < in.size(); ++i) {
            if (in[i] == '%' && i + 2 < in.size()) {
                int h = hexv(in[i + 1]), l = hexv(in[i + 2]);
                if (h >= 0 && l >= 0) {
                    out += static_cast<char>(h * 16 + l);
                    i += 2;
                    continue;
                }
            }
            out += in[i];
        }
        return out;
    }

    static std::string reason(int status) {
        switch (status) {
            case 200: return "OK";
            case 201: return "Created";
            case 204: return "No Content";
            case 207: return "Multi-Status";
            case 400: return "Bad Request";
            case 401: return "Unauthorized";
            case 403: return "Forbidden";
            case 404: return "Not Found";
            case 405: return "Method Not Allowed";
            case 500: return "Internal Server Error";
            default: return "Status";
        }
    }

    static bool recv_until(SOCKET s, std::string& buf, const std::string& delim,
                           size_t max_bytes) {
        char c;
        while (buf.find(delim) == std::string::npos) {
            if (buf.size() > max_bytes) return false;
            int n = ::recv(s, &c, 1, 0);
            if (n <= 0) return false;
            buf += c;
        }
        return true;
    }

    void accept_loop() {
        while (!stop_) {
            SOCKET conn = ::accept(listen_, nullptr, nullptr);
            if (conn == INVALID_SOCKET) {
                if (stop_) break;
                continue;  // transient accept error
            }
            // Bound every read so a misbehaving client cannot wedge the mock.
            DWORD tv = 10000;
            ::setsockopt(conn, SOL_SOCKET, SO_RCVTIMEO, reinterpret_cast<char*>(&tv),
                         sizeof(tv));
            ::setsockopt(conn, SOL_SOCKET, SO_SNDTIMEO, reinterpret_cast<char*>(&tv),
                         sizeof(tv));
            handle_connection(conn);
            ::closesocket(conn);
        }
    }

    void handle_connection(SOCKET conn) {
        std::string buf;
        if (!recv_until(conn, buf, "\r\n\r\n", 1 << 20)) return;
        std::string head = buf.substr(0, buf.size() - 2);  // strip trailing CRLF
        size_t line_end = head.find("\r\n");
        std::string request_line = head.substr(0, line_end == std::string::npos ? head.size()
                                                                                : line_end);
        std::string rest = line_end == std::string::npos ? std::string()
                                                         : head.substr(line_end + 2);
        // request line: METHOD TARGET VERSION
        size_t sp1 = request_line.find(' ');
        size_t sp2 = request_line.rfind(' ');
        if (sp1 == std::string::npos || sp2 == sp1) return;
        Request req;
        req.method = request_line.substr(0, sp1);
        req.target = request_line.substr(sp1 + 1, sp2 - sp1 - 1);
        // headers
        long long content_length = 0;
        size_t pos = 0;
        while (pos < rest.size()) {
            size_t eol = rest.find("\r\n", pos);
            std::string line = eol == std::string::npos ? rest.substr(pos)
                                                        : rest.substr(pos, eol - pos);
            pos = eol == std::string::npos ? rest.size() : eol + 2;
            size_t colon = line.find(':');
            if (colon == std::string::npos) continue;
            std::string k = to_lower(line.substr(0, colon));
            std::string v = line.substr(colon + 1);
            while (!v.empty() && (v.front() == ' ' || v.front() == '\t')) v.erase(v.begin());
            req.headers[k] = v;
            if (k == "content-length") content_length = std::atoll(v.c_str());
        }
        // body
        std::string body = buf.substr(buf.find("\r\n\r\n") + 4);
        while (static_cast<long long>(body.size()) < content_length) {
            char chunk[8192];
            int n = ::recv(conn, chunk, sizeof(chunk), 0);
            if (n <= 0) break;
            body.append(chunk, static_cast<size_t>(n));
        }
        if (content_length > 0 && static_cast<long long>(body.size()) > content_length)
            body.resize(static_cast<size_t>(content_length));
        req.body = body;
        size_t qpos = req.target.find('?');
        req.path = percent_decode(req.target.substr(0, qpos));

        {
            std::lock_guard<std::mutex> lk(mu_);
            Call c;
            c.method = req.method;
            c.target = req.target;
            c.body = req.body;
            c.headers = req.headers;
            calls_.push_back(c);
        }

        Response res;
        bool matched = false;
        {
            std::lock_guard<std::mutex> lk(mu_);
            for (const auto& r : routes_) {
                if (!r.method.empty() && r.method != req.method) continue;
                if (!r.prefix.empty() && req.target.rfind(r.prefix, 0) != 0) continue;
                r.fn(req, res);  // handlers are registered before start()
                matched = true;
                break;
            }
        }
        if (!matched) {
            res.status = 404;
            res.set_content("{\"error\":\"no mock route\"}", "application/json");
        }

        std::string out = "HTTP/1.1 " + std::to_string(res.status) + " " + reason(res.status) +
                          "\r\nContent-Type: " + res.content_type + "\r\nContent-Length: " +
                          std::to_string(res.body.size()) + "\r\nConnection: close\r\n";
        for (const auto& [k, v] : res.extra_headers) out += k + ": " + v + "\r\n";
        out += "\r\n";
        out += res.body;
        size_t sent = 0;
        while (sent < out.size()) {
            int n = ::send(conn, out.data() + sent, static_cast<int>(out.size() - sent), 0);
            if (n <= 0) break;
            sent += static_cast<size_t>(n);
        }
    }

    SOCKET listen_{INVALID_SOCKET};
#endif
    std::thread th_;
    std::atomic<bool> stop_{false};
    int port_ = 0;
    std::mutex mu_;
    std::vector<Route> routes_;
    std::vector<Call> calls_;
};

}  // namespace p5mock
